//! Plugin-owned state: the open vault and everything derived from it.
//!
//! One instance, created in `register` and torn down in `deinit`. Everything keyed to a
//! particular open folder lives behind `vault` and is rebuilt from scratch on `onFolderOpen` —
//! the filesystem is the source of truth, so there is nothing here worth preserving across a
//! folder switch.
//!
//! **Synth mode** (`loadSynth`) publishes an in-memory graph for Galaxy scale tests without
//! markdown on disk. Packed positions skip force layout; clear with `clearSynth` / folder open.
const std = @import("std");
const dvui = @import("dvui");
const sdk = @import("fizzy_sdk");

const Db = @import("index/Db.zig");
const Indexer = @import("index/Indexer.zig");
const Watcher = @import("index/Watcher.zig");
const cache_dir = @import("index/cache_dir.zig");
const query = @import("index/query.zig");
const resolve = @import("index/resolve.zig");
const Scanner = @import("index/Scanner.zig");
const Settings = @import("Settings.zig");
const vault_synth = @import("ui/vault_synth.zig");

const Schema = sdk.settings.Schema(Settings);

const State = @This();

/// Persisted via `Host.loadPluginSettings`/`storePluginSettings` — see `Settings.zig`.
settings: Settings = .{},

/// Set only for the duration of the explicit "convert wikilinks" command. atlas owns no
/// markdown documents, so it can't apply the edit itself — it delegates to the owner's format
/// command, which routes back into atlas's `format` hook. Without this the round trip would be
/// gated by the on-save setting, and the explicit command would silently do nothing whenever
/// that setting was off, which is exactly when someone reaches for it.
force_convert: bool = false,

/// Absolute path of the open project folder, or null when none is open. Owned.
vault_root: ?[]u8 = null,

/// The index for `vault_root`. Null when no folder is open, or when the index could not be
/// opened at all — atlas degrades to "resolves nothing" rather than refusing to load, since a
/// broken cache directory shouldn't cost the user their editor.
db: ?Db = null,

/// Background walker/writer. Lives for the life of the State; `start`/`stop` track the vault.
indexer: Indexer = undefined,
indexer_ready: bool = false,

/// Routes fizzy's filesystem events into the indexer, and polls open markdown docs as a backup.
watcher: Watcher = undefined,
watcher_ready: bool = false,

/// Bumped on every committed change to the index. Consumers (the markdown renderer, the
/// backlinks view) memoize against this and drop their caches when it moves — see
/// `sdk.services.wikilink.Api.generation`. Atomic because the indexer thread will write it
/// while the UI thread reads it.
generation: std.atomic.Value(u64) = .init(0),

/// True while a scan is in flight.
busy: std.atomic.Value(bool) = .init(false),

/// Candidate list for `resolve.resolve`, rebuilt on the UI thread whenever `generation` moves.
/// Lives in `cand_arena` so a rebuild is one reset.
cand_arena: std.heap.ArenaAllocator = undefined,
cand_ready: bool = false,
cand_gen: u64 = std.math.maxInt(u64),
candidates: []const resolve.Candidate = &.{},
/// Media (image) candidates, loaded from the same arena and generation as `candidates`.
/// Separate list so an embed resolves against attachments and a plain wikilink against notes,
/// with no precedence rule that could land `[[Target]]` on `Target.png`.
media_candidates: []const resolve.Candidate = &.{},

/// Unsaved buffer overlays: absolute path → owned bytes. Populated by `documentContentChanged`;
/// dropped when the document closes (`reconcileDirty`) or the vault does. The index still
/// reflects disk; this is a read-time overlay so a newly typed `[[Link]]` can show up in
/// backlinks before save.
dirty: std.StringHashMapUnmanaged([]u8) = .empty,
dirty_gpa: std.mem.Allocator = undefined,

/// In-memory scale vault (Atlas: Load Synth Graph). When set, the graph uses packed positions
/// and the indexer snapshot is synthetic — not the open folder's SQLite index.
synth_mode: bool = false,
/// Packed world positions parallel to synth note ids `1..N` (graph order after id-sort). Owned.
synth_pos: ?[]dvui.Point = null,
/// When non-null, countdown of `endFrame` ticks until a background regen is kicked off.
synth_reload_frames: ?u32 = null,
/// Spec fingerprint last applied — skip no-op reloads when only unrelated settings changed.
synth_applied_key: u64 = 0,
/// Background synth build. Previous graph stays on screen until this applies (or is cancelled).
synth_job: ?*SynthJob = null,

/// Quantize the note-count slider so tiny drags don't thrash 500k regenerations.
pub fn quantizedSynthNotes(raw: i64) usize {
    const x: usize = @intCast(std.math.clamp(raw, 100, 1_000_000));
    if (x <= 20_000) return @max(100, (x + 500) / 1000 * 1000);
    if (x <= 200_000) return (x + 5_000) / 10_000 * 10_000;
    return (x + 25_000) / 50_000 * 50_000;
}

const SynthJob = struct {
    gpa: std.mem.Allocator,
    key: u64,
    /// Snapshot of settings at spawn — worker must not race the UI settings cells.
    n: usize,
    shape: vault_synth.Shape,
    avg_deg: f32,
    cancel: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    /// First claimer (UI poll/cancel or cancelled worker) frees the job.
    claimed: std.atomic.Value(bool) = .init(false),
    fail: ?anyerror = null,
    thread: ?std.Thread = null,

    positions: ?[]dvui.Point = null,
    degrees: ?[]u32 = null,
    edges: ?[]Indexer.SnapEdge = null,
    /// Owned parallel titles (may be empty strings).
    titles: ?[][]const u8 = null,
    title_arena: ?std.heap.ArenaAllocator = null,
    shape_label: []const u8 = "",
    avg_deg_actual: f32 = 0,
    max_degree: u32 = 0,
    components: usize = 0,

    fn tryClaim(self: *SynthJob) bool {
        return !self.claimed.swap(true, .acq_rel);
    }

    fn discardResults(self: *SynthJob) void {
        if (self.positions) |p| self.gpa.free(p);
        if (self.degrees) |d| self.gpa.free(d);
        if (self.edges) |e| self.gpa.free(e);
        if (self.title_arena) |*a| a.deinit();
        self.positions = null;
        self.degrees = null;
        self.edges = null;
        self.titles = null;
        self.title_arena = null;
    }

    fn destroy(self: *SynthJob) void {
        self.discardResults();
        self.gpa.destroy(self);
    }
};

pub fn init(self: *State, gpa: std.mem.Allocator) void {
    self.indexer = Indexer.init(gpa, &self.busy, &self.generation);
    self.indexer_ready = true;
    self.watcher = Watcher.init(gpa, &self.indexer);
    self.watcher_ready = true;
    self.cand_arena = std.heap.ArenaAllocator.init(gpa);
    self.cand_ready = true;
    self.dirty_gpa = gpa;
}

pub fn deinit(self: *State, gpa: std.mem.Allocator) void {
    self.closeVault(gpa);
    if (self.watcher_ready) self.watcher.deinit();
    self.watcher_ready = false;
    if (self.indexer_ready) self.indexer.deinit();
    self.indexer_ready = false;
    if (self.cand_ready) self.cand_arena.deinit();
    self.cand_ready = false;
    self.clearDirty();
    self.dirty.deinit(gpa);
}

pub fn openVault(self: *State, gpa: std.mem.Allocator, root: []const u8) !void {
    // Opening the folder that is already open is nothing at all. The host sends this whenever a
    // folder is *chosen* — picking the current one out of the recents list counts — and without
    // this guard that choice tore the vault down and built it again from nothing: the index
    // closed and reopened, the indexer restarted, and the generation counter moved, which is the
    // signal every consumer watches. The graph rebuilds on it, so a click that changed nothing
    // re-solved the whole layout and faded every label out and back in.
    //
    // A failed open is not a state worth protecting, so a retry after one still goes through:
    // `db` is null exactly then, and asking for the same folder again is the obvious way a
    // reader would expect to retry. Deliberately re-reading a vault that opened fine is what the
    // "rebuild index" command is for.
    if (self.vault_root) |current| {
        if (self.db != null and !self.synth_mode and std.mem.eql(u8, current, root)) return;
    }
    self.closeVault(gpa);
    self.vault_root = try gpa.dupe(u8, root);
    errdefer {
        gpa.free(self.vault_root.?);
        self.vault_root = null;
    }

    self.db = openIndex(gpa, root) catch |err| blk: {
        std.log.scoped(.atlas).err("could not open index for {s}: {s}", .{ root, @errorName(err) });
        break :blk null;
    };

    if (self.db) |*db| {
        if (self.indexer_ready) {
            self.indexer.start(db, self.vault_root.?) catch |err| {
                std.log.scoped(.atlas).err("could not start indexer: {s}", .{@errorName(err)});
            };
        }
        if (self.watcher_ready) self.watcher.setVault(self.vault_root.?);
    }
}

fn openIndex(gpa: std.mem.Allocator, root: []const u8) !Db {
    const dir = try cache_dir.forVault(gpa, root);
    defer gpa.free(dir);
    // Opening the cache file is a one-shot FS op; a private threaded Io keeps State free of
    // dvui so the rest of the index stack stays headless-testable.
    var threaded = std.Io.Threaded.init_single_threaded;
    return Db.openIn(gpa, threaded.io(), dir, root);
}

pub fn closeVault(self: *State, gpa: std.mem.Allocator) void {
    self.dropSynth(gpa);
    if (self.watcher_ready) self.watcher.clear();
    // Join first — the worker holds `db` and must finish before we close it.
    if (self.indexer_ready) self.indexer.stop();
    if (self.db) |*db| db.close(gpa);
    self.db = null;
    if (self.vault_root) |r| gpa.free(r);
    self.vault_root = null;
    self.invalidateCandidates();
    self.clearDirty();
    // Anything holding a resolution from the old vault must drop it, and the only signal
    // consumers watch is this counter.
    _ = self.generation.fetchAdd(1, .release);
}

/// True when the graph panel has something to draw (real vault index or synth).
pub fn hasGraphSource(self: *const State) bool {
    return self.synth_mode or self.synth_job != null or (self.vault_root != null and self.db != null);
}

pub fn synthBusy(self: *const State) bool {
    return self.synth_job != null or self.synth_reload_frames != null;
}

fn dropSynth(self: *State, gpa: std.mem.Allocator) void {
    self.cancelSynthJob();
    if (self.synth_pos) |p| gpa.free(p);
    self.synth_pos = null;
    self.synth_mode = false;
    self.synth_reload_frames = null;
    self.synth_applied_key = 0;
    if (self.vault_root) |root| {
        if (std.mem.eql(u8, root, "synth://atlas")) {
            gpa.free(root);
            self.vault_root = null;
        }
    }
}

/// Drop synth overlay. If a real vault db is still open, restart the indexer full scan.
pub fn clearSynth(self: *State, gpa: std.mem.Allocator) void {
    if (!self.synth_mode and self.synth_pos == null and self.synth_job == null) return;
    self.dropSynth(gpa);
    if (self.db) |*db| {
        if (self.indexer_ready) {
            if (self.vault_root) |root| {
                self.indexer.start(db, root) catch |err| {
                    std.log.scoped(.atlas).err("could not restart indexer after synth: {s}", .{@errorName(err)});
                };
            }
        }
    } else if (self.indexer_ready) {
        self.indexer.publishSynthetic(&.{}, &.{}) catch {};
    }
}

/// Kick off (or re-kick) an async synth build from current settings. Keeps the previous graph
/// visible until the new one is ready — changing N/shape should feel like a swap, not a freeze.
pub fn loadSynth(self: *State, gpa: std.mem.Allocator) !void {
    _ = gpa;
    self.synth_reload_frames = null;
    self.startSynthJob();
}

pub fn tickWatcher(self: *State) void {
    self.reconcileDirty();
    if (self.watcher_ready) self.watcher.tick();
    self.tickSynthReload();
    self.pollSynthJob();
}

fn synthSpecKey(self: *const State) u64 {
    var h: u64 = 0xcbf29ce484222325;
    const mix = struct {
        fn go(hh: *u64, x: u64) void {
            hh.* ^= x;
            hh.* *%= 0x100000001b3;
        }
    }.go;
    mix(&h, quantizedSynthNotes(self.settings.synth_notes.get()));
    mix(&h, @intFromEnum(self.settings.synth_shape.get()));
    // Quantize degree to 0.5 steps already from settings; mix bits.
    mix(&h, @as(u64, @as(u32, @bitCast(self.settings.synth_avg_degree.get()))));
    return h;
}

/// Settings pane changed synth knobs — schedule a reload if a synth is already showing (or loading).
pub fn scheduleSynthReloadFromSettings(self: *State) void {
    if (!self.synth_mode and self.synth_job == null) return;
    if (self.synthSpecKey() == self.synth_applied_key) {
        self.synth_reload_frames = null;
        return;
    }
    // ~200ms — short enough to feel live; async build keeps the old graph up meanwhile.
    self.synth_reload_frames = 12;
}

fn tickSynthReload(self: *State) void {
    const frames = self.synth_reload_frames orelse return;
    if (frames > 1) {
        self.synth_reload_frames = frames - 1;
        return;
    }
    self.synth_reload_frames = null;
    if (self.synthSpecKey() == self.synth_applied_key) return;
    self.startSynthJob();
}

fn cancelSynthJob(self: *State) void {
    const job = self.synth_job orelse return;
    self.synth_job = null;
    job.cancel.store(true, .release);
    if (job.done.load(.acquire)) {
        if (job.thread) |t| t.join();
        job.thread = null;
        if (job.tryClaim()) job.destroy();
    } else if (job.thread) |t| {
        // Don't join on the UI thread — a 500k generate would freeze knobs for seconds.
        t.detach();
        job.thread = null;
        // Worker sees cancel and claims+destroys when it finishes.
    }
}

fn startSynthJob(self: *State) void {
    const gpa = self.dirty_gpa;
    const key = self.synthSpecKey();
    if (self.synth_job) |cur| {
        if (cur.key == key and !cur.done.load(.acquire)) return; // already building this spec
    }
    self.cancelSynthJob();

    // Disk indexer must not overwrite the synthetic snapshot when we apply.
    if (self.indexer_ready) self.indexer.stop();
    if (self.watcher_ready) self.watcher.clear();
    if (self.vault_root == null) {
        self.vault_root = gpa.dupe(u8, "synth://atlas") catch null;
    }

    const shape: vault_synth.Shape = switch (self.settings.synth_shape.get()) {
        .islands => .islands,
        .scale_free => .scale_free,
        .hub => .hub,
        .bipartite => .bipartite,
        .chain => .chain,
        .orphans => .orphans,
    };
    const job = gpa.create(SynthJob) catch |err| {
        std.log.scoped(.atlas).err("synth job alloc: {s}", .{@errorName(err)});
        return;
    };
    job.* = .{
        .gpa = gpa,
        .key = key,
        .n = quantizedSynthNotes(self.settings.synth_notes.get()),
        .shape = shape,
        .avg_deg = std.math.clamp(self.settings.synth_avg_degree.get(), 0, 64),
        .shape_label = shape.label(),
    };
    self.synth_job = job;
    job.thread = std.Thread.spawn(.{}, synthWorker, .{job}) catch |err| {
        std.log.scoped(.atlas).err("synth spawn: {s}", .{@errorName(err)});
        self.synth_job = null;
        job.destroy();
        return;
    };
}

fn synthWorker(job: *SynthJob) void {
    defer {
        const cancelled = job.cancel.load(.acquire);
        job.done.store(true, .release);
        if (cancelled) {
            if (job.tryClaim()) job.destroy();
        }
    }
    if (job.cancel.load(.acquire)) return;

    const n = job.n;
    const shape = job.shape;
    const avg = job.avg_deg;
    const isle_max: u32 = @intCast(@min(@as(usize, 10_000), @max(@as(usize, 64), n / 40)));
    const orphan_frac: f32 = if (shape == .islands) 0.02 else 0.10;
    const spec = vault_synth.Spec{
        .n = n,
        .shape = shape,
        .avg_deg = avg,
        .place = .pack,
        .island_max = isle_max,
        .orphan_frac = orphan_frac,
    };

    var path_arena = std.heap.ArenaAllocator.init(job.gpa);
    errdefer path_arena.deinit();

    var graph = vault_synth.generate(job.gpa, path_arena.allocator(), spec) catch |err| {
        job.fail = err;
        path_arena.deinit();
        return;
    };
    if (job.cancel.load(.acquire)) {
        graph.deinit(job.gpa);
        path_arena.deinit();
        return;
    }

    const edges = job.gpa.alloc(Indexer.SnapEdge, graph.edges.len) catch |err| {
        job.fail = err;
        graph.deinit(job.gpa);
        path_arena.deinit();
        return;
    };
    for (graph.edges, edges) |e, *out| {
        out.* = .{ .src_id = @intCast(e.a + 1), .dst_id = @intCast(e.b + 1) };
    }

    // Titles: empty at scale (Galaxy never labels half a million notes).
    var title_arena = std.heap.ArenaAllocator.init(job.gpa);
    const titles = title_arena.allocator().alloc([]const u8, n) catch |err| {
        job.fail = err;
        job.gpa.free(edges);
        graph.deinit(job.gpa);
        path_arena.deinit();
        title_arena.deinit();
        return;
    };
    if (n > 50_000) {
        @memset(titles, "");
    } else {
        for (titles, 0..) |*t, i| {
            t.* = std.fmt.allocPrint(title_arena.allocator(), "n{d}", .{i}) catch "";
        }
    }

    job.n = n;
    job.positions = graph.positions;
    job.degrees = graph.degrees;
    job.edges = edges;
    job.titles = titles;
    job.title_arena = title_arena;
    job.avg_deg_actual = graph.avg_deg_actual;
    job.max_degree = graph.max_degree;
    job.components = graph.components;
    // paths discarded with path_arena — publish uses empty/path from titles only.
    job.gpa.free(graph.edges);
    graph.positions = &.{};
    graph.degrees = &.{};
    path_arena.deinit();
}

fn pollSynthJob(self: *State) void {
    const job = self.synth_job orelse return;
    if (!job.done.load(.acquire)) return;
    if (job.thread) |t| t.join();
    job.thread = null;
    self.synth_job = null;
    if (!job.tryClaim()) return; // cancelled worker already freed
    defer job.destroy();

    if (job.cancel.load(.acquire)) return;
    if (job.fail) |err| {
        std.log.scoped(.atlas).err("synth job: {s}", .{@errorName(err)});
        return;
    }
    // Stale: user already moved the knobs again.
    if (job.key != self.synthSpecKey()) return;

    const positions = job.positions orelse return;
    const degrees = job.degrees orelse return;
    const edges = job.edges orelse return;
    const titles = job.titles orelse return;
    job.positions = null;
    job.degrees = null;
    job.edges = null;
    // titles live in title_arena — copy into indexer snap, then free arena with job.destroy.

    const nodes = self.dirty_gpa.alloc(Indexer.SnapNode, job.n) catch {
        self.dirty_gpa.free(positions);
        self.dirty_gpa.free(degrees);
        self.dirty_gpa.free(edges);
        return;
    };
    defer self.dirty_gpa.free(nodes);
    for (0..job.n) |i| {
        nodes[i] = .{
            .id = @intCast(i + 1),
            .path = "",
            .title = titles[i],
            .phantom = false,
            .degree = degrees[i],
        };
    }

    if (!self.indexer_ready) {
        self.dirty_gpa.free(positions);
        self.dirty_gpa.free(degrees);
        self.dirty_gpa.free(edges);
        return;
    }
    self.indexer.publishSynthetic(nodes, edges) catch |err| {
        std.log.scoped(.atlas).err("synth publish: {s}", .{@errorName(err)});
        self.dirty_gpa.free(positions);
        self.dirty_gpa.free(degrees);
        self.dirty_gpa.free(edges);
        return;
    };

    const edge_n = edges.len;
    if (self.synth_pos) |old| self.dirty_gpa.free(old);
    self.synth_pos = positions;
    self.dirty_gpa.free(degrees);
    self.dirty_gpa.free(edges);
    self.synth_mode = true;
    self.synth_applied_key = job.key;
    sdk.refresh();

    std.log.scoped(.atlas).info(
        "synth ready: {s} n={d} edges={d} avg_deg={d:.2} max_deg={d} comps={d}",
        .{ job.shape_label, job.n, edge_n, job.avg_deg_actual, job.max_degree, job.components },
    );
}

/// Drop overlays for documents that are no longer open, and re-read those notes from disk.
///
/// Closing a document *without saving* is the case this exists for, and it is invisible to every
/// other layer. `setDirtyContent` deliberately puts unsaved bytes into the index — that is what
/// makes a half-typed `[[Link]]` appear in the graph while you type it — but closing the tab
/// doesn't touch the file. No mtime moves, so neither fizzy's folder watch nor the open-doc poll
/// has anything to report, and the graph would go on drawing an edge the file on disk never had.
///
/// Written as a reconciliation against the open set rather than a close event, for two reasons.
/// atlas owns no documents, so `closeDocument` is routed to the owner and never reaches here at
/// all. And comparing the two sets cannot *miss* a close the way a subscription can.
///
/// `Indexer.enqueue` is the whole repair: `indexBuffer` stamped the row `mtime_ns = 0` precisely
/// so that the disk path's early-out can't mistake it for current, so `indexOne` re-reads the
/// file — and if the close followed a save, the content hash matches and it quietly refreshes
/// metadata instead of republishing.
fn reconcileDirty(self: *State) void {
    // The overwhelmingly common case: nothing typed but unsaved, so nothing to reconcile. Worth
    // the early-out because this runs every frame rather than on the poll interval — the graph
    // should correct itself on the frame the tab closes, not up to a poll later.
    if (self.dirty.count() == 0) return;
    const root = self.vault_root orelse return;

    // Removing while iterating a hash map isn't safe, and `dirty` is at most a tab bar's worth
    // of unsaved markdown, so take one stale entry per pass rather than allocating a list.
    while (self.firstClosedDirty()) |abs| {
        // `rel` borrows `abs`, which is the map's own key memory — enqueue (which copies) before
        // freeing it.
        if (query.vaultRelative(root, abs)) |rel| {
            if (self.indexer_ready) self.indexer.enqueue(rel);
        }
        if (self.dirty.fetchRemove(abs)) |kv| {
            self.dirty_gpa.free(kv.key);
            self.dirty_gpa.free(kv.value);
        } else break; // Unreachable in practice; without it a miss would spin forever.
    }
}

fn firstClosedDirty(self: *State) ?[]const u8 {
    var it = self.dirty.keyIterator();
    while (it.next()) |k| if (!documentIsOpen(k.*)) return k.*;
    return null;
}

fn documentIsOpen(abs: []const u8) bool {
    const host = sdk.host();
    const n = host.openDocCount();
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const doc = host.docByIndex(i) orelse continue;
        if (std.mem.eql(u8, doc.owner.documentPath(doc), abs)) return true;
    }
    return false;
}

pub fn folderPathsChanged(self: *State, changes: sdk.Plugin.PathChanges) void {
    if (self.watcher_ready) self.watcher.onPathsChanged(changes);
}

pub fn hasVault(self: *const State) bool {
    return self.vault_root != null and self.db != null;
}

pub fn rebuildIndex(self: *State) void {
    if (!self.indexer_ready or self.db == null) return;
    // Synth overlays the snapshot; a rebuild restores the real folder index.
    if (self.synth_mode) {
        // `clearSynth` restarts the indexer when db+root remain.
        const gpa = self.dirty_gpa;
        self.clearSynth(gpa);
        return;
    }
    if (self.indexer.thread == null) {
        if (self.vault_root) |root| {
            self.indexer.start(&self.db.?, root) catch return;
            return;
        }
    }
    self.indexer.requestFullScan();
}

/// Candidates for resolution, rebuilt when the index generation advances. UI-thread only.
pub fn loadSettings(self: *State, host: *sdk.Host) void {
    Schema.load(host, "atlas", &self.settings);
}

/// Register schema with the Host — fizzy draws the controls from `Schema.settings`.
pub fn registerSettings(self: *State, host: *sdk.Host, plugin: *sdk.Plugin) !void {
    try Schema.register(host, plugin, .{
        .title = "Atlas",
        .value = &self.settings,
    });
}

/// Convert every resolvable wikilink in `bytes`, or null when nothing changed. Shared by the
/// `LanguageSupport.format` hook and the explicit command so the two can't diverge.
pub fn convertWikilinks(self: *State, arena: std.mem.Allocator, path: []const u8, bytes: []const u8) !?[]const u8 {
    const root = self.vault_root orelse return null;
    const rel = query.vaultRelative(root, path) orelse return null;
    const candidates = try self.ensureCandidates();
    const media = try self.ensureMediaCandidates();
    if (candidates.len == 0 and media.len == 0) return null;
    return Scanner.convertWikilinks(arena, bytes, rel, candidates, media);
}

pub fn ensureCandidates(self: *State) ![]const resolve.Candidate {
    const gen = self.generation.load(.acquire);
    if (self.cand_gen == gen) return self.candidates;
    if (!self.cand_ready) return &.{};
    const db = if (self.db) |*d| d else {
        self.candidates = &.{};
        self.cand_gen = gen;
        return &.{};
    };
    _ = self.cand_arena.reset(.free_all);
    self.candidates = try query.loadCandidates(db, self.cand_arena.allocator());
    self.media_candidates = try query.loadMediaCandidates(db, self.cand_arena.allocator());
    self.cand_gen = gen;
    return self.candidates;
}

/// Media candidates for the current generation. Goes through `ensureCandidates` so both lists
/// are always rebuilt together out of the one arena.
pub fn ensureMediaCandidates(self: *State) ![]const resolve.Candidate {
    _ = try self.ensureCandidates();
    return self.media_candidates;
}

fn invalidateCandidates(self: *State) void {
    if (self.cand_ready) _ = self.cand_arena.reset(.free_all);
    self.candidates = &.{};
    self.media_candidates = &.{};
    self.cand_gen = std.math.maxInt(u64);
}

/// Record (or clear) an unsaved buffer. `bytes` is copied; empty `path` is ignored.
///
/// Two consumers. The `dirty` overlay is read by the backlinks panel directly. The indexer
/// gets the same bytes queued for a reindex, which is what puts the change in the *graph* —
/// the graph only ever reads the indexed snapshot, so before this it had no route to an edit
/// at all except `Watcher`'s 2s poll, which is driven from `endFrame` and therefore stops
/// happening entirely once the app idles.
pub fn setDirtyContent(self: *State, path: []const u8, bytes: []const u8) void {
    const gpa = self.dirty_gpa;
    const root = self.vault_root orelse return;
    if (path.len == 0) return;
    const rel = query.vaultRelative(root, path) orelse return;
    if (!query.isMarkdownPath(path)) return;

    // The indexer wakes the app itself once it publishes, so the graph repaints without
    // waiting on the next input event.
    if (self.indexer_ready) self.indexer.enqueueContent(rel, bytes);

    const gop = self.dirty.getOrPut(gpa, path) catch return;
    if (!gop.found_existing) {
        gop.key_ptr.* = gpa.dupe(u8, path) catch {
            _ = self.dirty.remove(path);
            return;
        };
        gop.value_ptr.* = &.{};
    } else {
        gpa.free(gop.value_ptr.*);
    }
    gop.value_ptr.* = gpa.dupe(u8, bytes) catch {
        if (self.dirty.fetchRemove(path)) |kv| {
            gpa.free(kv.key);
        }
        return;
    };
}

fn clearDirty(self: *State) void {
    const gpa = self.dirty_gpa;
    var it = self.dirty.iterator();
    while (it.next()) |e| {
        gpa.free(e.key_ptr.*);
        gpa.free(e.value_ptr.*);
    }
    self.dirty.clearRetainingCapacity();
}

/// Extra backlink hits from dirty (unsaved) buffers that point at `dst_rel`.
/// Allocated from `arena`. Skips paths already represented in `existing`.
pub fn dirtyBacklinks(
    self: *State,
    arena: std.mem.Allocator,
    dst_rel: []const u8,
    existing: []const query.Backlink,
) ![]query.Backlink {
    const root = self.vault_root orelse return &.{};
    var list: std.ArrayList(query.Backlink) = .empty;
    var path_buf: [resolve.max_path_len]u8 = undefined;

    var it = self.dirty.iterator();
    while (it.next()) |e| {
        const abs = e.key_ptr.*;
        const src_rel = query.vaultRelative(root, abs) orelse continue;
        // Already covered by the DB result for this source?
        if (sourceAlreadyListed(existing, src_rel)) continue;

        var scan_arena = std.heap.ArenaAllocator.init(self.dirty_gpa);
        defer scan_arena.deinit();
        const note = Scanner.scan(scan_arena.allocator(), e.value_ptr.*) catch continue;
        const cands = try self.ensureCandidates();

        for (note.links) |l| {
            const match = resolve.resolve(l.raw, src_rel, cands, &path_buf) orelse continue;
            if (!std.mem.eql(u8, cands[match.index].path, dst_rel)) continue;
            const title = stemOf(src_rel);
            try list.append(arena, .{
                .path = try arena.dupe(u8, src_rel),
                .title = try arena.dupe(u8, title),
                .line = l.line,
                .col = l.col,
                .context = try arena.dupe(u8, l.context),
            });
        }
    }
    return list.toOwnedSlice(arena);
}

fn sourceAlreadyListed(existing: []const query.Backlink, src_rel: []const u8) bool {
    for (existing) |b| {
        if (std.mem.eql(u8, b.path, src_rel)) return true;
    }
    return false;
}

fn stemOf(path: []const u8) []const u8 {
    const base = if (std.mem.lastIndexOfScalar(u8, path, '/')) |s| path[s + 1 ..] else path;
    if (std.ascii.endsWithIgnoreCase(base, ".markdown")) return base[0 .. base.len - ".markdown".len];
    if (std.ascii.endsWithIgnoreCase(base, ".md")) return base[0 .. base.len - ".md".len];
    return base;
}
