//! Hand-rolled 2D camera for the graph panel.
//!
//! Deliberately **not** `CanvasWidget`: that widget couples the camera to a ScrollArea's
//! viewport, which fights animated retargets (M3) and a content rect that changes every frame.
//! One `center`/`zoom` pair plus `worldToScreen`/`screenToWorld` is the whole model.
//!
//! M2 draws from `center`/`zoom` directly. M3 adds `center_target`/`zoom_target` and chases;
//! the conversion math here stays unchanged.
const std = @import("std");
const dvui = @import("dvui");

const hex = @import("hex.zig");

const Camera = @This();

/// Default zoom-out stop. Wide enough for an ordinary vault to overview in one view.
pub const min_zoom: f32 = 0.02;
/// Absolute floor, well below anything content could ask for. Only guards against
/// divide-by-zero and float blowups in the world↔screen conversions.
pub const abs_min_zoom: f32 = 1e-5;
/// Clean hex-grid LOD boundary — see `hex.cleanZoom` / `hex.max_zoom_level`. A round number
/// like 12 sat between two levels and left the finer grid half-faded at the stop.
pub const max_zoom: f32 = hex.cleanZoom(hex.max_zoom_level);

/// World-space point under the middle of the viewport.
center: dvui.Point = .{},
/// World units → screen pixels. 1.0 means one world unit is one screen pixel.
zoom: f32 = 1.0,

/// M3 seam: where the camera is heading. M2 keeps these equal to `center`/`zoom`.
center_target: dvui.Point = .{},
zoom_target: f32 = 1.0,
/// Set while the user is dragging/pinching/wheeling; suppresses auto-retarget in M3.
user_driving: bool = false,

/// Viewport rectangle in screen (physical) coordinates — set each frame before converting.
viewport: dvui.Rect.Physical = .{},

/// How far out this particular arrangement may be pulled, set from the world extent each frame.
///
/// A fixed stop cannot serve both a ten-note vault and a hundred-thousand-note one: `min_zoom`
/// is chosen so an ordinary vault does not vanish into a speck, and on a vault large enough to
/// need it, the same number means the reader hits the stop with the graph still overflowing the
/// panel and no way to see the whole thing. Whatever it takes to frame the content, plus room
/// to spare, is the only honest answer — see `setContentExtent`.
zoom_floor: f32 = min_zoom,

pub fn syncTargets(self: *Camera) void {
    self.center_target = self.center;
    self.zoom_target = self.zoom;
}

/// Clamp against the default stop only. Prefer `Camera.clamp`, which also honours the extent
/// of what is actually on screen.
pub fn clampZoom(z: f32) f32 {
    return std.math.clamp(z, min_zoom, max_zoom);
}

pub fn clamp(self: *const Camera, z: f32) f32 {
    return std.math.clamp(z, self.zoom_floor, max_zoom);
}

/// Let the reader pull back far enough to see all of `world_radius`, whatever size it is.
///
/// `slack` is how much emptier than a tight fit the furthest view may be: 2 means the content
/// can be pulled back to half the panel. Never *raises* the stop above `min_zoom` — a small
/// vault keeps the generous default rather than being locked to its own bounding box.
pub fn setContentExtent(self: *Camera, world_radius: f32, slack: f32) void {
    const span = @max(world_radius * 2, 1);
    const avail = @max(@min(self.viewport.w, self.viewport.h), 1);
    const fit = avail / span;
    self.zoom_floor = std.math.clamp(fit / @max(slack, 1), abs_min_zoom, min_zoom);
}

/// Screen-space centre of the viewport.
pub fn screenOrigin(self: *const Camera) dvui.Point.Physical {
    return .{
        .x = self.viewport.x + self.viewport.w * 0.5,
        .y = self.viewport.y + self.viewport.h * 0.5,
    };
}

pub fn worldToScreen(self: *const Camera, world: dvui.Point) dvui.Point.Physical {
    const o = self.screenOrigin();
    return .{
        .x = o.x + (world.x - self.center.x) * self.zoom,
        .y = o.y + (world.y - self.center.y) * self.zoom,
    };
}

pub fn screenToWorld(self: *const Camera, screen: dvui.Point.Physical) dvui.Point {
    const o = self.screenOrigin();
    return .{
        .x = self.center.x + (screen.x - o.x) / self.zoom,
        .y = self.center.y + (screen.y - o.y) / self.zoom,
    };
}

/// Pan by a screen-space delta (dragging right moves the world right under the cursor, so
/// the camera centre moves left — same convention as maps).
pub fn panScreen(self: *Camera, dx: f32, dy: f32) void {
    self.center.x -= dx / self.zoom;
    self.center.y -= dy / self.zoom;
    self.syncTargets();
}

/// Zoom by `factor` (>1 zooms in) around a screen-space focal point, so the world point
/// under the cursor stays put. Copied from CanvasWidget's scale-around-point math.
pub fn zoomAtScreen(self: *Camera, factor: f32, focal: dvui.Point.Physical) void {
    if (!std.math.isFinite(factor) or factor <= 0 or factor == 1.0) return;
    const old = self.zoom;
    const new_z = self.clamp(old * factor);
    // Already on the stop — don't thrash `center` with a no-op scale (felt like a bounce /
    // invert when high-sensitivity wheel events kept firing at min/max zoom).
    if (new_z == old) return;
    const before = self.screenToWorld(focal);
    self.zoom = new_z;
    const after = self.screenToWorld(focal);
    self.center.x += before.x - after.x;
    self.center.y += before.y - after.y;
    self.syncTargets();
}

/// A camera pose — where `fitBounds` would land, without committing to it.
pub const Pose = struct { center: dvui.Point, zoom: f32 };

/// Compute the pose that makes `bounds` (world AABB) fill the viewport with `padding`
/// screen pixels. Pure — callers snap (`fitBounds`) or retarget (`center_target`/`zoom_target`).
pub fn poseForBounds(self: *const Camera, bounds: dvui.Rect, padding: f32) Pose {
    const bw = @max(bounds.w, 1);
    const bh = @max(bounds.h, 1);
    const avail_w = @max(self.viewport.w - padding * 2, 1);
    const avail_h = @max(self.viewport.h - padding * 2, 1);
    const zx = avail_w / bw;
    const zy = avail_h / bh;
    return .{
        .zoom = self.clamp(@min(zx, zy)),
        .center = .{
            .x = bounds.x + bounds.w * 0.5,
            .y = bounds.y + bounds.h * 0.5,
        },
    };
}

/// Snap `center`/`zoom` so `bounds` (world AABB) fills the viewport with `padding` screen pixels.
pub fn fitBounds(self: *Camera, bounds: dvui.Rect, padding: f32) void {
    const pose = self.poseForBounds(bounds, padding);
    self.zoom = pose.zoom;
    self.center = pose.center;
    self.syncTargets();
}

/// True while `center`/`zoom` have not caught up to their targets.
pub fn chasing(self: *const Camera) bool {
    return self.center.x != self.center_target.x or
        self.center.y != self.center_target.y or
        self.zoom != self.zoom_target;
}

/// Ease `center`/`zoom` toward their targets. `k` is the chase rate (1/s); higher is snappier.
/// Returns true if anything moved. Snaps the last sliver so `chasing()` can actually go false.
///
/// Zoom eases **multiplicatively** — the step is a constant *ratio* per unit time, not a
/// constant difference. Zoom is perceived in octaves: a linear chase from 0.3 to 2.5 covers
/// half the octaves in the first few frames and then crawls through the last few percent, so a
/// flight from overview onto one note lurched and then dawdled. Geometric easing spends equal
/// time per doubling and reads as one continuous move. Neither form overshoots — both approach
/// their target from one side only.
pub fn chase(self: *Camera, dt: f32, k: f32) bool {
    if (!self.chasing()) return false;
    const t = 1.0 - @exp(-k * dt);

    const dx = self.center_target.x - self.center.x;
    const dy = self.center_target.y - self.center.y;
    const dz = self.zoom_target - self.zoom;

    // Zoom tolerance scales with zoom: at 0.02 an absolute 1e-3 epsilon would be 5% of the value.
    const done_pos = @abs(dx) < 0.01 and @abs(dy) < 0.01;
    const done_zoom = @abs(dz) < @max(self.zoom_target, 0.01) * 1e-3;
    if (done_pos and done_zoom) {
        self.center = self.center_target;
        self.zoom = self.zoom_target;
        return true;
    }

    self.center.x += dx * t;
    self.center.y += dy * t;
    if (self.zoom > 0 and self.zoom_target > 0) {
        self.zoom *= @exp(@log(self.zoom_target / self.zoom) * t);
    } else {
        self.zoom += dz * t;
    }
    return true;
}

// -- tests ------------------------------------------------------------------------

const testing = std.testing;

fn camAt(center: dvui.Point, zoom: f32, vp: dvui.Rect.Physical) Camera {
    var c: Camera = .{ .center = center, .zoom = zoom, .viewport = vp };
    c.syncTargets();
    return c;
}

test "worldToScreen round-trips through screenToWorld" {
    const vp: dvui.Rect.Physical = .{ .x = 100, .y = 50, .w = 800, .h = 600 };
    var c = camAt(.{ .x = 10, .y = -20 }, 1.5, vp);
    const samples = [_]dvui.Point{
        .{},
        .{ .x = 40, .y = 0 },
        .{ .x = -100, .y = 80 },
        .{ .x = 3.5, .y = -7.25 },
    };
    for (samples) |w| {
        const s = c.worldToScreen(w);
        const back = c.screenToWorld(s);
        try testing.expectApproxEqAbs(w.x, back.x, 1e-4);
        try testing.expectApproxEqAbs(w.y, back.y, 1e-4);
    }
}

test "round-trip holds across zooms" {
    const vp: dvui.Rect.Physical = .{ .x = 0, .y = 0, .w = 400, .h = 300 };
    const world: dvui.Point = .{ .x = 12, .y = -8 };
    for ([_]f32{ 0.2, 0.5, 1.0, 2.0, 5.0 }) |z| {
        var c = camAt(.{ .x = 1, .y = 2 }, z, vp);
        const back = c.screenToWorld(c.worldToScreen(world));
        try testing.expectApproxEqAbs(world.x, back.x, 1e-4);
        try testing.expectApproxEqAbs(world.y, back.y, 1e-4);
    }
}

test "zoomAtScreen keeps the focal world point fixed" {
    const vp: dvui.Rect.Physical = .{ .x = 0, .y = 0, .w = 800, .h = 600 };
    var c = camAt(.{ .x = 0, .y = 0 }, 1.0, vp);
    const focal: dvui.Point.Physical = .{ .x = 600, .y = 200 }; // not the centre
    const world_before = c.screenToWorld(focal);
    c.zoomAtScreen(2.0, focal);
    const world_after = c.screenToWorld(focal);
    try testing.expectApproxEqAbs(world_before.x, world_after.x, 1e-3);
    try testing.expectApproxEqAbs(world_before.y, world_after.y, 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 2.0), c.zoom, 1e-5);
}

test "panScreen moves the camera opposite the drag" {
    const vp: dvui.Rect.Physical = .{ .x = 0, .y = 0, .w = 100, .h = 100 };
    var c = camAt(.{ .x = 0, .y = 0 }, 2.0, vp);
    c.panScreen(20, 0); // drag 20 screen px right → centre moves left by 10 world
    try testing.expectApproxEqAbs(@as(f32, -10), c.center.x, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 0), c.center.y, 1e-4);
}

test "fitBounds centres and scales to fit" {
    const vp: dvui.Rect.Physical = .{ .x = 0, .y = 0, .w = 400, .h = 200 };
    var c = camAt(.{ .x = 0, .y = 0 }, 1.0, vp);
    c.fitBounds(.{ .x = -50, .y = -25, .w = 100, .h = 50 }, 0);
    try testing.expectApproxEqAbs(@as(f32, 0), c.center.x, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 0), c.center.y, 1e-4);
    // Height is the tighter axis: 200/50 = 4
    try testing.expectApproxEqAbs(@as(f32, 4), c.zoom, 1e-4);
}

test "clampZoom respects bounds" {
    try testing.expectEqual(min_zoom, clampZoom(0.001));
    // Relative to the bounds, not a literal: the ceiling is deep enough for the nested interior
    // level now, and a hardcoded "surely above max" stops being above it.
    try testing.expectEqual(max_zoom, clampZoom(max_zoom * 10));
    try testing.expectEqual(@as(f32, 1.5), clampZoom(1.5));
    try testing.expect(min_zoom < 1.5 and 1.5 < max_zoom);
}

test "the zoom-out stop opens up for a vault too big to fit at the default one" {
    const vp: dvui.Rect.Physical = .{ .x = 0, .y = 0, .w = 800, .h = 600 };
    var c = camAt(.{}, 1.0, vp);

    // A vault spanning 200k world units cannot be seen at `min_zoom`: 600px / 200000 is 0.003.
    c.setContentExtent(100_000, 2);
    try testing.expect(c.zoom_floor < min_zoom);
    // The whole thing fits, with the slack asked for.
    try testing.expect(200_000 * c.zoom_floor <= 600);
    const fit = c.poseForBounds(.{ .x = -100_000, .y = -100_000, .w = 200_000, .h = 200_000 }, 0);
    try testing.expect(fit.zoom > c.zoom_floor);

    // A small vault keeps the generous default rather than being locked to its own bounds.
    c.setContentExtent(50, 2);
    try testing.expectEqual(min_zoom, c.zoom_floor);
}

test "chase converges and then reports settled" {
    var c = camAt(.{ .x = 0, .y = 0 }, 1.0, .{ .x = 0, .y = 0, .w = 400, .h = 300 });
    c.center_target = .{ .x = 120, .y = -80 };
    c.zoom_target = 3.0;
    try testing.expect(c.chasing());

    // `wantsRepaint` is driven by `chasing()`, so this must reach exactly false — a chase
    // that only ever approaches its target would repaint the panel forever.
    var frames: usize = 0;
    while (c.chasing() and frames < 600) : (frames += 1) {
        _ = c.chase(1.0 / 60.0, 7);
    }
    try testing.expect(!c.chasing());
    try testing.expectEqual(@as(f32, 120), c.center.x);
    try testing.expectEqual(@as(f32, -80), c.center.y);
    try testing.expectEqual(@as(f32, 3.0), c.zoom);
}

test "chase settles at min_zoom without stalling on the epsilon" {
    // Zoom tolerance is relative: an absolute epsilon would be a large fraction of 0.02.
    var c = camAt(.{}, 1.0, .{ .x = 0, .y = 0, .w = 400, .h = 300 });
    c.center_target = .{};
    c.zoom_target = min_zoom;
    var frames: usize = 0;
    while (c.chasing() and frames < 600) : (frames += 1) {
        _ = c.chase(1.0 / 60.0, 7);
    }
    try testing.expect(!c.chasing());
    try testing.expectEqual(min_zoom, c.zoom);
}

test "zoom chase is geometric and never overshoots" {
    // A flight from overview onto one note is several octaves. Linear easing burns most of
    // them in the first frames; geometric easing spends equal time per doubling.
    var c = camAt(.{}, 0.25, .{ .x = 0, .y = 0, .w = 800, .h = 300 });
    c.zoom_target = 4.0; // exactly 4 octaves up
    var frames: usize = 0;
    var prev: f32 = c.zoom;
    while (c.chasing() and frames < 600) : (frames += 1) {
        _ = c.chase(1.0 / 60.0, 7);
        try testing.expect(c.zoom >= prev); // monotone: no overshoot, no ringing
        try testing.expect(c.zoom <= 4.0 + 1e-4);
        prev = c.zoom;
    }
    try testing.expect(!c.chasing());
    try testing.expectEqual(@as(f32, 4.0), c.zoom);

    // Mid-flight, progress through the octaves must match progress across the pan exactly —
    // that is what makes zoom and pan read as one move. A linear zoom chase would be well
    // ahead of the pan by this point.
    var d = camAt(.{}, 0.25, .{ .x = 0, .y = 0, .w = 800, .h = 300 });
    d.zoom_target = 4.0;
    d.center_target = .{ .x = 1000, .y = 0 };
    for (0..8) |_| _ = d.chase(1.0 / 60.0, 7);

    const zoom_progress = @log2(d.zoom / 0.25) / @log2(4.0 / 0.25);
    const pan_progress = d.center.x / 1000.0;
    try testing.expectApproxEqAbs(pan_progress, zoom_progress, 1e-3);
    try testing.expect(zoom_progress < 0.75); // still mid-flight, so the check means something
}

test "chase is a no-op once targets are met" {
    var c = camAt(.{ .x = 5, .y = 5 }, 2.0, .{ .x = 0, .y = 0, .w = 400, .h = 300 });
    try testing.expect(!c.chasing());
    try testing.expect(!c.chase(1.0 / 60.0, 7));
}

test "poseForBounds matches what fitBounds commits" {
    var c = camAt(.{ .x = 9, .y = 9 }, 1.0, .{ .x = 0, .y = 0, .w = 400, .h = 200 });
    const bounds: dvui.Rect = .{ .x = -50, .y = -25, .w = 100, .h = 50 };
    const pose = c.poseForBounds(bounds, 0);
    c.fitBounds(bounds, 0);
    try testing.expectEqual(pose.zoom, c.zoom);
    try testing.expectEqual(pose.center.x, c.center.x);
    try testing.expectEqual(pose.center.y, c.center.y);
}

test "zoomAtScreen is a no-op when already at the clamp" {
    var c = camAt(.{}, min_zoom, .{ .x = 0, .y = 0, .w = 200, .h = 100 });
    const center_before = c.center;
    c.zoomAtScreen(0.5, .{ .x = 150, .y = 80 });
    try testing.expectEqual(min_zoom, c.zoom);
    try testing.expectEqual(center_before.x, c.center.x);
    try testing.expectEqual(center_before.y, c.center.y);
}
