//! Where notes actually are.
//!
//! This is the layout, and under the positions-first design it owns the truth: a note's position
//! is decided here, by its links, and everything downstream *derives* from it. `spatial.zig`
//! groups these positions for drawing; `world.zig` decides which groups a given zoom shows. The
//! old arrangement ran the other way — `fold` built a link-derived tree and `containment` placed
//! each note inside its parent's disc — which meant a note had no position of its own, only a
//! slot in whichever cell happened to claim it. That is why notes travelled across the screen as
//! you zoomed, and why the map felt nebulous until you were all the way in.
//!
//! The forces, in the order they matter:
//!
//!   * **Links attract.** Weight is degree-normalised (`w·K/√(dₐ·d_b)`), because a link to a
//!     29,448-degree hub is nearly no evidence of relatedness while a link between two obscure
//!     notes is strong evidence. Measured at ~30% tighter local link spread than raw weights.
//!   * **Everything repels, at short range**, so notes do not pile up — the "bubbles" behaviour.
//!   * **Folder position is a weak tie between orphans only** (`folder_w` against ~1.0 for a real
//!     link), so the notes with no links at all cluster by directory instead of scattering, and
//!     folders never get a say where links already have one.
//!
//! The solve is multilevel (`multilevel.zig`): coarsen, solve the small graph, project down,
//! refine. A single-level solve cannot produce structure larger than the range of its forces,
//! which is the "one massive undifferentiated blob" failure.
//!
//! Two things happen after the solve that the solver cannot do for itself:
//!
//!   * **Each component is scaled to world units before anything is packed.** `multilevel` emits
//!     unit space (~one note per unit); the rest of Atlas is calibrated in note radii. The scale
//!     is chosen so the component's own median leaf spacing is `spacing` note radii — that is
//!     what keeps two notes drawn at radius `r` from overlapping (`< 2r` is overlap by
//!     construction; the old layout sat at 0.95x and sibling overlap was immovable). It has to
//!     happen *per island, before packing*: mixing unit-space cluster radii with a world-space
//!     island margin, then scaling the whole map by the leaf median, multiplies every gap by
//!     `note_r` and sits a linked pair on top of itself while the next island lands tens of
//!     leaf-spacings away. A Wikipedia-scale vault is one component, so it never hit this; a
//!     personal vault of a few dozen notes is almost all islands, and did.
//!   * **Components are then packed as discs.** `multilevel`'s repulsion is cut off at a few
//!     times the node spacing, so it cannot hold two unconnected islands apart — they would
//!     drift through each other and a proximity hierarchy would then put them in the same cell.
//!     Packing is the only place the "islands never share a cell" guarantee can be re-established,
//!     because it is the only place that knows the islands are separate. Radii and the gap
//!     between them are world units, same as the positions.

const std = @import("std");
const dvui = @import("dvui");

const fold = @import("fold.zig");
const multilevel = @import("multilevel.zig");
const spatial = @import("spatial.zig");

pub const Vec2 = spatial.Vec2;
pub const Edge = fold.Edge;

/// Target distance between neighbouring notes, in note radii.
///
/// Above 2.0 because two discs of radius `r` overlap whenever they sit closer than `2r` — the
/// margin above that is what keeps the *tenth* percentile clear, not just the median. `world`
/// exports this as `leaf_pitch`: it is now a chosen number that the solve is calibrated to hit,
/// where it used to be an empirical measurement of `containment`'s settle.
pub const default_spacing: f32 = 2.6;

pub const Options = struct {
    /// World radius one note draws at. Positions come out scaled against this.
    note_r: f32 = 1.0,
    /// Target median distance between neighbouring notes, in note radii. Must exceed 2.0 or
    /// adjacent notes overlap by construction — see the module header. The margin above 2.0 is
    /// what keeps the *tenth* percentile clear, not just the median.
    spacing: f32 = default_spacing,
    /// Exponent on the degree normalisation; 0 disables it, 0.5 is the Salton cosine.
    degree_norm: f32 = 0.5,
    /// Tie strength along the orphan folder chain, against ~1.0 for a real link.
    folder_w: f32 = 0.25,
    /// Area multiplier between packed components. Charged to peers only, never to the anchor —
    /// see `packComponents`.
    pack_gap: f32 = 1.15,
    iters: multilevel.Opts = .{},
    cancel: ?*std.atomic.Value(bool) = null,
};

pub const Result = struct {
    /// One position per note, in world units.
    pos: []Vec2 = &.{},
    /// Which connected component each note landed in. Components are disjoint discs, so this is
    /// what lets `spatial.build` keep islands out of each other's cells.
    comp: []u32 = &.{},
    n_comp: u32 = 0,
    /// Median distance between neighbouring notes, in note radii, after scaling. Should land on
    /// `Options.spacing`; reported because it is the number that decides leaf overlap.
    spacing: f32 = 0,

    pub fn deinit(self: *Result, gpa: std.mem.Allocator) void {
        gpa.free(self.pos);
        gpa.free(self.comp);
        self.* = .{};
    }
};

pub fn solve(
    gpa: std.mem.Allocator,
    n_notes: usize,
    links: []const Edge,
    paths: []const []const u8,
    opts: Options,
) !Result {
    var out: Result = .{};
    errdefer out.deinit(gpa);
    out.pos = try gpa.alloc(Vec2, n_notes);
    out.comp = try gpa.alloc(u32, n_notes);
    if (n_notes == 0) return out;
    @memset(out.pos, .{});
    @memset(out.comp, 0);
    if (n_notes == 1) return out;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // -- the edge set the solve sees ---------------------------------------------------
    // Degree normalisation applies to real links only. The orphan chain is appended afterwards at
    // its own flat weight, so normalising cannot dilute it and it cannot dilute the links.
    const weighted = try fold.degreeNormalised(arena, n_notes, links, opts.degree_norm);
    var aug: std.ArrayListUnmanaged(Edge) = .empty;
    try aug.ensureTotalCapacity(arena, weighted.len + n_notes);
    aug.appendSliceAssumeCapacity(weighted);
    // Deliberately the orphan drawer and not `addPathChain`: a chain over *every* note would fuse
    // the whole vault into one component and there would be nothing left to pack.
    //
    // Guarded on having a path per note because the chain sorts orphans *by* path — a short or
    // absent path array reads out of bounds, and synthetic corpora supply none.
    if (paths.len == n_notes) {
        try fold.addOrphanDrawer(arena, &aug, paths, links, n_notes, opts.folder_w);
    }
    const edges = aug.items;

    out.n_comp = try fold.linkComponents(arena, out.comp, edges, n_notes);

    // -- group notes and edges by component --------------------------------------------
    const notes_csr = try bucket(arena, out.comp, out.n_comp, n_notes);
    const edge_comp = try arena.alloc(u32, edges.len);
    for (edge_comp, edges) |*c, e| c.* = out.comp[e.a];
    const edges_csr = try bucket(arena, edge_comp, out.n_comp, edges.len);

    // `local[note]` is that note's index within its own component's solve.
    const local = try arena.alloc(u32, n_notes);
    for (0..out.n_comp) |c| {
        for (notes_csr.slice(@intCast(c)), 0..) |note, i| local[note] = @intCast(i);
    }

    // -- solve each component on its own ------------------------------------------------
    const centres = try arena.alloc(Vec2, out.n_comp);
    const radii = try arena.alloc(f32, out.n_comp);
    var sub_edges: std.ArrayListUnmanaged(multilevel.Edge) = .empty;
    var sub_pos: std.ArrayListUnmanaged(dvui.Point) = .empty;

    for (0..out.n_comp) |c| {
        if (opts.cancel) |k| if (k.load(.monotonic)) return error.Canceled;
        const members = notes_csr.slice(@intCast(c));
        centres[c] = .{};
        radii[c] = opts.note_r;
        if (members.len == 0) continue;
        if (members.len == 1) {
            out.pos[members[0]] = .{};
            continue;
        }

        sub_edges.clearRetainingCapacity();
        for (edges_csr.slice(@intCast(c))) |ei| {
            const e = edges[ei];
            try sub_edges.append(arena, .{ .a = local[e.a], .b = local[e.b], .w = e.w });
        }
        try sub_pos.resize(arena, members.len);
        var sub_opts = opts.iters;
        sub_opts.cancel = opts.cancel;
        try multilevel.solve(arena, members.len, sub_edges.items, sub_pos.items, sub_opts);

        // Recentre on the component's own centroid and record the disc that contains it, so the
        // pack below can treat each component as a single circle.
        var cx: f64 = 0;
        var cy: f64 = 0;
        for (sub_pos.items) |p| {
            cx += p.x;
            cy += p.y;
        }
        const inv = 1.0 / @as(f64, @floatFromInt(members.len));
        const ctr: Vec2 = .{ .x = @floatCast(cx * inv), .y = @floatCast(cy * inv) };
        var rmax: f32 = 0;
        for (members, sub_pos.items) |note, p| {
            const q: Vec2 = .{ .x = p.x - ctr.x, .y = p.y - ctr.y };
            out.pos[note] = q;
            rmax = @max(rmax, @sqrt(q.x * q.x + q.y * q.y));
        }
        radii[c] = rmax;

        // Unit space → world, using this island's own leaves. A later global scale would
        // recouple island gaps into the median and undo the point of packing in world units.
        const target = opts.spacing * opts.note_r;
        const med = if (members.len == n_notes)
            try spatial.medianSpacing(gpa, out.pos, out.comp)
        else
            try componentMedian(gpa, arena, out.pos, members);
        if (med > 0 and target > 0) {
            const s = target / med;
            for (members) |note| {
                out.pos[note].x *= s;
                out.pos[note].y *= s;
            }
            radii[c] *= s;
        }
    }

    try packComponents(arena, out, notes_csr, radii, centres, opts);
    recentre(out.pos);
    out.spacing = if (opts.note_r > 0)
        (try spatial.medianSpacing(gpa, out.pos, out.comp)) / opts.note_r
    else
        0;
    return out;
}

/// Lay the component discs out around the largest one.
///
/// Lifted from `containment.placeRoots`, whose comments are the hard-won part: `+ rr` puts a
/// component's *edge* on the packed circle rather than its centre, which is what actually keeps
/// them apart, and `pack_gap` is charged to peers only. Charging it to the anchor too pushes
/// every other component out by the square root of it — and when one component dominates, as on
/// any real wiki (Simple English is 98.99% one component), that scales the whole vault's extent
/// by √5.2 ≈ 2.3 and "fit to extents" then has to frame all that emptiness.
fn packComponents(
    arena: std.mem.Allocator,
    out: Result,
    notes_csr: Csr,
    radii: []const f32,
    centres: []Vec2,
    opts: Options,
) !void {
    if (out.n_comp <= 1) return;
    const order = try arena.alloc(u32, out.n_comp);
    for (order, 0..) |*o, i| o.* = @intCast(i);
    const ByCount = struct {
        csr: Csr,
        pub fn lessThan(self: @This(), a: u32, b: u32) bool {
            const ca = self.csr.slice(a).len;
            const cb = self.csr.slice(b).len;
            if (ca != cb) return ca > cb;
            return a < b;
        }
    };
    std.mem.sort(u32, order, ByCount{ .csr = notes_csr }, ByCount.lessThan);

    const golden = std.math.pi * (3.0 - @sqrt(5.0));
    var acc: f32 = 0;
    for (order, 0..) |c, i| {
        const rr = radii[c];
        // World units, same as `rr`. One leaf pitch between the outer notes of two islands is
        // what keeps a proximity hierarchy from putting a note of each in one cell; being
        // additive rather than folded into `acc` it costs the vault one pitch of extent in
        // total. The same expression used to run against unit-space radii (~0.5) and then get
        // scaled by ~`note_r` with the rest of the map, so the gap landed at `note_r` pitches.
        const margin = opts.spacing * opts.note_r;
        const rad = if (i == 0) 0 else @sqrt(acc) + rr + margin;
        acc += rr * rr * (if (i == 0) 1 else opts.pack_gap);
        const a = @as(f32, @floatFromInt(i)) * golden;
        centres[c] = .{ .x = @cos(a) * rad, .y = @sin(a) * rad };
        for (notes_csr.slice(c)) |note| {
            out.pos[note].x += centres[c].x;
            out.pos[note].y += centres[c].y;
        }
    }
}

/// Median leaf spacing of one component, from its members' already-written positions.
fn componentMedian(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    pos: []const Vec2,
    members: []const u32,
) !f32 {
    if (members.len < 2) return 0;
    if (members.len == 2) return dist(pos[members[0]], pos[members[1]]);
    const tmp = try arena.alloc(Vec2, members.len);
    const keys = try arena.alloc(u32, members.len);
    @memset(keys, 0);
    for (members, tmp) |note, *p| p.* = pos[note];
    return spatial.medianSpacing(gpa, tmp, keys);
}

fn dist(a: Vec2, b: Vec2) f32 {
    const dx = a.x - b.x;
    const dy = a.y - b.y;
    return @sqrt(dx * dx + dy * dy);
}

/// Put the centre of the content at the origin.
///
/// `World.extent` reports a radius *about the origin*, `graph.zig` builds `world_bounds` as
/// `{-r, -r, 2r, 2r}`, and `vaultExtentsPose` hardcodes centre `(0, 0)`. All three were true only
/// because the old packer happened to put the biggest island there. Doing it explicitly here lets
/// those three call sites keep their assumption honestly.
fn recentre(pos: []Vec2) void {
    if (pos.len == 0) return;
    var lo = pos[0];
    var hi = pos[0];
    for (pos) |p| {
        lo.x = @min(lo.x, p.x);
        lo.y = @min(lo.y, p.y);
        hi.x = @max(hi.x, p.x);
        hi.y = @max(hi.y, p.y);
    }
    const cx = (lo.x + hi.x) * 0.5;
    const cy = (lo.y + hi.y) * 0.5;
    for (pos) |*p| {
        p.x -= cx;
        p.y -= cy;
    }
}

// ---- grouping -------------------------------------------------------------------------------

/// Items grouped by key, as one counting-sorted array plus offsets. A plain counting sort rather
/// than a list-of-lists because the component count is tiny and the item count is not.
const Csr = struct {
    items: []u32 = &.{},
    off: []u32 = &.{},

    fn slice(self: Csr, key: u32) []const u32 {
        return self.items[self.off[key]..self.off[key + 1]];
    }
};

fn bucket(arena: std.mem.Allocator, keys: []const u32, n_keys: u32, n: usize) !Csr {
    const off = try arena.alloc(u32, n_keys + 1);
    @memset(off, 0);
    for (keys[0..n]) |k| off[k + 1] += 1;
    for (1..off.len) |i| off[i] += off[i - 1];
    const items = try arena.alloc(u32, n);
    const cur = try arena.alloc(u32, n_keys);
    @memcpy(cur, off[0..n_keys]);
    for (keys[0..n], 0..) |k, i| {
        items[cur[k]] = @intCast(i);
        cur[k] += 1;
    }
    return .{ .items = items, .off = off };
}

// ---- tests ----------------------------------------------------------------------------------

const testing = std.testing;

/// A ring of `n` notes, plus `orphans` notes with no links at all.
fn ringFixture(arena: std.mem.Allocator, n: u32, orphans: u32) !struct { edges: []Edge, paths: [][]const u8 } {
    const edges = try arena.alloc(Edge, n);
    for (edges, 0..) |*e, i| e.* = .{ .a = @intCast(i), .b = @intCast((i + 1) % n) };
    const paths = try arena.alloc([]const u8, n + orphans);
    for (paths, 0..) |*p, i| p.* = try std.fmt.allocPrint(arena, "dir{d}/note{d:0>5}.md", .{ i % 3, i });
    return .{ .edges = edges, .paths = paths };
}

test "leaves are spaced far enough apart not to overlap" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const fx = try ringFixture(arena_state.allocator(), 400, 40);

    var res = try solve(testing.allocator, 440, fx.edges, fx.paths, .{ .note_r = 4, .spacing = 2.6 });
    defer res.deinit(testing.allocator);

    // The whole point of the layout owning positions: it can guarantee this, and no grouping
    // built on top of it can. Two notes drawn at radius r overlap whenever they are closer
    // than 2r, so this is the condition for a non-overlapping map.
    try testing.expect(res.spacing > 2.0);
    try testing.expectApproxEqAbs(@as(f32, 2.6), res.spacing, 0.35);
}

test "unconnected islands land in disjoint discs" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Three separate rings of 30, sharing no links.
    const n: u32 = 90;
    var edges: std.ArrayListUnmanaged(Edge) = .empty;
    for (0..3) |g| {
        const base: u32 = @intCast(g * 30);
        for (0..30) |i| {
            try edges.append(arena, .{ .a = base + @as(u32, @intCast(i)), .b = base + @as(u32, @intCast((i + 1) % 30)) });
        }
    }
    const paths = try arena.alloc([]const u8, n);
    for (paths, 0..) |*p, i| p.* = try std.fmt.allocPrint(arena, "n{d}.md", .{i});

    var res = try solve(testing.allocator, n, edges.items, paths, .{ .note_r = 4 });
    defer res.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 3), res.n_comp);

    // Each component's bounding disc must clear every other's. This is the guarantee that used
    // to live in `fold.Cell.comp`; a proximity hierarchy cannot enforce it, so the layout must.
    var ctr: [3]Vec2 = @splat(.{});
    var cnt: [3]f32 = @splat(0);
    for (res.pos, res.comp) |p, c| {
        ctr[c].x += p.x;
        ctr[c].y += p.y;
        cnt[c] += 1;
    }
    for (&ctr, cnt) |*m, k| {
        m.x /= k;
        m.y /= k;
    }
    var rad: [3]f32 = @splat(0);
    for (res.pos, res.comp) |p, c| {
        const dx = p.x - ctr[c].x;
        const dy = p.y - ctr[c].y;
        rad[c] = @max(rad[c], @sqrt(dx * dx + dy * dy));
    }
    for (0..3) |a| {
        for (a + 1..3) |b| {
            const dx = ctr[a].x - ctr[b].x;
            const dy = ctr[a].y - ctr[b].y;
            try testing.expect(@sqrt(dx * dx + dy * dy) > rad[a] + rad[b]);
        }
    }
}

test "a handful of islands keep their leaves apart without emptying the map" {
    // The fizzy-vault shape: a few tiny components, no giant. Packing used to mix the solver's
    // unit space with a world-space island margin and then scale the whole map by the leaf
    // median, which sat each linked pair on top of itself (so they coalesced at every zoom
    // the budget would otherwise have resolved) and threw the next island tens of leaf-spacings
    // away. A Wikipedia-scale vault is one component and never hit this.
    const note_r: f32 = 4;
    const spacing: f32 = 2.6;
    const pitch = spacing * note_r;
    const edges = [_]Edge{
        .{ .a = 0, .b = 1 },
        .{ .a = 2, .b = 3 },
        .{ .a = 4, .b = 5 },
    };
    const paths = [_][]const u8{ "a.md", "b.md", "c.md", "d.md", "e.md", "f.md" };
    var res = try solve(testing.allocator, 6, &edges, &paths, .{ .note_r = note_r, .spacing = spacing });
    defer res.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 3), res.n_comp);

    const pair_d = [_]f32{
        dist(res.pos[0], res.pos[1]),
        dist(res.pos[2], res.pos[3]),
        dist(res.pos[4], res.pos[5]),
    };
    for (pair_d) |d| {
        try testing.expect(d > pitch * 0.5);
        try testing.expect(d < pitch * 2.5);
    }

    var ctr: [3]Vec2 = @splat(.{});
    for (0..3) |g| {
        ctr[g] = .{
            .x = (res.pos[g * 2].x + res.pos[g * 2 + 1].x) * 0.5,
            .y = (res.pos[g * 2].y + res.pos[g * 2 + 1].y) * 0.5,
        };
    }
    var max_island: f32 = 0;
    for (0..3) |a| {
        for (a + 1..3) |b| {
            max_island = @max(max_island, dist(ctr[a], ctr[b]));
        }
    }
    // One-to-two leaf pitches of air between small islands, not the ~50x blow-up mixed units
    // produced. Fit-to-extents then lands at a zoom where a two-note parent clears split_px.
    try testing.expect(max_island < pitch * 8);
}

test "the content is centred on the origin" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const fx = try ringFixture(arena_state.allocator(), 200, 20);

    var res = try solve(testing.allocator, 220, fx.edges, fx.paths, .{ .note_r = 4 });
    defer res.deinit(testing.allocator);

    // `World.extent` reports a radius about the origin and `vaultExtentsPose` hardcodes centre
    // (0, 0); both are only correct if the layout puts the content there.
    var lo = res.pos[0];
    var hi = res.pos[0];
    for (res.pos) |p| {
        lo.x = @min(lo.x, p.x);
        lo.y = @min(lo.y, p.y);
        hi.x = @max(hi.x, p.x);
        hi.y = @max(hi.y, p.y);
    }
    const span = @max(hi.x - lo.x, hi.y - lo.y);
    try testing.expect(@abs(lo.x + hi.x) < span * 1e-3);
    try testing.expect(@abs(lo.y + hi.y) < span * 1e-3);
}

test "the same graph lays out identically twice" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const fx = try ringFixture(arena_state.allocator(), 150, 10);

    var a = try solve(testing.allocator, 160, fx.edges, fx.paths, .{ .note_r = 4 });
    defer a.deinit(testing.allocator);
    var b = try solve(testing.allocator, 160, fx.edges, fx.paths, .{ .note_r = 4 });
    defer b.deinit(testing.allocator);

    // Positions are about to be persisted and diffed against; a solve that wanders between runs
    // would make every republish look like every note moved.
    for (a.pos, b.pos) |p, q| {
        try testing.expectEqual(p.x, q.x);
        try testing.expectEqual(p.y, q.y);
    }
}

test "a cancelled solve gives up" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const fx = try ringFixture(arena_state.allocator(), 300, 0);

    var flag = std.atomic.Value(bool).init(true);
    try testing.expectError(error.Canceled, solve(testing.allocator, 300, fx.edges, fx.paths, .{ .cancel = &flag }));
}

test "an empty or single-note vault is not a special case at the call site" {
    var a = try solve(testing.allocator, 0, &.{}, &.{}, .{});
    defer a.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), a.pos.len);

    var b = try solve(testing.allocator, 1, &.{}, &.{"only.md"}, .{});
    defer b.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), b.pos.len);
}
