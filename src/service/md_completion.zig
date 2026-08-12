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
//! Path rules live in `index/relpath.zig`. We write `[text](path)` / `![alt](path)` rather than
//! leaving `[[wikilinks]]` in the buffer so notes stay readable in GitHub / other renderers;
//! fizzy's markdown preview resolves the same relative destinations back into editor opens.
const std = @import("std");
const sdk = @import("fizzy_sdk");

const State = @import("../State.zig");
const query = @import("../index/query.zig");
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
    // Embeds and plain wikilinks never share a candidate list — `[[Target]]` must not land on
    // `Target.png`, and `![[…]]` has nothing useful to say about notes.
    const rows = if (ctx.embed)
        query.completeMedia(db, a, ctx.prefix, max_items) catch return null
    else
        query.complete(db, a, ctx.prefix, max_items) catch return null;
    if (rows.len == 0) return null;

    const src_rel = query.vaultRelative(root, path) orelse "";
    return buildItems(a, rows, src_rel, ctx) catch null;
}

fn buildItems(
    a: std.mem.Allocator,
    rows: []const query.CompleteRow,
    src_rel: []const u8,
    ctx: wikilink_context.Context,
) ![]const CompletionItem {
    var out: std.ArrayList(CompletionItem) = .empty;
    var rel_buf: [512]u8 = undefined;

    for (rows) |r| {
        const rel = if (src_rel.len == 0)
            r.path
        else
            relpath.relative(src_rel, r.path, &rel_buf) catch r.path;

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
