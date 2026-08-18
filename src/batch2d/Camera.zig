//! Hand-rolled 2D camera — world ↔ screen without ScrollArea coupling.
//!
//! Lifted from Atlas’s graph camera, without hex-lattice zoom stops (callers clamp).

const std = @import("std");
const dvui = @import("dvui");

const Camera = @This();

pub const min_zoom: f32 = 0.02;
pub const abs_min_zoom: f32 = 1e-5;
/// High enough to open tightly packed island cells (spread ~ leaf spacing).
pub const max_zoom: f32 = 256.0;

center: dvui.Point = .{},
zoom: f32 = 1.0,
center_target: dvui.Point = .{},
zoom_target: f32 = 1.0,
user_driving: bool = false,
viewport: dvui.Rect.Physical = .{},
zoom_floor: f32 = min_zoom,

pub fn syncTargets(self: *Camera) void {
    self.center_target = self.center;
    self.zoom_target = self.zoom;
}

pub fn clamp(self: *const Camera, z: f32) f32 {
    return std.math.clamp(z, self.zoom_floor, max_zoom);
}

pub fn setContentExtent(self: *Camera, world_radius: f32, slack: f32) void {
    const span = @max(world_radius * 2, 1);
    const avail = @max(@min(self.viewport.w, self.viewport.h), 1);
    const fit = avail / span;
    self.zoom_floor = std.math.clamp(fit / @max(slack, 1), abs_min_zoom, min_zoom);
}

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

pub fn panScreen(self: *Camera, dx: f32, dy: f32) void {
    self.center.x -= dx / self.zoom;
    self.center.y -= dy / self.zoom;
    self.syncTargets();
}

pub fn zoomAtScreen(self: *Camera, factor: f32, focal: dvui.Point.Physical) void {
    if (!std.math.isFinite(factor) or factor <= 0 or factor == 1.0) return;
    const old = self.zoom;
    const new_z = self.clamp(old * factor);
    if (new_z == old) return;
    const before = self.screenToWorld(focal);
    self.zoom = new_z;
    const after = self.screenToWorld(focal);
    self.center.x += before.x - after.x;
    self.center.y += before.y - after.y;
    self.syncTargets();
}

pub const Pose = struct { center: dvui.Point, zoom: f32 };

pub fn poseForBounds(self: *const Camera, bounds: dvui.Rect, padding: f32) Pose {
    const bw = @max(bounds.w, 1);
    const bh = @max(bounds.h, 1);
    const avail_w = @max(self.viewport.w - padding * 2, 1);
    const avail_h = @max(self.viewport.h - padding * 2, 1);
    return .{
        .zoom = self.clamp(@min(avail_w / bw, avail_h / bh)),
        .center = .{
            .x = bounds.x + bounds.w * 0.5,
            .y = bounds.y + bounds.h * 0.5,
        },
    };
}

pub fn fitBounds(self: *Camera, bounds: dvui.Rect, padding: f32) void {
    const pose = self.poseForBounds(bounds, padding);
    self.zoom = pose.zoom;
    self.center = pose.center;
    self.syncTargets();
}

pub fn chasing(self: *const Camera) bool {
    return self.center.x != self.center_target.x or
        self.center.y != self.center_target.y or
        self.zoom != self.zoom_target;
}

pub fn chase(self: *Camera, dt: f32, k: f32) bool {
    if (!self.chasing()) return false;
    const t = 1.0 - @exp(-k * dt);
    const dx = self.center_target.x - self.center.x;
    const dy = self.center_target.y - self.center.y;
    const dz = self.zoom_target - self.zoom;
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

/// World AABB currently visible.
pub fn viewWorld(self: *const Camera) dvui.Rect {
    const tl = self.screenToWorld(.{ .x = self.viewport.x, .y = self.viewport.y });
    const br = self.screenToWorld(.{
        .x = self.viewport.x + self.viewport.w,
        .y = self.viewport.y + self.viewport.h,
    });
    return .{
        .x = @min(tl.x, br.x),
        .y = @min(tl.y, br.y),
        .w = @abs(br.x - tl.x),
        .h = @abs(br.y - tl.y),
    };
}

// -- tests ------------------------------------------------------------------------

const testing = std.testing;

test "worldToScreen round-trips" {
    var c: Camera = .{
        .center = .{ .x = 10, .y = -20 },
        .zoom = 1.5,
        .viewport = .{ .x = 100, .y = 50, .w = 800, .h = 600 },
    };
    c.syncTargets();
    const w: dvui.Point = .{ .x = 40, .y = 0 };
    const s = c.worldToScreen(w);
    const back = c.screenToWorld(s);
    try testing.expectApproxEqAbs(w.x, back.x, 1e-4);
    try testing.expectApproxEqAbs(w.y, back.y, 1e-4);
}
