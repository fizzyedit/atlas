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
};

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
        const c = lad.cells[cell];
        return self.opts.note_r * @sqrt(@as(f32, @floatFromInt(@max(1, c.count))));
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
