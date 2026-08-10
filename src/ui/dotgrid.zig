//! Batched hex dot-grid background for the graph panel.
//!
//! Every visible dot goes into one `dvui.Triangles` batch and is handed to `renderTriangles`
//! in a handful of draw calls, rather than one `Path.stroke` per dot (a single-point path
//! *does* render as a dot, but that is a triangulate + draw call each — thousands per frame).
//!
//! **Level of detail.** The lattice in `hex.zig` nests on powers of two, so a level-`L` dot
//! is also a dot at every finer level. We pick the coarsest level whose on-screen spacing is
//! still at least `target_spacing`, draw it opaque, and fade in the *extra* points of the
//! next finer level as the zoom approaches the point where that level takes over. At the
//! handover the fade is exactly 1 and the two descriptions render identically, so dots never
//! pop — they only ever gain neighbours.
const std = @import("std");
const dvui = @import("dvui");

const hex = @import("hex.zig");
const Camera = @import("camera.zig");

/// Desired on-screen distance between the opaque dots, in natural (unscaled) pixels.
const target_spacing: f32 = hex.target_screen_spacing;
/// Radius of the opaque core of a fully-faded-in dot, in natural pixels. Hairline — just
/// enough solid centre that a feathered rim still reads as a point rather than a smudge.
const dot_radius: f32 = 0.35;
/// Anti-aliasing skirt outside the core, in natural pixels. Dominates the visual size; keep
/// it short so the whole blob stays near one device pixel.
const dot_feather: f32 = 0.55;
/// Faded-in dots also grow from a fraction of full size, so a level arrives as a soft bloom.
const dot_radius_floor: f32 = 0.4;
/// Below this the sub-level is not worth iterating; walk the coarse lattice directly.
const fade_epsilon: f32 = 0.02;
/// Sanity valve. LOD already bounds the count; this only matters if a caller hands us a
/// degenerate camera (zoom ~0 with a huge viewport).
const max_dots: usize = 60_000;

/// A dot is a hexagon: centre, an opaque ring at the core radius, and a transparent ring a
/// feather further out. Six segments is plenty at these radii and keeps the buffers small.
const ring = 6;
const verts_per_dot = 1 + ring * 2;
/// Core fan (`ring` triangles) plus the feather skirt (two per segment).
const idx_per_dot = ring * 3 + ring * 6;
/// Flush at this many vertices. `Vertex.Index` may be `u16`, so a batch must stay under
/// 65536; sized generously so a full-width panel is a handful of draw calls, not dozens.
const batch_verts: usize = 32768;

const unit_ring: [ring][2]f32 = blk: {
    @setEvalBranchQuota(4000);
    var out: [ring][2]f32 = undefined;
    for (0..ring) |i| {
        // Start at -90° so the ring is flat-top, matching the pointy-top lattice it sits on.
        const a = std.math.tau * @as(f32, @floatFromInt(i)) / ring - std.math.pi * 0.5;
        out[i] = .{ @cos(a), @sin(a) };
    }
    break :blk out;
};

/// Draw the grid under `cam`'s viewport. `color` is the fully-opaque dot colour (alpha
/// included); per-level fading multiplies into it.
pub fn draw(cam: *const Camera, color: dvui.Color) void {
    const vp = cam.viewport;
    if (vp.w < 4 or vp.h < 4) return;
    const zoom = cam.zoom;
    if (!std.math.isFinite(zoom) or zoom <= 0) return;

    const scale = dvui.currentWindow().natural_scale;
    const target_px = target_spacing * scale;

    // Real-valued level whose spacing is exactly `target_px` on screen. Levels at or above it
    // are "spacious enough"; `ceil` is the coarsest we must draw opaque.
    const f = std.math.log2(target_px / (hex.spacing * zoom));
    if (!std.math.isFinite(f)) return;
    const level: i32 = @intFromFloat(@ceil(f));
    const fade = @as(f32, @floatFromInt(level)) - f; // 0 → 1 as the finer level arrives

    const sub = fade >= fade_epsilon;
    // When the sub-level is invisible, walk the coarse lattice so we don't index four times
    // as many points just to skip three quarters of them.
    const draw_level = if (sub) level - 1 else level;
    const s = hex.levelSpacing(draw_level);
    const row_h = s * hex.row_ratio;
    if (!(s > 0) or !(row_h > 0)) return;

    // World-space AABB of the viewport (camera has no rotation, so corners suffice).
    const w0 = cam.screenToWorld(.{ .x = vp.x, .y = vp.y });
    const w1 = cam.screenToWorld(.{ .x = vp.x + vp.w, .y = vp.y + vp.h });
    const r_full = dot_radius * scale;
    const feather = dot_feather * scale;
    // Pad by a dot so half-dots at the edge still draw (they get clipped, not popped).
    const pad = (r_full + feather) / zoom + 1;

    const j0f = @floor((w0.y - pad) / row_h);
    const j1f = @ceil((w1.y + pad) / row_h);
    if (!std.math.isFinite(j0f) or !std.math.isFinite(j1f)) return;
    const rows = j1f - j0f + 1;
    const cols = (w1.x - w0.x + 2 * pad) / s + 2;
    if (!(rows > 0) or !(cols > 0) or rows * cols > @as(f32, max_dots)) return;

    const row_lo: i32 = @intFromFloat(j0f);
    const row_hi: i32 = @intFromFloat(j1f);

    const batch = &scratch;
    batch.reset();
    defer batch.flush();

    const fine_alpha = if (sub) fade else 0;
    const fine_r = r_full * (dot_radius_floor + (1 - dot_radius_floor) * fade);

    var j = row_lo;
    while (j <= row_hi) : (j += 1) {
        const jf: f32 = @floatFromInt(j);
        const y = jf * row_h;
        const row_x = jf * 0.5 * s; // odd rows are offset by half a spacing
        const col_lo: i32 = @intFromFloat(@floor((w0.x - pad - row_x) / s));
        const col_hi: i32 = @intFromFloat(@ceil((w1.x + pad - row_x) / s));
        var i = col_lo;
        while (i <= col_hi) : (i += 1) {
            // A point of `draw_level` is also a point of the coarser level exactly when both
            // indices are even — the coarse basis is twice the fine one.
            const coarse = !sub or (@rem(i, 2) == 0 and @rem(j, 2) == 0);
            const a: f32 = if (coarse) 1 else fine_alpha;
            if (a <= 0.004) continue;
            const r = if (coarse) r_full else fine_r;
            const p = cam.worldToScreen(.{ .x = @as(f32, @floatFromInt(i)) * s + row_x, .y = y });
            batch.dot(p, r, feather, color.opacity(a));
        }
    }
}

/// One frame's scratch geometry. A quarter-megabyte of buffers has no business on the draw
/// stack, and UI drawing is single-threaded, so the batch lives here and is reset per call.
var scratch: Batch = .{};

/// Accumulates dot geometry, flushing whenever the vertex budget would overflow the index
/// type. Each dot is a soft radial blob: an opaque centre fanned out to a transparent ring.
const Batch = struct {
    verts: [batch_verts]dvui.Vertex = undefined,
    idx: [batch_verts / verts_per_dot * idx_per_dot]dvui.Vertex.Index = undefined,
    n_verts: usize = 0,
    n_idx: usize = 0,
    bounds_min: dvui.Point.Physical = .{ .x = std.math.floatMax(f32), .y = std.math.floatMax(f32) },
    bounds_max: dvui.Point.Physical = .{ .x = -std.math.floatMax(f32), .y = -std.math.floatMax(f32) },

    fn reset(self: *Batch) void {
        self.n_verts = 0;
        self.n_idx = 0;
        self.bounds_min = .{ .x = std.math.floatMax(f32), .y = std.math.floatMax(f32) };
        self.bounds_max = .{ .x = -std.math.floatMax(f32), .y = -std.math.floatMax(f32) };
    }

    /// `r` is the opaque core radius; `feather` is the transparent skirt outside it.
    fn dot(self: *Batch, p: dvui.Point.Physical, r: f32, feather: f32, col: dvui.Color) void {
        if (self.n_verts + verts_per_dot > self.verts.len) self.flush();

        const solid: dvui.Color.PMA = .fromColor(col);
        const clear: dvui.Color.PMA = .fromColor(col.opacity(0));
        const base: dvui.Vertex.Index = @intCast(self.n_verts);
        const outer = r + feather;

        self.verts[self.n_verts] = .{ .pos = p, .col = solid };
        self.n_verts += 1;
        // Inner ring first, then the outer ring, so index arithmetic below stays simple:
        // core[k] = base+1+k, skirt[k] = base+1+ring+k.
        for (unit_ring) |u| {
            self.verts[self.n_verts] = .{
                .pos = .{ .x = p.x + u[0] * r, .y = p.y + u[1] * r },
                .col = solid,
            };
            self.n_verts += 1;
        }
        for (unit_ring) |u| {
            self.verts[self.n_verts] = .{
                .pos = .{ .x = p.x + u[0] * outer, .y = p.y + u[1] * outer },
                .col = clear,
            };
            self.n_verts += 1;
        }

        for (0..ring) |k| {
            const k1 = (k + 1) % ring;
            const a0 = base + 1 + @as(dvui.Vertex.Index, @intCast(k));
            const a1 = base + 1 + @as(dvui.Vertex.Index, @intCast(k1));
            const b0 = a0 + ring;
            const b1 = a1 + ring;
            // Wound the same way dvui's own convex fill does — counter-clockwise with y
            // going down — or the backend's backface culling eats them.
            self.idx[self.n_idx + 0] = base;
            self.idx[self.n_idx + 1] = a1;
            self.idx[self.n_idx + 2] = a0;
            self.idx[self.n_idx + 3] = a1;
            self.idx[self.n_idx + 4] = b1;
            self.idx[self.n_idx + 5] = a0;
            self.idx[self.n_idx + 6] = b1;
            self.idx[self.n_idx + 7] = b0;
            self.idx[self.n_idx + 8] = a0;
            self.n_idx += 9;
        }

        self.bounds_min.x = @min(self.bounds_min.x, p.x - outer);
        self.bounds_min.y = @min(self.bounds_min.y, p.y - outer);
        self.bounds_max.x = @max(self.bounds_max.x, p.x + outer);
        self.bounds_max.y = @max(self.bounds_max.y, p.y + outer);
    }

    fn flush(self: *Batch) void {
        if (self.n_verts == 0) return;
        const tri: dvui.Triangles = .{
            .vertexes = self.verts[0..self.n_verts],
            .indices = self.idx[0..self.n_idx],
            .bounds = .{
                .x = self.bounds_min.x,
                .y = self.bounds_min.y,
                .w = self.bounds_max.x - self.bounds_min.x,
                .h = self.bounds_max.y - self.bounds_min.y,
            },
        };
        dvui.renderTriangles(tri, null) catch |err| {
            dvui.log.err("atlas: dot grid renderTriangles: {any}", .{err});
        };
        self.reset();
    }
};

// -- tests ------------------------------------------------------------------------

const testing = std.testing;

fn lodAt(zoom: f32) struct { level: i32, fade: f32 } {
    const v = std.math.log2(hex.target_screen_spacing / (hex.spacing * zoom));
    const l: i32 = @intFromFloat(@ceil(v));
    return .{ .level = l, .fade = @as(f32, @floatFromInt(l)) - v };
}

test "level handover is continuous" {
    // At the zoom where a level takes over, `fade` must reach 1 just as `level` steps down —
    // otherwise dots would pop instead of bloom.
    var prev = lodAt(0.05);
    var z: f32 = 0.05;
    while (z < 5.0) : (z *= 1.01) {
        const cur = lodAt(z);
        try testing.expect(cur.fade >= -1e-4 and cur.fade <= 1.0 + 1e-4);
        if (cur.level != prev.level) {
            try testing.expectEqual(prev.level - 1, cur.level);
            try testing.expect(prev.fade > 0.98);
            try testing.expect(cur.fade < 0.02);
        }
        prev = cur;
    }
}

test "camera max_zoom is a clean LOD boundary" {
    // The whole point of tying max_zoom to `hex.cleanZoom`: at the stop, fade must be 0 so
    // we aren't rendering a half-arrived finer grid on top of the previous one.
    const at_max = lodAt(Camera.max_zoom);
    try testing.expectEqual(hex.max_zoom_level, at_max.level);
    try testing.expectApproxEqAbs(@as(f32, 0), at_max.fade, 1e-5);
}

test "index buffer is sized for the vertex budget" {
    // The batch is a quarter-megabyte; reuse the file-scope one rather than a stack copy.
    const b = &scratch;
    b.reset();
    const cap_dots = batch_verts / verts_per_dot;
    for (0..cap_dots) |k| {
        const f: f32 = @floatFromInt(k);
        b.dot(.{ .x = f, .y = f }, 1, 1, dvui.Color.white);
    }
    try testing.expectEqual(cap_dots * verts_per_dot, b.n_verts);
    try testing.expectEqual(cap_dots * idx_per_dot, b.n_idx);
    // Every index must be addressable by the backend's index type.
    for (b.idx[0..b.n_idx]) |i| try testing.expect(i < b.n_verts);
    b.n_verts = 0;
    b.n_idx = 0;
}
