//! One pass over a vault through a `core.vfs.Fs`, as a stepped task (`core.work.Task`).
//!
//! The vault may be a folder on this machine (`core.LocalFs`, whose reads overlap on the
//! `Io`'s pool) or a cloud mount (a Drive, whose completions the host's frame pump delivers).
//! Either way nothing here blocks: directories are listed, files stat'd and read through a
//! window of in-flight jobs, and `step` applies whatever has landed, issues more, and returns
//! when out of budget or when nothing is ready. The indexer runs it on a worker thread for a
//! disk vault and from the frame for a mount or on the web — see `Indexer` and `WEB_PLAN.md`.
//!
//! A full scan is `count → walk → drop → relink → publish`; a scoped scan (`targets`) skips
//! the walk and probes only the paths it was given — the incremental path a save takes.
const std = @import("std");
const sdk = @import("fizzy_sdk");
const core = @import("core");
const vfs = core.vfs;
const work = core.work;

const Indexer = @import("Indexer.zig");
const Index = @import("Index.zig");
const query = @import("query.zig");
const resolve = @import("resolve.zig");

const Scan = @This();

const log = std.log.scoped(.atlas);

/// Where the vault's bytes come from.
pub const Source = struct {
    fs: vfs.Fs,
    /// The vault root as `fs` names it: an absolute OS path for the local disk, a `/`-rooted
    /// path inside a mount.
    root: []const u8,
    /// Whether the indexer may run this scan on its own thread: only for a filesystem the
    /// indexer owns (its `LocalFs`), whose completions land on that thread. A mount's belong
    /// to the host's thread, so a scan over one runs from the frame — where pumping the mount
    /// from the task is fine, and gets a fast backend's (a zip's) answers within the step.
    threaded: bool,
};

pub const Mode = enum {
    /// Folder open / explicit rebuild: count first, publish whatever happened.
    always,
    /// A background sweep: publish only if something moved.
    if_changed,
};

/// In-flight jobs at once. Bounded by how many the backend will overlap: a pool of a dozen
/// reads for the disk, a dozen round trips for a mount.
const window: usize = 16;
/// Files in a directory listing that get their `stat` from the listing itself (a mount says
/// size and modified time; the disk does not) skip the stat job.

indexer: *Indexer,
src: Source,
mode: Mode,
/// Null for a full scan; the vault-relative paths to probe for a scoped one (owned), and
/// how many have been started.
targets: ?[][]u8 = null,
targets_next: usize = 0,

phase: Phase = .count,
/// Directories still to list, vault-relative (`""` is the root). A stack: depth-first, like
/// the walk it replaces, so a batch of reads comes from one folder.
dirs: std.ArrayListUnmanaged([]u8) = .empty,
/// Files decided upon by a listing, waiting for a stat (disk) or already carrying one.
files: std.ArrayListUnmanaged(FileTodo) = .empty,
/// Files whose stat said "read me", waiting for a slot in the window.
reads: std.ArrayListUnmanaged(ReadTodo) = .empty,
in_flight: std.AutoArrayHashMapUnmanaged(u64, *Job) = .empty,
/// Completions the callbacks parked for `step` to apply, in arrival order.
landed: std.ArrayListUnmanaged(*Job) = .empty,
next_job: u64 = 1,

/// Every real note seen this walk (owned), so a note whose file vanished can be dropped.
seen: std.StringHashMapUnmanaged(void) = .empty,
media_seen: std.StringHashMapUnmanaged(void) = .empty,
changed: bool = false,
count_total: u32 = 0,
files_since_progress: usize = 0,
/// The relink pass's cursor (note id) and whether it grew the note set.
relink_id: i64 = 1,
relink_done: u32 = 0,
made_phantom: bool = false,
/// Marks for the timings, taken by the indexer's clock.
t_phase: i96 = 0,

pub const Phase = enum { count, walk, targets, drop, relink, publish, done };

const FileTodo = struct {
    rel: []u8,
    /// From the listing when the backend had them; otherwise a stat job fills them in.
    size: u64,
    modified_ms: i64,
    known: bool,
};

const ReadTodo = struct {
    rel: []u8,
    mtime_ns: i64,
    size: i64,
    known_id: i64,
    known_hash: i64,
    had_known: bool,
};

const Job = struct {
    scan: *Scan,
    id: u64,
    kind: union(enum) {
        list: struct { rel: []u8, count_only: bool, result: ?vfs.Error![]vfs.Entry = null },
        stat: struct { todo: FileTodo, result: ?vfs.Error!vfs.Stat = null },
        read: struct { todo: ReadTodo, result: ?vfs.Error!vfs.Read = null },
    },
    job: vfs.Job = .{ .id = 0 },

    fn destroy(job: *Job, gpa: std.mem.Allocator) void {
        switch (job.kind) {
            .list => |l| {
                gpa.free(l.rel);
                if (l.result) |r| if (r) |entries| vfs.freeEntries(gpa, entries) else |_| {};
            },
            .stat => |s| gpa.free(s.todo.rel),
            .read => |r| {
                gpa.free(r.todo.rel);
                if (r.result) |res| if (res) |read| gpa.free(read.bytes) else |_| {};
            },
        }
        gpa.destroy(job);
    }
};

pub fn init(indexer: *Indexer, src: Source, mode: Mode) Scan {
    return .{ .indexer = indexer, .src = src, .mode = mode };
}

/// A scoped scan: probe (and, if changed, read) exactly `rels`, then relink and publish.
/// Takes ownership of the paths.
pub fn initTargets(indexer: *Indexer, src: Source, rels: [][]u8) Scan {
    return .{ .indexer = indexer, .src = src, .mode = .always, .targets = rels, .phase = .targets };
}

pub fn deinit(self: *Scan) void {
    const gpa = self.indexer.gpa;
    for (self.in_flight.values()) |job| {
        self.src.fs.cancel(job.job);
        job.destroy(gpa);
    }
    self.in_flight.deinit(gpa);
    for (self.landed.items) |job| job.destroy(gpa);
    self.landed.deinit(gpa);
    for (self.dirs.items) |d| gpa.free(d);
    self.dirs.deinit(gpa);
    for (self.files.items) |f| gpa.free(f.rel);
    self.files.deinit(gpa);
    for (self.reads.items) |r| gpa.free(r.rel);
    self.reads.deinit(gpa);
    if (self.targets) |ts| {
        for (ts) |t| gpa.free(t);
        gpa.free(ts);
    }
    var it = self.seen.keyIterator();
    while (it.next()) |k| gpa.free(k.*);
    self.seen.deinit(gpa);
    var mit = self.media_seen.keyIterator();
    while (mit.next()) |k| gpa.free(k.*);
    self.media_seen.deinit(gpa);
}

pub fn task(self: *Scan) work.Task {
    return .{ .ctx = self, .vtable = &task_vtable };
}
const task_vtable: work.Task.VTable = .{ .step = taskStep, .cancel = taskCancel };
fn taskStep(ctx: *anyopaque, deadline_ns: i64) work.Status {
    const self: *Scan = @ptrCast(@alignCast(ctx));
    return self.step(deadline_ns);
}
fn taskCancel(ctx: *anyopaque) void {
    const self: *Scan = @ptrCast(@alignCast(ctx));
    self.indexer.quit.store(true, .release);
}

/// Run to completion on this thread: the bench and the tests, with a source that pumps itself.
pub fn runBlocking(self: *Scan) !void {
    while (true) {
        switch (self.step(std.math.maxInt(i64))) {
            .done => return,
            .more => {},
            .waiting => std.Thread.yield() catch {},
        }
        if (self.indexer.quit.load(.acquire)) return;
    }
}

// ---- the step -------------------------------------------------------------------------------

pub fn step(self: *Scan, deadline_ns: i64) work.Status {
    const ix = self.indexer;
    if (ix.quit.load(.acquire)) return .done;
    self.src.fs.pump();
    return self.stepInner(deadline_ns) catch |err| {
        log.err("scan: {s}", .{@errorName(err)});
        return .done;
    };
}

fn stepInner(self: *Scan, deadline_ns: i64) !work.Status {
    const ix = self.indexer;
    while (true) {
        if (ix.quit.load(.acquire)) return .done;
        switch (self.phase) {
            .count, .walk, .targets => {
                // Apply what has landed, then fill the window.
                // From the end: order of application does not matter, and shifting a
                // directory's worth of entries per file would be quadratic.
                while (self.landed.items.len != 0) {
                    const job = self.landed.pop().?;
                    defer job.destroy(ix.gpa);
                    try self.apply(job);
                    if (overBudget(deadline_ns)) break;
                }
                try self.issue();
                if (self.landed.items.len != 0 or (self.hasQueued() and self.in_flight.count() < window)) {
                    if (overBudget(deadline_ns)) return .more;
                    continue;
                }
                if (self.in_flight.count() != 0) {
                    // A backend that answers at once (the disk, a zip in memory) has the window's
                    // worth landed already; take it now rather than a frame later.
                    self.src.fs.pump();
                    if (self.landed.items.len != 0 and !overBudget(deadline_ns)) continue;
                    return .waiting;
                }
                // Nothing queued, nothing in flight: the phase is over.
                switch (self.phase) {
                    .count => {
                        ix.timings.prepass_ns = ix.sinceNs(self.t_phase);
                        ix.scan_total.store(self.count_total, .release);
                        try self.beginWalk();
                    },
                    .walk => {
                        ix.timings.walk_ns = ix.sinceNs(self.t_phase);
                        self.phase = .drop;
                    },
                    .targets => self.phase = .relink,
                    else => unreachable,
                }
            },
            .drop => {
                // Anything real that we didn't see is gone from disk. A note deleted outside
                // the editor is its own kind of stale edge, so these count as changes too, and
                // a note that vanished is structural by definition.
                const t0 = ix.markNs();
                if (try ix.dropMissing(&self.seen)) {
                    self.changed = true;
                    ix.scan_structural = true;
                }
                if (try ix.dropMissingMedia(&self.media_seen)) self.changed = true;
                ix.timings.drop_ns = ix.sinceNs(t0);
                if (self.mode == .if_changed and !self.changed) {
                    self.phase = .done;
                    return .done;
                }
                self.phase = .relink;
                self.t_phase = ix.markNs();
                // Resolve every link against the final note set — but only if the walk moved
                // something. Scoped when the walk only found edited notes; a note appearing,
                // vanishing or being renamed moves where *other* notes' links resolve, and
                // nothing narrower is correct for that.
                if (!self.changed and self.targets == null) {
                    self.phase = .publish;
                } else if (!ix.scan_structural and ix.scan_rewrote.items.len != 0) {
                    for (ix.scan_rewrote.items) |id| {
                        _ = ix.relinkNote(id) catch |err| log.warn("relink note {d}: {s}", .{ id, @errorName(err) });
                    }
                    self.phase = .publish;
                } else {
                    ix.dropResolveCache();
                }
            },
            .relink => {
                // A chunk of notes per step, the index lock held per chunk; the cursor is the
                // note id, so a phantom appended along the way needs no visit.
                if (try ix.relinkChunk(&self.relink_id, &self.relink_done, &self.made_phantom)) {
                    ix.scan_rewrote.clearRetainingCapacity();
                    ix.scan_structural = false;
                    ix.timings.relink_ns = ix.sinceNs(self.t_phase);
                    self.phase = .publish;
                } else if (overBudget(deadline_ns)) return .more;
            },
            .publish => {
                ix.publishProgress(.publishing, 0, 0);
                sdk.refresh();
                const t0 = ix.markNs();
                try ix.commitAndPublish();
                ix.timings.publish_ns = ix.sinceNs(t0);
                if (self.targets == null) ix.logTimings();
                // A quiet sweep skips the worker's own wake, so this is the only nudge the UI
                // gets when a background walk finds that something changed.
                sdk.refresh();
                self.phase = .done;
                return .done;
            },
            .done => return .done,
        }
    }
}

/// Never over budget for the unbounded deadline the blocking runs pass — which also keeps the
/// clock (the host's `Io`) out of the headless tests.
fn overBudget(deadline_ns: i64) bool {
    if (deadline_ns == std.math.maxInt(i64)) return false;
    return Indexer.nowNs() >= deadline_ns;
}

fn hasQueued(self: *const Scan) bool {
    return self.dirs.items.len != 0 or self.files.items.len != 0 or self.reads.items.len != 0 or
        (self.targets != null and self.targets_next < self.targets.?.len);
}

/// The count phase's opening: the root, listed for a count. Called once, by `begin`.
pub fn begin(self: *Scan) !void {
    const ix = self.indexer;
    ix.pending_broad = true;
    if (self.targets != null) {
        // The incremental path runs on every save and does not need a clock in it — and the
        // headless tests drive it with no host `Io` to read one from.
        ix.timing = false;
        self.phase = .targets;
        return;
    }
    ix.timings.reset();
    ix.timing = true;
    self.t_phase = ix.markNs();
    // Hand the UI whatever the previous session already indexed, before walking anything —
    // exactly once per opened vault (see `Indexer.cand_pending`).
    if (ix.cand_pending.load(.acquire)) {
        ix.publishCandidates();
        sdk.refresh();
    }
    if (self.mode == .always) {
        self.phase = .count;
        try self.dirs.append(ix.gpa, try ix.gpa.dupe(u8, ""));
    } else {
        try self.beginWalk();
    }
}

fn beginWalk(self: *Scan) !void {
    self.phase = .walk;
    self.t_phase = self.indexer.markNs();
    try self.dirs.append(self.indexer.gpa, try self.indexer.gpa.dupe(u8, ""));
}

/// Start jobs while there is room in the window: reads first (they are the work), then
/// stats, then listings.
fn issue(self: *Scan) !void {
    const gpa = self.indexer.gpa;
    while (self.in_flight.count() < window) {
        if (self.reads.items.len != 0) {
            const todo = self.reads.pop().?;
            try self.start(.{ .read = .{ .todo = todo } });
        } else if (self.files.items.len != 0) {
            const f = self.files.pop().?;
            if (f.known) {
                // The listing said size and time; decide without a stat.
                try self.probe(f.rel, f.size, f.modified_ms);
                gpa.free(f.rel);
            } else {
                try self.start(.{ .stat = .{ .todo = f } });
            }
        } else if (self.targets != null and self.targets_next < self.targets.?.len) {
            const rel = try gpa.dupe(u8, self.targets.?[self.targets_next]);
            self.targets_next += 1;
            try self.start(.{ .stat = .{ .todo = .{ .rel = rel, .size = 0, .modified_ms = 0, .known = false } } });
        } else if (self.dirs.items.len != 0) {
            const rel = self.dirs.pop().?;
            try self.start(.{ .list = .{ .rel = rel, .count_only = self.phase == .count } });
        } else return;
    }
}

fn start(self: *Scan, kind: @FieldType(Job, "kind")) !void {
    const gpa = self.indexer.gpa;
    const job = try gpa.create(Job);
    job.* = .{ .scan = self, .id = self.next_job, .kind = kind };
    self.next_job += 1;
    var path_buf: [4096]u8 = undefined;
    const rel = switch (job.kind) {
        .list => |l| l.rel,
        .stat => |s| s.todo.rel,
        .read => |r| r.todo.rel,
    };
    const fs_path = self.fsPath(&path_buf, rel) orelse {
        job.destroy(gpa);
        return;
    };
    try self.in_flight.put(gpa, job.id, job);
    const started = switch (job.kind) {
        .list => self.src.fs.listDir(gpa, fs_path, onListed, job),
        .stat => self.src.fs.stat(fs_path, onStat, job),
        .read => self.src.fs.readFile(gpa, fs_path, onRead, job),
    };
    job.job = started catch |err| {
        _ = self.in_flight.swapRemove(job.id);
        log.warn("scan {s}: {s}", .{ rel, @errorName(err) });
        job.destroy(gpa);
        return;
    };
}

/// `rel` as the filesystem names it: under `src.root`, `/`-joined.
fn fsPath(self: *const Scan, buf: []u8, rel: []const u8) ?[]const u8 {
    if (rel.len == 0) return self.src.root;
    const root = self.src.root;
    const sep: []const u8 = if (root.len != 0 and root[root.len - 1] == '/') "" else "/";
    return std.fmt.bufPrint(buf, "{s}{s}{s}", .{ root, sep, rel }) catch null;
}

/// `rel` as the host names it: under the indexer's `vault_root` (the ignore rules want that).
fn hostPath(self: *const Scan, buf: []u8, rel: []const u8) ?[]const u8 {
    const root = self.indexer.vault_root;
    if (rel.len == 0) return root;
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ root, rel }) catch null;
}

fn land(job: *Job) void {
    const self = job.scan;
    _ = self.in_flight.swapRemove(job.id);
    self.landed.append(self.indexer.gpa, job) catch job.destroy(self.indexer.gpa);
}
fn onListed(ctx: ?*anyopaque, result: vfs.Error![]vfs.Entry) void {
    const job: *Job = @ptrCast(@alignCast(ctx.?));
    job.kind.list.result = result;
    land(job);
}
fn onStat(ctx: ?*anyopaque, result: vfs.Error!vfs.Stat) void {
    const job: *Job = @ptrCast(@alignCast(ctx.?));
    job.kind.stat.result = result;
    land(job);
}
fn onRead(ctx: ?*anyopaque, result: vfs.Error!vfs.Read) void {
    const job: *Job = @ptrCast(@alignCast(ctx.?));
    job.kind.read.result = result;
    land(job);
}

/// One landed job: a listing feeds the queues, a stat decides, a read is applied.
fn apply(self: *Scan, job: *Job) !void {
    const ix = self.indexer;
    const gpa = ix.gpa;
    switch (job.kind) {
        .list => |*l| {
            const entries = (l.result orelse return) catch |err| {
                log.warn("list {s}: {s}", .{ l.rel, @errorName(err) });
                return;
            };
            var host_buf: [4096]u8 = undefined;
            var rel_buf: [query.max_rel_path]u8 = undefined;
            for (entries) |e| {
                if (ix.quit.load(.acquire)) return;
                if (self.seen.count() >= Indexer.max_notes) return;
                // Dotfiles / dot-dirs are never notes (`.obsidian`, `.git`, …).
                if (e.name.len > 0 and e.name[0] == '.') continue;
                const rel = if (l.rel.len == 0)
                    std.fmt.bufPrint(&rel_buf, "{s}", .{e.name}) catch continue
                else
                    std.fmt.bufPrint(&rel_buf, "{s}/{s}", .{ l.rel, e.name }) catch continue;
                const host_path = self.hostPath(&host_buf, rel) orelse continue;
                const kind: std.Io.File.Kind = if (e.kind == .dir) .directory else .file;
                if (sdk.host().isPathIgnored(ix.vault_root, host_path, e.name, kind)) continue;
                switch (e.kind) {
                    .dir => try self.dirs.append(gpa, try gpa.dupe(u8, rel)),
                    .file => {
                        if (l.count_only) {
                            if (query.isMarkdownPath(e.name)) self.count_total += 1;
                            continue;
                        }
                        if (query.isMediaPath(e.name)) {
                            // Attachments are recorded by path only — never opened, never
                            // parsed, never linked into the graph.
                            const owned = try gpa.dupe(u8, rel);
                            errdefer gpa.free(owned);
                            try self.media_seen.put(gpa, owned, {});
                            ix.upsertMedia(rel) catch |err| log.warn("index media {s}: {s}", .{ rel, @errorName(err) });
                            continue;
                        }
                        if (!query.isMarkdownPath(e.name)) continue;
                        const owned = try gpa.dupe(u8, rel);
                        errdefer gpa.free(owned);
                        try self.seen.put(gpa, owned, {});
                        try self.files.append(gpa, .{
                            .rel = try gpa.dupe(u8, rel),
                            .size = e.size,
                            .modified_ms = e.modified_ms,
                            .known = e.modified_ms != 0,
                        });
                    },
                }
            }
        },
        .stat => |*s| {
            const st = (s.result orelse return) catch {
                // Gone: a target that was deleted, or a file that vanished mid-walk. Its row
                // is retired now rather than by the drop pass, so a scoped scan sees it too.
                ix.deleteNoteByPath(s.todo.rel) catch {};
                self.changed = true;
                ix.scan_structural = true;
                return;
            };
            if (st.kind != .file) return;
            try self.probe(s.todo.rel, st.size, st.modified_ms);
        },
        .read => |*r| {
            const read = (r.result orelse return) catch |err| {
                log.warn("read {s}: {s}", .{ r.todo.rel, @errorName(err) });
                return;
            };
            const t0 = ix.markNs();
            const outcome = ix.applyFile(.{
                .rel = r.todo.rel,
                .mtime_ns = r.todo.mtime_ns,
                .size = r.todo.size,
                .known_id = r.todo.known_id,
                .known_hash = r.todo.known_hash,
                .had_known = r.todo.had_known,
            }, read.bytes) catch |err| blk: {
                log.warn("index {s}: {s}", .{ r.todo.rel, @errorName(err) });
                break :blk Indexer.IndexOutcome.unchanged;
            };
            ix.timings.read_ns += ix.sinceNs(t0);
            switch (outcome) {
                .unchanged => {},
                .rewrote => |id| {
                    self.changed = true;
                    ix.scan_rewrote.append(gpa, id) catch {
                        ix.scan_structural = true;
                    };
                },
                .structural => {
                    self.changed = true;
                    ix.scan_structural = true;
                },
            }
            try self.progressed();
        },
    }
}

/// The cheap half of indexing one file: with its size and time in hand, whether it needs
/// reading at all — a warm open still touches no file contents.
fn probe(self: *Scan, rel: []const u8, size: u64, modified_ms: i64) !void {
    const ix = self.indexer;
    if (size > Indexer.max_file_bytes) return;
    const mtime_ns: i64 = modified_ms * std.time.ns_per_ms;
    const known = ix.lookupNoteMeta(rel);
    if (known) |meta| {
        if (meta.mtime_ns == mtime_ns and meta.size == @as(i64, @intCast(size))) {
            ix.timings.files_skipped += 1;
            try self.progressed();
            return;
        }
    }
    ix.timings.files_read += 1;
    try self.reads.append(ix.gpa, .{
        .rel = try ix.gpa.dupe(u8, rel),
        .mtime_ns = mtime_ns,
        .size = @intCast(size),
        .known_id = if (known) |m| m.id else 0,
        .known_hash = if (known) |m| m.hash else 0,
        .had_known = known != null,
    });
}

/// One more file accounted for: stream progress on the batch cadence (a sweep stays silent).
fn progressed(self: *Scan) !void {
    const ix = self.indexer;
    self.files_since_progress += 1;
    if (self.files_since_progress >= Indexer.batch_files) {
        self.files_since_progress = 0;
        if (self.mode == .always and self.targets == null) {
            ix.publishProgress(.scanning, @intCast(self.seen.count()), ix.scan_total.load(.acquire));
            sdk.refresh();
        }
    }
}
