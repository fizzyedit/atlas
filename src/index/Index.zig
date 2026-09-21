//! The vault index, in memory: every note (real or phantom), its derived rows — aliases,
//! headings, tags, blocks, outbound links — and every media file, keyed the ways the indexer
//! and the read side ask for them.
//!
//! This replaces the SQLite database. On the 284k-note reference vault SQLite was 70 % of a
//! cold build (the relink alone rewrote 3.35 M `dst_id` rows through a b-tree) and the parse
//! was 2 %; here a relink is a pass over each note's link array, a note write is a hash-map
//! upsert, and the graph snapshot is a walk over arrays already in hand. It is also what lets
//! the index run where there is no C, no libc and no file: the web build, over a vault on a
//! cloud mount. See `docs/WEB_PLAN.md`.
//!
//! **Locking.** The indexer writes from its worker; the UI reads from the frame. Every access
//! — read or write — happens with `mutex` held (`lock`/`unlock`), and slices handed out point
//! into the index, so a reader copies what it needs before unlocking. Ops are short (one note),
//! so the lock is never held for long; a full pass (relink, snapshot) takes and releases it per
//! note. On the web there is one thread and the lock is a cheap atomic.
//!
//! **Ids** are stable for the life of the index and never reused: `notes[id - 1]`, with a
//! tombstone for a deleted note (`alive = false`). Snapshots and the UI carry ids across
//! publishes, which is what makes reuse unsafe.
//!
//! **Ownership.** A note's own fields (`path`, `stem`, `stem_fold`, `title`) and its derived
//! rows each live in one allocation per note (`own`, `derived`), replaced wholesale when the
//! note is rewritten. Media rows are one allocation each.
const std = @import("std");
const schema = @import("schema.zig");

const Index = @This();

pub const Alias = struct { alias: []const u8, alias_fold: []const u8 };
pub const Heading = struct { text: []const u8, text_fold: []const u8, level: u8, line: u32 };
pub const Tag = struct { tag: []const u8, tag_fold: []const u8, line: u32 };
pub const Block = struct { kind: schema.BlockKind, line_start: u32, line_end: u32, weight: u32 };
pub const Link = struct {
    /// Resolved destination. Written as the source itself until a relink resolves it.
    dst_id: i64,
    raw: []const u8,
    heading: []const u8,
    alias: []const u8,
    kind: schema.LinkKind,
    ambiguous: bool,
    line: u32,
    col: u32,
};

pub const Note = struct {
    id: i64,
    alive: bool = true,
    phantom: bool,
    /// Vault-relative, `/`-separated, with extension. Empty for a phantom.
    path: []const u8 = "",
    stem: []const u8 = "",
    stem_fold: []const u8 = "",
    title: []const u8 = "",
    mtime_ns: i64 = 0,
    size: i64 = 0,
    hash: i64 = 0,
    aliases: []const Alias = &.{},
    headings: []const Heading = &.{},
    tags: []const Tag = &.{},
    blocks: []const Block = &.{},
    links: []const Link = &.{},
    /// Sources with at least one link to this note → how many of their links point here. The
    /// backlinks query walks these sources' `links`; a note is a phantom candidate for purge
    /// when this is empty.
    inbound: std.AutoHashMapUnmanaged(i64, u32) = .empty,
    /// The one allocation `path`/`stem`/`stem_fold`/`title` live in.
    own: []u8 = &.{},
    /// The one allocation every derived row and its strings live in.
    derived: []align(@alignOf(Link)) u8 = &.{},

    /// The title as shown: the stem when the front matter gave none.
    pub fn shownTitle(self: *const Note) []const u8 {
        return if (self.title.len > 0) self.title else self.stem;
    }
};

pub const Media = struct {
    id: i64,
    alive: bool = true,
    path: []const u8,
    stem: []const u8,
    stem_fold: []const u8,
    name_fold: []const u8,
    own: []u8,
};

gpa: std.mem.Allocator,
io: std.Io,
mutex: std.Io.Mutex = .init,

notes: std.ArrayListUnmanaged(Note) = .empty,
/// Real notes by path (keys borrow the note's `path`).
by_path: std.StringHashMapUnmanaged(i64) = .empty,
/// One phantom per folded stem (keys borrow the note's `stem_fold`).
phantom_by_stem: std.StringHashMapUnmanaged(i64) = .empty,
real_count: u32 = 0,
phantom_count: u32 = 0,
link_count: u32 = 0,

media: std.ArrayListUnmanaged(Media) = .empty,
media_by_path: std.StringHashMapUnmanaged(i64) = .empty,
media_count: u32 = 0,

/// Sorted views for prefix completion, rebuilt lazily after a write (`sorted_dirty`): real
/// note ids by `stem_fold`; `(note, alias index)` by `alias_fold`; media ids by `name_fold`
/// and by `stem_fold`.
stems_sorted: std.ArrayListUnmanaged(i64) = .empty,
aliases_sorted: std.ArrayListUnmanaged(AliasRef) = .empty,
media_by_name_sorted: std.ArrayListUnmanaged(i64) = .empty,
media_by_stem_sorted: std.ArrayListUnmanaged(i64) = .empty,
sorted_dirty: bool = true,

/// Bumped by every write, so a reader that cached something can tell it is stale.
version: u64 = 0,

pub const AliasRef = struct { note_id: i64, index: u32 };

pub fn init(gpa: std.mem.Allocator, io: std.Io) Index {
    return .{ .gpa = gpa, .io = io };
}

pub fn deinit(self: *Index) void {
    for (self.notes.items) |*n| self.freeNote(n);
    self.notes.deinit(self.gpa);
    self.by_path.deinit(self.gpa);
    self.phantom_by_stem.deinit(self.gpa);
    for (self.media.items) |m| self.gpa.free(m.own);
    self.media.deinit(self.gpa);
    self.media_by_path.deinit(self.gpa);
    self.stems_sorted.deinit(self.gpa);
    self.aliases_sorted.deinit(self.gpa);
    self.media_by_name_sorted.deinit(self.gpa);
    self.media_by_stem_sorted.deinit(self.gpa);
}

pub fn lock(self: *Index) void {
    self.mutex.lockUncancelable(self.io);
}
pub fn unlock(self: *Index) void {
    self.mutex.unlock(self.io);
}

/// Drop everything, keeping the allocation. Ids restart.
pub fn clear(self: *Index) void {
    for (self.notes.items) |*n| self.freeNote(n);
    self.notes.clearRetainingCapacity();
    self.by_path.clearRetainingCapacity();
    self.phantom_by_stem.clearRetainingCapacity();
    for (self.media.items) |m| self.gpa.free(m.own);
    self.media.clearRetainingCapacity();
    self.media_by_path.clearRetainingCapacity();
    self.real_count = 0;
    self.phantom_count = 0;
    self.link_count = 0;
    self.media_count = 0;
    self.sorted_dirty = true;
    self.version += 1;
}

fn freeNote(self: *Index, n: *Note) void {
    n.inbound.deinit(self.gpa);
    if (n.derived.len != 0) self.gpa.free(n.derived);
    if (n.own.len != 0) self.gpa.free(n.own);
}

// ---- notes: lookup --------------------------------------------------------------------------

/// The note with `id`, alive or not. Null for an id never issued.
pub fn note(self: *const Index, id: i64) ?*Note {
    if (id < 1 or id > self.notes.items.len) return null;
    return &self.notes.items[@intCast(id - 1)];
}

/// A live note with `id`.
pub fn live(self: *const Index, id: i64) ?*Note {
    const n = self.note(id) orelse return null;
    return if (n.alive) n else null;
}

pub fn idByPath(self: *const Index, path: []const u8) ?i64 {
    return self.by_path.get(path);
}

pub fn byPath(self: *const Index, path: []const u8) ?*Note {
    return self.live(self.by_path.get(path) orelse return null);
}

pub fn phantomByStem(self: *const Index, stem_fold: []const u8) ?i64 {
    return self.phantom_by_stem.get(stem_fold);
}

pub const Iterator = struct {
    notes: []Note,
    i: usize = 0,
    phantom: ?bool,
    pub fn next(it: *Iterator) ?*Note {
        while (it.i < it.notes.len) {
            const n = &it.notes[it.i];
            it.i += 1;
            if (!n.alive) continue;
            if (it.phantom) |p| if (n.phantom != p) continue;
            return n;
        }
        return null;
    }
};

/// Live notes in id order: all, real only (`false`) or phantoms only (`true`).
pub fn iterate(self: *const Index, phantom: ?bool) Iterator {
    return .{ .notes = self.notes.items, .phantom = phantom };
}

// ---- notes: write ---------------------------------------------------------------------------

pub const NoteFields = struct {
    path: []const u8,
    stem: []const u8,
    title: []const u8,
    mtime_ns: i64,
    size: i64,
    hash: i64,
};

/// Insert or update a real note: the row by path if there is one, else a phantom with this
/// stem promoted, else a new row. Returns its id. Derived rows are untouched — `setDerived`
/// replaces them.
pub fn upsertNote(self: *Index, f: NoteFields) !i64 {
    var fold_buf: [1024]u8 = undefined;
    const stem_fold = foldInto(&fold_buf, f.stem) orelse return error.NameTooLong;
    if (self.by_path.get(f.path)) |id| {
        const n = self.note(id).?;
        try self.setOwn(n, f.path, f.stem, stem_fold, f.title);
        n.mtime_ns = f.mtime_ns;
        n.size = f.size;
        n.hash = f.hash;
        self.touched();
        return id;
    }
    if (self.phantom_by_stem.get(stem_fold)) |id| {
        const n = self.note(id).?;
        _ = self.phantom_by_stem.remove(n.stem_fold);
        try self.setOwn(n, f.path, f.stem, stem_fold, f.title);
        n.phantom = false;
        n.mtime_ns = f.mtime_ns;
        n.size = f.size;
        n.hash = f.hash;
        self.phantom_count -= 1;
        self.real_count += 1;
        try self.by_path.put(self.gpa, n.path, id);
        self.touched();
        return id;
    }
    const id = try self.newNote(false);
    const n = self.note(id).?;
    errdefer self.dropRow(n);
    try self.setOwn(n, f.path, f.stem, stem_fold, f.title);
    n.mtime_ns = f.mtime_ns;
    n.size = f.size;
    n.hash = f.hash;
    try self.by_path.put(self.gpa, n.path, id);
    self.real_count += 1;
    self.touched();
    return id;
}

/// Refresh a note's file metadata after a read that found the same content.
pub fn touchNote(self: *Index, id: i64, mtime_ns: i64, size: i64) void {
    const n = self.live(id) orelse return;
    n.mtime_ns = mtime_ns;
    n.size = size;
}

/// The phantom standing for `stem` (folded to find it), created if there is none. `created`
/// is raised when the note set grew.
pub fn ensurePhantom(self: *Index, stem: []const u8, created: *bool) !i64 {
    var fold_buf: [1024]u8 = undefined;
    const stem_fold = foldInto(&fold_buf, stem) orelse return error.NameTooLong;
    if (self.phantom_by_stem.get(stem_fold)) |id| return id;
    const id = try self.newNote(true);
    const n = self.note(id).?;
    errdefer self.dropRow(n);
    try self.setOwn(n, "", stem, stem_fold, stem);
    try self.phantom_by_stem.put(self.gpa, n.stem_fold, id);
    self.phantom_count += 1;
    created.* = true;
    self.touched();
    return id;
}

/// Replace every derived row of `id` from a parse. Links are written pointing at the source
/// itself; `setLinkDst` / a relink resolves them. Inbound bookkeeping on the old and new
/// destinations is kept here.
pub fn setDerived(self: *Index, id: i64, d: Derived) !void {
    const n = self.live(id) orelse return error.NotFound;
    // Size the one allocation: rows, then every string.
    var bytes: usize = 0;
    bytes += d.aliases.len * @sizeOf(Alias);
    bytes += d.headings.len * @sizeOf(Heading);
    bytes += d.tags.len * @sizeOf(Tag);
    bytes += d.blocks.len * @sizeOf(Block);
    bytes += d.links.len * @sizeOf(Link);
    bytes = std.mem.alignForward(usize, bytes, @alignOf(Link));
    for (d.aliases) |a| bytes += 2 * a.len;
    for (d.headings) |h| bytes += 2 * h.text.len;
    for (d.tags) |t| bytes += 2 * t.tag.len;
    for (d.links) |l| bytes += l.raw.len + l.heading.len + l.alias.len;

    const buf: []align(@alignOf(Link)) u8 = if (bytes == 0) &.{} else try self.gpa.alignedAlloc(u8, .of(Link), bytes);
    errdefer if (bytes != 0) self.gpa.free(buf);
    var rows: usize = 0;
    const aliases = sliceAt(Alias, buf, &rows, d.aliases.len);
    const headings = sliceAt(Heading, buf, &rows, d.headings.len);
    const tags = sliceAt(Tag, buf, &rows, d.tags.len);
    const blocks = sliceAt(Block, buf, &rows, d.blocks.len);
    const links = sliceAt(Link, buf, &rows, d.links.len);
    var text: usize = std.mem.alignForward(usize, rows, @alignOf(Link));

    for (d.aliases, aliases) |a, *out| {
        out.* = .{ .alias = putStr(buf, &text, a), .alias_fold = putFold(buf, &text, a) };
    }
    for (d.headings, headings) |h, *out| {
        out.* = .{ .text = putStr(buf, &text, h.text), .text_fold = putFold(buf, &text, h.text), .level = h.level, .line = h.line };
    }
    for (d.tags, tags) |t, *out| {
        out.* = .{ .tag = putStr(buf, &text, t.tag), .tag_fold = putFold(buf, &text, t.tag), .line = t.line };
    }
    for (d.blocks, blocks) |b, *out| {
        out.* = .{ .kind = b.kind, .line_start = b.line_start, .line_end = b.line_end, .weight = b.weight };
    }
    for (d.links, links) |l, *out| {
        out.* = .{
            .dst_id = id,
            .raw = putStr(buf, &text, l.raw),
            .heading = putStr(buf, &text, l.heading),
            .alias = putStr(buf, &text, l.alias),
            .kind = l.kind,
            .ambiguous = false,
            .line = l.line,
            .col = l.col,
        };
    }
    std.debug.assert(text == bytes);

    // Inbound accounting: the old links come off their destinations, the new ones (all
    // pointing here for now) go on.
    for (n.links) |l| self.unlinkInbound(l.dst_id, id);
    for (links) |l| try self.linkInbound(l.dst_id, id);
    self.link_count = self.link_count - @as(u32, @intCast(n.links.len)) + @as(u32, @intCast(links.len));

    if (n.derived.len != 0) self.gpa.free(n.derived);
    n.derived = buf;
    n.aliases = aliases;
    n.headings = headings;
    n.tags = tags;
    n.blocks = blocks;
    n.links = links;
    self.touched();
}

/// What a parse produced (borrowed; copied in). Named element types so a caller can build
/// them from its own parser's rows.
pub const Derived = struct {
    aliases: []const []const u8 = &.{},
    headings: []const HeadingIn = &.{},
    tags: []const TagIn = &.{},
    blocks: []const Block = &.{},
    links: []const LinkIn = &.{},
};
pub const HeadingIn = struct { text: []const u8, level: u8, line: u32 };
pub const TagIn = struct { tag: []const u8, line: u32 };
pub const LinkIn = struct { raw: []const u8, heading: []const u8 = "", alias: []const u8 = "", kind: schema.LinkKind, line: u32, col: u32 };

/// Point link `index` of `src` at `dst` (with the resolver's ambiguity verdict).
pub fn setLinkDst(self: *Index, src: i64, index: usize, dst: i64, ambiguous: bool) !void {
    const n = self.live(src) orelse return error.NotFound;
    const links = @constCast(n.links);
    const l = &links[index];
    if (l.dst_id == dst and l.ambiguous == ambiguous) return;
    if (l.dst_id != dst) {
        self.unlinkInbound(l.dst_id, src);
        try self.linkInbound(dst, src);
        l.dst_id = dst;
    }
    l.ambiguous = ambiguous;
    self.touched();
}

/// Remove link `index` of `src` (a target that is not a note). Order of the rest is kept.
pub fn removeLink(self: *Index, src: i64, index: usize) void {
    const n = self.live(src) orelse return;
    const links = @constCast(n.links);
    self.unlinkInbound(links[index].dst_id, src);
    std.mem.copyForwards(Link, links[index..], links[index + 1 ..]);
    n.links = links[0 .. links.len - 1];
    self.link_count -= 1;
    self.touched();
}

/// Every link whose destination is `from` now points at `to` (merging two phantoms).
pub fn retargetInbound(self: *Index, from: i64, to: i64) !void {
    const f = self.live(from) orelse return;
    var srcs: std.ArrayListUnmanaged(i64) = .empty;
    defer srcs.deinit(self.gpa);
    var it = f.inbound.keyIterator();
    while (it.next()) |k| try srcs.append(self.gpa, k.*);
    for (srcs.items) |src| {
        const s = self.live(src) orelse continue;
        for (@constCast(s.links)) |*l| {
            if (l.dst_id == from) {
                l.dst_id = to;
                self.unlinkInbound(from, src);
                try self.linkInbound(to, src);
            }
        }
    }
    self.touched();
}

/// Take a real note out: its file is gone. Its own derived rows go; if something still links
/// here the row becomes the phantom those links resolve to (or merges into the phantom that
/// already has this stem), otherwise it is deleted.
pub fn retireNote(self: *Index, id: i64) !void {
    const n = self.live(id) orelse return;
    try self.setDerived(id, .{});
    if (n.inbound.count() == 0) {
        self.deleteNote(id);
        return;
    }
    if (n.phantom) return;
    if (self.phantom_by_stem.get(n.stem_fold)) |existing| {
        if (existing != id) {
            try self.retargetInbound(id, existing);
            self.deleteNote(id);
            return;
        }
    }
    _ = self.by_path.remove(n.path);
    try self.setOwn(n, "", n.stem, n.stem_fold, n.stem);
    n.phantom = true;
    n.mtime_ns = 0;
    n.size = 0;
    n.hash = 0;
    self.real_count -= 1;
    self.phantom_count += 1;
    try self.phantom_by_stem.put(self.gpa, n.stem_fold, id);
    self.touched();
}

/// Delete a note outright, its outbound links with it. Inbound links elsewhere are left as
/// they are — the caller has retargeted them or knows there are none.
pub fn deleteNote(self: *Index, id: i64) void {
    const n = self.live(id) orelse return;
    for (n.links) |l| self.unlinkInbound(l.dst_id, id);
    self.link_count -= @intCast(n.links.len);
    if (n.phantom) {
        if (self.phantom_by_stem.get(n.stem_fold)) |p| if (p == id) {
            _ = self.phantom_by_stem.remove(n.stem_fold);
        };
        self.phantom_count -= 1;
    } else {
        _ = self.by_path.remove(n.path);
        self.real_count -= 1;
    }
    n.alive = false;
    self.freeNote(n);
    n.* = .{ .id = id, .alive = false, .phantom = n.phantom };
    self.touched();
}

/// Phantoms nothing links to, and phantoms whose name is not a note's, deleted. Returns how
/// many went.
pub fn purgePhantoms(self: *Index, isNoteLike: *const fn ([]const u8) bool) usize {
    var dropped: usize = 0;
    for (self.notes.items) |*n| {
        if (!n.alive or !n.phantom) continue;
        const orphan = n.inbound.count() == 0;
        // The shared empty placeholder for degenerate targets is kept while linked.
        const wrong_kind = n.stem.len != 0 and (!isNoteLike(n.shownTitle()) or !isNoteLike(n.stem));
        if (orphan or wrong_kind) {
            self.deleteNote(n.id);
            dropped += 1;
        }
    }
    return dropped;
}

// ---- media ----------------------------------------------------------------------------------

pub fn upsertMedia(self: *Index, path: []const u8) !void {
    const name = if (std.mem.lastIndexOfScalar(u8, path, '/')) |s| path[s + 1 ..] else path;
    const dot = std.mem.lastIndexOfScalar(u8, name, '.');
    const stem = if (dot) |d| name[0..d] else name;
    if (self.media_by_path.get(path)) |id| {
        // Same path: the derived spellings cannot differ. Nothing to do.
        _ = id;
        return;
    }
    const own = try self.gpa.alloc(u8, path.len + 2 * stem.len + name.len);
    errdefer self.gpa.free(own);
    var at: usize = 0;
    const p = putStr(own, &at, path);
    const s = putStr(own, &at, stem);
    const sf = putFold(own, &at, stem);
    const nf = putFold(own, &at, name);
    const id: i64 = @intCast(self.media.items.len + 1);
    try self.media.append(self.gpa, .{ .id = id, .path = p, .stem = s, .stem_fold = sf, .name_fold = nf, .own = own });
    errdefer _ = self.media.pop();
    try self.media_by_path.put(self.gpa, p, id);
    self.media_count += 1;
    self.touched();
}

pub fn deleteMedia(self: *Index, id: i64) void {
    if (id < 1 or id > self.media.items.len) return;
    const m = &self.media.items[@intCast(id - 1)];
    if (!m.alive) return;
    _ = self.media_by_path.remove(m.path);
    self.gpa.free(m.own);
    m.* = .{ .id = id, .alive = false, .path = "", .stem = "", .stem_fold = "", .name_fold = "", .own = &.{} };
    self.media_count -= 1;
    self.touched();
}

pub const MediaIterator = struct {
    items: []Media,
    i: usize = 0,
    pub fn next(it: *MediaIterator) ?*Media {
        while (it.i < it.items.len) {
            const m = &it.items[it.i];
            it.i += 1;
            if (m.alive) return m;
        }
        return null;
    }
};
pub fn iterateMedia(self: *const Index) MediaIterator {
    return .{ .items = self.media.items };
}

// ---- sorted views (completion) --------------------------------------------------------------

/// Bring the sorted views up to date. Callers of the `*Sorted` accessors do this first.
pub fn ensureSorted(self: *Index) !void {
    if (!self.sorted_dirty) return;
    self.stems_sorted.clearRetainingCapacity();
    self.aliases_sorted.clearRetainingCapacity();
    self.media_by_name_sorted.clearRetainingCapacity();
    self.media_by_stem_sorted.clearRetainingCapacity();
    try self.stems_sorted.ensureTotalCapacity(self.gpa, self.real_count);
    for (self.notes.items) |*n| {
        if (!n.alive or n.phantom) continue;
        self.stems_sorted.appendAssumeCapacity(n.id);
        for (n.aliases, 0..) |_, ai| try self.aliases_sorted.append(self.gpa, .{ .note_id = n.id, .index = @intCast(ai) });
    }
    try self.media_by_name_sorted.ensureTotalCapacity(self.gpa, self.media_count);
    try self.media_by_stem_sorted.ensureTotalCapacity(self.gpa, self.media_count);
    for (self.media.items) |*m| {
        if (!m.alive) continue;
        self.media_by_name_sorted.appendAssumeCapacity(m.id);
        self.media_by_stem_sorted.appendAssumeCapacity(m.id);
    }
    std.mem.sort(i64, self.stems_sorted.items, self, stemLess);
    std.mem.sort(AliasRef, self.aliases_sorted.items, self, aliasLess);
    std.mem.sort(i64, self.media_by_name_sorted.items, self, mediaNameLess);
    std.mem.sort(i64, self.media_by_stem_sorted.items, self, mediaStemLess);
    self.sorted_dirty = false;
}

fn stemLess(self: *Index, a: i64, b: i64) bool {
    return std.mem.lessThan(u8, self.note(a).?.stem_fold, self.note(b).?.stem_fold);
}
fn aliasLess(self: *Index, a: AliasRef, b: AliasRef) bool {
    return std.mem.lessThan(u8, self.aliasFold(a), self.aliasFold(b));
}
pub fn aliasFold(self: *const Index, r: AliasRef) []const u8 {
    return self.note(r.note_id).?.aliases[r.index].alias_fold;
}
fn mediaNameLess(self: *Index, a: i64, b: i64) bool {
    return std.mem.lessThan(u8, self.media.items[@intCast(a - 1)].name_fold, self.media.items[@intCast(b - 1)].name_fold);
}
fn mediaStemLess(self: *Index, a: i64, b: i64) bool {
    return std.mem.lessThan(u8, self.media.items[@intCast(a - 1)].stem_fold, self.media.items[@intCast(b - 1)].stem_fold);
}

/// First position in a sorted view whose key is >= `prefix` — the start of a prefix scan.
pub fn lowerBound(comptime T: type, items: []const T, ctx: anytype, keyOf: fn (@TypeOf(ctx), T) []const u8, prefix: []const u8) usize {
    var lo: usize = 0;
    var hi: usize = items.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (std.mem.lessThan(u8, keyOf(ctx, items[mid]), prefix)) lo = mid + 1 else hi = mid;
    }
    return lo;
}

// ---- internals ------------------------------------------------------------------------------

fn newNote(self: *Index, phantom: bool) !i64 {
    const id: i64 = @intCast(self.notes.items.len + 1);
    try self.notes.append(self.gpa, .{ .id = id, .phantom = phantom });
    return id;
}

/// Undo `newNote` for a row that never got its fields (an allocation failed mid-insert).
fn dropRow(self: *Index, n: *Note) void {
    if (n.id == self.notes.items.len) {
        self.freeNote(n);
        _ = self.notes.pop();
    } else {
        n.alive = false;
    }
}

fn setOwn(self: *Index, n: *Note, path: []const u8, stem: []const u8, stem_fold: []const u8, title: []const u8) !void {
    const own = try self.gpa.alloc(u8, path.len + stem.len + stem_fold.len + title.len);
    var at: usize = 0;
    const p = putStr(own, &at, path);
    const s = putStr(own, &at, stem);
    const sf = putStr(own, &at, stem_fold);
    const t = putStr(own, &at, title);
    // The maps key on the old strings; re-key before they go.
    if (!n.phantom and n.path.len != 0 and self.by_path.get(n.path) == n.id) {
        _ = self.by_path.remove(n.path);
        try self.by_path.put(self.gpa, p, n.id);
    }
    if (n.phantom and self.phantom_by_stem.get(n.stem_fold) == n.id) {
        _ = self.phantom_by_stem.remove(n.stem_fold);
        try self.phantom_by_stem.put(self.gpa, sf, n.id);
    }
    if (n.own.len != 0) self.gpa.free(n.own);
    n.own = own;
    n.path = p;
    n.stem = s;
    n.stem_fold = sf;
    n.title = t;
}

fn linkInbound(self: *Index, dst: i64, src: i64) !void {
    const d = self.live(dst) orelse return;
    const g = try d.inbound.getOrPut(self.gpa, src);
    if (!g.found_existing) g.value_ptr.* = 0;
    g.value_ptr.* += 1;
}

fn unlinkInbound(self: *Index, dst: i64, src: i64) void {
    const d = self.live(dst) orelse return;
    const v = d.inbound.getPtr(src) orelse return;
    v.* -= 1;
    if (v.* == 0) _ = d.inbound.remove(src);
}

fn touched(self: *Index) void {
    self.sorted_dirty = true;
    self.version += 1;
}

fn sliceAt(comptime T: type, buf: []u8, at: *usize, n: usize) []T {
    if (n == 0) return &.{};
    const start = std.mem.alignForward(usize, at.*, @alignOf(T));
    at.* = start + n * @sizeOf(T);
    const p: [*]T = @ptrCast(@alignCast(buf.ptr + start));
    return p[0..n];
}

fn putStr(buf: []u8, at: *usize, s: []const u8) []const u8 {
    const out = buf[at.* .. at.* + s.len];
    @memcpy(out, s);
    at.* += s.len;
    return out;
}

fn putFold(buf: []u8, at: *usize, s: []const u8) []const u8 {
    const out = buf[at.* .. at.* + s.len];
    for (s, out) |c, *o| o.* = std.ascii.toLower(c);
    at.* += s.len;
    return out;
}

/// ASCII-folded `s` in `buf`, or null when it does not fit.
pub fn foldInto(buf: []u8, s: []const u8) ?[]const u8 {
    if (s.len > buf.len) return null;
    for (s, 0..) |c, i| buf[i] = std.ascii.toLower(c);
    return buf[0..s.len];
}

// ---- tests ----------------------------------------------------------------------------------

const testing = std.testing;

test "upsert by path, promote a phantom, count" {
    var idx = Index.init(testing.allocator, testing.io);
    defer idx.deinit();
    var created = false;
    const ph = try idx.ensurePhantom("Beta", &created);
    try testing.expect(created);
    try testing.expectEqual(@as(u32, 1), idx.phantom_count);
    const a = try idx.upsertNote(.{ .path = "Alpha.md", .stem = "Alpha", .title = "", .mtime_ns = 1, .size = 2, .hash = 3 });
    const b = try idx.upsertNote(.{ .path = "b/Beta.md", .stem = "beta", .title = "Beta!", .mtime_ns = 1, .size = 2, .hash = 3 });
    try testing.expectEqual(ph, b);
    try testing.expect(!idx.note(b).?.phantom);
    try testing.expectEqual(@as(u32, 2), idx.real_count);
    try testing.expectEqual(@as(u32, 0), idx.phantom_count);
    try testing.expectEqual(a, idx.idByPath("Alpha.md").?);
    try testing.expectEqualStrings("Beta!", idx.note(b).?.shownTitle());
    const again = try idx.upsertNote(.{ .path = "Alpha.md", .stem = "Alpha", .title = "T", .mtime_ns = 9, .size = 9, .hash = 9 });
    try testing.expectEqual(a, again);
    try testing.expectEqualStrings("T", idx.note(a).?.title);
    try testing.expectEqual(@as(u32, 2), idx.real_count);
}

test "derived rows, link retargeting, inbound and retire" {
    var idx = Index.init(testing.allocator, testing.io);
    defer idx.deinit();
    const a = try idx.upsertNote(.{ .path = "A.md", .stem = "A", .title = "", .mtime_ns = 0, .size = 0, .hash = 0 });
    const b = try idx.upsertNote(.{ .path = "B.md", .stem = "B", .title = "", .mtime_ns = 0, .size = 0, .hash = 0 });
    try idx.setDerived(a, .{
        .aliases = &.{"Alpha"},
        .headings = &.{.{ .text = "Intro", .level = 1, .line = 0 }},
        .links = &.{ .{ .raw = "B", .kind = .wikilink, .line = 1, .col = 0 }, .{ .raw = "B#x", .heading = "x", .kind = .wikilink, .line = 2, .col = 0 } },
    });
    try testing.expectEqual(@as(u32, 2), idx.link_count);
    // Unresolved links point home.
    try testing.expectEqual(a, idx.note(a).?.links[0].dst_id);
    try idx.setLinkDst(a, 0, b, false);
    try idx.setLinkDst(a, 1, b, false);
    try testing.expectEqual(@as(u32, 2), idx.note(b).?.inbound.get(a).?);
    try testing.expectEqual(@as(u32, 0), idx.note(a).?.inbound.count());
    try testing.expectEqualStrings("alpha", idx.note(a).?.aliases[0].alias_fold);
    try testing.expectEqualStrings("intro", idx.note(a).?.headings[0].text_fold);

    // B's file goes: A still links to it, so B becomes a phantom with its stem.
    try idx.retireNote(b);
    try testing.expect(idx.note(b).?.phantom);
    try testing.expectEqual(b, idx.phantomByStem("b").?);
    try testing.expect(idx.idByPath("B.md") == null);
    try testing.expectEqual(@as(u32, 1), idx.real_count);
    // Rewriting A without the links frees B, which the purge then drops.
    try idx.setDerived(a, .{});
    try testing.expectEqual(@as(u32, 0), idx.note(b).?.inbound.count());
    const dropped = idx.purgePhantoms(struct {
        fn f(_: []const u8) bool {
            return true;
        }
    }.f);
    try testing.expectEqual(@as(usize, 1), dropped);
    try testing.expect(idx.live(b) == null);
    try testing.expectEqual(@as(u32, 0), idx.phantom_count);
}

test "sorted views answer a prefix scan" {
    var idx = Index.init(testing.allocator, testing.io);
    defer idx.deinit();
    _ = try idx.upsertNote(.{ .path = "Zed.md", .stem = "Zed", .title = "", .mtime_ns = 0, .size = 0, .hash = 0 });
    const ab = try idx.upsertNote(.{ .path = "ab.md", .stem = "ab", .title = "", .mtime_ns = 0, .size = 0, .hash = 0 });
    _ = try idx.upsertNote(.{ .path = "AB Aurigae.md", .stem = "AB Aurigae", .title = "", .mtime_ns = 0, .size = 0, .hash = 0 });
    try idx.setDerived(ab, .{ .aliases = &.{"Abacus"} });
    try idx.upsertMedia("img/Diagram.PNG");
    try idx.ensureSorted();
    try testing.expectEqual(@as(usize, 3), idx.stems_sorted.items.len);
    const KeyOf = struct {
        fn stem(i: *Index, id: i64) []const u8 {
            return i.note(id).?.stem_fold;
        }
    };
    const at = lowerBound(i64, idx.stems_sorted.items, &idx, KeyOf.stem, "ab");
    try testing.expectEqual(@as(usize, 0), at);
    try testing.expectEqualStrings("ab", idx.note(idx.stems_sorted.items[0]).?.stem_fold);
    try testing.expectEqualStrings("ab aurigae", idx.note(idx.stems_sorted.items[1]).?.stem_fold);
    try testing.expectEqual(@as(usize, 1), idx.aliases_sorted.items.len);
    try testing.expectEqualStrings("diagram.png", idx.media.items[0].name_fold);
    try testing.expectEqualStrings("diagram", idx.media.items[0].stem_fold);
}
