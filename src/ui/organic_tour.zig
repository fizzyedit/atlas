//! Automated zoom tour for organic LOD — metrics + diagnostic frame dumps.
//!
//! Used by `organic_tour_main` (headless step timing) and `render-gpu --tour` (real GPU FPS).
//! See docs/design/organic-lod.md.

const std = @import("std");
const dvui = @import("dvui");
const quadlod = @import("quadlod.zig");
const quad_agents = @import("quad_agents.zig");

pub const Sample = struct {
    step: u32,
    label: []const u8,
    zoom: f32,
    /// Wall / frame time in ms (GPU tour fills from FPS; headless from step timer).
    /// Headless: average over settle frames *including* park-cache early-outs.
    ms: f32,
    fps: f32,
    agents: usize,
    singles: usize,
    edges: usize,
    settled: bool,
    budget_bound: bool,
    min_r: f32,
    max_r: f32,
    mean_count: f32,
    /// True if this step looks like a failure mode.
    warn: bool = false,
    warn_msg: []const u8 = "",

    // -- select / present breakdown (headless tour; zeroed on GPU tour) -----------------------
    /// ms of the first settle frame (always re-selects because sel_zoom is forced stale).
    first_ms: f32 = 0,
    /// Settle frames that did real work (not park-cache early-out).
    frames_ran: u32 = 0,
    /// Of those, how many called `selectStickyEx`.
    select_calls: u32 = 0,
    /// Mean select cost over frames that selected (ms).
    select_ms: f32 = 0,
    /// Mean present cost (touch+dying+integrate+purge) over frames that ran (ms).
    present_ms: f32 = 0,
    /// Peak dying-agent count observed during the settle window.
    peak_dying: u32 = 0,
    /// Peak sticky-open bit count (deep sticky on zoom-out is the merge tax).
    peak_open: u32 = 0,
    /// `trimByMergingUp` iterations on the (last) select of this step.
    trim_iters: u32 = 0,
    /// Nodes visited by the level-uniform BFS on that select.
    sel_visited: u32 = 0,
    /// Sticky bits cleared by pre-BFS prune on that select.
    sticky_pruned: u32 = 0,
};

pub const TourConfig = struct {
    /// Frames to hold at each zoom before sampling (springs + sticky settle).
    settle_frames: u32 = 20,
    /// Zoom multipliers from overview toward close (and reverse).
    zoom_steps: u32 = 10,
    screen_w: f32 = 1440,
    screen_h: f32 = 900,
    budget: usize = 280,
    note_r_px: f32 = 6,
    out_dir: []const u8 = "zig-out/organic-tour",
};

pub fn ensureOutDir(io: std.Io, dir: []const u8) !void {
    std.Io.Dir.cwd().createDirPath(io, dir) catch {};
}

pub fn sampleField(
    field: *const quad_agents.Field,
    zoom: f32,
    ms: f32,
    step: u32,
    label: []const u8,
    edge_n: usize,
) Sample {
    var singles: usize = 0;
    var min_r: f32 = std.math.floatMax(f32);
    var max_r: f32 = 0;
    var sum_count: f32 = 0;
    var n: usize = 0;
    for (field.agents.items) |a| {
        if (a.dying) continue; // fade extras — metrics track living topology only
        n += 1;
        if (a.count == 1) singles += 1;
        min_r = @min(min_r, a.r_px);
        max_r = @max(max_r, a.r_px);
        sum_count += @floatFromInt(a.count);
    }
    if (n == 0) min_r = 0;
    const mean_c = if (n > 0) sum_count / @as(f32, @floatFromInt(n)) else 0;
    const fps = if (ms > 1e-3) 1000.0 / ms else 0;

    var warn = false;
    var warn_msg: []const u8 = "";
    if (ms > 33.0) {
        warn = true;
        warn_msg = "slow_frame";
    } else if (n >= 260 and singles > n / 2) {
        warn = true;
        warn_msg = "dust_explode";
    } else if (max_r > 42.0) {
        // Present soft-caps masses at 40px — anything above means the clamp regressing.
        warn = true;
        warn_msg = "radius_runaway";
    }

    return .{
        .step = step,
        .label = label,
        .zoom = zoom,
        .ms = ms,
        .fps = fps,
        .agents = n,
        .singles = singles,
        .edges = edge_n,
        .settled = field.settled,
        .budget_bound = field.budget_bound,
        .min_r = min_r,
        .max_r = max_r,
        .mean_count = mean_c,
        .warn = warn,
        .warn_msg = warn_msg,
    };
}

pub fn appendCsvHeader(buf: *std.ArrayListUnmanaged(u8), gpa: std.mem.Allocator) !void {
    try buf.appendSlice(gpa,
        \\step,label,zoom,ms,fps,agents,singles,edges,settled,bound,min_r,max_r,mean_count,warn,first_ms,frames_ran,select_calls,select_ms,present_ms,peak_dying,peak_open,trim_iters,sel_visited,sticky_pruned
        \\
    );
}

pub fn appendCsvRow(buf: *std.ArrayListUnmanaged(u8), gpa: std.mem.Allocator, s: Sample) !void {
    const line = try std.fmt.allocPrint(gpa, "{d},{s},{d:.4},{d:.2},{d:.1},{d},{d},{d},{s},{s},{d:.2},{d:.2},{d:.1},{s},{d:.2},{d},{d},{d:.2},{d:.2},{d},{d},{d},{d},{d}\n", .{
        s.step,
        s.label,
        s.zoom,
        s.ms,
        s.fps,
        s.agents,
        s.singles,
        s.edges,
        if (s.settled) "Y" else "n",
        if (s.budget_bound) "Y" else "n",
        s.min_r,
        s.max_r,
        s.mean_count,
        if (s.warn) s.warn_msg else "",
        s.first_ms,
        s.frames_ran,
        s.select_calls,
        s.select_ms,
        s.present_ms,
        s.peak_dying,
        s.peak_open,
        s.trim_iters,
        s.sel_visited,
        s.sticky_pruned,
    });
    defer gpa.free(line);
    try buf.appendSlice(gpa, line);
}

pub fn printSample(s: Sample) void {
    const flag = if (s.warn) " WARN" else "";
    // Lead with select/first-frame — the settle-averaged `ms` dilutes a one-shot select across
    // spring frames and hid the zoom-out asymmetry that the breakdown exists to expose.
    std.debug.print(
        "  [{d:>2}] {s:<12} z={d:>8.3}  sel={d:>5.2}ms first={d:>5.2}ms avg={d:>4.2}ms  agents={d:<4} sing={d:<4} open={d:<4} dying={d:<4} trim={d}{s}\n",
        .{
            s.step,
            s.label,
            s.zoom,
            s.select_ms,
            s.first_ms,
            s.ms,
            s.agents,
            s.singles,
            s.peak_open,
            s.peak_dying,
            s.trim_iters,
            flag,
        },
    );
}

/// Software LOD map: agents as filled discs. Useful without GPU readback.
pub fn writeLodPpm(
    io: std.Io,
    gpa: std.mem.Allocator,
    path: []const u8,
    field: *const quad_agents.Field,
    view: dvui.Rect,
    w: u32,
    h: u32,
) !void {
    const pixels = try gpa.alloc(u8, w * h * 3);
    defer gpa.free(pixels);
    @memset(pixels, 18); // dark grey

    if (view.w > 0 and view.h > 0) {
        for (field.agents.items) |a| {
            const u = (a.pos.x - view.x) / view.w;
            const v = (a.pos.y - view.y) / view.h;
            if (u < 0 or u > 1 or v < 0 or v > 1) continue;
            const cx: i32 = @intFromFloat(u * @as(f32, @floatFromInt(w - 1)));
            const cy: i32 = @intFromFloat(v * @as(f32, @floatFromInt(h - 1)));
            // Radius in image pixels from screen radius (approx: r_px relative to 1440).
            const pr: i32 = @intFromFloat(@max(a.r_px * @as(f32, @floatFromInt(w)) / 1440.0, 1));
            const is_note = a.count == 1;
            const col: [3]u8 = if (is_note) .{ 220, 220, 230 } else .{ 120, 160, 220 };
            var dy: i32 = -pr;
            while (dy <= pr) : (dy += 1) {
                var dx: i32 = -pr;
                while (dx <= pr) : (dx += 1) {
                    if (dx * dx + dy * dy > pr * pr) continue;
                    const x = cx + dx;
                    const y = cy + dy;
                    if (x < 0 or y < 0 or x >= w or y >= h) continue;
                    const i = (@as(usize, @intCast(y)) * w + @as(usize, @intCast(x))) * 3;
                    pixels[i] = col[0];
                    pixels[i + 1] = col[1];
                    pixels[i + 2] = col[2];
                }
            }
        }
    }

    const header = try std.fmt.allocPrint(gpa, "P6\n{d} {d}\n255\n", .{ w, h });
    defer gpa.free(header);
    var blob: std.ArrayListUnmanaged(u8) = .empty;
    defer blob.deinit(gpa);
    try blob.appendSlice(gpa, header);
    try blob.appendSlice(gpa, pixels);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = blob.items });
}

pub fn writeCsvFile(io: std.Io, path: []const u8, csv: []const u8) !void {
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = csv });
}

/// Build a world-space view rect covering `screen_w×screen_h` at `zoom` around `center`.
pub fn viewAt(center: dvui.Point, zoom: f32, screen_w: f32, screen_h: f32) dvui.Rect {
    const zw = screen_w / @max(zoom, 1e-6);
    const zh = screen_h / @max(zoom, 1e-6);
    return .{
        .x = center.x - zw * 0.5,
        .y = center.y - zh * 0.5,
        .w = zw,
        .h = zh,
    };
}

fn nowNs(io: std.Io) i96 {
    return std.Io.Clock.boot.now(io).nanoseconds;
}

/// Run headless zoom tour: overview → close → overview. Returns samples + writes CSV/PPMs.
pub fn runHeadless(
    gpa: std.mem.Allocator,
    io: std.Io,
    tree: quadlod.Tree,
    live: []const dvui.Point,
    center: dvui.Point,
    z_lo: f32,
    z_hi: f32,
    cfg: TourConfig,
) ![]Sample {
    try ensureOutDir(io, cfg.out_dir);

    var field = quad_agents.Field.init(gpa);
    defer field.deinit();

    var samples: std.ArrayListUnmanaged(Sample) = .empty;
    errdefer {
        for (samples.items) |s| gpa.free(s.label);
        samples.deinit(gpa);
    }

    var csv: std.ArrayListUnmanaged(u8) = .empty;
    defer csv.deinit(gpa);
    try appendCsvHeader(&csv, gpa);

    // Labels: in-0..in-(n-1), out-0..out-(n-2)  (don't duplicate closest twice)
    const n_in = cfg.zoom_steps;
    const n_out = if (cfg.zoom_steps > 1) cfg.zoom_steps - 1 else 0;
    const total = n_in + n_out;

    var step_i: u32 = 0;
    while (step_i < total) : (step_i += 1) {
        const going_in = step_i < n_in;
        const t: f32 = if (going_in)
            @as(f32, @floatFromInt(step_i)) / @as(f32, @floatFromInt(@max(n_in - 1, 1)))
        else
            1.0 - @as(f32, @floatFromInt(step_i - n_in + 1)) / @as(f32, @floatFromInt(@max(n_out, 1)));
        // Smoothstep ease for denser mid samples.
        const u = t * t * (3 - 2 * t);
        const zoom = z_lo * std.math.pow(f32, z_hi / z_lo, u);
        const view = viewAt(center, zoom, cfg.screen_w, cfg.screen_h);

        const label = if (going_in)
            try std.fmt.allocPrint(gpa, "in-{d}", .{step_i})
        else
            try std.fmt.allocPrint(gpa, "out-{d}", .{step_i - n_in});
        errdefer gpa.free(label);

        // Force re-select when zoom changes (park cache).
        field.sel_zoom = -1;

        var frames_ran: u32 = 0;
        var select_calls: u32 = 0;
        var select_ns_sum: u64 = 0;
        var present_ns_sum: u64 = 0;
        var peak_dying: u32 = 0;
        var peak_open: u32 = 0;
        var trim_iters: u32 = 0;
        var sel_visited: u32 = 0;
        var sticky_pruned: u32 = 0;
        var first_ns: u64 = 0;

        const t0 = nowNs(io);
        var f: u32 = 0;
        while (f < cfg.settle_frames) : (f += 1) {
            const frame_t0 = nowNs(io);
            try field.step(tree, gpa, .{
                .view = view,
                .live = live,
                .zoom = zoom,
                .note_r_px = cfg.note_r_px,
                .dt = 1.0 / 60.0,
                .budget = cfg.budget,
                .profile = true,
            });
            const frame_ns: u64 = @intCast(nowNs(io) - frame_t0);
            if (f == 0) first_ns = frame_ns;

            const p = field.last_profile;
            if (!p.early_out) {
                frames_ran += 1;
                present_ns_sum += p.presentNs();
            }
            if (p.did_select) {
                select_calls += 1;
                select_ns_sum += p.select_ns;
                trim_iters = p.select.trim_iters;
                sel_visited = p.select.visited;
                sticky_pruned = p.select.sticky_pruned;
            }
            peak_dying = @max(peak_dying, p.dying_n);
            peak_open = @max(peak_open, p.sticky_open_n);
        }
        const ns: u64 = @intCast(nowNs(io) - t0);
        const ms = @as(f32, @floatFromInt(ns)) / 1e6 / @as(f32, @floatFromInt(cfg.settle_frames));

        var s = sampleField(&field, zoom, ms, step_i, label, 0);
        s.first_ms = @as(f32, @floatFromInt(first_ns)) / 1e6;
        s.frames_ran = frames_ran;
        s.select_calls = select_calls;
        s.select_ms = if (select_calls > 0)
            @as(f32, @floatFromInt(select_ns_sum)) / 1e6 / @as(f32, @floatFromInt(select_calls))
        else
            0;
        s.present_ms = if (frames_ran > 0)
            @as(f32, @floatFromInt(present_ns_sum)) / 1e6 / @as(f32, @floatFromInt(frames_ran))
        else
            0;
        s.peak_dying = peak_dying;
        s.peak_open = peak_open;
        s.trim_iters = trim_iters;
        s.sel_visited = sel_visited;
        s.sticky_pruned = sticky_pruned;
        try samples.append(gpa, s);
        try appendCsvRow(&csv, gpa, s);
        printSample(s);

        var ppm_buf: [160]u8 = undefined;
        const ppm_path = try std.fmt.bufPrint(&ppm_buf, "{s}/step-{d:0>2}-{s}.ppm", .{ cfg.out_dir, step_i, label });
        try writeLodPpm(io, gpa, ppm_path, &field, view, 640, 400);
    }

    const csv_path = try std.fmt.allocPrint(gpa, "{s}/tour.csv", .{cfg.out_dir});
    defer gpa.free(csv_path);
    try writeCsvFile(io, csv_path, csv.items);

    std.debug.print("organic-tour: wrote {s} and {d} ppm frames under {s}\n", .{ csv_path, total, cfg.out_dir });
    return try samples.toOwnedSlice(gpa);
}

/// Free labels owned by `runHeadless` samples (and the slice itself).
pub fn freeSamples(gpa: std.mem.Allocator, samples: []Sample) void {
    for (samples) |s| gpa.free(s.label);
    gpa.free(samples);
}

/// Zoom for tour step `step_i` of `total` (in then out). Same curve as headless.
pub fn zoomForStep(step_i: u32, zoom_steps: u32, z_lo: f32, z_hi: f32) struct { zoom: f32, going_in: bool, label_kind: u8, label_n: u32 } {
    const n_in = zoom_steps;
    const n_out = if (zoom_steps > 1) zoom_steps - 1 else 0;
    const going_in = step_i < n_in;
    const t: f32 = if (going_in)
        @as(f32, @floatFromInt(step_i)) / @as(f32, @floatFromInt(@max(n_in - 1, 1)))
    else
        1.0 - @as(f32, @floatFromInt(step_i - n_in + 1)) / @as(f32, @floatFromInt(@max(n_out, 1)));
    const u = t * t * (3 - 2 * t);
    const zoom = z_lo * std.math.pow(f32, z_hi / z_lo, u);
    return .{
        .zoom = zoom,
        .going_in = going_in,
        .label_kind = if (going_in) 0 else 1,
        .label_n = if (going_in) step_i else step_i - n_in,
    };
}

pub fn totalSteps(zoom_steps: u32) u32 {
    if (zoom_steps == 0) return 0;
    return zoom_steps + zoom_steps - 1;
}
