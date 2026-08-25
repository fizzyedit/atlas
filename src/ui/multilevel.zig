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
    return next;
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

fn dedup(allocator: std.mem.Allocator, edges: *std.ArrayList(WEdge)) !void {
    _ = allocator;
    for (edges.items) |*e| {
        const a = @min(e.a, e.b);
        const b = @max(e.a, e.b);
        e.a = a;
        e.b = b;
    }
    std.mem.sort(WEdge, edges.items, {}, struct {
        fn less(_: void, x: WEdge, y: WEdge) bool {
            if (x.a != y.a) return x.a < y.a;
            return x.b < y.b;
        }
    }.less);
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

    for (0..iters) |it| {
        if (cancel) |c| if (c.load(.monotonic)) return error.Canceled;
        @memset(force, .{});
        const temp = 1.0 - @as(f32, @floatFromInt(it)) / @as(f32, @floatFromInt(iters));
        const step = spacing * (0.55 * temp + 0.08);

        var grid = try Grid.init(allocator, pos, n, repulse_cut);
        defer grid.deinit(allocator);
        grid.repel(pos, force, mass);

        for (edges) |e| {
            const dx = pos[e.b].x - pos[e.a].x;
            const dy = pos[e.b].y - pos[e.a].y;
            const d = @sqrt(dx * dx + dy * dy);
            if (d < 1e-4) continue;
            // LinLog: long links pull hard, short ones barely at all, which is what keeps a
            // cluster from collapsing to a point once it is already together.
            const mag = spring_k * e.w * @log(1.0 + d / spacing);
            const fx = (dx / d) * mag;
            const fy = (dy / d) * mag;
            // Divided by mass: a supernode standing for a whole community should not be flung
            // around by one link the way a single note is.
            force[e.a].x += fx / mass[e.a];
            force[e.a].y += fy / mass[e.a];
            force[e.b].x -= fx / mass[e.b];
            force[e.b].y -= fy / mass[e.b];
        }

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

    fn repel(g: Grid, pos: []const dvui.Point, force: []dvui.Point, mass: []const f32) void {
        const offsets = [_][2]isize{ .{ 1, 0 }, .{ -1, 1 }, .{ 0, 1 }, .{ 1, 1 } };
        for (0..g.rows) |cy| {
            for (0..g.cols) |cx| {
                const c = cy * g.cols + cx;
                const mine = g.items[g.starts[c]..g.starts[c + 1]];
                for (mine, 0..) |ia, k| {
                    for (mine[k + 1 ..]) |ib| pairForce(pos, force, mass, ia, ib);
                }
                for (offsets) |off| {
                    const nx = @as(isize, @intCast(cx)) + off[0];
                    const ny = @as(isize, @intCast(cy)) + off[1];
                    if (nx < 0 or ny < 0 or nx >= g.cols or ny >= g.rows) continue;
                    const nc = @as(usize, @intCast(ny)) * g.cols + @as(usize, @intCast(nx));
                    const theirs = g.items[g.starts[nc]..g.starts[nc + 1]];
                    for (mine) |ia| {
                        for (theirs) |ib| pairForce(pos, force, mass, ia, ib);
                    }
                }
            }
        }
    }
};

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
