//! Plugin-owned state: the open vault and everything derived from it.
//!
//! One instance, created in `register` and torn down in `deinit`. Everything keyed to a
//! particular open folder lives behind `vault` and is rebuilt from scratch on `onFolderOpen` —
//! the filesystem is the source of truth, so there is nothing here worth preserving across a
//! folder switch.
//!
//! In-memory synthetic vaults (for scale/shape testing without markdown on disk) live in
//! `src/ui/vault_sim.zig` now, with their own independent state — see that file rather than here.
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

/// Candidate list for `resolve.resolve`, refreshed whenever `generation` moves.
///
/// Normally *not* built here: the indexer builds it on its worker as part of publishing and this
/// thread adopts the whole thing (`cand_owned`). `cand_arena` backs the fallback path only — no
/// indexer, or a generation nobody published candidates for — which is the query this used to run
/// on every rebuild, and the reason opening the first document in a large vault hitched.
cand_arena: std.heap.ArenaAllocator = undefined,
cand_ready: bool = false,
/// The set adopted from the indexer, when the current lists came from there. Owned: dropped when
/// the next set is adopted, when the fallback path takes over, or at teardown.
cand_owned: ?Indexer.CandidateSet = null,
cand_gen: u64 = std.math.maxInt(u64),
candidates: []const resolve.Candidate = &.{},
/// Lookup tables over `candidates`, for the **fallback** path only — the adopted set carries
/// its own (`Indexer.CandidateSet.index`), built on the worker. Read through `candidateIndex`,
/// which picks whichever of the two is live.
cand_index: ?resolve.Index = null,
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
    if (self.cand_owned) |*set| set.deinit();
    self.cand_owned = null;
    if (self.cand_index) |*ix| ix.deinit();
    self.cand_index = null;
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
        if (self.db != null and std.mem.eql(u8, current, root)) return;
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

/// True when the graph panel has something to draw.
pub fn hasGraphSource(self: *const State) bool {
    return self.vault_root != null and self.db != null;
}

pub fn tickWatcher(self: *State) void {
    self.reconcileDirty();
    if (self.watcher_ready) self.watcher.tick();
}

/// Drop overlays for documents that are no longer open.
///
/// This used to also re-read those notes from disk, because unsaved bytes went into the index and
/// closing a tab without saving left the graph drawing an edge the file never had. The index no
/// longer takes unsaved bytes at all (see `setDirtyContent`), so it already agrees with disk and
/// there is nothing to repair — only the backlinks overlay to forget, which would otherwise keep
/// showing lines from a buffer that is gone.
///
/// Written as a reconciliation against the open set rather than a close event, for two reasons.
/// atlas owns no documents, so `closeDocument` is routed to the owner and never reaches here at
/// all. And comparing the two sets cannot *miss* a close the way a subscription can.
fn reconcileDirty(self: *State) void {
    // The overwhelmingly common case: nothing typed but unsaved, so nothing to reconcile. Worth
    // the early-out because this runs every frame rather than on the poll interval — the graph
    // should correct itself on the frame the tab closes, not up to a poll later.
    if (self.dirty.count() == 0) return;
    // Removing while iterating a hash map isn't safe, and `dirty` is at most a tab bar's worth
    // of unsaved markdown, so take one stale entry per pass rather than allocating a list.
    while (self.firstClosedDirty()) |abs| {
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
    var rel_buf: [query.max_rel_path]u8 = undefined;
    const rel = query.vaultRelative(root, path, &rel_buf) orelse return null;
    // One refresh, then read both lists. Calling the two `ensure` helpers in sequence would leave a
    // window where the second one adopts a new set and frees the arena the first one's slice still
    // points into — the lists are refreshed together precisely so nobody has to hold one across a
    // rebuild of the other.
    const media = try self.ensureMediaCandidates();
    const candidates = self.candidates;
    if (candidates.len == 0 and media.len == 0) return null;
    return Scanner.convertWikilinks(arena, bytes, rel, candidates, self.candidateIndex(), media);
}

/// The candidates for the current generation. Cheap once warm, and cheap to *become* warm — the
/// lists are built on the indexer's worker and claimed here, so this is a pointer swap rather than
/// the multi-second walk of every note it used to be.
pub fn ensureCandidates(self: *State) ![]const resolve.Candidate {
    // Loaded before the take, never after. The worker parks a set and *then* bumps the
    // generation, so reading first can only under-claim — we adopt a set newer than `gen` and
    // stamp it with `gen`, costing one redundant refresh later. Reading after the take could
    // stamp a generation the adopted set doesn't cover, which is stale data flying as fresh.
    const gen = self.generation.load(.acquire);
    if (self.cand_gen == gen) return self.candidates;
    if (!self.cand_ready) return &.{};

    if (self.indexer_ready) {
        if (self.indexer.takeCandidates()) |set| {
            self.releaseCandidates();
            self.cand_owned = set;
            self.candidates = set.notes;
            self.media_candidates = set.media;
            self.cand_gen = gen;
            return self.candidates;
        }
    }

    // A set is on its way. Keep what we have — empty on a freshly opened vault — and ask again
    // next call rather than racing the worker to run the same multi-second query on this thread.
    // That race is the original hitch: the first document opens while the first scan is still
    // running, so the handoff is legitimately empty and a fallback here would fire every time.
    if (self.indexer_ready and self.indexer.candidatesPending()) return self.candidates;

    // Fallback. Nothing published candidates for this generation and none is coming: no vault
    // indexer (headless tests, a synthetic vault), a publish whose candidate build failed, or a
    // generation bumped by something other than `commitAndPublish`.
    const db = if (self.db) |*d| d else {
        self.releaseCandidates();
        self.cand_gen = gen;
        return &.{};
    };
    self.releaseCandidates();
    self.candidates = try query.loadCandidates(db, self.cand_arena.allocator());
    self.media_candidates = try query.loadMediaCandidates(db, self.cand_arena.allocator());
    // Built here too, not just on the worker: this path is rare, but the callers below are the
    // per-link ones, and "rare" is no reason to hand them a linear scan of the whole vault.
    self.cand_index = resolve.Index.init(self.cand_arena.child_allocator, self.candidates) catch null;
    self.cand_gen = gen;
    return self.candidates;
}

/// Lookup tables for `resolve.resolveIndexed` over the current `candidates`, or null when there
/// are none — in which case resolution falls back to scanning, which is correct and slow.
///
/// Borrowed: valid only until the next `ensureCandidates` adopts a newer set, so call it after
/// `ensureCandidates` and don't hold it across one.
pub fn candidateIndex(self: *State) ?*const resolve.Index {
    if (self.cand_owned) |*set| return &set.index;
    if (self.cand_index) |*ix| return ix;
    return null;
}

/// Drop whatever backs the current lists — the adopted set, the fallback arena, or neither — and
/// leave both empty. Does not touch `cand_gen`; every caller sets it to what it means next.
fn releaseCandidates(self: *State) void {
    if (self.cand_owned) |*set| set.deinit();
    self.cand_owned = null;
    if (self.cand_index) |*ix| ix.deinit();
    self.cand_index = null;
    if (self.cand_ready) _ = self.cand_arena.reset(.free_all);
    self.candidates = &.{};
    self.media_candidates = &.{};
}

/// Media candidates for the current generation. Goes through `ensureCandidates` so both lists
/// are always rebuilt together out of the one arena.
pub fn ensureMediaCandidates(self: *State) ![]const resolve.Candidate {
    _ = try self.ensureCandidates();
    return self.media_candidates;
}

fn invalidateCandidates(self: *State) void {
    self.releaseCandidates();
    self.cand_gen = std.math.maxInt(u64);
}

/// Record (or clear) an unsaved buffer. `bytes` is copied; empty `path` is ignored.
///
/// One consumer: the `dirty` overlay the backlinks panel reads, so a row can show the line as it
/// currently stands rather than as it was last saved.
///
/// **The index is deliberately not fed from here.** These bytes arrive on a typing lull, and a
/// half-typed document is not a document — `[[Paris]]` is preceded by `[[P]]`, `[[Pa]]`, `[[Par]]`,
/// and every one of those resolves to nothing and *materialises a phantom note* for a page that
/// will never exist. Those are real rows in `notes` and real nodes in the graph, so indexing as you
/// type does not merely cost a rebuild per lull — it fills the vault with debris and then draws it.
///
/// A save is the moment the document means something. This *does* nudge the indexer — but with the
/// **path only**, never the bytes, so the index still reads nothing but what is on disk.
///
/// That distinction is the whole design. Fizzy fires this both on a typing lull and on a save, and
/// cannot say which; `indexOne` can, because it stats the file. A lull finds the same mtime and
/// size as last time and early-outs before reading a byte, publishing nothing and creating no
/// phantoms. A save finds a new stat and re-reads from disk. So the ambiguous signal is resolved by
/// the filesystem rather than guessed at, and it costs one `stat` per typing lull.
///
/// Without this, a save waits on `Watcher` — layer 1's host-coalesced filesystem event, or worst
/// case layer 2's 2s poll. On a small vault that wait *is* the latency: the index and rebuild are
/// tens of milliseconds, and the reader is left watching a stale graph for up to two seconds.
pub fn setDirtyContent(self: *State, path: []const u8, bytes: []const u8) void {
    const gpa = self.dirty_gpa;
    // No vault means nothing to overlay onto, and no path means an unsaved buffer with no identity
    // for the panel to match against.
    const root = self.vault_root orelse return;
    if (path.len == 0) return;
    if (!query.isMarkdownPath(path)) return;

    // Path only — see above. `indexOne` stats it and does nothing if the file has not moved.
    if (self.indexer_ready) {
        var rel_buf: [query.max_rel_path]u8 = undefined;
        if (query.vaultRelative(root, path, &rel_buf)) |rel| self.indexer.enqueue(rel);
    }

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
    var rel_buf: [query.max_rel_path]u8 = undefined;

    var it = self.dirty.iterator();
    while (it.next()) |e| {
        const abs = e.key_ptr.*;
        const src_rel = query.vaultRelative(root, abs, &rel_buf) orelse continue;
        // Already covered by the DB result for this source?
        if (sourceAlreadyListed(existing, src_rel)) continue;

        var scan_arena = std.heap.ArenaAllocator.init(self.dirty_gpa);
        defer scan_arena.deinit();
        const note = Scanner.scan(scan_arena.allocator(), e.value_ptr.*) catch continue;
        const cands = try self.ensureCandidates();
        const ix = self.candidateIndex();

        for (note.links) |l| {
            const match = resolve.resolveIndexed(l.raw, src_rel, cands, ix, &path_buf) orelse continue;
            if (!std.mem.eql(u8, cands[match.index].path, dst_rel)) continue;
            const title = query.stemOf(src_rel);
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
