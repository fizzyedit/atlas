//! The one place a `world_mod.World`'s living marks and lifted links get turned into pixels.
//!
//! The vault overview draws a `World`. The note interior (a separate, larger change) is being
//! rewritten to reuse the same `fold`/`containment`/`World` machinery for a note's own content,
//! which means it will draw a `World` too — its own, nested one. If that meant writing a second
//! copy of this drawing logic, the two would eventually diverge, silently: that exact class of
//! bug (a second view quietly missing something the first one does) was the single biggest
//! source of regressions earlier this session, every time containment inherited a mechanism a
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
const Camera = @import("camera.zig");

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

pub const DrawStats = struct { notes_drawn: u32 = 0, clusters_drawn: u32 = 0 };

/// Draw `w`'s links, then its marks, through `cam`. `fade` is the overview/interior cross-fade
/// weight (0 draws nothing); `select_anim` drives an open note's links growing out to full
/// length rather than appearing at once — see the comment at its one current use below.
pub fn draw(
    w: *const world_mod.World,
    cam: *const Camera,
    dens: *galaxy.Density,
    fade: f32,
    select_anim: f32,
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

        var batch = galaxy.LineBatch.init(arena);
        var ink = border_rest;
        ink.a = @intFromFloat(@as(f32, @floatFromInt(ink.a)) * 0.22 * fade);
        var lit = theme.color(.highlight, .fill);
        lit.a = @intFromFloat(@as(f32, @floatFromInt(lit.a)) * 0.95 * fade);

        // An open note's links draw *out from it*, growing to full length. Reaching out is what
        // makes the connection read as belonging to the note you just opened rather than as more
        // of the ambient web.
        const grow = dvui.easing.outCubic(std.math.clamp(select_anim, 0, 1));

        for (w.links.items) |l| {
            const a = pos.get(l.a) orelse continue;
            const b = pos.get(l.b) orelse continue;
            const a_open = holds_open.contains(l.a);
            const b_open = holds_open.contains(l.b);
            if (!a_open and !b_open) {
                batch.add(a, b, 1.0, ink);
                continue;
            }
            // grow from whichever end is open
            const from = if (a_open) a else b;
            const to = if (a_open) b else a;
            const tip = dvui.Point.Physical{
                .x = from.x + (to.x - from.x) * grow,
                .y = from.y + (to.y - from.y) * grow,
            };
            batch.add(from, tip, 1.8, lit);
        }
        batch.flush();
    }

    const buf = arena.alloc(galaxy.StyledMark, w.marks.items.len) catch return .{};
    var n: usize = 0;
    var stats: DrawStats = .{};
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
