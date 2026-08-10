//! Shared synth + draw context for Atlas render benches (headless CPU and plain-SDL3 GPU).
//!
//! Island-shaped vault: log-uniform components of 5‥10k with intra-only links, plus orphans.
//! Islands themselves are Vogel/sunflower discs (not hex rectangles) so cloud LOD reads as
//! organic silhouettes; inter-island packing still uses the elliptical pack used by
//! `layout_full.packComponents`. DrawCtx mirrors `graph.bubbleScreenRadius` + hover.

const std = @import("std");
const dvui = @import("dvui");
const hex = @import("hex.zig");

pub const base_screen_r: f32 = 9;
pub const open_screen_r: f32 = 12;
pub const max_node_screen_r: f32 = 48;
pub const grow_factor: f32 = 1.0;
pub const zoom_rest_swell: f32 = 0.35;
pub const gap_radius_frac: f32 = 0.42;
pub const batch_max_r: f32 = 9.0;
pub const node_border_px: f32 = 1.25;
pub const shadow_min_r: f32 = 6.0;
pub const shadow_offset: f32 = 1.5;
pub const proximity_falloff_px: f32 = 100;
pub const proximity_falloff_zoom_boost: f32 = 1.75;
pub const detail_gap_lo: f32 = 34;
pub const detail_gap_hi: f32 = 64;
pub const open_frac: f32 = 0.002;

const golden_angle: f32 = std.math.pi * (3.0 - @sqrt(5.0));
const component_gap_slots: f32 = 1.35;
const lone_air_slots: f32 = 0.55;

pub const Island = struct {
    start: u32,
    count: u32,
    cx: f32,
    cy: f32,
    radius: f32,
};

pub const World = struct {
    pos_x: []f32,
    pos_y: []f32,
    edge_a: []u32,
    edge_b: []u32,
    islands: []Island,
    orphans: u32,
    min_x: f32,
    min_y: f32,
    max_x: f32,
    max_y: f32,

    pub fn len(self: World) usize {
        return self.pos_x.len;
    }

    pub fn edgeCount(self: World) usize {
        return self.edge_a.len;
    }

    pub fn span(self: World) f32 {
        return @max(self.max_x - self.min_x, self.max_y - self.min_y);
    }

    pub fn center(self: World) dvui.Point {
        return .{
            .x = (self.min_x + self.max_x) * 0.5,
            .y = (self.min_y + self.max_y) * 0.5,
        };
    }

    pub fn pointsSlice(self: World, arena: std.mem.Allocator) ![]dvui.Point {
        const out = try arena.alloc(dvui.Point, self.len());
        for (out, self.pos_x, self.pos_y) |*p, x, y| p.* = .{ .x = x, .y = y };
        return out;
    }

    pub fn deinit(self: *World, gpa: std.mem.Allocator) void {
        gpa.free(self.pos_x);
        gpa.free(self.pos_y);
        gpa.free(self.edge_a);
        gpa.free(self.edge_b);
        gpa.free(self.islands);
        self.* = undefined;
    }
};

pub const SynthOpts = struct {
    orphan_frac: f32 = 0.10,
    island_min: u32 = 5,
    island_max: u32 = 10_000,
    aspect: f32 = 1.6,
};

pub const View = struct {
    world: dvui.Rect,
    zoom: f32,
    screen_w: f32 = 1440,
    screen_h: f32 = 900,
    label: []const u8,
};

pub const DrawCtx = struct {
    zoom: f32,
    zoom_t: f32,
    gap_px: f32,
    hover_world: ?dvui.Point = null,
    falloff_world: f32 = 0,

    pub fn forCamera(w: World, zoom: f32, hover_world: ?dvui.Point) DrawCtx {
        const slot = hex.layoutSpacingFor(w.len());
        const gap = slot * zoom;
        const zoom_t = detailRevealT(gap);
        var ctx: DrawCtx = .{ .zoom = zoom, .zoom_t = zoom_t, .gap_px = gap };
        if (hover_world) |hw| {
            if (zoom_t >= 0.2) {
                ctx.hover_world = hw;
                const boost = 1.0 + (proximity_falloff_zoom_boost - 1.0) * zoom_t;
                ctx.falloff_world = (proximity_falloff_px * boost) / @max(zoom, 1e-6);
            }
        }
        return ctx;
    }

    pub fn hoverT(self: DrawCtx, x: f32, y: f32) f32 {
        const hw = self.hover_world orelse return 0;
        const dx = x - hw.x;
        const dy = y - hw.y;
        const d = @sqrt(dx * dx + dy * dy);
        const t = 1.0 - std.math.clamp(d / @max(self.falloff_world, 1e-6), 0, 1);
        return t * t * (3 - 2 * t);
    }

    pub fn radius(self: DrawCtx, hover_t: f32, open: bool) f32 {
        const base: f32 = if (open) open_screen_r else base_screen_r;
        const zoom_boost = zoom_rest_swell * std.math.clamp(self.zoom_t, 0, 1);
        const hover_boost = grow_factor * hover_t;
        const want = @min(base * (1.0 + zoom_boost + hover_boost), max_node_screen_r);
        const floor: f32 = if (open or hover_t > 0.5) 3.0 else 0.6;
        return @max(@min(want, self.gap_px * gap_radius_frac), floor);
    }
};

pub fn detailRevealT(gap_px: f32) f32 {
    const t = std.math.clamp((gap_px - detail_gap_lo) / (detail_gap_hi - detail_gap_lo), 0, 1);
    return t * t * (3 - 2 * t);
}

pub fn isOpenNote(i: usize) bool {
    const stride: usize = @max(1, @as(usize, @intFromFloat(1.0 / open_frac)));
    return i % stride == 0;
}

pub fn synthWorld(gpa: std.mem.Allocator, n: usize, opts: SynthOpts) !World {
    var o = opts;
    if (o.island_min < 2) o.island_min = 2;
    if (o.island_max < o.island_min) o.island_max = o.island_min;
    o.orphan_frac = std.math.clamp(o.orphan_frac, 0, 0.9);

    var rng = std.Random.DefaultPrng.init(0xA71A5);
    const rand = rng.random();

    var sizes: std.ArrayList(u32) = .empty;
    defer sizes.deinit(gpa);

    const orphan_target: usize = @intFromFloat(@as(f32, @floatFromInt(n)) * o.orphan_frac);
    var remaining: usize = n;
    var orphan_n: u32 = 0;
    while (orphan_n < orphan_target and remaining > 0) : (orphan_n += 1) {
        try sizes.append(gpa, 1);
        remaining -= 1;
    }
    const log_lo = @log(@as(f32, @floatFromInt(o.island_min)));
    const log_hi = @log(@as(f32, @floatFromInt(o.island_max)));
    while (remaining > 0) {
        if (remaining < o.island_min) {
            try sizes.append(gpa, 1);
            orphan_n += 1;
            remaining -= 1;
            continue;
        }
        const u = rand.float(f32);
        var sz: u32 = @intFromFloat(@round(@exp(log_lo + u * (log_hi - log_lo))));
        sz = std.math.clamp(sz, o.island_min, o.island_max);
        if (sz > remaining) sz = @intCast(remaining);
        if (sz < o.island_min and remaining >= o.island_min) sz = o.island_min;
        try sizes.append(gpa, sz);
        remaining -= sz;
    }

    std.mem.sort(u32, sizes.items, {}, struct {
        fn less(_: void, a: u32, b: u32) bool {
            return a > b;
        }
    }.less);

    const pos_x = try gpa.alloc(f32, n);
    errdefer gpa.free(pos_x);
    const pos_y = try gpa.alloc(f32, n);
    errdefer gpa.free(pos_y);
    const islands = try gpa.alloc(Island, sizes.items.len);
    errdefer gpa.free(islands);

    var edge_a: std.ArrayList(u32) = .empty;
    var edge_b: std.ArrayList(u32) = .empty;
    errdefer edge_a.deinit(gpa);
    errdefer edge_b.deinit(gpa);

    const slot = hex.layoutSpacingFor(n);
    const footprints = try gpa.alloc(f32, sizes.items.len);
    defer gpa.free(footprints);
    var total_area: f32 = 0;
    var core_r: f32 = 0;
    for (sizes.items, 0..) |sz, ii| {
        const r = if (sz == 1)
            slot * 0.5
        else
            slot * @sqrt(@as(f32, @floatFromInt(sz)) / std.math.pi);
        const air = if (sz == 1) slot * lone_air_slots else slot * component_gap_slots;
        footprints[ii] = r;
        const claim = r + air * 0.5;
        total_area += std.math.pi * claim * claim;
        core_r = @max(core_r, claim);
    }
    const aspect = std.math.clamp(o.aspect, 1.0 / 3.5, 3.5);
    const isle_r = slot * (0.5 + lone_air_slots * 0.5);
    const axes = packEllipseAxes(aspect, total_area, core_r, isle_r);

    var cursor: u32 = 0;
    var area_used: f32 = 0;
    var pool: std.ArrayList(u32) = .empty;
    defer pool.deinit(gpa);

    for (sizes.items, islands, 0..) |sz, *isle, ii| {
        const alone = sz == 1;
        const frac = if (alone) blk: {
            const phase = @mod(@as(f32, @floatFromInt(ii)) * 0.6180339887, 1.0);
            break :blk 0.72 + 0.22 * phase;
        } else @sqrt(std.math.clamp(area_used / @max(total_area, 1), 0, 1));
        const theta = @as(f32, @floatFromInt(ii)) * golden_angle;
        const cx = @cos(theta) * axes.x * frac;
        const cy = @sin(theta) * axes.y * frac;
        const r = footprints[ii];
        const air = if (alone) slot * lone_air_slots else slot * component_gap_slots;
        area_used += std.math.pi * (r + air * 0.5) * (r + air * 0.5);

        isle.* = .{ .start = cursor, .count = sz, .cx = cx, .cy = cy, .radius = r };

        // Disc pack: polar sunflower with ~`slot` nearest-neighbour spacing. Hex-column
        // grids read as solid rectangles under cloud LOD even when sampling is fair.
        if (sz == 1) {
            pos_x[cursor] = cx;
            pos_y[cursor] = cy;
        } else {
            for (0..sz) |k| {
                const rk = slot * @sqrt((@as(f32, @floatFromInt(k)) + 0.5) / std.math.pi);
                const th = @as(f32, @floatFromInt(k)) * golden_angle;
                pos_x[cursor + @as(u32, @intCast(k))] = cx + rk * @cos(th);
                pos_y[cursor + @as(u32, @intCast(k))] = cy + rk * @sin(th);
            }
        }

        if (sz >= 2) {
            pool.clearRetainingCapacity();
            try pool.append(gpa, cursor);
            for (1..sz) |k| {
                const ni: u32 = cursor + @as(u32, @intCast(k));
                const degree_budget: usize = 2 + rand.uintLessThan(usize, 2);
                var added: usize = 0;
                var guard: usize = 0;
                while (added < degree_budget and guard < degree_budget * 8) : (guard += 1) {
                    const j = pool.items[rand.uintLessThan(usize, pool.items.len)];
                    if (j == ni) continue;
                    const a = @min(ni, j);
                    const b = @max(ni, j);
                    var dup = false;
                    var back: usize = 0;
                    while (back < added and back < edge_a.items.len) : (back += 1) {
                        const ei = edge_a.items.len - 1 - back;
                        if (edge_a.items[ei] == a and edge_b.items[ei] == b) {
                            dup = true;
                            break;
                        }
                    }
                    if (dup) continue;
                    try edge_a.append(gpa, a);
                    try edge_b.append(gpa, b);
                    try pool.append(gpa, j);
                    added += 1;
                }
                try pool.append(gpa, ni);
            }
        }
        cursor += sz;
    }
    std.debug.assert(cursor == n);

    var min_x: f32 = std.math.floatMax(f32);
    var min_y: f32 = std.math.floatMax(f32);
    var max_x: f32 = -std.math.floatMax(f32);
    var max_y: f32 = -std.math.floatMax(f32);
    for (pos_x, pos_y) |x, y| {
        min_x = @min(min_x, x);
        min_y = @min(min_y, y);
        max_x = @max(max_x, x);
        max_y = @max(max_y, y);
    }

    return .{
        .pos_x = pos_x,
        .pos_y = pos_y,
        .edge_a = try edge_a.toOwnedSlice(gpa),
        .edge_b = try edge_b.toOwnedSlice(gpa),
        .islands = islands,
        .orphans = orphan_n,
        .min_x = min_x,
        .min_y = min_y,
        .max_x = max_x,
        .max_y = max_y,
    };
}

fn packEllipseAxes(a: f32, total_area: f32, core_r: f32, isle_r: f32) struct { x: f32, y: f32 } {
    const area_r = @sqrt(@max(total_area, 1) / std.math.pi);
    const base = @max(area_r, core_r + isle_r);
    if (a >= 1) return .{ .x = base * a, .y = base };
    return .{ .x = base, .y = base / a };
}

pub fn printIslandStats(w: World) void {
    var linked: u32 = 0;
    var max_sz: u32 = 0;
    var sum_linked: u64 = 0;
    var buckets = [_]u32{0} ** 9;
    for (w.islands) |isle| {
        const sz = isle.count;
        max_sz = @max(max_sz, sz);
        if (sz == 1) {
            buckets[0] += 1;
            continue;
        }
        linked += 1;
        sum_linked += sz;
        const b: usize = if (sz < 5) 1 else if (sz < 17) 2 else if (sz < 65) 3 else if (sz < 257) 4 else if (sz < 1025) 5 else if (sz < 4097) 6 else if (sz < 10001) 7 else 8;
        buckets[b] += 1;
    }
    const avg: f64 = if (linked == 0) 0 else @as(f64, @floatFromInt(sum_linked)) / @as(f64, @floatFromInt(linked));
    std.debug.print(
        "islands: {d} linked (avg {d:.0}, max {d}) + {d} orphans\n",
        .{ linked, avg, max_sz, w.orphans },
    );
    std.debug.print(
        "  sizes: 1={d}  2-4={d}  5-16={d}  17-64={d}  65-256={d}  257-1k={d}  1k-4k={d}  4k-10k={d}  10k+={d}\n",
        .{ buckets[0], buckets[1], buckets[2], buckets[3], buckets[4], buckets[5], buckets[6], buckets[7], buckets[8] },
    );
}

pub fn makeViews(gpa: std.mem.Allocator, w: World, screen_w: f32, screen_h: f32) ![]View {
    const c = w.center();
    const span = @max(w.span(), 1);
    const fit = @min(screen_w, screen_h) / span * 0.9;

    var mid_isle: ?Island = null;
    var big_isle: ?Island = null;
    for (w.islands) |isle| {
        if (isle.count < 2) continue;
        if (big_isle == null or isle.count > big_isle.?.count) big_isle = isle;
        if (isle.count >= 64 and isle.count <= 1024) {
            if (mid_isle == null or @abs(@as(i32, @intCast(isle.count)) - 256) < @abs(@as(i32, @intCast(mid_isle.?.count)) - 256))
                mid_isle = isle;
        }
    }
    if (mid_isle == null) mid_isle = big_isle;

    const out = try gpa.alloc(View, 3);
    out[0] = .{
        .world = .{ .x = w.min_x, .y = w.min_y, .w = w.max_x - w.min_x, .h = w.max_y - w.min_y },
        .zoom = fit,
        .screen_w = screen_w,
        .screen_h = screen_h,
        .label = "overview",
    };

    if (mid_isle) |isle| {
        const pad = @max(isle.radius * 1.3, hex.layoutSpacingFor(w.len()) * 4);
        out[1] = .{
            .world = .{ .x = isle.cx - pad, .y = isle.cy - pad, .w = pad * 2, .h = pad * 2 },
            .zoom = @min(screen_w, screen_h) / (pad * 2) * 0.9,
            .screen_w = screen_w,
            .screen_h = screen_h,
            .label = "island",
        };
    } else {
        const half = span * 0.05;
        out[1] = .{
            .world = .{ .x = c.x - half, .y = c.y - half, .w = half * 2, .h = half * 2 },
            .zoom = fit / 0.1,
            .screen_w = screen_w,
            .screen_h = screen_h,
            .label = "island",
        };
    }

    if (big_isle) |isle| {
        const slot = hex.layoutSpacingFor(w.len());
        const patch = slot * 3.5;
        out[2] = .{
            .world = .{ .x = isle.cx - patch, .y = isle.cy - patch, .w = patch * 2, .h = patch * 2 },
            .zoom = @min(screen_w, screen_h) / (patch * 2) * 0.9,
            .screen_w = screen_w,
            .screen_h = screen_h,
            .label = "close",
        };
    } else {
        const half = span * 0.005;
        out[2] = .{
            .world = .{ .x = c.x - half, .y = c.y - half, .w = half * 2, .h = half * 2 },
            .zoom = fit / 0.01,
            .screen_w = screen_w,
            .screen_h = screen_h,
            .label = "close",
        };
    }
    return out;
}

/// Spatial hash for zoomed-in draws. CSR of nodes and edges per cell.
pub const Grid = struct {
    cell: f32,
    origin_x: f32,
    origin_y: f32,
    cols: i32,
    rows: i32,
    start: []u32,
    nodes: []u32,
    edge_start: []u32,
    edges: []u32,

    pub fn deinit(self: *Grid, gpa: std.mem.Allocator) void {
        gpa.free(self.start);
        gpa.free(self.nodes);
        gpa.free(self.edge_start);
        gpa.free(self.edges);
    }
};

pub fn buildGrid(gpa: std.mem.Allocator, w: World, cell: f32) !Grid {
    const cols: i32 = @max(1, @as(i32, @intFromFloat(@ceil((w.max_x - w.min_x) / cell))) + 1);
    const rows: i32 = @max(1, @as(i32, @intFromFloat(@ceil((w.max_y - w.min_y) / cell))) + 1);
    const n_cells: usize = @intCast(cols * rows);

    const counts = try gpa.alloc(u32, n_cells);
    defer gpa.free(counts);
    @memset(counts, 0);
    for (w.pos_x, w.pos_y) |x, y| {
        const cx: i32 = @intFromFloat(@floor((x - w.min_x) / cell));
        const cy: i32 = @intFromFloat(@floor((y - w.min_y) / cell));
        const c: usize = @intCast(std.math.clamp(cy, 0, rows - 1) * cols + std.math.clamp(cx, 0, cols - 1));
        counts[c] += 1;
    }
    const start = try gpa.alloc(u32, n_cells + 1);
    start[0] = 0;
    for (counts, 0..) |c, i| start[i + 1] = start[i] + c;
    const nodes = try gpa.alloc(u32, w.len());
    const cursor = try gpa.alloc(u32, n_cells);
    defer gpa.free(cursor);
    @memcpy(cursor, start[0..n_cells]);
    for (w.pos_x, w.pos_y, 0..) |x, y, ni| {
        const cx: i32 = @intFromFloat(@floor((x - w.min_x) / cell));
        const cy: i32 = @intFromFloat(@floor((y - w.min_y) / cell));
        const c: usize = @intCast(std.math.clamp(cy, 0, rows - 1) * cols + std.math.clamp(cx, 0, cols - 1));
        nodes[cursor[c]] = @intCast(ni);
        cursor[c] += 1;
    }

    @memset(counts, 0);
    for (w.edge_a, w.edge_b) |a, b| {
        for ([_]u32{ a, b }) |ep| {
            counts[cellOf(w, ep, cell, cols, rows)] += 1;
        }
    }
    const edge_start = try gpa.alloc(u32, n_cells + 1);
    edge_start[0] = 0;
    for (counts, 0..) |c, i| edge_start[i + 1] = edge_start[i] + c;
    const edges = try gpa.alloc(u32, edge_start[n_cells]);
    @memcpy(cursor, edge_start[0..n_cells]);
    for (w.edge_a, w.edge_b, 0..) |a, b, ei| {
        for ([_]u32{ a, b }) |ep| {
            const c = cellOf(w, ep, cell, cols, rows);
            edges[cursor[c]] = @intCast(ei);
            cursor[c] += 1;
        }
    }

    return .{
        .cell = cell,
        .origin_x = w.min_x,
        .origin_y = w.min_y,
        .cols = cols,
        .rows = rows,
        .start = start,
        .nodes = nodes,
        .edge_start = edge_start,
        .edges = edges,
    };
}

fn cellOf(w: World, i: u32, cell: f32, cols: i32, rows: i32) usize {
    const cx: i32 = @intFromFloat(@floor((w.pos_x[i] - w.min_x) / cell));
    const cy: i32 = @intFromFloat(@floor((w.pos_y[i] - w.min_y) / cell));
    return @intCast(std.math.clamp(cy, 0, rows - 1) * cols + std.math.clamp(cx, 0, cols - 1));
}

pub fn rectContains(r: dvui.Rect, x: f32, y: f32) bool {
    return x >= r.x and y >= r.y and x < r.x + r.w and y < r.y + r.h;
}

pub fn segmentHits(r: dvui.Rect, ax: f32, ay: f32, bx: f32, by: f32) bool {
    if (rectContains(r, ax, ay) or rectContains(r, bx, by)) return true;
    const min_x = @min(ax, bx);
    const max_x = @max(ax, bx);
    const min_y = @min(ay, by);
    const max_y = @max(ay, by);
    return !(max_x < r.x or min_x > r.x + r.w or max_y < r.y or min_y > r.y + r.h);
}

pub fn inflate(r: dvui.Rect, pad: f32) dvui.Rect {
    return .{ .x = r.x - pad, .y = r.y - pad, .w = r.w + pad * 2, .h = r.h + pad * 2 };
}
