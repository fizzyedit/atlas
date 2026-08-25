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
    /// Draw this mark as a dashed rim over an opaque face, in vector, above everything else.
    /// For the note under the cursor and the notes the reader has open — see `galaxy.StyledMark`.
    dashed: bool = false,
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

/// Ambient-web mix. Constant, not a function of how many lines are on screen.
///
/// Density used to walk this toward the background as the viewport filled, so a zoom that
/// added or culled lines recoloured *every* surviving edge. That was the flash. Overlaps
/// already stay one shade (`intoBg` is opaque), so a dense web is a texture of this colour
/// rather than a glow — there is nothing left for a count-based mix to do except pulse.
const ambient_mix: f32 = 0.28;
/// Focused-note links, also constant, and kept well above the ambient web so the answer to
/// "what does this note connect to" stays the brightest lines on screen.
const focus_mix: f32 = 0.55;

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

/// Where a focused link's two ends are drawn once a note has coalesced.
///
/// The ends are doing different jobs, and the right answer is not the same for both.
///
/// The **source** is the note being looked at. Its web has to stay rooted in whatever is drawn for
/// it, or zooming out leaves the highlighted lines radiating from a point inside a mass that is no
/// longer on screen — the web comes adrift from the node it belongs to.
///
/// The **far end** is a destination. Snapping it to the mass standing in for it costs the one thing
/// this whole highlight exists for: following a link flies the camera along that edge, and the
/// illusion only holds while the line ends where the camera is actually going. A line into a mass
/// centroid, which then jumps as the mass opens, breaks the ride.
///
/// So: anchor the source, tell the truth about the far end. `.stand_in` and `.true_position` are
/// kept because both are defensible in isolation and the difference is only visible on a coalesced
/// graph — worth being able to look at each.
const FocusEndpoints = enum {
    /// Both ends at the notes' own positions. Sharpest about destinations; the source can come
    /// adrift from its own mark.
    true_position,
    /// Both ends at the mark standing in for them. Always attached, never precise.
    stand_in,
    /// Source anchored to its stand-in, far end left true.
    anchor_source,
};
const focus_endpoints: FocusEndpoints = .anchor_source;

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
    const bg = theme.color(.window, .fill);
    const border_rest = theme.color(.window, .text);

    const toScreen = struct {
        fn f(c: *const Camera, tw: DrawCtx, m: world_mod.Mark) dvui.Point.Physical {
            return c.worldToScreen(tw.toWorld(tw.ctx, .{ .x = m.wx, .y = m.wy }));
        }
    }.f;

    var stats: DrawStats = .{};

    // Links first so the web passes under the marks rather than over them.
    //
    // The focused note's own links are drawn by this block too, and they are a *separate* set with
    // a separate reason to exist — so the gate has to admit either one. Keyed on the ambient list
    // alone, a frame whose lift produced no cell-to-cell web took the reader's highlighted
    // connections down with it: the note stays drawn as itself, its neighbours stay drawn as
    // themselves, and the lines between them simply are not there.
    if (w.links.items.len > 0 or w.focus_links.items.len > 0) {
        // One pass over the marks instead of a scan per endpoint: the web is budgeted at 900 and
        // the marks at a few hundred, so the naive version was ~250k comparisons a frame.
        //
        // A plain array parallel to `marks`, not a map: `World.markIndex` already answers
        // "which mark is this cell's" from a dense stamped array, so the two lookups every link
        // endpoint needs — 40,000 a frame at the top of the quality slider — are index reads.
        const scr = arena.alloc(dvui.Point.Physical, w.marks.items.len) catch return stats;
        defer arena.free(scr);
        for (w.marks.items, scr) |m, *q| q.* = toScreen(cam, dctx, m);

        var batch = galaxy.LineBatch.init(arena);
        var lit_segs: std.ArrayListUnmanaged(struct {
            a: dvui.Point.Physical,
            b: dvui.Point.Physical,
        }) = .empty;
        defer lit_segs.deinit(arena);
        const lit_base = theme.color(.highlight, .fill);
        const ambient_t = ambient_mix * fade;
        const focus_t = focus_mix * fade;

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
        // The deepest *drawn* ancestor of `cell` — the thing currently standing in for it.
        //
        // Walks the ladder rather than asking the cut: at most a handful of steps (six levels at a
        // million notes), and it answers with what is actually on screen this frame, including
        // while a closing cell and its children are still crossfading past each other. That is what
        // keeps the endpoint continuous through a coalesce instead of jumping when the leaf's own
        // mark stops being drawn.
        const standIn = struct {
            fn f(
                world: *const world_mod.World,
                live: []const dvui.Point.Physical,
                cell: u32,
            ) ?dvui.Point.Physical {
                var c = cell;
                var guard: u8 = 0;
                while (c != world_mod.fold.invalid and guard < 64) : (guard += 1) {
                    if (world.markIndex(c)) |i| return live[i];
                    if (c >= world.lad.cells.len) return null;
                    c = world.lad.cells[c].parent;
                }
                return null;
            }
        }.f;

        const endpoint = struct {
            fn f(
                world: *const world_mod.World,
                c: *const Camera,
                d: DrawCtx,
                live: []const dvui.Point.Physical,
                cell: u32,
            ) ?dvui.Point.Physical {
                if (world.markIndex(cell)) |i| return live[i];
                if (cell >= world.field.pos.len) return null;
                const fp = world.field.pos[cell];
                return c.worldToScreen(d.toWorld(d.ctx, .{ .x = fp.x, .y = fp.y }));
            }
        }.f;

        // Clip against the viewport with a little lead, so a stub still starts inside the panel.
        const clip_rect = cam.viewport.outsetAll(link_clip_pad);

        for (w.links.items) |l| {
            // Ambient web only. **Every** link belonging to an open note — focused or not — is
            // drawn by the leaf-precision pass below, and by nothing else.
            //
            // There used to be a second drawer here: a branch that painted an open note's *lifted*
            // links in the highlight colour at full length. Two passes drawing the same connections
            // is what made the reveal unreliable, and the failure was not a timing bug that could be
            // nudged. The lift is cached, and held outright while the camera moves, so `l.focus` —
            // set when the lift last ran — goes stale exactly when a click opens a note and flies
            // there. For those frames the note was already "open" but its links were not yet marked
            // focus, so the second drawer painted the whole web at full highlight; when the lift
            // caught up the links became focus links and restarted from zero. Flash, vanish,
            // re-animate. One drawer cannot disagree with itself.
            if (l.focus) continue;
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
            const a = endpoint(w, cam, dctx, scr, l.a) orelse continue;
            const b = endpoint(w, cam, dctx, scr, l.b) orelse continue;
            const seg = clipToRect(a, b, clip_rect) orelse continue;
            const t = ambient_t * l.alpha;
            if (t <= 0.004) continue;
            batch.add(seg.a, seg.b, 1.0, galaxy.intoBg(border_rest, bg, t));
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
            const a_snap = focus_endpoints != .true_position;
            const b_snap = focus_endpoints == .stand_in;
            const a = (if (a_snap) standIn(w, scr, fl.a) else null) orelse
                endpoint(w, cam, dctx, scr, fl.a) orelse continue;
            const b = (if (b_snap) standIn(w, scr, fl.b) else null) orelse
                endpoint(w, cam, dctx, scr, fl.b) orelse continue;
            // This link's own reach, not the frame's: `World.stepFocusGrow` advances one value per
            // link, so clicking a new node leaves an already-extended connection where it is and
            // only the newly focused ones travel.
            const fgrow = dvui.easing.inOutCubic(std.math.clamp(fl.grow, 0, 1));
            const tip = dvui.Point.Physical{
                .x = a.x + (b.x - a.x) * fgrow,
                .y = a.y + (b.y - a.y) * fgrow,
            };
            // The unreached remainder in ambient colour, and the grown part in highlight — not
            // both on top of each other.
            //
            // The reach used to draw only the lit part, growing from the note. That is right for a
            // connection which was not on screen — but at any zoom where the note is drawn as
            // itself, its links are already visible as ambient web. Clicking then handed them to
            // this pass, which drew nothing at `grow = 0`: a line that was plainly there vanished
            // and grew back. Drawing the remainder keeps that line present. Drawing the two as
            // *translucent* overlays used to mix orange-over-grey into yellow and red; splitting
            // them means each pixel is one colour.
            if (fgrow < 0.996 and ambient_t > 0.004) {
                if (clipToRect(tip, b, clip_rect)) |rest| {
                    batch.add(rest.a, rest.b, 1.0, galaxy.intoBg(border_rest, bg, ambient_t));
                    stats.links_drawn += 1;
                }
            }
            if (fgrow <= 0.004) continue;
            const seg = clipToRect(a, tip, clip_rect) orelse continue;
            lit_segs.append(arena, .{ .a = seg.a, .b = seg.b }) catch {};
        }

        if (focus_t > 0.004) {
            const lit = galaxy.intoBg(lit_base, bg, focus_t);
            for (lit_segs.items) |seg| {
                batch.add(seg.a, seg.b, 1.8, lit);
                stats.links_drawn += 1;
            }
        }
        batch.flush();
    }

    const buf = arena.alloc(galaxy.StyledMark, w.marks.items.len) catch return stats;
    var n: usize = 0;
    for (w.marks.items) |m| {
        const holds_open = dctx.holdsOpen(dctx.ctx, w, m);
        const style = dctx.style(dctx.ctx, w, m, holds_open);
        // Split and merge stay continuous through pose, not through colour.
        //
        // `present` chases `anim`, slides a closing cell's children in toward their parent's
        // centre, and shrinks the parent toward a note. Notes and masses share a fill, so
        // overlapping discs read as one object becoming several — or several becoming one.
        // Mixing each mark toward the window fill as `alpha` fell used to punch opaque holes
        // in the parent: `intoBg` is opaque, so a dying child painted the background *over*
        // the mass it was joining. Colour that has to change (a hovered note, an open one)
        // walks to the shared rest fill in `overviewMarkStyle` instead.
        buf[n] = .{
            .screen = toScreen(cam, dctx, m),
            .r_px = style.r_px,
            .fill = style.fill,
            .border = style.border,
            .is_note = style.is_note,
            .dying = false,
            // Mass rings, then notes, then mass fills — `galaxy` sandwiches a merge so joining
            // notes cover the dashes and then disappear under the fill. Open notes (`dashed`)
            // still paint last, vector, on top of everything.
            .dashed = style.dashed,
        };
        n += 1;
        if (style.is_note) stats.notes_drawn += 1 else stats.clusters_drawn += 1;
    }
    _ = galaxy.drawStyledMarks(&dens.soft, cam, fade, buf[0..n]);
    return stats;
}
