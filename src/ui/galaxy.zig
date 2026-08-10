//! Galaxy LOD — one visual language of soft sprites + same-language density mips.
//!
//! Live marks (notes / masses) and far-field tiles are both soft-atlas discs. Topology stays
//! discrete (`quadlod.selectSticky`); motion is presentation-only (`quad_agents`). See
//! `docs/design/galaxy-lod.md`.

const std = @import("std");
const dvui = @import("dvui");
const batch2d = @import("batch2d");
const Camera = @import("camera.zig");
const quadlod = @import("quadlod.zig");
const quad_agents = @import("quad_agents.zig");
const impostor = @import("impostor.zig");
const lod = @import("lod.zig");

pub const SoftAtlas = batch2d.SoftAtlas;
pub const SpriteBatch = batch2d.SpriteBatch;
pub const LineBatch = batch2d.LineBatch;
pub const HitIndex = batch2d.HitIndex;

/// Bump when density mark/link bake changes so warm atlases discard the old fog picture.
pub const density_bake_style: u64 = 2;

/// Topology-aware far-field bake: positions + degrees + note edges.
pub const BakeInput = struct {
    live: []const dvui.Point,
    /// Parallel to `live`. Missing / short → treat as degree 1.
    degrees: []const u32 = &.{},
    edge_a: []const u32 = &.{},
    edge_b: []const u32 = &.{},
};

/// Zoom at which density tiles *would* hand off to live agents (world → screen).
/// Kept for bake math / parked path; product overview does not use density mips.
pub const density_switch_zoom: f32 = 0.12;
/// Share of an octave spent cross-fading (dotgrid-style complementary dissolve).
pub const fade_band: f32 = 0.22;
/// Soft mark budget for mid/near living set (harness). 2.8k × multi-sprite was the far/near FPS cliff.
pub const mark_budget: usize = 900;
/// Plugin overview stays tighter so hover stays cheap. Sized for a full gauntlet vault's
/// in-view refine headroom (far off-screen masses no longer consume this 1:1).
pub const plugin_mark_budget: usize = 360;
/// Max lifted web segments drawn per frame.
pub const edge_budget: usize = 360;

/// Density atlas mips are **parked**. Baking leaf positions into tiles and dissolving to
/// sticky agents is a dual-system handoff (blurry upscaled texture → different dot config),
/// the same class of failure as the old impostor path. Overview is sticky agents + lifted
/// edges only; split/join owns the language end-to-end.
pub const density_enabled: bool = false;

pub const TileView = struct {
    /// Primary density octave (0 = handover scale; each step out is coarser).
    primary: i32 = 0,
    /// Weight of density tiles [0,1]. Live weight = 1 - density (complementary).
    density_weight: f32 = 0,
    /// Neighbour octave overlay weight (dissolve-over-full, not 0.5+0.5).
    neighbour: ?struct { level: i32, weight: f32 } = null,
    /// Live agent/note contribution.
    live_weight: f32 = 1,

    pub fn maxDensityWeight(self: TileView) f32 {
        var w = self.density_weight;
        if (self.neighbour) |n| w = @max(w, n.weight);
        return w;
    }
};

/// Octaves out from handover: `out = log2(zs / zoom)`.
pub fn tileViewFor(zoom: f32) TileView {
    if (!density_enabled) {
        return .{ .primary = 0, .density_weight = 0, .live_weight = 1 };
    }
    const zs = density_switch_zoom;
    if (zoom >= zs) {
        return .{ .primary = 0, .density_weight = 0, .live_weight = 1 };
    }
    const out = @log2(@max(zs / @max(zoom, 1e-6), 1e-6));
    if (out < fade_band) {
        // Just past handover: live full; density fades in over it.
        return .{
            .primary = 0,
            .density_weight = out / fade_band,
            .live_weight = 1,
        };
    }
    const primary_f = out;
    const primary: i32 = @intFromFloat(@floor(primary_f));
    const frac = primary_f - @as(f32, @floatFromInt(primary));
    var tv: TileView = .{
        .primary = primary,
        .density_weight = 1,
        .live_weight = 0,
    };
    // Near octave midpoint: keep primary full; neighbour overlays up to 0.5.
    if (frac > 1.0 - fade_band) {
        const t = (frac - (1.0 - fade_band)) / fade_band;
        tv.neighbour = .{ .level = primary + 1, .weight = t * 0.5 };
    } else if (frac < fade_band and primary > 0) {
        const t = 1.0 - frac / fade_band;
        tv.neighbour = .{ .level = primary - 1, .weight = t * 0.5 };
    }
    // Mid band still wants some live masses under tiles for interaction continuity.
    if (out < 1.5) {
        tv.live_weight = std.math.clamp(1.0 - (out - fade_band) / (1.5 - fade_band), 0, 1);
    }
    return tv;
}

pub fn densityTileWorld(level: i32) f32 {
    // Level 0 tiles cover the world at handover scale so they draw ~1:1 on screen.
    const base = @as(f32, @floatFromInt(impostor.tile_px)) / density_switch_zoom;
    return base * std.math.pow(f32, 2, @as(f32, @floatFromInt(level)));
}

// ---- Density atlas (soft-sprite bake) ------------------------------------------

pub const Density = struct {
    atlas: impostor.Atlas = .{},
    hold_level: ?i32 = null,
    hold_epoch: u64 = std.math.maxInt(u64),
    pending: bool = false,
    soft: SoftAtlas,
    gpa: std.mem.Allocator,

    pub fn init(gpa: std.mem.Allocator) !Density {
        return .{
            .gpa = gpa,
            .soft = try SoftAtlas.init(gpa),
        };
    }

    pub fn deinit(self: *Density) void {
        self.atlas.deinit(self.gpa);
        self.soft.deinit(self.gpa);
    }

    pub fn begin(self: *Density, epoch: u64, style: u64) bool {
        if (!self.atlas.begin(epoch, style)) return false;
        if (self.hold_epoch != epoch) {
            self.hold_level = null;
            self.hold_epoch = epoch;
        }
        return self.soft.ensureTexture();
    }

    /// Hard cap on splat marks per tile bake. Dense gauntlet hubs would otherwise turn one
    /// 128² cell into tens of thousands of quads and spike the frame that claimed it.
    pub const max_splat_per_tile: usize = 384;
    /// Link segments baked per tile — the far field's "web", not live lifted edges.
    pub const max_links_per_tile: usize = 180;

    /// Bake missing tiles for `level` covering `view` (world). Budgeted.
    ///
    /// When the atlas is full we **do not** wipe it mid-zoom — that was the dive FPS loop
    /// (clear → bake storm → recover → fill → clear). Hold the last ready level and wait.
    pub fn bakeVisible(
        self: *Density,
        level: i32,
        view: dvui.Rect,
        input: BakeInput,
        bake_budget: usize,
    ) void {
        const soft_tex = self.soft.texture() orelse return;
        const tw = densityTileWorld(level);
        if (tw < 1) return;

        const tx0: i32 = @intFromFloat(@floor(view.x / tw));
        const ty0: i32 = @intFromFloat(@floor(view.y / tw));
        const tx1: i32 = @intFromFloat(@floor((view.x + view.w) / tw));
        const ty1: i32 = @intFromFloat(@floor((view.y + view.h) / tw));

        var baked: usize = 0;
        self.pending = false;
        var ty = ty0;
        while (ty <= ty1) : (ty += 1) {
            var tx = tx0;
            while (tx <= tx1) : (tx += 1) {
                const key: impostor.Key = .{ .level = level, .tx = tx, .ty = ty };
                if (self.atlas.get(key) != null) continue;
                self.pending = true;
                if (baked >= bake_budget) continue;
                const slot = self.atlas.claim(self.gpa, key) orelse {
                    // Full: keep what we have under `hold_level`. Do not clear.
                    break;
                };
                bakeTile(self, soft_tex, key, slot, tw, input);
                baked += 1;
            }
        }
        if (!self.pending) self.hold_level = level;
    }

    fn bakeTile(
        self: *Density,
        soft_tex: dvui.Texture,
        key: impostor.Key,
        slot: u32,
        tw: f32,
        input: BakeInput,
    ) void {
        const pass = impostor.Pass.begin(&self.atlas) orelse return;
        defer pass.end();
        const dst = self.atlas.slotRect(slot);
        pass.clipTo(dst);

        const x0 = @as(f32, @floatFromInt(key.tx)) * tw;
        const y0 = @as(f32, @floatFromInt(key.ty)) * tw;
        const scale = @as(f32, @floatFromInt(impostor.tile_px)) / tw;
        const world: dvui.Rect = .{ .x = x0, .y = y0, .w = tw, .h = tw };

        // Marks first (degree-weighted), web on top — same stack as the old impostor bake.
        bakeMarks(self, soft_tex, dst, world, scale, input);
        bakeLinks(dst, world, scale, input);
    }

    fn bakeMarks(
        self: *Density,
        soft_tex: dvui.Texture,
        dst: dvui.Rect.Physical,
        world: dvui.Rect,
        scale: f32,
        input: BakeInput,
    ) void {
        var batch = SpriteBatch.initAuto(dvui.currentWindow().arena(), soft_tex);
        const uv = self.soft.uv(.disc);
        // Overlap gather so marks near a tile edge land in both neighbours.
        const pad = 2.0 / scale;

        // Two classes: hubs keep structure; leaves fill residual budget. Uniform stride made
        // every island look like the same soft dust cloud.
        var hubs: usize = 0;
        var leaves: usize = 0;
        for (input.live, 0..) |p, i| {
            if (p.x < world.x - pad or p.y < world.y - pad or p.x >= world.x + world.w + pad or p.y >= world.y + world.h + pad)
                continue;
            if (bakeDegree(input, i) >= 3) hubs += 1 else leaves += 1;
        }
        const hub_cap = @min(hubs, (max_splat_per_tile * 2) / 3);
        const leaf_cap = max_splat_per_tile - hub_cap;
        const hub_stride: usize = if (hubs <= hub_cap) 1 else @max(1, hubs / @max(hub_cap, 1));
        const leaf_stride: usize = if (leaves <= leaf_cap) 1 else @max(1, leaves / @max(leaf_cap, 1));

        var seen_h: usize = 0;
        var seen_l: usize = 0;
        var emitted: usize = 0;
        for (input.live, 0..) |p, i| {
            if (p.x < world.x - pad or p.y < world.y - pad or p.x >= world.x + world.w + pad or p.y >= world.y + world.h + pad)
                continue;
            const deg = bakeDegree(input, i);
            const is_hub = deg >= 3;
            if (is_hub) {
                seen_h += 1;
                if ((seen_h - 1) % hub_stride != 0) continue;
            } else {
                seen_l += 1;
                if ((seen_l - 1) % leaf_stride != 0) continue;
            }
            if (emitted >= max_splat_per_tile) break;

            // Orphans stay faint pinpricks; hubs read as brighter cores of the cluster.
            const d = @min(deg, 48);
            const w = @sqrt(@as(f32, @floatFromInt(d + 1)));
            const half_px = 0.65 + 0.7 * @min(w / 5.0, 1.0);
            const alpha = if (deg == 0) @as(f32, 0.22) else 0.4 + 0.5 * @min(w / 5.0, 1.0);
            const sx = dst.x + (p.x - world.x) * scale;
            const sy = dst.y + (p.y - world.y) * scale;
            batch.add(.{
                .center = .{ .x = sx, .y = sy },
                .half_size = half_px,
                .color = dvui.Color.white.opacity(alpha),
                .uv = uv,
            });
            emitted += 1;
        }
        batch.flush(soft_tex);
    }

    fn bakeLinks(
        dst: dvui.Rect.Physical,
        world: dvui.Rect,
        scale: f32,
        input: BakeInput,
    ) void {
        if (input.edge_a.len == 0 or input.edge_a.len != input.edge_b.len) return;
        const n = input.edge_a.len;
        const live = input.live;
        // Stride the vault edge list; long-range spokes still get a chance via the pad.
        const examine = @min(n, max_links_per_tile * 48);
        const stride: usize = @max(1, n / @max(examine, 1));
        const pad = world.w * 0.04;

        var lines = LineBatch.init(dvui.currentWindow().arena());
        var emitted: usize = 0;
        var ei: usize = 0;
        while (ei < n and emitted < max_links_per_tile) : (ei += stride) {
            const ai = input.edge_a[ei];
            const bi = input.edge_b[ei];
            if (ai >= live.len or bi >= live.len) continue;
            const pa = live[ai];
            const pb = live[bi];
            if (!lod.segmentHitsRect(pa, pb, world, pad)) continue;
            // Prefer links that touch a hub — leaf–leaf noise reads as uniform haze.
            const da = bakeDegree(input, ai);
            const db = bakeDegree(input, bi);
            if (da < 2 and db < 2 and emitted > max_links_per_tile / 3) continue;

            const a: dvui.Point.Physical = .{
                .x = dst.x + (pa.x - world.x) * scale,
                .y = dst.y + (pa.y - world.y) * scale,
            };
            const b: dvui.Point.Physical = .{
                .x = dst.x + (pb.x - world.x) * scale,
                .y = dst.y + (pb.y - world.y) * scale,
            };
            const dx = b.x - a.x;
            const dy = b.y - a.y;
            // Skip hairlines that vanish under the marks once the tile is shown.
            if (dx * dx + dy * dy < 9) continue;
            const ink = 0.16 + 0.2 * @min(@sqrt(@as(f32, @floatFromInt(@min(da + db, 32)))) / 6.0, 1.0);
            lines.add(a, b, 1.0, dvui.Color.white.opacity(ink));
            emitted += 1;
        }
        lines.flush();
    }

    pub fn drawLevel(
        self: *Density,
        level: i32,
        view: dvui.Rect,
        cam: *const Camera,
        alpha: f32,
    ) void {
        if (alpha <= 0.01) return;
        const tex = self.atlas.texture() orelse return;
        const arena = dvui.currentWindow().arena();
        var quads = impostor.QuadBatch.init(arena, &self.atlas, tex);
        defer quads.flush();

        const tw = densityTileWorld(level);
        const tx0: i32 = @intFromFloat(@floor(view.x / tw));
        const ty0: i32 = @intFromFloat(@floor(view.y / tw));
        const tx1: i32 = @intFromFloat(@floor((view.x + view.w) / tw));
        const ty1: i32 = @intFromFloat(@floor((view.y + view.h) / tw));

        var ty = ty0;
        while (ty <= ty1) : (ty += 1) {
            var tx = tx0;
            while (tx <= tx1) : (tx += 1) {
                const key: impostor.Key = .{ .level = level, .tx = tx, .ty = ty };
                const slot = self.atlas.get(key) orelse continue;
                const x0 = @as(f32, @floatFromInt(tx)) * tw;
                const y0 = @as(f32, @floatFromInt(ty)) * tw;
                const tl = cam.worldToScreen(.{ .x = x0, .y = y0 });
                const br = cam.worldToScreen(.{ .x = x0 + tw, .y = y0 + tw });
                // Slight screen overlap so float gaps between abutting tiles don't hairline.
                const x = @min(tl.x, br.x) - 0.5;
                const y = @min(tl.y, br.y) - 0.5;
                const w = @abs(br.x - tl.x) + 1.0;
                const h = @abs(br.y - tl.y) + 1.0;
                quads.add(self.atlas.slotRect(slot), .{ .x = x, .y = y, .w = w, .h = h }, alpha);
            }
        }
    }
};

fn bakeDegree(input: BakeInput, i: usize) u32 {
    if (i >= input.degrees.len) return 1;
    return input.degrees[i];
}

// ---- Live agent / note draw ----------------------------------------------------

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

    for (marks) |m| {
        if (m.dying and m.r_px < 0.8) continue;
        const r = @max(m.r_px, 0.6);
        const screen = m.screen;
        if (screen.x + r < x0 or screen.x - r > x1 or screen.y + r < y0 or screen.y - r > y1) continue;

        const dying_a: f32 = if (m.dying) 0.35 else 1;
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
            if (r >= 14) {
                vector_dashes.append(arena, .{ .c = screen, .r = r, .col = rim }) catch {};
            } else if (r > 2) {
                sprites.add(.{
                    .center = screen,
                    .half_size = r,
                    .color = rim,
                    .uv = dash_uv,
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
    return stats;
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

pub fn drawAgents(
    soft: *SoftAtlas,
    field: *const quad_agents.Field,
    cam: *const Camera,
    fill: dvui.Color,
    border: dvui.Color,
    alpha: f32,
) DrawStats {
    if (alpha <= 0.01) return .{};
    const arena = dvui.currentWindow().arena();
    const buf = arena.alloc(StyledMark, field.agents.items.len) catch return .{};
    var n: usize = 0;
    for (field.agents.items) |a| {
        if (a.dying and a.r_px < 0.8) continue;
        const is_note = a.count <= 1;
        const r = if (is_note)
            @min(@max(a.r_px, 0.6), 48)
        else
            @min(@max(a.r_px, 2.5), 36) * (0.85 + 0.2 * @min(@log2(@as(f32, @floatFromInt(@min(a.count, 256))) + 1) / 6.0, 1));
        buf[n] = .{
            .screen = cam.worldToScreen(a.pos),
            .r_px = r,
            .fill = if (is_note) fill else border,
            .border = border,
            .is_note = is_note,
            .dying = a.dying,
        };
        n += 1;
    }
    return drawStyledMarks(soft, cam, alpha, buf[0..n]);
}

pub fn drawLiftedEdges(
    edges: []const quadlod.LiftedEdge,
    cam: *const Camera,
    color: dvui.Color,
    alpha: f32,
) u32 {
    if (alpha <= 0.01 or edges.len == 0) return 0;
    const arena = dvui.currentWindow().arena();
    var lines = LineBatch.init(arena);
    defer lines.flush();
    var n: u32 = 0;
    for (edges) |link| {
        const a = cam.worldToScreen(link.from);
        const b = cam.worldToScreen(link.to);
        const dx = b.x - a.x;
        const dy = b.y - a.y;
        const len = @sqrt(dx * dx + dy * dy);
        // Overview masses sit closer on screen — a 14px floor erased most of the web.
        const fade = std.math.clamp((len - 4) / 10, 0, 1) * alpha;
        if (fade <= 0.02) continue;
        lines.add(a, b, 1.35, color.opacity(fade));
        n += 1;
    }
    return n;
}

// -- tests ------------------------------------------------------------------------

const testing = std.testing;

test "tileViewFor: live owns the field when density parked" {
    try testing.expect(!density_enabled);
    const near = tileViewFor(density_switch_zoom * 2);
    try testing.expectEqual(@as(f32, 1), near.live_weight);
    try testing.expectEqual(@as(f32, 0), near.density_weight);
    const far = tileViewFor(density_switch_zoom * 0.05);
    try testing.expectEqual(@as(f32, 1), far.live_weight);
    try testing.expectEqual(@as(f32, 0), far.density_weight);
}

test "densityTileWorld doubles each octave" {
    try testing.expectApproxEqAbs(densityTileWorld(1), densityTileWorld(0) * 2, 1e-3);
}
