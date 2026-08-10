//! How much of the web to frame when a note is focused.
//!
//! Focusing should read as *flying to the selection*, not teleporting to a single dot. The
//! camera frames a region centred on the open notes and sized from those notes alone — fewer
//! open means a tighter frame; unselected neighbours are free to fall off the edges.
//!
//! Two inputs, and the distinction between them is the whole design:
//!
//! * `must` — the selection: the open documents. Preferred inside the frame — cropping an open
//!   tab is usually wrong — so `must` is applied after the soft clamps, not before. The
//!   *caller* may still floor the resulting zoom at the vault extents pose: spanning the whole
//!   web is never worth pulling further out than the center/maximize button.
//! * `context` — optional soft neighbours (the graph sends 1-hop links of the open set so a
//!   click frames a readable star, not a lone note). Percentile coverage lets remote spokes
//!   fall off rather than yanking the camera to overview.
//!
//! The size is a **percentile** of the context distances, not their maximum. A note with nine
//! neighbours in one cluster and one across the vault should frame the cluster; taking the max
//! would pull the camera all the way back to overview and defeat the whole point. `coverage` is
//! how much of the context has to fit — the rest is allowed to fall off the edges.
//!
//! Distances are Chebyshev (`max(|dx|, |dy|)`), so the framed region is a square and a node
//! sitting diagonally counts the same as one straight out to the side.
//!
//! Pure math over points — no dvui window, no camera. The caller turns the returned world
//! rect into a pose (`Camera.poseForBounds`) and applies its own zoom limits.
const std = @import("std");
const dvui = @import("dvui");

pub const Params = struct {
    /// Fraction of the context that must fit inside the frame. Below 1 on purpose — see above.
    coverage: f32 = 0.7,
    /// Floor on the framed half-extent, in layout slots. A note whose neighbours are all one
    /// cell away must still frame more than those neighbours' own bubbles.
    min_radius_slots: f32 = 1.6,
    /// Ceiling, in layout slots. Backstop for a hub whose links are scattered everywhere; the
    /// caller's zoom clamp is what actually decides readability.
    max_radius_slots: f32 = 5.0,
    /// Breathing room, in layout slots, kept outside the outermost `must` point — a linked
    /// neighbour flush against the edge of the panel has nowhere to put its label.
    must_margin_slots: f32 = 0.6,
};

pub const Frame = struct { center: dvui.Point, radius: f32 };

/// Where to point the camera and how much to take in. `scratch` holds one f32 per context
/// point (shorter is allowed — the extra points are simply ignored).
pub fn frame(
    anchor: dvui.Point,
    must: []const dvui.Point,
    context: []const dvui.Point,
    slot: f32,
    p: Params,
    scratch: []f32,
) Frame {
    const s = @max(slot, 1);

    // Centre on the AABB of everything that has to be visible, `anchor` included. Centring on
    // the anchor alone would leave a second open note lopsidedly out to one side and force
    // twice the radius to reach it.
    var min_x = anchor.x;
    var max_x = anchor.x;
    var min_y = anchor.y;
    var max_y = anchor.y;
    for (must) |m| {
        min_x = @min(min_x, m.x);
        max_x = @max(max_x, m.x);
        min_y = @min(min_y, m.y);
        max_y = @max(max_y, m.y);
    }
    const center: dvui.Point = .{ .x = (min_x + max_x) * 0.5, .y = (min_y + max_y) * 0.5 };
    const r_must = @max((max_x - min_x) * 0.5, (max_y - min_y) * 0.5);

    // Context distances from the same centre, so both radii are directly comparable.
    var n: usize = 0;
    for (context) |c| {
        if (n >= scratch.len) break;
        scratch[n] = @max(@abs(c.x - center.x), @abs(c.y - center.y));
        n += 1;
    }

    var r = s * p.min_radius_slots;
    if (n > 0) {
        std.mem.sort(f32, scratch[0..n], {}, std.sort.asc(f32));
        // Round up, so `coverage` is a floor on how many context nodes are inside the frame
        // rather than something that quietly drops the last one.
        const want = @ceil(std.math.clamp(p.coverage, 0, 1) * @as(f32, @floatFromInt(n - 1)));
        const idx: usize = @min(@as(usize, @intFromFloat(want)), n - 1);
        r = @max(r, scratch[idx]);
    }
    r = @min(r, s * p.max_radius_slots);

    // Last, and deliberately after the ceiling: the clamps are a preference about what reads
    // well, but cropping a note in the selection is not a matter of taste.
    return .{ .center = center, .radius = @max(r, r_must + s * p.must_margin_slots) };
}

/// World AABB to hand to `Camera.poseForBounds`. Square, so a node sitting diagonally is
/// framed like one straight out to the side.
pub fn bounds(
    anchor: dvui.Point,
    must: []const dvui.Point,
    context: []const dvui.Point,
    slot: f32,
    p: Params,
    scratch: []f32,
) dvui.Rect {
    const f = frame(anchor, must, context, slot, p, scratch);
    return .{ .x = f.center.x - f.radius, .y = f.center.y - f.radius, .w = f.radius * 2, .h = f.radius * 2 };
}


// -- tests ------------------------------------------------------------------------

const testing = std.testing;

const test_slot: f32 = 100;

fn radiusOf(
    anchor: dvui.Point,
    must: []const dvui.Point,
    context: []const dvui.Point,
    p: Params,
    scratch: []f32,
) f32 {
    return frame(anchor, must, context, test_slot, p, scratch).radius;
}

test "a note with no context still frames its own neighbourhood" {
    var scratch: [8]f32 = undefined;
    const r = radiusOf(.{ .x = 5, .y = -5 }, &.{}, &.{}, .{}, &scratch);
    try testing.expectApproxEqAbs(test_slot * 1.6, r, 1e-4);
}

test "a tight cluster is framed by its own spread, not the floor" {
    var scratch: [8]f32 = undefined;
    const ctx = [_]dvui.Point{
        .{ .x = 300, .y = 0 },
        .{ .x = -300, .y = 0 },
        .{ .x = 0, .y = 280 },
        .{ .x = 150, .y = 150 },
    };
    const r = radiusOf(.{}, &.{}, &ctx, .{}, &scratch);
    try testing.expect(r > test_slot * 1.6);
    try testing.expect(r <= 300);
}

test "one far-flung link does not drag the camera back to overview" {
    // The case the percentile exists for: nine neighbours in a cluster, one across the vault.
    var scratch: [16]f32 = undefined;
    var ctx: [10]dvui.Point = undefined;
    for (ctx[0..9], 0..) |*c, i| c.* = .{ .x = @floatFromInt(i * 20), .y = 0 };
    ctx[9] = .{ .x = 40_000, .y = 0 };

    const r = radiusOf(.{}, &.{}, &ctx, .{}, &scratch);
    // Framed on the cluster, which the floor covers — nowhere near the outlier.
    try testing.expectApproxEqAbs(test_slot * 1.6, r, 1e-4);
}

test "coverage of 1 does include the outlier" {
    // Guards that the exclusion above comes from `coverage`, not from the clamps.
    var scratch: [16]f32 = undefined;
    const ctx = [_]dvui.Point{ .{ .x = 10, .y = 0 }, .{ .x = 20, .y = 0 }, .{ .x = 400, .y = 0 } };
    const r = radiusOf(.{}, &.{}, &ctx, .{ .coverage = 1, .max_radius_slots = 100 }, &scratch);
    try testing.expectApproxEqAbs(@as(f32, 400), r, 1e-4);
}

test "context radius is clamped both ways" {
    var scratch: [8]f32 = undefined;
    const far = [_]dvui.Point{.{ .x = 100_000, .y = 0 }};
    try testing.expectApproxEqAbs(
        test_slot * 5.0,
        radiusOf(.{}, &.{}, &far, .{ .coverage = 1 }, &scratch),
        1e-4,
    );

    const near = [_]dvui.Point{.{ .x = 1, .y = 1 }};
    try testing.expectApproxEqAbs(
        test_slot * 1.6,
        radiusOf(.{}, &.{}, &near, .{ .coverage = 1 }, &scratch),
        1e-4,
    );
}

test "distance is Chebyshev, so a diagonal neighbour counts like a lateral one" {
    var scratch: [8]f32 = undefined;
    const lateral = [_]dvui.Point{.{ .x = 400, .y = 0 }};
    const diagonal = [_]dvui.Point{.{ .x = 400, .y = 400 }};
    const a = radiusOf(.{}, &.{}, &lateral, .{ .coverage = 1 }, &scratch);
    const b = radiusOf(.{}, &.{}, &diagonal, .{ .coverage = 1 }, &scratch);
    try testing.expectApproxEqAbs(a, b, 1e-4);
}

test "bounds is a square centred on the frame" {
    var scratch: [8]f32 = undefined;
    const ctx = [_]dvui.Point{.{ .x = 700, .y = 200 }};
    const a: dvui.Point = .{ .x = 250, .y = -60 };
    const b = bounds(a, &.{}, &ctx, test_slot, .{ .coverage = 1 }, &scratch);
    try testing.expectApproxEqAbs(b.w, b.h, 1e-4);
    // No `must` beyond the anchor, so the frame stays centred on the note you opened.
    try testing.expectApproxEqAbs(a.x, b.x + b.w * 0.5, 1e-4);
    try testing.expectApproxEqAbs(a.y, b.y + b.h * 0.5, 1e-4);
}

test "scratch shorter than the context is not a crash" {
    var scratch: [2]f32 = undefined;
    const ctx = [_]dvui.Point{
        .{ .x = 100, .y = 0 },
        .{ .x = 200, .y = 0 },
        .{ .x = 300, .y = 0 },
        .{ .x = 400, .y = 0 },
    };
    const r = radiusOf(.{}, &.{}, &ctx, .{ .coverage = 1 }, &scratch);
    try testing.expect(r >= test_slot * 1.6);
}

// -- `must`: the selection's link targets are never cropped -------------------------

test "a link target across the vault is always framed" {
    // The clamps would happily crop it — `must` is applied afterwards precisely so they can't.
    var scratch: [8]f32 = undefined;
    const far: dvui.Point = .{ .x = 9000, .y = 0 };
    const b = bounds(.{}, &.{far}, &.{}, test_slot, .{}, &scratch);
    try testing.expect(b.contains(far));
    try testing.expect(b.contains(.{ .x = 0, .y = 0 }));
    // Way past `max_radius_slots`, which only ever bounded the *context*.
    try testing.expect(b.w * 0.5 > test_slot * 5.0);
}

test "the frame centres between the selection and its link targets, not on the anchor" {
    var scratch: [8]f32 = undefined;
    const other: dvui.Point = .{ .x = 800, .y = 0 };
    const f = frame(.{}, &.{other}, &.{}, test_slot, .{}, &scratch);
    try testing.expectApproxEqAbs(@as(f32, 400), f.center.x, 1e-4);
    // Half the span plus the margin — not the full span it would need if centred on 0.
    try testing.expectApproxEqAbs(400 + test_slot * 0.6, f.radius, 1e-4);
}

test "must notes keep a margin off the edge of the frame" {
    var scratch: [8]f32 = undefined;
    const other: dvui.Point = .{ .x = 0, .y = 600 };
    const f = frame(.{}, &.{other}, &.{}, test_slot, .{ .must_margin_slots = 1.0 }, &scratch);
    try testing.expectApproxEqAbs(@as(f32, 300 + test_slot), f.radius, 1e-4);
}

test "the anchor alone in must does not widen the frame at all" {
    // Callers sometimes include the focused note itself in `must`. That must be a no-op.
    var scratch: [8]f32 = undefined;
    const a: dvui.Point = .{ .x = -30, .y = 12 };
    const with = frame(a, &.{a}, &.{}, test_slot, .{}, &scratch);
    const without = frame(a, &.{}, &.{}, test_slot, .{}, &scratch);
    try testing.expectApproxEqAbs(without.radius, with.radius, 1e-4);
    try testing.expectApproxEqAbs(a.x, with.center.x, 1e-4);
}

test "context still tightens the frame when the must notes are close together" {
    var scratch: [8]f32 = undefined;
    const near_link: dvui.Point = .{ .x = 20, .y = 0 };
    const ctx = [_]dvui.Point{ .{ .x = 250, .y = 0 }, .{ .x = 0, .y = 240 } };
    const f = frame(.{}, &.{near_link}, &ctx, test_slot, .{ .coverage = 1 }, &scratch);
    // Sized by the context, not by the trivially-small `must` span.
    try testing.expect(f.radius > test_slot * 1.6);
    try testing.expect(f.radius < 300);
}
