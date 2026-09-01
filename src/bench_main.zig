//! Headless timing harness for the expensive half of Atlas — everything between a folder of
//! markdown and a drawn frame — plus an in-memory generator for 100k–1M note vaults, so the
//! scale cases can be measured without that many files on disk.
//!
//!     zig build bench -Doptimize=ReleaseFast -- [mode] <target>...
//!
//! A target is a vault directory or a `synth:N[:shape[:avg_deg]]` spec; shapes are
//! `scale-free|islands|hub|bipartite|chain|orphans|lfr`, and `avg_deg` sets the mean undirected
//! degree. Each target is timed separately.
//!
//! | mode | what it measures |
//! |---|---|
//! | *(none)* | read → scan → resolve → place, the classic per-stage table |
//! | `--index` | building the SQLite index from scratch, phase by phase |
//! | `--index-warm` | re-opening an already-built index |
//! | `--index-edit` | one edit against a built index — the path a save takes |
//! | `--refold` | `fold.build` + `cellweb.build`, what a republish costs |
//! | `--world` | the level-of-detail sweep across a zoom range |
//! | `--interior` | the same sweep for a single note's content cloud |
//! | `--stats` | graph structure (degree, components, hub fragility) — no layout |
//! | `--shapes` | one row per vault: layout grade (spread, overlap, bimodality, displacement) |
//! | `--churn` | how many territories come back different after one added link |
//! | `--layout-edit` | save path: reuse memo + settled skip + World ms |
//!
//! Tuning flags: `--place pack|layout`, `--budget=N`, `--link-budget=N`, `--scan-cap=N`,
//! `--reps=N`, `--svg <dir>`.

const std = @import("std");
const dvui = @import("dvui");
const sdk = @import("fizzy_sdk");
const Db = @import("index/Db.zig");
const Indexer = @import("index/Indexer.zig");
const Scanner = @import("index/Scanner.zig");
const resolve = @import("index/resolve.zig");
const layout_full = @import("ui/layout_full.zig");
const multilevel = @import("ui/multilevel.zig");
const vault_synth = @import("ui/vault_synth.zig");
const bench_stats = @import("bench_stats.zig");
const world_mod = @import("ui/world.zig");
const containment = @import("ui/containment.zig");
const fold = @import("ui/fold.zig");
const spatial = @import("ui/spatial.zig");
const louvain = @import("ui/louvain.zig");
const layout = @import("ui/layout.zig");
const cellweb = @import("ui/cellweb.zig");
const shape_metrics = @import("ui/shape_metrics.zig");

/// When set (via `--svg <dir>`), every solved layout is also written there as an SVG.
var svg_dir: ?[]const u8 = null;
/// When set, after each layout run the plugin Galaxy LOD path (budget / settle / lift).
/// Synth placement: pack (fast, default) or full layout_full solve.
var synth_place: vault_synth.Place = .pack;
var synth_place_explicit: bool = false;
/// `--stats`: report graph structure (degree/components/hub-fragility/coarsening-ladder/folder
/// correlation) instead of running layout. Fast even on a huge vault — no force solve, no Galaxy.
var stats_mode: bool = false;
var world_mode: bool = false;
/// `--budget=N`: the mark budget the `--world` sweep runs at.
///
/// Defaults to the top of the "Graph quality" slider, because that is where the map is actually
/// being run and judged — not to `plugin_mark_budget`. A bench tuned to a setting nobody uses
/// reports comfort the reader never sees: at 4,000 the panel draws 10,000 links, eleven times the
/// 900 the old default measured.
/// The panel's own slider goes to
/// 4000, and several per-frame costs scale with it rather than with note count, so a sweep pinned
/// at the 280 default cannot see them.
var world_budget: usize = 4000;
/// `--pan`: after settling each zoom, keep stepping with the camera *moving*, and report what a
/// frame costs then. The settled numbers below it are the parked-camera steady state; a pan is the
/// case the reader actually complains about, because it invalidates the lift cache every frame.
var world_pan: bool = false;
/// `--zoom-mul=F`: zoom ratio between sweep steps. The default doubling can step clean over a
/// narrow band, which is exactly how a band-shaped bug hides from this sweep.
var world_zoom_mul: f32 = 2.0;
/// `--spatial`: after the usual layout report, build a *spatial* hierarchy over the same leaf
/// positions and report the same two structural numbers for it. This is the gate on the
/// positions-first inversion: if grouping by proximity does not drop sibling overlap against
/// grouping by links, the chunker is wrong and nothing should be built on top of it.
///
/// Off by default because it eagerly places every leaf, which is the cost lazy placement exists to
/// avoid — seconds on a large vault.
var want_relayout: bool = false;
var want_cluster: bool = false;
var cluster_resolution: f64 = 1.0;
var ml_iters: usize = 90;
var want_spatial: bool = false;
/// `--degree-norm=F`: `fold.Options.degree_norm`, how hard a link is discounted for the popularity
/// of its endpoints.
var fold_degree_norm: ?f32 = null;
/// `--fill=F`, `--radius-exp=F`, `--pack-gap=F`: `containment.Options`, so the layout's tuning can
/// be swept against the layout report instead of guessed at and rebuilt.
var place_fill: ?f32 = null;
var place_radius_exp: ?f32 = null;
var place_pack_gap: ?f32 = null;
/// `--focus=N`: sweep with note `N` focused and open, so the focused note's own leaf-precision
/// links are exercised. Without it `focus_leaf` is invalid at every zoom and the whole highlight
/// path — the thing a reader looks at after clicking a node — is never entered by the bench.
var world_focus: i64 = -1;
/// The note a zoom sweep points at when `--focus` is not given. Arbitrary but fixed, so the
/// numbers stay comparable between runs; any note does, as long as it is a note.
const sweep_centre_note: u32 = 0;
/// `--pan-px=N`: screen pixels the `--pan` probe moves the camera per frame. 13 is a normal hand
/// pan at 60 fps (~800 px/s); a flick is several times that, and the interesting failures are all
/// at the fast end.
var world_pan_px: f32 = 13;
/// `--zoom`: travel in and out repeatedly on one `World`, to catch cost that *accumulates*.
var world_zoom_travel: bool = false;
var world_zoom_cycles: u32 = 8;
/// `--scan-cap=N`: `Params.link_scan_cap`, so a sweep can show what the cap is costing.
var world_scan_cap: usize = 256;
/// `--split-px=N`: `Params.split_px`, the on-screen radius at which a cell opens. The panel scales
/// this by `motion_bias` while the camera moves (`graph.motionSplitMax`), so sweeping it is how you
/// measure what a frame costs *during* a pan rather than at rest.
var world_split_px: f32 = 30;
/// `--link-budget=N`: `Params.link_budget`. Zero means "derive from the mark budget exactly as the
/// panel does" (`Params.ambientLinkBudget`), which is the default so a sweep left alone measures
/// what the panel draws. An explicit value is how you find out what a denser web would cost.
var world_link_budget: usize = 0;
var interior_mode: bool = false;
/// `--index`: build the real SQLite index from scratch and report where the time went.
var index_mode: bool = false;
/// `--index-warm`: keep whatever index the previous run left behind, so the same command
/// measures a re-open (the path that is supposed to skip the relink) instead of a cold build.
var index_warm: bool = false;
/// `--index-edit`: time one live-buffer edit against an already-built index — the path a
/// keystroke takes, which is the one the app is judged on and the one no other mode covers.
var index_edit: bool = false;
/// `--refold`: run `fold.build` + `cellweb.build` repeatedly over a real vault and report each.
///
/// Its own mode because these two are what a *republish* costs — the layout job rebuilds the whole
/// `World` whenever the index bumps the generation, including for a one-note edit — and `--world`
/// buries them under a scan and a zoom sweep, which is both slow to iterate on and far too short a
/// window to sample. Looping gives a stable number and a profile long enough to read.
var refold_mode: bool = false;
var refold_reps: usize = 5;
/// `--shapes`: one compact row per vault (or per child vault of a gauntlet parent).
var shapes_mode: bool = false;
/// Skip the second solve that grades single-edge displacement. Fast iteration only.
var shapes_no_displace: bool = false;
/// `--no-territories`: solve as one global force layout instead of the default territories, so a
/// change can still be graded against what it replaced.
var shapes_territories: bool = true;
/// `--frame-max=N` / `--region-max=N`: the two sizes that decide how the vault is cut up for
/// placement, exposed so the trade between link locality and stability can be swept.
var shapes_frame_max: usize = 0;
var shapes_region_max: u32 = 0;
var shapes_header_printed: bool = false;
/// `--churn`: how many *territories* come back different after one added link, with the
/// post-clustering stages switched on and off, so the churn can be attributed to a stage.
var churn_mode: bool = false;
/// `--stability`: Gate 1 — cold Louvain, one extra edge, cold Louvain, how many notes flip.
var stability_mode: bool = false;
var stability_trials: u32 = 21;
var stability_header_printed: bool = false;
/// `--layout-edit`: cold `layout.solve`, then a second solve with reuse — identical edges
/// (settled / World skip) versus one added link — and World init vs skip.
var layout_edit_mode: bool = false;

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
            \\usage: atlas-bench [mode] [flags] <target>...
            \\  target = <vault-dir> | synth:N[:shape[:avg_deg]]
            \\  shapes = scale-free | islands | hub | bipartite | chain | orphans | lfr
            \\  modes  = --index | --index-warm | --index-edit | --refold | --layout-edit
            \\           --world | --interior | --stats | --shapes | --stability
            \\           (default: scan/resolve/`layout.solve` table)
            \\  flags  = --place pack|layout  --budget=N  --scan-cap=N  --reps=N  --svg <dir>
            \\           --no-displace  --no-territories  --trials=N  --resolution=F
            \\
        , .{});
        return error.MissingArgument;
    }

    // First pass: pull `--stats` out so it can gate the header and every target's handling below,
    // regardless of where it appears among the targets.
    for (args[1..]) |a| {
        if (std.mem.eql(u8, a, "--stats")) stats_mode = true;
        if (std.mem.eql(u8, a, "--shapes")) shapes_mode = true;
        if (std.mem.eql(u8, a, "--stability")) stability_mode = true;
        if (std.mem.eql(u8, a, "--churn")) churn_mode = true;
        if (std.mem.eql(u8, a, "--layout-edit")) layout_edit_mode = true;
        if (std.mem.startsWith(u8, a, "--trials=")) {
            stability_trials = std.fmt.parseInt(u32, a["--trials=".len..], 10) catch stability_trials;
        }
        if (std.mem.eql(u8, a, "--no-displace")) shapes_no_displace = true;
        if (std.mem.eql(u8, a, "--no-territories")) shapes_territories = false;
        if (std.mem.startsWith(u8, a, "--frame-max=")) {
            shapes_frame_max = std.fmt.parseInt(usize, a["--frame-max=".len..], 10) catch shapes_frame_max;
        }
        if (std.mem.startsWith(u8, a, "--region-max=")) {
            shapes_region_max = std.fmt.parseInt(u32, a["--region-max=".len..], 10) catch shapes_region_max;
        }
        if (std.mem.eql(u8, a, "--world")) world_mode = true;
        if (std.mem.eql(u8, a, "--pan")) {
            world_pan = true;
            world_mode = true;
        }
        if (std.mem.eql(u8, a, "--zoom")) {
            world_zoom_travel = true;
            world_mode = true;
        }
        if (std.mem.startsWith(u8, a, "--cycles=")) {
            world_zoom_cycles = std.fmt.parseInt(u32, a["--cycles=".len..], 10) catch world_zoom_cycles;
            world_zoom_travel = true;
            world_mode = true;
        }
        if (std.mem.startsWith(u8, a, "--zoom-mul=")) {
            world_zoom_mul = try std.fmt.parseFloat(f32, a["--zoom-mul=".len..]);
        }
        if (std.mem.startsWith(u8, a, "--ml-iters=")) {
            ml_iters = try std.fmt.parseInt(usize, a["--ml-iters=".len..], 10);
            continue;
        }
        if (std.mem.eql(u8, a, "--cluster")) {
            want_cluster = true;
            continue;
        }
        if (std.mem.startsWith(u8, a, "--resolution=")) {
            cluster_resolution = try std.fmt.parseFloat(f64, a["--resolution=".len..]);
            want_cluster = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--relayout")) {
            want_spatial = true;
            want_relayout = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--spatial")) {
            want_spatial = true;
            world_mode = true;
        }
        if (std.mem.startsWith(u8, a, "--degree-norm=")) {
            fold_degree_norm = try std.fmt.parseFloat(f32, a["--degree-norm=".len..]);
        }
        if (std.mem.startsWith(u8, a, "--fill=")) {
            place_fill = try std.fmt.parseFloat(f32, a["--fill=".len..]);
        }
        if (std.mem.startsWith(u8, a, "--radius-exp=")) {
            place_radius_exp = try std.fmt.parseFloat(f32, a["--radius-exp=".len..]);
        }
        if (std.mem.startsWith(u8, a, "--pack-gap=")) {
            place_pack_gap = try std.fmt.parseFloat(f32, a["--pack-gap=".len..]);
        }
        if (std.mem.startsWith(u8, a, "--focus=")) {
            world_focus = try std.fmt.parseInt(i64, a["--focus=".len..], 10);
        }
        if (std.mem.startsWith(u8, a, "--pan-px=")) {
            world_pan_px = try std.fmt.parseFloat(f32, a["--pan-px=".len..]);
            world_pan = true;
            world_mode = true;
        }
        if (std.mem.startsWith(u8, a, "--split-px=")) {
            world_split_px = try std.fmt.parseFloat(f32, a["--split-px=".len..]);
        }
        if (std.mem.startsWith(u8, a, "--link-budget=")) {
            world_link_budget = try std.fmt.parseInt(usize, a["--link-budget=".len..], 10);
        }
        if (std.mem.eql(u8, a, "--interior")) interior_mode = true;
        if (std.mem.eql(u8, a, "--index")) index_mode = true;
        if (std.mem.eql(u8, a, "--index-warm")) {
            index_mode = true;
            index_warm = true;
        }
        if (std.mem.eql(u8, a, "--refold")) refold_mode = true;
        if (std.mem.startsWith(u8, a, "--reps=")) {
            refold_reps = std.fmt.parseInt(usize, a["--reps=".len..], 10) catch refold_reps;
        }
        if (std.mem.eql(u8, a, "--index-edit")) {
            index_mode = true;
            index_warm = true;
            index_edit = true;
        }
        if (std.mem.startsWith(u8, a, "--budget=")) {
            world_budget = std.fmt.parseInt(usize, a["--budget=".len..], 10) catch world_budget;
        }
        if (std.mem.startsWith(u8, a, "--scan-cap=")) {
            world_scan_cap = std.fmt.parseInt(usize, a["--scan-cap=".len..], 10) catch world_scan_cap;
        }
    }

    if (interior_mode) {
        try interiorSweep(gpa);
        return;
    }

    if (!stats_mode and !world_mode and !index_mode and !refold_mode and !shapes_mode and !stability_mode) {
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
        if (std.mem.eql(u8, a, "--pan")) continue;
        if (std.mem.startsWith(u8, a, "--pan-px=")) continue;
        if (std.mem.startsWith(u8, a, "--focus=")) continue;
        if (std.mem.startsWith(u8, a, "--fill=")) continue;
        if (std.mem.startsWith(u8, a, "--degree-norm=")) continue;
        if (std.mem.eql(u8, a, "--spatial")) continue;
        if (std.mem.eql(u8, a, "--relayout")) continue;
        if (std.mem.eql(u8, a, "--cluster")) continue;
        if (std.mem.startsWith(u8, a, "--resolution=")) continue;
        if (std.mem.startsWith(u8, a, "--ml-iters=")) continue;
        if (std.mem.startsWith(u8, a, "--radius-exp=")) continue;
        if (std.mem.startsWith(u8, a, "--pack-gap=")) continue;
        if (std.mem.startsWith(u8, a, "--zoom-mul=")) continue;
        if (std.mem.eql(u8, a, "--index")) continue;
        if (std.mem.eql(u8, a, "--index-warm")) continue;
        if (std.mem.eql(u8, a, "--index-edit")) continue;
        if (std.mem.eql(u8, a, "--refold")) continue;
        if (std.mem.startsWith(u8, a, "--reps=")) continue;
        if (std.mem.startsWith(u8, a, "--budget=")) continue;
        if (std.mem.startsWith(u8, a, "--scan-cap=")) continue;
        if (std.mem.eql(u8, a, "--stats")) {
            continue; // handled in the pre-pass above
        }
        if (std.mem.eql(u8, a, "--shapes")) continue;
        if (std.mem.eql(u8, a, "--stability")) continue;
        if (std.mem.eql(u8, a, "--churn")) continue;
        if (std.mem.eql(u8, a, "--layout-edit")) continue;
        if (std.mem.startsWith(u8, a, "--trials=")) continue;
        if (std.mem.eql(u8, a, "--no-displace")) continue;
        if (std.mem.eql(u8, a, "--no-territories")) continue;
        if (std.mem.startsWith(u8, a, "--frame-max=")) continue;
        if (std.mem.startsWith(u8, a, "--region-max=")) continue;
        if (std.mem.eql(u8, a, "--zoom")) continue;
        if (std.mem.startsWith(u8, a, "--cycles=")) continue;
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
            } else if (stability_mode) {
                try stabilitySynth(gpa, io, spec);
            } else if (stats_mode) {
                try statsSynth(gpa, io, spec);
            } else {
                try benchSynth(gpa, io, spec);
            }
        } else if (churn_mode) {
            try churnTarget(gpa, io, a);
        } else if (layout_edit_mode) {
            try layoutEditTarget(gpa, io, a);
        } else if (stability_mode) {
            try stabilityTarget(gpa, io, a);
        } else if (shapes_mode) {
            try shapesTarget(gpa, io, a);
        } else if (refold_mode) {
            try refoldVault(gpa, io, a);
        } else if (index_mode) {
            try indexVault(gpa, io, a);
        } else if (world_mode) {
            try worldVault(gpa, io, a);
        } else if (stats_mode) {
            try statsVault(gpa, io, a);
        } else {
            try benchVault(gpa, io, a);
        }
    }
}

/// `--index`: build the real SQLite index over a real vault and report where the time went.
///
/// The scan is the one expensive stage the rest of this harness skips: `benchVault` reads and
/// parses the same files, but never opens a database, so nothing here could see the cost that
/// actually dominates opening a large vault for the first time. Every guess about that cost has
/// been wrong so far, which is what `Indexer.Timings` exists for — this just runs the scan on the
/// calling thread and prints the breakdown, in `ReleaseFast`, with no window and no UI thread
/// competing for the connection.
///
/// The database goes in a scratch directory that is wiped first, so the default is a **cold**
/// build. `--index-warm` keeps it, which measures the re-open path instead.
fn indexVault(gpa: std.mem.Allocator, io: std.Io, dir: []const u8) !void {
    // `Indexer.walk` asks the host whether a path is ignored, and `sdk.refresh` pokes the event
    // loop. Both are null-checked against `fizzy_api`, so a bare Host answers "not ignored" and
    // "no loop to wake" — which is exactly what a headless scan wants.
    var host: sdk.Host = .{ .allocator = gpa };
    var gpa_copy = gpa;
    sdk.installRuntime(&gpa_copy, &host, null);

    // Under the build cache rather than the vault: the index is derived data, it can be
    // gigabytes, and putting it next to the notes is exactly what `Db`'s file comment forbids.
    const cache_dir = ".zig-cache/atlas-index-bench";
    if (!index_warm) std.Io.Dir.cwd().deleteTree(io, cache_dir) catch {};

    var db = try Db.openIn(gpa, io, cache_dir, dir);
    defer db.close(gpa);

    var busy: std.atomic.Value(bool) = .init(false);
    var generation: std.atomic.Value(u64) = .init(0);
    var indexer = Indexer.init(gpa, &busy, &generation);
    defer indexer.deinit();
    indexer.db = &db;
    indexer.vault_root = dir;

    const t0 = std.Io.Clock.boot.now(io).nanoseconds;
    try indexer.runFullScan(io, .always);
    const total_ns = std.Io.Clock.boot.now(io).nanoseconds - t0;

    if (index_edit) {
        try timeOneEdit(gpa, io, &db, &indexer);
        return;
    }

    const t = indexer.timings;
    const s = struct {
        fn f(ns: u64) f64 {
            return @as(f64, @floatFromInt(ns)) / 1e9;
        }
    }.f;
    const c = indexer.counts();
    std.debug.print(
        \\{s}{s}
        \\  notes {d}  links {d}  phantoms {d}   ({d} files read, {d} unchanged)
        \\  prepass   {d:>7.2}s
        \\  walk      {d:>7.2}s   stat {d:.2}s  read {d:.2}s  parse {d:.2}s  db {d:.2}s
        \\  drop      {d:>7.2}s
        \\  relink    {d:>7.2}s
        \\  publish   {d:>7.2}s
        \\  TOTAL     {d:>7.2}s
        \\
    , .{
        dir,
        if (index_warm) " (warm)" else " (cold)",
        c.note_count,
        c.link_count,
        c.phantom_count,
        t.files_read,
        t.files_skipped,
        s(t.prepass_ns),
        s(t.walk_ns),
        s(t.stat_ns),
        s(t.read_ns),
        s(t.parse_ns),
        s(t.write_ns),
        s(t.drop_ns),
        s(t.relink_ns),
        s(t.publish_ns),
        s(@intCast(total_ns)),
    });
}

/// Time the three steps a single edited buffer costs: writing the note's rows, resolving links,
/// and republishing the snapshot. This is the interactive path — `documentContentChanged` fires on
/// a typing lull, and everything it triggers happens before the graph can show the edit.
fn timeOneEdit(gpa: std.mem.Allocator, io: std.Io, db: *Db, indexer: *Indexer) !void {
    // A real note, edited the way a reader edits one: same file, different body. The content must
    // actually differ or `indexBuffer` short-circuits on the hash and measures nothing.
    var stmt = try db.conn.prepare("SELECT path FROM notes WHERE phantom = 0 ORDER BY id LIMIT 1");
    defer stmt.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const row = (try stmt.oneAlloc([]const u8, arena.allocator(), .{}, .{})) orelse {
        std.debug.print("no notes to edit\n", .{});
        return;
    };

    var buf: [256]u8 = undefined;
    const body = try std.fmt.bufPrint(&buf, "# edited\n\nnow links to [[Paris]] and nothing else.\n", .{});

    // Twice, and the second one is the number that matters. Resolution's whole-vault inputs are
    // cached across edits (`Indexer.ResolveCache`), so a fresh process pays to build them on its
    // first edit and nothing thereafter — and in the app that build has already happened during the
    // opening scan. Reporting only the first edit would describe a cost the reader never pays twice.
    var body_first: [256]u8 = undefined;
    const first = try std.fmt.bufPrint(&body_first, "# warm\n\nlinks to [[Paris]].\n", .{});
    const t_cold0 = std.Io.Clock.boot.now(io).nanoseconds;
    switch (try indexer.indexBuffer(row, first)) {
        .rewrote => |id| _ = try indexer.relinkNote(id),
        else => try indexer.relinkAll(),
    }
    const cold_ns: u64 = @intCast(std.Io.Clock.boot.now(io).nanoseconds - t_cold0);

    const t0 = std.Io.Clock.boot.now(io).nanoseconds;
    const wrote = try indexer.indexBuffer(row, body);
    const t1 = std.Io.Clock.boot.now(io).nanoseconds;
    // Exactly what the worker does for a live buffer edit of a note it already had.
    switch (wrote) {
        .rewrote => |id| _ = try indexer.relinkNote(id),
        else => try indexer.relinkAll(),
    }
    const t2 = std.Io.Clock.boot.now(io).nanoseconds;
    try indexer.commitAndPublish();
    const t3 = std.Io.Clock.boot.now(io).nanoseconds;
    const write_ns: u64 = @intCast(t1 - t0);
    const relink_ns: u64 = @intCast(t2 - t1);
    const publish_ns: u64 = @intCast(t3 - t2);

    std.debug.print(
        \\one edit to {s} ({s})
        \\  first edit        {d:>9.1} ms   (builds the resolve cache)
        \\  --- steady state ---
        \\  writeNote         {d:>9.1} ms
        \\  relinkAll         {d:>9.1} ms
        \\  commitAndPublish  {d:>9.1} ms
        \\  TOTAL             {d:>9.1} ms
        \\
    , .{ row, @tagName(wrote), ms(cold_ns), ms(write_ns), ms(relink_ns), ms(publish_ns), ms(write_ns + relink_ns + publish_ns) });
}

/// `--world`: sweep the containment path (fold ladder → containment placement → budgeted select)
/// across a zoom range and report what each zoom actually draws.
///
/// This exists because the budget cannot be judged from a live window: a bug that only shows at
/// zooms you do not happen to stop at looks fine by eye. The sweep prints estimate against actual
/// at every step, which is how two separate bounds bugs were caught in the classic path.
/// Can a hierarchy of communities hold the links inside it?
///
/// The question a region layout stands or falls on. Nested regions are fast, deterministic, free
/// of overlap by construction and update only where the structure changed — and none of that is
/// worth anything if the links keep crossing between regions, because the map then says nothing
/// about what is near what.
///
/// Reported per level of the dendrogram, because a region layout uses every level: what stays
/// inside a community at that scale is what the reader sees as short at that zoom. Compared
/// against `fold`'s own ladder at the closest granularity, since that is the hierarchy this
/// would replace and it is the one that measured 58% of links crossing a quarter of the vault.
fn clusterReport(gpa: std.mem.Allocator, io: std.Io, n: usize, edges: []const fold.Edge) !void {
    const ledges = try gpa.alloc(louvain.Edge, edges.len);
    defer gpa.free(ledges);
    for (ledges, edges) |*d, e| d.* = .{ .a = e.a, .b = e.b, .w = e.w };

    const t0 = now(io);
    // The one caller that actually reads `q` — see `louvain.Options.measure_q`.
    var res = try louvain.cluster(gpa, n, ledges, .{ .resolution = cluster_resolution, .measure_q = true });
    defer res.deinit(gpa);
    const cluster_ns = elapsed(io, t0);

    std.debug.print("\n  -- modularity clustering --  [{d:.0} ms, {d} levels]\n", .{ ms(cluster_ns), res.levels.len });
    for (res.levels, res.counts, res.q, 0..) |lvl, cnt, q, i| {
        const intra = louvain.intraFraction(n, ledges, lvl);
        var largest: usize = 0;
        {
            const sizes = try gpa.alloc(u32, cnt);
            defer gpa.free(sizes);
            @memset(sizes, 0);
            for (lvl) |c| sizes[c] += 1;
            for (sizes) |x| largest = @max(largest, x);
        }
        std.debug.print(
            "     L{d}  communities {d:>7}  links inside {d:>5.1}%  Q {d:.3}  largest {d} ({d:.1}% of vault)\n",
            .{ i, cnt, intra * 100, q, largest, @as(f64, @floatFromInt(largest)) * 100.0 / @as(f64, @floatFromInt(@max(n, 1))) },
        );
    }

    // The same measure over `fold`'s ladder, level by level, as the baseline to beat.
    var lad = try fold.build(gpa, n, edges, &.{}, .{});
    defer lad.deinit(gpa);
    const at_level = try gpa.alloc(u32, n);
    defer gpa.free(at_level);
    std.debug.print("  -- fold ladder, same measure --\n", .{});
    var step: u32 = 1;
    while (step <= 8) : (step += 1) {
        var distinct = std.AutoHashMap(u32, void).init(gpa);
        defer distinct.deinit();
        for (0..n) |i| {
            var c = lad.leaf_cell[i];
            var up: u32 = 0;
            while (up < step and c != fold.invalid and c < lad.cells.len) : (up += 1) {
                const par = lad.cells[c].parent;
                if (par == fold.invalid) break;
                c = par;
            }
            at_level[i] = c;
            distinct.put(c, {}) catch {};
        }
        var inside: f64 = 0;
        var total: f64 = 0;
        for (edges) |e| {
            if (e.a >= n or e.b >= n or e.a == e.b) continue;
            total += e.w;
            if (at_level[e.a] == at_level[e.b]) inside += e.w;
        }
        if (total <= 0) break;
        std.debug.print("     up {d}  cells {d:>7}  links inside {d:>5.1}%\n", .{ step, distinct.count(), inside / total * 100 });
    }
    std.debug.print("\n", .{});
}

fn worldSweep(gpa: std.mem.Allocator, io: std.Io, n: usize, edges: []const fold.Edge, paths: []const []const u8, label: []const u8) !void {
    if (want_cluster) try clusterReport(gpa, io, n, edges);
    // Timed, because this is what every republish costs: the layout job rebuilds the whole World
    // — `fold.build` over every note, `cellweb` over every link — each time the index bumps the
    // generation, including for a one-note edit.
    gpa_for_probe = gpa;
    const build_t0 = std.Io.Clock.boot.now(io).nanoseconds;
    var place_opts: containment.Options = .{};
    if (place_fill) |v| place_opts.fill = v;
    if (place_radius_exp) |v| place_opts.radius_exp = v;
    if (place_pack_gap) |v| place_opts.pack_gap = v;
    var fold_opts: fold.Options = .{};
    if (fold_degree_norm) |v| fold_opts.degree_norm = v;
    // The same two stages the panel runs: solve for positions, then group them. Building through
    // `World.init` instead would measure a path the app no longer takes — which is how this sweep
    // once came to report parameters nothing shipped with.
    var lay = try layout.solve(gpa, n, edges, paths, .{
        .note_r = place_opts.note_r,
        .territories = shapes_territories,
    });
    const solve_ns: u64 = @intCast(std.Io.Clock.boot.now(io).nanoseconds - build_t0);
    {
        const mp = multilevel.prof;
        const msf = struct {
            fn f(ns: u64) f64 {
                return @as(f64, @floatFromInt(ns)) / 1_000_000.0;
            }
        }.f;
        std.debug.print(
            "  solve ms: grid {d:.0}  pyramid {d:.0}  traverse {d:.0}  attract {d:.0}  integrate {d:.0}  coarsen {d:.0}   (sum {d:.0})\n",
            .{ msf(mp.grid_ns), msf(mp.pyramid_ns), msf(mp.traverse_ns), msf(mp.attract_ns), msf(mp.integrate_ns), msf(mp.coarsen_ns), msf(mp.total()) },
        );
    }
    var w = try world_mod.World.initFrom(gpa, n, edges, .{ .pos = lay.pos, .comp = lay.comp }, fold_opts, place_opts, .{});
    {
        // Which islands the vault's extent is actually made of.
        const cnt = try gpa.alloc(u32, lay.n_comp);
        defer gpa.free(cnt);
        const cx = try gpa.alloc(f64, lay.n_comp);
        defer gpa.free(cx);
        const cy = try gpa.alloc(f64, lay.n_comp);
        defer gpa.free(cy);
        @memset(cnt, 0);
        @memset(cx, 0);
        @memset(cy, 0);
        for (lay.pos, lay.comp) |q, c| {
            cnt[c] += 1;
            cx[c] += q.x;
            cy[c] += q.y;
        }
        for (cx, cy, cnt) |*a, *b, k| {
            if (k == 0) continue;
            a.* /= @floatFromInt(k);
            b.* /= @floatFromInt(k);
        }
        const rad = try gpa.alloc(f32, lay.n_comp);
        defer gpa.free(rad);
        @memset(rad, 0);
        for (lay.pos, lay.comp) |q, c| {
            const dx = q.x - @as(f32, @floatCast(cx[c]));
            const dy = q.y - @as(f32, @floatCast(cy[c]));
            rad[c] = @max(rad[c], @sqrt(dx * dx + dy * dy));
        }
        const ord = try gpa.alloc(u32, lay.n_comp);
        defer gpa.free(ord);
        for (ord, 0..) |*o, i| o.* = @intCast(i);
        const ByR = struct {
            r: []const f32,
            pub fn lessThan(self: @This(), a: u32, b: u32) bool {
                return self.r[a] > self.r[b];
            }
        };
        std.mem.sort(u32, ord, ByR{ .r = rad }, ByR.lessThan);
        // Density profile of the giant component on its own, so the drawer and the packing
        // cannot flatter or distort it.
        var big: u32 = 0;
        for (cnt, 0..) |k, c| if (k > cnt[big]) { big = @intCast(c); };
        {
            var hist: [8]u32 = @splat(0);
            var tot: u32 = 0;
            for (lay.pos, lay.comp) |q, c| {
                if (c != big) continue;
                const dx = q.x - @as(f32, @floatCast(cx[big]));
                const dy = q.y - @as(f32, @floatCast(cy[big]));
                const t = @sqrt(dx * dx + dy * dy) / @max(rad[big], 1e-6);
                // Equal-area rings: the k-th ring ends at sqrt((k+1)/8).
                var k: usize = 0;
                while (k < 7 and t > @sqrt(@as(f32, @floatFromInt(k + 1)) / 8.0)) : (k += 1) {}
                hist[k] += 1;
                tot += 1;
            }
            var rs: std.ArrayListUnmanaged(f32) = .empty;
            defer rs.deinit(gpa);
            for (lay.pos, lay.comp) |q, c| {
                if (c != big) continue;
                const dx = q.x - @as(f32, @floatCast(cx[big]));
                const dy = q.y - @as(f32, @floatCast(cy[big]));
                rs.append(gpa, @sqrt(dx * dx + dy * dy)) catch {};
            }
            std.mem.sort(f32, rs.items, {}, std.sort.asc(f32));
            const L = rs.items.len;
            std.debug.print("  giant radius  p50 {d:.0}  p90 {d:.0}  p99 {d:.0}  p99.9 {d:.0}  max {d:.0}  (n {d})\n", .{
                rs.items[L / 2], rs.items[L * 9 / 10], rs.items[L * 99 / 100], rs.items[L * 999 / 1000], rs.items[L - 1], L,
            });
            std.debug.print("  giant component density (equal-area rings):  ", .{});
            for (hist) |h| std.debug.print("{d:>5.1}", .{@as(f64, @floatFromInt(h)) * 100.0 / @as(f64, @floatFromInt(@max(tot, 1)))});
            std.debug.print("  %\n", .{});
        }
        std.debug.print("  components {d}; widest:", .{lay.n_comp});
        for (ord[0..@min(ord.len, 5)]) |c| {
            std.debug.print("  n={d} r={d:.0}", .{ cnt[c], rad[c] });
        }
        std.debug.print("\n", .{});
    }
    // Kept past `lay.deinit` for the stage split below, which rebuilds `spatial` from them.
    const lay_pos = try gpa.dupe(spatial.Vec2, lay.pos);
    defer gpa.free(lay_pos);
    const lay_comp = try gpa.dupe(u32, lay.comp);
    defer gpa.free(lay_comp);
    lay.deinit(gpa);
    defer w.deinit();
    const build_ns: u64 = @intCast(std.Io.Clock.boot.now(io).nanoseconds - build_t0);
    std.debug.print("  layout solve {d} ms of that\n", .{ms(solve_ns)});

    const budget: usize = world_budget;
    // Mirror the panel exactly, through the same function it calls — see
    // `Params.ambientLinkBudget`. Hardcoding a number here is how this sweep once came to report
    // 10,000 links at every coarse zoom while the app drew 900. A bench that quietly measures
    // different parameters than the thing it stands in for is worse than no bench.
    var focus_leaf: u32 = world_mod.fold.invalid;
    var open_leaves: [1]u32 = .{world_mod.fold.invalid};
    if (world_focus >= 0 and @as(usize, @intCast(world_focus)) < w.lad.leaf_cell.len) {
        focus_leaf = w.lad.leaf_cell[@intCast(world_focus)];
        open_leaves[0] = focus_leaf;
    }
    const params: world_mod.Params = .{
        .budget = budget,
        .focus_leaf = focus_leaf,
        .open_leaves = if (focus_leaf == world_mod.fold.invalid) &.{} else open_leaves[0..1],
        .link_budget = if (world_link_budget > 0)
            world_link_budget
        else
            world_mod.Params.ambientLinkBudget(budget),
        .links_per_cell = 2,
        .link_scan_cap = world_scan_cap,
        .split_px = world_split_px,
    };
    // The pane the graph actually gets, not a token viewport. Marks and links are selected by
    // what falls inside it, so a half-size window measures half the load.
    const vw: f32 = 2400;
    const vh: f32 = 980;
    const ext = w.extent();
    const z_fit = @min(vw, vh) * 0.44 / ext;

    std.debug.print("\n==== world: {s} ====\n", .{label});
    // `roots` is the floor on the drawn set: nothing above it can coalesce, so a vault with
    // thousands of roots cannot honour a mark budget at any zoom, however far out the reader goes.
    std.debug.print("  notes={d}  links={d}  ladder depth={d}  cells={d}  roots={d}  root r={d:.1}\n", .{
        n, edges.len, w.lad.depth, w.lad.cells.len, w.lad.roots.len, ext,
    });
    // Split the stages by building them once more on their own. Costs one extra build in the bench
    // and tells us which one a rebuild is actually spending its seconds in.
    //
    // These are the stages `World.buildFrom` runs, which are **not** the ones this used to report.
    // It timed `fold.build`, and the positions-first rewrite stopped calling it here: the drawing
    // hierarchy comes from `spatial.build` over the solved positions now. So the line blamed 589 ms
    // on a function this path does not execute, which is the same failure the `link_budget` comment
    // in `Params.ambientLinkBudget` warns about — a bench that measures something other than the
    // thing it stands in for is worse than no bench.
    var norm_ns: u64 = 0;
    var spat_ns: u64 = 0;
    var web_ns: u64 = 0;
    {
        const f0 = std.Io.Clock.boot.now(io).nanoseconds;
        const scored = try fold.degreeNormalised(gpa, n, edges, fold_opts.degree_norm);
        defer gpa.free(scored);
        const f1 = std.Io.Clock.boot.now(io).nanoseconds;
        const wnote = try gpa.alloc(f32, n);
        defer gpa.free(wnote);
        @memset(wnote, 0);
        for (edges) |e| {
            if (e.a >= n or e.b >= n or e.a == e.b) continue;
            wnote[e.a] += 1;
            wnote[e.b] += 1;
        }
        const body = try gpa.alloc(f32, n);
        defer gpa.free(body);
        @memset(body, 0);
        var spat2 = try spatial.build(gpa, n, lay_pos, lay_comp, wnote, body, .{});
        defer spat2.deinit(gpa);
        const f2 = std.Io.Clock.boot.now(io).nanoseconds;
        var web2 = try cellweb.build(gpa, &spat2.lad, scored);
        defer web2.deinit(gpa);
        const f3 = std.Io.Clock.boot.now(io).nanoseconds;
        norm_ns = @intCast(f1 - f0);
        spat_ns = @intCast(f2 - f1);
        web_ns = @intCast(f3 - f2);
    }
    std.debug.print(
        "  World.init (per republish) = {d:.0} ms   [degreeNorm {d:.0} ms  spatial {d:.0} ms  cellweb {d:.0} ms]\n",
        .{
            @as(f64, @floatFromInt(build_ns)) / 1e6,
            @as(f64, @floatFromInt(norm_ns)) / 1e6,
            @as(f64, @floatFromInt(spat_ns)) / 1e6,
            @as(f64, @floatFromInt(web_ns)) / 1e6,
        },
    );
    // Before `layoutReport`, deliberately. That diagnostic walks the whole ladder and leaves
    // every cell's children placed, and the app never does — travelling a cold field is part of
    // what the probe is measuring.
    if (world_zoom_travel) {
        // Centred on a real note for the same reason the static sweep is: at leaf zoom the world
        // origin is empty space between notes, and a probe that draws nothing measures nothing.
        var cx: f32 = 0;
        var cy: f32 = 0;
        if (w.noteWorldPos(if (world_focus >= 0) @intCast(world_focus) else sweep_centre_note)) |fp| {
            cx = fp.x;
            cy = fp.y;
        }
        try zoomProbe(io, &w, .{ .w = vw, .h = vh, .zoom = z_fit, .cx = cx, .cy = cy }, params, z_fit);
        return;
    }
    try layoutReport(gpa, io, &w, edges, paths, label);
    std.debug.print("  {s:>9}  {s:>7}  {s:>7}  {s:>7}  {s:>7}  {s:>7}  {s:>6} {s:>8} {s:>6} {s:>6} {s:>6}  {s:>7} {s:>7} {s:>7} {s:>7} {s:>8}\n", .{
        "zoom",  "marks",  "notes",   "masses",  "links",   "drawn",
        "bound", "cand", "chwy%", "hwy%", "mute%", "clr ms", "topo ms", "pres ms", "lift ms", "frame ms",
    });


    var zoom = z_fit;
    var stepn: usize = 0;
    const steps: usize = if (world_zoom_mul < 1.5) 40 else 14;
    while (stepn < steps) : (stepn += 1) {
        // settle, so what is printed is the resting set rather than a mid-crossfade frame
        // Centre on the focused note, which is what clicking one does — the whole report is about
        // what the reader sees after that.
        var cx: f32 = 0;
        var cy: f32 = 0;
        // Centred on a real note, not on the world origin.
        //
        // At the coarse end it makes no difference — the whole vault is on screen either way. At
        // the fine end it is the difference between measuring something and measuring nothing:
        // adjacent notes sit a `slot` apart (224 world units on simplewiki), so by zoom 44 a
        // 900x600 viewport spans about 20x13 units and the origin is simply empty space between
        // notes. Every row past that reported 0 marks and a 0.03 ms frame, which reads as the
        // renderer being free when in fact nothing was being drawn — the exact rows a zoom sweep
        // exists to put under load.
        if (w.noteWorldPos(if (world_focus >= 0) @intCast(world_focus) else sweep_centre_note)) |fp| {
            cx = fp.x;
            cy = fp.y;
        }
        const view: world_mod.View = .{ .w = vw, .h = vh, .zoom = zoom, .cx = cx, .cy = cy };
        for (0..120) |_| try w.step(view, params, 1.0 / 60.0);

        // One more frame, phase by phase. Timings are of the *settled* frame — the steady state a
        // parked camera pays forever, which is what the frame rate is actually made of.
        var t0 = now(io);
        w.clearFrame();
        const clr_ns = elapsed(io, t0);
        t0 = now(io);
        try w.decideTopology(view, params);
        const topo_ns = elapsed(io, t0);
        t0 = now(io);
        try w.present(view, params, 1.0 / 60.0);
        const pres_ns = elapsed(io, t0);
        t0 = now(io);
        try w.liftLinks(params, 1.0);
        const lift_ns = elapsed(io, t0);
        const notes = w.noteMarks();
        // What the *draw* would keep, not what the lift produced. The two numbers diverge: the
        // lift fills its budget at every zoom while the drawn count collapses as the camera
        // closes in.
        var have: std.AutoHashMapUnmanaged(u32, void) = .empty;
        defer have.deinit(gpa);
        for (w.marks.items) |m| try have.put(gpa, m.cell, {});
        var drawn: usize = 0;
        for (w.links.items) |l| {
            if (l.focus) continue;
            if (have.contains(l.a) or have.contains(l.b)) drawn += 1;
        }
        if (world_focus >= 0) {
            std.debug.print("    focus: leaf links {d}  ambient draw list {d}{s}\n", .{
                w.focus_links.items.len,
                w.links.items.len,
                // `world_draw` nests the focused note's own pass inside the ambient one.
                if (w.focus_links.items.len > 0 and w.links.items.len == 0)
                    "   <-- HIGHLIGHT NOT DRAWN"
                else
                    "",
            });
        }
        var hwy_n: usize = 0;
        for (w.links.items) |l| {
            if (l.highway) hwy_n += 1;
        }
        // Drawn marks with no line touching them, as a share of those that *have* a link in the
        // graph. This is the "floating island" the reader sees: a cluster the budget left mute,
        // which reads as unconnected and then sprouts a dozen connections one zoom step later.
        var mute_n: usize = 0;
        var linked_n: usize = 0;
        {
            var touched = std.AutoHashMapUnmanaged(u32, void){};
            defer touched.deinit(gpa);
            for (w.links.items) |l| {
                try touched.put(gpa, l.a, {});
                try touched.put(gpa, l.b, {});
            }
            for (w.marks.items) |m| {
                const lo, const hi = w.web.range(m.cell);
                if (hi <= lo) continue;
                linked_n += 1;
                if (!touched.contains(m.cell)) mute_n += 1;
            }
        }
        std.debug.print("  {d:>9.3}  {d:>7}  {d:>7}  {d:>7}  {d:>7}  {d:>7}  {s:>6} {d:>8} {d:>5}% {d:>5}% {d:>5}%  {d:>7.2} {d:>7.2} {d:>7.2} {d:>7.2} {d:>8.2}\n", .{
            zoom,
            w.marks.items.len,
            notes,
            w.marks.items.len - notes,
            w.links.items.len,
            drawn,
            if (w.bound) "Y" else "",
            w.last_candidates,
            if (w.last_candidates > 0) w.last_cand_highway * 100 / w.last_candidates else 0,
            if (w.links.items.len > 0) hwy_n * 100 / w.links.items.len else 0,
            if (linked_n > 0) mute_n * 100 / linked_n else 0,
            ms(clr_ns),
            ms(topo_ns),
            ms(pres_ns),
            ms(lift_ns),
            ms(clr_ns + topo_ns + pres_ns + lift_ns),
        });
        if (w.marks.items.len > budget * 2) std.debug.print("    ^^ OVER BUDGET\n", .{});
        if (world_pan) {
            try panProbe(io, &w, view, params, 0);
            try panProbe(io, &w, view, params, world_pan_px);
        }
        zoom *= world_zoom_mul;
    }
}

/// `--interior`: the interior rewrite's own sweep. Builds a note's content cloud exactly as
/// `graph.zig`'s `buildInteriorWorld`/`stepInteriorWorld` do — root dropped from the fold graph,
/// `.link` edges weighted 1.4 against 1.0 for `.outline`, a zero-padded document-order path chain,
/// arity seven, interior-scale budget — against `vault_synth.DocSpec.flatHeadingsExtreme()`, which
/// reproduces the gauntlet's `giant-2.md` shape (one root, 800 flat headings, one paragraph each)
/// that motivated this whole redesign. Confirms containment's exhaustive slot search stays cheap
/// at the interior's smaller budget too, not just the vault's — asserted but unmeasured until now.
/// Mirrors `graph.zig`'s `buildInteriorWorld` radial placement directly (no fold/containment/world
/// involved any more — see that function's doc comment for why the tree-packing version was
/// dropped) against `flatHeadingsExtreme()`, the exact shape that motivated the rewrite. Every
/// item is always drawn in this layout, so there's no LOD/budget left to sweep; what's worth
/// checking here is just that the radial math stays well-behaved (finite, monotonic in depth,
/// item count matches) at the scale that broke the old tree-packing version.
fn interiorSweep(gpa: std.mem.Allocator) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var prng = std.Random.DefaultPrng.init(0xC0FFEE);
    const cg = try vault_synth.synthContentGraph(arena, prng.random(), vault_synth.DocSpec.flatHeadingsExtreme());
    const n = cg.items.len;
    const m = n - 1; // everything but the root

    var parent_level = try arena.alloc(i32, n);
    @memset(parent_level, -1);
    for (cg.edges) |e| {
        if (e.kind != .outline) continue;
        if (e.b < n) parent_level[e.b] = @intCast(cg.items[e.a].level);
    }
    const ring_gap: f32 = 1.6;
    const content_offset: f32 = 0.6;
    var min_r: f32 = std.math.floatMax(f32);
    var max_r: f32 = 0;
    var by_depth: [8]u32 = @splat(0);
    for (1..n) |i| {
        const depth: f32 = if (cg.items[i].kind == .heading)
            @floatFromInt(cg.items[i].level)
        else
            @as(f32, @floatFromInt(if (parent_level[i] >= 0) parent_level[i] else 0)) + content_offset;
        const r = 1.0 + depth * ring_gap;
        min_r = @min(min_r, r);
        max_r = @max(max_r, r);
        const band: usize = @min(@as(usize, @intFromFloat(depth)), by_depth.len - 1);
        by_depth[band] += 1;
    }

    std.debug.print("\n==== interior: flatHeadingsExtreme (radial) ====\n", .{});
    std.debug.print("  items={d} (root + {d} content)  radius range=[{d:.2}, {d:.2}]\n", .{ n, m, min_r, max_r });
    std.debug.print("  items per depth band: {any}\n", .{by_depth});
    if (min_r <= 0 or !std.math.isFinite(max_r)) std.debug.print("  !! non-finite or non-positive radius\n", .{});
}

/// What a frame costs while the camera is *moving*, which is the only case anyone complains about.
///
/// The settled row above this is the parked steady state, and the parked state is exactly the one
/// the lift cache makes free — `lift_key` matches, so all the work the row reports is crossfade
/// bookkeeping. A pan changes the cut nearly every frame, so the whole lift is recomputed at frame
/// rate, and none of that shows up in a sweep that only measures settled frames. Two separate
/// performance investigations have measured the parked case and concluded the panel was fine.
var gpa_for_probe: std.mem.Allocator = undefined;

/// What the finished layout is actually like, in numbers.
///
/// Four measurements, because "the graph looks like a lattice glob" is not something the existing
/// sweep can see. It reports marks and links and frame times, all of which can be perfect while the
/// picture is wrong — and they were. A layout change with no grade attached is how two attempts
/// came to be believed and one came to be disbelieved on the wrong evidence.
///
/// Everything is sampled. Placing 284k leaves and every cell exhaustively is minutes of work and
/// the distributions settle in the first few thousand; `ensurePlaced` is memoised, so a strided
/// sample warms the ancestors it shares and later draws are nearly free.
/// Link spread over an arbitrary set of positions.
///
/// Takes the positions rather than reaching into a `World`, because the whole point of the
/// positions-first work is that there is now more than one thing that can produce them: the old
/// `containment` placement and the new `layout.solve`. Grading both with the same code is the only
/// way the comparison means anything.
fn linkSpreadReport(
    gpa: std.mem.Allocator,
    edges: []const fold.Edge,
    pos: []const spatial.Vec2,
    deg: []const u32,
    ext: f64,
    sample_cap: usize,
) !void {
    // -- 1. link spread: how far a link has to travel ------------------------------------------
    //
    // The objective for "things that are linked should end up near each other". Note that this is
    // *not* the one that tracks how the map looks — a curve-order coarsening made this worse while
    // changing the picture not at all, and the picture was the complaint. Kept because it is still
    // the honest grade for grouping, and because a layout change that wrecks it is worth knowing
    // about even if it looks nicer.
    if (edges.len > 0) {
        var lens: std.ArrayListUnmanaged(f32) = .empty;
        defer lens.deinit(gpa);
        const stride = @max(1, edges.len / sample_cap);
        var i: usize = 0;
        while (i < edges.len) : (i += stride) {
            const a = posOf(pos, edges[i].a) orelse continue;
            const b = posOf(pos, edges[i].b) orelse continue;
            const dx = a.x - b.x;
            const dy = a.y - b.y;
            try lens.append(gpa, @sqrt(dx * dx + dy * dy));
        }
        if (lens.items.len > 0) {
            std.mem.sort(f32, lens.items, {}, std.sort.asc(f32));
            var sum: f64 = 0;
            var far: usize = 0;
            for (lens.items) |l| {
                sum += l;
                if (l > ext * 0.25) far += 1;
            }
            const n: f64 = @floatFromInt(lens.items.len);
            std.debug.print(
                "  link spread   mean {d:.3}r  p50 {d:.3}r  p90 {d:.3}r   crossing {d:.1}%\n",
                .{
                    sum / n / ext,
                    @as(f64, lens.items[lens.items.len / 2]) / ext,
                    @as(f64, lens.items[lens.items.len * 9 / 10]) / ext,
                    @as(f64, @floatFromInt(far)) * 100.0 / n,
                },
            );
        }

        // The same sample, split by the busier endpoint's degree.
        const cuts = [_]u32{ 8, 32, 128, 512, std.math.maxInt(u32) };
        var b_sum: [cuts.len]f64 = .{0} ** cuts.len;
        var b_far: [cuts.len]usize = .{0} ** cuts.len;
        var b_n: [cuts.len]usize = .{0} ** cuts.len;
        var ei: usize = 0;
        while (ei < edges.len) : (ei += stride) {
            const e = edges[ei];
            if (e.a >= deg.len or e.b >= deg.len) continue;
            const a = posOf(pos, e.a) orelse continue;
            const b = posOf(pos, e.b) orelse continue;
            const dx = a.x - b.x;
            const dy = a.y - b.y;
            const l = @sqrt(dx * dx + dy * dy);
            const d = @max(deg[e.a], deg[e.b]);
            for (cuts, 0..) |c, bi| {
                if (d <= c) {
                    b_sum[bi] += l;
                    b_n[bi] += 1;
                    if (l > ext * 0.25) b_far[bi] += 1;
                    break;
                }
            }
        }
        std.debug.print("     by busier endpoint's degree:\n", .{});
        var lo: u32 = 0;
        for (cuts, 0..) |c, bi| {
            if (b_n[bi] == 0) {
                lo = c +| 1; // the last cut is `maxInt`, and there is no bucket after it to name
                continue;
            }
            const bn: f64 = @floatFromInt(b_n[bi]);
            var lbuf: [24]u8 = undefined;
            const name = if (c == std.math.maxInt(u32))
                try std.fmt.bufPrint(&lbuf, "{d}+", .{lo})
            else
                try std.fmt.bufPrint(&lbuf, "{d}-{d}", .{ lo, c });
            std.debug.print(
                "       deg {s:>9}   n {d:>6}  ({d:>4.1}% of links)   mean {d:.3}r   crossing {d:.1}%\n",
                .{
                    name,                    b_n[bi],
                    bn * 100.0 / @as(f64, @floatFromInt(lens.items.len)),
                    b_sum[bi] / bn / ext,    @as(f64, @floatFromInt(b_far[bi])) * 100.0 / bn,
                },
            );
            lo = c +| 1; // the last cut is `maxInt`, and there is no bucket after it to name
        }
    }
}

fn posOf(pos: []const spatial.Vec2, i: u32) ?spatial.Vec2 {
    if (i >= pos.len) return null;
    return pos[i];
}

fn layoutReport(
    gpa: std.mem.Allocator,
    io: std.Io,
    w: *world_mod.World,
    edges: []const fold.Edge,
    paths: []const []const u8,
    label: []const u8,
) !void {
    const t0 = now(io);
    const ext = @max(w.extent(), 1e-3);
    const sample_cap: usize = 60_000;

    // -- 0. degree, so link spread can be read by what kind of link it is -----------------------
    //
    // A hub link cannot be short, and no layout can make it short. One note holds one position, so
    // at arity 7 at most six of a hub's neighbours can be its siblings — the other 29,442 are
    // somewhere else by arithmetic, not by any failure of placement. Reporting one number over all
    // links therefore buries the only part that is actually decidable: whether the *local* web,
    // between ordinary notes, is short. Bucketing by the busier endpoint separates the two.
    const deg = try gpa.alloc(u32, w.lad.leaf_cell.len);
    defer gpa.free(deg);
    @memset(deg, 0);
    for (edges) |e| {
        if (e.a >= deg.len or e.b >= deg.len or e.a == e.b) continue;
        deg[e.a] += 1;
        deg[e.b] += 1;
    }

    {
        const lp = try gpa.alloc(spatial.Vec2, w.lad.leaf_cell.len);
        defer gpa.free(lp);
        for (lp, 0..) |*q, i| {
            if (w.noteWorldPos(@intCast(i))) |wp| {
                q.* = .{ .x = wp.x, .y = wp.y };
            } else {
                q.* = .{};
            }
        }
        try linkSpreadReport(gpa, edges, lp, deg, ext, sample_cap);
    }

    // -- 1b. co-citation distance: is *nearby* the same as *related*? ---------------------------
    //
    // `link spread` grades the links that exist. It says nothing about the far commoner case —
    // two notes with no link between them that are plainly about the same thing because they
    // point at the same handful of others. That is what makes a map browsable: drifting across it
    // should pass through things that belong together, not just things that are wired together.
    //
    // Measured as: pairs sharing at least `cocite_min` neighbours and *not* directly linked, how
    // far apart do they sit, against random pairs as the null. Equal medians mean the layout has
    // captured none of it.
    //
    // Hubs are excluded as intermediaries. Two notes both linking to *United States* have nothing
    // in common; only a shared neighbour that is itself selective is evidence, which is the same
    // argument `degreeNormalised` makes about a link's weight.
    {
        const deg_cap: u32 = 128;
        const cocite_min: u32 = 3;
        const pos = try gpa.alloc(spatial.Vec2, w.lad.leaf_cell.len);
        defer gpa.free(pos);
        for (pos, 0..) |*q, i| {
            if (w.noteWorldPos(@intCast(i))) |wp| {
                q.* = .{ .x = wp.x, .y = wp.y };
            } else {
                q.* = .{};
            }
        }
        const starts = try gpa.alloc(u32, deg.len + 1);
        defer gpa.free(starts);
        @memset(starts, 0);
        for (edges) |e| {
            if (e.a >= deg.len or e.b >= deg.len or e.a == e.b) continue;
            starts[e.a + 1] += 1;
            starts[e.b + 1] += 1;
        }
        for (1..starts.len) |i| starts[i] += starts[i - 1];
        const adj = try gpa.alloc(u32, edges.len * 2);
        defer gpa.free(adj);
        const cur = try gpa.alloc(u32, deg.len);
        defer gpa.free(cur);
        @memcpy(cur, starts[0..deg.len]);
        for (edges) |e| {
            if (e.a >= deg.len or e.b >= deg.len or e.a == e.b) continue;
            adj[cur[e.a]] = e.b;
            cur[e.a] += 1;
            adj[cur[e.b]] = e.a;
            cur[e.b] += 1;
        }

        const shared = try gpa.alloc(u32, deg.len);
        defer gpa.free(shared);
        @memset(shared, 0);
        var touched: std.ArrayListUnmanaged(u32) = .empty;
        defer touched.deinit(gpa);
        var near: std.ArrayListUnmanaged(f32) = .empty;
        defer near.deinit(gpa);

        const stride = @max(1, deg.len / 4000);
        var u: usize = 0;
        while (u < deg.len) : (u += stride) {
            if (deg[u] == 0 or deg[u] > deg_cap) continue;
            const pu = posOf(pos, @intCast(u)) orelse continue;
            for (starts[u]..starts[u + 1]) |ka| {
                const v = adj[ka];
                if (deg[v] > deg_cap) continue; // a hub shared by both says nothing
                for (starts[v]..starts[v + 1]) |kb| {
                    const t = adj[kb];
                    if (t == u) continue;
                    if (shared[t] == 0) touched.append(gpa, t) catch continue;
                    shared[t] += 1;
                }
            }
            for (touched.items) |t| {
                if (shared[t] >= cocite_min) direct: {
                    for (starts[u]..starts[u + 1]) |k| if (adj[k] == t) break :direct;
                    const pt = posOf(pos, t) orelse break :direct;
                    const dx = pu.x - pt.x;
                    const dy = pu.y - pt.y;
                    near.append(gpa, @sqrt(dx * dx + dy * dy)) catch {};
                }
                shared[t] = 0;
            }
            touched.clearRetainingCapacity();
        }

        if (near.items.len > 0) {
            std.mem.sort(f32, near.items, {}, std.sort.asc(f32));
            // Null model: the same count of arbitrary pairs, walked with a coprime stride so the
            // sample is spread rather than local.
            var rnd: std.ArrayListUnmanaged(f32) = .empty;
            defer rnd.deinit(gpa);
            var i: usize = 0;
            while (i < near.items.len and i < 60_000) : (i += 1) {
                const a = (i * 7919) % pos.len;
                const b = (i * 104729 + 5000) % pos.len;
                if (a == b) continue;
                const dx = pos[a].x - pos[b].x;
                const dy = pos[a].y - pos[b].y;
                rnd.append(gpa, @sqrt(dx * dx + dy * dy)) catch {};
            }
            std.mem.sort(f32, rnd.items, {}, std.sort.asc(f32));
            const nm = @as(f64, near.items[near.items.len / 2]) / ext;
            const rm = if (rnd.items.len > 0) @as(f64, rnd.items[rnd.items.len / 2]) / ext else 0;
            std.debug.print(
                "  co-citation    n {d}  median {d:.3}r   random pairs {d:.3}r   ratio {d:.2}x closer\n",
                .{ near.items.len, nm, rm, if (nm > 1e-6) rm / nm else 0 },
            );
        }
    }

    // -- 2 & 4. sibling overlap and hexagonal order --------------------------------------------
    //
    // Overlap is the "glob": `containment` computes its own separation threshold
    // (`minRadiusExp(fill)` ≈ 0.619 at the shipped fill) and ships `radius_exp = 0.5`, so siblings
    // are expected to intersect at every level. This says by how much.
    //
    // Order is the "+ sign and horizontal rows". Every cell places six ring children on a uniform
    // 60° step, so each cell on its own is perfectly hexagonal — but the rotation is a function of
    // *level*, so every cell at a given level shares one orientation and the hexagons line up
    // across the whole vault. `local` is the first effect, `global` the second, and it is the
    // second that reads as a lattice.
    {
        var pairs: usize = 0;
        var overlapping: usize = 0;
        var penetration: f64 = 0;
        var local_sum: f64 = 0;
        var local_n: usize = 0;
        var gx: f64 = 0;
        var gy: f64 = 0;
        var gn: usize = 0;

        const stride = @max(1, w.lad.cells.len / 20_000);
        var ci: usize = 0;
        while (ci < w.lad.cells.len) : (ci += stride) {
            const cell: u32 = @intCast(ci);
            if (w.lad.cells[cell].child_count < 2) continue;
            w.field.ensurePlaced(&w.lad, cell);
            const centre = w.field.pos[cell];
            const kids = w.lad.childrenOf(cell);

            for (kids, 0..) |ka, ai| {
                for (kids[ai + 1 ..]) |kb| {
                    const pa = w.field.pos[ka];
                    const pb = w.field.pos[kb];
                    const ra = w.field.radius(&w.lad, ka);
                    const rb = w.field.radius(&w.lad, kb);
                    const dx = pa.x - pb.x;
                    const dy = pa.y - pb.y;
                    const d = @sqrt(dx * dx + dy * dy);
                    pairs += 1;
                    if (d < ra + rb) {
                        overlapping += 1;
                        penetration += @as(f64, (ra + rb - d)) / @max(1e-6, @min(ra, rb));
                    }
                }
            }

            // Six-fold order parameter of this cell's children about its centre.
            var sx: f64 = 0;
            var sy: f64 = 0;
            var kn: usize = 0;
            for (kids) |k| {
                const p = w.field.pos[k];
                const dx = p.x - centre.x;
                const dy = p.y - centre.y;
                if (@abs(dx) < 1e-6 and @abs(dy) < 1e-6) continue; // the centre child has no angle
                const th = std.math.atan2(dy, dx);
                sx += @cos(6 * th);
                sy += @sin(6 * th);
                gx += @cos(6 * th);
                gy += @sin(6 * th);
                kn += 1;
                gn += 1;
            }
            if (kn > 0) {
                const kf: f64 = @floatFromInt(kn);
                local_sum += @sqrt(sx * sx + sy * sy) / kf;
                local_n += 1;
            }
        }

        if (pairs > 0) {
            std.debug.print(
                "  sibling discs overlapping {d:.1}%   mean penetration {d:.2}x smaller radius\n",
                .{
                    @as(f64, @floatFromInt(overlapping)) * 100.0 / @as(f64, @floatFromInt(pairs)),
                    if (overlapping > 0) penetration / @as(f64, @floatFromInt(overlapping)) else 0,
                },
            );
        }
        if (local_n > 0 and gn > 0) {
            const gf: f64 = @floatFromInt(gn);
            std.debug.print(
                "  hex order     local {d:.3}  global {d:.3}   (1 = perfect lattice, 0 = isotropic)\n",
                .{
                    local_sum / @as(f64, @floatFromInt(local_n)),
                    @sqrt(gx * gx + gy * gy) / gf,
                },
            );
        }
    }

    // -- 2b. descent travel: how far a note jumps when its group explodes -----------------------
    //
    // A mark is drawn at its cell's centre, and as the camera closes in the cell standing in for a
    // note walks down the ladder — root, then the cell inside that, and so on to the leaf. Each
    // step moves the mark from one centre to the next, and `present` animates that as a slide. The
    // *size* of those steps is what decides whether zooming into a note reads as the note growing
    // or as the note flying across the screen and off it.
    //
    // Containment bounds a step by the parent's radius, which sounds reassuring and is not: at the
    // zoom where a cell is opening, its radius is most of the viewport. So the bound is "anywhere
    // on screen", and only measurement says where in that range a real vault sits.
    {
        var worst: std.ArrayListUnmanaged(f32) = .empty;
        defer worst.deinit(gpa);
        const n_notes = w.lad.leaf_cell.len;
        const stride = @max(1, n_notes / 20_000);
        var i: usize = 0;
        while (i < n_notes) : (i += stride) {
            const leaf = w.lad.leaf_cell[i];
            if (leaf == fold.invalid or leaf >= w.lad.cells.len) continue;
            w.field.ensurePlaced(&w.lad, leaf);

            // Root-down, so each step is the move the reader actually sees at that level change.
            var chain: [64]u32 = undefined;
            var n: usize = 0;
            var c = leaf;
            while (n < chain.len) {
                chain[n] = c;
                n += 1;
                const parent = w.lad.cells[c].parent;
                if (parent == fold.invalid) break;
                c = parent;
            }
            var biggest: f32 = 0;
            var k = n;
            while (k > 1) {
                k -= 1;
                const a = w.field.pos[chain[k]];
                const b = w.field.pos[chain[k - 1]];
                const dx = a.x - b.x;
                const dy = a.y - b.y;
                biggest = @max(biggest, @sqrt(dx * dx + dy * dy));
            }
            try worst.append(gpa, biggest);
        }
        if (worst.items.len > 0) {
            std.mem.sort(f32, worst.items, {}, std.sort.asc(f32));
            var sum: f64 = 0;
            for (worst.items) |v| sum += v;
            const n: f64 = @floatFromInt(worst.items.len);
            std.debug.print(
                "  descent travel (largest single level jump, per note)   mean {d:.3}r  p50 {d:.3}r  p90 {d:.3}r  max {d:.3}r\n",
                .{
                    sum / n / ext,
                    @as(f64, worst.items[worst.items.len / 2]) / ext,
                    @as(f64, worst.items[worst.items.len * 9 / 10]) / ext,
                    @as(f64, worst.items[worst.items.len - 1]) / ext,
                },
            );
        }
    }

    // -- 3. radial density profile -------------------------------------------------------------
    //
    // Equal-area rings, so a uniform layout reports eight equal numbers and the shape of the list
    // *is* the density gradient. "Dense in the middle, fading out" is a front-loaded list; the
    // blank annulus the reader sees around the giant component is a trailing zero.
    {
        const rings = 8;
        var hist: [rings]usize = .{0} ** rings;
        var total: usize = 0;
        const n_notes = w.lad.leaf_cell.len;
        const stride = @max(1, n_notes / sample_cap);
        var i: usize = 0;
        while (i < n_notes) : (i += stride) {
            const p = w.noteWorldPos(@intCast(i)) orelse continue;
            const r = @sqrt(p.x * p.x + p.y * p.y) / ext;
            // Equal-area rings: ring `b` spans radii √(b/rings) .. √((b+1)/rings).
            const b: usize = @intFromFloat(@min(@as(f32, rings - 1), r * r * rings));
            hist[b] += 1;
            total += 1;
        }
        if (total > 0) {
            std.debug.print("  radial density (equal-area rings, centre first):  ", .{});
            for (hist) |h| {
                std.debug.print("{d:>5.1}", .{@as(f64, @floatFromInt(h)) * 100.0 / @as(f64, @floatFromInt(total))});
            }
            std.debug.print("  %\n", .{});
        }
    }

    std.debug.print("  [layout report {d:.0} ms]\n", .{ms(elapsed(io, t0))});
    if (want_spatial) try spatialReport(gpa, io, w, edges, paths);
    if (svg_dir) |d| try writeWorldSvg(gpa, io, w, edges, d, label);
}

/// The same two structural numbers, for a hierarchy grouped by *proximity* over the very same leaf
/// positions.
///
/// One variable changes: which notes get drawn together. The positions are byte-for-byte the ones
/// `containment` produced, so any difference is the grouping rule and nothing else. That is the
/// whole reason this runs before a new position source lands — measuring both at once would leave
/// a regression unattributable.
fn spatialReport(
    gpa: std.mem.Allocator,
    io: std.Io,
    w: *world_mod.World,
    edges: []const fold.Edge,
    paths: []const []const u8,
) !void {
    const n_notes = w.lad.leaf_cell.len;
    if (n_notes == 0) return;

    // Eager placement. This is exactly the cost lazy placement exists to avoid, and paying it here
    // is the point of doing this in the bench rather than in the app.
    const t_place = now(io);
    const pos = try gpa.alloc(spatial.Vec2, n_notes);
    defer gpa.free(pos);
    const comp = try gpa.alloc(u32, n_notes);
    defer gpa.free(comp);
    const weight = try gpa.alloc(f32, n_notes);
    defer gpa.free(weight);
    const body = try gpa.alloc(f32, n_notes);
    defer gpa.free(body);

    var placed: usize = 0;
    for (0..n_notes) |i| {
        const leaf = w.lad.leaf_cell[i];
        if (leaf == fold.invalid or leaf >= w.lad.cells.len) {
            pos[i] = .{};
            comp[i] = 0;
            weight[i] = 0;
            body[i] = 0;
            continue;
        }
        if (w.noteWorldPos(@intCast(i))) |wp| {
            pos[i] = .{ .x = wp.x, .y = wp.y };
        } else {
            pos[i] = .{};
        }
        comp[i] = w.lad.cells[leaf].comp;
        weight[i] = w.lad.cells[leaf].weight;
        body[i] = w.lad.cells[leaf].body;
        placed += 1;
    }
    var place_ns = elapsed(io, t_place);

    const note_r = w.field.radius(&w.lad, w.lad.leaf_cell[0]);
    var ext = @max(w.extent(), 1e-3);

    // `--relayout`: throw the containment positions away and solve for new ones from the links.
    // Same note radius, same metrics, same hierarchy builder — so every number below is directly
    // comparable to the run without this flag, and the only thing that changed is where notes are.
    var relaid: layout.Result = .{};
    defer relaid.deinit(gpa);
    if (want_relayout) {
        const t_solve = now(io);
        relaid = try layout.solve(gpa, n_notes, edges, paths, .{
            .note_r = note_r,
            .iters = .{ .max_iters = ml_iters },
        });
        place_ns = elapsed(io, t_solve);
        @memcpy(pos, relaid.pos);
        @memcpy(comp, relaid.comp);
        ext = 1e-3;
        for (pos) |q| ext = @max(ext, @sqrt(q.x * q.x + q.y * q.y));
        std.debug.print(
            "  relayout: {d} components, extent {d:.0}, median leaf spacing {d:.2}x note_r  [solve {d:.0} ms]\n",
            .{ relaid.n_comp, ext, relaid.spacing, ms(place_ns) },
        );

        // The grade that matters for a *layout*: are linked notes actually near each other? Run
        // over the new positions with the same code that graded the old ones.
        const deg = try gpa.alloc(u32, n_notes);
        defer gpa.free(deg);
        @memset(deg, 0);
        for (edges) |e| {
            if (e.a >= deg.len or e.b >= deg.len or e.a == e.b) continue;
            deg[e.a] += 1;
            deg[e.b] += 1;
        }
        try linkSpreadReport(gpa, edges, pos, deg, ext, 60_000);
    }
    const t_build = now(io);
    var res = try spatial.build(gpa, n_notes, pos, comp, weight, body, .{
        .arity = .seven,
        // The leaf radius `containment` would have drawn, so the two hierarchies are compared at
        // the same note size and the overlap numbers mean the same thing.
        .note_r = note_r,
        .quant_half = ext,
    });
    defer res.deinit(gpa);
    const build_ns = elapsed(io, t_build);

    // -- sibling overlap, same definition as the fold-side report --
    var pairs: usize = 0;
    var overlapping: usize = 0;
    var penetration: f64 = 0;
    for (res.lad.cells, 0..) |c, id| {
        if (c.child_count < 2) continue;
        const kids = res.lad.childrenOf(@intCast(id));
        for (kids, 0..) |ka, ai| {
            for (kids[ai + 1 ..]) |kb| {
                pairs += 1;
                const dx = res.pos[ka].x - res.pos[kb].x;
                const dy = res.pos[ka].y - res.pos[kb].y;
                const d = @sqrt(dx * dx + dy * dy);
                const want = res.bound_r[ka] + res.bound_r[kb];
                if (d < want) {
                    overlapping += 1;
                    penetration += @as(f64, want - d) / @max(1e-6, @min(res.bound_r[ka], res.bound_r[kb]));
                }
            }
        }
    }

    // -- descent travel, same definition --
    var worst: std.ArrayListUnmanaged(f32) = .empty;
    defer worst.deinit(gpa);
    const stride = @max(1, n_notes / 20_000);
    var i: usize = 0;
    while (i < n_notes) : (i += stride) {
        var chain: [64]u32 = undefined;
        var cn: usize = 0;
        var c = res.lad.leaf_cell[i];
        while (cn < chain.len and c != fold.invalid and c < res.lad.cells.len) {
            chain[cn] = c;
            cn += 1;
            c = res.lad.cells[c].parent;
        }
        var biggest: f32 = 0;
        var k = cn;
        while (k > 1) {
            k -= 1;
            const dx = res.pos[chain[k]].x - res.pos[chain[k - 1]].x;
            const dy = res.pos[chain[k]].y - res.pos[chain[k - 1]].y;
            biggest = @max(biggest, @sqrt(dx * dx + dy * dy));
        }
        try worst.append(gpa, biggest);
    }
    std.mem.sort(f32, worst.items, {}, std.sort.asc(f32));
    var tsum: f64 = 0;
    for (worst.items) |v| tsum += v;

    // How far apart the leaves actually are, in units of the radius they are drawn at.
    //
    // This is the number that decides whether *any* grouping can produce non-overlapping cells.
    // Two notes drawn at radius `r` overlap whenever they sit closer than `2r`, so if the median
    // leaf spacing is below 2.0 here then the leaves themselves overlap and every cell above them
    // inherits it — the hierarchy has nothing to work with. Curve-adjacent is used as the
    // neighbour, which is an upper bound on true nearest-neighbour distance and close to it.
    {
        var gaps: std.ArrayListUnmanaged(f32) = .empty;
        defer gaps.deinit(gpa);
        var si: usize = 1;
        while (si < res.lad.note_at.len) : (si += 1) {
            const a = pos[res.lad.note_at[si - 1]];
            const b = pos[res.lad.note_at[si]];
            const dx = a.x - b.x;
            const dy = a.y - b.y;
            try gaps.append(gpa, @sqrt(dx * dx + dy * dy));
        }
        if (gaps.items.len > 0) {
            std.mem.sort(f32, gaps.items, {}, std.sort.asc(f32));
            std.debug.print(
                "  leaf spacing (curve-adjacent)   p50 {d:.2}x note_r   p10 {d:.2}x   (below 2.00x means leaves overlap)\n",
                .{
                    @as(f64, gaps.items[gaps.items.len / 2]) / note_r,
                    @as(f64, gaps.items[gaps.items.len / 10]) / note_r,
                },
            );
        }
    }

    std.debug.print("  -- spatial hierarchy over the same positions --\n", .{});
    std.debug.print(
        "  cells {d}  depth {d}  roots {d}   [place {d:.0} ms  build {d:.0} ms]\n",
        .{ res.lad.cells.len, res.lad.depth, res.lad.roots.len, ms(place_ns), ms(build_ns) },
    );
    if (pairs > 0) {
        std.debug.print(
            "  sibling discs overlapping {d:.1}%   mean penetration {d:.2}x smaller radius\n",
            .{
                @as(f64, @floatFromInt(overlapping)) * 100.0 / @as(f64, @floatFromInt(pairs)),
                if (overlapping > 0) penetration / @as(f64, @floatFromInt(overlapping)) else 0,
            },
        );
    }
    if (worst.items.len > 0) {
        const wn: f64 = @floatFromInt(worst.items.len);
        std.debug.print(
            "  descent travel (largest single level jump, per note)   mean {d:.3}r  p50 {d:.3}r  p90 {d:.3}r  max {d:.3}r\n",
            .{
                tsum / wn / ext,
                @as(f64, worst.items[worst.items.len / 2]) / ext,
                @as(f64, worst.items[worst.items.len * 9 / 10]) / ext,
                @as(f64, worst.items[worst.items.len - 1]) / ext,
            },
        );
    }
}

/// A picture of the placed vault, so a layout idea can be looked at without launching the editor.
///
/// The reason the earlier attempts were judged badly is that the only way to see a layout was to
/// run the app and squint at a hairball. An SVG can be opened, zoomed and diffed against the last
/// one.
fn writeWorldSvg(
    gpa: std.mem.Allocator,
    io: std.Io,
    w: *world_mod.World,
    edges: []const fold.Edge,
    dir: []const u8,
    label: []const u8,
) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Cap the drawing, not the vault: an SVG with 284k circles and 3.3M lines is a file no viewer
    // will open. A strided sample keeps the shape and loses only the ink.
    const draw_cap: usize = 12_000;
    const n_notes = w.lad.leaf_cell.len;
    const stride = @max(1, n_notes / draw_cap);

    var pts: std.ArrayListUnmanaged(dvui.Point) = .empty;
    const slot = try arena.alloc(u32, n_notes);
    @memset(slot, std.math.maxInt(u32));
    var i: usize = 0;
    while (i < n_notes) : (i += stride) {
        const p = w.noteWorldPos(@intCast(i)) orelse continue;
        slot[i] = @intCast(pts.items.len);
        try pts.append(arena, .{ .x = p.x, .y = p.y });
    }
    if (pts.items.len == 0) return;

    var kept: std.ArrayListUnmanaged(layout_full.Edge) = .empty;
    for (edges) |e| {
        if (e.a >= n_notes or e.b >= n_notes) continue;
        const sa = slot[e.a];
        const sb = slot[e.b];
        if (sa == std.math.maxInt(u32) or sb == std.math.maxInt(u32)) continue;
        try kept.append(arena, .{ .a = sa, .b = sb });
    }

    const degrees = try arena.alloc(u32, pts.items.len);
    @memset(degrees, 0);
    for (kept.items) |e| {
        degrees[e.a] += 1;
        degrees[e.b] += 1;
    }

    const name = try std.fmt.allocPrint(arena, "world-{s}", .{std.fs.path.basename(label)});
    try writeSvg(io, dir, name, pts.items, kept.items, degrees, arena);
    std.debug.print("  svg -> {s}/{s}.svg  ({d} notes, {d} links)\n", .{ dir, name, pts.items.len, kept.items.len });
}

/// `--zoom`: travel in and out repeatedly on **one** `World`, and report each lap separately.
///
/// The zoom sweep and `--pan` both measure a world that has just been built, at a zoom it has
/// settled at. Neither can see cost that *accumulates*: state that survives a frame and grows
/// every time the cut turns over — `link_fade`, lazy `containment` placement, the scratch tables —
/// is free on lap one and expensive on lap eight. "Smooth for the first few zooms, then very bad"
/// is exactly that shape, and nothing in the harness could show it.
///
/// So: ramp the camera from fit to leaf zoom and back, several times, on the same `World`, and
/// print per-lap frame cost beside the sizes of everything that persists. A lap that costs more
/// than the one before it names its own cause in the columns to its right.
fn zoomProbe(
    io: std.Io,
    w: *world_mod.World,
    view: world_mod.View,
    params: world_mod.Params,
    z_fit: f32,
) !void {
    // One lap covers the same decades the static sweep steps through, at a rate a hand can
    // actually produce: a scroll wheel run is roughly a factor of two per six frames.
    // Below fit as well as above it. The first cut of this started at fit and only travelled
    // inward, which is exactly the half that was already fine — the state the reader gets stuck
    // in is *further out* than fit, where the ladder has run out of things to coalesce and the
    // mark budget is being asked to bound a set that cannot shrink.
    const z_lo = z_fit / 16;
    const z_hi = z_fit * 4096;
    const half = 120;
    const per_lap = half * 2;
    // 120 fps is the target the map is judged against, so the whole frame — decide, present,
    // lift, and every pixel the panel then draws — has 8.33 ms. What this probe times is only the
    // first three; the draw is the rest of that budget, not headroom on top of it.
    const target_fps = 120;
    const frame_budget_ms: f64 = 1000.0 / @as(f64, target_fps);

    std.debug.print(
        "  frame budget {d:.2} ms ({d} fps)\n" ++
            "  {s:>4}  {s:>8} {s:>8} {s:>8} {s:>6}   {s:>7} {s:>7} {s:>9}   " ++
            "{s:>8} {s:>8} {s:>9} {s:>8} {s:>8}\n",
        .{ frame_budget_ms, target_fps, "lap",   "mean ms", "p95 ms", "max ms", "over", "marks", "links", "line Mpx",
            "rebuilt", "scan ms",  "build ms", "sort ms", "fade ms" },
    );

    world_mod.prof = .{};
    world_mod.prof_io = io;
    defer world_mod.prof_io = null;

    var samples: [per_lap]f64 = undefined;
    var prev: @TypeOf(world_mod.prof) = .{};
    var lap: u32 = 0;
    while (lap < world_zoom_cycles) : (lap += 1) {
        var v = view;
        var marks_max: usize = 0;
        var links_max: usize = 0;
        var fades_max: u32 = 0;
        var line_px_max: f64 = 0;
        for (0..per_lap) |i| {
            // Geometric in, geometric out: constant *ratio* per frame is what a wheel does, and a
            // linear ramp would crawl at overview and jump decades at leaf zoom.
            const k: f32 = if (i < half)
                @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(half))
            else
                @as(f32, @floatFromInt(per_lap - i)) / @as(f32, @floatFromInt(half));
            v.zoom = z_lo * std.math.pow(f32, z_hi / z_lo, k);

            const t0 = now(io);
            w.clearFrame();
            try w.decideTopology(v, params);
            try w.present(v, params, 1.0 / 60.0);
            try w.liftLinks(params, 1.0 / 60.0);
            samples[i] = ms(elapsed(io, t0));
            // Peak, not the value at the end of the lap. A lap ends back at fit zoom where almost
            // nothing is drawn, so end-of-lap sizes describe the cheapest frame in it.
            marks_max = @max(marks_max, w.marks.items.len);
            links_max = @max(links_max, w.links.items.len);
            fades_max = @max(fades_max, @as(u32, @intCast(w.fades.items.len)));

            // Total drawn line length, in screen pixels.
            //
            // Link *count* is budgeted and identical between two layouts; link *length* is not,
            // and it is what the rasteriser actually pays. A layout whose links cross a quarter of
            // the vault draws the same 11,250 lines over several times the pixels, and none of the
            // columns beside this one can tell the two apart — which is how a layout change that
            // tripled mean link length read as "no worse" in every existing harness.
            var px: f64 = 0;
            for (w.links.items) |l| {
                if (l.a >= w.px.len or l.b >= w.px.len) continue;
                const dx = w.px[l.a] - w.px[l.b];
                const dy = w.py[l.a] - w.py[l.b];
                px += @sqrt(@as(f64, dx * dx + dy * dy)) * v.zoom;
            }
            line_px_max = @max(line_px_max, px);
        }

        var sorted = samples;
        std.mem.sort(f64, &sorted, {}, std.sort.asc(f64));
        var sum: f64 = 0;
        for (samples) |x| sum += x;

        const pr = world_mod.prof;
        var over: usize = 0;
        for (samples) |x| {
            if (x > frame_budget_ms) over += 1;
        }
        std.debug.print(
            "  {d:>4}  {d:>8.2} {d:>8.2} {d:>8.2} {d:>5}%   {d:>7} {d:>7} {d:>9.1}   " ++
                "{d:>8} {d:>8.2} {d:>9.2} {d:>8.2} {d:>8.2}\n",
            .{
                lap + 1,
                sum / @as(f64, per_lap),
                sorted[per_lap * 95 / 100],
                sorted[per_lap - 1],
                over * 100 / per_lap,
                marks_max,
                links_max,
                line_px_max / 1_000_000.0,
                // The lift's own breakdown: how often the fingerprint cache missed, and where the
                // rebuild went when it did.
                pr.recomputes - prev.recomputes,
                ms(pr.scan_ns - prev.scan_ns),
                ms(pr.build_ns - prev.build_ns),
                ms(pr.sort_ns - prev.sort_ns),
                ms(pr.fade_ns - prev.fade_ns),
            },
        );
        prev = pr;
    }
}

fn panProbe(io: std.Io, w: *world_mod.World, view: world_mod.View, params: world_mod.Params, px_per_frame: f32) !void {
    const frames = 120;
    // A hand pan runs about 800 screen px/s, so ~13 px a frame at 60. Converting through the zoom
    // keeps that constant in *screen* terms: a fixed world-space step would sweep the entire vault
    // at overview and stand still at full zoom, which is the opposite of what a hand does.
    const dx: f32 = px_per_frame / view.zoom;

    world_mod.prof = .{};
    world_mod.prof_io = io;
    defer world_mod.prof_io = null;

    // How much of the cut actually turns over between consecutive frames. This is the number that
    // decides whether an *incremental* lift is worth building: if a pan replaces most of the cut
    // every frame there is nothing to reuse, and if it replaces a handful there is everything to.
    var churn_sum: f64 = 0;
    var churn_n: usize = 0;
    var prev_links: std.AutoHashMapUnmanaged(u64, void) = .empty;
    defer prev_links.deinit(gpa_for_probe);
    var link_churn_sum: f64 = 0;
    var link_churn_n: usize = 0;
    var n_min: usize = std.math.maxInt(usize);
    var n_max: usize = 0;
    var prev_cut: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer prev_cut.deinit(gpa_for_probe);

    var samples: [frames]f64 = undefined;
    // Per-frame detail, so the worst frames can be named rather than inferred from a percentile.
    var detail: [frames]struct {
        step: f64,
        topo: f64,
        pres: f64,
        scan: f64,
        build: f64,
        sort: f64,
        fade: f64,
        churn: f64,
        scanned: u64,
        lifted: usize,
        cut: usize,
        marks: usize,
    } = undefined;
    var step_ns: u64 = 0;
    var v = view;
    for (0..frames) |i| {
        const before = world_mod.prof;
        v.cx = view.cx + dx * @as(f32, @floatFromInt(i));
        const t0 = now(io);
        // Phase by phase rather than through `step`, so a spike can be attributed to the topology
        // decision or to lazy placement instead of to "the world".
        w.clearFrame();
        const ta = now(io);
        try w.decideTopology(v, params);
        const tb = now(io);
        try w.present(v, params, 1.0 / 60.0);
        const t1 = now(io);
        step_ns += @intCast(t1 - t0);
        try w.liftLinks(params, 1.0 / 60.0);
        samples[i] = ms(elapsed(io, t0));
        const after = world_mod.prof;
        detail[i] = .{
            .step = ms(@intCast(t1 - t0)),
            .topo = ms(@intCast(tb - ta)),
            .pres = ms(@intCast(t1 - tb)),
            .scan = ms(after.scan_ns - before.scan_ns),
            .build = ms(after.build_ns - before.build_ns),
            .sort = ms(after.sort_ns - before.sort_ns),
            .fade = ms(after.fade_ns - before.fade_ns),
            .churn = 0,
            .scanned = after.scanned - before.scanned,
            .lifted = w.lifted.items.len,
            .cut = w.cut.items.len,
            .marks = w.marks.items.len,
        };

        if (prev_cut.count() > 0) {
            var entered: usize = 0;
            for (w.cut.items) |c| {
                if (!prev_cut.contains(c)) entered += 1;
            }
            const left = prev_cut.count() - (w.cut.items.len - entered);
            const frac = @as(f64, @floatFromInt(entered + left)) /
                @as(f64, @floatFromInt(@max(1, w.cut.items.len)));
            detail[i].churn = frac;
            churn_sum += frac;
            churn_n += 1;
        }
        // How much of the *drawn web* changes frame to frame.
        //
        // Distinct from cut churn, and the number that decides whether links visibly pop. A cut
        // change of one cell rebuilds the whole lift, and the lift is a budgeted top-K — so a
        // small change to the candidate set can re-rank across the budget boundary and swap many
        // links at once. Nothing fades them any more, so whatever changes here is a pop.
        n_min = @min(n_min, w.links.items.len);
        n_max = @max(n_max, w.links.items.len);
        if (prev_links.count() > 0) {
            // Set difference both ways, counted over distinct keys. Subtracting counts would
            // underflow whenever two lifted links share a cell pair, which they can.
            var cur_keys: std.AutoHashMapUnmanaged(u64, void) = .empty;
            defer cur_keys.deinit(gpa_for_probe);
            for (w.links.items) |l| {
                try cur_keys.put(gpa_for_probe, (@as(u64, l.a) << 32) | @as(u64, l.b), {});
            }
            var entered: usize = 0;
            var it_cur = cur_keys.keyIterator();
            while (it_cur.next()) |k| {
                if (!prev_links.contains(k.*)) entered += 1;
            }
            var left: usize = 0;
            var it_prev = prev_links.keyIterator();
            while (it_prev.next()) |k| {
                if (!cur_keys.contains(k.*)) left += 1;
            }
            link_churn_sum += @as(f64, @floatFromInt(entered + left)) /
                @as(f64, @floatFromInt(@max(1, cur_keys.count())));
            link_churn_n += 1;
        }
        prev_links.clearRetainingCapacity();
        for (w.links.items) |l| {
            try prev_links.put(gpa_for_probe, (@as(u64, l.a) << 32) | @as(u64, l.b), {});
        }

        prev_cut.clearRetainingCapacity();
        for (w.cut.items) |c| try prev_cut.put(gpa_for_probe, c, {});
    }
    // The worst frame, broken out. A mean hides a hitch by definition — what the reader feels is
    // the one frame that took 35 ms, and the only useful question about it is which phase did.
    var worst: usize = 0;
    for (samples, 0..) |x, i| {
        if (x > samples[worst]) worst = i;
    }

    const churn = if (churn_n > 0) churn_sum / @as(f64, @floatFromInt(churn_n)) else 0;
    const link_churn = if (link_churn_n > 0) link_churn_sum / @as(f64, @floatFromInt(link_churn_n)) else 0;

    var sorted = samples;
    std.mem.sort(f64, &sorted, {}, std.sort.asc(f64));
    var sum: f64 = 0;
    for (samples) |x| sum += x;

    const pr = world_mod.prof;
    const per = struct {
        fn f(ns: u64) f64 {
            return ms(ns) / @as(f64, frames);
        }
    }.f;
    std.debug.print(
        "    {s}  mean {d:.2}  p50 {d:.2}  p95 {d:.2}  max {d:.2} ms/frame   lift rebuilt {d}/{d}  cut churn {d:.1}%  web churn {d:.1}%  drawn {d}..{d}\n" ++
            "         ms/frame: step {d:.2} | lift focus {d:.2}  scan {d:.2}  build {d:.2}  sort {d:.2}  fade {d:.2}   links {d}\n" ++
            "         worst frame {d:.2} ms: topo {d:.2}  present {d:.2}  scan {d:.2}  build {d:.2}  sort {d:.2}  fade {d:.2}  lifted {d}  cut {d}  marks {d}\n",
        .{
            if (px_per_frame == 0) "park" else "pan ",
            sum / @as(f64, frames), sorted[frames / 2], sorted[frames * 95 / 100], sorted[frames - 1],
            pr.recomputes,          pr.calls,
            churn * 100,
            link_churn * 100,
            n_min,
            n_max,
            per(step_ns),           per(pr.focus_ns),
            per(pr.scan_ns),
            per(pr.build_ns),       per(pr.sort_ns),
            per(pr.fade_ns),
            w.links.items.len,
            samples[worst],
            detail[worst].topo,
            detail[worst].pres,
            detail[worst].scan,
            detail[worst].build,
            detail[worst].sort,
            detail[worst].fade,
            detail[worst].lifted,
            detail[worst].cut,
            detail[worst].marks,
        },
    );

    // The three worst frames, by name. A p95 four times the median is a hitch, and a hitch has a
    // cause that a distribution cannot show.
    var order: [frames]usize = undefined;
    for (&order, 0..) |*o, i| o.* = i;
    const By = struct {
        s: []const f64,
        fn worse(c: @This(), a: usize, b: usize) bool {
            return c.s[a] > c.s[b];
        }
    };
    std.mem.sort(usize, &order, By{ .s = &samples }, By.worse);
    for (order[0..3]) |i| {
        std.debug.print(
            "         worst f{d:<3} {d:.2} ms = topo {d:.2} pres {d:.2} scan {d:.2} build {d:.2} sort {d:.2} fade {d:.2}" ++
                "   churn {d:.0}%  cut {d}  marks {d}  lifted {d}  scanned {d}\n",
            .{
                i,                 samples[i],       detail[i].topo,  detail[i].pres,
                detail[i].scan,    detail[i].build,  detail[i].sort,  detail[i].fade,
                detail[i].churn * 100,
                detail[i].cut,     detail[i].marks,  detail[i].lifted,
                detail[i].scanned,
            },
        );
    }
}

fn worldSynth(gpa: std.mem.Allocator, io: std.Io, spec: vault_synth.Spec) !void {
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
    try worldSweep(gpa, io, spec.n, edges, paths, label);
}

/// `--refold`: time the two stages a republish pays for, repeatedly.
fn refoldVault(gpa: std.mem.Allocator, io: std.Io, dir_path: []const u8) !void {
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

    std.debug.print("\n==== refold: {s} ====\n  notes={d}  links={d}  reps={d}\n", .{
        std.fs.path.basename(dir_path), n, edges.items.len, refold_reps,
    });
    std.debug.print("  {s:>4}  {s:>10}  {s:>10}  {s:>10}\n", .{ "rep", "fold ms", "cellweb ms", "total ms" });

    var best_fold: u64 = std.math.maxInt(u64);
    var best_web: u64 = std.math.maxInt(u64);
    for (0..refold_reps) |rep| {
        const t0 = std.Io.Clock.boot.now(io).nanoseconds;
        var lad = try fold.build(gpa, n, edges.items, paths, .{});
        defer lad.deinit(gpa);
        const t1 = std.Io.Clock.boot.now(io).nanoseconds;
        var web = try cellweb.build(gpa, &lad, edges.items);
        defer web.deinit(gpa);
        const t2 = std.Io.Clock.boot.now(io).nanoseconds;

        const f: u64 = @intCast(t1 - t0);
        const w: u64 = @intCast(t2 - t1);
        best_fold = @min(best_fold, f);
        best_web = @min(best_web, w);
        std.debug.print("  {d:>4}  {d:>10.0}  {d:>10.0}  {d:>10.0}\n", .{
            rep,
            @as(f64, @floatFromInt(f)) / 1e6,
            @as(f64, @floatFromInt(w)) / 1e6,
            @as(f64, @floatFromInt(f + w)) / 1e6,
        });
    }
    // Best-of, not mean: the thing being measured is deterministic, so a slower run is noise from
    // the machine and never information about the code.
    std.debug.print("  best  {d:>10.0}  {d:>10.0}  {d:>10.0}   cells={d}\n", .{
        @as(f64, @floatFromInt(best_fold)) / 1e6,
        @as(f64, @floatFromInt(best_web)) / 1e6,
        @as(f64, @floatFromInt(best_fold + best_web)) / 1e6,
        0,
    });
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

    try worldSweep(gpa, io, n, edges.items, paths, std.fs.path.basename(dir_path));
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

fn printStabilityHeader() void {
    std.debug.print(
        "{s:<22}{s:>8}{s:>9}{s:>8}{s:>8}{s:>7}{s:>22}{s:>22}{s:>8}{s:>8}\n",
        .{
            "shape", "n", "e", "comm-f", "comm-r", "trials",
            "fine p50/p90/max", "region p50/p90/max", "fine%", "region%",
        },
    );
    std.debug.print("{s}\n", .{"-" ** 120});
}

fn printStabilityRow(label: []const u8, n: usize, e: usize, s: louvain.Stability) void {
    const nf: f64 = @floatFromInt(@max(n, 1));
    std.debug.print(
        "{s:<22}{d:>8}{d:>9}{d:>8}{d:>8}{d:>7}  {d:>6}/{d}/{d}  {d:>6}/{d}/{d}  {d:>6.2}% {d:>6.2}%\n",
        .{
            label,
            n,
            e,
            s.comm_fine,
            s.comm_region,
            s.trials,
            s.fine_p50,
            s.fine_p90,
            s.fine_max,
            s.region_p50,
            s.region_p90,
            s.region_max,
            @as(f64, @floatFromInt(s.fine_p50)) * 100.0 / nf,
            @as(f64, @floatFromInt(s.region_p50)) * 100.0 / nf,
        },
    );
}

fn stabilityTarget(gpa: std.mem.Allocator, io: std.Io, dir_path: []const u8) !void {
    if (!stability_header_printed) {
        printStabilityHeader();
        stability_header_printed = true;
    }
    if (try shouldExpandShapes(gpa, io, dir_path)) {
        var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true, .access_sub_paths = true });
        defer dir.close(io);
        var names: std.ArrayListUnmanaged([]const u8) = .empty;
        defer {
            for (names.items) |nm| gpa.free(nm);
            names.deinit(gpa);
        }
        var iter = dir.iterate();
        while (iter.next(io) catch null) |entry| {
            if (entry.kind != .directory) continue;
            if (entry.name.len > 0 and entry.name[0] == '.') continue;
            try names.append(gpa, try gpa.dupe(u8, entry.name));
        }
        std.mem.sort([]const u8, names.items, {}, struct {
            fn less(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.less);
        for (names.items) |name| {
            const child = try std.fs.path.join(gpa, &.{ dir_path, name });
            defer gpa.free(child);
            try stabilityVault(gpa, io, child);
        }
        return;
    }
    try stabilityVault(gpa, io, dir_path);
}

fn stabilityVault(gpa: std.mem.Allocator, io: std.Io, dir_path: []const u8) !void {
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

    var edges: std.ArrayList(louvain.Edge) = .empty;
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

    const s = try louvain.stability(gpa, n, edges.items, stability_trials, .{ .resolution = cluster_resolution });
    printStabilityRow(std.fs.path.basename(dir_path), n, edges.items.len, s);
}

fn stabilitySynth(gpa: std.mem.Allocator, io: std.Io, spec: vault_synth.Spec) !void {
    _ = io;
    if (!stability_header_printed) {
        printStabilityHeader();
        stability_header_printed = true;
    }
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var graph = try vault_synth.generate(gpa, arena, spec);
    defer graph.deinit(gpa);
    const ledges = try arena.alloc(louvain.Edge, graph.edges.len);
    for (graph.edges, ledges) |e, *d| d.* = .{ .a = @intCast(e.a), .b = @intCast(e.b) };
    var name_buf: [48]u8 = undefined;
    const label = spec.nameBuf(&name_buf);
    const s = try louvain.stability(gpa, spec.n, ledges, stability_trials, .{ .resolution = cluster_resolution });
    printStabilityRow(label, spec.n, ledges.len, s);
}

/// How far every note moved between two solves, and how much of that was the whole map sliding.
///
/// `layout.recentre` keys the origin to the *bounding box* centre, so one note reaching a new
/// extreme translates all 284k of them. Reporting raw and de-translated movement separates "the
/// map moved under the reader" from "notes moved relative to each other" — only the second is a
/// real rearrangement, and they need opposite fixes.
const Displacement = struct {
    raw_med: f64 = 0,
    raw_p99: f64 = 0,
    raw_max: f64 = 0,
    aligned_med: f64 = 0,
    aligned_p99: f64 = 0,
    aligned_max: f64 = 0,
    /// Notes that moved more than one lattice slot once the global slide is taken out.
    moved: usize = 0,
    shift_x: f64 = 0,
    shift_y: f64 = 0,
    /// Best-fit uniform scale between the two solves, and what is left after removing it.
    /// A map that only breathed shows scale != 1 and a near-zero residual; a map that genuinely
    /// rearranged shows scale ~= 1 and a residual as large as the raw movement.
    scale: f64 = 1,
    fit_med: f64 = 0,
    fit_p99: f64 = 0,
    fit_max: f64 = 0,
    fit_moved: usize = 0,
    /// Notes whose territory subgraph changed at all (`home` hash), whose interior offset within
    /// that territory changed (`inner`), and whose territory kept both and was simply *placed*
    /// somewhere else. The last one is frame-tree instability and nothing else.
    home_changed: usize = 0,
    inner_changed: usize = 0,
    replaced: usize = 0,
};

/// Split the movement by which stage of the solve caused it. `home` is the territory's subgraph
/// hash and `inner` the note's offset from its territory centre, so a note with both unchanged
/// that still moved was carried there by the frame it sits in.
fn attribute(d: *Displacement, before: layout.Result, after: layout.Result, slot: f64) void {
    if (before.home.len != after.home.len or before.inner.len != after.inner.len) return;
    for (before.home, after.home, before.inner, after.inner) |bh, ah, bi, ai| {
        const dx = @as(f64, ai.x) - @as(f64, bi.x);
        const dy = @as(f64, ai.y) - @as(f64, bi.y);
        const inner_moved = @sqrt(dx * dx + dy * dy) > slot;
        if (bh != ah) d.home_changed += 1;
        if (inner_moved) d.inner_changed += 1;
        if (bh == ah and !inner_moved) d.replaced += 1;
    }
}

fn displacement(
    gpa: std.mem.Allocator,
    before: []const layout.Vec2,
    after: []const layout.Vec2,
    slot: f64,
) !Displacement {
    var d: Displacement = .{};
    if (before.len == 0 or before.len != after.len) return d;

    // Best-fit translation is the mean offset: the map's rigid slide between the two solves.
    var sx: f64 = 0;
    var sy: f64 = 0;
    for (before, after) |b, a| {
        sx += @as(f64, a.x) - @as(f64, b.x);
        sy += @as(f64, a.y) - @as(f64, b.y);
    }
    d.shift_x = sx / @as(f64, @floatFromInt(before.len));
    d.shift_y = sy / @as(f64, @floatFromInt(before.len));

    const raw = try gpa.alloc(f64, before.len);
    defer gpa.free(raw);
    const aligned = try gpa.alloc(f64, before.len);
    defer gpa.free(aligned);
    for (before, after, raw, aligned) |b, a, *r, *al| {
        const dx = @as(f64, a.x) - @as(f64, b.x);
        const dy = @as(f64, a.y) - @as(f64, b.y);
        r.* = @sqrt(dx * dx + dy * dy);
        const ax = dx - d.shift_x;
        const ay = dy - d.shift_y;
        al.* = @sqrt(ax * ax + ay * ay);
        if (al.* > slot) d.moved += 1;
    }
    // Best-fit uniform scale about each solve's own centroid. "Things near the edge move more"
    // is what a scale change looks like — a note at radius R moves by (s-1)*R — so it has to be
    // ruled in or out before blaming the clustering.
    var bcx: f64 = 0;
    var bcy: f64 = 0;
    var acx: f64 = 0;
    var acy: f64 = 0;
    for (before, after) |b, a| {
        bcx += b.x;
        bcy += b.y;
        acx += a.x;
        acy += a.y;
    }
    const inv = 1.0 / @as(f64, @floatFromInt(before.len));
    bcx *= inv;
    bcy *= inv;
    acx *= inv;
    acy *= inv;
    var num: f64 = 0;
    var den: f64 = 0;
    for (before, after) |b, a| {
        const bx = @as(f64, b.x) - bcx;
        const by = @as(f64, b.y) - bcy;
        num += bx * (@as(f64, a.x) - acx) + by * (@as(f64, a.y) - acy);
        den += bx * bx + by * by;
    }
    d.scale = if (den > 0) num / den else 1;

    const fit = try gpa.alloc(f64, before.len);
    defer gpa.free(fit);
    for (before, after, fit) |b, a, *f| {
        const fx = (@as(f64, a.x) - acx) - d.scale * (@as(f64, b.x) - bcx);
        const fy = (@as(f64, a.y) - acy) - d.scale * (@as(f64, b.y) - bcy);
        f.* = @sqrt(fx * fx + fy * fy);
        if (f.* > slot) d.fit_moved += 1;
    }
    std.mem.sort(f64, fit, {}, std.sort.asc(f64));

    std.mem.sort(f64, raw, {}, std.sort.asc(f64));
    std.mem.sort(f64, aligned, {}, std.sort.asc(f64));
    const last = before.len - 1;
    const p99 = @min(last, before.len * 99 / 100);
    d.raw_med = raw[before.len / 2];
    d.raw_p99 = raw[p99];
    d.raw_max = raw[last];
    d.aligned_med = aligned[before.len / 2];
    d.aligned_p99 = aligned[p99];
    d.aligned_max = aligned[last];
    d.fit_med = fit[before.len / 2];
    d.fit_p99 = fit[p99];
    d.fit_max = fit[last];
    return d;
}

fn stageMs(stages: @TypeOf(layout.stage_ns), s: layout.Stage) f64 {
    return @as(f64, @floatFromInt(stages.get(s))) / 1_000_000.0;
}

/// `--layout-edit DIR`: the save path. Cold `layout.solve` + `World.initFrom`, then a second
/// solve with reuse on identical edges (settled skip) and on one added link (scoped dirty ids),
/// reporting solve ms, interior/frame reuse, and the world rebuild each one still pays.
fn layoutEditTarget(gpa: std.mem.Allocator, io: std.Io, dir_path: []const u8) !void {
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
            try edges.append(arena, .{ .a = @intCast(i), .b = @intCast(m.index) });
        }
    }
    const paths = try arena.alloc([]const u8, n);
    for (notes.items, paths) |note, *p| p.* = note.path;
    const ids = try arena.alloc(u64, n);
    for (ids, 0..) |*d, i| d.* = i + 1;

    const t0 = now(io);
    var cold = try layout.solve(gpa, n, edges.items, paths, .{ .note_r = 4, .ids = ids, .profile = true });
    defer cold.deinit(gpa);
    const cold_ms = ms(elapsed(io, t0));
    const cold_stages = layout.stage_ns;

    const t_world = now(io);
    var w = try world_mod.World.initFrom(
        gpa,
        n,
        edges.items,
        .{ .pos = cold.pos, .comp = cold.comp },
        .{},
        .{ .note_r = 4 },
        .{},
    );
    const world_ms = ms(elapsed(io, t_world));
    const quant = w.hilbertBox();
    w.deinit();

    const t_same = now(io);
    var same = try layout.solve(gpa, n, edges.items, paths, .{
        .note_r = 4,
        .ids = ids,
        .reuse = .{ .ids = cold.ids, .inner = cold.inner, .home = cold.home, .frames = cold.frames },
        .profile = true,
    });
    defer same.deinit(gpa);
    const same_ms = ms(elapsed(io, t_same));
    // Correctness gate for the memos: identical edges must give an identical map. If a reused
    // interior or frame ever differs from what a cold solve produces, this is where it shows up,
    // and the number is not "small" — it is zero.
    var same_max: f64 = 0;
    for (cold.pos, same.pos) |a, b| {
        const dx = @as(f64, a.x) - @as(f64, b.x);
        const dy = @as(f64, a.y) - @as(f64, b.y);
        same_max = @max(same_max, @sqrt(dx * dx + dy * dy));
    }
    const same_in = layout.reused_interiors;
    const same_in_n = layout.solved_interiors;
    const same_fr = layout.reused_frames;
    const same_fr_n = layout.placed_frames;

    const extra = (try shape_metrics.pickNewEdge(gpa, n, edges.items));
    var edit_ms: f64 = 0;
    var edit_in: u32 = 0;
    var edit_in_n: u32 = 0;
    var edit_fr: u32 = 0;
    var edit_fr_n: u32 = 0;
    var edit_world_ms: f64 = 0;
    var edit_stages: @TypeOf(layout.stage_ns) = .initFill(0);
    var edit_miss_discs: usize = 0;
    var edit_miss_max: usize = 0;
    var edit_miss_depth: u32 = 0;
    var disp: Displacement = .{};
    var comp_before: u32 = cold.n_comp;
    var comp_after: u32 = cold.n_comp;
    if (extra) |e| {
        try edges.append(arena, e);
        const t_edit = now(io);
        var edited = try layout.solve(gpa, n, edges.items, paths, .{
            .note_r = 4,
            .ids = ids,
            .reuse = .{ .ids = cold.ids, .inner = cold.inner, .home = cold.home, .frames = cold.frames },
            .profile = true,
        });
        defer edited.deinit(gpa);
        edit_ms = ms(elapsed(io, t_edit));
        edit_stages = layout.stage_ns;
        comp_before = cold.n_comp;
        comp_after = edited.n_comp;
        disp = try displacement(gpa, cold.pos, edited.pos, @as(f64, cold.spacing) * 4);
        attribute(&disp, cold, edited, @as(f64, cold.spacing) * 4);
        edit_in = layout.reused_interiors;
        edit_in_n = layout.solved_interiors;
        edit_fr = layout.reused_frames;
        edit_fr_n = layout.placed_frames;
        edit_miss_discs = layout.missed_frame_discs;
        edit_miss_max = layout.largest_missed_frame;
        edit_miss_depth = layout.shallowest_missed_frame;

        // The world the edit has to be drawn through. Rebuilt, not nudged: keeping the live
        // ladder needs the Hilbert order to survive the re-solve, and a global Louvain plus
        // global frame placement always moves some note past a neighbour on the curve.
        const t_world2 = now(io);
        var w2 = try world_mod.World.initFrom(
            gpa,
            n,
            edges.items,
            .{ .pos = edited.pos, .comp = edited.comp },
            .{},
            .{ .note_r = 4 },
            quant,
        );
        edit_world_ms = ms(elapsed(io, t_world2));
        w2.deinit();
    }

    std.debug.print(
        \\{s}  n={d}  edges={d}
        \\  cold solve          {d:>8.1} ms
        \\  World.initFrom      {d:>8.1} ms
        \\  reuse (same edges)  {d:>8.1} ms  interiors {d}/{d}  frames {d}/{d}  (World skip)
        \\  reuse (one link)    {d:>8.1} ms  interiors {d}/{d}  frames {d}/{d}
        \\  World (one link)    {d:>8.1} ms
        \\
        \\  inside layout.solve      cold      one link
        \\    normalise       {d:>10.1} {d:>13.1} ms   one pass over every link
        \\    components      {d:>10.1} {d:>13.1} ms   union-find + bucketing
        \\    cluster         {d:>10.1} {d:>13.1} ms   Louvain, split, merge
        \\    interiors       {d:>10.1} {d:>13.1} ms   memoised by subgraph
        \\    frames          {d:>10.1} {d:>13.1} ms   nested placement
        \\    pack            {d:>10.1} {d:>13.1} ms   island radii + separate
        \\
    , .{
        std.fs.path.basename(dir_path),
        n,
        edges.items.len,
        cold_ms,
        world_ms,
        same_ms,
        same_in,
        same_in_n,
        same_fr,
        same_fr_n,
        edit_ms,
        edit_in,
        edit_in_n,
        edit_fr,
        edit_fr_n,
        edit_world_ms,
        stageMs(cold_stages, .normalise),  stageMs(edit_stages, .normalise),
        stageMs(cold_stages, .components), stageMs(edit_stages, .components),
        stageMs(cold_stages, .cluster),    stageMs(edit_stages, .cluster),
        stageMs(cold_stages, .interiors),  stageMs(edit_stages, .interiors),
        stageMs(cold_stages, .frames),     stageMs(edit_stages, .frames),
        stageMs(cold_stages, .pack),       stageMs(edit_stages, .pack),
    });

    std.debug.print(
        \\      louvain       {d:>10.1} {d:>13.1} ms   the floor: global, serial, unreusable
        \\      splitOversized{d:>10.1} {d:>13.1} ms
        \\      mergeSpecks   {d:>10.1} {d:>13.1} ms
        \\    same-edge map drift {d:.6}   (must be 0)
        \\
    , .{
        stageMs(cold_stages, .cluster_louvain), stageMs(edit_stages, .cluster_louvain),
        stageMs(cold_stages, .cluster_split),   stageMs(edit_stages, .cluster_split),
        stageMs(cold_stages, .cluster_merge),   stageMs(edit_stages, .cluster_merge),
        same_max,
    });

    std.debug.print(
        \\
        \\  how far one added link moved the map (world units, slot={d:.0})
        \\    components      {d} -> {d}
        \\    whole-map slide {d:.1}, {d:.1}   (recentre keys off the bounding box)
        \\    raw             med {d:>8.1}   p99 {d:>9.1}   max {d:>9.1}
        \\    slide removed   med {d:>8.1}   p99 {d:>9.1}   max {d:>9.1}
        \\    moved > 1 slot  {d} of {d}
        \\    best-fit scale  {d:.6}
        \\    scale removed   med {d:>8.1}   p99 {d:>9.1}   max {d:>9.1}   moved {d}
        \\
        \\  why they moved
        \\    territory changed        {d}   (subgraph hash differs)
        \\    interior offset moved    {d}   (re-solved inside its territory)
        \\    neither, but map moved   {d}   (carried by the frame it sits in)
        \\
        \\  frame memo misses
        \\    discs re-placed          {d}
        \\    biggest missed frame     {d} discs
        \\    shallowest miss at depth {d}   (0 = the outermost frame)
        \\
    , .{
        @as(f64, cold.spacing) * 4,
        comp_before, comp_after,
        disp.shift_x, disp.shift_y,
        disp.raw_med, disp.raw_p99, disp.raw_max,
        disp.aligned_med, disp.aligned_p99, disp.aligned_max,
        disp.moved, n,
        disp.scale,
        disp.fit_med, disp.fit_p99, disp.fit_max, disp.fit_moved,
        disp.home_changed, disp.inner_changed, disp.replaced,
        edit_miss_discs, edit_miss_max, edit_miss_depth,
    });
}

/// `--churn DIR`: how much of the *territory* set survives one added link, stage by stage.
///
/// The memo in `layout.solve` reuses a territory whose membership came back identical, so its hit
/// rate *is* the stability of the partition — no separate matching needed. Running the same pair of
/// solves with the post-clustering stages switched off attributes the churn: `region_max` at
/// infinity disables `splitOversized`, `region_min` at one disables `mergeSpecks`.
///
/// This exists because the memo landed at 66% of interiors and 0% of frames on a live edit, and
/// those two numbers are the same fact: groups hold ~13 territories, so a third of territories
/// churning leaves almost no group untouched. Whatever moves this number moves everything built on
/// top of it.
fn churnTarget(gpa: std.mem.Allocator, io: std.Io, dir_path: []const u8) !void {
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
            try edges.append(arena, .{ .a = @intCast(i), .b = @intCast(m.index) });
        }
    }
    const paths = try arena.alloc([]const u8, n);
    for (notes.items, paths) |note, *p| p.* = note.path;
    const ids = try arena.alloc(u64, n);
    for (ids, 0..) |*d, i| d.* = i + 1;

    const extra = (try shape_metrics.pickNewEdge(gpa, n, edges.items)) orelse {
        std.debug.print("{s}: no edge to add\n", .{std.fs.path.basename(dir_path)});
        return;
    };
    const edges2 = try arena.alloc(fold.Edge, edges.items.len + 1);
    @memcpy(edges2[0..edges.items.len], edges.items);
    edges2[edges.items.len] = extra;

    // The same experiment against a *busy* pair.
    //
    // `pickNewEdge` takes a random non-adjacent pair, and in a heavy-tailed vault a random note is
    // an obscure one — so the random probe measures the easiest edit there is. Degree normalisation
    // weights a link `w·K/√(dₐ·d_b)`, so adding one link to a note of degree d changes the weight
    // of all d of its existing links: an edit between two well-connected notes perturbs thousands
    // of weights at once, and that is the edit a reader actually makes.
    const deg = try arena.alloc(u32, n);
    @memset(deg, 0);
    for (edges.items) |e| {
        deg[e.a] += 1;
        deg[e.b] += 1;
    }
    var hub_a: u32 = 0;
    for (deg, 0..) |d, i| {
        if (d > deg[hub_a]) hub_a = @intCast(i);
    }
    var hub_b: u32 = if (hub_a == 0) 1 else 0;
    for (deg, 0..) |d, i| {
        if (i == hub_a) continue;
        if (d > deg[hub_b]) hub_b = @intCast(i);
    }
    const edges3 = try arena.alloc(fold.Edge, edges.items.len + 1);
    @memcpy(edges3[0..edges.items.len], edges.items);
    edges3[edges.items.len] = .{ .a = hub_a, .b = hub_b };
    std.debug.print("  random pair deg {d}/{d}   busy pair deg {d}/{d}\n", .{
        deg[extra.a], deg[extra.b], deg[hub_a], deg[hub_b],
    });

    std.debug.print("  {s}  ({d} notes, {d} links)\n", .{ std.fs.path.basename(dir_path), n, edges.items.len });
    std.debug.print("  {s:<30} {s:>6} {s:>9} {s:>9} {s:>10}\n", .{ "stages", "reuse", "d-p50", "d-p99", "raw p50" });

    const Cfg = struct { label: []const u8, min: u32, max: u32, norm: f32, busy: bool = false };
    const cfgs = [_]Cfg{
        .{ .label = "louvain only, random pair", .min = 1, .max = std.math.maxInt(u32), .norm = 0.5 },
        .{ .label = "+ splitOversized", .min = 1, .max = 128, .norm = 0.5 },
        .{ .label = "+ mergeSpecks (shipping)", .min = 8, .max = 128, .norm = 0.5 },
        .{ .label = "shipping, busy pair", .min = 8, .max = 128, .norm = 0.5, .busy = true },
        .{ .label = "busy pair, no degree norm", .min = 8, .max = 128, .norm = 0, .busy = true },
    };
    for (cfgs) |cfg| {
        var first = try layout.solve(gpa, n, edges.items, paths, .{
            .note_r = 1,
            .ids = ids,
            .region_min = cfg.min,
            .region_max = cfg.max,
            .degree_norm = cfg.norm,
        });
        defer first.deinit(gpa);
        var second = try layout.solve(gpa, n, if (cfg.busy) edges3 else edges2, paths, .{
            .note_r = 1,
            .ids = ids,
            .region_min = cfg.min,
            .region_max = cfg.max,
            .degree_norm = cfg.norm,
            .reuse = .{ .ids = first.ids, .inner = first.inner, .home = first.home, .frames = first.frames },
        });
        defer second.deinit(gpa);
        const kept = layout.reused_interiors;
        const of = layout.solved_interiors;
        const frames_kept = layout.reused_frames;
        const frames_of = layout.placed_frames;

        // Reuse says the *inputs* held still. This says whether the reader sees that: a memo that
        // hits everywhere is worth nothing if the frames above it still re-place and carry every
        // territory with them.
        var report: shape_metrics.Report = .{};
        try shape_metrics.setDisplacement(gpa, &report, first.pos, second.pos, 1);

        // Raw distance, with no alignment at all.
        //
        // `setDisplacement` is Procrustes: it rotates and translates the new positions onto the old
        // before measuring, which is right for asking "did the *arrangement* change" and exactly
        // wrong for asking "did the reader see anything move". A whole island sliding across the
        // map is a pure translation, so Procrustes reports zero for the one motion most visible
        // from the outside.
        const raw = try gpa.alloc(f32, first.pos.len);
        defer gpa.free(raw);
        for (raw, first.pos, second.pos) |*d, a, b| {
            d.* = @sqrt((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y));
        }
        std.mem.sort(f32, raw, {}, std.sort.asc(f32));
        const raw_p50 = if (raw.len > 0) raw[raw.len / 2] else 0;
        std.debug.print("  {s:<30} {d:>5}% {d:>8.1}r {d:>8.1}r {d:>9.1}r   frames {d}/{d}\n", .{
            cfg.label,
            if (of > 0) kept * 100 / of else 0,
            report.disp_p50,
            report.disp_p99,
            raw_p50,
            frames_kept,
            frames_of,
        });
    }
}

/// `--shapes DIR`: grade `layout.solve` on each child vault, or on DIR itself when it is one vault.
///
/// A gauntlet parent (many child corpora, almost no markdown of its own) expands. A single vault
/// — `tree/`, simplewiki — is one row, even if it has subfolders of notes.
fn shapesTarget(gpa: std.mem.Allocator, io: std.Io, dir_path: []const u8) !void {
    if (!shapes_header_printed) {
        shape_metrics.printHeader();
        shapes_header_printed = true;
    }
    if (try shouldExpandShapes(gpa, io, dir_path)) {
        var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true, .access_sub_paths = true });
        defer dir.close(io);
        var names: std.ArrayListUnmanaged([]const u8) = .empty;
        defer {
            for (names.items) |n| gpa.free(n);
            names.deinit(gpa);
        }
        var iter = dir.iterate();
        while (iter.next(io) catch null) |entry| {
            if (entry.kind != .directory) continue;
            if (entry.name.len > 0 and entry.name[0] == '.') continue;
            try names.append(gpa, try gpa.dupe(u8, entry.name));
        }
        std.mem.sort([]const u8, names.items, {}, struct {
            fn less(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.less);
        for (names.items) |name| {
            const child = try std.fs.path.join(gpa, &.{ dir_path, name });
            defer gpa.free(child);
            try shapesVault(gpa, io, child);
        }
        return;
    }
    try shapesVault(gpa, io, dir_path);
}

fn shouldExpandShapes(gpa: std.mem.Allocator, io: std.Io, dir_path: []const u8) !bool {
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true, .access_sub_paths = true }) catch return false;
    defer dir.close(io);
    var md_here: usize = 0;
    var vault_kids: usize = 0;
    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        if (entry.name.len > 0 and entry.name[0] == '.') continue;
        switch (entry.kind) {
            .file => {
                if (std.ascii.endsWithIgnoreCase(entry.name, ".md")) md_here += 1;
            },
            .directory => {
                const child = try std.fs.path.join(gpa, &.{ dir_path, entry.name });
                defer gpa.free(child);
                if (try dirHasMarkdown(gpa, io, child)) vault_kids += 1;
            },
            else => {},
        }
    }
    return vault_kids >= 2 and md_here < vault_kids;
}

fn dirHasMarkdown(gpa: std.mem.Allocator, io: std.Io, dir_path: []const u8) !bool {
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true, .access_sub_paths = true }) catch return false;
    defer dir.close(io);
    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        if (entry.name.len > 0 and entry.name[0] == '.') continue;
        switch (entry.kind) {
            .file => {
                if (std.ascii.endsWithIgnoreCase(entry.name, ".md")) return true;
            },
            .directory => {
                const child = try std.fs.path.join(gpa, &.{ dir_path, entry.name });
                defer gpa.free(child);
                if (try dirHasMarkdown(gpa, io, child)) return true;
            },
            else => {},
        }
    }
    return false;
}

fn shapesVault(gpa: std.mem.Allocator, io: std.Io, dir_path: []const u8) !void {
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
            try edges.append(arena, .{ .a = @intCast(i), .b = @intCast(m.index) });
        }
    }

    const paths = try arena.alloc([]const u8, n);
    for (notes.items, paths) |note, *p| p.* = note.path;

    const note_r: f32 = 1.0;
    const defaults: layout.Options = .{};
    const t0 = now(io);
    var laid = try layout.solve(gpa, n, edges.items, paths, .{
        .note_r = note_r,
        .iters = .{ .max_iters = ml_iters },
        .territories = shapes_territories,
        .frame_max = if (shapes_frame_max > 0) shapes_frame_max else defaults.frame_max,
        .region_max = if (shapes_region_max > 0) shapes_region_max else defaults.region_max,
        .resolution = cluster_resolution,
    });
    defer laid.deinit(gpa);
    const solve_ms = ms(elapsed(io, t0));

    var report = try shape_metrics.grade(gpa, n, edges.items, laid.pos, laid.comp, note_r, solve_ms);

    if (!shapes_no_displace) {
        if (try shape_metrics.pickNewEdge(gpa, n, edges.items)) |extra| {
            const edges2 = try arena.alloc(fold.Edge, edges.items.len + 1);
            @memcpy(edges2[0..edges.items.len], edges.items);
            edges2[edges.items.len] = extra;
            var laid2 = try layout.solve(gpa, n, edges2, paths, .{
                .note_r = note_r,
                .iters = .{ .max_iters = ml_iters },
                .territories = shapes_territories,
                .frame_max = if (shapes_frame_max > 0) shapes_frame_max else defaults.frame_max,
                .region_max = if (shapes_region_max > 0) shapes_region_max else defaults.region_max,
            });
            defer laid2.deinit(gpa);
            try shape_metrics.setDisplacement(gpa, &report, laid.pos, laid2.pos, note_r);
        }
    }

    shape_metrics.printRow(std.fs.path.basename(dir_path), report);
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
    // First build: the live panel path (`layout.solve`), not the parked `layout_full.targets`.
    const paths = try arena.alloc([]const u8, n);
    for (notes.items, paths) |note, *p| p.* = note.path;
    const links = try arena.alloc(fold.Edge, edges.items.len);
    for (edges.items, links) |e, *le| le.* = .{ .a = @intCast(e.a), .b = @intCast(e.b) };

    const t_lay = now(io);
    var lay = try layout.solve(gpa, n, links, paths, .{ .note_r = 4 });
    defer lay.deinit(gpa);
    const layout_ns = elapsed(io, t_lay);

    const out = try arena.alloc(dvui.Point, n);
    for (lay.pos, out) |q, *p| p.* = .{ .x = q.x, .y = q.y };

    std.debug.print(
        "{s:<16}{d:>7}{d:>8}{d:>8.0}m{d:>7.0}m{d:>9.0}m  layout {d:.0}ms  interiors {d}/{d}  frames {d}/{d}\n",
        .{
            std.fs.path.basename(dir_path),
            n,
            edges.items.len,
            ms(read_ns),
            ms(scan_ns),
            ms(resolve_ns),
            ms(layout_ns),
            layout.reused_interiors,
            layout.solved_interiors,
            layout.reused_frames,
            layout.placed_frames,
        },
    );
    std.debug.print("    fill={d:.3}  cross-dir-edges={d}  max-degree={d}  spacing={d:.2}\n", .{
        fillRatio(out, n),
        cross_dir,
        max_deg,
        lay.spacing,
    });
    if (svg_dir) |d| {
        try writeSvg(io, d, std.fs.path.basename(dir_path), out, edges.items, degrees, arena);
    }
}
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

