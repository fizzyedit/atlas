//! Numbers that say whether a layout *looks like the graph it came from*.
//!
//! Link spread and co-citation already grade relatedness. They cannot see a tree drawn as a
//! knot with flung arms, or a whole map sliding when one edge is added. This file is the rest of
//! that grade: radial bimodality, disc overlap, single-edge displacement, and a cheap classifier
//! over the graph (and over Louvain communities) so Stage 4 has a baseline before inner packing
//! exists.
//!
//! Deliberately dvui-free. Positions come in from `layout.solve`; this only measures them.

const std = @import("std");
const fold = @import("fold.zig");
const spatial = @import("spatial.zig");
const louvain = @import("louvain.zig");

pub const Edge = fold.Edge;
pub const Vec2 = spatial.Vec2;

pub const Kind = enum {
    orphans,
    chain,
    tree,
    star,
    clique,
    grid,
    bipartite,
    scale_free,
    islands,
    messy,

    pub fn label(self: Kind) []const u8 {
        return switch (self) {
            .orphans => "orphans",
            .chain => "chain",
            .tree => "tree",
            .star => "star",
            .clique => "clique",
            .grid => "grid",
            .bipartite => "bipartite",
            .scale_free => "scale-free",
            .islands => "islands",
            .messy => "messy",
        };
    }

    fn letter(self: Kind) u8 {
        return switch (self) {
            .orphans => 'o',
            .chain => 'c',
            .tree => 't',
            .star => 's',
            .clique => 'q',
            .grid => 'g',
            .bipartite => 'b',
            .scale_free => 'f',
            .islands => 'i',
            .messy => 'm',
        };
    }
};

pub const CommHist = struct {
    counts: [std.meta.fields(Kind).len]u32 = .{0} ** std.meta.fields(Kind).len,

    fn add(self: *CommHist, k: Kind) void {
        self.counts[@intFromEnum(k)] += 1;
    }

    pub fn total(self: CommHist) u32 {
        var s: u32 = 0;
        for (self.counts) |c| s += c;
        return s;
    }

    /// Compact `12t 3s 8m`. Empty if nothing was classified.
    pub fn formatBuf(self: CommHist, buf: []u8) []const u8 {
        var n: usize = 0;
        var first = true;
        for (self.counts, 0..) |c, i| {
            if (c == 0) continue;
            if (!first) {
                if (n + 1 >= buf.len) break;
                buf[n] = ' ';
                n += 1;
            }
            first = false;
            const k: Kind = @enumFromInt(i);
            const w = std.fmt.bufPrint(buf[n..], "{d}{c}", .{ c, k.letter() }) catch break;
            n += w.len;
        }
        return buf[0..n];
    }
};

pub const Report = struct {
    n: usize = 0,
    e: usize = 0,
    solve_ms: f64 = 0,
    /// Mean link length / vault extent.
    spread_mean: f64 = 0,
    /// Share of sampled links longer than a quarter of the vault.
    crossing_pct: f64 = 0,
    /// Co-cited pairs vs random pairs; 0 when there are no co-cited pairs.
    cocite_ratio: f64 = 0,
    cocite_n: usize = 0,
    /// Equal-area ring 0 (the centre), percent of notes.
    dens0_pct: f64 = 0,
    /// Bimodality coefficient of radius-from-centroid. Above ~0.555 suggests two radial masses
    /// (the tree's knot-plus-arms).
    bimod: f64 = 0,
    overlap_pct: f64 = 0,
    penet: f64 = 0,
    leaf_p50: f64 = 0,
    /// Cross-community link length in region radii (`len / (√n_a + √n_b)`). Adjacent packed
    /// discs sit near `spacing` (~2.6); a highway that spans the vault is tens. Negative if
    /// there were no cross-community links to measure.
    highway_p50: f64 = -1,
    highway_p90: f64 = -1,
    /// Per-note displacement after one added link, Procrustes-aligned, in note radii.
    /// Negative means the second solve was skipped.
    disp_p50: f64 = -1,
    disp_p99: f64 = -1,
    graph: Kind = .messy,
    comm_n: u32 = 0,
    comm: CommHist = .{},
};

pub fn printHeader() void {
    std.debug.print(
        "{s:<14}{s:>8}{s:>9}{s:>9}{s:>8}{s:>6}{s:>7}{s:>6}{s:>6}{s:>6}{s:>6}{s:>6}{s:>8}{s:>8}{s:>8}{s:>11}  {s}\n",
        .{
            "shape", "n", "e", "solve", "spread", "xing", "cocite", "r0", "bimod",
            "ovlp",  "penet", "leaf", "hwy", "d-p50", "d-p99", "graph", "communities",
        },
    );
    std.debug.print("{s}\n", .{"-" ** 148});
}

pub fn printRow(label: []const u8, r: Report) void {
    var cbuf: [64]u8 = undefined;
    const comm_s = r.comm.formatBuf(&cbuf);
    const comm_shown = if (comm_s.len == 0) "—" else comm_s;

    var d50_buf: [16]u8 = undefined;
    var d99_buf: [16]u8 = undefined;
    const d50 = fmtDisp(&d50_buf, r.disp_p50);
    const d99 = fmtDisp(&d99_buf, r.disp_p99);

    var cocite_buf: [16]u8 = undefined;
    const cocite = if (r.cocite_n == 0)
        "—"
    else
        std.fmt.bufPrint(&cocite_buf, "{d:.2}x", .{r.cocite_ratio}) catch "?";

    var hwy_buf: [20]u8 = undefined;
    const hwy = fmtHwy(&hwy_buf, r.highway_p50, r.highway_p90);

    std.debug.print(
        "{s:<14}{d:>8}{d:>9}{d:>7.0}ms {d:>6.3}r {d:>5.1}% {s:>6} {d:>5.1}% {d:>5.2} {d:>5.1}% {d:>5.2}x {d:>5.2} {s:>8} {s:>8} {s:>8} {s:>11}  {s}\n",
        .{
            label,
            r.n,
            r.e,
            r.solve_ms,
            r.spread_mean,
            r.crossing_pct,
            cocite,
            r.dens0_pct,
            r.bimod,
            r.overlap_pct,
            r.penet,
            r.leaf_p50,
            hwy,
            d50,
            d99,
            r.graph.label(),
            comm_shown,
        },
    );
}

fn fmtHwy(buf: []u8, p50: f64, p90: f64) []const u8 {
    if (p50 < 0) return "—";
    return std.fmt.bufPrint(buf, "{d:.1}/{d:.1}", .{ p50, p90 }) catch "?";
}

fn fmtDisp(buf: []u8, v: f64) []const u8 {
    if (v < 0) return "—";
    return std.fmt.bufPrint(buf, "{d:.2}r", .{v}) catch "?";
}

/// Grade a solved layout. `comp` is the layout's component id per note (for spatial). `note_r`
/// is the radius the notes were solved at.
pub fn grade(
    gpa: std.mem.Allocator,
    n: usize,
    edges: []const Edge,
    pos: []const Vec2,
    comp: []const u32,
    note_r: f32,
    solve_ms: f64,
) !Report {
    var r: Report = .{
        .n = n,
        .e = edges.len,
        .solve_ms = solve_ms,
        .graph = classify(gpa, n, edges) catch .messy,
    };
    if (n == 0 or pos.len != n) return r;

    const ext = @max(extentOf(pos), 1e-3);
    const nr = @max(note_r, 1e-6);

    linkSpread(&r, edges, pos, ext);
    try cocitation(gpa, &r, n, edges, pos, ext);
    try radial(gpa, &r, pos, ext);
    try overlapAndLeaf(gpa, &r, n, pos, comp, nr, ext);
    try communities(gpa, &r, n, edges, pos);
    return r;
}

pub fn setDisplacement(gpa: std.mem.Allocator, r: *Report, old: []const Vec2, new: []const Vec2, note_r: f32) !void {
    if (old.len == 0 or old.len != new.len) return;
    const nr = @max(note_r, 1e-6);
    var p50: f32 = 0;
    var p99: f32 = 0;
    try displacementsPercentiles(gpa, old, new, &p50, &p99);
    r.disp_p50 = p50 / nr;
    r.disp_p99 = p99 / nr;
}

/// A new undirected pair, preferring two notes already in the same component so the edit does
/// not merge islands (which would move a whole packed disc and swamp the coupling signal).
pub fn pickNewEdge(gpa: std.mem.Allocator, n: usize, edges: []const Edge) !?Edge {
    if (n < 2) return null;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const pairs = try arena.alloc(u64, edges.len);
    var pn: usize = 0;
    for (edges) |e| {
        if (e.a >= n or e.b >= n or e.a == e.b) continue;
        pairs[pn] = packPair(e.a, e.b);
        pn += 1;
    }
    std.mem.sort(u64, pairs[0..pn], {}, std.sort.asc(u64));
    const uniq = uniqueInPlace(pairs[0..pn]);

    const comp = try arena.alloc(u32, n);
    _ = try fold.linkComponents(arena, comp, edges, n);

    // Same-component non-edge first.
    if (try findNonEdge(n, uniq, comp, true)) |e| return e;
    return try findNonEdge(n, uniq, comp, false);
}

fn findNonEdge(n: usize, uniq: []const u64, comp: []const u32, same_comp: bool) !?Edge {
    // Bounded scan: enough to find a missing edge on anything but a near-clique.
    const cap: usize = @min(n, 4096);
    var i: usize = 0;
    while (i < cap) : (i += 1) {
        var j: usize = i + 1;
        var tries: usize = 0;
        while (j < n and tries < 64) : (j += 1) {
            if (same_comp and comp[i] != comp[j]) continue;
            tries += 1;
            if (!hasPair(uniq, packPair(@intCast(i), @intCast(j)))) {
                return .{ .a = @intCast(i), .b = @intCast(j) };
            }
        }
    }
    return null;
}

fn packPair(a: u32, b: u32) u64 {
    const lo = @min(a, b);
    const hi = @max(a, b);
    return (@as(u64, lo) << 32) | hi;
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

fn extentOf(pos: []const Vec2) f32 {
    var ext: f32 = 0;
    for (pos) |p| ext = @max(ext, @sqrt(p.x * p.x + p.y * p.y));
    return ext;
}

fn linkSpread(r: *Report, edges: []const Edge, pos: []const Vec2, ext: f64) void {
    if (edges.len == 0 or pos.len == 0) return;
    const sample_cap: usize = 60_000;
    const stride = @max(1, edges.len / sample_cap);
    var sum: f64 = 0;
    var far: usize = 0;
    var n: usize = 0;
    var i: usize = 0;
    while (i < edges.len) : (i += stride) {
        const e = edges[i];
        if (e.a >= pos.len or e.b >= pos.len) continue;
        const dx = pos[e.a].x - pos[e.b].x;
        const dy = pos[e.a].y - pos[e.b].y;
        const l: f64 = @sqrt(dx * dx + dy * dy);
        sum += l;
        if (l > ext * 0.25) far += 1;
        n += 1;
    }
    if (n == 0) return;
    const nf: f64 = @floatFromInt(n);
    r.spread_mean = (sum / nf) / ext;
    r.crossing_pct = @as(f64, @floatFromInt(far)) * 100.0 / nf;
}

fn cocitation(
    gpa: std.mem.Allocator,
    r: *Report,
    n: usize,
    edges: []const Edge,
    pos: []const Vec2,
    ext: f64,
) !void {
    if (n == 0 or edges.len == 0) return;
    const deg_cap: u32 = 128;
    const cocite_min: u32 = 3;

    const deg = try gpa.alloc(u32, n);
    defer gpa.free(deg);
    @memset(deg, 0);
    for (edges) |e| {
        if (e.a >= n or e.b >= n or e.a == e.b) continue;
        deg[e.a] += 1;
        deg[e.b] += 1;
    }

    const starts = try gpa.alloc(u32, n + 1);
    defer gpa.free(starts);
    @memset(starts, 0);
    for (edges) |e| {
        if (e.a >= n or e.b >= n or e.a == e.b) continue;
        starts[e.a + 1] += 1;
        starts[e.b + 1] += 1;
    }
    for (1..starts.len) |i| starts[i] += starts[i - 1];
    const adj = try gpa.alloc(u32, starts[n]);
    defer gpa.free(adj);
    const cur = try gpa.alloc(u32, n);
    defer gpa.free(cur);
    @memcpy(cur, starts[0..n]);
    for (edges) |e| {
        if (e.a >= n or e.b >= n or e.a == e.b) continue;
        adj[cur[e.a]] = e.b;
        cur[e.a] += 1;
        adj[cur[e.b]] = e.a;
        cur[e.b] += 1;
    }

    const shared = try gpa.alloc(u32, n);
    defer gpa.free(shared);
    @memset(shared, 0);
    var touched: std.ArrayListUnmanaged(u32) = .empty;
    defer touched.deinit(gpa);
    var near: std.ArrayListUnmanaged(f32) = .empty;
    defer near.deinit(gpa);

    const stride = @max(1, n / 4000);
    var u: usize = 0;
    while (u < n) : (u += stride) {
        if (deg[u] == 0 or deg[u] > deg_cap) continue;
        const pu = pos[u];
        for (starts[u]..starts[u + 1]) |ka| {
            const v = adj[ka];
            if (deg[v] > deg_cap) continue;
            for (starts[v]..starts[v + 1]) |kb| {
                const t = adj[kb];
                if (t == u) continue;
                if (shared[t] == 0) touched.append(gpa, t) catch continue;
                shared[t] += 1;
            }
        }
        for (touched.items) |t| {
            if (shared[t] >= cocite_min) direct: {
                for (starts[u]..starts[u + 1]) |k| if (adj[k] == t) break :direct;
                const pt = pos[t];
                const dx = pu.x - pt.x;
                const dy = pu.y - pt.y;
                near.append(gpa, @sqrt(dx * dx + dy * dy)) catch {};
            }
            shared[t] = 0;
        }
        touched.clearRetainingCapacity();
    }

    if (near.items.len == 0) return;
    std.mem.sort(f32, near.items, {}, std.sort.asc(f32));
    var rnd: std.ArrayListUnmanaged(f32) = .empty;
    defer rnd.deinit(gpa);
    var i: usize = 0;
    while (i < near.items.len and i < 60_000) : (i += 1) {
        const a = (i * 7919) % n;
        const b = (i * 104729 + 5000) % n;
        if (a == b) continue;
        const dx = pos[a].x - pos[b].x;
        const dy = pos[a].y - pos[b].y;
        rnd.append(gpa, @sqrt(dx * dx + dy * dy)) catch {};
    }
    if (rnd.items.len == 0) return;
    std.mem.sort(f32, rnd.items, {}, std.sort.asc(f32));
    const nm = @as(f64, near.items[near.items.len / 2]) / ext;
    const rm = @as(f64, rnd.items[rnd.items.len / 2]) / ext;
    r.cocite_n = near.items.len;
    r.cocite_ratio = if (nm > 1e-6) rm / nm else 0;
}

fn radial(gpa: std.mem.Allocator, r: *Report, pos: []const Vec2, ext: f64) !void {
    if (pos.len == 0) return;
    var cx: f64 = 0;
    var cy: f64 = 0;
    for (pos) |p| {
        cx += p.x;
        cy += p.y;
    }
    const nf: f64 = @floatFromInt(pos.len);
    cx /= nf;
    cy /= nf;

    const rings = 8;
    var hist: [rings]usize = .{0} ** rings;
    const radii = try gpa.alloc(f32, pos.len);
    defer gpa.free(radii);

    for (pos, radii) |p, *out| {
        const dx = @as(f64, p.x) - cx;
        const dy = @as(f64, p.y) - cy;
        const rad: f32 = @floatCast(@sqrt(dx * dx + dy * dy) / ext);
        out.* = rad;
        const b: usize = @intFromFloat(@min(@as(f32, rings - 1), rad * rad * rings));
        hist[b] += 1;
    }
    r.dens0_pct = @as(f64, @floatFromInt(hist[0])) * 100.0 / nf;
    r.bimod = bimodalityCoefficient(radii);
}

/// Pearson's moment coefficient of bimodality: (skew² + 1) / kurtosis. Values above ~0.555
/// suggest two masses. Kurtosis here is the fourth standardised moment, not excess.
fn bimodalityCoefficient(xs: []const f32) f64 {
    if (xs.len < 8) return 0;
    const n: f64 = @floatFromInt(xs.len);
    var mean: f64 = 0;
    for (xs) |x| mean += x;
    mean /= n;
    var m2: f64 = 0;
    var m3: f64 = 0;
    var m4: f64 = 0;
    for (xs) |x| {
        const d = @as(f64, x) - mean;
        const d2 = d * d;
        m2 += d2;
        m3 += d2 * d;
        m4 += d2 * d2;
    }
    m2 /= n;
    m3 /= n;
    m4 /= n;
    if (m2 <= 1e-18) return 0;
    const s = @sqrt(m2);
    const skew = m3 / (s * s * s);
    const kurt = m4 / (m2 * m2);
    if (kurt <= 1e-12) return 0;
    return (skew * skew + 1.0) / kurt;
}

fn overlapAndLeaf(
    gpa: std.mem.Allocator,
    r: *Report,
    n: usize,
    pos: []const Vec2,
    comp: []const u32,
    note_r: f32,
    ext: f32,
) !void {
    const weight = try gpa.alloc(f32, n);
    defer gpa.free(weight);
    const body = try gpa.alloc(f32, n);
    defer gpa.free(body);
    @memset(weight, 1);
    @memset(body, 1);

    var spat = try spatial.build(gpa, n, pos, comp, weight, body, .{
        .note_r = note_r,
        .quant_half = @max(ext, note_r),
    });
    defer spat.deinit(gpa);

    var pairs: usize = 0;
    var overlapping: usize = 0;
    var penetration: f64 = 0;
    for (spat.lad.cells, 0..) |c, id| {
        if (c.child_count < 2) continue;
        const kids = spat.lad.childrenOf(@intCast(id));
        for (kids, 0..) |ka, ai| {
            for (kids[ai + 1 ..]) |kb| {
                pairs += 1;
                const dx = spat.pos[ka].x - spat.pos[kb].x;
                const dy = spat.pos[ka].y - spat.pos[kb].y;
                const d = @sqrt(dx * dx + dy * dy);
                const want = spat.bound_r[ka] + spat.bound_r[kb];
                if (d < want) {
                    overlapping += 1;
                    penetration += @as(f64, want - d) / @max(1e-6, @min(spat.bound_r[ka], spat.bound_r[kb]));
                }
            }
        }
    }
    if (pairs > 0) {
        const pf: f64 = @floatFromInt(pairs);
        r.overlap_pct = @as(f64, @floatFromInt(overlapping)) * 100.0 / pf;
        r.penet = if (overlapping > 0) penetration / @as(f64, @floatFromInt(overlapping)) else 0;
    }

    if (spat.lad.note_at.len >= 2) {
        var gaps: std.ArrayListUnmanaged(f32) = .empty;
        defer gaps.deinit(gpa);
        var si: usize = 1;
        while (si < spat.lad.note_at.len) : (si += 1) {
            const a = pos[spat.lad.note_at[si - 1]];
            const b = pos[spat.lad.note_at[si]];
            const dx = a.x - b.x;
            const dy = a.y - b.y;
            try gaps.append(gpa, @sqrt(dx * dx + dy * dy));
        }
        if (gaps.items.len > 0) {
            std.mem.sort(f32, gaps.items, {}, std.sort.asc(f32));
            r.leaf_p50 = gaps.items[gaps.items.len / 2] / note_r;
        }
    }
}

fn communities(gpa: std.mem.Allocator, r: *Report, n: usize, edges: []const Edge, pos: []const Vec2) !void {
    if (n < 4 or edges.len == 0) {
        r.comm_n = 1;
        r.comm.add(r.graph);
        return;
    }
    const ledges = try gpa.alloc(louvain.Edge, edges.len);
    defer gpa.free(ledges);
    for (ledges, edges) |*d, e| d.* = .{ .a = e.a, .b = e.b, .w = e.w };

    var res = try louvain.cluster(gpa, n, ledges, .{});
    defer res.deinit(gpa);
    if (res.levels.len == 0) {
        r.comm_n = 1;
        r.comm.add(r.graph);
        return;
    }

    // Finest partition: that is the scale inner packing would see first.
    const lvl = res.levels[0];
    r.comm_n = res.counts[0];

    const sizes = try gpa.alloc(u32, r.comm_n);
    defer gpa.free(sizes);
    @memset(sizes, 0);
    for (lvl) |c| if (c < sizes.len) {
        sizes[c] += 1;
    };

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Classify communities of at least 4 notes; smaller ones are noise at this stage.
    for (sizes, 0..) |sz, c| {
        if (sz < 4) continue;
        var local_edges: std.ArrayListUnmanaged(Edge) = .empty;
        // Remap members to 0..sz so classify sees a standalone graph.
        const of = try arena.alloc(u32, n);
        @memset(of, std.math.maxInt(u32));
        var next: u32 = 0;
        for (lvl, 0..) |cc, i| {
            if (cc != c) continue;
            of[i] = next;
            next += 1;
        }
        for (edges) |e| {
            if (e.a >= n or e.b >= n) continue;
            const a = of[e.a];
            const b = of[e.b];
            if (a == std.math.maxInt(u32) or b == std.math.maxInt(u32) or a == b) continue;
            try local_edges.append(arena, .{ .a = a, .b = b, .w = e.w });
        }
        const k = classify(gpa, sz, local_edges.items) catch .messy;
        r.comm.add(k);
    }
    if (r.comm.total() == 0) r.comm.add(r.graph);

    if (pos.len == n and res.levels.len > 0) {
        const ri = louvain.regionLevel(&res, n);
        try fillHighways(gpa, r, edges, pos, res.levels[ri]);
    }
}

/// Cross-community hops, in region radii: `len / (√n_a + √n_b)`. Adjacent packed discs
/// land near the layout spacing; a hop that spans the vault is tens.
fn fillHighways(
    gpa: std.mem.Allocator,
    r: *Report,
    edges: []const Edge,
    pos: []const Vec2,
    comm: []const u32,
) !void {
    if (comm.len != pos.len or pos.len == 0) return;
    var n_comm: u32 = 0;
    for (comm) |c| n_comm = @max(n_comm, c + 1);
    const count = try gpa.alloc(u32, n_comm);
    defer gpa.free(count);
    @memset(count, 0);
    for (comm) |c| count[c] += 1;

    var lens: std.ArrayListUnmanaged(f32) = .empty;
    defer lens.deinit(gpa);
    const sample_cap: usize = 60_000;
    const stride = @max(1, edges.len / sample_cap);
    var i: usize = 0;
    while (i < edges.len) : (i += stride) {
        const e = edges[i];
        if (e.a >= comm.len or e.b >= comm.len or e.a == e.b) continue;
        const ca = comm[e.a];
        const cb = comm[e.b];
        if (ca == cb) continue;
        const ra = @sqrt(@as(f32, @floatFromInt(@max(count[ca], 1))));
        const rb = @sqrt(@as(f32, @floatFromInt(@max(count[cb], 1))));
        const dx = pos[e.a].x - pos[e.b].x;
        const dy = pos[e.a].y - pos[e.b].y;
        const len = @sqrt(dx * dx + dy * dy);
        try lens.append(gpa, len / @max(ra + rb, 1e-3));
    }
    if (lens.items.len == 0) return;
    std.mem.sort(f32, lens.items, {}, std.sort.asc(f32));
    r.highway_p50 = lens.items[lens.items.len / 2];
    r.highway_p90 = lens.items[(lens.items.len * 9) / 10];
}

pub fn classify(gpa: std.mem.Allocator, n: usize, edges: []const Edge) !Kind {
    if (n == 0) return .orphans;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const s = try graphStats(arena, n, edges);
    return classifyStats(s);
}

const Stats = struct {
    n: usize,
    m: usize,
    n_comp: u32,
    n_comp_nt: u32,
    largest: usize,
    max_deg: u32,
    mean_deg: f64,
    isolates: usize,
    leaves: usize,
    density: f64,
    bipartite: bool,
    forest: bool,
};

fn graphStats(arena: std.mem.Allocator, n: usize, edges: []const Edge) !Stats {
    const pairs = try arena.alloc(u64, edges.len);
    var pn: usize = 0;
    for (edges) |e| {
        if (e.a >= n or e.b >= n or e.a == e.b) continue;
        pairs[pn] = packPair(e.a, e.b);
        pn += 1;
    }
    std.mem.sort(u64, pairs[0..pn], {}, std.sort.asc(u64));
    const uniq = uniqueInPlace(pairs[0..pn]);
    const m = uniq.len;

    const deg = try arena.alloc(u32, n);
    @memset(deg, 0);
    for (uniq) |p| {
        const a: u32 = @intCast(p >> 32);
        const b: u32 = @intCast(p & 0xffff_ffff);
        deg[a] += 1;
        deg[b] += 1;
    }
    var max_deg: u32 = 0;
    var isolates: usize = 0;
    var leaves: usize = 0;
    var deg_sum: u64 = 0;
    for (deg) |d| {
        max_deg = @max(max_deg, d);
        deg_sum += d;
        if (d == 0) isolates += 1;
        if (d == 1) leaves += 1;
    }

    const fold_edges = try arena.alloc(Edge, m);
    for (uniq, fold_edges) |p, *e| {
        e.* = .{ .a = @intCast(p >> 32), .b = @intCast(p & 0xffff_ffff) };
    }
    const comp = try arena.alloc(u32, n);
    const n_comp = try fold.linkComponents(arena, comp, fold_edges, n);

    const sizes = try arena.alloc(u32, n);
    @memset(sizes, 0);
    for (comp) |c| sizes[c] += 1;
    var largest: usize = 0;
    var n_comp_nt: u32 = 0;
    for (sizes) |sz| {
        if (sz == 0) continue;
        largest = @max(largest, sz);
        if (sz >= 2) n_comp_nt += 1;
    }

    const possible = n * @max(n, 1) - n;
    const density = if (n < 2) 0 else @as(f64, @floatFromInt(m)) * 2.0 / @as(f64, @floatFromInt(possible));
    const mean_deg = if (n == 0) 0 else @as(f64, @floatFromInt(deg_sum)) / @as(f64, @floatFromInt(n));
    // Undirected forest: m == n - n_comp. Isolated vertices are components of size 1.
    const forest = m + @as(usize, n_comp) <= n;

    return .{
        .n = n,
        .m = m,
        .n_comp = n_comp,
        .n_comp_nt = n_comp_nt,
        .largest = largest,
        .max_deg = max_deg,
        .mean_deg = mean_deg,
        .isolates = isolates,
        .leaves = leaves,
        .density = density,
        .bipartite = try isBipartite(arena, n, uniq, deg),
        .forest = forest,
    };
}

fn classifyStats(s: Stats) Kind {
    if (s.n == 0 or s.m == 0 or (s.isolates * 2 >= s.n and s.n_comp_nt == 0)) return .orphans;

    const nf: f64 = @floatFromInt(s.n);
    const leaf_frac = @as(f64, @floatFromInt(s.leaves)) / nf;
    const max_frac = @as(f64, @floatFromInt(s.max_deg)) / nf;
    if (s.n >= 4 and max_frac >= 0.4 and leaf_frac >= 0.6) return .star;

    // A 4-node path has density 0.5, so density alone cannot mean clique until the
    // graph is large enough that a tree cannot reach the threshold.
    if (s.n >= 8 and s.density >= 0.55) return .clique;
    if (s.density >= 0.8 and s.n >= 5) return .clique;

    if (s.n_comp_nt >= 3 and @as(f64, @floatFromInt(s.largest)) / nf < 0.55) return .islands;

    if (s.max_deg <= 2 and s.n_comp_nt <= 2 and s.m + 2 >= s.n - s.isolates) return .chain;

    if (s.forest and s.n_comp_nt <= 2) return .tree;

    if (s.max_deg <= 4 and s.mean_deg >= 2.4 and s.mean_deg <= 4.2 and !s.forest) return .grid;

    if (s.bipartite and !s.forest) return .bipartite;

    if (s.mean_deg > 0.5 and @as(f64, @floatFromInt(s.max_deg)) / s.mean_deg >= 8 and max_frac < 0.4) {
        return .scale_free;
    }

    if (s.forest) return .tree;
    return .messy;
}

fn isBipartite(arena: std.mem.Allocator, n: usize, uniq: []const u64, deg: []const u32) !bool {
    if (n == 0) return true;
    const starts = try arena.alloc(u32, n + 1);
    @memset(starts, 0);
    for (uniq) |p| {
        const a: u32 = @intCast(p >> 32);
        const b: u32 = @intCast(p & 0xffff_ffff);
        starts[a + 1] += 1;
        starts[b + 1] += 1;
    }
    for (1..starts.len) |i| starts[i] += starts[i - 1];
    const adj = try arena.alloc(u32, starts[n]);
    const cur = try arena.alloc(u32, n);
    @memcpy(cur, starts[0..n]);
    for (uniq) |p| {
        const a: u32 = @intCast(p >> 32);
        const b: u32 = @intCast(p & 0xffff_ffff);
        adj[cur[a]] = b;
        cur[a] += 1;
        adj[cur[b]] = a;
        cur[b] += 1;
    }

    const colour = try arena.alloc(i8, n);
    @memset(colour, 0);
    const q = try arena.alloc(u32, n);
    for (0..n) |s| {
        if (colour[s] != 0 or deg[s] == 0) continue;
        colour[s] = 1;
        var qh: usize = 0;
        var qt: usize = 0;
        q[qt] = @intCast(s);
        qt += 1;
        while (qh < qt) {
            const u = q[qh];
            qh += 1;
            for (starts[u]..starts[u + 1]) |k| {
                const v = adj[k];
                if (colour[v] == 0) {
                    colour[v] = -colour[u];
                    q[qt] = v;
                    qt += 1;
                } else if (colour[v] == colour[u]) {
                    return false;
                }
            }
        }
    }
    return true;
}

/// 2D Procrustes (translate + rotate, no scale): rotate `new` onto `old`, then per-point distance.
fn displacementsPercentiles(
    gpa: std.mem.Allocator,
    old: []const Vec2,
    new: []const Vec2,
    p50: *f32,
    p99: *f32,
) !void {
    const n = old.len;
    var ocx: f64 = 0;
    var ocy: f64 = 0;
    var ncx: f64 = 0;
    var ncy: f64 = 0;
    for (old, new) |o, nv| {
        ocx += o.x;
        ocy += o.y;
        ncx += nv.x;
        ncy += nv.y;
    }
    const nf: f64 = @floatFromInt(n);
    ocx /= nf;
    ocy /= nf;
    ncx /= nf;
    ncy /= nf;

    var dot: f64 = 0;
    var cross: f64 = 0;
    for (old, new) |o, nv| {
        const ox = @as(f64, o.x) - ocx;
        const oy = @as(f64, o.y) - ocy;
        const nx = @as(f64, nv.x) - ncx;
        const ny = @as(f64, nv.y) - ncy;
        dot += nx * ox + ny * oy;
        cross += nx * oy - ny * ox;
    }
    const theta = std.math.atan2(cross, dot);
    const c = @cos(theta);
    const s = @sin(theta);

    const tmp = try gpa.alloc(f32, n);
    defer gpa.free(tmp);

    for (old, new, tmp) |o, nv, *d| {
        const nx = @as(f64, nv.x) - ncx;
        const ny = @as(f64, nv.y) - ncy;
        const ax = c * nx - s * ny + ocx;
        const ay = s * nx + c * ny + ocy;
        const dx = ax - o.x;
        const dy = ay - o.y;
        d.* = @floatCast(@sqrt(dx * dx + dy * dy));
    }
    std.mem.sort(f32, tmp, {}, std.sort.asc(f32));
    p50.* = tmp[tmp.len / 2];
    const idx99 = @min(tmp.len - 1, (tmp.len * 99) / 100);
    p99.* = tmp[idx99];
}

// ---- tests ------------------------------------------------------------------------------------

const testing = std.testing;

fn pathEdges(gpa: std.mem.Allocator, n: u32) ![]Edge {
    const e = try gpa.alloc(Edge, n - 1);
    for (e, 0..) |*x, i| x.* = .{ .a = @intCast(i), .b = @intCast(i + 1) };
    return e;
}

test "classifier: path is a chain" {
    const gpa = testing.allocator;
    const e = try pathEdges(gpa, 12);
    defer gpa.free(e);
    try testing.expectEqual(Kind.chain, try classify(gpa, 12, e));
}

test "classifier: star" {
    const gpa = testing.allocator;
    const e = try gpa.alloc(Edge, 20);
    defer gpa.free(e);
    for (e, 0..) |*x, i| x.* = .{ .a = 0, .b = @intCast(i + 1) };
    try testing.expectEqual(Kind.star, try classify(gpa, 21, e));
}

test "classifier: clique" {
    const gpa = testing.allocator;
    var list: std.ArrayListUnmanaged(Edge) = .empty;
    defer list.deinit(gpa);
    const n: u32 = 8;
    for (0..n) |a| {
        for (a + 1..n) |b| try list.append(gpa, .{ .a = @intCast(a), .b = @intCast(b) });
    }
    try testing.expectEqual(Kind.clique, try classify(gpa, n, list.items));
}

test "classifier: tree (balanced, not a star)" {
    const gpa = testing.allocator;
    // Perfect binary tree of 15 nodes: parent i → 2i+1, 2i+2.
    var list: std.ArrayListUnmanaged(Edge) = .empty;
    defer list.deinit(gpa);
    const n: u32 = 15;
    for (0..7) |i| {
        try list.append(gpa, .{ .a = @intCast(i), .b = @intCast(2 * i + 1) });
        try list.append(gpa, .{ .a = @intCast(i), .b = @intCast(2 * i + 2) });
    }
    try testing.expectEqual(Kind.tree, try classify(gpa, n, list.items));
}

test "classifier: orphans" {
    const gpa = testing.allocator;
    try testing.expectEqual(Kind.orphans, try classify(gpa, 10, &.{}));
}

test "classifier: islands" {
    const gpa = testing.allocator;
    var list: std.ArrayListUnmanaged(Edge) = .empty;
    defer list.deinit(gpa);
    // Four disjoint 4-cliques.
    for (0..4) |g| {
        const base: u32 = @intCast(g * 4);
        for (0..4) |a| {
            for (a + 1..4) |b| {
                try list.append(gpa, .{ .a = base + @as(u32, @intCast(a)), .b = base + @as(u32, @intCast(b)) });
            }
        }
    }
    try testing.expectEqual(Kind.islands, try classify(gpa, 16, list.items));
}

test "classifier: grid" {
    const gpa = testing.allocator;
    var list: std.ArrayListUnmanaged(Edge) = .empty;
    defer list.deinit(gpa);
    const side: u32 = 8;
    for (0..side) |y| {
        for (0..side) |x| {
            const i = y * side + x;
            if (x + 1 < side) try list.append(gpa, .{ .a = @intCast(i), .b = @intCast(i + 1) });
            if (y + 1 < side) try list.append(gpa, .{ .a = @intCast(i), .b = @intCast(i + side) });
        }
    }
    try testing.expectEqual(Kind.grid, try classify(gpa, side * side, list.items));
}

test "Procrustes: a rotation is zero displacement" {
    const n = 20;
    var old: [n]Vec2 = undefined;
    var new: [n]Vec2 = undefined;
    for (0..n) |i| {
        const t: f32 = @floatFromInt(i);
        old[i] = .{ .x = t, .y = t * 0.3 };
        // 90° plus a translation.
        new[i] = .{ .x = -old[i].y + 10, .y = old[i].x - 4 };
    }
    var p50: f32 = 1;
    var p99: f32 = 1;
    try displacementsPercentiles(testing.allocator, &old, &new, &p50, &p99);
    try testing.expect(p50 < 1e-4);
    try testing.expect(p99 < 1e-3);
}

test "Procrustes: one moved point shows up in p99" {
    const n = 20;
    var old: [n]Vec2 = undefined;
    var new: [n]Vec2 = undefined;
    for (0..n) |i| {
        const t: f32 = @floatFromInt(i);
        old[i] = .{ .x = t, .y = 0 };
        new[i] = old[i];
    }
    new[0].x += 5;
    var p50: f32 = 0;
    var p99: f32 = 0;
    try displacementsPercentiles(testing.allocator, &old, &new, &p50, &p99);
    try testing.expect(p50 < 0.5);
    try testing.expect(p99 > 4);
}

test "pickNewEdge finds a missing pair" {
    const gpa = testing.allocator;
    const e = try pathEdges(gpa, 6);
    defer gpa.free(e);
    const got = (try pickNewEdge(gpa, 6, e)) orelse return error.TestExpectedEqual;
    try testing.expect(got.a != got.b);
    var found = false;
    for (e) |x| {
        if ((x.a == got.a and x.b == got.b) or (x.a == got.b and x.b == got.a)) found = true;
    }
    try testing.expect(!found);
}
