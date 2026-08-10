//! Change detection for the open vault.
//!
//! Three layers, in decreasing order of how much we'd like to rely on them:
//!
//! 1. **`folderPathsChanged`** — fizzy's own recursive filesystem watch on the open folder,
//!    fanned out to every plugin (see `FolderWatcher.zig` in fizzy). This is the real answer:
//!    a note edited by an agent, a git checkout, or another app arrives as an event within the
//!    host's debounce window. atlas doesn't run a watcher of its own, so there is one watch over
//!    the tree instead of one per interested plugin, and the ignore rules are already applied.
//! 2. **endFrame poll** of open `.md` paths every ~2s. Narrower than layer 1 but not redundant:
//!    it is what notices a file this editor itself just wrote, without waiting on the host's
//!    coalesce window, and it works when no watcher could start.
//! 3. **endFrame sweep request**, which asks the indexer to re-walk the whole vault on its own
//!    thread. Every ~15s when there is no watcher, and once every few minutes when there is.
//!    It stays even with a live watcher because "the watcher is running" and "the watcher is
//!    delivering" are not the same claim — the backends differ per platform, and a silently
//!    dead one should cost a few minutes of staleness, not a permanently wrong graph.
//!
//! All three enqueue into `Indexer`; none write the DB themselves. Layers 2 and 3 are
//! deliberately narrow — a full-tree walk belongs to the indexer thread, not the UI frame — and
//! the sweep respects that by only *asking* for one.
//!
//! Both timers are driven from `endFrame`, so they stop while the app is idle. That is fine for
//! what they are: you cannot see a stale graph without a frame being drawn. Layer 1 is not on a
//! timer at all — the host wakes the event loop when it has something.
const std = @import("std");
const dvui = @import("dvui");
const sdk = @import("fizzy_sdk");

const Indexer = @import("Indexer.zig");
const query = @import("query.zig");

const Watcher = @This();

pub const poll_ns: i96 = 2 * std.time.ns_per_s;
/// Longer than `poll_ns` because it walks the tree — though a sweep that finds nothing is a
/// stat and an indexed lookup per note, and publishes nothing at all.
pub const sweep_ns: i96 = 15 * std.time.ns_per_s;
/// Sweep interval while `folderPathsChanged` is live. Long enough not to be the mechanism, short
/// enough to bound how wrong the graph can get if the platform's watcher stops delivering
/// without saying so.
pub const watched_sweep_ns: i96 = 5 * std.time.ns_per_min;

indexer: *Indexer,
vault_root: []const u8 = "",
last_poll_ns: i96 = 0,
last_sweep_ns: i96 = 0,
/// Absolute path → last seen mtime (ns). Owned keys.
mtimes: std.StringHashMapUnmanaged(i64) = .empty,
gpa: std.mem.Allocator,

pub fn init(gpa: std.mem.Allocator, indexer: *Indexer) Watcher {
    return .{ .gpa = gpa, .indexer = indexer };
}

pub fn deinit(self: *Watcher) void {
    self.clear();
    self.mtimes.deinit(self.gpa);
}

pub fn setVault(self: *Watcher, root: []const u8) void {
    self.clear();
    self.vault_root = root;
    self.last_poll_ns = 0;
    self.last_sweep_ns = 0;
}

pub fn clear(self: *Watcher) void {
    var it = self.mtimes.keyIterator();
    while (it.next()) |k| self.gpa.free(k.*);
    self.mtimes.clearRetainingCapacity();
    self.vault_root = "";
}

/// Call from the UI thread's `endFrame`. Cheap when the interval hasn't elapsed.
pub fn tick(self: *Watcher) void {
    if (self.vault_root.len == 0) return;
    const now = std.Io.Clock.boot.now(dvui.io).nanoseconds;

    const host = sdk.host();
    const interval: i96 = if (host.folderWatchActive()) watched_sweep_ns else sweep_ns;
    if (self.last_sweep_ns == 0) {
        // Opening the vault already queued a full scan — start the clock rather than asking
        // for a second walk on the very next frame.
        self.last_sweep_ns = now;
    } else if (now - self.last_sweep_ns >= interval) {
        self.last_sweep_ns = now;
        self.indexer.requestSweep();
    }

    if (self.last_poll_ns != 0 and now - self.last_poll_ns < poll_ns) return;
    self.last_poll_ns = now;

    const n = host.openDocCount();
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const doc = host.docByIndex(i) orelse continue;
        const path = doc.owner.documentPath(doc);
        if (path.len == 0 or !isMarkdownAbs(path)) continue;
        const rel = vaultRelative(self.vault_root, path) orelse continue;

        const st = std.Io.Dir.cwd().statFile(dvui.io, path, .{}) catch {
            // Gone from disk — tell the indexer so the note row can drop.
            self.indexer.enqueueDelete(rel);
            if (self.mtimes.fetchRemove(path)) |kv| self.gpa.free(kv.key);
            continue;
        };
        const mtime: i64 = @truncate(st.mtime.nanoseconds);
        const gop = self.mtimes.getOrPut(self.gpa, path) catch continue;
        if (!gop.found_existing) {
            gop.key_ptr.* = self.gpa.dupe(u8, path) catch {
                _ = self.mtimes.remove(path);
                continue;
            };
            gop.value_ptr.* = mtime;
            // First sighting of an already-open doc: the full scan will have caught it.
            // Still enqueue so a file created *after* the scan and then opened is indexed.
            self.indexer.enqueue(rel);
            continue;
        }
        if (gop.value_ptr.* != mtime) {
            gop.value_ptr.* = mtime;
            self.indexer.enqueue(rel);
        }
    }
}

/// Layer 1: a batch of on-disk changes under the vault, from fizzy's watcher. Paths are absolute
/// and already filtered against the host's ignore rules, and only live for this call.
///
/// Routes what it can one path at a time and falls back to asking for a walk for what it can't.
/// The two cases that can't be routed are worth naming, because both are about the index having
/// rows a path alone doesn't identify:
///
///   * **directories** — one `mv notes/ archive/` moves every note beneath it, and enumerating
///     those is precisely the tree walk the sweep already does well.
///   * **attachments** — an embed resolves against the media table, which the indexer only
///     rebuilds from a walk; there is no single-path entry point for it the way `enqueue` is one
///     for notes.
pub fn onPathsChanged(self: *Watcher, changes: sdk.Plugin.PathChanges) void {
    if (self.vault_root.len == 0) return;
    // `truncated` means the host dropped events, so the list is not a description of what
    // happened and there is nothing to be gained by walking it.
    if (changes.truncated) {
        self.indexer.requestSweep();
        return;
    }

    var want_sweep = false;
    for (changes.events) |e| {
        if (e.object == .dir) {
            want_sweep = true;
            continue;
        }
        // A rename is two facts. The old path has to leave the index on its own — indexing the
        // new one says nothing about where it came from — and on the platforms that can't pair
        // the halves this arrives as delete + create instead, which lands in the same place.
        if (e.kind == .renamed and e.old_path.len > 0) self.route(e.old_path, &want_sweep);
        self.route(e.path, &want_sweep);
    }
    if (want_sweep) self.indexer.requestSweep();
}

fn route(self: *Watcher, abs: []const u8, want_sweep: *bool) void {
    const rel = vaultRelative(self.vault_root, abs) orelse return;
    // Create, modify and delete are all "re-read this path": the worker treats missing-on-disk
    // as the delete, so there is nothing here to branch on.
    if (query.isMarkdownPath(rel)) {
        self.indexer.enqueue(rel);
        return;
    }
    if (query.isMediaPath(rel)) want_sweep.* = true;
}

fn isMarkdownAbs(path: []const u8) bool {
    return std.ascii.endsWithIgnoreCase(path, ".md") or
        std.ascii.endsWithIgnoreCase(path, ".markdown");
}

fn vaultRelative(vault: []const u8, abs: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, abs, vault)) return null;
    var rest = abs[vault.len..];
    while (rest.len > 0 and (rest[0] == '/' or rest[0] == '\\')) rest = rest[1..];
    if (rest.len == 0) return null;
    return rest;
}
