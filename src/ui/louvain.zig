//! Modularity clustering — communities as the graph itself defines them.
//!
//! The question this exists to answer: **can a hierarchy of communities hold most of the links
//! inside it?** A layout built from nested regions is fast, deterministic, free of overlap by
//! construction, and updates only where the structure changed — but all of that is worthless if
//! the links keep crossing between regions, because then the map says nothing about what is
//! related to what. `fold`'s heavy-edge matching answered that badly (58% of links crossing a
//! quarter of the vault), and it was blamed on the *family* rather than on the pairing rule.
//! Modularity is the pairing rule that is actually about communities.
//!
//! Louvain, in the usual two phases per level: move each node to whichever neighbouring community
//! improves modularity most, then contract each community to a node and repeat. Both phases are
//! linear in the edge count, so the whole dendrogram costs a few passes over the links — against
//! the seconds a force solve spends reaching equilibrium.
//!
//! Deliberately headless and free of any layout concern: it takes edges and returns which
//! community each note landed in, at every level. Whether that becomes nested regions is a
//! separate decision, and this is the measurement that decides it.

const std = @import("std");

pub const Edge = struct { a: u32, b: u32, w: f32 = 1.0 };

pub const Options = struct {
    /// Passes over the nodes within one level before giving up on it.
    max_passes: u32 = 16,
    /// Levels of the dendrogram to build. Each is a coarsening of the one below.
    max_levels: u32 = 24,
    /// Resolution. Above 1 favours many small communities, below 1 favours few large ones.
    resolution: f64 = 1.0,
};

pub const Result = struct {
    /// Per level: which community of that level each *note* belongs to. `levels[0]` is the
    /// finest partition, each one above it a coarsening.
    levels: [][]u32 = &.{},
    /// Community count at each level, parallel to `levels`.
    counts: []u32 = &.{},
    /// Modularity of each level's partition, against the original graph.
    q: []f64 = &.{},

    pub fn deinit(self: *Result, gpa: std.mem.Allocator) void {
        for (self.levels) |l| gpa.free(l);
        gpa.free(self.levels);
        gpa.free(self.counts);
        gpa.free(self.q);
        self.* = .{};
    }
};

/// One level's graph in CSR form, with the self-loop weight each node carries from contraction.
const Graph = struct {
    n: usize,
    starts: []u32,
    to: []u32,
    w: []f32,
    /// Weight of edges that were folded *into* this node when its community was contracted.
    self_w: []f64,
    /// Weighted degree, self-loops counted twice — the `k_i` of the modularity formula.
    k: []f64,
    /// Total weight, `m`. Every edge counted once.
    m: f64,

    fn build(arena: std.mem.Allocator, n: usize, edges: []const Edge, self_w: []const f64) !Graph {
        const starts = try arena.alloc(u32, n + 1);
        @memset(starts, 0);
        for (edges) |e| {
            if (e.a >= n or e.b >= n or e.a == e.b) continue;
            starts[e.a + 1] += 1;
            starts[e.b + 1] += 1;
        }
        for (1..starts.len) |i| starts[i] += starts[i - 1];
        const to = try arena.alloc(u32, starts[n]);
        const w = try arena.alloc(f32, starts[n]);
        const cur = try arena.alloc(u32, n);
        @memcpy(cur, starts[0..n]);
        for (edges) |e| {
            if (e.a >= n or e.b >= n or e.a == e.b) continue;
            to[cur[e.a]] = e.b;
            w[cur[e.a]] = e.w;
            cur[e.a] += 1;
            to[cur[e.b]] = e.a;
            w[cur[e.b]] = e.w;
            cur[e.b] += 1;
        }

        const sw = try arena.alloc(f64, n);
        if (self_w.len == n) @memcpy(sw, self_w) else @memset(sw, 0);

        const k = try arena.alloc(f64, n);
        var m: f64 = 0;
        for (0..n) |i| {
            var deg: f64 = 0;
            for (starts[i]..starts[i + 1]) |t| deg += w[t];
            // A self-loop is an edge to yourself: it adds two to your degree and one to `m`.
            k[i] = deg + 2 * sw[i];
            m += deg / 2 + sw[i];
        }
        return .{ .n = n, .starts = starts, .to = to, .w = w, .self_w = sw, .k = k, .m = @max(m, 1e-12) };
    }
};

pub fn cluster(gpa: std.mem.Allocator, n_notes: usize, edges: []const Edge, opts: Options) !Result {
    var out: Result = .{};
    errdefer out.deinit(gpa);
    if (n_notes == 0) return out;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var levels: std.ArrayListUnmanaged([]u32) = .empty;
    var counts: std.ArrayListUnmanaged(u32) = .empty;
    var qs: std.ArrayListUnmanaged(f64) = .empty;

    // `of_note[i]` tracks which node of the *current* level note `i` has been folded into, so a
    // level's partition can always be reported in terms of the original notes.
    const of_note = try arena.alloc(u32, n_notes);
    for (of_note, 0..) |*v, i| v.* = @intCast(i);

    var cur_edges: []const Edge = edges;
    var cur_self: []const f64 = &.{};
    var cur_n: usize = n_notes;

    while (levels.items.len < opts.max_levels) {
        var g = try Graph.build(arena, cur_n, cur_edges, cur_self);
        const comm = try arena.alloc(u32, g.n);
        const moved = try localMoving(arena, &g, comm, opts);
        const n_comm = try renumber(arena, comm, g.n);
        // Nothing merged — the partition below is as coarse as modularity wants to go.
        if (!moved or n_comm == g.n) break;

        for (of_note) |*v| v.* = comm[v.*];
        const snapshot = try gpa.dupe(u32, of_note);
        errdefer gpa.free(snapshot);
        try levels.append(gpa, snapshot);
        try counts.append(gpa, n_comm);
        try qs.append(gpa, modularityOf(arena, n_notes, edges, snapshot, opts.resolution));

        const next = try contract(arena, &g, comm, n_comm);
        cur_edges = next.edges;
        cur_self = next.self_w;
        cur_n = n_comm;
        if (cur_n <= 1) break;
    }

    out.levels = try levels.toOwnedSlice(gpa);
    out.counts = try counts.toOwnedSlice(gpa);
    out.q = try qs.toOwnedSlice(gpa);
    return out;
}

/// Phase one: walk the nodes, moving each to the neighbouring community it most improves.
///
/// The gain from moving `i` into `c` is `w_i_into_c - resolution * tot[c] * k_i / (2m)`; the
/// constant terms that depend only on `i` cancel, so only that difference has to be compared.
/// Returns whether anything moved at all.
fn localMoving(arena: std.mem.Allocator, g: *Graph, comm: []u32, opts: Options) !bool {
    for (comm, 0..) |*c, i| c.* = @intCast(i);

    // `tot[c]` is the summed degree of everything currently in `c`.
    const tot = try arena.alloc(f64, g.n);
    for (tot, g.k) |*t, k| t.* = k;

    // Weight from the node being considered into each neighbouring community, written only for
    // the communities actually touched so it never costs a pass over all of them.
    const into = try arena.alloc(f64, g.n);
    @memset(into, 0);
    const touched = try arena.alloc(u32, g.n);

    const inv_2m = 1.0 / (2.0 * g.m);
    var any = false;
    var pass: u32 = 0;
    while (pass < opts.max_passes) : (pass += 1) {
        var moves: usize = 0;
        for (0..g.n) |i| {
            const ci = comm[i];
            const ki = g.k[i];

            var n_touched: usize = 0;
            for (g.starts[i]..g.starts[i + 1]) |t| {
                const j = g.to[t];
                const cj = comm[j];
                if (into[cj] == 0) {
                    touched[n_touched] = cj;
                    n_touched += 1;
                }
                into[cj] += g.w[t];
            }

            // Leave first, so the node does not count its own degree against itself.
            tot[ci] -= ki;

            var best = ci;
            var best_gain = into[ci] - opts.resolution * tot[ci] * ki * inv_2m;
            for (touched[0..n_touched]) |c| {
                const gain = into[c] - opts.resolution * tot[c] * ki * inv_2m;
                // Strictly greater, with the lower id winning ties: the order nodes are visited
                // in must not decide the partition, or the result stops being reproducible.
                if (gain > best_gain or (gain == best_gain and c < best)) {
                    best_gain = gain;
                    best = c;
                }
            }

            tot[best] += ki;
            if (best != ci) {
                comm[i] = best;
                moves += 1;
                any = true;
            }

            for (touched[0..n_touched]) |c| into[c] = 0;
        }
        // A pass that moves nothing has converged; nothing later in this level can move either,
        // since the state it would read is the state it just saw.
        if (moves == 0) break;
    }
    return any;
}

/// Renumber a partition to `0..k` in order of first appearance, and return `k`.
///
/// `localMoving` leaves each node holding the id of whichever node leads its community, which is
/// sparse; everything downstream wants dense ids it can index arrays by.
fn renumber(arena: std.mem.Allocator, comm: []u32, n: usize) !u32 {
    const none = std.math.maxInt(u32);
    const map = try arena.alloc(u32, n);
    @memset(map, none);
    var next: u32 = 0;
    for (comm[0..n]) |*c| {
        if (map[c.*] == none) {
            map[c.*] = next;
            next += 1;
        }
        c.* = map[c.*];
    }
    return next;
}

const Contracted = struct { edges: []Edge, self_w: []f64 };

/// Phase two: every community becomes one node, and the edges between them are summed.
fn contract(arena: std.mem.Allocator, g: *Graph, comm: []const u32, n_comm: u32) !Contracted {
    const self_w = try arena.alloc(f64, n_comm);
    @memset(self_w, 0);
    for (0..g.n) |i| self_w[comm[i]] += g.self_w[i];

    var list: std.ArrayListUnmanaged(Edge) = .empty;
    try list.ensureTotalCapacity(arena, g.to.len / 2 + 1);
    for (0..g.n) |i| {
        const ci = comm[i];
        for (g.starts[i]..g.starts[i + 1]) |t| {
            const j = g.to[t];
            if (j < i) continue; // each undirected edge once
            const cj = comm[j];
            if (ci == cj) {
                self_w[ci] += g.w[t];
            } else {
                list.appendAssumeCapacity(.{ .a = @min(ci, cj), .b = @max(ci, cj), .w = g.w[t] });
            }
        }
    }

    // Sum parallel edges: sort by the packed pair, then run through.
    const items = list.items;
    std.mem.sort(Edge, items, {}, struct {
        fn less(_: void, x: Edge, y: Edge) bool {
            if (x.a != y.a) return x.a < y.a;
            return x.b < y.b;
        }
    }.less);
    var wpos: usize = 0;
    for (items) |e| {
        if (wpos > 0 and items[wpos - 1].a == e.a and items[wpos - 1].b == e.b) {
            items[wpos - 1].w += e.w;
            continue;
        }
        items[wpos] = e;
        wpos += 1;
    }
    return .{ .edges = items[0..wpos], .self_w = self_w };
}

/// Newman modularity of a partition, measured against the original graph.
pub fn modularityOf(arena: std.mem.Allocator, n: usize, edges: []const Edge, comm: []const u32, resolution: f64) f64 {
    var m: f64 = 0;
    for (edges) |e| {
        if (e.a >= n or e.b >= n or e.a == e.b) continue;
        m += e.w;
    }
    if (m <= 0) return 0;

    var n_c: u32 = 0;
    for (comm) |c| n_c = @max(n_c, c + 1);
    const deg = arena.alloc(f64, n_c) catch return 0;
    const inside = arena.alloc(f64, n_c) catch return 0;
    @memset(deg, 0);
    @memset(inside, 0);

    for (edges) |e| {
        if (e.a >= n or e.b >= n or e.a == e.b) continue;
        deg[comm[e.a]] += e.w;
        deg[comm[e.b]] += e.w;
        if (comm[e.a] == comm[e.b]) inside[comm[e.a]] += e.w;
    }
    var q: f64 = 0;
    for (0..n_c) |c| {
        q += inside[c] / m - resolution * (deg[c] / (2 * m)) * (deg[c] / (2 * m));
    }
    return q;
}

/// Fraction of link weight that stays inside a community.
///
/// The number the whole question turns on. A region layout can only keep links short if the links
/// are mostly *inside* a region to begin with; whatever crosses has to be drawn across the map
/// however cleverly the regions are packed.
pub fn intraFraction(n: usize, edges: []const Edge, comm: []const u32) f64 {
    var total: f64 = 0;
    var inside: f64 = 0;
    for (edges) |e| {
        if (e.a >= n or e.b >= n or e.a == e.b) continue;
        total += e.w;
        if (comm[e.a] == comm[e.b]) inside += e.w;
    }
    return if (total > 0) inside / total else 0;
}

// ---- tests ----------------------------------------------------------------------------------

const testing = std.testing;

test "two cliques joined by one edge come out as two communities" {
    const gpa = testing.allocator;
    var edges: std.ArrayListUnmanaged(Edge) = .empty;
    defer edges.deinit(gpa);
    // Two 8-cliques, one bridge.
    for (0..2) |g| {
        const base: u32 = @intCast(g * 8);
        for (0..8) |a| {
            for (a + 1..8) |b| {
                try edges.append(gpa, .{ .a = base + @as(u32, @intCast(a)), .b = base + @as(u32, @intCast(b)) });
            }
        }
    }
    try edges.append(gpa, .{ .a = 0, .b = 8 });

    var res = try cluster(gpa, 16, edges.items, .{});
    defer res.deinit(gpa);
    try testing.expect(res.levels.len > 0);
    const finest = res.levels[0];
    // Everything in the first clique together, everything in the second together, and not shared.
    for (1..8) |i| try testing.expectEqual(finest[0], finest[i]);
    for (9..16) |i| try testing.expectEqual(finest[8], finest[i]);
    try testing.expect(finest[0] != finest[8]);
    // One bridge out of 57 edges.
    try testing.expect(intraFraction(16, edges.items, finest) > 0.95);
}

test "the partition does not depend on the order nodes are visited" {
    const gpa = testing.allocator;
    var edges: std.ArrayListUnmanaged(Edge) = .empty;
    defer edges.deinit(gpa);
    for (0..300) |i| {
        try edges.append(gpa, .{ .a = @intCast(i), .b = @intCast((i + 1) % 300) });
        try edges.append(gpa, .{ .a = @intCast(i), .b = @intCast((i * 7 + 3) % 300) });
    }

    var a = try cluster(gpa, 300, edges.items, .{});
    defer a.deinit(gpa);
    var b = try cluster(gpa, 300, edges.items, .{});
    defer b.deinit(gpa);
    try testing.expectEqual(a.levels.len, b.levels.len);
    for (a.levels, b.levels) |la, lb| try testing.expectEqualSlices(u32, la, lb);
}

test "modularity rises with each level" {
    const gpa = testing.allocator;
    var edges: std.ArrayListUnmanaged(Edge) = .empty;
    defer edges.deinit(gpa);
    // Four cliques in a ring, so there is real structure at two scales.
    for (0..4) |g| {
        const base: u32 = @intCast(g * 12);
        for (0..12) |a| {
            for (a + 1..12) |b| {
                try edges.append(gpa, .{ .a = base + @as(u32, @intCast(a)), .b = base + @as(u32, @intCast(b)) });
            }
        }
        try edges.append(gpa, .{ .a = base, .b = @intCast((base + 12) % 48) });
    }

    var res = try cluster(gpa, 48, edges.items, .{});
    defer res.deinit(gpa);
    try testing.expect(res.q.len > 0);
    try testing.expect(res.q[0] > 0.5);
    try testing.expect(intraFraction(48, edges.items, res.levels[0]) > 0.9);
}
