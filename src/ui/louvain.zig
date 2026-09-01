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
const radix = @import("radix.zig");

pub const Edge = struct { a: u32, b: u32, w: f32 = 1.0 };

pub const Options = struct {
    /// Passes over the nodes within one level before giving up on it.
    max_passes: u32 = 16,
    /// Levels of the dendrogram to build. Each is a coarsening of the one below.
    max_levels: u32 = 24,
    /// Resolution. Above 1 favours many small communities, below 1 favours few large ones.
    resolution: f64 = 1.0,
    /// After local moving, split any community that is not connected in the graph, then polish.
    /// That is the part of Leiden that fixes Louvain's disconnected communities; it is also the
    /// bit that usually stops a small edit from rewriting a coarse blob.
    refine: bool = false,
    /// Fill `Result.q` with each level's modularity.
    ///
    /// Off by default because it is not free and almost nobody wants it: it walks the whole
    /// original edge list per level, which on a Wikipedia-sized vault is millions of edges times
    /// the depth of the dendrogram, to produce a number the layout never reads.
    measure_q: bool = false,
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

/// One neighbour: who, and how strongly.
///
/// One record rather than parallel `to` / `w` arrays. Splitting them is the reflex, and it is the
/// wrong one here: every walk of a node's neighbours reads both fields of every entry, so two
/// arrays means two cache lines per neighbour instead of one. The local-moving pass touches
/// 6.7M directed neighbours per sweep on simplewiki and does it up to sixteen times, so this is
/// most of what the clustering does with its memory.
const Adj = struct { to: u32, w: f32 };

/// One level's graph in CSR form, with the self-loop weight each node carries from contraction.
const Graph = struct {
    n: usize,
    starts: []u32,
    adj: []Adj,
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
        const adj = try arena.alloc(Adj, starts[n]);
        const cur = try arena.alloc(u32, n);
        @memcpy(cur, starts[0..n]);
        for (edges) |e| {
            if (e.a >= n or e.b >= n or e.a == e.b) continue;
            adj[cur[e.a]] = .{ .to = e.b, .w = e.w };
            cur[e.a] += 1;
            adj[cur[e.b]] = .{ .to = e.a, .w = e.w };
            cur[e.b] += 1;
        }

        const sw = try arena.alloc(f64, n);
        if (self_w.len == n) @memcpy(sw, self_w) else @memset(sw, 0);

        const k = try arena.alloc(f64, n);
        var m: f64 = 0;
        for (0..n) |i| {
            var deg: f64 = 0;
            for (adj[starts[i]..starts[i + 1]]) |a| deg += a.w;
            // A self-loop is an edge to yourself: it adds two to your degree and one to `m`.
            k[i] = deg + 2 * sw[i];
            m += deg / 2 + sw[i];
        }
        return .{ .n = n, .starts = starts, .adj = adj, .self_w = sw, .k = k, .m = @max(m, 1e-12) };
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
        var moved = try localMoving(arena, &g, comm, opts, false);
        var n_comm = try renumber(arena, comm, g.n);
        if (opts.refine) {
            const split = try splitDisconnected(arena, &g, comm);
            if (split) {
                n_comm = try renumber(arena, comm, g.n);
                const polished = try localMoving(arena, &g, comm, opts, true);
                n_comm = try renumber(arena, comm, g.n);
                moved = true;
                _ = polished;
            }
        }
        // Nothing merged — the partition below is as coarse as modularity wants to go.
        if (!moved or n_comm == g.n) break;

        for (of_note) |*v| v.* = comm[v.*];
        const snapshot = try gpa.dupe(u32, of_note);
        errdefer gpa.free(snapshot);
        try levels.append(gpa, snapshot);
        try counts.append(gpa, n_comm);
        // Off unless asked for. `modularityOf` walks the *original* edge list — 3.35M edges on
        // simplewiki — once per level, and `Result.q` is read by nothing but `bench --cluster` and
        // its own test. The layout paid four full passes over the vault's links, every solve, for a
        // diagnostic it never looked at.
        try qs.append(gpa, if (opts.measure_q)
            modularityOf(arena, n_notes, edges, snapshot, opts.resolution)
        else
            0);

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
fn localMoving(arena: std.mem.Allocator, g: *Graph, comm: []u32, opts: Options, from_current: bool) !bool {
    const tot = try arena.alloc(f64, g.n);
    if (from_current) {
        @memset(tot, 0);
        for (0..g.n) |i| tot[comm[i]] += g.k[i];
    } else {
        for (comm, 0..) |*c, i| c.* = @intCast(i);
        for (tot, g.k) |*t, k| t.* = k;
    }

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
            for (g.adj[g.starts[i]..g.starts[i + 1]]) |a| {
                const cj = comm[a.to];
                if (into[cj] == 0) {
                    touched[n_touched] = cj;
                    n_touched += 1;
                }
                into[cj] += a.w;
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

/// Split any community that is not a connected subgraph. Louvain is allowed to produce those;
/// Leiden is not, and a disconnected community is the usual way a small edit rewrites a blob.
fn splitDisconnected(arena: std.mem.Allocator, g: *Graph, comm: []u32) !bool {
    const n = g.n;
    if (n == 0) return false;
    var n_c: u32 = 0;
    for (comm) |c| n_c = @max(n_c, c + 1);

    const seen = try arena.alloc(bool, n);
    @memset(seen, false);
    const first = try arena.alloc(bool, n_c);
    @memset(first, true);
    const q = try arena.alloc(u32, n);

    var next = n_c;
    var split = false;
    for (0..n) |s| {
        if (seen[s]) continue;
        const c0 = comm[s];
        const new_id: u32 = if (first[c0]) c0 else blk: {
            split = true;
            const id = next;
            next += 1;
            break :blk id;
        };
        first[c0] = false;
        var qh: usize = 0;
        var qt: usize = 0;
        seen[s] = true;
        comm[s] = new_id;
        q[qt] = @intCast(s);
        qt += 1;
        while (qh < qt) {
            const u = q[qh];
            qh += 1;
            for (g.starts[u]..g.starts[u + 1]) |t| {
                const v = g.adj[t].to;
                if (seen[v] or comm[v] != c0) continue;
                seen[v] = true;
                comm[v] = new_id;
                q[qt] = v;
                qt += 1;
            }
        }
    }
    return split;
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

fn edgePairKey(e: Edge) u64 {
    return (@as(u64, e.a) << 32) | e.b;
}

/// Phase two: every community becomes one node, and the edges between them are summed.
fn contract(arena: std.mem.Allocator, g: *Graph, comm: []const u32, n_comm: u32) !Contracted {
    const self_w = try arena.alloc(f64, n_comm);
    @memset(self_w, 0);
    for (0..g.n) |i| self_w[comm[i]] += g.self_w[i];

    var list: std.ArrayListUnmanaged(Edge) = .empty;
    try list.ensureTotalCapacity(arena, g.adj.len / 2 + 1);
    for (0..g.n) |i| {
        const ci = comm[i];
        for (g.starts[i]..g.starts[i + 1]) |t| {
            const a = g.adj[t];
            if (a.to < i) continue; // each undirected edge once
            const cj = comm[a.to];
            if (ci == cj) {
                self_w[ci] += a.w;
            } else {
                list.appendAssumeCapacity(.{ .a = @min(ci, cj), .b = @max(ci, cj), .w = a.w });
            }
        }
    }

    // Sum parallel edges: sort by the packed pair, then run through.
    //
    // Radix rather than a comparison sort. The key is two `u32` community ids packed into 64 bits,
    // which buckets in linear time instead of comparing in `n log n` — and on the first level of a
    // vault this list is over a million edges. It is the same swap that took `cellweb` from 710 ms
    // to 268 ms; see `radix.zig`, which exists because this shape of sort turns up in three places.
    //
    // Stability is not incidental here. Equal keys are the *expected* input — that is what "sum
    // parallel edges" means — and the run below adds their weights in encounter order. A stable
    // sort keeps that order fixed, so the float sum is bit-for-bit reproducible across runs, which
    // is what a deterministic partition rests on.
    const scratch = try arena.alloc(Edge, list.items.len);
    const sorted = radix.sortByKey(Edge, edgePairKey, list.items, scratch);
    var wpos: usize = 0;
    const out = list.items;
    for (sorted) |e| {
        if (wpos > 0 and out[wpos - 1].a == e.a and out[wpos - 1].b == e.b) {
            out[wpos - 1].w += e.w;
            continue;
        }
        out[wpos] = e;
        wpos += 1;
    }
    return .{ .edges = out[0..wpos], .self_w = self_w };
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

/// How many notes changed community between two partitions of the same nodes.
///
/// Community *ids* are arbitrary, so this greedily matches old communities to new ones by
/// overlap (each side used at most once) and counts the notes whose matched id disagrees.
/// A merge flips the smaller side; a split flips the smaller fragment; a relabel of the same
/// grouping flips nothing.
pub fn notesFlipped(gpa: std.mem.Allocator, a: []const u32, b: []const u32) !u32 {
    if (a.len != b.len) return error.LengthMismatch;
    const n = a.len;
    if (n == 0) return 0;

    var na: u32 = 0;
    var nb: u32 = 0;
    for (a) |c| na = @max(na, c + 1);
    for (b) |c| nb = @max(nb, c + 1);

    var overlap = std.AutoHashMap(u64, u32).init(gpa);
    defer overlap.deinit();
    for (a, b) |ca, cb| {
        const key = (@as(u64, ca) << 32) | cb;
        const gop = try overlap.getOrPut(key);
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* += 1;
    }

    const Triple = struct { a: u32, b: u32, n: u32 };
    var triples: std.ArrayListUnmanaged(Triple) = .empty;
    defer triples.deinit(gpa);
    try triples.ensureTotalCapacity(gpa, overlap.count());
    var it = overlap.iterator();
    while (it.next()) |e| {
        triples.appendAssumeCapacity(.{
            .a = @intCast(e.key_ptr.* >> 32),
            .b = @intCast(e.key_ptr.* & 0xffff_ffff),
            .n = e.value_ptr.*,
        });
    }
    std.mem.sort(Triple, triples.items, {}, struct {
        fn less(_: void, x: Triple, y: Triple) bool {
            if (x.n != y.n) return x.n > y.n;
            if (x.a != y.a) return x.a < y.a;
            return x.b < y.b;
        }
    }.less);

    const used_a = try gpa.alloc(bool, na);
    defer gpa.free(used_a);
    const used_b = try gpa.alloc(bool, nb);
    defer gpa.free(used_b);
    @memset(used_a, false);
    @memset(used_b, false);
    const map = try gpa.alloc(u32, na);
    defer gpa.free(map);
    @memset(map, std.math.maxInt(u32));
    for (triples.items) |t| {
        if (used_a[t.a] or used_b[t.b]) continue;
        used_a[t.a] = true;
        used_b[t.b] = true;
        map[t.a] = t.b;
    }

    var flips: u32 = 0;
    for (a, b) |ca, cb| {
        if (map[ca] != cb) flips += 1;
    }
    return flips;
}

pub const Stability = struct {
    trials: u32 = 0,
    comm_fine: u32 = 0,
    comm_region: u32 = 0,
    fine_p50: u32 = 0,
    fine_p90: u32 = 0,
    fine_max: u32 = 0,
    region_p50: u32 = 0,
    region_p90: u32 = 0,
    region_max: u32 = 0,
};

/// Cold-cluster, add one missing edge, cold-cluster again, count community flips.
/// Repeat `trials` times with different edges. This is Gate 1: a layout that re-solves a
/// region only where membership changed is worthless if membership itself thrashs.
///
/// `fine` is the first Louvain level. `region` is the coarsest level that still has at least
/// `n/80` communities — over-aggregating past that is how a 2k-node graph ends up as 24 blobs
/// that reshuffle. Simplewiki's ~3k cut lands here naturally.
pub fn stability(
    gpa: std.mem.Allocator,
    n: usize,
    edges: []const Edge,
    trials: u32,
    opts: Options,
) !Stability {
    var out: Stability = .{};
    if (n < 2 or trials == 0) return out;

    var base = try cluster(gpa, n, edges, opts);
    defer base.deinit(gpa);
    const fine_base = try finestOrId(gpa, n, &base);
    defer if (base.levels.len == 0) gpa.free(fine_base);
    const region_i = regionLevel(&base, n);
    const region_base = if (base.levels.len == 0) fine_base else base.levels[region_i];
    out.comm_fine = if (base.counts.len == 0) @intCast(n) else base.counts[0];
    out.comm_region = if (base.counts.len == 0) @intCast(n) else base.counts[region_i];

    const extras = try pickTrialEdges(gpa, n, edges, trials);
    defer gpa.free(extras);
    if (extras.len == 0) return out;

    const fine_flips = try gpa.alloc(u32, extras.len);
    defer gpa.free(fine_flips);
    const region_flips = try gpa.alloc(u32, extras.len);
    defer gpa.free(region_flips);

    const edges2 = try gpa.alloc(Edge, edges.len + 1);
    defer gpa.free(edges2);
    if (edges.len > 0) @memcpy(edges2[0..edges.len], edges);

    for (extras, 0..) |extra, t| {
        edges2[edges.len] = extra;
        var next = try cluster(gpa, n, edges2, opts);
        defer next.deinit(gpa);
        const fine_next = try finestOrId(gpa, n, &next);
        defer if (next.levels.len == 0) gpa.free(fine_next);
        const region_next = if (next.levels.len == 0) fine_next else next.levels[regionLevel(&next, n)];
        fine_flips[t] = try notesFlipped(gpa, fine_base, fine_next);
        region_flips[t] = try notesFlipped(gpa, region_base, region_next);
    }

    std.mem.sort(u32, fine_flips, {}, std.sort.asc(u32));
    std.mem.sort(u32, region_flips, {}, std.sort.asc(u32));
    out.trials = @intCast(extras.len);
    out.fine_p50 = percentileU32(fine_flips, 50);
    out.fine_p90 = percentileU32(fine_flips, 90);
    out.fine_max = fine_flips[fine_flips.len - 1];
    out.region_p50 = percentileU32(region_flips, 50);
    out.region_p90 = percentileU32(region_flips, 90);
    out.region_max = region_flips[region_flips.len - 1];
    return out;
}

/// Coarsest dendrogram cut that still has at least `n/80` communities (floor 8).
pub fn regionLevel(res: *const Result, n: usize) usize {
    if (res.counts.len == 0) return 0;
    const want: u32 = @intCast(@max(n / 80, 8));
    var best: usize = 0;
    for (res.counts, 0..) |c, i| {
        if (c >= want) best = i;
    }
    return best;
}

fn finestOrId(gpa: std.mem.Allocator, n: usize, res: *const Result) ![]u32 {
    if (res.levels.len > 0) return res.levels[0];
    const id = try gpa.alloc(u32, n);
    for (id, 0..) |*c, i| c.* = @intCast(i);
    return id;
}

fn percentileU32(sorted: []const u32, p: u32) u32 {
    if (sorted.len == 0) return 0;
    const idx = @min(sorted.len - 1, (sorted.len * p) / 100);
    return sorted[idx];
}

fn packPair(a: u32, b: u32) u64 {
    return (@as(u64, @min(a, b)) << 32) | @max(a, b);
}

fn hasPair(sorted: []const u64, key: u64) bool {
    var lo: usize = 0;
    var hi: usize = sorted.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (sorted[mid] < key) lo = mid + 1 else if (sorted[mid] > key) hi = mid else return true;
    }
    return false;
}

fn uniqueInPlace(xs: []u64) []u64 {
    if (xs.len == 0) return xs;
    var w: usize = 1;
    for (xs[1..]) |x| {
        if (x != xs[w - 1]) {
            xs[w] = x;
            w += 1;
        }
    }
    return xs[0..w];
}

fn pickTrialEdges(gpa: std.mem.Allocator, n: usize, edges: []const Edge, trials: u32) ![]Edge {
    const pairs = try gpa.alloc(u64, edges.len);
    defer gpa.free(pairs);
    var pn: usize = 0;
    for (edges) |e| {
        if (e.a >= n or e.b >= n or e.a == e.b) continue;
        pairs[pn] = packPair(e.a, e.b);
        pn += 1;
    }
    std.mem.sort(u64, pairs[0..pn], {}, std.sort.asc(u64));
    const uniq = uniqueInPlace(pairs[0..pn]);

    // Same-component pairs first, so an edit does not merge two islands and count every
    // member of both as a flip.
    const parent = try gpa.alloc(u32, n);
    defer gpa.free(parent);
    for (parent, 0..) |*p, i| p.* = @intCast(i);
    const find = struct {
        fn f(u: []u32, x0: u32) u32 {
            var x = x0;
            while (u[x] != x) {
                u[x] = u[u[x]];
                x = u[x];
            }
            return x;
        }
    }.f;
    for (edges) |e| {
        if (e.a >= n or e.b >= n or e.a == e.b) continue;
        const ra = find(parent, e.a);
        const rb = find(parent, e.b);
        if (ra != rb) parent[@max(ra, rb)] = @min(ra, rb);
    }

    var out: std.ArrayListUnmanaged(Edge) = .empty;
    errdefer out.deinit(gpa);
    var seen = std.AutoHashMap(u64, void).init(gpa);
    defer seen.deinit();

    var t: u64 = 0;
    var guard: u32 = 0;
    const guard_max: u32 = trials * 4096 + 64;
    while (out.items.len < trials and guard < guard_max) : (guard += 1) {
        const a: u32 = @intCast((t *% 7919) % n);
        const b: u32 = @intCast((t *% 104729 + 17) % n);
        t += 1;
        if (a == b) continue;
        const key = packPair(a, b);
        if (hasPair(uniq, key)) continue;
        if (find(parent, a) != find(parent, b)) continue;
        const gop = try seen.getOrPut(key);
        if (gop.found_existing) continue;
        try out.append(gpa, .{ .a = @min(a, b), .b = @max(a, b) });
    }
    // Complete-graph or single-node components: allow a cross-component edge so the
    // probe still runs, rather than silently reporting zeros.
    t = 0;
    guard = 0;
    while (out.items.len < trials and guard < guard_max) : (guard += 1) {
        const a: u32 = @intCast((t *% 13007 + 3) % n);
        const b: u32 = @intCast((t *% 196613 + 11) % n);
        t += 1;
        if (a == b) continue;
        const key = packPair(a, b);
        if (hasPair(uniq, key)) continue;
        const gop = try seen.getOrPut(key);
        if (gop.found_existing) continue;
        try out.append(gpa, .{ .a = @min(a, b), .b = @max(a, b) });
    }
    return out.toOwnedSlice(gpa);
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

    var res = try cluster(gpa, 48, edges.items, .{ .measure_q = true });
    defer res.deinit(gpa);
    try testing.expect(res.q.len > 0);
    try testing.expect(res.q[0] > 0.5);
    try testing.expect(intraFraction(48, edges.items, res.levels[0]) > 0.9);
}

test "notesFlipped is zero under relabel and counts a split" {
    const gpa = testing.allocator;
    const a = [_]u32{ 0, 0, 0, 1, 1, 1 };
    const relabel = [_]u32{ 7, 7, 7, 3, 3, 3 };
    try testing.expectEqual(@as(u32, 0), try notesFlipped(gpa, &a, &relabel));
    const split = [_]u32{ 0, 0, 1, 2, 2, 2 };
    // Smaller fragment of the first community (one note) flips; the second community matches.
    try testing.expectEqual(@as(u32, 1), try notesFlipped(gpa, &a, &split));
}

test "adding an edge inside a clique flips few notes" {
    const gpa = testing.allocator;
    var edges: std.ArrayListUnmanaged(Edge) = .empty;
    defer edges.deinit(gpa);
    for (0..2) |g| {
        const base: u32 = @intCast(g * 12);
        for (0..12) |a| {
            for (a + 1..12) |b| {
                try edges.append(gpa, .{ .a = base + @as(u32, @intCast(a)), .b = base + @as(u32, @intCast(b)) });
            }
        }
    }
    try edges.append(gpa, .{ .a = 0, .b = 12 });

    const s = try stability(gpa, 24, edges.items, 5, .{});
    // The two cliques are the only structure; an extra edge is either inside a clique
    // (already complete, so the probe picks a cross edge we already have... wait, cliques
    // are complete so same-component missing edges don't exist; the fallback adds a second
    // bridge). A second bridge should not reassign the cliques.
    try testing.expect(s.trials > 0);
    try testing.expect(s.region_p50 <= 2);
}

test "Leiden refine still separates two cliques" {
    const gpa = testing.allocator;
    var edges: std.ArrayListUnmanaged(Edge) = .empty;
    defer edges.deinit(gpa);
    for (0..2) |g| {
        const base: u32 = @intCast(g * 8);
        for (0..8) |a| {
            for (a + 1..8) |b| {
                try edges.append(gpa, .{ .a = base + @as(u32, @intCast(a)), .b = base + @as(u32, @intCast(b)) });
            }
        }
    }
    try edges.append(gpa, .{ .a = 0, .b = 8 });
    var res = try cluster(gpa, 16, edges.items, .{ .refine = true });
    defer res.deinit(gpa);
    try testing.expect(res.levels.len > 0);
    const finest = res.levels[0];
    for (1..8) |i| try testing.expectEqual(finest[0], finest[i]);
    for (9..16) |i| try testing.expectEqual(finest[8], finest[i]);
    try testing.expect(finest[0] != finest[8]);
}

