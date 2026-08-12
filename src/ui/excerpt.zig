//! Turning a line of markdown source into a short label.
//!
//! The interior view draws one node per item in a note's content graph, and body blocks —
//! paragraphs, lists, code, blockquotes, tables — have no text in the index: `blocks` stores a
//! kind, a line span and a weight, never the prose. The label therefore comes from the file, and
//! this is the part that decides *which* line and *how much of it* to show.
//!
//! Pure: no `dvui`, no `Db`, no allocation. Every slice returned points into the input.

const std = @import("std");

/// First line of real content at or just after `line`, with its markdown decoration stripped, or
/// null if there is nothing worth showing.
///
/// Looks a few lines ahead rather than only at `line`. A block's recorded `line_start` is usually
/// the content itself, but a fenced code block starts on its ``` fence and a block can carry a
/// blank line at the top of its own span. The lookahead is bounded so a search never runs on into
/// the next block and labels it with someone else's text.
pub fn blockExcerpt(lines: []const []const u8, line: u32) ?[]const u8 {
    const start: usize = line;
    if (start >= lines.len) return null;
    const end = @min(start + lookahead, lines.len);

    for (lines[start..end]) |raw| {
        var s = std.mem.trim(u8, raw, " \t\r");
        if (s.len == 0) continue;

        // A fence: prefer its info string ("```zig" → "zig"), else keep looking for the first real
        // line of the body.
        if (std.mem.startsWith(u8, s, "```") or std.mem.startsWith(u8, s, "~~~")) {
            const info = std.mem.trim(u8, s[3..], " \t\r`~");
            if (info.len > 0) return info;
            continue;
        }

        s = stripDecoration(s);

        // A table's separator row (`|---|---|`) says nothing about the table.
        if (s.len == 0 or std.mem.indexOfNone(u8, s, "-:| \t") == null) continue;
        return s;
    }
    return null;
}

/// How many lines past a block's start to look for content. Four covers a fence plus a blank line
/// plus a line of body; more risks reaching into the next block.
const lookahead: usize = 4;

/// Strip leading markdown decoration: blockquote markers and table pipes (repeatedly, since they
/// nest), then one list bullet or ordinal.
fn stripDecoration(text: []const u8) []const u8 {
    var s = text;
    while (s.len > 0 and (s[0] == '>' or s[0] == '|')) {
        s = std.mem.trimStart(u8, s[1..], " \t");
    }
    if (s.len > 1 and (s[0] == '-' or s[0] == '*' or s[0] == '+') and s[1] == ' ') {
        return std.mem.trimStart(u8, s[2..], " \t");
    }
    // `1. `, `12. ` — only when everything before the dot is a digit, so "e.g. foo" is left alone.
    if (std.mem.indexOfScalar(u8, s, '.')) |dot| {
        if (dot > 0 and dot < 4 and dot + 1 < s.len and s[dot + 1] == ' ') {
            const all_digits = for (s[0..dot]) |c| {
                if (!std.ascii.isDigit(c)) break false;
            } else true;
            if (all_digits) return std.mem.trimStart(u8, s[dot + 2 ..], " \t");
        }
    }
    return s;
}

/// One line, at most `max` bytes, never cut mid-codepoint.
///
/// This is a hard ceiling, not the visual fit: the label placer measures the text it is given and
/// appends its own "…" when it does not fit the slot. Without a ceiling a 900-word paragraph is
/// measured in full, every frame the placer runs, to draw forty characters of it.
pub fn clip(text: []const u8, max: usize) []const u8 {
    const nl = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
    var line = std.mem.trim(u8, text[0..nl], " \t\r");
    if (line.len <= max) return line;

    // Back off any continuation byte (0b10xxxxxx) so the cut lands on a codepoint boundary.
    var cut = max;
    while (cut > 0 and (line[cut] & 0xC0) == 0x80) cut -= 1;
    line = line[0..cut];

    // Prefer a nearby word boundary, so the placer's ellipsis reads as a cut sentence rather than
    // a cut word. Only when one is close — backing up half the label to find a space is worse.
    if (std.mem.lastIndexOfScalar(u8, line, ' ')) |sp| {
        if (sp + word_boundary_slack >= line.len) line = line[0..sp];
    }
    return std.mem.trimEnd(u8, line, " \t");
}

/// How far back `clip` will reach for a space rather than cutting a word.
const word_boundary_slack: usize = 8;

// -- tests ------------------------------------------------------------------------

const testing = std.testing;

test "a plain paragraph is its own first line" {
    const lines = [_][]const u8{ "# Title", "Some prose here.", "more" };
    try testing.expectEqualStrings("Some prose here.", blockExcerpt(&lines, 1).?);
}

test "a list item loses its bullet" {
    for ([_][]const u8{ "- one two", "* one two", "+ one two" }) |raw| {
        const lines = [_][]const u8{raw};
        try testing.expectEqualStrings("one two", blockExcerpt(&lines, 0).?);
    }
}

test "an ordered list loses its number" {
    const lines = [_][]const u8{"12. counted"};
    try testing.expectEqualStrings("counted", blockExcerpt(&lines, 0).?);
}

test "an abbreviation is not mistaken for an ordinal" {
    // The dot rule must not fire on prose that happens to contain one.
    const lines = [_][]const u8{"e.g. a sentence"};
    try testing.expectEqualStrings("e.g. a sentence", blockExcerpt(&lines, 0).?);
}

test "a quote loses its markers, however nested" {
    const lines = [_][]const u8{"> > deep quote"};
    try testing.expectEqualStrings("deep quote", blockExcerpt(&lines, 0).?);
}

test "a fence gives up its language" {
    const lines = [_][]const u8{ "```zig", "const x = 1;", "```" };
    try testing.expectEqualStrings("zig", blockExcerpt(&lines, 0).?);
}

test "a bare fence falls through to the first body line" {
    const lines = [_][]const u8{ "```", "const x = 1;", "```" };
    try testing.expectEqualStrings("const x = 1;", blockExcerpt(&lines, 0).?);
}

test "a table skips its separator row" {
    const lines = [_][]const u8{ "| a | b |", "|---|---|", "| 1 | 2 |" };
    // Row one is real content; the separator alone would be meaningless.
    try testing.expectEqualStrings("a | b |", blockExcerpt(&lines, 0).?);
    try testing.expectEqualStrings("1 | 2 |", blockExcerpt(&lines, 1).?);
}

test "leading blank lines are skipped" {
    const lines = [_][]const u8{ "", "  ", "content" };
    try testing.expectEqualStrings("content", blockExcerpt(&lines, 0).?);
}

test "the lookahead does not run past its budget" {
    var lines: [8][]const u8 = undefined;
    for (&lines) |*l| l.* = "";
    lines[6] = "too far";
    try testing.expect(blockExcerpt(&lines, 0) == null);
}

test "a line past the end is not a crash" {
    const lines = [_][]const u8{"only"};
    try testing.expect(blockExcerpt(&lines, 9) == null);
    try testing.expect(blockExcerpt(&.{}, 0) == null);
}

test "clip leaves a short line alone" {
    try testing.expectEqualStrings("short", clip("short", 48));
}

test "clip stops at the first newline" {
    try testing.expectEqualStrings("first", clip("first\nsecond", 48));
}

test "clip prefers a word boundary" {
    //                     0123456789012345
    const s = "alpha beta gamma delta";
    // Cutting at 16 lands inside "delta"; the space at 16 is within slack, so it backs up.
    try testing.expectEqualStrings("alpha beta gamma", clip(s, 17));
}

test "clip does not back up half the label to find a space" {
    // One long word: no boundary within slack, so it cuts where it must.
    const s = "aaaaaaaaaaaaaaaaaaaaaaaaa";
    try testing.expectEqualStrings(s[0..10], clip(s, 10));
}

test "clip never cuts a codepoint in half" {
    // "é" is two bytes; cutting at 5 would land inside it.
    const s = "abcdé fgh";
    const out = clip(s, 5);
    try testing.expect(std.unicode.utf8ValidateSlice(out));
    try testing.expectEqualStrings("abcd", out);
}

test "clip handles a multibyte run at the limit" {
    const s = "ααααααααα"; // 9 × 2 bytes
    const out = clip(s, 7);
    try testing.expect(std.unicode.utf8ValidateSlice(out));
    try testing.expectEqual(@as(usize, 6), out.len);
}
