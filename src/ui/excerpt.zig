//! Turning a line of markdown source into a short label.
//!
//! The interior view draws one node per item in a note's content graph, and body blocks —
//! paragraphs, lists, code, blockquotes, tables — have no text in the index: `blocks` stores a
//! kind, a line span and a weight, never the prose. The label therefore comes from the file, and
//! this is the part that decides *which* line and *how much of it* to show.
//!
//! Pure: no `dvui`, no `Db`. `blockExcerpt` and `clip` allocate nothing and return slices into
//! their input; `plain` is the one exception — turning `[Moi](Glossary/Moi.md)` into `Moi` means
//! rewriting the middle of a line, which no subslice can express.

const std = @import("std");

/// First line of real content at or just after `line`, with its markdown decoration stripped, or
/// null if there is nothing worth showing.
///
/// Looks a few lines ahead rather than only at `line`. A block's recorded `line_start` is usually
/// the content itself, but a fenced code block starts on its ``` fence and a block can carry a
/// blank line at the top of its own span. The lookahead is bounded so a search never runs on into
/// the next block and labels it with someone else's text.
pub fn blockExcerpt(lines: []const []const u8, line: u32) ?[]const u8 {
    const start: usize = line;
    if (start >= lines.len) return null;
    const end = @min(start + lookahead, lines.len);

    for (lines[start..end]) |raw| {
        var s = std.mem.trim(u8, raw, " \t\r");
        if (s.len == 0) continue;

        // A fence: prefer its info string ("```zig" → "zig"), else keep looking for the first real
        // line of the body.
        if (std.mem.startsWith(u8, s, "```") or std.mem.startsWith(u8, s, "~~~")) {
            const info = std.mem.trim(u8, s[3..], " \t\r`~");
            if (info.len > 0) return info;
            continue;
        }

        s = stripDecoration(s);

        // A table's separator row (`|---|---|`) says nothing about the table.
        if (s.len == 0 or std.mem.indexOfNone(u8, s, "-:| \t") == null) continue;
        return s;
    }
    return null;
}

/// How many lines past a block's start to look for content. Four covers a fence plus a blank line
/// plus a line of body; more risks reaching into the next block.
const lookahead: usize = 4;

/// Strip leading markdown decoration: blockquote markers and table pipes (repeatedly, since they
/// nest), then one list bullet or ordinal, then that item's task checkbox if it has one.
fn stripDecoration(text: []const u8) []const u8 {
    var s = text;
    while (s.len > 0 and (s[0] == '>' or s[0] == '|')) {
        s = std.mem.trimStart(u8, s[1..], " \t");
    }
    const bullet = stripBullet(s);
    // A checkbox is only a checkbox inside a list item — CommonMark has no task paragraphs. So a
    // line of prose that happens to open with `[x]` keeps it, and `- [x] test` becomes `test`.
    if (bullet.len == s.len) return s;
    return stripTaskMarker(bullet);
}

/// One list bullet or ordinal, or `text` unchanged when there is neither.
fn stripBullet(text: []const u8) []const u8 {
    if (text.len > 1 and (text[0] == '-' or text[0] == '*' or text[0] == '+') and text[1] == ' ') {
        return std.mem.trimStart(u8, text[2..], " \t");
    }
    // `1. `, `12. ` — only when everything before the dot is a digit, so "e.g. foo" is left alone.
    if (std.mem.indexOfScalar(u8, text, '.')) |dot| {
        if (dot > 0 and dot < 4 and dot + 1 < text.len and text[dot + 1] == ' ') {
            const all_digits = for (text[0..dot]) |c| {
                if (!std.ascii.isDigit(c)) break false;
            } else true;
            if (all_digits) return std.mem.trimStart(u8, text[dot + 2 ..], " \t");
        }
    }
    return text;
}

/// `[ ] `, `[x] `, `[X] ` at the front of a list item. The state is dropped along with the
/// brackets: a one-line caption has no room to spend on it, and the node is captioned by what
/// the item *says*.
fn stripTaskMarker(text: []const u8) []const u8 {
    if (text.len < 3 or text[0] != '[' or text[2] != ']') return text;
    if (text[1] != ' ' and text[1] != 'x' and text[1] != 'X') return text;
    return std.mem.trimStart(u8, text[3..], " \t");
}

/// Inline markdown, reduced to the text a reader actually sees: `[Moi](Glossary/Moi.md)` → `Moi`,
/// `**real**` → `real`, `` `code` `` → `code`.
///
/// A label is a *reading* of the line, not a quotation of it — a graph node captioned
/// `[Moi](Glossary/Moi.md) and I were lead to` spends most of its width on a path the reader can
/// already see in the editor. `blockExcerpt` strips the decoration at the *start* of a line; this
/// strips what is embedded in it, and headings need it too (`### The **real** truth`).
///
/// Returns `text` itself, unallocated, when there is no markup to remove — the common case — and
/// on allocation failure, since a label with syntax in it beats no label at all.
///
/// Run this *before* `clip`: the budget should be spent on visible characters, not on a URL that
/// is about to be thrown away.
pub fn plain(arena: std.mem.Allocator, text: []const u8) []const u8 {
    if (std.mem.indexOfAny(u8, text, "[!*_`~\\") == null) return text;
    var out: std.ArrayList(u8) = .empty;
    out.ensureTotalCapacity(arena, text.len) catch return text;
    appendPlain(arena, &out, text) catch return text;
    return out.items;
}

/// `plain`'s body. Recursive only through a link's own label (`[**bold**](x)`), so depth is
/// bounded by how deeply a line nests brackets — single digits in any real document.
fn appendPlain(arena: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    var i: usize = 0;
    while (i < text.len) {
        switch (text[i]) {
            // An escaped marker is a literal: `\*not emphasis\*`.
            '\\' => {
                if (i + 1 < text.len and isMarkdownPunct(text[i + 1])) {
                    try out.append(arena, text[i + 1]);
                    i += 2;
                } else {
                    try out.append(arena, text[i]);
                    i += 1;
                }
            },
            // Code span: whatever run of backticks opened it, the same run closes it.
            '`' => {
                const ticks = runLength(text, i, '`');
                const body = i + ticks;
                if (std.mem.indexOfPos(u8, text, body, text[i..body])) |close| {
                    try out.appendSlice(arena, text[body..close]);
                    i = close + ticks;
                } else {
                    try out.append(arena, text[i]);
                    i += 1;
                }
            },
            // `![alt](url)` — the alt text is the only part with anything to say.
            '!' => {
                if (i + 1 < text.len and text[i + 1] == '[') {
                    if (parseLink(text, i + 1)) |link| {
                        try appendPlain(arena, out, link.label);
                        i = link.end;
                        continue;
                    }
                }
                try out.append(arena, text[i]);
                i += 1;
            },
            '[' => {
                if (parseWikilink(text, i)) |wl| {
                    try out.appendSlice(arena, wl.label);
                    i = wl.end;
                    continue;
                }
                if (parseLink(text, i)) |link| {
                    try appendPlain(arena, out, link.label);
                    i = link.end;
                    continue;
                }
                try out.append(arena, text[i]);
                i += 1;
            },
            '*' => i += runLength(text, i, '*'),
            // `~~strike~~` only. A single `~` is a literal — it is punctuation far more often
            // than it is markup.
            '~' => {
                const run = runLength(text, i, '~');
                if (run >= 2) {
                    i += run;
                } else {
                    try out.append(arena, text[i]);
                    i += 1;
                }
            },
            // `_` is emphasis only at a word edge, so `snake_case_names` survives intact — the
            // same left/right-flanking rule CommonMark uses, in its short form.
            '_' => {
                const run = runLength(text, i, '_');
                const opens = i == 0 or isSpaceOrPunct(text[i - 1]);
                const closes = i + run >= text.len or isSpaceOrPunct(text[i + run]);
                if (opens or closes) {
                    i += run;
                } else {
                    try out.appendSlice(arena, text[i .. i + run]);
                    i += run;
                }
            },
            else => {
                try out.append(arena, text[i]);
                i += 1;
            },
        }
    }
}

const Link = struct { label: []const u8, end: usize };

/// `[label](url)` starting at `open`. Null when it isn't one — an unmatched `[`, or a `[label]`
/// with no destination (a reference link, whose label is already the visible text).
fn parseLink(text: []const u8, open: usize) ?Link {
    const close = std.mem.indexOfScalarPos(u8, text, open + 1, ']') orelse return null;
    if (close + 1 >= text.len or text[close + 1] != '(') return null;
    const end = std.mem.indexOfScalarPos(u8, text, close + 2, ')') orelse return null;
    return .{ .label = text[open + 1 .. close], .end = end + 1 };
}

const Wikilink = struct { label: []const u8, end: usize };

/// `[[Target]]` / `[[Target|alias]]` starting at `open`, reduced to what a reader sees: the alias
/// when there is one, the target otherwise. `#anchor` is kept — in a one-line label, *which
/// section* is exactly the interesting half.
fn parseWikilink(text: []const u8, open: usize) ?Wikilink {
    if (open + 1 >= text.len or text[open + 1] != '[') return null;
    const close = std.mem.indexOfPos(u8, text, open + 2, "]]") orelse return null;
    const inner = text[open + 2 .. close];
    const label = if (std.mem.indexOfScalar(u8, inner, '|')) |pipe| inner[pipe + 1 ..] else inner;
    return .{ .label = label, .end = close + 2 };
}

fn runLength(text: []const u8, start: usize, c: u8) usize {
    var n: usize = 0;
    while (start + n < text.len and text[start + n] == c) n += 1;
    return n;
}

fn isSpaceOrPunct(c: u8) bool {
    return c == ' ' or c == '\t' or !std.ascii.isAlphanumeric(c);
}

/// The characters a backslash may escape in markdown. Anything else keeps its backslash, so a
/// Windows path in prose reads as written.
fn isMarkdownPunct(c: u8) bool {
    return std.mem.indexOfScalar(u8, "\\`*_{}[]()#+-.!|~<>", c) != null;
}

/// One line, at most `max` bytes, never cut mid-codepoint.
///
/// This is a hard ceiling, not the visual fit: the label placer measures the text it is given and
/// appends its own "…" when it does not fit the slot. Without a ceiling a 900-word paragraph is
/// measured in full, every frame the placer runs, to draw forty characters of it.
pub fn clip(text: []const u8, max: usize) []const u8 {
    const nl = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
    var line = std.mem.trim(u8, text[0..nl], " \t\r");
    if (line.len <= max) return line;

    // Back off any continuation byte (0b10xxxxxx) so the cut lands on a codepoint boundary.
    var cut = max;
    while (cut > 0 and (line[cut] & 0xC0) == 0x80) cut -= 1;
    line = line[0..cut];

    // Prefer a nearby word boundary, so the placer's ellipsis reads as a cut sentence rather than
    // a cut word. Only when one is close — backing up half the label to find a space is worse.
    if (std.mem.lastIndexOfScalar(u8, line, ' ')) |sp| {
        if (sp + word_boundary_slack >= line.len) line = line[0..sp];
    }
    return std.mem.trimEnd(u8, line, " \t");
}

/// How far back `clip` will reach for a space rather than cutting a word.
const word_boundary_slack: usize = 8;

// -- tests ------------------------------------------------------------------------

const testing = std.testing;

test "a plain paragraph is its own first line" {
    const lines = [_][]const u8{ "# Title", "Some prose here.", "more" };
    try testing.expectEqualStrings("Some prose here.", blockExcerpt(&lines, 1).?);
}

test "a list item loses its bullet" {
    for ([_][]const u8{ "- one two", "* one two", "+ one two" }) |raw| {
        const lines = [_][]const u8{raw};
        try testing.expectEqualStrings("one two", blockExcerpt(&lines, 0).?);
    }
}

test "a task item loses its checkbox" {
    for ([_][]const u8{ "- [x] test", "- [X] test", "- [ ] test", "* [x] test", "1. [x] test" }) |raw| {
        const lines = [_][]const u8{raw};
        try testing.expectEqualStrings("test", blockExcerpt(&lines, 0).?);
    }
}

test "prose is not a task item" {
    // No bullet, so `[x]` is whatever the author meant by it, not a checkbox.
    const lines = [_][]const u8{"[x] marks the spot"};
    try testing.expectEqualStrings("[x] marks the spot", blockExcerpt(&lines, 0).?);
}

test "a bracket that is not a checkbox survives the bullet strip" {
    const lines = [_][]const u8{"- [Moi](Glossary/Moi.md) and I"};
    try testing.expectEqualStrings("[Moi](Glossary/Moi.md) and I", blockExcerpt(&lines, 0).?);
}

test "an ordered list loses its number" {
    const lines = [_][]const u8{"12. counted"};
    try testing.expectEqualStrings("counted", blockExcerpt(&lines, 0).?);
}

test "an abbreviation is not mistaken for an ordinal" {
    // The dot rule must not fire on prose that happens to contain one.
    const lines = [_][]const u8{"e.g. a sentence"};
    try testing.expectEqualStrings("e.g. a sentence", blockExcerpt(&lines, 0).?);
}

test "a quote loses its markers, however nested" {
    const lines = [_][]const u8{"> > deep quote"};
    try testing.expectEqualStrings("deep quote", blockExcerpt(&lines, 0).?);
}

test "a fence gives up its language" {
    const lines = [_][]const u8{ "```zig", "const x = 1;", "```" };
    try testing.expectEqualStrings("zig", blockExcerpt(&lines, 0).?);
}

test "a bare fence falls through to the first body line" {
    const lines = [_][]const u8{ "```", "const x = 1;", "```" };
    try testing.expectEqualStrings("const x = 1;", blockExcerpt(&lines, 0).?);
}

test "a table skips its separator row" {
    const lines = [_][]const u8{ "| a | b |", "|---|---|", "| 1 | 2 |" };
    // Row one is real content; the separator alone would be meaningless.
    try testing.expectEqualStrings("a | b |", blockExcerpt(&lines, 0).?);
    try testing.expectEqualStrings("1 | 2 |", blockExcerpt(&lines, 1).?);
}

test "leading blank lines are skipped" {
    const lines = [_][]const u8{ "", "  ", "content" };
    try testing.expectEqualStrings("content", blockExcerpt(&lines, 0).?);
}

test "the lookahead does not run past its budget" {
    var lines: [8][]const u8 = undefined;
    for (&lines) |*l| l.* = "";
    lines[6] = "too far";
    try testing.expect(blockExcerpt(&lines, 0) == null);
}

test "a line past the end is not a crash" {
    const lines = [_][]const u8{"only"};
    try testing.expect(blockExcerpt(&lines, 9) == null);
    try testing.expect(blockExcerpt(&.{}, 0) == null);
}

test "clip leaves a short line alone" {
    try testing.expectEqualStrings("short", clip("short", 48));
}

test "clip stops at the first newline" {
    try testing.expectEqualStrings("first", clip("first\nsecond", 48));
}

test "clip prefers a word boundary" {
    //                     0123456789012345
    const s = "alpha beta gamma delta";
    // Cutting at 16 lands inside "delta"; the space at 16 is within slack, so it backs up.
    try testing.expectEqualStrings("alpha beta gamma", clip(s, 17));
}

test "clip does not back up half the label to find a space" {
    // One long word: no boundary within slack, so it cuts where it must.
    const s = "aaaaaaaaaaaaaaaaaaaaaaaaa";
    try testing.expectEqualStrings(s[0..10], clip(s, 10));
}

test "clip never cuts a codepoint in half" {
    // "é" is two bytes; cutting at 5 would land inside it.
    const s = "abcdé fgh";
    const out = clip(s, 5);
    try testing.expect(std.unicode.utf8ValidateSlice(out));
    try testing.expectEqualStrings("abcd", out);
}

test "clip handles a multibyte run at the limit" {
    const s = "ααααααααα"; // 9 × 2 bytes
    const out = clip(s, 7);
    try testing.expect(std.unicode.utf8ValidateSlice(out));
    try testing.expectEqual(@as(usize, 6), out.len);
}

// -- plain ------------------------------------------------------------------------

fn expectPlain(expected: []const u8, src: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings(expected, plain(arena.allocator(), src));
}

test "a markdown link keeps its text and loses its path" {
    try expectPlain(
        "Moi and I were lead to existential topics",
        "[Moi](Glossary/Moi.md) and I were lead to existential topics",
    );
}

test "a wikilink shows what a reader would see" {
    try expectPlain("Moi and I", "[[Moi]] and I");
    try expectPlain("the thing and I", "[[Glossary/Moi|the thing]] and I");
    // Which section is the interesting half, so the anchor stays.
    try expectPlain("Daphne#Habitat", "[[Daphne#Habitat]]");
}

test "an image is its alt text" {
    try expectPlain("a diagram", "![a diagram](../assets/d.png)");
}

test "emphasis markers go, the words stay" {
    try expectPlain("The real truth", "The **real** truth");
    try expectPlain("The real truth", "The *real* truth");
    try expectPlain("The real truth", "The _real_ truth");
    try expectPlain("The real truth", "The ~~real~~ truth");
    try expectPlain("code here", "`code` here");
}

test "an identifier with underscores is not emphasis" {
    try expectPlain("call snake_case_name now", "call snake_case_name now");
    // A single `~` is punctuation far more often than markup.
    try expectPlain("about ~30 items", "about ~30 items");
}

test "an escaped marker is a literal" {
    try expectPlain("a *literal* star", "a \\*literal\\* star");
}

test "unmatched syntax is left as written rather than eaten" {
    try expectPlain("a [bracket that never closes", "a [bracket that never closes");
    try expectPlain("a `tick that never closes", "a `tick that never closes");
    // A reference link's label is already the visible text.
    try expectPlain("see [the docs][1]", "see [the docs][1]");
}

test "a link label keeps its own emphasis stripped" {
    try expectPlain("bold link", "[**bold** link](x.md)");
}

test "text with no markup is returned unallocated" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const src = "nothing to do here";
    try testing.expectEqual(src.ptr, plain(arena.allocator(), src).ptr);
}

test "plain then clip spends the budget on visible characters" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const src = "[Moi](Glossary/Moi.md) and I were lead to existential topics this morning";
    // Clipped raw, the whole budget goes on the path; clipped after `plain`, on the sentence.
    try testing.expectEqualStrings("Moi and I were lead", clip(plain(arena.allocator(), src), 20));
}
