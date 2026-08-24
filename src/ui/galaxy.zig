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
    /// For the handful of marks the reader is actually dealing with — the note under the cursor,
    /// the notes they have open. A coalesced mass uses a dashed rim too but keeps its face at 0.28
    /// so the web reads through it: a mass is a container you are looking *into*. These are the
    /// opposite, and have to occlude the hairball behind them or the thing being announced stays
    /// unreadable.
    dashed: bool = false,
};

/// Shared soft-sprite stack (frustum cull + cheap dense path). Used by harness and plugin.
/// Coalesced masses use a lighter fill + dashed ring (same language as the interior sun).
pub fn drawStyledMarks(
    soft: *SoftAtlas,
    cam: *const Camera,
    alpha: f32,
    marks: []const StyledMark,
) DrawStats {
    if (alpha <= 0.01 or marks.len == 0) return .{};
    if (!soft.ensureTexture()) return .{};
    const tex = soft.texture() orelse return .{};
    const arena = dvui.currentWindow().arena();

    var sprites = SpriteBatch.init(arena);

    var stats: DrawStats = .{};
    const disc_uv = soft.uv(.disc);
    const glow_uv = soft.uv(.glow);
    const ring_uv = soft.uv(.ring);
    const dash_uv = soft.uv(.dash_ring);
    const dash_thin_uv = soft.uv(.dash_ring_thin);
    // Radius past which the narrow dash cell keeps the stroke near two screen pixels. A sprite's
    // stroke scales with the quad, so one cell cannot serve the whole mass radius range.
    const dash_thin_from: f32 = 24;
    const vp = cam.viewport;
    // Select keeps off-screen siblings alive for LOD stability — do not pay to paint them.
    const pad: f32 = 40;
    const x0 = vp.x - pad;
    const y0 = vp.y - pad;
    const x1 = vp.x + vp.w + pad;
    const y1 = vp.y + vp.h + pad;
    const cheap = marks.len > 420;

    // Large masses get a vector dashed stroke after the sprite flush — atlas dashes stay cheap
    // for small marks; path strokes stay round when the mark is big on screen.
    const Dash = struct { c: dvui.Point.Physical, r: f32, col: dvui.Color };
    var vector_dashes: std.ArrayListUnmanaged(Dash) = .empty;
    const Dashed = struct { c: dvui.Point.Physical, r: f32, face: dvui.Color, rim: dvui.Color };
    var dashed_marks: std.ArrayListUnmanaged(Dashed) = .empty;

    for (marks) |m| {
        if (m.dying and m.r_px < 0.8) continue;
        const r = @max(m.r_px, 0.6);
        const screen = m.screen;
        if (screen.x + r < x0 or screen.x - r > x1 or screen.y + r < y0 or screen.y - r > y1) continue;

        const dying_a: f32 = if (m.dying) 0.35 else 1;
        if (m.dashed) {
            // Drawn the expensive way, and it looks it: a crisp filled circle and a vector dashed
            // rim, no atlas sprite. The standing rejection of path-stroked dashed rings is about
            // *thousands* of masses — 4,000 measured at ~8 fps — and says nothing about the two or
            // three marks the reader is actually dealing with. The sprite's feathered edge is
            // obvious on a mark you are looking straight at, and its glow pass reads as a second
            // ring around the first.
            dashed_marks.append(arena, .{
                .c = screen,
                .r = r,
                .face = m.fill.opacity(alpha * dying_a),
                .rim = m.border.opacity(0.95 * alpha * dying_a),
            }) catch {};
            stats.marks += 1;
            continue;
        }
        if (m.is_note) {
            const face = m.fill.opacity(alpha * dying_a);
            if (!cheap and r > 3) {
                sprites.add(.{
                    .center = .{ .x = screen.x + 0.8, .y = screen.y + 1.0 },
                    .half_size = r * 1.08,
                    .color = dvui.Color.black.opacity(0.16 * alpha),
                    .uv = glow_uv,
                });
            }
            sprites.add(.{
                .center = screen,
                .half_size = r,
                .color = face,
                .uv = disc_uv,
            });
            if (r > 1.5) {
                sprites.add(.{
                    .center = screen,
                    .half_size = r,
                    .color = m.border.opacity(0.85 * alpha * dying_a),
                    .uv = ring_uv,
                });
            }
        } else {
            // Mass: soft disc at low opacity so the dashed rim carries the shape (sun idiom).
            const face = m.fill.opacity(alpha * 0.28 * dying_a);
            if (!cheap and r > 4) {
                sprites.add(.{
                    .center = screen,
                    .half_size = r * 1.15,
                    .color = m.fill.opacity(0.12 * alpha * dying_a),
                    .uv = glow_uv,
                });
            }
            sprites.add(.{
                .center = screen,
                .half_size = r,
                .color = face,
                .uv = disc_uv,
            });
            const rim = m.border.opacity(0.9 * alpha * dying_a);
            // `!cheap` is load-bearing, not a nicety.
            //
            // The vector path allocates a ~90-point polyline per ring and strokes each dash as its
            // own path, so a screen full of large masses is tens of thousands of path strokes a
            // frame — 4,000 masses at a 4,000 mark budget measured out at ~8 fps with a *parked*
            // camera. This is the "path-stroked dashed rings at scale" cliff the design notes
            // already list as rejected; it survived here because `cheap` gated the shadow and the
            // glow but never this.
            //
            // Above the threshold the atlas dash sprite carries every mass instead: one batched
            // quad each, no draw call of its own. It is slightly softer on a very large ring, which
            // is a trade worth making the moment there are hundreds of them — nobody is examining
            // the roundness of one rim in a field of four thousand.
            if (r >= 14 and !cheap) {
                vector_dashes.append(arena, .{ .c = screen, .r = r, .col = rim }) catch {};
            } else if (r > 2) {
                sprites.add(.{
                    .center = screen,
                    .half_size = r,
                    .color = rim,
                    .uv = if (r >= dash_thin_from) dash_thin_uv else dash_uv,
                });
            }
        }
        stats.marks += 1;
    }
    sprites.flush(tex);

    for (vector_dashes.items) |d| {
        strokeCircleDashed(d.c, d.r, .{
            .thickness = std.math.clamp(d.r * 0.08, 1.25, 2.25),
            .color = d.col,
        });
    }
    // Last of all, over every sprite. Smallest first, so the largest — the one under the cursor —
    // ends up on top rather than under whichever of the others the mark list happened to emit
    // later.
    const BySize = struct {
        fn less(_: void, x: Dashed, y: Dashed) bool {
            return x.r < y.r;
        }
    };
    std.mem.sort(Dashed, dashed_marks.items, {}, BySize.less);
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
