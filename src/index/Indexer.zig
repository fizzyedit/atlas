//! Background indexer: scan the vault, parse notes, write the in-memory `Index`.
//!
//! One writer, the UI thread a reader under the `Index`'s lock (held per note, never across a
//! pass). The work is a `core.work.Task` (`Scan` for a pass over the vault, this file's own
//! step for the queue between passes) that the `Runner` drives one of two ways — see
//! `Source`: on a worker thread for a folder on this machine, whose reads land inside the
//! task; from the frame for a cloud mount (its completions arrive with the host's pump) and on
//! the web (no threads). Lifecycle is owned by `State`: `start` on folder open, `stop` on
//! folder close / deinit. The stop joins — this code runs inside atlas's dylib and must not
//! outlive it.
const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const sdk = @import("fizzy_sdk");
const core = @import("core");
const work = core.work;
const vfs = core.vfs;

const Index = @import("Index.zig");
const Scan = @import("Scan.zig");
const threads = @import("threads");
const Scanner = @import("Scanner.zig");
const resolve = @import("resolve.zig");
const query = @import("query.zig");

const Indexer = @This();

pub const max_file_bytes: usize = 4 * 1024 * 1024;
/// Runaway guard, not a product limit: it exists so a vault root accidentally pointed at a home
/// directory cannot walk forever. Sized for the largest corpus the graph is meant to handle — a
/// full Wikipedia-scale markdown vault — rather than for a personal vault, which is what the old
/// 200_000 was and what silently truncated a 283,878-note import by a third.
pub const max_notes: usize = 10_000_000;
/// Commit at least this often during a full scan so the UI sees progress.
pub const batch_files: usize = 200;
pub const batch_ns: i96 = 250 * std.time.ns_per_ms;

const log = std.log.scoped(.atlas);

/// Immutable view published after each commit. Flat node/edge arrays for the graph panel so it
/// can walk neighbourhoods without touching SQLite mid-draw.
///
/// Slices live in a `snap_arenas` slot owned by the worker, so the UI never gets to keep one:
/// `snapshotCopy` deep-copies into a caller arena while holding `snap_mutex`, and the worker
/// takes the same mutex around the reset that recycles a slot. A borrowed snapshot used to be
/// the API, on the theory that a 2-deep ring keeps the UI's pointer alive across one commit —
/// but a rebuild frame on a large vault outlives *many* commits (a full scan publishes every
/// 200 files), so the ring wrapped and the arena backing the strings the layout was walking got
/// freed underneath it. Counts alone are pointer-free; see `counts`.
pub const SnapNode = struct {
    id: i64,
    path: []const u8,
    title: []const u8,
    phantom: bool,
    /// Distinct neighbour count (in ∪ out). Drives node radius.
    degree: u32,
    /// File size in bytes. 0 for phantoms / synth notes that did not set one.
    size: u32 = 0,
};

pub const SnapEdge = struct {
    src_id: i64,
    dst_id: i64,
};

pub const Snapshot = struct {
    note_count: u32 = 0,
    link_count: u32 = 0,
    phantom_count: u32 = 0,
    nodes: []const SnapNode = &.{},
    edges: []const SnapEdge = &.{},
    /// True when this snapshot's links have been resolved against the final note set.
    ///
    /// A scan publishes progress every `batch_files`/`batch_ns`, but `relinkAll` runs **once**,
    /// after the whole walk — it cannot run earlier, since resolving `[[Paris]]` means knowing
    /// whether `Paris.md` exists anywhere in the vault. So every mid-scan snapshot carries notes
    /// whose links have no destination: an *edgeless* graph. That is not "part of the vault", it
    /// is a misleading picture of all of it, and a consumer that draws relationships must wait.
    /// Consumers that only list files (the tree, search) can and should use partial snapshots.
    complete: bool = false,
    /// Markdown files the pre-pass counted on disk, so a scan in progress can say "x of y".
    /// Zero when unknown (no scan has run, or the count failed).
    scan_total: u32 = 0,
    /// What a scan in progress is currently doing, so the spinner can say so. Resolving links is
    /// its own multi-minute phase on a large vault, and reporting it as "building notes" leaves
    /// the count frozen on the last file for the whole of it — which reads as a hang.
    phase: Phase = .idle,
    /// Notes rewritten since the previous published snapshot.
    ///
    /// The indexer already knows this — `indexPending` returns `unchanged` / `rewrote` / `structural`
    /// per file and the incremental path uses it to scope the *relink*. It then threw it away, and
    /// every consumer downstream re-derived it: the graph re-solves the whole vault on every
    /// commit because a whole snapshot is all it is given, so a one-note edit costs the same
    /// seconds a first open does.
    ///
    /// Only meaningful when `dirty_known` is true.
    dirty: []const i64 = &.{},
    /// Is `dirty` an exhaustive account of what changed?
    ///
    /// False after a full scan, and false after a *structural* change — a note appearing or
    /// vanishing moves where other notes' links resolve, so the edit is not confined to the notes
    /// that were written. A consumer must treat false as "assume everything moved".
    dirty_known: bool = false,
    /// True when this publish left the edge array identical to the previous one.
    ///
    /// A prose save rewrites a note's body and republishes, but its outbound links are the same
    /// rows. The graph already knows that case as `job.settled`; this flag lets it skip the copy
    /// of every edge *and* the world rebuild, rather than discovering the no-op after walking
    /// 3.3M of them. Only meaningful when `dirty_known` is true — a structural publish reloads
    /// everything and leaves this false.
    edges_same: bool = false,
};

/// Pointer-free layout inputs, so the graph can decide "identity skip" without copying 73 MB.
pub const LayoutPeek = struct {
    dirty_known: bool = false,
    edges_same: bool = false,
    complete: bool = false,
    node_n: usize = 0,
    dirty_n: usize = 0,
};

pub const Phase = enum(u8) {
    idle,
    /// Walking the vault: reading, parsing and writing notes.
    scanning,
    /// `relinkAll`: resolving every link against the final note set.
    resolving,
    /// `commitAndPublish`: building the snapshot the graph is handed.
    ///
    /// Its own phase because it is not instantaneous and it reports nothing while it runs — it is
    /// one long pair of queries over every note and every link, with no loop to hang a counter on.
    /// Without a label of its own the spinner keeps displaying whichever phase ran last, so a
    /// twelve-second publish read as "resolving links" taking far longer than it does.
    publishing,
};

/// The resolution candidate lists, built on the worker and handed to the UI thread whole.
///
/// Ownership transfer, not a borrow: the receiver takes the arena and every string in it, and the
/// worker never touches this memory again. That is what makes it safe without the snapshot ring's
/// mutex dance — there is no slot to recycle out from under a reader mid-frame.
pub const CandidateSet = struct {
    /// Notes, plus one entry per alias.
    notes: []const resolve.Candidate = &.{},
    /// Attachments. A separate list on purpose — see `query.loadMediaCandidates`.
    media: []const resolve.Candidate = &.{},
    /// Backs both slices. The owner deinits it; `undefined` is never a valid state here, so this
    /// type is only ever constructed by `buildCandidates`.
    arena: std.heap.ArenaAllocator,
    /// Lookup tables over `notes`, built here on the worker so the UI thread never resolves a
    /// link by scanning the vault. Without it every `[[…]]` the markdown renderer draws costs
    /// four passes over every candidate. Measured at Simple English Wikipedia's 284k notes:
    /// **5.7 ms per link** scanning versus **1.2 µs** through the index, so a 100-link article
    /// costs 570 ms of stalled UI on the frame after each generation bump — and the generation
    /// moves on every commit, so a background scan re-froze the document repeatedly.
    ///
    /// Notes only. Attachments are a few hundred entries even in a vault full of images, so an
    /// index over them would cost more to build than the scan it replaces.
    index: resolve.Index,

    pub fn deinit(self: *CandidateSet) void {
        self.index.deinit();
        self.arena.deinit();
    }
};

/// The whole-vault inputs link resolution needs, kept between calls.
///
/// Resolving one note's links needs the *entire* candidate set — a link can point anywhere — so
/// `relinkScope` built all three of these from scratch every time: every note's path and stem, the
/// lookup index over them, and every note's id by path. That is ~250 ms of the ~255 ms a
/// single-note relink cost, to resolve a handful of targets. The resolve loop itself did not
/// register.
///
/// Valid exactly while the *note set* is unchanged. Which notes exist, and their stems and aliases,
/// is what resolution reads; a note's body is not. So an edit that only rewrites a note's links
/// keeps the cache, and anything that adds or removes a note drops it — which is the same boundary
/// `relinkNote` already draws, and the same event that forces a `relinkAll` anyway.
///
/// The memory is real: roughly one `Candidate` per note plus an alias, its strings, the index over
/// them, and a path→id map — tens of megabytes on the reference corpus, held for as long as the
/// vault is open rather than for the length of one call. That is the trade being made, and it is
/// the same data the indexer was already building transiently on every publish.
const ResolveCache = struct {
    arena: std.heap.ArenaAllocator,
    candidates: []const resolve.Candidate,
    index: resolve.Index,

    fn deinit(self: *ResolveCache, _: std.mem.Allocator) void {
        self.index.deinit();
        self.arena.deinit();
        self.* = undefined;
    }
};

/// The pointer-free part of a snapshot, for callers that only want the footer numbers.
pub const Counts = struct {
    note_count: u32 = 0,
    link_count: u32 = 0,
    phantom_count: u32 = 0,
    /// See `Snapshot.complete`.
    complete: bool = false,
    /// See `Snapshot.scan_total`.
    scan_total: u32 = 0,
    /// See `Snapshot.phase`.
    phase: Phase = .idle,
};

gpa: std.mem.Allocator,
/// Borrowed from State for the life of the indexer. Null only after `stop`.
index: ?*Index = null,
vault_root: []const u8 = "",

quit: std.atomic.Value(bool) = .init(false),
busy: *std.atomic.Value(bool),
generation: *Generation,

/// Guards `want_full`/`want_sweep`/`pending`, written by the UI (enqueue) and read by the task.
mutex: std.Io.Mutex = .init,
/// Drives the task: a worker thread or the frame, per `source`. See `start`.
runner: ?work.Runner = null,
/// Where the vault's bytes come from; set by `start`.
source: ?Scan.Source = null,
/// The pass in progress, if one is.
scan: ?Scan = null,

/// Set under `mutex`. The worker clears it when it begins a scan.
want_full: bool = false,
/// Set under `mutex`. A background re-walk that publishes *only* if something actually moved.
/// `Watcher` only polls files someone has open, so an edit made by anything else — an agent, a
/// git checkout, another editor — is otherwise invisible to the index until the next explicit
/// rebuild, and the graph keeps drawing links that no longer exist.
want_sweep: bool = false,
/// Notes waiting for an incremental reindex. Owned strings.
pending: std.ArrayList(Pending) = .empty,

/// 2-deep ring so the UI can hold a pointer across a frame while the worker publishes the next.
snapshots: [2]Snapshot = .{ .{}, .{} },
snap_arenas: [2]?std.heap.ArenaAllocator = .{ null, null },
snap_pub: std.atomic.Value(u8) = .init(0),
snap_mutex: std.Io.Mutex = .init,
/// Notes rewritten since the last publish, accumulated by whichever path did the writing and
/// drained by `commitAndPublish` into the snapshot it builds. Worker-thread only.
pending_dirty: std.ArrayListUnmanaged(i64) = .empty,
/// Notes a *full scan* rewrote, and whether it saw anything a scoped relink cannot describe.
/// Same distinction the incremental path keeps; see the relink decision in `runFullScan`.
scan_rewrote: std.ArrayListUnmanaged(i64) = .empty,
scan_structural: bool = false,
/// Set when the change cannot be described by `pending_dirty` alone — a full scan, a structural
/// edit, or a failure to record an id. Cleared on publish along with the list.
pending_broad: bool = true,

/// The candidate lists for the generation `commitAndPublish` is about to announce, waiting for the
/// UI thread to claim them. Written by the worker under `cand_mutex` *before* the generation bump,
/// so a UI thread that observes the new generation always finds the matching lists here.
///
/// Null once claimed. An unclaimed set is dropped when the next publish replaces it — nobody asked
/// for that generation's candidates, so nothing is lost by freeing them.
cand_handoff: ?CandidateSet = null,
cand_mutex: std.Io.Mutex = .init,
/// True from `start` until the worker has handed over its first set: "candidates are coming, don't
/// build your own". Without it the UI thread would run the expensive query itself during the one
/// window where the handoff is legitimately empty — the seconds between opening a vault and the
/// worker's first pass — which is the whole hitch, just moved to a rarer trigger.
cand_pending: std.atomic.Value(bool) = .init(false),

resolve_cache: ?ResolveCache = null,

/// Where a full scan's time went, logged when it finishes. Worker-thread only — no atomics, and
/// no reader outside `runFullScan`'s own summary.
///
/// This exists because every performance guess about this path has been wrong so far, and each
/// time a measurement found the real answer immediately. A scan that takes minutes should be able
/// to say which minutes.
timings: Timings = .{},
/// True only while `runFullScan` is running — see `markNs`.
timing: bool = false,

/// Markdown files a full scan's pre-pass found on disk. Read by the UI for "x of y" progress;
/// written only by the worker. Zero until the first full scan counts them.
scan_total: std.atomic.Value(u32) = .init(0),

pub const Timings = struct {
    prepass_ns: u64 = 0,
    /// Inside the walk, per file.
    stat_ns: u64 = 0,
    read_ns: u64 = 0,
    parse_ns: u64 = 0,
    write_ns: u64 = 0,
    walk_ns: u64 = 0,
    /// `dropMissing` + `dropMissingMedia`: reconciling the seen set against the database.
    /// Untimed until a scan that "hung for ten seconds after the counter stopped" turned out to
    /// be spending them here, between the last progress publish and the next phase.
    drop_ns: u64 = 0,
    relink_ns: u64 = 0,
    /// The one full snapshot build at the end.
    publish_ns: u64 = 0,
    files_read: u64 = 0,
    files_skipped: u64 = 0,

    pub fn reset(self: *Timings) void {
        self.* = .{};
    }
};

/// Clock reads are gated on a full scan actually running, for two reasons: the incremental edit
/// path runs on every save and does not need a clock in it, and `dvui.io` is only valid inside the
/// app — the headless tests drive `indexBuffer`/`writeNote` directly with their own `Io`, so an
/// ungated read there is a crash rather than a measurement.
pub fn markNs(self: *const Indexer) i96 {
    if (!self.timing) return 0;
    return threads.nowNs();
}

pub fn sinceNs(self: *const Indexer, from: i96) u64 {
    if (!self.timing or from == 0) return 0;
    const d = threads.nowNs() - from;
    return if (d > 0) @intCast(d) else 0;
}

/// One queued reindex: a vault-relative path to go and re-read.
///
/// It used to be able to carry *bytes* as well — a live editor buffer from
/// `Plugin.documentContentChanged`, so an unsaved edit reached the graph. That is gone on purpose:
/// those bytes arrive on a typing lull, and half a wikilink resolves to nothing and materialises a
/// phantom note for it, so indexing them filled the vault with debris. See `State.setDirtyContent`.
pub const Pending = struct {
    rel: []u8,

    fn deinit(self: Pending, gpa: std.mem.Allocator) void {
        gpa.free(self.rel);
    }
};

pub const Source = Scan.Source;

/// The generation counter's type: atomic where there are threads to race, a plain counter
/// on wasm32, whose atomics stop at 32 bits and whose one thread needs none.
pub const Generation = if (is_wasm) struct {
    raw: u64,
    pub fn init(v: u64) @This() {
        return .{ .raw = v };
    }
    pub fn load(self: *const @This(), _: std.builtin.AtomicOrder) u64 {
        return self.raw;
    }
    pub fn store(self: *@This(), v: u64, _: std.builtin.AtomicOrder) void {
        self.raw = v;
    }
    pub fn fetchAdd(self: *@This(), v: u64, _: std.builtin.AtomicOrder) u64 {
        const old = self.raw;
        self.raw += v;
        return old;
    }
} else std.atomic.Value(u64);

pub fn init(
    gpa: std.mem.Allocator,
    busy: *std.atomic.Value(bool),
    generation: *Generation,
) Indexer {
    return .{
        .gpa = gpa,
        .busy = busy,
        .generation = generation,
    };
}

/// Begin indexing `vault_root` (as the host names it) into `index`, reading through `source`.
/// Queues a full scan and starts the runner: on a thread when the source pumps itself (the
/// disk), from the frame otherwise (a mount, the web) — the caller then calls `pump` once a
/// frame. `vault_root` is borrowed for the life of the indexer (State owns it).
pub fn start(self: *Indexer, index: *Index, vault_root: []const u8, source: Source) !void {
    self.stop();
    self.index = index;
    self.vault_root = vault_root;
    self.source = source;
    self.quit.store(false, .release);

    // Raised here, on the UI thread, rather than by the task once it runs: between the start
    // and the first candidate build there is a window where the flag is the only thing telling
    // `State.ensureCandidates` that a set is coming, and if it reads `false` in that window it
    // runs the very query this exists to keep off the UI thread.
    self.cand_pending.store(true, .release);

    self.mutex.lockUncancelable(dvui.io);
    self.want_full = true;
    self.mutex.unlock(dvui.io);

    const mode: work.Mode = if (source.pump_self and !is_wasm) .thread else .pump;
    self.runner = work.Runner.init(self.gpa, dvui.io, nowNs, wakeHost);
    self.runner.?.start(self.task(), mode) catch |err| {
        // No runner means no publish means nothing to wait for.
        self.runner = null;
        self.cand_pending.store(false, .release);
        return err;
    };
}

const is_wasm = builtin.target.cpu.arch == .wasm32;

/// Whether the runner is alive — the caller's cue that `pump` is needed (or that `start` is).
pub fn running(self: *const Indexer) bool {
    return if (self.runner) |*r| r.running() else false;
}

/// `.pump` mode: give the task up to `budget_ns` of this frame. No-op for a threaded runner.
pub fn pump(self: *Indexer, budget_ns: i64) void {
    if (self.runner) |*r| _ = r.pump(budget_ns);
}

fn wakeHost() void {
    sdk.refresh();
}

/// The runner's clock — see `threads.nowNs`.
pub fn nowNs() i64 {
    return @intCast(threads.nowNs());
}

/// Stop the task and join it. Safe to call when never started.
pub fn stop(self: *Indexer) void {
    // The cache describes *this* vault's notes and is keyed to the index `index` points at.
    self.dropResolveCache();
    self.quit.store(true, .release);
    if (self.runner) |*r| {
        r.notify();
        r.stop();
        self.runner = null;
    }
    if (self.scan) |*sc| {
        sc.deinit();
        self.scan = null;
    }
    self.index = null;
    self.vault_root = "";
    self.source = null;
    self.busy.store(false, .release);
    // The worker is joined; whatever it was going to hand over, it isn't going to now.
    self.cand_pending.store(false, .release);
    self.scan_total.store(0, .release);

    // Drop the published snapshot. It describes the vault we just closed.
    //
    // Without this a vault *switch* serves the previous vault's graph to the next one, and serves
    // it as finished: `counts().complete` is still true, so the panel's "never build from an
    // incomplete snapshot" gate waves it straight through, `snapshotCopy` hands over the old
    // vault's nodes, and the graph rebuilds itself into exactly what it was already showing. The
    // symptom is a folder switch that appears to do nothing at all — no spinner, no progress, the
    // old map still on screen — for however long the new vault takes to scan.
    //
    // Safe to do here: `stop` has joined the worker above, and the only other reader is the UI
    // thread that called us.
    {
        self.snap_mutex.lockUncancelable(dvui.io);
        defer self.snap_mutex.unlock(dvui.io);
        for (&self.snap_arenas) |*slot| {
            if (slot.*) |*a| _ = a.reset(.free_all);
        }
        self.snapshots = .{ .{}, .{} };
        self.snap_pub.store(0, .release);
    }

    self.mutex.lockUncancelable(dvui.io);
    defer self.mutex.unlock(dvui.io);
    self.want_full = false;
    self.want_sweep = false;
    for (self.pending.items) |p| p.deinit(self.gpa);
    self.pending.clearRetainingCapacity();
}

pub fn deinit(self: *Indexer) void {
    self.stop();
    self.dropResolveCache();
    self.pending.deinit(self.gpa);
    self.pending_dirty.deinit(self.gpa);
    self.scan_rewrote.deinit(self.gpa);
    for (&self.snap_arenas) |*slot| {
        if (slot.*) |*a| a.deinit();
        slot.* = null;
    }
    self.snapshots = .{ .{}, .{} };
    // `stop` has joined the worker, so nothing can be publishing a new one behind this.
    if (self.cand_handoff) |*set| set.deinit();
    self.cand_handoff = null;
}

/// Queue a full rescan. Used by the rebuild command and by `start`.
pub fn requestFullScan(self: *Indexer) void {
    self.mutex.lockUncancelable(dvui.io);
    defer self.mutex.unlock(dvui.io);
    self.want_full = true;
    self.want_sweep = false;
    // A full scan supersedes any pending path work.
    for (self.pending.items) |p| p.deinit(self.gpa);
    self.pending.clearRetainingCapacity();
    self.notify();
}

/// Wake a parked task: there is work for it.
fn notify(self: *Indexer) void {
    if (self.runner) |*r| r.notify();
}

/// Ask for a quiet re-walk of the vault. Unlike `requestFullScan` this does not disturb queued
/// work and does not republish unless a file actually changed, so it can run on a timer without
/// rebuilding the graph — or re-running the relink — every tick.
pub fn requestSweep(self: *Indexer) void {
    self.mutex.lockUncancelable(dvui.io);
    defer self.mutex.unlock(dvui.io);
    if (self.want_full) return;
    self.want_sweep = true;
    self.notify();
}

/// Queue one vault-relative path for reindex (create/modify). Empty / non-md paths are ignored.
pub fn enqueue(self: *Indexer, rel_path: []const u8) void {
    self.enqueuePending(rel_path);
}

fn enqueuePending(self: *Indexer, rel_path: []const u8) void {
    if (!query.isMarkdownPath(rel_path)) return;
    const owned = self.gpa.dupe(u8, rel_path) catch return;
    const item: Pending = .{ .rel = owned };

    self.mutex.lockUncancelable(dvui.io);
    defer self.mutex.unlock(dvui.io);
    if (self.want_full) {
        item.deinit(self.gpa);
        return;
    }
    // Collapse repeats: a debounced typing run re-notifies the same note over and over, and
    // only the newest content matters. Without this a fast typist grows an unbounded queue of
    // whole-file copies that the worker then indexes one stale version at a time.
    for (self.pending.items) |*existing| {
        if (!std.mem.eql(u8, existing.rel, item.rel)) continue;
        existing.deinit(self.gpa);
        existing.* = item;
        self.notify();
        return;
    }
    self.pending.append(self.gpa, item) catch {
        item.deinit(self.gpa);
        return;
    };
    self.notify();
}

/// Queue a deletion. The note row (and its outbound links) go away; inbound edges keep their
/// phantoms so the graph still shows "N notes pointed here".
pub fn enqueueDelete(self: *Indexer, rel_path: []const u8) void {
    // Represented as a pending path; the worker distinguishes missing-on-disk as delete.
    self.enqueue(rel_path);
}

/// Footer numbers. No allocation, no borrowed slices — safe to call every frame.
pub fn counts(self: *Indexer) Counts {
    self.snap_mutex.lockUncancelable(dvui.io);
    defer self.snap_mutex.unlock(dvui.io);
    const s = self.snapshots[self.snap_pub.load(.acquire)];
    return .{
        .note_count = s.note_count,
        .link_count = s.link_count,
        .phantom_count = s.phantom_count,
        .complete = s.complete,
        .scan_total = s.scan_total,
        .phase = s.phase,
    };
}

/// Publish an in-memory graph (scale synth) into the snapshot ring and bump `generation`.
/// Safe with the worker stopped and `db == null` — used by **Atlas: Load Synth Graph**.
///
/// `nodes`/`edges` are copied into the ring arena (including path/title strings). Call from the
/// UI thread only.
pub fn publishSynthetic(
    self: *Indexer,
    nodes: []const SnapNode,
    edges: []const SnapEdge,
) !void {
    const next: u8 = (self.snap_pub.load(.acquire) + 1) & 1;
    {
        self.snap_mutex.lockUncancelable(dvui.io);
        defer self.snap_mutex.unlock(dvui.io);
        if (self.snap_arenas[next] == null) {
            self.snap_arenas[next] = std.heap.ArenaAllocator.init(self.gpa);
        } else {
            _ = self.snap_arenas[next].?.reset(.free_all);
            self.snapshots[next] = .{};
        }
    }
    const arena = self.snap_arenas[next].?.allocator();

    const out_nodes = try arena.alloc(SnapNode, nodes.len);
    for (nodes, out_nodes) |s, *d| {
        d.* = s;
        d.path = try arena.dupe(u8, s.path);
        d.title = try arena.dupe(u8, s.title);
    }
    const out_edges = try arena.dupe(SnapEdge, edges);

    var note_count: u32 = 0;
    var phantom_count: u32 = 0;
    for (out_nodes) |n| {
        if (n.phantom) phantom_count += 1 else note_count += 1;
    }

    const snap = Snapshot{
        .note_count = note_count,
        .link_count = @intCast(out_edges.len),
        .phantom_count = phantom_count,
        .nodes = out_nodes,
        .edges = out_edges,
        // A synthetic graph arrives whole, with its edges already pointing at real node ids.
        // There is no walk and no relink pass to wait for.
        .complete = true,
    };

    self.snap_mutex.lockUncancelable(dvui.io);
    self.snapshots[next] = snap;
    self.snap_mutex.unlock(dvui.io);
    self.snap_pub.store(next, .release);
    _ = self.generation.fetchAdd(1, .release);
    self.busy.store(false, .release);
}

/// Deep-copy the published snapshot into `arena`, so the caller owns every byte it walks.
///
/// The copy happens under `snap_mutex`, which is also what `commitAndPublish` takes around the
/// arena reset that recycles a slot — that mutual exclusion is the whole reason this is safe.
/// Returning the borrowed slices instead (the old `snapshot`) is a use-after-free the moment a
/// caller holds them longer than two commits, and a graph rebuild on a large vault does.
///
/// O(nodes + edges) plus the strings. Call it once per rebuild, not once per frame.
pub fn snapshotCopy(self: *Indexer, arena: std.mem.Allocator) !Snapshot {
    self.snap_mutex.lockUncancelable(dvui.io);
    defer self.snap_mutex.unlock(dvui.io);
    const src = self.snapshots[self.snap_pub.load(.acquire)];

    // One allocation for every string, not two per note.
    //
    // `dupe` per path and per title is 568,000 allocations on a 284k-note vault, every rebuild, on
    // the UI thread — and the strings are read-only for the life of the copy, so there is nothing
    // the separate allocations buy. Sizing one block and slicing it is the same bytes with the
    // allocator called once.
    var text_len: usize = 0;
    for (src.nodes) |s| text_len += s.path.len + s.title.len;
    const text = try arena.alloc(u8, text_len);
    var at: usize = 0;

    const nodes = try arena.alloc(SnapNode, src.nodes.len);
    for (src.nodes, nodes) |s, *d| {
        d.* = s;
        @memcpy(text[at..][0..s.path.len], s.path);
        d.path = text[at..][0..s.path.len];
        at += s.path.len;
        @memcpy(text[at..][0..s.title.len], s.title);
        d.title = text[at..][0..s.title.len];
        at += s.title.len;
    }
    const edges = try arena.dupe(SnapEdge, src.edges);

    return .{
        .note_count = src.note_count,
        .link_count = src.link_count,
        .phantom_count = src.phantom_count,
        .nodes = nodes,
        .edges = edges,
        .complete = src.complete,
        .scan_total = src.scan_total,
        .phase = src.phase,
        .dirty = try arena.dupe(i64, src.dirty),
        .dirty_known = src.dirty_known,
        .edges_same = src.edges_same,
    };
}

/// The facts a layout rebuild needs to choose a path, without copying the snapshot.
pub fn peekLayout(self: *Indexer) LayoutPeek {
    self.snap_mutex.lockUncancelable(dvui.io);
    defer self.snap_mutex.unlock(dvui.io);
    const src = self.snapshots[self.snap_pub.load(.acquire)];
    return .{
        .dirty_known = src.dirty_known,
        .edges_same = src.edges_same,
        .complete = src.complete,
        .node_n = src.nodes.len,
        .dirty_n = src.dirty.len,
    };
}

/// Deep-copy the dirty notes (and only those) into `arena`.
pub fn copyDirtyNotes(self: *Indexer, arena: std.mem.Allocator) ![]SnapNode {
    self.snap_mutex.lockUncancelable(dvui.io);
    defer self.snap_mutex.unlock(dvui.io);
    const src = self.snapshots[self.snap_pub.load(.acquire)];
    if (src.dirty.len == 0 or src.nodes.len == 0) return &.{};

    var want = std.AutoHashMap(i64, void).init(arena);
    try want.ensureTotalCapacity(@intCast(src.dirty.len));
    for (src.dirty) |id| try want.put(id, {});

    var out: std.ArrayList(SnapNode) = .empty;
    try out.ensureTotalCapacity(arena, src.dirty.len);
    for (src.nodes) |s| {
        if (!want.contains(s.id)) continue;
        var d = s;
        d.path = try arena.dupe(u8, s.path);
        d.title = try arena.dupe(u8, s.title);
        out.appendAssumeCapacity(d);
    }
    return out.toOwnedSlice(arena);
}

// -- the task ---------------------------------------------------------------------
//
// One long-lived task: a pass in progress is stepped; otherwise the queue is checked — a full
// scan or a sweep starts a `Scan` over the vault, queued paths start a scoped one — and with
// nothing to do the task parks (`waiting`: the thread until `notify`, the frame until next
// time).

fn task(self: *Indexer) work.Task {
    return .{ .ctx = self, .vtable = &task_vtable };
}
const task_vtable: work.Task.VTable = .{ .step = taskStep, .cancel = taskCancel };
fn taskStep(ctx: *anyopaque, deadline_ns: i64) work.Status {
    const self: *Indexer = @ptrCast(@alignCast(ctx));
    return self.step(deadline_ns);
}
fn taskCancel(ctx: *anyopaque) void {
    const self: *Indexer = @ptrCast(@alignCast(ctx));
    self.quit.store(true, .release);
}

fn step(self: *Indexer, deadline_ns: i64) work.Status {
    if (self.quit.load(.acquire)) return .done;
    if (self.scan) |*sc| {
        const st = sc.step(deadline_ns);
        if (st != .done) return st;
        sc.deinit();
        self.scan = null;
        // The wake has to come *after* `busy` clears, not before: a refresh issued while the
        // flag is still set paints one more "indexing" frame and then the app idles with a
        // spinner that never goes away.
        self.busy.store(false, .release);
        sdk.refresh();
        return .more;
    }

    self.mutex.lockUncancelable(dvui.io);
    const do_full = self.want_full;
    self.want_full = false;
    if (do_full) self.want_sweep = false;
    // A sweep yields to queued work: a pending item may describe a newer state of a note than
    // the disk walk would, so the queue drains first; `want_sweep` stays set.
    const do_sweep = !do_full and self.want_sweep and self.pending.items.len == 0;
    if (do_sweep) self.want_sweep = false;
    const batch = if (!do_full and !do_sweep and self.pending.items.len != 0)
        self.pending.toOwnedSlice(self.gpa) catch null
    else
        null;
    self.mutex.unlock(dvui.io);

    const source = self.source orelse return .waiting;
    if (do_full or do_sweep) {
        // A sweep is speculative and usually finds nothing. Raising `busy` for it would blink
        // the sidebar's indexing state every 15s, and refreshing would wake an idle app to
        // repaint an identical frame — so a quiet sweep announces nothing at all.
        if (!do_sweep) {
            self.busy.store(true, .release);
            sdk.refresh();
        }
        self.scan = Scan.init(self, source, if (do_full) .always else .if_changed);
        self.scan.?.begin() catch |err| {
            log.err("scan: {s}", .{@errorName(err)});
            self.scan.?.deinit();
            self.scan = null;
            self.busy.store(false, .release);
            return .more;
        };
        return .more;
    }
    if (batch) |items| {
        // The paths only; the pending records are theirs to free.
        const rels = self.gpa.alloc([]u8, items.len) catch {
            for (items) |p| p.deinit(self.gpa);
            self.gpa.free(items);
            return .more;
        };
        for (items, rels) |p, *r| r.* = p.rel;
        self.gpa.free(items);
        self.busy.store(true, .release);
        sdk.refresh();
        self.scan = Scan.initTargets(self, source, rels);
        self.scan.?.begin() catch |err| {
            log.err("scan: {s}", .{@errorName(err)});
            self.scan.?.deinit();
            self.scan = null;
            self.busy.store(false, .release);
        };
        return .more;
    }
    return .waiting;
}

/// A full pass, run to completion on this thread: the bench and the tests, with a `Source`
/// that pumps itself. `io` is unused now that the source carries its own; kept so the
/// harness's call sites read as they did.
pub fn runFullScan(self: *Indexer, io: std.Io, mode: Scan.Mode) !void {
    _ = io;
    const source = self.source orelse return error.NoSource;
    var sc = Scan.init(self, source, mode);
    defer sc.deinit();
    try sc.begin();
    try sc.runBlocking();
}

/// One queued path, run to completion on this thread (tests). The same scoped scan the task
/// starts for a batch of saves.
pub fn indexOne(self: *Indexer, io: std.Io, rel: []const u8) !void {
    _ = io;
    const source = self.source orelse return error.NoSource;
    const rels = try self.gpa.alloc([]u8, 1);
    rels[0] = try self.gpa.dupe(u8, rel);
    var sc = Scan.initTargets(self, source, rels);
    defer sc.deinit();
    try sc.begin();
    try sc.runBlocking();
}

/// What indexing one queued item did, so the caller knows both *whether* to relink and *how
/// narrowly* it may. Worth the bookkeeping now that live buffers queue a reindex every ~300ms of
/// typing rather than once per 2s poll: a save re-sends bytes we already indexed, and republishing
/// that would re-query every note and edge for nothing.
pub const IndexOutcome = union(enum) {
    /// Nothing the graph reads moved.
    unchanged,
    /// This note's rows were rewritten and its links need resolving. Only its own — see
    /// `relinkNote`.
    rewrote: i64,
    /// A note appeared or vanished. Other notes' links may now resolve somewhere else (a phantom
    /// became real, or a real note became a phantom), so nothing narrower than `relinkAll` is
    /// correct here.
    structural,
};

/// Index a note from bytes rather than from disk, stamping `mtime_ns = 0` so the disk path's
/// mtime/size early-out can never mistake the row for up to date — a later real read of the file
/// finds the same content hash and just refreshes the metadata.
///
/// No production caller: the app indexes saved files, never live buffers (see `Pending`). This is
/// the byte-level write path that `writeNote` and the relink hang off, kept as the entry point the
/// headless tests and `bench --index-edit` drive, since both need to write a note without one
/// existing on disk.
pub fn indexBuffer(self: *Indexer, rel: []const u8, bytes: []const u8) !IndexOutcome {
    const index = self.index orelse return .unchanged;
    const hash: i64 = @bitCast(std.hash.XxHash3.hash(0, bytes));
    const known = lookupNoteMetaIn(index, rel);
    if (known) |meta| {
        // Same content we already hold — the usual case for the save that follows a typing
        // lull we already indexed.
        if (meta.hash == hash) return .unchanged;
    }
    const has_aliases = try self.writeNote(index, rel, bytes, 0, @intCast(bytes.len), hash);
    // A buffer for a note we already had is the interactive case, and the only thing it can have
    // changed is that note's own links. A buffer for a note we had never seen is a new node in the
    // graph, which other notes' links may have been waiting on as a phantom.
    //
    // Aliases make it structural too, and that is the price of `ResolveCache`: an alias is a *name
    // other notes resolve against*, so a note that declares one can change where links elsewhere
    // point, and the cached candidate list would keep answering with the old names. Conservative on
    // purpose — this fires whenever the note has any alias, not only when one changed — because
    // front-matter aliases are rare enough that the common edit stays on the fast path.
    if (known == null or has_aliases) return .structural;
    return .{ .rewrote = (lookupNoteMetaIn(index, rel) orelse return .structural).id };
}

/// One file the scan has decided it must read, from the size and time it already had.
pub const ReadAhead = struct {
    rel: []const u8,
    mtime_ns: i64,
    size: i64,
    known_id: i64,
    known_hash: i64,
    had_known: bool,
};

/// The half that writes: hash the bytes, and store the note if they differ from what we had.
pub fn applyFile(self: *Indexer, it: ReadAhead, bytes: []const u8) !IndexOutcome {
    const index = self.index orelse return .unchanged;
    const hash: i64 = @bitCast(std.hash.XxHash3.hash(0, bytes));
    if (it.had_known and it.known_hash == hash) {
        // Metadata catch-up only — this is the save landing on a buffer we already indexed
        // (which stamped `mtime_ns = 0`). Nothing the graph draws moved.
        index.lock();
        defer index.unlock();
        index.touchNote(it.known_id, it.mtime_ns, it.size);
        return .unchanged;
    }
    const has_aliases = try self.writeNote(index, it.rel, bytes, it.mtime_ns, it.size, hash);
    // A file we already had: only its own links moved. A file we had not seen is a new node, and
    // links elsewhere may have been parked on a phantom waiting for it. Aliases are structural for
    // the reason spelled out in `indexBuffer`.
    if (!has_aliases and it.had_known) return .{ .rewrote = it.known_id };
    return .structural;
}

/// Scan `bytes` and replace every derived row for `rel`. Shared by the disk and live-buffer
/// paths so the two can't drift in what they record.
/// Returns whether this note declares any front-matter aliases — see `ResolveCache`, which the
/// caller must not keep across a note that does.
fn writeNote(self: *Indexer, index: *Index, rel: []const u8, bytes: []const u8, mtime_ns: i64, size: i64, hash: i64) !bool {
    var arena = std.heap.ArenaAllocator.init(self.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const parse_start = self.markNs();
    const note = try Scanner.scan(a, bytes);
    self.timings.parse_ns += self.sinceNs(parse_start);

    const write_start = self.markNs();
    defer self.timings.write_ns += self.sinceNs(write_start);

    // The parser's rows in the store's shape. Same fields; the store folds the strings itself.
    const headings = try a.alloc(Index.HeadingIn, note.headings.len);
    for (note.headings, headings) |h, *o| o.* = .{ .text = h.text, .level = h.level, .line = h.line };
    const tags = try a.alloc(Index.TagIn, note.tags.len);
    for (note.tags, tags) |t, *o| o.* = .{ .tag = t.tag, .line = t.line };
    const blocks = try a.alloc(Index.Block, note.blocks.len);
    for (note.blocks, blocks) |b, *o| o.* = .{ .kind = b.kind, .line_start = b.line_start, .line_end = b.line_end, .weight = b.weight };
    // Links are written pointing at the source itself; `relinkAll` resolves them once every
    // note is present (so a forward link to a file later in the walk still resolves).
    const links = try a.alloc(Index.LinkIn, note.links.len);
    for (note.links, links) |l, *o| o.* = .{ .raw = l.raw, .heading = l.heading, .alias = l.alias, .kind = l.kind, .line = l.line, .col = l.col };

    index.lock();
    defer index.unlock();
    const note_id = try index.upsertNote(.{
        .path = rel,
        .stem = query.stemOf(rel),
        .title = note.title,
        .mtime_ns = mtime_ns,
        .size = size,
        .hash = hash,
    });
    try index.setDerived(note_id, .{
        .aliases = note.aliases,
        .headings = headings,
        .tags = tags,
        .blocks = blocks,
        .links = links,
    });
    return note.aliases.len > 0;
}

pub fn logTimings(self: *const Indexer) void {
    const t = self.timings;
    const ms = struct {
        fn f(ns: u64) f64 {
            return @as(f64, @floatFromInt(ns)) / 1e6;
        }
    }.f;
    log.debug(
        "scan: {d} read, {d} unchanged | prepass {d:.0}ms  walk {d:.0}ms " ++
            "(stat {d:.0}  read {d:.0}  parse {d:.0}  db {d:.0})  drop {d:.0}ms  " ++
            "relink {d:.0}ms  publish {d:.0}ms",
        .{
            t.files_read,     t.files_skipped,
            ms(t.prepass_ns), ms(t.walk_ns),
            ms(t.stat_ns),    ms(t.read_ns),
            ms(t.parse_ns),   ms(t.write_ns),
            ms(t.drop_ns),    ms(t.relink_ns),
            ms(t.publish_ns),
        },
    );
}

/// Public only so the headless harness (`bench --index-edit`) can time one incremental edit the
/// way the worker performs it.
pub fn relinkAll(self: *Indexer) !void {
    _ = try self.relinkScope(null);
}

/// Resolve just one note's outbound links.
///
/// What an edit actually changes is the links of the note that was edited, and `relinkAll` answers
/// that by re-resolving **every link in the vault** — 3.35M of them on the reference corpus, to
/// discover what one note points at. That is why an edit appeared to do nothing: the next debounce
/// fires long before the previous pass finishes, so the graph never catches up while anyone is
/// actually typing.
///
/// The narrowing is not free of consequences and the boundary is worth stating. Resolution reads
/// the *whole* candidate set, so this still sees every note — a link to a note someone else created
/// resolves correctly. What it does not do is re-resolve **other** notes' links, so if this edit
/// changed the note's own title or aliases, links elsewhere that should now point here keep their
/// old destinations until the background sweep's `relinkAll` catches them. That is the right trade
/// for an interactive path: the edit you are making resolves immediately, and the rarer case of an
/// alias changing where *other* documents point settles a few seconds later.
pub fn relinkNote(self: *Indexer, note_id: i64) !bool {
    return self.relinkScope(note_id);
}

pub fn dropResolveCache(self: *Indexer) void {
    if (self.resolve_cache) |*c| c.deinit(self.gpa);
    self.resolve_cache = null;
}

/// The resolution inputs for the current note set, building them if they are not already held.
///
/// `rebuild` forces a fresh read — what `relinkAll` passes, since it is only ever reached when
/// something structural happened and the cached set is exactly what can no longer be trusted.
fn ensureResolveCache(self: *Indexer, index: *Index, rebuild: bool) !*ResolveCache {
    if (rebuild) self.dropResolveCache();
    if (self.resolve_cache) |*c| return c;

    var arena = std.heap.ArenaAllocator.init(self.gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    const candidates = try loadCandidates(index, a);
    // Built once for the whole relink: without it the resolve loop is one linear scan of every
    // note per link, which is the single most expensive thing the indexer does on a large vault.
    var idx = try resolve.Index.init(self.gpa, candidates);
    errdefer idx.deinit();

    self.resolve_cache = .{ .arena = arena, .candidates = candidates, .index = idx };
    return &self.resolve_cache.?;
}

/// Every real note as a resolution candidate, plus one entry per alias — the list
/// `resolve.resolve` matches against. Strings are copied into `arena`, so the caller may keep
/// the list after the lock is released. Takes the index lock.
pub fn loadCandidates(index: *Index, arena: std.mem.Allocator) ![]resolve.Candidate {
    index.lock();
    defer index.unlock();
    var list: std.ArrayList(resolve.Candidate) = .empty;
    try list.ensureTotalCapacity(arena, index.real_count);
    var it = index.iterate(false);
    while (it.next()) |n| {
        const path = try arena.dupe(u8, n.path);
        const stem = try arena.dupe(u8, n.stem);
        try list.append(arena, .{ .path = path, .stem = stem });
        for (n.aliases) |al| {
            try list.append(arena, .{ .path = path, .stem = stem, .alias = try arena.dupe(u8, al.alias) });
        }
    }
    return list.toOwnedSlice(arena);
}

/// Media files as resolution candidates, two per file (stem and full name) — see
/// `query.loadMediaCandidates`. Takes the index lock.
pub fn loadMediaCandidates(index: *Index, arena: std.mem.Allocator) ![]resolve.Candidate {
    index.lock();
    defer index.unlock();
    var list: std.ArrayList(resolve.Candidate) = .empty;
    var it = index.iterateMedia();
    while (it.next()) |m| {
        const path = try arena.dupe(u8, m.path);
        const stem = try arena.dupe(u8, m.stem);
        try list.append(arena, .{ .path = path, .stem = stem });
        const name = std.fs.path.basenamePosix(path);
        if (!std.mem.eql(u8, name, stem)) try list.append(arena, .{ .path = path, .stem = name });
    }
    return list.toOwnedSlice(arena);
}

/// Notes per lock hold in a full relink: long enough to amortise the lock, short enough that a
/// UI query never waits more than a moment.
const relink_chunk: usize = 2_000;

/// Resolve the links of one note (`only_src`) or of every note. Returns whether the note set
/// grew — see `Index.ensurePhantom`.
fn relinkScope(self: *Indexer, only_src: ?i64) !bool {
    const index = self.index orelse return false;
    var made_phantom = false;
    if (only_src) |src| {
        const cache = try self.ensureResolveCache(index, false);
        var buf: [resolve.max_path_len]u8 = undefined;
        index.lock();
        defer index.unlock();
        try self.relinkOne(index, src, cache, &buf, &made_phantom);
        _ = index.purgePhantoms(resolve.isNoteLikeTarget);
        return made_phantom;
    }
    self.dropResolveCache();
    var id: i64 = 1;
    var done: u32 = 0;
    while (!try self.relinkChunk(&id, &done, &made_phantom)) {
        if (self.quit.load(.acquire)) return made_phantom;
    }
    return made_phantom;
}

/// One chunk of a full relink: `relink_chunk` notes from `cursor` on, the index lock held for
/// the chunk. Returns true when the pass is complete (and the phantoms purged). Ids are dense
/// and stable, so the cursor is a counter; phantoms appended along the way have no links and
/// need no visit.
pub fn relinkChunk(self: *Indexer, cursor: *i64, done: *u32, made_phantom: *bool) !bool {
    const index = self.index orelse return true;
    const cache = try self.ensureResolveCache(index, false);
    var buf: [resolve.max_path_len]u8 = undefined;
    index.lock();
    defer index.unlock();
    const end = index.notes.items.len;
    var in_chunk: usize = 0;
    while (cursor.* <= end and in_chunk < relink_chunk) : ({
        cursor.* += 1;
        in_chunk += 1;
    }) {
        if (index.live(cursor.*) == null) continue;
        try self.relinkOne(index, cursor.*, cache, &buf, made_phantom);
    }
    done.* += @intCast(in_chunk);
    if (cursor.* <= end) {
        self.publishProgress(.resolving, done.*, @intCast(end));
        sdk.refresh();
        return false;
    }
    _ = index.purgePhantoms(resolve.isNoteLikeTarget);
    return true;
}

/// Resolve every link of `src`. Index locked by the caller.
fn relinkOne(self: *Indexer, index: *Index, src: i64, cache: *ResolveCache, buf: []u8, made_phantom: *bool) !void {
    _ = self;
    // Backwards, so removing a non-note target keeps the indices ahead of it valid. The note is
    // fetched per link: creating a phantom appends to the note array, which can move it.
    var i: usize = (index.live(src) orelse return).links.len;
    while (i > 0) {
        i -= 1;
        const n = index.live(src) orelse return;
        const l = n.links[i];
        // Drop edges that never should have been notes (e.g. `[x](foo.zig)` from older scans).
        if (!resolve.isNoteLikeTarget(l.raw)) {
            index.removeLink(src, i);
            continue;
        }
        const match = resolve.resolveIndexed(l.raw, n.path, cache.candidates, &cache.index, buf);
        const dst: i64 = if (match) |m|
            index.idByPath(cache.candidates[m.index].path) orelse try ensurePhantom(index, l.raw, made_phantom)
        else
            try ensurePhantom(index, l.raw, made_phantom);
        const ambiguous = if (match) |m| m.ambiguous else false;
        try index.setLinkDst(src, i, dst, ambiguous);
    }
}

/// Record one media file by path. No read, no hash — an attachment has no contents the index
/// cares about, only a name to resolve `![[…]]` against.
pub fn upsertMedia(self: *Indexer, rel: []const u8) !void {
    const index = self.index orelse return;
    index.lock();
    defer index.unlock();
    try index.upsertMedia(rel);
}

/// Returns true if anything was dropped.
pub fn dropMissingMedia(self: *Indexer, seen: *std.StringHashMapUnmanaged(void)) !bool {
    return self.dropMissingRows(.media, seen);
}

/// Rows whose file is gone from disk, deleted in interruptible chunks.
///
/// Callers must have established that `seen` describes a *complete* walk — see `runFullScan`.
/// The chunk boundary is where cancellation lands, so `stop()` never blocks the UI thread behind
/// the deletion of most of a vault.
fn dropMissingRows(
    self: *Indexer,
    comptime kind: enum { note, media },
    seen: *std.StringHashMapUnmanaged(void),
) !bool {
    const index = self.index orelse return false;

    var to_delete: std.ArrayList(i64) = .empty;
    defer to_delete.deinit(self.gpa);
    {
        index.lock();
        defer index.unlock();
        switch (kind) {
            .note => {
                var it = index.iterate(false);
                while (it.next()) |n| if (!seen.contains(n.path)) try to_delete.append(self.gpa, n.id);
            },
            .media => {
                var it = index.iterateMedia();
                while (it.next()) |m| if (!seen.contains(m.path)) try to_delete.append(self.gpa, m.id);
            },
        }
    }
    if (to_delete.items.len == 0) return false;
    if (self.quit.load(.acquire)) return false;

    var i: usize = 0;
    while (i < to_delete.items.len) {
        index.lock();
        const end = @min(i + drop_chunk, to_delete.items.len);
        while (i < end) : (i += 1) {
            switch (kind) {
                .note => try index.retireNote(to_delete.items[i]),
                .media => index.deleteMedia(to_delete.items[i]),
            }
        }
        index.unlock();
        // Consistent here: the rows either went or did not.
        if (self.quit.load(.acquire)) return true;
    }
    return true;
}

/// Deletes per lock hold in `dropMissingRows`.
const drop_chunk: usize = 20_000;

/// Returns true if anything was dropped.
pub fn dropMissing(self: *Indexer, seen: *std.StringHashMapUnmanaged(void)) !bool {
    return self.dropMissingRows(.note, seen);
}

/// Publish a *progress* snapshot: the note count, and nothing else.
///
/// This used to go through `commitAndPublish`, which materializes the whole graph — every note
/// with a correlated `UNION` subquery for its degree, every edge, and an arena copy of every path
/// and title string. During a scan that runs every `batch_files`/`batch_ns`, so the cost of a full
/// read is **quadratic** in the note count: at 284k notes and a publish every 200 files, roughly
/// 4×10⁸ correlated subqueries, which is the difference between minutes and hours.
///
/// And none of it was ever read. The only consumer of a snapshot's nodes and edges is the graph
/// panel's rebuild, which now refuses mid-scan snapshots outright (see `Snapshot.complete`);
/// everything else — the footer, the backlinks pane — takes `counts()`. So the walker hands over
/// the number it already has and the graph is built exactly once, at the end.
pub fn publishProgress(self: *Indexer, phase: Phase, done: u32, total: u32) void {
    const next: u8 = (self.snap_pub.load(.acquire) + 1) & 1;
    {
        self.snap_mutex.lockUncancelable(dvui.io);
        defer self.snap_mutex.unlock(dvui.io);
        if (self.snap_arenas[next]) |*a| {
            _ = a.reset(.free_all);
        }
        self.snapshots[next] = .{
            .note_count = done,
            .complete = false,
            .scan_total = total,
            .phase = phase,
        };
    }
    self.snap_pub.store(next, .release);

    // Deliberately **not** a `generation` bump.
    //
    // `generation` means "the note data changed, throw away anything derived from it". A progress
    // snapshot carries no note data at all — only how far the scan has got — so bumping it here
    // invalidates caches that are still perfectly valid. `State.ensureCandidates` is the one that
    // hurts: it holds every note's path and stem, keyed on `generation`, and the markdown preview
    // resolves *every wikilink it renders* through it. Ticking generation four times a second
    // meant a 283,878-row table scan per wikilink per frame, which froze the app outright while a
    // scan ran — and the CPU sample of that freeze pointed at the preview, nowhere near the
    // indexer that caused it.
    //
    // The UI still needs to *repaint* to show the new number; that is `sdk.refresh`, which is a
    // different thing and is the caller's job — this runs headlessly in tests, where there is no
    // host to refresh.
}

/// The real publish, after `relinkAll` has resolved every link against the final note set. Always
/// marks the snapshot complete — a caller that has not relinked wants `publishProgress`.
/// Public for the headless harness — see `relinkAll`.
pub fn commitAndPublish(self: *Indexer) !void {
    const index = self.index orelse return;
    // Building the snapshot is a full read of every note and every link — seconds on a large
    // vault, and pure waste if the vault is being closed. The UI thread is joining this worker.
    if (self.quit.load(.acquire)) return;

    // A scoped edit already has a complete snapshot in the ring. Patch that slot in place
    // rather than rebuilding every node and every edge — the common save is one note's title
    // and body, and walking 284k rows to republish it is the hitch the graph then has to skip
    // a second time.
    const dirty_known = !self.pending_broad;
    if (dirty_known) {
        if (try self.tryPatchPublished(index, self.pending_dirty.items)) {
            self.pending_dirty.clearRetainingCapacity();
            self.pending_broad = false;
            _ = self.generation.fetchAdd(1, .release);
            return;
        }
    }

    const next: u8 = (self.snap_pub.load(.acquire) + 1) & 1;

    // Recycling this slot frees the strings a reader may be part-way through copying, so the
    // reset is mutually exclusive with `snapshotCopy`. Only the reset needs the lock — the slot
    // is unpublished, so the loads below fill memory nobody can reach.
    {
        self.snap_mutex.lockUncancelable(dvui.io);
        defer self.snap_mutex.unlock(dvui.io);
        if (self.snap_arenas[next] == null) {
            self.snap_arenas[next] = std.heap.ArenaAllocator.init(self.gpa);
        } else {
            _ = self.snap_arenas[next].?.reset(.free_all);
            self.snapshots[next] = .{};
        }
    }
    const arena = self.snap_arenas[next].?.allocator();

    index.lock();
    const nodes = try loadSnapNodes(index, arena);
    const edges = try loadSnapEdges(index, arena);
    const note_count = index.real_count;
    const phantom_count = index.phantom_count;
    index.unlock();
    // Drained here rather than by the caller, so every path that publishes — incremental, full
    // scan, or a future one — gets the same accounting without having to remember to.
    const dirty = try arena.dupe(i64, self.pending_dirty.items);
    const known = !self.pending_broad;
    self.pending_dirty.clearRetainingCapacity();
    self.pending_broad = false;
    const snap = Snapshot{
        .note_count = note_count,
        .link_count = @intCast(edges.len),
        .phantom_count = phantom_count,
        .nodes = nodes,
        .edges = edges,
        .complete = true,
        .scan_total = self.scan_total.load(.acquire),
        .dirty = dirty,
        .dirty_known = known,
        .edges_same = false,
    };

    // Same trip through the notes table, one thread earlier.
    //
    // `State.ensureCandidates` used to run this query itself, on the UI thread, the first time the
    // markdown preview resolved a wikilink — which on a 286,547-note vault is the whole hitch on
    // opening the first document. The worker is already here, already reading every note, and has
    // nobody waiting on its frame budget, so it builds the lists and hands them over.
    //
    // Before the generation bump, deliberately: the bump is what tells the UI its cached lists are
    // stale, and it must not be able to see that and find nothing to replace them with.
    self.publishCandidates();

    self.snap_mutex.lockUncancelable(dvui.io);
    self.snapshots[next] = snap;
    self.snap_mutex.unlock(dvui.io);
    self.snap_pub.store(next, .release);

    _ = self.generation.fetchAdd(1, .release);
}

/// Build the candidate lists and park them for the UI thread. Worker-only.
///
/// Best-effort: a failure here leaves the handoff empty and `State.ensureCandidates` falls back to
/// querying for itself, which is slow but correct. Failing the publish over it would cost the
/// graph its snapshot for a list the UI can rebuild on its own.
pub fn publishCandidates(self: *Indexer) void {
    // Cleared whatever happens. A UI thread waiting on this flag must not wait forever because a
    // build failed or the vault closed underneath it.
    defer self.cand_pending.store(false, .release);
    const index = self.index orelse return;
    const set = self.buildCandidates(index, self.gpa) catch |err| {
        log.warn("build candidates: {s}", .{@errorName(err)});
        return;
    };
    self.cand_mutex.lockUncancelable(dvui.io);
    defer self.cand_mutex.unlock(dvui.io);
    if (self.cand_handoff) |*old| old.deinit();
    self.cand_handoff = set;
}

fn buildCandidates(self: *Indexer, index: *Index, gpa: std.mem.Allocator) !CandidateSet {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    // Copy the note list out of `ResolveCache` when it is warm rather than walking every note
    // again. The cache cannot simply be handed over: the UI takes ownership of a `CandidateSet`
    // and outlives any given publish, while the cache belongs to the worker and is dropped
    // whenever the note set moves.
    const notes = if (self.resolve_cache) |*c| dupeCandidates(a, c.candidates) catch |err| blk: {
        log.warn("copy cached candidates: {s}; re-reading", .{@errorName(err)});
        break :blk try loadCandidates(index, a);
    } else try loadCandidates(index, a);

    const media = try loadMediaCandidates(index, a);
    // `gpa`, not the set's arena: `Index` owns hash maps and an arena of its own and frees them
    // in `deinit`, which the arena's free-all would not reach.
    var idx = try resolve.Index.init(gpa, notes);
    errdefer idx.deinit();
    return .{ .notes = notes, .media = media, .arena = arena, .index = idx };
}

/// Deep-copy a candidate list into `a`. The strings are owned by the source arena, so a shallow
/// copy would hand the UI slices the worker frees the next time the note set changes.
fn dupeCandidates(a: std.mem.Allocator, src: []const resolve.Candidate) ![]const resolve.Candidate {
    const out = try a.alloc(resolve.Candidate, src.len);
    for (src, out) |in, *o| {
        // Every string field, not just the two obvious ones: `alias` is empty for most notes and a
        // borrowed slice for the rest, so missing it would dangle exactly on the vaults that use
        // front-matter aliases and nowhere else.
        o.* = .{
            .path = try a.dupe(u8, in.path),
            .stem = try a.dupe(u8, in.stem),
            .alias = try a.dupe(u8, in.alias),
        };
    }
    return out;
}

/// True while the worker owes the UI thread its first candidate set. A caller that finds nothing to
/// claim should keep the lists it has (empty, on a fresh vault) and ask again, rather than building
/// its own — see `cand_pending`.
pub fn candidatesPending(self: *const Indexer) bool {
    return self.cand_pending.load(.acquire);
}

/// Claim the candidate lists published alongside the current generation, or null if there are none
/// waiting (nothing published yet, or this generation's set was already taken). UI-thread only.
///
/// The caller owns what it gets back and must `deinit` it.
pub fn takeCandidates(self: *Indexer) ?CandidateSet {
    self.cand_mutex.lockUncancelable(dvui.io);
    defer self.cand_mutex.unlock(dvui.io);
    const set = self.cand_handoff;
    self.cand_handoff = null;
    return set;
}

/// Patch the published snapshot in place for a prose save. Returns false when the change cannot
/// be described that way — no complete snapshot yet, a note appeared or vanished, a dirty id the
/// snapshot does not know, or *any* link changed — and the caller then takes the full reload.
///
/// Deliberately limited to saves that leave the edge array alone. Splicing a note's rows into the
/// published edge list was tried: the list lives in that slot's arena, which is only recycled by a
/// full publish, so every link edit added another copy of all 3.3M rows — tens of megabytes a
/// save, for the length of the session. A link save has to re-solve the whole layout anyway
/// (seconds), so the ~180 ms reload it falls back to is not the cost worth that.
///
/// Nothing is written until every check has passed, so a `false` return leaves the published
/// snapshot exactly as it was rather than half-patched.
///
/// Holds `snap_mutex` for the whole patch so a concurrent `snapshotCopy` either sees the previous
/// generation or the patched one, never a half-written slot.
fn tryPatchPublished(self: *Indexer, index: *Index, dirty_ids: []const i64) !bool {
    const pub_i = self.snap_pub.load(.acquire);
    self.snap_mutex.lockUncancelable(dvui.io);
    defer self.snap_mutex.unlock(dvui.io);

    const snap = &self.snapshots[pub_i];
    if (!snap.complete or snap.nodes.len == 0) return false;
    if (self.snap_arenas[pub_i] == null) return false;
    const arena = self.snap_arenas[pub_i].?.allocator();

    var scratch_state = std.heap.ArenaAllocator.init(self.gpa);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();

    index.lock();
    defer index.unlock();
    if (index.real_count + index.phantom_count != snap.nodes.len) return false;

    // `loadSnapNodes` orders by id, so a dirty note is a binary search rather than a hash map
    // built over the whole vault on every save. A snapshot that is not sorted (a synthetic
    // publish) simply fails the lookup and takes the full reload.
    const at = try scratch.alloc(usize, dirty_ids.len);
    for (dirty_ids, at) |id, *slot| slot.* = indexOfId(snap.nodes, id) orelse return false;

    if (dirty_ids.len == 0) {
        snap.dirty = &.{};
        snap.dirty_known = true;
        snap.edges_same = true;
        snap.phase = .idle;
        return true;
    }

    if (!try outboundUnchanged(index, scratch, snap.edges, dirty_ids)) return false;

    // Load every replacement row before installing any of them, so a note that vanished between
    // the write and this read cannot leave half the dirty set patched.
    const fresh = try scratch.alloc(SnapNode, dirty_ids.len);
    for (dirty_ids, fresh) |id, *slot| {
        slot.* = (try loadOneSnapNode(index, arena, id)) orelse return false;
    }
    const nodes = @constCast(snap.nodes);
    for (at, fresh) |idx, row| nodes[idx] = row;

    snap.dirty = try arena.dupe(i64, dirty_ids);
    snap.dirty_known = true;
    snap.edges_same = true;
    snap.phase = .idle;
    return true;
}

/// Index of `id` in an id-sorted node array, or null when it is absent or the array is not sorted.
fn indexOfId(nodes: []const SnapNode, id: i64) ?usize {
    var lo: usize = 0;
    var hi: usize = nodes.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const at = nodes[mid].id;
        if (at == id) return mid;
        if (at < id) lo = mid + 1 else hi = mid;
    }
    return null;
}

fn snapNodeOf(n: *const Index.Note, arena: std.mem.Allocator) !SnapNode {
    return .{
        .id = n.id,
        .path = try arena.dupe(u8, n.path),
        .title = try arena.dupe(u8, n.shownTitle()),
        .phantom = n.phantom,
        .degree = 0,
        .size = @intCast(@max(n.size, 0)),
    };
}

/// Index locked by the caller.
fn loadOneSnapNode(index: *Index, arena: std.mem.Allocator, id: i64) !?SnapNode {
    const n = index.live(id) orelse return null;
    return try snapNodeOf(n, arena);
}

/// Index locked by the caller.
fn outboundUnchanged(
    index: *Index,
    arena: std.mem.Allocator,
    edges: []const SnapEdge,
    dirty_ids: []const i64,
) !bool {
    var dirty = std.AutoHashMap(i64, void).init(arena);
    try dirty.ensureTotalCapacity(@intCast(dirty_ids.len));
    for (dirty_ids) |id| try dirty.put(id, {});

    var old_n = std.AutoHashMap(i64, u32).init(arena);
    var old_h = std.AutoHashMap(i64, u64).init(arena);
    try old_n.ensureTotalCapacity(@intCast(dirty_ids.len));
    try old_h.ensureTotalCapacity(@intCast(dirty_ids.len));
    for (dirty_ids) |id| {
        try old_n.put(id, 0);
        try old_h.put(id, 0);
    }
    for (edges) |e| {
        if (!dirty.contains(e.src_id)) continue;
        const n = old_n.getPtr(e.src_id).?;
        const h = old_h.getPtr(e.src_id).?;
        n.* += 1;
        h.* +%= mix64(@as(u64, @bitCast(e.dst_id)));
    }

    for (dirty_ids) |id| {
        var n: u32 = 0;
        var h: u64 = 0;
        if (index.live(id)) |note| {
            for (note.links) |l| {
                n += 1;
                h +%= mix64(@as(u64, @bitCast(l.dst_id)));
            }
        }
        if (n != (old_n.get(id) orelse 0)) return false;
        if (h != (old_h.get(id) orelse 0)) return false;
    }
    return true;
}

fn mix64(v: u64) u64 {
    var x = v;
    x ^= x >> 33;
    x *%= 0xff51afd7ed558ccd;
    x ^= x >> 33;
    x *%= 0xc4ceb9fe1a85ec53;
    x ^= x >> 33;
    return x;
}

/// Every live note, in id order — `tryPatchPublished` binary-searches this. No degree: the
/// graph's rebuild counts distinct neighbours in one pass over the edge array it has in hand.
/// Index locked by the caller.
fn loadSnapNodes(index: *Index, arena: std.mem.Allocator) ![]const SnapNode {
    var list: std.ArrayList(SnapNode) = .empty;
    try list.ensureTotalCapacity(arena, index.real_count + index.phantom_count);
    // One allocation for every string, not two per note.
    var text_len: usize = 0;
    var it = index.iterate(null);
    while (it.next()) |n| text_len += n.path.len + n.shownTitle().len;
    const text = try arena.alloc(u8, text_len);
    var at: usize = 0;
    it = index.iterate(null);
    while (it.next()) |n| {
        const title = n.shownTitle();
        @memcpy(text[at..][0..n.path.len], n.path);
        const path = text[at..][0..n.path.len];
        at += n.path.len;
        @memcpy(text[at..][0..title.len], title);
        const t = text[at..][0..title.len];
        at += title.len;
        list.appendAssumeCapacity(.{
            .id = n.id,
            .path = path,
            .title = t,
            .phantom = n.phantom,
            .degree = 0,
            .size = @intCast(@max(n.size, 0)),
        });
    }
    return list.toOwnedSlice(arena);
}

/// Every link as `(src, dst)`. No dedupe: the consumer folds each pair into an unordered
/// `(min, max)` set anyway. Index locked by the caller.
fn loadSnapEdges(index: *Index, arena: std.mem.Allocator) ![]const SnapEdge {
    var list: std.ArrayList(SnapEdge) = .empty;
    try list.ensureTotalCapacity(arena, index.link_count);
    var it = index.iterate(null);
    while (it.next()) |n| {
        for (n.links) |l| list.appendAssumeCapacity(.{ .src_id = n.id, .dst_id = l.dst_id });
    }
    return list.toOwnedSlice(arena);
}

// -- index helpers ------------------------------------------------------------------

pub const NoteMeta = struct { id: i64, mtime_ns: i64, size: i64, hash: i64 };

/// Takes the index lock.
pub fn lookupNoteMeta(self: *Indexer, path: []const u8) ?NoteMeta {
    const index = self.index orelse return null;
    return lookupNoteMetaIn(index, path);
}

/// A real note whose file is gone. Takes the index lock.
pub fn deleteNoteByPath(self: *Indexer, path: []const u8) !void {
    const index = self.index orelse return;
    try deleteNote(index, path);
}

fn lookupNoteMetaIn(index: *Index, path: []const u8) ?NoteMeta {
    index.lock();
    defer index.unlock();
    const n = index.byPath(path) orelse return null;
    return .{ .id = n.id, .mtime_ns = n.mtime_ns, .size = n.size, .hash = n.hash };
}

/// A real note whose file is gone. Takes the index lock.
fn deleteNote(index: *Index, path: []const u8) !void {
    index.lock();
    defer index.unlock();
    const id = index.idByPath(path) orelse return;
    try index.retireNote(id);
}

/// The phantom a link to `raw_target` resolves to when no note matches, created if it does not
/// exist. `created` is raised when the note set grew — a publish can only reuse the previous
/// snapshot's node array when nothing added or removed a node. Index locked by the caller.
fn ensurePhantom(index: *Index, raw_target: []const u8, created: *bool) !i64 {
    // Callers should already filter; belt-and-braces so `.zig` never becomes a graph node.
    if (!resolve.isNoteLikeTarget(raw_target)) return error.NotANote;
    const norm = resolve.normalize(raw_target);
    // Degenerate targets share one empty phantom.
    const stem = if (std.mem.lastIndexOfScalar(u8, norm.text, '/')) |slash| norm.text[slash + 1 ..] else norm.text;
    return index.ensurePhantom(stem, created);
}

// -- path helpers -----------------------------------------------------------------

fn foldOwned(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    const out = try arena.alloc(u8, s.len);
    return query.foldInto(out, s);
}

// -- tests ------------------------------------------------------------------------
//
// These drive the real write path (`indexBuffer` → `writeNote` → `relinkAll`) against real
// the store. Everything the graph draws comes out of the links, so "does removing a wikilink
// actually remove the row" is not something a unit test of the scanner can answer.

const testing = std.testing;

const TestVault = struct {
    tmp: std.testing.TmpDir,
    dir: [:0]u8,
    threaded: std.Io.Threaded,
    index: Index,
    /// The disk, for the tests that write real files: the indexer's own, pumped by the scan.
    local: core.LocalFs,
    /// A bare host, so `sdk.refresh` and `isPathIgnored` have something to answer from.
    host: sdk.Host,
    busy: std.atomic.Value(bool) = .init(false),
    gen: Generation = .init(0),
    indexer: Indexer = undefined,

    fn create(gpa: std.mem.Allocator) !*TestVault {
        const self = try gpa.create(TestVault);
        errdefer gpa.destroy(self);
        self.* = .{
            .tmp = std.testing.tmpDir(.{}),
            .dir = undefined,
            .threaded = std.Io.Threaded.init_single_threaded,
            .index = undefined,
            .local = undefined,
            .host = .{ .allocator = gpa },
        };
        var gpa_copy = gpa;
        sdk.installRuntime(&gpa_copy, &self.host, null);
        self.dir = try self.tmp.dir.realPathFileAlloc(self.threaded.io(), ".", gpa);
        self.index = Index.init(gpa, self.threaded.io());
        self.local = core.LocalFs.init(gpa, self.threaded.io());
        self.indexer = Indexer.init(gpa, &self.busy, &self.gen);
        self.indexer.index = &self.index;
        self.indexer.vault_root = "/vault";
        return self;
    }

    fn destroy(self: *TestVault, gpa: std.mem.Allocator) void {
        // The indexer owns the two snapshot arenas, which only exist once something has actually
        // published. No test did until the completeness gate needed one, so this was missing and
        // the leak had never had a chance to show up.
        self.indexer.deinit();
        self.index.deinit();
        self.local.deinit();
        gpa.free(self.dir);
        self.tmp.cleanup();
        gpa.destroy(self);
    }

    /// Point the indexer at a real folder on disk, borrowed for the test.
    fn useDisk(self: *TestVault, vault: []const u8) void {
        self.indexer.vault_root = vault;
        self.indexer.source = .{ .fs = self.local.fs(), .root = vault, .pump_self = true };
    }

    /// One incremental edit, exactly as the worker runs it for a live editor buffer.
    fn write(self: *TestVault, rel: []const u8, body: []const u8) !void {
        _ = try self.indexer.indexBuffer(rel, body);
        try self.indexer.relinkAll();
    }

    fn noteCount(self: *TestVault) !usize {
        return self.index.real_count;
    }

    fn phantomCount(self: *TestVault) !usize {
        return self.index.phantom_count;
    }

    fn edgeCount(self: *TestVault) !usize {
        return self.index.link_count;
    }

    /// Edges as the graph sees them, i.e. excluding the `dst_id = src_id` self-loop stand-in.
    fn realEdgeCount(self: *TestVault) !usize {
        var n: usize = 0;
        var it = self.index.iterate(null);
        while (it.next()) |note| {
            for (note.links) |l| if (l.dst_id != note.id) {
                n += 1;
            };
        }
        return n;
    }

    /// Live notes at `path` (0 or 1).
    fn rowsAtPath(self: *TestVault, path: []const u8) usize {
        return if (self.index.byPath(path) != null) 1 else 0;
    }

    /// Phantoms whose stem is `stem`, exactly as written.
    fn phantomsWithStem(self: *TestVault, stem: []const u8) usize {
        var n: usize = 0;
        var it = self.index.iterate(true);
        while (it.next()) |note| if (std.mem.eql(u8, note.stem, stem)) {
            n += 1;
        };
        return n;
    }
};

test "removing a wikilink removes the edge" {
    const gpa = testing.allocator;
    var v = try TestVault.create(gpa);
    defer v.destroy(gpa);

    try v.write("Physics.md", "# Physics\n");
    try v.write("README.md", "# Readme\n");
    try testing.expectEqual(@as(usize, 0), try v.edgeCount());

    try v.write("README.md", "# Readme\n\nsee [[Physics]]\n");
    try testing.expectEqual(@as(usize, 1), try v.realEdgeCount());

    try v.write("README.md", "# Readme\n");
    try testing.expectEqual(@as(usize, 0), try v.edgeCount());
}

test "removing a wikilink to a note outside the vault removes edge and phantom" {
    const gpa = testing.allocator;
    var v = try TestVault.create(gpa);
    defer v.destroy(gpa);

    try v.write("README.md", "# Readme\n");
    try v.write("README.md", "# Readme\n\nsee [[Physics]]\n");
    try testing.expectEqual(@as(usize, 1), try v.realEdgeCount());
    try testing.expectEqual(
        @as(usize, 1),
        try v.phantomCount(),
    );

    try v.write("README.md", "# Readme\n");
    try testing.expectEqual(@as(usize, 0), try v.edgeCount());
    try testing.expectEqual(
        @as(usize, 0),
        try v.phantomCount(),
    );
}

test "editing an unrelated note leaves an existing edge alone" {
    const gpa = testing.allocator;
    var v = try TestVault.create(gpa);
    defer v.destroy(gpa);

    try v.write("Physics.md", "# Physics\n");
    try v.write("README.md", "# Readme\n\nsee [[Physics]]\n");
    try testing.expectEqual(@as(usize, 1), try v.realEdgeCount());

    try v.write("Physics.md", "# Physics\n\nmore words\n");
    try testing.expectEqual(@as(usize, 1), try v.realEdgeCount());
}

// The vault simulator's data path, minus the UI: republish at a different size and confirm the
// next `snapshotCopy` actually reports the new size. Regression test for "changing the note count
// slider does nothing" — this is the half of that path that can be checked headlessly, so a
// future failure lands here instead of only as an on-screen symptom.
// The graph panel refuses to build from a snapshot whose links are not resolved yet, so the flag
// that says so has to be wired to the right publishes. Getting it wrong is invisible in isolation:
// a mid-scan snapshot marked complete draws an edgeless graph that looks like a finished vault of
// unconnected notes, which is exactly the symptom a 283,878-note Wikipedia import produced.
test "only a relinked snapshot is marked complete" {
    const gpa = testing.allocator;
    var v = try TestVault.create(gpa);
    defer v.destroy(gpa);

    // A snapshot that has never been published is not complete.
    try testing.expect(!v.indexer.counts().complete);

    // `indexBuffer` alone leaves every new edge parked on the `dst_id = src_id` stand-in, so a
    // publish here would carry unresolved links. That is precisely the state the flag guards.
    _ = try v.indexer.indexBuffer("Physics.md", "# Physics\n");
    _ = try v.indexer.indexBuffer("README.md", "# Readme\n\nsee [[Physics]]\n");
    v.indexer.publishProgress(.scanning, 2, 2);
    const partial = v.indexer.counts();
    try testing.expect(!partial.complete);
    try testing.expectEqual(@as(u32, 2), partial.note_count);

    // After the relink pass the edge is real and the snapshot may be used.
    try v.indexer.relinkAll();
    try v.indexer.commitAndPublish();
    try testing.expect(v.indexer.counts().complete);
    try testing.expectEqual(@as(usize, 1), try v.realEdgeCount());
}

// The candidate lists are what the markdown preview resolves every wikilink against, and building
// them is a walk of every note and alias in the vault — multi-second on a Wikipedia-scale import.
// It used to run on the UI thread the first time a document rendered a link, which is exactly the
// hitch on opening the first document. This pins the handoff that moved it: a publish parks the
// lists, and the claim is a pointer swap that happens *before* the generation the UI is watching.
// Closing a folder mid-scan must not delete the vault.
//
// `dropMissing` reconciles the notes table against `seen` — "every note the walk found on disk" —
// and deletes the rest. That is only true of a walk that *finished*. When `quit` cuts one short,
// `seen` holds the part we reached, and reconciling against it deletes everything else: on a large
// vault, hundreds of thousands of cascading deletes, run while `stop()` has the UI thread blocked
// in `join`. It hung the app for minutes and emptied the index while doing it.
//
// The primary guard is `runFullScan` returning before the drops whenever `quit` is set, which
// needs a real walk to exercise. What this pins is the second one, inside the drop itself — the
// layer that has to hold if any future caller reaches it another way.
test "an aborted walk does not reconcile the index" {
    const gpa = testing.allocator;
    var v = try TestVault.create(gpa);
    defer v.destroy(gpa);

    try v.write("kept.md", "# Kept\n");
    try v.write("also-kept.md", "# Also\n");
    try testing.expectEqual(@as(usize, 2), try v.noteCount());

    // A walk that was cut off after one file: `seen` names only what it reached.
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(gpa);
    try seen.put(gpa, "kept.md", {});

    // Reconciling against that partial set would delete `also-kept.md`. With `quit` raised the
    // drop collects its candidates and then refuses to write any of them.
    v.indexer.quit.store(true, .release);
    _ = try v.indexer.dropMissing(&seen);
    try testing.expectEqual(@as(usize, 2), try v.noteCount());

    // And with the walk allowed to finish, the reconcile still does its real job.
    v.indexer.quit.store(false, .release);
    try testing.expect(try v.indexer.dropMissing(&seen));
    try testing.expectEqual(@as(usize, 1), try v.noteCount());
}

// A vault switch must not serve the previous vault's graph to the next one — and must not serve it
// as *finished*, which waves it past the panel's "never build from an incomplete snapshot" gate.
test "stopping clears the published snapshot" {
    const gpa = testing.allocator;
    var v = try TestVault.create(gpa);
    defer v.destroy(gpa);

    try v.write("Physics.md", "# Physics\n");
    try v.write("README.md", "# Readme\n\nsee [[Physics]]\n");
    try v.indexer.commitAndPublish();
    try testing.expect(v.indexer.counts().complete);
    try testing.expectEqual(@as(u32, 2), v.indexer.counts().note_count);

    // `stop` is what `closeVault` calls, on both a close and the close half of a switch.
    v.indexer.stop();
    const after = v.indexer.counts();
    try testing.expect(!after.complete);
    try testing.expectEqual(@as(u32, 0), after.note_count);

    // `stop` clears `index`; put it back so `destroy` tears down the same way every other test does.
    v.indexer.index = &v.index;
}

test "publishing hands the candidate lists to the UI thread" {
    const gpa = testing.allocator;
    var v = try TestVault.create(gpa);
    defer v.destroy(gpa);

    // Nothing published yet: nothing to claim, and the caller falls back to querying.
    try testing.expect(v.indexer.takeCandidates() == null);

    try v.write("Physics.md", "# Physics\n");
    try v.write("README.md", "# Readme\n\nsee [[Physics]]\n");
    try v.indexer.commitAndPublish();

    var set = v.indexer.takeCandidates() orelse return error.NoCandidates;
    defer set.deinit();

    // The same list the UI would have built for itself, entry for entry — this is a move of the
    // work, not a different answer.
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const want = try loadCandidates(&v.index, arena.allocator());
    try testing.expectEqual(want.len, set.notes.len);
    for (want, set.notes) |w, got| {
        try testing.expectEqualStrings(w.path, got.path);
        try testing.expectEqualStrings(w.stem, got.stem);
        try testing.expectEqualStrings(w.alias, got.alias);
    }

    // Claimed once. A second take on the same generation finds it gone rather than handing the
    // same arena to two owners.
    try testing.expect(v.indexer.takeCandidates() == null);
}

test "publishSynthetic marks its snapshot complete" {
    // A generated graph arrives whole, with edges already pointing at real ids — there is no walk
    // and no relink to wait for, so the simulator must not sit behind the gate forever.
    const gpa = testing.allocator;
    var busy = std.atomic.Value(bool).init(false);
    var gen = Generation.init(0);
    var ix = Indexer.init(gpa, &busy, &gen);
    defer ix.deinit();

    const nodes = [_]SnapNode{
        .{ .id = 1, .path = "", .title = "", .phantom = false, .degree = 1 },
        .{ .id = 2, .path = "", .title = "", .phantom = false, .degree = 1 },
    };
    const edges = [_]SnapEdge{.{ .src_id = 1, .dst_id = 2 }};
    try ix.publishSynthetic(&nodes, &edges);
    try testing.expect(ix.counts().complete);
}

test "publishSynthetic replaces the previous snapshot wholesale" {
    const gpa = testing.allocator;
    var busy = std.atomic.Value(bool).init(false);
    var gen = Generation.init(0);
    var ix = Indexer.init(gpa, &busy, &gen);
    defer ix.deinit();

    const sizes = [_]usize{ 100, 20_000, 100 };
    for (sizes) |n| {
        const before = gen.load(.acquire);

        const nodes = try gpa.alloc(SnapNode, n);
        defer gpa.free(nodes);
        for (nodes, 0..) |*node, i| {
            node.* = .{
                .id = @intCast(i + 1),
                .path = "",
                .title = "",
                .phantom = false,
                .degree = 2,
            };
        }
        // One chain edge per node pair, mirroring what a generated vault hands over.
        const edges = try gpa.alloc(SnapEdge, n - 1);
        defer gpa.free(edges);
        for (edges, 0..) |*e, i| e.* = .{ .src_id = @intCast(i + 1), .dst_id = @intCast(i + 2) };

        try ix.publishSynthetic(nodes, edges);

        // Generation must move, or nothing downstream ever asks for a rebuild.
        try testing.expect(gen.load(.acquire) > before);

        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const snap = try ix.snapshotCopy(arena.allocator());
        try testing.expectEqual(n, snap.nodes.len);
        try testing.expectEqual(n, snap.note_count);
        try testing.expectEqual(n - 1, snap.edges.len);
    }
}

test "an alias-bearing note is structural, so the resolve cache cannot go stale" {
    // `ResolveCache` holds every note's stems *and aliases* between edits, and an alias is a name
    // other notes resolve against — so a note that declares one must not take the fast path that
    // keeps the cache. Conservative on purpose: the flag fires whenever the note has an alias, not
    // only when one changed. If this ever reports `.rewrote`, a rename of an alias would keep
    // resolving to the old name until a full pass.
    const gpa = testing.allocator;
    var v = try TestVault.create(gpa);
    defer v.destroy(gpa);

    try testing.expect(try v.indexer.indexBuffer("Plain.md", "# Plain\n") == .structural); // new note
    // Same note again, no aliases: only its own links can have moved.
    switch (try v.indexer.indexBuffer("Plain.md", "# Plain\n\nnow with words\n")) {
        .rewrote => {},
        else => return error.TestExpectedRewrote,
    }

    _ = try v.indexer.indexBuffer("Aliased.md", "---\naliases: [Other Name]\n---\n# Aliased\n");
    // Editing it again must stay structural for as long as the alias is declared.
    try testing.expect(
        try v.indexer.indexBuffer("Aliased.md", "---\naliases: [Other Name]\n---\n# Aliased\n\nbody\n") == .structural,
    );
}

test "relinkNote resolves the edited note's links and leaves the rest alone" {
    // The scoped relink is what makes an edit cost milliseconds instead of re-resolving every link
    // in the vault. It has to actually resolve the note it is given — a scope that silently matched
    // nothing would look identical to a fast relink until the graph came up short an edge.
    const gpa = testing.allocator;
    var v = try TestVault.create(gpa);
    defer v.destroy(gpa);

    try v.write("Physics.md", "# Physics\n");
    try v.write("Optics.md", "# Optics\n");
    try v.write("README.md", "# Readme\n\nsee [[Physics]]\n");
    try testing.expectEqual(@as(usize, 1), try v.realEdgeCount());

    // Add a second link to README and relink *only* README.
    const outcome = try v.indexer.indexBuffer("README.md", "# Readme\n\nsee [[Physics]] and [[Optics]]\n");
    const id = switch (outcome) {
        .rewrote => |note_id| note_id,
        else => return error.TestExpectedRewrote,
    };
    _ = try v.indexer.relinkNote(id);
    try testing.expectEqual(@as(usize, 2), try v.realEdgeCount());
}

test "a published snapshot says which notes were rewritten, and when it cannot" {
    // The layout re-solves the whole vault on every commit because a whole snapshot is all it is
    // handed — a one-note edit costs the seconds a first open does. The indexer has always known
    // better: `indexPending` classifies every file and the incremental path already uses that to
    // scope the *relink*. This is the same fact, carried as far as the consumers.
    const gpa = testing.allocator;
    var v = try TestVault.create(gpa);
    defer v.destroy(gpa);

    try v.write("Physics.md", "# Physics\n");
    try v.write("README.md", "# Readme\n\nsee [[Physics]]\n");

    // A body edit to an existing note: exactly the notes that were written, and nothing else.
    const outcome = try v.indexer.indexBuffer("README.md", "# Readme\n\nsee [[Physics]] twice\n");
    const id = switch (outcome) {
        .rewrote => |note_id| note_id,
        else => return error.TestExpectedRewrote,
    };
    v.indexer.pending_dirty.clearRetainingCapacity();
    v.indexer.pending_broad = false;
    try v.indexer.pending_dirty.append(gpa, id);
    try v.indexer.commitAndPublish();

    var scoped_arena = std.heap.ArenaAllocator.init(gpa);
    defer scoped_arena.deinit();
    const scoped = try v.indexer.snapshotCopy(scoped_arena.allocator());
    try testing.expect(scoped.dirty_known);
    try testing.expectEqual(@as(usize, 1), scoped.dirty.len);
    try testing.expectEqual(id, scoped.dirty[0]);

    // Draining is what makes the account per-publish rather than cumulative — a second commit with
    // nothing new must not re-report the first commit's note as dirty.
    try v.indexer.commitAndPublish();
    var empty_arena = std.heap.ArenaAllocator.init(gpa);
    defer empty_arena.deinit();
    const empty = try v.indexer.snapshotCopy(empty_arena.allocator());
    try testing.expect(empty.dirty_known);
    try testing.expect(empty.edges_same);
    try testing.expectEqual(@as(usize, 0), empty.dirty.len);

    // A structural change cannot be described by a list of written notes: a note appearing moves
    // where *other* notes' links resolve. The snapshot has to say so rather than under-report.
    v.indexer.pending_broad = true;
    try v.indexer.commitAndPublish();
    var broad_arena = std.heap.ArenaAllocator.init(gpa);
    defer broad_arena.deinit();
    const broad = try v.indexer.snapshotCopy(broad_arena.allocator());
    try testing.expect(!broad.dirty_known);
    try testing.expect(!broad.edges_same);
}

test "a prose save patches the snapshot and leaves edges in place" {
    const gpa = testing.allocator;
    var v = try TestVault.create(gpa);
    defer v.destroy(gpa);

    try v.write("Physics.md", "# Physics\n");
    try v.write("README.md", "# Readme\n\nsee [[Physics]]\n");
    try v.indexer.commitAndPublish();
    var before_arena = std.heap.ArenaAllocator.init(gpa);
    defer before_arena.deinit();
    const before_snap = try v.indexer.snapshotCopy(before_arena.allocator());
    const before = v.indexer.peekLayout();
    try testing.expect(before.complete);
    const edge_n = before_snap.edges.len;

    const outcome = try v.indexer.indexBuffer("README.md", "# Readme\n\nsee [[Physics]] — more words\n");
    const id = switch (outcome) {
        .rewrote => |note_id| note_id,
        else => return error.TestExpectedRewrote,
    };
    v.indexer.pending_dirty.clearRetainingCapacity();
    v.indexer.pending_broad = false;
    try v.indexer.pending_dirty.append(gpa, id);
    _ = try v.indexer.relinkNote(id);
    try v.indexer.commitAndPublish();

    const peek = v.indexer.peekLayout();
    try testing.expect(peek.dirty_known);
    try testing.expect(peek.edges_same);
    try testing.expectEqual(before.node_n, peek.node_n);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const dirty = try v.indexer.copyDirtyNotes(arena.allocator());
    try testing.expectEqual(@as(usize, 1), dirty.len);
    try testing.expectEqual(id, dirty[0].id);
    try testing.expect(std.mem.endsWith(u8, dirty[0].path, "README.md"));

    const snap = try v.indexer.snapshotCopy(arena.allocator());
    try testing.expectEqual(edge_n, snap.edges.len);
}

test "adding a wikilink falls back to a full reload rather than a patch" {
    const gpa = testing.allocator;
    var v = try TestVault.create(gpa);
    defer v.destroy(gpa);

    try v.write("Physics.md", "# Physics\n");
    try v.write("Optics.md", "# Optics\n");
    try v.write("README.md", "# Readme\n\nsee [[Physics]]\n");
    try v.indexer.commitAndPublish();

    const outcome = try v.indexer.indexBuffer("README.md", "# Readme\n\nsee [[Physics]] and [[Optics]]\n");
    const id = switch (outcome) {
        .rewrote => |note_id| note_id,
        else => return error.TestExpectedRewrote,
    };
    _ = try v.indexer.relinkNote(id);
    v.indexer.pending_dirty.clearRetainingCapacity();
    v.indexer.pending_broad = false;
    try v.indexer.pending_dirty.append(gpa, id);
    try v.indexer.commitAndPublish();

    const peek = v.indexer.peekLayout();
    try testing.expect(peek.dirty_known);
    try testing.expect(!peek.edges_same);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const snap = try v.indexer.snapshotCopy(arena.allocator());
    try testing.expectEqual(@as(usize, 2), snap.edges.len);
}

test "removing a wikilink falls back to a full reload rather than counting as prose" {
    const gpa = testing.allocator;
    var v = try TestVault.create(gpa);
    defer v.destroy(gpa);

    try v.write("Physics.md", "# Physics\n");
    try v.write("Optics.md", "# Optics\n");
    try v.write("README.md", "# Readme\n\nsee [[Physics]] and [[Optics]]\n");
    try v.indexer.commitAndPublish();

    var before_arena = std.heap.ArenaAllocator.init(gpa);
    defer before_arena.deinit();
    const before = try v.indexer.snapshotCopy(before_arena.allocator());
    try testing.expectEqual(@as(usize, 2), before.edges.len);

    const outcome = try v.indexer.indexBuffer("README.md", "# Readme\n\nsee [[Physics]]\n");
    const id = switch (outcome) {
        .rewrote => |note_id| note_id,
        else => return error.TestExpectedRewrote,
    };
    _ = try v.indexer.relinkNote(id);
    v.indexer.pending_dirty.clearRetainingCapacity();
    v.indexer.pending_broad = false;
    try v.indexer.pending_dirty.append(gpa, id);
    try v.indexer.commitAndPublish();

    const peek = v.indexer.peekLayout();
    try testing.expect(peek.dirty_known);
    try testing.expect(!peek.edges_same);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const snap = try v.indexer.snapshotCopy(arena.allocator());
    try testing.expectEqual(@as(usize, 1), snap.edges.len);
    try testing.expectEqual(id, snap.edges[0].src_id);
}

test "removing every wikilink falls back to a full reload rather than counting as prose" {
    const gpa = testing.allocator;
    var v = try TestVault.create(gpa);
    defer v.destroy(gpa);

    try v.write("Physics.md", "# Physics\n");
    try v.write("README.md", "# Readme\n\nsee [[Physics]]\n");
    try v.indexer.commitAndPublish();

    const outcome = try v.indexer.indexBuffer("README.md", "# Readme\n");
    const id = switch (outcome) {
        .rewrote => |note_id| note_id,
        else => return error.TestExpectedRewrote,
    };
    _ = try v.indexer.relinkNote(id);
    v.indexer.pending_dirty.clearRetainingCapacity();
    v.indexer.pending_broad = false;
    try v.indexer.pending_dirty.append(gpa, id);
    try v.indexer.commitAndPublish();

    const peek = v.indexer.peekLayout();
    try testing.expect(peek.dirty_known);
    try testing.expect(!peek.edges_same);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const snap = try v.indexer.snapshotCopy(arena.allocator());
    try testing.expectEqual(@as(usize, 0), snap.edges.len);
}

// A rename in the file explorer is two facts on disk — the old path is gone, the new one is
// there — and the watcher hands both to the indexer as ordinary paths to re-read. What must not
// survive it is a node under the old name: the old row has to leave the notes table, and every
// link that pointed at the old name has to move (or become a phantom) rather than keep the old
// row alive. Reported as "renaming a note leaves both names in the graph".
test "renaming a note on disk leaves only the new name" {
    const gpa = testing.allocator;
    var v = try TestVault.create(gpa);
    defer v.destroy(gpa);
    const io = v.threaded.io();

    try v.tmp.dir.createDirPath(io, "vault");
    const vault = try v.tmp.dir.realPathFileAlloc(io, "vault", gpa);
    defer gpa.free(vault);
    v.useDisk(vault);

    var vd = try std.Io.Dir.cwd().openDir(io, vault, .{});
    defer vd.close(io);
    try vd.writeFile(io, .{ .sub_path = "Alpha.md", .data = "# Alpha\n" });
    try vd.writeFile(io, .{ .sub_path = "Beta.md", .data = "# Beta\n\nsee [[Alpha]]\n" });

    // Seeded through `indexOne` rather than `runFullScan`: the walk reads the clock, and
    // `dvui.io` is not valid headlessly (see `markNs`). Same write path either way.
    _ = try v.indexer.indexOne(io, "Alpha.md");
    _ = try v.indexer.indexOne(io, "Beta.md");
    try v.indexer.relinkAll();
    try testing.expectEqual(@as(usize, 2), try v.noteCount());
    try testing.expectEqual(@as(usize, 1), try v.realEdgeCount());

    try vd.rename("Alpha.md", vd, "Gamma.md", io);

    // Exactly what `Watcher.onPathsChanged` enqueues for a rename on macOS, where the halves
    // arrive unpaired: the old path (delivered as `.deleted`) and the new one (`.created`),
    // both as "re-read this".
    _ = try v.indexer.indexOne(io, "Alpha.md");
    _ = try v.indexer.indexOne(io, "Gamma.md");
    try v.indexer.relinkAll();

    // One note under the new name, and no second row under the old one.
    try testing.expectEqual(@as(usize, 2), try v.noteCount());
    try testing.expectEqual(
        @as(usize, 0),
        v.rowsAtPath("Alpha.md"),
    );
    try testing.expectEqual(
        @as(usize, 1),
        v.rowsAtPath("Gamma.md"),
    );

    // Beta still says `[[Alpha]]`, and that is a broken link, not a link that never existed:
    // its row must survive the note it pointed at (see `retireNote`) and land on a phantom.
    try testing.expectEqual(@as(usize, 1), try v.realEdgeCount());
    try testing.expectEqual(
        @as(usize, 1),
        v.phantomsWithStem("Alpha"),
    );

    // And re-reading a backlink source later changes nothing. Before `retireNote`, the cascade
    // had already destroyed Beta's row, so the phantom appeared only here — the graph grew a
    // node under the old name minutes after the rename, whenever something touched Beta.
    _ = try v.indexer.indexBuffer("Beta.md", "# Beta\n\nsee [[Alpha]]\n\nmore\n");
    try v.indexer.relinkAll();
    try testing.expectEqual(@as(usize, 2), try v.noteCount());
    try testing.expectEqual(@as(usize, 1), try v.realEdgeCount());
    try testing.expectEqual(
        @as(usize, 1),
        try v.phantomCount(),
    );
}

// The other half of `retireNote`: when nothing points at the note, the row goes entirely rather
// than lingering as a phantom nobody links to — which would draw as a node for a file that does
// not exist and that no note mentions.
test "deleting an unlinked note removes its row" {
    const gpa = testing.allocator;
    var v = try TestVault.create(gpa);
    defer v.destroy(gpa);
    const io = v.threaded.io();

    try v.tmp.dir.createDirPath(io, "vault");
    const vault = try v.tmp.dir.realPathFileAlloc(io, "vault", gpa);
    defer gpa.free(vault);
    v.useDisk(vault);

    var vd = try std.Io.Dir.cwd().openDir(io, vault, .{});
    defer vd.close(io);
    try vd.writeFile(io, .{ .sub_path = "Lonely.md", .data = "# Lonely\n" });
    _ = try v.indexer.indexOne(io, "Lonely.md");
    try testing.expectEqual(@as(usize, 1), try v.noteCount());

    try vd.deleteFile(io, "Lonely.md");
    _ = try v.indexer.indexOne(io, "Lonely.md");
    try v.indexer.relinkAll();

    try testing.expectEqual(@as(usize, 0), try v.noteCount());
    try testing.expectEqual(
        @as(usize, 0),
        @as(usize, v.index.real_count + v.index.phantom_count),
    );
}

// A vault on a mount, indexed the way the web build and a cloud drive do it: the source does
// not pump itself, the host pumps it once a frame and then steps the task within a budget.
// `vfs.Mem` stands in for the mount (its completions land on `pump`, like a drive's).
test "a mounted vault is indexed from the frame, a budget at a time" {
    const gpa = testing.allocator;
    var v = try TestVault.create(gpa);
    defer v.destroy(gpa);
    // The runner's clock and lock come from the host's `Io`; headless, that is the test's.
    dvui.io = v.threaded.io();

    var mem = try core.vfs.Mem.init(gpa);
    defer mem.deinit();
    try mem.putDir("/notes");
    try mem.put("/notes/Alpha.md", "# Alpha\n\nsee [[Beta]] and [[Nowhere]]\n");
    try mem.put("/notes/Beta.md", "# Beta\n\nback to [[Alpha]]\n");
    try mem.put("/diagram.png", "");

    try v.indexer.start(&v.index, "mem://box", .{ .fs = mem.fs(), .root = "/", .pump_self = false });
    // Frames: the host pumps the mount, then gives the task its slice.
    var frames: usize = 0;
    while (frames < 10_000) : (frames += 1) {
        mem.fs().pump();
        v.indexer.pump(1 * std.time.ns_per_ms);
        if (v.indexer.counts().complete) break;
    }
    const c = v.indexer.counts();
    try testing.expect(c.complete);
    try testing.expectEqual(@as(u32, 2), c.note_count);
    try testing.expectEqual(@as(u32, 1), c.phantom_count); // Nowhere
    try testing.expectEqual(@as(usize, 3), try v.realEdgeCount());
    try testing.expectEqual(@as(u32, 1), v.index.media_count);
    try testing.expect(frames > 1); // it took more than one frame, i.e. it yielded

    // A save arrives as a queued path: the scoped scan runs from the frame too. Written the way
    // a save is — through the filesystem, landing on a pump.
    const Done = struct {
        fn f(_: ?*anyopaque, _: core.vfs.Error!void) void {}
    };
    _ = try mem.fs().writeFile("/notes/Beta.md", "# Beta\n\nno links now\n", .{}, Done.f, null);
    mem.fs().pump();
    v.indexer.enqueue("notes/Beta.md");
    frames = 0;
    while (frames < 10_000) : (frames += 1) {
        mem.fs().pump();
        v.indexer.pump(1 * std.time.ns_per_ms);
        if (try v.realEdgeCount() == 2) break;
    }
    try testing.expectEqual(@as(usize, 2), try v.realEdgeCount());
    v.indexer.stop();
    v.indexer.index = &v.index;
}
