//! `[[` / `![[` trigger → portable markdown-link completions for `.md` buffers.
//!
//! Typing `[` twice with auto-close already yields `[[|]]`. While the caret sits inside an
//! open `[[…]]`, this provider offers every note in the vault; accepting one **replaces the
//! whole wikilink** with a CommonMark link:
//!
//! ```
//! [[phy|]]  + accept "Physics"  →  [Physics](physics.md)
//! ```
//!
//! An embed (`![[…]]`) offers indexed media instead. `replace_start` begins at `[[`, so the
//! leading `!` is left alone and the insert is still `[alt](path)` — together that yields a
//! CommonMark image:
//!
//! ```
//! ![[dia|]]  + accept "diagram.png"  →  ![diagram.png](../assets/diagram.png)
//! ```
//!
//! Once the caret passes a `#`, the note is already chosen and the offer changes to that note's
//! own headings — the sections of `[[Daphne#…]]`, in document order:
//!
//! ```
//! [[Daphne#hab|]]  + accept "Habitat and Range"  →  [Daphne > Habitat and Range](daphne.md#habitat-and-range)
//! ```
//!
//! Path rules live in `index/relpath.zig`. We write `[text](path)` / `![alt](path)` rather than
//! leaving `[[wikilinks]]` in the buffer so notes stay readable in GitHub / other renderers;
//! fizzy's markdown preview resolves the same relative destinations back into editor opens.
const std = @import("std");
const sdk = @import("fizzy_sdk");

const State = @import("../State.zig");
const query = @import("../index/query.zig");
const Db = @import("../index/Db.zig");
const resolve = @import("../index/resolve.zig");
const relpath = @import("../index/relpath.zig");
const wikilink_context = @import("wikilink_context.zig");

const CompletionItem = sdk.language.CompletionItem;

/// Cap so a huge vault can't flood the dropdown.
const max_items: usize = 64;

/// Arena for the slice returned to the host; reset every call. Text copies what it needs.
var arena_inst: std.heap.ArenaAllocator = undefined;
var arena_ready: bool = false;

fn arena() std.mem.Allocator {
    if (!arena_ready) {
        arena_inst = std.heap.ArenaAllocator.init(sdk.allocator());
        arena_ready = true;
    }
    _ = arena_inst.reset(.retain_capacity);
    return arena_inst.allocator();
}

pub fn completion(
    state: *anyopaque,
    ext: []const u8,
    path: []const u8,
    bytes: []const u8,
    byte_offset: usize,
) ?[]const CompletionItem {
    if (!isMarkdownExt(ext)) return null;
    const st: *State = @ptrCast(@alignCast(state));
    const root = st.vault_root orelse return null;
    const db = if (st.db) |*d| d else return null;

    const ctx = wikilink_context.find(bytes, byte_offset) orelse return null;

    const a = arena();
    var rel_buf: [query.max_rel_path]u8 = undefined;
    const src_rel = query.vaultRelative(root, path, &rel_buf) orelse "";

    if (ctx.heading) |h| {
        // `![[img.png#…]]` anchors nothing; only notes have sections.
        if (ctx.embed) return null;
        return headingItems(st, a, db, ctx, h, src_rel) catch null;
    }

    // Embeds and plain wikilinks never share a candidate list — `[[Target]]` must not land on
    // `Target.png`, and `![[…]]` has nothing useful to say about notes.
    const rows = if (ctx.embed)
        query.completeMedia(db, a, ctx.prefix, max_items) catch return null
    else
        query.complete(db, a, ctx.prefix, max_items) catch return null;
    if (rows.len == 0) return null;

    return buildItems(a, rows, src_rel, ctx) catch null;
}

/// The sections of the note `ctx.prefix` names, for a caret sitting after the `#`.
///
/// The target is resolved through the same candidate list `[[Note]]` resolution uses, so an
/// alias or a relative path in front of the `#` finds the same note the finished link would.
/// Null (rather than an empty list) whenever the target doesn't resolve or has no headings:
/// an unfinished note name in front of the `#` should show nothing, not the wrong note's outline.
fn headingItems(
    st: *State,
    a: std.mem.Allocator,
    db: *Db,
    ctx: wikilink_context.Context,
    heading_prefix: []const u8,
    src_rel: []const u8,
) !?[]const CompletionItem {
    if (ctx.prefix.len == 0) return null;

    const cands = try st.ensureCandidates();
    var path_buf: [resolve.max_path_len]u8 = undefined;
    const match = resolve.resolveIndexed(ctx.prefix, src_rel, cands, st.candidateIndex(), &path_buf) orelse
        return null;
    const target_rel = cands[match.index].path;

    const rows = try query.completeHeadings(db, a, target_rel, heading_prefix, max_items);
    if (rows.len == 0) return null;

    const title_src = query.noteTitle(db, a, target_rel) catch "";
    const title = if (title_src.len > 0) title_src else query.stemOf(target_rel);

    const rel = if (src_rel.len == 0)
        target_rel
    else
        relpath.relative(a, src_rel, target_rel) catch target_rel;

    var out: std.ArrayList(CompletionItem) = .empty;
    for (rows) |r| {
        const insert = try relpath.formatHeadingLink(a, title, r.text, rel);
        // Indented by outline depth, so a list of sibling `###`s under different `##`s doesn't
        // read as one flat run of equals.
        const label = try std.fmt.allocPrint(a, "{s}{s}", .{ indent(r.level), r.text });
        const detail = try std.fmt.allocPrint(a, "{s}:{d}", .{ target_rel, r.line + 1 });
        try out.append(a, .{
            .label = label,
            .insert_text = insert,
            .replace_start = ctx.replace_start,
            .replace_end = ctx.replace_end,
            .kind = .field,
            .detail = detail,
            .documentation = "",
        });
    }
    return try out.toOwnedSlice(a);
}

/// Two spaces per heading level below the first, capped so a `######` can't push its text out of
/// the dropdown.
fn indent(level: u32) []const u8 {
    const pad = "          ";
    const depth = @min(@as(usize, @intCast(level -| 1)), 5);
    return pad[0 .. depth * 2];
}

fn buildItems(
    a: std.mem.Allocator,
    rows: []const query.CompleteRow,
    src_rel: []const u8,
    ctx: wikilink_context.Context,
) ![]const CompletionItem {
    var out: std.ArrayList(CompletionItem) = .empty;

    for (rows) |r| {
        const rel = if (src_rel.len == 0)
            r.path
        else
            relpath.relative(a, src_rel, r.path) catch r.path;

        // Same `[text](path)` for notes and embeds: the `!` sits outside `replace_start`, so
        // an embed accept becomes `![alt](path)` without a separate image formatter.
        const insert = try relpath.formatLink(a, r.title, rel);
        const label = try a.dupe(u8, r.title);
        const detail = try a.dupe(u8, r.path);

        try out.append(a, .{
            .label = label,
            .insert_text = insert,
            .replace_start = ctx.replace_start,
            .replace_end = ctx.replace_end,
            .kind = if (ctx.embed) .other else .module,
            .detail = detail,
            .documentation = "",
        });
    }
    return out.toOwnedSlice(a);
}

fn isMarkdownExt(ext: []const u8) bool {
    return std.ascii.eqlIgnoreCase(ext, ".md") or std.ascii.eqlIgnoreCase(ext, ".markdown");
}
