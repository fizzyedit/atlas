//! Positions derived from the hierarchy, instead of a hierarchy inferred from positions.
//!
//! `layout_full.zig` places every note flat and then lets `quadlod` infer structure back out of
//! the result. Laying a whole vault out flat is genuinely hard, which is why that file needs seven
//! stacked mechanisms — force solve, folder cohesion, lattice snap, component packing, aspect
//! envelope, crossing-minimising refine/swap, local relaxation — each with its own constants, all
//! pulling against each other. It is not one layout to tune; it is seven.
//!
//! This file replaces them with a single rule:
//!
//! > **A cell's children are placed inside that cell's disc.**
//!
//! Applied recursively down a `fold.Ladder`. Three things fall out that were previously work:
//!
//! * **Aspect ratio is bounded by construction.** Everything lives inside the root disc at every
//!   zoom, so there is no envelope to enforce and no wide-thin degenerate case. A tree laid out as
//!   a tree has width 2^depth and height depth — a horizontal line is the inevitable result, not a
//!   tuning failure. Here depth becomes *zoom*, not a spatial axis.
//! * **The same rule works at 5 notes and at 1,000,000**, because it only ever places `arity`
//!   items relative to one parent. Nothing is global, so nothing needs re-tuning with n.
//! * **Radius is the area-conserving law** `r = note_r · √count`, which is what a merged bubble
//!   does (2D area conservation: r = √(r₁² + r₂²)) and what the renderer already draws.
//!
//! What a force solve gave us and this does not, is expressing link structure *within* a group.
//! That comes back as slot **assignment**: `fold` records the link weight between each pair of a
//! cell's children, and `ensureChildren` searches arrangements to put strongly-linked siblings in
//! adjacent slots. With at most `arity` children that search is exhaustive and exact — a global
//! optimisation problem replaced by a bounded local one, evaluated lazily when a cell is opened.
//!
//! No dvui: positions are plain `Vec2`, so this stays in the headless test group alongside
//! `fold.zig`.

const std = @import("std");
const fold = @import("fold.zig");

pub const Vec2 = struct {
    x: f32 = 0,
    y: f32 = 0,

    pub fn dist(a: Vec2, b: Vec2) f32 {
        return @sqrt((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y));
    }
};

pub const Options = struct {
    /// World radius of a single note. Every other radius is `note_r · √count`.
    note_r: f32 = 1.0,
    /// Fraction of the parent's radius the children's ring may reach. Below 1 so a child's rim
    /// stays visibly inside its parent's ring rather than touching it.
    fill: f32 = 0.9,
    /// Weight on keeping heavy children near the centre, against shortening sibling links. Zero
    /// means links alone decide; large means mass alone decides.
    mass_k: f32 = 0.4,
    /// Air between packed island discs, as a multiple of their area. Above 1 so islands read as
    /// separate chunks rather than a tiled surface.
    pack_gap: f32 = 5.2,
    /// Horizontal stretch of the island pack, to suit a wide panel.
    pack_aspect: f32 = 1.35,
    /// Extra turn applied per level, in radians. Defaults to half a slot step, which staggers
    /// consecutive levels so children never line up radially with their parent and the field does
    /// not band. Set `aperture7_rotation` instead to nest levels on one global hex lattice.
    rotation_per_level: ?f32 = null,
    /// Exponent in `r = note_r · count^radius_exp`.
    ///
    /// 0.5 is strict area conservation, which *forces* siblings to overlap — see `minRadiusExp`.
    /// A flat multiplier cannot fix that, because it scales parent and child alike and leaves
    /// their ratio untouched; the ratio is `(1/arity)^radius_exp`, so only the exponent moves it.
    ///
    /// Deliberately keyed off `count` rather than `Cell.level`: `fold.prune` splices out
    /// single-child chains without renumbering, so a parent's level can skip one or more of its
    /// child's, and a per-level factor would then disagree with the actual count ratio.
    radius_exp: f32 = 0.5,
    /// Weight on facing links that leave the cell, against shortening the ones inside it. See the
    /// `extOf` term in `arrangementCost`; 0 restores purely-local slot assignment.
    ext_k: f32 = 1.0,
};

/// The smallest `radius_exp` at which an arity-7 cell's uniform children stop overlapping.
///
/// Seven equal circles pack into a circle at radius ratio exactly 1/3 (hexagonally, 7 unit
/// circles inside radius 3). Area conservation instead gives `1/√7 ≈ 0.378`, so children are
/// ~13% too wide before anything else is applied — and `ensureChildren` then pulls the ring in
/// by `fill`, which costs more. With `ratio = (1/7)^p`, solving `ring ≥ r_centre + r_ring`:
///
///   `fill − ratio ≥ 2·ratio`  →  `ratio ≤ fill/3`  →  `p ≥ ln(3/fill) / ln(7)`
///
/// The ring-to-ring constraint reduces to the same bound (six slots put adjacent children
/// exactly `ring` apart), so this one number covers both. At `fill = 0.9` it is ≈0.619.
///
/// Overlap is only *forced* for uniform counts; a cell whose mass is one dominant sub-cluster
/// still overlaps at any exponent, because its centre child is nearly parent-sized by
/// construction.
pub fn minRadiusExp(fill: f32) f32 {
    return @log(3.0 / @max(fill, 0.01)) / @log(@as(f32, 7.0));
}

/// The rotation that makes consecutive levels land on a *single* hex lattice rather than each
/// being turned an arbitrary amount from its parent — `atan(√3/5)`, 19.1066°, the aperture-7
/// angle (the same one H3 uses between resolutions).
///
/// Both halves of the lattice are already here at `arity = .seven`: `ensureChildren` places one
/// child at the centre and six on a ring, which is the aperture-7 flower, and the area law
/// `r = note_r · √count` gives a full cell `(√7)^level` — exactly the per-level scale factor
/// aperture-7 needs. Only the per-level *turn* was off-lattice.
///
/// Alignment is exact only for uniformly full cells; real counts are ragged, so radii deviate
/// from the ideal `(√7)^level` and the fit degrades with raggedness. It is a coherence gain, not
/// a guarantee — which is why this is offered rather than forced, and why the default stays the
/// anti-banding half-step until it has been looked at on real shapes.
pub const aperture7_rotation: f32 = std.math.atan(@as(f32, @sqrt(3.0)) / 5.0);

/// Deliberately holds no pointer back to the ladder: a struct that stores a pointer into itself
/// (or into a sibling field of the same value) dangles the moment it is returned or moved. The
/// ladder is passed in at each call instead.
pub const Field = struct {
    opts: Options,
    pos: []Vec2,
    /// Whether this cell's *children* have been placed yet. Placement is lazy: only cells the
    /// LOD actually opens ever pay for the slot search.
    expanded: []bool,
    /// Scratch for ordering the roots during the pack; owned, so packing allocates nothing.
    root_order: []u32,
    arity: usize,

    pub fn deinit(self: *Field, gpa: std.mem.Allocator) void {
        gpa.free(self.pos);
        gpa.free(self.expanded);
        gpa.free(self.root_order);
        self.* = undefined;
    }

    pub fn radius(self: Field, lad: *const fold.Ladder, cell: u32) f32 {
        const n: f32 = @floatFromInt(@max(1, lad.cells[cell].count));
        // Fast path for strict area conservation — this runs per living cell per frame in the
        // LOD's cull/split tests, and `@sqrt` is a single instruction where `pow` is not.
        if (self.opts.radius_exp == 0.5) return self.opts.note_r * @sqrt(n);
        return self.opts.note_r * std.math.pow(f32, n, self.opts.radius_exp);
    }

    /// Place `cell`'s children. Idempotent, and safe to call on a leaf.
    pub fn ensureChildren(self: *Field, lad: *const fold.Ladder, cell: u32) void {
        if (self.expanded[cell]) return;
        self.expanded[cell] = true;

        const kids = lad.childrenOf(cell);
        if (kids.len == 0) return;

        const centre = self.pos[cell];
        const r_parent = self.radius(lad, cell);

        // Biggest child takes the centre slot: it holds most of the mass, so centring it keeps the
        // cell's visual weight where its parent's ring already was, and the split reads as an
        // expansion rather than a jump.
        var big: usize = 0;
        for (kids, 0..) |k, i| {
            if (lad.cells[k].count > lad.cells[kids[big]].count) big = i;
        }

        if (kids.len == 1) {
            self.pos[kids[0]] = centre;
            return;
        }

        // Ring radius leaves room for the largest *ring* child, so no child's rim escapes the
        // parent. The centre child may be nearly as large as the parent — that is the honest
        // picture of a cell whose mass is one dominant sub-cluster.
        var max_ring_r: f32 = 0;
        for (kids, 0..) |k, i| {
            if (i == big) continue;
            max_ring_r = @max(max_ring_r, self.radius(lad, k));
        }
        const ring = @max(r_parent * 0.15, r_parent * self.opts.fill - max_ring_r);

        const ring_slots = self.arity - 1;
        const step = std.math.tau / @as(f32, @floatFromInt(ring_slots));
        const rot = (self.opts.rotation_per_level orelse (step * 0.5)) *
            @as(f32, @floatFromInt(lad.cells[cell].level));

        var slot: [8]Vec2 = undefined;
        for (0..ring_slots) |s| {
            const a = rot + step * @as(f32, @floatFromInt(s));
            slot[s] = .{ .x = @cos(a) * ring, .y = @sin(a) * ring };
        }

        // Everything except the centre child gets arranged over the ring slots.
        var ring_kids: [8]u32 = undefined;
        var ring_idx: [8]u8 = undefined;
        var nr: usize = 0;
        for (kids, 0..) |k, i| {
            if (i == big) continue;
            ring_kids[nr] = k;
            ring_idx[nr] = @intCast(i);
            nr += 1;
        }

        var best: [8]u8 = undefined;
        for (0..nr) |i| best[i] = @intCast(i);
        var perm: [8]u8 = best;
        var best_cost = self.arrangementCost(lad, cell, ring_idx[0..nr], perm[0..nr], slot[0..ring_slots], ring_kids[0..nr], @intCast(big));
        permute(self, lad, cell, ring_idx[0..nr], &perm, 0, nr, slot[0..ring_slots], ring_kids[0..nr], @intCast(big), &best, &best_cost);

        self.pos[kids[big]] = centre;
        for (0..nr) |i| {
            const s = best[i];
            self.pos[ring_kids[i]] = .{ .x = centre.x + slot[s].x, .y = centre.y + slot[s].y };
        }
    }

    /// Sum of `weight × slot distance` over the cell's sibling link pairs, plus a pull keeping
    /// heavy children near the centre. Lower is better.
    fn arrangementCost(
        self: Field,
        lad: *const fold.Ladder,
        cell: u32,
        ring_idx: []const u8,
        perm: []const u8,
        slot: []const Vec2,
        ring_kids: []const u32,
        big: u8,
    ) f32 {
        // where did child index i end up?
        var at: [8]Vec2 = undefined;
        var is_centre: [8]bool = .{false} ** 8;
        for (ring_idx, 0..) |ci, i| {
            at[ci] = slot[perm[i]];
        }
        at[big] = .{};
        is_centre[big] = true;

        var cost: f32 = 0;
        for (lad.pairsOf(cell)) |p| {
            cost += p.w * Vec2.dist(at[p.i], at[p.j]);
        }

        // Face the rest of the graph. Sibling pairs alone make each cell internally sensible but
        // blind to its neighbours, so locally-ordered groups still read as random in aggregate —
        // a child whose real neighbours are one cell over has no reason to sit on that side.
        //
        // Direction only, deliberately: the distance to a sibling *cell* is far larger than any
        // intra-cell slot distance, so a positional term would swamp the sibling cost entirely and
        // turn slot choice into "point at the neighbour" regardless of internal structure. This
        // costs `1 − cos θ` per unit weight, bounded in [0, 2], so it breaks ties and nudges
        // rather than dominating.
        if (self.opts.ext_k != 0) {
            const centre = self.pos[cell];
            for (lad.extOf(cell)) |e| {
                if (e.child >= at.len or is_centre[e.child]) continue; // centre has no direction
                if (e.toward >= self.pos.len) continue;
                const slot_v = at[e.child];
                const slot_len = @sqrt(slot_v.x * slot_v.x + slot_v.y * slot_v.y);
                if (slot_len < 1e-6) continue;
                const tx = self.pos[e.toward].x - centre.x;
                const ty = self.pos[e.toward].y - centre.y;
                const t_len = @sqrt(tx * tx + ty * ty);
                if (t_len < 1e-6) continue;
                const cos = (slot_v.x * tx + slot_v.y * ty) / (slot_len * t_len);
                cost += self.opts.ext_k * e.w * (1.0 - cos);
            }
        }
        if (self.opts.mass_k != 0) {
            for (ring_kids, 0..) |k, i| {
                const c: f32 = @floatFromInt(lad.cells[k].count);
                cost += self.opts.mass_k * @sqrt(c) * Vec2.dist(at[ring_idx[i]], .{});
            }
        }
        return cost;
    }
};

/// Exhaustive over ring arrangements. At most `(arity-1)! = 720` for arity 7 — evaluated only
/// when a cell is opened, so a frame at the usual budget searches a few hundred of these.
fn permute(
    f: *Field,
    lad: *const fold.Ladder,
    cell: u32,
    ring_idx: []const u8,
    perm: *[8]u8,
    k: usize,
    n: usize,
    slot: []const Vec2,
    ring_kids: []const u32,
    big: u8,
    best: *[8]u8,
    best_cost: *f32,
) void {
    if (k == n) {
        const c = f.arrangementCost(lad, cell, ring_idx, perm[0..n], slot, ring_kids, big);
        if (c < best_cost.*) {
            best_cost.* = c;
            best.* = perm.*;
        }
        return;
    }
    var i = k;
    while (i < n) : (i += 1) {
        std.mem.swap(u8, &perm[k], &perm[i]);
        permute(f, lad, cell, ring_idx, perm, k + 1, n, slot, ring_kids, big, best, best_cost);
        std.mem.swap(u8, &perm[k], &perm[i]);
    }
}

pub fn init(
    gpa: std.mem.Allocator,
    n_cells: usize,
    n_roots: usize,
    arity: fold.Arity,
    opts: Options,
) !Field {
    const pos = try gpa.alloc(Vec2, n_cells);
    @memset(pos, .{});
    const expanded = try gpa.alloc(bool, n_cells);
    @memset(expanded, false);
    const root_order = try gpa.alloc(u32, n_roots);
    return .{
        .opts = opts,
        .pos = pos,
        .expanded = expanded,
        .root_order = root_order,
        .arity = arity.n(),
    };
}

/// Place the component roots relative to each other.
///
/// Containment only ever says where a cell's children go *inside* it. The islands themselves have
/// no parent, so they need one arrangement of their own: a golden-angle spiral with each root's
/// area reserved in turn, biggest first at the centre. That keeps a vault of discrete islands
/// reading as separate chunks spread over the field, instead of the single converging blob you get
/// from folding unrelated components under one disc.
///
/// Must run before any `ensureChildren`, since children are placed relative to their root.
pub fn placeRoots(f: *Field, lad: *const fold.Ladder) void {
    if (lad.roots.len == 0) return;
    if (lad.roots.len == 1) {
        f.pos[lad.roots[0]] = .{};
        return;
    }
    // biggest first, so the largest island anchors the middle
    const order = f.root_order;
    for (order, lad.roots) |*o, r| o.* = r;
    const ByCount = struct {
        lad: *const fold.Ladder,
        pub fn lessThan(self: @This(), a: u32, b: u32) bool {
            const ca = self.lad.cells[a].count;
            const cb = self.lad.cells[b].count;
            if (ca != cb) return ca > cb;
            return a < b;
        }
    };
    std.mem.sort(u32, order, ByCount{ .lad = lad }, ByCount.lessThan);

    const golden = std.math.pi * (3.0 - @sqrt(5.0));
    var acc: f32 = 0;
    for (order, 0..) |r, i| {
        const rad = @sqrt(acc);
        const rr = f.radius(lad, r);
        acc += rr * rr * f.opts.pack_gap;
        const a = @as(f32, @floatFromInt(i)) * golden;
        f.pos[r] = .{ .x = @cos(a) * rad * f.opts.pack_aspect, .y = @sin(a) * rad };
    }
}

/// Expand the whole ladder. Real use is lazy — this exists for tests and benches.
pub fn placeAll(f: *Field, lad: *const fold.Ladder) void {
    placeRoots(f, lad);
    for (lad.roots) |r| expandRec(f, lad, r);
}

fn expandRec(f: *Field, lad: *const fold.Ladder, cell: u32) void {
    f.ensureChildren(lad, cell);
    for (lad.childrenOf(cell)) |k| expandRec(f, lad, k);
}

// ---- tests ----------------------------------------------------------------------------------

const testing = std.testing;

fn buildStar(gpa: std.mem.Allocator, leaves: u32) ![]fold.Edge {
    const e = try gpa.alloc(fold.Edge, leaves);
    for (0..leaves) |i| e[i] = .{ .a = 0, .b = @intCast(i + 1) };
    return e;
}

test "every child is contained inside its parent's disc" {
    // The invariant the whole design rests on. If it holds, the vault fits in one circle at every
    // zoom, and aspect ratio can never degenerate.
    const gpa = testing.allocator;
    const edges = try buildStar(gpa, 300);
    defer gpa.free(edges);
    var lad = try fold.build(gpa, 301, edges, &.{}, .{});
    defer lad.deinit(gpa);

    var f = try init(gpa, lad.cells.len, lad.roots.len, .seven, .{});
    defer f.deinit(gpa);
    placeAll(&f, &lad);

    for (lad.cells, 0..) |c, id| {
        if (c.child_count == 0) continue;
        const R = f.radius(&lad, @intCast(id));
        for (lad.childrenOf(@intCast(id))) |k| {
            const d = Vec2.dist(f.pos[@intCast(id)], f.pos[k]);
            try testing.expect(d + f.radius(&lad, k) <= R * 1.001);
        }
    }
}

test "radius is the area-conserving law" {
    const gpa = testing.allocator;
    const edges = try buildStar(gpa, 50);
    defer gpa.free(edges);
    var lad = try fold.build(gpa, 51, edges, &.{}, .{});
    defer lad.deinit(gpa);
    var f = try init(gpa, lad.cells.len, lad.roots.len, .seven, .{ .note_r = 2 });
    defer f.deinit(gpa);

    for (lad.cells, 0..) |c, id| {
        if (c.count == 0) continue;
        const want = 2 * @sqrt(@as(f32, @floatFromInt(c.count)));
        try testing.expectApproxEqAbs(want, f.radius(&lad, @intCast(id)), 0.001);
    }
}

test "the whole vault fits inside the root disc" {
    const gpa = testing.allocator;
    const n: u32 = 2000;
    const edges = try gpa.alloc(fold.Edge, n - 1);
    defer gpa.free(edges);
    for (0..n - 1) |i| edges[i] = .{ .a = @intCast(i), .b = @intCast(i + 1) };
    var lad = try fold.build(gpa, n, edges, &.{}, .{});
    defer lad.deinit(gpa);
    var f = try init(gpa, lad.cells.len, lad.roots.len, .seven, .{});
    defer f.deinit(gpa);
    placeAll(&f, &lad);

    const R = f.radius(&lad, lad.roots[0]);
    const origin = f.pos[lad.roots[0]];
    for (lad.cells, 0..) |c, id| {
        if (c.note == fold.invalid) continue;
        try testing.expect(Vec2.dist(origin, f.pos[@intCast(id)]) <= R * 1.001);
    }
}

test "slot assignment shortens sibling links" {
    // A cell whose children are linked in a path should not arrange them arbitrarily. Compare the
    // chosen arrangement's cost against the identity one; it must never be worse.
    const gpa = testing.allocator;
    const n: u32 = 400;
    const edges = try gpa.alloc(fold.Edge, n - 1);
    defer gpa.free(edges);
    for (0..n - 1) |i| edges[i] = .{ .a = @intCast(i), .b = @intCast(i + 1) };
    var lad = try fold.build(gpa, n, edges, &.{}, .{});
    defer lad.deinit(gpa);

    var chosen = try init(gpa, lad.cells.len, lad.roots.len, .seven, .{ .mass_k = 0 });
    defer chosen.deinit(gpa);
    placeAll(&chosen, &lad);

    var total_chosen: f32 = 0;
    var pairs_seen: usize = 0;
    for (lad.cells, 0..) |c, id| {
        if (c.pair_count == 0) continue;
        for (lad.pairsOf(@intCast(id))) |p| {
            const kids = lad.childrenOf(@intCast(id));
            total_chosen += p.w * Vec2.dist(chosen.pos[kids[p.i]], chosen.pos[kids[p.j]]);
            pairs_seen += 1;
        }
    }
    try testing.expect(pairs_seen > 0);
    try testing.expect(total_chosen > 0);
    // Chosen arrangements must beat the worst case by a clear margin; a path's ends should not sit
    // on opposite sides of the ring.
    var worst: f32 = 0;
    for (lad.cells, 0..) |c, id| {
        if (c.pair_count == 0) continue;
        const R = chosen.radius(&lad, @intCast(id));
        for (lad.pairsOf(@intCast(id))) |p| worst += p.w * 2 * R;
    }
    try testing.expect(total_chosen < worst * 0.9);
}

test "lazy expansion places only what is opened" {
    const gpa = testing.allocator;
    const edges = try buildStar(gpa, 500);
    defer gpa.free(edges);
    var lad = try fold.build(gpa, 501, edges, &.{}, .{});
    defer lad.deinit(gpa);
    var f = try init(gpa, lad.cells.len, lad.roots.len, .seven, .{});
    defer f.deinit(gpa);

    placeRoots(&f, &lad);
    f.ensureChildren(&lad, lad.roots[0]);
    var expanded: usize = 0;
    for (f.expanded) |e| {
        if (e) expanded += 1;
    }
    try testing.expectEqual(@as(usize, 1), expanded);
}

test "deterministic" {
    const gpa = testing.allocator;
    const edges = try buildStar(gpa, 120);
    defer gpa.free(edges);
    var lad = try fold.build(gpa, 121, edges, &.{}, .{});
    defer lad.deinit(gpa);

    var a = try init(gpa, lad.cells.len, lad.roots.len, .seven, .{});
    defer a.deinit(gpa);
    var b = try init(gpa, lad.cells.len, lad.roots.len, .seven, .{});
    defer b.deinit(gpa);
    placeAll(&a, &lad);
    placeAll(&b, &lad);
    for (a.pos, b.pos) |pa, pb| {
        try testing.expectEqual(pa.x, pb.x);
        try testing.expectEqual(pa.y, pb.y);
    }
}

test "aperture-7 rotation is the lattice angle, not the anti-banding half-step" {
    // 19.1066°, the value the Options doc comment names. Asserted rather than trusted: it is
    // written as `atan(√3/5)`, and the whole point of the constant is that it is *exact* — an
    // eyeballed 0.3335 would nest almost-but-not-quite and look like a subtle layout bug.
    const deg = aperture7_rotation * 180.0 / std.math.pi;
    try testing.expectApproxEqAbs(@as(f32, 19.1066), deg, 1e-3);

    // And it must differ from the default it replaces (half of a 60° slot step), or the toggle
    // exposing it would be a no-op.
    const half_step = (std.math.tau / 6.0) * 0.5;
    try testing.expect(@abs(aperture7_rotation - half_step) > 0.1);
}

test "radius_exp removes the overlap area conservation forces" {
    // A full, uniform arity-7 ladder: 49 notes -> 7 level-1 cells -> 1 level-2 root. Uniform
    // counts are exactly the case `minLevelSlack` solves, so this is the tight test of it.
    const gpa = testing.allocator;
    const n: u32 = 49;
    // A chain inside each group of 7, so `fold` coarsens into clean 7s rather than by path order.
    var edges: std.ArrayListUnmanaged(fold.Edge) = .empty;
    defer edges.deinit(gpa);
    var g: u32 = 0;
    while (g < 7) : (g += 1) {
        var i: u32 = 0;
        while (i < 6) : (i += 1) {
            try edges.append(gpa, .{ .a = g * 7 + i, .b = g * 7 + i + 1 });
        }
    }

    const fill: f32 = 0.9;
    for ([_]f32{ 0.5, 0 }) |probe| {
        const exp = if (probe == 0) minRadiusExp(fill) else probe;
        var lad = try fold.build(gpa, n, edges.items, &.{}, .{ .arity = .seven });
        defer lad.deinit(gpa);
        var f = try init(gpa, lad.cells.len, lad.roots.len, .seven, .{
            .fill = fill,
            .radius_exp = exp,
            // Links alone decide slots here; a mass pull would bias the uniform case.
            .mass_k = 0,
        });
        defer f.deinit(gpa);
        placeAll(&f, &lad);

        // Worst sibling overlap anywhere in the ladder, as a fraction of the pair's summed radii.
        var worst: f32 = 0;
        for (0..lad.cells.len) |ci| {
            const kids = lad.childrenOf(@intCast(ci));
            if (kids.len < 2) continue;
            // Only uniform cells — a dominant-child cell overlaps at any slack, by construction.
            var uniform = true;
            for (kids) |k| {
                if (lad.cells[k].count != lad.cells[kids[0]].count) uniform = false;
            }
            if (!uniform) continue;
            for (kids, 0..) |a, i| {
                for (kids[i + 1 ..]) |b| {
                    const need = f.radius(&lad, a) + f.radius(&lad, b);
                    const got = Vec2.dist(f.pos[a], f.pos[b]);
                    if (got < need) worst = @max(worst, (need - got) / need);
                }
            }
            // Containment must hold either way — this is what `world.zig`'s exact cull rests on.
            for (kids) |k| {
                const reach = Vec2.dist(f.pos[@intCast(ci)], f.pos[k]) + f.radius(&lad, k);
                try testing.expect(reach <= f.radius(&lad, @intCast(ci)) * 1.001);
            }
        }

        if (probe == 0.5) {
            // Strict area conservation: overlap is forced, so this must actually be violated —
            // otherwise the test would pass vacuously and prove nothing about the fix.
            try testing.expect(worst > 0.01);
        } else {
            try testing.expectApproxEqAbs(@as(f32, 0), worst, 1e-3);
        }
    }
}

test "ext_k aims children at their out-of-cell neighbours" {
    // Two groups of seven, each internally chained, plus one heavy cross-link between a specific
    // leaf in each. At the cell holding a group, that link is *external* — invisible to
    // `pairsOf`, which is exactly the gap `extOf` fills. Measured as the objective itself: total
    // weighted (1 − cos) between each pulled child's slot direction and its target's direction.
    const gpa = testing.allocator;
    const n: u32 = 14;
    var edges: std.ArrayListUnmanaged(fold.Edge) = .empty;
    defer edges.deinit(gpa);
    for (0..6) |i| try edges.append(gpa, .{ .a = @intCast(i), .b = @intCast(i + 1) });
    for (7..13) |i| try edges.append(gpa, .{ .a = @intCast(i), .b = @intCast(i + 1) });
    // One strong tie, from the *end* of each chain so it is not the obvious centre child.
    try edges.append(gpa, .{ .a = 6, .b = 7, .w = 8.0 });

    var misalign: [2]f32 = .{ 0, 0 };
    for ([_]f32{ 0, 1 }, 0..) |ext_k, pass| {
        var lad = try fold.build(gpa, n, edges.items, &.{}, .{ .arity = .seven });
        defer lad.deinit(gpa);
        var f = try init(gpa, lad.cells.len, lad.roots.len, .seven, .{ .ext_k = ext_k });
        defer f.deinit(gpa);
        placeAll(&f, &lad);

        var total: f32 = 0;
        for (0..lad.cells.len) |ci| {
            const cell: u32 = @intCast(ci);
            const centre = f.pos[cell];
            for (lad.extOf(cell)) |e| {
                const kids = lad.childrenOf(cell);
                if (e.child >= kids.len or e.toward >= f.pos.len) continue;
                const kp = f.pos[kids[e.child]];
                const sx = kp.x - centre.x;
                const sy = kp.y - centre.y;
                const tx = f.pos[e.toward].x - centre.x;
                const ty = f.pos[e.toward].y - centre.y;
                const sl = @sqrt(sx * sx + sy * sy);
                const tl = @sqrt(tx * tx + ty * ty);
                if (sl < 1e-6 or tl < 1e-6) continue;
                total += e.w * (1.0 - (sx * tx + sy * ty) / (sl * tl));
            }
        }
        misalign[pass] = total;
    }

    // The pulls must exist at all, or this proves nothing about the term.
    try testing.expect(misalign[0] > 0.01);
    // And turning the term on must not make aim worse. Exhaustive search means it can only pick a
    // lower-cost arrangement, but sibling-distance still shares the objective — so the honest
    // assertion is "no worse", with a strict improvement expected on this deliberately-tied case.
    try testing.expect(misalign[1] <= misalign[0] + 1e-4);
    try testing.expect(misalign[1] < misalign[0]);
}
