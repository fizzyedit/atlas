//! Line-scanner parser for a single markdown note.
//!
//! Deliberately **not** cmark: the index needs the line and column of every link (backlinks
//! quote the source line; `[[Note#Heading]]` scrolls to a line), which the AST only gives
//! grudgingly, and it needs none of the rest of the tree. One pass over the bytes produces
//! every record the indexer writes — title, aliases, headings, links, tags — with fenced and
//! inline code suppressed so a `[[example]]` in a code block never becomes an edge.
//!
//! Pure: bytes in, records out. No filesystem, no database. Wikilink syntax comes from the
//! SDK tokenizer so this and the markdown renderer can never disagree about what a link is.
const std = @import("std");
const sdk = @import("fizzy_sdk");

const schema = @import("schema.zig");
const resolve = @import("resolve.zig");
const wikilink = sdk.services.wikilink;

/// Everything extracted from one note. Strings are owned by `arena` — free the arena, free
/// the note. The indexer gives each file its own arena and discards it after the write.
pub const Note = struct {
    title: []const u8 = "",
    aliases: []const []const u8 = &.{},
    headings: []const Heading = &.{},
    links: []const Link = &.{},
    tags: []const Tag = &.{},
    blocks: []const Block = &.{},
};

pub const Heading = struct {
    text: []const u8,
    level: u8,
    /// 0-based.
    line: u32,
};

pub const Link = struct {
    /// Exactly what was between the brackets / in the URL — the resolver sees this.
    raw: []const u8,
    heading: []const u8 = "",
    alias: []const u8 = "",
    kind: schema.LinkKind,
    /// 0-based.
    line: u32,
    /// 0-based byte column of the link's start within the line.
    col: u32,
    /// The whole source line, for the backlinks list.
    context: []const u8,
};

pub const Tag = struct {
    tag: []const u8,
    /// 0-based.
    line: u32,
};

/// One paragraph/list/code/blockquote/table span. Headings are not blocks — they keep their own
/// `Heading` record — so a document's body, once headings are pulled out, is entirely covered by
/// these. Which heading owns a block is resolved at read time (`query.noteContentGraph`), not
/// stored here, the same choice already made for `Link.heading`.
pub const Block = struct {
    kind: schema.BlockKind,
    /// 0-based, inclusive.
    line_start: u32,
    /// 0-based, inclusive.
    line_end: u32,
    /// Word count for prose kinds, line count for `.code`.
    weight: u32,
};

/// Accumulates the block currently being scanned, one line at a time, and flushes it into
/// `blocks` when the scanner decides the block has ended. Kept as its own type (rather than a
/// handful of loose locals in `scan`) because it needs to be threaded through several branches
/// of the per-line loop without each one re-deriving the flush/weight logic.
const BlockAcc = struct {
    kind: ?schema.BlockKind = null,
    line_start: u32 = 0,
    byte_start: usize = 0,
    last_line: u32 = 0,
    last_line_end: usize = 0,

    fn open(self: *BlockAcc, kind: schema.BlockKind, line_no: u32, byte_start: usize, byte_end: usize) void {
        self.kind = kind;
        self.line_start = line_no;
        self.byte_start = byte_start;
        self.last_line = line_no;
        self.last_line_end = byte_end;
    }

    fn extend(self: *BlockAcc, line_no: u32, byte_end: usize) void {
        self.last_line = line_no;
        self.last_line_end = byte_end;
    }

    fn flush(self: *BlockAcc, arena: std.mem.Allocator, bytes: []const u8, blocks: *std.ArrayList(Block)) !void {
        const kind = self.kind orelse return;
        self.kind = null;
        const weight: u32 = if (kind == .code)
            self.last_line - self.line_start + 1
        else
            countWords(bytes[self.byte_start..self.last_line_end]);
        try blocks.append(arena, .{
            .kind = kind,
            .line_start = self.line_start,
            .line_end = self.last_line,
            .weight = weight,
        });
    }
};

/// Scan `bytes` into records allocated from `arena`.
pub fn scan(arena: std.mem.Allocator, bytes: []const u8) !Note {
    var aliases: std.ArrayList([]const u8) = .empty;
    var headings: std.ArrayList(Heading) = .empty;
    var links: std.ArrayList(Link) = .empty;
    var tags: std.ArrayList(Tag) = .empty;
    var blocks: std.ArrayList(Block) = .empty;
    var acc: BlockAcc = .{};

    var title: []const u8 = "";
    var body_start: usize = 0;

    if (parseFrontMatter(bytes)) |fm| {
        body_start = fm.body_start;
        if (fm.title) |t| title = try arena.dupe(u8, t);
        for (fm.aliases()) |a| {
            try aliases.append(arena, try arena.dupe(u8, a));
        }
    }

    var line_no: u32 = 0;
    // Front matter occupies lines too; count them so body line numbers match the file.
    {
        var i: usize = 0;
        while (i < body_start) : (i += 1) {
            if (bytes[i] == '\n') line_no += 1;
        }
    }

    var in_fence = false;
    var fence_char: u8 = 0;
    var fence_len: usize = 0;

    var pos = body_start;
    while (pos <= bytes.len) {
        // The loop runs one extra time past a trailing `\n` (`pos == bytes.len`) so the last
        // real line still gets processed like any other; that pass carries no content and must
        // not be mistaken for one more line of an unclosed fence.
        const is_phantom_tail = pos == bytes.len;
        const line_end = std.mem.indexOfScalarPos(u8, bytes, pos, '\n') orelse bytes.len;
        const line = bytes[pos..line_end];
        // Drop a trailing `\r` so Windows-flavored notes don't put CR into contexts.
        const content = if (line.len > 0 and line[line.len - 1] == '\r') line[0 .. line.len - 1] else line;

        if (in_fence) {
            if (!is_phantom_tail) acc.extend(line_no, pos + content.len);
            if (isClosingFence(content, fence_char, fence_len)) {
                in_fence = false;
                try acc.flush(arena, bytes, &blocks);
            }
        } else if (openingFence(content)) |f| {
            // A fence always starts a fresh block, whatever was open before it.
            try acc.flush(arena, bytes, &blocks);
            in_fence = true;
            fence_char = f.char;
            fence_len = f.len;
            acc.open(.code, line_no, pos, pos + content.len);
        } else {
            if (parseAtxHeading(content)) |h| {
                try acc.flush(arena, bytes, &blocks);
                try headings.append(arena, .{
                    .text = try arena.dupe(u8, h.text),
                    .level = h.level,
                    .line = line_no,
                });
            } else if (isBlank(content)) {
                try acc.flush(arena, bytes, &blocks);
            } else {
                const kind = classifyBlockLine(content);
                if (acc.kind != null and acc.kind.? == kind) {
                    acc.extend(line_no, pos + content.len);
                } else {
                    try acc.flush(arena, bytes, &blocks);
                    acc.open(kind, line_no, pos, pos + content.len);
                }
            }
            try scanLine(arena, content, line_no, &links, &tags);
        }

        if (line_end == bytes.len) break;
        pos = line_end + 1;
        line_no += 1;
    }
    // EOF with no trailing blank line still ends whatever block was open (a paragraph, an
    // unclosed fence, ...).
    try acc.flush(arena, bytes, &blocks);

    return .{
        .title = title,
        .aliases = try aliases.toOwnedSlice(arena),
        .headings = try headings.toOwnedSlice(arena),
        .links = try links.toOwnedSlice(arena),
        .tags = try tags.toOwnedSlice(arena),
        .blocks = try blocks.toOwnedSlice(arena),
    };
}

// -- front matter -----------------------------------------------------------------

const FrontMatter = struct {
    title: ?[]const u8 = null,
    /// Inline storage so returning this struct doesn't dangle a stack slice.
    alias_buf: [32][]const u8 = undefined,
    alias_n: usize = 0,
    body_start: usize,

    fn aliases(self: *const FrontMatter) []const []const u8 {
        return self.alias_buf[0..self.alias_n];
    }
};

/// Obsidian-style YAML between a leading `---` and a closing `---`. Only `title` and
/// `aliases` are read; everything else is ignored. Returns null when the file doesn't
/// start with a front-matter block.
fn parseFrontMatter(bytes: []const u8) ?FrontMatter {
    // Optional UTF-8 BOM.
    var start: usize = 0;
    if (bytes.len >= 3 and bytes[0] == 0xEF and bytes[1] == 0xBB and bytes[2] == 0xBF) start = 3;

    if (!std.mem.startsWith(u8, bytes[start..], "---")) return null;
    const after_open = start + 3;
    // The opening `---` must be alone on the first line (optional trailing spaces).
    const first_nl = std.mem.indexOfScalarPos(u8, bytes, after_open, '\n') orelse return null;
    if (!isBlank(bytes[after_open..first_nl])) return null;

    const body_of_fm = first_nl + 1;
    // Find the closing `---` on its own line.
    var i = body_of_fm;
    while (i < bytes.len) {
        const nl = std.mem.indexOfScalarPos(u8, bytes, i, '\n') orelse {
            // Unclosed front matter — treat the file as having none rather than swallowing it.
            return null;
        };
        const line = trimRight(bytes[i..nl]);
        if (std.mem.eql(u8, line, "---") or std.mem.eql(u8, line, "...")) {
            return parseFrontMatterBody(bytes[body_of_fm..i], nl + 1);
        }
        i = nl + 1;
    }
    return null;
}

fn parseFrontMatterBody(body: []const u8, body_start: usize) FrontMatter {
    var fm: FrontMatter = .{ .body_start = body_start };
    var in_aliases_list = false;

    var iter = std.mem.splitScalar(u8, body, '\n');
    while (iter.next()) |raw_line| {
        const line = trimRight(raw_line);
        const trimmed = std.mem.trim(u8, line, " \t");

        if (in_aliases_list) {
            if (std.mem.startsWith(u8, trimmed, "- ")) {
                const val = std.mem.trim(u8, trimmed[2..], " \t");
                if (val.len > 0 and fm.alias_n < fm.alias_buf.len) {
                    fm.alias_buf[fm.alias_n] = unquote(val);
                    fm.alias_n += 1;
                }
                continue;
            }
            // Dedent or a new key ends the list.
            if (line.len > 0 and (line[0] == ' ' or line[0] == '\t')) continue;
            in_aliases_list = false;
        }

        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        if (std.mem.indexOfScalar(u8, trimmed, ':')) |colon| {
            const key = std.mem.trim(u8, trimmed[0..colon], " \t");
            const value = std.mem.trim(u8, trimmed[colon + 1 ..], " \t");

            if (std.mem.eql(u8, key, "title")) {
                if (value.len > 0) fm.title = unquote(value);
            } else if (std.mem.eql(u8, key, "aliases") or std.mem.eql(u8, key, "alias")) {
                if (value.len == 0) {
                    in_aliases_list = true;
                } else if (value[0] == '[') {
                    // Inline flow: `[a, b, "c"]`.
                    fm.alias_n = parseInlineAliasList(value, &fm.alias_buf);
                } else if (fm.alias_n < fm.alias_buf.len) {
                    fm.alias_buf[fm.alias_n] = unquote(value);
                    fm.alias_n += 1;
                }
            }
        }
    }

    return fm;
}

fn parseInlineAliasList(value: []const u8, out: *[32][]const u8) usize {
    if (value.len < 2 or value[0] != '[') return 0;
    const end = std.mem.lastIndexOfScalar(u8, value, ']') orelse return 0;
    const inner = value[1..end];
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, inner, ',');
    while (it.next()) |part| {
        const t = std.mem.trim(u8, part, " \t");
        if (t.len == 0) continue;
        if (n >= out.len) break;
        out[n] = unquote(t);
        n += 1;
    }
    return n;
}

fn unquote(s: []const u8) []const u8 {
    if (s.len >= 2 and ((s[0] == '"' and s[s.len - 1] == '"') or (s[0] == '\'' and s[s.len - 1] == '\''))) {
        return s[1 .. s.len - 1];
    }
    return s;
}

// -- headings / fences ------------------------------------------------------------

const AtxHeading = struct { text: []const u8, level: u8 };

fn parseAtxHeading(line: []const u8) ?AtxHeading {
    var i: usize = 0;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
    // CommonMark allows up to three spaces of indent.
    if (i > 3) return null;
    var level: u8 = 0;
    while (i < line.len and line[i] == '#' and level < 6) : (i += 1) level += 1;
    if (level == 0) return null;
    if (i < line.len and line[i] != ' ' and line[i] != '\t') return null; // `##no` is not a heading
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
    var text = line[i..];
    // Strip optional trailing `#`s.
    text = std.mem.trimEnd(u8, text, " \t");
    if (text.len > 0) {
        var t = text.len;
        while (t > 0 and text[t - 1] == '#') : (t -= 1) {}
        if (t < text.len and (t == 0 or text[t - 1] == ' ' or text[t - 1] == '\t')) {
            text = std.mem.trimEnd(u8, text[0..t], " \t");
        }
    }
    return .{ .text = text, .level = level };
}

const Fence = struct { char: u8, len: usize };

fn openingFence(line: []const u8) ?Fence {
    var i: usize = 0;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
    if (i > 3 or i >= line.len) return null;
    const char = line[i];
    if (char != '`' and char != '~') return null;
    var len: usize = 0;
    while (i + len < line.len and line[i + len] == char) : (len += 1) {}
    if (len < 3) return null;
    // A backtick fence may not contain backticks in its info string.
    if (char == '`') {
        const info = line[i + len ..];
        if (std.mem.indexOfScalar(u8, info, '`') != null) return null;
    }
    return .{ .char = char, .len = len };
}

fn isClosingFence(line: []const u8, char: u8, min_len: usize) bool {
    var i: usize = 0;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
    if (i > 3) return false;
    var len: usize = 0;
    while (i + len < line.len and line[i + len] == char) : (len += 1) {}
    if (len < min_len) return false;
    const rest = std.mem.trim(u8, line[i + len ..], " \t");
    return rest.len == 0;
}

// -- block classification ----------------------------------------------------------

/// Classify one non-blank, non-heading, non-fence line for the block accumulator.
fn classifyBlockLine(line: []const u8) schema.BlockKind {
    if (isListMarker(line)) return .list;
    if (isBlockquoteMarker(line)) return .blockquote;
    if (isTableRow(line)) return .table;
    return .paragraph;
}

/// `-`/`*`/`+`, or `N.`/`N)`, after at most three leading spaces — CommonMark's own indent
/// budget, same as `openingFence`/`parseAtxHeading` use. The marker must be followed by
/// whitespace or end-of-line so `--horizontal--` isn't mistaken for a list item.
fn isListMarker(line: []const u8) bool {
    var i: usize = 0;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
    if (i > 3 or i >= line.len) return false;

    const c = line[i];
    if (c == '-' or c == '*' or c == '+') {
        return i + 1 >= line.len or line[i + 1] == ' ' or line[i + 1] == '\t';
    }

    var j = i;
    while (j < line.len and std.ascii.isDigit(line[j])) : (j += 1) {}
    if (j == i or j - i > 9) return false; // no digits, or not a plausible ordinal
    if (j >= line.len or (line[j] != '.' and line[j] != ')')) return false;
    return j + 1 >= line.len or line[j + 1] == ' ' or line[j + 1] == '\t';
}

/// `>` after at most three leading spaces.
fn isBlockquoteMarker(line: []const u8) bool {
    var i: usize = 0;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
    if (i > 3 or i >= line.len) return false;
    return line[i] == '>';
}

/// A simple heuristic, not a CommonMark table parser: any unescaped `|` marks the line as a
/// table row. Good enough to keep a GFM table's header/delimiter/body rows together as one
/// block without building real table syntax.
fn isTableRow(line: []const u8) bool {
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        if (line[i] == '\\') {
            i += 1;
            continue;
        }
        if (line[i] == '|') return true;
    }
    return false;
}

/// Whitespace-delimited word count over a block's whole line span (including the newlines
/// joining its lines, which count as separators like any other whitespace).
fn countWords(text: []const u8) u32 {
    var n: u32 = 0;
    var in_word = false;
    for (text) |c| {
        const ws = c == ' ' or c == '\t' or c == '\n' or c == '\r';
        if (ws) {
            in_word = false;
        } else if (!in_word) {
            in_word = true;
            n += 1;
        }
    }
    return n;
}

// -- in-line scan -----------------------------------------------------------------

fn scanLine(
    arena: std.mem.Allocator,
    line: []const u8,
    line_no: u32,
    links: *std.ArrayList(Link),
    tags: *std.ArrayList(Tag),
) !void {
    // Walk the line once, skipping inline code spans, and at each interesting byte either
    // emit a wikilink, a markdown link, or a tag.
    var i: usize = 0;
    while (i < line.len) {
        if (line[i] == '`') {
            i = skipInlineCode(line, i);
            continue;
        }

        // Wikilink / embed. A preceding `\` means the author escaped it — leave it alone.
        if (i + 1 < line.len and line[i] == '[' and line[i + 1] == '[' and !isEscaped(line, i)) {
            var tok_buf: [1]wikilink.Token = undefined;
            const toks = wikilink.tokenize(line[i..], &tok_buf);
            if (toks.len == 1 and toks[0].start == 0) {
                const tok = toks[0];
                // `tokenize` reports spans relative to its input; for embeds it may start at
                // `-1` relative to `[[` when `!` precedes — but we passed a slice starting at
                // `[`, so embed detection needs the byte before `i`.
                const embed = i > 0 and line[i - 1] == '!';
                const col: u32 = @intCast(if (embed) i - 1 else i);
                // `[[foo.zig]]` is not a note — don't invent a phantom for source files.
                if (resolve.isNoteLikeTarget(tok.target)) {
                    const context = try arena.dupe(u8, line);
                    try links.append(arena, .{
                        .raw = try arena.dupe(u8, tok.target),
                        .heading = try arena.dupe(u8, tok.heading),
                        .alias = try arena.dupe(u8, tok.alias),
                        .kind = if (embed or tok.embed) .embed else .wikilink,
                        .line = line_no,
                        .col = col,
                        .context = context,
                    });
                }
                i += tok.end;
                continue;
            }
        }

        // Markdown link: `[text](url)`. Skip image syntax `![…](…)` as a link-to-note —
        // those are media, not vault edges. Wikilink embeds (`![[…]]`) are handled above.
        if (line[i] == '[' and !isEscaped(line, i) and !(i > 0 and line[i - 1] == '!')) {
            if (parseMarkdownLink(line, i)) |md| {
                if (resolve.isNoteLikeTarget(md.url)) {
                    const context = try arena.dupe(u8, line);
                    // `raw` stays exactly as written (the backlinks filter searches it), but the
                    // `#fragment` is also split out into `heading`, the same column a wikilink's
                    // `#anchor` fills. Without that, a link into a section is indistinguishable
                    // from a link to the whole note once it's in the DB — which is what left the
                    // interior view's section-to-section edges wikilink-only.
                    const frag = if (std.mem.indexOfScalar(u8, md.url, '#')) |h| md.url[h + 1 ..] else "";
                    try links.append(arena, .{
                        .raw = try arena.dupe(u8, md.url),
                        .heading = try arena.dupe(u8, frag),
                        .alias = try arena.dupe(u8, md.text),
                        .kind = .markdown,
                        .line = line_no,
                        .col = @intCast(i),
                        .context = context,
                    });
                }
                i = md.end;
                continue;
            }
        }

        // Tag: `#foo` / `#foo/bar`, not an ATX heading and not mid-identifier.
        if (line[i] == '#' and !isEscaped(line, i)) {
            if (parseTag(line, i)) |tag| {
                try tags.append(arena, .{
                    .tag = try arena.dupe(u8, tag.text),
                    .line = line_no,
                });
                i = tag.end;
                continue;
            }
        }

        i += 1;
    }
}

fn isEscaped(line: []const u8, idx: usize) bool {
    // An odd run of backslashes immediately before `idx` escapes it.
    var n: usize = 0;
    var j = idx;
    while (j > 0 and line[j - 1] == '\\') : (j -= 1) n += 1;
    return n % 2 == 1;
}

/// Advance past a CommonMark inline code span starting at `open` (which points at `` ` ``).
/// Returns the index just after the closing fence, or `open+1` when it's unclosed (so the
/// rest of the line is still scanned — better to over-detect a link than to drop a line).
fn skipInlineCode(line: []const u8, open: usize) usize {
    var n: usize = 0;
    while (open + n < line.len and line[open + n] == '`') : (n += 1) {}
    if (n == 0) return open + 1;
    var j = open + n;
    while (j < line.len) {
        if (line[j] != '`') {
            j += 1;
            continue;
        }
        var m: usize = 0;
        while (j + m < line.len and line[j + m] == '`') : (m += 1) {}
        if (m == n) return j + m;
        j += m;
    }
    return open + n; // unclosed: skip the opening backticks and keep going
}

const MdLink = struct { text: []const u8, url: []const u8, end: usize };

fn parseMarkdownLink(line: []const u8, open: usize) ?MdLink {
    // `[text](url)` with no nesting in `text` for the common case. A `]` inside the text
    // ends it; that's what CommonMark's link-text rules collapse to for the simple paths
    // we care about (vault-relative note links).
    if (open >= line.len or line[open] != '[') return null;
    const close_text = std.mem.indexOfScalarPos(u8, line, open + 1, ']') orelse return null;
    if (close_text + 1 >= line.len or line[close_text + 1] != '(') return null;
    const url_start = close_text + 2;
    const close_url = std.mem.indexOfScalarPos(u8, line, url_start, ')') orelse return null;
    const text = line[open + 1 .. close_text];
    var url = std.mem.trim(u8, line[url_start..close_url], " \t");
    // Angle-bracket form: `(<path with spaces.md>)`.
    if (url.len >= 2 and url[0] == '<' and url[url.len - 1] == '>') url = url[1 .. url.len - 1];
    // Destination may carry a title after whitespace: `(path "title")` — keep the path.
    if (std.mem.indexOfAny(u8, url, " \t")) |sp| url = url[0..sp];
    if (url.len == 0) return null;
    return .{ .text = text, .url = url, .end = close_url + 1 };
}

const ParsedTag = struct { text: []const u8, end: usize };

fn parseTag(line: []const u8, hash: usize) ?ParsedTag {
    // Must not be mid-word (`foo#bar`) and must not be an ATX heading (`# heading` / `##`).
    if (hash > 0) {
        const prev = line[hash - 1];
        if (std.ascii.isAlphanumeric(prev) or prev == '_' or prev == '-') return null;
    }
    var i = hash + 1;
    if (i >= line.len) return null;
    // A second `#` is a heading, not a tag. A space means ATX too.
    if (line[i] == '#' or line[i] == ' ' or line[i] == '\t') return null;

    while (i < line.len) : (i += 1) {
        const c = line[i];
        const ok = std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '/';
        if (!ok) break;
    }
    const text = line[hash + 1 .. i];
    if (text.len == 0) return null;
    // Trailing slash is noise, not a tag character that means something.
    if (text[text.len - 1] == '/') return null;
    return .{ .text = text, .end = i };
}

// -- tiny helpers -----------------------------------------------------------------

fn isBlank(s: []const u8) bool {
    return std.mem.trim(u8, s, " \t\r").len == 0;
}

fn trimRight(s: []const u8) []const u8 {
    return std.mem.trimEnd(u8, s, " \t\r");
}

// -- wikilink → markdown link conversion -------------------------------------------

/// Rewrite every *resolvable* `[[wikilink]]` in `bytes` as a `[label](path)` markdown link.
/// Returns null when nothing changed, so callers can skip a no-op edit.
///
/// Deliberately lives beside `scanLine` and reuses its helpers (`openingFence`,
/// `isClosingFence`, `skipInlineCode`, `isEscaped`, and the same SDK tokenizer). A converter
/// that decided for itself what counts as a link would eventually rewrite text the indexer
/// ignores — inside a fence, inside a code span, or escaped — which is the renderer/indexer
/// drift the SDK tokenizer exists to prevent, one layer up.
///
/// Left alone on purpose:
///   * links that don't resolve — those are the phantoms you click to create the note, and a
///     path to a file that doesn't exist yet is worse than the wikilink.
///   * non-note targets (`[[foo.zig]]`) — the index has no record of them, same rule the
///     indexer applies.
///
/// Embeds (`![[diagram.png]]`) resolve against `media` instead and become `![alt](path)`, so
/// an embed keeps rendering as an image rather than turning into a link to one.
pub fn convertWikilinks(
    arena: std.mem.Allocator,
    bytes: []const u8,
    src_rel: []const u8,
    candidates: []const resolve.Candidate,
    /// Lookup tables over `candidates`; null falls back to scanning them. A document being
    /// converted has as many links as it has, and each one would otherwise be a pass over the
    /// whole vault — on a save, on the UI thread.
    index: ?*const resolve.Index,
    media: []const resolve.Candidate,
) !?[]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(arena);
    var changed = false;

    var body_start: usize = 0;
    if (parseFrontMatter(bytes)) |fm| body_start = fm.body_start;
    try out.appendSlice(arena, bytes[0..body_start]);

    var in_fence = false;
    var fence_char: u8 = 0;
    var fence_len: usize = 0;

    var pos = body_start;
    while (pos <= bytes.len) {
        const line_end = std.mem.indexOfScalarPos(u8, bytes, pos, '\n') orelse bytes.len;
        const line = bytes[pos..line_end];
        const content = if (line.len > 0 and line[line.len - 1] == '\r') line[0 .. line.len - 1] else line;

        if (in_fence) {
            if (isClosingFence(content, fence_char, fence_len)) in_fence = false;
            try out.appendSlice(arena, line);
        } else if (openingFence(content)) |f| {
            in_fence = true;
            fence_char = f.char;
            fence_len = f.len;
            try out.appendSlice(arena, line);
        } else if (try convertLine(arena, &out, content, src_rel, candidates, index, media)) {
            changed = true;
            // `content` dropped a trailing `\r`; put it back so line endings survive.
            if (content.len != line.len) try out.appendSlice(arena, line[content.len..]);
        } else {
            try out.appendSlice(arena, line);
        }

        if (line_end == bytes.len) break;
        try out.append(arena, '\n');
        pos = line_end + 1;
    }

    if (!changed) {
        out.deinit(arena);
        return null;
    }
    return try out.toOwnedSlice(arena);
}

/// Appends `line` to `out`, converting resolvable wikilinks. Returns true if anything changed
/// (when false, nothing was appended and the caller writes the original line).
fn convertLine(
    arena: std.mem.Allocator,
    out: *std.ArrayList(u8),
    line: []const u8,
    src_rel: []const u8,
    candidates: []const resolve.Candidate,
    index: ?*const resolve.Index,
    media: []const resolve.Candidate,
) !bool {
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(arena);
    var buf: [resolve.max_path_len]u8 = undefined;
    var changed = false;

    var i: usize = 0;
    while (i < line.len) {
        if (line[i] == '`') {
            const end = skipInlineCode(line, i);
            try scratch.appendSlice(arena, line[i..end]);
            i = end;
            continue;
        }

        if (i + 1 < line.len and line[i] == '[' and line[i + 1] == '[' and !isEscaped(line, i)) {
            var tok_buf: [1]wikilink.Token = undefined;
            const toks = wikilink.tokenize(line[i..], &tok_buf);
            if (toks.len == 1 and toks[0].start == 0) {
                const tok = toks[0];
                const embed = tok.embed or (i > 0 and line[i - 1] == '!');
                if (embed) {
                    // The `!` sits before the slice we tokenized, so it is already in `scratch`
                    // (or is `tok.embed`'s own leading byte). Emit only the `[...](...)` part.
                    // Media stays a linear scan: `index` covers notes, and there are few
                    // enough attachments that building a second one would not pay for itself.
                    if (resolve.resolve(tok.target, src_rel, media, &buf)) |m| {
                        const label = if (tok.alias.len > 0) tok.alias else tok.target;
                        try writeMarkdownLink(arena, &scratch, label, media[m.index].path, src_rel, "");
                        i += tok.end;
                        changed = true;
                        continue;
                    }
                } else if (resolve.isNoteLikeTarget(tok.target)) {
                    if (resolve.resolveIndexed(tok.target, src_rel, candidates, index, &buf)) |m| {
                        const label = if (tok.alias.len > 0) tok.alias else tok.target;
                        try writeMarkdownLink(arena, &scratch, label, candidates[m.index].path, src_rel, tok.heading);
                        i += tok.end;
                        changed = true;
                        continue;
                    }
                }
                // Unresolved, or not note-like — copy it through untouched.
                try scratch.appendSlice(arena, line[i .. i + tok.end]);
                i += tok.end;
                continue;
            }
        }

        try scratch.append(arena, line[i]);
        i += 1;
    }

    if (!changed) return false;
    try out.appendSlice(arena, scratch.items);
    return true;
}

/// `[label](target)`, where target is `dst_rel` made relative to the directory holding
/// `src_rel`. CommonMark's `<...>` form is used when the path holds characters that would
/// otherwise end the destination early, which is cheaper to read than percent-encoding.
fn writeMarkdownLink(
    arena: std.mem.Allocator,
    out: *std.ArrayList(u8),
    label: []const u8,
    dst_rel: []const u8,
    src_rel: []const u8,
    heading: []const u8,
) !void {
    try out.append(arena, '[');
    try out.appendSlice(arena, label);
    try out.appendSlice(arena, "](");

    var target: std.ArrayList(u8) = .empty;
    defer target.deinit(arena);
    try appendRelativePath(arena, &target, src_rel, dst_rel);
    if (heading.len > 0) {
        try target.append(arena, '#');
        try target.appendSlice(arena, heading);
    }

    const needs_angle = std.mem.indexOfAny(u8, target.items, " ()<>") != null;
    if (needs_angle) try out.append(arena, '<');
    try out.appendSlice(arena, target.items);
    if (needs_angle) try out.append(arena, '>');
    try out.append(arena, ')');
}

/// Path from `src_rel`'s directory to `dst_rel`, both vault-relative and `/`-separated.
/// A link is written relative to the file holding it, so a note in a subfolder gets `../`
/// rather than a vault-root path that only works from the root.
fn appendRelativePath(
    arena: std.mem.Allocator,
    out: *std.ArrayList(u8),
    src_rel: []const u8,
    dst_rel: []const u8,
) !void {
    const src_dir = if (std.mem.lastIndexOfScalar(u8, src_rel, '/')) |s| src_rel[0..s] else "";
    const dst_dir = if (std.mem.lastIndexOfScalar(u8, dst_rel, '/')) |s| dst_rel[0..s] else "";
    const dst_name = if (std.mem.lastIndexOfScalar(u8, dst_rel, '/')) |s| dst_rel[s + 1 ..] else dst_rel;

    // Longest shared directory prefix, counted in whole segments.
    var shared: usize = 0;
    var src_it = std.mem.splitScalar(u8, src_dir, '/');
    var dst_it = std.mem.splitScalar(u8, dst_dir, '/');
    while (true) {
        const a = src_it.next();
        const b = dst_it.next();
        if (a == null or b == null) break;
        if (a.?.len == 0 or b.?.len == 0) break;
        if (!std.mem.eql(u8, a.?, b.?)) break;
        shared += 1;
    }

    const up = segmentCount(src_dir) - shared;
    var n: usize = 0;
    while (n < up) : (n += 1) try out.appendSlice(arena, "../");

    var rest = dst_dir;
    var skip = shared;
    while (skip > 0) : (skip -= 1) {
        const s = std.mem.indexOfScalar(u8, rest, '/') orelse {
            rest = "";
            break;
        };
        rest = rest[s + 1 ..];
    }
    if (rest.len > 0) {
        try out.appendSlice(arena, rest);
        try out.append(arena, '/');
    }
    try out.appendSlice(arena, dst_name);
}

fn segmentCount(dir: []const u8) usize {
    if (dir.len == 0) return 0;
    var n: usize = 1;
    for (dir) |c| {
        if (c == '/') n += 1;
    }
    return n;
}

// -- tests ------------------------------------------------------------------------

const testing = std.testing;

fn withScan(bytes: []const u8, comptime body: fn (Note) anyerror!void) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const note = try scan(arena.allocator(), bytes);
    try body(note);
}

test "a plain note with one wikilink" {
    try withScan("See [[Setup]] for details.\n", struct {
        fn body(note: Note) !void {
            try testing.expectEqual(@as(usize, 1), note.links.len);
            try testing.expectEqualStrings("Setup", note.links[0].raw);
            try testing.expect(note.links[0].kind == .wikilink);
            try testing.expectEqual(@as(u32, 0), note.links[0].line);
            try testing.expectEqual(@as(u32, 4), note.links[0].col);
            try testing.expectEqualStrings("See [[Setup]] for details.", note.links[0].context);
        }
    }.body);
}

test "wikilink with alias and heading" {
    try withScan("[[Note#Heading|Label]]\n", struct {
        fn body(note: Note) !void {
            try testing.expectEqual(@as(usize, 1), note.links.len);
            try testing.expectEqualStrings("Note", note.links[0].raw);
            try testing.expectEqualStrings("Heading", note.links[0].heading);
            try testing.expectEqualStrings("Label", note.links[0].alias);
        }
    }.body);
}

test "embed is recorded as embed kind" {
    try withScan("Intro ![[Diagram]] out\n", struct {
        fn body(note: Note) !void {
            try testing.expectEqual(@as(usize, 1), note.links.len);
            try testing.expect(note.links[0].kind == .embed);
            try testing.expectEqualStrings("Diagram", note.links[0].raw);
            try testing.expectEqual(@as(u32, 6), note.links[0].col);
        }
    }.body);
}

test "fenced code suppresses wikilinks" {
    const src =
        \\Before [[Keep]]
        \\```
        \\[[Ignore]]
        \\```
        \\After [[Also]]
        \\
    ;
    try withScan(src, struct {
        fn body(note: Note) !void {
            try testing.expectEqual(@as(usize, 2), note.links.len);
            try testing.expectEqualStrings("Keep", note.links[0].raw);
            try testing.expectEqualStrings("Also", note.links[1].raw);
        }
    }.body);
}

test "tilde fences work too" {
    const src =
        \\~~~zig
        \\[[Ignore]]
        \\~~~
        \\[[Keep]]
        \\
    ;
    try withScan(src, struct {
        fn body(note: Note) !void {
            try testing.expectEqual(@as(usize, 1), note.links.len);
            try testing.expectEqualStrings("Keep", note.links[0].raw);
        }
    }.body);
}

test "inline code suppresses wikilinks" {
    try withScan("Use `[[Nope]]` but [[Yep]] works.\n", struct {
        fn body(note: Note) !void {
            try testing.expectEqual(@as(usize, 1), note.links.len);
            try testing.expectEqualStrings("Yep", note.links[0].raw);
        }
    }.body);
}

test "escaped wikilink is not a link" {
    try withScan("Not a link: \\[[Nope]] but [[Yep]] is.\n", struct {
        fn body(note: Note) !void {
            try testing.expectEqual(@as(usize, 1), note.links.len);
            try testing.expectEqualStrings("Yep", note.links[0].raw);
        }
    }.body);
}

test "ATX headings are collected with levels and lines" {
    const src =
        \\# Title
        \\
        \\## Section
        \\### Deep
        \\
    ;
    try withScan(src, struct {
        fn body(note: Note) !void {
            try testing.expectEqual(@as(usize, 3), note.headings.len);
            try testing.expectEqualStrings("Title", note.headings[0].text);
            try testing.expectEqual(@as(u8, 1), note.headings[0].level);
            try testing.expectEqual(@as(u32, 0), note.headings[0].line);
            try testing.expectEqualStrings("Section", note.headings[1].text);
            try testing.expectEqual(@as(u8, 2), note.headings[1].level);
            try testing.expectEqual(@as(u32, 2), note.headings[1].line);
            try testing.expectEqualStrings("Deep", note.headings[2].text);
        }
    }.body);
}

test "front matter supplies title and aliases" {
    const src =
        \\---
        \\title: Getting Started
        \\aliases: [Setup, Intro]
        \\tags: [ignored]
        \\---
        \\Body with [[Setup]]
        \\
    ;
    try withScan(src, struct {
        fn body(note: Note) !void {
            try testing.expectEqualStrings("Getting Started", note.title);
            try testing.expectEqual(@as(usize, 2), note.aliases.len);
            try testing.expectEqualStrings("Setup", note.aliases[0]);
            try testing.expectEqualStrings("Intro", note.aliases[1]);
            try testing.expectEqual(@as(usize, 1), note.links.len);
            // Body starts after the closing `---`, so the link isn't on line 0.
            try testing.expect(note.links[0].line > 0);
        }
    }.body);
}

test "front matter list-style aliases" {
    const src =
        \\---
        \\aliases:
        \\  - One
        \\  - Two
        \\---
        \\
    ;
    try withScan(src, struct {
        fn body(note: Note) !void {
            try testing.expectEqual(@as(usize, 2), note.aliases.len);
            try testing.expectEqualStrings("One", note.aliases[0]);
            try testing.expectEqualStrings("Two", note.aliases[1]);
        }
    }.body);
}

test "unclosed front matter is ignored" {
    const src =
        \\---
        \\title: Nope
        \\still going
        \\
    ;
    try withScan(src, struct {
        fn body(note: Note) !void {
            try testing.expectEqualStrings("", note.title);
        }
    }.body);
}

test "local markdown links are recorded; http links are not" {
    const src =
        \\[local](./Notes/A.md) and [web](https://example.com) and [also](B.md)
        \\
    ;
    try withScan(src, struct {
        fn body(note: Note) !void {
            try testing.expectEqual(@as(usize, 2), note.links.len);
            try testing.expect(note.links[0].kind == .markdown);
            try testing.expectEqualStrings("./Notes/A.md", note.links[0].raw);
            try testing.expectEqualStrings("local", note.links[0].alias);
            try testing.expectEqualStrings("B.md", note.links[1].raw);
        }
    }.body);
}

test "a markdown link's fragment is recorded as its heading" {
    const src =
        \\[Daphne > Habitat and Range](Daphne.md#habitat-and-range) and [plain](B.md)
        \\
    ;
    try withScan(src, struct {
        fn body(note: Note) !void {
            try testing.expectEqual(@as(usize, 2), note.links.len);
            // `raw` is still the destination exactly as written — the fragment is *also* split out.
            try testing.expectEqualStrings("Daphne.md#habitat-and-range", note.links[0].raw);
            try testing.expectEqualStrings("habitat-and-range", note.links[0].heading);
            try testing.expectEqualStrings("", note.links[1].heading);
        }
    }.body);
}

test "non-note file links are not recorded as edges" {
    const src =
        \\[code](src/foo.zig) and [[bar.zig]] and [note](Idea) and [img](pic.png)
        \\
    ;
    try withScan(src, struct {
        fn body(note: Note) !void {
            try testing.expectEqual(@as(usize, 1), note.links.len);
            try testing.expectEqualStrings("Idea", note.links[0].raw);
        }
    }.body);
}

test "tags are collected; headings are not tags" {
    const src =
        \\# Heading
        \\A #tag and #nested/tag here.
        \\
    ;
    try withScan(src, struct {
        fn body(note: Note) !void {
            try testing.expectEqual(@as(usize, 1), note.headings.len);
            try testing.expectEqual(@as(usize, 2), note.tags.len);
            try testing.expectEqualStrings("tag", note.tags[0].tag);
            try testing.expectEqualStrings("nested/tag", note.tags[1].tag);
        }
    }.body);
}

test "mid-word hash is not a tag" {
    try withScan("issue#123 is not a tag\n", struct {
        fn body(note: Note) !void {
            try testing.expectEqual(@as(usize, 0), note.tags.len);
        }
    }.body);
}

test "line numbers account for front matter" {
    const src =
        \\---
        \\title: X
        \\---
        \\first
        \\[[Link]]
        \\
    ;
    try withScan(src, struct {
        fn body(note: Note) !void {
            try testing.expectEqual(@as(usize, 1), note.links.len);
            // lines: 0=`---`, 1=`title`, 2=`---`, 3=`first`, 4=`[[Link]]`
            try testing.expectEqual(@as(u32, 4), note.links[0].line);
        }
    }.body);
}

test "empty note is fine" {
    try withScan("", struct {
        fn body(note: Note) !void {
            try testing.expectEqual(@as(usize, 0), note.links.len);
            try testing.expectEqual(@as(usize, 0), note.headings.len);
            try testing.expectEqualStrings("", note.title);
        }
    }.body);
}

// -- block tests --------------------------------------------------------------------

test "a paragraph, a list, a fenced code block, and a blockquote each become their own block" {
    const src =
        \\Some words here.
        \\
        \\- one
        \\- two
        \\
        \\```zig
        \\const x = 1;
        \\```
        \\
        \\> quoted text
        \\
    ;
    try withScan(src, struct {
        fn body(note: Note) !void {
            try testing.expectEqual(@as(usize, 4), note.blocks.len);

            try testing.expect(note.blocks[0].kind == .paragraph);
            try testing.expectEqual(@as(u32, 0), note.blocks[0].line_start);
            try testing.expectEqual(@as(u32, 0), note.blocks[0].line_end);
            try testing.expectEqual(@as(u32, 3), note.blocks[0].weight); // "Some words here."

            try testing.expect(note.blocks[1].kind == .list);
            try testing.expectEqual(@as(u32, 2), note.blocks[1].line_start);
            try testing.expectEqual(@as(u32, 3), note.blocks[1].line_end);
            try testing.expectEqual(@as(u32, 4), note.blocks[1].weight); // "- one" "- two"

            try testing.expect(note.blocks[2].kind == .code);
            try testing.expectEqual(@as(u32, 5), note.blocks[2].line_start); // the ``` line
            try testing.expectEqual(@as(u32, 7), note.blocks[2].line_end); // the closing ```
            try testing.expectEqual(@as(u32, 3), note.blocks[2].weight); // 3 lines

            try testing.expect(note.blocks[3].kind == .blockquote);
            try testing.expectEqual(@as(u32, 9), note.blocks[3].line_start);
            try testing.expectEqual(@as(u32, 9), note.blocks[3].line_end);
        }
    }.body);
}

test "a table is one block via the pipe heuristic" {
    const src =
        \\| A | B |
        \\|---|---|
        \\| 1 | 2 |
        \\
    ;
    try withScan(src, struct {
        fn body(note: Note) !void {
            try testing.expectEqual(@as(usize, 1), note.blocks.len);
            try testing.expect(note.blocks[0].kind == .table);
            try testing.expectEqual(@as(u32, 0), note.blocks[0].line_start);
            try testing.expectEqual(@as(u32, 2), note.blocks[0].line_end);
        }
    }.body);
}

test "a heading directly followed by a paragraph still splits, no blank line needed" {
    const src =
        \\# Title
        \\First paragraph right under the heading.
        \\
        \\## Section
        \\Second paragraph.
        \\
    ;
    try withScan(src, struct {
        fn body(note: Note) !void {
            try testing.expectEqual(@as(usize, 2), note.headings.len);
            try testing.expectEqual(@as(usize, 2), note.blocks.len);
            try testing.expect(note.blocks[0].kind == .paragraph);
            try testing.expectEqual(@as(u32, 1), note.blocks[0].line_start);
            try testing.expectEqual(@as(u32, 1), note.blocks[0].line_end);
            try testing.expect(note.blocks[1].kind == .paragraph);
            try testing.expectEqual(@as(u32, 4), note.blocks[1].line_start);
        }
    }.body);
}

test "consecutive list items without a blank line stay one block; a new paragraph after them splits" {
    const src =
        \\- a
        \\- b
        \\- c
        \\Not a list line, so this starts a new paragraph block.
        \\
    ;
    try withScan(src, struct {
        fn body(note: Note) !void {
            try testing.expectEqual(@as(usize, 2), note.blocks.len);
            try testing.expect(note.blocks[0].kind == .list);
            try testing.expectEqual(@as(u32, 0), note.blocks[0].line_start);
            try testing.expectEqual(@as(u32, 2), note.blocks[0].line_end);
            try testing.expect(note.blocks[1].kind == .paragraph);
            try testing.expectEqual(@as(u32, 3), note.blocks[1].line_start);
        }
    }.body);
}

test "multiple paragraphs separated by blank lines are separate blocks" {
    const src =
        \\First paragraph.
        \\Still first paragraph.
        \\
        \\Second paragraph.
        \\
        \\Third paragraph.
        \\
    ;
    try withScan(src, struct {
        fn body(note: Note) !void {
            try testing.expectEqual(@as(usize, 3), note.blocks.len);
            for (note.blocks) |b| try testing.expect(b.kind == .paragraph);
            try testing.expectEqual(@as(u32, 0), note.blocks[0].line_start);
            try testing.expectEqual(@as(u32, 1), note.blocks[0].line_end);
            try testing.expectEqual(@as(u32, 3), note.blocks[1].line_start);
            try testing.expectEqual(@as(u32, 5), note.blocks[2].line_start);
        }
    }.body);
}

test "an unclosed fence still yields one code block through EOF" {
    const src =
        \\```
        \\line one
        \\line two
    ;
    try withScan(src, struct {
        fn body(note: Note) !void {
            try testing.expectEqual(@as(usize, 1), note.blocks.len);
            try testing.expect(note.blocks[0].kind == .code);
            try testing.expectEqual(@as(u32, 0), note.blocks[0].line_start);
            try testing.expectEqual(@as(u32, 2), note.blocks[0].line_end);
        }
    }.body);
}

// -- conversion tests ---------------------------------------------------------------

const conv_candidates = [_]resolve.Candidate{
    .{ .path = "Notes/Target.md", .stem = "Target" },
    .{ .path = "Other.md", .stem = "Other" },
    .{ .path = "Notes/Sub/Deep.md", .stem = "Deep" },
};

// Two spellings per file, matching what `query.loadMediaCandidates` emits.
const conv_media = [_]resolve.Candidate{
    .{ .path = "assets/diagram.png", .stem = "diagram" },
    .{ .path = "assets/diagram.png", .stem = "diagram.png" },
    .{ .path = "shot.jpg", .stem = "shot" },
    .{ .path = "shot.jpg", .stem = "shot.jpg" },
};

fn convert(src: []const u8, src_rel: []const u8) !?[]const u8 {
    return convertWikilinks(testing.allocator, src, src_rel, &conv_candidates, null, &conv_media);
}

fn expectConverted(src: []const u8, src_rel: []const u8, want: []const u8) !void {
    const got = (try convert(src, src_rel)) orelse return error.ExpectedChange;
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(want, got);
}

fn expectUnchanged(src: []const u8, src_rel: []const u8) !void {
    if (try convert(src, src_rel)) |got| {
        defer testing.allocator.free(got);
        std.debug.print("expected no change, got:\n{s}\n", .{got});
        return error.UnexpectedChange;
    }
}

test "resolvable wikilink becomes a markdown link" {
    try expectConverted("see [[Target]] here\n", "Notes/A.md", "see [Target](Target.md) here\n");
}

test "alias becomes the link label" {
    try expectConverted("[[Target|the thing]]\n", "Notes/A.md", "[the thing](Target.md)\n");
}

test "heading is carried into the fragment" {
    try expectConverted("[[Target#Usage]]\n", "Notes/A.md", "[Target](Target.md#Usage)\n");
}

test "path is relative to the linking file, not the vault root" {
    // From the vault root, into a subfolder.
    try expectConverted("[[Target]]\n", "A.md", "[Target](Notes/Target.md)\n");
    // From a subfolder, back out to the root.
    try expectConverted("[[Other]]\n", "Notes/A.md", "[Other](../Other.md)\n");
    // Across sibling subfolders.
    try expectConverted("[[Deep]]\n", "Notes/A.md", "[Deep](Sub/Deep.md)\n");
    try expectConverted("[[Other]]\n", "Notes/Sub/A.md", "[Other](../../Other.md)\n");
}

test "unresolved links are left alone so the phantom flow still works" {
    try expectUnchanged("[[NotYetCreated]]\n", "Notes/A.md");
}

test "an embed resolves against media and stays an image" {
    try expectConverted("![[diagram.png]]\n", "Notes/A.md", "![diagram.png](../assets/diagram.png)\n");
    try expectConverted("![[shot.jpg]]\n", "Notes/A.md", "![shot.jpg](../shot.jpg)\n");
}

test "an embed resolves with or without the extension" {
    try expectConverted("![[diagram]]\n", "Notes/A.md", "![diagram](../assets/diagram.png)\n");
}

test "an embed alias becomes the alt text" {
    try expectConverted("![[diagram.png|a diagram]]\n", "Notes/A.md", "![a diagram](../assets/diagram.png)\n");
}

test "an embed of a note is left alone" {
    // `Target` is a note, not media — there is no image to point at, and `![x](x.md)` would
    // render as a broken image.
    try expectUnchanged("![[Target]]\n", "Notes/A.md");
}

test "an embed of unknown media is left alone" {
    try expectUnchanged("![[nope.png]]\n", "Notes/A.md");
}

test "a plain wikilink never resolves to media" {
    // `[[Target]]` must find the note; media is only ever reachable through an embed.
    try expectUnchanged("[[diagram.png]]\n", "Notes/A.md");
}

test "non-note targets are not converted" {
    try expectUnchanged("[[bar.zig]]\n", "Notes/A.md");
}

test "escaped wikilinks are left alone" {
    try expectUnchanged("\\[\\[Target]]\n", "Notes/A.md");
}

test "wikilinks inside inline code are left alone" {
    try expectUnchanged("use `[[Target]]` to link\n", "Notes/A.md");
}

test "wikilinks inside a fenced block are left alone" {
    const src =
        \\```
        \\[[Target]]
        \\```
        \\
    ;
    try expectUnchanged(src, "Notes/A.md");
}

test "conversion resumes after a fence closes" {
    const src =
        \\```
        \\[[Target]]
        \\```
        \\[[Target]]
        \\
    ;
    const want =
        \\```
        \\[[Target]]
        \\```
        \\[Target](Target.md)
        \\
    ;
    try expectConverted(src, "Notes/A.md", want);
}

test "front matter is preserved verbatim" {
    const src =
        \\---
        \\title: A
        \\---
        \\[[Target]]
        \\
    ;
    const want =
        \\---
        \\title: A
        \\---
        \\[Target](Target.md)
        \\
    ;
    try expectConverted(src, "Notes/A.md", want);
}

test "a document with nothing to convert reports no change" {
    try expectUnchanged("just prose and [a link](Other.md)\n", "Notes/A.md");
}

test "several links on one line all convert" {
    try expectConverted(
        "[[Target]] and [[Other]]\n",
        "Notes/A.md",
        "[Target](Target.md) and [Other](../Other.md)\n",
    );
}

test "converted output is stable under a second pass" {
    const once = (try convert("[[Target]] and [[Other]]\n", "Notes/A.md")).?;
    defer testing.allocator.free(once);
    try expectUnchanged(once, "Notes/A.md");
}

test "CRLF line endings survive conversion" {
    const got = (try convert("[[Target]]\r\nx\r\n", "Notes/A.md")).?;
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("[Target](Target.md)\r\nx\r\n", got);
}
