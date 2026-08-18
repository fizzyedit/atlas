//! Screen-radius hit testing over a living mark list (warm set / LOD agents).

const std = @import("std");
const dvui = @import("dvui");

const HitIndex = @This();

pub const Mark = struct {
    id: u32,
    center: dvui.Point.Physical,
    radius: f32,
};

marks: []const Mark = &.{},

pub fn init(marks: []const Mark) HitIndex {
    return .{ .marks = marks };
}

/// Nearest mark whose disc contains `p`, or null.
pub fn hit(self: HitIndex, p: dvui.Point.Physical) ?u32 {
    var best_id: ?u32 = null;
    var best_d2: f32 = std.math.floatMax(f32);
    for (self.marks) |m| {
        const dx = p.x - m.center.x;
        const dy = p.y - m.center.y;
        const r = @max(m.radius, 0.5);
        const d2 = dx * dx + dy * dy;
        if (d2 <= r * r and d2 < best_d2) {
            best_d2 = d2;
            best_id = m.id;
        }
    }
    return best_id;
}

/// All marks within `falloff` of `p`, written into `out` (capped by out.len). Returns count.
pub fn gatherNear(
    self: HitIndex,
    p: dvui.Point.Physical,
    falloff: f32,
    out: []u32,
) usize {
    var n: usize = 0;
    const f2 = falloff * falloff;
    for (self.marks) |m| {
        if (n >= out.len) break;
        const dx = p.x - m.center.x;
        const dy = p.y - m.center.y;
        if (dx * dx + dy * dy <= f2) {
            out[n] = m.id;
            n += 1;
        }
    }
    return n;
}

// -- tests ------------------------------------------------------------------------

const testing = std.testing;

test "hit picks nearest contained mark" {
    const marks = [_]Mark{
        .{ .id = 1, .center = .{ .x = 0, .y = 0 }, .radius = 10 },
        .{ .id = 2, .center = .{ .x = 5, .y = 0 }, .radius = 10 },
    };
    const idx = HitIndex.init(&marks);
    try testing.expectEqual(@as(?u32, 2), idx.hit(.{ .x = 6, .y = 0 }));
    try testing.expectEqual(@as(?u32, null), idx.hit(.{ .x = 100, .y = 0 }));
}

test "gatherNear respects falloff" {
    const marks = [_]Mark{
        .{ .id = 1, .center = .{ .x = 0, .y = 0 }, .radius = 1 },
        .{ .id = 2, .center = .{ .x = 50, .y = 0 }, .radius = 1 },
    };
    const idx = HitIndex.init(&marks);
    var out: [4]u32 = undefined;
    const n = idx.gatherNear(.{ .x = 0, .y = 0 }, 20, &out);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqual(@as(u32, 1), out[0]);
}
