//! One hierarchy for the whole vault.
//!
//! Today the graph carries four overlapping structures: `multilevel.Ladder` (link coarsening),
//! `layout_full`'s flat positions, `lod.Pyramid` (the ladder, then continued *by position* once
//! link structure runs out), and `quadlod.Tree` (a component forest rebuilt from those positions).
//! They disagree, which is what a "half-fine/half-coarse" frame actually is.
//!
//! This file is the replacement for all four: a single arity-N coarsening ladder, and nothing
//! else. Positions are derived from it (`containment.zig`) rather than being an input to it.
//!
//! Two design choices carry most of the weight:
//!
//! **Folders are weak links, not a separate mechanism.** Notes are sorted by path and consecutive
//! notes get an edge at `folder_w`. Because lexicographic order on paths *is* a depth-first walk of
//! the folder tree, one edge per note buys: same-directory notes adjacent, sibling directories
//! adjacent, and parent directories next to their children. So "group by links, and by folder when
//! there are no links" needs no code at all — an unlinked note's only edges are to its
//! path-neighbours, so it coarsens with its folder-mates automatically. No orphan special case, no
//! folder-cohesion force, no virtual nodes.
//!
//! An earlier attempt gave each directory a node linked to all its members. That fails: the folder
//! node is itself claimed into a group, so it can only pull `arity - 1` members before the rest are
//! cut adrift and bundled with strangers. A chain has no such bottleneck.
//!
//! `folder_w` is deliberately small. On a real wikilink graph (Simple English Wikipedia, 284k
//! articles) linked pairs shared a category 8.6% of the time against a 1.93% random baseline — a
//! 4.5× lift. Real, but weak, so folder membership is a *weight*, never a constraint.
//!
//! **Arity is a free parameter, independent of the data's shape.** A binary tree of a million
//! notes does not need a 20-level binary hierarchy; it coarsens into a 7-ary ladder of depth ~7,
//! grouping seven tree-nodes per cell. The ladder is a re-grouping of the vault, not a picture of
//! it — which is why depth can become zoom instead of a spatial axis, and why the same system
//! works at 5 notes and at 1,000,000.
//!
//! No dvui, no filesystem, no vault types — this is plain graph math over `Edge` pairs so it can
//! be tested headlessly and eventually lifted into its own package.

const std = @import("std");

pub const invalid: u32 = std.math.maxInt(u32);

/// Children per cell. Both nest exactly on the hex lattice (see `hex.zig`); 7 is the
/// centre-plus-six-neighbours fold and reaches 1M in 8 levels against 4's 10.
pub const Arity = enum(u8) {
    four = 4,
    seven = 7,

    pub fn n(self: Arity) usize {
        return @intFromEnum(self);
    }
};

pub const Edge = struct { a: u32, b: u32, w: f32 = 1.0 };

/// Link weight between two children of the same cell, used by `containment.zig` to pick which
/// child lands in which hex slot. Indices are positions within the parent's child list, so they
/// fit in a `u8` for any sane arity.
pub const SibPair = struct { i: u8, j: u8, w: f32 };

pub const Cell = struct {
    parent: u32 = invalid,
    child_start: u32 = 0,
    child_count: u16 = 0,
    pair_start: u32 = 0,
    pair_count: u16 = 0,
    /// Real notes beneath this cell. Folder nodes never count.
    count: u32 = 0,
    level: u16 = 0,
    /// Set iff this cell is a single real note.
    note: u32 = invalid,
    /// Contiguous [ls, le) range over `note_at` — every note beneath this cell. Lets a link be
    /// lifted to the cell that currently owns it with two array reads and no ancestor walk.
    ls: u32 = 0,
    le: u32 = 0,

    pub fn isLeaf(self: Cell) bool {
        return self.child_count == 0;
    }
};

pub const Ladder = struct {
    cells: []Cell = &.{},
    children: []u32 = &.{},
    pairs: []SibPair = &.{},
    /// note id -> the leaf cell holding it (`invalid` if the note was not placed).
    leaf_cell: []u32 = &.{},
    /// dfs slot -> note id, and its inverse.
    note_at: []u32 = &.{},
    slot_of: []u32 = &.{},
    root: u32 = invalid,
    depth: u16 = 0,

    pub fn deinit(self: *Ladder, gpa: std.mem.Allocator) void {
        gpa.free(self.cells);
        gpa.free(self.children);
        gpa.free(self.pairs);
        gpa.free(self.leaf_cell);
        gpa.free(self.note_at);
        gpa.free(self.slot_of);
        self.* = .{};
    }

    pub fn childrenOf(self: Ladder, id: u32) []const u32 {
        const c = self.cells[id];
        return self.children[c.child_start..][0..c.child_count];
    }

    pub fn pairsOf(self: Ladder, id: u32) []const SibPair {
        const c = self.cells[id];
        return self.pairs[c.pair_start..][0..c.pair_count];
    }
};

pub const Options = struct {
    arity: Arity = .seven,
    /// Weight of note↔folder and folder↔parent-folder edges, against 1.0 for a real link.
    folder_w: f32 = 0.25,
    /// Safety stop. A correct run terminates in ~log_arity(n) levels.
    max_levels: u16 = 40,
};

/// Build the ladder. `paths` may be empty (no folder nodes); otherwise `paths[i]` is note `i`'s
/// vault-relative path and only its directory part is used.
pub fn build(
    gpa: std.mem.Allocator,
    n_notes: usize,
    links: []const Edge,
    paths: []const []const u8,
    opts: Options,
) !Ladder {
    if (n_notes == 0) return .{};

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // ---- augment: folder nodes -------------------------------------------------------------
    var edges: std.ArrayListUnmanaged(Edge) = .empty;
    try edges.ensureTotalCapacity(arena, links.len + n_notes * 2);
    for (links) |e| {
        if (e.a == e.b or e.a >= n_notes or e.b >= n_notes) continue;
        edges.appendAssumeCapacity(.{ .a = e.a, .b = e.b, .w = e.w });
    }

    const total: u32 = @intCast(n_notes);
    if (paths.len == n_notes and opts.folder_w > 0) {
        try addPathChain(arena, &edges, paths, opts.folder_w);
    }

    // ---- coarsen ---------------------------------------------------------------------------
    var cells: std.ArrayListUnmanaged(Cell) = .empty;
    try cells.ensureTotalCapacity(gpa, total * 2);
    errdefer cells.deinit(gpa);
    for (0..total) |i| {
        try cells.append(gpa, .{
            .count = if (i < n_notes) 1 else 0,
            .note = if (i < n_notes) @intCast(i) else invalid,
        });
    }

    var children: std.ArrayListUnmanaged(u32) = .empty;
    errdefer children.deinit(gpa);

    var cur = try arena.alloc(u32, total);
    for (cur, 0..) |*c, i| c.* = @intCast(i);
    var level_edges = try arena.dupe(Edge, edges.items);

    var depth: u16 = 0;
    while (depth < opts.max_levels and cur.len > 1) {
        const res = try coarsenLevel(arena, gpa, &cells, &children, cur, level_edges, opts.arity, depth);
        if (res.cells.len >= cur.len) break; // no progress
        cur = res.cells;
        level_edges = res.edges;
        depth += 1;
    }

    // A disconnected vault can leave several tops; give them one root so the ladder is a tree.
    var root: u32 = undefined;
    if (cur.len == 1) {
        root = cur[0];
    } else {
        root = @intCast(cells.items.len);
        var sum: u32 = 0;
        const start: u32 = @intCast(children.items.len);
        for (cur) |c| {
            cells.items[c].parent = root;
            sum += cells.items[c].count;
            try children.append(gpa, c);
        }
        try cells.append(gpa, .{
            .count = sum,
            .level = depth + 1,
            .child_start = start,
            .child_count = @intCast(cur.len),
        });
        depth += 1;
    }

    var lad: Ladder = .{
        .cells = try cells.toOwnedSlice(gpa),
        .children = try children.toOwnedSlice(gpa),
        .root = root,
        .depth = depth,
    };
    errdefer lad.deinit(gpa);

    // Folder nodes have done their job; drop them and any cell left holding nothing real, then
    // splice out single-child chains so the ladder stays ~log_arity(n) deep.
    lad.root = prune(&lad, lad.root) orelse return .{};

    lad.leaf_cell = try gpa.alloc(u32, n_notes);
    @memset(lad.leaf_cell, invalid);
    lad.note_at = try gpa.alloc(u32, n_notes);
    lad.slot_of = try gpa.alloc(u32, n_notes);
    @memset(lad.slot_of, invalid);
    var cursor: u32 = 0;
    assignRanges(&lad, lad.root, 0, &cursor);
    lad.depth = maxDepth(lad, lad.root);

    try buildPairs(gpa, &lad, links, n_notes);
    return lad;
}

// ---- folder nodes ---------------------------------------------------------------------------

/// One edge per note, between path-order neighbours. Lexicographic order on vault-relative paths
/// is a depth-first walk of the folder tree, so this single chain expresses the whole hierarchy:
/// same-directory notes are contiguous, sibling directories abut, and a directory sits next to its
/// children. Weight is `folder_w` against 1.0 for a real link, so links always win where they
/// exist and folders only decide where they don't.
fn addPathChain(
    arena: std.mem.Allocator,
    edges: *std.ArrayListUnmanaged(Edge),
    paths: []const []const u8,
    w: f32,
) !void {
    const order = try arena.alloc(u32, paths.len);
    for (order, 0..) |*o, i| o.* = @intCast(i);
    const Ctx = struct {
        paths: []const []const u8,
        pub fn lessThan(self: @This(), a: u32, b: u32) bool {
            return std.mem.lessThan(u8, self.paths[a], self.paths[b]);
        }
    };
    std.mem.sort(u32, order, Ctx{ .paths = paths }, Ctx.lessThan);

    var i: usize = 1;
    while (i < order.len) : (i += 1) {
        try edges.append(arena, .{ .a = order[i - 1], .b = order[i], .w = w });
    }
}

// ---- one coarsening level -------------------------------------------------------------------

const LevelResult = struct { cells: []u32, edges: []Edge };

fn coarsenLevel(
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    cells: *std.ArrayListUnmanaged(Cell),
    children: *std.ArrayListUnmanaged(u32),
    cur: []const u32,
    level_edges: []const Edge,
    arity: Arity,
    level: u16,
) !LevelResult {
    const k = arity.n();

    // Dense index over the current cells so adjacency can be a flat CSR.
    var idx = std.AutoHashMapUnmanaged(u32, u32).empty;
    try idx.ensureTotalCapacity(arena, @intCast(cur.len));
    for (cur, 0..) |c, i| idx.putAssumeCapacity(c, @intCast(i));

    const m = cur.len;
    const deg = try arena.alloc(u32, m);
    @memset(deg, 0);
    for (level_edges) |e| {
        const ia = idx.get(e.a) orelse continue;
        const ib = idx.get(e.b) orelse continue;
        if (ia == ib) continue;
        deg[ia] += 1;
        deg[ib] += 1;
    }
    const off = try arena.alloc(u32, m + 1);
    off[0] = 0;
    for (0..m) |i| off[i + 1] = off[i] + deg[i];
    const fill = try arena.dupe(u32, off[0..m]);
    const adj = try arena.alloc(u32, off[m]);
    const adjw = try arena.alloc(f32, off[m]);
    for (level_edges) |e| {
        const ia = idx.get(e.a) orelse continue;
        const ib = idx.get(e.b) orelse continue;
        if (ia == ib) continue;
        adj[fill[ia]] = ib;
        adjw[fill[ia]] = e.w;
        fill[ia] += 1;
        adj[fill[ib]] = ia;
        adjw[fill[ib]] = e.w;
        fill[ib] += 1;
    }

    // Biggest-first is deterministic and keeps hubs at the centre of their group.
    const order = try arena.dupe(u32, cur);
    const Ctx = struct {
        cells: []const Cell,
        pub fn lessThan(self: @This(), a: u32, b: u32) bool {
            const ca = self.cells[a].count;
            const cb = self.cells[b].count;
            if (ca != cb) return ca > cb;
            return a < b;
        }
    };
    std.mem.sort(u32, order, Ctx{ .cells = cells.items }, Ctx.lessThan);

    const taken = try arena.alloc(bool, m);
    @memset(taken, false);

    var groups: std.ArrayListUnmanaged([]u32) = .empty;
    var leftovers: std.ArrayListUnmanaged(u32) = .empty;
    var buf = try arena.alloc(u32, k);

    for (order) |cell_id| {
        const u = idx.get(cell_id).?;
        if (taken[u]) continue;
        taken[u] = true;
        var len: usize = 1;
        buf[0] = u;

        // 1-hop, heaviest link first.
        len = growFrom(u, adj, adjw, off, taken, buf, len, k);
        // then the group's own neighbourhood, so a star's rim can still coalesce
        if (len < k) {
            var gi: usize = 1;
            while (gi < len and len < k) : (gi += 1) {
                len = growFrom(buf[gi], adj, adjw, off, taken, buf, len, k);
            }
        }

        if (len == 1) {
            try leftovers.append(arena, u);
        } else {
            try groups.append(arena, try arena.dupe(u32, buf[0..len]));
        }
    }

    // A cell whose neighbours were all claimed would otherwise pass through unchanged. Around a
    // hub that is *most* of the star, and the ladder degenerates into a chain tens of levels deep
    // instead of log_arity(n) — the leaves never coalesce at all. Bundle them instead. Isolated
    // nodes (no links, no folder) fall out of the same rule with no special case.
    if (leftovers.items.len > 1) {
        var i: usize = 0;
        while (i < leftovers.items.len) : (i += k) {
            const end = @min(i + k, leftovers.items.len);
            if (end - i == 1 and groups.items.len > 0) {
                // a lone tail: hand it to the last group rather than making a 1-cell parent
                const last = groups.items[groups.items.len - 1];
                if (last.len < k) {
                    const grown = try arena.alloc(u32, last.len + 1);
                    @memcpy(grown[0..last.len], last);
                    grown[last.len] = leftovers.items[i];
                    groups.items[groups.items.len - 1] = grown;
                    continue;
                }
            }
            try groups.append(arena, try arena.dupe(u32, leftovers.items[i..end]));
        }
    } else if (leftovers.items.len == 1) {
        try groups.append(arena, try arena.dupe(u32, leftovers.items[0..1]));
    }

    // ---- materialise parents ----
    const next = try arena.alloc(u32, groups.items.len);
    const parent_of = try arena.alloc(u32, m);
    for (groups.items, 0..) |grp, gi| {
        if (grp.len == 1) {
            // pass through unchanged; nothing gained by wrapping it
            const id = cur[grp[0]];
            next[gi] = id;
            parent_of[grp[0]] = id;
            continue;
        }
        const id: u32 = @intCast(cells.items.len);
        const start: u32 = @intCast(children.items.len);
        var sum: u32 = 0;
        for (grp) |gi2| {
            const child = cur[gi2];
            cells.items[child].parent = id;
            sum += cells.items[child].count;
            try children.append(gpa, child);
            parent_of[gi2] = id;
        }
        try cells.append(gpa, .{
            .count = sum,
            .level = level + 1,
            .child_start = start,
            .child_count = @intCast(grp.len),
        });
        next[gi] = id;
    }

    // ---- lift edges (sort + merge; no per-edge hashing) ----
    var lifted: std.ArrayListUnmanaged(Edge) = .empty;
    try lifted.ensureTotalCapacity(arena, level_edges.len);
    for (level_edges) |e| {
        const ia = idx.get(e.a) orelse continue;
        const ib = idx.get(e.b) orelse continue;
        const pa = parent_of[ia];
        const pb = parent_of[ib];
        if (pa == pb) continue;
        lifted.appendAssumeCapacity(.{
            .a = @min(pa, pb),
            .b = @max(pa, pb),
            .w = e.w,
        });
    }
    const S = struct {
        pub fn lessThan(_: void, x: Edge, y: Edge) bool {
            if (x.a != y.a) return x.a < y.a;
            return x.b < y.b;
        }
    };
    std.mem.sort(Edge, lifted.items, {}, S.lessThan);
    var merged: std.ArrayListUnmanaged(Edge) = .empty;
    try merged.ensureTotalCapacity(arena, lifted.items.len);
    for (lifted.items) |e| {
        if (merged.items.len > 0) {
            const last = &merged.items[merged.items.len - 1];
            if (last.a == e.a and last.b == e.b) {
                last.w += e.w;
                continue;
            }
        }
        merged.appendAssumeCapacity(e);
    }

    return .{ .cells = next, .edges = merged.items };
}

fn growFrom(
    u: u32,
    adj: []const u32,
    adjw: []const f32,
    off: []const u32,
    taken: []bool,
    buf: []u32,
    len_in: usize,
    k: usize,
) usize {
    var len = len_in;
    while (len < k) {
        var best: u32 = invalid;
        var best_w: f32 = -1;
        var e = off[u];
        while (e < off[u + 1]) : (e += 1) {
            const v = adj[e];
            if (taken[v]) continue;
            if (adjw[e] > best_w) {
                best_w = adjw[e];
                best = v;
            }
        }
        if (best == invalid) break;
        taken[best] = true;
        buf[len] = best;
        len += 1;
    }
    return len;
}

// ---- prune / ranges -------------------------------------------------------------------------

/// Splice out single-child cells. A cell with one child is a zoom level that shows exactly what
/// the level above it showed, which is both a wasted split animation and extra depth.
fn prune(lad: *Ladder, id: u32) ?u32 {
    const c = &lad.cells[id];
    if (c.child_count == 0) return id;

    const start = c.child_start;
    for (0..c.child_count) |i| {
        const child = lad.children[start + i];
        if (prune(lad, child)) |surv| {
            lad.children[start + i] = surv;
            lad.cells[surv].parent = id;
        }
    }
    if (c.child_count == 1) {
        const only = lad.children[start];
        lad.cells[only].parent = c.parent;
        return only;
    }
    return id;
}

fn assignRanges(lad: *Ladder, id: u32, level: u16, cursor: *u32) void {
    const c = &lad.cells[id];
    c.level = level;
    c.ls = cursor.*;
    if (c.child_count == 0) {
        if (c.note != invalid) {
            lad.note_at[cursor.*] = c.note;
            lad.slot_of[c.note] = cursor.*;
            lad.leaf_cell[c.note] = id;
            cursor.* += 1;
        }
    } else {
        for (0..c.child_count) |i| {
            assignRanges(lad, lad.children[c.child_start + i], level + 1, cursor);
        }
    }
    c.le = cursor.*;
}

fn maxDepth(lad: Ladder, id: u32) u16 {
    const c = lad.cells[id];
    if (c.child_count == 0) return 0;
    var m: u16 = 0;
    for (0..c.child_count) |i| {
        m = @max(m, maxDepth(lad, lad.children[c.child_start + i]));
    }
    return m + 1;
}

// ---- sibling pair weights -------------------------------------------------------------------

/// For every original link, find the lowest cell that contains both ends and record the weight
/// between the two of its children that the link crosses. `containment.zig` uses this to choose
/// which child gets which hex slot — turning what would be a global force solve into an
/// exhaustive search over at most `arity!` arrangements per cell.
fn buildPairs(gpa: std.mem.Allocator, lad: *Ladder, links: []const Edge, n_notes: usize) !void {
    var acc: std.AutoHashMapUnmanaged(u64, f32) = .empty;
    defer acc.deinit(gpa);

    for (links) |e| {
        if (e.a >= n_notes or e.b >= n_notes or e.a == e.b) continue;
        var x = lad.leaf_cell[e.a];
        var y = lad.leaf_cell[e.b];
        if (x == invalid or y == invalid or x == y) continue;

        // climb to equal depth, then together until the parents meet
        while (lad.cells[x].level > lad.cells[y].level) x = lad.cells[x].parent;
        while (lad.cells[y].level > lad.cells[x].level) y = lad.cells[y].parent;
        while (lad.cells[x].parent != lad.cells[y].parent) {
            if (lad.cells[x].parent == invalid or lad.cells[y].parent == invalid) break;
            x = lad.cells[x].parent;
            y = lad.cells[y].parent;
        }
        const p = lad.cells[x].parent;
        if (p == invalid or x == y) continue;

        const kids = lad.childrenOf(p);
        var i: u8 = 255;
        var j: u8 = 255;
        for (kids, 0..) |kid, ki| {
            if (kid == x) i = @intCast(ki);
            if (kid == y) j = @intCast(ki);
        }
        if (i == 255 or j == 255) continue;
        const lo = @min(i, j);
        const hi = @max(i, j);
        const key = (@as(u64, p) << 16) | (@as(u64, lo) << 8) | hi;
        const gop = try acc.getOrPut(gpa, key);
        gop.value_ptr.* = (if (gop.found_existing) gop.value_ptr.* else 0) + e.w;
    }

    var pairs: std.ArrayListUnmanaged(SibPair) = .empty;
    errdefer pairs.deinit(gpa);
    // group by cell so each cell's pairs are contiguous
    var by_cell: std.AutoHashMapUnmanaged(u32, std.ArrayListUnmanaged(SibPair)) = .empty;
    defer {
        var it = by_cell.valueIterator();
        while (it.next()) |v| v.deinit(gpa);
        by_cell.deinit(gpa);
    }
    var it = acc.iterator();
    while (it.next()) |kv| {
        const cell: u32 = @intCast(kv.key_ptr.* >> 16);
        const lo: u8 = @intCast((kv.key_ptr.* >> 8) & 0xff);
        const hi: u8 = @intCast(kv.key_ptr.* & 0xff);
        const gop = try by_cell.getOrPut(gpa, cell);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(gpa, .{ .i = lo, .j = hi, .w = kv.value_ptr.* });
    }
    var it2 = by_cell.iterator();
    while (it2.next()) |kv| {
        const cell = kv.key_ptr.*;
        lad.cells[cell].pair_start = @intCast(pairs.items.len);
        lad.cells[cell].pair_count = @intCast(kv.value_ptr.items.len);
        try pairs.appendSlice(gpa, kv.value_ptr.items);
    }
    lad.pairs = try pairs.toOwnedSlice(gpa);
}

// ---- tests ----------------------------------------------------------------------------------

const testing = std.testing;

fn star(gpa: std.mem.Allocator, leaves: u32) ![]Edge {
    const e = try gpa.alloc(Edge, leaves);
    for (0..leaves) |i| e[i] = .{ .a = 0, .b = @intCast(i + 1) };
    return e;
}

test "a star does not degenerate into a chain" {
    // The failure this guards: around a hub every leaf's neighbours are claimed by the hub, so
    // each becomes a singleton group and passes through unchanged. Depth goes linear in n.
    const gpa = testing.allocator;
    inline for (.{ Arity.four, Arity.seven }) |ar| {
        const edges = try star(gpa, 200);
        defer gpa.free(edges);
        var lad = try build(gpa, 201, edges, &.{}, .{ .arity = ar });
        defer lad.deinit(gpa);

        const ideal = std.math.log(f64, @floatFromInt(ar.n()), 201.0);
        try testing.expect(@as(f64, @floatFromInt(lad.depth)) <= ideal * 2.5 + 1);
        try testing.expectEqual(@as(u32, 201), lad.cells[lad.root].count);
    }
}

test "every note lands in exactly one leaf, ranges are contiguous" {
    const gpa = testing.allocator;
    const edges = try star(gpa, 60);
    defer gpa.free(edges);
    var lad = try build(gpa, 61, edges, &.{}, .{});
    defer lad.deinit(gpa);

    var seen = try gpa.alloc(bool, 61);
    defer gpa.free(seen);
    @memset(seen, false);
    for (lad.note_at) |note| {
        try testing.expect(!seen[note]);
        seen[note] = true;
    }
    for (seen) |s| try testing.expect(s);

    // a cell's range covers exactly the notes beneath it
    for (lad.cells, 0..) |c, i| {
        if (c.parent == invalid and i != lad.root) continue;
        try testing.expectEqual(c.count, c.le - c.ls);
    }
}

test "unlinked notes group by folder" {
    const gpa = testing.allocator;
    const paths = [_][]const u8{
        "a/1.md", "a/2.md", "a/3.md", "a/4.md",
        "b/1.md", "b/2.md", "b/3.md", "b/4.md",
    };
    var lad = try build(gpa, paths.len, &.{}, &paths, .{ .arity = .four });
    defer lad.deinit(gpa);

    // With no links at all, folder edges are the only structure — so the two directories must
    // come out as separate cells rather than being bundled by index order.
    var found_pure_a = false;
    var found_pure_b = false;
    for (lad.cells, 0..) |c, id| {
        if (c.count != 4 or id == lad.root) continue;
        var all_a = true;
        var all_b = true;
        for (c.ls..c.le) |s| {
            const p = paths[lad.note_at[s]];
            if (p[0] != 'a') all_a = false;
            if (p[0] != 'b') all_b = false;
        }
        if (all_a) found_pure_a = true;
        if (all_b) found_pure_b = true;
    }
    try testing.expect(found_pure_a);
    try testing.expect(found_pure_b);
}

test "every drawn leaf is a real note" {
    const gpa = testing.allocator;
    const paths = [_][]const u8{ "x/a.md", "x/b.md", "y/c.md", "y/d.md" };
    var lad = try build(gpa, paths.len, &.{}, &paths, .{ .arity = .four });
    defer lad.deinit(gpa);
    for (lad.cells) |c| {
        if (c.child_count == 0) try testing.expect(c.note != invalid);
    }
    try testing.expectEqual(@as(u32, 4), lad.cells[lad.root].count);
}

test "a real link outranks folder adjacency" {
    // Two directories, and one link tying a note in each together. The linked pair must land in
    // the same cell before either falls in with its path-neighbours.
    const gpa = testing.allocator;
    const paths = [_][]const u8{
        "a/1.md", "a/2.md", "a/3.md",
        "b/1.md", "b/2.md", "b/3.md",
    };
    const links = [_]Edge{.{ .a = 0, .b = 3, .w = 1 }};
    var lad = try build(gpa, paths.len, &links, &paths, .{ .arity = .four });
    defer lad.deinit(gpa);
    try testing.expectEqual(lad.cells[lad.leaf_cell[0]].parent, lad.cells[lad.leaf_cell[3]].parent);
}

test "deterministic for the same input" {
    const gpa = testing.allocator;
    const edges = try star(gpa, 90);
    defer gpa.free(edges);
    var a = try build(gpa, 91, edges, &.{}, .{});
    defer a.deinit(gpa);
    var b = try build(gpa, 91, edges, &.{}, .{});
    defer b.deinit(gpa);
    try testing.expectEqual(a.depth, b.depth);
    try testing.expectEqualSlices(u32, a.note_at, b.note_at);
}

test "scale-free 20k stays log depth" {
    // The shape that broke the old coarsener: preferential attachment makes hubs, and around a hub
    // every leaf is a leftover. Depth must stay ~log_7(n), not linear.
    const gpa = testing.allocator;
    const n: u32 = 20_000;
    var prng = std.Random.DefaultPrng.init(0xA71A5);
    const rand = prng.random();

    var pool: std.ArrayListUnmanaged(u32) = .empty;
    defer pool.deinit(gpa);
    var edges: std.ArrayListUnmanaged(Edge) = .empty;
    defer edges.deinit(gpa);
    try pool.append(gpa, 0);
    for (1..n) |i| {
        const j = pool.items[rand.uintLessThan(usize, pool.items.len)];
        try edges.append(gpa, .{ .a = @intCast(i), .b = j });
        try pool.append(gpa, j);
        try pool.append(gpa, @intCast(i));
    }

    var lad = try build(gpa, n, edges.items, &.{}, .{ .arity = .seven });
    defer lad.deinit(gpa);

    const ideal = std.math.log(f64, 7.0, @as(f64, @floatFromInt(n)));
    try testing.expect(@as(f64, @floatFromInt(lad.depth)) <= ideal * 2.5);
    try testing.expectEqual(n, lad.cells[lad.root].count);
    // and every note is reachable exactly once
    var seen = try gpa.alloc(bool, n);
    defer gpa.free(seen);
    @memset(seen, false);
    for (lad.note_at) |note| {
        try testing.expect(!seen[note]);
        seen[note] = true;
    }
    for (seen) |s| try testing.expect(s);
}

test "chain of 1000 coarsens to log depth, not 1000" {
    const gpa = testing.allocator;
    const n: u32 = 1000;
    const edges = try gpa.alloc(Edge, n - 1);
    defer gpa.free(edges);
    for (0..n - 1) |i| edges[i] = .{ .a = @intCast(i), .b = @intCast(i + 1) };
    var lad = try build(gpa, n, edges, &.{}, .{ .arity = .seven });
    defer lad.deinit(gpa);
    const ideal = std.math.log(f64, 7.0, @as(f64, @floatFromInt(n)));
    try testing.expect(@as(f64, @floatFromInt(lad.depth)) <= ideal * 2.5 + 1);
}
