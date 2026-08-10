//! Plain-SDL3 GPU window for the Atlas render bench.
//!
//! Same island synth as the headless harness, but every frame submits real
//! `dvui.renderTriangles` batches — the path fizzy's host uses today (`dvui_sdl3` /
//! `SDL_Renderer`, not sdl3gpu).
//!
//!     zig build render-gpu -Doptimize=ReleaseFast -- [N] [--mode=lod|organic|grid|galaxy] [--view=overview|island|close] [--frames=N] [--tour]
//!
//! Keys: 1 overview · 2 island · 3 close · L lod · O organic · Y galaxy · G grid · scroll zoom · drag pan · Esc quit
//! `galaxy` is soft-sprite agents + same-language density mips (batch2d). `organic` is the prior
//! DiscBatch keep-alive field. `--tour` forces galaxy and auto-zooms overview↔close while logging
//! FPS + writing CSV/PPM under `zig-out/organic-tour/`.

const std = @import("std");
const dvui = @import("dvui");
const hex = @import("ui/hex.zig");
const lod = @import("ui/lod.zig");
const multilevel = @import("ui/multilevel.zig");
const camera_mod = @import("ui/camera.zig");
const rb = @import("ui/render_bench_world.zig");
const quadlod = @import("ui/quadlod.zig");
const quad_agents = @import("ui/quad_agents.zig");
const organic_tour = @import("ui/organic_tour.zig");
const galaxy = @import("ui/galaxy.zig");

const Camera = camera_mod;

pub const dvui_app: dvui.App = .{
    .config = .{ .startFn = appStart },
    .frameFn = appFrame,
    .initFn = appInit,
    .deinitFn = appDeinit,
};
pub const main = dvui.App.main;
pub const panic = dvui.App.panic;
pub const std_options: std.Options = .{
    .logFn = dvui.App.logFn,
};

/// `lod` = pyramid select; `organic` = DiscBatch agents; `galaxy` = soft sprites + density mips; `grid` = no hierarchy.
const Mode = enum { lod, organic, galaxy, grid };
const ViewKind = enum { overview, island, close };

const State = struct {
    gpa: std.mem.Allocator = undefined,
    world: rb.World = undefined,
    views: []rb.View = &.{},
    grid: ?rb.Grid = null,
    edge_stamp: []u32 = &.{},
    stamp_gen: u32 = 1,
    pyramid: ?lod.Pyramid = null,
    /// Point-region quadtree spine for `organic` mode.
    quad_tree: ?quadlod.Tree = null,
    live: []dvui.Point = &.{},
    /// Note degrees for topology-aware density bake (parallel to `live`).
    degrees: []u32 = &.{},
    camera: Camera = .{},
    mode: Mode = .lod,
    view_kind: ViewKind = .overview,
    n: usize = 50_000,
    /// Print the level-of-detail table across the zoom range and quit. See `sweepLevels`.
    sweep: bool = false,
    /// 0 = run until Esc; otherwise auto-quit after this many frames.
    max_frames: u32 = 0,
    frame_i: u32 = 0,
    ready: bool = false,
    drag: bool = false,
    last_mouse: dvui.Point.Physical = .{},
    /// Keep-alive coalesced masses — `organic` / `galaxy` modes. See `ui/quad_agents.zig`.
    field: ?quad_agents.Field = null,
    /// Soft-sprite atlas + density mips — `galaxy` mode.
    density: ?galaxy.Density = null,
    /// Rolling frame time for the HUD.
    frame_ms: f32 = 0,
    /// What `levelFor` decided, and the two halves it decided it from. On the HUD because the
    /// budget it is supposed to enforce is the one property the whole hierarchy exists for, and a
    /// frame that blows it looks identical to one that does not until you can see these.
    hud_lf: f32 = 0,
    hud_legible: f32 = 0,
    hud_affordable: f32 = 0,
    /// Level-0 clusters `levelFor` believes are in view, against how many `select` actually
    /// returned. A large gap here means the cost model is wrong, not the budget.
    hud_est0: f32 = 0,
    nodes_drawn: u32 = 0,
    nodes_pathed: u32 = 0,
    edges_drawn: u32 = 0,
    /// Automated zoom tour (`--tour`): settle → sample FPS → step zoom → PPM/CSV.
    tour: bool = false,
    tour_cfg: organic_tour.TourConfig = .{},
    tour_step: u32 = 0,
    tour_settle_i: u32 = 0,
    tour_z_lo: f32 = 1,
    tour_z_hi: f32 = 1,
    tour_center: dvui.Point = .{},
    tour_ms_acc: f32 = 0,
    tour_csv: std.ArrayListUnmanaged(u8) = .empty,
    tour_warns: usize = 0,
};

var state: State = .{};
var want_close: bool = false;

fn appStart() dvui.App.StartOptions {
    // `main` sets `App.main_init` before config runs — borrow process gpa/args from there.
    if (dvui.App.main_init) |init| {
        state.gpa = init.gpa;
        var n: usize = 50_000;
        var mode: Mode = .lod;
        var view: ViewKind = .overview;
        var max_frames: u32 = 0;
        var sweep_arg: bool = false;
        var tour_arg: bool = false;
        if (init.minimal.args.toSlice(init.arena.allocator())) |args| {
            var i: usize = 1;
            while (i < args.len) : (i += 1) {
                const a = args[i];
                if (std.mem.startsWith(u8, a, "--mode=")) {
                    mode = parseMode(a["--mode=".len..]) orelse mode;
                } else if (std.mem.eql(u8, a, "--mode")) {
                    i += 1;
                    if (i < args.len) mode = parseMode(args[i]) orelse mode;
                } else if (std.mem.startsWith(u8, a, "--view=")) {
                    view = std.meta.stringToEnum(ViewKind, a["--view=".len..]) orelse view;
                } else if (std.mem.eql(u8, a, "--view")) {
                    i += 1;
                    if (i < args.len) view = std.meta.stringToEnum(ViewKind, args[i]) orelse view;
                } else if (std.mem.startsWith(u8, a, "--frames=")) {
                    max_frames = std.fmt.parseInt(u32, a["--frames=".len..], 10) catch 0;
                } else if (std.mem.eql(u8, a, "--frames")) {
                    i += 1;
                    if (i < args.len) max_frames = std.fmt.parseInt(u32, args[i], 10) catch 0;
                } else if (std.mem.eql(u8, a, "--sweep")) {
                    sweep_arg = true;
                } else if (std.mem.eql(u8, a, "--tour")) {
                    tour_arg = true;
                } else if (std.fmt.parseInt(usize, a, 10)) |v| {
                    n = v;
                } else |_| {}
            }
        } else |_| {}
        state.n = n;
        state.mode = if (tour_arg) .galaxy else mode;
        state.view_kind = view;
        state.max_frames = max_frames;
        state.sweep = sweep_arg;
        state.tour = tour_arg;
    }
    return .{
        .size = .{ .w = 1440, .h = 900 },
        .min_size = .{ .w = 640, .h = 480 },
        .vsync = true,
        .title = "Atlas render-gpu",
        .persist_window_geometry = false,
    };
}

fn appInit(win: *dvui.Window) !void {
    state.gpa = win.gpa;
    const gpa = state.gpa;
    std.debug.print("render-gpu: synth N={d} mode={s} (plain sdl3)\n", .{ state.n, @tagName(state.mode) });

    state.world = try rb.synthWorld(gpa, state.n, .{});
    rb.printIslandStats(state.world);

    state.views = try rb.makeViews(gpa, state.world, 1440, 900);
    const cell = @max(hex.layoutSpacingFor(state.world.len()) * 4, 1);
    state.grid = try rb.buildGrid(gpa, state.world, cell);
    state.edge_stamp = try gpa.alloc(u32, state.world.edgeCount());
    @memset(state.edge_stamp, 0);

    state.live = try state.world.pointsSlice(gpa);
    state.degrees = try gpa.alloc(u32, state.world.len());
    @memset(state.degrees, 0);
    for (state.world.edge_a, state.world.edge_b) |a, b| {
        state.degrees[a] += 1;
        state.degrees[b] += 1;
    }

    const ml_edges = try gpa.alloc(multilevel.Edge, state.world.edgeCount());
    defer gpa.free(ml_edges);
    for (state.world.edge_a, state.world.edge_b, ml_edges) |a, b, *e| e.* = .{ .a = a, .b = b };
    var ladder = try multilevel.coarsen(gpa, state.world.len(), ml_edges);
    defer ladder.deinit(gpa);
    const cedges = try gpa.alloc(lod.CEdge, state.world.edgeCount());
    defer gpa.free(cedges);
    for (state.world.edge_a, state.world.edge_b, cedges) |a, b, *e| e.* = .{ .a = a, .b = b };
    state.pyramid = try lod.build(gpa, ladder, state.live, cedges);
    state.quad_tree = try quadlod.build(gpa, state.live);
    state.field = quad_agents.Field.init(gpa);
    state.density = try galaxy.Density.init(gpa);

    applyView(state.view_kind);
    if (state.tour) {
        try beginTour();
    }
    state.ready = true;
    if (state.tour) {
        std.debug.print("render-gpu: --tour galaxy zoom sweep → {s}\n", .{state.tour_cfg.out_dir});
    } else {
        std.debug.print("render-gpu: ready — 1/2/3 views, L lod · O organic · Y galaxy · G grid · scroll zoom · drag pan\n", .{});
    }
}

fn beginTour() !void {
    const cfg = state.tour_cfg;
    try organic_tour.ensureOutDir(dvui.io, cfg.out_dir);
    const overview = state.views[0];
    const close = state.views[2];
    state.tour_z_lo = overview.zoom;
    state.tour_z_hi = close.zoom;
    state.tour_center = .{
        .x = close.world.x + close.world.w * 0.5,
        .y = close.world.y + close.world.h * 0.5,
    };
    state.tour_step = 0;
    state.tour_settle_i = 0;
    state.tour_ms_acc = 0;
    state.tour_warns = 0;
    state.tour_csv.clearRetainingCapacity();
    try organic_tour.appendCsvHeader(&state.tour_csv, state.gpa);
    applyTourCamera();
    if (state.field) |*f| f.reset();

    std.debug.print(
        "render-gpu tour: zoom {d:.3} → {d:.3}  steps={d} settle={d}\n",
        .{ state.tour_z_lo, state.tour_z_hi, organic_tour.totalSteps(cfg.zoom_steps), cfg.settle_frames },
    );
}

fn applyTourCamera() void {
    const z = organic_tour.zoomForStep(state.tour_step, state.tour_cfg.zoom_steps, state.tour_z_lo, state.tour_z_hi);
    state.camera.center = state.tour_center;
    state.camera.zoom = z.zoom;
    state.camera.syncTargets();
    if (state.field) |*f| f.sel_zoom = -1;
}

fn tourTick(frame_ms: f32) !bool {
    // Returns true when the whole tour is finished (caller should close).
    const cfg = state.tour_cfg;
    const total = organic_tour.totalSteps(cfg.zoom_steps);
    if (state.tour_step >= total) return true;

    state.tour_ms_acc += frame_ms;
    state.tour_settle_i += 1;
    if (state.tour_settle_i < cfg.settle_frames) return false;

    const avg_ms = state.tour_ms_acc / @as(f32, @floatFromInt(cfg.settle_frames));
    const zinfo = organic_tour.zoomForStep(state.tour_step, cfg.zoom_steps, state.tour_z_lo, state.tour_z_hi);
    var label_buf: [32]u8 = undefined;
    const label = if (zinfo.going_in)
        try std.fmt.bufPrint(&label_buf, "in-{d}", .{zinfo.label_n})
    else
        try std.fmt.bufPrint(&label_buf, "out-{d}", .{zinfo.label_n});

    const field = &(state.field orelse return true);
    const s = organic_tour.sampleField(field, zinfo.zoom, avg_ms, state.tour_step, label, state.edges_drawn);
    if (s.warn) state.tour_warns += 1;
    try organic_tour.appendCsvRow(&state.tour_csv, state.gpa, s);
    organic_tour.printSample(s);

    const view = organic_tour.viewAt(state.tour_center, zinfo.zoom, cfg.screen_w, cfg.screen_h);
    var ppm_buf: [160]u8 = undefined;
    const ppm_path = try std.fmt.bufPrint(&ppm_buf, "{s}/gpu-{d:0>2}-{s}.ppm", .{ cfg.out_dir, state.tour_step, label });
    try organic_tour.writeLodPpm(dvui.io, state.gpa, ppm_path, field, view, 640, 400);

    state.tour_step += 1;
    state.tour_settle_i = 0;
    state.tour_ms_acc = 0;
    if (state.tour_step >= total) {
        var path_buf: [256]u8 = undefined;
        const csv_path = try std.fmt.bufPrint(&path_buf, "{s}/tour-gpu.csv", .{cfg.out_dir});
        try organic_tour.writeCsvFile(dvui.io, csv_path, state.tour_csv.items);
        std.debug.print(
            "render-gpu tour: done  warns={d}  csv={s}\n",
            .{ state.tour_warns, csv_path },
        );
        return true;
    }
    applyTourCamera();
    return false;
}

fn parseMode(name: []const u8) ?Mode {
    if (std.mem.eql(u8, name, "cloud") or std.mem.eql(u8, name, "leaves")) {
        std.debug.print(
            "render-gpu: --mode={s} retired; use organic. See docs/design/organic-lod.md\n",
            .{name},
        );
        return .organic;
    }
    return std.meta.stringToEnum(Mode, name);
}

/// What the hierarchy decides, and what it actually draws, at every zoom from the whole vault in
/// view to a single note filling the panel.
///
/// The budget is the one thing the level of detail exists to guarantee — a vault of any size draws
/// a bounded number of things per frame — and a guarantee is only worth what it is measured at.
/// Eyeballing a live window finds the zooms you happen to stop at; this finds the ones you don't.
fn sweepLevels(gpa: std.mem.Allocator) !void {
    const py = &(state.pyramid orelse return);
    const budget: f32 = 3000;

    var sel: std.ArrayList(lod.Visible) = .empty;
    defer sel.deinit(gpa);
    var links: std.ArrayList(lod.Link) = .empty;
    defer links.deinit(gpa);

    // Centred on a dense island rather than on the vault's middle: zoomed in, the middle of a
    // packed layout is the air between islands, and a sweep through empty space measures nothing.
    const island = state.views[1];
    state.camera.center = .{
        .x = island.world.x + island.world.w * 0.5,
        .y = island.world.y + island.world.h * 0.5,
    };
    const overview_zoom = state.views[0].zoom;
    std.debug.print("\nlevels={d}  spacing=[", .{py.levels.len});
    for (py.spacing, 0..) |sp, i| {
        if (i > 0) std.debug.print(" ", .{});
        std.debug.print("{d:.1}", .{sp});
    }
    std.debug.print("]\n  counts=[", .{});
    for (py.levels, 0..) |l, i| {
        if (i > 0) std.debug.print(" ", .{});
        std.debug.print("{d}", .{l.len});
    }
    std.debug.print("]\n\n", .{});
    std.debug.print("  {s:>10} {s:>6} {s:>7} {s:>7} {s:>10} {s:>9} {s:>9} {s:>6}\n", .{
        "zoom", "lf", "legible", "afford", "est_lvl0", "marks", "links", "over",
    });

    var zoom = overview_zoom;
    var step: usize = 0;
    while (step < 28) : (step += 1) {
        state.camera.zoom = zoom;
        state.camera.syncTargets();
        const vp = state.camera.viewport;
        const tl = state.camera.screenToWorld(.{ .x = vp.x, .y = vp.y });
        const view_w: dvui.Rect = .{
            .x = tl.x,
            .y = tl.y,
            .w = vp.w / zoom,
            .h = vp.h / zoom,
        };

        const lf = py.levelFor(zoom, 24, view_w, budget);
        const legible = py.levelFor(zoom, 24, view_w, 1e12);
        const afford = py.levelFor(1e12, 24, view_w, budget);
        const est0 = if (py.spacing[0] > 0)
            (view_w.w * view_w.h) / (py.spacing[0] * py.spacing[0])
        else
            0;

        try py.select(gpa, lf, view_w, &sel);
        try py.gatherWeb(gpa, gpa, lf, view_w, state.live, null, &links);
        const total = sel.items.len + links.items.len;
        std.debug.print("  {d:>10.5} {d:>6.2} {d:>7.2} {d:>7.2} {d:>10.0} {d:>9} {d:>9} {s:>6}\n", .{
            zoom,
            lf,
            legible,
            afford,
            est0,
            sel.items.len,
            links.items.len,
            if (@as(f32, @floatFromInt(total)) > budget * 1.5) "OVER" else "",
        });
        zoom *= 1.6;
    }
    std.debug.print("\n", .{});
}

fn appDeinit(_: *dvui.Window) void {
    const gpa = state.gpa;
    state.tour_csv.deinit(gpa);
    if (state.density) |*d| d.deinit();
    if (state.field) |*f| f.deinit();
    if (state.quad_tree) |*t| t.deinit();
    if (state.pyramid) |*p| p.deinit();
    if (state.grid) |*g| g.deinit(gpa);
    if (state.edge_stamp.len > 0) gpa.free(state.edge_stamp);
    if (state.live.len > 0) gpa.free(state.live);
    if (state.degrees.len > 0) gpa.free(state.degrees);
    if (state.views.len > 0) gpa.free(state.views);
    if (state.ready) state.world.deinit(gpa);
}

fn applyView(kind: ViewKind) void {
    state.view_kind = kind;
    const idx: usize = switch (kind) {
        .overview => 0,
        .island => 1,
        .close => 2,
    };
    const v = state.views[idx];
    state.camera.center = .{
        .x = v.world.x + v.world.w * 0.5,
        .y = v.world.y + v.world.h * 0.5,
    };
    state.camera.zoom = v.zoom;
    state.camera.syncTargets();
    state.camera.setContentExtent(state.world.span() * 0.5, 2.0);
}

fn appFrame() !dvui.App.Result {
    if (want_close) return .close;
    if (!state.ready) return .ok;

    const cw = dvui.currentWindow();
    state.camera.viewport = dvui.windowRectPixels();

    // Continuous repaint — this is a stress harness, not an idle UI.
    dvui.refresh(null, @src(), null);

    // After the viewport is known — the sweep's whole question is how much of the graph lands in
    // a screenful, which is not a question that can be asked before there is a screen.
    if (state.sweep) {
        sweepLevels(state.gpa) catch {};
        return .close;
    }

    if (!state.tour) handleInput();
    drawGraph();
    if (!state.tour) drawHud();

    const fps = cw.FPS();
    state.frame_ms = if (fps > 0.1) 1000.0 / fps else 0;
    state.frame_i += 1;

    if (state.tour) {
        // Skip the first couple frames — window/FPS often nonsense until vsync settles.
        if (state.frame_i > 3) {
            const done = tourTick(state.frame_ms) catch false;
            if (done) return .close;
        }
    }

    if (state.max_frames > 0 and state.frame_i >= state.max_frames) {
        const rs = cw.renderStats();
        std.debug.print(
            "render-gpu: done frames={d}  {d:.1} ms  {d:.0} fps  nodes={d} pathed={d} edges={d} draw_calls={d} tris={d}\n",
            .{
                state.frame_i,
                state.frame_ms,
                fps,
                state.nodes_drawn,
                state.nodes_pathed,
                state.edges_drawn,
                rs.draw_calls,
                rs.triangles,
            },
        );
        return .close;
    }
    return .ok;
}

fn handleInput() void {
    for (dvui.events()) |*e| {
        if (e.handled) continue;
        switch (e.evt) {
            .key => |ke| {
                if (ke.action != .down and ke.action != .repeat) continue;
                switch (ke.code) {
                    .escape => want_close = true,
                    .one, .kp_1 => applyView(.overview),
                    .two, .kp_2 => applyView(.island),
                    .three, .kp_3 => applyView(.close),
                    .l => state.mode = .lod,
                    .o => {
                        if (state.field) |*f| f.reset();
                        state.mode = .organic;
                    },
                    .y => {
                        if (state.field) |*f| f.reset();
                        state.mode = .galaxy;
                    },
                    .g => state.mode = .grid,
                    else => {},
                }
            },
            .mouse => |me| {
                const pt = me.p;
                switch (me.action) {
                    .press => {
                        if (me.button.pointer() or me.button == .middle) {
                            state.drag = true;
                            state.last_mouse = pt;
                        }
                    },
                    .release => {
                        if (me.button.pointer() or me.button == .middle) state.drag = false;
                    },
                    .motion => |d| {
                        if (state.drag) {
                            state.camera.panScreen(d.x, d.y);
                            state.last_mouse = pt;
                        }
                    },
                    .wheel_y => |wy| {
                        // Match graph's mouse wheel base — 1.08 jumps an order of magnitude per flick.
                        const base: f32 = 1.005;
                        const factor = @exp(@log(base) * wy);
                        if (factor != 1.0) state.camera.zoomAtScreen(factor, pt);
                    },
                    else => {},
                }
            },
            .window => |we| {
                if (we.action == .close) want_close = true;
            },
            else => {},
        }
    }
}

fn drawGraph() void {
    const arena = dvui.currentWindow().arena();
    const theme = dvui.themeGet();
    const fill_col = theme.color(.control, .fill);
    const border_col = theme.color(.window, .text).opacity(0.85);
    const edge_col = theme.color(.window, .text).opacity(0.22);
    const path_fill = theme.color(.control, .fill_hover);
    const shadow_col = dvui.Color.black.opacity(0.35);

    // Full-window clear without claiming layout — HUD floats above as a subwindow.
    dvui.windowRectPixels().fill(.{}, .{ .color = theme.color(.content, .fill) });

    const hover_world = state.camera.screenToWorld(dvui.currentWindow().mouse_pt);
    const ctx = rb.DrawCtx.forCamera(state.world, state.camera.zoom, hover_world);

    var borders = DiscBatch.init(arena);
    var fills = DiscBatch.init(arena);
    var lines = LineBatch.init(arena);
    defer {
        borders.flush();
        fills.flush();
        lines.flush();
    }

    state.nodes_drawn = 0;
    state.nodes_pathed = 0;
    state.edges_drawn = 0;

    const pad = ctx.radius(1, true) / @max(state.camera.zoom, 1e-6);
    const tl = state.camera.screenToWorld(.{ .x = state.camera.viewport.x, .y = state.camera.viewport.y });
    const view_w = rb.inflate(.{
        .x = tl.x,
        .y = tl.y,
        .w = state.camera.viewport.w / state.camera.zoom,
        .h = state.camera.viewport.h / state.camera.zoom,
    }, pad);

    switch (state.mode) {
        .lod => drawLod(arena, &borders, &fills, &lines, ctx, view_w, fill_col, border_col, edge_col, path_fill, shadow_col),
        .organic => drawOrganic(arena, &borders, &fills, &lines, ctx, view_w, fill_col, border_col, edge_col, shadow_col),
        .galaxy => {
            // Soft sprites submit their own batches — skip DiscBatch path entirely.
            borders.b = null;
            fills.b = null;
            lines.b = null;
            drawGalaxy(arena, ctx, view_w, fill_col, border_col, edge_col);
        },
        .grid => drawGridMode(&borders, &fills, &lines, ctx, view_w, fill_col, border_col, edge_col, path_fill, shadow_col),
    }
}

/// Soft-sprite sticky agents — Galaxy LOD. Density mips parked (`galaxy.density_enabled`).
fn drawGalaxy(
    arena: std.mem.Allocator,
    ctx: rb.DrawCtx,
    view_w: dvui.Rect,
    fill_col: dvui.Color,
    border_col: dvui.Color,
    edge_col: dvui.Color,
) void {
    const tree = &(state.quad_tree orelse return);
    const field = &(state.field orelse return);
    const dens = &(state.density orelse return);

    if (!dens.soft.ensureTexture()) return;

    // Optional parked density path — off in product; kept for A/B via `density_enabled`.
    const tv = galaxy.tileViewFor(state.camera.zoom);
    if (galaxy.density_enabled and tv.density_weight > 0.01) {
        _ = dens.begin(1, galaxy.density_bake_style);
        const bake_in: galaxy.BakeInput = .{
            .live = state.live,
            .degrees = state.degrees,
            .edge_a = state.world.edge_a,
            .edge_b = state.world.edge_b,
        };
        const bake_n: usize = 8;
        dens.bakeVisible(tv.primary, view_w, bake_in, bake_n);
        if (tv.neighbour) |n| dens.bakeVisible(n.level, view_w, bake_in, bake_n / 2);
        if (dens.hold_level) |hl| {
            if (hl != tv.primary) dens.drawLevel(hl, view_w, &state.camera, tv.density_weight);
        }
        dens.drawLevel(tv.primary, view_w, &state.camera, tv.density_weight);
        if (tv.neighbour) |n| dens.drawLevel(n.level, view_w, &state.camera, n.weight);
    }

    if (tv.live_weight <= 0.05) {
        state.nodes_drawn = 0;
        state.edges_drawn = 0;
        return;
    }

    // Modest pad for pan LOD stability; large pads filled the living set with off-screen marks.
    const sel_pad = @max(view_w.w, view_w.h) * 0.2;
    const sel_view = rb.inflate(view_w, sel_pad);
    field.step(tree.*, arena, .{
        .view = sel_view,
        .live = state.live,
        .zoom = state.camera.zoom,
        .note_r_px = ctx.radius(0, false),
        .dt = dvui.secondsSinceLastFrame(),
        .budget = galaxy.mark_budget,
    }) catch return;

    const qedges = try_alloc_edges(arena) orelse return;
    defer arena.free(qedges);
    var lifted: std.ArrayListUnmanaged(quadlod.LiftedEdge) = .empty;
    defer lifted.deinit(arena);
    field.gatherLiftedEdges(tree.*, qedges, arena, &lifted) catch return;

    // Stronger web than the generic theme tint — overview edges were nearly invisible.
    const web = edge_col.opacity(0.55);
    state.edges_drawn = galaxy.drawLiftedEdges(lifted.items, &state.camera, web, tv.live_weight);
    const stats = galaxy.drawAgents(&dens.soft, field, &state.camera, fill_col, border_col, tv.live_weight);
    state.nodes_drawn = stats.marks;
}

/// Budgeted keep-alive masses over the quadtree — same field the plugin overview uses.
fn drawOrganic(
    arena: std.mem.Allocator,
    borders: *DiscBatch,
    fills: *DiscBatch,
    lines: *LineBatch,
    ctx: rb.DrawCtx,
    view_w: dvui.Rect,
    fill_col: dvui.Color,
    border_col: dvui.Color,
    edge_col: dvui.Color,
    shadow_col: dvui.Color,
) void {
    const tree = &(state.quad_tree orelse return);
    const field = &(state.field orelse return);

    // Match plugin overview budget — keep draw/edge work inside a frame.
    const budget: usize = 280;
    // Stable v1: topology is selectSticky — no pyramid levelFor on the organic path.
    const sel_pad = @max(view_w.w, view_w.h) * 0.2;
    field.step(tree.*, arena, .{
        .view = rb.inflate(view_w, sel_pad),
        .live = state.live,
        .zoom = state.camera.zoom,
        .note_r_px = ctx.radius(0, false),
        .dt = dvui.secondsSinceLastFrame(),
        .budget = budget,
    }) catch return;

    const qedges = try_alloc_edges(arena) orelse return;
    defer arena.free(qedges);
    var lifted: std.ArrayListUnmanaged(quadlod.LiftedEdge) = .empty;
    defer lifted.deinit(arena);
    field.gatherLiftedEdges(tree.*, qedges, arena, &lifted) catch return;

    for (lifted.items) |link| {
        const a = state.camera.worldToScreen(link.from);
        const b = state.camera.worldToScreen(link.to);
        const dx = b.x - a.x;
        const dy = b.y - a.y;
        const fade = std.math.clamp((@sqrt(dx * dx + dy * dy) - 14) / 14, 0, 1);
        if (fade <= 0.02) continue;
        lines.add(a, b, 1.0, edge_col.opacity(fade));
        state.edges_drawn += 1;
    }

    for (field.agents.items) |a| {
        // Batch at true radius — pathing thousands of hubs was the FPS cliff after a fast zoom.
        emitNode(
            borders,
            fills,
            state.camera.worldToScreen(a.pos),
            @max(a.r_px, 0.6),
            fill_col,
            border_col,
            fill_col,
            shadow_col,
            arena,
            .batch_sized,
        );
    }
}

fn try_alloc_edges(arena: std.mem.Allocator) ?[]quadlod.Edge {
    const n = state.world.edgeCount();
    if (n == 0) return &.{};
    // Strided sample — keep under lift examine cap (2k); 8k samples were wasted work.
    const max_n: usize = 2_400;
    const stride = @max(1, n / max_n);
    const out_n = (n + stride - 1) / stride;
    const edges = arena.alloc(quadlod.Edge, out_n) catch return null;
    var oi: usize = 0;
    var i: usize = 0;
    while (i < n and oi < out_n) : (i += stride) {
        edges[oi] = .{ .a = state.world.edge_a[i], .b = state.world.edge_b[i] };
        oi += 1;
    }
    return edges[0..oi];
}

fn drawLod(
    arena: std.mem.Allocator,
    borders: *DiscBatch,
    fills: *DiscBatch,
    lines: *LineBatch,
    ctx: rb.DrawCtx,
    view_w: dvui.Rect,
    fill_col: dvui.Color,
    border_col: dvui.Color,
    edge_col: dvui.Color,
    path_fill: dvui.Color,
    shadow_col: dvui.Color,
) void {
    _ = path_fill;
    const py = &(state.pyramid orelse return);
    var sel: std.ArrayList(lod.Visible) = .empty;
    defer sel.deinit(arena);
    var links: std.ArrayList(lod.Link) = .empty;
    defer links.deinit(arena);

    // `levelFor`'s cost model assumes one level. During a cross-fade `select` emits both, so
    // tighten the budget when `lf` sits inside the dissolve band or mid-zoom doubles the work.
    const base_budget: f32 = 3000;
    var lf = py.levelFor(state.camera.zoom, 24, view_w, base_budget);
    recordLevelDiag(py.*, view_w, lf, base_budget);
    const into_split = @ceil(lf) - lf;
    if (into_split > 1e-4 and into_split < 0.75) {
        lf = py.levelFor(state.camera.zoom, 24, view_w, base_budget / 1.55);
    }
    py.select(arena, lf, view_w, &sel) catch return;
    py.gatherWeb(arena, arena, lf, view_w, state.live, null, &links) catch return;

    for (links.items) |link| {
        const a = state.camera.worldToScreen(link.from);
        const b = state.camera.worldToScreen(link.to);
        lines.add(a, b, 1.0, edge_col);
        state.edges_drawn += 1;
    }

    // Gap-sized "mark" radius — what a note emerges from during a split (same idea as graph.zig).
    const mark_r = @max(rb.gap_radius_frac * ctx.gap_px, 0.6);
    for (sel.items) |v| {
        const a = std.math.clamp(v.alpha, 0, 1);
        if (a <= 0.04) continue;

        const p = if (v.level == 0) state.live[v.index] else py.levels[v.level][v.index].pos;
        const settled: f32 = if (v.level == 0) blk: {
            const open = rb.isOpenNote(v.index);
            const ht = ctx.hoverT(p.x, p.y);
            break :blk ctx.radius(ht, open);
        } else blk: {
            const c = py.levels[v.level][v.index];
            const load = @log(1.0 + @as(f32, @floatFromInt(c.count))) / @log(1.0 + 256.0);
            break :blk ctx.radius(0, false) * (1.0 + 0.35 * std.math.clamp(load, 0, 1));
        };
        // Grow from mark size with alpha so parent/child don't fight as two full-size discs.
        const r = mark_r + (settled - mark_r) * a;
        // LOD stays on the triangle batches — path-per-node is the ~12 fps cliff mid-zoom.
        emitNode(
            borders,
            fills,
            state.camera.worldToScreen(p),
            r,
            fill_col.opacity(a),
            border_col.opacity(a),
            fill_col.opacity(a),
            shadow_col.opacity(a),
            arena,
            .batch,
        );
    }
}

fn drawGridMode(
    borders: *DiscBatch,
    fills: *DiscBatch,
    lines: *LineBatch,
    ctx: rb.DrawCtx,
    view_w: dvui.Rect,
    fill_col: dvui.Color,
    border_col: dvui.Color,
    edge_col: dvui.Color,
    path_fill: dvui.Color,
    shadow_col: dvui.Color,
) void {
    const grid = &(state.grid orelse return);
    state.stamp_gen +%= 1;
    if (state.stamp_gen == 0) {
        @memset(state.edge_stamp, 0);
        state.stamp_gen = 1;
    }
    const g = state.stamp_gen;
    const arena = dvui.currentWindow().arena();

    const x0: i32 = @intFromFloat(@floor((view_w.x - grid.origin_x) / grid.cell));
    const y0: i32 = @intFromFloat(@floor((view_w.y - grid.origin_y) / grid.cell));
    const x1: i32 = @intFromFloat(@floor((view_w.x + view_w.w - grid.origin_x) / grid.cell));
    const y1: i32 = @intFromFloat(@floor((view_w.y + view_w.h - grid.origin_y) / grid.cell));

    var y: i32 = @max(y0, 0);
    while (y <= @min(y1, grid.rows - 1)) : (y += 1) {
        var x: i32 = @max(x0, 0);
        while (x <= @min(x1, grid.cols - 1)) : (x += 1) {
            const c: usize = @intCast(y * grid.cols + x);
            for (grid.nodes[grid.start[c]..grid.start[c + 1]]) |ni| {
                if (!rb.rectContains(view_w, state.world.pos_x[ni], state.world.pos_y[ni])) continue;
                const ht = ctx.hoverT(state.world.pos_x[ni], state.world.pos_y[ni]);
                const r = ctx.radius(ht, rb.isOpenNote(ni));
                const screen = state.camera.worldToScreen(.{ .x = state.world.pos_x[ni], .y = state.world.pos_y[ni] });
                emitNode(borders, fills, screen, r, fill_col, border_col, path_fill, shadow_col, arena, .auto);
            }
            for (grid.edges[grid.edge_start[c]..grid.edge_start[c + 1]]) |ei| {
                if (state.edge_stamp[ei] == g) continue;
                state.edge_stamp[ei] = g;
                const a = state.world.edge_a[ei];
                const b = state.world.edge_b[ei];
                if (!rb.segmentHits(view_w, state.world.pos_x[a], state.world.pos_y[a], state.world.pos_x[b], state.world.pos_y[b])) continue;
                lines.add(
                    state.camera.worldToScreen(.{ .x = state.world.pos_x[a], .y = state.world.pos_y[a] }),
                    state.camera.worldToScreen(.{ .x = state.world.pos_x[b], .y = state.world.pos_y[b] }),
                    1.0,
                    edge_col,
                );
                state.edges_drawn += 1;
            }
        }
    }
}

/// Pull apart what `levelFor` just decided, so the HUD can show *why* rather than only what.
///
/// Recomputed here rather than returned from `lod.zig`: the split is only ever interesting to a
/// diagnostic, and threading two extra out-parameters through the real call site to serve one
/// would be paying for it on every frame of the plugin as well.
fn recordLevelDiag(py: lod.Pyramid, view_w: dvui.Rect, lf: f32, budget: f32) void {
    state.hud_lf = lf;
    state.hud_legible = py.levelFor(state.camera.zoom, 24, view_w, 1e12);
    state.hud_affordable = py.levelFor(1e12, 24, view_w, budget);
    state.hud_est0 = if (py.spacing.len > 0 and py.spacing[0] > 0)
        (view_w.w * view_w.h) / (py.spacing[0] * py.spacing[0])
    else
        0;
}

/// `batch` clamps to `batch_max_r` (LOD path — cheap at the cost of size).
/// `batch_sized` keeps true radius in the triangle batch (organic masses).
/// `auto` paths above `batch_max_r`.
const EmitMode = enum { auto, batch, batch_sized };

fn emitNode(
    borders: *DiscBatch,
    fills: *DiscBatch,
    screen: dvui.Point.Physical,
    r_px: f32,
    fill_col: dvui.Color,
    border_col: dvui.Color,
    path_fill: dvui.Color,
    shadow_col: dvui.Color,
    arena: std.mem.Allocator,
    mode: EmitMode,
) void {
    const use_batch = mode == .batch or mode == .batch_sized or r_px <= rb.batch_max_r;
    if (use_batch) {
        state.nodes_drawn += 1;
        const r = if (mode == .batch) @min(r_px, rb.batch_max_r) else r_px;
        // Thin the ring on small marks so a point is mostly fill, not a hollow that vanishes.
        const border = @min(rb.node_border_px, @max(r * 0.35, 0.4));
        const inner = @max(r - border, r * 0.55);
        borders.addRing(screen, r, inner, border_col);
        fills.add(screen, inner, fill_col);
        return;
    }
    state.nodes_pathed += 1;
    // Path path — one draw call per primitive, matching graph.drawNodes.
    if (r_px >= rb.shadow_min_r) {
        var sh = dvui.Path.Builder.init(arena);
        sh.addArc(.{ .x = screen.x + rb.shadow_offset, .y = screen.y + rb.shadow_offset }, r_px, std.math.tau, 0, true);
        sh.build().fillConvex(.{ .color = shadow_col, .fade = 4 });
    }
    var body = dvui.Path.Builder.init(arena);
    body.addArc(screen, r_px, std.math.tau, 0, true);
    body.build().fillConvex(.{ .color = path_fill, .fade = 1 });
    var ring = dvui.Path.Builder.init(arena);
    ring.addArc(screen, r_px, std.math.tau, 0, true);
    ring.build().stroke(.{ .thickness = rb.node_border_px, .color = border_col, .closed = true });
}

fn drawHud() void {
    const cw = dvui.currentWindow();
    const theme = dvui.themeGet();
    const rs = cw.renderStats();
    const fps = cw.FPS();
    const ok = state.frame_ms <= (1000.0 / 120.0) + 0.5;
    const organic = state.mode == .organic or state.mode == .galaxy;
    const hud_h: f32 = if (organic) 168 else 142;

    var fw: dvui.FloatingWidget = undefined;
    fw.init(@src(), .{ .mouse_events = false }, .{
        .rect = .{ .x = 12, .y = 12, .w = if (organic) 520 else 460, .h = hud_h },
        .expand = .none,
        .background = true,
        .color_fill = theme.color(.window, .fill).opacity(0.92),
        .corners = .round(6),
        .padding = .{ .x = 10, .y = 8, .w = 10, .h = 8 },
    });
    defer fw.deinit();

    var col = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .background = false });
    defer col.deinit();

    dvui.label(@src(), "{d:.1} ms  {d:.0} fps  {s}", .{
        state.frame_ms,
        fps,
        if (ok) "≤120Hz" else "MISS",
    }, .{});
    dvui.label(@src(), "N={d}  mode={s}  view={s}", .{
        state.world.len(),
        @tagName(state.mode),
        @tagName(state.view_kind),
    }, .{});
    dvui.label(@src(), "nodes {d}  pathed {d}  edges {d}", .{
        state.nodes_drawn,
        state.nodes_pathed,
        state.edges_drawn,
    }, .{});
    dvui.label(@src(), "draw_calls {d}  tris {d}", .{ rs.draw_calls, rs.triangles }, .{});
    dvui.label(@src(), "lf {d:.2}  (legible {d:.2} · afford {d:.2})  est_lvl0 {d:.0}", .{
        state.hud_lf,
        state.hud_legible,
        state.hud_affordable,
        state.hud_est0,
    }, .{ .color_text = if (state.hud_lf <= 0.01 and state.nodes_drawn > 5000)
        theme.color(.err, .fill)
    else
        theme.color(.window, .text) });
    if (organic) {
        if (state.field) |*field| {
            const nodes = if (state.quad_tree) |t| t.nodeCount() else 0;
            var opens: usize = 0;
            for (field.sticky.open) |o| {
                if (o) opens += 1;
            }
            dvui.label(@src(), "agents {d}  open {d}  qnodes {d}  bound={s}  settled={s}", .{
                field.agents.items.len,
                opens,
                nodes,
                if (field.budget_bound) "Y" else "n",
                if (field.settled) "Y" else "n",
            }, .{ .color_text = if (field.budget_bound)
                theme.color(.err, .fill)
            else
                theme.color(.window, .text) });
        }
    }
    dvui.label(@src(), "1/2/3 view · L lod · O organic · Y galaxy · G grid · scroll · drag", .{}, .{
        .color_text = theme.color(.control, .text),
    });
}

// =============================================================================
// Batches — same shape as graph.DiscBatch / LineBatch, submitting to the GPU
// =============================================================================

const batch_sides: usize = 64;

const DiscBatch = struct {
    arena: std.mem.Allocator,
    b: ?dvui.Triangles.Builder = null,

    const verts_per: usize = batch_sides + 1;
    const idx_per: usize = batch_sides * 3;
    const max_discs: usize = std.math.maxInt(u16) / verts_per;

    fn init(arena: std.mem.Allocator) DiscBatch {
        return .{ .arena = arena };
    }

    fn ensure(self: *DiscBatch, need_vtx: usize, need_idx: usize) ?*dvui.Triangles.Builder {
        if (self.b) |*b| {
            if (b.vertexes.items.len + need_vtx > max_discs * verts_per or
                b.indices.items.len + need_idx > max_discs * idx_per)
            {
                self.flush();
            }
        }
        if (self.b == null) {
            self.b = dvui.Triangles.Builder.init(
                self.arena,
                max_discs * verts_per,
                max_discs * idx_per,
            ) catch return null;
        }
        return &(self.b.?);
    }

    fn sideCount(rad: f32) usize {
        const want = @as(usize, @intFromFloat(@max(rad, 1.5) * 2.5));
        return std.math.clamp(want, 12, batch_sides);
    }

    fn add(self: *DiscBatch, center: dvui.Point.Physical, r: f32, color: dvui.Color) void {
        const rad = @max(r, 0.5);
        const n = sideCount(rad);
        const b = self.ensure(1 + n, n * 3) orelse return;
        const base: u16 = @intCast(b.vertexes.items.len);
        const col: dvui.Color.PMA = .fromColor(color);
        b.appendVertex(.{ .pos = center, .col = col });
        for (0..n) |s| {
            const a = std.math.tau * @as(f32, @floatFromInt(s)) / @as(f32, @floatFromInt(n));
            b.appendVertex(.{
                .pos = .{ .x = center.x + @cos(a) * rad, .y = center.y + @sin(a) * rad },
                .col = col,
            });
        }
        for (0..n) |s| {
            const cur: u16 = @intCast(base + 1 + s);
            const nxt: u16 = @intCast(base + 1 + (s + 1) % n);
            b.appendTriangles(&.{ base, cur, nxt });
        }
    }

    fn addRing(self: *DiscBatch, center: dvui.Point.Physical, outer_r: f32, inner_r: f32, color: dvui.Color) void {
        const outer = @max(outer_r, 0.5);
        const inner = @min(@max(inner_r, 0.0), outer - 0.25);
        if (inner <= 0.01) {
            self.add(center, outer, color);
            return;
        }
        const n = sideCount(outer);
        const b = self.ensure(n * 2, n * 6) orelse return;
        const base: u16 = @intCast(b.vertexes.items.len);
        const col: dvui.Color.PMA = .fromColor(color);
        for (0..n) |s| {
            const a = std.math.tau * @as(f32, @floatFromInt(s)) / @as(f32, @floatFromInt(n));
            b.appendVertex(.{
                .pos = .{ .x = center.x + @cos(a) * outer, .y = center.y + @sin(a) * outer },
                .col = col,
            });
        }
        for (0..n) |s| {
            const a = std.math.tau * @as(f32, @floatFromInt(s)) / @as(f32, @floatFromInt(n));
            b.appendVertex(.{
                .pos = .{ .x = center.x + @cos(a) * inner, .y = center.y + @sin(a) * inner },
                .col = col,
            });
        }
        for (0..n) |s| {
            const o0: u16 = @intCast(base + s);
            const o1: u16 = @intCast(base + (s + 1) % n);
            const r0: u16 = @intCast(base + n + s);
            const r1: u16 = @intCast(base + n + (s + 1) % n);
            b.appendTriangles(&.{ o0, o1, r1, o0, r1, r0 });
        }
    }

    fn flush(self: *DiscBatch) void {
        var b = self.b orelse return;
        self.b = null;
        if (b.vertexes.items.len == 0) return;
        dvui.renderTriangles(b.build_unowned(), null) catch {};
    }
};

const LineBatch = struct {
    arena: std.mem.Allocator,
    b: ?dvui.Triangles.Builder = null,

    const verts_per: usize = 4;
    const idx_per: usize = 6;
    const max_lines: usize = std.math.maxInt(u16) / verts_per;

    fn init(arena: std.mem.Allocator) LineBatch {
        return .{ .arena = arena };
    }

    fn add(self: *LineBatch, a: dvui.Point.Physical, b_pt: dvui.Point.Physical, thickness: f32, color: dvui.Color) void {
        const dx = b_pt.x - a.x;
        const dy = b_pt.y - a.y;
        const len = @sqrt(dx * dx + dy * dy);
        if (len < 1e-3) return;
        const h = @max(thickness, 0.75) * 0.5;
        const nx = -dy / len * h;
        const ny = dx / len * h;

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
    }

    fn flush(self: *LineBatch) void {
        var b = self.b orelse return;
        self.b = null;
        if (b.vertexes.items.len == 0) return;
        dvui.renderTriangles(b.build_unowned(), null) catch {};
    }
};
