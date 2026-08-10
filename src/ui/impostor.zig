//! The note field, baked into world-space tiles at a few fixed drawing scales.
//!
//! Zoomed out, the panel's job is to draw more notes than there is any point drawing one at a
//! time. The way out is not to draw something else in their place — a marker per region loses the
//! shape of the vault, which is the only reason to be zoomed out — but to draw the same picture
//! from a cache. So the world is cut into tiles, each tile is rendered once into an offscreen
//! texture, and a frame is a handful of textured quads however many notes are underneath them.
//!
//! This is the arrangement a map renderer uses, and it is worth being explicit about why, because
//! the obvious alternative — a picture per cluster — fails in ways that are not obvious.
//!
//!   • *A cached picture is only sharp at the scale it was baked for.* A per-cluster picture is
//!     stretched to whatever size its cluster happens to be, which is a different factor for every
//!     cluster and drifts with every zoom: large regions come out blurred, small ones alias, and
//!     the aliasing crawls as the camera moves. Mipmaps would answer that, and `SDL_Renderer` has
//!     none. Tiles answer it by construction instead — a level's density is chosen so its tiles
//!     draw at about 1:1 while that level is showing, and levels sit an octave apart, so nothing
//!     is ever resampled by more than about √2 in either direction.
//!
//!   • *Everything on screen comes from one level.* Whether a thing is drawn from a picture is a
//!     property of the level, not of the thing, so no arrangement of the camera can put baked and
//!     unbaked objects side by side looking like two kinds of object.
//!
//!   • *Panning is free.* A tile is a patch of the world, not of the screen, so scrolling reuses
//!     what is already baked instead of invalidating it.
//!
//! Tiles hold the notes *and* the links among them. Links drawn live had to pick a coalescing
//! level from the current zoom, and every level crossing snapped the whole web; baked in, they
//! dissolve with their tile instead.
//!
//! Slots are handed out in order and never re-used without an intervening full clear, which is
//! what lets this work with no way to erase a single slot: a slot is either untouched since the
//! last clear or still holds the picture it was given.

const std = @import("std");
const dvui = @import("dvui");

/// Side of one tile, in pixels of the scale it was baked at.
///
/// The binding consideration is not the cost of a tile — that is one quad and one lookup however
/// much world it covers — but how many fit. Slots are handed out in order and reclaimed only by
/// wiping the lot, so a view that churns through them faster than it settles loses its pictures
/// and spends frames drawing the field directly, which is sharper than the pictures and therefore
/// visible every time it happens. Halving the tile quadruples the slots for the same texture, and
/// four times the headroom is worth more here than four times fewer quads.
pub const tile_px: u32 = 128;

/// Sizes tried for the atlas, largest first.
///
/// A frame needs slots for the view at one level, and briefly for two while levels cross, so the
/// requirement is roughly `2 × viewport area / tile area` plus room for what a pan is about to
/// want. The larger texture is 64MB and clears that comfortably; the smaller is the fallback for a
/// device that will not give it.
const atlas_sizes = [_]u32{ 4096, 2048 };

/// A tile: which drawing scale it belongs to, and which patch of the world it covers. Level is
/// part of the key so two levels can coexist while they cross-fade.
pub const Key = struct { level: i32, tx: i32, ty: i32 };

pub const Atlas = struct {
    target: ?dvui.TextureTarget = null,
    size_px: u32 = 0,
    /// Set once the backend has refused a target texture at every size. Nothing here is essential —
    /// the caller draws the notes directly instead — and retrying every frame would stall a frame
    /// for as long as the panel is open.
    unsupported: bool = false,
    tiles: std.AutoHashMapUnmanaged(Key, u32) = .empty,
    /// Next unused slot. Slots below this hold a picture; slots at or above it are clear.
    next: u32 = 0,
    /// The arrangement the contents belong to. A new layout moves every note, so every picture
    /// baked from the old one is wrong.
    gen: u64 = std.math.maxInt(u64),
    /// Everything else a picture depends on that isn't the layout — the theme, which notes are
    /// open. Folded in beside `gen` for the same reason.
    style: u64 = 0,

    /// Safe to call outside a frame, which is where teardown happens: releasing the texture needs
    /// a live window, and when there isn't one the process is going away with it anyway.
    pub fn deinit(self: *Atlas, gpa: std.mem.Allocator) void {
        self.tiles.deinit(gpa);
        if (dvui.current_window != null) {
            if (self.target) |t| t.destroyLater();
        }
        self.* = .{};
    }

    pub fn cols(self: *const Atlas) u32 {
        return if (self.size_px == 0) 0 else self.size_px / tile_px;
    }

    pub fn capacity(self: *const Atlas) u32 {
        const c = self.cols();
        return c * c;
    }

    /// Point the atlas at the current arrangement, clearing it if that has changed under it.
    /// Returns false when there is no atlas to be had and the caller should draw notes directly.
    ///
    /// Only valid between `Window.begin` and `Window.end`.
    pub fn begin(self: *Atlas, gen: u64, style: u64) bool {
        if (self.unsupported) return false;
        if (self.target == null) {
            for (atlas_sizes) |size| {
                self.target = dvui.textureCreateTarget(.{
                    .width = size,
                    .height = size,
                    .interpolation = .linear,
                }) catch continue;
                self.size_px = size;
                break;
            }
            if (self.target == null) {
                self.unsupported = true;
                return false;
            }
            self.gen = gen;
            self.style = style;
            self.next = 0;
            self.tiles.clearRetainingCapacity();
            return true;
        }
        if (self.gen != gen or self.style != style) {
            self.gen = gen;
            self.style = style;
            self.clear();
        }
        return true;
    }

    /// Forget every picture and wipe the texture, so slots can be handed out from the start again.
    /// The reason slots are never individually re-used: the backend can clear a whole target but
    /// not a rectangle of one.
    pub fn clear(self: *Atlas) void {
        self.tiles.clearRetainingCapacity();
        self.next = 0;
        if (self.target) |t| t.clear();
    }

    pub fn get(self: *const Atlas, key: Key) ?u32 {
        return self.tiles.get(key);
    }

    /// Reserve a slot for `key`, or null when the atlas is full.
    ///
    /// A full atlas is not handled here: the caller keeps drawing what it already has and decides
    /// for itself whether starting over is worth it. Wiping mid-frame would drop the pictures the
    /// frame is about to draw from.
    pub fn claim(self: *Atlas, gpa: std.mem.Allocator, key: Key) ?u32 {
        if (self.next >= self.capacity()) return null;
        const slot = self.next;
        self.tiles.put(gpa, key, slot) catch return null;
        self.next += 1;
        return slot;
    }

    /// Where a slot lives in the texture, in texture pixels.
    pub fn slotRect(self: *const Atlas, slot: u32) dvui.Rect.Physical {
        const c = @max(self.cols(), 1);
        return .{
            .x = @floatFromInt((slot % c) * tile_px),
            .y = @floatFromInt((slot / c) * tile_px),
            .w = @floatFromInt(tile_px),
            .h = @floatFromInt(tile_px),
        };
    }

    pub fn texture(self: *const Atlas) ?dvui.Texture {
        const t = self.target orelse return null;
        return dvui.Texture.fromTargetTemp(t) catch null;
    }
};

/// A bake pass: everything drawn between `begin` and `end` lands in the atlas rather than on
/// screen. One per frame at most — each one costs a pipeline flush at both ends.
///
/// Coordinates inside the pass are texture pixels, because the target is installed with no offset.
/// Nothing here touches dvui's deferred render queues, unlike `dvui.Picture`: a bake issues
/// `renderTriangles` against a target whose `rendering` is set, which renders immediately and
/// never reaches a queue.
pub const Pass = struct {
    prev_target: dvui.RenderTarget,
    prev_clip: dvui.Rect.Physical,

    /// Only valid between `Window.begin` and `Window.end`.
    pub fn begin(atlas: *const Atlas) ?Pass {
        const t = atlas.target orelse return null;
        const prev_clip = dvui.clipGet();
        return .{
            .prev_target = dvui.renderTarget(.{ .texture = t, .offset = .{} }),
            .prev_clip = prev_clip,
        };
    }

    /// Confine drawing to one slot. Set directly rather than intersected: the clip in force is a
    /// rectangle of the *screen*, and has nothing to say about where in a texture we may draw.
    pub fn clipTo(_: Pass, r: dvui.Rect.Physical) void {
        dvui.clipSet(r);
    }

    pub fn end(self: Pass) void {
        dvui.clipSet(self.prev_clip);
        _ = dvui.renderTarget(self.prev_target);
    }
};

/// Tile quads, in one draw call. Colour is white scaled by the layer's alpha, which on a
/// premultiplied texture is a straight fade of the baked picture.
pub const QuadBatch = struct {
    arena: std.mem.Allocator,
    tex: dvui.Texture,
    size_px: f32,
    b: ?dvui.Triangles.Builder = null,

    const verts_per: usize = 4;
    const idx_per: usize = 6;
    const max_quads: usize = std.math.maxInt(u16) / verts_per;

    pub fn init(arena: std.mem.Allocator, atlas: *const Atlas, tex: dvui.Texture) QuadBatch {
        return .{ .arena = arena, .tex = tex, .size_px = @floatFromInt(atlas.size_px) };
    }

    /// `src` is the slot in the texture, `dst` where it goes on screen.
    pub fn add(self: *QuadBatch, src: dvui.Rect.Physical, dst: dvui.Rect.Physical, alpha: f32) void {
        if (self.b) |*b| {
            if (b.vertexes.items.len / verts_per >= max_quads) self.flush();
        }
        if (self.b == null) {
            self.b = dvui.Triangles.Builder.init(
                self.arena,
                max_quads * verts_per,
                max_quads * idx_per,
            ) catch return;
        }
        const b = &(self.b.?);

        // Inset past the linear filter footprint. 0.5 was enough for hard marks; soft glows
        // still bled into the neighbouring atlas slot and read as a hard cut / UV seam.
        const h: f32 = 1.5;
        const ul = (src.x + h) / self.size_px;
        const vt = (src.y + h) / self.size_px;
        const ur = (src.x + src.w - h) / self.size_px;
        const vb = (src.y + src.h - h) / self.size_px;

        const col: dvui.Color.PMA = .fromColor(dvui.Color.white.opacity(alpha));
        const base: u16 = @intCast(b.vertexes.items.len);
        b.appendVertex(.{ .pos = .{ .x = dst.x, .y = dst.y }, .col = col, .uv = .{ ul, vt } });
        b.appendVertex(.{ .pos = .{ .x = dst.x + dst.w, .y = dst.y }, .col = col, .uv = .{ ur, vt } });
        b.appendVertex(.{ .pos = .{ .x = dst.x + dst.w, .y = dst.y + dst.h }, .col = col, .uv = .{ ur, vb } });
        b.appendVertex(.{ .pos = .{ .x = dst.x, .y = dst.y + dst.h }, .col = col, .uv = .{ ul, vb } });
        b.appendTriangles(&.{ base, base + 1, base + 2, base, base + 2, base + 3 });
    }

    pub fn flush(self: *QuadBatch) void {
        var b = self.b orelse return;
        self.b = null;
        if (b.vertexes.items.len == 0) return;
        dvui.renderTriangles(b.build_unowned(), self.tex) catch {};
    }
};

test {
    std.testing.refAllDecls(@This());
}

test "slots tile the atlas without overlapping" {
    var a: Atlas = .{ .size_px = 2048 };
    var seen = std.AutoHashMap([2]i32, void).init(std.testing.allocator);
    defer seen.deinit();
    for (0..a.capacity()) |slot| {
        const r = a.slotRect(@intCast(slot));
        try std.testing.expect(r.x + r.w <= @as(f32, @floatFromInt(a.size_px)));
        try std.testing.expect(r.y + r.h <= @as(f32, @floatFromInt(a.size_px)));
        const key: [2]i32 = .{ @intFromFloat(r.x), @intFromFloat(r.y) };
        try std.testing.expect(!(try seen.getOrPut(key)).found_existing);
    }
}
