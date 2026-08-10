//! Headless organic LOD zoom tour — step timing, CSV, diagnostic PPM frames.
//!
//!     zig build organic-tour -Doptimize=ReleaseFast -- [N]
//!
//! Output: zig-out/organic-tour/tour.csv + step-*.ppm

const std = @import("std");
const dvui = @import("dvui");
const rb = @import("ui/render_bench_world.zig");
const quadlod = @import("ui/quadlod.zig");
const tour = @import("ui/organic_tour.zig");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    dvui.io = io;

    var n: usize = 50_000;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    for (args[1..]) |a| {
        if (std.fmt.parseInt(usize, a, 10)) |v| n = v else |_| {}
    }

    std.debug.print("organic-tour: synth N={d}\n", .{n});
    var world = try rb.synthWorld(gpa, n, .{});
    defer world.deinit(gpa);
    rb.printIslandStats(world);

    const live = try world.pointsSlice(gpa);
    defer gpa.free(live);

    var tree = try quadlod.build(gpa, live);
    defer tree.deinit();

    const views = try rb.makeViews(gpa, world, 1440, 900);
    defer gpa.free(views);
    const overview = views[0];
    const close = views[2];
    const center = dvui.Point{
        .x = close.world.x + close.world.w * 0.5,
        .y = close.world.y + close.world.h * 0.5,
    };

    std.debug.print("organic-tour: zoom {d:.3} → {d:.3} (island center)\n", .{ overview.zoom, close.zoom });
    std.debug.print("organic-tour: ---- begin ----\n", .{});

    const samples = try tour.runHeadless(gpa, io, tree, live, center, overview.zoom, close.zoom, .{});
    defer tour.freeSamples(gpa, samples);

    var warns: usize = 0;
    var worst_ms: f32 = 0;
    var worst_agents: usize = 0;
    for (samples) |s| {
        if (s.warn) warns += 1;
        worst_ms = @max(worst_ms, s.ms);
        worst_agents = @max(worst_agents, s.agents);
    }
    std.debug.print(
        "organic-tour: ---- done ----  steps={d}  warns={d}  worst_ms={d:.1}  peak_agents={d}\n",
        .{ samples.len, warns, worst_ms, worst_agents },
    );
    if (warns > 0) std.process.exit(2);
}
