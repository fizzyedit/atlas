//! Headless timing harness for the expensive half of Atlas: turning a folder of markdown into
//! a node/edge graph, and turning that graph into positions — plus an in-memory **scale
//! simulator** for 100k–1M note vaults (no million files on disk).
//!
//!     zig build bench -Doptimize=ReleaseFast -- <vault-dir> [more-dirs...]
//!     zig build bench -Doptimize=ReleaseFast -- --galaxy <vault-dir> ...
//!     zig build bench -Doptimize=ReleaseFast -- --galaxy --place pack \
//!         synth:100000:islands:4 synth:500000:islands:3 synth:1000000:scale-free:2
//!
//! Spec: `synth:N[:shape[:avg_deg]]` — shapes `scale-free|islands|hub|bipartite|chain|orphans|lfr`.
//! `--place pack` (default for synth) packs components; `--place layout` runs full force layout.
//! Slide connection density via `avg_deg` (target mean undirected degree ≈ 2|E|/N).
//!
//! Every directory / synth is timed separately. `--galaxy` runs the plugin overview LOD path
//! headlessly (quadtree → sticky agents → lifted edges) at overview and dive zooms.

const std = @import("std");
const dvui = @import("dvui");
const Scanner = @import("index/Scanner.zig");
const resolve = @import("index/resolve.zig");
const layout_full = @import("ui/layout_full.zig");
const multilevel = @import("ui/multilevel.zig");
const lod = @import("ui/lod.zig");
const quadlod = @import("ui/quadlod.zig");
const quad_agents = @import("ui/quad_agents.zig");
const galaxy = @import("ui/galaxy.zig");
const vault_synth = @import("ui/vault_synth.zig");
const bench_stats = @import("bench_stats.zig");
const world_mod = @import("ui/world.zig");
const fold = @import("ui/fold.zig");

/// When set (via `--svg <dir>`), every solved layout is also written there as an SVG.
var svg_dir: ?[]const u8 = null;
/// When set, after each layout run the plugin Galaxy LOD path (budget / settle / lift).
var galaxy_smoke: bool = false;
/// Synth placement: pack (fast, default) or full layout_full solve.
var synth_place: vault_synth.Place = .pack;
var synth_place_explicit: bool = false;
/// `--stats`: report graph structure (degree/components/hub-fragility/coarsening-ladder/folder
/// correlation) instead of running layout. Fast even on a huge vault — no force solve, no Galaxy.
var stats_mode: bool = false;
var world_mode: bool = false;

const Note = struct {
    path: []const u8,
    stem: []const u8,
    links: []const []const u8,
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    // `layout_full`'s profiling clock reads this; the app sets it during dvui init.
    dvui.io = io;

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) {
        std.debug.print(
            \\usage: atlas-bench [--galaxy] [--place pack|layout] [--svg <dir>] [--stats] <target>...
            \\  target = <vault-dir> | synth:N[:shape[:avg_deg]]
            \\  shapes = scale-free | islands | hub | bipartite | chain | orphans | lfr
            \\  --stats: report graph structure instead of running layout (fast on any vault size)
            \\
        , .{});
        return error.MissingArgument;
    }

    // First pass: pull `--stats` out so it can gate the header and every target's handling below,
    // regardless of where it appears among the targets.
    for (args[1..]) |a| {
        if (std.mem.eql(u8, a, "--stats")) stats_mode = true;
        if (std.mem.eql(u8, a, "--world")) world_mode = true;
    }

    if (!stats_mode and !world_mode) {
        std.debug.print(
            "{s:<22}{s:>7}{s:>8}{s:>9}{s:>8}{s:>10}{s:>8}{s:>9}{s:>8}{s:>8}{s:>9}{s:>11}\n",
            .{ "vault", "notes", "edges", "read", "scan", "resolve", "hop2", "force", "pack", "relax", "snap+ref", "LAYOUT" },
        );
        std.debug.print("{s}\n", .{"-" ** 117});
    }

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--world")) continue;
        if (std.mem.eql(u8, a, "--stats")) {
            continue; // handled in the pre-pass above
        }
        if (std.mem.eql(u8, a, "--galaxy")) {
            galaxy_smoke = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--place")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            synth_place = try vault_synth.Place.parse(args[i]);
            synth_place_explicit = true;
            continue;
        }
        if (std.mem.startsWith(u8, a, "--place=")) {
            synth_place = try vault_synth.Place.parse(a["--place=".len..]);
            synth_place_explicit = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--svg")) {
            i += 1;
            if (i < args.len) svg_dir = args[i];
            continue;
        }
        if (std.mem.startsWith(u8, a, "synth:")) {
            var spec = try vault_synth.Spec.parse(a);
            const bare = std.mem.indexOfScalar(u8, a["synth:".len..], ':') == null;
            // Legacy `synth:N` ⇒ full layout. Shaped synths default to pack (100k–1M feasible).
            // Explicit `--place` always wins. `--stats` always wins over all of that — it never
            // needs a placed layout, and pack is the cheap path into the graph it does need.
            if (stats_mode) {
                spec.place = .pack;
            } else if (synth_place_explicit) {
                spec.place = synth_place;
            } else if (bare) {
                spec.place = .layout;
            } else {
                spec.place = .pack;
            }
            if (world_mode) {
                try worldSynth(gpa, io, spec);
            } else if (stats_mode) {
                try statsSynth(gpa, io, spec);
            } else {
                try benchSynth(gpa, io, spec);
            }
        } else if (world_mode) {
            try worldVault(gpa, io, a);
        } else if (stats_mode) {
            try statsVault(gpa, io, a);
        } else {
            try benchVault(gpa, io, a);
        }
    }
}

/// `--world`: sweep the containment path (fold ladder → containment placement → budgeted select)
/// across a zoom range and report what each zoom actually draws.
///
/// This exists because the budget cannot be judged from a live window: a bug that only shows at
/// zooms you do not happen to stop at looks fine by eye. The sweep prints estimate against actual
/// at every step, which is how two separate bounds bugs were caught in the classic path.
fn worldSweep(gpa: std.mem.Allocator, n: usize, edges: []const fold.Edge, paths: []const []const u8, label: []const u8) !void {
    var w = try world_mod.World.init(gpa, n, edges, paths, .{}, .{});
    defer w.deinit();

    const budget: usize = 280;
    const params: world_mod.Params = .{ .budget = budget };
    const vw: f32 = 1200;
    const vh: f32 = 700;
    const ext = w.extent();
    const z_fit = @min(vw, vh) * 0.44 / ext;

    std.debug.print("\n==== world: {s} ====\n", .{label});
    std.debug.print("  notes={d}  links={d}  ladder depth={d}  cells={d}  root r={d:.1}\n", .{
        n, edges.len, w.lad.depth, w.lad.cells.len, ext,
    });
    std.debug.print("  {s:>9}  {s:>7}  {s:>7}  {s:>7}  {s:>7}  {s:>6}\n", .{ "zoom", "marks", "notes", "masses", "links", "bound" });

    var zoom = z_fit;
    var stepn: usize = 0;
    while (stepn < 14) : (stepn += 1) {
        // settle, so what is printed is the resting set rather than a mid-crossfade frame
        for (0..120) |_| try w.step(.{ .w = vw, .h = vh, .zoom = zoom, .cx = 0, .cy = 0 }, params, 1.0 / 60.0);
        try w.liftLinks(edges, params);
        const notes = w.noteMarks();
        std.debug.print("  {d:>9.3}  {d:>7}  {d:>7}  {d:>7}  {d:>7}  {s:>6}\n", .{
            zoom, w.marks.items.len, notes, w.marks.items.len - notes, w.links.items.len,
            if (w.bound) "Y" else "",
        });
        if (w.marks.items.len > budget * 2) std.debug.print("    ^^ OVER BUDGET\n", .{});
        zoom *= 2.0;
    }
}

fn worldSynth(gpa: std.mem.Allocator, io: std.Io, spec: vault_synth.Spec) !void {
    _ = io;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var graph = try vault_synth.generate(gpa, arena, spec);
    defer graph.deinit(gpa);
    var name_buf: [48]u8 = undefined;
    const label = spec.nameBuf(&name_buf);
    const edges = try arena.alloc(fold.Edge, graph.edges.len);
    for (graph.edges, edges) |e, *fe| fe.* = .{ .a = @intCast(e.a), .b = @intCast(e.b), .w = 1 };
    const have_paths = graph.paths.len == spec.n and (spec.n == 0 or graph.paths[0].len > 0);
    const paths: []const []const u8 = if (have_paths) graph.paths else &.{};
    try worldSweep(gpa, spec.n, edges, paths, label);
}

fn worldVault(gpa: std.mem.Allocator, io: std.Io, dir_path: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var notes: std.ArrayList(Note) = .empty;
    var read_ns: u64 = 0;
    var scan_ns: u64 = 0;
    try collect(gpa, arena, io, dir_path, dir_path, &notes, &read_ns, &scan_ns);
    if (notes.items.len == 0) return;
    const n = notes.items.len;

    const candidates = try arena.alloc(resolve.Candidate, n);
    for (notes.items, candidates) |note, *c| c.* = .{ .path = note.path, .stem = note.stem };

    var edges: std.ArrayList(fold.Edge) = .empty;
    var buf: [resolve.max_path_len]u8 = undefined;
    var cand_index = try resolve.Index.init(gpa, candidates);
    defer cand_index.deinit();
    for (notes.items, 0..) |note, i| {
        for (note.links) |raw| {
            if (!resolve.isNoteLikeTarget(raw)) continue;
            const m = resolve.resolveIndexed(raw, note.path, candidates, &cand_index, &buf) orelse continue;
            if (m.index == i) continue;
            try edges.append(arena, .{ .a = @intCast(i), .b = @intCast(m.index), .w = 1 });
        }
    }
    const paths = try arena.alloc([]const u8, n);
    for (notes.items, paths) |note, *p| p.* = note.path;

    try worldSweep(gpa, n, edges.items, paths, std.fs.path.basename(dir_path));
}

/// `--stats` over a synth spec: build the same graph a normal synth bench would (pack placement,
/// no force layout), then hand it to `bench_stats.report` instead of timing/placing it.
fn statsSynth(gpa: std.mem.Allocator, io: std.Io, spec: vault_synth.Spec) !void {
    _ = io;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var graph = try vault_synth.generate(gpa, arena, spec);
    defer graph.deinit(gpa);

    var name_buf: [48]u8 = undefined;
    const label = spec.nameBuf(&name_buf);

    const edges = try arena.alloc(bench_stats.Edge, graph.edges.len);
    for (graph.edges, edges) |e, *se| se.* = .{ .a = @intCast(e.a), .b = @intCast(e.b) };

    // `vault_synth.generate` skips path generation above 50k notes (see its doc comment) — pass
    // an empty slice so the stats report skips folder correlation instead of comparing `""` to
    // `""` and reporting a meaningless 100% match.
    const have_paths = graph.paths.len == spec.n and (spec.n == 0 or graph.paths[0].len > 0);
    const paths: []const []const u8 = if (have_paths) graph.paths else &.{};

    try bench_stats.report(gpa, spec.n, edges, paths, label);
}

/// `--stats` over a real vault directory: reuse the exact scan → resolve path `benchVault` uses
/// to build nodes and edges, then hand off to `bench_stats.report` instead of running layout.
fn statsVault(gpa: std.mem.Allocator, io: std.Io, dir_path: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var notes: std.ArrayList(Note) = .empty;
    var read_ns: u64 = 0;
    var scan_ns: u64 = 0;
    try collect(gpa, arena, io, dir_path, dir_path, &notes, &read_ns, &scan_ns);
    if (notes.items.len == 0) return;
    const n = notes.items.len;

    const candidates = try arena.alloc(resolve.Candidate, n);
    for (notes.items, candidates) |note, *c| c.* = .{ .path = note.path, .stem = note.stem };

    var edges: std.ArrayList(bench_stats.Edge) = .empty;
    var buf: [resolve.max_path_len]u8 = undefined;
    var cand_index = try resolve.Index.init(gpa, candidates);
    defer cand_index.deinit();
    for (notes.items, 0..) |note, i| {
        for (note.links) |raw| {
            if (!resolve.isNoteLikeTarget(raw)) continue;
            const m = resolve.resolveIndexed(raw, note.path, candidates, &cand_index, &buf) orelse continue;
            if (m.index == i) continue;
            try edges.append(arena, .{ .a = @intCast(i), .b = @intCast(m.index) });
        }
    }

    const paths = try arena.alloc([]const u8, n);
    for (notes.items, paths) |note, *p| p.* = note.path;

    try bench_stats.report(gpa, n, edges.items, paths, std.fs.path.basename(dir_path));
}

/// In-memory scale simulator: generate a shaped graph, pack or force-layout, optional Galaxy smoke.
fn benchSynth(gpa: std.mem.Allocator, io: std.Io, spec: vault_synth.Spec) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const t_gen = now(io);
    var graph = try vault_synth.generate(gpa, arena, spec);
    defer graph.deinit(gpa);
    const gen_ms = ms(elapsed(io, t_gen));

    const n = spec.n;
    var out = graph.positions;
    var prof: layout_full.Profile = .{};
    var total_ns: u64 = 0;

    if (spec.place == .layout) {
        const seeds = try arena.alloc(?dvui.Point, n);
        @memset(seeds, null);
        // Fresh buffer — layout writes here; keep packed positions as unused warm start option later.
        out = try arena.alloc(dvui.Point, n);
        const t0 = now(io);
        try layout_full.targets(gpa, n, graph.edges, seeds, graph.degrees, .{
            .aspect = spec.aspect,
            .paths = graph.paths,
            .profile = &prof,
        }, out);
        total_ns = elapsed(io, t0);
        std.debug.print(
            "  [{s}] place=layout gen={d:.0}ms grid={d:.0}ms repulse={d:.0}ms spring={d:.0}ms folder={d:.0}ms  hop2_pairs={d}\n",
            .{
                spec.shape.label(),
                gen_ms,
                ms(prof.f_grid_ns),
                ms(prof.f_repulse_ns),
                ms(prof.f_spring_ns),
                ms(prof.f_folder_ns),
                prof.hop2_pairs,
            },
        );
    } else {
        total_ns = elapsed(io, t_gen);
        std.debug.print(
            "  [{s}] place=pack gen={d:.0}ms comps={d} orphans={d} avg_deg={d:.2} max_deg={d}\n",
            .{ spec.shape.label(), gen_ms, graph.components, graph.orphans, graph.avg_deg_actual, graph.max_degree },
        );
    }

    var name_buf: [48]u8 = undefined;
    const label = spec.nameBuf(&name_buf);
    std.debug.print(
        "{s:<22}{d:>7}{d:>8}{d:>8.0}m{d:>7.0}m{d:>9.0}m{d:>7.0}m{d:>8.0}m{d:>7.0}m{d:>7.0}m{d:>8.0}m{d:>10.0}m\n",
        .{
            label,
            n,
            graph.edges.len,
            ms(0),
            ms(0),
            ms(0),
            ms(prof.hop2_ns),
            ms(prof.force_ns),
            if (spec.place == .pack) gen_ms else ms(prof.pack_ns),
            ms(prof.relax_ns),
            ms(prof.snap_ns + prof.refine_ns),
            ms(total_ns),
        },
    );
    std.debug.print("    fill={d:.3} (~0.91 = solid hex disc, lower = structured)\n", .{fillRatio(out, n)});
    if (svg_dir) |d| {
        const svg_label = try std.fmt.allocPrint(arena, "synth-{s}-{d}", .{ spec.shape.label(), n });
        try writeSvg(io, d, svg_label, out, graph.edges, graph.degrees, arena);
    }
    if (galaxy_smoke) {
        try smokeGalaxy(gpa, io, label, out, graph.edges);
    }
}

fn benchVault(gpa: std.mem.Allocator, io: std.Io, dir_path: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var notes: std.ArrayList(Note) = .empty;
    var read_ns: u64 = 0;
    var scan_ns: u64 = 0;
    try collect(gpa, arena, io, dir_path, dir_path, &notes, &read_ns, &scan_ns);
    if (notes.items.len == 0) return;
    const n = notes.items.len;

    // -- resolve -------------------------------------------------------------------
    // Same shape as the indexer's relink: one candidate per note, `resolve` per link.
    const candidates = try arena.alloc(resolve.Candidate, n);
    for (notes.items, candidates) |note, *c| c.* = .{ .path = note.path, .stem = note.stem };

    var edges: std.ArrayList(layout_full.Edge) = .empty;
    var buf: [resolve.max_path_len]u8 = undefined;
    const t_resolve = now(io);
    var cand_index = try resolve.Index.init(gpa, candidates);
    defer cand_index.deinit();
    for (notes.items, 0..) |note, i| {
        for (note.links) |raw| {
            if (!resolve.isNoteLikeTarget(raw)) continue;
            const m = resolve.resolveIndexed(raw, note.path, candidates, &cand_index, &buf) orelse continue;
            if (m.index == i) continue;
            try edges.append(arena, .{ .a = i, .b = m.index });
        }
    }
    const resolve_ns = elapsed(io, t_resolve);

    const degrees = try arena.alloc(u32, n);
    @memset(degrees, 0);
    var cross_dir: usize = 0;
    for (edges.items) |e| {
        degrees[e.a] += 1;
        degrees[e.b] += 1;
        const da = std.fs.path.dirname(notes.items[e.a].path) orelse "";
        const db = std.fs.path.dirname(notes.items[e.b].path) orelse "";
        if (!std.mem.eql(u8, da, db)) cross_dir += 1;
    }
    var max_deg: u32 = 0;
    var max_i: usize = 0;
    for (degrees, 0..) |d, di| if (d > max_deg) {
        max_deg = d;
        max_i = di;
    };
    if (max_deg > 20) {
        std.debug.print("    hottest: {s} (deg {d}); sample links:", .{ notes.items[max_i].path, max_deg });
        for (notes.items[max_i].links, 0..) |l, li| {
            if (li >= 4) break;
            std.debug.print(" \"{s}\"", .{l});
        }
        std.debug.print("\n", .{});
        // Who points at it?
        var shown: usize = 0;
        for (edges.items) |e| {
            const other = if (e.a == max_i) e.b else if (e.b == max_i) e.a else continue;
            if (shown >= 4) break;
            std.debug.print("      <- {s}\n", .{notes.items[other].path});
            shown += 1;
        }
    }

    // -- layout --------------------------------------------------------------------
    // First build: no seeds, nothing anchored — the exact path a freshly opened vault takes,
    // and the one the user watches the app freeze through.
    const seeds = try arena.alloc(?dvui.Point, n);
    @memset(seeds, null);
    const paths = try arena.alloc([]const u8, n);
    for (notes.items, paths) |note, *p| p.* = note.path;
    const out = try arena.alloc(dvui.Point, n);

    var prof: layout_full.Profile = .{};
    try layout_full.targets(gpa, n, edges.items, seeds, degrees, .{
        .aspect = 1.6,
        .paths = paths,
        .profile = &prof,
    }, out);

    std.debug.print(
        "{s:<16}{d:>7}{d:>8}{d:>8.0}m{d:>7.0}m{d:>9.0}m{d:>7.0}m{d:>8.0}m{d:>7.0}m{d:>7.0}m{d:>8.0}m{d:>10.0}m\n",
        .{
            std.fs.path.basename(dir_path),
            n,
            edges.items.len,
            ms(read_ns),   ms(scan_ns),  ms(resolve_ns),
            ms(prof.hop2_ns), ms(prof.force_ns), ms(prof.pack_ns),
            ms(prof.relax_ns), ms(prof.snap_ns + prof.refine_ns), ms(prof.total_ns),
        },
    );
    std.debug.print("    fill={d:.3}  cross-dir-edges={d}  max-degree={d}\n", .{ fillRatio(out, n), cross_dir, max_deg });
    if (galaxy_smoke) {
        try smokeGalaxy(gpa, io, std.fs.path.basename(dir_path), out, edges.items);
    }
    if (svg_dir) |d| {
        try writeSvg(io, d, std.fs.path.basename(dir_path), out, edges.items, degrees, arena);
        // Raw multilevel output, before packing/snap/refine — isolates whether the ladder is
        // producing structure or whether a later stage is flattening it.
        const ml_edges = try arena.alloc(multilevel.Edge, edges.items.len);
        for (edges.items, ml_edges) |e, *me| me.* = .{ .a = @intCast(e.a), .b = @intCast(e.b) };
        const raw = try arena.alloc(dvui.Point, n);
        try multilevel.solve(gpa, n, ml_edges, raw, .{});
        const label = try std.fmt.allocPrint(arena, "{s}-raw-ml", .{std.fs.path.basename(dir_path)});
        try writeSvg(io, d, label, raw, edges.items, degrees, arena);

        // And the merged-region view, at a couple of levels of the hierarchy.
        var ladder = try multilevel.coarsen(gpa, n, ml_edges);
        defer ladder.deinit(gpa);
        const cedges = try arena.alloc(lod.CEdge, edges.items.len);
        for (edges.items, cedges) |e, *ce| ce.* = .{ .a = @intCast(e.a), .b = @intCast(e.b) };
        var py = try lod.build(gpa, ladder, out, cedges);
        defer py.deinit();
        var lv: usize = 1;
        while (lv < py.levels.len) : (lv += 2) {
            const clabel = try std.fmt.allocPrint(arena, "{s}-clusters-L{d}", .{ std.fs.path.basename(dir_path), lv });
            try writeClusterSvg(io, d, clabel, py.levels[lv], arena);
        }
    }
}

/// Plugin overview path without a window: build → selectSticky agents → lift edges.
/// Fails the process if living marks exceed `plugin_mark_budget` or the field never settles.
fn smokeGalaxy(
    gpa: std.mem.Allocator,
    io: std.Io,
    name: []const u8,
    positions: []const dvui.Point,
    layout_edges: []const layout_full.Edge,
) !void {
    const qedges = try gpa.alloc(quadlod.Edge, layout_edges.len);
    defer gpa.free(qedges);
    for (layout_edges, qedges) |e, *qe| qe.* = .{ .a = @intCast(e.a), .b = @intCast(e.b) };

    var tree = try quadlod.buildEx(gpa, positions, qedges);
    defer tree.deinit();

    var field = quad_agents.Field.init(gpa);
    defer field.deinit();

    const root = tree.get(tree.root);
    const span_w = root.max_x - root.min_x;
    const span_h = root.max_y - root.min_y;
    const pad = @max(@max(span_w, span_h) * 0.05, 1);
    const full_view = dvui.Rect{
        .x = root.min_x - pad,
        .y = root.min_y - pad,
        .w = span_w + 2 * pad,
        .h = span_h + 2 * pad,
    };
    // Dive: ~¼ of the world, centred — forces split toward leaves without leaving the vault.
    const dive_view = dvui.Rect{
        .x = root.min_x + span_w * 0.35,
        .y = root.min_y + span_h * 0.35,
        .w = @max(span_w * 0.3, 1),
        .h = @max(span_h * 0.3, 1),
    };

    const budget = galaxy.plugin_mark_budget;
    const cases = [_]struct { label: []const u8, view: dvui.Rect, zoom: f32 }{
        .{ .label = "overview", .view = full_view, .zoom = 0.08 },
        .{ .label = "dive", .view = dive_view, .zoom = 1.2 },
    };

    for (cases) |c| {
        field.reset();
        const t0 = now(io);
        var settled_at: ?usize = null;
        var frame: usize = 0;
        while (frame < 90) : (frame += 1) {
            const sel_pad = @max(c.view.w, c.view.h) * 0.2;
            const sel = dvui.Rect{
                .x = c.view.x - sel_pad,
                .y = c.view.y - sel_pad,
                .w = c.view.w + 2 * sel_pad,
                .h = c.view.h + 2 * sel_pad,
            };
            try field.step(tree, gpa, .{
                .view = sel,
                .live = positions,
                .zoom = c.zoom,
                .note_r_px = 6,
                .dt = 1.0 / 60.0,
                .budget = budget,
            });
            // Living topology ≤ livingCap; draw list may briefly include fading (dying) marks.
            const cap = quadlod.livingCap(budget);
            const living_n = blk: {
                var n: usize = 0;
                for (field.agents.items) |a| {
                    if (!a.dying) n += 1;
                }
                break :blk n;
            };
            if (living_n > cap) {
                std.debug.print(
                    "    GALAXY FAIL {s}/{s}: living={d} > livingCap={d} (agents={d} budget={d})\n",
                    .{ name, c.label, living_n, cap, field.agents.items.len, budget },
                );
                return error.GalaxyBudgetExceeded;
            }
            if (field.settled and settled_at == null) settled_at = frame;
            if (field.settled and frame > 8) break;
        }
        const step_ms = ms(elapsed(io, t0));

        var lifted: std.ArrayListUnmanaged(quadlod.LiftedEdge) = .empty;
        defer lifted.deinit(gpa);
        try field.gatherLiftedEdges(tree, qedges, gpa, &lifted);

        const leaf_marks = blk: {
            var n: usize = 0;
            for (field.agents.items) |a| {
                if (!a.dying and a.count <= 1) n += 1;
            }
            break :blk n;
        };
        if (settled_at) |sf| {
            std.debug.print(
                "    galaxy {s}: agents={d} living={d} leaves={d} edges={d} settled@{d} {d:.0}ms\n",
                .{ c.label, field.agents.items.len, field.living.items.len, leaf_marks, lifted.items.len, sf, step_ms },
            );
        } else {
            std.debug.print(
                "    galaxy {s}: agents={d} living={d} leaves={d} edges={d} settled@never {d:.0}ms\n",
                .{ c.label, field.agents.items.len, field.living.items.len, leaf_marks, lifted.items.len, step_ms },
            );
        }
        if (settled_at == null) {
            std.debug.print("    GALAXY FAIL {s}/{s}: field never settled\n", .{ name, c.label });
            return error.GalaxyNeverSettled;
        }
        if (positions.len > 0 and field.living.items.len == 0) {
            std.debug.print("    GALAXY FAIL {s}/{s}: empty living set\n", .{ name, c.label });
            return error.GalaxyEmptyLiving;
        }
    }
}

/// How much of the cloud's own bounding box the nodes actually fill, in units of the snap
/// lattice.
///
/// A solid hex-packed *disc* — every cell taken, no voids — reads ~0.91 (hex cells fill 1/0.866
/// of their spacing squared, times π/4 for a disc inside its bounding box). A layout with real
/// structure, where clusters are separated by empty lattice, reads far below that. It is the
/// numeric form of "did this collapse into one massive hex".
fn fillRatio(pts: []const dvui.Point, n: usize) f64 {
    var min_x: f32 = std.math.floatMax(f32);
    var min_y: f32 = std.math.floatMax(f32);
    var max_x: f32 = -std.math.floatMax(f32);
    var max_y: f32 = -std.math.floatMax(f32);
    for (pts) |p| {
        min_x = @min(min_x, p.x);
        min_y = @min(min_y, p.y);
        max_x = @max(max_x, p.x);
        max_y = @max(max_y, p.y);
    }
    const area = @as(f64, (max_x - min_x)) * @as(f64, (max_y - min_y));
    if (area <= 0) return 0;
    const snap = layout_full.snapSpacingFor(n);
    return @as(f64, @floatFromInt(n)) * @as(f64, snap) * @as(f64, snap) / area;
}

/// Write the solved layout to an SVG so it can actually be looked at.
///
/// A fill ratio says a layout collapsed; it cannot say whether what came out reads as a map.
/// This is the difference between tuning a force model and guessing at one.
fn writeSvg(
    io: std.Io,
    dir: []const u8,
    name: []const u8,
    pts: []const dvui.Point,
    edges: []const layout_full.Edge,
    degrees: []const u32,
    arena: std.mem.Allocator,
) !void {
    const size: f32 = 1400;
    var min_x: f32 = std.math.floatMax(f32);
    var min_y: f32 = std.math.floatMax(f32);
    var max_x: f32 = -std.math.floatMax(f32);
    var max_y: f32 = -std.math.floatMax(f32);
    for (pts) |p| {
        min_x = @min(min_x, p.x);
        min_y = @min(min_y, p.y);
        max_x = @max(max_x, p.x);
        max_y = @max(max_y, p.y);
    }
    const span = @max(@max(max_x - min_x, max_y - min_y), 1e-3);
    const k = (size - 40) / span;

    var out: std.ArrayList(u8) = .empty;
    // `ArrayListUnmanaged` has no writer in this std, so lines are formatted into the arena and
    // appended. The arena is discarded wholesale right after, so the churn costs nothing.
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

    // Edges first so nodes sit on top. Thin and faint — at vault scale the link mesh is a
    // texture, not a set of individually readable lines.
    try add(&out, arena, "<g stroke=\"#3a4a6b\" stroke-width=\"0.5\" stroke-opacity=\"0.5\">\n", .{});
    for (edges) |e| {
        if (e.a >= pts.len or e.b >= pts.len) continue;
        try add(&out, arena, "<line x1=\"{d:.1}\" y1=\"{d:.1}\" x2=\"{d:.1}\" y2=\"{d:.1}\"/>\n", .{
            20 + (pts[e.a].x - min_x) * k, 20 + (pts[e.a].y - min_y) * k,
            20 + (pts[e.b].x - min_x) * k, 20 + (pts[e.b].y - min_y) * k,
        });
    }
    try add(&out, arena, "</g>\n<g fill=\"#8fc7ff\">\n", .{});
    for (pts, 0..) |p, i| {
        const d: f32 = if (i < degrees.len) @floatFromInt(degrees[i]) else 0;
        const r = std.math.clamp(0.9 + @sqrt(d) * 0.55, 0.9, 6);
        try add(&out, arena, "<circle cx=\"{d:.1}\" cy=\"{d:.1}\" r=\"{d:.2}\"/>\n", .{
            20 + (p.x - min_x) * k, 20 + (p.y - min_y) * k, r,
        });
    }
    try add(&out, arena, "</g>\n</svg>\n", .{});

    const path = try std.fmt.allocPrint(arena, "{s}/{s}.svg", .{ dir, name });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = out.items });
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

fn collect(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    directory: []const u8,
    notes: *std.ArrayList(Note),
    read_ns: *u64,
    scan_ns: *u64,
) !void {
    var dir = std.Io.Dir.cwd().openDir(io, directory, .{
        .access_sub_paths = true,
        .iterate = true,
    }) catch return;
    defer dir.close(io);

    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        if (entry.name.len > 0 and entry.name[0] == '.') continue;
        const abs = try std.fs.path.join(gpa, &.{ directory, entry.name });
        defer gpa.free(abs);

        switch (entry.kind) {
            .directory => try collect(gpa, arena, io, root, abs, notes, read_ns, scan_ns),
            .file => {
                if (!std.ascii.endsWithIgnoreCase(entry.name, ".md")) continue;

                const t0 = now(io);
                const bytes = std.Io.Dir.cwd().readFileAlloc(io, abs, arena, .limited(4 * 1024 * 1024)) catch continue;
                read_ns.* += elapsed(io, t0);

                const t1 = now(io);
                const scanned = try Scanner.scan(arena, bytes);
                scan_ns.* += elapsed(io, t1);

                // Vault-relative, `/`-separated — what the indexer stores and what `resolve`
                // and the folder-cohort pass both expect.
                var rel = abs[root.len..];
                while (rel.len > 0 and rel[0] == '/') rel = rel[1..];
                const rel_owned = try arena.dupe(u8, rel);

                const links = try arena.alloc([]const u8, scanned.links.len);
                for (scanned.links, links) |src, *dst| dst.* = src.raw;

                // `entry.name` belongs to the iterator and is reused on the next `next()`, so
                // the stem has to be owned — borrowing it fed `resolve` garbage candidate names
                // and invented links between unrelated notes.
                const base = std.fs.path.basename(rel_owned);
                try notes.append(arena, .{
                    .path = rel_owned,
                    .stem = base[0 .. base.len - 3],
                    .links = links,
                });
            },
            else => {},
        }
    }
}

/// Render one pyramid level the way the panel now draws merged regions — a soft glow sized to
/// the region's footprint, plus a small crisp core — so the look can be judged before it ships.
fn writeClusterSvg(
    io: std.Io,
    dir: []const u8,
    name: []const u8,
    clusters: []const lod.Cluster,
    arena: std.mem.Allocator,
) !void {
    const size: f32 = 1400;
    var min_x: f32 = std.math.floatMax(f32);
    var min_y: f32 = std.math.floatMax(f32);
    var max_x: f32 = -std.math.floatMax(f32);
    var max_y: f32 = -std.math.floatMax(f32);
    for (clusters) |c| {
        min_x = @min(min_x, c.pos.x - c.radius);
        min_y = @min(min_y, c.pos.y - c.radius);
        max_x = @max(max_x, c.pos.x + c.radius);
        max_y = @max(max_y, c.pos.y + c.radius);
    }
    const span = @max(@max(max_x - min_x, max_y - min_y), 1e-3);
    const k = (size - 40) / span;

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

    // Mirrors `graph.drawClusters` in additive mode: wide, low-weight splats summed together.
    // `plus-lighter` is the same arithmetic dvui's premultiplied src-over performs when a vertex
    // carries zero alpha, so this previews what the panel actually draws.
    try add(&out, arena, "<g style=\"mix-blend-mode:plus-lighter\">\n", .{});
    try add(&out, arena,
        \\<defs><radialGradient id="s">
        \\<stop offset="0%" stop-color="#fff" stop-opacity="1"/>
        \\<stop offset="28%" stop-color="#fff" stop-opacity="0.55"/>
        \\<stop offset="60%" stop-color="#fff" stop-opacity="0.18"/>
        \\<stop offset="100%" stop-color="#fff" stop-opacity="0"/>
        \\</radialGradient></defs>
        \\
    , .{});
    const node_r: f32 = 9.0;
    for (clusters) |c| {
        const cx = 20 + (c.pos.x - min_x) * k;
        const cy = 20 + (c.pos.y - min_y) * k;
        const extent = c.radius * k + node_r;
        const splat = @max(extent * 1.9, node_r * 3.0);
        const load = @log(1.0 + @as(f32, @floatFromInt(c.count))) / @log(1.0 + 256.0);
        const w = 0.10 + 0.16 * std.math.clamp(load, 0, 1);
        try add(&out, arena, "<circle cx=\"{d:.1}\" cy=\"{d:.1}\" r=\"{d:.1}\" fill=\"url(#s)\" opacity=\"{d:.3}\"/>\n", .{ cx, cy, splat, w });
    }
    try add(&out, arena, "</g>\n", .{});

    try add(&out, arena, "</svg>\n", .{});

    const path = try std.fmt.allocPrint(arena, "{s}/{s}.svg", .{ dir, name });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = out.items });
}
