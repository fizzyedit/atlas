//! Read-side helpers over the in-memory `Index`, plus the shared path helpers (`vaultRelative`,
//! `isMarkdownPath`, `stemOf`, `foldInto`) used by the indexer, watcher, and services.
//!
//! Every reader here is UI-thread / caller-thread and takes the index lock for the length of
//! one function, copying what it returns into the caller's arena — nothing handed back points
//! into the index. The indexer is the only writer.
const std = @import("std");
const builtin = @import("builtin");
const Index = @import("Index.zig");
const resolve = @import("resolve.zig");
const relpath = @import("relpath.zig");
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
    /// The link as it was written: the target text of `[[Target|alias]]`, or the label of a
    /// markdown link. Carried so the backlinks filter has something on the *mention* to match —
    /// without it the only searchable text is the source note's path and title, which is not
    /// what someone typing in that box is looking for.
    raw: []const u8 = "",
    /// The `|alias` of a piped wikilink, empty otherwise. Searched alongside `raw`, since the
    /// alias is the text actually visible in the source note.
    alias: []const u8 = "",
    /// Filled by the *view* when a row is drawn, not by the query — see `backlinks.contextFor`.
    /// Empty until then, which is why it is deliberately **not** part of what the filter
    /// searches: a row's context exists only once it has been on screen, so filtering on it
    /// would match a different set depending on how far you had scrolled.
    context: []const u8 = "",
};

/// Load every real note (+ one Candidate per alias) for `resolve.resolve`.
///
/// Prefer *not* calling this on a hot UI path: on a 286,547-note vault it is a walk of every
/// note and alias. The indexer builds the same list on its worker as part of publishing and
/// hands it over (`Indexer.takeCandidates`); this remains the fallback for callers with no
/// indexer behind them (tests, a synthetic vault, a publish that never happened).
pub fn loadCandidates(index: *Index, arena: std.mem.Allocator) ![]resolve.Candidate {
    index.lock();
    defer index.unlock();
    var list: std.ArrayList(resolve.Candidate) = .empty;
    try list.ensureTotalCapacity(arena, index.real_count);
    var it = index.iterate(false);
    while (it.next()) |n| {
        const path = try arena.dupe(u8, n.path);
        const stem = try arena.dupe(u8, n.stem);
        try list.append(arena, .{ .path = path, .stem = stem });
        for (n.aliases) |al| try list.append(arena, .{ .path = path, .stem = stem, .alias = try arena.dupe(u8, al.alias) });
    }
    return list.toOwnedSlice(arena);
}

pub fn noteIdForPath(index: *Index, path: []const u8) !?i64 {
    index.lock();
    defer index.unlock();
    return index.idByPath(path);
}

pub fn noteTitle(index: *Index, arena: std.mem.Allocator, path: []const u8) ![]const u8 {
    index.lock();
    defer index.unlock();
    const n = index.byPath(path) orelse return "";
    return arena.dupe(u8, n.shownTitle());
}

/// 0-based line of a heading in `path`, or 0 when missing (not an error).
pub fn headingLine(index: *Index, path: []const u8, heading: []const u8) !u32 {
    if (heading.len == 0) return 0;
    var fold_buf: [512]u8 = undefined;
    if (heading.len > fold_buf.len) return 0;
    const folded = foldInto(&fold_buf, heading);
    index.lock();
    defer index.unlock();
    const n = index.byPath(path) orelse return 0;
    for (n.headings) |h| if (std.mem.eql(u8, h.text_fold, folded)) return h.line;
    // Not the heading as written — try it as a slug (`#habitat-and-range`), the form a portable
    // markdown link into a section carries. One pass over this note's headings, only on the miss.
    for (n.headings) |h| {
        var text_fold: [512]u8 = undefined;
        if (h.text.len > text_fold.len) continue;
        if (headingMatches(h.text, folded, &text_fold)) return h.line;
    }
    return 0;
}

/// Inbound edges for `dst_path`, ordered by source path then line — ready to group in the UI.
pub fn backlinksFor(index: *Index, arena: std.mem.Allocator, dst_path: []const u8) ![]Backlink {
    index.lock();
    defer index.unlock();
    const dst = index.byPath(dst_path) orelse return &.{};
    var list: std.ArrayList(Backlink) = .empty;
    var srcs = dst.inbound.keyIterator();
    while (srcs.next()) |src_id| {
        const src = index.live(src_id.*) orelse continue;
        if (src.phantom) continue;
        const path = try arena.dupe(u8, src.path);
        const title = try arena.dupe(u8, src.shownTitle());
        for (src.links) |l| {
            if (l.dst_id != dst.id) continue;
            try list.append(arena, .{
                .path = path,
                .title = title,
                .line = l.line,
                .col = l.col,
                .raw = try arena.dupe(u8, l.raw),
                .alias = try arena.dupe(u8, l.alias),
            });
        }
    }
    std.mem.sort(Backlink, list.items, {}, struct {
        fn lessThan(_: void, a: Backlink, b: Backlink) bool {
            return switch (std.mem.order(u8, a.path, b.path)) {
                .lt => true,
                .gt => false,
                .eq => if (a.line != b.line) a.line < b.line else a.col < b.col,
            };
        }
    }.lessThan);
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
    index: *Index,
    arena: std.mem.Allocator,
    note_id: i64,
    title: []const u8,
) !content_graph.ContentGraph {
    var items: std.ArrayList(content_graph.Item) = .empty;
    try items.append(arena, .{ .id = 0, .kind = .root, .level = 0, .line = 0, .text = title, .weight = 1 });

    // Everything this note's interior is built from, copied out under the lock — the rest of
    // this function is pure over the copies.
    const HeadingRow = struct { line: u32, level: u32 };
    var heading_rows: std.ArrayList(HeadingRow) = .empty;
    const BlockRow = struct { kind: i64, line_start: i64, line_end: i64, weight: i64 };
    var block_rows: std.ArrayList(BlockRow) = .empty;
    const TagRow = struct { tag: []const u8, line: i64 };
    var tag_rows: std.ArrayList(TagRow) = .empty;
    const EmbedRow = struct { raw: []const u8, alias: []const u8, line: i64 };
    var embed_rows: std.ArrayList(EmbedRow) = .empty;
    const SelfLink = struct { line: i64, heading: []const u8 };
    var self_links: std.ArrayList(SelfLink) = .empty;
    {
        index.lock();
        defer index.unlock();
        const n = index.live(note_id) orelse return .{ .items = try items.toOwnedSlice(arena), .edges = &.{} };

        // -- headings: identity survives edits that only move lines ----------------------
        // Folded text of each heading added so far, so a repeated heading can be given a
        // different occurrence number and so a different id.
        var folds: std.ArrayList([]const u8) = .empty;
        for (n.headings) |h| {
            var seen: u32 = 0;
            for (folds.items) |f| {
                if (std.mem.eql(u8, f, h.text_fold)) seen += 1;
            }
            const text_fold = try arena.dupe(u8, h.text_fold);
            try folds.append(arena, text_fold);
            const level: u32 = @intCast(std.math.clamp(h.level, 1, 6));
            try items.append(arena, .{
                .id = sectionId(text_fold, seen),
                .kind = .heading,
                .level = level,
                .line = h.line,
                .text = try arena.dupe(u8, h.text),
                .weight = 1,
            });
            try heading_rows.append(arena, .{ .line = h.line, .level = level });
        }
        for (n.blocks) |b| try block_rows.append(arena, .{ .kind = @intFromEnum(b.kind), .line_start = b.line_start, .line_end = b.line_end, .weight = b.weight });
        for (n.tags) |t| try tag_rows.append(arena, .{ .tag = try arena.dupe(u8, t.tag), .line = t.line });
        // Embeds are kept apart from the same-note cross-reference edges below rather than
        // merged into them.
        for (n.links) |l| {
            if (l.kind == .embed) try embed_rows.append(arena, .{ .raw = try arena.dupe(u8, l.raw), .alias = try arena.dupe(u8, l.alias), .line = l.line });
            // Only a self-link (dst == this note) has both ends inside this graph.
            if (l.dst_id == note_id and l.heading.len != 0) try self_links.append(arena, .{ .line = l.line, .heading = try arena.dupe(u8, l.heading) });
        }
    }
    const heading_count = heading_rows.items.len;

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
    // headings.
    for (self_links.items) |row| {
        const from = sectionAtLine(items.items[0 .. 1 + heading_count], @max(row.line, 0));
        const to = sectionByHeading(items.items[0 .. 1 + heading_count], row.heading) orelse continue;
        if (to == from) continue;
        try edges.append(arena, .{ .a = @intCast(from), .b = @intCast(to), .kind = .link });
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
        if (headingMatches(n.text, want, &nb)) return i;
    }
    return null;
}

/// Does `heading_text` answer to the folded anchor `want`?
///
/// Two spellings of the same anchor have to match: a wikilink carries the heading *as written*
/// (`#Habitat and Range`), a portable markdown link carries its GitHub slug
/// (`#habitat-and-range`). Comparing folded text first and the slug second accepts both without
/// the caller having to know which syntax the link came from — and without the slug form being
/// able to match a *different* heading, since the slug is derived from this heading's own text.
fn headingMatches(heading_text: []const u8, want: []const u8, fold_buf: []u8) bool {
    if (std.mem.eql(u8, foldInto(fold_buf[0..heading_text.len], heading_text), want)) return true;
    var slug_buf: [512]u8 = undefined;
    return std.mem.eql(u8, relpath.headingAnchor(heading_text, &slug_buf), want);
}

pub const CompleteRow = struct {
    target: []const u8,
    path: []const u8,
    title: []const u8,
};

/// Exclusive upper bound of the byte range holding every string that starts with `p`.
///
/// `stem_fold LIKE 'ab%'` cannot use an index — sqlite's LIKE is case-insensitive by default,
/// so the optimizer refuses the BINARY-collated `notes_stem_fold` and falls back to scanning
/// every note, then sorts the survivors in a temp b-tree. On Simple English Wikipedia that is
/// 286k rows per keystroke: ~270 ms of frozen UI, and constant in the prefix, so typing more
/// never made it faster. The same match written as `stem_fold >= 'ab' AND stem_fold < 'ac'` is
/// an index seek that stops after `limit` rows, because the values are pre-folded so a byte
/// range *is* the case-folded prefix set. It also stops `%` and `_` in what the user typed from
/// being read as wildcards.
///
/// Null when the prefix is all `0xFF` (no successor exists) — the caller then scans from the
/// lower bound alone, which is still an index seek, just an open-ended one.
fn prefixEnd(buf: []u8, p: []const u8) ?[]const u8 {
    @memcpy(buf[0..p.len], p);
    var i = p.len;
    while (i > 0) : (i -= 1) {
        if (buf[i - 1] != 0xFF) {
            buf[i - 1] += 1;
            return buf[0..i];
        }
    }
    return null;
}

/// Longest prefix `complete` will match on. Anything longer matches nothing in a real vault.
pub const max_prefix: usize = 512;

/// Prefix match for `complete`. Returns up to `limit` notes whose stem/alias starts with `prefix`
/// (ASCII-folded).
///
/// Ordered by the *folded* key rather than the display one so the ordering is the index's own
/// and no sort is needed. That also makes the list case-insensitively alphabetical, which is
/// what someone typing a prefix expects: `Ab Anar` next to `AB Aurigae`, not two runs split by
/// capitalisation.
pub fn complete(
    index: *Index,
    arena: std.mem.Allocator,
    prefix: []const u8,
    limit: usize,
) ![]CompleteRow {
    if (limit == 0) return &.{};
    var fold_buf: [max_prefix]u8 = undefined;
    if (prefix.len > fold_buf.len) return &.{};
    const lo = foldInto(&fold_buf, prefix);

    index.lock();
    defer index.unlock();
    try index.ensureSorted();
    var list: std.ArrayList(CompleteRow) = .empty;

    const Keys = struct {
        fn stem(i: *Index, id: i64) []const u8 {
            return i.note(id).?.stem_fold;
        }
        fn alias(i: *Index, r: Index.AliasRef) []const u8 {
            return i.aliasFold(r);
        }
    };
    // A seek into the sorted view, then rows while they still start with the prefix.
    const stems = index.stems_sorted.items;
    var at = Index.lowerBound(i64, stems, index, Keys.stem, lo);
    while (at < stems.len and list.items.len < limit) : (at += 1) {
        const n = index.note(stems[at]).?;
        if (!std.mem.startsWith(u8, n.stem_fold, lo)) break;
        try list.append(arena, .{ .target = try arena.dupe(u8, n.stem), .path = try arena.dupe(u8, n.path), .title = try arena.dupe(u8, n.shownTitle()) });
    }
    if (list.items.len < limit) {
        const aliases = index.aliases_sorted.items;
        var ai = Index.lowerBound(Index.AliasRef, aliases, index, Keys.alias, lo);
        while (ai < aliases.len and list.items.len < limit) : (ai += 1) {
            const r = aliases[ai];
            const n = index.note(r.note_id).?;
            const al = n.aliases[r.index];
            if (!std.mem.startsWith(u8, al.alias_fold, lo)) break;
            try list.append(arena, .{ .target = try arena.dupe(u8, al.alias), .path = try arena.dupe(u8, n.path), .title = try arena.dupe(u8, n.shownTitle()) });
        }
    }
    return list.toOwnedSlice(arena);
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

pub const HeadingHit = struct {
    text: []const u8,
    /// `#` depth, 1-6. Carried so the completion list can show the outline's shape.
    level: u32,
    /// 0-based line, for a caller that wants to jump there.
    line: u32,
};

/// The headings of one note whose text starts with — or contains — `prefix` (folded), for
/// `[[Note#Section]]` completion.
///
/// Document order, not alphabetical: the list *is* the note's outline, and someone who has
/// already picked the note is looking for a place in it. Filtered here rather than by a
/// `text_fold` range the way `complete` does, because one note's headings are a handful of rows
/// — the whole set costs one indexed seek on `headings_note` — and that buys a substring match,
/// which is what finds "Habitat and range" from "range".
pub fn completeHeadings(
    index: *Index,
    arena: std.mem.Allocator,
    note_path: []const u8,
    prefix: []const u8,
    limit: usize,
) ![]HeadingHit {
    if (limit == 0) return &.{};
    var fold_buf: [max_prefix]u8 = undefined;
    if (prefix.len > fold_buf.len) return &.{};
    const want = foldInto(&fold_buf, prefix);

    index.lock();
    defer index.unlock();
    const n = index.byPath(note_path) orelse return &.{};
    var list: std.ArrayList(HeadingHit) = .empty;
    for (n.headings) |h| {
        if (list.items.len >= limit) break;
        if (want.len > 0 and std.mem.indexOf(u8, h.text_fold, want) == null) continue;
        try list.append(arena, .{
            .text = try arena.dupe(u8, h.text),
            .level = @max(h.level, 1),
            .line = h.line,
        });
    }
    return list.toOwnedSlice(arena);
}

/// Media rows whose name starts with `prefix` (folded), for `![[…]]` completion. Ordered by
/// name so the list is stable between keystrokes.
pub fn completeMedia(index: *Index, arena: std.mem.Allocator, prefix: []const u8, limit: usize) ![]CompleteRow {
    if (limit == 0) return &.{};
    var fold_buf: [max_prefix]u8 = undefined;
    if (prefix.len > fold_buf.len) return &.{};
    const lo = foldInto(&fold_buf, prefix);

    index.lock();
    defer index.unlock();
    try index.ensureSorted();
    // Two seeks — by folded name and by folded stem — unioned: a file matching on both its name
    // and its stem appears once. Ordered by name so the list is stable between keystrokes.
    const Keys = struct {
        fn name(i: *Index, id: i64) []const u8 {
            return i.media.items[@intCast(id - 1)].name_fold;
        }
        fn stem(i: *Index, id: i64) []const u8 {
            return i.media.items[@intCast(id - 1)].stem_fold;
        }
    };
    var hits: std.AutoArrayHashMapUnmanaged(i64, void) = .empty;
    const by_name = index.media_by_name_sorted.items;
    var at = Index.lowerBound(i64, by_name, index, Keys.name, lo);
    while (at < by_name.len) : (at += 1) {
        if (!std.mem.startsWith(u8, Keys.name(index, by_name[at]), lo)) break;
        try hits.put(arena, by_name[at], {});
    }
    const by_stem = index.media_by_stem_sorted.items;
    at = Index.lowerBound(i64, by_stem, index, Keys.stem, lo);
    while (at < by_stem.len) : (at += 1) {
        if (!std.mem.startsWith(u8, Keys.stem(index, by_stem[at]), lo)) break;
        try hits.put(arena, by_stem[at], {});
    }
    const ids = hits.keys();
    std.mem.sort(i64, ids, index, struct {
        fn lessThan(i: *Index, a: i64, b: i64) bool {
            return std.mem.lessThan(u8, Keys.name(i, a), Keys.name(i, b));
        }
    }.lessThan);
    var list: std.ArrayList(CompleteRow) = .empty;
    for (ids) |id| {
        if (list.items.len >= limit) break;
        try appendMedia(arena, &list, try arena.dupe(u8, index.media.items[@intCast(id - 1)].path));
    }
    return list.toOwnedSlice(arena);
}

/// Basename (with extension) is both the typed target and the image alt text — same default the
/// converter uses when an embed has no `|alias`.
fn appendMedia(arena: std.mem.Allocator, list: *std.ArrayList(CompleteRow), path: []const u8) !void {
    const name = std.fs.path.basenamePosix(path);
    try list.append(arena, .{ .target = name, .path = path, .title = name });
}

/// Media files as resolution candidates. Kept a separate list from `loadCandidates` rather
/// than merged with a kind flag: an embed resolves against media and a plain wikilink against
/// notes, so two lists means no precedence rule to get wrong (and `[[Target]]` can never
/// silently land on `Target.png` instead of `Target.md`). Two rows per file, one per spelling —
/// both `![[diagram]]` and `![[diagram.png]]` should find the image.
pub fn loadMediaCandidates(index: *Index, arena: std.mem.Allocator) ![]resolve.Candidate {
    index.lock();
    defer index.unlock();
    var list: std.ArrayList(resolve.Candidate) = .empty;
    var it = index.iterateMedia();
    while (it.next()) |m| {
        const path = try arena.dupe(u8, m.path);
        const stem = try arena.dupe(u8, m.stem);
        try list.append(arena, .{ .path = path, .stem = stem });
        const name = std.fs.path.basenamePosix(path);
        if (!std.mem.eql(u8, name, stem)) try list.append(arena, .{ .path = path, .stem = name });
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
