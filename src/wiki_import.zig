//! Turn a MediaWiki XML dump into a vault of markdown notes, keeping the link graph intact.
//!
//! Atlas's whole graph is the wikilink structure, so the only thing this tool really has to get
//! right is that `[[Target]]` in the output resolves to the file that holds `Target`. Everything
//! else — how faithfully wikitext becomes markdown — is cosmetic by comparison. That ordering is
//! deliberate, and it is why the HuggingFace `marin-community/wikipedia-markdown` corpus is not
//! usable here despite being far better prose: its HTML→markdown pipeline drops every anchor, so
//! 8.29M articles arrive as 8.29M orphans.
//!
//! Three decisions worth knowing about:
//!
//! **Redirects are resolved away, not emitted.** A redirect is not a note; it is an alias. Writing
//! one file per redirect would roughly double the note count and hang a degree-1 stub off half the
//! articles in the vault, which is a graph shape no real vault has. Instead pass 1 builds
//! `title -> target` and pass 2 rewrites every link through it. What comes out is the article
//! graph — the thing the 283,997-articles / 3,682,542-links calibration was measured on.
//!
//! **The output is flat: no folders.** Categories are the obvious candidate and they are a trap —
//! Simple English categories have a median of 2–3 members, so a folder per category is ~100k
//! directories holding two files each. `fold.build` treats the folder chain as a real (if weak)
//! grouping prior at `folder_w = 0.25`, so inventing structure that carries no signal is worse
//! than having none: it actively pulls unrelated notes together. Alphabetical sharding is the same
//! mistake with extra steps. A flat vault says what is true — the only structure here is links.
//!
//! **Titles are sanitized identically on both sides.** `resolve.zig` matches a link to a note by
//! filename stem, and rejects any target containing `:` outright. So the same `safeStem` runs over
//! the filename and over every link target, or half the vault would resolve to nothing.
//!
//! Scale note: this reads the whole dump into memory and walks it twice. That is fine for Simple
//! English (1.6 GB of XML) and will not do for full English (~100 GB) — that needs a streaming
//! pass 1 over titles/redirects and a second streamed pass, which is a rewrite of `eachPage` and
//! nothing else.

const std = @import("std");

const usage =
    \\usage: atlas-wiki-import <dump.xml> <out-dir> [--limit N]
    \\
    \\  dump.xml   uncompressed MediaWiki XML (bunzip2 -k the dump first)
    \\  out-dir    created if missing; one .md per article, flat
    \\  --limit N  stop after N articles (for a quick smoke test)
    \\
;

/// Characters that cannot appear in a note's filename *or* in a link target that has to resolve.
/// `:` and `#` are the load-bearing ones: `resolve.isNoteLikeTarget` rejects any target with a
/// colon (it reads as a URL scheme) and treats `#` as a heading anchor.
fn isUnsafe(c: u8) bool {
    return switch (c) {
        '/', '\\', ':', '*', '?', '"', '<', '>', '|', '#', '[', ']' => true,
        else => c < 0x20,
    };
}

/// Title -> filename stem. Also applied to every link target, so the two always agree.
fn safeStem(out: []u8, title: []const u8) []const u8 {
    var n: usize = 0;
    for (title) |c| {
        if (n == out.len) break;
        out[n] = if (isUnsafe(c)) '-' else c;
        n += 1;
    }
    // Trailing dots and spaces are legal in the dump and awkward on disk.
    while (n > 0 and (out[n - 1] == '.' or out[n - 1] == ' ')) n -= 1;
    return out[0..n];
}

/// MediaWiki's own title normalization, as far as link lookup needs it: underscores are spaces,
/// surrounding space is insignificant, and the first character is capitalized. Without this,
/// `[[united_states]]` and `[[United States]]` are two different notes.
fn canonTitle(out: []u8, raw: []const u8) []const u8 {
    var t = std.mem.trim(u8, raw, " \t\n_");
    if (t.len > out.len) t = t[0..out.len];
    var n: usize = 0;
    var prev_space = false;
    for (t) |c| {
        const ch: u8 = if (c == '_') ' ' else c;
        if (ch == ' ') {
            if (prev_space or n == 0) continue;
            prev_space = true;
        } else prev_space = false;
        out[n] = ch;
        n += 1;
    }
    while (n > 0 and out[n - 1] == ' ') n -= 1;
    if (n > 0) out[0] = std.ascii.toUpper(out[0]);
    return out[0..n];
}

/// XML entity decode, in place into `out`. The dump only uses the five predefined entities plus
/// numeric references.
fn unescape(out: *std.ArrayListUnmanaged(u8), gpa: std.mem.Allocator, src: []const u8) !void {
    out.clearRetainingCapacity();
    var i: usize = 0;
    while (i < src.len) {
        if (src[i] != '&') {
            try out.append(gpa, src[i]);
            i += 1;
            continue;
        }
        const semi = std.mem.indexOfScalarPos(u8, src, i, ';') orelse {
            try out.append(gpa, src[i]);
            i += 1;
            continue;
        };
        if (semi - i > 10) {
            try out.append(gpa, src[i]);
            i += 1;
            continue;
        }
        const name = src[i + 1 .. semi];
        if (std.mem.eql(u8, name, "amp")) {
            try out.append(gpa, '&');
        } else if (std.mem.eql(u8, name, "lt")) {
            try out.append(gpa, '<');
        } else if (std.mem.eql(u8, name, "gt")) {
            try out.append(gpa, '>');
        } else if (std.mem.eql(u8, name, "quot")) {
            try out.append(gpa, '"');
        } else if (std.mem.eql(u8, name, "apos")) {
            try out.append(gpa, '\'');
        } else if (name.len > 1 and name[0] == '#') {
            const digits = if (name[1] == 'x' or name[1] == 'X') name[2..] else name[1..];
            const base: u8 = if (name[1] == 'x' or name[1] == 'X') 16 else 10;
            const cp = std.fmt.parseInt(u21, digits, base) catch {
                try out.append(gpa, src[i]);
                i += 1;
                continue;
            };
            var buf: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(cp, &buf) catch {
                i = semi + 1;
                continue;
            };
            try out.appendSlice(gpa, buf[0..len]);
        } else {
            try out.append(gpa, src[i]);
            i += 1;
            continue;
        }
        i = semi + 1;
    }
}

/// One `<page>`'s fields, as raw (still XML-escaped) slices into the dump.
const Page = struct {
    title: []const u8,
    ns: []const u8,
    redirect: ?[]const u8,
    text: []const u8,
};

fn tagValue(page: []const u8, comptime open: []const u8, comptime close: []const u8) ?[]const u8 {
    const a = std.mem.indexOf(u8, page, open) orelse return null;
    const rest = page[a + open.len ..];
    const b = std.mem.indexOf(u8, rest, close) orelse return null;
    return rest[0..b];
}

/// Iterate `<page>` blocks. Deliberately a substring scan rather than a real XML parser: the dump's
/// shape is fixed and machine-generated, and a parser would be slower and no more correct here.
fn eachPage(xml: []const u8, cursor: *usize) ?Page {
    const start_tag = "<page>";
    const end_tag = "</page>";
    const a = std.mem.indexOfPos(u8, xml, cursor.*, start_tag) orelse return null;
    const b = std.mem.indexOfPos(u8, xml, a, end_tag) orelse return null;
    cursor.* = b + end_tag.len;
    const page = xml[a + start_tag.len .. b];

    const title = tagValue(page, "<title>", "</title>") orelse return .{
        .title = "",
        .ns = "",
        .redirect = null,
        .text = "",
    };
    const ns = tagValue(page, "<ns>", "</ns>") orelse "";
    // `<redirect title="Foo" />`
    var redirect: ?[]const u8 = null;
    if (std.mem.indexOf(u8, page, "<redirect title=\"")) |r| {
        const rest = page[r + "<redirect title=\"".len ..];
        if (std.mem.indexOfScalar(u8, rest, '"')) |q| redirect = rest[0..q];
    }
    // `<text ... xml:space="preserve">…</text>`; the attributes vary, so find the tag's own '>'.
    var text: []const u8 = "";
    if (std.mem.indexOf(u8, page, "<text")) |t| {
        const rest = page[t..];
        if (std.mem.indexOfScalar(u8, rest, '>')) |gt| {
            const body = rest[gt + 1 ..];
            if (std.mem.indexOf(u8, body, "</text>")) |e| text = body[0..e];
        }
    }
    return .{ .title = title, .ns = ns, .redirect = redirect, .text = text };
}

/// Namespaces whose links are not notes. `resolve.isNoteLikeTarget` would reject these anyway (they
/// all carry a colon), but dropping them here keeps them out of the prose too.
fn isNamespaced(target: []const u8) bool {
    if (target.len == 0) return false;
    if (target[0] == ':') return true; // `[[:Category:X]]`
    const colon = std.mem.indexOfScalar(u8, target, ':') orelse return false;
    // An interlanguage link (`[[fr:Paris]]`) has a short lowercase prefix; a real title with a
    // colon in it (`Boston: A City`) almost always has a space after the colon.
    if (colon + 1 < target.len and target[colon + 1] == ' ') return false;
    return true;
}

const Stats = struct {
    pages: usize = 0,
    articles: usize = 0,
    redirects: usize = 0,
    links: usize = 0,
    dropped_links: usize = 0,
    collisions: usize = 0,
    bytes: usize = 0,
};

/// Wikitext -> markdown, keeping `[[…]]` and rewriting each target through `redirects`.
fn convert(
    gpa: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    src: []const u8,
    redirects: *const std.StringHashMapUnmanaged([]const u8),
    titles: *const std.StringHashMapUnmanaged(void),
    stats: *Stats,
) !void {
    out.clearRetainingCapacity();
    var i: usize = 0;
    var at_line_start = true;
    while (i < src.len) {
        const rest = src[i..];

        if (std.mem.startsWith(u8, rest, "<!--")) {
            i += if (std.mem.indexOf(u8, rest, "-->")) |e| e + 3 else rest.len;
            continue;
        }
        if (std.mem.startsWith(u8, rest, "<ref")) {
            // Either `<ref …/>` or `<ref …>…</ref>`; take whichever terminator comes first.
            const self_close = std.mem.indexOf(u8, rest, "/>");
            const pair = std.mem.indexOf(u8, rest, "</ref>");
            if (pair != null and (self_close == null or pair.? < self_close.?)) {
                i += pair.? + "</ref>".len;
            } else if (self_close) |sc| {
                i += sc + 2;
            } else i = src.len;
            continue;
        }
        // Templates and tables, both nested. Skipping them wholesale loses infoboxes, which is
        // the right trade: they are markup, not links, and their contents are mostly templates.
        if (std.mem.startsWith(u8, rest, "{{")) {
            i += skipBalanced(rest, "{{", "}}");
            continue;
        }
        if (std.mem.startsWith(u8, rest, "{|")) {
            i += skipBalanced(rest, "{|", "|}");
            continue;
        }

        if (std.mem.startsWith(u8, rest, "[[")) {
            const close = std.mem.indexOf(u8, rest, "]]") orelse {
                i += 2;
                continue;
            };
            const inner = rest[2..close];
            i += close + 2;

            const bar = std.mem.indexOfScalar(u8, inner, '|');
            const raw_target = if (bar) |b| inner[0..b] else inner;
            const display = if (bar) |b| inner[b + 1 ..] else "";

            if (isNamespaced(raw_target)) {
                stats.dropped_links += 1;
                continue; // File/Image/Category/interlanguage — not a note, and not prose either
            }
            // Drop the anchor: `[[Foo#Bar]]` is a link to Foo.
            var target = raw_target;
            if (std.mem.indexOfScalar(u8, target, '#')) |h| target = target[0..h];
            if (target.len == 0) {
                // `[[#Section|text]]` — same-page anchor, keep the words only.
                if (display.len > 0) try out.appendSlice(gpa, display);
                at_line_start = false;
                continue;
            }

            var cbuf: [512]u8 = undefined;
            const canon = canonTitle(&cbuf, target);
            // One hop through the redirect map. Redirect chains exist but are rare and MediaWiki
            // itself does not follow them, so neither do we.
            const final = redirects.get(canon) orelse canon;
            if (!titles.contains(final)) {
                // A red link. Emitting it would make a phantom note; the vault should describe
                // what exists, so keep the words and drop the link.
                stats.dropped_links += 1;
                try out.appendSlice(gpa, if (display.len > 0) display else target);
                at_line_start = false;
                continue;
            }

            var sbuf: [512]u8 = undefined;
            const stem = safeStem(&sbuf, final);
            try out.appendSlice(gpa, "[[");
            try out.appendSlice(gpa, stem);
            if (display.len > 0 and !std.mem.eql(u8, display, stem)) {
                try out.append(gpa, '|');
                try out.appendSlice(gpa, display);
            }
            try out.appendSlice(gpa, "]]");
            stats.links += 1;
            at_line_start = false;
            continue;
        }

        // `[http://… label]` -> `label`. A bare `[` is literal.
        if (rest[0] == '[' and (std.mem.startsWith(u8, rest, "[http") or std.mem.startsWith(u8, rest, "[//"))) {
            const close = std.mem.indexOfScalar(u8, rest, ']') orelse {
                i += 1;
                continue;
            };
            const inner = rest[1..close];
            if (std.mem.indexOfScalar(u8, inner, ' ')) |sp| try out.appendSlice(gpa, inner[sp + 1 ..]);
            i += close + 1;
            at_line_start = false;
            continue;
        }

        if (std.mem.startsWith(u8, rest, "'''")) {
            try out.appendSlice(gpa, "**");
            i += 3;
            at_line_start = false;
            continue;
        }
        if (std.mem.startsWith(u8, rest, "''")) {
            try out.append(gpa, '*');
            i += 2;
            at_line_start = false;
            continue;
        }

        if (at_line_start and rest[0] == '=') {
            var level: usize = 0;
            while (level < rest.len and rest[level] == '=') level += 1;
            const line_end = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
            const line = std.mem.trimEnd(u8, rest[level..line_end], " \t=");
            if (level >= 2 and level <= 6 and line.len > 0) {
                for (0..level) |_| try out.append(gpa, '#');
                try out.append(gpa, ' ');
                try out.appendSlice(gpa, std.mem.trim(u8, line, " \t"));
                i += line_end;
                continue;
            }
        }

        at_line_start = rest[0] == '\n';
        try out.append(gpa, rest[0]);
        i += 1;
    }
}

/// Bytes to skip past a balanced `open`…`close` run starting at `src[0]`.
fn skipBalanced(src: []const u8, comptime open: []const u8, comptime close: []const u8) usize {
    var depth: usize = 0;
    var i: usize = 0;
    while (i < src.len) {
        if (std.mem.startsWith(u8, src[i..], open)) {
            depth += 1;
            i += open.len;
        } else if (std.mem.startsWith(u8, src[i..], close)) {
            depth -= 1;
            i += close.len;
            if (depth == 0) return i;
        } else i += 1;
    }
    return src.len;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var dump_path: ?[]const u8 = null;
    var out_dir: ?[]const u8 = null;
    var limit: usize = std.math.maxInt(usize);
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--limit")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            limit = try std.fmt.parseInt(usize, args[i], 10);
        } else if (dump_path == null) {
            dump_path = a;
        } else if (out_dir == null) {
            out_dir = a;
        }
    }
    if (dump_path == null or out_dir == null) {
        std.debug.print("{s}", .{usage});
        return error.MissingArgument;
    }

    std.debug.print("reading {s}…\n", .{dump_path.?});
    // Not `readFileAlloc`: its unbuffered `allocRemaining` path fails on a multi-gigabyte file,
    // and its own doc comment says to use a `File.Reader` when the size is known — which it is.
    const xml = read: {
        var f = try std.Io.Dir.cwd().openFile(io, dump_path.?, .{});
        defer f.close(io);
        const st = try f.stat(io);
        const buf = try gpa.alloc(u8, @intCast(st.size));
        errdefer gpa.free(buf);
        var chunk: [1 << 20]u8 = undefined;
        var r = f.reader(io, &chunk);
        try r.interface.readSliceAll(buf);
        break :read buf;
    };
    defer gpa.free(xml);
    std.debug.print("  {d:.2} GB\n", .{@as(f64, @floatFromInt(xml.len)) / (1 << 30)});

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // ---- pass 1: every article title, and every redirect's destination -------------------------
    var titles: std.StringHashMapUnmanaged(void) = .empty;
    defer titles.deinit(gpa);
    var redirects: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer redirects.deinit(gpa);
    var stats: Stats = .{};

    var scratch: std.ArrayListUnmanaged(u8) = .empty;
    defer scratch.deinit(gpa);

    var cursor: usize = 0;
    while (eachPage(xml, &cursor)) |page| {
        stats.pages += 1;
        if (!std.mem.eql(u8, page.ns, "0")) continue;
        try unescape(&scratch, gpa, page.title);
        var cbuf: [512]u8 = undefined;
        const canon = canonTitle(&cbuf, scratch.items);
        if (canon.len == 0) continue;

        if (page.redirect) |r| {
            try unescape(&scratch, gpa, r);
            var tbuf: [512]u8 = undefined;
            const to = canonTitle(&tbuf, scratch.items);
            if (to.len == 0) continue;
            const key = try arena.dupe(u8, canon);
            const val = try arena.dupe(u8, to);
            try redirects.put(gpa, key, val);
            stats.redirects += 1;
        } else {
            try titles.put(gpa, try arena.dupe(u8, canon), {});
            stats.articles += 1;
        }
    }
    std.debug.print("pass 1: {d} pages, {d} articles, {d} redirects\n", .{
        stats.pages, stats.articles, stats.redirects,
    });

    // ---- pass 2: write one note per article ---------------------------------------------------
    std.Io.Dir.cwd().createDirPath(io, out_dir.?) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    var dir = try std.Io.Dir.cwd().openDir(io, out_dir.?, .{ .access_sub_paths = true });
    defer dir.close(io);

    var used: std.StringHashMapUnmanaged(void) = .empty;
    defer used.deinit(gpa);
    var body: std.ArrayListUnmanaged(u8) = .empty;
    defer body.deinit(gpa);
    var file: std.ArrayListUnmanaged(u8) = .empty;
    defer file.deinit(gpa);

    var written: usize = 0;
    cursor = 0;
    while (eachPage(xml, &cursor)) |page| {
        if (written >= limit) break;
        if (!std.mem.eql(u8, page.ns, "0")) continue;
        if (page.redirect != null) continue;

        try unescape(&scratch, gpa, page.title);
        var cbuf: [512]u8 = undefined;
        const canon = canonTitle(&cbuf, scratch.items);
        if (canon.len == 0) continue;
        var sbuf: [512]u8 = undefined;
        const stem = safeStem(&sbuf, canon);
        if (stem.len == 0) continue;

        // Two titles can sanitize to one stem (`A/B` and `A-B`). Keeping the first is the only
        // option that leaves link resolution deterministic; it is rare enough to just count.
        const gop = try used.getOrPut(gpa, stem);
        if (gop.found_existing) {
            stats.collisions += 1;
            continue;
        }
        gop.key_ptr.* = try arena.dupe(u8, stem);

        try unescape(&scratch, gpa, page.text);
        try convert(gpa, &body, scratch.items, &redirects, &titles, &stats);

        file.clearRetainingCapacity();
        try file.appendSlice(gpa, "# ");
        try file.appendSlice(gpa, canon);
        try file.appendSlice(gpa, "\n\n");
        try file.appendSlice(gpa, std.mem.trim(u8, body.items, " \n\t"));
        try file.append(gpa, '\n');

        var name: [560]u8 = undefined;
        const path = try std.fmt.bufPrint(&name, "{s}.md", .{stem});
        dir.writeFile(io, .{ .sub_path = path, .data = file.items, .flags = .{ .truncate = true } }) catch |err| {
            std.debug.print("  write {s}: {s}\n", .{ path, @errorName(err) });
            continue;
        };
        stats.bytes += file.items.len;
        written += 1;
        if (written % 25_000 == 0) std.debug.print("  {d} notes…\n", .{written});
    }

    std.debug.print(
        \\
        \\wrote {d} notes to {s}
        \\  links kept    {d}
        \\  links dropped {d}  (red links, files, categories, interlanguage)
        \\  collisions    {d}  (titles sharing a sanitized stem; later ones skipped)
        \\  content       {d:.1} MB
        \\
    , .{
        written,      out_dir.?,
        stats.links,  stats.dropped_links,
        stats.collisions,
        @as(f64, @floatFromInt(stats.bytes)) / (1 << 20),
    });
}
