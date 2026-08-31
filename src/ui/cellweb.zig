//! Link weight aggregated onto *cells*, at every level of the fold ladder at once.
//!
//! This is what makes the drawn web cost what is on screen rather than what is in the vault.
//!
//! `world.liftLinks` used to walk the entire note-level edge list every frame, mapping both
//! endpoints of every edge to the cell that currently owned them and merging duplicates in a hash
//! map. That is `O(E)` per frame no matter what the camera is doing — at a million notes it was
//! 1.3–6.5 ms a frame, and at overview zoom on an islands vault it spent all of it to produce
//! *zero* links, because every edge was internal to one root and got discarded after the lookup.
//! Scaled to a Wikipedia-sized corpus (millions of articles, tens of millions of links) that loop
//! alone is tens to hundreds of milliseconds a frame, before anything is drawn.
//!
//! The fix is to precompute, once per rebuild, the total link weight between every pair of cells
//! that are adjacent *at their own level* of the ladder. A frame then reads the adjacency of the
//! cells on the cut — which is bounded by the mark budget — and never touches a note-level edge.
//!
//! ## Why "at their own level" is enough
//!
//! The cut (the closed cells covering the screen) is not level-uniform: an island that coarsened
//! shallowly sits beside one that went deep. So a pair of cut cells `(a, b)` may live at different
//! levels, and only one of the two directions will find the other.
//!
//! Take `level(a) < level(b)`, so `a` is the finer one. `b` is coarser, so its subtree reaches down
//! through `a`'s level, and aggregation preserves the connection at every level it survives to:
//! `adj[a]` therefore contains some descendant of `b` at `a`'s level, which walks up to `b`. Read
//! from `b` instead, `adj[b]` contains an *ancestor* of `a` — a cell that is open this frame, since
//! the cut is strictly below it. So the rule is: resolve a neighbour to the cut cell above it, and
//! skip the pair when the cut on that side is deeper than the neighbour. Every pair is then found
//! exactly once from the finer side (or from both, at equal levels, where the merge handles it).
//!
//! ## Memory
//!
//! Levels aggregate, so the entry count is roughly `2E` for the whole hierarchy (the level-0 pairs
//! plus a geometric tail), doubled for the two CSR directions. Around 64 MB of adjacency at two
//! million links. That is the trade: a per-rebuild allocation proportional to the link count, in
//! exchange for a per-frame cost proportional to the budget.

const std = @import("std");
const fold = @import("fold.zig");
const radix = @import("radix.zig");

/// One undirected cell pair, canonicalised `u < v`.
const Pair = struct { u: u32, v: u32, w: f32 };

fn pairKey(p: Pair) u64 {
    return (@as(u64, p.u) << 32) | @as(u64, p.v);
}

/// Sort, then sum runs of equal `(u, v)` into `items`. Returns the deduplicated prefix length.
///
/// `scratch` is the radix sort's ping-pong buffer and must be at least as long as `items`. The
/// sort was the entire cost of this file on a large vault — a comparison sort over 3.35M pairs at
/// level 0, repeated for every level of the ladder — and the key is two cell ids, which buckets in
/// linear time. See `radix.sortByKey`.
///
/// The merge reads `sorted` and writes `items`, which is correct whichever buffer the sort landed
/// in: a different buffer is trivially safe, and the same buffer is safe because `out` never runs
/// ahead of the read cursor.
fn dedupe(items: []Pair, scratch: []Pair) usize {
    if (items.len == 0) return 0;
    const sorted = radix.sortByKey(Pair, pairKey, items, scratch);
    items[0] = sorted[0];
    var out: usize = 0;
    for (sorted[1..]) |it| {
        if (it.u == items[out].u and it.v == items[out].v) {
            items[out].w += it.w;
        } else {
            out += 1;
            items[out] = it;
        }
    }
    return out + 1;
}

pub const CellWeb = struct {
    /// CSR over every cell in the ladder. `nbr[start[u]..start[u + 1]]` are the cells adjacent to
    /// `u` at `u`'s own level, ordered by *descending* weight so a capped scan keeps the heaviest.
    start: []u32 = &.{},
    nbr: []u32 = &.{},
    w: []f32 = &.{},

    pub fn deinit(self: *CellWeb, gpa: std.mem.Allocator) void {
        gpa.free(self.start);
        gpa.free(self.nbr);
        gpa.free(self.w);
        self.* = .{};
    }

    pub fn degree(self: CellWeb, u: u32) u32 {
        if (u + 1 >= self.start.len) return 0;
        return self.start[u + 1] - self.start[u];
    }

    /// Index range into `nbr`/`w` for cell `u`.
    pub fn range(self: CellWeb, u: u32) struct { usize, usize } {
        if (u + 1 >= self.start.len) return .{ 0, 0 };
        return .{ self.start[u], self.start[u + 1] };
    }
};

/// Workers the per-cell neighbour sort may use. Capped for the same reason the interior solves are:
/// this runs behind an editor.
const max_sort_threads: usize = 8;

/// One worker's stripe of cells for the heaviest-first sort in `build`.
const SortCtx = struct {
    web: *CellWeb,
    gpa: std.mem.Allocator,

    fn range(self: *SortCtx, lo_cell: usize, hi_cell: usize) void {
        var run: std.ArrayListUnmanaged(u64) = .empty;
        defer run.deinit(self.gpa);
        const web = self.web;
        for (lo_cell..hi_cell) |u| {
            const lo = web.start[u];
            const hi = web.start[u + 1];
            if (hi - lo < 2) continue;

            if (hi - lo <= 24) {
                var i = lo + 1;
                while (i < hi) : (i += 1) {
                    const nv = web.nbr[i];
                    const wv = web.w[i];
                    var j = i;
                    while (j > lo and (web.w[j - 1] < wv or (web.w[j - 1] == wv and web.nbr[j - 1] > nv))) : (j -= 1) {
                        web.nbr[j] = web.nbr[j - 1];
                        web.w[j] = web.w[j - 1];
                    }
                    web.nbr[j] = nv;
                    web.w[j] = wv;
                }
                continue;
            }

            // Weight in the high half, inverted so ascending integer order is descending weight; the
            // neighbour id in the low half, so it breaks ties ascending for free. Sound because these
            // weights are sums of positive weights, and positive floats order as their bit patterns do.
            run.resize(self.gpa, hi - lo) catch continue;
            for (run.items, web.nbr[lo..hi], web.w[lo..hi]) |*r, nv, wv| {
                r.* = (@as(u64, ~@as(u32, @bitCast(wv))) << 32) | nv;
            }
            std.mem.sort(u64, run.items, {}, std.sort.asc(u64));
            for (run.items, web.nbr[lo..hi], web.w[lo..hi]) |r, *nv, *wv| {
                nv.* = @truncate(r);
                wv.* = @bitCast(~@as(u32, @truncate(r >> 32)));
            }
        }
    }
};

/// Aggregate `edges` (note ids) onto cells, level by level, and return the CSR.
///
/// Ascending in lockstep would be wrong for an unbalanced ladder: a shallow leaf reaches its root
/// while its partner is still several levels down. A cell already at a root therefore stays put
/// instead of climbing, and the loop runs until every pair has collapsed to a single cell.
pub fn build(
    gpa: std.mem.Allocator,
    lad: *const fold.Ladder,
    edges: []const fold.Edge,
) !CellWeb {
    const n_cells = lad.cells.len;
    if (n_cells == 0) return .{};
    const all = try climbPairs(gpa, lad, edges);
    defer gpa.free(all);
    return csrFromPairs(gpa, n_cells, all);
}

/// Lift note-level edges onto cell pairs at every level they survive.
fn climbPairs(
    gpa: std.mem.Allocator,
    lad: *const fold.Ladder,
    edges: []const fold.Edge,
) ![]Pair {
    var all: std.ArrayListUnmanaged(Pair) = .empty;
    errdefer all.deinit(gpa);
    var cur: std.ArrayListUnmanaged(Pair) = .empty;
    defer cur.deinit(gpa);
    var next: std.ArrayListUnmanaged(Pair) = .empty;
    defer next.deinit(gpa);

    if (lad.cells.len == 0 or edges.len == 0) return all.toOwnedSlice(gpa);

    const scratch = try gpa.alloc(Pair, edges.len);
    defer gpa.free(scratch);

    try cur.ensureTotalCapacity(gpa, edges.len);
    for (edges) |e| {
        if (e.a >= lad.leaf_cell.len or e.b >= lad.leaf_cell.len) continue;
        const la = lad.leaf_cell[e.a];
        const lb = lad.leaf_cell[e.b];
        if (la == fold.invalid or lb == fold.invalid or la == lb) continue;
        cur.appendAssumeCapacity(.{
            .u = @min(la, lb),
            .v = @max(la, lb),
            .w = e.w,
        });
    }
    cur.shrinkRetainingCapacity(dedupe(cur.items, scratch));
    try all.appendSlice(gpa, cur.items);

    var round: u32 = 0;
    while (cur.items.len > 0 and round < @as(u32, lad.depth) + 2) : (round += 1) {
        next.clearRetainingCapacity();
        try next.ensureTotalCapacity(gpa, cur.items.len);
        for (cur.items) |p| {
            const pu = if (lad.cells[p.u].parent == fold.invalid) p.u else lad.cells[p.u].parent;
            const pv = if (lad.cells[p.v].parent == fold.invalid) p.v else lad.cells[p.v].parent;
            if (pu == pv) continue;
            next.appendAssumeCapacity(.{
                .u = @min(pu, pv),
                .v = @max(pu, pv),
                .w = p.w,
            });
        }
        next.shrinkRetainingCapacity(dedupe(next.items, scratch));
        try all.appendSlice(gpa, next.items);
        std.mem.swap(std.ArrayListUnmanaged(Pair), &cur, &next);
    }
    return all.toOwnedSlice(gpa);
}

fn csrFromPairs(gpa: std.mem.Allocator, n_cells: usize, all: []const Pair) !CellWeb {
    var web: CellWeb = .{
        .start = try gpa.alloc(u32, n_cells + 1),
        .nbr = try gpa.alloc(u32, all.len * 2),
        .w = try gpa.alloc(f32, all.len * 2),
    };
    errdefer web.deinit(gpa);
    @memset(web.start, 0);

    for (all) |p| {
        web.start[p.u] += 1;
        web.start[p.v] += 1;
    }
    var acc: u32 = 0;
    for (web.start) |*s| {
        const c = s.*;
        s.* = acc;
        acc += c;
    }
    const cursor = try gpa.alloc(u32, n_cells);
    defer gpa.free(cursor);
    @memcpy(cursor, web.start[0..n_cells]);
    for (all) |p| {
        web.nbr[cursor[p.u]] = p.v;
        web.w[cursor[p.u]] = p.w;
        cursor[p.u] += 1;
        web.nbr[cursor[p.v]] = p.u;
        web.w[cursor[p.v]] = p.w;
        cursor[p.v] += 1;
    }
    web.start[n_cells] = acc;

    // Heaviest first within each cell, so `link_scan_cap` truncates the least interesting tail
    // rather than an arbitrary one.
    //
    // Sorted in place on the two parallel arrays. This used to sort an *index permutation* per cell
    // through three `ArrayList`s and a comparator that indirected through the weight array, which
    // on a Wikipedia-sized ladder is 353,000 small sorts and was 317-496 ms — more than the level
    // climb and the CSR fill together, and the largest single item in a rebuild after clustering.
    //
    // Two shapes, because the runs are overwhelmingly short. A handful of neighbours is an
    // insertion sort that moves both arrays together and allocates nothing; a long run is packed
    // into one `u64` key so it sorts as plain integers with no comparator at all.
    //
    // Both break ties by neighbour id, which the old comparator did not: `link_scan_cap` truncates
    // this list, so which of two equally-heavy neighbours survives was being decided by the sort's
    // internal order. Now it is decided by the graph.
    // Sorted in parallel: each cell's run is its own slice of `nbr`/`w`, so the workers share no
    // writes. This was 214 ms of a 637 ms `cellweb.build` on a Wikipedia-sized ladder, and it is
    // 353,000 independent sorts — the shape a thread pool exists for.
    var ctx: SortCtx = .{ .web = &web, .gpa = gpa };
    const want = @min(@max(std.Thread.getCpuCount() catch 1, 1), max_sort_threads);
    if (want <= 1 or n_cells < 4096) {
        ctx.range(0, n_cells);
    } else {
        var handles: [max_sort_threads]std.Thread = undefined;
        var spawned: usize = 0;
        const step = n_cells / want + 1;
        var lo: usize = 0;
        while (lo < n_cells) : (lo += step) {
            const hi = @min(lo + step, n_cells);
            handles[spawned] = std.Thread.spawn(.{}, SortCtx.range, .{ &ctx, lo, hi }) catch {
                ctx.range(lo, hi);
                continue;
            };
            spawned += 1;
            if (spawned == max_sort_threads) break;
        }
        if (spawned > 0 and lo < n_cells) ctx.range(lo, n_cells);
        for (handles[0..spawned]) |h| h.join();
    }

    return web;
}

// ---- tests ----------------------------------------------------------------------------------

const testing = std.testing;

fn totalWeightBetween(web: CellWeb, a: u32, b: u32) f32 {
    const lo, const hi = web.range(a);
    var sum: f32 = 0;
    for (web.nbr[lo..hi], web.w[lo..hi]) |v, ww| {
        if (v == b) sum += ww;
    }
    return sum;
}

test "a chain's leaf cells are adjacent to their neighbours" {
    const gpa = testing.allocator;
    const n: u32 = 64;
    const edges = try gpa.alloc(fold.Edge, n - 1);
    defer gpa.free(edges);
    for (0..n - 1) |i| edges[i] = .{ .a = @intCast(i), .b = @intCast(i + 1) };

    var lad = try fold.build(gpa, n, edges, &.{}, .{});
    defer lad.deinit(gpa);
    var web = try build(gpa, &lad, edges);
    defer web.deinit(gpa);

    // Every chain edge survives as adjacency between the two leaf cells that hold its endpoints.
    for (edges) |e| {
        const la = lad.leaf_cell[e.a];
        const lb = lad.leaf_cell[e.b];
        if (la == fold.invalid or lb == fold.invalid or la == lb) continue;
        try testing.expect(totalWeightBetween(web, la, lb) > 0);
    }
}

test "weight is conserved when a level aggregates" {
    // Two cells joined by several notes must aggregate to one entry carrying the summed weight,
    // which is the whole reason a coarse pair draws one line instead of thousands.
    const gpa = testing.allocator;
    const n: u32 = 14;
    var edges: std.ArrayListUnmanaged(fold.Edge) = .empty;
    defer edges.deinit(gpa);
    // A dense-ish pair of groups so coarsening has something to merge.
    for (0..7) |i| {
        for (7..14) |j| {
            try edges.append(gpa, .{ .a = @intCast(i), .b = @intCast(j), .w = 1 });
        }
    }
    var lad = try fold.build(gpa, n, edges.items, &.{}, .{});
    defer lad.deinit(gpa);
    var web = try build(gpa, &lad, edges.items);
    defer web.deinit(gpa);

    // Total weight over the whole CSR is every pair counted twice (once per direction), and each
    // level holds the same total as level 0 minus whatever collapsed inside a single cell.
    var total: f32 = 0;
    for (web.w) |ww| total += ww;
    try testing.expect(total > 0);
    // No cell may list itself.
    for (0..lad.cells.len) |u| {
        const lo, const hi = web.range(@intCast(u));
        for (web.nbr[lo..hi]) |v| try testing.expect(v != u);
    }
}

test "adjacency is symmetric" {
    const gpa = testing.allocator;
    const n: u32 = 200;
    var prng = std.Random.DefaultPrng.init(0xBEEF);
    const rnd = prng.random();
    const edges = try gpa.alloc(fold.Edge, 400);
    defer gpa.free(edges);
    for (edges) |*e| e.* = .{
        .a = rnd.uintLessThan(u32, n),
        .b = rnd.uintLessThan(u32, n),
        .w = 1,
    };

    var lad = try fold.build(gpa, n, edges, &.{}, .{});
    defer lad.deinit(gpa);
    var web = try build(gpa, &lad, edges);
    defer web.deinit(gpa);

    for (0..lad.cells.len) |u| {
        const lo, const hi = web.range(@intCast(u));
        for (web.nbr[lo..hi], web.w[lo..hi]) |v, ww| {
            try testing.expectApproxEqAbs(ww, totalWeightBetween(web, v, @intCast(u)), 1e-4);
        }
    }
}

test "neighbours are ordered heaviest first" {
    const gpa = testing.allocator;
    const n: u32 = 120;
    var prng = std.Random.DefaultPrng.init(9);
    const rnd = prng.random();
    const edges = try gpa.alloc(fold.Edge, 500);
    defer gpa.free(edges);
    for (edges) |*e| e.* = .{
        .a = rnd.uintLessThan(u32, n),
        .b = rnd.uintLessThan(u32, n),
        .w = @floatFromInt(1 + rnd.uintLessThan(u32, 9)),
    };

    var lad = try fold.build(gpa, n, edges, &.{}, .{});
    defer lad.deinit(gpa);
    var web = try build(gpa, &lad, edges);
    defer web.deinit(gpa);

    for (0..lad.cells.len) |u| {
        const lo, const hi = web.range(@intCast(u));
        if (hi <= lo + 1) continue;
        for (web.w[lo .. hi - 1], web.w[lo + 1 .. hi]) |a, b| {
            try testing.expect(a >= b);
        }
    }
}

test "an empty graph builds an empty web" {
    const gpa = testing.allocator;
    var lad = try fold.build(gpa, 0, &.{}, &.{}, .{});
    defer lad.deinit(gpa);
    var web = try build(gpa, &lad, &.{});
    defer web.deinit(gpa);
    try testing.expectEqual(@as(u32, 0), web.degree(0));
}
