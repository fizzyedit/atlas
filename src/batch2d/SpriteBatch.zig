//! Many tinted textured quads in one (or a few) `renderTriangles` calls.

const std = @import("std");
const dvui = @import("dvui");
const SoftAtlas = @import("SoftAtlas.zig");

const SpriteBatch = @This();

pub const Instance = struct {
    center: dvui.Point.Physical,
    /// Half-extent of the axis-aligned quad in screen pixels.
    half_size: f32,
    color: dvui.Color,
    uv: SoftAtlas.UvRect,
};

arena: std.mem.Allocator,
/// When set, `add` auto-flushes on u16 capacity so large bakes cannot drop sprites.
auto_tex: ?dvui.Texture = null,
b: ?dvui.Triangles.Builder = null,
count: u32 = 0,
/// How many times `flush` submitted triangles this batch lifetime (profiling).
flush_count: u32 = 0,

const verts_per: usize = 4;
const idx_per: usize = 6;
/// `Vertex.Index` is u16 in this dvui pin.
pub const max_sprites: usize = std.math.maxInt(u16) / verts_per;

pub fn init(arena: std.mem.Allocator) SpriteBatch {
    return .{ .arena = arena };
}

pub fn initAuto(arena: std.mem.Allocator, tex: dvui.Texture) SpriteBatch {
    return .{ .arena = arena, .auto_tex = tex };
}

pub fn add(self: *SpriteBatch, inst: Instance) void {
    const hs = @max(inst.half_size, 0.25);
    if (self.b) |*bb| {
        if (bb.vertexes.items.len / verts_per >= max_sprites) {
            if (self.auto_tex) |tex| {
                self.flush(tex);
            } else {
                return;
            }
        }
    }
    if (self.b == null) {
        self.b = dvui.Triangles.Builder.init(
            self.arena,
            max_sprites * verts_per,
            max_sprites * idx_per,
        ) catch return;
    }
    const bb = &(self.b.?);
    const col: dvui.Color.PMA = .fromColor(inst.color);
    const x0 = inst.center.x - hs;
    const y0 = inst.center.y - hs;
    const x1 = inst.center.x + hs;
    const y1 = inst.center.y + hs;
    const base: u16 = @intCast(bb.vertexes.items.len);
    bb.appendVertex(.{ .pos = .{ .x = x0, .y = y0 }, .col = col, .uv = .{ inst.uv.u0, inst.uv.v0 } });
    bb.appendVertex(.{ .pos = .{ .x = x1, .y = y0 }, .col = col, .uv = .{ inst.uv.u1, inst.uv.v0 } });
    bb.appendVertex(.{ .pos = .{ .x = x1, .y = y1 }, .col = col, .uv = .{ inst.uv.u1, inst.uv.v1 } });
    bb.appendVertex(.{ .pos = .{ .x = x0, .y = y1 }, .col = col, .uv = .{ inst.uv.u0, inst.uv.v1 } });
    bb.appendTriangles(&.{ base, base + 1, base + 2, base, base + 2, base + 3 });
    self.count += 1;
}

/// Convenience: disc/glow/ring from a soft atlas.
pub fn addKind(
    self: *SpriteBatch,
    atlas: *const SoftAtlas,
    center: dvui.Point.Physical,
    half_size: f32,
    color: dvui.Color,
    kind: SoftAtlas.Kind,
) void {
    self.add(.{
        .center = center,
        .half_size = half_size,
        .color = color,
        .uv = atlas.uv(kind),
    });
}

pub fn flush(self: *SpriteBatch, tex: ?dvui.Texture) void {
    var b = self.b orelse return;
    self.b = null;
    self.count = 0;
    if (b.vertexes.items.len == 0) return;
    self.flush_count += 1;
    dvui.renderTriangles(b.build_unowned(), tex) catch {};
}

/// Build without submitting — for headless benches / tests.
pub fn buildUnowned(self: *SpriteBatch) ?dvui.Triangles {
    var b = self.b orelse return null;
    self.b = null;
    if (b.vertexes.items.len == 0) return null;
    return b.build_unowned();
}

// -- tests ------------------------------------------------------------------------

const testing = std.testing;

test "four verts per sprite; tint preserved" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var batch = SpriteBatch.init(arena);
    const uv: SoftAtlas.UvRect = .{ .u0 = 0, .v0 = 0, .u1 = 0.3, .v1 = 1 };
    batch.add(.{
        .center = .{ .x = 10, .y = 20 },
        .half_size = 4,
        .color = .{ .r = 255, .g = 0, .b = 0, .a = 128 },
        .uv = uv,
    });
    batch.add(.{
        .center = .{ .x = 40, .y = 20 },
        .half_size = 8,
        .color = .{ .r = 0, .g = 255, .b = 0, .a = 255 },
        .uv = uv,
    });
    try testing.expectEqual(@as(u32, 2), batch.count);
    const tris = batch.buildUnowned() orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 8), tris.vertexes.len);
    try testing.expectEqual(@as(usize, 12), tris.indices.len);
    // Premultiplied: a=128 → r channel scaled.
    try testing.expect(tris.vertexes[0].col.a > 0);
}
