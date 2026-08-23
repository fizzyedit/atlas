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
const fold = @import("ui/fold.zig");
const cellweb = @import("ui/cellweb.zig");

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
/// `--budget=N`: the mark budget the `--world` sweep runs at. The panel's own slider goes to
/// 4000, and several per-frame costs scale with it rather than with note count, so a sweep pinned
/// at the 280 default cannot see them.
var world_budget: usize = 280;
/// `--pan`: after settling each zoom, keep stepping with the camera *moving*, and report what a
/// frame costs then. The settled numbers below it are the parked-camera steady state; a pan is the
/// case the reader actually complains about, because it invalidates the lift cache every frame.
var world_pan: bool = false;
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
            \\  modes  = --index | --index-warm | --index-edit | --refold
            \\           --world | --interior | --stats   (default: scan/resolve/place table)
            \\  flags  = --place pack|layout  --budget=N  --scan-cap=N  --reps=N  --svg <dir>
            \\
        , .{});
        return error.MissingArgument;
    }

    // First pass: pull `--stats` out so it can gate the header and every target's handling below,
    // regardless of where it appears among the targets.
    for (args[1..]) |a| {
        if (std.mem.eql(u8, a, "--stats")) stats_mode = true;
        if (std.mem.eql(u8, a, "--world")) world_mode = true;
        if (std.mem.eql(u8, a, "--pan")) {
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

    if (!stats_mode and !world_mode and !index_mode and !refold_mode) {
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
fn worldSweep(gpa: std.mem.Allocator, io: std.Io, n: usize, edges: []const fold.Edge, paths: []const []const u8, label: []const u8) !void {
    // Timed, because this is what every republish costs: the layout job rebuilds the whole World
    // — `fold.build` over every note, `cellweb` over every link — each time the index bumps the
    // generation, including for a one-note edit.
    gpa_for_probe = gpa;
    const build_t0 = std.Io.Clock.boot.now(io).nanoseconds;
    var w = try world_mod.World.init(gpa, n, edges, paths, .{}, .{});
    defer w.deinit();
    const build_ns: u64 = @intCast(std.Io.Clock.boot.now(io).nanoseconds - build_t0);

    const budget: usize = world_budget;
    // Mirror the panel exactly, through the same function it calls — see
    // `Params.ambientLinkBudget`. Hardcoding a number here is how this sweep once came to report
    // 10,000 links at every coarse zoom while the app drew 900. A bench that quietly measures
    // different parameters than the thing it stands in for is worse than no bench.
    const params: world_mod.Params = .{
        .budget = budget,
        .link_budget = if (world_link_budget > 0)
            world_link_budget
        else
            world_mod.Params.ambientLinkBudget(budget),
        .link_scan_cap = world_scan_cap,
        .split_px = world_split_px,
    };
    const vw: f32 = 1200;
    const vh: f32 = 700;
    const ext = w.extent();
    const z_fit = @min(vw, vh) * 0.44 / ext;

    std.debug.print("\n==== world: {s} ====\n", .{label});
    std.debug.print("  notes={d}  links={d}  ladder depth={d}  cells={d}  root r={d:.1}\n", .{
        n, edges.len, w.lad.depth, w.lad.cells.len, ext,
    });
    // Split the two halves by building them once more on their own. Costs one extra build in the
    // bench and tells us which stage a rebuild is actually spending its seconds in.
    var fold_ns: u64 = 0;
    var web_ns: u64 = 0;
    {
        const f0 = std.Io.Clock.boot.now(io).nanoseconds;
        var lad2 = try fold.build(gpa, n, edges, paths, .{});
        defer lad2.deinit(gpa);
        const f1 = std.Io.Clock.boot.now(io).nanoseconds;
        var web2 = try cellweb.build(gpa, &lad2, edges);
        defer web2.deinit(gpa);
        const f2 = std.Io.Clock.boot.now(io).nanoseconds;
        fold_ns = @intCast(f1 - f0);
        web_ns = @intCast(f2 - f1);
    }
    std.debug.print(
        "  World.init (per republish) = {d:.0} ms   [fold.build {d:.0} ms  cellweb {d:.0} ms]\n",
        .{
            @as(f64, @floatFromInt(build_ns)) / 1e6,
            @as(f64, @floatFromInt(fold_ns)) / 1e6,
            @as(f64, @floatFromInt(web_ns)) / 1e6,
        },
    );
    std.debug.print("  {s:>9}  {s:>7}  {s:>7}  {s:>7}  {s:>7}  {s:>7}  {s:>6}   {s:>7} {s:>7} {s:>7} {s:>7} {s:>8}\n", .{
        "zoom",  "marks",  "notes",   "masses",  "links",   "drawn",
        "bound", "clr ms", "topo ms", "pres ms", "lift ms", "frame ms",
    });

    var zoom = z_fit;
    var stepn: usize = 0;
    while (stepn < 14) : (stepn += 1) {
        // settle, so what is printed is the resting set rather than a mid-crossfade frame
        const view: world_mod.View = .{ .w = vw, .h = vh, .zoom = zoom, .cx = 0, .cy = 0 };
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
        // What the *draw* would keep, not what the lift produced. `world_draw` requires at least
        // one endpoint to have a living mark, and the two numbers diverge hard: the lift fills its
        // budget at every zoom while the drawn count collapses as the camera closes in. That gap
        // is what `world_draw.ambientAlpha` reads, so a sweep that only reports `links` cannot
        // tell you what the web will actually look like.
        var have: std.AutoHashMapUnmanaged(u32, void) = .empty;
        defer have.deinit(gpa);
        for (w.marks.items) |m| try have.put(gpa, m.cell, {});
        var drawn: usize = 0;
        for (w.links.items) |l| {
            if (l.focus) continue;
            if (have.contains(l.a) or have.contains(l.b)) drawn += 1;
        }
        std.debug.print("  {d:>9.3}  {d:>7}  {d:>7}  {d:>7}  {d:>7}  {d:>7}  {s:>6}   {d:>7.2} {d:>7.2} {d:>7.2} {d:>7.2} {d:>8.2}\n", .{
            zoom,
            w.marks.items.len,
            notes,
            w.marks.items.len - notes,
            w.links.items.len,
            drawn,
            if (w.bound) "Y" else "",
            ms(clr_ns),
            ms(topo_ns),
            ms(pres_ns),
            ms(lift_ns),
            ms(clr_ns + topo_ns + pres_ns + lift_ns),
        });
        if (w.marks.items.len > budget * 2) std.debug.print("    ^^ OVER BUDGET\n", .{});
        if (world_pan) {
            try panProbe(io, &w, view, params, 0);
            try panProbe(io, &w, view, params, 13);
        }
        zoom *= 2.0;
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
    var prev_cut: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer prev_cut.deinit(gpa_for_probe);

    var samples: [frames]f64 = undefined;
    var step_ns: u64 = 0;
    var v = view;
    for (0..frames) |i| {
        v.cx = view.cx + dx * @as(f32, @floatFromInt(i));
        const t0 = now(io);
        try w.step(v, params, 1.0 / 60.0);
        const t1 = now(io);
        step_ns += @intCast(t1 - t0);
        try w.liftLinks(params, 1.0 / 60.0);
        samples[i] = ms(elapsed(io, t0));

        if (prev_cut.count() > 0) {
            var entered: usize = 0;
            for (w.cut.items) |c| {
                if (!prev_cut.contains(c)) entered += 1;
            }
            const left = prev_cut.count() - (w.cut.items.len - entered);
            churn_sum += @as(f64, @floatFromInt(entered + left)) /
                @as(f64, @floatFromInt(@max(1, w.cut.items.len)));
            churn_n += 1;
        }
        prev_cut.clearRetainingCapacity();
        for (w.cut.items) |c| try prev_cut.put(gpa_for_probe, c, {});
    }
    const churn = if (churn_n > 0) churn_sum / @as(f64, @floatFromInt(churn_n)) else 0;

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
        "    {s}  mean {d:.2}  p50 {d:.2}  p95 {d:.2}  max {d:.2} ms/frame   lift rebuilt {d}/{d}  cut churn {d:.1}%\n" ++
            "         ms/frame: step {d:.2} | lift focus {d:.2}  scan {d:.2}  build {d:.2}  sort {d:.2}  fade {d:.2}   links {d}\n",
        .{
            if (px_per_frame == 0) "park" else "pan ",
            sum / @as(f64, frames), sorted[frames / 2], sorted[frames * 95 / 100], sorted[frames - 1],
            pr.recomputes,          pr.calls,
            churn * 100,
            per(step_ns),           per(pr.focus_ns),
            per(pr.scan_ns),
            per(pr.build_ns),       per(pr.sort_ns),
            per(pr.fade_ns),
            w.links.items.len,
        },
    );
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

