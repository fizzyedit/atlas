//! Standalone vault simulator window — a synthetic, live-editable vault drawn through the exact
//! same rebuild/step/draw pass the real bottom panel uses (`graph.drawPanel`), so a shape or
//! scale change re-lays-out and eases into place exactly like a real vault reindex would: nodes
//! and edges animate in or out, survivors ease to their new position, never a hard snap.
//!
//! Fully independent of `State`/the real bottom panel. `SimState` is a `State`-lookalike built
//! the same way `State.init` builds the real one — its own `Indexer`, `generation`, `busy` — so it
//! satisfies exactly the same duck-typed surface `graph.drawPanel`/`rebuildIfNeeded`/
//! `buildInteriorWorld` read off `*State` (`db`, `generation`, `indexer`, `indexer_ready`,
//! `vault_root`, `hasGraphSource()`), never given a `db`. `SimSpec`'s fields are the "independent
//! settings just at runtime" this window's sidebar widgets read and write directly — no
//! `sdk.settings.Value`, no persistence, nothing shared with the real bottom panel's own state.
const std = @import("std");
const dvui = @import("dvui");
const sdk = @import("fizzy_sdk");
const core = @import("core");

const Db = @import("../index/Db.zig");
const Indexer = @import("../index/Indexer.zig");
const vault_synth = @import("vault_synth.zig");
const graph = @import("graph.zig");
const containment = @import("containment.zig");

/// Live shape/scale knobs. Plain fields — the window's sliders/dropdown write to `pending`
/// directly every frame; `Sim.tick` is what turns a settled edit into a rebuild.
pub const SimSpec = struct {
    n: usize = 2_000,
    shape: vault_synth.Shape = .islands,
    avg_deg: f32 = 4,
};

/// The six shapes exposed in the sidebar — `vault_synth.Shape` also has `lfr`, which needs a
/// handful of extra community-model fields (`tau_degree`, `mu`, ...) this window doesn't expose;
/// left out to keep the control set matching what the old Settings-pane knobs offered.
const shape_choices: []const vault_synth.Shape = &.{ .scale_free, .islands, .hub, .bipartite, .chain, .orphans, .motifs };
const shape_labels: []const []const u8 = &.{ "scale-free", "islands", "hub", "bipartite", "chain", "orphans", "motifs" };

/// Width of the numeric readout rows, in M-widths of the mono font — which is also why the rows
/// are mono: with uniform digit widths a pinned width is exact rather than a guess, and the
/// right-aligned columns line up. Must cover the longest row below. See `Sim.readout`.
const readout_cols: f32 = 26;

/// How often the readout resamples the panel's counters. Sampling every frame is what made the
/// numbers unreadable *and* what kept the window awake — see `Sim.readout`.
const readout_period_s: f32 = 0.25;

/// Quantize the note-count slider so a small drag doesn't thrash a 500k-note regeneration — same
/// idea `State.quantizedSynthNotes` used before the whole synth path moved into this file.
pub fn quantizeNotes(raw: f32) usize {
    const x: usize = @intFromFloat(std.math.clamp(raw, 100, 1_000_000));
    if (x <= 20_000) return @max(100, (x + 500) / 1000 * 1000);
    if (x <= 200_000) return (x + 5_000) / 10_000 * 10_000;
    return (x + 25_000) / 50_000 * 50_000;
}

/// The minimal `State`-lookalike `graph.drawPanel` and friends need — see the file doc comment.
/// Never given a `db`: `buildInteriorWorld`'s `if (st.db == null) return error.NoDb` means a
/// synthetic note's interior doesn't build in this pass (`vault_synth.synthContentGraph` already
/// exists and is the natural follow-up wiring for that — left out here to keep this change scoped
/// to the vault-shape/scale simulator that was actually asked for).
pub const SimState = struct {
    busy: std.atomic.Value(bool) = .init(false),
    generation: std.atomic.Value(u64) = .init(0),
    indexer: Indexer = undefined,
    indexer_ready: bool = false,
    db: ?Db = null,
    vault_root: ?[]const u8 = "synth://atlas-simulator",
    /// Packed world positions from `vault_synth`, parallel to note ids `1..N` (so graph index
    /// `i` after the id-sort). Owned; freed on replace and on `deinit`.
    synth_pos: ?[]dvui.Point = null,
    gpa: std.mem.Allocator = undefined,

    pub fn init(self: *SimState, gpa: std.mem.Allocator) void {
        self.indexer = Indexer.init(gpa, &self.busy, &self.generation);
        self.indexer_ready = true;
        self.gpa = gpa;
    }

    pub fn deinit(self: *SimState) void {
        if (self.indexer_ready) self.indexer.deinit();
        self.indexer_ready = false;
        if (self.synth_pos) |p| self.gpa.free(p);
        self.synth_pos = null;
    }

    /// Duck-typed hook `graph.zig`'s rebuild looks for with `@hasDecl`: positions are already
    /// known, so the force layout is skipped entirely. Without this a synthetic vault above a few
    /// thousand notes runs a full `layout_full` solve — minutes at 450k, during which `Panel.job`
    /// never completes and the panel keeps redrawing whatever arrangement last *finished*. The
    /// real `State` has no such method, so that branch compiles out for the live bottom panel.
    pub fn packedPositions(self: *const SimState) ?[]const dvui.Point {
        return self.synth_pos;
    }

    pub fn hasGraphSource(self: *const SimState) bool {
        return self.generation.load(.acquire) > 0;
    }
};

/// Background regeneration — same cancel/done/claimed idiom the old `State.SynthJob` used before
/// this file replaced it, scoped down to just what a `vault_synth.generate` call needs.
const RegenJob = struct {
    gpa: std.mem.Allocator,
    spec: SimSpec,
    cancel: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    /// First claimer (poll or a cancelled worker) frees the job.
    claimed: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,
    fail: ?anyerror = null,

    nodes: ?[]Indexer.SnapNode = null,
    edges: ?[]Indexer.SnapEdge = null,
    /// Packed positions from the generator — handed to the panel so it skips the force layout
    /// entirely. Ownership moves to `SimState.synth_pos` on a successful poll.
    positions: ?[]dvui.Point = null,
    /// `nodes[].path`/`.title` live here; freed once `publishSynthetic` has deep-copied them.
    node_arena: ?std.heap.ArenaAllocator = null,

    fn tryClaim(self: *RegenJob) bool {
        return !self.claimed.swap(true, .acq_rel);
    }

    fn discardResults(self: *RegenJob) void {
        if (self.edges) |e| self.gpa.free(e);
        if (self.positions) |p| self.gpa.free(p);
        if (self.node_arena) |*a| a.deinit();
        self.edges = null;
        self.positions = null;
        self.nodes = null;
        self.node_arena = null;
    }

    fn destroy(self: *RegenJob) void {
        self.discardResults();
        self.gpa.destroy(self);
    }
};

fn regenWorker(job: *RegenJob) void {
    defer job.done.store(true, .release);
    if (job.cancel.load(.acquire)) return;

    const n = job.spec.n;
    const shape = job.spec.shape;
    const isle_max: u32 = @intCast(@min(@as(usize, 10_000), @max(@as(usize, 64), n / 40)));
    const orphan_frac: f32 = if (shape == .islands) 0.02 else 0.10;
    const spec: vault_synth.Spec = .{
        .n = n,
        .shape = shape,
        .avg_deg = std.math.clamp(job.spec.avg_deg, 0, 64),
        .place = .pack,
        .island_max = isle_max,
        .orphan_frac = orphan_frac,
    };

    var path_arena = std.heap.ArenaAllocator.init(job.gpa);
    defer path_arena.deinit();

    var g = vault_synth.generate(job.gpa, path_arena.allocator(), spec) catch |err| {
        job.fail = err;
        return;
    };
    defer g.deinit(job.gpa);
    if (job.cancel.load(.acquire)) return;

    const edges = job.gpa.alloc(Indexer.SnapEdge, g.edges.len) catch |err| {
        job.fail = err;
        return;
    };
    for (g.edges, edges) |e, *out| out.* = .{ .src_id = @intCast(e.a + 1), .dst_id = @intCast(e.b + 1) };

    // Titles: empty past a few thousand notes, same as the vault's own real-note labelling
    // threshold — nothing labels that many marks on screen at once regardless of source.
    var node_arena = std.heap.ArenaAllocator.init(job.gpa);
    const nodes = node_arena.allocator().alloc(Indexer.SnapNode, n) catch |err| {
        job.fail = err;
        job.gpa.free(edges);
        node_arena.deinit();
        return;
    };
    const label_titles = n <= 5_000;
    // Carry the generated folder paths through, rather than publishing every node with an empty
    // one. `fold.build` uses paths for its folder chain — the weak structural tiebreak that gives
    // coarsening something to group on where real links don't decide it — and `vault_synth`
    // already models a plausible folder tree per component. Publishing all-empty paths didn't
    // merely lose that signal, it actively corrupted it: `paths.len == n_notes` still holds, so
    // `addPathChain` runs, and with every path comparing equal the sort leaves arbitrary index
    // order and the chain wires unrelated notes together at weight 0.25. That is why the
    // simulator's coalescing looked flat and barely responsive to note count while the `--world`
    // bench (which passes an *empty slice*, skipping the chain entirely) looked correct.
    const have_paths = g.paths.len == n;
    for (nodes, 0..) |*node, i| {
        node.* = .{
            .id = @intCast(i + 1),
            .path = if (have_paths)
                node_arena.allocator().dupe(u8, g.paths[i]) catch ""
            else
                "",
            .title = if (label_titles)
                std.fmt.allocPrint(node_arena.allocator(), "n{d}", .{i}) catch ""
            else
                "",
            .phantom = false,
            .degree = g.degrees[i],
            // Degree-squared so a hub reads heavier than a stub; the salt spreads sizes
            // inside an exclusive pair so gravity has a mass contrast to show.
            .size = size: {
                const d: u64 = g.degrees[i];
                const salt: u64 = i % 5;
                const bytes = 128 + d * d * 256 + salt * salt * 8_000;
                break :size @intCast(@min(bytes, std.math.maxInt(u32)));
            },
        };
    }

    job.nodes = nodes;
    job.edges = edges;
    job.node_arena = node_arena;
    // Take ownership of the packed positions out of `g` before its `deinit` frees them — this is
    // what lets the panel skip `layout_full` for a synthetic vault of any size.
    if (g.positions.len == n) {
        job.positions = g.positions;
        g.positions = &.{};
    }
}

pub const Sim = struct {
    open: bool = false,
    gpa: std.mem.Allocator,
    panel: graph.Panel,
    state: SimState = .{},
    /// What the sidebar widgets are currently set to.
    pending: SimSpec = .{},
    /// What has actually been published to `state.indexer` — compared against `pending` to
    /// decide whether a debounce should fire.
    applied: SimSpec = .{},
    applied_valid: bool = false,
    /// Countdown of frames until a settled edit turns into a rebuild — the "live" part of "live
    /// controls" without spawning a regeneration on every single frame a slider is dragged.
    reload_frames: ?u32 = null,
    job: ?*RegenJob = null,
    win_rect: dvui.Rect = .{ .x = 80, .y = 80, .w = 900, .h = 600 },
    shape_idx: usize = 1, // .islands, matching SimSpec's default
    /// A/B for `containment.aperture7_rotation` — see the checkbox in `drawSidebar`.
    hex_lattice: bool = false,
    /// Live `containment.Options`, mirrored into `panel.place_opts` on edit. Starts at the
    /// no-overlap `radius_exp` rather than 0.5 so the spread fix is what you see first.
    place: containment.Options = .{ .radius_exp = 0.619, .gravity = true },
    /// Collapsed by default — five more sliders is a lot of sidebar when you only want a shape.
    show_tuning: bool = false,
    /// Faint push-radius rings on living notes — gravity debug, off by default.
    show_push: bool = false,
    /// The counters the sidebar is currently displaying, resampled every `readout_period_s`
    /// rather than every frame. A number that changes 120 times a second is unreadable, and
    /// re-measuring it is not why the readout exists.
    hud: graph.PanelStats = .{},
    hud_accum: f32 = 0,

    /// Deliberately doesn't call `self.state.init(gpa)` — `Indexer.init` stores pointers to its
    /// owner's `busy`/`generation` fields, and `Sim.init` returns by value into `ensureSim`'s
    /// module-level `sim`, one more move after this function would return. Pointers captured
    /// against a temporary that then gets copied elsewhere go stale the moment the copy happens:
    /// `generation`/`busy` would keep reading/writing the original stack slot, which is exactly
    /// why the graph never appeared — `Indexer.publishSynthetic`'s `generation.fetchAdd` landed on
    /// dead stack memory, so `hasGraphSource`'s read of the *real* `generation` field (on the
    /// stable copy) never saw it move. `ensureSim` calls `state.init` itself, once `sim` is at its
    /// final address — the same reason `State.init` takes `self: *State` and is only ever called
    /// on the already-placed `plugin_state` global, never inside a by-value constructor.
    pub fn init(gpa: std.mem.Allocator) Sim {
        var p = graph.Panel.init(gpa);
        // Pan/zoom must use the dialog-canvas input policy — the main-pane suppressor
        // treats any floating subwindow as "don't touch the editor canvas".
        p.dialog_canvas = true;
        // Nothing here is backed by a file — clicks must never reach the workbench.
        p.synthetic = true;
        // Match the sidebar's own starting value, or the first frame would draw the
        // area-conserving layout under a slider that says otherwise.
        p.place_opts.radius_exp = 0.619;
        p.place_opts.gravity = true;
        return .{ .gpa = gpa, .panel = p };
    }

    pub fn deinit(self: *Sim) void {
        // `.wait` here, never `.detach`: the worker is running `vault_synth.generate`, which lives
        // in this dylib, and teardown is followed by the library being unloaded. A detached thread
        // outliving that executes freed code — the exact hazard `graph.shutdown`'s own doc comment
        // describes for the layout worker. The wait is bounded by one `generate` call (cancel is
        // only checked between phases, so a large N cannot be cut short mid-solve), which is why
        // the interactive path below still detaches instead.
        self.cancelJob(.wait);
        graph.shutdownPanel(&self.panel);
        self.panel.deinit();
        self.state.deinit();
    }

    fn specChanged(self: *const Sim) bool {
        return !self.applied_valid or
            self.pending.n != self.applied.n or
            self.pending.shape != self.applied.shape or
            self.pending.avg_deg != self.applied.avg_deg;
    }

    /// The sidebar calls this on every edit — schedules a short debounce (~200ms) rather than
    /// rebuilding on every single frame a slider is mid-drag. Background build keeps the previous
    /// graph up and interactive until the new one lands.
    pub fn scheduleReload(self: *Sim) void {
        self.reload_frames = 12;
    }

    fn tick(self: *Sim) void {
        self.hud_accum += dvui.secondsSinceLastFrame();
        if (self.hud_accum >= readout_period_s) {
            self.hud_accum = 0;
            self.hud = graph.panelTimings(&self.panel);
        }
        if (self.reload_frames) |frames| {
            if (frames > 1) {
                self.reload_frames = frames - 1;
            } else {
                self.reload_frames = null;
                if (self.specChanged()) self.startJob();
            }
        }
        self.pollJob();
    }

    /// `.detach` leaves an unfinished worker to claim and free itself — right for an interactive
    /// re-edit, where joining a large `generate` would freeze the window. `.wait` joins instead,
    /// and is required at teardown: see `deinit`.
    const CancelMode = enum { detach, wait };

    fn cancelJob(self: *Sim, mode: CancelMode) void {
        const job = self.job orelse return;
        self.job = null;
        job.cancel.store(true, .release);
        if (job.done.load(.acquire) or mode == .wait) {
            if (job.thread) |t| t.join();
            job.thread = null;
            if (job.tryClaim()) job.destroy();
        } else if (job.thread) |t| {
            // Don't join on the UI thread — a 500k generate would freeze the window for seconds.
            t.detach();
            job.thread = null;
            // Worker sees cancel and claims+destroys itself when it finishes.
        }
    }

    fn startJob(self: *Sim) void {
        self.cancelJob(.detach);
        const job = self.gpa.create(RegenJob) catch return;
        job.* = .{ .gpa = self.gpa, .spec = self.pending };
        self.job = job;
        job.thread = std.Thread.spawn(.{}, regenWorker, .{job}) catch {
            self.job = null;
            job.destroy();
            return;
        };
    }

    fn pollJob(self: *Sim) void {
        const job = self.job orelse return;
        if (!job.done.load(.acquire)) return;
        if (job.thread) |t| t.join();
        job.thread = null;
        self.job = null;
        if (!job.tryClaim()) return; // cancelled worker already freed itself
        defer job.destroy();

        if (job.cancel.load(.acquire)) return;
        if (job.fail) |err| {
            dvui.log.err("atlas: vault simulator regen: {any}", .{err});
            return;
        }
        const nodes = job.nodes orelse return;
        const edges = job.edges orelse return;
        if (!self.state.indexer_ready) return;

        // Positions before the publish: the very next `rebuildIfNeeded` reads them via
        // `packedPositions`, and it is driven by the generation bump `publishSynthetic` does.
        if (job.positions) |pos| {
            if (self.state.synth_pos) |old| self.gpa.free(old);
            self.state.synth_pos = pos;
            job.positions = null; // ownership moved; don't let `destroy` free it
        }

        self.state.indexer.publishSynthetic(nodes, edges) catch |err| {
            dvui.log.err("atlas: vault simulator publish: {any}", .{err});
            return;
        };
        self.applied = job.spec;
        self.applied_valid = true;
        // A shape/scale change can be a wildly different extent than what the camera was last
        // fitted to (islands at 300k vs. a chain at 2k) — recenter so the new graph is where the
        // reader is actually looking, the same way the very first build already does.
        graph.zoomExtentsFor(&self.panel);
        sdk.refresh();
    }

    fn drawSidebar(self: *Sim) void {
        // Same fill role the file explorer's own pane uses (`.content, .fill` — the app's single
        // window-background color; every pane between it and the root just inherits it rather
        // than setting its own), so this reads as a pane rather than a plain content area.
        var box = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .vertical,
            .min_size_content = .{ .w = 260 },
            .margin = .{ .x = 8, .y = 8, .w = 8, .h = 8 },
            .padding = dvui.Rect.all(8),
            .background = true,
            .color_fill = dvui.themeGet().color(.content, .fill),
            .corners = .round(6),
        });
        defer box.deinit();

        dvui.labelNoFmt(@src(), "Vault Simulator", .{}, .{ .font = dvui.Font.theme(.heading) });

        dvui.labelNoFmt(@src(), "Shape", .{}, .{ .margin = .{ .y = 8 } });
        if (dvui.dropdown(@src(), shape_labels, .{ .choice = &self.shape_idx }, .{}, .{})) {
            self.pending.shape = shape_choices[@min(self.shape_idx, shape_choices.len - 1)];
            self.scheduleReload();
        }

        var n_f: f32 = @floatFromInt(self.pending.n);
        if (dvui.sliderEntry(@src(), "Notes: {d:.0}", .{
            .value = &n_f,
            .min = 100,
            .max = 1_000_000,
        }, .{ .expand = .horizontal, .margin = .{ .y = 8 } })) {
            self.pending.n = quantizeNotes(n_f);
            self.scheduleReload();
        }

        if (dvui.sliderEntry(@src(), "Avg degree: {d:.1}", .{
            .value = &self.pending.avg_deg,
            .min = 0,
            .max = 16,
            .interval = 0.5,
        }, .{ .expand = .horizontal, .margin = .{ .y = 8 } })) {
            self.scheduleReload();
        }

        // Mark budget — the LOD's cap on marks per frame, not a property of the generated vault,
        // so it takes effect on the very next frame rather than scheduling a regen.
        // Capped well under dvui's own ~16k sprite ceiling (a u16 index limit, not an SDL one):
        // marks and the web's line segments share that budget, so a mark cap anywhere near it
        // would drop geometry rather than draw more.
        var budget_f: f32 = @floatFromInt(self.panel.mark_budget);
        if (dvui.sliderEntry(@src(), "Mark budget: {d:.0}", .{
            .value = &budget_f,
            .min = 50,
            .max = 4_000,
        }, .{ .expand = .horizontal, .margin = .{ .y = 8 } })) {
            self.panel.mark_budget = @intFromFloat(std.math.clamp(budget_f, 50, 4_000));
        }

        // Per-level rotation is baked into the world at construction, so this rebuilds it rather
        // than just taking effect on the next step like the budget above.
        if (dvui.checkbox(@src(), &self.hex_lattice, "Hex lattice nesting", .{ .margin = .{ .y = 8 } })) {
            self.panel.place_rotation = if (self.hex_lattice) containment.aperture7_rotation else null;
            graph.invalidateWorld(&self.panel);
        }

        if (dvui.checkbox(@src(), &self.place.gravity, "Gravity placement", .{ .margin = .{ .y = 4 } })) {
            self.panel.place_opts = self.place;
            graph.invalidateWorld(&self.panel);
        }
        _ = dvui.checkbox(@src(), &self.show_push, "Show push radii", .{ .margin = .{ .y = 2 } });

        self.drawTuning();

        if (self.job != null) {
            dvui.labelNoFmt(@src(), "Regenerating…", .{}, .{
                .margin = .{ .y = 12 },
                .color_text = dvui.themeGet().color(.content, .text).opacity(0.5),
            });
        } else if (self.applied_valid) {
            const shown = blk: {
                for (shape_choices, 0..) |sh, i| {
                    if (sh == self.applied.shape) break :blk shape_labels[i];
                }
                break :blk "?";
            };
            dvui.label(@src(), "Showing: {s} · {d}", .{ shown, self.applied.n }, .{
                .margin = .{ .y = 12 },
                .color_text = dvui.themeGet().color(.content, .text).opacity(0.55),
            });
        }

        // What is actually on screen, against what the arrangement holds. A million-note vault
        // drawing a few hundred marks is the LOD working — `notes` resolved as themselves,
        // `masses` standing in for everything else — and the gap between the two numbers is the
        // thing worth being able to see while tuning the budget above.
        const st = self.hud;
        dvui.labelNoFmt(@src(), "Drawn", .{}, .{ .margin = .{ .y = 10 } });
        readout(@src(), "marks: {d} / {d}{s}", .{
            st.notes + st.masses,
            st.budget,
            if (st.bound) " capped" else "",
        });
        readout(@src(), "notes: {d} of {d}", .{ st.notes, st.total_notes });
        readout(@src(), "masses: {d}", .{st.masses});
        readout(@src(), "links: {d} of {d}", .{ st.links, st.total_edges });
        // Camera/viewport, because a canvas that never got a real rect (or a camera parked
        // somewhere the graph isn't) looks exactly like a control that did nothing, and there is
        // otherwise no way to tell those two apart from the outside.
        const vp = self.panel.camera.viewport;
        readout(@src(), "view: {d:.0}x{d:.0} @ {d:.3}x", .{ vp.w, vp.h, self.panel.camera.zoom });

        // Where the frame actually went. The `per-vault` rows are paid in full whether the budget
        // draws 50 marks or 4000; `per-drawn` is the only part that scales with what is on screen.
        // When the first dwarfs the second, raising the budget cannot help and lowering it cannot
        // rescue the frame rate: the cost is upstream of drawing entirely. That is precisely the
        // reading a slider labelled "Mark budget" invites you to get wrong, which is why it is
        // printed right underneath it.
        dvui.labelNoFmt(@src(), "Frame (µs)", .{}, .{ .margin = .{ .y = 10 } });
        readout(@src(), "total {d:>7}  ({d:>4} fps)", .{
            st.us_total,
            if (st.us_total > 0) @min(@as(u64, 9999), 1_000_000 / st.us_total) else 0,
        });
        readout(@src(), "per-vault  step {d:>6}", .{st.us_world_step});
        readout(@src(), "           sync {d:>6}", .{st.us_world_sync});
        readout(@src(), "           lift {d:>6}", .{st.us_world_lift});
        readout(@src(), "        rebuild {d:>6}", .{st.us_rebuild});
        readout(@src(), "           misc {d:>6}", .{st.us_misc});
        readout(@src(), "per-drawn  bubl {d:>6}", .{st.us_bubbles});
        readout(@src(), "          hover {d:>6}", .{st.us_hover});
        readout(@src(), "         labels {d:>6}", .{st.us_labels});
        readout(@src(), "           draw {d:>6}", .{st.us_draw});
    }

    /// One line of the numeric readout, at a **pinned width**.
    ///
    /// Every one of these carries a number that changes as the camera moves, and a plain
    /// `dvui.label` takes its min size from its text. Two things follow, both of which this window
    /// had: `WidgetData.minSizeSetAndRefresh` calls `dvui.refresh` whenever a widget's min size
    /// changes and was a binding constraint, so a per-frame-varying width means the app can never
    /// go to sleep; and the sidebar box sizes to its widest child, so the pane — and the splitter
    /// beside it — visibly jittered as digits came and went.
    ///
    /// `min_sizeM`/`max_sizeM` pin the content box to a fixed number of M-widths, so the text never
    /// reaches the layout at all. The format strings above right-align their numbers into that
    /// width; keep them inside `readout_cols` or they will be clipped rather than resize anything.
    fn readout(src: std.builtin.SourceLocation, comptime fmt: []const u8, args: anytype) void {
        const opts: dvui.Options = .{
            .color_text = dvui.themeGet().color(.content, .text).opacity(0.55),
            .font = dvui.Font.theme(.mono),
        };
        dvui.label(src, fmt, args, opts.min_sizeM(readout_cols, 1).max_sizeM(readout_cols, 1));
    }

    /// Placement knobs, all `containment.Options`. Every one is baked into the world when it is
    /// built, so each edit invalidates it — cheap at simulator scale, and the point is to see the
    /// effect immediately rather than to be frugal.
    fn drawTuning(self: *Sim) void {
        _ = dvui.checkbox(@src(), &self.show_tuning, "Placement tuning", .{ .margin = .{ .y = 8 } });
        if (!self.show_tuning) return;

        const dim = dvui.themeGet().color(.content, .text).opacity(0.5);
        var changed = false;

        // `sliderEntry` takes its format string comptime, so this is an inline loop over a
        // comptime tuple rather than a runtime array of descriptors.
        inline for (.{
            .{ "Spread: {d:.3}", "radius_exp", 0.5, 0.75, 0.005, "0.5 = area-conserving (forces overlap)" },
            .{ "Aim outward: {d:.2}", "ext_k", 0.0, 6.0, 0.1, "0 = slots ignore links leaving the cell" },
            .{ "Fill: {d:.2}", "fill", 0.5, 1.0, 0.01, "how far the child ring may reach" },
            .{ "Mass pull: {d:.2}", "mass_k", 0.0, 2.0, 0.05, "0 = links alone decide slots" },
            .{ "Island gap: {d:.2}", "pack_gap", 1.0, 12.0, 0.1, "air between top-level islands" },
            .{ "Island aspect: {d:.2}", "pack_aspect", 0.6, 2.5, 0.05, "horizontal stretch of the island pack" },
            .{ "Gravity G: {d:.2}", "gravity_g", 0.02, 0.5, 0.01, "exclusive-link attraction" },
            .{ "COM pull: {d:.3}", "gravity_com", 0.0, 0.15, 0.005, "weak centre-of-universe" },
            .{ "Exclusive: {d:.2}", "exclusive_k", 0.0, 4.0, 0.05, "low-degree cells claim more space" },
            .{ "Sibling push: {d:.2}", "sib_push", 0.4, 2.5, 0.05, "pair sits far; more siblings pack tighter" },
            .{ "File mass: {d:.2}", "body_k", 0.0, 1.2, 0.05, "log(file size) extra push / inertia" },
        }, 0..) |k, i| {
            // Every iteration shares one `@src()`, so dvui would derive the same widget id for
            // all six — `id_extra` is what separates them. The slider's own internal label is
            // keyed off the slider, so it is covered by the same disambiguation.
            if (dvui.sliderEntry(@src(), k[0], .{
                .value = &@field(self.place, k[1]),
                .min = k[2],
                .max = k[3],
                .interval = k[4],
            }, .{ .expand = .horizontal, .margin = .{ .y = 4 }, .id_extra = i })) changed = true;
            dvui.labelNoFmt(@src(), k[5], .{}, .{
                .color_text = dim,
                .margin = .{ .h = 6 },
                .id_extra = i,
            });
        }

        dvui.label(@src(), "no-overlap at spread ≥ {d:.3}", .{
            containment.minRadiusExp(self.place.fill),
        }, .{ .color_text = dim });

        if (changed) {
            self.panel.place_opts = self.place;
            graph.invalidateWorld(&self.panel);
        }
    }

    fn drawCanvas(self: *Sim) !void {
        // Opaque, and distinctly darker than the window fill. The window itself is drawn at 0.85
        // opacity (matching fizzy's dialog chrome), which left the editor — and the real bottom
        // panel's own graph — legible straight through this area. With nothing of its own painted
        // here it was genuinely ambiguous whether a graph on screen belonged to the simulator or
        // to the panel behind it, which is exactly the wrong thing to be unsure about while
        // judging whether a control did anything.
        var box = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .both,
            .background = true,
            .color_fill = dvui.themeGet().color(.window, .fill),
            .margin = .{ .y = 8, .w = 8, .h = 8 },
            .corners = .round(6),
        });
        defer box.deinit();
        try graph.drawPanel(&self.panel, &self.state);
        if (self.show_push) self.drawPushRadii();
    }

    /// Faint rings at each living note's invisible push radius — the interior-entry gap.
    fn drawPushRadii(self: *Sim) void {
        const w = if (self.panel.world_state) |*ws| ws else return;
        const cam = self.panel.camera;
        const col = dvui.themeGet().color(.highlight, .fill).opacity(0.35);
        for (w.marks.items) |m| {
            if (!m.is_note) continue;
            const sr = w.field.separationRadius(&w.lad, m.cell);
            const r_px = sr * cam.zoom;
            if (r_px < 2 or r_px > 400) continue;
            const scr = cam.worldToScreen(.{ .x = m.wx, .y = m.wy });
            const n_pts: usize = 24;
            var pts: [25]dvui.Point.Physical = undefined;
            for (0..n_pts + 1) |i| {
                const a = std.math.tau * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n_pts));
                pts[i] = .{ .x = scr.x + @cos(a) * r_px, .y = scr.y + @sin(a) * r_px };
            }
            var path: dvui.Path = .{ .points = pts[0 .. n_pts + 1] };
            path.stroke(.{ .color = col, .thickness = 1 });
        }
    }
};

var sim: ?Sim = null;

fn ensureSim(gpa: std.mem.Allocator) *Sim {
    if (sim == null) {
        sim = Sim.init(gpa);
        // Now that `sim` is at its final, stable address: see the comment on `Sim.init`.
        sim.?.state.init(gpa);
    }
    return &sim.?;
}

/// Whether the window needs frames kept coming even with no input to react to — a debounce
/// counting down, or a background regen the UI thread hasn't polled the result of yet. Neither
/// one otherwise has anything that wakes the frame loop back up: the debounce only ticks inside
/// `Sim.tick`, called from `drawOverlay`, called only when a frame actually draws, and the worker
/// thread finishing in the background doesn't itself cause a frame — without this, a slider drag
/// pumped enough frames to *start* a regen (dvui's own input handling keeps frames coming while
/// the mouse is moving) but then nothing ever polled it to completion once the drag ended and the
/// mouse stopped, which is exactly "regenerating shows, then nothing happens." Same role
/// `st.synthBusy()` played in `needsContinuousRepaint` for the old settings-pane synth path.
pub fn needsContinuousRepaint() bool {
    const s = if (sim) |*sv| sv else return false;
    if (!s.open) return false;
    if (s.job != null or s.reload_frames != null) return true;
    // The regen job above only covers *this* file's own background work (vault_synth.generate +
    // publishSynthetic). A large enough note count pushes the graph's own layout solve onto its
    // own worker (Panel.job, well past layout_inline_max) — that has to be polled to completion
    // too, or a note-count change past that threshold applies data-wise (publishSynthetic
    // succeeds, the label updates) but the panel never actually finishes laying it out on screen.
    return graph.wantsRepaintFor(&s.panel);
}

/// Toggle the window open — the command handler.
pub fn toggleOpen() void {
    const s = ensureSim(sdk.allocator());
    s.open = !s.open;
    if (s.open) {
        // First open (or reopen after a close that never landed a build): nothing schedules a
        // rebuild until a control is actually touched, so without this the window sits there
        // forever with nothing generated — the controls only ever request a *change*, not the
        // first graph.
        if (!s.applied_valid and s.job == null) s.scheduleReload();
        sdk.refresh();
    }
}

/// Join the regen worker and the panel's own layout worker. Called from the plugin's `deinit` —
/// the same reason `graph.shutdown` exists for the real bottom panel.
pub fn shutdown() void {
    if (sim) |*s| s.deinit();
    sim = null;
}

/// `sdk.Plugin.VTable.drawOverlay` — called every frame regardless of which tab/panel is active,
/// so the window can stay open alongside a real vault's own bottom panel.
pub fn drawOverlay(_: *anyopaque) !void {
    const s = ensureSim(sdk.allocator());
    if (!s.open) return;
    s.tick();

    // Same chrome every other fizzy dialog uses (`core.dvui.dialogWindow`'s own opts) — rounded
    // corners, no border, a soft drop shadow — rather than a bare dvui.floatingWindow, which reads
    // as a foreign widget next to the rest of the app's dialogs and tool windows.
    var float = core.dvui.floatingWindow(@src(), .{
        .rect = &s.win_rect,
        .open_flag = &s.open,
        .window_avoid = .nudge_once,
    }, .{
        .color_fill = dvui.themeGet().color(.content, .fill).opacity(0.85),
        .corners = .round(10),
        .border = .all(0),
        .box_shadow = .{ .color = .black, .alpha = 0.35, .fade = 10, .corners = .round(10) },
    });
    defer float.deinit();

    // Narrow the window-drag hit target to the header. Without this, FloatingWindowWidget
    // keeps drag_area = the whole window → move cursor everywhere, and presses become
    // window drags instead of sidebar edits / canvas pan-zoom.
    float.dragAreaSet(core.dvui.windowHeader("Atlas: Vault Simulator", "", &s.open, .none));

    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .both });
    defer row.deinit();
    s.drawSidebar();
    try s.drawCanvas();
}
