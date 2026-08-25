//! Soft-sprite marks: the one visual language the graph draws through.
//!
//! Notes and coalesced masses are both soft-atlas discs, so there is a single mark language at
//! every zoom and no dual-system handoff to pop. Topology comes from `world.zig`; this file only
//! paints what it decided.

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
    /// Draw this mark as a dashed rim over a *fully opaque* face, in vector rather than sprites,
    /// after every other mark.
    ///
    /// Only for the handful of marks the reader is actually dealing with — an open note, the
    /// interior sun. Coalesced masses never take this path: a screen of polyline dashes is the
    /// 8 fps cliff. Their rings are atlas sprites, always.
    dashed: bool = false,
};

/// Mass fill quad as a fraction of the ring quad.
///
/// Atlas geometry: disc core is 0.90 of half-size, dash inner is 0.72 of the ring's half-size.
/// 0.80 puts the fill against the inside of the dashes so the ring stays a visible rim, and so
/// merging notes occupy that rim (drawn after the ring, before the fill) rather than sitting
/// on top of the fill in the centre.
const mass_fill_of_ring: f32 = 0.80;
/// Radius past which the narrow dash cell keeps the stroke near two screen pixels.
const dash_thin_from: f32 = 24;

/// Shared soft-sprite stack (frustum cull + cheap dense path). Used by harness and plugin.
///
/// Coalesced masses are two passes around the notes: dashed rings, then notes, then fills.
/// A merging note covers the ring as it crosses the boundary and disappears under the fill
/// as it reaches the centre — which is why note borders used to remain visible in the middle
/// of a mass. Vector dashed strokes are reserved for `StyledMark.dashed` (open / selected).
///
/// `mix` is how far the marks sit off the background (1 = their own colour, 0 = gone), not an
/// alpha. See `intoBg`.
pub fn drawStyledMarks(
    soft: *SoftAtlas,
    cam: *const Camera,
    mix: f32,
    marks: []const StyledMark,
) DrawStats {
    if (mix <= 0.01 or marks.len == 0) return .{};
    if (!soft.ensureTexture()) return .{};
    const tex = soft.texture() orelse return .{};
    const arena = dvui.currentWindow().arena();
    const bg = dvui.themeGet().color(.window, .fill);

    var stats: DrawStats = .{};
    const disc_uv = soft.uv(.disc);
    const glow_uv = soft.uv(.glow);
    const ring_uv = soft.uv(.ring);
    const dash_uv = soft.uv(.dash_ring);
    const dash_thin_uv = soft.uv(.dash_ring_thin);
    const vp = cam.viewport;
    // Select keeps off-screen siblings alive for LOD stability — do not pay to paint them.
    const pad: f32 = 40;
    const x0 = vp.x - pad;
    const y0 = vp.y - pad;
    const x1 = vp.x + vp.w + pad;
    const y1 = vp.y + vp.h + pad;
    const cheap = marks.len > 420;

    const Item = struct {
        c: dvui.Point.Physical,
        r: f32,
        face: dvui.Color,
        rim: dvui.Color,
    };
    var masses: std.ArrayListUnmanaged(Item) = .empty;
    var notes: std.ArrayListUnmanaged(Item) = .empty;
    var dashed_marks: std.ArrayListUnmanaged(Item) = .empty;

    for (marks) |m| {
        if (m.dying and m.r_px < 0.8) continue;
        const r = @max(m.r_px, 0.6);
        const screen = m.screen;
        if (screen.x + r < x0 or screen.x - r > x1 or screen.y + r < y0 or screen.y - r > y1) continue;

        const dying_t: f32 = if (m.dying) 0.35 else 1;
        const t = mix * dying_t;
        const item: Item = .{
            .c = screen,
            .r = r,
            .face = intoBg(m.fill, bg, t),
            .rim = intoBg(m.border, bg, if (m.dashed) 0.95 * t else if (m.is_note) 0.85 * t else 0.9 * t),
        };
        if (m.dashed) {
            dashed_marks.append(arena, item) catch {};
        } else if (m.is_note) {
            notes.append(arena, item) catch {};
        } else {
            masses.append(arena, item) catch {};
        }
        stats.marks += 1;
    }

    var sprites = SpriteBatch.init(arena);

    // 1. Mass rings. Atlas sprites only — never `strokeCircleDashed`. That path is a ~90-point
    // polyline with each dash its own stroke; a field of large masses measured out at ~8 fps
    // with a parked camera. The switch used to fire at r ≥ 14 whenever the mark count was
    // under 420, which is exactly the zoom where masses get big and there are not yet hundreds
    // of them.
    for (masses.items) |m| {
        if (m.r <= 2) continue;
        sprites.add(.{
            .center = m.c,
            .half_size = m.r,
            .color = m.rim,
            .uv = if (m.r >= dash_thin_from) dash_thin_uv else dash_uv,
        });
    }
    sprites.flush(tex);

    // 2. Notes, over the rings so a joining disc covers the dashes as it crosses the boundary.
    for (notes.items) |n| {
        if (!cheap and n.r > 3) {
            sprites.add(.{
                .center = .{ .x = n.c.x + 0.8, .y = n.c.y + 1.0 },
                .half_size = n.r * 1.08,
                .color = dvui.Color.black.opacity(0.16 * mix),
                .uv = glow_uv,
            });
        }
        sprites.add(.{
            .center = n.c,
            .half_size = n.r,
            .color = n.face,
            .uv = disc_uv,
        });
        if (n.r > 1.5) {
            sprites.add(.{
                .center = n.c,
                .half_size = n.r,
                .color = n.rim,
                .uv = ring_uv,
            });
        }
    }
    sprites.flush(tex);

    // 3. Mass fills, over the notes. A note that has reached the centre is hidden; one still
    // on the ring is not. Inset so the dashes from pass 1 remain a rim rather than being
    // covered by a disc that is larger than they are.
    for (masses.items) |m| {
        sprites.add(.{
            .center = m.c,
            .half_size = m.r * mass_fill_of_ring,
            .color = m.face,
            .uv = disc_uv,
        });
    }
    sprites.flush(tex);

    // Last of all, over every sprite. Smallest first, so the largest — the one under the cursor —
    // ends up on top rather than under whichever of the others the mark list happened to emit
    // later. Vector dashes belong here and only here.
    const BySize = struct {
        fn less(_: void, x: Item, y: Item) bool {
            return x.r < y.r;
        }
    };
    std.mem.sort(Item, dashed_marks.items, {}, BySize.less);
    for (dashed_marks.items) |d| {
        fillCircle(d.c, d.r, d.face);
        strokeCircleDashed(d.c, d.r, .{
            .thickness = std.math.clamp(d.r * 0.07, 1.5, 2.5),
            .color = d.rim,
        });
    }
    return stats;
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

test "mass fill sits inside the dashed rim" {
    // Atlas: disc core is 0.90 of half-size; dash inner is 0.82 − 0.10 = 0.72 of the ring
    // half-size. Raising `mass_fill_of_ring` past this covers the dashes with the fill and
    // the sandwich (ring, notes, fill) stops showing a rim.
    try std.testing.expect(mass_fill_of_ring * 0.90 <= 0.72 + 0.001);
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
