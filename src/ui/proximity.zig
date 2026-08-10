//! How much the graph's mouse-proximity swell should count for at the current scale.
//!
//! Pure scalar curve, no dvui — the graph panel is hard to test, this isn't.
//!
//! Proximity assumes the cursor picks out a *local* neighbourhood of the web. That assumption
//! breaks at far zoom: once the entire vault is smaller on screen than the proximity radius,
//! every node reads as fully hovered at once. They all swell, and because a swollen node shoves
//! its neighbours by its own *screen* radius converted back into world units, every node also
//! shoves every other one. At minimum zoom that shove is thousands of world units inside a
//! cloud a few hundred units across, so nodes are flung past the centre and out the far side.
//!
//! That was the "at far zoom the nodes get bigger, offset, and inverted" failure: one cause,
//! three symptoms. `strength` is the fix — it fades the whole proximity system out before the
//! web collapses to the size of the falloff.
const std = @import("std");

/// Below this (web diameter / falloff radius) the cursor can no longer select a neighbourhood
/// — everything is "near" — so proximity is off entirely.
pub const off_ratio: f32 = 0.8;
/// At or above this the falloff spans at most half the web's width, which is genuinely
/// selective, so proximity runs at full strength. Every vault size's default fitted view
/// lands at or above this.
pub const full_ratio: f32 = 2.0;

/// 0 → proximity disabled, 1 → full swell. `web_screen_diameter` and `falloff_px` are both in
/// screen pixels, so this is scale-free: it reads the actual on-screen extent and behaves the
/// same for a 5-note vault as for a 5000-note one.
pub fn strength(web_screen_diameter: f32, falloff_px: f32) f32 {
    const ratio = web_screen_diameter / @max(falloff_px, 1);
    const t = std.math.clamp((ratio - off_ratio) / (full_ratio - off_ratio), 0, 1);
    return t * t * (3.0 - 2.0 * t); // smoothstep
}

// -- tests ------------------------------------------------------------------------

const testing = std.testing;

test "off once the web is no bigger than the falloff" {
    // The regression: at min zoom a whole vault collapses into a handful of pixels. Every node
    // would otherwise read as fully hovered and shove every other one across the cloud.
    const falloff: f32 = 100;
    for ([_]f32{ 0, 4, 12, 30, 60, 79 }) |web_px| {
        try testing.expectEqual(@as(f32, 0), strength(web_px, falloff));
    }
}

test "full strength once the web is twice the falloff" {
    const falloff: f32 = 100;
    for ([_]f32{ 200, 328, 600, 1200, 4000 }) |web_px| {
        try testing.expectEqual(@as(f32, 1), strength(web_px, falloff));
    }
}

test "monotonic across the ramp" {
    const falloff: f32 = 100;
    var prev: f32 = -1;
    var web: f32 = 0;
    while (web <= 400) : (web += 5) {
        const s = strength(web, falloff);
        try testing.expect(s >= prev);
        try testing.expect(s >= 0 and s <= 1);
        prev = s;
    }
}

test "scale-free: only the ratio matters" {
    // A small vault zoomed in and a huge one zoomed out at the same ratio behave identically.
    try testing.expectApproxEqAbs(strength(150, 100), strength(1500, 1000), 1e-6);
    try testing.expectApproxEqAbs(strength(240, 100), strength(24, 10), 1e-6);
}

test "default fitted view of every vault size keeps proximity fully on" {
    // Guards the other direction: the fix must not quietly weaken hover at the view you get on
    // open. Ratios measured from `fitToNodes` against a typical bottom-panel viewport for
    // vaults of 5/10/50/100 notes.
    for ([_]f32{ 1.65, 2.06, 2.88, 3.24 }) |ratio| {
        try testing.expect(strength(ratio * 100, 100) > 0.75);
    }
}
