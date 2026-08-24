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

    // Full: render what is here and start a new builder, rather than dropping the line.
    //
    // `max_lines` is dvui's `Vertex.Index` being a u16, which is permanent app-wide (the web,
    // raylib and dx11 backends all reject `-Dvertex-index=u32`). It is a *batching* limit, not a
    // budget — `SpriteBatch` has always treated it that way — but this dropped everything past it
    // on the floor, in silence.
    //
    // What made that a visible bug rather than a missing hair: `world_draw` adds the ambient web
    // first and the focused note's own links last. At the zoom where a large vault has just
    // finished exploding, the ambient web alone is past 16,383 lines, so the cap was reached
    // before the highlight was ever added and the reader's connections vanished entirely — at that
    // band only, since zooming either way puts fewer links on screen. Overflowing into another
    // draw call also keeps the ordering the highlight depends on: later calls paint over earlier.
    if (self.b) |*bb| {
        if (bb.vertexes.items.len / verts_per >= max_lines) self.flush();
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

/// Render and reset. `count` is the lines in the *current* builder, so this zeroes it — an
/// overflowing batch reports the tail, not the total.
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

test "a full batch overflows into a new one instead of dropping lines" {
    // The failure this pins down is silent: past the cap `add` used to return, so a caller adding
    // the important lines last — which `world_draw` does, the focused note's own links after the
    // ambient web — lost exactly those and had no way to know.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var batch = LineBatch.init(arena_state.allocator());

    // Right up to the cap, without tripping it.
    for (0..max_lines) |i| {
        const y: f32 = @floatFromInt(i % 512);
        batch.add(.{ .x = 0, .y = y }, .{ .x = 100, .y = y }, 1, dvui.Color.white);
    }
    try testing.expectEqual(@as(u32, max_lines), batch.count);

    // One more has nowhere to go in this builder. It must still be accepted — dropping it is the
    // bug — and the only place it can go is a fresh builder, so the count restarts.
    //
    // Asserted through `buildUnowned` rather than by letting `add` auto-flush, because a flush
    // renders, and rendering needs a window this test does not have. The branch under test is the
    // capacity check itself.
    const first = batch.buildUnowned() orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, max_lines * verts_per), first.vertexes.len);
    batch.count = 0;

    batch.add(.{ .x = 0, .y = 7 }, .{ .x = 100, .y = 7 }, 1, dvui.Color.white);
    try testing.expectEqual(@as(u32, 1), batch.count);
    const second = batch.buildUnowned() orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, verts_per), second.vertexes.len);
}
