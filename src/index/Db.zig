//! The index database: where it lives, how it opens, and when it gets thrown away.
//!
//! **Not in the vault.** The file goes in fizzy's config directory, in a folder named after a
//! hash of the vault's path. Putting it in the vault would be more discoverable, and wrong for
//! four reasons: a vault is usually a git repo and a WAL-mode database churns three files on
//! every save; synced vaults (Dropbox, iCloud) corrupt WAL files across machines; a vault on a
//! read-only mount still has to be browsable; and the database is derived data, which belongs
//! in a cache directory rather than in the user's own tree. `rm -rf` the directory and the next
//! open rebuilds it.
//! Everything here is sqlite-only — no `core`, no dvui — so `db_test.zig` can exercise it
//! headlessly. Locating the file is `cache_dir.zig`'s job.
const std = @import("std");
const sqlite = @import("sqlite");

const schema = @import("schema.zig");

const Db = @This();

conn: sqlite.Db,
/// Absolute path of the database file, owned.
path: []u8,
/// Prepared once, reused for every note. See `Stmts`.
stmts: ?Stmts = null,
/// A second, read-only handle for the UI thread. See `reader`.
read_conn: ?sqlite.Db = null,

/// The SQL the indexer runs per note, named so the cache and the call sites cannot drift: a
/// `Stmts` field and its query share a name, which is what lets `prepare`/`deinit` be one
/// `inline for` instead of thirteen hand-written lines that can fall out of step.
pub const sql = struct {
    pub const note_by_path = "SELECT id, mtime_ns, size, hash FROM notes WHERE path = ? AND phantom = 0";
    pub const note_id_by_path = "SELECT id FROM notes WHERE path = ? AND phantom = 0";
    pub const phantom_by_stem = "SELECT id FROM notes WHERE phantom = 1 AND stem_fold = ? LIMIT 1";
    pub const touch_note = "UPDATE notes SET mtime_ns = ?, size = ? WHERE id = ?";
    pub const update_note = "UPDATE notes SET stem = ?, stem_fold = ?, title = ?, mtime_ns = ?, size = ?, hash = ?, phantom = 0 WHERE id = ?";
    pub const promote_phantom = "UPDATE notes SET path = ?, stem = ?, stem_fold = ?, title = ?, mtime_ns = ?, size = ?, hash = ?, phantom = 0 WHERE id = ?";
    pub const insert_note = "INSERT INTO notes(path, stem, stem_fold, title, mtime_ns, size, hash, phantom) VALUES(?, ?, ?, ?, ?, ?, ?, 0)";
    pub const del_aliases = "DELETE FROM aliases WHERE note_id = ?";
    pub const del_headings = "DELETE FROM headings WHERE note_id = ?";
    pub const del_links = "DELETE FROM links WHERE src_id = ?";
    pub const del_tags = "DELETE FROM tags WHERE note_id = ?";
    pub const del_blocks = "DELETE FROM blocks WHERE note_id = ?";
    pub const ins_alias = "INSERT INTO aliases(note_id, alias, alias_fold) VALUES(?, ?, ?)";
    pub const ins_heading = "INSERT INTO headings(note_id, text, text_fold, level, line) VALUES(?, ?, ?, ?, ?)";
    pub const ins_tag = "INSERT INTO tags(note_id, tag, tag_fold, line) VALUES(?, ?, ?, ?)";
    pub const ins_block = "INSERT INTO blocks(note_id, kind, line_start, line_end, weight) VALUES(?, ?, ?, ?, ?)";
    pub const del_link_row = "DELETE FROM links WHERE rowid = ?";
    pub const update_link = "UPDATE links SET dst_id = ?, ambiguous = ? WHERE rowid = ?";
    pub const ins_link =
        \\INSERT INTO links(src_id, dst_id, raw, heading, alias, kind, ambiguous, line, col)
        \\VALUES(?, ?, ?, ?, ?, ?, 0, ?, ?)
    ;
};

/// Every per-note statement, prepared once.
///
/// `conn.exec`/`conn.one` compile the SQL text on **every call** — this wrapper has no statement
/// cache — and `writeNote` issues around fifty statements for a typical Wikipedia article (five
/// deletes, the note upsert, then one insert per alias, heading, tag, block and link). Across a
/// 283,878-note vault that is roughly fourteen million `sqlite3_prepare_v2` calls, each parsing
/// and compiling SQL, with the actual row write as the cheap part. Preparing once turns fourteen
/// million compilations into seventeen.
///
/// Reuse means `reset` before every use, never after: resetting first is what makes a statement
/// left dirty by a failed write recover on the next note instead of poisoning it.
pub const Stmts = struct {
    note_by_path: sqlite.StatementType(.{}, sql.note_by_path),
    note_id_by_path: sqlite.StatementType(.{}, sql.note_id_by_path),
    phantom_by_stem: sqlite.StatementType(.{}, sql.phantom_by_stem),
    touch_note: sqlite.StatementType(.{}, sql.touch_note),
    update_note: sqlite.StatementType(.{}, sql.update_note),
    promote_phantom: sqlite.StatementType(.{}, sql.promote_phantom),
    insert_note: sqlite.StatementType(.{}, sql.insert_note),
    del_aliases: sqlite.StatementType(.{}, sql.del_aliases),
    del_headings: sqlite.StatementType(.{}, sql.del_headings),
    del_links: sqlite.StatementType(.{}, sql.del_links),
    del_tags: sqlite.StatementType(.{}, sql.del_tags),
    del_blocks: sqlite.StatementType(.{}, sql.del_blocks),
    ins_alias: sqlite.StatementType(.{}, sql.ins_alias),
    ins_heading: sqlite.StatementType(.{}, sql.ins_heading),
    ins_tag: sqlite.StatementType(.{}, sql.ins_tag),
    ins_block: sqlite.StatementType(.{}, sql.ins_block),
    ins_link: sqlite.StatementType(.{}, sql.ins_link),
    del_link_row: sqlite.StatementType(.{}, sql.del_link_row),
    update_link: sqlite.StatementType(.{}, sql.update_link),

    fn prepareAll(conn: *sqlite.Db) !Stmts {
        var out: Stmts = undefined;
        var done: usize = 0;
        errdefer {
            // Unwind exactly the ones that were prepared, so a failure part-way through does not
            // leak the statements before it.
            var i: usize = 0;
            inline for (@typeInfo(Stmts).@"struct".fields) |f| {
                if (i < done) @field(out, f.name).deinit();
                i += 1;
            }
        }
        inline for (@typeInfo(Stmts).@"struct".fields) |f| {
            @field(out, f.name) = try conn.prepare(@field(sql, f.name));
            done += 1;
        }
        return out;
    }

    fn deinitAll(self: *Stmts) void {
        inline for (@typeInfo(Stmts).@"struct".fields) |f| @field(self, f.name).deinit();
    }
};

/// The per-note statements, prepared on first use.
///
/// Lazy rather than prepared in `openIn` because `openIn` returns by value: the statements hold
/// the raw `sqlite3*` (not a pointer to this wrapper), so a move is harmless either way, but
/// preparing after the `Db` has reached its final home keeps that from being a thing to reason
/// about.
/// The connection UI-thread reads should use.
///
/// `conn` is opened `.Serialized`, so every call into it takes one process-wide-per-connection
/// mutex — and that mutex is the whole reason a scan crawls while the app is in use. A CPU sample
/// of the relink write-back found 2,648 of ~2,900 worker samples parked in `__psynch_mutexwait`
/// inside `sqlite3_reset`/`sqlite3_bind_int64`: not doing SQLite work, waiting for the UI thread's
/// turn. The UI runs big reads (`loadCandidates` walks every note), the worker runs millions of
/// tiny writes, and one mutex serializes the two into each other's worst case.
///
/// WAL exists for exactly this: readers never block the writer and never see uncommitted state, so
/// a second handle to the same file removes the contention rather than rationing it. Opened
/// read-only so it cannot become a second writer by accident.
///
/// Falls back to the writer if the read-only open fails — slow is better than broken, and a vault
/// on a read-only mount or an odd filesystem should still work.
pub fn reader(self: *Db) *sqlite.Db {
    if (self.read_conn) |*c| return c;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&buf, "{s}", .{self.path}) catch return &self.conn;
    var c = sqlite.Db.init(.{
        .mode = .{ .File = path_z },
        .open_flags = .{ .write = false },
        .threading_mode = .Serialized,
    }) catch |err| {
        std.log.scoped(.atlas).warn(
            "read-only index connection: {s}; UI reads will share the writer",
            .{@errorName(err)},
        );
        return &self.conn;
    };
    // A reader can still hit SQLITE_BUSY around a checkpoint; wait rather than fail a frame.
    _ = c.pragma(void, .{}, "busy_timeout", "2000") catch {};
    self.read_conn = c;
    return &self.read_conn.?;
}

pub fn cached(self: *Db) !*Stmts {
    if (self.stmts == null) self.stmts = try Stmts.prepareAll(&self.conn);
    return &self.stmts.?;
}

/// Open (or create) the index in `dir` for `vault_root`, rebuilding from scratch if what's on
/// disk isn't a database of the current schema version.
///
/// `io` is threaded in rather than reached for through dvui so this stays testable headlessly;
/// the plugin passes `dvui.io`.
pub fn openIn(gpa: std.mem.Allocator, io: std.Io, dir: []const u8, vault_root: []const u8) !Db {
    std.Io.Dir.cwd().createDirPath(io, dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    // Records which vault this directory belongs to, so a hash collision is detected rather
    // than silently serving one vault's index for another.
    try writeVaultStamp(gpa, io, dir, vault_root);

    const path = try std.fs.path.join(gpa, &.{ dir, "index.db" });
    errdefer gpa.free(path);

    if (openExisting(path)) |conn| {
        return .{ .conn = conn, .path = path };
    } else |err| {
        // Every failure mode lands here on purpose — see the file comment. Rebuilding a cache
        // is cheap; carrying migration code for one is not.
        std.log.scoped(.atlas).info("index unusable ({s}), rebuilding", .{@errorName(err)});
    }

    std.Io.Dir.cwd().deleteFile(io, path) catch {};
    // WAL sidecars outlive the database file and would otherwise be replayed into the new one.
    deleteSidecars(gpa, io, path);

    return .{ .conn = try create(path), .path = path };
}

pub fn close(self: *Db, gpa: std.mem.Allocator) void {
    // Before the connection: `sqlite3_close` refuses to close a database with live statements.
    if (self.stmts) |*st| st.deinitAll();
    self.stmts = null;
    if (self.read_conn) |*c| c.deinit();
    self.read_conn = null;
    self.conn.deinit();
    gpa.free(self.path);
    self.* = undefined;
}

/// Open an existing database, failing if it isn't one, is damaged, or is a version we don't
/// speak. Every one of those is the caller's cue to rebuild.
fn openExisting(path: []const u8) !sqlite.Db {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_z = try std.fmt.bufPrintZ(&buf, "{s}", .{path});

    var conn = try sqlite.Db.init(.{
        .mode = .{ .File = path_z },
        // Deliberately not `.create`: a missing file must take the create path, which stamps
        // the version. Opening a nonexistent database read-write would produce an empty one
        // with no `meta` row, which then reads as a *corrupt* one on the next launch.
        .open_flags = .{ .write = true },
        .threading_mode = .Serialized,
    });
    errdefer conn.deinit();

    try applyPragmas(&conn);

    const found = readVersion(&conn) orelse return error.NoSchemaVersion;
    if (found != schema.version) return error.SchemaVersionMismatch;

    try verifyIntegrity(&conn);
    return conn;
}

/// Largest database this will structurally verify on open.
///
/// `PRAGMA integrity_check` walks and cross-references every b-tree page in the file. On a
/// personal vault's few megabytes that is imperceptible; on a 283,878-note Wikipedia index it is
/// **1.4 GB of pages read on the UI thread**, which presents as a spinning beachball for minutes
/// with no indication of why. A CPU sample of the hang is a wall of recursive `checkTreePage`.
///
/// Above this, the check is skipped rather than made asynchronous, because the thing being
/// protected does not warrant it: this database is *derived data*, rebuildable from the vault at
/// any time — the file header says as much. Real corruption still surfaces, as `SQLITE_CORRUPT`
/// from an ordinary query, and every caller of `openIn` already treats a failed open as its cue to
/// rebuild from scratch. Verifying a disposable cache is worth milliseconds, not minutes.
const integrity_check_max_bytes: u64 = 64 << 20;

fn verifyIntegrity(conn: *sqlite.Db) !void {
    // Size from the connection rather than the filesystem: two cheap pragmas, no `Io` to thread
    // through, and it is the size SQLite itself believes in.
    const page_count = (conn.one(u64, "PRAGMA page_count", .{}, .{}) catch null) orelse 0;
    const page_size = (conn.one(u64, "PRAGMA page_size", .{}, .{}) catch null) orelse 0;
    const bytes = page_count * page_size;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    if (bytes > integrity_check_max_bytes) {
        std.log.scoped(.atlas).debug(
            "index is {d} MB; skipping the open-time integrity check (see integrity_check_max_bytes)",
            .{bytes >> 20},
        );
        return;
    }

    // `quick_check` rather than `integrity_check` even under the cap: it catches the structural
    // damage that matters here — malformed pages, broken b-tree links — and skips the index-vs-
    // table cross-reference pass, which is the expensive half and the one that would only ever
    // tell us to do what a rebuild does anyway.
    const check = try conn.oneAlloc([]const u8, arena.allocator(), "PRAGMA quick_check", .{}, .{});
    const result = check orelse return error.IntegrityCheckFailed;
    if (!std.mem.eql(u8, result, "ok")) return error.IntegrityCheckFailed;
}

fn create(path: []const u8) !sqlite.Db {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_z = try std.fmt.bufPrintZ(&buf, "{s}", .{path});

    var conn = try sqlite.Db.init(.{
        .mode = .{ .File = path_z },
        .open_flags = .{ .write = true, .create = true },
        .threading_mode = .Serialized,
    });
    errdefer conn.deinit();

    try applyPragmas(&conn);
    try conn.execMulti(schema.ddl, .{});
    try setMeta(&conn, "schema_version", schema.version);
    return conn;
}

/// `PRAGMA journal_mode=…` returns a row, so it can't go through `exec`/`execMulti`. The other
/// two don't, but keeping them together means the open path can't forget one.
fn applyPragmas(conn: *sqlite.Db) !void {
    _ = try conn.pragma([128:0]u8, .{}, "journal_mode", "WAL");
    _ = try conn.pragma(void, .{}, "synchronous", "NORMAL");
    _ = try conn.pragma(void, .{}, "foreign_keys", "1");
    _ = try conn.pragma(void, .{}, "cache_size", cache_size_pragma);
    _ = try conn.pragma(void, .{}, "wal_autocheckpoint", wal_autocheckpoint_pages);
}

/// How many WAL pages may accumulate before a commit folds them back into the database.
///
/// SQLite's default is 1000 pages — about 4 MB — which is sized for a database taking occasional
/// writes, not for one being built. A checkpoint `fsync`s the main file, and `synchronous=NORMAL`
/// means the checkpoint is the *only* thing that fsyncs, so the checkpoint interval is really the
/// fsync interval. A CPU sample of `relinkAll` found **6,367 of ~8,800 samples in `fsync`** under
/// `sqlite3WalCheckpoint`, reached from the commit that closes each 20,000-row chunk.
///
/// 20,000 pages (~80 MB) keeps the WAL bounded — it still has to be a size a reader can search and
/// a crash can replay — while making the checkpoint twenty times rarer. This is a threshold, not a
/// schedule: a vault that writes four pages and stops still checkpoints when the connection closes.
const wal_autocheckpoint_pages = "20000";

/// Page cache, as a negative number of **kibibytes** (SQLite's own convention: positive means
/// pages, negative means memory).
///
/// SQLite's default is 2 MB, sized for a database taking occasional writes rather than one being
/// built. A cold build touches 3.35M link rows in two secondary indexes in random key order while
/// the file grows past a gigabyte, so at 2 MB essentially every write faults its b-tree page in and
/// writes it back out — index maintenance degenerates into random I/O. 256 MB is enough to hold the
/// hot interior pages of every index for the reference corpus, and is worth **20 s of a 69 s cold
/// build**, nearly all of it in `relinkAll`, which is the pass whose access pattern is most random.
///
/// Charged per connection, and `reader` opens a second one, so the real ceiling is twice this.
/// That is in keeping with what opening a vault is already allowed to cost (see
/// `docs/design/scale-architecture.md`) — and it is a ceiling, not a reservation: a personal vault
/// never grows a cache it has no pages for.
const cache_size_pragma = "-262144";

fn readVersion(conn: *sqlite.Db) ?u32 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const row = conn.oneAlloc(
        []const u8,
        arena.allocator(),
        "SELECT value FROM meta WHERE key = 'schema_version'",
        .{},
        .{},
    ) catch return null;
    const text = row orelse return null;
    return std.fmt.parseInt(u32, text, 10) catch null;
}

fn setMeta(conn: *sqlite.Db, key: []const u8, value: u32) !void {
    var buf: [32]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, "{d}", .{value});
    try conn.exec(
        "INSERT INTO meta(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        .{},
        .{ key, text },
    );
}

fn deleteSidecars(gpa: std.mem.Allocator, io: std.Io, path: []const u8) void {
    for ([_][]const u8{ "-wal", "-shm", "-journal" }) |suffix| {
        const p = std.fmt.allocPrint(gpa, "{s}{s}", .{ path, suffix }) catch continue;
        defer gpa.free(p);
        std.Io.Dir.cwd().deleteFile(io, p) catch {};
    }
}

/// Note which vault this cache directory serves, and wipe the database if it turns out to
/// serve a different one (a hash collision — vanishingly unlikely, silently wrong if ignored).
fn writeVaultStamp(gpa: std.mem.Allocator, io: std.Io, dir: []const u8, vault_root: []const u8) !void {
    const stamp = try std.fs.path.join(gpa, &.{ dir, "vault.txt" });
    defer gpa.free(stamp);

    if (std.Io.Dir.cwd().readFileAlloc(io, stamp, gpa, .limited(4096))) |existing| {
        defer gpa.free(existing);
        if (std.mem.eql(u8, std.mem.trim(u8, existing, " \n\r\t"), vault_root)) return;
        const db = try std.fs.path.join(gpa, &.{ dir, "index.db" });
        defer gpa.free(db);
        std.Io.Dir.cwd().deleteFile(io, db) catch {};
        deleteSidecars(gpa, io, db);
    } else |_| {}

    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = stamp,
        .data = vault_root,
        .flags = .{ .truncate = true },
    });
}
