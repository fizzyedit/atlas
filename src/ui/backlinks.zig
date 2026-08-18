//! The Backlinks sidebar view.
//!
//! Shows every note that links to the active document, grouped by source path. Click a row to
//! reveal that location; middle / ctrl-cmd opens to the side — same convention as markdown
//! wikilink clicks. Re-queries only when the active path or index generation changes.
const std = @import("std");
const dvui = @import("dvui");
const core = @import("core");
const icons = @import("icons");
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

    /// Source lines, fetched the first time a row is *drawn* and kept for as long as this cache
    /// describes the same note. `null` means "not looked at yet"; a fetch that fails stores `""`
    /// so it is not retried every frame.
    ///
    /// The index used to carry this text for every link in the vault. On a 283,878-note wiki that
    /// was ~900 MB — over 90% of the database, and more than twice the markdown it came from — to
    /// avoid a file read that only happens when someone actually looks at a backlink.
    ctx: []?[]const u8 = &.{},
    /// One-entry file cache. Backlinks are ordered by source path, so consecutive rows are usually
    /// the same file and this turns a screenful of rows into one read.
    last_path: []const u8 = "",
    last_bytes: []const u8 = "",

    fn init(gpa: std.mem.Allocator) Cache {
        return .{ .arena = std.heap.ArenaAllocator.init(gpa) };
    }

    fn deinit(self: *Cache) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

var cache: ?Cache = null;

// ---- row virtualization ----------------------------------------------------------------------
//
// Every row here is a real widget stack — a box, a label, a hover rect, an event scan — so the
// row *count* is a per-frame cost whether or not a row is on screen. A note linked from three
// thousand others was three thousand widget stacks a frame, which is the same wall the file tree
// hit and is fixed the same way: draw the window the viewport can see, and stand in for the rest
// with a leading and trailing spacer so the scrollbar and offset land where they otherwise would.
//
// The unit is the **flattened** row list, not the group. Backlinks are grouped by source note, so
// a note linked once from each of three thousand others produces three thousand *groups* — the
// headers are the row count, and virtualizing only the mentions inside each group would save
// nothing. Header and mention rows are built to the same vertical metrics so the run is uniform.

/// Below this many rows, virtualizing costs more than it saves.
const virtual_min_rows: usize = 64;

/// Rows drawn beyond each edge of the viewport. Not just polish: dvui drops a widget's min size
/// the moment it goes undrawn, so a row scrolled back into view reports zero height on its first
/// frame. Drawing it early means it has settled by the time it matters.
const virtual_overscan: f32 = 16;

/// Rows drawn on the first frame purely to measure the pitch, before which there is no way to
/// know where the viewport falls. One frame, then it self-corrects.
const virtual_probe_rows: usize = 32;

/// Measured spacing between consecutive rows, in physical pixels. Module-level for the same
/// reason the file tree keeps its own there: every row is built identically, so one measurement
/// serves all of them, and it survives the pane not being drawn for a frame.
var row_pitch_px: f32 = 0;

/// Groups the reader has collapsed, keyed by a hash of the source path.
///
/// Hashed rather than stored: the paths live in the cache arena, which is reset whenever the
/// active note or the index generation changes, so keeping the strings would mean owning copies
/// of them for the life of the pane.
var collapsed: std.AutoHashMapUnmanaged(u64, void) = .empty;

fn pathKey(path: []const u8) u64 {
    return std.hash.Wyhash.hash(0, path);
}

/// Corner rounding on a row's hover surface.
///
/// The store card's own shell uses 8, on a card several times this tall. Scaled down to a sidebar
/// row so the proportion reads the same rather than the number — at 8 a 24px row is halfway to a
/// pill. Everything else about the surface is the card's: transparent at rest, `control.fill` at
/// half opacity on hover, nine tenths on press.
const row_corner_radius: f32 = 6;

/// The hover/press surface every row sits in, so header and mention rows cannot drift apart.
///
/// Uniform metrics are not only cosmetic here — the virtualized run assumes one row height, and a
/// header a few pixels taller than a mention would make the scrollbar drift over a long list. One
/// shell, one set of paddings, both kinds.
///
/// A `ButtonWidget` rather than a hand-rolled `contains(mouse_pt)` fill, matching `PluginStore`'s
/// card: it brings the rounded surface, a press state, and `processHover` — which highlights
/// *without* consuming the click, leaving the row's own event scan to decide what a middle click
/// or a ctrl/cmd click means.
///
/// Takes the widget by pointer and never returns one. `init` registers `&bw` as the current
/// parent, so a version that built the widget here and returned it by value handed dvui the
/// address of a stack frame that was already gone — "widget is not closed within its parent",
/// then a segfault. The caller owns the storage; this only fills it in.
/// The height every row's content is pinned to, in natural units — one line of the row font, which
/// is what a settled row occupies anyway.
///
/// Pinned rather than left to the label, because a widget id dvui has not seen before has no
/// remembered min size and lays out **zero-height on its first frame**. Wheel scrolling hides that:
/// it advances a few rows at a time and `virtual_overscan` draws them a screenful early, so they
/// have settled by the time they are visible. Dragging the scrollbar does not — the drag sets the
/// offset absolutely from the mouse every frame, so a drag of any speed lands on rows that are all
/// new, all at once, and keeps doing it for as long as the drag lasts. The whole window then
/// collapsed into a pile of overlapping zero-height rows: the text smeared together and looked
/// disabled, and every row's click rect was degenerate, so nothing under the cursor answered.
/// Releasing fixed it a frame later, which is why only dragging showed it.
///
/// A pin is honest here rather than a workaround: the run already *requires* uniform rows — the
/// pitch, the spacers and the offset-to-row mapping all assume it (see `rowShell`'s doc comment) —
/// so stating that height up front is what the rest of the file already believes.
///
/// Sized to the tallest thing a row legitimately holds: the caret slot in a header
/// (`treeRowGlyphSize`, a *rounded* value, so it is a hair taller than the text it sits beside) or
/// one line of the row font. Taking the max means neither is squeezed, and it is applied as both
/// the minimum *and* the maximum, so no child can push a row past it — see `rowShell`.
fn rowContentHeight() f32 {
    return @max(dvui.Font.theme(.body).larger(-1).textHeight(), core.dvui.treeRowGlyphSize().h);
}

/// Rows carry no padding of their own — `rowShell` owns all of it. Every label in a row is built
/// with this, because dvui's label default is `Rect.all(6)` and a row that inherits it is 12
/// taller than the pinned height, which is precisely the two-height bug described on `rowShell`.
const row_label_padding: dvui.Rect = .all(0);

fn rowShell(bw: *dvui.ButtonWidget, id_extra: usize, indent: f32) void {
    const theme = dvui.themeGet();
    bw.init(@src(), .{}, .{
        .id_extra = id_extra,
        .expand = .horizontal,
        .min_size_content = .{ .w = 0, .h = rowContentHeight() },
        .margin = .{ .x = indent, .y = 1, .w = 4, .h = 1 },
        // All of a row's vertical padding lives here, on the shell, and nowhere else — the labels
        // inside are built with `row_label_padding` (zero). `LabelWidget.defaults.padding` is
        // `Rect.all(6)`, so a label left at its defaults added 12 to the row on top of this, and
        // `ButtonWidget.minSizeForChild` maxes each child's padded size into the row. That is what
        // made a row two different heights: 11.15 of content on the frame an id was new (only the
        // pin, children not yet measured) and 23.15 once dvui remembered the padded label. Since
        // the pitch is measured from drawn rows, the run's total height then flipped between
        // 345k and 561k physical pixels every frame — the scrollbar's thumb was sized and placed
        // against a virtual size that changed under it, `lo` jumped between two disjoint parts of
        // the list, and the offset walked on its own after the drag ended.
        .padding = .{ .x = 4, .y = 6, .w = 4, .h = 6 },
        .corners = dvui.CornerRect.all(row_corner_radius),
        .background = true,
        .color_fill = .transparent,
        .color_fill_hover = theme.color(.control, .fill).opacity(0.5),
        .color_fill_press = theme.color(.control, .fill).opacity(0.9),
    });
    bw.processHover();
    bw.drawBackground();
}

/// One line of the flattened list.
const Row = union(enum) {
    /// Index into `c.links` of the group's first mention, plus how many it has.
    header: struct { first: usize, len: usize },
    /// Index into `c.links`.
    mention: usize,
};

/// A row's `id_extra` — keyed to the link it shows, never to where it currently sits on screen.
///
/// The visible-row index looks like the obvious key and is the wrong one: `lo` moves with the
/// scroll, so scrolling by a single row renumbered every drawn row, handing each one the identity
/// (and dvui's cached min size, hover and press state) of the row that was in that slot last frame.
/// Typing in the filter re-flattened the list and renumbered everything again. The file tree keys
/// its virtualized rows by entry for the same reason.
///
/// Headers and mentions have to share one numbering: `rowShell` builds both from a single `@src()`
/// under a single parent, so their ids are distinguished by nothing but this value, and a header
/// for the group starting at link 5 would otherwise collide with the mention row for link 5. Even
/// for headers, odd for mentions.
fn rowId(row: Row) usize {
    return switch (row) {
        .header => |g| g.first * 2,
        .mention => |li| li * 2 + 1,
    };
}

/// Release everything this view holds across frames.
///
/// Called from the plugin's `deinit`, the same as the graph panel's: the store can unload and
/// reload a plugin in a running editor, so module-level state that outlives a frame has to have
/// somewhere to be given back. The cache owns an arena and the collapse set owns its table.
pub fn shutdown() void {
    if (cache) |*c| c.deinit();
    cache = null;
    collapsed.deinit(sdk.allocator());
    collapsed = .empty;
    row_pitch_px = 0;
}

fn ensureCache(gpa: std.mem.Allocator) *Cache {
    if (cache == null) cache = Cache.init(gpa);
    return &cache.?;
}

pub fn draw(_: ?*anyopaque) anyerror!void {
    const st = runtime.state();
    const gpa = sdk.allocator();
    const c = ensureCache(gpa);

    // No scroll area of our own. The explorer already wraps every sidebar view's `draw` in one
    // (`Explorer.drawPane`), and a second one nested inside it is what produced two vertical bars,
    // a jittering scrollbar, and rows that ignored clicks: with the default `.auto` vertical mode
    // an inner scrollArea reports its whole content height as its min size, so the explorer's bar
    // sized itself to the full run while the inner bar scrolled it — and each frame's content
    // height fed back into the next frame's layout. The file tree, which this pane's row
    // virtualization is modelled on, draws straight into the explorer's scroll for the same
    // reason. `dvui.clipGet()` below reads that scroll's viewport, so the windowing is unchanged.
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

    var active_rel_buf: [query.max_rel_path]u8 = undefined;
    const active_rel = activeNoteRel(st.vault_root.?, &active_rel_buf) orelse {
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

    // Flatten to the rows this frame would draw, before drawing any of them.
    //
    // Cheap — it is arithmetic over the link list, which the old loop walked anyway — and it is
    // what makes the run virtualizable: the window can only be chosen once the total row count
    // and each row's identity are known.
    const arena = dvui.currentWindow().arena();
    var visible: std.ArrayList(Row) = .empty;
    {
        var i: usize = 0;
        while (i < c.links.len) {
            const path = c.links[i].path;
            var j = i + 1;
            while (j < c.links.len and std.mem.eql(u8, c.links[j].path, path)) : (j += 1) {}
            if (groupMatches(&q, path, c.links[i..j])) {
                visible.append(arena, .{ .header = .{ .first = i, .len = j - i } }) catch {};
                if (!collapsed.contains(pathKey(path))) {
                    for (i..j) |k| visible.append(arena, .{ .mention = k }) catch {};
                }
            }
            i = j;
        }
    }

    const rows = visible.items;
    if (rows.len == 0) {
        dvui.labelNoFmt(@src(), "No matches.", .{}, .{
            .font = dvui.Font.theme(.body).larger(-1),
            .color_text = dvui.themeGet().color(.content, .text).opacity(0.5),
        });
        drawFooter(st);
        return;
    }

    // Anchors the top of the run in screen space, after the header/filter chrome above, so their
    // height never has to be predicted.
    const anchor = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 0, .h = 0 } });
    const anchor_rs = anchor.rectScale();
    const scale = if (anchor_rs.s > 0) anchor_rs.s else 1;
    const pitch: f32 = row_pitch_px;
    const count_f: f32 = @floatFromInt(rows.len);

    var lo: usize = 0;
    var hi: usize = rows.len;
    if (rows.len > virtual_min_rows) {
        const clip = dvui.clipGet();
        if (pitch > 0.5 and clip.h > 0) {
            const limit: f32 = count_f;
            const top = (clip.y - anchor_rs.r.y) / pitch - virtual_overscan;
            lo = @intFromFloat(std.math.clamp(@floor(top), 0, limit));
            const span: usize = @intFromFloat(std.math.clamp(
                @ceil(clip.h / pitch + 2 * virtual_overscan),
                1,
                limit,
            ));
            if (lo + span > rows.len) lo = rows.len -| span;
            hi = @min(rows.len, lo + span);
        } else {
            // No pitch yet — draw a bounded probe to measure one.
            hi = @min(rows.len, virtual_probe_rows);
        }
    }

    // Both spacers draw unconditionally, even at zero height: a widget that comes and goes as you
    // scroll churns ids for no benefit.
    const run_px = count_f * pitch;
    const block_px = @as(f32, @floatFromInt(hi - lo)) * pitch;
    const lead_px = @max(0, @min(@as(f32, @floatFromInt(lo)) * pitch, run_px - block_px));
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 0, .h = lead_px / scale } });

    // Pitch is the *largest* gap between consecutive drawn rows, never their average: a row that
    // just scrolled in has no min size yet and lays out zero-height for one frame, so an average
    // is biased low — and a pitch that shrinks shrinks the content height, which is the feedback
    // the trailing spacer exists to prevent.
    var widest_gap: f32 = 0;
    var prev_y: f32 = 0;
    var drawn: usize = 0;
    for (rows[lo..hi]) |row| {
        const y = switch (row) {
            .header => |g| drawGroupHeader(c.links[g.first], g.len, rowId(row)),
            .mention => |li| drawMentionRow(c.links[li], li, rowId(row)),
        };
        if (drawn > 0) widest_gap = @max(widest_gap, y - prev_y);
        prev_y = y;
        drawn += 1;
    }
    if (widest_gap > 0.5) row_pitch_px = widest_gap;

    // Sized from what the rows *actually* occupied, not from `(rows.len - hi) * pitch`, so the run
    // is exactly `rows.len * pitch` tall whatever happened above. That invariant is the fix for a
    // scroll area that fights the user: dvui drops a min size as soon as a widget goes undrawn, so
    // rows scrolled back in are zero-height for a frame — with a fixed trailing spacer the content
    // height collapsed by a screenful, which re-clamped the offset, which moved the window again.
    const marker = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 0, .h = 0 } });
    const consumed_px = marker.rectScale().r.y - anchor_rs.r.y;
    _ = dvui.spacer(@src(), .{ .min_size_content = .{
        .w = 0,
        .h = @max(0, run_px - consumed_px) / scale,
    } });


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

/// The source line behind one backlink, read on demand and memoized.
fn contextFor(c: *Cache, root: []const u8, i: usize) []const u8 {
    if (i >= c.ctx.len) return "";
    if (c.ctx[i]) |have| return have;

    const a = c.arena.allocator();
    const bl = c.links[i];
    c.ctx[i] = ""; // pessimistic: any failure below leaves this and is not retried

    if (!std.mem.eql(u8, c.last_path, bl.path)) {
        const abs = std.fs.path.join(a, &.{ root, bl.path }) catch return "";
        const bytes = std.Io.Dir.cwd().readFileAlloc(
            dvui.io,
            abs,
            a,
            .limited(Indexer.max_file_bytes),
        ) catch return "";
        c.last_path = a.dupe(u8, bl.path) catch return "";
        c.last_bytes = bytes;
    }

    var line_no: u32 = 0;
    var it = std.mem.splitScalar(u8, c.last_bytes, '\n');
    while (it.next()) |line| : (line_no += 1) {
        if (line_no != bl.line) continue;
        const trimmed = std.mem.trim(u8, line, " \t\r");
        c.ctx[i] = trimmed;
        return trimmed;
    }
    return "";
}

/// One group header: the source note, how many times it links here, and a caret.
///
/// Returns the row's top edge in physical screen coordinates, which is what the run measures its
/// pitch from. Same vertical metrics as `drawMentionRow` — the virtualized run assumes a uniform
/// row height, and a header that was a few pixels taller would make the scrollbar drift.
fn drawGroupHeader(bl: query.Backlink, count: usize, id_extra: usize) f32 {
    const st = runtime.state();
    const key = pathKey(bl.path);
    const is_collapsed = collapsed.contains(key);

    var row: dvui.ButtonWidget = undefined;
    rowShell(&row, id_extra, 4);
    defer row.deinit();
    const rs = row.data().borderRectScale().r;

    var content = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .id_extra = id_extra,
    });
    defer content.deinit();

    // The tree caret, drawn the way every other tree row in fizzy draws it: a `treeRowGlyph` slot
    // sized from the body font, holding an entypo arrow.
    //
    // Not a text triangle. `\u{25b8}`/`\u{25be}` are not in the theme font, so they rendered as
    // tofu — and picking a glyph the font happens to have would still drift from the file tree's
    // caret the moment either changed. This is the same call the workbench makes.
    const caret_color = dvui.themeGet().color(.content, .text).opacity(0.55);
    const caret = core.dvui.treeRowGlyph(@src(), .{ .id_extra = id_extra, .gravity_y = 0.5 });
    const caret_rs = caret.data().borderRectScale().r;
    _ = dvui.icon(
        @src(),
        "BacklinkGroupCaret",
        if (is_collapsed) icons.tvg.entypo.@"right-open" else icons.tvg.entypo.@"down-open",
        .{ .fill_color = caret_color, .stroke_color = caret_color },
        core.dvui.treeRowIconOptions(.{ .id_extra = id_extra }),
    );
    caret.deinit();

    var label_buf: [256]u8 = undefined;
    const header = std.fmt.bufPrint(&label_buf, "{s}  ({d})", .{ bl.title, count }) catch bl.title;
    dvui.labelNoFmt(@src(), header, .{}, .{
        .font = dvui.Font.theme(.body).larger(-1).withWeight(.bold),
        .color_text = dvui.themeGet().color(.content, .text).opacity(0.85),
        .gravity_y = 0.5,
        .padding = row_label_padding,
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
                // The caret folds the group; anywhere else opens the note it names. Clicking the
                // *name* of a note should go to that note — the header was previously inert, so
                // the obvious target did nothing and only the context lines beneath it worked.
                if (caret_rs.contains(me.p)) {
                    if (is_collapsed) {
                        _ = collapsed.remove(key);
                    } else {
                        collapsed.put(sdk.allocator(), key, {}) catch {};
                    }
                    dvui.refresh(null, @src(), row.data().id);
                } else {
                    const open_side = me.button == .middle or me.mod.matchBind("ctrl/cmd");
                    revealBacklink(st, bl, open_side);
                }
            },
            else => {},
        }
    }
    return rs.y;
}

/// Open the note a backlink comes *from*, scrolled to the line the link is on.
fn revealBacklink(st: anytype, bl: query.Backlink, open_side: bool) void {
    const root = st.vault_root orelse return;
    const abs = std.fs.path.join(dvui.currentWindow().arena(), &.{ root, bl.path }) catch return;
    const wb = sdk.host().getServiceTyped(sdk.services.workbench.Api) orelse return;
    _ = wb.revealPosition(abs, bl.line, bl.col, open_side) catch |err| {
        dvui.log.err("atlas: revealPosition {s}: {any}", .{ abs, err });
    };
}

fn drawMentionRow(bl: query.Backlink, index: usize, id_extra: usize) f32 {
    const st = runtime.state();
    const root = st.vault_root orelse return 0;

    var row: dvui.ButtonWidget = undefined;
    rowShell(&row, id_extra, 18);
    defer row.deinit();
    const rs = row.data().borderRectScale().r;

    // A dirty (unsaved-buffer) backlink arrives with its context already attached; a stored one
    // does not, and gets read from the file the first time this row is drawn.
    const from_cache = if (bl.context.len > 0) bl.context else blk: {
        if (cache == null) break :blk "";
        break :blk contextFor(&cache.?, root, index);
    };
    const ctx = if (from_cache.len > 0) from_cache else "(empty line)";
    dvui.labelNoFmt(@src(), ctx, .{}, .{
        .font = dvui.Font.theme(.body).larger(-1),
        .color_text = dvui.themeGet().color(.content, .text).opacity(0.75),
        .gravity_y = 0.5,
        .padding = row_label_padding,
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
                revealBacklink(st, bl, open_side);
            },
            else => {},
        }
    }
    return rs.y;
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
        try resetContext(c, arena);
        return;
    }
    var all: std.ArrayList(query.Backlink) = .empty;
    try all.appendSlice(arena, db_links);
    try all.appendSlice(arena, dirty_extra);
    c.links = try all.toOwnedSlice(arena);
    try resetContext(c, arena);
}

/// Clear the lazily-read source lines. The arena backing them was just reset with the cache, so
/// every stored slice is dangling until this runs.
fn resetContext(c: *Cache, arena: std.mem.Allocator) !void {
    c.ctx = try arena.alloc(?[]const u8, c.links.len);
    @memset(c.ctx, null);
    c.last_path = "";
    c.last_bytes = "";
}

/// `buf` holds the returned slice — `vaultRelative` normalizes separators, so the result is a
/// copy rather than a view into the document's own path.
fn activeNoteRel(vault: []const u8, buf: []u8) ?[]const u8 {
    const doc = sdk.host().activeDoc() orelse return null;
    const path = doc.owner.documentPath(doc);
    if (path.len == 0) return null;
    if (!query.isMarkdownPath(path)) return null;
    return query.vaultRelative(vault, path, buf);
}

fn displayTitle(rel: []const u8) []const u8 {
    const base = std.fs.path.basenamePosix(rel);
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
