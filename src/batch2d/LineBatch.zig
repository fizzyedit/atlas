//! Thin tinted line quads — highlights and webs without leaving the batch path.

const std = @import("std");
const dvui = @import("dvui");

const LineBatch = @This();

arena: std.mem.Allocator,
b: ?dvui.Triangles.Builder = null,
count: u32 = 0,

const verts_per: usize = 4;
const idx_per: usize = 6;
pub const max_lines: usize = std.math.maxInt(u16) / verts_per;

pub fn init(arena: std.mem.Allocator) LineBatch {
    return .{ .arena = arena };
}

pub fn add(
    self: *LineBatch,
    a: dvui.Point.Physical,
    b_pt: dvui.Point.Physical,
    thickness: f32,
    color: dvui.Color,
) void {
    const dx = b_pt.x - a.x;
    const dy = b_pt.y - a.y;
    const len = @sqrt(dx * dx + dy * dy);
    if (len < 1e-3) return;
    const h = @max(thickness, 0.75) * 0.5;
    const nx = -dy / len * h;
    const ny = dx / len * h;

    if (self.b) |*bb| {
        if (bb.vertexes.items.len / verts_per >= max_lines) return;
    }
    if (self.b == null) {
        self.b = dvui.Triangles.Builder.init(
            self.arena,
            max_lines * verts_per,
            max_lines * idx_per,
        ) catch return;
    }
    const bb = &(self.b.?);
    const base: u16 = @intCast(bb.vertexes.items.len);
    const col: dvui.Color.PMA = .fromColor(color);
    bb.appendVertex(.{ .pos = .{ .x = a.x + nx, .y = a.y + ny }, .col = col });
    bb.appendVertex(.{ .pos = .{ .x = a.x - nx, .y = a.y - ny }, .col = col });
    bb.appendVertex(.{ .pos = .{ .x = b_pt.x - nx, .y = b_pt.y - ny }, .col = col });
    bb.appendVertex(.{ .pos = .{ .x = b_pt.x + nx, .y = b_pt.y + ny }, .col = col });
    bb.appendTriangles(&.{ base, base + 1, base + 2, base, base + 2, base + 3 });
    self.count += 1;
}

pub fn flush(self: *LineBatch) void {
    var b = self.b orelse return;
    self.b = null;
    self.count = 0;
    if (b.vertexes.items.len == 0) return;
    dvui.renderTriangles(b.build_unowned(), null) catch {};
}

pub fn buildUnowned(self: *LineBatch) ?dvui.Triangles {
    var b = self.b orelse return null;
    self.b = null;
    if (b.vertexes.items.len == 0) return null;
    return b.build_unowned();
}

// -- tests ------------------------------------------------------------------------

const testing = std.testing;

test "line emits one quad" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var batch = LineBatch.init(arena_state.allocator());
    batch.add(.{ .x = 0, .y = 0 }, .{ .x = 100, .y = 0 }, 2, dvui.Color.white);
    try testing.expectEqual(@as(u32, 1), batch.count);
    const tris = batch.buildUnowned() orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 4), tris.vertexes.len);
    try testing.expectEqual(@as(usize, 6), tris.indices.len);
}
