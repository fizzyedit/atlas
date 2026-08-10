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

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const check = try conn.oneAlloc([]const u8, arena.allocator(), "PRAGMA integrity_check", .{}, .{});
    const result = check orelse return error.IntegrityCheckFailed;
    if (!std.mem.eql(u8, result, "ok")) return error.IntegrityCheckFailed;

    return conn;
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
}

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
