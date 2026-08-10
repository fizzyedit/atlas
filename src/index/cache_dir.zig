//! Where a vault's index file lives.
//!
//! Split from `Db.zig` on purpose: path resolution is a pure function of the environment, so
//! keeping it here lets the database logic be tested against real sqlite without dragging path
//! policy into it — and lets the policy be tested with no filesystem, database, or dvui at all.
//!
//! **Must not be under fizzy's config folder.** `SettingsWatcher` puts a *recursive* watch on
//! `<config>/`, and its handler wakes the event loop for any path under that tree without
//! looking at which one. The index is SQLite in WAL mode, so every transaction — and every
//! reader, via the mmap'd `-shm` — rewrites a file next to `settings.zon`. Kept there, each
//! write fired the watcher, which spun the frame loop flat out for its 200ms coalesce window,
//! and the frames it produced ran `endFrame` → `Watcher.tick` → another query → another event.
//! fizzy never slept, with or without the graph panel open. The index is derived, rebuildable
//! data; a cache root is where it belongs anyway.
const std = @import("std");
const builtin = @import("builtin");

/// `<cache>/fizzy/atlas/<16 hex of the vault path>` — one directory per vault, so switching
/// folders doesn't throw away the other one's index.
pub fn forVault(gpa: std.mem.Allocator, vault_root: []const u8) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cache = try cacheFolder(arena);

    var name_buf: [16]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "{x:0>16}", .{
        std.hash.XxHash3.hash(0, vault_root),
    }) catch unreachable;

    return std.fs.path.join(gpa, &.{ cache, "atlas", name });
}

/// `<cache root>/fizzy`, mirroring `core.paths.configFolder`'s shape one root over.
fn cacheFolder(arena: std.mem.Allocator) ![]const u8 {
    const root = (try localCacheRoot(
        builtin.target.os.tag,
        arena,
        env(arena, "HOME"),
        env(arena, "XDG_CACHE_HOME"),
        env(arena, "LOCALAPPDATA"),
    )) orelse return error.NoCacheDir;
    return std.fs.path.join(arena, &.{ root, "fizzy" });
}

/// Per-OS cache root. Deliberately parallel to `core.paths.localConfigRoot` — same argument
/// shape, same "pure function of the environment" testability — but resolving to the platform's
/// *cache* location instead.
///
/// Windows is the one that can't follow the platform convention. Its cache location is
/// `%LOCALAPPDATA%\<App>\Cache`, but `%LOCALAPPDATA%\fizzy` *is* the config folder fizzy
/// watches, so anything beneath it re-creates the bug this module exists to avoid. A sibling
/// directory is the only spelling that is definitely outside the watch.
fn localCacheRoot(
    os: std.Target.Os.Tag,
    allocator: std.mem.Allocator,
    home: ?[]const u8,
    xdg_cache_home: ?[]const u8,
    local_app_data: ?[]const u8,
) !?[]const u8 {
    return switch (os) {
        .windows => if (local_app_data) |l|
            try std.fs.path.join(allocator, &.{ l, "fizzy-cache" })
        else
            null,
        .macos => if (home) |h|
            try std.fs.path.join(allocator, &.{ h, "Library", "Caches" })
        else
            null,
        else => xdg_cache_home orelse (if (home) |h|
            try std.fs.path.join(allocator, &.{ h, ".cache" })
        else
            null),
    };
}

fn env(arena: std.mem.Allocator, name: []const u8) ?[]const u8 {
    return processEnviron().getAlloc(arena, name) catch null;
}

/// Same shape as fizzy's `processEnviron` — `Environ.init` isn't a thing in this Zig.
fn processEnviron() std.process.Environ {
    if (comptime builtin.target.cpu.arch == .wasm32) {
        const empty: [:null]const ?[*:0]const u8 = &.{};
        return .{ .block = .{ .slice = empty } };
    }
    if (builtin.os.tag == .windows) {
        return .{ .block = .global };
    }
    var n: usize = 0;
    while (std.c.environ[n] != null) : (n += 1) {}
    const slice: [:null]const ?[*:0]const u8 = @as([*:null]const ?[*:0]const u8, @ptrCast(std.c.environ))[0..n :null];
    return .{ .block = .{ .slice = slice } };
}

// -- tests ------------------------------------------------------------------------

const testing = std.testing;

test "cache root is not under the watched config root" {
    const a = testing.allocator;

    const mac = (try localCacheRoot(.macos, a, "/Users/x", null, null)).?;
    defer a.free(mac);
    try testing.expectEqualStrings("/Users/x/Library/Caches", mac);

    const linux = (try localCacheRoot(.linux, a, "/home/x", null, null)).?;
    defer a.free(linux);
    try testing.expectEqualStrings("/home/x/.cache", linux);

    // `%LOCALAPPDATA%\fizzy` is the watched config folder, so the cache must be a sibling.
    const win = (try localCacheRoot(.windows, a, null, null, "C:\\Users\\x\\AppData\\Local")).?;
    defer a.free(win);
    try testing.expect(!std.mem.endsWith(u8, win, "fizzy"));
}

test "xdg cache home wins on linux" {
    const a = testing.allocator;
    const got = (try localCacheRoot(.linux, a, "/home/x", "/tmp/xdg", null)).?;
    try testing.expectEqualStrings("/tmp/xdg", got);
}

test "missing environment yields null rather than a bogus path" {
    const a = testing.allocator;
    try testing.expect(try localCacheRoot(.macos, a, null, null, null) == null);
    try testing.expect(try localCacheRoot(.windows, a, null, null, null) == null);
    try testing.expect(try localCacheRoot(.linux, a, null, null, null) == null);
}
