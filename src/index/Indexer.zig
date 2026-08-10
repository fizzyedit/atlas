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
pub const max_notes: usize = 200_000;
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
};

/// The pointer-free part of a snapshot, for callers that only want the footer numbers.
pub const Counts = struct {
    note_count: u32 = 0,
    link_count: u32 = 0,
    phantom_count: u32 = 0,
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

too_large: std.atomic.Value(u32) = .init(0),

/// One queued reindex. `bytes` non-null means "index *this* content" — a live editor buffer
/// handed over by `Plugin.documentContentChanged` — rather than re-reading the file. That is
/// how an unsaved edit reaches the graph at all, and it also removes the read-after-write race
/// on save. Null means the ordinary "something changed on disk, go look" path.
pub const Pending = struct {
    rel: []u8,
    bytes: ?[]u8 = null,

    fn deinit(self: Pending, gpa: std.mem.Allocator) void {
        gpa.free(self.rel);
        if (self.bytes) |b| gpa.free(b);
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
    self.too_large.store(0, .release);

    self.mutex.lockUncancelable(dvui.io);
    self.want_full = true;
    self.mutex.unlock(dvui.io);

    self.thread = try std.Thread.spawn(.{}, worker, .{self});
}

/// Signal the worker and join. Safe to call when never started.
pub fn stop(self: *Indexer) void {
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

    self.mutex.lockUncancelable(dvui.io);
    defer self.mutex.unlock(dvui.io);
    self.want_full = false;
    for (self.pending.items) |p| p.deinit(self.gpa);
    self.pending.clearRetainingCapacity();
}

pub fn deinit(self: *Indexer) void {
    self.stop();
    self.pending.deinit(self.gpa);
    for (&self.snap_arenas) |*slot| {
        if (slot.*) |*a| a.deinit();
        slot.* = null;
    }
    self.snapshots = .{ .{}, .{} };
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
    self.enqueuePending(rel_path, null);
}

/// Queue a reindex against a live editor buffer rather than the file on disk.
///
/// `bytes` is copied — the SDK only guarantees it for the duration of the
/// `documentContentChanged` call. Called from the UI thread; the worker does the DB write.
pub fn enqueueContent(self: *Indexer, rel_path: []const u8, bytes: []const u8) void {
    if (bytes.len > max_file_bytes) {
        _ = self.too_large.fetchAdd(1, .monotonic);
        return;
    }
    self.enqueuePending(rel_path, bytes);
}

fn enqueuePending(self: *Indexer, rel_path: []const u8, bytes: ?[]const u8) void {
    if (!isMarkdownPath(rel_path)) return;
    const owned = self.gpa.dupe(u8, rel_path) catch return;
    const owned_bytes: ?[]u8 = if (bytes) |b| (self.gpa.dupe(u8, b) catch {
        self.gpa.free(owned);
        return;
    }) else null;
    const item: Pending = .{ .rel = owned, .bytes = owned_bytes };

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
            var changed = false;
            for (batch) |item| {
                if (self.quit.load(.acquire)) break;
                const did = self.indexPending(io, item) catch |err| blk: {
                    log.warn("index {s}: {s}", .{ item.rel, @errorName(err) });
                    break :blk false;
                };
                changed = changed or did;
            }
            // `writeNote` parks every new edge on `dst_id = src_id` as a stand-in; without a
            // relink pass, the graph only ever sees self-loops and never materializes phantoms
            // for targets like `[[claude]]` that don't exist yet.
            if (changed) {
                self.relinkAll() catch |err| {
                    log.warn("relink after incremental: {s}", .{@errorName(err)});
                };
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

fn runFullScan(self: *Indexer, io: std.Io, mode: ScanMode) !void {
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

    var changed = false;
    try self.walk(io, self.vault_root, &seen, &media_seen, &files_since_commit, &last_commit, &changed);

    // Anything real that we didn't see is gone from disk. A note deleted outside the editor is
    // its own kind of stale edge, so these count as changes too.
    if (try self.dropMissing(&seen)) changed = true;
    if (try self.dropMissingMedia(&media_seen)) changed = true;

    if (mode == .if_changed and !changed) return;

    // Resolve every link against the final note set and materialize phantoms.
    try self.relinkAll();
    try self.commitAndPublish();
    // A quiet sweep skips the worker's own wake, so this is the only nudge the UI gets when a
    // background walk finds that something changed.
    sdk.refresh();
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
            .directory => try self.walk(io, abs, seen, media_seen, files_since_commit, last_commit, changed),
            .file => {
                if (query.isMediaPath(entry.name)) {
                    // Attachments are recorded by path only — never opened, never parsed, and
                    // never linked into the note graph. All the index needs is enough to
                    // resolve and complete `![[diagram.png]]`.
                    const mrel = vaultRelative(self.vault_root, abs) orelse continue;
                    const mrel_owned = try self.gpa.dupe(u8, mrel);
                    errdefer self.gpa.free(mrel_owned);
                    try media_seen.put(self.gpa, mrel_owned, {});
                    self.upsertMedia(mrel) catch |err| {
                        log.warn("index media {s}: {s}", .{ mrel, @errorName(err) });
                    };
                    continue;
                }
                if (!isMarkdownPath(entry.name)) continue;
                const rel = vaultRelative(self.vault_root, abs) orelse continue;
                const rel_owned = try self.gpa.dupe(u8, rel);
                errdefer self.gpa.free(rel_owned);
                try seen.put(self.gpa, rel_owned, {});

                if (self.indexOne(io, rel_owned) catch |err| blk: {
                    log.warn("index {s}: {s}", .{ rel_owned, @errorName(err) });
                    break :blk false;
                }) changed.* = true;

                files_since_commit.* += 1;
                const now = std.Io.Clock.boot.now(io).nanoseconds;
                // Only stream progress once there is progress to stream. A sweep that finds
                // nothing must stay completely silent, or it republishes on the batch timer.
                if (changed.* and (files_since_commit.* >= batch_files or now - last_commit.* >= batch_ns)) {
                    try self.commitAndPublish();
                    files_since_commit.* = 0;
                    last_commit.* = now;
                    sdk.refresh();
                }
            },
            else => {},
        }
    }
}

/// Returns true when rows the graph reads actually changed, so the caller can skip the
/// relink + snapshot rebuild otherwise. Worth the bookkeeping now that live buffers queue a
/// reindex every ~300ms of typing rather than once per 2s poll: a save re-sends bytes we
/// already indexed, and republishing that would re-query every note and edge for nothing.
fn indexPending(self: *Indexer, io: std.Io, item: Pending) !bool {
    if (item.bytes) |bytes| return self.indexBuffer(item.rel, bytes);
    return self.indexOne(io, item.rel);
}

/// Index a live editor buffer. The file on disk may still say something else (an unsaved
/// edit), so the row is stamped with `mtime_ns = 0`: that can never equal a real stat, which
/// keeps the disk path's mtime/size early-out from later mistaking this for an up-to-date
/// row. When the save does land, the content hash matches and `indexOne` just refreshes the
/// metadata instead of rescanning.
fn indexBuffer(self: *Indexer, rel: []const u8, bytes: []const u8) !bool {
    const db = self.db orelse return false;
    const hash: i64 = @bitCast(std.hash.XxHash3.hash(0, bytes));
    if (try lookupNoteMeta(db, rel)) |meta| {
        // Same content we already hold — the usual case for the save that follows a typing
        // lull we already indexed.
        if (meta.hash == hash) return false;
    }
    try self.writeNote(db, rel, bytes, 0, @intCast(bytes.len), hash);
    return true;
}

fn indexOne(self: *Indexer, io: std.Io, rel: []const u8) !bool {
    const db = self.db orelse return false;

    const abs = try std.fs.path.join(self.gpa, &.{ self.vault_root, rel });
    defer self.gpa.free(abs);

    const st = std.Io.Dir.cwd().statFile(io, abs, .{}) catch {
        // Gone — delete the real note row if we had one. The graph loses a node, so publish.
        try deleteNote(db, rel);
        return true;
    };
    if (st.size > max_file_bytes) {
        _ = self.too_large.fetchAdd(1, .monotonic);
        return false;
    }
    const mtime_ns: i64 = @truncate(st.mtime.nanoseconds);
    const size: i64 = @intCast(st.size);

    if (try lookupNoteMeta(db, rel)) |meta| {
        if (meta.mtime_ns == mtime_ns and meta.size == size) return false;
    }

    const bytes = std.Io.Dir.cwd().readFileAlloc(io, abs, self.gpa, .limited(max_file_bytes)) catch |err| {
        log.warn("read {s}: {s}", .{ rel, @errorName(err) });
        return false;
    };
    defer self.gpa.free(bytes);

    const hash: i64 = @bitCast(std.hash.XxHash3.hash(0, bytes));
    if (try lookupNoteMeta(db, rel)) |meta| {
        if (meta.hash == hash) {
            // Metadata catch-up only — this is the save landing on a buffer we already
            // indexed (which stamped `mtime_ns = 0`). Nothing the graph draws moved.
            try touchNote(db, meta.id, mtime_ns, size);
            return false;
        }
    }
    try self.writeNote(db, rel, bytes, mtime_ns, size, hash);
    return true;
}

/// Scan `bytes` and replace every derived row for `rel`. Shared by the disk and live-buffer
/// paths so the two can't drift in what they record.
fn writeNote(self: *Indexer, db: *Db, rel: []const u8, bytes: []const u8, mtime_ns: i64, size: i64, hash: i64) !void {
    var arena = std.heap.ArenaAllocator.init(self.gpa);
    defer arena.deinit();
    const note = try Scanner.scan(arena.allocator(), bytes);

    const stem = stemOf(rel);
    const note_id = try upsertNote(db, rel, stem, note.title, mtime_ns, size, hash);

    // Replace derived rows for this note.
    try db.conn.exec("DELETE FROM aliases WHERE note_id = ?", .{}, .{note_id});
    try db.conn.exec("DELETE FROM headings WHERE note_id = ?", .{}, .{note_id});
    try db.conn.exec("DELETE FROM links WHERE src_id = ?", .{}, .{note_id});
    try db.conn.exec("DELETE FROM tags WHERE note_id = ?", .{}, .{note_id});

    for (note.aliases) |a| {
        try db.conn.exec(
            "INSERT INTO aliases(note_id, alias, alias_fold) VALUES(?, ?, ?)",
            .{},
            .{ note_id, a, try foldOwned(arena.allocator(), a) },
        );
    }
    for (note.headings) |h| {
        try db.conn.exec(
            "INSERT INTO headings(note_id, text, text_fold, level, line) VALUES(?, ?, ?, ?, ?)",
            .{},
            .{ note_id, h.text, try foldOwned(arena.allocator(), h.text), h.level, h.line },
        );
    }
    for (note.tags) |t| {
        try db.conn.exec(
            "INSERT INTO tags(note_id, tag, tag_fold, line) VALUES(?, ?, ?, ?)",
            .{},
            .{ note_id, t.tag, try foldOwned(arena.allocator(), t.tag), t.line },
        );
    }
    // Links are written with `dst_id = src_id` as a temporary stand-in; `relinkAll` rewrites
    // destinations once every note is present (so a forward link to a file later in the walk
    // still resolves).
    for (note.links) |l| {
        try db.conn.exec(
            \\INSERT INTO links(src_id, dst_id, raw, heading, alias, kind, ambiguous, line, col, context)
            \\VALUES(?, ?, ?, ?, ?, ?, 0, ?, ?, ?)
        ,
            .{},
            .{
                note_id,
                note_id,
                l.raw,
                l.heading,
                l.alias,
                @intFromEnum(l.kind),
                l.line,
                l.col,
                l.context,
            },
        );
    }
}

fn relinkAll(self: *Indexer) !void {
    const db = self.db orelse return;
    var arena = std.heap.ArenaAllocator.init(self.gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const candidates = try query.loadCandidates(db, a);
    // Built once for the whole relink: without it this loop is one linear scan of every note
    // per link, which is the single most expensive thing the indexer does on a large vault.
    var cand_index = try resolve.Index.init(self.gpa, candidates);
    defer cand_index.deinit();
    var buf: [resolve.max_path_len]u8 = undefined;

    // Pull every link and resolve it.
    var stmt = try db.conn.prepare(
        \\SELECT rowid, src_id, raw, heading,
        \\  (SELECT path FROM notes WHERE id = src_id)
        \\FROM links
    );
    defer stmt.deinit();

    // Collect updates / deletes first so we don't mutate while iterating.
    const Update = struct { rowid: i64, dst_id: i64, ambiguous: i32 };
    var updates: std.ArrayList(Update) = .empty;
    var deletes: std.ArrayList(i64) = .empty;
    defer updates.deinit(self.gpa);
    defer deletes.deinit(self.gpa);

    var iter = try stmt.iterator(
        struct { rowid: i64, src_id: i64, raw: []const u8, heading: []const u8, src_path: []const u8 },
        .{},
    );
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

        const match = resolve.resolveIndexed(row.raw, row.src_path, candidates, &cand_index, &buf);
        const dst_id: i64 = if (match) |m|
            (try query.noteIdForPath(db, candidates[m.index].path)) orelse try ensurePhantom(db, row.raw)
        else
            try ensurePhantom(db, row.raw);
        const ambiguous: i32 = if (match) |m| @intFromBool(m.ambiguous) else 0;
        try updates.append(self.gpa, .{ .rowid = row.rowid, .dst_id = dst_id, .ambiguous = ambiguous });
    }

    for (deletes.items) |rowid| {
        try db.conn.exec("DELETE FROM links WHERE rowid = ?", .{}, .{rowid});
    }
    for (updates.items) |u| {
        try db.conn.exec(
            "UPDATE links SET dst_id = ?, ambiguous = ? WHERE rowid = ?",
            .{},
            .{ u.dst_id, u.ambiguous, u.rowid },
        );
    }

    try purgeNonNotePhantoms(db, self.gpa);
    try query.purgeOrphanPhantoms(db);
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
    const db = self.db orelse return false;
    var stmt = try db.conn.prepare("SELECT id, path FROM media");
    defer stmt.deinit();
    var iter = try stmt.iterator(struct { id: i64, path: []const u8 }, .{});

    var to_delete: std.ArrayList(i64) = .empty;
    defer to_delete.deinit(self.gpa);

    while (true) {
        var row_arena = std.heap.ArenaAllocator.init(self.gpa);
        defer row_arena.deinit();
        const row = (try iter.nextAlloc(row_arena.allocator(), .{})) orelse break;
        if (!seen.contains(row.path)) try to_delete.append(self.gpa, row.id);
    }
    for (to_delete.items) |id| {
        try db.conn.exec("DELETE FROM media WHERE id = ?", .{}, .{id});
    }
    return to_delete.items.len > 0;
}

/// Returns true if anything was dropped.
fn dropMissing(self: *Indexer, seen: *std.StringHashMapUnmanaged(void)) !bool {
    const db = self.db orelse return false;
    var arena = std.heap.ArenaAllocator.init(self.gpa);
    defer arena.deinit();

    var stmt = try db.conn.prepare("SELECT id, path FROM notes WHERE phantom = 0");
    defer stmt.deinit();
    var iter = try stmt.iterator(struct { id: i64, path: []const u8 }, .{});

    var to_delete: std.ArrayList(i64) = .empty;
    defer to_delete.deinit(self.gpa);

    while (true) {
        var row_arena = std.heap.ArenaAllocator.init(self.gpa);
        defer row_arena.deinit();
        const row = (try iter.nextAlloc(row_arena.allocator(), .{})) orelse break;
        if (!seen.contains(row.path)) try to_delete.append(self.gpa, row.id);
    }
    for (to_delete.items) |id| {
        try db.conn.exec("DELETE FROM notes WHERE id = ?", .{}, .{id});
    }
    return to_delete.items.len > 0;
}

fn commitAndPublish(self: *Indexer) !void {
    const db = self.db orelse return;
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
        .link_count = try countOf(db, "SELECT count(*) FROM links"),
        .phantom_count = try countOf(db, "SELECT count(*) FROM notes WHERE phantom = 1"),
        .nodes = nodes,
        .edges = edges,
    };

    self.snap_mutex.lockUncancelable(dvui.io);
    self.snapshots[next] = snap;
    self.snap_mutex.unlock(dvui.io);
    self.snap_pub.store(next, .release);

    _ = self.generation.fetchAdd(1, .release);
}

fn loadSnapNodes(db: *Db, arena: std.mem.Allocator) ![]const SnapNode {
    // Degree = distinct neighbours via a UNION so a mutual link isn't counted twice.
    var stmt = try db.conn.prepare(
        \\SELECT n.id, n.path, n.title, n.stem, n.phantom,
        \\  (SELECT count(*) FROM (
        \\     SELECT dst_id AS oid FROM links WHERE src_id = n.id
        \\     UNION
        \\     SELECT src_id AS oid FROM links WHERE dst_id = n.id
        \\  )) AS degree
        \\FROM notes n
    );
    defer stmt.deinit();

    var list: std.ArrayList(SnapNode) = .empty;
    var iter = try stmt.iterator(struct {
        id: i64,
        path: []const u8,
        title: []const u8,
        stem: []const u8,
        phantom: i64,
        degree: i64,
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
        });
    }
    return list.toOwnedSlice(arena);
}

fn loadSnapEdges(db: *Db, arena: std.mem.Allocator) ![]const SnapEdge {
    var stmt = try db.conn.prepare("SELECT DISTINCT src_id, dst_id FROM links");
    defer stmt.deinit();

    var list: std.ArrayList(SnapEdge) = .empty;
    var iter = try stmt.iterator(struct { src_id: i64, dst_id: i64 }, .{});
    while (true) {
        const row = (try iter.nextAlloc(arena, .{})) orelse break;
        try list.append(arena, .{ .src_id = row.src_id, .dst_id = row.dst_id });
    }
    return list.toOwnedSlice(arena);
}

// -- SQL helpers ------------------------------------------------------------------

const NoteMeta = struct { id: i64, mtime_ns: i64, size: i64, hash: i64 };

fn lookupNoteMeta(db: *Db, path: []const u8) !?NoteMeta {
    return db.conn.one(
        NoteMeta,
        "SELECT id, mtime_ns, size, hash FROM notes WHERE path = ? AND phantom = 0",
        .{},
        .{path},
    );
}

fn touchNote(db: *Db, id: i64, mtime_ns: i64, size: i64) !void {
    try db.conn.exec(
        "UPDATE notes SET mtime_ns = ?, size = ? WHERE id = ?",
        .{},
        .{ mtime_ns, size, id },
    );
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
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const stem_fold = try foldOwned(arena.allocator(), stem);

    if (try db.conn.one(i64, "SELECT id FROM notes WHERE path = ? AND phantom = 0", .{}, .{path})) |id| {
        try db.conn.exec(
            "UPDATE notes SET stem = ?, stem_fold = ?, title = ?, mtime_ns = ?, size = ?, hash = ?, phantom = 0 WHERE id = ?",
            .{},
            .{ stem, stem_fold, title, mtime_ns, size, hash, id },
        );
        return id;
    }

    if (try db.conn.one(
        i64,
        "SELECT id FROM notes WHERE phantom = 1 AND stem_fold = ? LIMIT 1",
        .{},
        .{stem_fold},
    )) |id| {
        try db.conn.exec(
            "UPDATE notes SET path = ?, stem = ?, stem_fold = ?, title = ?, mtime_ns = ?, size = ?, hash = ?, phantom = 0 WHERE id = ?",
            .{},
            .{ path, stem, stem_fold, title, mtime_ns, size, hash, id },
        );
        return id;
    }

    try db.conn.exec(
        "INSERT INTO notes(path, stem, stem_fold, title, mtime_ns, size, hash, phantom) VALUES(?, ?, ?, ?, ?, ?, ?, 0)",
        .{},
        .{ path, stem, stem_fold, title, mtime_ns, size, hash },
    );
    return (try db.conn.one(i64, "SELECT last_insert_rowid()", .{}, .{})) orelse return error.NoRowId;
}

fn deleteNote(db: *Db, path: []const u8) !void {
    try db.conn.exec("DELETE FROM notes WHERE path = ? AND phantom = 0", .{}, .{path});
}

fn ensurePhantom(db: *Db, raw_target: []const u8) !i64 {
    // Callers should already filter; belt-and-braces so `.zig` never becomes a graph node.
    if (!resolve.isNoteLikeTarget(raw_target)) return error.NotANote;

    const norm = resolve.normalize(raw_target);
    if (norm.text.len == 0) {
        // Degenerate — point at a shared empty phantom.
        if (try db.conn.one(i64, "SELECT id FROM notes WHERE phantom = 1 AND stem_fold = '' LIMIT 1", .{}, .{})) |id| return id;
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
    const stem_fold = foldInto(&fold_buf, stem);

    if (try db.conn.one(
        i64,
        "SELECT id FROM notes WHERE phantom = 1 AND stem_fold = ? LIMIT 1",
        .{},
        .{stem_fold},
    )) |id| return id;

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

fn isMarkdownPath(name: []const u8) bool {
    return std.ascii.endsWithIgnoreCase(name, ".md") or
        std.ascii.endsWithIgnoreCase(name, ".markdown");
}

fn stemOf(path: []const u8) []const u8 {
    const base = if (std.mem.lastIndexOfScalar(u8, path, '/')) |s| path[s + 1 ..] else path;
    if (std.ascii.endsWithIgnoreCase(base, ".markdown")) return base[0 .. base.len - ".markdown".len];
    if (std.ascii.endsWithIgnoreCase(base, ".md")) return base[0 .. base.len - ".md".len];
    return base;
}

fn vaultRelative(vault: []const u8, abs: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, abs, vault)) return null;
    var rest = abs[vault.len..];
    while (rest.len > 0 and (rest[0] == '/' or rest[0] == '\\')) rest = rest[1..];
    if (rest.len == 0) return null;
    return rest;
}

fn foldInto(buf: []u8, s: []const u8) []const u8 {
    for (s, 0..) |c, i| buf[i] = std.ascii.toLower(c);
    return buf[0..s.len];
}

fn foldOwned(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    const out = try arena.alloc(u8, s.len);
    for (s, 0..) |c, i| out[i] = std.ascii.toLower(c);
    return out;
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

    try v.write("CLAUDE.md", "# Claude\n");
    try v.write("README.md", "# Readme\n");
    try testing.expectEqual(@as(usize, 0), try v.edgeCount());

    try v.write("README.md", "# Readme\n\nsee [[CLAUDE]]\n");
    try testing.expectEqual(@as(usize, 1), try v.realEdgeCount());

    try v.write("README.md", "# Readme\n");
    try testing.expectEqual(@as(usize, 0), try v.edgeCount());
}

test "removing a wikilink to a note outside the vault removes edge and phantom" {
    const gpa = testing.allocator;
    var v = try TestVault.create(gpa);
    defer v.destroy(gpa);

    try v.write("README.md", "# Readme\n");
    try v.write("README.md", "# Readme\n\nsee [[CLAUDE]]\n");
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

    try v.write("CLAUDE.md", "# Claude\n");
    try v.write("README.md", "# Readme\n\nsee [[CLAUDE]]\n");
    try testing.expectEqual(@as(usize, 1), try v.realEdgeCount());

    try v.write("CLAUDE.md", "# Claude\n\nmore words\n");
    try testing.expectEqual(@as(usize, 1), try v.realEdgeCount());
}
