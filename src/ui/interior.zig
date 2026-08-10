//! Where a note's own cloud sits inside the overview's.
//!
//! The graph has two levels. The overview draws one node per note; descending into a note draws
//! one node per section of it (`query.noteSnapshot`). The two are not separate screens that swap
//! — the note's cloud lives *inside* its node, at a smaller scale, and the camera simply keeps
//! zooming until it fills the panel. Backing out reverses exactly.
//!
//! **The scale is always a power of two, and that is the whole trick.** Hex levels are powers of
//! two by construction (`hex.levelSpacing`), and the layout only ever snaps to integer levels
//! (`hex.layoutLevelFor`), so halving an interior layout's coordinates maps it *exactly* onto a
//! finer level of the very same lattice the background grid is already drawing. The nested cloud
//! is therefore not a second coordinate system that happens to resemble the first — it is
//! literally the next level down. Three things fall out of that for free:
//!
//! * The dot grid densifies into the interior as the camera descends, because it was always
//!   going to draw that level; nobody has to hand it a different lattice.
//! * The descent lands on a clean LOD boundary (`hex.cleanZoom`), where the grid fade is 0
//!   rather than caught half-way between two levels.
//! * Nothing about the layout needs to know it is nested. `layout_full` lays the sections out at
//!   their natural level and this scales the result; a non-power-of-two scale would put every
//!   node between cells and undo the snapping that the whole layout is built on.
//!
//! Pure geometry — no camera, no DB, no dvui frame state.
const std = @import("std");
const dvui = @import("dvui");

const hex = @import("hex.zig");

/// Share of one overview lattice step the interior cloud is allowed to fill.
///
/// Small, and it is the *reveal* that sets how small rather than tidiness. This is a radius
/// against a centre-to-centre step, so 0.5 would have adjacent notes' interiors touching — but the
/// binding constraint is much tighter than that: an interior has to be safely invisible while the
/// overview is on screen, and the overview can be zoomed a long way in on a small vault (it is
/// capped only by `graph.fit_max_gap_px`, at 150px between notes). A roomy footprint leaves an
/// interior lattice tens of pixels across at that pose, well inside `show_gap_px`, and the two
/// levels are then visible at once — which is exactly what "zooming out doesn't hide the inner
/// nodes" looks like. At 0.12 every vault size lands under 10px at the overview's closest pose.
///
/// It also buys the zoom range: a tighter berth means more levels down, and so more room to move
/// around once you are inside a note.
pub const default_footprint: f32 = 0.12;

/// Fewest lattice levels between the overview and an interior — a 16× flight.
///
/// Needed because "small enough to fit in its berth" does not by itself imply "deep enough". A
/// note with one or two headings has essentially no radius, so the fitting loop asks for no shrink
/// at all and the interior would sit on its parent's own lattice: nothing to descend through, and
/// still plainly visible at the overview. This floor is what governs sparse notes, and the
/// footprint governs dense ones; between them every note ends up properly tucked inside its node.
pub const min_descent_levels: i32 = 4;

pub const Nest = struct {
    /// Level steps down from the interior layout's own level. Never negative — an interior is
    /// never scaled *up*.
    steps: i32,
    /// 2^-steps. Multiply interior layout coordinates by this.
    scale: f32,
    /// Hex level the interior lattice lands on, and so the level the background grid will be
    /// drawing when the camera is down there.
    level: i32,
    /// The shrink this wanted was refused because it would have fallen past the finest level the
    /// camera can usefully reach. The interior will overflow its berth; the caller should expect
    /// it to overlap neighbouring notes.
    clamped: bool,
};

/// How far to shrink an interior cloud so it sits inside one overview node's berth.
///
/// `interior_radius` is the world-space radius the sections were actually laid out at,
/// `interior_level` the lattice level they were laid out on, and `parent_level` the overview's.
/// Rounds *down* to a power of two — a cloud that only just fits is exactly the case where being
/// a little smaller costs nothing and being a little larger overlaps.
pub fn nest(
    interior_radius: f32,
    interior_level: i32,
    parent_level: i32,
    footprint: f32,
) Nest {
    const berth = @max(hex.levelSpacing(parent_level), 1) * @max(footprint, 0.01);
    var steps: i32 = 0;
    var r = @max(interior_radius, 0);
    while (r > berth and steps < 32) : (steps += 1) r *= 0.5;

    // Fitting is not enough — see `min_descent_levels`. A small interior may already fit at scale
    // 1, which would leave it sitting on its parent's own lattice with nothing to descend through.
    steps = @max(steps, interior_level - (parent_level - min_descent_levels));

    // Leave a couple of levels of headroom under the interior: once inside, the reader can still
    // zoom in on it, and a cloud parked on the very finest level would hit the stop immediately.
    const floor_level = hex.max_zoom_level + 2;
    const ideal = interior_level - steps;
    if (ideal < floor_level) {
        const allowed = interior_level - floor_level;
        return .{
            .steps = allowed,
            .scale = std.math.ldexp(@as(f32, 1), @intCast(-allowed)),
            .level = floor_level,
            .clamped = true,
        };
    }
    return .{
        .steps = steps,
        .scale = std.math.ldexp(@as(f32, 1), @intCast(-steps)),
        .level = ideal,
        .clamped = false,
    };
}

/// The berth every interior shares, in world units, for a vault whose lattice is `parent_level`.
///
/// The *same* for every note, and that is the point. Sizing each note's berth to its own section
/// count would have a three-heading note and a forty-heading note beside each other blooming at
/// different rates and to different sizes — but zooming is literal, so they have to open together,
/// as one movement. Section count decides how dense a cloud is inside its berth, never how big
/// the berth is.
pub fn berthFor(parent_level: i32) f32 {
    return hex.levelSpacing(parent_level) * default_footprint;
}

/// How far into the descent the whole view is. Global, not per-note, for the same reason the berth
/// is shared: every node blooms at once, so there is one number, and it comes from the camera.
pub fn descentAt(parent_level: i32, zoom: f32, viewport_min_px: f32) f32 {
    return descent(berthFor(parent_level), zoom, viewport_min_px);
}

/// Map a laid-out interior coordinate into world space, under `parent`'s node.
pub fn toWorld(local: dvui.Point, n: Nest, parent: dvui.Point) dvui.Point {
    return .{ .x = parent.x + local.x * n.scale, .y = parent.y + local.y * n.scale };
}


/// Share of the panel's short side the interior's own spread has to cover before it starts to
/// appear, and before it has fully taken over.
///
/// Occupancy rather than zoom, because the two levels are meant to *be* the same thing: once you
/// are inside a note its cloud is framed to extents and reshaped by the panel exactly as the vault
/// is, so "how much of the panel does this cloud fill" is the one measure that means the same on
/// both, whatever lattice either happens to sit on or however big the vault is.
/// `show_at_fraction` sits above where a *focus* pose lands (`graph.focus_max_gap_px`), so
/// selecting a document zooms closer without the interiors starting to bleed through — those are
/// meant to be two distinct places to be, not a continuum with a smudge in between.
pub const show_at_fraction: f32 = 0.22;
pub const full_at_fraction: f32 = 0.55;

/// How far into the descent the view is, as 0 (the vault) → 1 (the note's own cloud owns the
/// panel). `radius` is the interior cloud's world-space radius, already nested.
///
/// A pure function of what is on screen, so it is reversible and interruptible for free: there is
/// no stored progress to unwind, and zooming back out simply plays it backwards.
///
/// It must not be measured against either lattice's zoom, which is what it did before. The
/// overview has no single zoom to compare to — `fitToNodes` caps a small vault far closer in than
/// a large one — so the same pose read as "at the vault" in one vault and "inside a note" in
/// another, and small vaults showed their interiors permanently with no way to dismiss them.
pub fn descent(radius: f32, zoom: f32, viewport_min_px: f32) f32 {
    if (!(zoom > 0) or !(viewport_min_px > 1) or !(radius > 0)) return 0;
    const covered = (radius * 2 * zoom) / viewport_min_px;
    const t = std.math.clamp(
        (covered - show_at_fraction) / (full_at_fraction - show_at_fraction),
        0,
        1,
    );
    // Same smoothstep the label reveal uses, so the fades feel like one system.
    return t * t * (3.0 - 2.0 * t);
}

// -- tests ------------------------------------------------------------------------

const testing = std.testing;

test "an interior is shrunk to fit inside one overview step" {
    const parent_slot = hex.levelSpacing(3); // 224wu, a large vault's lattice
    const n = nest(400, 2, 3, default_footprint);
    try testing.expect(!n.clamped);
    try testing.expect(400 * n.scale <= parent_slot * default_footprint);
    // ...and not shrunk further than it had to be: one step less would not have fit.
    try testing.expect(400 * n.scale * 2 > parent_slot * default_footprint);
}

test "the scale is always an exact power of two" {
    // The property the whole nesting rests on: an interior lands *on* a coarser-or-finer level of
    // the same lattice, never between two. A scale of, say, 0.3 would put every node off-cell.
    for ([_]f32{ 10, 137, 400, 2000 }) |r| {
        for ([_]i32{ 1, 2, 3 }) |lvl| {
            const n = nest(r, lvl, 3, default_footprint);
            const back = std.math.log2(n.scale);
            try testing.expectApproxEqAbs(@round(back), back, 1e-5);
            // And the level bookkeeping agrees with the scale.
            try testing.expectEqual(lvl - n.steps, n.level);
            try testing.expectApproxEqAbs(
                hex.levelSpacing(n.level),
                hex.levelSpacing(lvl) * n.scale,
                1e-3,
            );
        }
    }
}

test "nesting never falls past the finest level the camera can reach" {
    const n = nest(100_000, 1, 1, 0.05);
    try testing.expect(n.clamped);
    try testing.expect(n.level >= hex.max_zoom_level);
}

test "an interior is always deeper than its parent, even when it would fit as-is" {
    // A note with one or two headings has essentially no radius, so the fitting loop asks for no
    // shrink at all and the cloud would sit on its parent's own lattice — indistinguishable from
    // the vault around it, with nothing to zoom through.
    for ([_]i32{ 1, 2, 3 }) |parent| {
        for ([_]i32{ 1, 2, 3 }) |inner| {
            const n = nest(0, inner, parent, default_footprint);
            try testing.expect(n.level <= parent - min_descent_levels);
            try testing.expect(n.scale < 1);
        }
    }
}

test "toWorld places the interior under its parent" {
    const n = nest(400, 2, 3, default_footprint);
    const parent: dvui.Point = .{ .x = 500, .y = -200 };
    // The interior's own origin is its parent's position exactly, so the note's node and the
    // centre of its cloud are the same point and the descent has nothing to slide sideways.
    const at_origin = toWorld(.{}, n, parent);
    try testing.expectApproxEqAbs(parent.x, at_origin.x, 1e-4);
    try testing.expectApproxEqAbs(parent.y, at_origin.y, 1e-4);

    const off = toWorld(.{ .x = 400, .y = 0 }, n, parent);
    try testing.expect(off.x > parent.x);
    try testing.expect(off.x - parent.x < hex.levelSpacing(3));
}

test "descent runs 0 to 1 as the interior grows on screen" {
    const vp: f32 = 800;
    const r: f32 = 100;
    // Invisible while it covers almost nothing of the panel, fully arrived once it dominates.
    try testing.expectEqual(@as(f32, 0), descent(r, 0.0001, vp));
    try testing.expectApproxEqAbs(@as(f32, 1), descent(r, vp / (2 * r), vp), 1e-4);
    // Degenerate inputs are 0, not NaN.
    try testing.expectEqual(@as(f32, 0), descent(0, 1, vp));
    try testing.expectEqual(@as(f32, 0), descent(r, 0, vp));
    try testing.expectEqual(@as(f32, 0), descent(r, 1, 0));
}

test "an interior is hidden while the vault is the thing on screen" {
    // Occupancy is measured against the panel, so this holds whatever the vault's size or the
    // panel's shape — which is the point of measuring it this way rather than against a zoom.
    const vp: f32 = 800;
    const lf = @import("layout_full.zig");
    for ([_]usize{ 8, 12, 40, 300, 3000 }) |notes| {
        for ([_]usize{ 1, 3, 8, 20, 90, 300 }) |secs| {
            const parent_level = hex.layoutLevelFor(notes);
            const n = nest(lf.packRadius(secs), hex.layoutLevelFor(secs), parent_level, default_footprint);
            const radius = lf.packRadius(secs) * n.scale;
            // The vault framed to extents puts a lattice step at well under a tenth of the panel;
            // an interior is a fraction of one step, so it cannot be showing yet.
            const vault_zoom = (vp / 10) / hex.levelSpacing(parent_level);
            try testing.expectEqual(@as(f32, 0), descent(radius, vault_zoom, vp));
        }
    }
}

test "descent is monotonic in zoom" {
    // What makes the transition reversible: it is a function of what is on screen, with no
    // hysteresis and no stored progress, so zooming back out plays it exactly backwards.
    const vp: f32 = 800;
    const r: f32 = 100;
    var prev: f32 = -1;
    var z: f32 = 0.001;
    while (z <= 20) : (z *= 1.1) {
        const t = descent(r, z, vp);
        try testing.expect(t >= prev);
        prev = t;
    }
    try testing.expectApproxEqAbs(@as(f32, 1), prev, 1e-4);
}




test "an interior stays inside its own note's berth" {
    // If a cloud overflowed its berth it would tangle with the neighbouring notes' nodes at
    // overview zoom, and the descent would read as the vault coming apart rather than one note
    // opening up.
    const lf = @import("layout_full.zig");
    for ([_]usize{ 8, 40, 300, 3000 }) |notes| {
        for ([_]usize{ 1, 5, 20, 90, 400 }) |secs| {
            const parent = hex.layoutLevelFor(notes);
            const radius = lf.packRadius(secs);
            const n = nest(radius, hex.layoutLevelFor(secs), parent, default_footprint);
            if (n.clamped) continue; // documented to overflow; nothing to assert
            const berth = hex.levelSpacing(parent) * default_footprint;
            try testing.expect(radius * n.scale <= berth + 1e-3);
        }
    }
}

test "every note blooms at the same rate, whatever its size" {
    // Zooming is literal: three notes side by side must open together, as one movement. That means
    // one shared berth and one shared `t` — if depth were sized per note, a sparse note and a
    // dense one beside it would arrive at different moments and at different sizes.
    const vp: f32 = 800;
    for ([_]i32{ 1, 2, 3 }) |parent_level| {
        const zoom = (vp / 3) / hex.levelSpacing(parent_level);
        const t = descentAt(parent_level, zoom, vp);
        // The same pose gives the same t regardless of what any individual note contains.
        for ([_]usize{ 1, 7, 50, 400 }) |secs| {
            _ = secs;
            try testing.expectEqual(t, descentAt(parent_level, zoom, vp));
        }
        try testing.expect(berthFor(parent_level) < hex.levelSpacing(parent_level) * 0.5);
    }
}

test "a focus pose does not start showing interiors" {
    // Selecting a document zooms closer, but it is a different place to be than being *inside* the
    // document — the two must not bleed into each other. `graph.focus_max_gap_px` is the closest a
    // focus ever gets, in px between vault lattice neighbours.
    const graph_focus_max_gap_px: f32 = 300;
    for ([_]f32{ 400, 600, 900, 1400 }) |vp| {
        for ([_]i32{ 1, 2, 3 }) |parent_level| {
            const zoom = graph_focus_max_gap_px / hex.levelSpacing(parent_level);
            try testing.expectEqual(@as(f32, 0), descentAt(parent_level, zoom, vp));
        }
    }
}
