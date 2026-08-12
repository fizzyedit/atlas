//! The one place a `world_mod.World`'s living marks and lifted links get turned into pixels.
//!
//! The vault overview draws a `World`. The note interior (a separate, larger change) is being
//! rewritten to reuse the same `fold`/`containment`/`World` machinery for a note's own content,
//! which means it will draw a `World` too — its own, nested one. If that meant writing a second
//! copy of this drawing logic, the two would eventually diverge, silently: that exact class of
//! bug (a second view quietly missing something the first one does) was the single biggest
//! source of regressions while containment was landing, every time it inherited a mechanism a
//! sibling code path never filled in. This file exists so there is structurally only one
//! implementation, called from every view that draws a `World`.
//!
//! Deliberately runtime-dispatched through `DrawCtx`'s function pointers, not a `comptime`
//! generic. A generic body gets re-instantiated per calling type — which is a second copy with
//! extra steps, since two instantiations can drift from each other exactly like two hand-written
//! copies can. One function, called with different closures, is the only form that actually
//! guarantees one code path.

const std = @import("std");
const dvui = @import("dvui");
const galaxy = @import("galaxy.zig");
const world_mod = @import("world.zig");

/// Lead beyond the viewport for the link clip, so a clipped stub still begins inside the panel
/// rather than exactly on its edge.
const link_clip_pad: f32 = 64;
const Camera = @import("Camera.zig");

pub const MarkStyle = struct {
    fill: dvui.Color,
    border: dvui.Color,
    r_px: f32,
    is_note: bool,
};

pub const DrawCtx = struct {
    ctx: *anyopaque,
    /// Local (`Field`-space) -> vault-world. Identity for the plain overview; a nested caller
    /// (the interior) closes over its own `nest`/`parent` and calls `interior.toWorld` here.
    /// Applied to `Mark.wx/wy` *before* the caller's camera transform — never the other way
    /// round, or a nested cloud's marks land at the wrong screen position entirely.
    toWorld: *const fn (ctx: *anyopaque, local: dvui.Point) dvui.Point,
    style: *const fn (ctx: *anyopaque, w: *const world_mod.World, m: world_mod.Mark, holds_open: bool) MarkStyle,
    holdsOpen: *const fn (ctx: *anyopaque, w: *const world_mod.World, m: world_mod.Mark) bool,
};

pub const DrawStats = struct { notes_drawn: u32 = 0, clusters_drawn: u32 = 0, links_drawn: u32 = 0 };

/// Ambient-web opacity, as a function of how many lines the web is drawing at once.
///
/// A fixed opacity cannot serve both ends of the quality slider. Two hundred lines at the old flat
/// 0.22 are a legible web; ten thousand at the same value are a grey wash that says only
/// "everything touches everything" — and raising the quality slider is precisely how you ask for
/// ten thousand. So the ink thins as the web thickens: the whole vault's connections can appear at
/// once without drowning the marks, and as you zoom in and the viewport culls most of them away,
/// the survivors darken until an individual link reads as a line you can follow.
///
/// Keyed on the *drawn* count — what survives the viewport — and not on the lifted count, which
/// fills its budget at every zoom (a 300k sweep reports the full budget on every row) and so pinned
/// the web at its faintest no matter how far in you were. Zoom alone is the wrong variable too: the
/// same zoom is a wash on a hub vault and nearly empty on a sparse one, and the number that
/// actually decides legibility is lines per screen.
///
/// The bounds are chosen so the shipped default lands where it already was: at `graph_detail`'s
/// 360 the web is 900 lines, which comes out at ~0.26 against the 0.22 this replaced.
const ambient_alpha_lit: f32 = 0.40;
const ambient_alpha_wash: f32 = 0.08;
/// At or below this many drawn lines the web is at full strength; at or above the second, at its
/// faintest. Interpolated in log space, since what reads as "twice as busy" is a doubling.
const ambient_lines_lit: f32 = 200;
const ambient_lines_wash: f32 = 6000;

fn ambientAlpha(drawn: usize) f32 {
    const n: f32 = @floatFromInt(@max(1, drawn));
    const t = std.math.clamp(
        @log2(n / ambient_lines_lit) / @log2(ambient_lines_wash / ambient_lines_lit),
        0,
        1,
    );
    return std.math.lerp(ambient_alpha_lit, ambient_alpha_wash, t);
}

/// Scale a colour's alpha by `t`, for the per-link crossfade.
fn withAlpha(c: dvui.Color, t: f32) dvui.Color {
    var out = c;
    out.a = @intFromFloat(@as(f32, @floatFromInt(c.a)) * std.math.clamp(t, 0, 1));
    return out;
}

/// dvui-typed wrapper over `world_mod.clipSegment`. Null when the segment misses `r` entirely.
///
/// Every link goes through this, not just the focused note's. Two reasons. A link whose far end is
/// a cell hundreds of thousands of world units away used to reach the batch at full length, which
/// is wasted fill and a precision hazard at large zoom. And a link with one endpoint off screen
/// should read as *going somewhere* rather than as absent — clipping turns it into a stub running
/// off the bezel, which is the honest picture: the note connects to something you would have to
/// travel to see.
fn clipToRect(
    a: dvui.Point.Physical,
    b: dvui.Point.Physical,
    r: dvui.Rect.Physical,
) ?struct { a: dvui.Point.Physical, b: dvui.Point.Physical } {
    const c = world_mod.clipSegment(a.x, a.y, b.x, b.y, r.x, r.y, r.w, r.h) orelse return null;
    return .{ .a = .{ .x = c[0], .y = c[1] }, .b = .{ .x = c[2], .y = c[3] } };
}

/// Whether `cell` should light its links up as an open note's own.
///
/// Only ever true for a **leaf**, and that restriction is the point. `holdsOpen` walks a cell's
/// whole note range, so on a coalesced mass it answers "does this mass contain an open note" —
/// and treating that as "these are the note's links" paints every link the mass touches, which at
/// a far zoom is a starburst across the panel with almost nothing to do with the document. On a
/// leaf the range is one note, so the question and the answer finally mean the same thing.
///
/// The focused note is handled separately and better, at leaf precision, by `World.focus_links`.
/// This clause is what still lights up a *second* open tab that happens to be drawn as itself.
fn endpointLit(
    w: *const world_mod.World,
    holds_open: std.AutoHashMapUnmanaged(u32, void),
    cell: u32,
) bool {
    return cell < w.lad.cells.len and
        w.lad.cells[cell].child_count == 0 and
        holds_open.contains(cell);
}

/// TEMPORARY: is anything other than the focus pass drawing the focused note's links, and at what
/// extension does the focus pass start? Logs only when the answer changes.
const debug_dupe = true;
var dbg_sig: u64 = std.math.maxInt(u64);

pub fn draw(
    w: *const world_mod.World,
    cam: *const Camera,
    dens: *galaxy.Density,
    fade: f32,
    dctx: DrawCtx,
) DrawStats {
    if (fade <= 0.004) return .{};
    const arena = dvui.currentWindow().arena();
    const theme = dvui.themeGet();
    const border_rest = theme.color(.window, .text);

    const toScreen = struct {
        fn f(c: *const Camera, tw: DrawCtx, m: world_mod.Mark) dvui.Point.Physical {
            return c.worldToScreen(tw.toWorld(tw.ctx, .{ .x = m.wx, .y = m.wy }));
        }
    }.f;

    var stats: DrawStats = .{};

    // Links first so the web passes under the marks rather than over them.
    if (w.links.items.len > 0) {
        // One pass over the marks instead of a scan per endpoint: the web is budgeted at 900 and
        // the marks at a few hundred, so the naive version was ~250k comparisons a frame.
        var pos = std.AutoHashMapUnmanaged(u32, dvui.Point.Physical){};
        defer pos.deinit(arena);
        pos.ensureTotalCapacity(arena, @intCast(w.marks.items.len)) catch {};
        var holds_open = std.AutoHashMapUnmanaged(u32, void){};
        defer holds_open.deinit(arena);
        for (w.marks.items) |m| {
            pos.put(arena, m.cell, toScreen(cam, dctx, m)) catch {};
            if (dctx.holdsOpen(dctx.ctx, w, m)) holds_open.put(arena, m.cell, {}) catch {};
        }

        var dupe: usize = 0;
        var batch = galaxy.LineBatch.init(arena);
        // Ambient segments are collected before any are emitted, because their opacity depends on
        // how many of them there turn out to be — and that is knowable only *after* culling. What
        // falls as you zoom in is the number that survives the viewport, so that is what sets the
        // ink.
        var segs: std.ArrayListUnmanaged(struct {
            a: dvui.Point.Physical,
            b: dvui.Point.Physical,
            alpha: f32,
        }) = .empty;
        defer segs.deinit(arena);
        var lit = theme.color(.highlight, .fill);
        lit.a = @intFromFloat(@as(f32, @floatFromInt(lit.a)) * 0.95 * fade);

        // Where a link's endpoint is, even when that endpoint has no mark this frame.
        //
        // `decideTopology` culls off-screen cells but still claims their note ranges, precisely so
        // "a link leaving the viewport keeps a target" — yet the draw dropped exactly those links,
        // because `pos` is built from living marks only. A connection to something just past the
        // edge simply vanished, which reads as the graph being less connected than it is.
        //
        // The culled cell is still *placed*: anything reaching the cull test got there through its
        // parent's `ensureChildren`, so `field.pos` is valid. Using it draws the link running off
        // toward where its far end actually is. Continuous, too — at rest a mark sits on its
        // field position, so an endpoint scrolling off-screen swaps to the same coordinate rather
        // than jumping.
        const endpoint = struct {
            fn f(
                world: *const world_mod.World,
                c: *const Camera,
                d: DrawCtx,
                live: std.AutoHashMapUnmanaged(u32, dvui.Point.Physical),
                cell: u32,
            ) ?dvui.Point.Physical {
                if (live.get(cell)) |p| return p;
                if (cell >= world.field.pos.len) return null;
                const fp = world.field.pos[cell];
                return c.worldToScreen(d.toWorld(d.ctx, .{ .x = fp.x, .y = fp.y }));
            }
        }.f;

        // Clip against the viewport with a little lead, so a stub still starts inside the panel.
        const clip_rect = cam.viewport.outsetAll(link_clip_pad);

        for (w.links.items) |l| {
            // `l.focus` is set by the lift, and means "this is one of the focused note's own
            // links" — not "touches the cell the focused note is inside", which when that note is
            // coalesced is a mass with hundreds of unrelated members.
            //
            // Focus links are drawn by the leaf-precision pass below, at the note's own position
            // rather than its stand-in cell's. Drawing them here as well would double the line and
            // — once the cut coarsens — draw it from the wrong place.
            if (l.focus) continue;
            if (debug_dupe and (l.a == w.focus_cut or l.b == w.focus_cut)) dupe += 1;
            // No "at least one end has a living mark" test here, deliberately.
            //
            // That guard was a cheap stand-in for "is any of this on screen", and it is wrong at
            // exactly the moment the picture changes: when a node coalesces, the cells this link
            // was lifted onto stop being marks *that frame*, so the line was dropped outright — it
            // vanished, and only came back once the next lift rebuilt it against the new cut and
            // its fade rose from zero, a second or more later. The crossfade in `fadeLinks` exists
            // to make that transition continuous and never got the chance.
            //
            // Both endpoints are still *placed* (`field.pos` survives coalescing — the cell simply
            // sits inside its parent's disc now), so the line keeps a true position throughout and
            // `clipToRect` below is the honest test of whether any of it is visible. It is also
            // strictly more correct: a link between two off-screen cells whose segment crosses the
            // viewport used to be discarded by the guard and is now drawn, which is the whole point
            // of clipping rather than culling by endpoint.
            const a = endpoint(w, cam, dctx, pos, l.a) orelse continue;
            const b = endpoint(w, cam, dctx, pos, l.b) orelse continue;
            const a_open = endpointLit(w, holds_open, l.a);
            const b_open = endpointLit(w, holds_open, l.b);
            if (!a_open and !b_open) {
                const seg = clipToRect(a, b, clip_rect) orelse continue;
                segs.append(arena, .{ .a = seg.a, .b = seg.b, .alpha = l.alpha }) catch {};
                continue;
            }
            // Drawn at full length, with no reach-out of its own.
            //
            // This branch lights up a *second* open tab that happens to be drawn as itself — never
            // the note the reader just selected, which `focus_links` handles below at leaf
            // precision with per-link timing. It used to share one animation scalar with that set,
            // so every change of focus replayed the reach for every other open tab too: with two or
            // more documents open, clicking a node sent a second wave of lines out from an
            // unrelated note. Those links are established context, not the answer to the click.
            const from = if (a_open) a else b;
            const to = if (a_open) b else a;
            const seg = clipToRect(from, to, clip_rect) orelse continue;
            batch.add(seg.a, seg.b, 1.8, withAlpha(lit, l.alpha));
            stats.links_drawn += 1;
        }

        // Now the count is known, so the ink can be mixed and the ambient web emitted.
        var ink = border_rest;
        ink.a = @intFromFloat(@as(f32, @floatFromInt(ink.a)) * ambientAlpha(segs.items.len) * fade);
        for (segs.items) |seg| {
            batch.add(seg.a, seg.b, 1.0, withAlpha(ink, seg.alpha));
            stats.links_drawn += 1;
        }

        // The focused note's own links, drawn from where the note actually is.
        //
        // Unlifted and uncoalesced on purpose: this is the set the reader is tracing, and the whole
        // failure it fixes is that lifting quietly deletes it as you travel away from the note (see
        // `World.FocusLink`). Endpoints still prefer a living mark when there is one, so a link
        // whose far end is on screen stays glued to the animated position rather than jumping to
        // the static field coordinate.
        for (w.focus_links.items) |fl| {
            const a = endpoint(w, cam, dctx, pos, fl.a) orelse continue;
            const b = endpoint(w, cam, dctx, pos, fl.b) orelse continue;
            // This link's own reach, not the frame's: `World.stepFocusGrow` advances one value per
            // link, so clicking a new node leaves an already-extended connection where it is and
            // only the newly focused ones travel.
            const fgrow = dvui.easing.inOutCubic(std.math.clamp(fl.grow, 0, 1));
            const tip = dvui.Point.Physical{
                .x = a.x + (b.x - a.x) * fgrow,
                .y = a.y + (b.y - a.y) * fgrow,
            };
            // The whole line first, in ambient ink, and *then* the highlight sweeping along it.
            //
            // The reach used to draw only the lit part, growing from the note. That is right for a
            // connection which was not on screen — but at any zoom where the note is drawn as
            // itself, its links are already visible as ambient web. Clicking then handed them to
            // this pass, which drew nothing at `grow = 0`: a line that was plainly there vanished
            // and grew back, which is the "connections show, disappear, and then animate" the
            // reader kept hitting. Keeping the full line underneath means nothing is ever removed;
            // the reveal is the *highlight* travelling out to the far end, which is also what the
            // animation was trying to say in the first place.
            if (clipToRect(a, b, clip_rect)) |whole| {
                batch.add(whole.a, whole.b, 1.0, withAlpha(ink, 1));
                stats.links_drawn += 1;
            }
            const seg = clipToRect(a, tip, clip_rect) orelse continue;
            batch.add(seg.a, seg.b, 1.8, lit);
            stats.links_drawn += 1;
        }
        if (debug_dupe) {
            var g_min: f32 = 1;
            var g_max: f32 = 0;
            for (w.focus_links.items) |fl| {
                g_min = @min(g_min, fl.grow);
                g_max = @max(g_max, fl.grow);
            }
            const sig = (@as(u64, @intCast(dupe)) << 32) |
                (@as(u64, @intFromFloat(g_min * 100)) << 16) |
                @as(u64, @intCast(w.focus_links.items.len));
            if (sig != dbg_sig) {
                dbg_sig = sig;
                dvui.log.info("draw focus_links={d} grow={d:.2}..{d:.2} dupe={d} focus_cut={d}", .{
                    w.focus_links.items.len, g_min, g_max, dupe, w.focus_cut,
                });
            }
        }
        batch.flush();
    }

    const buf = arena.alloc(galaxy.StyledMark, w.marks.items.len) catch return stats;
    var n: usize = 0;
    for (w.marks.items) |m| {
        const holds_open = dctx.holdsOpen(dctx.ctx, w, m);
        const style = dctx.style(dctx.ctx, w, m, holds_open);
        buf[n] = .{
            .screen = toScreen(cam, dctx, m),
            .r_px = style.r_px,
            .fill = style.fill,
            .border = style.border,
            .is_note = style.is_note,
            .dying = false,
        };
        n += 1;
        if (style.is_note) stats.notes_drawn += 1 else stats.clusters_drawn += 1;
    }
    _ = galaxy.drawStyledMarks(&dens.soft, cam, fade, buf[0..n]);
    return stats;
}
