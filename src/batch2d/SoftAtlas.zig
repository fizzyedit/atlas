//! Tiny shared atlas of soft disc / glow / ring cells for tinted sprite batches.
//!
//! Pixels are generated on the CPU as premultiplied RGBA. Upload happens once via
//! `ensureTexture` between `Window.begin` and `Window.end`.

const std = @import("std");
const dvui = @import("dvui");

const SoftAtlas = @This();

/// `dash_ring_thin` is the same recipe as `dash_ring` with a much narrower stroke.
///
/// A sprite's stroke scales with the quad, so drawn thickness is `width × radius` — one cell
/// cannot hold a constant-looking stroke across the radius range a coalesced mass spans (roughly
/// 14–46 px). One cell tuned for small marks reads as a fat band on a large one. Callers pick by
/// radius (`dash_thin_from` in `galaxy.drawStyledMarks`). Masses always use these sprites in the
/// field; the vector dashed stroke is reserved for the overlay (open notes, hovered masses).
pub const Kind = enum { disc, glow, ring, dash_ring, dash_ring_thin };

/// Normalized UV rectangle into the atlas texture.
pub const UvRect = struct {
    u0: f32,
    v0: f32,
    u1: f32,
    v1: f32,
};

/// Side of one cell in atlas pixels. 128 keeps a ~1.5 px dash stroke several texels wide after
/// linear filter, which is what lets the stroke read thin instead of a smeared band. 64 read as
/// soft rounded-rects past ~20 px; 96 was round enough but too coarse to thin the dashes.
pub const cell_px: u32 = 128;
/// Padding inside each cell so linear filter does not bleed into neighbours.
pub const pad_px: u32 = 3;
const cells: u32 = 5;
pub const atlas_w: u32 = cell_px * cells;
pub const atlas_h: u32 = cell_px;

pixels: []dvui.Color.PMA = &.{},
tex: ?dvui.Texture = null,
/// Set when every create size failed; callers draw without texture.
unsupported: bool = false,

pub fn init(gpa: std.mem.Allocator) !SoftAtlas {
    const n = atlas_w * atlas_h;
    const pixels = try gpa.alloc(dvui.Color.PMA, n);
    @memset(pixels, .{ .r = 0, .g = 0, .b = 0, .a = 0 });
    paintCells(pixels);
    return .{ .pixels = pixels };
}

pub fn deinit(self: *SoftAtlas, gpa: std.mem.Allocator) void {
    if (self.tex) |t| {
        if (dvui.current_window != null) dvui.Texture.destroyLater(t);
    }
    gpa.free(self.pixels);
    self.* = .{};
}

/// UV for a sprite kind. Inset by `pad_px` so linear filtering cannot sample the
/// neighbouring atlas cell (kinds sit in one horizontal strip).
pub fn uv(self: *const SoftAtlas, kind: Kind) UvRect {
    _ = self;
    const i: u32 = @intFromEnum(kind);
    const size: f32 = @floatFromInt(atlas_w);
    const h: f32 = @floatFromInt(pad_px);
    const x0: f32 = @floatFromInt(i * cell_px);
    const ah: f32 = @floatFromInt(atlas_h);
    return .{
        .u0 = (x0 + h) / size,
        .v0 = h / ah,
        .u1 = (x0 + @as(f32, @floatFromInt(cell_px)) - h) / size,
        .v1 = (ah - h) / ah,
    };
}

/// Create / refresh the GPU texture. Safe to call every frame; no-ops once uploaded.
pub fn ensureTexture(self: *SoftAtlas) bool {
    if (self.unsupported) return false;
    if (self.tex != null) return true;
    if (dvui.current_window == null) return false;
    self.tex = dvui.Texture.fromPixelsPMA(self.pixels, atlas_w, atlas_h, .linear) catch {
        self.unsupported = true;
        return false;
    };
    return true;
}

pub fn texture(self: *const SoftAtlas) ?dvui.Texture {
    return self.tex;
}

fn paintCells(pixels: []dvui.Color.PMA) void {
    // Tighter feather than the old 0.12 band — large scaled discs stay circular instead of
    // reading as soft rounded squares.
    paintDisc(pixels, 0, 0.90, 0.07);
    paintGlow(pixels, 1);
    paintRing(pixels, 2, 0.82, 0.10, 0.07);
    // Nine long dashes at ~70% duty — the same cadence as the vector overlay (`strokeCircleDashed`
    // lands on ~9 dashes around the circle). Fourteen short ticks used to read as a dotted band,
    // thicker than the nodes they sat next to. Stroke is `width × radius`: 0.055 keeps a 20 px
    // mass near a pixel, 0.032 keeps a 46 px mass near 1.5 px.
    paintDashRing(pixels, 3, 0.82, 0.055, 0.04, 9, 0.70);
    paintDashRing(pixels, 4, 0.82, 0.032, 0.03, 9, 0.70);
}

fn cellOrigin(cell: u32) struct { x: u32, y: u32 } {
    return .{ .x = cell * cell_px, .y = 0 };
}

fn setPx(pixels: []dvui.Color.PMA, x: u32, y: u32, a: f32) void {
    if (x >= atlas_w or y >= atlas_h) return;
    const ai = std.math.clamp(a, 0, 1);
    const u8a: u8 = @intFromFloat(@round(ai * 255));
    pixels[y * atlas_w + x] = .{ .r = u8a, .g = u8a, .b = u8a, .a = u8a };
}

fn paintDisc(pixels: []dvui.Color.PMA, cell: u32, core: f32, feather: f32) void {
    const o = cellOrigin(cell);
    const cx = @as(f32, @floatFromInt(cell_px)) * 0.5;
    const cy = cx;
    const r_core = cx * core;
    const r_out = r_core + cx * feather;
    var y: u32 = pad_px;
    while (y < cell_px - pad_px) : (y += 1) {
        var x: u32 = pad_px;
        while (x < cell_px - pad_px) : (x += 1) {
            const dx = @as(f32, @floatFromInt(x)) + 0.5 - cx;
            const dy = @as(f32, @floatFromInt(y)) + 0.5 - cy;
            const d = @sqrt(dx * dx + dy * dy);
            const a = if (d <= r_core)
                1.0
            else if (d >= r_out)
                0.0
            else
                1.0 - (d - r_core) / (r_out - r_core);
            setPx(pixels, o.x + x, o.y + y, a * a * (3 - 2 * a));
        }
    }
}

fn paintGlow(pixels: []dvui.Color.PMA, cell: u32) void {
    const o = cellOrigin(cell);
    const cx = @as(f32, @floatFromInt(cell_px)) * 0.5;
    const cy = cx;
    const r_out = cx * 0.96;
    var y: u32 = pad_px;
    while (y < cell_px - pad_px) : (y += 1) {
        var x: u32 = pad_px;
        while (x < cell_px - pad_px) : (x += 1) {
            const dx = @as(f32, @floatFromInt(x)) + 0.5 - cx;
            const dy = @as(f32, @floatFromInt(y)) + 0.5 - cy;
            const d = @sqrt(dx * dx + dy * dy) / r_out;
            const a = if (d >= 1) 0.0 else std.math.pow(f32, 1.0 - d, 2.2);
            setPx(pixels, o.x + x, o.y + y, a);
        }
    }
}

fn paintRing(pixels: []dvui.Color.PMA, cell: u32, outer: f32, width: f32, feather: f32) void {
    const o = cellOrigin(cell);
    const cx = @as(f32, @floatFromInt(cell_px)) * 0.5;
    const cy = cx;
    const r_out = cx * outer;
    const r_in = r_out - cx * width;
    const f = cx * feather;
    var y: u32 = pad_px;
    while (y < cell_px - pad_px) : (y += 1) {
        var x: u32 = pad_px;
        while (x < cell_px - pad_px) : (x += 1) {
            const dx = @as(f32, @floatFromInt(x)) + 0.5 - cx;
            const dy = @as(f32, @floatFromInt(y)) + 0.5 - cy;
            const d = @sqrt(dx * dx + dy * dy);
            var a: f32 = 0;
            if (d >= r_in - f and d <= r_out + f) {
                const outer_a = if (d <= r_out)
                    1.0
                else if (d >= r_out + f)
                    0.0
                else
                    1.0 - (d - r_out) / f;
                const inner_a = if (d >= r_in)
                    1.0
                else if (d <= r_in - f)
                    0.0
                else
                    (d - (r_in - f)) / f;
                a = @min(outer_a, inner_a);
            }
            setPx(pixels, o.x + x, o.y + y, a * a * (3 - 2 * a));
        }
    }
}

/// Dashed ring — same language as the interior document sun, batched as a sprite.
/// `dash_frac` is the filled portion of each dash/gap period (0–1).
fn paintDashRing(
    pixels: []dvui.Color.PMA,
    cell: u32,
    outer: f32,
    width: f32,
    feather: f32,
    dash_count: u32,
    dash_frac: f32,
) void {
    const o = cellOrigin(cell);
    const cx = @as(f32, @floatFromInt(cell_px)) * 0.5;
    const cy = cx;
    const r_out = cx * outer;
    const r_in = r_out - cx * width;
    const f = cx * feather;
    const n_dash: f32 = @floatFromInt(@max(dash_count, 1));
    const fill = std.math.clamp(dash_frac, 0.15, 0.9);
    var y: u32 = pad_px;
    while (y < cell_px - pad_px) : (y += 1) {
        var x: u32 = pad_px;
        while (x < cell_px - pad_px) : (x += 1) {
            const dx = @as(f32, @floatFromInt(x)) + 0.5 - cx;
            const dy = @as(f32, @floatFromInt(y)) + 0.5 - cy;
            const d = @sqrt(dx * dx + dy * dy);
            var a: f32 = 0;
            if (d >= r_in - f and d <= r_out + f) {
                const outer_a = if (d <= r_out)
                    1.0
                else if (d >= r_out + f)
                    0.0
                else
                    1.0 - (d - r_out) / f;
                const inner_a = if (d >= r_in)
                    1.0
                else if (d <= r_in - f)
                    0.0
                else
                    (d - (r_in - f)) / f;
                a = @min(outer_a, inner_a);
                // Angular dash mask with a soft trailing edge so dashes don't stair-step.
                const ang = std.math.atan2(dy, dx); // -π..π
                const u = (ang + std.math.pi) / std.math.tau; // 0..1
                const phase = @mod(u * n_dash, 1.0);
                const edge = 0.08;
                const in_dash = if (phase <= fill)
                    if (phase < fill - edge) @as(f32, 1.0) else 1.0 - (phase - (fill - edge)) / edge
                else
                    0.0;
                a *= in_dash;
            }
            setPx(pixels, o.x + x, o.y + y, a * a * (3 - 2 * a));
        }
    }
}

// -- tests ------------------------------------------------------------------------

const testing = std.testing;

test "atlas cells are non-empty and non-overlapping in alpha mass" {
    var a = try SoftAtlas.init(testing.allocator);
    defer a.deinit(testing.allocator);
    var mass: [cells]u32 = .{0} ** cells;
    for (0..cells) |c| {
        const ox = c * cell_px;
        for (0..cell_px) |y| {
            for (0..cell_px) |x| {
                const p = a.pixels[y * atlas_w + ox + x];
                mass[c] += p.a;
            }
        }
        try testing.expect(mass[c] > 1000);
    }
}

test "uv rects sit inside unit square and do not overlap" {
    var a = try SoftAtlas.init(testing.allocator);
    defer a.deinit(testing.allocator);
    const d = a.uv(.disc);
    const g = a.uv(.glow);
    const r = a.uv(.ring);
    const dr = a.uv(.dash_ring);
    try testing.expect(d.u0 < d.u1 and d.v0 < d.v1);
    try testing.expect(d.u1 <= g.u0 + 1e-4);
    try testing.expect(g.u1 <= r.u0 + 1e-4);
    try testing.expect(r.u1 <= dr.u0 + 1e-4);
    try testing.expect(dr.u1 <= 1.0 + 1e-4);
}

test "dash ring has less alpha mass than solid ring" {
    var a = try SoftAtlas.init(testing.allocator);
    defer a.deinit(testing.allocator);
    var solid: u32 = 0;
    var dashed: u32 = 0;
    const ox_r = @intFromEnum(Kind.ring) * cell_px;
    const ox_d = @intFromEnum(Kind.dash_ring) * cell_px;
    for (0..cell_px) |y| {
        for (0..cell_px) |x| {
            solid += a.pixels[y * atlas_w + ox_r + x].a;
            dashed += a.pixels[y * atlas_w + ox_d + x].a;
        }
    }
    try testing.expect(dashed > 1000);
    try testing.expect(dashed < solid);
}
