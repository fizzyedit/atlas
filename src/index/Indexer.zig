//! Background indexer: walk the vault, parse notes, write the SQLite index.
//!
//! One writer thread owns the DB connection. The UI thread only ever *reads* (via the same
//! serialized connection for now — WAL means that doesn't block). Lifecycle is owned by
//! `State`: `start` on folder open, `stop`+`join` on folder close / deinit. The join is
//! mandatory — this thread runs code inside atlas's dylib and must not outlive it.
const std = @import("std");
const dvui = @import("dvui");
const sdk = @import("fizzy_sdk");

const Db = @import("Db.zig");
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

    pub fn deinit(self: *CandidateSet) void {
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
    id_by_path: std.StringHashMapUnmanaged(i64),

    fn deinit(self: *ResolveCache, gpa: std.mem.Allocator) void {
        self.index.deinit();
        self.id_by_path.deinit(gpa);
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
db: ?*Db = null,
vault_root: []const u8 = "",

quit: std.atomic.Value(bool) = .init(false),
busy: *std.atomic.Value(bool),
generation: *std.atomic.Value(u64),

/// Same shape as pixi's SaveQueue: `std.Io.Mutex`/`Condition` locked with `dvui.io` from both
/// the UI thread (enqueue) and the worker.
mutex: std.Io.Mutex = .init,
cond: std.Io.Condition = .init,
thread: ?std.Thread = null,

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

    fn reset(self: *Timings) void {
        self.* = .{};
    }
};

/// Clock reads are gated on a full scan actually running, for two reasons: the incremental edit
/// path runs on every save and does not need a clock in it, and `dvui.io` is only valid inside the
/// app — the headless tests drive `indexBuffer`/`writeNote` directly with their own `Io`, so an
/// ungated read there is a crash rather than a measurement.
fn markNs(self: *const Indexer) i96 {
    if (!self.timing) return 0;
    return std.Io.Clock.boot.now(dvui.io).nanoseconds;
}

fn sinceNs(self: *const Indexer, from: i96) u64 {
    if (!self.timing or from == 0) return 0;
    const d = std.Io.Clock.boot.now(dvui.io).nanoseconds - from;
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

pub fn init(
    gpa: std.mem.Allocator,
    busy: *std.atomic.Value(bool),
    generation: *std.atomic.Value(u64),
) Indexer {
    return .{
        .gpa = gpa,
        .busy = busy,
        .generation = generation,
    };
}

/// Begin indexing `vault_root` into `db`. Spawns the worker and queues a full scan.
/// `vault_root` is borrowed for the life of the indexer (State owns it).
pub fn start(self: *Indexer, db: *Db, vault_root: []const u8) !void {
    self.stop();
    self.db = db;
    self.vault_root = vault_root;
    self.quit.store(false, .release);

    // Raised here, on the UI thread, rather than by the worker once it wakes: between the spawn
    // and the worker's first candidate build there is a window where the flag is the only thing
    // telling `State.ensureCandidates` that a set is coming, and if it reads `false` in that window
    // it runs the very query this exists to keep off the UI thread.
    self.cand_pending.store(true, .release);

    self.mutex.lockUncancelable(dvui.io);
    self.want_full = true;
    self.mutex.unlock(dvui.io);

    self.thread = std.Thread.spawn(.{}, worker, .{self}) catch |err| {
        // No worker means no publish means nothing to wait for.
        self.cand_pending.store(false, .release);
        return err;
    };
}

/// Signal the worker and join. Safe to call when never started.
pub fn stop(self: *Indexer) void {
    // The cache describes *this* vault's notes and is keyed to the database `db` points at.
    self.dropResolveCache();
    self.quit.store(true, .release);
    self.mutex.lockUncancelable(dvui.io);
    self.cond.signal(dvui.io);
    self.mutex.unlock(dvui.io);
    if (self.thread) |t| {
        t.join();
        self.thread = null;
    }
    self.db = null;
    self.vault_root = "";
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
    for (self.pending.items) |p| p.deinit(self.gpa);
    self.pending.clearRetainingCapacity();
}

pub fn deinit(self: *Indexer) void {
    self.stop();
    self.dropResolveCache();
    self.pending.deinit(self.gpa);
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
    self.cond.signal(dvui.io);
}

/// Ask for a quiet re-walk of the vault. Unlike `requestFullScan` this does not disturb queued
/// work and does not republish unless a file actually changed, so it can run on a timer without
/// rebuilding the graph — or re-running the relink — every tick.
pub fn requestSweep(self: *Indexer) void {
    self.mutex.lockUncancelable(dvui.io);
    defer self.mutex.unlock(dvui.io);
    if (self.want_full) return;
    self.want_sweep = true;
    self.cond.signal(dvui.io);
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
        self.cond.signal(dvui.io);
        return;
    }
    self.pending.append(self.gpa, item) catch {
        item.deinit(self.gpa);
        return;
    };
    self.cond.signal(dvui.io);
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

    const nodes = try arena.alloc(SnapNode, src.nodes.len);
    for (src.nodes, nodes) |s, *d| {
        d.* = s;
        d.path = try arena.dupe(u8, s.path);
        d.title = try arena.dupe(u8, s.title);
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
    };
}

// -- worker -----------------------------------------------------------------------

fn worker(self: *Indexer) void {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();

    while (true) {
        self.mutex.lockUncancelable(dvui.io);
        while (!self.quit.load(.acquire) and !self.want_full and !self.want_sweep and
            self.pending.items.len == 0)
        {
            self.cond.waitUncancelable(dvui.io, &self.mutex);
        }
        if (self.quit.load(.acquire)) {
            self.mutex.unlock(dvui.io);
            return;
        }
        const do_full = self.want_full;
        self.want_full = false;
        if (do_full) self.want_sweep = false;
        // A sweep yields to queued work: a pending item can carry unsaved buffer bytes, and
        // re-walking the disk first would stamp the saved content back over them. `want_sweep`
        // stays set, so the next trip round the loop picks it up.
        const do_sweep = !do_full and self.want_sweep and self.pending.items.len == 0;
        if (do_sweep) self.want_sweep = false;
        const batch = self.pending.toOwnedSlice(self.gpa) catch {
            self.mutex.unlock(dvui.io);
            continue;
        };
        self.mutex.unlock(dvui.io);
        defer {
            for (batch) |p| p.deinit(self.gpa);
            self.gpa.free(batch);
        }

        // A sweep is speculative and usually finds nothing. Raising `busy` for it would blink
        // the sidebar's indexing state every 15s, and refreshing would wake an idle app to
        // repaint an identical frame — so a quiet sweep announces nothing at all. On the one
        // path where it does have news, `runFullScan` refreshes for itself.
        const announce = !do_sweep;
        if (announce) {
            self.busy.store(true, .release);
            sdk.refresh();
        }
        // The wake has to come *after* `busy` clears, not before: a refresh issued while the
        // flag is still set paints one more "indexing" frame and then the app idles with a
        // spinner that never goes away. Same failure the stale graph had, one flag over.
        defer if (announce) {
            self.busy.store(false, .release);
            sdk.refresh();
        };

        if (do_full or do_sweep) {
            self.runFullScan(io, if (do_full) .always else .if_changed) catch |err| {
                log.err("full scan failed: {s}", .{@errorName(err)});
            };
        } else {
            // Which notes were rewritten, so the relink can be scoped to them.
            //
            // A typing lull rewrites exactly one note, and re-resolving all 3.35M links in the
            // vault to find out where that note points cost 3.4 s of the 3.7 s an edit took — see
            // `relinkNote`. Scoped, it is the note's own handful of links. `structural` is the
            // escape hatch: a note that appeared or vanished can change where *other* notes
            // resolve, and only the full pass is correct for that.
            var rewrote: std.ArrayList(i64) = .empty;
            defer rewrote.deinit(self.gpa);
            var structural = false;
            var changed = false;
            for (batch) |item| {
                if (self.quit.load(.acquire)) break;
                const outcome = self.indexPending(io, item) catch |err| blk: {
                    log.warn("index {s}: {s}", .{ item.rel, @errorName(err) });
                    break :blk .unchanged;
                };
                switch (outcome) {
                    .unchanged => {},
                    .rewrote => |id| {
                        changed = true;
                        rewrote.append(self.gpa, id) catch {
                            // Cannot record which note to relink, so relink everything rather
                            // than leave its edges parked on the `dst_id = src_id` stand-in.
                            structural = true;
                        };
                    },
                    .structural => {
                        changed = true;
                        structural = true;
                        // The note set (or the names resolution reads) moved.
                        self.dropResolveCache();
                    },
                }
            }
            // `writeNote` parks every new edge on `dst_id = src_id` as a stand-in; without a
            // relink pass, the graph only ever sees self-loops and never materializes phantoms
            // for targets like `[[Physics]]` that don't exist yet.
            if (changed) {
                if (structural) {
                    self.relinkAll() catch |err| {
                        log.warn("relink after incremental: {s}", .{@errorName(err)});
                    };
                } else {
                    for (rewrote.items) |id| {
                        _ = self.relinkNote(id) catch |err| {
                            log.warn("relink note {d}: {s}", .{ id, @errorName(err) });
                        };
                    }
                }
                self.commitAndPublish() catch {};
            }
        }
    }
}

pub const ScanMode = enum {
    /// Publish when the walk finishes, changed or not — folder open, explicit rebuild. The UI
    /// asked for this, so it gets a fresh snapshot even if the answer is identical.
    always,
    /// Publish only if a note actually moved. What the background sweep uses: it runs on a
    /// timer over the whole vault, and republishing an unchanged index would rebuild the graph,
    /// re-run the relink, and retarget the camera every tick for nothing.
    if_changed,
};

/// Public only so the headless harness (`bench --index`) can drive one scan on the calling
/// thread and read `timings` afterwards. The app always reaches this through `worker`.
pub fn runFullScan(self: *Indexer, io: std.Io, mode: ScanMode) !void {
    // Hand the UI whatever the *previous* session already indexed, before walking anything.
    //
    // A scan of a Wikipedia-scale vault runs for minutes, and until it publishes there is no
    // candidate set — so every wikilink the preview renders in the meantime resolves against
    // nothing, even though a complete index from last time is sitting on disk. This is the same
    // build the end-of-scan publish does, run first and against the rows already there.
    //
    // Gated on `cand_pending`, which `start` raises and the first publish clears: exactly once per
    // opened vault. A later explicit rebuild already has a live set on the UI side and does not
    // need a second full pass over the notes table to say so.
    if (self.cand_pending.load(.acquire)) {
        self.publishCandidates();
        // No generation bump: the note data hasn't changed, and a bump would throw away every cache
        // derived from it (see `publishProgress`). `State.ensureCandidates` claims a waiting set on
        // its next call regardless of the generation, because it has nothing to lose by doing so.
        sdk.refresh();
    }

    // Seen set so we can drop notes whose files disappeared.
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer {
        var it = seen.keyIterator();
        while (it.next()) |k| self.gpa.free(k.*);
        seen.deinit(self.gpa);
    }

    var files_since_commit: usize = 0;
    var last_commit = std.Io.Clock.boot.now(io).nanoseconds;

    var media_seen: std.StringHashMapUnmanaged(void) = .empty;
    defer {
        var it = media_seen.keyIterator();
        while (it.next()) |k| self.gpa.free(k.*);
        media_seen.deinit(self.gpa);
    }

    // How many notes this scan is going to visit, so the UI can show progress against a total
    // rather than a number that climbs toward nothing. This is a metadata-only walk — directory
    // iteration, no `stat`, no reads, no parsing, no database — which costs a small fraction of
    // the scan proper, where every one of those files is read, parsed and written.
    //
    // Only for `.always` (folder open / explicit rebuild). The background sweep already walks the
    // whole vault on a timer; making it walk twice to refresh a number nobody is watching is a
    // poor trade, and the previous total is still the right answer.
    self.timings.reset();
    self.timing = true;
    defer self.timing = false;
    if (mode == .always) {
        const t0 = self.markNs();
        const total = self.countMarkdown(io, self.vault_root) catch 0;
        self.timings.prepass_ns = self.sinceNs(t0);
        self.scan_total.store(total, .release);
    }

    var changed = false;
    // One explicit transaction per batch instead of an implicit one per statement.
    //
    // A note write is several statements (the row, its links, headings, blocks, tags), and SQLite
    // wraps each one in its own transaction unless told otherwise — so a 284k-file scan pays
    // millions of transaction commits, each with its own WAL frame and locking. Batching them is
    // the single largest constant-factor win available in the walk, and the batch boundary already
    // exists: `walk` commits and publishes progress on the same `batch_files`/`batch_ns` cadence.
    //
    // A long write transaction is safe here precisely because the index is WAL: readers see the
    // pre-transaction state and are never blocked, which is the behaviour we want anyway — a
    // half-written batch is not something any consumer should see.
    self.beginBatch();
    const walk_start = self.markNs();
    {
        errdefer self.endBatch();
        try self.walk(io, self.vault_root, &seen, &media_seen, &files_since_commit, &last_commit, &changed, mode == .always);
    }
    self.endBatch();
    self.timings.walk_ns = self.sinceNs(walk_start);

    // An aborted walk must never reconcile.
    //
    // `seen` means "every note that exists on disk" only if the walk *finished*. When `quit` cuts
    // it short — closing the folder, switching vaults — `seen` is just "the part we reached", and
    // handing that to `dropMissing` means deleting every note the walk had not got to yet. On a
    // 286k-note vault aborted early that is hundreds of thousands of `DELETE`s, each cascading
    // through the note's links, headings, blocks and tags.
    //
    // It froze the app *and* destroyed the index: `stop()` sets `quit` and then blocks the UI
    // thread in `pthread_join` for the whole of it (a beachball, minutes long), and what it was
    // waiting for was the deletion of most of the vault — so the next open had to rebuild from
    // nothing. Closing a folder mid-scan is a completely ordinary thing to do.
    if (self.quit.load(.acquire)) return;

    // Anything real that we didn't see is gone from disk. A note deleted outside the editor is
    // its own kind of stale edge, so these count as changes too.
    const drop_start = self.markNs();
    if (try self.dropMissing(&seen)) changed = true;
    if (try self.dropMissingMedia(&media_seen)) changed = true;
    self.timings.drop_ns = self.sinceNs(drop_start);

    if (mode == .if_changed and !changed) return;

    // Fold the walk's write-ahead log back into the database before reading across it.
    //
    // The walk just wrote every note and link in the vault, and in WAL mode those writes live in a
    // log that each subsequent page read has to search. That search (`walFindFrame`) was the
    // second-largest cost in a sample of a scan that looked stuck. Checkpointing here — with no
    // transaction open and no cursor live, which is the only time it can fully succeed — puts the
    // pages back where a plain read finds them.
    //
    // `PASSIVE`, not `TRUNCATE`: truncation needs exclusive access and fails outright the moment
    // any reader is live — and since the UI thread now holds its own read connection (see
    // `Db.reader`), there almost always is one, so `TRUNCATE` logged `SQLiteLocked` and folded
    // back nothing at all. `PASSIVE` copies whatever frames it can without blocking anyone, which
    // is the useful part, and a busy database is a normal outcome rather than a fault.
    if (self.db) |d| {
        // `one`, not `exec`: `PRAGMA wal_checkpoint` *returns a row* (busy, log, checkpointed), and
        // this wrapper's `exec` panics on `SQLITE_ROW` because it expects a statement to complete
        // without producing one. That went unnoticed while this was `TRUNCATE`, which failed with
        // `SQLiteLocked` before ever reaching the row; switching to `PASSIVE` made it succeed, and
        // succeeding is what crashed the indexer.
        const Checkpoint = struct { busy: i64, log: i64, checkpointed: i64 };
        _ = d.conn.one(Checkpoint, "PRAGMA wal_checkpoint(PASSIVE)", .{}, .{}) catch |err| {
            log.debug("wal checkpoint skipped: {s}", .{@errorName(err)});
        };
    }

    // Resolve every link against the final note set and materialize phantoms — but only if the
    // walk actually moved something.
    //
    // Re-opening an unchanged vault used to redo the entire relink: 3.3 million links resolved and
    // written back to arrive at exactly the destinations already stored from last time. The
    // resolved `dst_id`s are durable, so there is nothing to recompute unless a note appeared,
    // vanished or had its links edited — all of which set `changed`. This is what makes the second
    // open of a large vault fast instead of a repeat of the first.
    if (self.quit.load(.acquire)) return;
    const relink_start = self.markNs();
    if (changed) try self.relinkAll();
    self.timings.relink_ns = self.sinceNs(relink_start);

    self.publishProgress(.publishing, 0, 0);
    sdk.refresh();
    const publish_start = self.markNs();
    try self.commitAndPublish();
    self.timings.publish_ns = self.sinceNs(publish_start);
    self.logTimings();
    // A quiet sweep skips the worker's own wake, so this is the only nudge the UI gets when a
    // background walk finds that something changed.
    sdk.refresh();
}

/// Markdown files under `directory`, applying the same filters `walk` does so the total and the
/// running count describe the same set. Metadata only: `Dir.iterate` yields the kind, so nothing
/// here opens or stats a file.
fn countMarkdown(self: *Indexer, io: std.Io, directory: []const u8) !u32 {
    if (self.quit.load(.acquire)) return 0;
    var dir = std.Io.Dir.cwd().openDir(io, directory, .{
        .access_sub_paths = true,
        .iterate = true,
    }) catch return 0;
    defer dir.close(io);

    var n: u32 = 0;
    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        if (self.quit.load(.acquire)) return n;
        if (entry.name.len > 0 and entry.name[0] == '.') continue;
        const abs = std.fs.path.join(self.gpa, &.{ directory, entry.name }) catch continue;
        defer self.gpa.free(abs);
        if (sdk.host().isPathIgnored(self.vault_root, abs, entry.name, entry.kind)) continue;
        switch (entry.kind) {
            .directory => n += self.countMarkdown(io, abs) catch 0,
            .file => if (query.isMarkdownPath(entry.name)) {
                n += 1;
            },
            else => {},
        }
    }
    return n;
}

fn walk(
    self: *Indexer,
    io: std.Io,
    directory: []const u8,
    seen: *std.StringHashMapUnmanaged(void),
    media_seen: *std.StringHashMapUnmanaged(void),
    files_since_commit: *usize,
    last_commit: *i96,
    changed: *bool,
    report_progress: bool,
) !void {
    if (self.quit.load(.acquire)) return;
    if (seen.count() >= max_notes) return;

    var dir = std.Io.Dir.cwd().openDir(io, directory, .{
        .access_sub_paths = true,
        .iterate = true,
    }) catch |err| {
        log.warn("open {s}: {s}", .{ directory, @errorName(err) });
        return;
    };
    defer dir.close(io);

    var rel_buf: [query.max_rel_path]u8 = undefined;
    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        if (self.quit.load(.acquire)) return;
        if (seen.count() >= max_notes) return;

        // Dotfiles / dot-dirs are never notes (`.obsidian`, `.git`, …).
        if (entry.name.len > 0 and entry.name[0] == '.') continue;

        const abs = try std.fs.path.join(self.gpa, &.{ directory, entry.name });
        defer self.gpa.free(abs);

        if (sdk.host().isPathIgnored(self.vault_root, abs, entry.name, entry.kind)) continue;

        switch (entry.kind) {
            .directory => try self.walk(io, abs, seen, media_seen, files_since_commit, last_commit, changed, report_progress),
            .file => {
                if (query.isMediaPath(entry.name)) {
                    // Attachments are recorded by path only — never opened, never parsed, and
                    // never linked into the note graph. All the index needs is enough to
                    // resolve and complete `![[diagram.png]]`.
                    const mrel = query.vaultRelative(self.vault_root, abs, &rel_buf) orelse continue;
                    const mrel_owned = try self.gpa.dupe(u8, mrel);
                    errdefer self.gpa.free(mrel_owned);
                    try media_seen.put(self.gpa, mrel_owned, {});
                    self.upsertMedia(mrel) catch |err| {
                        log.warn("index media {s}: {s}", .{ mrel, @errorName(err) });
                    };
                    continue;
                }
                if (!query.isMarkdownPath(entry.name)) continue;
                const rel = query.vaultRelative(self.vault_root, abs, &rel_buf) orelse continue;
                const rel_owned = try self.gpa.dupe(u8, rel);
                errdefer self.gpa.free(rel_owned);
                try seen.put(self.gpa, rel_owned, {});

                const outcome = self.indexOne(io, rel_owned) catch |err| blk: {
                    log.warn("index {s}: {s}", .{ rel_owned, @errorName(err) });
                    break :blk .unchanged;
                };
                if (outcome != .unchanged) changed.* = true;

                files_since_commit.* += 1;
                const now = std.Io.Clock.boot.now(io).nanoseconds;
                // Only stream progress once there is progress to stream. A sweep that finds
                // nothing must stay completely silent, or it republishes on the batch timer.
                if (files_since_commit.* >= batch_files or now - last_commit.* >= batch_ns) {
                    // Close the batch's transaction before publishing so the counts a reader sees
                    // describe durable state, then open the next one.
                    // Unconditionally, not `if (changed.*)`: committing a deferred transaction
                    // that never wrote is nearly free, and the conditional version left a
                    // transaction open across the entire walk whenever nothing had changed yet —
                    // which is precisely the re-open case, and exactly the shape of hold that
                    // blocks the UI thread's own queries on this connection.
                    self.endBatch();
                    self.beginBatch();
                    // Deliberately *not* gated on `changed`. Progress is about how far the walk has
                    // got, not about whether anything moved — and re-opening an already-indexed
                    // vault changes nothing at all, so gating this on `changed` meant the one case
                    // that most needs a progress count showed none: a bare "Building…" for as long
                    // as the whole scan took. A progress publish carries no graph (see
                    // `Snapshot.complete`), so it cannot cause the rebuild the old gate protected.
                    if (report_progress) {
                        self.publishProgress(.scanning, @intCast(seen.count()), self.scan_total.load(.acquire));
                    }
                    files_since_commit.* = 0;
                    last_commit.* = now;
                    sdk.refresh();
                }
            },
            else => {},
        }
    }
}

/// What indexing one queued item did, so the caller knows both *whether* to relink and *how
/// narrowly* it may. Worth the bookkeeping now that live buffers queue a reindex every ~300ms of
/// typing rather than once per 2s poll: a save re-sends bytes we already indexed, and republishing
/// that would re-query every note and edge for nothing.
const IndexOutcome = union(enum) {
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

fn indexPending(self: *Indexer, io: std.Io, item: Pending) !IndexOutcome {
    return self.indexOne(io, item.rel);
}

/// Index a note from bytes rather than from disk, stamping `mtime_ns = 0` so the disk path's
/// mtime/size early-out can never mistake the row for up to date — a later real read of the file
/// finds the same content hash and just refreshes the metadata.
///
/// No production caller: the app indexes saved files, never live buffers (see `Pending`). This is
/// the byte-level write path that `writeNote` and the relink hang off, kept as the entry point the
/// headless tests and `bench --index-edit` drive, since both need to write a note without one
/// existing on disk.
pub fn indexBuffer(self: *Indexer, rel: []const u8, bytes: []const u8) !IndexOutcome {
    const db = self.db orelse return .unchanged;
    const hash: i64 = @bitCast(std.hash.XxHash3.hash(0, bytes));
    const known = try lookupNoteMeta(db, rel);
    if (known) |meta| {
        // Same content we already hold — the usual case for the save that follows a typing
        // lull we already indexed.
        if (meta.hash == hash) return .unchanged;
    }
    const has_aliases = try self.writeNote(db, rel, bytes, 0, @intCast(bytes.len), hash);
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
    return .{ .rewrote = (try lookupNoteMeta(db, rel) orelse return .structural).id };
}

fn indexOne(self: *Indexer, io: std.Io, rel: []const u8) !IndexOutcome {
    const db = self.db orelse return .unchanged;

    const abs = try std.fs.path.join(self.gpa, &.{ self.vault_root, rel });
    defer self.gpa.free(abs);

    const stat_start = self.markNs();
    const st = std.Io.Dir.cwd().statFile(io, abs, .{}) catch {
        self.timings.stat_ns += self.sinceNs(stat_start);
        // Gone — delete the real note row if we had one. The graph loses a node, and every link
        // that pointed at it has to fall back to a phantom, so this is structural.
        try deleteNote(db, rel);
        return .structural;
    };
    if (st.size > max_file_bytes) return .unchanged;
    const mtime_ns: i64 = @truncate(st.mtime.nanoseconds);
    const size: i64 = @intCast(st.size);

    const known = try lookupNoteMeta(db, rel);
    if (known) |meta| {
        if (meta.mtime_ns == mtime_ns and meta.size == size) {
            self.timings.stat_ns += self.sinceNs(stat_start);
            self.timings.files_skipped += 1;
            return .unchanged;
        }
    }
    self.timings.stat_ns += self.sinceNs(stat_start);
    self.timings.files_read += 1;

    const read_start = self.markNs();
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, abs, self.gpa, .limited(max_file_bytes)) catch |err| {
        log.warn("read {s}: {s}", .{ rel, @errorName(err) });
        return .unchanged;
    };
    defer self.gpa.free(bytes);
    self.timings.read_ns += self.sinceNs(read_start);

    const hash: i64 = @bitCast(std.hash.XxHash3.hash(0, bytes));
    if (known) |meta| {
        if (meta.hash == hash) {
            // Metadata catch-up only — this is the save landing on a buffer we already
            // indexed (which stamped `mtime_ns = 0`). Nothing the graph draws moved.
            try touchNote(db, meta.id, mtime_ns, size);
            return .unchanged;
        }
    }
    const has_aliases = try self.writeNote(db, rel, bytes, mtime_ns, size, hash);
    // A file we already had: only its own links moved. A file we had not seen is a new node, and
    // links elsewhere may have been parked on a phantom waiting for it. Aliases are structural for
    // the reason spelled out in `indexBuffer`.
    if (!has_aliases) {
        if (known) |meta| return .{ .rewrote = meta.id };
    }
    return .structural;
}

/// Scan `bytes` and replace every derived row for `rel`. Shared by the disk and live-buffer
/// paths so the two can't drift in what they record.
/// Returns whether this note declares any front-matter aliases — see `ResolveCache`, which the
/// caller must not keep across a note that does.
fn writeNote(self: *Indexer, db: *Db, rel: []const u8, bytes: []const u8, mtime_ns: i64, size: i64, hash: i64) !bool {
    var arena = std.heap.ArenaAllocator.init(self.gpa);
    defer arena.deinit();
    const parse_start = self.markNs();
    const note = try Scanner.scan(arena.allocator(), bytes);
    self.timings.parse_ns += self.sinceNs(parse_start);

    const write_start = self.markNs();
    defer self.timings.write_ns += self.sinceNs(write_start);

    const stem = query.stemOf(rel);
    const note_id = try upsertNote(db, rel, stem, note.title, mtime_ns, size, hash);

    // Replace derived rows for this note. Every statement below is prepared once and reset per
    // use — see `Db.Stmts` for why that is the difference between minutes and hours here.
    const st = try db.cached();
    inline for (.{ "del_aliases", "del_headings", "del_links", "del_tags", "del_blocks" }) |name| {
        const stmt = &@field(st, name);
        stmt.reset();
        try stmt.exec(.{}, .{note_id});
    }

    for (note.aliases) |a| {
        st.ins_alias.reset();
        try st.ins_alias.exec(.{}, .{ note_id, a, try foldOwned(arena.allocator(), a) });
    }
    for (note.headings) |h| {
        st.ins_heading.reset();
        try st.ins_heading.exec(.{}, .{
            note_id, h.text, try foldOwned(arena.allocator(), h.text), h.level, h.line,
        });
    }
    for (note.tags) |t| {
        st.ins_tag.reset();
        try st.ins_tag.exec(.{}, .{
            note_id, t.tag, try foldOwned(arena.allocator(), t.tag), t.line,
        });
    }
    for (note.blocks) |b| {
        st.ins_block.reset();
        try st.ins_block.exec(.{}, .{
            note_id, @intFromEnum(b.kind), b.line_start, b.line_end, b.weight,
        });
    }
    // Links are written with `dst_id = src_id` as a temporary stand-in; `relinkAll` rewrites
    // destinations once every note is present (so a forward link to a file later in the walk
    // still resolves).
    for (note.links) |l| {
        st.ins_link.reset();
        try st.ins_link.exec(.{}, .{
            note_id,
            note_id,
            l.raw,
            l.heading,
            l.alias,
            @intFromEnum(l.kind),
            l.line,
            l.col,
        });
    }
    return note.aliases.len > 0;
}

fn logTimings(self: *const Indexer) void {
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
            t.files_read,   t.files_skipped,
            ms(t.prepass_ns), ms(t.walk_ns),
            ms(t.stat_ns),  ms(t.read_ns),
            ms(t.parse_ns), ms(t.write_ns),
            ms(t.drop_ns),
            ms(t.relink_ns), ms(t.publish_ns),
        },
    );
}

const RelinkRow = struct {
    rowid: i64,
    src_id: i64,
    raw: []const u8,
    heading: []const u8,
    src_path: []const u8,
    dst_id: i64,
    ambiguous: i32,
};

const RelinkUpdate = struct { rowid: i64, dst_id: i64, ambiguous: i32 };

/// Resolve every row `iter` yields, accumulating what needs writing. `iter` is `anytype` because
/// the scoped and unscoped statements are different types in this wrapper; the body must not be.
fn collectRelink(
    self: *Indexer,
    db: *Db,
    iter: anytype,
    candidates: []const resolve.Candidate,
    cand_index: *resolve.Index,
    id_by_path: *const std.StringHashMapUnmanaged(i64),
    updates: *std.ArrayList(RelinkUpdate),
    deletes: *std.ArrayList(i64),
    made_phantom: *bool,
) !void {
    var buf: [resolve.max_path_len]u8 = undefined;
    while (true) {
        var row_arena = std.heap.ArenaAllocator.init(self.gpa);
        defer row_arena.deinit();
        const row = (try iter.nextAlloc(row_arena.allocator(), .{})) orelse break;
        if (self.quit.load(.acquire)) return;

        // Drop edges that never should have been notes (e.g. `[x](foo.zig)` from older scans).
        if (!resolve.isNoteLikeTarget(row.raw)) {
            try deletes.append(self.gpa, row.rowid);
            continue;
        }

        const match = resolve.resolveIndexed(row.raw, row.src_path, candidates, cand_index, &buf);
        const dst_id: i64 = if (match) |m|
            id_by_path.get(candidates[m.index].path) orelse try ensurePhantom(db, row.raw, made_phantom)
        else
            try ensurePhantom(db, row.raw, made_phantom);
        const ambiguous: i32 = if (match) |m| @intFromBool(m.ambiguous) else 0;
        // Only write rows that actually change. A link whose destination already points where
        // resolution says it should is the overwhelming majority on any re-scan, and rewriting it
        // costs a b-tree update on `links_dst` to store the value already there.
        if (row.dst_id == dst_id and row.ambiguous == ambiguous) continue;
        try updates.append(self.gpa, .{ .rowid = row.rowid, .dst_id = dst_id, .ambiguous = ambiguous });
    }
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
/// discover what one note points at. Measured with `bench --index-edit`, that is 3.4 s of the 3.7 s
/// a single keystroke-debounce costs, against 0.6 ms to write the note's own rows. It is why an
/// edit appeared to do nothing: the next debounce fires long before the previous pass finishes, so
/// the graph never catches up while anyone is actually typing.
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

fn dropResolveCache(self: *Indexer) void {
    if (self.resolve_cache) |*c| c.deinit(self.gpa);
    self.resolve_cache = null;
}

/// The resolution inputs for the current note set, building them if they are not already held.
///
/// `rebuild` forces a fresh read — what `relinkAll` passes, since it is only ever reached when
/// something structural happened and the cached set is exactly what can no longer be trusted.
fn ensureResolveCache(self: *Indexer, db: *Db, rebuild: bool) !*ResolveCache {
    if (rebuild) self.dropResolveCache();
    if (self.resolve_cache) |*c| return c;

    var arena = std.heap.ArenaAllocator.init(self.gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    // Worker thread: the writer handle, never `Db.reader()` — see `query.loadCandidatesOn`.
    const candidates = try query.loadCandidatesOn(&db.conn, a);

    // Every note's id, by path, resolved once up front.
    //
    // This loop runs per *link* — 3.3 million times on a Wikipedia-scale vault — and it used to
    // ask the database for `SELECT id FROM notes WHERE path = ?` each time. A CPU sample of a scan
    // that appeared stuck put 79% of all samples inside that one query, and almost all of it in
    // `walFindFrame`: an indexed b-tree probe is cheap in principle, but each page it touches has
    // to be located in a write-ahead log that the walk has just made enormous.
    //
    // The information was already in hand. `loadCandidates` reads every non-phantom note's path a
    // few lines above, and resolution hands back a candidate — so the id was one column away the
    // whole time. One query and a hash map replace 3.3 million b-tree descents.
    var id_by_path: std.StringHashMapUnmanaged(i64) = .empty;
    errdefer id_by_path.deinit(self.gpa);
    {
        var stmt = try db.conn.prepare("SELECT path, id FROM notes WHERE phantom = 0");
        defer stmt.deinit();
        var iter = try stmt.iterator(struct { path: []const u8, id: i64 }, .{});
        while (true) {
            const row = (try iter.nextAlloc(a, .{})) orelse break;
            try id_by_path.put(self.gpa, row.path, row.id);
        }
    }

    // Built once for the whole relink: without it the resolve loop is one linear scan of every
    // note per link, which is the single most expensive thing the indexer does on a large vault.
    var index = try resolve.Index.init(self.gpa, candidates);
    errdefer index.deinit();

    self.resolve_cache = .{
        .arena = arena,
        .candidates = candidates,
        .index = index,
        .id_by_path = id_by_path,
    };
    return &self.resolve_cache.?;
}

/// Returns whether the note set grew — see `ensurePhantom`.
fn relinkScope(self: *Indexer, only_src: ?i64) !bool {
    const db = self.db orelse return false;

    const cache = try self.ensureResolveCache(db, only_src == null);
    const candidates = cache.candidates;
    const id_by_path = &cache.id_by_path;
    const cand_index = &cache.index;

    // Pull the links in scope and resolve them. Two statements rather than one with an
    // always-true predicate: the scoped form must hit `links_src`, and a `WHERE ? IS NULL OR
    // src_id = ?` would leave SQLite scanning the whole table to find one note's rows.
    const select_all =
        \\SELECT rowid, src_id, raw, heading,
        \\  (SELECT path FROM notes WHERE id = src_id),
        \\  dst_id, ambiguous
        \\FROM links
    ;
    const select_one = select_all ++ " WHERE src_id = ?";

    var made_phantom = false;

    // Collect updates / deletes first so we don't mutate while iterating.
    var updates: std.ArrayList(RelinkUpdate) = .empty;
    var deletes: std.ArrayList(i64) = .empty;
    defer updates.deinit(self.gpa);
    defer deletes.deinit(self.gpa);

    // The loop body is `collectRelink`, shared rather than written twice: the two statements differ
    // only in their `WHERE`, and a resolution rule that held for one scope and not the other would
    // be a silent divergence between the interactive path and the full pass.
    if (only_src) |src| {
        var stmt = try db.conn.prepare(select_one);
        defer stmt.deinit();
        var iter = try stmt.iterator(RelinkRow, .{src});
        try self.collectRelink(db, &iter, candidates, cand_index, id_by_path, &updates, &deletes, &made_phantom);
    } else {
        var stmt = try db.conn.prepare(select_all);
        defer stmt.deinit();
        var iter = try stmt.iterator(RelinkRow, .{});
        try self.collectRelink(db, &iter, candidates, cand_index, id_by_path, &updates, &deletes, &made_phantom);
    }

    // Prepared statements for the write-back, and a transaction **per chunk** — never one
    // transaction around the whole thing.
    //
    // Both halves of that matter and they pull in opposite directions. Without the statements,
    // 3.3 million `conn.exec` calls each compile the SQL afresh and commit their own implicit
    // transaction, which is what made a re-open look like it had hung. But wrapping the lot in a
    // single transaction to fix that is worse in a way that is easy to miss headlessly: the UI
    // thread queries this same connection during a frame (`backlinksFor`, `noteContentGraph`), and
    // SQLite serializes a connection — so one transaction spanning millions of rows blocks every
    // UI query for its whole duration. That is a beachball, not a slow frame.
    //
    // Chunking keeps essentially all of the batching win (the per-commit cost is amortized over
    // 20,000 rows) while giving the UI thread a gap to get in every few milliseconds.
    const relink_chunk = 20_000;
    const st = try db.cached();

    self.beginBatch();
    for (deletes.items, 0..) |rowid, i| {
        st.del_link_row.reset();
        st.del_link_row.exec(.{}, .{rowid}) catch |err| {
            self.endBatch();
            return err;
        };
        if ((i + 1) % relink_chunk == 0) {
            self.endBatch();
            // Cancellation lands on the chunk boundary, where the transaction is closed and the
            // database is consistent. Without it `stop()` sets `quit` and then blocks the *UI
            // thread* in `pthread_join` until millions of rows have been written — which is what
            // froze the app when switching vaults mid-relink.
            if (self.quit.load(.acquire)) return made_phantom;
            self.beginBatch();
        }
    }
    self.endBatch();
    if (self.quit.load(.acquire)) return made_phantom;

    self.beginBatch();
    for (updates.items, 0..) |u, i| {
        st.update_link.reset();
        st.update_link.exec(.{}, .{ u.dst_id, u.ambiguous, u.rowid }) catch |err| {
            self.endBatch();
            return err;
        };
        if ((i + 1) % relink_chunk == 0) {
            self.endBatch();
            if (self.quit.load(.acquire)) return made_phantom;
            // The write-back is long enough on a large vault to need its own progress, or the
            // spinner sits on the last scan number for minutes with nothing to say.
            self.publishProgress(.resolving, @intCast(i + 1), @intCast(updates.items.len));
            sdk.refresh();
            self.beginBatch();
        }
    }
    self.endBatch();

    try purgeNonNotePhantoms(db, self.gpa);
    try query.purgeOrphanPhantoms(db);
    return made_phantom;
}

/// Record one media file by path. No read, no hash — an attachment has no contents the index
/// cares about, only a name to resolve `![[…]]` against.
fn upsertMedia(self: *Indexer, rel: []const u8) !void {
    const db = self.db orelse return;
    var arena = std.heap.ArenaAllocator.init(self.gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const name = if (std.mem.lastIndexOfScalar(u8, rel, '/')) |s| rel[s + 1 ..] else rel;
    const dot = std.mem.lastIndexOfScalar(u8, name, '.');
    const stem = if (dot) |d| name[0..d] else name;

    try db.conn.exec(
        \\INSERT INTO media(path, stem, stem_fold, name_fold) VALUES(?, ?, ?, ?)
        \\ON CONFLICT(path) DO UPDATE SET stem = excluded.stem,
        \\  stem_fold = excluded.stem_fold, name_fold = excluded.name_fold
    , .{}, .{ rel, stem, try foldOwned(a, stem), try foldOwned(a, name) });
}

/// Returns true if anything was dropped.
fn dropMissingMedia(self: *Indexer, seen: *std.StringHashMapUnmanaged(void)) !bool {
    return self.dropMissingRows(
        "SELECT id, path FROM media",
        "DELETE FROM media WHERE id = ?",
        seen,
    );
}

/// Rows whose file is gone from disk, deleted in interruptible chunks.
///
/// Callers must have established that `seen` describes a *complete* walk — see `runFullScan`.
///
/// Two things here are load-bearing, and both are the lesson `relinkAll`'s write-back already
/// learned. The deletes run in chunked transactions rather than one implicit transaction each,
/// because a row at a time re-compiles the statement and commits its own WAL frame every time; and
/// the chunk boundary is where cancellation lands, because the alternative is `stop()` blocking the
/// UI thread in `pthread_join` until every last cascade has been written.
///
/// Not one transaction for the whole set either: this connection is the one the UI thread queries
/// during a frame, and SQLite serializes a connection, so a single transaction over a large delete
/// blocks every UI query for its duration.
fn dropMissingRows(
    self: *Indexer,
    comptime select_sql: []const u8,
    comptime delete_sql: []const u8,
    seen: *std.StringHashMapUnmanaged(void),
) !bool {
    const db = self.db orelse return false;

    var to_delete: std.ArrayList(i64) = .empty;
    defer to_delete.deinit(self.gpa);

    {
        // One arena for the whole read, reset per row rather than created and destroyed per row.
        // The old shape was an mmap/munmap pair for every note in the vault, purely to hold one
        // path string that is dead by the next iteration.
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();

        var stmt = try db.conn.prepare(select_sql);
        defer stmt.deinit();
        var iter = try stmt.iterator(struct { id: i64, path: []const u8 }, .{});
        while (true) {
            _ = arena.reset(.retain_capacity);
            const row = (try iter.nextAlloc(arena.allocator(), .{})) orelse break;
            if (!seen.contains(row.path)) try to_delete.append(self.gpa, row.id);
        }
    }
    if (to_delete.items.len == 0) return false;
    if (self.quit.load(.acquire)) return false;

    var stmt = try db.conn.prepare(delete_sql);
    defer stmt.deinit();

    self.beginBatch();
    for (to_delete.items, 0..) |id, i| {
        stmt.reset();
        stmt.exec(.{}, .{id}) catch |err| {
            self.endBatch();
            return err;
        };
        if ((i + 1) % drop_chunk == 0) {
            self.endBatch();
            // Consistent here: the transaction is closed and the rows either went or did not.
            if (self.quit.load(.acquire)) return true;
            self.beginBatch();
        }
    }
    self.endBatch();
    return true;
}

/// Deletes per transaction in `dropMissingRows`. Same size and same reasoning as `relink_chunk`.
const drop_chunk: usize = 20_000;

/// Returns true if anything was dropped.
fn dropMissing(self: *Indexer, seen: *std.StringHashMapUnmanaged(void)) !bool {
    return self.dropMissingRows(
        "SELECT id, path FROM notes WHERE phantom = 0",
        "DELETE FROM notes WHERE id = ?",
        seen,
    );
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
/// Open a write transaction for a batch of note writes. Best-effort: if SQLite refuses (already
/// in a transaction, database busy) the writes still happen, just one implicit transaction each,
/// which is the behaviour this replaces. Never fail a scan over a speed optimization.
fn beginBatch(self: *Indexer) void {
    const db = self.db orelse return;
    db.conn.exec("BEGIN", .{}, .{}) catch |err| {
        log.warn("begin batch: {s}", .{@errorName(err)});
    };
}

fn endBatch(self: *Indexer) void {
    const db = self.db orelse return;
    db.conn.exec("COMMIT", .{}, .{}) catch |err| {
        log.warn("commit batch: {s}", .{@errorName(err)});
    };
}

fn publishProgress(self: *Indexer, phase: Phase, done: u32, total: u32) void {
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
    const db = self.db orelse return;
    // Building the snapshot is a full read of every note and every link — seconds on a large
    // vault, and pure waste if the vault is being closed. The UI thread is joining this worker.
    if (self.quit.load(.acquire)) return;
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

    const nodes = try loadSnapNodes(db, arena);
    const edges = try loadSnapEdges(db, arena);
    const snap = Snapshot{
        .note_count = try countOf(db, "SELECT count(*) FROM notes WHERE phantom = 0"),
        // From the rows just read, not a second full scan of `links` for a number we hold.
        .link_count = @intCast(edges.len),
        .phantom_count = try countOf(db, "SELECT count(*) FROM notes WHERE phantom = 1"),
        .nodes = nodes,
        .edges = edges,
        .complete = true,
        .scan_total = self.scan_total.load(.acquire),
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
fn publishCandidates(self: *Indexer) void {
    // Cleared whatever happens. A UI thread waiting on this flag must not wait forever because a
    // build failed or the vault closed underneath it.
    defer self.cand_pending.store(false, .release);
    const db = self.db orelse return;
    const set = self.buildCandidates(db, self.gpa) catch |err| {
        log.warn("build candidates: {s}", .{@errorName(err)});
        return;
    };
    self.cand_mutex.lockUncancelable(dvui.io);
    defer self.cand_mutex.unlock(dvui.io);
    if (self.cand_handoff) |*old| old.deinit();
    self.cand_handoff = set;
}

fn buildCandidates(self: *Indexer, db: *Db, gpa: std.mem.Allocator) !CandidateSet {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    // Copy the note list out of `ResolveCache` when it is warm, rather than reading every note back
    // out of SQLite for the second time this publish.
    //
    // The two lists are the same query — `loadCandidatesOn` — and the cache is invalidated by
    // exactly the events that can change it, so a warm cache *is* the answer. It cannot simply be
    // handed over: the UI takes ownership of a `CandidateSet` and outlives any given publish, while
    // the cache belongs to the worker and is dropped whenever the note set moves. So this copies,
    // which is a memcpy of the strings against a full table scan and a few hundred thousand row
    // decodes — the whole point being that the *query* was the cost, not the bytes.
    const notes = if (self.resolve_cache) |*c| dupeCandidates(a, c.candidates) catch |err| blk: {
        log.warn("copy cached candidates: {s}; re-reading", .{@errorName(err)});
        break :blk try query.loadCandidatesOn(&db.conn, a);
    } else
        // `db.conn`, not `db.reader()`: the read connection belongs to the UI thread and is opened
        // on first use, so reaching for it here races that lazy init.
        try query.loadCandidatesOn(&db.conn, a);

    const media = try query.loadMediaCandidatesOn(&db.conn, a);
    return .{ .notes = notes, .media = media, .arena = arena };
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

fn loadSnapNodes(db: *Db, arena: std.mem.Allocator) ![]const SnapNode {
    // Degree = distinct neighbours via a UNION so a mutual link isn't counted twice.
    // No degree here. It used to be computed in SQL — first as a correlated `UNION` subquery per
    // note, then as one grouped pass — and both were the largest single cost of publishing a
    // snapshot on a 283,878-note vault, because both have to touch all 3.3M links to answer a
    // question the *consumer* can answer for free. `graph.zig`'s rebuild already collapses every
    // edge onto its unordered `(min,max)` pair to build its own edge list, which is precisely
    // "distinct neighbours (in ∪ out)", so it counts degree there in one pass over an array it has
    // in hand. `SnapNode.degree` survives for `publishSynthetic`, which is handed real degrees.
    var stmt = try db.conn.prepare(
        \\SELECT n.id, n.path, n.title, n.stem, n.phantom, 0 AS degree, n.size
        \\FROM notes n
    );
    defer stmt.deinit();

    // Same reservation as the edge loader: 286k appends to an empty list is a couple of dozen
    // reallocate-and-copy passes. `nextAlloc` is required here — `path` and `stem` are real
    // strings and the snapshot owns them.
    const n = (try db.conn.one(usize, "SELECT count(*) FROM notes", .{}, .{})) orelse 0;

    var list: std.ArrayList(SnapNode) = .empty;
    try list.ensureTotalCapacity(arena, n);
    var iter = try stmt.iterator(struct {
        id: i64,
        path: []const u8,
        title: []const u8,
        stem: []const u8,
        phantom: i64,
        degree: i64,
        size: i64,
    }, .{});
    while (true) {
        const row = (try iter.nextAlloc(arena, .{})) orelse break;
        const title = if (row.title.len > 0) row.title else row.stem;
        try list.append(arena, .{
            .id = row.id,
            .path = row.path,
            .title = title,
            .phantom = row.phantom != 0,
            .degree = @intCast(@max(row.degree, 0)),
            .size = @intCast(@max(row.size, 0)),
        });
    }
    return list.toOwnedSlice(arena);
}

fn loadSnapEdges(db: *Db, arena: std.mem.Allocator) ![]const SnapEdge {
    // No `DISTINCT`: it forces a sort or a temp b-tree over every link in the vault, and the
    // consumer already dedups. `graph.zig`'s rebuild folds each pair into a `seen` set keyed on
    // the unordered `(min, max)` index pair — which is strictly stronger than `DISTINCT src, dst`,
    // since it also collapses A→B against B→A. Paying for a sort to remove a subset of what the
    // reader removes anyway is pure cost.
    // Reserve first. Growing an ArrayList to 3.3M entries reallocates and copies a 50 MB buffer
    // a couple of dozen times on the way; one count query is far cheaper than that.
    const n = (try db.conn.one(usize, "SELECT count(*) FROM links", .{}, .{})) orelse 0;

    var stmt = try db.conn.prepare("SELECT src_id, dst_id FROM links");
    defer stmt.deinit();

    var list: std.ArrayList(SnapEdge) = .empty;
    try list.ensureTotalCapacity(arena, n);

    // `next`, not `nextAlloc`. The row is two integers — there is nothing to allocate — but the
    // allocating path was being run once per link anyway. At 3.3M links that alone was most of the
    // "Preparing graph…" wait.
    var iter = try stmt.iterator(struct { src_id: i64, dst_id: i64 }, .{});
    while (true) {
        const row = (try iter.next(.{})) orelse break;
        list.appendAssumeCapacity(.{ .src_id = row.src_id, .dst_id = row.dst_id });
    }
    return list.toOwnedSlice(arena);
}

// -- SQL helpers ------------------------------------------------------------------

const NoteMeta = struct { id: i64, mtime_ns: i64, size: i64, hash: i64 };

fn lookupNoteMeta(db: *Db, path: []const u8) !?NoteMeta {
    const st = try db.cached();
    st.note_by_path.reset();
    const meta = try st.note_by_path.one(NoteMeta, .{}, .{path});
    // Reset *after* as well, which the general rule in `Db.Stmts` deliberately does not do.
    //
    // `one` stops the moment it has a row, so a lookup that finds one leaves the statement parked
    // mid-scan with a live read cursor on `notes` — and reset-before-use means it stays parked
    // until the *next* note is looked up. After the walk's last file there is no next note, so an
    // open read transaction sits on the writer connection for the whole of `dropMissing`, the
    // checkpoint, the relink and the publish. That is not theoretical: it made the post-walk
    // `PRAGMA wal_checkpoint(PASSIVE)` fail with `SQLITE_LOCKED` on every re-open (the case the
    // checkpoint exists for), and an open read transaction also pins the WAL against reset, so it
    // grows for as long as the session lasts.
    //
    // Safe here only because `NoteMeta` is four integers. A row with a `[]const u8` in it would be
    // pointing into the statement's own memory, and resetting would free it out from under the
    // caller — which is why this is a fix at this call site and not a change to the shared rule.
    st.note_by_path.reset();
    return meta;
}

fn touchNote(db: *Db, id: i64, mtime_ns: i64, size: i64) !void {
    const st = try db.cached();
    st.touch_note.reset();
    try st.touch_note.exec(.{}, .{ mtime_ns, size, id });
}

fn upsertNote(
    db: *Db,
    path: []const u8,
    stem: []const u8,
    title: []const u8,
    mtime_ns: i64,
    size: i64,
    hash: i64,
) !i64 {
    // Promote a phantom with this stem if one exists, else insert / update by path.
    //
    // A stack buffer, not an arena on `page_allocator`: this runs once per file, and that arena
    // was an mmap/munmap pair per note purely to hold one case-folded stem. Anything longer than
    // the buffer falls back to the heap, which a note name never reaches in practice.
    var fold_buf: [512]u8 = undefined;
    var fold_fba = std.heap.FixedBufferAllocator.init(&fold_buf);
    var fold_arena = std.heap.ArenaAllocator.init(fold_fba.allocator());
    var heap_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer heap_arena.deinit();
    const stem_fold = foldOwned(fold_arena.allocator(), stem) catch
        try foldOwned(heap_arena.allocator(), stem);

    const st = try db.cached();

    // Both lookups reset again once they have their id, for the reason spelled out in
    // `lookupNoteMeta`: a `one` that finds a row stops on it and leaves a read cursor open. Here
    // that cursor is on `notes` and the very next statement *writes* `notes` — reading a table
    // through one cursor while writing it through another, on a single connection, is a shape to
    // stay out of even where SQLite tolerates it. Ids are integers, so nothing borrows the row.
    st.note_id_by_path.reset();
    const by_path = try st.note_id_by_path.one(i64, .{}, .{path});
    st.note_id_by_path.reset();
    if (by_path) |id| {
        st.update_note.reset();
        try st.update_note.exec(.{}, .{ stem, stem_fold, title, mtime_ns, size, hash, id });
        return id;
    }

    st.phantom_by_stem.reset();
    const by_stem = try st.phantom_by_stem.one(i64, .{}, .{stem_fold});
    st.phantom_by_stem.reset();
    if (by_stem) |id| {
        st.promote_phantom.reset();
        try st.promote_phantom.exec(.{}, .{ path, stem, stem_fold, title, mtime_ns, size, hash, id });
        return id;
    }

    st.insert_note.reset();
    try st.insert_note.exec(.{}, .{ path, stem, stem_fold, title, mtime_ns, size, hash });
    return (try db.conn.one(i64, "SELECT last_insert_rowid()", .{}, .{})) orelse return error.NoRowId;
}

fn deleteNote(db: *Db, path: []const u8) !void {
    try db.conn.exec("DELETE FROM notes WHERE path = ? AND phantom = 0", .{}, .{path});
}

/// `created` is raised when this call *inserts* a phantom row, i.e. when the note set grew. The
/// caller needs that: a publish can only reuse the previous snapshot's node array when nothing
/// added or removed a node, and a link to a page nobody has written does exactly that.
fn ensurePhantom(db: *Db, raw_target: []const u8, created: *bool) !i64 {
    // Callers should already filter; belt-and-braces so `.zig` never becomes a graph node.
    if (!resolve.isNoteLikeTarget(raw_target)) return error.NotANote;

    const norm = resolve.normalize(raw_target);
    if (norm.text.len == 0) {
        // Degenerate — point at a shared empty phantom.
        if (try db.conn.one(i64, "SELECT id FROM notes WHERE phantom = 1 AND stem_fold = '' LIMIT 1", .{}, .{})) |id| return id;
        created.* = true;
        try db.conn.exec(
            "INSERT INTO notes(path, stem, stem_fold, title, phantom) VALUES('', '', '', '', 1)",
            .{},
            .{},
        );
        return (try db.conn.one(i64, "SELECT last_insert_rowid()", .{}, .{})) orelse error.NoRowId;
    }

    const stem = blk: {
        if (std.mem.lastIndexOfScalar(u8, norm.text, '/')) |slash| break :blk norm.text[slash + 1 ..];
        break :blk norm.text;
    };
    var fold_buf: [resolve.max_path_len]u8 = undefined;
    if (stem.len > fold_buf.len) return error.PathTooLong;
    const stem_fold = query.foldInto(&fold_buf, stem);

    if (try db.conn.one(
        i64,
        "SELECT id FROM notes WHERE phantom = 1 AND stem_fold = ? LIMIT 1",
        .{},
        .{stem_fold},
    )) |id| return id;

    created.* = true;
    try db.conn.exec(
        "INSERT INTO notes(path, stem, stem_fold, title, phantom) VALUES('', ?, ?, ?, 1)",
        .{},
        .{ stem, stem_fold, stem },
    );
    return (try db.conn.one(i64, "SELECT last_insert_rowid()", .{}, .{})) orelse error.NoRowId;
}

/// Remove phantoms that look like non-note files (leftovers from when markdown links to
/// `.zig` / images were indexed). Cascades drop their edges.
fn purgeNonNotePhantoms(db: *Db, gpa: std.mem.Allocator) !void {
    var stmt = try db.conn.prepare("SELECT id, stem, title FROM notes WHERE phantom = 1");
    defer stmt.deinit();
    var iter = try stmt.iterator(struct { id: i64, stem: []const u8, title: []const u8 }, .{});

    var drop: std.ArrayList(i64) = .empty;
    defer drop.deinit(gpa);

    while (true) {
        var row_arena = std.heap.ArenaAllocator.init(gpa);
        defer row_arena.deinit();
        const row = (try iter.nextAlloc(row_arena.allocator(), .{})) orelse break;
        // Shared empty placeholder from degenerate targets — keep it.
        if (row.stem.len == 0) continue;
        const label = if (row.title.len > 0) row.title else row.stem;
        // Stem is stored without `.md`; a leftover `foo.zig` phantom still has that in stem.
        if (!resolve.isNoteLikeTarget(label) or !resolve.isNoteLikeTarget(row.stem)) {
            try drop.append(gpa, row.id);
        }
    }
    for (drop.items) |id| {
        try db.conn.exec("DELETE FROM notes WHERE id = ?", .{}, .{id});
    }
}

fn countOf(db: *Db, comptime sql: []const u8) !u32 {
    const n = try db.conn.one(i64, sql, .{}, .{});
    return @intCast(n orelse 0);
}

// -- path helpers -----------------------------------------------------------------

fn foldOwned(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    const out = try arena.alloc(u8, s.len);
    return query.foldInto(out, s);
}

// -- tests ------------------------------------------------------------------------
//
// These drive the real write path (`indexBuffer` → `writeNote` → `relinkAll`) against real
// sqlite. Everything the graph draws comes out of `links`, so "does removing a wikilink
// actually remove the row" is not something a unit test of the scanner can answer.

const testing = std.testing;

const TestVault = struct {
    tmp: std.testing.TmpDir,
    dir: [:0]u8,
    threaded: std.Io.Threaded,
    db: Db,
    busy: std.atomic.Value(bool) = .init(false),
    gen: std.atomic.Value(u64) = .init(0),
    indexer: Indexer = undefined,

    fn create(gpa: std.mem.Allocator) !*TestVault {
        const self = try gpa.create(TestVault);
        errdefer gpa.destroy(self);
        self.* = .{
            .tmp = std.testing.tmpDir(.{}),
            .dir = undefined,
            .threaded = std.Io.Threaded.init_single_threaded,
            .db = undefined,
        };
        self.dir = try self.tmp.dir.realPathFileAlloc(self.threaded.io(), ".", gpa);
        self.db = try Db.openIn(gpa, self.threaded.io(), self.dir, "/vault");
        self.indexer = Indexer.init(gpa, &self.busy, &self.gen);
        self.indexer.db = &self.db;
        self.indexer.vault_root = "/vault";
        return self;
    }

    fn destroy(self: *TestVault, gpa: std.mem.Allocator) void {
        // The indexer owns the two snapshot arenas, which only exist once something has actually
        // published. No test did until the completeness gate needed one, so this was missing and
        // the leak had never had a chance to show up.
        self.indexer.deinit();
        self.db.close(gpa);
        gpa.free(self.dir);
        self.tmp.cleanup();
        gpa.destroy(self);
    }

    /// One incremental edit, exactly as the worker runs it for a live editor buffer.
    fn write(self: *TestVault, rel: []const u8, body: []const u8) !void {
        _ = try self.indexer.indexBuffer(rel, body);
        try self.indexer.relinkAll();
    }

    fn noteCount(self: *TestVault) !usize {
        return (try self.db.conn.one(usize, "SELECT count(*) FROM notes WHERE phantom = 0", .{}, .{})) orelse 0;
    }

    fn edgeCount(self: *TestVault) !usize {
        return (try self.db.conn.one(usize, "SELECT count(*) FROM links", .{}, .{})) orelse 0;
    }

    /// Edges as the graph sees them, i.e. excluding the `dst_id = src_id` self-loop stand-in.
    fn realEdgeCount(self: *TestVault) !usize {
        return (try self.db.conn.one(
            usize,
            "SELECT count(*) FROM links WHERE dst_id <> src_id",
            .{},
            .{},
        )) orelse 0;
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
        (try v.db.conn.one(usize, "SELECT count(*) FROM notes WHERE phantom = 1", .{}, .{})).?,
    );

    try v.write("README.md", "# Readme\n");
    try testing.expectEqual(@as(usize, 0), try v.edgeCount());
    try testing.expectEqual(
        @as(usize, 0),
        (try v.db.conn.one(usize, "SELECT count(*) FROM notes WHERE phantom = 1", .{}, .{})).?,
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

    // `stop` clears `db`; put it back so `destroy` tears down the same way every other test does.
    v.indexer.db = &v.db;
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
    const want = try query.loadCandidatesOn(&v.db.conn, arena.allocator());
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
    var gen = std.atomic.Value(u64).init(0);
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
    var gen = std.atomic.Value(u64).init(0);
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
