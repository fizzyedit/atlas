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
const shape_choices: []const vault_synth.Shape = &.{ .scale_free, .islands, .hub, .bipartite, .chain, .orphans };
const shape_labels: []const []const u8 = &.{ "scale-free", "islands", "hub", "bipartite", "chain", "orphans" };

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

    pub fn init(self: *SimState, gpa: std.mem.Allocator) void {
        self.indexer = Indexer.init(gpa, &self.busy, &self.generation);
        self.indexer_ready = true;
    }

    pub fn deinit(self: *SimState) void {
        if (self.indexer_ready) self.indexer.deinit();
        self.indexer_ready = false;
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
    /// `nodes[].path`/`.title` live here; freed once `publishSynthetic` has deep-copied them.
    node_arena: ?std.heap.ArenaAllocator = null,

    fn tryClaim(self: *RegenJob) bool {
        return !self.claimed.swap(true, .acq_rel);
    }

    fn discardResults(self: *RegenJob) void {
        if (self.edges) |e| self.gpa.free(e);
        if (self.node_arena) |*a| a.deinit();
        self.edges = null;
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
    for (nodes, 0..) |*node, i| {
        node.* = .{
            .id = @intCast(i + 1),
            .path = "",
            .title = if (label_titles)
                std.fmt.allocPrint(node_arena.allocator(), "n{d}", .{i}) catch ""
            else
                "",
            .phantom = false,
            .degree = g.degrees[i],
        };
    }

    job.nodes = nodes;
    job.edges = edges;
    job.node_arena = node_arena;
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
        return .{ .gpa = gpa, .panel = p };
    }

    pub fn deinit(self: *Sim) void {
        self.cancelJob();
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

    fn cancelJob(self: *Sim) void {
        const job = self.job orelse return;
        self.job = null;
        job.cancel.store(true, .release);
        if (job.done.load(.acquire)) {
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
        self.cancelJob();
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
            .min_size_content = .{ .w = 220 },
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
    }

    fn drawCanvas(self: *Sim) !void {
        var box = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both });
        defer box.deinit();
        try graph.drawPanel(&self.panel, &self.state);
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
    const s = sim orelse return false;
    if (!s.open) return false;
    return s.job != null or s.reload_frames != null;
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
