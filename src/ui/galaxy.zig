//! Soft-sprite marks: the one visual language the graph draws through.
//!
//! Notes and coalesced masses are both soft-atlas discs, drawn through one stack — every outline,
//! then the web, then every fill — so overlapping marks merge rather than stacking as separate
//! coins. Topology comes from `world.zig`; this file only paints what it decided.

const std = @import("std");
const dvui = @import("dvui");
const batch2d = @import("batch2d");
const Camera = @import("Camera.zig");

pub const SoftAtlas = batch2d.SoftAtlas;
pub const SpriteBatch = batch2d.SpriteBatch;
pub const LineBatch = batch2d.LineBatch;

/// Mix `c` toward `bg` by `t` (1 = `c`, 0 = `bg`) and keep the result opaque.
///
/// Density used to be done by dropping alpha. Overlapping then composites: ten faint orange
/// lines become a bright yellow smear, and 8-bit PMA at low alpha rounds the weaker channels
/// away first so a warm colour goes red. Mixing in the colour itself, fully opaque, means a
/// stack of lines is the same colour as one — a dense web stays a texture, not a glow.
pub fn intoBg(c: dvui.Color, bg: dvui.Color, t: f32) dvui.Color {
    const u = std.math.clamp(t, 0, 1);
    if (u >= 0.996) {
        var out = c;
        out.a = 255;
        return out;
    }
    if (u <= 0.004) {
        var out = bg;
        out.a = 255;
        return out;
    }
    var out = bg.lerp(c, u);
    out.a = 255;
    return out;
}

/// Walk `own` toward `rest` as a mark is absorbed (`alpha` 1 → 0).
///
/// This is not `intoBg`. Mixing a dying note toward the window fill paints an opaque hole
/// over the mass it is joining. The rest colour is the mass's own fill, so the note becomes
/// the mass rather than vanishing in front of it.
pub fn joinFill(own: dvui.Color, rest: dvui.Color, alpha: f32) dvui.Color {
    const a = std.math.clamp(alpha, 0, 1);
    if (a >= 0.996) return own;
    var out = own.lerp(rest, 1 - a);
    out.a = 255;
    return out;
}

/// Rec. 601 luma, integer, so two fills can be compared without a float.
fn luma(c: dvui.Color) u32 {
    return @as(u32, c.r) * 299 + @as(u32, c.g) * 587 + @as(u32, c.b) * 114;
}

/// The lighter of two fills. Notes rest on this so they sit off the panel background
/// whichever of `.content` / `.control` the theme painted brighter.
pub fn lighter(a: dvui.Color, b: dvui.Color) dvui.Color {
    return if (luma(a) >= luma(b)) a else b;
}

/// Marks the overview may draw in a frame. Headroom is deliberate: labels, proximity and the
/// interior all draw on top of this.
pub const plugin_mark_budget: usize = 360;

// ---- Density atlas (soft-sprite bake) ------------------------------------------

/// The soft-sprite atlas the graph draws marks through.
///
/// This used to also own world-tile *density mips* — a far-field underlay baked from leaf
/// positions. They are gone with the rest of the classic path: the bake came from leaf positions
/// while the marks came from agent centroids, so the dissolve always landed on a different
/// configuration.
pub const Density = struct {
    soft: SoftAtlas,
    /// `SoftAtlas` doesn't keep its own allocator, so `deinit` needs the same one back.
    gpa: std.mem.Allocator,

    pub fn init(gpa: std.mem.Allocator) !Density {
        return .{ .soft = try SoftAtlas.init(gpa), .gpa = gpa };
    }

    pub fn deinit(self: *Density) void {
        self.soft.deinit(self.gpa);
    }
};

pub const DrawStats = struct {
    marks: u32 = 0,
    edges: u32 = 0,
};

/// One overview mark ready to paint. Plugin fills per-note theme/hover; harness uses defaults.
pub const StyledMark = struct {
    screen: dvui.Point.Physical,
    r_px: f32,
    fill: dvui.Color,
    border: dvui.Color,
    is_note: bool,
    dying: bool = false,
    /// Vector dashed stroke on the overlay pass. Open notes, the interior sun, a hovered mass.
    ///
    /// Coalesced masses in the field use atlas dash sprites, never this — a screen of polyline
    /// dashes is the 8 fps cliff. This flag is for the handful of marks the reader is dealing
    /// with, drawn last.
    dashed: bool = false,
    /// Redraw after the field (and after the web) so a piled-in fill stays visible.
    on_top: bool = false,
    /// Among overlay marks, this one is under the cursor and paints last of all.
    hover: bool = false,
};

/// Fill quad as a fraction of the ring quad. Notes and masses share this, which is what lets
/// overlapping discs merge into one blob whose outline is still a rim.
///
/// Atlas geometry: disc core is 0.90 of half-size, dash inner is 0.72 of the ring's half-size.
/// 0.80 puts the fill against the inside of the dashes so the ring stays a visible rim.
const fill_of_ring: f32 = 0.80;
/// Radius past which the narrow dash cell keeps the stroke near two screen pixels.
const dash_thin_from: f32 = 24;

/// Atlas rim is dashed for masses and for any mark that overlays dashed (open / hovered mass).
pub fn rimIsDashed(m: StyledMark) bool {
    return !m.is_note or m.dashed;
}

/// Overlay order: non-hover first (smallest on the bottom), hovered last so its fill stays
/// visible in a pile. Used by `prepareStyledMarks`; tested as a function so a sort rewrite
/// cannot silently bury the cursor.
pub fn overlayBefore(a_hover: bool, a_r: f32, b_hover: bool, b_r: f32) bool {
    if (a_hover != b_hover) return !a_hover;
    return a_r < b_r;
}

const MarkItem = struct {
    c: dvui.Point.Physical,
    r: f32,
    face: dvui.Color,
    rim: dvui.Color,
    dashed_rim: bool,
    overlay_dashed: bool,
    hover: bool,
};

/// Culled, coloured marks split into the shared field and the overlay, ready for
/// `drawRims` → (the caller's web) → `drawFills` → `drawOverlay`.
pub const PreparedMarks = struct {
    field: []const MarkItem,
    overlay: []const MarkItem,
    tex: dvui.Texture,
    disc_uv: SoftAtlas.UvRect,
    ring_uv: SoftAtlas.UvRect,
    dash_uv: SoftAtlas.UvRect,
    dash_thin_uv: SoftAtlas.UvRect,
    marks: u32,

    /// Every outline, notes and masses together. Atlas sprites only — never `strokeCircleDashed`.
    /// That path is a ~90-point polyline with each dash its own stroke; a field of large masses
    /// measured out at ~8 fps with a parked camera.
    pub fn drawRims(self: PreparedMarks) void {
        const arena = dvui.currentWindow().arena();
        var sprites = SpriteBatch.init(arena);
        for (self.field) |m| {
            const min_r: f32 = if (m.dashed_rim) 2 else 1.5;
            if (m.r <= min_r) continue;
            sprites.add(.{
                .center = m.c,
                .half_size = m.r,
                .color = m.rim,
                .uv = if (!m.dashed_rim)
                    self.ring_uv
                else if (m.r >= dash_thin_from)
                    self.dash_thin_uv
                else
                    self.dash_uv,
            });
        }
        sprites.flush(self.tex);
    }

    /// Every centre, inset so the rims from `drawRims` survive. Same colour discs overlapping
    /// read as one blob.
    pub fn drawFills(self: PreparedMarks) void {
        const arena = dvui.currentWindow().arena();
        var sprites = SpriteBatch.init(arena);
        for (self.field) |m| {
            sprites.add(.{
                .center = m.c,
                .half_size = m.r * fill_of_ring,
                .color = m.face,
                .uv = self.disc_uv,
            });
        }
        sprites.flush(self.tex);
    }

    /// The handful under the cursor / open, in vector, after every sprite. Hovered last.
    pub fn drawOverlay(self: PreparedMarks) void {
        for (self.overlay) |d| {
            fillCircle(d.c, d.r, d.face);
            const stroke: dvui.Path.StrokeOptions = .{
                .thickness = std.math.clamp(d.r * 0.07, 1.5, 2.5),
                .color = d.rim,
            };
            if (d.overlay_dashed) {
                strokeCircleDashed(d.c, d.r, stroke);
            } else {
                strokeCircle(d.c, d.r, stroke);
            }
        }
    }
};

pub fn prepareStyledMarks(
    soft: *SoftAtlas,
    cam: *const Camera,
    mix: f32,
    marks: []const StyledMark,
) ?PreparedMarks {
    if (mix <= 0.01 or marks.len == 0) return null;
    if (!soft.ensureTexture()) return null;
    const tex = soft.texture() orelse return null;
    const arena = dvui.currentWindow().arena();
    const bg = dvui.themeGet().color(.window, .fill);

    const vp = cam.viewport;
    // Select keeps off-screen siblings alive for LOD stability — do not pay to paint them.
    const pad: f32 = 40;
    const x0 = vp.x - pad;
    const y0 = vp.y - pad;
    const x1 = vp.x + vp.w + pad;
    const y1 = vp.y + vp.h + pad;

    var field: std.ArrayListUnmanaged(MarkItem) = .empty;
    var overlay: std.ArrayListUnmanaged(MarkItem) = .empty;
    var drawn: u32 = 0;

    for (marks) |m| {
        if (m.dying and m.r_px < 0.8) continue;
        const r = @max(m.r_px, 0.6);
        const screen = m.screen;
        if (screen.x + r < x0 or screen.x - r > x1 or screen.y + r < y0 or screen.y - r > y1) continue;

        const dying_t: f32 = if (m.dying) 0.35 else 1;
        const t = mix * dying_t;
        const item: MarkItem = .{
            .c = screen,
            .r = r,
            .face = intoBg(m.fill, bg, t),
            .rim = intoBg(m.border, bg, if (m.dashed) 0.95 * t else if (m.is_note) 0.85 * t else 0.9 * t),
            .dashed_rim = rimIsDashed(m),
            .overlay_dashed = m.dashed,
            .hover = m.hover,
        };
        field.append(arena, item) catch {};
        if (m.on_top) overlay.append(arena, item) catch {};
        drawn += 1;
    }

    const OverlayOrder = struct {
        fn less(_: void, a: MarkItem, b: MarkItem) bool {
            return overlayBefore(a.hover, a.r, b.hover, b.r);
        }
    };
    std.mem.sort(MarkItem, overlay.items, {}, OverlayOrder.less);

    return .{
        .field = field.items,
        .overlay = overlay.items,
        .tex = tex,
        .disc_uv = soft.uv(.disc),
        .ring_uv = soft.uv(.ring),
        .dash_uv = soft.uv(.dash_ring),
        .dash_thin_uv = soft.uv(.dash_ring_thin),
        .marks = drawn,
    };
}

/// Shared soft-sprite stack. Notes and masses use the same three passes: every outline, then
/// (the caller's web, if any), then every fill. Overlapping discs of the same rest colour read
/// as one blob; `on_top` marks are redrawn last so the one under the cursor is not buried.
///
/// `mix` is how far the marks sit off the background (1 = their own colour, 0 = gone), not an
/// alpha. See `intoBg`.
pub fn drawStyledMarks(
    soft: *SoftAtlas,
    cam: *const Camera,
    mix: f32,
    marks: []const StyledMark,
) DrawStats {
    const prepared = prepareStyledMarks(soft, cam, mix, marks) orelse return .{};
    prepared.drawRims();
    prepared.drawFills();
    prepared.drawOverlay();
    return .{ .marks = prepared.marks };
}

/// A crisp filled disc. The soft-atlas sprite has a feathered edge, which is right for a field of
/// thousands and wrong for the one mark the reader is looking straight at.
fn fillCircle(center: dvui.Point.Physical, radius: f32, col: dvui.Color) void {
    if (radius < 1) return;
    const arena = dvui.currentWindow().arena();
    const samples: usize = @max(@as(usize, 32), @as(usize, @intFromFloat(radius * 1.5)));
    const pts = arena.alloc(dvui.Point.Physical, samples) catch return;
    for (pts, 0..) |*pt, i| {
        const a = std.math.tau * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(samples));
        pt.* = .{ .x = center.x + @cos(a) * radius, .y = center.y + @sin(a) * radius };
    }
    const path: dvui.Path = .{ .points = pts };
    path.fillConvex(.{ .color = col });
}

fn strokeCircle(center: dvui.Point.Physical, radius: f32, stroke: dvui.Path.StrokeOptions) void {
    if (radius < 1) return;
    const arena = dvui.currentWindow().arena();
    const samples: usize = @max(@as(usize, 32), @as(usize, @intFromFloat(radius * 1.5)));
    const pts = arena.alloc(dvui.Point.Physical, samples + 1) catch return;
    for (pts[0..samples], 0..) |*pt, i| {
        const a = std.math.tau * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(samples));
        pt.* = .{ .x = center.x + @cos(a) * radius, .y = center.y + @sin(a) * radius };
    }
    pts[samples] = pts[0];
    dvui.Path.stroke(.{ .points = pts }, stroke);
}

/// Same dash recipe as the interior document sun — vector path so large masses stay round.
fn strokeCircleDashed(center: dvui.Point.Physical, radius: f32, stroke: dvui.Path.StrokeOptions) void {
    if (radius < 2) return;
    const arena = dvui.currentWindow().arena();
    const samples: usize = @max(@as(usize, 40), @as(usize, @intFromFloat(radius * 2.0)));
    const pts = arena.alloc(dvui.Point.Physical, samples + 1) catch return;
    var i: usize = 0;
    while (i < samples) : (i += 1) {
        const a = std.math.tau * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(samples));
        pts[i] = .{
            .x = center.x + @cos(a) * radius,
            .y = center.y + @sin(a) * radius,
        };
    }
    pts[samples] = pts[0];

    const dash = std.math.clamp(radius * 0.42, 4, 11);
    const gap = std.math.clamp(radius * 0.26, 3, 7);
    strokePolylineDashed(pts, dash, gap, stroke);
}

fn strokePolylineDashed(
    points: []const dvui.Point.Physical,
    dash_len: f32,
    gap_len: f32,
    stroke: dvui.Path.StrokeOptions,
) void {
    const n = points.len;
    if (n < 2 or dash_len <= 0) return;
    const gap = @max(0.0, gap_len);
    const arena = dvui.currentWindow().arena();
    const cum = arena.alloc(f32, n) catch return;
    cum[0] = 0;
    var i: usize = 1;
    while (i < n) : (i += 1) {
        cum[i] = cum[i - 1] + dvui.Point.Physical.diff(points[i], points[i - 1]).length();
    }
    const total = cum[n - 1];
    if (total < 1e-4) return;

    var buf: std.ArrayList(dvui.Point.Physical) = .empty;
    const edge_eps: f32 = 1e-5;
    var s: f32 = 0;
    while (s < total - edge_eps) {
        const dash_end = @min(s + dash_len, total);
        if (dash_end <= s + edge_eps) break;
        buf.clearRetainingCapacity();
        appendDashedSpan(points, cum, s, dash_end, &buf) catch return;
        if (buf.items.len != 0) {
            dvui.Path.stroke(.{ .points = buf.items }, stroke);
        }
        s = dash_end + gap;
    }
}

fn pointAtArcLength(points: []const dvui.Point.Physical, cum: []const f32, dist: f32) dvui.Point.Physical {
    const n = points.len;
    if (n == 0) return .{};
    if (n == 1 or dist <= 0) return points[0];
    if (dist >= cum[n - 1]) return points[n - 1];
    var seg: usize = 1;
    while (seg < n and cum[seg] < dist) : (seg += 1) {}
    const seg_len = cum[seg] - cum[seg - 1];
    const t = if (seg_len < 1e-6) 0 else (dist - cum[seg - 1]) / seg_len;
    return .{
        .x = points[seg - 1].x + (points[seg].x - points[seg - 1].x) * t,
        .y = points[seg - 1].y + (points[seg].y - points[seg - 1].y) * t,
    };
}

fn appendDashedSpan(
    points: []const dvui.Point.Physical,
    cum: []const f32,
    s0: f32,
    s1: f32,
    out: *std.ArrayList(dvui.Point.Physical),
) !void {
    const arena = dvui.currentWindow().arena();
    const eps: f32 = 1e-4;
    if (s1 <= s0 + eps) return;
    try out.append(arena, pointAtArcLength(points, cum, s0));
    var k: usize = 1;
    while (k < points.len) : (k += 1) {
        const d = cum[k];
        if (d <= s0 + eps) continue;
        if (d >= s1 - eps) break;
        try out.append(arena, points[k]);
    }
    const end_pt = pointAtArcLength(points, cum, s1);
    const last = out.items[out.items.len - 1];
    const dx = end_pt.x - last.x;
    const dy = end_pt.y - last.y;
    if (dx * dx + dy * dy > 1e-8) try out.append(arena, end_pt);
}

test "lighter picks the brighter fill" {
    const dark = dvui.Color{ .r = 20, .g = 20, .b = 24, .a = 255 };
    const pale = dvui.Color{ .r = 40, .g = 42, .b = 48, .a = 255 };
    const got = lighter(dark, pale);
    try std.testing.expectEqual(pale.r, got.r);
    try std.testing.expectEqual(pale.g, got.g);
    try std.testing.expectEqual(pale.b, got.b);
}

test "fill sits inside the rim for notes and masses" {
    // Atlas: disc core is 0.90 of half-size; dash inner is 0.82 − 0.10 = 0.72 of the ring
    // half-size. Raising `fill_of_ring` past this covers the dashes with the fill and the
    // shared stack (rims, then fills) stops showing a rim.
    try std.testing.expect(fill_of_ring * 0.90 <= 0.72 + 0.001);
}

test "masses and open notes use a dashed rim; resting notes do not" {
    const rest_note: StyledMark = .{ .screen = .{}, .r_px = 8, .fill = .{}, .border = .{}, .is_note = true };
    const mass: StyledMark = .{ .screen = .{}, .r_px = 8, .fill = .{}, .border = .{}, .is_note = false };
    const open: StyledMark = .{
        .screen = .{},
        .r_px = 8,
        .fill = .{},
        .border = .{},
        .is_note = true,
        .dashed = true,
        .on_top = true,
    };
    const hover_note: StyledMark = .{
        .screen = .{},
        .r_px = 8,
        .fill = .{},
        .border = .{},
        .is_note = true,
        .on_top = true,
        .hover = true,
    };
    const hover_mass: StyledMark = .{
        .screen = .{},
        .r_px = 8,
        .fill = .{},
        .border = .{},
        .is_note = false,
        .dashed = true,
        .on_top = true,
        .hover = true,
    };
    try std.testing.expect(!rimIsDashed(rest_note));
    try std.testing.expect(rimIsDashed(mass));
    try std.testing.expect(rimIsDashed(open));
    try std.testing.expect(!rimIsDashed(hover_note));
    try std.testing.expect(rimIsDashed(hover_mass));
    try std.testing.expect(hover_note.on_top and hover_note.hover and !hover_note.dashed);
    try std.testing.expect(hover_mass.on_top and hover_mass.dashed);
    try std.testing.expect(open.on_top and !open.hover);
}

test "hovered overlay paints last, even when smaller than an open mark" {
    try std.testing.expect(overlayBefore(false, 40, true, 10));
    try std.testing.expect(overlayBefore(false, 10, false, 40));
    try std.testing.expect(!overlayBefore(true, 10, false, 40));
    try std.testing.expect(overlayBefore(true, 10, true, 40));
}

test "joinFill lands on the mass fill, never the window" {
    const rest = dvui.Color{ .r = 50, .g = 52, .b = 58, .a = 255 };
    const own = dvui.Color{ .r = 240, .g = 160, .b = 40, .a = 255 };
    const bg = dvui.Color{ .r = 12, .g = 12, .b = 16, .a = 255 };
    const gone = joinFill(own, rest, 0);
    try std.testing.expectEqual(rest.r, gone.r);
    try std.testing.expectEqual(rest.g, gone.g);
    try std.testing.expectEqual(rest.b, gone.b);
    try std.testing.expectEqual(@as(u8, 255), gone.a);
    const mid = joinFill(own, rest, 0.5);
    try std.testing.expect(mid.r != bg.r);
    try std.testing.expect(mid.r > rest.r and mid.r < own.r);
    const full = joinFill(own, rest, 1);
    try std.testing.expectEqual(own.r, full.r);
}

test "intoBg stays opaque and never walks through a third hue" {
    const bg = dvui.Color{ .r = 20, .g = 20, .b = 24, .a = 255 };
    const ink = dvui.Color{ .r = 240, .g = 160, .b = 40, .a = 200 };
    const mid = intoBg(ink, bg, 0.5);
    try std.testing.expectEqual(@as(u8, 255), mid.a);
    // Halfway is between ink and bg on every channel, not a more-saturated neighbour.
    try std.testing.expect(mid.r > bg.r and mid.r < ink.r);
    try std.testing.expect(mid.g > bg.g and mid.g < ink.g);
    try std.testing.expect(mid.b > bg.b and mid.b < ink.b);
    const gone = intoBg(ink, bg, 0);
    try std.testing.expectEqual(bg.r, gone.r);
    try std.testing.expectEqual(@as(u8, 255), gone.a);
    const full = intoBg(ink, bg, 1);
    try std.testing.expectEqual(ink.r, full.r);
    try std.testing.expectEqual(@as(u8, 255), full.a);
}
