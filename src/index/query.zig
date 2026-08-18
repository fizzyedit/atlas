//! Read-side helpers over the index DB, plus the shared path helpers (`vaultRelative`,
//! `isMarkdownPath`, `stemOf`, `foldInto`) used by the indexer, watcher, and services.
//!
//! All of the SELECTs are UI-thread / caller-thread. The indexer is the only writer; WAL +
//! sqlite's Serialized threading mode make concurrent reads safe against in-flight commits.
const std = @import("std");
const builtin = @import("builtin");
const sqlite = @import("sqlite");
const Db = @import("Db.zig");
const resolve = @import("resolve.zig");
const schema = @import("schema.zig");
// Named import, not a relative sibling path: `vault_synth.zig` (the synthetic producer of this
// same type) needs the named form since its own standalone test module is rooted narrower than
// this file's directory, and content_graph.zig reaching `plugin_impl` via two different
// mechanisms at once (this file's relative import AND vault_synth.zig's named one) is exactly
// the "file exists in modules X and Y" double-attachment Zig refuses — see build.zig.
const content_graph = @import("content_graph");

pub const Backlink = struct {
    /// Vault-relative path of the source note.
    path: []const u8,
    title: []const u8,
    line: u32,
    col: u32,
    /// Filled by the *view* when a row is drawn, not by the query — see `backlinks.contextFor`.
    /// Empty until then.
    context: []const u8 = "",
};

/// Load every real note (+ one Candidate per alias) for `resolve.resolve`, over the UI thread's
/// read connection.
///
/// Prefer *not* calling this on a hot UI path: on a 286,547-note vault it is a multi-second walk
/// of every note and alias. The indexer builds the same list on its worker as part of publishing
/// and hands it over (`Indexer.takeCandidates`); this remains the fallback for callers with no
/// indexer behind them (tests, a synthetic vault, a publish that never happened).
pub fn loadCandidates(db: *Db, arena: std.mem.Allocator) ![]resolve.Candidate {
    return loadCandidatesOn(db.reader(), arena);
}

/// `loadCandidates` against an explicit connection, so the indexer's worker can build the list on
/// the *writer* handle it already owns. It must not touch `Db.reader()`: that connection is opened
/// lazily on first use, and two threads racing that one null check is a data race on `Db` itself,
/// whatever SQLite's own threading mode guarantees about the handles.
pub fn loadCandidatesOn(conn: *sqlite.Db, arena: std.mem.Allocator) ![]resolve.Candidate {
    var list: std.ArrayList(resolve.Candidate) = .empty;
    // Reserve up front: growing an empty list to that length reallocates and copies it a couple of
    // dozen times on the way, and one count is far cheaper than the copies.
    if (conn.one(usize, "SELECT count(*) FROM notes WHERE phantom = 0", .{}, .{}) catch null) |n| {
        try list.ensureTotalCapacity(arena, n);
    }

    {
        var stmt = try conn.prepare("SELECT path, stem FROM notes WHERE phantom = 0");
        defer stmt.deinit();
        var iter = try stmt.iterator(struct { path: []const u8, stem: []const u8 }, .{});
        while (true) {
            const row = (try iter.nextAlloc(arena, .{})) orelse break;
            try list.append(arena, .{ .path = row.path, .stem = row.stem });
        }
    }
    {
        var stmt = try conn.prepare(
            \\SELECT n.path, n.stem, a.alias
            \\FROM aliases a JOIN notes n ON n.id = a.note_id
            \\WHERE n.phantom = 0
        );
        defer stmt.deinit();
        var iter = try stmt.iterator(struct { path: []const u8, stem: []const u8, alias: []const u8 }, .{});
        while (true) {
            const row = (try iter.nextAlloc(arena, .{})) orelse break;
            try list.append(arena, .{ .path = row.path, .stem = row.stem, .alias = row.alias });
        }
    }
    return list.toOwnedSlice(arena);
}

/// Prepares its own statement every call, on purpose.
///
/// This is a **UI-thread** helper (`backlinksFor` and friends run it during a frame) while the
/// indexer's worker is writing on the same connection. `Db.cached()` hands out one shared set of
/// `sqlite3_stmt`s, and two threads resetting and stepping the same statement is undefined
/// behaviour — not a race that shows up under load, one that corrupts whenever it interleaves.
/// The indexer has `cachedNoteId` for the hot relink path, which is worker-only.
pub fn noteIdForPath(db: *Db, path: []const u8) !?i64 {
    return db.reader().one(i64, "SELECT id FROM notes WHERE path = ? AND phantom = 0", .{}, .{path});
}

pub fn noteTitle(db: *Db, arena: std.mem.Allocator, path: []const u8) ![]const u8 {
    const row = try db.reader().oneAlloc(
        struct { title: []const u8, stem: []const u8 },
        arena,
        "SELECT title, stem FROM notes WHERE path = ? AND phantom = 0",
        .{},
        .{path},
    ) orelse return "";
    if (row.title.len > 0) return row.title;
    return row.stem;
}

/// 0-based line of a heading in `path`, or 0 when missing (not an error).
pub fn headingLine(db: *Db, path: []const u8, heading: []const u8) !u32 {
    if (heading.len == 0) return 0;
    const id = (try noteIdForPath(db, path)) orelse return 0;
    var fold_buf: [512]u8 = undefined;
    if (heading.len > fold_buf.len) return 0;
    const folded = foldInto(&fold_buf, heading);
    const line = try db.reader().one(
        i64,
        "SELECT line FROM headings WHERE note_id = ? AND text_fold = ? LIMIT 1",
        .{},
        .{ id, folded },
    );
    return @intCast(line orelse 0);
}

/// Inbound edges for `dst_path`, ordered by source path then line — ready to group in the UI.
pub fn backlinksFor(db: *Db, arena: std.mem.Allocator, dst_path: []const u8) ![]Backlink {
    const id = (try noteIdForPath(db, dst_path)) orelse return &.{};
    var stmt = try db.reader().prepare(
        \\SELECT n.path, n.title, n.stem, l.line, l.col
        \\FROM links l
        \\JOIN notes n ON n.id = l.src_id
        \\WHERE l.dst_id = ? AND n.phantom = 0
        \\ORDER BY n.path, l.line, l.col
    );
    defer stmt.deinit();

    var list: std.ArrayList(Backlink) = .empty;
    var iter = try stmt.iterator(struct {
        path: []const u8,
        title: []const u8,
        stem: []const u8,
        line: i64,
        col: i64,
    }, .{id});
    while (true) {
        const row = (try iter.nextAlloc(arena, .{})) orelse break;
        const title = if (row.title.len > 0) row.title else row.stem;
        try list.append(arena, .{
            .path = row.path,
            .title = title,
            .line = @intCast(row.line),
            .col = @intCast(row.col),
        });
    }
    return list.toOwnedSlice(arena);
}

// -- note interior ----------------------------------------------------------------
//
// One note's own structure, as a content graph — the input to the interior view's
// coarsening/LOD pipeline, the same way `Indexer.Snapshot` is the input to the vault overview.
// Every heading, paragraph, list, code block, blockquote, table, tag, and embed is its own
// `content_graph.Item`, outline-nested under the nearest enclosing heading (or the root).

/// The interior graph of one note: a root standing for the document, its headings and body
/// blocks nested beneath, and any link the note makes to one of its own headings.
///
/// There is always a root, and that is what makes this safe to descend into unconditionally — a
/// note with nothing in it at all is a single item rather than an empty graph, and it doubles as
/// the thing the outline hangs off when a document opens at `###` and never has an `#`, or has
/// content before its first heading.
pub fn noteContentGraph(
    db: *Db,
    arena: std.mem.Allocator,
    note_id: i64,
    title: []const u8,
) !content_graph.ContentGraph {
    var items: std.ArrayList(content_graph.Item) = .empty;
    try items.append(arena, .{ .id = 0, .kind = .root, .level = 0, .line = 0, .text = title, .weight = 1 });

    // -- headings, exactly as before: identity survives edits that only move lines ----------
    const HeadingRow = struct { line: u32, level: u32 };
    var heading_rows: std.ArrayList(HeadingRow) = .empty;
    {
        var stmt = try db.reader().prepare(
            \\SELECT text, text_fold, level, line FROM headings
            \\WHERE note_id = ? ORDER BY line
        );
        defer stmt.deinit();
        var iter = try stmt.iterator(
            struct { text: []const u8, text_fold: []const u8, level: i64, line: i64 },
            .{note_id},
        );
        // Folded text of each heading added so far, so a repeated heading can be given a
        // different occurrence number and so a different id.
        var folds: std.ArrayList([]const u8) = .empty;
        while (true) {
            const row = (try iter.nextAlloc(arena, .{})) orelse break;
            var seen: u32 = 0;
            for (folds.items) |f| {
                if (std.mem.eql(u8, f, row.text_fold)) seen += 1;
            }
            try folds.append(arena, row.text_fold);
            const level: u32 = @intCast(std.math.clamp(row.level, 1, 6));
            const line: u32 = @intCast(@max(row.line, 0));
            try items.append(arena, .{
                .id = sectionId(row.text_fold, seen),
                .kind = .heading,
                .level = level,
                .line = line,
                .text = row.text,
                .weight = 1,
            });
            try heading_rows.append(arena, .{ .line = line, .level = level });
        }
    }
    const heading_count = heading_rows.items.len;

    // -- body blocks --------------------------------------------------------------------
    const BlockRow = struct { kind: i64, line_start: i64, line_end: i64, weight: i64 };
    var block_rows: std.ArrayList(BlockRow) = .empty;
    {
        var stmt = try db.reader().prepare(
            \\SELECT kind, line_start, line_end, weight FROM blocks
            \\WHERE note_id = ? ORDER BY line_start
        );
        defer stmt.deinit();
        var iter = try stmt.iterator(BlockRow, .{note_id});
        while (true) {
            const row = (try iter.nextAlloc(arena, .{})) orelse break;
            try block_rows.append(arena, row);
        }
    }

    // -- tags: captured since day one, consumed here for the first time -------------------
    const TagRow = struct { tag: []const u8, line: i64 };
    var tag_rows: std.ArrayList(TagRow) = .empty;
    {
        var stmt = try db.reader().prepare("SELECT tag, line FROM tags WHERE note_id = ? ORDER BY line");
        defer stmt.deinit();
        var iter = try stmt.iterator(TagRow, .{note_id});
        while (true) {
            const row = (try iter.nextAlloc(arena, .{})) orelse break;
            try tag_rows.append(arena, row);
        }
    }

    // -- embeds: links of kind `.embed`, kept apart from the same-note cross-reference edges
    // below rather than merged into them.
    const EmbedRow = struct { raw: []const u8, alias: []const u8, line: i64 };
    var embed_rows: std.ArrayList(EmbedRow) = .empty;
    {
        var stmt = try db.reader().prepare(
            \\SELECT raw, alias, line FROM links WHERE src_id = ? AND kind = ? ORDER BY line
        );
        defer stmt.deinit();
        var iter = try stmt.iterator(EmbedRow, .{ note_id, @intFromEnum(schema.LinkKind.embed) });
        while (true) {
            const row = (try iter.nextAlloc(arena, .{})) orelse break;
            try embed_rows.append(arena, row);
        }
    }

    // -- merge everything by line, and attach each non-heading item to whichever heading was
    // last seen in that walk (the root, until the first heading). A single forward pass over
    // the line-sorted merge gives both rules for free: a heading's own outline parent still
    // needs the "nearest shallower heading" walk (a `##` under a `###` must skip past it), but
    // a body item just wants whatever heading immediately contains it, at any depth — the same
    // "last heading at or above this line" rule the old per-note cloud used for attributing a
    // link to its section.
    const MergeKind = enum { heading, block, tag, embed };
    const Entry = struct { kind: MergeKind, line: u32, idx: usize };
    var merged: std.ArrayList(Entry) = .empty;
    for (heading_rows.items, 0..) |h, i| try merged.append(arena, .{ .kind = .heading, .line = h.line, .idx = i });
    for (block_rows.items, 0..) |b, i| {
        try merged.append(arena, .{ .kind = .block, .line = @intCast(@max(b.line_start, 0)), .idx = i });
    }
    for (tag_rows.items, 0..) |t, i| {
        try merged.append(arena, .{ .kind = .tag, .line = @intCast(@max(t.line, 0)), .idx = i });
    }
    for (embed_rows.items, 0..) |e, i| {
        try merged.append(arena, .{ .kind = .embed, .line = @intCast(@max(e.line, 0)), .idx = i });
    }
    std.mem.sort(Entry, merged.items, {}, struct {
        fn lessThan(_: void, a: Entry, b: Entry) bool {
            return a.line < b.line;
        }
    }.lessThan);

    var edges: std.ArrayList(content_graph.ItemEdge) = .empty;
    // A running count of items of a given kind under a given parent, so a non-heading item gets
    // an id that survives edits that don't reorder or insert siblings under the same heading —
    // the same imperfection the heading id already accepts for a repeated heading.
    var ordinals: std.AutoHashMapUnmanaged(u64, u32) = .empty;
    var last_heading_item: u32 = 0; // root, until the first heading is seen

    for (merged.items) |m| switch (m.kind) {
        .heading => {
            const item_idx: u32 = @intCast(1 + m.idx);
            const level = heading_rows.items[m.idx].level;
            // Nearest earlier heading with a shallower level, else root.
            var parent: u32 = 0;
            var j = m.idx;
            while (j > 0) {
                j -= 1;
                if (heading_rows.items[j].level < level) {
                    parent = @intCast(1 + j);
                    break;
                }
            }
            try edges.append(arena, .{ .a = parent, .b = item_idx, .kind = .outline });
            last_heading_item = item_idx;
        },
        .block => {
            const b = block_rows.items[m.idx];
            const kind: content_graph.ItemKind = switch (@as(schema.BlockKind, @enumFromInt(b.kind))) {
                .paragraph => .paragraph,
                .list => .list,
                .code => .code,
                .blockquote => .blockquote,
                .table => .table,
            };
            try appendBodyItem(arena, &items, &edges, &ordinals, last_heading_item, .{
                .id = 0,
                .kind = kind,
                .level = 0,
                .line = @intCast(@max(b.line_start, 0)),
                .text = "",
                .weight = @intCast(@max(b.weight, 1)),
            });
        },
        .tag => {
            const t = tag_rows.items[m.idx];
            try appendBodyItem(arena, &items, &edges, &ordinals, last_heading_item, .{
                .id = 0,
                .kind = .tag,
                .level = 0,
                .line = @intCast(@max(t.line, 0)),
                .text = t.tag,
                .weight = 1,
            });
        },
        .embed => {
            const e = embed_rows.items[m.idx];
            try appendBodyItem(arena, &items, &edges, &ordinals, last_heading_item, .{
                .id = 0,
                .kind = .embed,
                .level = 0,
                .line = @intCast(@max(e.line, 0)),
                .text = if (e.alias.len > 0) e.alias else e.raw,
                .weight = 1,
            });
        },
    };

    // Same-note wikilinks: an explicit `[[This Note#Heading]]` connects two of this note's own
    // headings. Only a self-link (dst_id == note_id) has both ends inside this graph.
    {
        var stmt = try db.reader().prepare(
            \\SELECT line, heading FROM links
            \\WHERE src_id = ? AND dst_id = ? AND heading <> ''
            \\ORDER BY line
        );
        defer stmt.deinit();
        var iter = try stmt.iterator(struct { line: i64, heading: []const u8 }, .{ note_id, note_id });
        while (true) {
            const row = (try iter.nextAlloc(arena, .{})) orelse break;
            const from = sectionAtLine(items.items[0 .. 1 + heading_count], @max(row.line, 0));
            const to = sectionByHeading(items.items[0 .. 1 + heading_count], row.heading) orelse continue;
            if (to == from) continue;
            try edges.append(arena, .{ .a = @intCast(from), .b = @intCast(to), .kind = .link });
        }
    }

    return .{
        .items = try items.toOwnedSlice(arena),
        .edges = try edges.toOwnedSlice(arena),
    };
}

/// Appends one non-heading body item (block/tag/embed), gives it an ordinal-derived id, and
/// wires its outline edge to `parent`. Shared by all three kinds in `noteContentGraph`'s merge
/// loop so the id scheme and edge shape can't drift between them.
fn appendBodyItem(
    arena: std.mem.Allocator,
    items: *std.ArrayList(content_graph.Item),
    edges: *std.ArrayList(content_graph.ItemEdge),
    ordinals: *std.AutoHashMapUnmanaged(u64, u32),
    parent: u32,
    item: content_graph.Item,
) !void {
    const parent_id = items.items[parent].id;
    const key = ordinalKey(parent_id, item.kind);
    const gop = try ordinals.getOrPut(arena, key);
    if (!gop.found_existing) gop.value_ptr.* = 0;
    const ordinal = gop.value_ptr.*;
    gop.value_ptr.* += 1;

    var stamped = item;
    stamped.id = contentItemId(item.kind, parent_id, ordinal);
    const item_idx: u32 = @intCast(items.items.len);
    try items.append(arena, stamped);
    try edges.append(arena, .{ .a = parent, .b = item_idx, .kind = .outline });
}

fn ordinalKey(parent_id: i64, kind: content_graph.ItemKind) u64 {
    return (@as(u64, @bitCast(parent_id)) *% 1099511628211) ^ @as(u64, @intFromEnum(kind));
}

/// Identity for a non-heading item: unstable across edits that reorder or insert siblings under
/// the same heading, stable otherwise — see `content_graph.Item.id`'s doc comment.
fn contentItemId(kind: content_graph.ItemKind, parent_id: i64, ordinal: u32) i64 {
    var h = std.hash.Wyhash.init(ordinal);
    h.update(std.mem.asBytes(&parent_id));
    h.update(&[_]u8{@intFromEnum(kind)});
    const v: i64 = @intCast(h.final() & 0x7fff_ffff_ffff_ffff);
    return if (v == 0) 1 else v;
}

/// Identity for a heading, from its folded text plus how many identical headings precede it.
/// Never 0 — that is reserved for the root.
///
/// Derived from the heading *text* and not its line, because line numbers are the one thing
/// that reliably changes for no reason: typing a word into the first paragraph shifts every
/// heading below it, and keyed on lines the whole graph would lose its state on every
/// keystroke. The occurrence ordinal disambiguates a note that repeats a heading.
fn sectionId(text_fold: []const u8, occurrence: u32) i64 {
    var h = std.hash.Wyhash.init(occurrence);
    h.update(text_fold);
    // Fold to 63 bits so the value is always positive, then step off zero.
    const v: i64 = @intCast(h.final() & 0x7fff_ffff_ffff_ffff);
    return if (v == 0) 1 else v;
}

/// Index, into a root+headings-only slice (`items[0 .. 1 + heading_count]`), of the heading
/// containing `line` — the last heading at or above it, else the root (index 0).
fn sectionAtLine(root_and_headings: []const content_graph.Item, line: i64) usize {
    var best: usize = 0;
    for (root_and_headings[1..], 1..) |n, i| {
        if (@as(i64, n.line) > line) break;
        best = i;
    }
    return best;
}

fn sectionByHeading(root_and_headings: []const content_graph.Item, heading: []const u8) ?usize {
    var buf: [512]u8 = undefined;
    if (heading.len > buf.len) return null;
    const want = foldInto(&buf, heading);
    for (root_and_headings[1..], 1..) |n, i| {
        var nb: [512]u8 = undefined;
        if (n.text.len > nb.len) continue;
        if (std.mem.eql(u8, foldInto(&nb, n.text), want)) return i;
    }
    return null;
}

pub const CompleteRow = struct {
    target: []const u8,
    path: []const u8,
    title: []const u8,
};

/// Prefix match for `complete`. Returns up to `limit` notes whose stem/alias starts with `prefix`
/// (ASCII-folded).
pub fn complete(
    db: *Db,
    arena: std.mem.Allocator,
    prefix: []const u8,
    limit: usize,
) ![]CompleteRow {
    if (limit == 0) return &.{};
    var fold_buf: [512]u8 = undefined;
    if (prefix.len > fold_buf.len) return &.{};
    const folded = foldInto(&fold_buf, prefix);
    const like = try std.fmt.allocPrint(arena, "{s}%", .{folded});

    var list: std.ArrayList(CompleteRow) = .empty;

    {
        var stmt = try db.reader().prepare(
            \\SELECT stem, path, title FROM notes
            \\WHERE phantom = 0 AND stem_fold LIKE ?
            \\ORDER BY stem LIMIT ?
        );
        defer stmt.deinit();
        var iter = try stmt.iterator(
            struct { stem: []const u8, path: []const u8, title: []const u8 },
            .{ like, @as(i64, @intCast(limit)) },
        );
        while (true) {
            const row = (try iter.nextAlloc(arena, .{})) orelse break;
            try list.append(arena, .{
                .target = row.stem,
                .path = row.path,
                .title = if (row.title.len > 0) row.title else row.stem,
            });
        }
    }
    if (list.items.len < limit) {
        var stmt = try db.reader().prepare(
            \\SELECT a.alias, n.path, n.title, n.stem FROM aliases a
            \\JOIN notes n ON n.id = a.note_id
            \\WHERE n.phantom = 0 AND a.alias_fold LIKE ?
            \\ORDER BY a.alias LIMIT ?
        );
        defer stmt.deinit();
        const remain: i64 = @intCast(limit - list.items.len);
        var iter = try stmt.iterator(
            struct { alias: []const u8, path: []const u8, title: []const u8, stem: []const u8 },
            .{ like, remain },
        );
        while (true) {
            const row = (try iter.nextAlloc(arena, .{})) orelse break;
            try list.append(arena, .{
                .target = row.alias,
                .path = row.path,
                .title = if (row.title.len > 0) row.title else row.stem,
            });
        }
    }
    return list.toOwnedSlice(arena);
}

/// Drop phantoms nothing links to any more.
///
/// A phantom only exists to stand in for "a link points here but the file doesn't exist", so
/// once its last inbound link is gone it has no reason to. Nothing else deletes them: writing
/// a note replaces its links wholesale, which silently orphans whatever phantoms the old ones
/// had materialized, and the non-note purge only rejects targets that aren't note-like at all.
/// So editing `[[test]]` into `[[testi]]` left a permanent `test` node behind — every
/// intermediate state of a link you typed became its own floating node in the graph, and
/// clicking one offered to create a file for a link that no longer existed.
///
/// `NOT EXISTS` rather than `NOT IN` only as insurance: `links.dst_id` is `NOT NULL` today, so
/// both forms behave identically, but `NOT IN` would silently match nothing (purging none of
/// them) if that constraint were ever relaxed.
/// The one writer in this file, so `db.conn` rather than `db.reader()` — the read-only handle
/// would reject it. Called from the indexer's worker at the end of a relink.
pub fn purgeOrphanPhantoms(db: *Db) !void {
    try db.conn.exec(
        \\DELETE FROM notes WHERE phantom = 1
        \\  AND NOT EXISTS (SELECT 1 FROM links WHERE links.dst_id = notes.id)
    , .{}, .{});
}

/// Longest vault-relative path the index carries. Matches `resolve.max_path_len`: a path longer
/// than that could not be named by a link anyway.
pub const max_rel_path: usize = resolve.max_path_len;

/// Vault-relative form of `abs`, written into `buf` and normalized to `/` separators.
///
/// The normalization is why this copies instead of returning a slice of `abs`. Every consumer of
/// a vault-relative path assumes `/`: `stemOf` and `resolve.dirOf` split on it, `resolve`'s
/// `by_path` index is keyed on it, `relpath` writes links with it, and `fold`'s folder chain
/// reads it. On Windows `std.fs.path.join` produces `\`, so leaving the separator alone stored
/// `notes\Setup.md` in the `path` column — whose stem is then the whole string `notes\Setup`.
/// `[[Setup]]` matched nothing, every link into a subfolder materialized a phantom instead of
/// resolving, and clicking that phantom in the graph created a new empty note rather than opening
/// the one that was already there.
///
/// `\` is only translated on Windows: on a POSIX filesystem it is an ordinary filename byte, and
/// rewriting it would invent a directory that isn't there.
///
/// The prefix match is case- and separator-insensitive on Windows, because the paths being
/// compared arrive from three places that do not agree on either — the host's open documents, the
/// filesystem watcher, and our own directory walk.
pub fn vaultRelative(vault: []const u8, abs: []const u8, buf: []u8) ?[]const u8 {
    if (!hasPathPrefix(abs, vault)) return null;
    const rest = std.mem.trimStart(u8, abs[vault.len..], sep_any);
    if (rest.len == 0 or rest.len > buf.len) return null;
    const out = buf[0..rest.len];
    @memcpy(out, rest);
    if (builtin.os.tag == .windows) {
        std.mem.replaceScalar(u8, out, std.fs.path.sep_windows, std.fs.path.sep_posix);
    }
    return out;
}

/// Both separators, for the trims and scans that have to accept a path as the OS spelled it.
/// `std.fs.path.isSep` is the native-only form of the same question and is wrong for us in both
/// directions: it rejects `\` on POSIX (right) but also on a Windows path we were handed by the
/// host, and there is no `isSepWindows` to ask instead.
const sep_any = &[_]u8{ std.fs.path.sep_posix, std.fs.path.sep_windows };

fn hasPathPrefix(abs: []const u8, vault: []const u8) bool {
    if (abs.len < vault.len) return false;
    if (std.mem.eql(u8, abs[0..vault.len], vault)) return true;
    if (builtin.os.tag != .windows) return false;
    for (abs[0..vault.len], vault) |a, v| {
        const an = if (a == std.fs.path.sep_windows) std.fs.path.sep_posix else std.ascii.toLower(a);
        const vn = if (v == std.fs.path.sep_windows) std.fs.path.sep_posix else std.ascii.toLower(v);
        if (an != vn) return false;
    }
    return true;
}

pub fn isMarkdownPath(name: []const u8) bool {
    return std.ascii.endsWithIgnoreCase(name, ".md") or
        std.ascii.endsWithIgnoreCase(name, ".markdown");
}

/// Basename with `.md` / `.markdown` stripped. Anything else is returned as the basename.
pub fn stemOf(path: []const u8) []const u8 {
    // Not `std.fs.path.stem`: that strips whatever follows the last dot, so `foo.zig` would come
    // back as `foo` and a link to a source file would look like a note name. Only the two
    // markdown extensions are an extension as far as the index is concerned.
    const base = std.fs.path.basenamePosix(path);
    if (std.ascii.endsWithIgnoreCase(base, ".markdown")) return base[0 .. base.len - ".markdown".len];
    if (std.ascii.endsWithIgnoreCase(base, ".md")) return base[0 .. base.len - ".md".len];
    return base;
}

/// Lowercase `s` into `buf`. Caller must pass `buf.len >= s.len`.
pub fn foldInto(buf: []u8, s: []const u8) []const u8 {
    for (s, 0..) |c, i| buf[i] = std.ascii.toLower(c);
    return buf[0..s.len];
}

/// Extensions the index tracks as embeddable media, so `![[diagram.png]]` can resolve to a
/// file and the completer can offer it. Scoped to what a markdown preview can actually render
/// inline — an index of *every* non-note file would be most of a source repo, and a completion
/// list nobody can find anything in.
pub const media_extensions = [_][]const u8{
    ".png", ".jpg", ".jpeg", ".gif", ".webp", ".svg", ".bmp", ".avif",
};

pub fn isMediaPath(name: []const u8) bool {
    for (media_extensions) |ext| {
        if (std.ascii.endsWithIgnoreCase(name, ext)) return true;
    }
    return false;
}

/// Media rows whose name starts with `prefix` (folded), for `![[…]]` completion. Ordered by
/// name so the list is stable between keystrokes.
pub fn completeMedia(db: *Db, arena: std.mem.Allocator, prefix: []const u8, limit: usize) ![]CompleteRow {
    if (limit == 0) return &.{};
    var fold_buf: [resolve.max_path_len]u8 = undefined;
    if (prefix.len > fold_buf.len) return &.{};
    const folded = foldInto(fold_buf[0..prefix.len], prefix);
    const pattern = try std.fmt.allocPrint(arena, "{s}%", .{folded});

    var list: std.ArrayList(CompleteRow) = .empty;
    var stmt = try db.reader().prepare(
        \\SELECT path, name_fold FROM media
        \\WHERE name_fold LIKE ? OR stem_fold LIKE ?
        \\ORDER BY name_fold LIMIT ?
    );
    defer stmt.deinit();
    var iter = try stmt.iterator(
        struct { path: []const u8, name_fold: []const u8 },
        .{ pattern, pattern, @as(i64, @intCast(limit)) },
    );
    while (true) {
        const row = (try iter.nextAlloc(arena, .{})) orelse break;
        const name = std.fs.path.basenamePosix(row.path);
        // Basename (with extension) is both the typed target and the image alt text — same
        // default the converter uses when an embed has no `|alias`.
        try list.append(arena, .{ .target = name, .path = row.path, .title = name });
    }
    return list.toOwnedSlice(arena);
}

/// Media files as resolution candidates. Kept a separate list from `loadCandidates` rather
/// than merged with a kind flag: an embed resolves against media and a plain wikilink against
/// notes, so two lists means no precedence rule to get wrong (and `[[Target]]` can never
/// silently land on `Target.png` instead of `Target.md`).
pub fn loadMediaCandidates(db: *Db, arena: std.mem.Allocator) ![]resolve.Candidate {
    return loadMediaCandidatesOn(db.reader(), arena);
}

/// `loadMediaCandidates` against an explicit connection — see `loadCandidatesOn`.
pub fn loadMediaCandidatesOn(conn: *sqlite.Db, arena: std.mem.Allocator) ![]resolve.Candidate {
    var list: std.ArrayList(resolve.Candidate) = .empty;
    var stmt = try conn.prepare("SELECT path, stem FROM media");
    defer stmt.deinit();
    var iter = try stmt.iterator(struct { path: []const u8, stem: []const u8 }, .{});
    while (true) {
        const row = (try iter.nextAlloc(arena, .{})) orelse break;
        // Two rows per file, one per spelling — the same shape aliases use for notes. A
        // resolver pass matches `Candidate.stem`, and both `![[diagram]]` and
        // `![[diagram.png]]` should find the image (unlike a note, the extension is not
        // stripped from a media target, so the bare stem would never match on its own).
        try list.append(arena, .{ .path = row.path, .stem = row.stem });
        const name = std.fs.path.basenamePosix(row.path);
        if (!std.mem.eql(u8, name, row.stem)) {
            try list.append(arena, .{ .path = row.path, .stem = name });
        }
    }
    return list.toOwnedSlice(arena);
}

const testing = std.testing;

test "vaultRelative strips the vault prefix" {
    var buf: [max_rel_path]u8 = undefined;
    try testing.expectEqualStrings("a/b.md", vaultRelative("/vault", "/vault/a/b.md", &buf).?);
    try testing.expectEqualStrings("a/b.md", vaultRelative("/vault/", "/vault/a/b.md", &buf).?);
    try testing.expect(vaultRelative("/vault", "/other/a.md", &buf) == null);
    try testing.expect(vaultRelative("/vault", "/vault", &buf) == null);
    // The result is a copy, not a view into `abs` — that is what lets Windows rewrite `\`.
    const rel = vaultRelative("/vault", "/vault/a/b.md", &buf).?;
    try testing.expect(rel.ptr == &buf);
    // Longer than the buffer is refused rather than truncated into a different note's path.
    var tiny: [4]u8 = undefined;
    try testing.expect(vaultRelative("/vault", "/vault/a/b.md", &tiny) == null);
}

test "isMarkdownPath accepts md and markdown, case-insensitive" {
    try testing.expect(isMarkdownPath("Note.md"));
    try testing.expect(isMarkdownPath("Note.markdown"));
    try testing.expect(isMarkdownPath("Note.MD"));
    try testing.expect(!isMarkdownPath("Note.png"));
    try testing.expect(!isMarkdownPath("Note.mdx"));
}

test "stemOf drops the markdown extension" {
    try testing.expectEqualStrings("Note", stemOf("a/Note.md"));
    try testing.expectEqualStrings("Note", stemOf("Note.markdown"));
    try testing.expectEqualStrings("Note", stemOf("Note"));
}

test "isMediaPath is the embeddable-image set, not notes" {
    try testing.expect(isMediaPath("diagram.png"));
    try testing.expect(isMediaPath("Photo.JPEG"));
    try testing.expect(!isMediaPath("Note.md"));
}

test "foldInto lowercases in place" {
    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("heading", foldInto(&buf, "Heading"));
}
