//! Detect an in-progress `[[…]]` around the caret for autocomplete.
//!
//! Pure string scan — no SDK, no DB. Shared by the completion provider and its unit tests.
const std = @import("std");

pub const Context = struct {
    /// Bytes after `[[` and before `|` / `#` / caret — the stem being typed.
    prefix: []const u8,
    /// Start of the opening `[[`.
    replace_start: usize,
    /// End of the closing `]]` when present on the line, otherwise the caret.
    replace_end: usize,
    /// True for `![[…]]`. The completer offers media instead of notes, and the `!` is left
    /// outside `replace_start` so accepting an item keeps the embed an embed.
    embed: bool = false,
};

/// Find an open `[[…]]` around `caret`. Null when the caret isn't inside one (so other
/// completion providers can still win via first-non-null).
pub fn find(bytes: []const u8, caret: usize) ?Context {
    if (caret > bytes.len) return null;

    var line_start = caret;
    while (line_start > 0 and bytes[line_start - 1] != '\n') : (line_start -= 1) {}

    var open: ?usize = null;
    var i = line_start;
    while (i + 1 < caret) : (i += 1) {
        if (bytes[i] == '[' and bytes[i + 1] == '[') {
            open = i;
            i += 1;
        } else if (open != null and bytes[i] == ']' and bytes[i + 1] == ']') {
            open = null;
            i += 1;
        }
    }
    const o = open orelse return null;

    const body_start = o + 2;
    var body_end = caret;
    var p = body_start;
    while (p < caret) : (p += 1) {
        if (bytes[p] == '|' or bytes[p] == '#') {
            body_end = p;
            break;
        }
    }

    var replace_end = caret;
    var q = caret;
    while (q < bytes.len and bytes[q] != '\n') : (q += 1) {
        if (q + 1 < bytes.len and bytes[q] == ']' and bytes[q + 1] == ']') {
            replace_end = q + 2;
            break;
        }
    }

    return .{
        .prefix = bytes[body_start..body_end],
        .replace_start = o,
        .replace_end = replace_end,
        .embed = o > 0 and bytes[o - 1] == '!',
    };
}

const testing = std.testing;

test "inside auto-closed pair" {
    const bytes = "see [[cla]]";
    const caret = "see [[cla".len;
    const ctx = find(bytes, caret).?;
    try testing.expectEqualStrings("cla", ctx.prefix);
    try testing.expectEqual(@as(usize, 4), ctx.replace_start);
    try testing.expectEqual(bytes.len, ctx.replace_end);
}

test "empty body" {
    const full = "[[]]";
    const ctx = find(full, 2).?;
    try testing.expectEqualStrings("", ctx.prefix);
    try testing.expectEqual(@as(usize, 0), ctx.replace_start);
    try testing.expectEqual(@as(usize, 4), ctx.replace_end);
}

test "ignores closed links" {
    const bytes = "[[done]] and more";
    try testing.expect(find(bytes, bytes.len) == null);
}

test "stops prefix at pipe" {
    const bytes = "[[Note|ali]]";
    const caret = "[[Note|ali".len;
    const ctx = find(bytes, caret).?;
    try testing.expectEqualStrings("Note", ctx.prefix);
}

test "does not cross newlines" {
    const bytes = "[[a\n]]";
    // caret after newline — no open [[ on this line
    try testing.expect(find(bytes, bytes.len) == null);
}

test "embed leaves the bang outside the replace range" {
    // `![[dia|]]` — replace starts at `[[` so accepting keeps the `!` and yields `![…](…)`.
    const bytes = "see ![[dia]]";
    const caret = "see ![[dia".len;
    const ctx = find(bytes, caret).?;
    try testing.expect(ctx.embed);
    try testing.expectEqualStrings("dia", ctx.prefix);
    try testing.expectEqual(@as(usize, "see !".len), ctx.replace_start);
    try testing.expectEqual(bytes.len, ctx.replace_end);
    try testing.expect(bytes[ctx.replace_start - 1] == '!');
}

test "plain wikilink is not an embed" {
    const bytes = "[[note]]";
    const ctx = find(bytes, "[[note".len).?;
    try testing.expect(!ctx.embed);
}
