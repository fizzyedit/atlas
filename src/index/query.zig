//! Read-side helpers over the index DB — shared by the wikilink service and the backlinks UI.
//!
//! All of these are UI-thread / caller-thread SELECTs. The indexer is the only writer; WAL +
//! sqlite's Serialized threading mode make concurrent reads safe against in-flight commits.
const std = @import("std");
const Db = @import("Db.zig");
const resolve = @import("resolve.zig");

pub const Backlink = struct {
    /// Vault-relative path of the source note.
    path: []const u8,
    title: []const u8,
    line: u32,
    col: u32,
    context: []const u8,
};

/// Load every real note (+ one Candidate per alias) for `resolve.resolve`.
pub fn loadCandidates(db: *Db, arena: std.mem.Allocator) ![]resolve.Candidate {
    var list: std.ArrayList(resolve.Candidate) = .empty;

    {
        var stmt = try db.conn.prepare("SELECT path, stem FROM notes WHERE phantom = 0");
        defer stmt.deinit();
        var iter = try stmt.iterator(struct { path: []const u8, stem: []const u8 }, .{});
        while (true) {
            const row = (try iter.nextAlloc(arena, .{})) orelse break;
            try list.append(arena, .{ .path = row.path, .stem = row.stem });
        }
    }
    {
        var stmt = try db.conn.prepare(
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

pub fn noteIdForPath(db: *Db, path: []const u8) !?i64 {
    return db.conn.one(i64, "SELECT id FROM notes WHERE path = ? AND phantom = 0", .{}, .{path});
}

pub fn noteTitle(db: *Db, arena: std.mem.Allocator, path: []const u8) ![]const u8 {
    const row = try db.conn.oneAlloc(
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
    const line = try db.conn.one(
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
    var stmt = try db.conn.prepare(
        \\SELECT n.path, n.title, n.stem, l.line, l.col, l.context
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
        context: []const u8,
    }, .{id});
    while (true) {
        const row = (try iter.nextAlloc(arena, .{})) orelse break;
        const title = if (row.title.len > 0) row.title else row.stem;
        try list.append(arena, .{
            .path = row.path,
            .title = title,
            .line = @intCast(row.line),
            .col = @intCast(row.col),
            .context = row.context,
        });
    }
    return list.toOwnedSlice(arena);
}

// -- note interior ----------------------------------------------------------------
//
// One note's own structure, as a graph — the input to the graph panel's note-level cloud, the
// same way `Indexer.Snapshot` is the input to the overview. Deliberately the same shape of data
// (nodes with a degree, undirected edges between indices) so the layout can be handed either.

/// A section of one document: its heading, and everything under it up to the next heading of the
/// same or shallower depth.
pub const SectionNode = struct {
    /// Stable identity within the note, for carrying animation state across a reindex.
    ///
    /// Derived from the heading *text* and not its line, because line numbers are the one thing
    /// that reliably changes for no reason: typing a word into the first paragraph shifts every
    /// heading below it, and keyed on lines the whole cloud would lose its state on every
    /// keystroke. The occurrence ordinal disambiguates a note that repeats a heading.
    id: i64,
    /// 0-based line of the heading, for scrolling the editor to it. The root section is line 0.
    line: u32,
    text: []const u8,
    /// ATX depth 1–6, or 0 for the synthetic root that stands for the document itself.
    level: u32,
    /// Links leaving this section. Drives node radius the way `degree` does in the overview —
    /// a section that reaches out to a lot of the vault should read as a heavier body.
    links: u32,
    /// Distinct neighbours inside this note: outline parent/children, plus self-link partners.
    degree: u32,
};

/// Undirected, by index into `NoteSnapshot.nodes`.
pub const SectionEdge = struct {
    a: u32,
    b: u32,
    /// `.outline` is the document's own nesting; `.link` is an explicit `[[This Note#Heading]]`.
    /// Kept apart so the panel can draw a structural edge differently from a real link.
    kind: enum { outline, link },
};

pub const NoteSnapshot = struct {
    nodes: []const SectionNode = &.{},
    edges: []const SectionEdge = &.{},
};

/// The interior graph of one note: a root standing for the document, its headings nested beneath,
/// and any link the note makes to one of its own headings.
///
/// There is always a root, and that is what makes this safe to descend into unconditionally — a
/// note with no headings at all is a single node rather than an empty cloud, and it doubles as
/// the thing the outline hangs off when a document opens at `###` and never has an `#`.
pub fn noteSnapshot(db: *Db, arena: std.mem.Allocator, note_id: i64, title: []const u8) !NoteSnapshot {
    var nodes: std.ArrayList(SectionNode) = .empty;
    try nodes.append(arena, .{
        .id = 0,
        .line = 0,
        .text = title,
        .level = 0,
        .links = 0,
        .degree = 0,
    });

    {
        var stmt = try db.conn.prepare(
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
            try nodes.append(arena, .{
                .id = sectionId(row.text_fold, seen),
                .line = @intCast(@max(row.line, 0)),
                .text = row.text,
                .level = @intCast(std.math.clamp(row.level, 1, 6)),
                .links = 0,
                .degree = 0,
            });
        }
    }

    var edges: std.ArrayList(SectionEdge) = .empty;

    // Outline nesting: each heading hangs off the nearest section above it that is shallower.
    // The root is level 0, so this always terminates — a note that opens at `###` still parents
    // to the document rather than floating.
    for (nodes.items[1..], 1..) |h, i| {
        var j = i;
        const parent = while (j > 0) {
            j -= 1;
            if (nodes.items[j].level < h.level) break j;
        } else 0;
        try edges.append(arena, .{ .a = @intCast(parent), .b = @intCast(i), .kind = .outline });
    }

    // Links leaving the note, attributed to the section they were written in — the last heading
    // at or above the link's line. A link above the first heading belongs to the root.
    {
        var stmt = try db.conn.prepare(
            \\SELECT line, dst_id, heading FROM links WHERE src_id = ? ORDER BY line
        );
        defer stmt.deinit();
        var iter = try stmt.iterator(
            struct { line: i64, dst_id: i64, heading: []const u8 },
            .{note_id},
        );
        while (true) {
            const row = (try iter.nextAlloc(arena, .{})) orelse break;
            const from = sectionAtLine(nodes.items, @max(row.line, 0));
            nodes.items[from].links += 1;
            // Only a link back into this same note has both ends in this cloud. Everything else
            // leaves it, and at this level there is nothing on the far end to draw to.
            if (row.dst_id != note_id or row.heading.len == 0) continue;
            const to = sectionByHeading(nodes.items, row.heading) orelse continue;
            if (to == from) continue;
            try edges.append(arena, .{ .a = @intCast(from), .b = @intCast(to), .kind = .link });
        }
    }

    for (edges.items) |e| {
        nodes.items[e.a].degree += 1;
        nodes.items[e.b].degree += 1;
    }

    return .{
        .nodes = try nodes.toOwnedSlice(arena),
        .edges = try edges.toOwnedSlice(arena),
    };
}

/// Identity for a section, from its folded heading text plus how many identical headings precede
/// it. Never 0 — that is reserved for the root.
fn sectionId(text_fold: []const u8, occurrence: u32) i64 {
    var h = std.hash.Wyhash.init(occurrence);
    h.update(text_fold);
    // Fold to 63 bits so the value is always positive, then step off zero.
    const v: i64 = @intCast(h.final() & 0x7fff_ffff_ffff_ffff);
    return if (v == 0) 1 else v;
}

/// Index of the section containing `line` — the last heading at or above it, else the root.
fn sectionAtLine(nodes: []const SectionNode, line: i64) usize {
    var best: usize = 0;
    for (nodes[1..], 1..) |n, i| {
        if (@as(i64, n.line) > line) break;
        best = i;
    }
    return best;
}

fn sectionByHeading(nodes: []const SectionNode, heading: []const u8) ?usize {
    var buf: [512]u8 = undefined;
    if (heading.len > buf.len) return null;
    const want = foldInto(&buf, heading);
    for (nodes[1..], 1..) |n, i| {
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
        var stmt = try db.conn.prepare(
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
        var stmt = try db.conn.prepare(
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
pub fn purgeOrphanPhantoms(db: *Db) !void {
    try db.conn.exec(
        \\DELETE FROM notes WHERE phantom = 1
        \\  AND NOT EXISTS (SELECT 1 FROM links WHERE links.dst_id = notes.id)
    , .{}, .{});
}

pub fn vaultRelative(vault: []const u8, abs: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, abs, vault)) return null;
    var rest = abs[vault.len..];
    while (rest.len > 0 and (rest[0] == '/' or rest[0] == '\\')) rest = rest[1..];
    if (rest.len == 0) return null;
    return rest;
}

pub fn isMarkdownPath(name: []const u8) bool {
    return std.ascii.endsWithIgnoreCase(name, ".md") or
        std.ascii.endsWithIgnoreCase(name, ".markdown");
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
    var stmt = try db.conn.prepare(
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
        const name = if (std.mem.lastIndexOfScalar(u8, row.path, '/')) |s| row.path[s + 1 ..] else row.path;
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
    var list: std.ArrayList(resolve.Candidate) = .empty;
    var stmt = try db.conn.prepare("SELECT path, stem FROM media");
    defer stmt.deinit();
    var iter = try stmt.iterator(struct { path: []const u8, stem: []const u8 }, .{});
    while (true) {
        const row = (try iter.nextAlloc(arena, .{})) orelse break;
        // Two rows per file, one per spelling — the same shape aliases use for notes. A
        // resolver pass matches `Candidate.stem`, and both `![[diagram]]` and
        // `![[diagram.png]]` should find the image (unlike a note, the extension is not
        // stripped from a media target, so the bare stem would never match on its own).
        try list.append(arena, .{ .path = row.path, .stem = row.stem });
        const name = if (std.mem.lastIndexOfScalar(u8, row.path, '/')) |s| row.path[s + 1 ..] else row.path;
        if (!std.mem.eql(u8, name, row.stem)) {
            try list.append(arena, .{ .path = row.path, .stem = name });
        }
    }
    return list.toOwnedSlice(arena);
}

fn foldInto(buf: []u8, s: []const u8) []const u8 {
    for (s, 0..) |c, i| buf[i] = std.ascii.toLower(c);
    return buf[0..s.len];
}
