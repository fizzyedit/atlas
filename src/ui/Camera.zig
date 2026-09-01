//! Hand-rolled 2D camera for the graph panel.
//!
//! Deliberately **not** `CanvasWidget`: that widget couples the camera to a ScrollArea's
//! viewport, which fights animated retargets and a content rect that changes every frame.
//! One `center`/`zoom` pair plus `worldToScreen`/`screenToWorld` is the whole model.
//!
//! Drawing reads `center`/`zoom`; `center_target`/`zoom_target` are where the camera is heading
//! and `chase` eases toward them. The conversion math is the same either way.
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

/// Where the camera is heading. Equal to `center`/`zoom` unless something retargeted.
center_target: dvui.Point = .{},
zoom_target: f32 = 1.0,
/// Set while the user is dragging/pinching/wheeling; suppresses the automatic chase.
user_driving: bool = false,

/// The flight `chase` is currently flying, and how far along it is. See `chase`.
fly_from: dvui.Point = .{},
fly_from_zoom: f32 = 0,
fly_to: dvui.Point = .{},
fly_to_zoom: f32 = 0,
/// Path length in perceptually-uniform units. Zero means no flight is planned.
fly_len: f32 = 0,
fly_t: f32 = 0,

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
    // Abandon any planned arc. Every hand-driven path — drag, wheel, pinch, fit — funnels through
    // here, and a flight is a path from a start the camera has just left. `chase` would re-plan on
    // its own, but stating it here is what makes "the user's hand wins immediately" a property of
    // the one function they all call rather than of the one they don't.
    self.fly_len = 0;
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

/// Pose that applies `new_zoom` while keeping `world` at its current screen position.
///
/// Zooming around a point always moves `center` (that is how the point stays put). It does
/// **not** slide `world` to the middle of the viewport — that is `poseForBounds`, and it is
/// what made diving into a note at the edge of the panel yank the whole view.
pub fn poseZoomAround(self: *const Camera, world: dvui.Point, new_zoom: f32) Pose {
    const z = self.clamp(new_zoom);
    const screen = self.worldToScreen(world);
    const o = self.screenOrigin();
    return .{
        .zoom = z,
        .center = .{
            .x = world.x - (screen.x - o.x) / z,
            .y = world.y - (screen.y - o.y) / z,
        },
    };
}

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
/// Abandon any arc. Called wherever the user takes the camera by hand — a drag or a wheel mid-
/// flight must win immediately, not fight a path it cannot see.

pub fn fitBounds(self: *Camera, bounds: dvui.Rect, padding: f32) void {
    const pose = self.poseForBounds(bounds, padding);
    self.zoom = pose.zoom;
    self.center = pose.center;
    self.syncTargets();
}

/// Point the camera at `pose`.
///
/// The single entry point for every retarget, which exists for the epsilon no-op as much as for
/// the assignment: `applyFraming` re-derives the same pose on every frame of a pane drag, and
/// re-assigning an identical target mid-flight restarts the ease and hitches. Comparing first
/// makes that free.
pub fn retarget(self: *Camera, pose: Pose) void {
    const same_c = @abs(pose.center.x - self.center_target.x) < 0.01 and
        @abs(pose.center.y - self.center_target.y) < 0.01;
    const same_z = @abs(pose.zoom - self.zoom_target) < @max(pose.zoom, 0.01) * 1e-3;
    if (same_c and same_z) return;

    self.center_target = pose.center;
    self.zoom_target = pose.zoom;
}

/// True while `center`/`zoom` have not caught up to their targets.
pub fn chasing(self: *const Camera) bool {
    return self.center.x != self.center_target.x or
        self.center.y != self.center_target.y or
        self.zoom != self.zoom_target;
}

/// Ease `center`/`zoom` toward their targets along a path that moves at a constant *apparent*
/// speed. `k` is the chase rate (1/s); higher is snappier. Returns true if anything moved.
///
/// Easing the two independently — which is what this did — is why flying to a note read as "zoom
/// in on the middle of the blob, then slide sideways to the note". The centre offset costs
/// `offset · zoom` screen pixels, so while the camera is still zoomed out the pan is worth almost
/// no pixels and appears not to be happening, and once it has zoomed in the same small world offset
/// is suddenly worth a screenful and everything lurches. The two motions have one time constant and
/// two completely different perceived effects.
///
/// The fix is the standard one: van Wijk & Nuij's smooth zoom-and-pan (2003), the same path
/// `d3.interpolateZoom` walks. Treat the view as a point in `(x, y, w)` — `w` being how much world
/// the viewport spans — and follow the path through that space along which the image moves at
/// constant speed on screen. It falls out as a hyperbolic curve: the camera zooms *out* on its way
/// across when the two ends are far apart, which is what makes a long flight read as one arc
/// instead of two moves, and is exactly what a reader does by hand when moving between two distant
/// places on a map.
///
/// `fly_t` still eases exponentially, so the flight keeps the feel and the convergence the chase
/// always had; what changed is what `t` is interpolating *along*.
pub fn chase(self: *Camera, dt: f32, k: f32) bool {
    if (!self.chasing()) {
        self.fly_len = 0;
        return false;
    }
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
        self.fly_len = 0;
        return true;
    }

    // Re-plan whenever the destination moves. A flight is a path from where the camera *was*, so a
    // retarget mid-flight starts a fresh one from wherever it has reached — no discontinuity,
    // because the new path begins at the current view by construction.
    if (self.fly_len <= 0 or
        self.fly_to.x != self.center_target.x or
        self.fly_to.y != self.center_target.y or
        self.fly_to_zoom != self.zoom_target)
    {
        self.beginFlight();
    }

    self.fly_t += (1.0 - self.fly_t) * t;
    self.applyFlight(self.fly_t);
    return true;
}

/// Perceived-speed constant. √2 is van Wijk's recommended value: lower makes a long flight arc out
/// further and feel slower to commit, higher flattens it back toward the two-phase motion this
/// exists to avoid.
const fly_rho: f32 = std.math.sqrt2;

/// Plan a flight from the current view to the current target.
fn beginFlight(self: *Camera) void {
    self.fly_from = self.center;
    self.fly_from_zoom = self.zoom;
    self.fly_to = self.center_target;
    self.fly_to_zoom = self.zoom_target;
    self.fly_t = 0;
    self.fly_len = 0;

    const w0 = self.worldSpan(self.zoom);
    const w1 = self.worldSpan(self.zoom_target);
    if (!(w0 > 0) or !(w1 > 0)) return;

    const ux = self.center_target.x - self.center.x;
    const uy = self.center_target.y - self.center.y;
    const dist = @sqrt(ux * ux + uy * uy);

    // Pure zoom: no path to walk, just a scale ramp. `u1` in the denominators below would divide
    // by zero, and the limit is this.
    if (dist < w0 * 1e-4) {
        self.fly_len = @abs(@log(w1 / w0)) / fly_rho;
        return;
    }

    const rho2 = fly_rho * fly_rho;
    const rho4 = rho2 * rho2;
    const b0 = (w1 * w1 - w0 * w0 + rho4 * dist * dist) / (2 * w0 * rho2 * dist);
    const b1 = (w1 * w1 - w0 * w0 - rho4 * dist * dist) / (2 * w1 * rho2 * dist);
    const r0 = @log(@sqrt(b0 * b0 + 1) - b0);
    const r1 = @log(@sqrt(b1 * b1 + 1) - b1);
    const len = (r1 - r0) / fly_rho;
    if (!std.math.isFinite(len) or @abs(len) < 1e-6) {
        // Degenerate geometry (the two views nearly coincide in path space). Fall back to the
        // scale ramp rather than emit a NaN into the view matrix.
        self.fly_len = @abs(@log(w1 / w0)) / fly_rho;
        return;
    }
    self.fly_len = len;
}

/// Evaluate the planned flight at `f` in 0..1 and write it to `center`/`zoom`.
fn applyFlight(self: *Camera, f: f32) void {
    const w0 = self.worldSpan(self.fly_from_zoom);
    const w1 = self.worldSpan(self.fly_to_zoom);
    if (!(w0 > 0) or !(w1 > 0) or self.fly_len <= 0) {
        // No usable path — ease straight there rather than stall.
        self.center.x = std.math.lerp(self.fly_from.x, self.fly_to.x, f);
        self.center.y = std.math.lerp(self.fly_from.y, self.fly_to.y, f);
        self.zoom = self.fly_from_zoom * @exp(@log(self.fly_to_zoom / self.fly_from_zoom) * f);
        return;
    }

    // Same zoom at both ends: slide. van Wijk's path still arcs *out* when the two centres
    // are far apart, which is right for a click-to-focus flight and wrong for a save that
    // asked to keep zoom — the reader would watch the map zoom out and lose the note.
    if (@abs(self.fly_from_zoom - self.fly_to_zoom) < @max(self.fly_from_zoom, 0.01) * 1e-3) {
        self.center.x = std.math.lerp(self.fly_from.x, self.fly_to.x, f);
        self.center.y = std.math.lerp(self.fly_from.y, self.fly_to.y, f);
        self.zoom = self.fly_to_zoom;
        return;
    }

    const ux = self.fly_to.x - self.fly_from.x;
    const uy = self.fly_to.y - self.fly_from.y;
    const dist = @sqrt(ux * ux + uy * uy);

    if (dist < w0 * 1e-4) {
        self.center = self.fly_to;
        self.zoom = self.zoomForSpan(w0 * @exp(@log(w1 / w0) * f));
        return;
    }

    const rho2 = fly_rho * fly_rho;
    const rho4 = rho2 * rho2;
    const b0 = (w1 * w1 - w0 * w0 + rho4 * dist * dist) / (2 * w0 * rho2 * dist);
    const r0 = @log(@sqrt(b0 * b0 + 1) - b0);
    const s = f * self.fly_len;

    const cosh_r0 = std.math.cosh(r0);
    const sinh_r0 = std.math.sinh(r0);
    const arg = fly_rho * s + r0;
    const w = w0 * cosh_r0 / std.math.cosh(arg);
    const u = w0 / rho2 * (cosh_r0 * std.math.tanh(arg) - sinh_r0);
    const along = std.math.clamp(u / dist, 0, 1);

    if (!std.math.isFinite(w) or !std.math.isFinite(along)) return;
    self.center.x = self.fly_from.x + ux * along;
    self.center.y = self.fly_from.y + uy * along;
    self.zoom = self.zoomForSpan(w);
}

/// How much world the viewport spans at `z`. The unit the flight path is measured in — it has to
/// be world *distance*, the same as the gap between the two centres, or the two halves of the
/// path equation are in different units.
fn worldSpan(self: *const Camera, z: f32) f32 {
    const vw = if (self.viewport.w > 0) self.viewport.w else 1;
    return vw / @max(z, abs_min_zoom);
}

fn zoomForSpan(self: *const Camera, w: f32) f32 {
    const vw = if (self.viewport.w > 0) self.viewport.w else 1;
    return vw / @max(w, 1e-6);
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

test "poseZoomAround keeps the world point on screen and off the viewport centre" {
    const vp: dvui.Rect.Physical = .{ .x = 0, .y = 0, .w = 800, .h = 600 };
    var c = camAt(.{ .x = 0, .y = 0 }, 1.0, vp);
    const world: dvui.Point = .{ .x = 200, .y = -100 };
    const before = c.worldToScreen(world);
    // Not in the middle of the pane — that is the whole point of pinning rather than fitting.
    try testing.expect(@abs(before.x - 400) > 50);
    const pose = c.poseZoomAround(world, 4.0);
    c.center = pose.center;
    c.zoom = pose.zoom;
    const after = c.worldToScreen(world);
    try testing.expectApproxEqAbs(before.x, after.x, 1e-3);
    try testing.expectApproxEqAbs(before.y, after.y, 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 4.0), c.zoom, 1e-5);
    // Fitting would have put this point at the viewport centre; pinning must not.
    const origin = c.screenOrigin();
    try testing.expect(@abs(after.x - origin.x) > 50);
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

    // The destination must never drift *away* from the middle of the viewport.
    //
    // This used to assert that progress through the octaves matched progress across the pan
    // exactly, on the reasoning that moving both in lockstep is what makes them read as one move.
    // It is not, and the arithmetic says so: screen offset is `world_offset · zoom`, so easing the
    // octaves linearly while the world offset falls linearly makes the product *rise* through the
    // middle of the flight. Flying 1000 units while zooming 0.25 -> 4, the destination starts 250
    // px off centre, drifts out to 522 px by two thirds of the way through, and only then rushes
    // back in. That is the "zoom into the middle of the blob, then pan to the note" the reader
    // reported, and the old test was holding it in place.
    var d = camAt(.{}, 0.25, .{ .x = 0, .y = 0, .w = 800, .h = 300 });
    d.zoom_target = 4.0;
    d.center_target = .{ .x = 1000, .y = 0 };
    const origin = d.screenOrigin();
    const start_off = @abs(d.worldToScreen(d.center_target).x - origin.x);
    var far: f32 = 0;
    var steps: usize = 0;
    while (d.chasing() and steps < 600) : (steps += 1) {
        _ = d.chase(1.0 / 60.0, 7);
        far = @max(far, @abs(d.worldToScreen(d.center_target).x - d.screenOrigin().x));
    }
    try testing.expect(!d.chasing());
    // A little slack for the arc's own overshoot in screen terms; the failure this guards is a
    // doubling, not a few percent.
    try testing.expect(far <= start_off * 1.1);
}

test "equal-zoom chase slides without arcing out" {
    // A save follow keeps zoom_target. van Wijk would still zoom out on a long pan; that is
    // how a link save lost the note even after the camera started chasing.
    var c = camAt(.{ .x = 0, .y = 0 }, 2.0, .{ .x = 0, .y = 0, .w = 800, .h = 600 });
    c.center_target = .{ .x = 4000, .y = -2500 };
    c.zoom_target = 2.0;
    var frames: usize = 0;
    while (c.chasing() and frames < 600) : (frames += 1) {
        _ = c.chase(1.0 / 60.0, 7);
        try testing.expectApproxEqAbs(@as(f32, 2.0), c.zoom, 1e-4);
    }
    try testing.expect(!c.chasing());
    try testing.expectApproxEqAbs(@as(f32, 4000), c.center.x, 0.02);
    try testing.expectApproxEqAbs(@as(f32, -2500), c.center.y, 0.02);
    try testing.expectEqual(@as(f32, 2.0), c.zoom);
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
