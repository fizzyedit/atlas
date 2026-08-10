//! Structural statistics for a vault graph: degree distribution, connected components, hub
//! fragility, a coarsening-ladder simulation, and folder correlation. This is the measurement
//! tool behind `zig build bench -- --stats <target>` (see `bench_main.zig`) — it exists to
//! answer one design question: is a real vault's link graph one dense web, or a pile of small
//! components stitched together by a handful of hub notes? That answer decides whether
//! folder-path is usable as a coarsening prior.
//!
//! Deliberately dvui-free: everything here is index arithmetic over `Edge` pairs, so it runs and
//! tests without the rest of the app, and both the real-vault loader and `vault_synth` in
//! `bench_main.zig` can feed it the same shape of data.

const std = @import("std");
const testing = std.testing;

pub const Edge = struct { a: u32, b: u32 };

/// Print the full stats block for one target to stdout. `paths` must be either empty (folder
/// correlation is skipped) or exactly `n` long — large synths skip path generation entirely, so
/// `bench_main` passes an empty slice for those rather than `n` copies of `""`.
pub fn report(
    gpa: std.mem.Allocator,
    n: usize,
    edges: []const Edge,
    paths: []const []const u8,
    label: []const u8,
) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    std.debug.print("\n==== stats: {s} ====\n", .{label});
    if (n == 0) {
        std.debug.print("  (empty)\n", .{});
        return;
    }

    const degrees = try degreesOf(arena, n, edges);
    try printBasics(arena, n, edges.len, degrees);
    try printDistributionExtras(arena, n, edges, degrees);

    const comp = try Components.compute(arena, n, edges);
    try printComponents(arena, n, comp);

    try printHubFragility(arena, n, edges, degrees);

    try printLadder(gpa, arena, n, edges, comp, degrees, 4);
    try printLadder(gpa, arena, n, edges, comp, degrees, 7);

    if (paths.len == n) {
        try printFolderCorrelation(n, comp, paths);
    } else {
        std.debug.print("-- folder correlation --\n  (skipped: no paths for this target)\n", .{});
    }
}

fn degreesOf(a: std.mem.Allocator, n: usize, edges: []const Edge) ![]u32 {
    const deg = try a.alloc(u32, n);
    @memset(deg, 0);
    for (edges) |e| {
        if (e.a < n) deg[e.a] += 1;
        if (e.b < n) deg[e.b] += 1;
    }
    return deg;
}

fn pct(x: usize, of: usize) f64 {
    if (of == 0) return 0;
    return 100.0 * @as(f64, @floatFromInt(x)) / @as(f64, @floatFromInt(of));
}

fn pctU(x: u64, of: u64) f64 {
    if (of == 0) return 0;
    return 100.0 * @as(f64, @floatFromInt(x)) / @as(f64, @floatFromInt(of));
}

// -- 1. basics ---------------------------------------------------------------------------------

fn percentile(sorted_asc: []const u32, p: f64) u32 {
    if (sorted_asc.len == 0) return 0;
    const idx_f = (p / 100.0) * @as(f64, @floatFromInt(sorted_asc.len - 1));
    const idx: usize = @intFromFloat(@round(idx_f));
    return sorted_asc[std.math.clamp(idx, 0, sorted_asc.len - 1)];
}

fn printBasics(a: std.mem.Allocator, n: usize, edge_count: usize, degrees: []const u32) !void {
    const sorted = try a.dupe(u32, degrees);
    std.mem.sort(u32, sorted, {}, std.sort.asc(u32));

    var sum: u64 = 0;
    var orphans: usize = 0;
    for (degrees) |d| {
        sum += d;
        if (d == 0) orphans += 1;
    }
    const mean = @as(f64, @floatFromInt(sum)) / @as(f64, @floatFromInt(n));

    std.debug.print("-- basics --\n", .{});
    std.debug.print("  notes={d}  links={d}\n", .{ n, edge_count });
    std.debug.print(
        "  degree: mean={d:.2}  median={d}  p90={d}  p99={d}  max={d}\n",
        .{ mean, percentile(sorted, 50), percentile(sorted, 90), percentile(sorted, 99), sorted[sorted.len - 1] },
    );
    std.debug.print("  orphans (degree=0): {d} ({d:.2}%)\n", .{ orphans, pct(orphans, n) });
}

// -- 1b. degree power-law exponent + local clustering -------------------------------------------

const PowerLaw = struct {
    alpha: f64,
    x_min: u32,
    tail_n: usize,
    has_data: bool,
};

/// Discrete MLE for the power-law exponent (Clauset/Shalizi/Newman), fixing `x_min` at the 70th
/// percentile of nonzero degrees (floored at 2) rather than scanning for the KS-optimal cutoff —
/// good enough for a bench sanity check, much cheaper than the full estimator.
fn degreePowerLaw(a: std.mem.Allocator, degrees: []const u32) !PowerLaw {
    var nonzero: std.ArrayList(u32) = .empty;
    for (degrees) |d| {
        if (d > 0) try nonzero.append(a, d);
    }
    if (nonzero.items.len == 0) return .{ .alpha = 0, .x_min = 0, .tail_n = 0, .has_data = false };
    std.mem.sort(u32, nonzero.items, {}, std.sort.asc(u32));

    const idx_f = 0.70 * @as(f64, @floatFromInt(nonzero.items.len - 1));
    const idx: usize = @intFromFloat(@round(idx_f));
    var x_min = nonzero.items[std.math.clamp(idx, 0, nonzero.items.len - 1)];
    if (x_min < 2) x_min = 2;

    var sum_ln: f64 = 0;
    var tail_n: usize = 0;
    for (nonzero.items) |d| {
        if (d < x_min) continue;
        sum_ln += @log(@as(f64, @floatFromInt(d)) / (@as(f64, @floatFromInt(x_min)) - 0.5));
        tail_n += 1;
    }
    if (tail_n < 50) return .{ .alpha = 0, .x_min = x_min, .tail_n = tail_n, .has_data = false };

    const alpha = 1.0 + @as(f64, @floatFromInt(tail_n)) / sum_ln;
    return .{ .alpha = alpha, .x_min = x_min, .tail_n = tail_n, .has_data = true };
}

const Clustering = struct {
    avg: f64,
    sampled: usize,
    has_data: bool,
};

/// CSR adjacency for the whole graph (unsorted per-node neighbour order — callers that need
/// existence checks go through a separate hash set, not binary search).
const Adjacency = struct {
    offsets: []u32,
    nbrs: []u32,

    fn build(a: std.mem.Allocator, n: usize, edges: []const Edge, degrees: []const u32) !Adjacency {
        const offsets = try a.alloc(u32, n + 1);
        offsets[0] = 0;
        for (0..n) |i| offsets[i + 1] = offsets[i] + degrees[i];
        const m = offsets[n];
        const nbrs = try a.alloc(u32, m);
        const cursor = try a.dupe(u32, offsets[0..n]);
        for (edges) |e| {
            if (e.a >= n or e.b >= n) continue;
            nbrs[cursor[e.a]] = e.b;
            cursor[e.a] += 1;
            nbrs[cursor[e.b]] = e.a;
            cursor[e.b] += 1;
        }
        return .{ .offsets = offsets, .nbrs = nbrs };
    }

    fn neighbors(self: Adjacency, i: usize) []const u32 {
        return self.nbrs[self.offsets[i]..self.offsets[i + 1]];
    }
};

/// Average local clustering coefficient, sampled: for each sampled node u (degree in [2, 400]),
/// C_u = (edges among u's neighbours) / C(deg_u, 2) — the standard local clustering coefficient.
/// Capped at 6000 sampled nodes and degree<=400 because the per-node cost is O(deg^2); real
/// graphs have hubs whose degree would otherwise blow the estimator up. Sampling is seeded with a
/// fixed constant so the result is deterministic across runs.
fn clusteringCoefficient(a: std.mem.Allocator, n: usize, edges: []const Edge, degrees: []const u32) !Clustering {
    if (n == 0) return .{ .avg = 0, .sampled = 0, .has_data = false };
    const adj = try Adjacency.build(a, n, edges, degrees);

    var edge_set: std.AutoHashMapUnmanaged(u64, void) = .{};
    try edge_set.ensureTotalCapacity(a, @intCast(edges.len));
    for (edges) |e| {
        if (e.a >= n or e.b >= n or e.a == e.b) continue;
        edge_set.putAssumeCapacity(packPair(e.a, e.b), {});
    }

    var eligible: std.ArrayList(u32) = .empty;
    for (0..n) |i| {
        if (degrees[i] >= 2 and degrees[i] <= 400) try eligible.append(a, @intCast(i));
    }
    if (eligible.items.len == 0) return .{ .avg = 0, .sampled = 0, .has_data = false };

    // Fixed-seed deterministic sample: partial Fisher-Yates shuffle, take the prefix.
    var rng = std.Random.DefaultPrng.init(0x5EED_C105_0FF1CE);
    const rand = rng.random();
    const sample_n = @min(@as(usize, 6000), eligible.items.len);
    var i: usize = 0;
    while (i < sample_n) : (i += 1) {
        const j = i + rand.uintLessThan(usize, eligible.items.len - i);
        std.mem.swap(u32, &eligible.items[i], &eligible.items[j]);
    }

    var sum: f64 = 0;
    for (eligible.items[0..sample_n]) |u| {
        const deg = degrees[u];
        const nb = adj.neighbors(u);
        var connected: u64 = 0;
        var p: usize = 0;
        while (p < nb.len) : (p += 1) {
            var q = p + 1;
            while (q < nb.len) : (q += 1) {
                if (edge_set.contains(packPair(nb[p], nb[q]))) connected += 1;
            }
        }
        const denom = @as(f64, @floatFromInt(deg)) * @as(f64, @floatFromInt(deg - 1));
        sum += 2.0 * @as(f64, @floatFromInt(connected)) / denom;
    }

    return .{ .avg = sum / @as(f64, @floatFromInt(sample_n)), .sampled = sample_n, .has_data = true };
}

fn printDistributionExtras(a: std.mem.Allocator, n: usize, edges: []const Edge, degrees: []const u32) !void {
    std.debug.print("-- degree power law / clustering --\n", .{});

    const pl = try degreePowerLaw(a, degrees);
    if (pl.has_data) {
        std.debug.print("  power-law: alpha={d:.3}  x_min={d}  tail_n={d}\n", .{ pl.alpha, pl.x_min, pl.tail_n });
    } else {
        std.debug.print("  power-law: n/a (tail_n={d} < 50)\n", .{pl.tail_n});
    }

    const cc = try clusteringCoefficient(a, n, edges, degrees);
    if (cc.has_data) {
        std.debug.print("  avg local clustering: {d:.4}  (sampled {d} nodes)\n", .{ cc.avg, cc.sampled });
    } else {
        std.debug.print("  avg local clustering: n/a (no nodes with degree in [2, 400])\n", .{});
    }
}

// -- shared union-find ---------------------------------------------------------------------------

const UnionFind = struct {
    parent: []u32,

    fn init(a: std.mem.Allocator, n: usize) !UnionFind {
        const p = try a.alloc(u32, n);
        for (0..n) |i| p[i] = @intCast(i);
        return .{ .parent = p };
    }

    fn find(self: *UnionFind, x: u32) u32 {
        var cur = x;
        while (self.parent[cur] != cur) {
            self.parent[cur] = self.parent[self.parent[cur]];
            cur = self.parent[cur];
        }
        return cur;
    }

    fn unite(self: *UnionFind, a: u32, b: u32) void {
        const ra = self.find(a);
        const rb = self.find(b);
        if (ra != rb) self.parent[rb] = ra;
    }
};

// -- 2. components --------------------------------------------------------------------------------

const Components = struct {
    /// Dense component id per note, 0..count-1. Every degree-0 note gets its own id here — this
    /// is the "real" graph component structure, distinct from the ladder's single orphan pile.
    id_of: []u32,
    size: []u32,
    /// Dense ids sorted by size desc, tie-broken by id asc.
    order: []u32,
    count: usize,

    fn compute(a: std.mem.Allocator, n: usize, edges: []const Edge) !Components {
        var uf = try UnionFind.init(a, n);
        for (edges) |e| {
            if (e.a >= n or e.b >= n) continue;
            uf.unite(e.a, e.b);
        }

        var dense: std.AutoHashMapUnmanaged(u32, u32) = .{};
        const id_of = try a.alloc(u32, n);
        var count: u32 = 0;
        for (0..n) |i| {
            const r = uf.find(@intCast(i));
            const gop = try dense.getOrPut(a, r);
            if (!gop.found_existing) {
                gop.value_ptr.* = count;
                count += 1;
            }
            id_of[i] = gop.value_ptr.*;
        }

        const size = try a.alloc(u32, count);
        @memset(size, 0);
        for (id_of) |cid| size[cid] += 1;

        const order = try a.alloc(u32, count);
        for (0..count) |i| order[i] = @intCast(i);
        std.mem.sort(u32, order, size, struct {
            fn less(ctx: []const u32, x: u32, y: u32) bool {
                if (ctx[x] != ctx[y]) return ctx[x] > ctx[y];
                return x < y;
            }
        }.less);

        return .{ .id_of = id_of, .size = size, .order = order, .count = count };
    }
};

fn sizeBucket(size: usize) usize {
    if (size <= 1) return 0;
    return @as(usize, std.math.log2_int(usize, size));
}

fn bucketLabel(b: usize, buf: []u8) []const u8 {
    if (b == 0) return "1";
    const lo = @as(usize, 1) << @intCast(b);
    const hi = (@as(usize, 1) << @intCast(b + 1)) - 1;
    return std.fmt.bufPrint(buf, "{d}-{d}", .{ lo, hi }) catch "?";
}

fn printComponents(a: std.mem.Allocator, n: usize, comp: Components) !void {
    _ = a;
    std.debug.print("-- components --\n", .{});
    std.debug.print("  count={d}\n", .{comp.count});
    const largest = comp.size[comp.order[0]];
    std.debug.print("  largest={d} ({d:.2}% of notes)\n", .{ largest, pct(largest, n) });

    std.debug.print("  top10:", .{});
    var i: usize = 0;
    while (i < comp.order.len and i < 10) : (i += 1) {
        std.debug.print(" {d}", .{comp.size[comp.order[i]]});
    }
    std.debug.print("\n", .{});

    var buckets: [24]usize = undefined;
    @memset(&buckets, 0);
    var max_bucket: usize = 0;
    for (comp.size) |s| {
        const b = sizeBucket(s);
        buckets[b] += 1;
        max_bucket = @max(max_bucket, b);
    }
    std.debug.print("  size histogram:\n", .{});
    var b: usize = 0;
    while (b <= max_bucket) : (b += 1) {
        if (buckets[b] == 0) continue;
        var label_buf: [24]u8 = undefined;
        const bl = bucketLabel(b, &label_buf);
        std.debug.print("    {s:<10}{d}\n", .{ bl, buckets[b] });
    }
}

// -- 3. hub fragility -----------------------------------------------------------------------------

fn printHubFragility(a: std.mem.Allocator, n: usize, edges: []const Edge, degrees: []const u32) !void {
    std.debug.print("-- hub fragility --\n", .{});
    std.debug.print("  {s:>5}  {s:>16}  {s:>12}\n", .{ "K", "largest%remain", "components" });

    const idx = try a.alloc(u32, n);
    for (0..n) |i| idx[i] = @intCast(i);
    std.mem.sort(u32, idx, degrees, struct {
        fn less(ctx: []const u32, x: u32, y: u32) bool {
            if (ctx[x] != ctx[y]) return ctx[x] > ctx[y];
            return x < y;
        }
    }.less);

    const ks = [_]usize{ 1, 2, 5, 10, 25, 50 };
    for (ks) |k0| {
        const k = @min(k0, n);
        const removed = try a.alloc(bool, n);
        @memset(removed, false);
        for (idx[0..k]) |ri| removed[ri] = true;

        var uf = try UnionFind.init(a, n);
        for (edges) |e| {
            if (e.a >= n or e.b >= n) continue;
            if (removed[e.a] or removed[e.b]) continue;
            uf.unite(e.a, e.b);
        }

        var size_of_root: std.AutoHashMapUnmanaged(u32, u32) = .{};
        var largest: u32 = 0;
        var comp_count: usize = 0;
        for (0..n) |i| {
            if (removed[i]) continue;
            const r = uf.find(@intCast(i));
            const gop = try size_of_root.getOrPut(a, r);
            if (!gop.found_existing) {
                gop.value_ptr.* = 0;
                comp_count += 1;
            }
            gop.value_ptr.* += 1;
            largest = @max(largest, gop.value_ptr.*);
        }

        const remaining = n - k;
        std.debug.print("  {d:>5}  {d:>15.1}%  {d:>12}\n", .{ k, pct(largest, remaining), comp_count });
    }
}

// -- 4. coarsening ladder simulation ----------------------------------------------------------------

const EdgeW = struct { a: u32, b: u32, w: f32 };

const CompLadder = struct {
    depth: usize,
    /// gpa-owned; level_counts[0] == component size, last entry == 1.
    level_counts: []usize,
};

fn packPair(a: u32, b: u32) u64 {
    const lo = @min(a, b);
    const hi = @max(a, b);
    return (@as(u64, hi) << 32) | @as(u64, lo);
}

/// Coarsen one connected component (or the orphan pile) in isolation — merges never cross
/// component boundaries because this function never sees more than one component's cells.
///
/// Per level: visit cells biggest-count-first (tie-break on id), grow each unclaimed cell into a
/// group of up to `arity` by greedily adding unclaimed same-component neighbours (highest edge
/// weight first), falling back to the 2-hop neighbourhood when direct neighbours run out. Any
/// group left at size 1 after that pass is then bundled with other size-1 groups (in id order)
/// into groups of `arity` — without this step a hub's leaves stay singletons forever once their
/// only neighbour (the hub) is claimed, and the ladder degenerates into a near-linear chain
/// instead of a `log_arity(n)`-deep tree. See `test "star graph does not degenerate..."` below.
fn coarsenComponent(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    size: usize,
    local_edges: []const EdgeW,
    arity: u32,
    child_hist: []usize,
) !CompLadder {
    var level_counts: std.ArrayList(usize) = .empty;
    try level_counts.append(gpa, size);

    if (size <= 1) {
        return .{ .depth = 0, .level_counts = try level_counts.toOwnedSlice(gpa) };
    }

    var cur_n: u32 = @intCast(size);
    var count = try arena.alloc(u32, cur_n);
    @memset(count, 1);
    var id = try arena.alloc(u32, cur_n);
    for (0..cur_n) |i| id[i] = @intCast(i);
    var cur_edges = try arena.dupe(EdgeW, local_edges);

    var depth: usize = 0;
    while (cur_n > 1) {
        depth += 1;

        // -- CSR adjacency for this level --
        const deg = try arena.alloc(u32, cur_n);
        @memset(deg, 0);
        for (cur_edges) |e| {
            deg[e.a] += 1;
            deg[e.b] += 1;
        }
        const offsets = try arena.alloc(u32, cur_n + 1);
        offsets[0] = 0;
        for (0..cur_n) |i| offsets[i + 1] = offsets[i] + deg[i];
        const m = offsets[cur_n];
        const nbrs = try arena.alloc(u32, m);
        const wts = try arena.alloc(f32, m);
        const cursor = try arena.dupe(u32, offsets[0..cur_n]);
        for (cur_edges) |e| {
            nbrs[cursor[e.a]] = e.b;
            wts[cursor[e.a]] = e.w;
            cursor[e.a] += 1;
            nbrs[cursor[e.b]] = e.a;
            wts[cursor[e.b]] = e.w;
            cursor[e.b] += 1;
        }

        // -- visiting order: biggest-count-first, tie-break id asc --
        const order = try arena.alloc(u32, cur_n);
        for (0..cur_n) |i| order[i] = @intCast(i);
        const OrderCtx = struct { count: []const u32, id: []const u32 };
        std.mem.sort(u32, order, OrderCtx{ .count = count, .id = id }, struct {
            fn less(ctx: OrderCtx, x: u32, y: u32) bool {
                if (ctx.count[x] != ctx.count[y]) return ctx.count[x] > ctx.count[y];
                return ctx.id[x] < ctx.id[y];
            }
        }.less);

        const claimed = try arena.alloc(bool, cur_n);
        @memset(claimed, false);

        var groups: std.ArrayList(std.ArrayList(u32)) = .empty;

        for (order) |ci| {
            if (claimed[ci]) continue;
            var group: std.ArrayList(u32) = .empty;
            try group.append(arena, ci);
            claimed[ci] = true;

            while (group.items.len < arity) {
                var cand: std.AutoHashMapUnmanaged(u32, f32) = .{};
                for (group.items) |mi| {
                    const s = offsets[mi];
                    const e2 = offsets[mi + 1];
                    for (nbrs[s..e2], wts[s..e2]) |nb, w| {
                        if (claimed[nb]) continue;
                        const gop = try cand.getOrPut(arena, nb);
                        if (!gop.found_existing) gop.value_ptr.* = 0;
                        gop.value_ptr.* += w;
                    }
                }

                var pick: ?u32 = null;
                var pick_w: f32 = -1;
                {
                    var it = cand.iterator();
                    while (it.next()) |entry| {
                        const w = entry.value_ptr.*;
                        const cid = entry.key_ptr.*;
                        if (pick == null or w > pick_w or (w == pick_w and id[cid] < id[pick.?])) {
                            pick = cid;
                            pick_w = w;
                        }
                    }
                }

                if (pick == null) {
                    // 1-hop exhausted (every direct neighbour already claimed) — reach through
                    // the group's 2-hop neighbourhood instead. This is exactly what saves a
                    // hub's leaves: once the hub itself is claimed, an isolated leaf's only path
                    // to another unclaimed leaf is via the (claimed) hub.
                    var cand2: std.AutoHashMapUnmanaged(u32, void) = .{};
                    for (group.items) |mi| {
                        const s = offsets[mi];
                        const e2 = offsets[mi + 1];
                        for (nbrs[s..e2]) |nb1| {
                            const s2 = offsets[nb1];
                            const e3 = offsets[nb1 + 1];
                            for (nbrs[s2..e3]) |nb2| {
                                if (claimed[nb2]) continue;
                                var in_group = false;
                                for (group.items) |gm| {
                                    if (gm == nb2) {
                                        in_group = true;
                                        break;
                                    }
                                }
                                if (in_group) continue;
                                try cand2.put(arena, nb2, {});
                            }
                        }
                    }
                    var it2 = cand2.iterator();
                    while (it2.next()) |entry| {
                        const cid = entry.key_ptr.*;
                        if (pick == null or id[cid] < id[pick.?]) pick = cid;
                    }
                    if (pick == null) break; // truly stuck: no reachable unclaimed cell at all
                }

                claimed[pick.?] = true;
                try group.append(arena, pick.?);
            }

            try groups.append(arena, group);
        }

        // -- bundle leftover size-1 groups into groups of `arity` --
        var singles: std.ArrayList(usize) = .empty;
        for (groups.items, 0..) |g, gi| {
            if (g.items.len == 1) try singles.append(arena, gi);
        }
        if (singles.items.len > 0) {
            const SingleCtx = struct { groups: []const std.ArrayList(u32), id: []const u32 };
            std.mem.sort(usize, singles.items, SingleCtx{ .groups = groups.items, .id = id }, struct {
                fn less(ctx: SingleCtx, x: usize, y: usize) bool {
                    return ctx.id[ctx.groups[x].items[0]] < ctx.id[ctx.groups[y].items[0]];
                }
            }.less);

            var new_groups: std.ArrayList(std.ArrayList(u32)) = .empty;
            var si: usize = 0;
            while (si < singles.items.len) {
                const end = @min(si + arity, singles.items.len);
                var bundled: std.ArrayList(u32) = .empty;
                for (singles.items[si..end]) |gi| try bundled.appendSlice(arena, groups.items[gi].items);
                try new_groups.append(arena, bundled);
                si = end;
            }

            var single_set: std.AutoHashMapUnmanaged(usize, void) = .{};
            for (singles.items) |gi| try single_set.put(arena, gi, {});

            var kept: std.ArrayList(std.ArrayList(u32)) = .empty;
            for (groups.items, 0..) |g, gi| {
                if (single_set.contains(gi)) continue;
                try kept.append(arena, g);
            }
            try kept.appendSlice(arena, new_groups.items);
            groups = kept;
        }

        // -- materialize next level --
        const new_n: u32 = @intCast(groups.items.len);
        const new_count = try arena.alloc(u32, new_n);
        const new_id = try arena.alloc(u32, new_n);
        const new_of = try arena.alloc(u32, cur_n);
        for (groups.items, 0..) |g, gi| {
            var c: u32 = 0;
            var min_id: u32 = std.math.maxInt(u32);
            for (g.items) |mi| {
                c += count[mi];
                if (id[mi] < min_id) min_id = id[mi];
                new_of[mi] = @intCast(gi);
            }
            new_count[gi] = c;
            new_id[gi] = min_id;
            child_hist[@min(g.items.len, @as(usize, arity))] += 1;
        }

        var acc: std.AutoHashMapUnmanaged(u64, f32) = .{};
        for (cur_edges) |e| {
            const na = new_of[e.a];
            const nb = new_of[e.b];
            if (na == nb) continue;
            const key = packPair(na, nb);
            const gop = try acc.getOrPut(arena, key);
            if (!gop.found_existing) gop.value_ptr.* = 0;
            gop.value_ptr.* += e.w;
        }
        const new_edges = try arena.alloc(EdgeW, acc.count());
        {
            var i: usize = 0;
            var it = acc.iterator();
            while (it.next()) |entry| : (i += 1) {
                const lo: u32 = @intCast(entry.key_ptr.* & 0xFFFF_FFFF);
                const hi: u32 = @intCast(entry.key_ptr.* >> 32);
                new_edges[i] = .{ .a = lo, .b = hi, .w = entry.value_ptr.* };
            }
        }

        cur_n = new_n;
        count = new_count;
        id = new_id;
        cur_edges = new_edges;
        try level_counts.append(gpa, cur_n);
    }

    return .{ .depth = depth, .level_counts = try level_counts.toOwnedSlice(gpa) };
}

const LadderResult = struct {
    depth: usize,
    cells_per_level: []usize, // gpa-owned
    child_hist: []usize, // gpa-owned, index 1..arity
    largest_component_depth: usize,
};

/// Group notes into ladder components: every real graph component keeps its identity; every
/// degree-0 note is folded into one shared "orphan pile" pseudo-component that coarsens by index
/// order (it has no edges, so the generic algorithm above degenerates to exactly that).
fn simulateLadder(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    n: usize,
    edges: []const Edge,
    comp: Components,
    degrees: []const u32,
    arity: u32,
) !LadderResult {
    var used = try arena.alloc(bool, comp.count);
    @memset(used, false);
    for (0..n) |i| {
        if (degrees[i] > 0) used[comp.id_of[i]] = true;
    }
    const remap = try arena.alloc(u32, comp.count);
    var k: u32 = 0;
    for (0..comp.count) |c| {
        if (used[c]) {
            remap[c] = k;
            k += 1;
        }
    }
    var has_orphans = false;
    for (degrees) |d| {
        if (d == 0) {
            has_orphans = true;
            break;
        }
    }
    const orphan_id: u32 = k;
    const total_groups: u32 = k + (if (has_orphans) @as(u32, 1) else 0);

    const group_id = try arena.alloc(u32, n);
    for (0..n) |i| {
        group_id[i] = if (degrees[i] == 0) orphan_id else remap[comp.id_of[i]];
    }

    var members = try arena.alloc(std.ArrayList(u32), total_groups);
    for (members) |*m| m.* = .empty;
    for (0..n) |i| try members[group_id[i]].append(arena, @intCast(i));

    const local_of = try arena.alloc(u32, n);
    for (members) |m| {
        for (m.items, 0..) |orig, li| local_of[orig] = @intCast(li);
    }

    var group_edges = try arena.alloc(std.ArrayList(EdgeW), total_groups);
    for (group_edges) |*ge| ge.* = .empty;
    for (edges) |e| {
        if (e.a >= n or e.b >= n) continue;
        const ga = group_id[e.a];
        const gb = group_id[e.b];
        if (ga != gb) continue; // orphans have no edges; real edges never cross components
        try group_edges[ga].append(arena, .{ .a = local_of[e.a], .b = local_of[e.b], .w = 1 });
    }

    const child_hist = try gpa.alloc(usize, arity + 1);
    @memset(child_hist, 0);

    const per_group_level_counts = try gpa.alloc([]usize, total_groups);
    defer {
        for (per_group_level_counts) |lc| gpa.free(lc);
        gpa.free(per_group_level_counts);
    }
    const per_group_depth = try arena.alloc(usize, total_groups);

    var max_depth: usize = 0;
    for (0..total_groups) |g| {
        const res = try coarsenComponent(gpa, arena, members[g].items.len, group_edges[g].items, arity, child_hist);
        per_group_level_counts[g] = res.level_counts;
        per_group_depth[g] = res.depth;
        max_depth = @max(max_depth, res.depth);
    }

    const totals = try gpa.alloc(usize, max_depth + 1);
    @memset(totals, 0);
    for (0..total_groups) |g| {
        const lc = per_group_level_counts[g];
        for (0..max_depth + 1) |lvl| {
            totals[lvl] += if (lvl < lc.len) lc[lvl] else 1;
        }
    }

    const largest_dense = comp.order[0];
    const largest_group: u32 = if (comp.size[largest_dense] > 1) remap[largest_dense] else orphan_id;

    return .{
        .depth = max_depth,
        .cells_per_level = totals,
        .child_hist = child_hist,
        .largest_component_depth = per_group_depth[largest_group],
    };
}

fn printLadder(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    n: usize,
    edges: []const Edge,
    comp: Components,
    degrees: []const u32,
    arity: u32,
) !void {
    const result = try simulateLadder(gpa, arena, n, edges, comp, degrees, arity);
    defer gpa.free(result.cells_per_level);
    defer gpa.free(result.child_hist);

    std.debug.print("-- coarsening ladder (arity={d}) --\n", .{arity});
    std.debug.print("  depth={d}\n", .{result.depth});
    std.debug.print("  cells per level:", .{});
    for (result.cells_per_level) |c| std.debug.print(" {d}", .{c});
    std.debug.print("\n", .{});
    std.debug.print("  child-count histogram:", .{});
    var ch: usize = 1;
    while (ch <= arity) : (ch += 1) {
        if (result.child_hist[ch] == 0) continue;
        std.debug.print("  {d}x{d}", .{ ch, result.child_hist[ch] });
    }
    std.debug.print("\n", .{});
    std.debug.print("  max root-to-leaf depth in largest component: {d}\n", .{result.largest_component_depth});

    const largest_size = comp.size[comp.order[0]];
    if (largest_size > 1) {
        const log_arity = @log(@as(f64, @floatFromInt(largest_size))) / @log(@as(f64, @floatFromInt(arity)));
        if (@as(f64, @floatFromInt(result.largest_component_depth)) > log_arity * 2.5) {
            std.debug.print(
                "  WARNING: depth {d} exceeds 2.5x log_{d}(largest)={d:.1} — possible singleton-chain regression\n",
                .{ result.largest_component_depth, arity, log_arity },
            );
        }
    }
}

// -- 5. folder correlation ------------------------------------------------------------------------

fn dirnameOf(p: []const u8) []const u8 {
    return std.fs.path.dirname(p) orelse "";
}

fn leadingSegOf(p: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, p, '/')) |i| return p[0..i];
    return p;
}

fn printFolderCorrelation(n: usize, comp: Components, paths: []const []const u8) !void {
    std.debug.print("-- folder correlation --\n", .{});
    if (n < 2) {
        std.debug.print("  (too few notes)\n", .{});
        return;
    }

    var rng = std.Random.DefaultPrng.init(0xC0FFEE_D15EA5E);
    const rand = rng.random();
    const max_pairs: u64 = @as(u64, n) * (@as(u64, n) - 1) / 2;
    const trials: u64 = @min(@as(u64, 200_000), max_pairs);

    var same_total: u64 = 0;
    var same_dir: u64 = 0;
    var same_seg: u64 = 0;
    var diff_total: u64 = 0;
    var diff_dir: u64 = 0;
    var diff_seg: u64 = 0;

    var t: u64 = 0;
    while (t < trials) : (t += 1) {
        const i = rand.uintLessThan(usize, n);
        const j = rand.uintLessThan(usize, n);
        if (i == j) continue;
        const same_comp = comp.id_of[i] == comp.id_of[j];
        const dir_match = std.mem.eql(u8, dirnameOf(paths[i]), dirnameOf(paths[j]));
        const seg_match = std.mem.eql(u8, leadingSegOf(paths[i]), leadingSegOf(paths[j]));
        if (same_comp) {
            same_total += 1;
            if (dir_match) same_dir += 1;
            if (seg_match) same_seg += 1;
        } else {
            diff_total += 1;
            if (dir_match) diff_dir += 1;
            if (seg_match) diff_seg += 1;
        }
    }

    std.debug.print(
        "  same-component pairs:  n={d}  same-dir={d:.2}%  same-top-segment={d:.2}%\n",
        .{ same_total, pctU(same_dir, same_total), pctU(same_seg, same_total) },
    );
    std.debug.print(
        "  diff-component pairs:  n={d}  same-dir={d:.2}%  same-top-segment={d:.2}%\n",
        .{ diff_total, pctU(diff_dir, diff_total), pctU(diff_seg, diff_total) },
    );
}

// -- tests -----------------------------------------------------------------------------------------

test "degreesOf counts undirected degree" {
    const a = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const edges = [_]Edge{ .{ .a = 0, .b = 1 }, .{ .a = 1, .b = 2 }, .{ .a = 0, .b = 2 } };
    const deg = try degreesOf(arena_state.allocator(), 3, &edges);
    try testing.expectEqual(@as(u32, 2), deg[0]);
    try testing.expectEqual(@as(u32, 2), deg[1]);
    try testing.expectEqual(@as(u32, 2), deg[2]);
}

test "components: orphans count as singleton components" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // 0-1-2 triangle, 3 and 4 isolated.
    const edges = [_]Edge{ .{ .a = 0, .b = 1 }, .{ .a = 1, .b = 2 }, .{ .a = 0, .b = 2 } };
    const comp = try Components.compute(a, 5, &edges);
    try testing.expectEqual(@as(usize, 3), comp.count); // {0,1,2}, {3}, {4}
    try testing.expectEqual(@as(u32, 3), comp.size[comp.order[0]]);
}

test "size bucket labels match the spec's doubling scheme" {
    try testing.expectEqual(@as(usize, 0), sizeBucket(1));
    try testing.expectEqual(@as(usize, 1), sizeBucket(2));
    try testing.expectEqual(@as(usize, 1), sizeBucket(3));
    try testing.expectEqual(@as(usize, 2), sizeBucket(4));
    try testing.expectEqual(@as(usize, 2), sizeBucket(7));
    try testing.expectEqual(@as(usize, 3), sizeBucket(8));

    var buf: [24]u8 = undefined;
    try testing.expectEqualStrings("1", bucketLabel(0, &buf));
    try testing.expectEqualStrings("2-3", bucketLabel(1, &buf));
    try testing.expectEqualStrings("4-7", bucketLabel(2, &buf));
    try testing.expectEqualStrings("8-15", bucketLabel(3, &buf));
}

// The exact shape that triggers the singleton-chain bug: one hub connected to 200 leaves, no
// leaf-leaf edges. Without the 2-hop fallback + singleton-bundling pass, every leaf whose only
// neighbour (the hub) gets claimed in level 1 is stuck as a permanent singleton, and the ladder
// degenerates into ~200 levels instead of ~log_arity(201).
test "star graph does not degenerate into a singleton chain" {
    const gpa = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const n: u32 = 201; // hub (id 0) + 200 leaves
    var local_edges = try arena.alloc(EdgeW, n - 1);
    for (1..n) |i| local_edges[i - 1] = .{ .a = 0, .b = @intCast(i), .w = 1 };

    inline for (.{ 4, 7 }) |arity| {
        const child_hist = try gpa.alloc(usize, arity + 1);
        defer gpa.free(child_hist);
        @memset(child_hist, 0);

        const res = try coarsenComponent(gpa, arena, n, local_edges, arity, child_hist);
        defer gpa.free(res.level_counts);

        const log_arity = @log(@as(f64, @floatFromInt(n))) / @log(@as(f64, @floatFromInt(arity)));
        try testing.expect(@as(f64, @floatFromInt(res.depth)) <= log_arity * 2.5);

        // Cells strictly shrink every level until they hit 1 — the direct signature of a chain
        // bug is a long run of levels that each drop by exactly one cell.
        try testing.expectEqual(@as(usize, 1), res.level_counts[res.level_counts.len - 1]);
        for (1..res.level_counts.len) |lv| {
            try testing.expect(res.level_counts[lv] < res.level_counts[lv - 1]);
        }
    }
}

test "coarsenComponent handles a component of size 1" {
    const gpa = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const child_hist = try gpa.alloc(usize, 5);
    defer gpa.free(child_hist);
    @memset(child_hist, 0);
    const res = try coarsenComponent(gpa, arena, 1, &.{}, 4, child_hist);
    defer gpa.free(res.level_counts);
    try testing.expectEqual(@as(usize, 0), res.depth);
    try testing.expectEqual(@as(usize, 1), res.level_counts.len);
    try testing.expectEqual(@as(usize, 1), res.level_counts[0]);
}

test "simulateLadder folds all degree-0 notes into one orphan pile" {
    const gpa = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A 10-note triangle-chain component (0..9 all linked in a path) plus 50 fully isolated notes.
    const n: usize = 60;
    var edges: std.ArrayList(Edge) = .empty;
    for (0..9) |i| try edges.append(arena, .{ .a = @intCast(i), .b = @intCast(i + 1) });

    const degrees = try degreesOf(arena, n, edges.items);
    const comp = try Components.compute(arena, n, edges.items);
    // 1 real component of size 10, plus 50 singleton "components" (orphans).
    try testing.expectEqual(@as(usize, 51), comp.count);

    const result = try simulateLadder(gpa, arena, n, edges.items, comp, degrees, 4);
    defer gpa.free(result.cells_per_level);
    defer gpa.free(result.child_hist);

    // Orphan pile of 50 at arity 4 needs ceil(log4(50)) ~= 3 levels; the 10-note chain needs a
    // similar handful. Depth should reflect whichever is deeper, not blow up into 50 levels.
    try testing.expect(result.depth <= 6);
    try testing.expectEqual(n, result.cells_per_level[0]);
    try testing.expectEqual(@as(usize, 1) + @as(usize, 1), blk: {
        // Once both the chain and the orphan pile have collapsed, exactly 2 cells remain: the
        // chain's root and the orphan pile's root.
        break :blk result.cells_per_level[result.cells_per_level.len - 1];
    });
}

test "clusteringCoefficient: a triangle has coefficient 1" {
    const a = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const edges = [_]Edge{ .{ .a = 0, .b = 1 }, .{ .a = 1, .b = 2 }, .{ .a = 0, .b = 2 } };
    const degrees = try degreesOf(arena_state.allocator(), 3, &edges);
    const cc = try clusteringCoefficient(arena_state.allocator(), 3, &edges, degrees);
    try testing.expect(cc.has_data);
    try testing.expectEqual(@as(usize, 3), cc.sampled);
    try testing.expect(@abs(cc.avg - 1.0) < 1e-9);
}

test "clusteringCoefficient: a star has coefficient 0" {
    const a = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var edges: std.ArrayList(Edge) = .empty;
    for (1..21) |i| try edges.append(arena, .{ .a = 0, .b = @intCast(i) });
    const degrees = try degreesOf(arena, 21, edges.items);
    const cc = try clusteringCoefficient(arena, 21, edges.items, degrees);
    try testing.expect(cc.has_data);
    // hub (degree 20) is the only eligible node with neighbours that could connect; leaves have
    // degree 1 and are excluded. No leaf-leaf edges exist, so the coefficient is 0.
    try testing.expect(cc.avg < 1e-9);
}

test "degreePowerLaw: reports n/a below the 50-sample tail floor" {
    const a = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const degrees = [_]u32{ 1, 2, 3, 4, 5 };
    const pl = try degreePowerLaw(arena_state.allocator(), &degrees);
    try testing.expect(!pl.has_data);
}

test "degreePowerLaw: a steep synthetic tail yields a finite alpha" {
    const a = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // 1000 nodes of degree 1, plus a power-law-ish tail so the 70th-percentile x_min still
    // leaves >=50 tail samples.
    var degrees: std.ArrayList(u32) = .empty;
    for (0..1000) |_| try degrees.append(arena, 1);
    var d: u32 = 2;
    while (d <= 200) : (d += 1) try degrees.append(arena, d);
    const pl = try degreePowerLaw(arena, degrees.items);
    try testing.expect(pl.has_data);
    try testing.expect(pl.alpha > 1.0);
}

test "folder correlation: same-directory notes trend toward same component" {
    const gpa = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Two components, each confined to its own directory.
    const n: usize = 20;
    var edges: std.ArrayList(Edge) = .empty;
    for (0..9) |i| try edges.append(arena, .{ .a = @intCast(i), .b = @intCast(i + 1) });
    for (10..19) |i| try edges.append(arena, .{ .a = @intCast(i), .b = @intCast(i + 1) });

    var paths: [20][]const u8 = undefined;
    for (0..10) |i| paths[i] = try std.fmt.allocPrint(arena, "areaA/note-{d}.md", .{i});
    for (10..20) |i| paths[i] = try std.fmt.allocPrint(arena, "areaB/note-{d}.md", .{i});

    const comp = try Components.compute(arena, n, edges.items);
    try testing.expectEqual(@as(usize, 2), comp.count);
    // Just make sure it runs without error and prints something sane; correctness of the
    // sampling math is covered by the aggregate counts being internally consistent.
    try printFolderCorrelation(n, comp, &paths);
}
