//! Turning the text between brackets into a note — Obsidian-compatible link resolution.
//!
//! Deliberately pure: it takes a list of candidate notes and gives back an index, with no
//! database, no filesystem, and no allocator. Every rule below is therefore a table test, which
//! matters more here than anywhere else in the plugin — "which note did `[[Setup]]` mean" is
//! the kind of behavior that is obvious when right, baffling when wrong, and impossible to
//! debug through three layers of SQL and UI.
//!
//! Paths are **vault-relative and `/`-separated** throughout (the scanner normalizes at its
//! boundary), so nothing here has to think about drive letters or backslashes.
const std = @import("std");

/// A note the index knows about, as far as resolution is concerned.
pub const Candidate = struct {
    /// Vault-relative path, `/`-separated, including the extension.
    path: []const u8,
    /// Basename without the extension, exactly as written on disk.
    stem: []const u8,
    /// One alias for this note (from front matter). A note with several aliases appears once
    /// per alias, since resolution only ever needs "does *some* name match".
    alias: []const u8 = "",
};

pub const Match = struct {
    /// Index into the candidate slice.
    index: usize,
    /// Several notes matched and the tie-break picked this one. Still a usable answer — the
    /// caller decides whether to say so in the UI.
    ambiguous: bool = false,
};

/// Longest path we'll resolve `./` and `../` through. A wiki link deeper than this is not a
/// thing that happens by accident.
pub const max_path_len: usize = 1024;

/// The link target, cleaned up: extension stripped, separators normalized.
pub const Normalized = struct {
    /// The name or path to look for, without a trailing `.md`/`.markdown`.
    text: []const u8,
    /// True when the target names a *location* (`notes/Setup`, `../Setup`) rather than just a
    /// name — which switches resolution from "search everywhere" to "look exactly there".
    is_path: bool,
    /// True for `./x` or `../x`, which resolve against the linking note's directory rather
    /// than the vault root.
    is_relative: bool,
};

/// Strip the extension and decide whether this target names a path. Does not copy — the result
/// borrows from `target`.
pub fn normalize(target: []const u8) Normalized {
    var text = std.mem.trim(u8, target, " \t");
    // A trailing separator is meaningless on a note name and would break `is_path` reasoning.
    text = std.mem.trimEnd(u8, text, "/\\");
    text = stripMarkdownExtension(text);

    const is_relative = std.mem.startsWith(u8, text, "./") or
        std.mem.startsWith(u8, text, "../") or
        std.mem.eql(u8, text, "..");
    // `\` counts as a separator so a Windows-flavored link still reads as a path.
    const is_path = is_relative or std.mem.indexOfAny(u8, text, "/\\") != null;

    return .{ .text = text, .is_path = is_path, .is_relative = is_relative };
}

fn stripMarkdownExtension(text: []const u8) []const u8 {
    for ([_][]const u8{ ".md", ".markdown" }) |ext| {
        if (text.len > ext.len and std.ascii.endsWithIgnoreCase(text, ext)) {
            return text[0 .. text.len - ext.len];
        }
    }
    return text;
}

/// True when `target` is something the note graph should treat as a note edge —
/// a bare name (`Setup`), a vault path (`notes/Setup`), or an explicit markdown file
/// (`Setup.md`). Rejects schemes, same-file anchors, and other file types (`foo.zig`,
/// images, etc.) so a CommonMark link to source code doesn't become a phantom note.
pub fn isNoteLikeTarget(target: []const u8) bool {
    var text = std.mem.trim(u8, target, " \t");
    if (text.len == 0) return false;
    if (text[0] == '#') return false; // same-file anchor
    if (std.mem.indexOfScalar(u8, text, ':') != null) return false; // https:, mailto:, C:\…
    // Fragment is navigation within a note; ignore it for the extension check.
    if (std.mem.indexOfScalar(u8, text, '#')) |hash| {
        text = text[0..hash];
        if (text.len == 0) return false;
    }
    const base = if (std.mem.lastIndexOfAny(u8, text, "/\\")) |slash|
        text[slash + 1 ..]
    else
        text;
    if (base.len == 0) return false;
    // No extension → Obsidian-style note name. Otherwise only markdown files count.
    if (std.mem.lastIndexOfScalar(u8, base, '.')) |dot| {
        if (dot == 0) return false; // `.gitignore`-style
        const ext = base[dot..];
        return std.ascii.eqlIgnoreCase(ext, ".md") or std.ascii.eqlIgnoreCase(ext, ".markdown");
    }
    return true;
}

/// Resolve `target` as written in the note at `source_path` (vault-relative, `""` when the
/// source has no place in the vault) against `candidates`. Returns null when nothing matches —
/// a normal state, not an error: that's a note you haven't written yet.
///
/// `buf` is scratch for path joining; `max_path_len` bytes is always enough.
pub fn resolve(
    target: []const u8,
    source_path: []const u8,
    candidates: []const Candidate,
    buf: []u8,
) ?Match {
    return resolveIndexed(target, source_path, candidates, null, buf);
}

/// `resolve`, but consulting a prebuilt `Index` to avoid scanning every candidate.
///
/// Resolution is otherwise a linear pass over the whole vault *per link*, which is O(links ×
/// notes): 400ms on an 11k-note vault, and quadratic, so tens of seconds by 100k. The index is
/// keyed on the case-folded name, and folding is the loosest comparison this file does — so the
/// bucket for a name is a superset of everything that could match it, and running the same
/// four-pass priority over just that bucket gives byte-identical answers.
///
/// `index` may be null, in which case this is exactly the old linear behaviour. That is what
/// the one-off lookups (a hover, a completion) still use — building an index to resolve a single
/// link would cost more than the scan it saves.
pub fn resolveIndexed(
    target: []const u8,
    source_path: []const u8,
    candidates: []const Candidate,
    index: ?*const Index,
    buf: []u8,
) ?Match {
    // Percent-decode first, because a markdown link to a note whose name has a space is written
    // `[R. N. Ravi](R.%20N.%20Ravi.md)` — that is what editors emit, and it is what the preview
    // renders as a working link. Undecoded, `R.%20N.%20Ravi` matches no candidate and the edge
    // simply does not exist: the note is linked on screen and unlinked in the graph, with nothing
    // to say which. Wikilinks are unaffected (they carry the name verbatim), so this only ever
    // shows up on the markdown-link form.
    var decoded: [max_path_len]u8 = undefined;
    const norm = normalize(percentDecode(target, &decoded));
    if (norm.text.len == 0) return null;

    if (norm.is_path) return resolveAsPath(norm, source_path, candidates, index, buf);
    return resolveAsName(norm.text, source_path, candidates, index);
}

/// Decode `%XX` escapes. Returns `target` untouched when there is nothing to decode, and a slice
/// of `buf` otherwise. Decoding only ever shortens, so `max_path_len` is always enough.
///
/// A lone `%` or a malformed escape is passed through as written: it is far more likely to be a
/// literal per-cent in a note's name than a truncated escape, and inventing a byte there would
/// break a link that currently works.
pub fn percentDecode(target: []const u8, buf: []u8) []const u8 {
    if (std.mem.indexOfScalar(u8, target, '%') == null) return target;
    if (target.len > buf.len) return target;
    var n: usize = 0;
    var i: usize = 0;
    while (i < target.len) {
        if (target[i] == '%' and i + 2 < target.len) {
            const hi = std.fmt.charToDigit(target[i + 1], 16) catch null;
            const lo = std.fmt.charToDigit(target[i + 2], 16) catch null;
            if (hi != null and lo != null) {
                buf[n] = hi.? * 16 + lo.?;
                n += 1;
                i += 3;
                continue;
            }
        }
        buf[n] = target[i];
        n += 1;
        i += 1;
    }
    return buf[0..n];
}

/// Case-folded lookup tables over a candidate slice.
///
/// Buckets hold indices into the caller's `candidates`, so the index borrows it and must not
/// outlive it. Rebuild whenever the candidate list is rebuilt (i.e. per index generation).
pub const Index = struct {
    allocator: std.mem.Allocator,
    /// folded stem or alias → candidate indices
    by_name: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(u32)) = .empty,
    /// folded extension-stripped path → candidate indices
    by_path: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(u32)) = .empty,
    /// Owns the folded key strings the maps point at.
    keys: std.heap.ArenaAllocator,

    pub fn init(allocator: std.mem.Allocator, candidates: []const Candidate) !Index {
        var self: Index = .{
            .allocator = allocator,
            .keys = std.heap.ArenaAllocator.init(allocator),
        };
        errdefer self.deinit();
        const ka = self.keys.allocator();

        for (candidates, 0..) |cand, i| {
            try addKey(allocator, ka, &self.by_name, cand.stem, @intCast(i));
            if (cand.alias.len > 0) try addKey(allocator, ka, &self.by_name, cand.alias, @intCast(i));
            try addKey(allocator, ka, &self.by_path, stripMarkdownExtension(cand.path), @intCast(i));
        }
        return self;
    }

    pub fn deinit(self: *Index) void {
        var it = self.by_name.valueIterator();
        while (it.next()) |v| v.deinit(self.allocator);
        self.by_name.deinit(self.allocator);
        var it2 = self.by_path.valueIterator();
        while (it2.next()) |v| v.deinit(self.allocator);
        self.by_path.deinit(self.allocator);
        self.keys.deinit();
    }

    fn addKey(
        allocator: std.mem.Allocator,
        key_arena: std.mem.Allocator,
        map: *std.StringHashMapUnmanaged(std.ArrayListUnmanaged(u32)),
        raw: []const u8,
        i: u32,
    ) !void {
        const key = try foldDup(key_arena, raw);
        const gop = try map.getOrPut(allocator, key);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(allocator, i);
    }

    fn lookup(
        map: *const std.StringHashMapUnmanaged(std.ArrayListUnmanaged(u32)),
        allocator: std.mem.Allocator,
        raw: []const u8,
    ) ?[]const u32 {
        var stack: [max_path_len]u8 = undefined;
        if (raw.len > stack.len) return null;
        _ = allocator;
        for (raw, 0..) |c, i| stack[i] = std.ascii.toLower(c);
        const e = map.get(stack[0..raw.len]) orelse return null;
        return e.items;
    }
};

fn foldDup(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    const out = try allocator.alloc(u8, s.len);
    for (s, out) |c, *o| o.* = std.ascii.toLower(c);
    return out;
}

/// A target naming a location: try exactly there, and nowhere else. No searching, so no
/// tie-break — a path either names a note or it doesn't.
fn resolveAsPath(
    norm: Normalized,
    source_path: []const u8,
    candidates: []const Candidate,
    index: ?*const Index,
    buf: []u8,
) ?Match {
    // An explicitly relative target (`./x`, `../x`) has exactly one meaning: resolve it against
    // the source's directory and nowhere else.
    if (norm.is_relative) {
        const joined = joinAndClean(dirOf(source_path), norm.text, buf) orelse return null;
        return findPath(joined, candidates, index);
    }

    // A bare multi-segment target (`notes/Setup.md`) is ambiguous between two conventions that
    // Atlas is on both sides of:
    //
    //   • Obsidian — and this function, historically — reads it from the vault root.
    //   • Atlas's own link format (README) says paths are relative to the *source note's*
    //     directory, and that is what the `[[` completion writes.
    //
    // Reading it as vault-root only meant a link written by Atlas from a note in a subfolder
    // into a deeper subfolder never resolved at all — the whole `tree` shape of the gauntlet
    // came out as 4 edges from ~1364 links.
    //
    // Trying both, source-directory first, resolves each convention's links without breaking the
    // other: the source-relative reading can only match a note that actually sits there, so a
    // vault-root link that resolves today still resolves, and one that used to resolve to
    // nothing now finds the note the author meant.
    if (dirOf(source_path).len > 0) {
        if (joinAndClean(dirOf(source_path), norm.text, buf)) |joined| {
            if (findPath(joined, candidates, index)) |m| return m;
        }
    }
    const from_root = joinAndClean("", norm.text, buf) orelse return null;
    return findPath(from_root, candidates, index);
}

fn findPath(joined: []const u8, candidates: []const Candidate, index: ?*const Index) ?Match {
    // Case-sensitive first: on a case-insensitive filesystem two notes differing only in case
    // can't coexist, but on a case-sensitive one they can, and the exact spelling must win.
    if (index) |ix| {
        const bucket = Index.lookup(&ix.by_path, ix.allocator, joined) orelse return null;
        for ([_]bool{ false, true }) |folded| {
            for (bucket) |ci| {
                const cand_stem_path = stripMarkdownExtension(candidates[ci].path);
                if (pathEql(cand_stem_path, joined, folded)) return .{ .index = ci };
            }
        }
        return null;
    }
    for ([_]bool{ false, true }) |folded| {
        for (candidates, 0..) |cand, i| {
            const cand_stem_path = stripMarkdownExtension(cand.path);
            if (pathEql(cand_stem_path, joined, folded)) return .{ .index = i };
        }
    }
    return null;
}

/// A bare name: search the whole vault, then break ties by "which one did they most likely
/// mean from here".
fn resolveAsName(
    name: []const u8,
    source_path: []const u8,
    candidates: []const Candidate,
    index: ?*const Index,
) ?Match {
    // Priority order. An exact spelling beats a case-insensitive one, and a note's real name
    // beats somebody's alias for it — otherwise an alias could shadow a note actually called
    // that, which is never what the author meant.
    const Pass = enum { exact_stem, exact_alias, folded_stem, folded_alias };
    // The folded bucket is a superset of every candidate any pass could match, so restricting
    // the scan to it changes nothing about which one wins.
    const bucket: ?[]const u32 = if (index) |ix|
        (Index.lookup(&ix.by_name, ix.allocator, name) orelse return null)
    else
        null;
    for ([_]Pass{ .exact_stem, .exact_alias, .folded_stem, .folded_alias }) |pass| {
        var best: ?usize = null;
        var ambiguous = false;
        var k: usize = 0;
        const limit = if (bucket) |b| b.len else candidates.len;
        while (k < limit) : (k += 1) {
            const i: usize = if (bucket) |b| b[k] else k;
            const cand = candidates[i];
            const hit = switch (pass) {
                .exact_stem => std.mem.eql(u8, cand.stem, name),
                .exact_alias => cand.alias.len > 0 and std.mem.eql(u8, cand.alias, name),
                .folded_stem => foldEql(cand.stem, name),
                .folded_alias => cand.alias.len > 0 and foldEql(cand.alias, name),
            };
            if (!hit) continue;
            if (best) |b| {
                // Two notes with the same path are the same note reached via two aliases.
                if (std.mem.eql(u8, candidates[b].path, cand.path)) continue;
                ambiguous = true;
                if (preferred(cand.path, candidates[b].path, source_path)) best = i;
            } else {
                best = i;
            }
        }
        if (best) |b| return .{ .index = b, .ambiguous = ambiguous };
    }
    return null;
}

/// True when `a` is the better answer than `b` for a link written in `source_path`.
///
/// This is the "shortest unique name" behavior: `[[Setup]]` in `projects/x/notes.md` should
/// find `projects/x/Setup.md` before `archive/2019/Setup.md`, and a top-level `Setup.md`
/// before something buried six directories deep.
fn preferred(a: []const u8, b: []const u8, source_path: []const u8) bool {
    const src_dir = dirOf(source_path);

    // 1. Same directory as the linking note wins outright — the strongest signal there is.
    const a_same = std.mem.eql(u8, dirOf(a), src_dir);
    const b_same = std.mem.eql(u8, dirOf(b), src_dir);
    if (a_same != b_same) return a_same;

    // 2. Shallower wins: a note at the vault root is "the" note, one nested deep is a variant.
    const a_depth = depthOf(a);
    const b_depth = depthOf(b);
    if (a_depth != b_depth) return a_depth < b_depth;

    // 3. Nearer in the tree wins.
    const a_shared = sharedDirPrefix(dirOf(a), src_dir);
    const b_shared = sharedDirPrefix(dirOf(b), src_dir);
    if (a_shared != b_shared) return a_shared > b_shared;

    // 4. Nothing distinguishes them, so pick by name — arbitrary, but *stable*, which is what
    //    keeps a link from pointing somewhere different each time the index is rebuilt.
    return std.mem.order(u8, a, b) == .lt;
}

/// Directory part of a vault-relative path, `""` for a file at the root.
/// Directory of a vault-relative note path. `""` for a note at the vault root.
///
/// The POSIX variant explicitly: a vault-relative path is always `/`-separated whatever the host
/// filesystem does (see `query.vaultRelative`), and the native `dirname` on Windows would also
/// split on `\`, which here can only be a literal character in a name.
fn dirOf(path: []const u8) []const u8 {
    return std.fs.path.dirnamePosix(path) orelse "";
}

/// Number of directories above the file.
fn depthOf(path: []const u8) usize {
    return std.mem.count(u8, path, "/");
}

/// How many leading path segments two directories share.
fn sharedDirPrefix(a: []const u8, b: []const u8) usize {
    var a_it = std.mem.splitScalar(u8, a, '/');
    var b_it = std.mem.splitScalar(u8, b, '/');
    var n: usize = 0;
    while (true) {
        const sa = a_it.next() orelse return n;
        const sb = b_it.next() orelse return n;
        if (sa.len == 0 or sb.len == 0) return n;
        if (!std.mem.eql(u8, sa, sb)) return n;
        n += 1;
    }
}

fn pathEql(a: []const u8, b: []const u8, folded: bool) bool {
    return if (folded) foldEql(a, b) else std.mem.eql(u8, a, b);
}

/// Case-insensitive compare, ASCII only.
///
/// Full Unicode case folding needs tables this plugin has no business vendoring, and Obsidian
/// is itself inconsistent about non-ASCII here. The documented consequence: `Café` and `CAFÉ`
/// are different notes. Exact matches are tried before folded ones, so this only ever affects
/// links whose case doesn't already match.
pub fn foldEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
    }
    return true;
}

/// Join `base` and `rel` and resolve `.`/`..` segments, writing into `buf`. Returns null when
/// the result would escape the vault root or overrun the buffer.
///
/// Not `std.fs.path.resolvePosix`, for two reasons. It allocates, and this runs once per link —
/// millions of times on a Wikipedia-scale import, which is why the whole path here is a caller's
/// buffer. And it *clamps* `..` at the root rather than refusing it, so `../../etc/passwd` would
/// come back as a plausible-looking vault path instead of the null that keeps resolution inside
/// the vault. Both separators are accepted on the way in so a link written on Windows still
/// parses; the output is always `/`, matching the stored paths it will be compared against.
pub fn joinAndClean(base: []const u8, rel: []const u8, buf: []u8) ?[]const u8 {
    var b: PathBuilder = .{ .buf = buf };
    for ([_][]const u8{ base, rel }) |part| {
        var it = std.mem.splitAny(u8, part, "/\\");
        while (it.next()) |seg| {
            if (seg.len == 0 or std.mem.eql(u8, seg, ".")) continue;
            if (std.mem.eql(u8, seg, "..")) {
                // Above the vault root is not somewhere we can index.
                if (!b.pop()) return null;
                continue;
            }
            if (!b.push(seg)) return null;
        }
    }
    return b.result();
}

/// Builds a `/`-separated path segment by segment, remembering where each one starts so `..`
/// can drop the last without rescanning.
const PathBuilder = struct {
    buf: []u8,
    len: usize = 0,
    starts: [64]usize = undefined,
    n: usize = 0,

    fn push(self: *PathBuilder, seg: []const u8) bool {
        if (self.n >= self.starts.len) return false;
        const need = if (self.len == 0) seg.len else seg.len + 1;
        if (self.len + need > self.buf.len) return false;
        if (self.len != 0) {
            self.buf[self.len] = '/';
            self.len += 1;
        }
        self.starts[self.n] = self.len;
        self.n += 1;
        @memcpy(self.buf[self.len..][0..seg.len], seg);
        self.len += seg.len;
        return true;
    }

    fn pop(self: *PathBuilder) bool {
        if (self.n == 0) return false;
        self.n -= 1;
        // Back up over the separator too, except at the start where there isn't one.
        self.len = if (self.n == 0) 0 else self.starts[self.n] - 1;
        return true;
    }

    fn result(self: *const PathBuilder) ?[]const u8 {
        if (self.len == 0) return null;
        return self.buf[0..self.len];
    }
};

// -- tests ------------------------------------------------------------------------------

const testing = std.testing;

fn resolveIn(target: []const u8, source: []const u8, candidates: []const Candidate) ?Match {
    var buf: [max_path_len]u8 = undefined;
    return resolve(target, source, candidates, &buf);
}

fn expectPath(target: []const u8, source: []const u8, candidates: []const Candidate, want: []const u8) !void {
    const m = resolveIn(target, source, candidates) orelse {
        std.debug.print("expected [[{s}]] from {s} to resolve to {s}, got nothing\n", .{ target, source, want });
        return error.NoMatch;
    };
    try testing.expectEqualStrings(want, candidates[m.index].path);
}

fn expectNone(target: []const u8, source: []const u8, candidates: []const Candidate) !void {
    if (resolveIn(target, source, candidates)) |m| {
        std.debug.print("expected [[{s}]] to resolve to nothing, got {s}\n", .{ target, candidates[m.index].path });
        return error.UnexpectedMatch;
    }
}

const flat = [_]Candidate{
    .{ .path = "Setup.md", .stem = "Setup" },
    .{ .path = "Ideas.md", .stem = "Ideas" },
    .{ .path = "notes/Daily.md", .stem = "Daily" },
};

test "a bare name finds the note" {
    try expectPath("Setup", "Ideas.md", &flat, "Setup.md");
}

test "a name in a subdirectory is found from anywhere" {
    try expectPath("Daily", "Ideas.md", &flat, "notes/Daily.md");
}

test "a missing note resolves to nothing" {
    try expectNone("Nonexistent", "Ideas.md", &flat);
}

test "an empty target resolves to nothing" {
    try expectNone("", "Ideas.md", &flat);
    try expectNone("   ", "Ideas.md", &flat);
}

test "a trailing markdown extension is ignored" {
    try expectPath("Setup.md", "Ideas.md", &flat, "Setup.md");
    try expectPath("Setup.markdown", "Ideas.md", &flat, "Setup.md");
    try expectPath("Setup.MD", "Ideas.md", &flat, "Setup.md");
}

test "case-insensitive match when no exact one exists" {
    try expectPath("setup", "Ideas.md", &flat, "Setup.md");
    try expectPath("SETUP", "Ideas.md", &flat, "Setup.md");
}

test "an exact spelling beats a case-insensitive one" {
    const cands = [_]Candidate{
        .{ .path = "a/note.md", .stem = "note" },
        .{ .path = "b/Note.md", .stem = "Note" },
    };
    try expectPath("Note", "x.md", &cands, "b/Note.md");
    try expectPath("note", "x.md", &cands, "a/note.md");
}

test "a path target resolves from the vault root" {
    try expectPath("notes/Daily", "Ideas.md", &flat, "notes/Daily.md");
}

test "a path target does not match a note of the same name elsewhere" {
    try expectNone("wrong/Daily", "Ideas.md", &flat);
}

test "a bare path target also resolves against the source's own directory" {
    // Atlas's `[[` completion writes paths relative to the linking note's directory (README),
    // but this function used to read a bare path from the vault root only — so a link from a
    // note in a subfolder into a deeper one never resolved. The gauntlet's `tree` shape found
    // this: 1364 links, 4 edges.
    const cands = [_]Candidate{
        .{ .path = "root/n-0/leaf.md", .stem = "leaf" },
    };
    try expectPath("n-0/leaf", "root/index.md", &cands, "root/n-0/leaf.md");
}

test "vault-root paths still win where they already resolved" {
    // The source-relative attempt must not shadow the vault-root reading: a target that names a
    // real note from the root keeps resolving there when nothing sits at the relative spot.
    const cands = [_]Candidate{
        .{ .path = "notes/Daily.md", .stem = "Daily" },
    };
    try expectPath("notes/Daily", "archive/old.md", &cands, "notes/Daily.md");
}

test "the source-relative reading is preferred when both exist" {
    const cands = [_]Candidate{
        .{ .path = "notes/sub/Target.md", .stem = "Target" },
        .{ .path = "sub/Target.md", .stem = "Target" },
    };
    try expectPath("sub/Target", "notes/here.md", &cands, "notes/sub/Target.md");
}

test "a relative target resolves against the linking note's directory" {
    const cands = [_]Candidate{
        .{ .path = "a/Target.md", .stem = "Target" },
        .{ .path = "b/Target.md", .stem = "Target" },
    };
    try expectPath("./Target", "a/note.md", &cands, "a/Target.md");
    try expectPath("./Target", "b/note.md", &cands, "b/Target.md");
}

test "a parent-relative target walks up" {
    const cands = [_]Candidate{
        .{ .path = "a/Target.md", .stem = "Target" },
        .{ .path = "a/b/note.md", .stem = "note" },
    };
    try expectPath("../Target", "a/b/note.md", &cands, "a/Target.md");
}

test "escaping the vault root resolves to nothing" {
    try expectNone("../../Setup", "Ideas.md", &flat);
}

test "backslash separators are accepted" {
    try expectPath("notes\\Daily", "Ideas.md", &flat, "notes/Daily.md");
}

test "an alias resolves" {
    const cands = [_]Candidate{
        .{ .path = "Setup.md", .stem = "Setup", .alias = "Getting Started" },
    };
    try expectPath("Getting Started", "x.md", &cands, "Setup.md");
}

test "a real note name beats someone else's alias for it" {
    const cands = [_]Candidate{
        .{ .path = "Other.md", .stem = "Other", .alias = "Setup" },
        .{ .path = "Setup.md", .stem = "Setup" },
    };
    const m = resolveIn("Setup", "x.md", &cands).?;
    try testing.expectEqualStrings("Setup.md", cands[m.index].path);
    try testing.expect(!m.ambiguous);
}

test "two aliases of the same note are not ambiguous" {
    const cands = [_]Candidate{
        .{ .path = "Setup.md", .stem = "Setup", .alias = "Start" },
        .{ .path = "Setup.md", .stem = "Setup", .alias = "Start" },
    };
    const m = resolveIn("Start", "x.md", &cands).?;
    try testing.expect(!m.ambiguous);
}

test "tie-break: same directory as the source wins" {
    const cands = [_]Candidate{
        .{ .path = "Setup.md", .stem = "Setup" },
        .{ .path = "projects/x/Setup.md", .stem = "Setup" },
    };
    const m = resolveIn("Setup", "projects/x/notes.md", &cands).?;
    try testing.expectEqualStrings("projects/x/Setup.md", cands[m.index].path);
    try testing.expect(m.ambiguous);
}

test "tie-break: shallower wins when neither is a sibling" {
    const cands = [_]Candidate{
        .{ .path = "archive/2019/deep/Setup.md", .stem = "Setup" },
        .{ .path = "Setup.md", .stem = "Setup" },
    };
    try expectPath("Setup", "elsewhere/notes.md", &cands, "Setup.md");
}

test "tie-break: nearer in the tree wins at equal depth" {
    const cands = [_]Candidate{
        .{ .path = "other/branch/Setup.md", .stem = "Setup" },
        .{ .path = "projects/x/Setup.md", .stem = "Setup" },
    };
    try expectPath("Setup", "projects/y/notes.md", &cands, "projects/x/Setup.md");
}

test "tie-break: stable by name when nothing else distinguishes" {
    const cands = [_]Candidate{
        .{ .path = "b/Setup.md", .stem = "Setup" },
        .{ .path = "a/Setup.md", .stem = "Setup" },
    };
    const first = resolveIn("Setup", "z/notes.md", &cands).?;
    try testing.expectEqualStrings("a/Setup.md", cands[first.index].path);

    // Same answer with the candidates in the other order — the point of the rule.
    const reordered = [_]Candidate{
        .{ .path = "a/Setup.md", .stem = "Setup" },
        .{ .path = "b/Setup.md", .stem = "Setup" },
    };
    const second = resolveIn("Setup", "z/notes.md", &reordered).?;
    try testing.expectEqualStrings("a/Setup.md", reordered[second.index].path);
}

test "a unique match is never ambiguous" {
    try testing.expect(!resolveIn("Setup", "Ideas.md", &flat).?.ambiguous);
}

test "an empty source path still resolves bare names" {
    // An unsaved buffer has no place in the vault, so same-directory and nearness rules have
    // nothing to work with, but a plain name lookup must still work.
    try expectPath("Setup", "", &flat, "Setup.md");
}

test "normalize classifies targets" {
    try testing.expect(!normalize("Setup").is_path);
    try testing.expect(normalize("a/Setup").is_path);
    try testing.expect(normalize("./Setup").is_relative);
    try testing.expect(normalize("../Setup").is_relative);
    try testing.expect(!normalize("a/Setup").is_relative);
    try testing.expectEqualStrings("Setup", normalize("  Setup.md  ").text);
}

test "isNoteLikeTarget accepts notes and rejects other files" {
    try testing.expect(isNoteLikeTarget("Setup"));
    try testing.expect(isNoteLikeTarget("notes/Setup"));
    try testing.expect(isNoteLikeTarget("./Notes/A.md"));
    try testing.expect(isNoteLikeTarget("B.md#Heading"));
    try testing.expect(isNoteLikeTarget("foo.markdown"));
    try testing.expect(!isNoteLikeTarget("https://example.com"));
    try testing.expect(!isNoteLikeTarget("#anchor"));
    try testing.expect(!isNoteLikeTarget("src/foo.zig"));
    try testing.expect(!isNoteLikeTarget("foo.zig"));
    try testing.expect(!isNoteLikeTarget("pic.png"));
    try testing.expect(!isNoteLikeTarget(".gitignore"));
}

test "the index gives byte-identical answers to the linear scan" {
    // The index exists purely to make resolution not-quadratic; if it ever disagrees with the
    // scan it is a correctness bug, not a performance trade. So assert equivalence directly,
    // over the awkward cases: case differences, aliases, ambiguity, paths, and misses.
    const cands = [_]Candidate{
        .{ .path = "Setup.md", .stem = "Setup" },
        .{ .path = "a/Setup.md", .stem = "Setup" },
        .{ .path = "a/b/setup.md", .stem = "setup" },
        .{ .path = "notes/Daily.md", .stem = "Daily", .alias = "Journal" },
        .{ .path = "notes/Other.md", .stem = "Other", .alias = "Daily" },
        .{ .path = "Zed.md", .stem = "Zed" },
    };
    var index = try Index.init(testing.allocator, &cands);
    defer index.deinit();

    const targets = [_][]const u8{
        "Setup",       "setup",          "SETUP",     "Journal",
        "Daily",       "notes/Daily",    "a/Setup",   "a/b/setup",
        "./Setup",     "../Setup",       "Zed.md",    "Missing",
        "notes/Daily.md", "b/Setup",     "",          "Other",
    };
    const sources = [_][]const u8{ "", "a/note.md", "a/b/note.md", "notes/x.md" };

    for (sources) |src| {
        for (targets) |t| {
            var buf_a: [max_path_len]u8 = undefined;
            var buf_b: [max_path_len]u8 = undefined;
            const linear = resolveIndexed(t, src, &cands, null, &buf_a);
            const hashed = resolveIndexed(t, src, &cands, &index, &buf_b);
            if (linear) |l| {
                try testing.expect(hashed != null);
                try testing.expectEqual(l.index, hashed.?.index);
                try testing.expectEqual(l.ambiguous, hashed.?.ambiguous);
            } else {
                try testing.expectEqual(@as(?Match, null), hashed);
            }
        }
    }
}

test "joinAndClean resolves dot segments" {
    var buf: [max_path_len]u8 = undefined;
    try testing.expectEqualStrings("a/b", joinAndClean("", "a/b", &buf).?);
    try testing.expectEqualStrings("a/c", joinAndClean("a/b", "../c", &buf).?);
    try testing.expectEqualStrings("a/b/c", joinAndClean("a/b", "./c", &buf).?);
    try testing.expectEqualStrings("c", joinAndClean("a/b", "../../c", &buf).?);
    try testing.expectEqual(@as(?[]const u8, null), joinAndClean("a", "../../c", &buf));
    try testing.expectEqualStrings("a/b", joinAndClean("", "a//b", &buf).?);
}

test "joinAndClean refuses to overrun its buffer" {
    var small: [4]u8 = undefined;
    try testing.expectEqual(@as(?[]const u8, null), joinAndClean("", "aaa/bbb", &small));
}

test "a markdown link to a spaced note name resolves through its percent escapes" {
    // `[R. N. Ravi](R.%20N.%20Ravi.md)` is what an editor writes for a note whose name has spaces,
    // and the preview renders it as a working link. The graph resolved it against the candidate
    // list verbatim, matched nothing, and silently dropped the edge — a note visibly linked in the
    // document and absent from the map.
    const candidates = [_]Candidate{
        .{ .path = "R. N. Ravi.md", .stem = "R. N. Ravi" },
        .{ .path = "Ashwani Kumar (politician).md", .stem = "Ashwani Kumar (politician)" },
    };
    var buf: [max_path_len]u8 = undefined;
    const m = resolve("R.%20N.%20Ravi.md", "Ashwani Kumar (politician).md", &candidates, &buf);
    try std.testing.expect(m != null);
    try std.testing.expectEqual(@as(usize, 0), m.?.index);

    // A literal per-cent that is not an escape stays literal.
    var buf2: [max_path_len]u8 = undefined;
    try std.testing.expectEqualStrings("100% done", percentDecode("100% done", &buf2));
}
