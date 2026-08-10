//! The Backlinks sidebar view.
//!
//! Shows every note that links to the active document, grouped by source path. Click a row to
//! reveal that location; middle / ctrl-cmd opens to the side — same convention as markdown
//! wikilink clicks. Re-queries only when the active path or index generation changes.
const std = @import("std");
const dvui = @import("dvui");
const core = @import("core");
const sdk = @import("fizzy_sdk");
const runtime = @import("../runtime.zig");
const Indexer = @import("../index/Indexer.zig");
const query = @import("../index/query.zig");

const fuzzy = core.fuzzy;

pub const view_id = "atlas.backlinks";

const Cache = struct {
    path: []u8 = &.{},
    gen: u64 = std.math.maxInt(u64),
    dirty_n: usize = std.math.maxInt(usize),
    links: []query.Backlink = &.{},
    arena: std.heap.ArenaAllocator,

    fn init(gpa: std.mem.Allocator) Cache {
        return .{ .arena = std.heap.ArenaAllocator.init(gpa) };
    }

    fn deinit(self: *Cache) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

var cache: ?Cache = null;

fn ensureCache(gpa: std.mem.Allocator) *Cache {
    if (cache == null) cache = Cache.init(gpa);
    return &cache.?;
}

pub fn draw(_: ?*anyopaque) anyerror!void {
    const st = runtime.state();
    const gpa = sdk.allocator();
    const c = ensureCache(gpa);

    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .background = false });
    defer scroll.deinit();

    var box = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .padding = .{ .x = 8, .y = 8, .w = 8, .h = 8 },
    });
    defer box.deinit();

    if (st.vault_root == null or st.db == null) {
        dvui.labelNoFmt(@src(), "Open a folder to index your notes.", .{}, .{
            .font = dvui.Font.theme(.body).larger(-1),
            .color_text = dvui.themeGet().color(.content, .text).opacity(0.6),
        });
        return;
    }

    const active_rel = activeNoteRel(st.vault_root.?) orelse {
        dvui.labelNoFmt(@src(), "Open a markdown note to see its backlinks.", .{}, .{
            .font = dvui.Font.theme(.body).larger(-1),
            .color_text = dvui.themeGet().color(.content, .text).opacity(0.6),
        });
        drawFooter(st);
        return;
    };

    try refreshCache(c, st, active_rel);

    dvui.labelNoFmt(@src(), displayTitle(active_rel), .{}, .{
        .font = dvui.Font.theme(.body).larger(-1).withWeight(.bold),
        .color_text = dvui.themeGet().color(.content, .text),
    });

    var count_buf: [64]u8 = undefined;
    const count_label = std.fmt.bufPrint(&count_buf, "{d} linked mention{s}", .{
        c.links.len,
        if (c.links.len == 1) "" else "s",
    }) catch "";
    dvui.labelNoFmt(@src(), count_label, .{}, .{
        .font = dvui.Font.theme(.body).larger(-1),
        .color_text = dvui.themeGet().color(.content, .text).opacity(0.55),
    });

    const filter_entry = dvui.textEntry(@src(), .{
        .placeholder = "Filter backlinks…",
    }, .{
        .expand = .horizontal,
        .margin = .{ .y = 6, .h = 4 },
    });
    const filter_text = filter_entry.getText();
    filter_entry.deinit();
    const q = fuzzy.Query.init(filter_text);

    if (c.links.len == 0) {
        dvui.labelNoFmt(@src(), "No notes link here yet.", .{}, .{
            .font = dvui.Font.theme(.body).larger(-1),
            .color_text = dvui.themeGet().color(.content, .text).opacity(0.5),
        });
        drawFooter(st);
        return;
    }

    var tree = core.dvui.TreeWidget.tree(@src(), .{}, .{
        .expand = .horizontal,
        .background = false,
        .margin = .{ .y = 4 },
    });
    defer tree.deinit();

    var i: usize = 0;
    var group_id: usize = 1;
    while (i < c.links.len) {
        const path = c.links[i].path;
        var j = i + 1;
        while (j < c.links.len and std.mem.eql(u8, c.links[j].path, path)) : (j += 1) {}
        const group = c.links[i..j];

        if (!groupMatches(&q, path, group)) {
            i = j;
            group_id += 1;
            continue;
        }

        var branch = tree.branch(@src(), .{
            .expanded = true,
            .branch_id = group_id,
        }, .{
            .expand = .horizontal,
            .id_extra = group_id,
        });
        defer branch.deinit();

        {
            var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .expand = .horizontal,
                .margin = .{ .y = 2 },
                .id_extra = group_id,
            });
            defer row.deinit();

            var label_buf: [256]u8 = undefined;
            const header = std.fmt.bufPrint(&label_buf, "{s}  ({d})", .{
                group[0].title,
                group.len,
            }) catch group[0].title;
            dvui.labelNoFmt(@src(), header, .{}, .{
                .font = dvui.Font.theme(.body).larger(-1).withWeight(.bold),
                .color_text = dvui.themeGet().color(.content, .text).opacity(0.85),
                .gravity_y = 0.5,
                .id_extra = group_id,
            });
        }

        if (branch.expanded) {
            for (group, 0..) |bl, k| {
                if (!q.isEmpty()) {
                    const path_hit = fuzzy.score(path, &q, .{ .plain = false }) != null;
                    if (!path_hit and fuzzy.score(bl.context, &q, .{}) == null) continue;
                }
                drawMentionRow(bl, group_id * 1000 + k + 1);
            }
        }

        i = j;
        group_id += 1;
    }

    drawFooter(st);
}

fn groupMatches(q: *const fuzzy.Query, path: []const u8, group: []const query.Backlink) bool {
    if (q.isEmpty()) return true;
    if (fuzzy.score(path, q, .{ .plain = false }) != null) return true;
    for (group) |bl| {
        if (fuzzy.score(bl.context, q, .{}) != null) return true;
    }
    return false;
}

fn drawMentionRow(bl: query.Backlink, id_extra: usize) void {
    const st = runtime.state();
    const root = st.vault_root orelse return;

    var row = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .margin = .{ .x = 12, .y = 1 },
        .padding = .{ .x = 4, .y = 3, .w = 4, .h = 3 },
        .background = true,
        .color_fill = .transparent,
        .id_extra = id_extra,
    });
    defer row.deinit();

    const rs = row.data().borderRectScale().r;
    if (rs.contains(dvui.currentWindow().mouse_pt)) {
        row.data().options.color_fill = dvui.themeGet().color(.control, .fill).opacity(0.55);
    }

    const ctx = if (bl.context.len > 0) bl.context else "(empty line)";
    dvui.labelNoFmt(@src(), ctx, .{}, .{
        .font = dvui.Font.theme(.body).larger(-1),
        .color_text = dvui.themeGet().color(.content, .text).opacity(0.75),
        .id_extra = id_extra,
    });

    for (dvui.events()) |*e| {
        if (e.handled) continue;
        switch (e.evt) {
            .mouse => |me| {
                if (me.action != .press) continue;
                if (!me.button.pointer() and me.button != .middle) continue;
                if (!rs.contains(me.p)) continue;
                e.handled = true;
                const open_side = me.button == .middle or me.mod.matchBind("ctrl/cmd");
                const abs = std.fs.path.join(dvui.currentWindow().arena(), &.{ root, bl.path }) catch break;
                const wb = sdk.host().getServiceTyped(sdk.services.workbench.Api) orelse break;
                _ = wb.revealPosition(abs, bl.line, bl.col, open_side) catch |err| {
                    dvui.log.err("atlas: revealPosition {s}: {any}", .{ abs, err });
                };
            },
            else => {},
        }
    }
}

fn refreshCache(c: *Cache, st: anytype, active_rel: []const u8) !void {
    const gen = st.generation.load(.acquire);
    // Also rebuild when dirty overlays change — keyed loosely by dirty count so typing into
    // another note can surface a new backlink without waiting for save.
    const dirty_n = st.dirty.count();
    const path_same = std.mem.eql(u8, c.path, active_rel);
    if (c.gen == gen and path_same and c.dirty_n == dirty_n) return;

    _ = c.arena.reset(.free_all);
    const arena = c.arena.allocator();
    c.path = try arena.dupe(u8, active_rel);
    c.gen = gen;
    c.dirty_n = dirty_n;

    const db_links = try query.backlinksFor(&st.db.?, arena, active_rel);
    const dirty_extra = try st.dirtyBacklinks(arena, active_rel, db_links);
    if (dirty_extra.len == 0) {
        c.links = db_links;
        return;
    }
    var all: std.ArrayList(query.Backlink) = .empty;
    try all.appendSlice(arena, db_links);
    try all.appendSlice(arena, dirty_extra);
    c.links = try all.toOwnedSlice(arena);
}

fn activeNoteRel(vault: []const u8) ?[]const u8 {
    const doc = sdk.host().activeDoc() orelse return null;
    const path = doc.owner.documentPath(doc);
    if (path.len == 0) return null;
    if (!query.isMarkdownPath(path)) return null;
    return query.vaultRelative(vault, path);
}

fn displayTitle(rel: []const u8) []const u8 {
    const base = if (std.mem.lastIndexOfScalar(u8, rel, '/')) |s| rel[s + 1 ..] else rel;
    if (std.ascii.endsWithIgnoreCase(base, ".md")) return base[0 .. base.len - 3];
    if (std.ascii.endsWithIgnoreCase(base, ".markdown")) return base[0 .. base.len - 9];
    return base;
}

fn drawFooter(st: anytype) void {
    const busy = st.busy.load(.acquire);
    const snap: Indexer.Counts = if (st.indexer_ready) st.indexer.counts() else .{};
    var buf: [160]u8 = undefined;
    const text = if (busy)
        (std.fmt.bufPrint(&buf, "Indexing… {d} notes · {d} links", .{ snap.note_count, snap.link_count }) catch "Indexing…")
    else
        (std.fmt.bufPrint(&buf, "{d} notes · {d} links · {d} phantoms", .{
            snap.note_count,
            snap.link_count,
            snap.phantom_count,
        }) catch "");

    dvui.labelNoFmt(@src(), text, .{}, .{
        .font = dvui.Font.theme(.body).larger(-2),
        .color_text = dvui.themeGet().color(.content, .text).opacity(0.4),
        .margin = .{ .y = 10 },
    });
}
