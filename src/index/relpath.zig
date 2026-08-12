//! Vault-relative path arithmetic for portable markdown links.
//!
//! Link format we write (and teach the preview to open):
//!
//! ```
//! [Title](relative/path.md)
//! ```
//!
//! - Path is relative to the **source note's directory** (not the vault root).
//! - Always includes the real extension (`.md` / `.markdown`).
//! - Same directory → `Note.md` (no `./` prefix — GitHub-friendly).
//! - Parent directories → `../Note.md`.
//! - Forward slashes only; spaces / parentheses percent-encoded in the URL.
//! - Display text is the note title (front matter) or stem.
//!
//! Leading `/` (vault-root) is deliberately avoided: CommonMark treats it as site/filesystem
//! root, so those links break outside fizzy.
const std = @import("std");

/// Write the POSIX relative path from `from_file` to `to_file` into `buf`.
/// Both arguments are vault-relative (`/`-separated, with extension). Returns the written slice.
pub fn relative(from_file: []const u8, to_file: []const u8, buf: []u8) error{NoSpaceLeft}![]u8 {
    const from_dir = dirname(from_file);
    var from_parts: [64][]const u8 = undefined;
    var to_parts: [64][]const u8 = undefined;
    const from_n = split(from_dir, &from_parts);
    const to_n = split(to_file, &to_parts);

    var common: usize = 0;
    while (common < from_n and common < to_n and std.mem.eql(u8, from_parts[common], to_parts[common])) : (common += 1) {}

    var out_len: usize = 0;
    var i = common;
    while (i < from_n) : (i += 1) {
        if (out_len + 3 > buf.len) return error.NoSpaceLeft;
        if (out_len > 0) {
            // `../` already ends with slash from previous; just append
        }
        @memcpy(buf[out_len..][0..3], "../");
        out_len += 3;
    }

    var j = common;
    while (j < to_n) : (j += 1) {
        const seg = to_parts[j];
        const need = seg.len + @intFromBool(out_len > 0 and buf[out_len - 1] != '/');
        // When we already end with `/` from `../`, don't add another.
        const add_slash = out_len > 0 and buf[out_len - 1] != '/';
        const total = seg.len + @as(usize, if (add_slash) 1 else 0);
        _ = need;
        if (out_len + total > buf.len) return error.NoSpaceLeft;
        if (add_slash) {
            buf[out_len] = '/';
            out_len += 1;
        }
        @memcpy(buf[out_len..][0..seg.len], seg);
        out_len += seg.len;
    }

    if (out_len == 0) {
        // Same path — rare (linking a note to itself); keep the basename.
        const base = basename(to_file);
        if (base.len > buf.len) return error.NoSpaceLeft;
        @memcpy(buf[0..base.len], base);
        return buf[0..base.len];
    }
    return buf[0..out_len];
}

/// Percent-encode a relative path for use inside `(...)`. Unreserved + `/-._~` pass through;
/// everything else (space, parens, non-ASCII bytes) becomes `%HH`.
pub fn encodeUrlPath(path: []const u8, buf: []u8) error{NoSpaceLeft}![]u8 {
    var out: usize = 0;
    for (path) |c| {
        if (isUnreserved(c) or c == '/' or c == '.' or c == '_' or c == '-' or c == '~') {
            if (out >= buf.len) return error.NoSpaceLeft;
            buf[out] = c;
            out += 1;
        } else {
            if (out + 3 > buf.len) return error.NoSpaceLeft;
            const hex = "0123456789ABCDEF";
            buf[out] = '%';
            buf[out + 1] = hex[c >> 4];
            buf[out + 2] = hex[c & 0xf];
            out += 3;
        }
    }
    return buf[0..out];
}

/// `[Title](encoded/rel/path.md)` — title has `[`/`]` stripped so the markdown stays well-formed.
pub fn formatLink(allocator: std.mem.Allocator, title: []const u8, rel_path: []const u8) ![]u8 {
    var enc_buf: [1024]u8 = undefined;
    const enc = try encodeUrlPath(rel_path, &enc_buf);
    var title_buf: [256]u8 = undefined;
    const safe_title = sanitizeTitle(title, &title_buf);
    return std.fmt.allocPrint(allocator, "[{s}]({s})", .{ safe_title, enc });
}

fn sanitizeTitle(title: []const u8, buf: []u8) []const u8 {
    var n: usize = 0;
    for (title) |c| {
        if (c == '[' or c == ']') continue;
        if (n >= buf.len) break;
        buf[n] = c;
        n += 1;
    }
    if (n == 0) return "note";
    return buf[0..n];
}

fn isUnreserved(c: u8) bool {
    return std.ascii.isAlphanumeric(c);
}

pub fn dirname(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| return path[0..i];
    return "";
}

pub fn basename(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| return path[i + 1 ..];
    return path;
}

fn split(path: []const u8, out: [][]const u8) usize {
    if (path.len == 0) return 0;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |part| {
        if (part.len == 0) continue;
        if (n >= out.len) break;
        out[n] = part;
        n += 1;
    }
    return n;
}

// -- tests ------------------------------------------------------------------------

const testing = std.testing;

test "same directory" {
    var buf: [128]u8 = undefined;
    const r = try relative("readme.md", "physics.md", &buf);
    try testing.expectEqualStrings("physics.md", r);
}

test "into subdirectory" {
    var buf: [128]u8 = undefined;
    const r = try relative("readme.md", "notes/daily.md", &buf);
    try testing.expectEqualStrings("notes/daily.md", r);
}

test "up one level" {
    var buf: [128]u8 = undefined;
    const r = try relative("notes/daily.md", "readme.md", &buf);
    try testing.expectEqualStrings("../readme.md", r);
}

test "cousin directories" {
    var buf: [128]u8 = undefined;
    const r = try relative("a/x.md", "b/y.md", &buf);
    try testing.expectEqualStrings("../b/y.md", r);
}

test "deeper nesting" {
    var buf: [128]u8 = undefined;
    const r = try relative("docs/guide/intro.md", "docs/api/ref.md", &buf);
    try testing.expectEqualStrings("../api/ref.md", r);
}

test "encode spaces" {
    var buf: [128]u8 = undefined;
    const r = try encodeUrlPath("my note.md", &buf);
    try testing.expectEqualStrings("my%20note.md", r);
}

test "formatLink" {
    const s = try formatLink(testing.allocator, "Physics", "notes/physics.md");
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("[Physics](notes/physics.md)", s);
}
