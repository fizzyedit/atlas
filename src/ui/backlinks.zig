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
const vrun = @import("vrun.zig");

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
    /// Bold ranges over each rendered line, parallel to `ctx` — the stretches that were links
    /// before `renderContext` collapsed them to their names. Empty for a line with no link in it.
    ctx_bold: [][]const Span = &.{},
    /// Height each row's context wraps to, in natural units; parallel to `ctx`. Zero means "not
    /// known" — the context has not been read yet, or the pane width moved and every entry is
    /// due a recount.
    ///
    /// Cached rather than measured each frame because the flatten pass runs every frame and
    /// `Font.textSize` walks the string: recomputing it for every hydrated row would put an
    /// O(rows read so far) text measurement back into the frame, which is the cost the
    /// virtualization exists to remove.
    ctx_h: []f32 = &.{},
    /// Width `ctx_h` was measured at. Wrapping is a function of width, so a resize retires it.
    ctx_w: f32 = 0,
    /// The flattened row list — headers plus the mentions under any group that is not collapsed —
    /// for one particular filter and collapse state.
    ///
    /// Memoized, because building it is the one genuinely O(rows) thing left in the frame: it
    /// walks all 28,754 links comparing paths to find group boundaries, and with a filter active
    /// it fuzzy-scores every one of them. That ran *every frame*, so the pane's cost was a
    /// property of the note's popularity rather than of the viewport — exactly what virtualizing
    /// the drawing was supposed to fix.
    ///
    /// Backed by `rows_arena` rather than `arena`: it is retired on a filter keystroke, which is
    /// far more often than the link list behind it changes.
    rows: []Row = &.{},
    rows_arena: std.heap.ArenaAllocator,
    /// Filter text `rows` was built for, owned. Compared rather than hashed — it is a few dozen
    /// bytes and a compare is cheaper than being wrong.
    rows_filter: []const u8 = "",
    /// `collapse_version` when `rows` was built. Folding a group changes which mentions are in
    /// the list without changing the filter or the links.
    rows_collapse_v: u64 = std.math.maxInt(u64),
    /// False until `rows` describes the current `links`.
    rows_valid: bool = false,
    /// True once `hydrateContexts` has run for this note. Hydration is a property of the *cache*,
    /// not of the filter: it happens at most once per note, so every filter keystroke after the
    /// first scores text that is already in memory.
    ctx_hydrated: bool = false,
    /// False when hydration stopped at `context_search_files` — the filter searched the link text
    /// of every mention but the surrounding line of only some of them, and the pane says so
    /// rather than quietly returning a short list.
    ctx_complete: bool = true,
    /// One-entry file cache. Backlinks are ordered by source path, so consecutive rows are usually
    /// the same file and this turns a screenful of rows into one read.
    last_path: []const u8 = "",
    last_bytes: []const u8 = "",

    fn init(gpa: std.mem.Allocator) Cache {
        return .{
            .arena = std.heap.ArenaAllocator.init(gpa),
            .rows_arena = std.heap.ArenaAllocator.init(gpa),
        };
    }

    fn deinit(self: *Cache) void {
        self.rows_arena.deinit();
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
// nothing.
//
// Heights are *not* uniform: a mention wraps its context to `row_max_lines`, so it can be taller
// than the header above it. `vrun` windows a run of arbitrary heights from cumulative offsets,
// which is exact — the measured-pitch version this replaced had to guess a row height from the
// rows it had drawn, and the guess fed back into the content height the scrollbar was reading.

/// Height drawn beyond each edge of the viewport, in natural units.
///
/// Height rather than a row count, because rows are no longer all the same height. It buys a row
/// the frame it needs to settle — a context line is read from disk the first time its row is
/// drawn, and the row is one line tall until that read lands — so it is generous on purpose.
const virtual_overscan: f32 = 240;

/// How many distinct source files the filter will read to search mentions by their surrounding
/// line.
///
/// Reading files to answer a filter sounds expensive and mostly is not: backlinks are ordered by
/// source path, so this is one read per *note that links here*, not per mention, and the result is
/// kept for as long as the pane is describing the same note — so it is a one-off cost on the first
/// keystroke, not a cost per keystroke.
///
/// The budget is where it is because of the shape of a real vault. On Simple English Wikipedia's
/// 210,026 linked notes the median has **3** distinct sources and the 99th percentile has 193;
/// 99.7% are at or under this number, so almost every note gets a complete context search, and the
/// handful that do not are hubs where no one is looking for one particular sentence anyway. The
/// alternative — indexing every link's context — was measured at ~900 MB, over 90% of the database.
const context_search_files: usize = 512;

/// Most lines a mention's context may wrap to. Past this it is clipped: a backlink row is a
/// glimpse of where the link sits, and a row tall enough to hold a whole paragraph pushes every
/// other result off the pane.
const row_max_lines: usize = 2;

/// Vertical chrome `rowShell` adds around a row's content: its padding (6 above, 6 below) and its
/// margin (1 and 1). Named because the run's arithmetic has to agree with the widget exactly —
/// a row that draws taller than the offsets said would walk the scrollbar.
const row_chrome_h: f32 = 14;

/// Widest a row's text may ask to be, in natural units. Zero until the first frame measures it.
///
/// Without a cap, a row is as wide as its longest line of source context — `LabelWidget`'s min
/// size is the full text width, and `ButtonWidget.minSizeForChild` maxes it into the row. That
/// min width propagates out to the explorer's scroll, which grows a horizontal range to fit it,
/// which widens the box, which widens the row: the pane scrolled arbitrarily far right, and every
/// row's screen rect ran out under the editor.
///
/// Derived from the scroll viewport rather than from the box's own content rect: the box width is
/// downstream of this very feedback loop, so measuring it would preserve the loop it is meant to
/// break. It is also what `mentionLines` wraps against, so the two always agree.
var row_text_max_w: f32 = 0;

/// Row chrome between the pane's content edge and the text: the shell's margin and padding, plus
/// the deepest indent a row uses. Approximate on purpose — the cap only has to stop the min-size
/// feedback, and the text wraps and clips to its real rect regardless.
const row_chrome_w: f32 = 34;

/// Groups the reader has collapsed, keyed by a hash of the source path.
///
/// Hashed rather than stored: the paths live in the cache arena, which is reset whenever the
/// active note or the index generation changes, so keeping the strings would mean owning copies
/// of them for the life of the pane.
var collapsed: std.AutoHashMapUnmanaged(u64, void) = .empty;

/// Bumped whenever `collapsed` changes, so the memoized row list can tell that folding a group
/// invalidated it without having to compare the set.
var collapse_version: u64 = 0;

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

/// The height one line of a row's content occupies, in natural units. `rowContentHeightFor` stacks
/// it; `rowShell` pins whatever comes out.
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
/// A pin is honest here rather than a workaround: the run's offsets are computed *before* any row
/// is built, so a row's height is already a decision this file has made by the time the widget
/// exists. Letting the widget re-decide it could only disagree with the spacers around it.
///
/// Sized to the tallest thing a row legitimately holds: the caret slot in a header
/// (`treeRowGlyphSize`, a *rounded* value, so it is a hair taller than the text it sits beside) or
/// one line of the row font. Taking the max means neither is squeezed, and it is applied as both
/// the minimum *and* the maximum, so no child can push a row past it — see `rowShell`.
fn rowContentHeight() f32 {
    return @max(rowFont().textHeight(), core.dvui.treeRowGlyphSize().h);
}

fn rowFont() dvui.Font {
    return dvui.Font.theme(.body).larger(-1);
}

/// Content height of a row holding `lines` lines. One line keeps the single-line row exactly as
/// tall as it has always been — the caret glyph, not the font, sets that floor — and each line
/// after it adds one line height.
fn rowContentHeightFor(lines: usize) f32 {
    const base = rowContentHeight();
    if (lines <= 1) return base;
    return base + rowFont().lineHeight() * @as(f32, @floatFromInt(lines - 1));
}

/// Total height of a row, chrome included. The one definition the run's offsets and the widget's
/// pinned size both come from, so the two cannot disagree.
fn rowHeight(c: *Cache, row: Row) f32 {
    return switch (row) {
        // A group header is its note's name: one line, always.
        .header => rowContentHeightFor(1) + row_chrome_h,
        .mention => |li| rowContentHeightFor(mentionLines(c, li)) + row_chrome_h,
    };
}

/// How many lines mention `li`'s context wraps to, memoized in `Cache.ctx_h`.
///
/// A row whose context has not been read yet counts as one line. That is an underestimate for
/// some of them, and it is the right one: the read happens when the row is first *drawn*, so
/// every correction lands on a row at or below the viewport and pushes content that is already
/// off-screen further down. Guessing high would do the opposite — shrink the run as you scroll,
/// which moves what you are reading.
fn mentionLines(c: *Cache, li: usize) usize {
    if (li >= c.ctx_h.len) return 1;
    const avail = row_text_max_w;
    if (avail <= 0) return 1;
    if (c.ctx_h[li] > 0) return @intFromFloat(c.ctx_h[li]);

    const text = c.ctx[li] orelse return 1;
    if (text.len == 0) return 1;
    const width = rowFont().textSize(text).w;
    const est: f32 = @ceil(width / avail);
    const lines = @min(row_max_lines, @max(@as(usize, 1), @as(usize, @intFromFloat(@max(1, est)))));
    c.ctx_h[li] = @floatFromInt(lines);
    return lines;
}

/// Drop every memoized line count. Wrapping is a function of width, so a pane resize retires all
/// of them at once rather than leaving rows sized for a width that no longer exists.
fn invalidateLineCounts(c: *Cache) void {
    if (c.ctx_w == row_text_max_w) return;
    c.ctx_w = row_text_max_w;
    @memset(c.ctx_h, 0);
}

/// Rows carry no padding of their own — `rowShell` owns all of it. Every label in a row is built
/// with this, because dvui's label default is `Rect.all(6)` and a row that inherits it is 12
/// taller than the pinned height, which is precisely the two-height bug described on `rowShell`.
const row_label_padding: dvui.Rect = .all(0);

/// Set `row_text_max_w` from the scroll viewport this pane draws into. See that variable.
fn measureRowTextWidth(box: *dvui.BoxWidget) void {
    const scale = box.data().rectScale().s;
    if (scale <= 0) return;
    // `clipGet` is the explorer scroll's viewport in physical pixels — the one width in this
    // layout that our own content cannot inflate.
    const viewport_w = dvui.clipGet().w / scale;
    if (viewport_w <= 0) return;
    row_text_max_w = @max(0, @min(box.data().contentRect().w, viewport_w) - row_chrome_w);
}

/// Cap for a row label, or null before the first measurement (in which case the label is left
/// unconstrained for one frame rather than pinned to zero width).
fn rowTextMax(reserve: f32) ?dvui.Options.MaxSize {
    if (row_text_max_w <= 0) return null;
    return .width(@max(0, row_text_max_w - reserve));
}

/// The hover/press surface every row sits in, so header and mention rows cannot drift apart.
///
/// One shell, one set of paddings, both kinds — but no longer one *height*. Rows used to be
/// uniform because the run's window was a division by a measured pitch; `vrun` windows by
/// cumulative offsets instead, so a row is as tall as `height` says and the caller is free to
/// make a wrapped mention taller than a header. What must still agree is the arithmetic: the
/// height passed here is the same number the run's offsets were built from, and `row_chrome_h`
/// is the constant that keeps the two spellings of it in step.
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
fn rowShell(bw: *dvui.ButtonWidget, id_extra: usize, indent: f32, height: f32) void {
    const theme = dvui.themeGet();
    // Pinned, not merely floored: the run's offsets were computed from this number, so a child
    // that measured taller would draw past where the next row was accounted for.
    const content_h = @max(0, height - row_chrome_h);
    bw.init(@src(), .{}, .{
        .id_extra = id_extra,
        .expand = .horizontal,
        .min_size_content = .{ .w = 0, .h = content_h },
        .max_size_content = .height(content_h),
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
    collapse_version +%= 1;
    row_text_max_w = 0;
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
    measureRowTextWidth(box);

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
    invalidateLineCounts(c);

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

    const rows = ensureRows(c, &q, filter_text, st.vault_root.?);

    if (rows.len == 0) {
        dvui.labelNoFmt(@src(), "No matches.", .{}, .{
            .font = dvui.Font.theme(.body).larger(-1),
            .color_text = dvui.themeGet().color(.content, .text).opacity(0.5),
        });
        drawContextLimitNote(c);
        drawFooter(st);
        return;
    }
    drawContextLimitNote(c);

    // Every row's height, then the run that windows them. `vrun` is exact where the old measured
    // pitch was a guess: the run's total height is arithmetic over the same numbers the rows are
    // pinned to, so it cannot drift under the scrollbar reading it.
    //
    // Recomputed per frame, unlike the row list: it is `rows.len` float adds with no comparisons
    // and no allocation beyond a bump, and it has to see the line counts that rows hydrated on
    // the way past. If it ever shows up in a profile the fix is incremental offsets, not another
    // cache.
    const arena = dvui.currentWindow().arena();
    const heights = arena.alloc(f32, rows.len) catch return;
    const offsets = arena.alloc(f32, rows.len + 1) catch return;
    for (rows, heights) |row, *h| h.* = rowHeight(c, row);
    const run = vrun.accumulate(offsets, heights);

    // Anchors the top of the run in screen space, after the header/filter chrome above, so their
    // height never has to be predicted.
    const anchor = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 0, .h = 0 } });
    const anchor_rs = anchor.rectScale();
    const scale = if (anchor_rs.s > 0) anchor_rs.s else 1;

    // `clipGet` is the explorer scroll's viewport, in physical pixels; the run speaks natural
    // units, because that is what font metrics and `min_size_content` speak.
    const clip = dvui.clipGet();
    const w = run.window(
        (clip.y - anchor_rs.r.y) / scale,
        clip.h / scale,
        virtual_overscan,
    );

    // Both spacers draw unconditionally, even at zero height: a widget that comes and goes as you
    // scroll churns ids for no benefit.
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 0, .h = w.lead } });

    for (rows[w.lo..w.hi], heights[w.lo..w.hi]) |row, h| {
        switch (row) {
            .header => |g| drawGroupHeader(c.links[g.first], g.len, rowId(row), h, &q),
            .mention => |li| drawMentionRow(c.links[li], li, rowId(row), h, &q),
        }
    }

    // Sized from what the rows *actually* occupied, not from `w.tail` alone, so the run is exactly
    // `run.total()` tall whatever happened above. That invariant is the fix for a scroll area that
    // fights the user: dvui drops a min size as soon as a widget goes undrawn, so a row scrolled
    // back in can lay out short for a frame — with a fixed trailing spacer the content height
    // collapsed by a screenful, which re-clamped the offset, which moved the window again.
    const marker = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 0, .h = 0 } });
    const consumed = (marker.rectScale().r.y - anchor_rs.r.y) / scale;
    _ = dvui.spacer(@src(), .{ .min_size_content = .{
        .w = 0,
        .h = @max(0, run.total() - consumed),
    } });

    drawFooter(st);
}

/// The flattened row list for the current filter and collapse state, rebuilding it only when one
/// of those actually moved. See `Cache.rows`.
///
/// `q` and `filter_text` are the same filter twice: the parsed form to score with, and the raw
/// text to compare against what the cached list was built for.
fn ensureRows(c: *Cache, q: *const fuzzy.Query, filter_text: []const u8, root: []const u8) []const Row {
    if (c.rows_valid and
        c.rows_collapse_v == collapse_version and
        std.mem.eql(u8, c.rows_filter, filter_text)) return c.rows;

    // Only once someone is actually filtering. Reading a note's sources the moment its backlinks
    // are shown would put file I/O on every note you open, to answer a question nobody asked.
    if (!q.isEmpty()) hydrateContexts(c, root);

    _ = c.rows_arena.reset(.retain_capacity);
    const a = c.rows_arena.allocator();
    c.rows = &.{};
    c.rows_valid = false;
    c.rows_filter = a.dupe(u8, filter_text) catch "";
    c.rows_collapse_v = collapse_version;

    var out: std.ArrayList(Row) = .empty;
    var i: usize = 0;
    while (i < c.links.len) {
        const path = c.links[i].path;
        var j = i + 1;
        while (j < c.links.len and std.mem.eql(u8, c.links[j].path, path)) : (j += 1) {}
        if (groupMatches(q, c, i, j)) {
            out.append(a, .{ .header = .{ .first = i, .len = j - i } }) catch {};
            if (!collapsed.contains(pathKey(path))) {
                for (i..j) |k| out.append(a, .{ .mention = k }) catch {};
            }
        }
        i = j;
    }
    c.rows = out.toOwnedSlice(a) catch &.{};
    c.rows_valid = true;
    return c.rows;
}

/// Read the source line behind every mention, so the filter can search them.
///
/// Costs one file read per *distinct source note*, not per mention — `contextFor` keeps the last
/// file it read and the links are ordered by source path, so a note that links here forty times
/// is opened once. Stops at `context_search_files` and records that it did.
fn hydrateContexts(c: *Cache, root: []const u8) void {
    if (c.ctx_hydrated) return;
    c.ctx_hydrated = true;
    c.ctx_complete = true;

    var files: usize = 0;
    var last: []const u8 = "";
    for (c.links, 0..) |bl, i| {
        // A dirty (unsaved-buffer) row already carries its line, and the file on disk would be the
        // stale version of it — the whole point of the overlay.
        if (bl.context.len > 0) continue;
        if (last.len == 0 or !std.mem.eql(u8, last, bl.path)) {
            if (files >= context_search_files) {
                c.ctx_complete = false;
                return;
            }
            files += 1;
            last = bl.path;
        }
        _ = contextFor(c, root, i);
    }
}

/// Does any row in this source-note group survive the filter?
///
/// Every field here is one the *index* carries, so a row's match is the same whether or not it
/// has ever been on screen. `Backlink.context` is deliberately not among them: it is read from
/// disk the first time a row is drawn, so filtering on it would quietly return a different set
/// depending on how far the reader had scrolled — and reading 28,754 source files to make it
/// consistent is not a filter, it is a grep.
///
/// The path is scored `plain = false` so zf weights its basename; the rest are bare names and
/// link text with no `/`-structure to weight.
/// Say so when the filter could not read every mention's line. Silence here would look like a
/// short result rather than a truncated search — see `context_search_files`.
fn drawContextLimitNote(c: *const Cache) void {
    if (c.ctx_complete or !c.ctx_hydrated) return;
    var buf: [96]u8 = undefined;
    const msg = std.fmt.bufPrint(
        &buf,
        "Searched link text everywhere; line text in the first {d} notes.",
        .{context_search_files},
    ) catch return;
    dvui.labelNoFmt(@src(), msg, .{}, .{
        .font = dvui.Font.theme(.body).larger(-2),
        .color_text = dvui.themeGet().color(.content, .text).opacity(0.45),
    });
}

fn groupMatches(q: *const fuzzy.Query, c: *const Cache, first: usize, last: usize) bool {
    if (q.isEmpty()) return true;
    const path = c.links[first].path;
    // The path is scored `plain = false` so zf weights its basename; everything below is a bare
    // name or link text with no `/`-structure to weight.
    if (fuzzy.score(path, q, .{ .plain = false }) != null) return true;
    for (first..last) |k| {
        const bl = c.links[k];
        // The source note's title, then the link as it was written and the alias it was written
        // under — "which mention was it" is answered by the link text far more often than by the
        // name of the note the link happens to live in.
        if (fuzzy.score(bl.title, q, .{}) != null) return true;
        if (fuzzy.score(bl.raw, q, .{}) != null) return true;
        if (fuzzy.score(bl.alias, q, .{}) != null) return true;
        // And the line the link sits in, which is what the row actually shows — a filter that
        // highlights a word in the context but refuses to match it is worse than one that does
        // neither. `hydrateContexts` is what makes this answerable without having drawn the row.
        const ctx = mentionContext(c, k);
        if (ctx.len > 0 and fuzzy.score(ctx, q, .{}) != null) return true;
    }
    return false;
}

/// The source line behind mention `i`, or empty when it has not been read. Dirty rows carry their
/// own; everything else comes from `hydrateContexts` or from having been drawn.
fn mentionContext(c: *const Cache, i: usize) []const u8 {
    const bl = c.links[i];
    if (bl.context.len > 0) return bl.context;
    if (i >= c.ctx.len) return "";
    return c.ctx[i] orelse "";
}

// ---- link rendering --------------------------------------------------------------------------
//
// A backlink row shows the line the link sits in, and that line is *markdown source*: half of it
// is often brackets, a path, and an extension. `[Daphne](Daphne.md)` is nine characters of note
// name inside twenty of syntax, and a row two of those wide reads as punctuation rather than as
// prose. So the line is rewritten the way the note itself would render it — the link collapses to
// the text a reader sees — and the stretches that came from a link are drawn bold, which is the
// only cue left that they were links at all.

/// A byte range of a rendered context line that came from a link, drawn bold.
const Span = struct { start: usize, end: usize };

/// One raw source line, rewritten for display, plus the bold ranges over the *rewritten* string.
const Rendered = struct {
    text: []const u8,
    bold: []const Span = &.{},
};

/// What one link contributes to a rendered line, and where the syntax it came from ends.
const Link = struct {
    text: []const u8,
    end: usize,
};

/// Strip a wikilink target down to the name a reader would recognise: drop any `#heading` or
/// `^block` suffix, then take the basename and lose the extension, so `notes/Daphne.md#Family`
/// shows as `Daphne`.
fn wikiTargetName(target: []const u8) []const u8 {
    var t = target;
    if (std.mem.indexOfAny(u8, t, "#^")) |cut| t = t[0..cut];
    t = std.mem.trim(u8, t, " \t");
    if (t.len == 0) return t;
    return displayTitle(t);
}

/// Parse the link opening at `raw[at]`, or null when what follows is not one — an unmatched `[`
/// in prose is far more common than a broken link, and either way the bracket is then emitted
/// literally and scanning resumes one byte along.
fn parseLink(raw: []const u8, at: usize) ?Link {
    if (at >= raw.len or raw[at] != '[') return null;

    // `[[Target|alias]]` — the alias is what the source note displays, so it wins.
    if (at + 1 < raw.len and raw[at + 1] == '[') {
        const close = std.mem.indexOfPos(u8, raw, at + 2, "]]") orelse return null;
        const inner = raw[at + 2 .. close];
        const end = close + 2;
        if (std.mem.indexOfScalar(u8, inner, '|')) |bar| {
            const alias = std.mem.trim(u8, inner[bar + 1 ..], " \t");
            if (alias.len > 0) return .{ .text = alias, .end = end };
            return .{ .text = wikiTargetName(inner[0..bar]), .end = end };
        }
        return .{ .text = wikiTargetName(inner), .end = end };
    }

    // `[label](target)`. The label may not contain a nested `]`, which is the same restriction
    // the scanner indexes under.
    const rb = std.mem.indexOfScalarPos(u8, raw, at + 1, ']') orelse return null;
    if (rb + 1 >= raw.len or raw[rb + 1] != '(') return null;
    const rp = std.mem.indexOfScalarPos(u8, raw, rb + 2, ')') orelse return null;
    const label = std.mem.trim(u8, raw[at + 1 .. rb], " \t");
    // An empty label leaves nothing to show, so fall back to the target the way the wikilink
    // branch does — `[](Daphne.md)` still reads as Daphne.
    const text = if (label.len > 0) label else wikiTargetName(raw[rb + 2 .. rp]);
    return .{ .text = text, .end = rp + 1 };
}

/// Rewrite one raw source line into what the row shows. The returned text is either `raw` itself
/// (when there is no link in it, which is the common case and allocates nothing) or a fresh copy
/// in `a`.
fn renderContext(a: std.mem.Allocator, raw: []const u8) !Rendered {
    if (std.mem.indexOfScalar(u8, raw, '[') == null) return .{ .text = raw };

    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(a, raw.len);
    var bold: std.ArrayList(Span) = .empty;

    var i: usize = 0;
    while (i < raw.len) {
        // `![[embed]]` and `![alt](img)`: the bang belongs to the syntax, not to the text.
        const bang = raw[i] == '!' and i + 1 < raw.len and raw[i + 1] == '[';
        const open = if (bang) i + 1 else i;
        if (raw[open] == '[') {
            if (parseLink(raw, open)) |link| {
                const start = out.items.len;
                try out.appendSlice(a, link.text);
                if (out.items.len > start) try bold.append(a, .{ .start = start, .end = out.items.len });
                i = link.end;
                continue;
            }
        }
        try out.append(a, raw[i]);
        i += 1;
    }

    return .{
        .text = try out.toOwnedSlice(a),
        .bold = try bold.toOwnedSlice(a),
    };
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
        // Rendered once, here, rather than at draw time: `mentionLines` wraps against this string
        // and the filter searches it, so the row's height and its text have to be the same text.
        const r = renderContext(a, trimmed) catch Rendered{ .text = trimmed };
        c.ctx[i] = r.text;
        c.ctx_bold[i] = r.bold;
        return r.text;
    }
    return "";
}

/// One group header: the source note, how many times it links here, and a caret.
///
/// Returns the row's top edge in physical screen coordinates, which is what the run measures its
/// pitch from. Same vertical metrics as `drawMentionRow` — the virtualized run assumes a uniform
/// row height, and a header that was a few pixels taller would make the scrollbar drift.
fn drawGroupHeader(bl: query.Backlink, count: usize, id_extra: usize, height: f32, q: *const fuzzy.Query) void {
    const st = runtime.state();
    const key = pathKey(bl.path);
    const is_collapsed = collapsed.contains(key);

    var row: dvui.ButtonWidget = undefined;
    rowShell(&row, id_extra, 4, height);
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

    // A text layout, not a label, so the bytes the filter matched can be tinted — and built by
    // hand for the same reason as the mention row's: `dvui.textLayout` (and `labelHighlighted`
    // through it) calls `processEvents`, and a text layout that takes the press for selection is
    // a header that stops folding its group.
    const title_color = dvui.themeGet().color(.content, .text).opacity(0.85);
    var label: dvui.TextLayoutWidget = undefined;
    label.init(@src(), .{
        .break_lines = false,
        .process_events_in_deinit = false,
    }, .{
        .gravity_y = 0.5,
        .padding = row_label_padding,
        .background = false,
        .font = rowFont().withWeight(.bold),
        // The caret sits to the left of this label inside the row, so it is not text width.
        .max_size_content = rowTextMax(core.dvui.treeRowGlyphSize().w),
        .id_extra = id_extra,
    });
    // Scored `plain = false` to match `groupMatches`, which weights the path's basename — and the
    // title *is* the basename for a note with no front-matter title.
    core.dvui.addHighlightedText(&label, bl.title, q, false, title_color);
    var count_buf: [24]u8 = undefined;
    const suffix = std.fmt.bufPrint(&count_buf, "  ({d})", .{count}) catch "";
    label.addText(suffix, .{ .color_text = title_color });
    label.deinit();

    for (dvui.events()) |*e| {
        if (e.handled) continue;
        switch (e.evt) {
            .mouse => |me| {
                if (me.action != .press) continue;
                if (!me.button.pointer() and me.button != .middle) continue;
                // Against the row's rect *intersected with the clip*, not the rect alone. A
                // row wider or taller than the viewport still has a screen rect that runs on
                // past it, and hit-testing the bare rect let a click in the editor land on a
                // backlink and navigate away — the pane accepting events it never drew.
                if (!rs.intersect(dvui.clipGet()).contains(me.p)) continue;
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
                    collapse_version +%= 1;
                    dvui.refresh(null, @src(), row.data().id);
                } else {
                    const open_side = me.button == .middle or me.mod.matchBind("ctrl/cmd");
                    revealBacklink(st, bl, open_side);
                }
            },
            else => {},
        }
    }
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

/// One run of a context line: `core.dvui.addHighlightedText` with the font carried per run, so a
/// link's name can be bold while the prose around it is not. The helper takes only a colour — the
/// font there comes from the widget — and a run of a different weight is the whole point here.
///
/// Filter tinting is therefore scored per run rather than across the line: a query that straddles
/// the boundary between prose and a link name highlights the halves it matches in each, which is
/// what a reader sees anyway.
fn addRun(
    tl: *dvui.TextLayoutWidget,
    s: []const u8,
    q: *const fuzzy.Query,
    plain_color: dvui.Color,
    font: dvui.Font,
) void {
    if (s.len == 0) return;
    const plain: dvui.Options = .{ .font = font, .color_text = plain_color };
    if (q.isEmpty()) return tl.addText(s, plain);

    var buf: [fuzzy.highlight_buf_len]usize = undefined;
    const hits = fuzzy.highlight(s, q, &buf, .{ .plain = true });
    if (hits.len == 0) return tl.addText(s, plain);

    const matched: dvui.Options = .{ .font = font, .color_text = dvui.themeGet().color(.highlight, .fill) };
    var i: usize = 0;
    var h: usize = 0;
    while (i < s.len) {
        if (h < hits.len and hits[h] == i) {
            // Consume the whole contiguous run of matched bytes in one addText.
            const start = i;
            while (h < hits.len and hits[h] == i) : (h += 1) i += 1;
            tl.addText(s[start..i], matched);
        } else {
            const start = i;
            i = if (h < hits.len) hits[h] else s.len;
            tl.addText(s[start..i], plain);
        }
    }
}

fn drawMentionRow(bl: query.Backlink, index: usize, id_extra: usize, height: f32, q: *const fuzzy.Query) void {
    const st = runtime.state();
    const root = st.vault_root orelse return;

    var row: dvui.ButtonWidget = undefined;
    rowShell(&row, id_extra, 18, height);
    defer row.deinit();
    const rs = row.data().borderRectScale().r;

    // A dirty (unsaved-buffer) backlink arrives with its context already attached; a stored one
    // does not, and gets read from the file the first time this row is drawn.
    //
    // The stored one was rendered when it was read, and its bold ranges came back with it. The
    // dirty one has never been through `renderContext`, so it goes through it here, into the
    // frame arena — one line's work for the handful of rows an unsaved buffer contributes.
    const rendered: Rendered = if (bl.context.len > 0)
        renderContext(dvui.currentWindow().arena(), bl.context) catch .{ .text = bl.context }
    else if (cache) |*c| .{
        .text = contextFor(c, root, index),
        .bold = if (index < c.ctx_bold.len) c.ctx_bold[index] else &.{},
    } else .{ .text = "" };
    const ctx = if (rendered.text.len > 0) rendered.text else "(empty line)";
    const bold = if (rendered.text.len > 0) rendered.bold else &.{};
    // A text layout rather than a label, because a line of prose from the middle of a note is
    // however long it is and a single clipped line is not a useful glimpse of it. `break_lines`
    // wraps it; the shell's pinned height clips it at `row_max_lines`.
    //
    // Built directly rather than through `dvui.textLayout`, and with `process_events_in_deinit`
    // off, so it handles **no** events at all: the helper calls `processEvents` for text selection
    // and touch editing, and a text layout that matches the press first is a row that stops
    // opening its note. The row's own scan below is the only thing here that reads a click.
    var text: dvui.TextLayoutWidget = undefined;
    text.init(@src(), .{
        .break_lines = true,
        .process_events_in_deinit = false,
    }, .{
        .expand = .horizontal,
        // The widget's defaults are `padding = all(6)` and `background = true`; both would fight
        // the shell that owns this row's padding and its hover surface.
        .padding = row_label_padding,
        .background = false,
        // The row's base font, which `addRun` overrides only for a link's name. It is the same
        // `rowFont` that `mentionLines` wrapped against, or the measured height and the drawn
        // height would be for two different fonts — the bold runs are a handful of words on a
        // line and are deliberately not modelled in that estimate.
        .font = rowFont(),
        .max_size_content = rowTextMax(0),
        .id_extra = id_extra,
    });
    // Tinted even though the filter does not *search* the context (see `groupMatches`): when the
    // query does happen to appear in the line, showing where is the whole point of the row.
    const plain_color = dvui.themeGet().color(.content, .text).opacity(0.75);
    const bold_font = rowFont().withWeight(.bold);
    var at: usize = 0;
    for (bold) |span| {
        if (span.start > at) addRun(&text, ctx[at..span.start], q, plain_color, rowFont());
        // Full strength as well as bold: the name of a note is the part of the line worth
        // finding, and it is the only thing left standing in for the link syntax that was here.
        addRun(&text, ctx[span.start..span.end], q, dvui.themeGet().color(.content, .text), bold_font);
        at = span.end;
    }
    if (at < ctx.len) addRun(&text, ctx[at..], q, plain_color, rowFont());
    text.deinit();

    for (dvui.events()) |*e| {
        if (e.handled) continue;
        switch (e.evt) {
            .mouse => |me| {
                if (me.action != .press) continue;
                if (!me.button.pointer() and me.button != .middle) continue;
                // Against the row's rect *intersected with the clip*, not the rect alone. A
                // row wider or taller than the viewport still has a screen rect that runs on
                // past it, and hit-testing the bare rect let a click in the editor land on a
                // backlink and navigate away — the pane accepting events it never drew.
                if (!rs.intersect(dvui.clipGet()).contains(me.p)) continue;
                e.handled = true;
                const open_side = me.button == .middle or me.mod.matchBind("ctrl/cmd");
                revealBacklink(st, bl, open_side);
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
    // The rows point into `links`, which is about to be freed underneath them.
    c.rows_valid = false;
    c.rows = &.{};
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
    c.ctx_bold = try arena.alloc([]const Span, c.links.len);
    @memset(c.ctx_bold, &.{});
    c.ctx_h = try arena.alloc(f32, c.links.len);
    @memset(c.ctx_h, 0);
    c.ctx_w = 0;
    c.ctx_hydrated = false;
    c.ctx_complete = true;
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

test "renderContext collapses links to their names" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // No link: the line is handed back untouched, with nothing to embolden.
    {
        const r = try renderContext(a, "plain prose, no links");
        try t.expectEqualStrings("plain prose, no links", r.text);
        try t.expectEqual(@as(usize, 0), r.bold.len);
    }
    // Markdown link: the label survives, the target and the brackets do not.
    {
        const r = try renderContext(a, "met [Daphne](Daphne.md) at noon");
        try t.expectEqualStrings("met Daphne at noon", r.text);
        try t.expectEqual(@as(usize, 1), r.bold.len);
        try t.expectEqualStrings("Daphne", r.text[r.bold[0].start..r.bold[0].end]);
    }
    // Wikilinks: the alias when there is one, otherwise the target's bare name.
    {
        const r = try renderContext(a, "[[notes/Daphne.md#Family|her]] and [[notes/Ivo.md]]");
        try t.expectEqualStrings("her and Ivo", r.text);
        try t.expectEqual(@as(usize, 2), r.bold.len);
        try t.expectEqualStrings("her", r.text[r.bold[0].start..r.bold[0].end]);
        try t.expectEqualStrings("Ivo", r.text[r.bold[1].start..r.bold[1].end]);
    }
    // Embeds drop their bang; an empty label falls back to the target.
    {
        const r = try renderContext(a, "![[Daphne]] ![alt](x.png) [](Ivo.md)");
        try t.expectEqualStrings("Daphne alt Ivo", r.text);
        try t.expectEqual(@as(usize, 3), r.bold.len);
    }
    // Brackets that open nothing are prose and stay put.
    {
        const r = try renderContext(a, "a [bracket] and [half](oops");
        try t.expectEqualStrings("a [bracket] and [half](oops", r.text);
        try t.expectEqual(@as(usize, 0), r.bold.len);
    }
}
