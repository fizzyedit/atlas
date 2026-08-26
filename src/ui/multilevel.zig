//! Multilevel force layout: coarsen the graph, solve the small version, refine back down.
//!
//! A single-level force solve cannot produce structure larger than the range of its forces.
//! Attraction runs along every edge (global), repulsion is deliberately short-range so islands
//! can sit close together — so inside one connected component nothing operates above the scale
//! of a couple of cells, and the whole thing settles at uniform lattice density. That is the
//! "one massive hex" a well-linked vault turns into: not a tuning failure, a reach failure.
//!
//! Coarsening fixes the reach rather than the constants. Repeatedly merging linked pairs into
//! supernodes gives a graph of a few dozen nodes where the same short-range repulsion spans the
//! *whole* vault, so communities are placed relative to each other before any individual note
//! exists. Projecting back down and re-solving at each level fills in progressively finer
//! detail without disturbing the arrangement already decided above it.
//!
//! Cost is roughly O(n log n): each level has about half the nodes of the one below, so the
//! whole ladder costs a small multiple of the finest level, and the finest level needs only a
//! few iterations because it starts from an already-good arrangement.
//!
//! Positions come out in *unit* space — roughly one node per unit² — for the caller to scale to
//! its own lattice. Nothing here knows about hex cells, panels, or notes.

const std = @import("std");
const dvui = @import("dvui");
const radix = @import("radix.zig");

/// A tie between two nodes. `w` scales the attraction along it, so callers can express that some
/// links are better evidence of relatedness than others — a link to a 29k-degree hub says almost
/// nothing, a link between two obscure notes says a lot. See `fold.degreeNormalised`.
pub const Edge = struct { a: u32, b: u32, w: f32 = 1.0 };

/// An edge at some coarse level, carrying how many original edges it stands for.
const WEdge = struct { a: u32, b: u32, w: f32 };

/// Stop coarsening once the graph is this small — small enough that the force solve's own
/// short-range repulsion reaches across all of it, which is the entire point of the ladder.
const coarsest_n: usize = 40;
/// Give up if a coarsening pass cannot shrink the graph by at least this fraction. A graph with
/// no matchable structure left (a star, say) would otherwise loop forever making no progress.
const min_shrink: f32 = 0.9;
/// Most nodes one coarse group may stand for. Pairs are the ideal; the leftover fold in `match`
/// may push a group to this, and no further — an uncapped fold lets a hub absorb every note
/// pendant to it in one level, which coarsens fast and throws away the structure underneath.
const group_max: u32 = 4;
const max_levels: usize = 32;

/// Unit-space spacing the solve aims for at every level. Density is held constant across levels
/// by scaling positions on projection, so one set of force constants works the whole way down.
const spacing: f32 = 1.0;
const repulse_cut: f32 = 2.6 * spacing;
const repulse_k: f32 = 0.9;
const spring_k: f32 = 1.0;
const gravity_k: f32 = 0.005;

pub const Opts = struct {
    /// Iterations at the coarsest level. Finer levels taper toward `min_iters`, since each
    /// starts from the level above's answer and only has to fill in local detail.
    max_iters: usize = 90,
    min_iters: usize = 12,
    /// When set, the coarsening ladder is handed back instead of freed — see `Ladder`.
    keep_ladder: ?*Ladder = null,
    /// Polled between levels and between iterations; set it to abandon the solve with
    /// `error.Canceled`. A full-vault solve runs for seconds on a worker thread, and shutdown
    /// must not have to wait it out — this code lives in a dylib that is about to be unloaded.
    cancel: ?*std.atomic.Value(bool) = null,
};

/// The coarsening hierarchy the solve built on its way down.
///
/// This falls out of the layout for free and is exactly the structure a zoomed-out view wants:
/// each level is a coarser grouping of the one below, so "many nearby linked notes become one
/// marker when you zoom out" is a level lookup rather than a separate clustering pass. Keeping
/// it costs one `u32` per node per level — a few hundred KB even at 100k notes — and it is the
/// difference between drawing 100k nodes and drawing a few thousand.
///
/// `maps[L][i]` is the index, at level `L + 1`, of the node that level-`L` node `i` belongs to.
/// Level 0 is the original graph. `counts[L]` is the node count at level `L`.
pub const Ladder = struct {
    maps: [][]u32 = &.{},
    counts: []usize = &.{},

    pub fn deinit(self: *Ladder, allocator: std.mem.Allocator) void {
        for (self.maps) |m| allocator.free(m);
        allocator.free(self.maps);
        allocator.free(self.counts);
        self.* = .{};
    }

    /// Index at level `level` of the level-0 node `i`.
    pub fn ancestorOf(self: Ladder, i: usize, level: usize) usize {
        var idx: u32 = @intCast(i);
        for (self.maps[0..@min(level, self.maps.len)]) |m| idx = m[idx];
        return idx;
    }

    pub fn levelCount(self: Ladder) usize {
        return self.counts.len;
    }

    /// Deep copy into `allocator`. The solve allocates the ladder from its own scratch arena, so
    /// anything that wants to outlive the solve has to take a copy.
    pub fn clone(self: Ladder, allocator: std.mem.Allocator) !Ladder {
        const maps = try allocator.alloc([]u32, self.maps.len);
        for (self.maps, maps) |src, *dst| dst.* = try allocator.dupe(u32, src);
        return .{ .maps = maps, .counts = try allocator.dupe(usize, self.counts) };
    }
};

/// Build the coarsening hierarchy alone, without laying anything out.
///
/// The layout only produces a ladder when it takes the multilevel path — a full repack of a
/// large vault. But the *view* wants the hierarchy on every rebuild, including the incremental
/// ones that dominate while a vault is being indexed, and tying level-of-detail to which layout
/// path happened to run means it blinks out the moment anything is edited.
///
/// This is O(n + e) per level over about log(n) levels, and touches no positions, so it is cheap
/// enough to redo on every rebuild.
pub fn coarsen(allocator: std.mem.Allocator, n: usize, edges: []const Edge) !Ladder {
    var level_edges: std.ArrayList(WEdge) = .empty;
    defer level_edges.deinit(allocator);
    try level_edges.ensureTotalCapacity(allocator, edges.len);
    for (edges) |e| {
        if (e.a >= n or e.b >= n or e.a == e.b) continue;
        level_edges.appendAssumeCapacity(.{ .a = e.a, .b = e.b, .w = e.w });
    }

    var maps: std.ArrayList([]u32) = .empty;
    var counts: std.ArrayList(usize) = .empty;
    errdefer {
        for (maps.items) |m| allocator.free(m);
        maps.deinit(allocator);
        counts.deinit(allocator);
    }
    try counts.append(allocator, n);

    var cur_n = n;
    while (cur_n > coarsest_n and maps.items.len < max_levels) {
        const parent = try allocator.alloc(u32, cur_n);
        const coarse_n = try match(allocator, cur_n, level_edges.items, parent);
        // No structure left to merge — a star, or a graph with no edges at all. Stopping here
        // is right: further levels would be arbitrary groupings, not communities.
        if (@as(f32, @floatFromInt(coarse_n)) > @as(f32, @floatFromInt(cur_n)) * min_shrink) {
            allocator.free(parent);
            break;
        }
        try contract(allocator, &level_edges, parent);
        try maps.append(allocator, parent);
        try counts.append(allocator, coarse_n);
        cur_n = coarse_n;
    }

    return .{
        .maps = try maps.toOwnedSlice(allocator),
        .counts = try counts.toOwnedSlice(allocator),
    };
}

/// Lay out `n` nodes into `out` (unit space, centred on the origin).
pub fn solve(
    allocator: std.mem.Allocator,
    n: usize,
    edges: []const Edge,
    out: []dvui.Point,
    opts: Opts,
) !void {
    std.debug.assert(out.len >= n);
    if (n == 0) return;
    if (n == 1) {
        out[0] = .{};
        return;
    }

    var level_edges: std.ArrayList(WEdge) = .empty;
    defer level_edges.deinit(allocator);
    try level_edges.ensureTotalCapacity(allocator, edges.len);
    for (edges) |e| {
        if (e.a >= n or e.b >= n or e.a == e.b) continue;
        level_edges.appendAssumeCapacity(.{ .a = e.a, .b = e.b, .w = e.w });
    }

    // Masses track how many original nodes each (super)node stands for, so a heavy community
    // clears proportionally more room than a lone note.
    var mass = try allocator.alloc(f32, n);
    defer allocator.free(mass);
    @memset(mass, 1);

    // -- coarsen -----------------------------------------------------------------------
    // Each entry maps that level's nodes up to the next coarser level's.
    var ladder: std.ArrayList([]u32) = .empty;
    var counts: std.ArrayList(usize) = .empty;
    var hand_off = false;
    defer if (!hand_off) {
        for (ladder.items) |m| allocator.free(m);
        ladder.deinit(allocator);
        counts.deinit(allocator);
    };
    try counts.append(allocator, n);

    // Level 0 is deduplicated like every level above it, where `contract` has always done this.
    // A pair listed twice becomes one edge of twice the weight rather than two that both pull,
    // which is both the correct reading and a large saving: it is the largest edge list in the
    // solve, and `match` picks better pairs from it, so the ladder coarsens faster as well. On a
    // real wiki this alone took the solve from 51 s to 22 s and produced a map 2.4x more compact
    // with shorter links in absolute terms.
    try dedup(allocator, &level_edges);

    // Each level's edge list and masses, kept rather than rebuilt.
    //
    // The refine pass needs level L's edges after the solve at level L+1. Re-deriving them by
    // contracting the *original* edges through the remaining ladder — which is what this used to
    // do — is O(E) work plus a full sort of E per level, so O(E·L²) overall with L sorts of the
    // entire input. On a real wiki (3.3M links, ten levels) that was the dominant cost of the
    // whole solve: 53 s, most of it re-deriving edge lists that had already been computed on the
    // way down. Keeping them costs the sum over levels, and levels shrink geometrically, so the
    // total is about 2·E — roughly 80 MB at 3.3M links, freed level by level as the refine
    // descends.
    var level_sets: std.ArrayList([]WEdge) = .empty;
    var level_mass: std.ArrayList([]f32) = .empty;
    defer {
        for (level_sets.items) |e| allocator.free(e);
        for (level_mass.items) |m| allocator.free(m);
        level_sets.deinit(allocator);
        level_mass.deinit(allocator);
    }
    try level_sets.append(allocator, try allocator.dupe(WEdge, level_edges.items));
    try level_mass.append(allocator, try allocator.dupe(f32, mass));

    var cur_n = n;
    while (cur_n > coarsest_n and ladder.items.len < max_levels) {
        if (opts.cancel) |c| if (c.load(.monotonic)) return error.Canceled;
        const parent = try allocator.alloc(u32, cur_n);
        errdefer allocator.free(parent);
        const coarse_n = try match(allocator, cur_n, level_edges.items, parent);
        if (@as(f32, @floatFromInt(coarse_n)) > @as(f32, @floatFromInt(cur_n)) * min_shrink) {
            allocator.free(parent);
            break;
        }

        // Fold masses and edges up to the coarse level.
        const coarse_mass = try allocator.alloc(f32, coarse_n);
        @memset(coarse_mass, 0);
        for (0..cur_n) |i| coarse_mass[parent[i]] += mass[i];
        allocator.free(mass);
        mass = coarse_mass;

        try contract(allocator, &level_edges, parent);

        try ladder.append(allocator, parent);
        try counts.append(allocator, coarse_n);
        try level_sets.append(allocator, try allocator.dupe(WEdge, level_edges.items));
        try level_mass.append(allocator, try allocator.dupe(f32, mass));
        cur_n = coarse_n;
    }

    // -- solve the coarsest ------------------------------------------------------------
    var pos = try allocator.alloc(dvui.Point, cur_n);
    defer allocator.free(pos);
    seedSpiral(pos[0..cur_n]);
    try relax(allocator, cur_n, level_edges.items, mass, pos, opts.max_iters, opts.cancel);

    // -- project back down -------------------------------------------------------------
    var level = ladder.items.len;
    while (level > 0) {
        level -= 1;
        const parent = ladder.items[level];
        const fine_n = counts.items[level];
        const coarse_n = counts.items[level + 1];

        // Density is held constant, so a level with more nodes occupies proportionally more
        // area. Without this the graph would be re-compressed into the coarse level's footprint
        // at every step and all the structure just decided would be squeezed back out.
        const scale = @sqrt(@as(f32, @floatFromInt(fine_n)) / @as(f32, @floatFromInt(coarse_n)));

        const fine_pos = try allocator.alloc(dvui.Point, fine_n);
        for (0..fine_n) |i| {
            const p = pos[parent[i]];
            // Split a supernode's children by a deterministic jitter, or they start exactly on
            // top of each other and the repulsion has no direction to push them apart in.
            const j = jitter(i);
            fine_pos[i] = .{
                .x = p.x * scale + j[0] * spacing * 0.4,
                .y = p.y * scale + j[1] * spacing * 0.4,
            };
        }
        allocator.free(pos);
        pos = fine_pos;

        // This level's edges and masses, as computed on the way down.
        const fine_edges = level_sets.items[level];
        const fine_mass = level_mass.items[level];
        std.debug.assert(fine_mass.len == fine_n);

        // Taper: coarse levels are cheap and decide everything, fine levels are expensive and
        // only refine. Iterations fall off as the node count climbs.
        const t = @as(f32, @floatFromInt(level)) / @as(f32, @floatFromInt(@max(ladder.items.len, 1)));
        const iters_f = @as(f32, @floatFromInt(opts.min_iters)) +
            (@as(f32, @floatFromInt(opts.max_iters)) - @as(f32, @floatFromInt(opts.min_iters))) * t;
        try relax(allocator, fine_n, fine_edges, fine_mass, pos, @intFromFloat(iters_f), opts.cancel);

        // Done with this level; the finer ones below still have to be held.
        allocator.free(level_sets.items[level]);
        level_sets.items[level] = &.{};
        allocator.free(level_mass.items[level]);
        level_mass.items[level] = &.{};
    }

    @memcpy(out[0..n], pos[0..n]);
    centre(out[0..n]);

    if (opts.keep_ladder) |k| {
        k.* = .{
            .maps = try ladder.toOwnedSlice(allocator),
            .counts = try counts.toOwnedSlice(allocator),
        };
        hand_off = true;
    }
}

/// Heavy-edge matching: pair each unmatched node with its heaviest unmatched neighbour. Writes
/// `parent[i]` = the coarse node `i` belongs to, and returns the coarse node count.
fn match(allocator: std.mem.Allocator, n: usize, edges: []const WEdge, parent: []u32) !usize {
    const none = std.math.maxInt(u32);
    @memset(parent, none);

    // Adjacency in CSR form — built fresh each pass, which is O(n + e) and not worth caching
    // since the edge set changes every level.
    const starts = try allocator.alloc(u32, n + 1);
    defer allocator.free(starts);
    @memset(starts, 0);
    for (edges) |e| {
        starts[e.a + 1] += 1;
        starts[e.b + 1] += 1;
    }
    for (1..starts.len) |i| starts[i] += starts[i - 1];

    const adj = try allocator.alloc(u32, edges.len * 2);
    defer allocator.free(adj);
    const w = try allocator.alloc(f32, edges.len * 2);
    defer allocator.free(w);
    const cursor = try allocator.alloc(u32, n);
    defer allocator.free(cursor);
    @memcpy(cursor, starts[0..n]);
    for (edges) |e| {
        adj[cursor[e.a]] = e.b;
        w[cursor[e.a]] = e.w;
        cursor[e.a] += 1;
        adj[cursor[e.b]] = e.a;
        w[cursor[e.b]] = e.w;
        cursor[e.b] += 1;
    }

    var next: u32 = 0;
    for (0..n) |i| {
        if (parent[i] != none) continue;
        var best: ?u32 = null;
        var best_w: f32 = -1;
        for (starts[i]..starts[i + 1]) |k| {
            const j = adj[k];
            if (parent[j] != none) continue;
            if (w[k] > best_w) {
                best_w = w[k];
                best = j;
            }
        }
        parent[i] = next;
        if (best) |j| parent[j] = next;
        next += 1;
    }

    // Second pass: fold the leftovers into a neighbour's group.
    //
    // Heavy-edge matching only pairs a node with an *unmatched* neighbour, and on a scale-free
    // graph that stalls badly. Hubs are claimed in the first few steps, and the thousands of
    // notes pendant to them then find every neighbour already taken and become groups of one, so
    // the level barely shrinks. Measured on a 284k-note vault: 281k -> 192k -> 143k -> 115k ->
    // 99k, each step worse than the last, until `min_shrink` gave up. The "coarsest" graph the
    // solve then started from still had 99k nodes and 1.7M edges, and every level on the way back
    // down cost nearly as much as the finest — which is most of why a solve took twenty seconds.
    //
    // Letting a leftover join a group that is already formed is what unblocks it, capped at
    // `group_max` so one hub cannot swallow its entire neighbourhood into a single supernode and
    // flatten the structure the ladder exists to find.
    const size = try allocator.alloc(u32, next);
    defer allocator.free(size);
    @memset(size, 0);
    for (0..n) |i| size[parent[i]] += 1;
    for (0..n) |i| {
        if (size[parent[i]] != 1) continue;
        var best: ?u32 = null;
        var best_w: f32 = -1;
        for (starts[i]..starts[i + 1]) |k| {
            const j = adj[k];
            if (j == i or parent[j] == parent[i]) continue;
            if (size[parent[j]] >= group_max) continue;
            if (w[k] > best_w) {
                best_w = w[k];
                best = j;
            }
        }
        const j = best orelse continue;
        size[parent[i]] -= 1;
        parent[i] = parent[j];
        size[parent[i]] += 1;
    }

    // Compact: the fold above leaves holes in the numbering, and the caller takes the count as
    // the next level's node count.
    const remap = try allocator.alloc(u32, next);
    defer allocator.free(remap);
    @memset(remap, none);
    var out: u32 = 0;
    for (0..n) |i| {
        const g = parent[i];
        if (remap[g] == none) {
            remap[g] = out;
            out += 1;
        }
        parent[i] = remap[g];
    }
    return out;
}

/// Rewrite `edges` in terms of `parent`, dropping self-loops and summing duplicates.
fn contract(allocator: std.mem.Allocator, edges: *std.ArrayList(WEdge), parent: []const u32) !void {
    var w: usize = 0;
    for (edges.items) |e| {
        const a = parent[e.a];
        const b = parent[e.b];
        if (a == b) continue;
        edges.items[w] = .{ .a = @min(a, b), .b = @max(a, b), .w = e.w };
        w += 1;
    }
    edges.shrinkRetainingCapacity(w);
    try dedup(allocator, edges);
}

fn edgeKey(e: WEdge) u64 {
    return (@as(u64, e.a) << 32) | @as(u64, e.b);
}

fn dedup(allocator: std.mem.Allocator, edges: *std.ArrayList(WEdge)) !void {
    for (edges.items) |*e| {
        const a = @min(e.a, e.b);
        const b = @max(e.a, e.b);
        e.a = a;
        e.b = b;
    }
    // Radix, not a comparison sort. This runs once per coarsening level over the whole edge set
    // — 2.7M pairs at the finest — and `std.mem.sort` on that is hundreds of milliseconds a level.
    // The key is the canonicalised pair, which is exactly what the dedup below scans for.
    const scratch = try allocator.alloc(WEdge, edges.items.len);
    defer allocator.free(scratch);
    const sorted = radix.sortByKey(WEdge, edgeKey, edges.items, scratch);
    if (sorted.ptr != edges.items.ptr) @memcpy(edges.items, sorted);
    var w: usize = 0;
    for (edges.items) |e| {
        if (w > 0 and edges.items[w - 1].a == e.a and edges.items[w - 1].b == e.b) {
            edges.items[w - 1].w += e.w;
            continue;
        }
        edges.items[w] = e;
        w += 1;
    }
    edges.shrinkRetainingCapacity(w);
}

/// One level's force solve: mass-weighted short-range repulsion through a bucket grid, LinLog
/// attraction along edges, a whisper of gravity to keep the cloud from drifting.
fn relax(
    allocator: std.mem.Allocator,
    n: usize,
    edges: []const WEdge,
    mass: []const f32,
    pos: []dvui.Point,
    iters: usize,
    cancel: ?*std.atomic.Value(bool),
) !void {
    if (n < 2 or iters == 0) return;
    const force = try allocator.alloc(dvui.Point, n);
    defer allocator.free(force);

    // Per-thread accumulators for the spring pass, allocated once for the whole relax rather than
    // per iteration. Null when the level is small enough to run on one thread.
    var scratch: ?[][]dvui.Point = null;
    defer if (scratch) |bufs| {
        for (bufs) |b| allocator.free(b);
        allocator.free(bufs);
    };
    if (edges.len >= attract_thread_min) {
        const want = std.Thread.getCpuCount() catch 1;
        const threads = @min(@max(want, 1), repel_threads_max);
        if (threads > 1) {
            const bufs = try allocator.alloc([]dvui.Point, threads);
            var made: usize = 0;
            errdefer {
                for (bufs[0..made]) |b| allocator.free(b);
                allocator.free(bufs);
            }
            while (made < threads) : (made += 1) bufs[made] = try allocator.alloc(dvui.Point, n);
            scratch = bufs;
        }
    }

    for (0..iters) |it| {
        if (cancel) |c| if (c.load(.monotonic)) return error.Canceled;
        @memset(force, .{});
        const temp = 1.0 - @as(f32, @floatFromInt(it)) / @as(f32, @floatFromInt(iters));
        const step = spacing * (0.55 * temp + 0.08);

        var grid = try Grid.init(allocator, pos, n, repulse_cut);
        defer grid.deinit(allocator);
        grid.repel(n, pos, force, mass);

        attract(edges, mass, pos, force, scratch);

        for (0..n) |i| {
            var fx = force[i].x - pos[i].x * gravity_k;
            var fy = force[i].y - pos[i].y * gravity_k;
            const fl = @sqrt(fx * fx + fy * fy);
            if (fl > step and fl > 1e-6) {
                fx *= step / fl;
                fy *= step / fl;
            }
            pos[i].x += fx;
            pos[i].y += fy;
        }
    }
}

/// Edge count below which the spring pass stays on one thread.
const attract_thread_min: usize = 200_000;

/// Springs along every link, in parallel when there are enough of them.
///
/// Unlike repulsion this writes *both* endpoints, and an edge range does not own its nodes — so
/// each thread accumulates into a buffer of its own and the buffers are summed afterwards. The
/// partition is by edge index and fixed, so the reduction always adds the same partial sums in
/// the same order: the answer does not move between runs, which `solve` is required to guarantee.
///
/// Measured at 284k notes this was 1.94 s of a 3.45 s solve once repulsion had been bounded and
/// threaded — the whole ladder walks 420M edges.
fn attract(
    edges: []const WEdge,
    mass: []const f32,
    pos: []const dvui.Point,
    force: []dvui.Point,
    scratch: ?[][]dvui.Point,
) void {
    const bufs = scratch orelse {
        attractRange(edges, mass, pos, force);
        return;
    };
    const threads = bufs.len;
    const chunk = (edges.len + threads - 1) / threads;
    var handles: [repel_threads_max]std.Thread = undefined;
    var spawned: usize = 0;
    while (spawned < threads) : (spawned += 1) {
        const lo = spawned * chunk;
        if (lo >= edges.len) break;
        const hi = @min(lo + chunk, edges.len);
        @memset(bufs[spawned], .{});
        handles[spawned] = std.Thread.spawn(.{}, attractRange, .{ edges[lo..hi], mass, pos, bufs[spawned] }) catch {
            attractRange(edges[lo..hi], mass, pos, bufs[spawned]);
            spawned += 1;
            break;
        };
    }
    for (handles[0..spawned]) |h| h.join();
    for (bufs[0..spawned]) |b| {
        for (force, b) |*f, add| {
            f.x += add.x;
            f.y += add.y;
        }
    }
}

fn attractRange(edges: []const WEdge, mass: []const f32, pos: []const dvui.Point, force: []dvui.Point) void {
    for (edges) |e| {
        const dx = pos[e.b].x - pos[e.a].x;
        const dy = pos[e.b].y - pos[e.a].y;
        const d = @sqrt(dx * dx + dy * dy);
        if (d < 1e-4) continue;
        // LinLog: long links pull hard, short ones barely at all, which is what keeps a cluster
        // from collapsing to a point once it is already together.
        const mag = spring_k * e.w * @log(1.0 + d / spacing);
        const fx = (dx / d) * mag;
        const fy = (dy / d) * mag;
        // Divided by mass: a supernode standing for a whole community should not be flung around
        // by one link the way a single note is.
        force[e.a].x += fx / mass[e.a];
        force[e.a].y += fy / mass[e.a];
        force[e.b].x -= fx / mass[e.b];
        force[e.b].y -= fy / mass[e.b];
    }
}

/// Bucket grid sized to the repulsion cutoff — the same trick `layout_full` uses, kept local so
/// this file has no dependency on it.
const Grid = struct {
    cell: f32,
    min_x: f32,
    min_y: f32,
    cols: usize,
    rows: usize,
    starts: []u32,
    items: []u32,

    const max_cells: usize = 1 << 21;

    fn init(allocator: std.mem.Allocator, pos: []const dvui.Point, n: usize, cell: f32) !Grid {
        var min_x: f32 = std.math.floatMax(f32);
        var min_y: f32 = std.math.floatMax(f32);
        var max_x: f32 = -std.math.floatMax(f32);
        var max_y: f32 = -std.math.floatMax(f32);
        for (pos[0..n]) |p| {
            min_x = @min(min_x, p.x);
            min_y = @min(min_y, p.y);
            max_x = @max(max_x, p.x);
            max_y = @max(max_y, p.y);
        }
        const c = @max(cell, 1e-3);
        var cols = @as(usize, @intFromFloat(@floor((max_x - min_x) / c))) + 1;
        var rows = @as(usize, @intFromFloat(@floor((max_y - min_y) / c))) + 1;
        if (cols * rows > max_cells) {
            cols = 1;
            rows = 1;
        }
        const starts = try allocator.alloc(u32, cols * rows + 1);
        errdefer allocator.free(starts);
        const items = try allocator.alloc(u32, n);
        var g: Grid = .{
            .cell = c,
            .min_x = min_x,
            .min_y = min_y,
            .cols = cols,
            .rows = rows,
            .starts = starts,
            .items = items,
        };
        @memset(starts, 0);
        for (pos[0..n]) |p| starts[g.cellOf(p) + 1] += 1;
        for (1..starts.len) |i| starts[i] += starts[i - 1];
        const cursor = try allocator.alloc(u32, cols * rows);
        defer allocator.free(cursor);
        @memcpy(cursor, starts[0 .. cols * rows]);
        for (pos[0..n], 0..) |p, i| {
            const ci = g.cellOf(p);
            items[cursor[ci]] = @intCast(i);
            cursor[ci] += 1;
        }
        return g;
    }

    fn deinit(g: *Grid, allocator: std.mem.Allocator) void {
        allocator.free(g.starts);
        allocator.free(g.items);
    }

    fn cellOf(g: Grid, p: dvui.Point) usize {
        const cx = std.math.clamp(@as(isize, @intFromFloat(@floor((p.x - g.min_x) / g.cell))), 0, @as(isize, @intCast(g.cols - 1)));
        const cy = std.math.clamp(@as(isize, @intFromFloat(@floor((p.y - g.min_y) / g.cell))), 0, @as(isize, @intCast(g.rows - 1)));
        return @as(usize, @intCast(cy)) * g.cols + @as(usize, @intCast(cx));
    }

    /// Short-range repulsion, with the work per cell bounded.
    ///
    /// A uniform grid is only linear while occupancy is uniform, and a force layout of a real
    /// vault is the opposite of uniform: it *builds* dense cores, which is the point. Measured at
    /// 284k notes, the grid was 265x266 with an average of 4 notes per cell — and a maximum of
    /// 739, with 499 cells over 64. The all-pairs walk inside a cell is quadratic in occupancy, so
    /// those few hundred cells produced `sum(b^2)` = 49.5M and, with the neighbour offsets, about
    /// 250M pair evaluations per iteration. That was 579 ms of a 592 ms iteration: repulsion was
    /// 98% of the solve, and attraction over all 2.7M links was 11 ms of it.
    ///
    /// So a crowded cell is sampled rather than enumerated: at most `repel_cell_cap` partners,
    /// taken at a fixed stride, with the force scaled by how many were skipped. The expected force
    /// is unchanged — it is the same sum, estimated from an evenly spaced subset — and the
    /// direction is averaged over nine cells' worth of samples, which is far more than a layout
    /// needs. Work becomes `n * 9 * min(occupancy, cap)` no matter how tight the cores get.
    ///
    /// The stride and its offset come from the node index, never a PRNG: `solve` is required to be
    /// a pure function of the graph, and a sampled force that moved between runs would break that
    /// as surely as a random seed would.
    /// Split the node range across cores.
    ///
    /// Safe because `repelRange` writes `force[i]` for its own `i` and nothing else — the
    /// reaction on a partner lands when that partner's own index comes round, which is what the
    /// per-node form above bought. Ranges are disjoint, so there is no sharing to guard, and the
    /// result does not depend on how the threads interleave: each slot is written by exactly one
    /// thread computing exactly the same sum it would have computed alone. `solve` stays a pure
    /// function of the graph.
    fn repel(g: Grid, n: usize, pos: []const dvui.Point, force: []dvui.Point, mass: []const f32) void {
        const want = std.Thread.getCpuCount() catch 1;
        const threads = @min(@max(want, 1), repel_threads_max);
        // Below this the split costs more than it saves, and the coarse levels of the ladder are
        // all below it.
        // Exact below the size where the sampling is worth anything.
        //
        // The cap bounds the quadratic tail of a *crowded* grid. On a small graph every cell is
        // crowded relative to a cap of two, so sampling there is not bounding a tail, it is
        // throwing away most of the force — two hundred unlinked notes stopped pushing each other
        // apart and piled up, which `disconnected nodes do not stack on the origin` catches.
        const cap: usize = if (n < repel_exact_max) std.math.maxInt(usize) else repel_cell_cap;
        if (threads <= 1 or n < repel_thread_min) {
            g.repelRange(0, n, cap, pos, force, mass);
            return;
        }
        var handles: [repel_threads_max]std.Thread = undefined;
        const chunk = (n + threads - 1) / threads;
        var spawned: usize = 0;
        while (spawned < threads) : (spawned += 1) {
            const lo = spawned * chunk;
            if (lo >= n) break;
            const hi = @min(lo + chunk, n);
            handles[spawned] = std.Thread.spawn(.{}, Grid.repelRange, .{ g, lo, hi, cap, pos, force, mass }) catch break;
        }
        // Whatever failed to spawn is done on this thread, so a thread-starved system is slower
        // rather than wrong.
        if (spawned < threads) {
            const lo = spawned * chunk;
            if (lo < n) g.repelRange(lo, n, cap, pos, force, mass);
        }
        for (handles[0..spawned]) |h| h.join();
    }

    fn repelRange(g: Grid, from: usize, to: usize, cap: usize, pos: []const dvui.Point, force: []dvui.Point, mass: []const f32) void {
        for (from..to) |i| {
            const p = pos[i];
            const cx0 = std.math.clamp(@as(isize, @intFromFloat(@floor((p.x - g.min_x) / g.cell))), 0, @as(isize, @intCast(g.cols - 1)));
            const cy0 = std.math.clamp(@as(isize, @intFromFloat(@floor((p.y - g.min_y) / g.cell))), 0, @as(isize, @intCast(g.rows - 1)));
            var dy: isize = -1;
            while (dy <= 1) : (dy += 1) {
                const ny = cy0 + dy;
                if (ny < 0 or ny >= g.rows) continue;
                var dx: isize = -1;
                while (dx <= 1) : (dx += 1) {
                    const nx = cx0 + dx;
                    if (nx < 0 or nx >= g.cols) continue;
                    const nc = @as(usize, @intCast(ny)) * g.cols + @as(usize, @intCast(nx));
                    const bucket = g.items[g.starts[nc]..g.starts[nc + 1]];
                    if (bucket.len <= cap) {
                        for (bucket) |j| {
                            if (j != i) pairForceOn(pos, force, mass, @intCast(i), j, 1);
                        }
                        continue;
                    }
                    const stride = bucket.len / cap;
                    const scale = @as(f32, @floatFromInt(bucket.len)) / @as(f32, @floatFromInt(cap));
                    var k: usize = i % stride;
                    var taken: usize = 0;
                    while (k < bucket.len and taken < cap) : ({
                        k += stride;
                        taken += 1;
                    }) {
                        const j = bucket[k];
                        if (j != i) pairForceOn(pos, force, mass, @intCast(i), j, scale);
                    }
                }
            }
        }
    }
};

/// Partners examined in one cell before the rest are sampled. See `Grid.repel`.
const repel_cell_cap: usize = 2;
/// Cores the repulsion pass will use, and the node count below which it stays single-threaded.
const repel_threads_max: usize = 16;
const repel_thread_min: usize = 20_000;
/// Node count below which repulsion is exact — see `Grid.repel`.
const repel_exact_max: usize = 20_000;

/// One partner's repulsion, applied to `ia` only.
///
/// The reaction lands when `ib`'s own turn comes round, which is what lets a crowded cell be
/// sampled from each side independently. `scale` stands for the partners this one was drawn in
/// place of.
fn pairForceOn(pos: []const dvui.Point, force: []dvui.Point, mass: []const f32, ia: u32, ib: u32, scale: f32) void {
    const i: usize = ia;
    const j: usize = ib;
    var dx = pos[i].x - pos[j].x;
    var dy = pos[i].y - pos[j].y;
    var d2 = dx * dx + dy * dy;
    if (d2 < 1e-8) {
        const jt = jitter(@min(i, j) * 31 + @max(i, j));
        dx = jt[0] * 1e-3;
        dy = jt[1] * 1e-3;
        d2 = dx * dx + dy * dy;
    }
    const d = @sqrt(d2);
    if (d > repulse_cut) return;
    const soft = @max(d, spacing * 0.35);
    const m = @sqrt(mass[i] * mass[j]);
    const mag = repulse_k * m / (soft * soft) * (1.0 - d / repulse_cut) * scale;
    force[i].x += (dx / d) * mag / mass[i];
    force[i].y += (dy / d) * mag / mass[i];
}

fn pairForce(pos: []const dvui.Point, force: []dvui.Point, mass: []const f32, ia: u32, ib: u32) void {
    const i: usize = ia;
    const j: usize = ib;
    var dx = pos[i].x - pos[j].x;
    var dy = pos[i].y - pos[j].y;
    var d2 = dx * dx + dy * dy;
    if (d2 < 1e-8) {
        const jt = jitter(@min(i, j) * 31 + @max(i, j));
        dx = jt[0] * 1e-3;
        dy = jt[1] * 1e-3;
        d2 = dx * dx + dy * dy;
    }
    const d = @sqrt(d2);
    if (d > repulse_cut) return;
    const soft = @max(d, spacing * 0.35);
    // Mass-weighted so heavy communities open real voids around themselves — this is the force
    // that produces the empty space between clusters.
    const m = @sqrt(mass[i] * mass[j]);
    const mag = repulse_k * m / (soft * soft) * (1.0 - d / repulse_cut);
    const fx = (dx / d) * mag;
    const fy = (dy / d) * mag;
    force[i].x += fx / mass[i];
    force[i].y += fy / mass[i];
    force[j].x -= fx / mass[j];
    force[j].y -= fy / mass[j];
}

fn seedSpiral(pos: []dvui.Point) void {
    const golden = 2.39996322972865332;
    for (pos, 0..) |*p, i| {
        const r = spacing * 0.9 * @sqrt(@as(f32, @floatFromInt(i)) + 0.5);
        const a = @as(f32, @floatFromInt(i)) * golden;
        p.* = .{ .x = @cos(a) * r, .y = @sin(a) * r };
    }
}

fn centre(pts: []dvui.Point) void {
    var cx: f32 = 0;
    var cy: f32 = 0;
    for (pts) |p| {
        cx += p.x;
        cy += p.y;
    }
    const inv = 1.0 / @as(f32, @floatFromInt(pts.len));
    cx *= inv;
    cy *= inv;
    for (pts) |*p| {
        p.x -= cx;
        p.y -= cy;
    }
}

fn jitter(i: usize) [2]f32 {
    var h: u32 = @truncate(i);
    h ^= h >> 16;
    h *%= 0x7feb352d;
    h ^= h >> 15;
    h *%= 0x846ca68b;
    h ^= h >> 16;
    const x = @as(f32, @floatFromInt(h & 0xffff)) / 32768.0 - 1.0;
    const y = @as(f32, @floatFromInt((h >> 16) & 0xffff)) / 32768.0 - 1.0;
    return .{ x, y };
}

// -- tests ------------------------------------------------------------------------

const testing = std.testing;

test "two linked nodes end up about one spacing apart" {
    var out: [2]dvui.Point = undefined;
    try solve(testing.allocator, 2, &.{.{ .a = 0, .b = 1 }}, &out, .{});
    const d = @sqrt((out[0].x - out[1].x) * (out[0].x - out[1].x) +
        (out[0].y - out[1].y) * (out[0].y - out[1].y));
    try testing.expect(d > spacing * 0.3 and d < spacing * 4);
}

test "two cliques joined by one link separate into two blobs" {
    // The property a single-level solve cannot deliver: structure larger than the force range.
    const n = 60;
    var edges: std.ArrayList(Edge) = .empty;
    defer edges.deinit(testing.allocator);
    for (0..30) |i| {
        for (i + 1..30) |j| {
            try edges.append(testing.allocator, .{ .a = @intCast(i), .b = @intCast(j) });
            try edges.append(testing.allocator, .{ .a = @intCast(i + 30), .b = @intCast(j + 30) });
        }
    }
    try edges.append(testing.allocator, .{ .a = 0, .b = 30 });

    var out: [n]dvui.Point = undefined;
    try solve(testing.allocator, n, edges.items, &out, .{});

    var ca: dvui.Point = .{};
    var cb: dvui.Point = .{};
    for (0..30) |i| {
        ca.x += out[i].x / 30;
        ca.y += out[i].y / 30;
        cb.x += out[i + 30].x / 30;
        cb.y += out[i + 30].y / 30;
    }
    const gap = @sqrt((ca.x - cb.x) * (ca.x - cb.x) + (ca.y - cb.y) * (ca.y - cb.y));

    // Mean distance from a member to its own clique's centre.
    var spread: f32 = 0;
    for (0..30) |i| {
        spread += @sqrt((out[i].x - ca.x) * (out[i].x - ca.x) + (out[i].y - ca.y) * (out[i].y - ca.y)) / 30;
    }
    try testing.expect(gap > spread);
}

test "disconnected nodes do not stack on the origin" {
    const n = 200;
    var out: [n]dvui.Point = undefined;
    try solve(testing.allocator, n, &.{}, &out, .{});
    var min_d: f32 = std.math.floatMax(f32);
    for (0..n) |i| {
        for (i + 1..n) |j| {
            const d = @sqrt((out[i].x - out[j].x) * (out[i].x - out[j].x) +
                (out[i].y - out[j].y) * (out[i].y - out[j].y));
            min_d = @min(min_d, d);
        }
    }
    try testing.expect(min_d > spacing * 0.05);
}
