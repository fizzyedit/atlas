//! Headless stress test for the *draw* half of Atlas at vault scale.
//!
//! The existing `atlas-bench` times scan/resolve/layout. This one asks a different question:
//! given ~500k notes already placed as *islands* (the shape a real vault takes — see the
//! gauntlet's `islands/` folder, and `layout_full`'s component pack), can the *render path*
//! alone stay inside a 120 fps frame (≈8.33 ms) on this laptop — and which strategy gets us
//! there.
//!
//! Synthetic shape (not one giant connected component):
//!   • islands of 5‥10_000 notes, log-uniform sizes, links only *within* an island
//!   • a fraction of singles (orphans) with degree 0, parked on the rim
//!   • placement mirrors `layout_full.packComponents`: biggest islands near the origin,
//!     loners in the outer band of an aspect ellipse, hex lattice inside each island
//!
//! It deliberately never opens a window or calls `dvui.renderTriangles`. Vertex buffers are
//! filled and discarded exactly as `DiscBatch` / `LineBatch` do in `graph.zig`, so what is
//! measured is CPU tessellation + selection/culling cost under the same u16-index batching
//! rules the live panel uses.
//!
//!     zig build render-bench -Doptimize=ReleaseFast -- [N] [--iters=K] [--modes=…]
//!         [--orphans=0.1] [--island-min=5] [--island-max=10000] [--svg <dir>]
//!
//! Modes (comma-separated, default all):
//!   brute   — emit discs+lines for *every* node/edge (sanity ceiling; will miss budget)
//!   cull    — linear SOA walk, keep what hits the viewport AABB
//!   grid    — cell hash → only visit cells overlapping the view
//!   lod     — pyramid `levelFor` + `select` + `gatherWeb` (current Atlas path)
//!   tiles   — impostor tile keys covering the view (zoomed-out endgame)
//!
//! Views: `overview` (whole vault), `island` (one mid-sized component framed), `close`
//! (dense patch inside a large island).

const std = @import("std");
const dvui = @import("dvui");
const multilevel = @import("ui/multilevel.zig");
const lod = @import("ui/lod.zig");
const impostor = @import("ui/impostor.zig");
const hex = @import("ui/hex.zig");

/// 120 Hz frame budget. Anything that can't fit here on the CPU side cannot be rescued by
/// batching harder — the work itself has to shrink (cull / LOD / bake).
const budget_ms: f64 = 1000.0 / 120.0;

// Node draw constants — keep in lockstep with `graph.zig`.
const base_screen_r: f32 = 9;
const open_screen_r: f32 = 12;
const max_node_screen_r: f32 = 48;
const grow_factor: f32 = 1.0;
const zoom_rest_swell: f32 = 0.35;
const gap_radius_frac: f32 = 0.42;
const batch_max_r: f32 = 9.0;
const node_border_px: f32 = 1.25;
const shadow_min_r: f32 = 6.0;
const shadow_offset: f32 = 1.5;
const proximity_falloff_px: f32 = 100;
const proximity_falloff_zoom_boost: f32 = 1.75;
const detail_gap_lo: f32 = 34;
const detail_gap_hi: f32 = 64;
/// Open notes in the synth — a few selected docs, larger at rest, always past the batch cutoff
/// once zoom-revealed.
const open_frac: f32 = 0.002;

const batch_sides: usize = 8;
/// Path.Builder arcs use denser tessellation; 32 is a fair stand-in for the CPU cost of one
/// `fillConvex`/`stroke` on a ~12–24px bubble.
const path_sides: usize = 32;
const disc_verts: usize = batch_sides + 1;
const max_discs: usize = std.math.maxInt(u16) / disc_verts;
const line_verts: usize = 4;
const max_lines: usize = std.math.maxInt(u16) / line_verts;

/// Scratch buffers sized like a full u16-index DiscBatch / LineBatch. Vertices are actually
/// written (and discarded on flush) so the timed path pays the same memory traffic the live
/// panel does — counting alone made brute force look free.
///
/// Every visible node is a *background fill* plus an *outline ring* (see `graph.drawNodes`).
/// Small radii stay batched; once `bubbleScreenRadius` exceeds `batch_max_r` (hover growth or
/// zoom rest-swell), the live panel switches to per-node path draws with a drop shadow — that
/// path is modelled here as denser geometry flushed per primitive, since each is one draw call.
const GeomScratch = struct {
    disc_pos: [][2]f32,
    disc_n: usize = 0,
    line_pos: [][2]f32,
    line_n: usize = 0,
    discs: u64 = 0,
    rings: u64 = 0,
    lines: u64 = 0,
    /// Nodes that took the expensive path (r > batch_max_r): shadow + fill + ring, one flush each.
    pathed: u64 = 0,
    disc_flushes: u64 = 0,
    line_flushes: u64 = 0,
    path_flushes: u64 = 0,
    verts: u64 = 0,

    fn init(gpa: std.mem.Allocator) !GeomScratch {
        // Path discs need more room per primitive than the batch octagon.
        const disc_cap = @max(max_discs * (batch_sides * 2), path_sides * 4);
        return .{
            .disc_pos = try gpa.alloc([2]f32, disc_cap),
            .line_pos = try gpa.alloc([2]f32, max_lines * line_verts),
        };
    }

    fn deinit(self: *GeomScratch, gpa: std.mem.Allocator) void {
        gpa.free(self.disc_pos);
        gpa.free(self.line_pos);
    }

    fn resetCounts(self: *GeomScratch) void {
        self.disc_n = 0;
        self.line_n = 0;
        self.discs = 0;
        self.rings = 0;
        self.lines = 0;
        self.pathed = 0;
        self.disc_flushes = 0;
        self.line_flushes = 0;
        self.path_flushes = 0;
        self.verts = 0;
    }

    fn flushDisc(self: *GeomScratch) void {
        if (self.disc_n == 0) return;
        std.mem.doNotOptimizeAway(self.disc_pos[0][0] + self.disc_pos[self.disc_n - 1][0]);
        self.disc_flushes += 1;
        self.disc_n = 0;
    }

    fn flushLine(self: *GeomScratch) void {
        if (self.line_n == 0) return;
        std.mem.doNotOptimizeAway(self.line_pos[0][0] + self.line_pos[self.line_n - 1][0]);
        self.line_flushes += 1;
        self.line_n = 0;
    }

    fn flushPath(self: *GeomScratch) void {
        if (self.disc_n == 0) return;
        std.mem.doNotOptimizeAway(self.disc_pos[0][0] + self.disc_pos[self.disc_n - 1][0]);
        self.path_flushes += 1;
        self.disc_n = 0;
    }

    fn appendFan(self: *GeomScratch, x: f32, y: f32, r: f32, sides: usize) void {
        if (self.disc_n + sides + 1 > self.disc_pos.len) self.flushDisc();
        self.disc_pos[self.disc_n] = .{ x, y };
        self.disc_n += 1;
        var s: usize = 0;
        while (s < sides) : (s += 1) {
            const a = std.math.tau * @as(f32, @floatFromInt(s)) / @as(f32, @floatFromInt(sides));
            self.disc_pos[self.disc_n] = .{ x + @cos(a) * r, y + @sin(a) * r };
            self.disc_n += 1;
        }
        self.discs += 1;
        self.verts += sides + 1;
    }

    fn appendRing(self: *GeomScratch, x: f32, y: f32, outer: f32, inner: f32, sides: usize) void {
        if (self.disc_n + sides * 2 > self.disc_pos.len) self.flushDisc();
        var s: usize = 0;
        while (s < sides) : (s += 1) {
            const a = std.math.tau * @as(f32, @floatFromInt(s)) / @as(f32, @floatFromInt(sides));
            self.disc_pos[self.disc_n] = .{ x + @cos(a) * outer, y + @sin(a) * outer };
            self.disc_n += 1;
        }
        s = 0;
        while (s < sides) : (s += 1) {
            const a = std.math.tau * @as(f32, @floatFromInt(s)) / @as(f32, @floatFromInt(sides));
            self.disc_pos[self.disc_n] = .{ x + @cos(a) * inner, y + @sin(a) * inner };
            self.disc_n += 1;
        }
        self.rings += 1;
        self.verts += sides * 2;
    }

    fn addDisc(self: *GeomScratch, x: f32, y: f32, r: f32) void {
        self.appendFan(x, y, r, batch_sides);
    }

    fn addRing(self: *GeomScratch, x: f32, y: f32, outer: f32, inner: f32) void {
        self.appendRing(x, y, outer, inner, batch_sides);
    }

    /// One note as the live panel draws it: outline ring + fill, or the large-node path with
    /// drop shadow. `open` selects the larger resting radius used for docs open in the editor.
    fn addNode(self: *GeomScratch, x: f32, y: f32, r_px: f32) void {
        if (r_px <= batch_max_r) {
            const inner = @max(r_px - node_border_px, 0.5);
            self.addRing(x, y, r_px, inner);
            self.addDisc(x, y, inner);
            return;
        }
        // Path path — each primitive is its own draw call in the live panel.
        self.pathed += 1;
        if (r_px >= shadow_min_r) {
            self.appendFan(x + shadow_offset, y + shadow_offset, r_px, path_sides);
            self.flushPath();
        }
        self.appendFan(x, y, r_px, path_sides);
        self.flushPath();
        self.appendRing(x, y, r_px, @max(r_px - node_border_px, 0.5), path_sides);
        self.flushPath();
    }

    fn addLine(self: *GeomScratch, ax: f32, ay: f32, bx: f32, by: f32, thickness: f32) void {
        const dx = bx - ax;
        const dy = by - ay;
        const len = @sqrt(dx * dx + dy * dy);
        if (len < 1e-3) return;
        if (self.line_n + line_verts > self.line_pos.len) self.flushLine();
        const h = @max(thickness, 0.75) * 0.5;
        const nx = -dy / len * h;
        const ny = dx / len * h;
        self.line_pos[self.line_n] = .{ ax + nx, ay + ny };
        self.line_pos[self.line_n + 1] = .{ ax - nx, ay - ny };
        self.line_pos[self.line_n + 2] = .{ bx - nx, by - ny };
        self.line_pos[self.line_n + 3] = .{ bx + nx, by + ny };
        self.line_n += 4;
        self.lines += 1;
        self.verts += line_verts;
    }

    fn finish(self: *GeomScratch) void {
        self.flushDisc();
        self.flushLine();
    }

    fn totalFlushes(self: GeomScratch) u64 {
        return self.disc_flushes + self.line_flushes + self.path_flushes;
    }
};

/// Per-view draw parameters matching `bubbleScreenRadius` + proximity falloff.
const DrawCtx = struct {
    zoom: f32,
    zoom_t: f32,
    gap_px: f32,
    /// World-space cursor for hover; null disables swell (overview / tiles).
    hover_world: ?dvui.Point = null,
    falloff_world: f32 = 0,

    fn forView(w: World, view: View, with_hover: bool) DrawCtx {
        const slot = hex.layoutSpacingFor(w.len());
        const gap = slot * view.zoom;
        const zoom_t = detailRevealT(gap);
        var ctx: DrawCtx = .{
            .zoom = view.zoom,
            .zoom_t = zoom_t,
            .gap_px = gap,
        };
        // Hover only once notes are big enough to read — same gate as `proximity_min_reveal`.
        if (with_hover and zoom_t >= 0.2) {
            ctx.hover_world = .{
                .x = view.world.x + view.world.w * 0.5,
                .y = view.world.y + view.world.h * 0.5,
            };
            const boost = 1.0 + (proximity_falloff_zoom_boost - 1.0) * zoom_t;
            ctx.falloff_world = (proximity_falloff_px * boost) / @max(view.zoom, 1e-6);
        }
        return ctx;
    }

    fn hoverT(self: DrawCtx, x: f32, y: f32) f32 {
        const hw = self.hover_world orelse return 0;
        const dx = x - hw.x;
        const dy = y - hw.y;
        const d = @sqrt(dx * dx + dy * dy);
        const t = 1.0 - std.math.clamp(d / @max(self.falloff_world, 1e-6), 0, 1);
        // Smoothstep — close enough to the live chase target for sizing cost.
        return t * t * (3 - 2 * t);
    }

    fn radius(self: DrawCtx, hover_t: f32, open: bool) f32 {
        const base: f32 = if (open) open_screen_r else base_screen_r;
        const zoom_boost = zoom_rest_swell * std.math.clamp(self.zoom_t, 0, 1);
        // outBack(1) ≈ 1; skip the easing import and use the asymptotic grow.
        const hover_boost = grow_factor * hover_t;
        const want = @min(base * (1.0 + zoom_boost + hover_boost), max_node_screen_r);
        const floor: f32 = if (open or hover_t > 0.5) 3.0 else 0.6;
        return @max(@min(want, self.gap_px * gap_radius_frac), floor);
    }
};

fn detailRevealT(gap_px: f32) f32 {
    const t = std.math.clamp((gap_px - detail_gap_lo) / (detail_gap_hi - detail_gap_lo), 0, 1);
    return t * t * (3 - 2 * t);
}

fn isOpenNote(i: usize) bool {
    // Deterministic sparse open set — ~0.2% of nodes, matching a handful of editor tabs.
    const stride: usize = @max(1, @as(usize, @intFromFloat(1.0 / open_frac)));
    return i % stride == 0;
}

/// One connected component (or a lone orphan). Sizes and centres let views frame a real island
/// the way a reader does, instead of an arbitrary rectangle of the AABB.
const Island = struct {
    start: u32,
    count: u32,
    cx: f32,
    cy: f32,
    radius: f32,
};

/// Structure-of-arrays world. Positions and edges are the only fields the draw path needs;
/// titles/paths/open-state stay out so the hot loops look like what an ECS/SOA rewrite would
/// actually walk. Island metadata is kept so views and the SVG dump can judge distribution.
const World = struct {
    pos_x: []f32,
    pos_y: []f32,
    edge_a: []u32,
    edge_b: []u32,
    islands: []Island,
    orphans: u32,
    /// Axis-aligned bounds of every position (world units).
    min_x: f32,
    min_y: f32,
    max_x: f32,
    max_y: f32,

    fn len(self: World) usize {
        return self.pos_x.len;
    }

    fn edgeCount(self: World) usize {
        return self.edge_a.len;
    }

    fn span(self: World) f32 {
        return @max(self.max_x - self.min_x, self.max_y - self.min_y);
    }

    fn center(self: World) dvui.Point {
        return .{
            .x = (self.min_x + self.max_x) * 0.5,
            .y = (self.min_y + self.max_y) * 0.5,
        };
    }

    fn pointAt(self: World, i: usize) dvui.Point {
        return .{ .x = self.pos_x[i], .y = self.pos_y[i] };
    }

    fn pointsSlice(self: World, arena: std.mem.Allocator) ![]dvui.Point {
        const out = try arena.alloc(dvui.Point, self.len());
        for (out, self.pos_x, self.pos_y) |*p, x, y| p.* = .{ .x = x, .y = y };
        return out;
    }
};

const SynthOpts = struct {
    orphan_frac: f32 = 0.10,
    island_min: u32 = 5,
    island_max: u32 = 10_000,
    /// Panel aspect fed to the island packer — same role as `layout_full.Opts.aspect`.
    aspect: f32 = 1.6,
};

const View = struct {
    /// World-space rectangle currently on screen.
    world: dvui.Rect,
    /// Pixels per world unit (camera zoom).
    zoom: f32,
    /// Panel size in physical pixels — used for tile coverage and budget math.
    screen_w: f32 = 1440,
    screen_h: f32 = 900,
    label: []const u8,
};

const Mode = enum { brute, cull, grid, lod, tiles };

const RunRow = struct {
    mode: Mode,
    view: []const u8,
    ms: f64,
    items: u64,
    edges: u64,
    flushes: u64,
    verts: u64,
    extra: u64 = 0, // mode-specific: lod level, tile count, cells visited, …
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    dvui.io = io;

    var n: usize = 500_000;
    var iters: usize = 20;
    var want: std.EnumSet(Mode) = .initFull();
    var synth: SynthOpts = .{};
    var svg_dir: ?[]const u8 = null;

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--iters")) {
            i += 1;
            if (i >= args.len) return usage();
            iters = try std.fmt.parseInt(usize, args[i], 10);
        } else if (std.mem.startsWith(u8, a, "--iters=")) {
            iters = try std.fmt.parseInt(usize, a["--iters=".len..], 10);
        } else if (std.mem.eql(u8, a, "--modes")) {
            i += 1;
            if (i >= args.len) return usage();
            want = try parseModes(args[i]);
        } else if (std.mem.startsWith(u8, a, "--modes=")) {
            want = try parseModes(a["--modes=".len..]);
        } else if (std.mem.eql(u8, a, "--orphans")) {
            i += 1;
            if (i >= args.len) return usage();
            synth.orphan_frac = try std.fmt.parseFloat(f32, args[i]);
        } else if (std.mem.startsWith(u8, a, "--orphans=")) {
            synth.orphan_frac = try std.fmt.parseFloat(f32, a["--orphans=".len..]);
        } else if (std.mem.eql(u8, a, "--island-min")) {
            i += 1;
            if (i >= args.len) return usage();
            synth.island_min = try std.fmt.parseInt(u32, args[i], 10);
        } else if (std.mem.startsWith(u8, a, "--island-min=")) {
            synth.island_min = try std.fmt.parseInt(u32, a["--island-min=".len..], 10);
        } else if (std.mem.eql(u8, a, "--island-max")) {
            i += 1;
            if (i >= args.len) return usage();
            synth.island_max = try std.fmt.parseInt(u32, args[i], 10);
        } else if (std.mem.startsWith(u8, a, "--island-max=")) {
            synth.island_max = try std.fmt.parseInt(u32, a["--island-max=".len..], 10);
        } else if (std.mem.eql(u8, a, "--svg")) {
            i += 1;
            if (i >= args.len) return usage();
            svg_dir = args[i];
        } else if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            return usage();
        } else {
            n = try std.fmt.parseInt(usize, a, 10);
        }
    }
    if (n == 0) return usage();
    if (synth.island_min < 2) synth.island_min = 2;
    if (synth.island_max < synth.island_min) synth.island_max = synth.island_min;
    synth.orphan_frac = std.math.clamp(synth.orphan_frac, 0, 0.9);

    std.debug.print(
        \\atlas-render-bench  N={d}  iters={d}  budget={d:.2}ms (120fps)
        \\  shape: islands [{d}‥{d}] + {d:.0}% orphans, links only inside islands
        \\  nodes: fill + outline ring; radius from bubbleScreenRadius (zoom swell + hover);
        \\         r≤{d:.0}px batched, else path (shadow+fill+stroke) — hover on island/close
        \\  backend constraint: DVUI triangles only (no custom/compute shaders, no mipmaps)
        \\  measuring: CPU select/cull + tessellation (no GPU submit); extra=pathed nodes
        \\
    ,
        .{ n, iters, budget_ms, synth.island_min, synth.island_max, synth.orphan_frac * 100, batch_max_r },
    );

    // -- synthesise ----------------------------------------------------------------
    var t = now(io);
    var world = try synthWorld(gpa, n, synth);
    defer freeWorld(gpa, &world);
    std.debug.print(
        "synth: {d} nodes, {d} edges (avg deg {d:.2}) in {d:.0}ms  span={d:.0}wu\n",
        .{
            world.len(),
            world.edgeCount(),
            2.0 * @as(f64, @floatFromInt(world.edgeCount())) / @as(f64, @floatFromInt(world.len())),
            ms(elapsed(io, t)),
            world.span(),
        },
    );
    printIslandStats(world);
    if (svg_dir) |dir| {
        t = now(io);
        try writeWorldSvg(io, gpa, dir, world);
        std.debug.print("svg: wrote {s}/islands.svg in {d:.0}ms\n", .{ dir, ms(elapsed(io, t)) });
    }

    // -- LOD pyramid (setup cost; paid once per rebuild, not per frame) ------------
    var pyramid: ?lod.Pyramid = null;
    defer if (pyramid) |*p| p.deinit();
    if (want.contains(.lod) or want.contains(.tiles)) {
        t = now(io);
        const ml_edges = try gpa.alloc(multilevel.Edge, world.edgeCount());
        defer gpa.free(ml_edges);
        for (world.edge_a, world.edge_b, ml_edges) |a, b, *e| e.* = .{ .a = a, .b = b };

        var ladder = try multilevel.coarsen(gpa, world.len(), ml_edges);
        defer ladder.deinit(gpa);

        const pos = try world.pointsSlice(gpa);
        defer gpa.free(pos);
        const cedges = try gpa.alloc(lod.CEdge, world.edgeCount());
        defer gpa.free(cedges);
        for (world.edge_a, world.edge_b, cedges) |a, b, *e| e.* = .{ .a = a, .b = b };

        pyramid = try lod.build(gpa, ladder, pos, cedges);
        const py = pyramid.?;
        std.debug.print(
            "lod pyramid: {d} levels, coarsest={d} clusters, build {d:.0}ms\n",
            .{ py.levels.len, py.levels[py.levels.len - 1].len, ms(elapsed(io, t)) },
        );
        for (py.levels, 0..) |lvl, li| {
            std.debug.print(
                "  L{d}: clusters={d} edges={d} spacing={d:.1} per={d:.2}\n",
                .{ li, lvl.len, py.edges[li].len, py.spacing[li], py.per_cluster[li] },
            );
        }
    }

    const views = try makeViews(gpa, world);
    defer gpa.free(views);

    std.debug.print("\n{s:<8}{s:<10}{s:>10}{s:>10}{s:>10}{s:>10}{s:>12}{s:>10}  {s}\n", .{
        "mode", "view", "ms", "items", "edges", "flushes", "verts", "extra", "vs 8.33ms",
    });
    std.debug.print("{s}\n", .{"-" ** 96});

    var rows: std.ArrayList(RunRow) = .empty;
    defer rows.deinit(gpa);

    for (views) |view| {
        if (want.contains(.brute)) try rows.append(gpa, try benchBrute(gpa, io, world, view, iters));
        if (want.contains(.cull)) try rows.append(gpa, try benchCull(gpa, io, world, view, iters));
        if (want.contains(.grid)) try rows.append(gpa, try benchGrid(gpa, io, world, view, iters));
        if (want.contains(.lod)) {
            if (pyramid) |*py| try rows.append(gpa, try benchLod(gpa, io, world, py, view, iters));
        }
        if (want.contains(.tiles)) {
            if (pyramid) |*py| try rows.append(gpa, try benchTiles(gpa, io, world, py, view, iters));
        }
    }

    for (rows.items) |r| {
        const ok = r.ms <= budget_ms;
        std.debug.print(
            "{s:<8}{s:<10}{d:>10.2}{d:>10}{d:>10}{d:>10}{d:>12}{d:>10}  {s} ({d:.0}%)\n",
            .{
                @tagName(r.mode),
                r.view,
                r.ms,
                r.items,
                r.edges,
                r.flushes,
                r.verts,
                r.extra,
                if (ok) "OK  " else "MISS",
                100.0 * r.ms / budget_ms,
            },
        );
    }

    std.debug.print("\n", .{});
    try printVerdict(rows.items, n);
}

fn usage() void {
    std.debug.print(
        \\usage: atlas-render-bench [N] [--iters=K] [--modes=…] [--orphans=F]
        \\                          [--island-min=A] [--island-max=B] [--svg <dir>]
        \\
        \\  N              node count (default 500000)
        \\  --iters        timed iterations per (mode, view) after a warmup (default 20)
        \\  --modes        brute,cull,grid,lod,tiles (comma-separated, or all)
        \\  --orphans      fraction of nodes with no links (default 0.10)
        \\  --island-min   smallest connected island (default 5)
        \\  --island-max   largest connected island (default 10000)
        \\  --svg <dir>    write islands.svg showing pack distribution
        \\
    , .{});
}

fn parseModes(spec: []const u8) !std.EnumSet(Mode) {
    var set: std.EnumSet(Mode) = .initEmpty();
    var it = std.mem.splitScalar(u8, spec, ',');
    while (it.next()) |tok| {
        if (tok.len == 0) continue;
        if (std.mem.eql(u8, tok, "all")) return .initFull();
        const m = std.meta.stringToEnum(Mode, tok) orelse {
            std.debug.print("unknown mode '{s}'\n", .{tok});
            return error.UnknownMode;
        };
        set.insert(m);
    }
    if (set.count() == 0) return error.NoModes;
    return set;
}

// =============================================================================
// Synth: disconnected islands + orphans, packed like layout_full
// =============================================================================

/// Golden angle — same constant `layout_full` uses so successive islands never stack on spokes.
const golden_angle: f32 = std.math.pi * (3.0 - @sqrt(5.0));
const component_gap_slots: f32 = 1.35;
const lone_air_slots: f32 = 0.55;

fn synthWorld(gpa: std.mem.Allocator, n: usize, opts: SynthOpts) !World {
    var rng = std.Random.DefaultPrng.init(0xA71A5);
    const rand = rng.random();

    // -- size plan: orphans first, then log-uniform islands until N is filled ------------
    var sizes: std.ArrayList(u32) = .empty;
    defer sizes.deinit(gpa);

    const orphan_target: usize = @intFromFloat(@as(f32, @floatFromInt(n)) * opts.orphan_frac);
    var remaining: usize = n;
    var orphan_n: u32 = 0;
    while (orphan_n < orphan_target and remaining > 0) : (orphan_n += 1) {
        try sizes.append(gpa, 1);
        remaining -= 1;
    }
    const log_lo = @log(@as(f32, @floatFromInt(opts.island_min)));
    const log_hi = @log(@as(f32, @floatFromInt(opts.island_max)));
    while (remaining > 0) {
        if (remaining < opts.island_min) {
            // Leftover crumbs become orphans rather than undersized "islands".
            try sizes.append(gpa, 1);
            orphan_n += 1;
            remaining -= 1;
            continue;
        }
        const u = rand.float(f32);
        var sz: u32 = @intFromFloat(@round(@exp(log_lo + u * (log_hi - log_lo))));
        sz = std.math.clamp(sz, opts.island_min, opts.island_max);
        if (sz > remaining) sz = @intCast(remaining);
        if (sz < opts.island_min and remaining >= opts.island_min) sz = opts.island_min;
        try sizes.append(gpa, sz);
        remaining -= sz;
    }

    // Biggest first — matches `packComponents` so large topics claim the centre.
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
    // Footprint radii for the packer (world units). Dense hex disc ≈ slot * √(count / π).
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
    const aspect = std.math.clamp(opts.aspect, 1.0 / 3.5, 3.5);
    const isle_r = slot * (0.5 + lone_air_slots * 0.5);
    const axes = packEllipseAxes(aspect, total_area, core_r, isle_r);

    // Park islands into the ellipse, then fill each with a local hex lattice + intra edges.
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

        // Local hex disc centred on the island. Slot matches the vault lattice so density at
        // fit-zoom reads like a real packed component, not a point cloud.
        const cols: u32 = @max(1, @as(u32, @intFromFloat(@ceil(@sqrt(@as(f32, @floatFromInt(sz)))))));
        const local_slot = if (sz == 1) slot else slot;
        for (0..sz) |k| {
            const q: i32 = @intCast(k % cols);
            const row: i32 = @intCast(k / cols);
            const lx = (@as(f32, @floatFromInt(q)) + @as(f32, @floatFromInt(row)) * 0.5) * local_slot;
            const ly = @as(f32, @floatFromInt(row)) * local_slot * hex.row_ratio;
            // Centre the lattice on the island origin.
            const ox = (@as(f32, @floatFromInt(cols - 1)) * 0.5 + @as(f32, @floatFromInt(cols - 1)) * 0.25) * local_slot;
            const oy = @as(f32, @floatFromInt(cols - 1)) * 0.5 * local_slot * hex.row_ratio;
            pos_x[cursor + @as(u32, @intCast(k))] = cx + lx - ox;
            pos_y[cursor + @as(u32, @intCast(k))] = cy + ly - oy;
        }

        // Preferential attachment *inside* the island only — no cross-island edges. Target
        // ~5 undirected degree so the web cost matches the "up to ~5 links each" goal.
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

/// Same floor-at-core-radius ellipse sizing as `layout_full.ellipseAxes`.
fn packEllipseAxes(a: f32, total_area: f32, core_r: f32, isle_r: f32) struct { x: f32, y: f32 } {
    const area_r = @sqrt(@max(total_area, 1) / std.math.pi);
    const base = @max(area_r, core_r + isle_r);
    if (a >= 1) {
        return .{ .x = base * a, .y = base };
    } else {
        return .{ .x = base, .y = base / a };
    }
}

fn printIslandStats(w: World) void {
    var linked: u32 = 0;
    var max_sz: u32 = 0;
    var sum_linked: u64 = 0;
    // Histogram buckets: 1 | 2-4 | 5-16 | 17-64 | 65-256 | 257-1k | 1k-4k | 4k-10k | 10k+
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

fn freeWorld(gpa: std.mem.Allocator, w: *World) void {
    gpa.free(w.pos_x);
    gpa.free(w.pos_y);
    gpa.free(w.edge_a);
    gpa.free(w.edge_b);
    gpa.free(w.islands);
    w.* = undefined;
}

fn makeViews(gpa: std.mem.Allocator, w: World) ![]View {
    const screen_w: f32 = 1440;
    const screen_h: f32 = 900;
    const c = w.center();
    const span = @max(w.span(), 1);
    const fit = @min(screen_w, screen_h) / span * 0.9;

    // Pick a mid-sized island (~median of linked components) and a large one for close-up.
    var mid_isle: ?Island = null;
    var big_isle: ?Island = null;
    for (w.islands) |isle| {
        if (isle.count < 2) continue;
        if (big_isle == null or isle.count > big_isle.?.count) big_isle = isle;
        // Prefer something in the 64‥1024 band — big enough to have a web, small enough that
        // framing it is what a reader does when they click a topic.
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
        .label = "overview",
    };

    if (mid_isle) |isle| {
        const pad = @max(isle.radius * 1.3, hex.layoutSpacingFor(w.len()) * 4);
        out[1] = .{
            .world = .{ .x = isle.cx - pad, .y = isle.cy - pad, .w = pad * 2, .h = pad * 2 },
            .zoom = @min(screen_w, screen_h) / (pad * 2) * 0.9,
            .label = "island",
        };
    } else {
        const half = span * 0.05;
        out[1] = .{
            .world = .{ .x = c.x - half, .y = c.y - half, .w = half * 2, .h = half * 2 },
            .zoom = fit / 0.1,
            .label = "island",
        };
    }

    if (big_isle) |isle| {
        // Dense patch near the island centre — tight enough that lattice gaps clear
        // `detail_gap_hi` (64px), so zoom-rest swell + hover push radii past `batch_max_r`
        // and the live path (shadow + fill + stroke) is what we time.
        const slot = hex.layoutSpacingFor(w.len());
        const patch = slot * 3.5; // ~7 cells across → gap ≈ 900/7 ≈ 128px at fit
        out[2] = .{
            .world = .{ .x = isle.cx - patch, .y = isle.cy - patch, .w = patch * 2, .h = patch * 2 },
            .zoom = @min(screen_w, screen_h) / (patch * 2) * 0.9,
            .label = "close",
        };
    } else {
        const half = span * 0.005;
        out[2] = .{
            .world = .{ .x = c.x - half, .y = c.y - half, .w = half * 2, .h = half * 2 },
            .zoom = fit / 0.01,
            .label = "close",
        };
    }
    return out;
}

fn writeWorldSvg(io: std.Io, gpa: std.mem.Allocator, dir: []const u8, w: World) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const size: f32 = 1600;
    const span = @max(w.span(), 1);
    const k = (size - 40) / span;
    const ox = 20 - w.min_x * k;
    const oy = 20 - w.min_y * k;

    var out: std.ArrayList(u8) = .empty;
    const add = struct {
        fn f(list: *std.ArrayList(u8), a: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
            try list.appendSlice(a, try std.fmt.allocPrint(a, fmt, args));
        }
    }.f;

    try add(&out, arena,
        \\<svg xmlns="http://www.w3.org/2000/svg" width="{d:.0}" height="{d:.0}" viewBox="0 0 {d:.0} {d:.0}">
        \\<rect width="{d:.0}" height="{d:.0}" fill="#0b0d12"/>
        \\
    , .{ size, size, size, size, size, size });

    // Island footprints first — makes the pack readable even when individual nodes are dust.
    try out.appendSlice(arena, "<g fill=\"none\" stroke=\"#3a4558\" stroke-width=\"0.6\" opacity=\"0.55\">\n");
    for (w.islands) |isle| {
        if (isle.count < 2) continue;
        const cx = ox + isle.cx * k;
        const cy = oy + isle.cy * k;
        const r = @max(isle.radius * k, 2);
        try add(&out, arena, "<circle cx=\"{d:.1}\" cy=\"{d:.1}\" r=\"{d:.1}\"/>\n", .{ cx, cy, r });
    }
    try out.appendSlice(arena, "</g>\n");

    // Sample nodes for the SVG — drawing all 500k circles makes a multi-MB file and a frozen
    // viewer. Cap at ~40k dots; every island still contributes proportionally.
    const budget: usize = 40_000;
    const step = @max(1, w.len() / budget);
    try out.appendSlice(arena, "<g fill=\"#c8d0dc\">\n");
    var i: usize = 0;
    while (i < w.len()) : (i += step) {
        const cx = ox + w.pos_x[i] * k;
        const cy = oy + w.pos_y[i] * k;
        try add(&out, arena, "<circle cx=\"{d:.1}\" cy=\"{d:.1}\" r=\"0.9\"/>\n", .{ cx, cy });
    }
    try out.appendSlice(arena, "</g>\n</svg>\n");

    std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    const path = try std.fmt.allocPrint(arena, "{s}/islands.svg", .{dir});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = out.items });
}

// =============================================================================
// Strategies
// =============================================================================

fn hoverForView(label: []const u8) bool {
    // Overview is tiles/LOD territory — proximity is gated off there in the live panel too.
    return std.mem.eql(u8, label, "island") or std.mem.eql(u8, label, "close");
}

fn rowFromGeom(mode: Mode, view: View, ms_avg: f64, geom: *const GeomScratch) RunRow {
    return .{
        .mode = mode,
        .view = view.label,
        .ms = ms_avg,
        .items = geom.discs,
        .edges = geom.lines,
        .flushes = geom.totalFlushes(),
        .verts = geom.verts,
        .extra = geom.pathed,
    };
}

fn benchBrute(gpa: std.mem.Allocator, io: std.Io, w: World, view: View, iters: usize) !RunRow {
    var geom = try GeomScratch.init(gpa);
    defer geom.deinit(gpa);
    const ctx = DrawCtx.forView(w, view, hoverForView(view.label));
    for (0..2) |_| {
        geom.resetCounts();
        emitAll(w, ctx, &geom);
        geom.finish();
    }
    const t0 = now(io);
    for (0..iters) |_| {
        geom.resetCounts();
        emitAll(w, ctx, &geom);
        geom.finish();
    }
    return rowFromGeom(.brute, view, ms(elapsed(io, t0)) / @as(f64, @floatFromInt(iters)), &geom);
}

fn emitAll(w: World, ctx: DrawCtx, geom: *GeomScratch) void {
    for (w.pos_x, w.pos_y, 0..) |x, y, i| {
        const ht = ctx.hoverT(x, y);
        geom.addNode(x, y, ctx.radius(ht, isOpenNote(i)));
    }
    for (w.edge_a, w.edge_b) |a, b| {
        geom.addLine(w.pos_x[a], w.pos_y[a], w.pos_x[b], w.pos_y[b], 1.0);
    }
}

fn benchCull(gpa: std.mem.Allocator, io: std.Io, w: World, view: View, iters: usize) !RunRow {
    const ctx = DrawCtx.forView(w, view, hoverForView(view.label));
    const pad = ctx.radius(1, true) / @max(view.zoom, 1e-6);
    const vr = inflate(view.world, pad);

    var geom = try GeomScratch.init(gpa);
    defer geom.deinit(gpa);
    for (0..2) |_| {
        geom.resetCounts();
        emitCulled(w, vr, ctx, &geom);
        geom.finish();
    }
    const t0 = now(io);
    for (0..iters) |_| {
        geom.resetCounts();
        emitCulled(w, vr, ctx, &geom);
        geom.finish();
    }
    return rowFromGeom(.cull, view, ms(elapsed(io, t0)) / @as(f64, @floatFromInt(iters)), &geom);
}

fn emitCulled(w: World, vr: dvui.Rect, ctx: DrawCtx, geom: *GeomScratch) void {
    // Still O(N): every position is tested. This is the "SOA walk alone" floor.
    for (w.pos_x, w.pos_y, 0..) |x, y, i| {
        if (!rectContains(vr, x, y)) continue;
        const ht = ctx.hoverT(x, y);
        geom.addNode(x, y, ctx.radius(ht, isOpenNote(i)));
    }
    for (w.edge_a, w.edge_b) |a, b| {
        const ax = w.pos_x[a];
        const ay = w.pos_y[a];
        const bx = w.pos_x[b];
        const by = w.pos_y[b];
        if (!segmentHits(vr, ax, ay, bx, by)) continue;
        geom.addLine(ax, ay, bx, by, 1.0);
    }
}

fn benchGrid(gpa: std.mem.Allocator, io: std.Io, w: World, view: View, iters: usize) !RunRow {
    const ctx = DrawCtx.forView(w, view, hoverForView(view.label));
    const pad = ctx.radius(1, true) / @max(view.zoom, 1e-6);
    const vr = inflate(view.world, pad);

    // Cell size ≈ one layout slot — a cell holds a handful of notes, and the view covers
    // a bounded number of cells regardless of vault size.
    const cell = @max(hex.layoutSpacingFor(w.len()) * 4, 1);
    var grid = try buildGrid(gpa, w, cell);
    defer grid.deinit(gpa);

    // Generation stamp: O(1) edge dedupe without hashing. Same pattern an SoA draw job would use.
    const stamp = try gpa.alloc(u32, w.edgeCount());
    defer gpa.free(stamp);
    @memset(stamp, 0);
    var gen: u32 = 1;

    var geom = try GeomScratch.init(gpa);
    defer geom.deinit(gpa);
    for (0..2) |_| {
        geom.resetCounts();
        _ = emitGrid(&grid, w, vr, stamp, &gen, ctx, &geom);
        geom.finish();
    }
    const t0 = now(io);
    for (0..iters) |_| {
        geom.resetCounts();
        _ = emitGrid(&grid, w, vr, stamp, &gen, ctx, &geom);
        geom.finish();
    }
    // `extra` is pathed-node count (hover/zoom past batch_max_r), not cells — cells stay in the
    // grid math; what we need to watch is how many leave the batch and become path draws.
    return rowFromGeom(.grid, view, ms(elapsed(io, t0)) / @as(f64, @floatFromInt(iters)), &geom);
}

const Grid = struct {
    cell: f32,
    origin_x: f32,
    origin_y: f32,
    cols: i32,
    rows: i32,
    /// CSR: nodes in cell `c` are `nodes[start[c]..start[c+1]]`.
    start: []u32,
    nodes: []u32,
    /// Edges whose *either* endpoint is in the cell (may duplicate across cells; draw dedupes
    /// with a generation stamp).
    edge_start: []u32,
    edges: []u32,

    fn deinit(self: *Grid, gpa: std.mem.Allocator) void {
        gpa.free(self.start);
        gpa.free(self.nodes);
        gpa.free(self.edge_start);
        gpa.free(self.edges);
    }

    fn cellIndex(self: Grid, x: f32, y: f32) ?usize {
        const cx: i32 = @intFromFloat(@floor((x - self.origin_x) / self.cell));
        const cy: i32 = @intFromFloat(@floor((y - self.origin_y) / self.cell));
        if (cx < 0 or cy < 0 or cx >= self.cols or cy >= self.rows) return null;
        return @intCast(cy * self.cols + cx);
    }
};

fn buildGrid(gpa: std.mem.Allocator, w: World, cell: f32) !Grid {
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

    // Edge index: put each edge in the cell of endpoint a (enough for "visit cell → its edges"
    // when we also scan neighbours; here we put in both cells via a second pass count).
    @memset(counts, 0);
    for (w.edge_a, w.edge_b) |a, b| {
        for ([_]u32{ a, b }) |ep| {
            const c = cellOf(w, ep, cell, cols, rows);
            counts[c] += 1;
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

fn emitGrid(
    grid: *const Grid,
    w: World,
    vr: dvui.Rect,
    stamp: []u32,
    gen: *u32,
    ctx: DrawCtx,
    geom: *GeomScratch,
) u64 {
    gen.* +%= 1;
    if (gen.* == 0) {
        @memset(stamp, 0);
        gen.* = 1;
    }
    const g = gen.*;

    const x0: i32 = @intFromFloat(@floor((vr.x - grid.origin_x) / grid.cell));
    const y0: i32 = @intFromFloat(@floor((vr.y - grid.origin_y) / grid.cell));
    const x1: i32 = @intFromFloat(@floor((vr.x + vr.w - grid.origin_x) / grid.cell));
    const y1: i32 = @intFromFloat(@floor((vr.y + vr.h - grid.origin_y) / grid.cell));

    var cells: u64 = 0;
    var y: i32 = @max(y0, 0);
    while (y <= @min(y1, grid.rows - 1)) : (y += 1) {
        var x: i32 = @max(x0, 0);
        while (x <= @min(x1, grid.cols - 1)) : (x += 1) {
            const c: usize = @intCast(y * grid.cols + x);
            cells += 1;
            const ns = grid.start[c];
            const ne = grid.start[c + 1];
            for (grid.nodes[ns..ne]) |ni| {
                if (!rectContains(vr, w.pos_x[ni], w.pos_y[ni])) continue;
                const ht = ctx.hoverT(w.pos_x[ni], w.pos_y[ni]);
                geom.addNode(w.pos_x[ni], w.pos_y[ni], ctx.radius(ht, isOpenNote(ni)));
            }
            const es = grid.edge_start[c];
            const ee = grid.edge_start[c + 1];
            for (grid.edges[es..ee]) |ei| {
                if (stamp[ei] == g) continue;
                stamp[ei] = g;
                const a = w.edge_a[ei];
                const b = w.edge_b[ei];
                if (!segmentHits(vr, w.pos_x[a], w.pos_y[a], w.pos_x[b], w.pos_y[b])) continue;
                geom.addLine(w.pos_x[a], w.pos_y[a], w.pos_x[b], w.pos_y[b], 1.0);
            }
        }
    }
    return cells;
}

fn benchLod(
    gpa: std.mem.Allocator,
    io: std.Io,
    w: World,
    py: *lod.Pyramid,
    view: View,
    iters: usize,
) !RunRow {
    const live = try w.pointsSlice(gpa);
    defer gpa.free(live);

    const lod_budget: f32 = 3000;
    const lod_min_gap_px: f32 = 24;

    var sel: std.ArrayList(lod.Visible) = .empty;
    defer sel.deinit(gpa);
    var links: std.ArrayList(lod.Link) = .empty;
    defer links.deinit(gpa);

    var geom = try GeomScratch.init(gpa);
    defer geom.deinit(gpa);
    const ctx = DrawCtx.forView(w, view, hoverForView(view.label));

    // Warmup
    for (0..2) |_| {
        const lf = py.levelFor(view.zoom, lod_min_gap_px, view.world, lod_budget);
        try py.select(gpa, lf, view.world, &sel);
        try py.gatherWeb(gpa, gpa, lf, view.world, live, null, &links);
        geom.resetCounts();
        for (sel.items) |v| {
            const p = if (v.level == 0) live[v.index] else py.levels[v.level][v.index].pos;
            const open = v.level == 0 and isOpenNote(v.index);
            const ht = if (v.level == 0) ctx.hoverT(p.x, p.y) else 0;
            geom.addNode(p.x, p.y, ctx.radius(ht, open));
        }
        for (links.items) |link| geom.addLine(link.from.x, link.from.y, link.to.x, link.to.y, 1.0);
        geom.finish();
    }

    const t0 = now(io);
    for (0..iters) |_| {
        const lf = py.levelFor(view.zoom, lod_min_gap_px, view.world, lod_budget);
        try py.select(gpa, lf, view.world, &sel);
        try py.gatherWeb(gpa, gpa, lf, view.world, live, null, &links);
        geom.resetCounts();
        for (sel.items) |v| {
            const p = if (v.level == 0) live[v.index] else py.levels[v.level][v.index].pos;
            const open = v.level == 0 and isOpenNote(v.index);
            const ht = if (v.level == 0) ctx.hoverT(p.x, p.y) else 0;
            geom.addNode(p.x, p.y, ctx.radius(ht, open));
        }
        for (links.items) |link| geom.addLine(link.from.x, link.from.y, link.to.x, link.to.y, 1.0);
        geom.finish();
    }

    return rowFromGeom(.lod, view, ms(elapsed(io, t0)) / @as(f64, @floatFromInt(iters)), &geom);
}

fn benchTiles(
    gpa: std.mem.Allocator,
    io: std.Io,
    w: World,
    py: *lod.Pyramid,
    view: View,
    iters: usize,
) !RunRow {
    _ = gpa;
    // Handover zoom ≈ where a note stops shrinking (`bubbleScreenRadius` cross) — same formula
    // as `graph.tileSwitchZoom`.
    const slot = hex.layoutSpacingFor(w.len());
    const zs = base_screen_r * (1.0 + zoom_rest_swell) / gap_radius_frac / slot;

    var last_tiles: u64 = 0;
    var last_level: i32 = 0;

    for (0..2) |_| {
        const r = tileCoverage(view, zs, py);
        last_tiles = r.tiles;
        last_level = r.level;
    }
    const t0 = now(io);
    for (0..iters) |_| {
        const r = tileCoverage(view, zs, py);
        last_tiles = r.tiles;
        last_level = r.level;
    }

    // Emitting N textured quads is trivial; report tile count as `items`, and estimate bake
    // cost separately in the verdict (bake is amortized — not per-frame once warm).
    return .{
        .mode = .tiles,
        .view = view.label,
        .ms = ms(elapsed(io, t0)) / @as(f64, @floatFromInt(iters)),
        .items = last_tiles,
        .edges = 0,
        .flushes = if (last_tiles == 0) 0 else 1,
        .verts = last_tiles * 4,
        .extra = if (last_level < 0) 0 else @intCast(last_level),
    };
}

const TileCov = struct { tiles: u64, level: i32 };

fn tileCoverage(view: View, zs: f32, py: *const lod.Pyramid) TileCov {
    const zoom = @max(view.zoom, 1e-6);
    const out = std.math.log2(zs / zoom);
    if (out <= 0) {
        // Past handover: tiles don't apply; live notes win. Report 0.
        _ = py;
        return .{ .tiles = 0, .level = -1 };
    }
    const level: i32 = @intFromFloat(@round(out));
    const density = zs * std.math.pow(f32, 2, -@as(f32, @floatFromInt(level)));
    const tile_world = @as(f32, @floatFromInt(impostor.tile_px)) / @max(density, 1e-9);

    const x0: i32 = @intFromFloat(@floor(view.world.x / tile_world));
    const y0: i32 = @intFromFloat(@floor(view.world.y / tile_world));
    const x1: i32 = @intFromFloat(@floor((view.world.x + view.world.w) / tile_world));
    const y1: i32 = @intFromFloat(@floor((view.world.y + view.world.h) / tile_world));
    const tw = @as(u64, @intCast(@max(x1 - x0 + 1, 0)));
    const th = @as(u64, @intCast(@max(y1 - y0 + 1, 0)));
    return .{ .tiles = tw * th, .level = level };
}

// =============================================================================
// Verdict
// =============================================================================

fn printVerdict(rows: []const RunRow, n: usize) !void {
    std.debug.print(
        \\--- verdict (N={d}, target ≤ {d:.2}ms) ---
        \\
        \\Compatible path under DVUI/SDL_Renderer constraints
        \\  (no custom shaders, no compute, no mipmaps, u16 indices):
        \\
        \\  1. Zoomed OUT  → impostor tiles (`tiles` mode). Frame cost is O(viewport tiles),
        \\     not O(N). Bake is amortized; once warm, a frame is a handful of textured quads.
        \\     This is the only strategy that can show 500k notes at overview without lying.
        \\
        \\  2. Mid zoom    → LOD pyramid (`lod` mode) with a hard ~3000-item budget + coalesced
        \\     web. Rings stay as batched octagon rings until they become single-pixel discs;
        \\     below that they live inside tiles, not as live geometry.
        \\
        \\  3. Zoomed IN   → spatial grid cull (`grid` mode) of live discs/lines. Only the
        \\     notes under the lens exist as geometry. Linear SOA cull (`cull`) still scans
        \\     all N positions and will miss the budget at 500k even when few are visible.
        \\
        \\SOA / ECS: useful for the *processing* side (layout, proximity, index updates) where
        \\column scans and parallel batch jobs win. It does not by itself make DVUI draw 500k
        \\discs — batching + not drawing most of them is what does. Prefer SoA columns for
        \\pos/edge arrays feeding the strategies above; a full ECS is optional scaffolding.
        \\
        \\Results that matter:
        \\
    ,
        .{ n, budget_ms },
    );

    var overview_tiles_ok = false;
    var overview_lod_ok = false;
    var island_lod_ok = false;
    var close_grid_ok = false;
    var close_cull_ok = false;
    for (rows) |r| {
        if (std.mem.eql(u8, r.view, "overview") and r.mode == .tiles and r.ms <= budget_ms) overview_tiles_ok = true;
        if (std.mem.eql(u8, r.view, "overview") and r.mode == .lod and r.ms <= budget_ms) overview_lod_ok = true;
        if (std.mem.eql(u8, r.view, "island") and r.mode == .lod and r.ms <= budget_ms) island_lod_ok = true;
        if (std.mem.eql(u8, r.view, "close") and r.mode == .grid and r.ms <= budget_ms) close_grid_ok = true;
        if (std.mem.eql(u8, r.view, "close") and r.mode == .cull and r.ms <= budget_ms) close_cull_ok = true;
    }
    std.debug.print("  overview×tiles  {s}\n", .{if (overview_tiles_ok) "OK — zoomed-out endgame holds" else "MISS or not run"});
    std.debug.print("  overview×lod    {s}\n", .{if (overview_lod_ok) "OK — budgeted markers hold" else "MISS or not run"});
    std.debug.print("  island×lod      {s}\n", .{if (island_lod_ok) "OK — one topic framed stays cheap" else "MISS or not run"});
    std.debug.print("  close×grid      {s}\n", .{if (close_grid_ok) "OK — zoomed-in live path holds" else "MISS or not run"});
    std.debug.print("  close×cull      {s}\n", .{if (close_cull_ok) "OK — but grid should still win" else "MISS (expected at 500k: O(N) scan)"});
    std.debug.print(
        \\
        \\Next: wire the winning modes into a GPU windowed harness (same batches, real
        \\`renderTriangles`) to confirm submit+composite stays under the remaining budget.
        \\
    , .{});
}

// =============================================================================
// Geometry helpers
// =============================================================================

fn inflate(r: dvui.Rect, pad: f32) dvui.Rect {
    return .{ .x = r.x - pad, .y = r.y - pad, .w = r.w + pad * 2, .h = r.h + pad * 2 };
}

fn rectContains(r: dvui.Rect, x: f32, y: f32) bool {
    return x >= r.x and y >= r.y and x < r.x + r.w and y < r.y + r.h;
}

fn segmentHits(r: dvui.Rect, ax: f32, ay: f32, bx: f32, by: f32) bool {
    if (rectContains(r, ax, ay) or rectContains(r, bx, by)) return true;
    const min_x = @min(ax, bx);
    const max_x = @max(ax, bx);
    const min_y = @min(ay, by);
    const max_y = @max(ay, by);
    return !(max_x < r.x or min_x > r.x + r.w or max_y < r.y or min_y > r.y + r.h);
}

fn now(io: std.Io) i96 {
    return std.Io.Clock.boot.now(io).nanoseconds;
}

fn elapsed(io: std.Io, since: i96) u64 {
    return @intCast(now(io) - since);
}

fn ms(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1e6;
}
