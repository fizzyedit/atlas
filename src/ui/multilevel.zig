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

/// Where a solve spent its time. Accumulated across every component and every level, reset by the
/// caller. Counting nanoseconds costs nothing against the work being counted, and every speed-up
/// in this file so far has come from finding out which phase was actually large — twice after
/// optimising the wrong one first.
pub const Prof = struct {
    grid_ns: u64 = 0,
    pyramid_ns: u64 = 0,
    traverse_ns: u64 = 0,
    attract_ns: u64 = 0,
    integrate_ns: u64 = 0,
    coarsen_ns: u64 = 0,

    pub fn total(self: Prof) u64 {
        return self.grid_ns + self.pyramid_ns + self.traverse_ns + self.attract_ns +
            self.integrate_ns + self.coarsen_ns;
    }
};
pub var prof: Prof = .{};

fn pnow() i128 {
    // Inert under test: the clock reads `dvui.io`, which a headless test never initialises, so
    // asking it there is a segfault rather than a measurement.
    if (@import("builtin").is_test) return 0;
    return std.Io.Clock.boot.now(dvui.io).nanoseconds;
}

fn plap(mark: *i128) u64 {
    const t = pnow();
    defer mark.* = t;
    return @intCast(t - mark.*);
}

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

const repulse_k: f32 = 0.45;
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
        var ct = pnow();
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
        prof.coarsen_ns += plap(&ct);
        cur_n = coarse_n;
    }

    // -- solve the coarsest ------------------------------------------------------------
    var pos = try allocator.alloc(dvui.Point, cur_n);
    defer allocator.free(pos);
    seedSpiral(pos[0..cur_n]);
    try relax(allocator, n, cur_n, level_edges.items, mass, pos, opts.max_iters, opts.cancel);

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
        try relax(allocator, n, fine_n, fine_edges, fine_mass, pos, @intFromFloat(iters_f), opts.cancel);

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
    /// Nodes in the whole component, not just this level — see `bh_near_cells`.
    n_total: usize,
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

        var pt = pnow();
        var grid = try Grid.init(allocator, pos, n);
        defer grid.deinit(allocator);
        prof.grid_ns += plap(&pt);
        var pyr = try Pyramid.build(allocator, grid, n, pos, mass);
        defer pyr.deinit(allocator);
        prof.pyramid_ns += plap(&pt);
        grid.repel(pyr, n_total, n, pos, force, mass);
        prof.traverse_ns += plap(&pt);

        attract(edges, mass, pos, force, scratch);
        prof.attract_ns += plap(&pt);

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
        prof.integrate_ns += plap(&pt);
    }
}

/// Edge count below which the spring pass stays on one thread. Low for the same reason as
/// `repel_thread_min`: the coarse levels are small and run the most iterations.
const attract_thread_min: usize = 20_000;

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
/// One entry on the Barnes-Hut descent stack.
const Cellref = struct { level: u8, x: u32, y: u32 };

/// Opening angle. A cell is used whole when its width over its distance is below this; wider than
/// that and the traversal descends into it. Smaller is more exact and visits more cells.
///
/// 2.0 is loose — loose enough that even an adjacent cell is taken as a point at its centre of
/// mass. On a real vault that is not only faster but *better*: blurring distant structure leaves
/// the springs to decide it, and they are the ones that know. Measured on simplewiki, 0.7 gave
/// crossing 6.9% at 15.3 s where 2.0 gives 1.4% at 7.2 s.
///
/// Loose is only safe because of `bh_near_cells`. On its own it takes even an adjacent cell as a
/// point at its centre of mass, and a node's immediate neighbours are the ones that must not be
/// approximated — two hundred unlinked notes are *nothing but* their neighbours, so aggregating
/// them left nothing to push them apart and they piled up on the origin.
///
/// The first fix for that keyed the angle off the node count, which was wrong in an instructive
/// way: every coarse level of a large solve has few nodes, and those are the levels the iteration
/// taper spends the most passes on. Tightening the angle there took the traversal from 1.3 s to
/// 4.8 s on simplewiki without helping any real vault. Distinguishing "close" from "small" is what
/// was actually needed.
const bh_theta: f32 = 2.0;

/// Base cells within this radius are always opened, whatever the angle says.
///
/// A guaranteed-exact near field: the nodes close enough to overlap are always paired
/// individually, and everything beyond is free to be a centre of mass. Widening it is what buys
/// non-overlapping discs — on a 1,365-note tree, 2.5 leaves 21.8% of sibling discs overlapping
/// and 6.0 leaves 14.0% — and it costs the square of itself, so a 284k vault cannot have it.
///
/// Keyed on the size of the *problem*, not of the level. An earlier version keyed the opening
/// angle on the level's node count, which sounds the same and is not: every coarse level of a
/// large solve is small, and those are the levels the iteration taper runs hardest, so it made a
/// big vault pay for exactness it could not use. A small vault is small at every level, and can.
const bh_near_cells: f32 = 2.5;
const bh_near_cells_small: f32 = 6.0;

/// Levels of aggregation above the base grid, capped so a pathological extent cannot allocate
/// without bound. Eight doublings reach 256x the base cell, which covers any vault the base cell
/// is sized for.
const bh_levels_max: usize = 12;

/// A pyramid of cell aggregates over the base grid — Barnes-Hut on a regular subdivision.
///
/// Repulsion used to stop at `repulse_cut`, a few node spacings. That is what collapsed the vault
/// into a core: springs pull at *any* distance while nothing pushed back beyond a hair's breadth,
/// so the graph fell inward until only local repulsion held it apart. Measured on simplewiki, 90%
/// of the notes ended up inside 6% of the map's area, and two notes sharing three neighbours sat
/// only 1.7x closer together than two notes picked at random — which is the map failing at the one
/// thing it is for.
///
/// Widening the cutoff fixes the shape and costs the earth: at 24x the reach the solve went from
/// 1.0 s to 13.4 s, because the work per node grows with the *area* it must look at. This gives
/// the same global reach for a cost that grows with its logarithm instead: distant crowds are one
/// force from their centre of mass, and only what is close enough to matter is looked at
/// individually.
const Pyramid = struct {
    /// Level 0 is the base grid's own cells; each level above is 2x2 of the one below.
    com_x: [bh_levels_max][]f32 = undefined,
    com_y: [bh_levels_max][]f32 = undefined,
    mass: [bh_levels_max][]f32 = undefined,
    cols: [bh_levels_max]usize = undefined,
    rows: [bh_levels_max]usize = undefined,
    cell: [bh_levels_max]f32 = undefined,
    levels: usize = 0,
    min_x: f32 = 0,
    min_y: f32 = 0,

    fn build(allocator: std.mem.Allocator, g: Grid, n: usize, pos: []const dvui.Point, mass: []const f32) !Pyramid {
        var p: Pyramid = .{ .min_x = g.min_x, .min_y = g.min_y };
        errdefer p.deinit(allocator);

        // Level 0: centre of mass per base cell, straight from the points.
        p.cols[0] = g.cols;
        p.rows[0] = g.rows;
        p.cell[0] = g.cell;
        p.levels = 1;
        const n0 = g.cols * g.rows;
        p.com_x[0] = try allocator.alloc(f32, n0);
        p.com_y[0] = try allocator.alloc(f32, n0);
        p.mass[0] = try allocator.alloc(f32, n0);
        @memset(p.com_x[0], 0);
        @memset(p.com_y[0], 0);
        @memset(p.mass[0], 0);
        for (0..n) |i| {
            const c = g.cellOf(pos[i]);
            const m = mass[i];
            p.com_x[0][c] += pos[i].x * m;
            p.com_y[0][c] += pos[i].y * m;
            p.mass[0][c] += m;
        }
        for (p.com_x[0], p.com_y[0], p.mass[0]) |*x, *y, m| {
            if (m <= 0) continue;
            x.* /= m;
            y.* /= m;
        }

        // Each level above: 2x2 of the level below, mass-weighted.
        while (p.levels < bh_levels_max and (p.cols[p.levels - 1] > 1 or p.rows[p.levels - 1] > 1)) {
            const k = p.levels;
            const pc = p.cols[k - 1];
            const pr = p.rows[k - 1];
            const cc = (pc + 1) / 2;
            const cr = (pr + 1) / 2;
            p.cols[k] = cc;
            p.rows[k] = cr;
            p.cell[k] = p.cell[k - 1] * 2;
            const nk = cc * cr;
            p.com_x[k] = try allocator.alloc(f32, nk);
            p.com_y[k] = try allocator.alloc(f32, nk);
            p.mass[k] = try allocator.alloc(f32, nk);
            @memset(p.com_x[k], 0);
            @memset(p.com_y[k], 0);
            @memset(p.mass[k], 0);
            for (0..pr) |y| {
                for (0..pc) |x| {
                    const src = y * pc + x;
                    const m = p.mass[k - 1][src];
                    if (m <= 0) continue;
                    const dst = (y / 2) * cc + (x / 2);
                    p.com_x[k][dst] += p.com_x[k - 1][src] * m;
                    p.com_y[k][dst] += p.com_y[k - 1][src] * m;
                    p.mass[k][dst] += m;
                }
            }
            for (p.com_x[k], p.com_y[k], p.mass[k]) |*x, *y, m| {
                if (m <= 0) continue;
                x.* /= m;
                y.* /= m;
            }
            p.levels += 1;
        }
        return p;
    }

    fn deinit(p: *Pyramid, allocator: std.mem.Allocator) void {
        for (0..p.levels) |k| {
            allocator.free(p.com_x[k]);
            allocator.free(p.com_y[k]);
            allocator.free(p.mass[k]);
        }
        p.levels = 0;
    }
};

const Grid = struct {
    cell: f32,
    min_x: f32,
    min_y: f32,
    cols: usize,
    rows: usize,
    starts: []u32,
    items: []u32,

    const max_cells: usize = 1 << 21;

    /// Points per base cell the grid aims for.
    ///
    /// The cell used to be `repulse_cut` wide, because repulsion stopped there and a 3x3
    /// neighbourhood was the whole interaction. Barnes-Hut has no cutoff, so that size means
    /// nothing to it — and once the vault spread out it meant 593,000 mostly-empty cells for
    /// 281,000 points, every one of them walked by the prefix sum and by every level of the
    /// pyramid, every iteration. Sizing to the density instead leaves the cell doing the one job
    /// it still has: holding the handful of points close enough to be worth a pair each.
    const target_per_cell: f32 = 6;

    fn init(allocator: std.mem.Allocator, pos: []const dvui.Point, n: usize) !Grid {
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
        // Sized after the bounding box is known, so the grid tracks the layout as it expands
        // rather than being fixed by a constant from a force model that no longer has a cutoff.
        const area = @max((max_x - min_x) * (max_y - min_y), 1e-6);
        const c = @max(@sqrt(area * target_per_cell / @as(f32, @floatFromInt(@max(n, 1)))), 1e-3);
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
    fn repel(g: Grid, p: Pyramid, n_total: usize, n: usize, pos: []const dvui.Point, force: []dvui.Point, mass: []const f32) void {
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
        const near: f32 = if (n_total < repel_exact_max) bh_near_cells_small else bh_near_cells;
        if (threads <= 1 or n < repel_thread_min) {
            g.repelRange(p, 0, n, cap, near, pos, force, mass);
            return;
        }
        var handles: [repel_threads_max]std.Thread = undefined;
        const chunk = (n + threads - 1) / threads;
        var spawned: usize = 0;
        while (spawned < threads) : (spawned += 1) {
            const lo = spawned * chunk;
            if (lo >= n) break;
            const hi = @min(lo + chunk, n);
            handles[spawned] = std.Thread.spawn(.{}, Grid.repelRange, .{ g, p, lo, hi, cap, near, pos, force, mass }) catch break;
        }
        // Whatever failed to spawn is done on this thread, so a thread-starved system is slower
        // rather than wrong.
        if (spawned < threads) {
            const lo = spawned * chunk;
            if (lo < n) g.repelRange(p, lo, n, cap, near, pos, force, mass);
        }
        for (handles[0..spawned]) |h| h.join();
    }

    /// Every partner in one base cell, sampled if the cell is crowded.
    ///
    /// The sampling is unchanged from the uniform-grid version: a fixed stride, the force scaled
    /// by what was skipped, deterministic in the node index so `solve` stays a pure function of
    /// the graph. It matters more here, not less — Barnes-Hut bounds how many *cells* are visited
    /// and says nothing about how many points sit in the one you are standing in.
    fn repelBucket(
        i: u32,
        bucket: []const u32,
        cap: usize,
        pos: []const dvui.Point,
        force: []dvui.Point,
        mass: []const f32,
    ) void {
        if (bucket.len <= cap) {
            for (bucket) |j| {
                if (j != i) pairForceOn(pos, force, mass, i, j, 1);
            }
            return;
        }
        const stride = bucket.len / cap;
        const scale = @as(f32, @floatFromInt(bucket.len)) / @as(f32, @floatFromInt(cap));
        var k: usize = @as(usize, i) % stride;
        var taken: usize = 0;
        while (k < bucket.len and taken < cap) : ({
            k += stride;
            taken += 1;
        }) {
            const j = bucket[k];
            if (j != i) pairForceOn(pos, force, mass, i, j, scale);
        }
    }

    /// Barnes-Hut traversal for one node: coarse cells whole, near cells individually.
    ///
    /// Starts at the top of the pyramid and descends only where the opening angle demands it, so a
    /// distant community costs one force and the handful of notes actually beside this one cost a
    /// pair each. Force is mass-proportional — `repulse_k * m_j / d^2`, with `m_i` cancelling
    /// against the integrator's division — which is what makes a cell's whole contribution equal
    /// its total mass at its centre, exactly.
    fn repelFar(
        g: Grid,
        p: Pyramid,
        i: u32,
        cap: usize,
        near: f32,
        pos: []const dvui.Point,
        force: []dvui.Point,
        mass: []const f32,
        stack: *[bh_levels_max * 4]Cellref,
    ) void {
        const me = pos[i];
        const near_exact = p.cell[0] * near;
        var fx: f32 = 0;
        var fy: f32 = 0;
        var top: usize = 0;

        const kt = p.levels - 1;
        for (0..p.rows[kt]) |y| {
            for (0..p.cols[kt]) |x| {
                if (top < stack.len) {
                    stack[top] = .{ .level = @intCast(kt), .x = @intCast(x), .y = @intCast(y) };
                    top += 1;
                }
            }
        }

        while (top > 0) {
            top -= 1;
            const node = stack[top];
            const k: usize = node.level;
            const idx = @as(usize, node.y) * p.cols[k] + @as(usize, node.x);
            const m = p.mass[k][idx];
            if (m <= 0) continue;

            const dx = me.x - p.com_x[k][idx];
            const dy = me.y - p.com_y[k][idx];
            const d2 = dx * dx + dy * dy;

            // Close enough to matter individually, or already at the base grid: pair up.
            if (k == 0) {
                const bucket = g.items[g.starts[idx]..g.starts[idx + 1]];
                repelBucket(i, bucket, cap, pos, force, mass);
                continue;
            }
            const d = @sqrt(d2);
            if (p.cell[k] < d * bh_theta and d > near_exact) {
                const soft = @max(d, spacing * 0.35);
                const mag = repulse_k * m / (soft * soft);
                fx += (dx / @max(d, 1e-6)) * mag;
                fy += (dy / @max(d, 1e-6)) * mag;
                continue;
            }
            // Too wide to stand in for its contents: open it.
            const cx0 = @as(usize, node.x) * 2;
            const cy0 = @as(usize, node.y) * 2;
            const kc = k - 1;
            for (0..2) |oy| {
                for (0..2) |ox| {
                    const cx = cx0 + ox;
                    const cy = cy0 + oy;
                    if (cx >= p.cols[kc] or cy >= p.rows[kc]) continue;
                    if (top < stack.len) {
                        stack[top] = .{ .level = @intCast(kc), .x = @intCast(cx), .y = @intCast(cy) };
                        top += 1;
                    }
                }
            }
        }
        force[i].x += fx;
        force[i].y += fy;
    }

    fn repelRange(
        g: Grid,
        p: Pyramid,
        from: usize,
        to: usize,
        cap: usize,
        near: f32,
        pos: []const dvui.Point,
        force: []dvui.Point,
        mass: []const f32,
    ) void {
        // Walked in cell order, not index order.
        //
        // `g.items` is the points grouped by base cell, so consecutive entries are neighbours in
        // space and their descents through the pyramid are nearly the same walk — the same coarse
        // cells, in the same order, already in cache. Iterating raw indices instead sends every
        // node down an unrelated path and turns a traversal into a pointer chase. Ranges over
        // `items` are still disjoint in `i`, since it is a permutation, so the threading argument
        // above is unchanged.
        var stack: [bh_levels_max * 4]Cellref = undefined;
        for (g.items[from..to]) |i| repelFar(g, p, i, cap, near, pos, force, mass, &stack);
    }
};

/// Partners examined in one cell before the rest are sampled. See `Grid.repel`.
const repel_cell_cap: usize = 2;
/// Cores the repulsion pass will use, and the node count below which it stays single-threaded.
///
/// The floor is low on purpose. "Small level, not worth a thread" is the wrong instinct in a
/// multilevel solve: the iteration taper gives the *coarse* levels the most passes — up to
/// `max_iters` against `min_iters` at the finest — so a level with a tenth of the nodes can cost
/// more than the one below it. Leaving those serial left most of the solve on one core.
const repel_threads_max: usize = 16;
const repel_thread_min: usize = 2_000;
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
    // The same law the aggregate uses, and it has to be: a cell standing in for its contents is
    // only honest if opening it would give the same answer. Near and far had drifted apart when
    // Barnes-Hut landed — the far field summed `m_j` while the near field summed
    // `sqrt(m_i*m_j)/m_i`, which agree at the finest level where every mass is 1 and diverge
    // badly at the coarse levels where a supernode stands for a whole subtree. A tree coarsens
    // into exactly those, so its branches were flung out by a repulsion its one spring could not
    // answer.
    //
    // No cutoff either. `repulse_cut` used to bound the interaction *and* size the grid, so the
    // two agreed by construction; the grid is sized to density now, and leaving the taper here
    // left a hole — two notes in the same cell but further apart than the old cutoff got no
    // repulsion from the near field and were never considered by the far field, so they settled
    // on top of each other.
    const soft = @max(d, spacing * 0.35);
    const mag = repulse_k * mass[j] / (soft * soft) * scale;
    force[i].x += (dx / d) * mag;
    force[i].y += (dy / d) * mag;
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
