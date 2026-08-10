//! Shared hexagonal lattice — the one coordinate system the graph background grid *and* the
//! node layout agree on, so every node lands exactly on a grid dot.
//!
//! Points are the vertices of a pointy-top triangular (a.k.a. hex) lattice:
//!
//!     P(q, r) = q·a + r·b,   a = (s, 0),   b = (s/2, s·√3/2)
//!
//! Two properties the rest of the graph leans on:
//!
//! 1. **Powers of two nest.** Scaling the basis by 2 yields a *sublattice*: `P(q,r)` at
//!    spacing `2s` is exactly `P(2q,2r)` at spacing `s`. That is what lets the background
//!    fade a finer level in on zoom without any dot ever moving — a level-`L` dot is still
//!    a dot at level `L-1`, just with more neighbours between it and the next one.
//! 2. **Nodes sit on a power-of-two level.** `layoutLevelFor(n)` picks how coarse, so a
//!    tiny vault stays intimate and a large one opens up — and every node still coincides
//!    with a background dot of every finer level.
const std = @import("std");
const dvui = @import("dvui");

/// World-space nearest-neighbour distance of the finest "level 0" lattice.
/// Levels are `spacing * 2^L`; `L` may go negative when zoomed far in.
pub const spacing: f32 = 28;

/// Layout lattice level clamps. Level 1 = 56wu, level 3 = 224wu. Kept modest on purpose:
/// fit-to-extents zooms to the world AABB, so an oversized slot just shrinks the camera and
/// makes bubbles/labels tiny — clustering, not slot size, is what separates groups.
pub const layout_level_min: i32 = 1;
pub const layout_level_max: i32 = 3;

/// Pick the hex level nodes should snap to for a vault of `n` notes.
///
/// Biased toward tighter lattices so the extents camera lands at a zoom where a layout
/// step is a comfortable multiple of the on-screen bubble (and labels can show). Result is
/// always an integer level, so spacing is an exact power-of-two multiple of `spacing`.
pub fn layoutLevelFor(n: usize) i32 {
    // Step functions read clearer than a float curve here: each band is "still feels
    // intimate at fit-zoom on a typical panel".
    if (n <= 16) return 1; // 56wu
    if (n <= 80) return 2; // 112wu
    return 3; // 224wu
}

/// World spacing of the layout lattice for a vault of `n` notes.
pub fn layoutSpacingFor(n: usize) f32 {
    return levelSpacing(layoutLevelFor(n));
}

/// On-screen spacing (natural pixels) the background LOD aims for. Must stay in lockstep
/// with `dotgrid.zig` — that file reads this rather than owning its own copy.
pub const target_screen_spacing: f32 = 30;

/// Finest lattice level the camera is allowed to reach. Chosen so `Camera.max_zoom`
/// (`cleanZoom(max_zoom_level)`) lands on a fade=0 LOD boundary rather than between levels.
///
/// Deep, because the graph nests: a note's sections live several levels below the vault's own
/// lattice (see `ui/interior.zig`), and a ceiling set for the overview alone leaves the *inner*
/// level with almost nowhere to zoom — you arrive inside a note and immediately hit the stop.
/// The interior needs roughly the room to move around that the overview has, and since it starts
/// four or five levels down, the ceiling has to be that much further down again.
///
/// Nothing else has to change to go deeper: `dotgrid` derives its level from zoom directly and
/// just keeps subdividing. The practical bound is f32 — world coordinates are multiplied by zoom
/// for the screen, and at 2^-9 the worst case is comfortably inside f32's usable digits.
pub const max_zoom_level: i32 = -9;

/// Row pitch as a fraction of the horizontal spacing (√3/2).
pub const row_ratio: f32 = 0.8660254037844386;

/// World-space distance between neighbouring points at `level`.
pub fn levelSpacing(level: i32) f32 {
    return spacing * @exp2(@as(f32, @floatFromInt(level)));
}

/// Camera zoom at which lattice `level` sits at exactly `target_screen_spacing` natural
/// pixels (natural_scale = 1). That is a clean LOD boundary (`fade = 0`). At power-of-two
/// DPI the same zoom is still clean — just for a shifted level index — because doubling
/// the scale is exactly one level step.
pub fn cleanZoom(level: i32) f32 {
    return target_screen_spacing / levelSpacing(level);
}

/// Lattice point `(q, r)` at a given nearest-neighbour spacing.
pub fn toWorld(q: i32, r: i32, s: f32) dvui.Point {
    const qf: f32 = @floatFromInt(q);
    const rf: f32 = @floatFromInt(r);
    return .{ .x = s * (qf + rf * 0.5), .y = s * rf * row_ratio };
}

/// Nearest axial cell to a world point at spacing `s`. Cube-coordinate rounding so ties
/// don't produce a non-lattice result.
pub fn fromWorld(p: dvui.Point, s: f32) [2]i32 {
    const rf = p.y / (s * row_ratio);
    const qf = p.x / s - rf * 0.5;
    return axialRound(qf, rf);
}

fn axialRound(qf: f32, rf: f32) [2]i32 {
    // Axial (q, r) ↔ cube (x, y, z) with x=q, z=r, y=-x-z.
    const xf = qf;
    const zf = rf;
    const yf = -xf - zf;
    var rx: f32 = @round(xf);
    var ry: f32 = @round(yf);
    var rz: f32 = @round(zf);
    const xd = @abs(rx - xf);
    const yd = @abs(ry - yf);
    const zd = @abs(rz - zf);
    if (xd > yd and xd > zd) {
        rx = -ry - rz;
    } else if (yd > zd) {
        ry = -rx - rz;
    } else {
        rz = -rx - ry;
    }
    return .{ @intFromFloat(rx), @intFromFloat(rz) };
}

/// Hex distance between two axial cells (number of steps on the lattice).
pub fn axialDistance(a: [2]i32, b: [2]i32) i32 {
    const dq = a[0] - b[0];
    const dr = a[1] - b[1];
    // `@abs` on a signed int yields unsigned in this Zig; cast back for the sum.
    const adq: i32 = @intCast(@abs(dq));
    const adr: i32 = @intCast(@abs(dr));
    const adqdr: i32 = @intCast(@abs(dq + dr));
    return @divTrunc(adq + adqdr + adr, 2);
}

/// Axial neighbour directions, counter-clockwise from +q.
pub const dirs = [6][2]i32{
    .{ 1, 0 },
    .{ 1, -1 },
    .{ 0, -1 },
    .{ -1, 0 },
    .{ -1, 1 },
    .{ 0, 1 },
};

/// Axial coordinate of the `i`-th cell of the outward hex spiral (0 = centre).
///
/// Closed form rather than the usual accumulate-as-you-walk loop: the layout needs
/// `spiral(i)` for arbitrary `i` and walking from 0 each time would be O(n²) per rebuild.
pub fn spiral(i: usize) [2]i32 {
    if (i == 0) return .{ 0, 0 };

    // Ring `k` ends at cumulative index 3k(k+1); solve for the smallest k containing `i`.
    const fi: f64 = @floatFromInt(i);
    var k: i64 = @intFromFloat(@ceil((@sqrt(12.0 * fi + 9.0) - 3.0) / 6.0));
    if (k < 1) k = 1;
    // Guard the float solve against landing one ring off at exact boundaries.
    while (3 * k * (k + 1) < @as(i64, @intCast(i))) k += 1;
    while (k > 1 and 3 * (k - 1) * k >= @as(i64, @intCast(i))) k -= 1;

    const ring_start: usize = @intCast(1 + 3 * (k - 1) * k);
    const m = i - ring_start; // 0 .. 6k-1
    const kk: usize = @intCast(k);
    const side = m / kk;
    const step = m % kk;

    // Walk starts at `dirs[4] * k` (the standard hex-ring origin) and runs `k` cells along
    // each direction in turn; sides already completed contribute a full `k` each.
    var q: i32 = dirs[4][0] * @as(i32, @intCast(k));
    var r: i32 = dirs[4][1] * @as(i32, @intCast(k));
    for (0..side) |u| {
        q += dirs[u][0] * @as(i32, @intCast(k));
        r += dirs[u][1] * @as(i32, @intCast(k));
    }
    q += dirs[side][0] * @as(i32, @intCast(step));
    r += dirs[side][1] * @as(i32, @intCast(step));
    return .{ q, r };
}

// -- tests ------------------------------------------------------------------------

const testing = std.testing;

test "spiral is a bijection onto the lattice" {
    var seen = std.AutoHashMap([2]i32, usize).init(testing.allocator);
    defer seen.deinit();
    for (0..200) |i| {
        const c = spiral(i);
        try testing.expect(seen.get(c) == null);
        try seen.put(c, i);
    }
    try testing.expectEqual(@as([2]i32, .{ 0, 0 }), spiral(0));
}

test "spiral matches an incremental walk" {
    // The closed form must agree with the textbook accumulate-as-you-go traversal.
    var q: i32 = 0;
    var r: i32 = 0;
    var i: usize = 0;
    try testing.expectEqual(@as([2]i32, .{ q, r }), spiral(i));
    i += 1;
    var k: i32 = 1;
    while (k <= 6) : (k += 1) {
        q = dirs[4][0] * k;
        r = dirs[4][1] * k;
        for (0..6) |side| {
            for (0..@intCast(k)) |_| {
                try testing.expectEqual(@as([2]i32, .{ q, r }), spiral(i));
                i += 1;
                q += dirs[side][0];
                r += dirs[side][1];
            }
        }
    }
}

test "rings grow monotonically in radius" {
    var prev_r: f32 = -1;
    for (0..60) |i| {
        const c = spiral(i);
        const p = toWorld(c[0], c[1], spacing);
        const rad = @sqrt(p.x * p.x + p.y * p.y);
        // Within a ring radius wobbles (corners vs edge midpoints), so only assert the
        // first cell of each ring grows.
        if (i == 0 or i == 1 or i == 7 or i == 19 or i == 37) {
            try testing.expect(rad > prev_r);
            prev_r = rad;
        }
    }
}

test "fromWorld round-trips through toWorld" {
    const s = spacing;
    for ([_][2]i32{ .{ 0, 0 }, .{ 3, -2 }, .{ -4, 5 }, .{ 7, 7 } }) |c| {
        const p = toWorld(c[0], c[1], s);
        const back = fromWorld(p, s);
        try testing.expectEqual(c[0], back[0]);
        try testing.expectEqual(c[1], back[1]);
    }
}

test "fromWorld rounds off-lattice points to a neighbour" {
    const s = spacing;
    const origin = toWorld(0, 0, s);
    // A point slightly toward +q should still round to the origin or +q, never a far cell.
    const p: dvui.Point = .{ .x = origin.x + s * 0.2, .y = origin.y };
    const c = fromWorld(p, s);
    try testing.expect(axialDistance(c, .{ 0, 0 }) <= 1);
}

test "layoutLevelFor steps up with vault size" {
    try testing.expectEqual(@as(i32, 1), layoutLevelFor(1));
    try testing.expectEqual(@as(i32, 1), layoutLevelFor(16));
    try testing.expectEqual(@as(i32, 2), layoutLevelFor(17));
    try testing.expectEqual(@as(i32, 2), layoutLevelFor(80));
    try testing.expectEqual(@as(i32, 3), layoutLevelFor(81));
    try testing.expectEqual(layout_level_max, layoutLevelFor(5000));
    // Monotonic: more notes never pick a finer lattice.
    var prev = layoutLevelFor(1);
    var n: usize = 2;
    while (n <= 2000) : (n *= 2) {
        const cur = layoutLevelFor(n);
        try testing.expect(cur >= prev);
        prev = cur;
    }
}

test "layoutSpacingFor is always a power-of-two multiple of spacing" {
    for ([_]usize{ 1, 5, 20, 80, 400 }) |n| {
        const s = layoutSpacingFor(n);
        const ratio = s / spacing;
        // ratio must be 2^k for integer k.
        const k = std.math.log2(ratio);
        try testing.expectApproxEqAbs(@round(k), k, 1e-4);
        try testing.expect(s >= levelSpacing(layout_level_min) - 1e-3);
        try testing.expect(s <= levelSpacing(layout_level_max) + 1e-3);
    }
}

test "cleanZoom lands on an exact power-of-two spacing" {
    // At cleanZoom(L), level-L neighbours are exactly `target_screen_spacing` apart on screen
    // (natural_scale = 1) — the LOD's fade=0 condition.
    for ([_]i32{ 2, 0, -3, -4 }) |level| {
        const z = cleanZoom(level);
        const screen = levelSpacing(level) * z;
        try testing.expectApproxEqAbs(target_screen_spacing, screen, 1e-4);
    }
}

test "doubling the spacing yields a sublattice" {
    // A level-(L+1) point must coincide with the level-L point at doubled indices.
    for ([_][2]i32{ .{ 0, 0 }, .{ 3, -2 }, .{ -4, 5 } }) |c| {
        const coarse = toWorld(c[0], c[1], levelSpacing(1));
        const fine = toWorld(c[0] * 2, c[1] * 2, levelSpacing(0));
        try testing.expectApproxEqAbs(coarse.x, fine.x, 1e-3);
        try testing.expectApproxEqAbs(coarse.y, fine.y, 1e-3);
    }
}
