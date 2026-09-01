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

/// The POSIX relative path from `from_file` to `to_file`, allocated in `allocator`.
/// Both arguments are vault-relative (`/`-separated, with extension).
///
/// `std.fs.path.relativePosix` is the whole implementation. Anchoring both sides at `/` makes the
/// vault root the filesystem root for the duration of the call, so the result can never climb out
/// of the vault, and the POSIX variant is used explicitly rather than the native one because a
/// vault-relative path is always `/`-separated (see `query.vaultRelative`) — the link we write has
/// to read the same on every platform.
///
/// A note linking to itself falls out correctly without a special case: `from_dir` is the note's
/// own directory, so the relative path to the note is just its basename.
pub fn relative(allocator: std.mem.Allocator, from_file: []const u8, to_file: []const u8) ![]u8 {
    const from_dir = std.fs.path.dirnamePosix(from_file) orelse "";
    return std.fs.path.relativePosix(allocator, "/", from_dir, to_file);
}

/// Percent-encode a relative path for use inside `(...)`. Unreserved + `/-._~` pass through;
/// everything else (space, parens, non-ASCII bytes) becomes `%HH`.
///
/// Deliberately not `std.Uri.percentEncode` with `Uri.isPathChar`: a URI path may legally contain
/// `(` and `)`, so std leaves them alone — and an unescaped paren inside `[text](path)` ends the
/// markdown link early. The set here is the markdown-safe one, which is narrower than the URI one.
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

/// `[Title > Heading](encoded/rel/path.md#anchor)` — a link into a section of another note.
///
/// The fragment is the GitHub heading slug (see `headingAnchor`), so the link lands on the
/// section in any renderer that follows that convention. fizzy's own preview currently strips
/// the fragment and opens the note at the top; when it learns heading→line, the same links start
/// jumping without anything being rewritten.
pub fn formatHeadingLink(
    allocator: std.mem.Allocator,
    title: []const u8,
    heading: []const u8,
    rel_path: []const u8,
) ![]u8 {
    var enc_buf: [1024]u8 = undefined;
    const enc = try encodeUrlPath(rel_path, &enc_buf);
    var title_buf: [256]u8 = undefined;
    const safe_title = sanitizeTitle(title, &title_buf);
    var heading_buf: [256]u8 = undefined;
    const safe_heading = sanitizeTitle(heading, &heading_buf);
    var anchor_buf: [512]u8 = undefined;
    const anchor = headingAnchor(heading, &anchor_buf);
    return std.fmt.allocPrint(allocator, "[{s} > {s}]({s}#{s})", .{ safe_title, safe_heading, enc, anchor });
}

/// GitHub's heading slug: lowercased, punctuation dropped, runs of whitespace collapsed to a
/// single `-`. Truncated (never split mid-escape — there are none) when it doesn't fit `buf`.
///
/// Not percent-encoded: every byte it emits is already URL-safe, and non-ASCII passes through
/// lowercased-as-is, which is what GitHub does with a Unicode heading.
pub fn headingAnchor(heading: []const u8, buf: []u8) []const u8 {
    var n: usize = 0;
    var pending_dash = false;
    for (heading) |c| {
        if (c == ' ' or c == '\t' or c == '-' or c == '_') {
            // A separator only becomes a `-` once something follows it, so the slug never
            // leads or trails with one.
            if (n > 0) pending_dash = true;
            continue;
        }
        const keep = std.ascii.isAlphanumeric(c) or c >= 0x80;
        if (!keep) continue;
        if (pending_dash) {
            if (n >= buf.len) break;
            buf[n] = '-';
            n += 1;
            pending_dash = false;
        }
        if (n >= buf.len) break;
        buf[n] = std.ascii.toLower(c);
        n += 1;
    }
    return buf[0..n];
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

// -- tests ------------------------------------------------------------------------

const testing = std.testing;

fn expectRelative(expected: []const u8, from_file: []const u8, to_file: []const u8) !void {
    const r = try relative(testing.allocator, from_file, to_file);
    defer testing.allocator.free(r);
    try testing.expectEqualStrings(expected, r);
}

test "same directory" {
    try expectRelative("physics.md", "readme.md", "physics.md");
}

test "into subdirectory" {
    try expectRelative("notes/daily.md", "readme.md", "notes/daily.md");
}

test "up one level" {
    try expectRelative("../readme.md", "notes/daily.md", "readme.md");
}

test "cousin directories" {
    try expectRelative("../b/y.md", "a/x.md", "b/y.md");
}

test "deeper nesting" {
    try expectRelative("../api/ref.md", "docs/guide/intro.md", "docs/api/ref.md");
}

test "a note linking to itself keeps its own name" {
    try expectRelative("daily.md", "notes/daily.md", "notes/daily.md");
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

test "headingAnchor slugs like GitHub" {
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("habitat-and-range", headingAnchor("Habitat and Range", &buf));
    try testing.expectEqualStrings("whats-new", headingAnchor("What's new?", &buf));
    try testing.expectEqualStrings("a-b", headingAnchor("  A   B  ", &buf));
    try testing.expectEqualStrings("", headingAnchor("!!!", &buf));
}

test "formatHeadingLink" {
    const s = try formatHeadingLink(testing.allocator, "Daphne", "Habitat and Range", "notes/daphne.md");
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("[Daphne > Habitat and Range](notes/daphne.md#habitat-and-range)", s);
}
