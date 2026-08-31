//! Windowing for a run of **variable-height** rows drawn inside somebody else's scroll area.
//!
//! The problem this solves. A list of tens of thousands of rows cannot build a widget per row —
//! at Wikipedia scale a single note has 28,754 backlinks, and even dvui's `cacheSize` (which
//! skips an off-screen row's *children*) still costs a widget and a few hash lookups each. The
//! answer is to build only the rows the viewport can see and account for the rest as height:
//! a lead spacer for everything above, the visible block, a tail spacer for everything below.
//!
//! Why not `ScrollInfo{ .vertical = .given }`, which dvui's icon browser uses for exactly this:
//! because a sidebar pane does not own its scroll area. fizzy's explorer wraps every view's
//! `draw` in one, and nesting a second produced two scrollbars fighting each other (see the
//! comment on `backlinks.draw`). Not owning the scroll means we cannot *declare* the content
//! height, so we spell it with spacers instead — same arithmetic, one layer out.
//!
//! Why this is not just a row pitch. A uniform pitch turns the window into division, which is
//! why it is what everything reaches for first. But it forces every row to the same height, and
//! a row of wrapped prose is however many lines the prose takes. Cumulative offsets cost one
//! `f32` per row and a binary search per frame, and they are *exact* — no measured-pitch
//! feedback loop where the run's total height changes under the scrollbar that is reading it.
//!
//! Deliberately free of dvui and of any vault type: it is arithmetic over two float arrays, so
//! it tests headlessly and can serve any list. Units are whatever the caller's heights are in —
//! natural (logical) units in every current caller, since that is what font metrics speak.
const std = @import("std");

/// The rows to build this frame, and the height to account for on either side.
///
/// `lead + (offsets[hi] - offsets[lo]) + tail == total`, always — that identity is what keeps
/// the scrollbar still while the window slides.
pub const Window = struct {
    /// First row to build.
    lo: usize,
    /// One past the last row to build.
    hi: usize,
    /// Height of the skipped run above `lo`.
    lead: f32,
    /// Height of the skipped run below `hi`.
    tail: f32,

    pub fn count(self: Window) usize {
        return self.hi - self.lo;
    }
};

/// Cumulative row tops. Built by `accumulate`; borrows the caller's storage.
pub const Run = struct {
    /// Top edge of every row, plus the run's total height at the end — so `len == rows + 1`
    /// and `offsets[i + 1] - offsets[i]` is row `i`'s height. The extra entry is not padding:
    /// it is what makes `tail` and `total` the same lookup as any other row's top, with no
    /// special case at the end of the list.
    offsets: []const f32,

    pub fn rows(self: Run) usize {
        return self.offsets.len - 1;
    }

    pub fn total(self: Run) f32 {
        return self.offsets[self.offsets.len - 1];
    }

    /// Top edge of row `i`. `i == rows()` answers `total()`.
    pub fn top(self: Run, i: usize) f32 {
        return self.offsets[i];
    }

    /// The row containing `y` — the last one whose top is at or below it.
    ///
    /// A `y` before the run answers 0, and one past its end answers `rows()`: a one-past index,
    /// not the last row. That is deliberate, and it is what lets `window` return an empty window
    /// for a viewport scrolled clear of the run instead of pinning the final row on screen. It is
    /// also why `offsets` carries the total as an extra entry — `rows()` is a real index there.
    pub fn indexAt(self: Run, y: f32) usize {
        const n = self.rows();
        if (n == 0) return 0;
        // `offsets` is non-decreasing by construction (heights are clamped non-negative), so
        // this is a plain binary search rather than anything cleverer.
        return @min(n, std.sort.upperBound(f32, self.offsets, y, ltF32) -| 1);
    }

    /// The rows overlapping `[view_top, view_top + view_h)`, grown by `overscan` on each side.
    ///
    /// Overscan is height, not a row count: a row count means something different at every row
    /// height, which is the assumption this file exists to drop. It buys the frame a row needs
    /// to settle its content before it is looked at, so a screenful is generous and a few
    /// hundred units is plenty.
    pub fn window(self: Run, view_top: f32, view_h: f32, overscan: f32) Window {
        const n = self.rows();
        if (n == 0) return .{ .lo = 0, .hi = 0, .lead = 0, .tail = 0 };

        const lo = self.indexAt(view_top - overscan);
        // First row that starts at or after the bottom edge; everything before it overlaps.
        // `lowerBound`, not `upperBound`: a row whose top *equals* the bottom edge starts where
        // the viewport ends and is not on screen, so it must fall outside the window.
        const bottom = view_top + view_h + overscan;
        const hi = @min(n, std.sort.lowerBound(f32, self.offsets, bottom, ltF32));

        // A viewport entirely above or below the run leaves `hi <= lo`; an empty window is the
        // right answer there, and the spacers still have to add up.
        if (hi <= lo) {
            const edge = self.offsets[lo];
            return .{ .lo = lo, .hi = lo, .lead = edge, .tail = self.total() - edge };
        }
        return .{
            .lo = lo,
            .hi = hi,
            .lead = self.offsets[lo],
            .tail = self.total() - self.offsets[hi],
        };
    }
};

/// Fill `offsets` (which must be one longer than `heights`) with the running sum, and return the
/// `Run` over it.
///
/// Negative heights are clamped to zero rather than rejected: a caller computing a height from
/// font metrics and a subtraction has one arithmetic slip between it and a non-monotonic offsets
/// array, and every search here assumes monotonic. Clamping keeps a bad height a bad *row*
/// instead of a corrupt window.
pub fn accumulate(offsets: []f32, heights: []const f32) Run {
    std.debug.assert(offsets.len == heights.len + 1);
    var acc: f32 = 0;
    offsets[0] = 0;
    for (heights, 0..) |h, i| {
        acc += @max(0, h);
        offsets[i + 1] = acc;
    }
    return .{ .offsets = offsets };
}

fn ltF32(a: f32, b: f32) std.math.Order {
    return std.math.order(a, b);
}

// -- tests ------------------------------------------------------------------------

const testing = std.testing;

fn runOf(offsets: []f32, heights: []const f32) Run {
    return accumulate(offsets, heights);
}

test "accumulate produces tops and a total" {
    var offsets: [4]f32 = undefined;
    const run = runOf(&offsets, &.{ 10, 20, 5 });
    try testing.expectEqual(@as(usize, 3), run.rows());
    try testing.expectEqual(@as(f32, 0), run.top(0));
    try testing.expectEqual(@as(f32, 10), run.top(1));
    try testing.expectEqual(@as(f32, 30), run.top(2));
    try testing.expectEqual(@as(f32, 35), run.total());
}

test "uniform heights window the same rows a pitch would" {
    var offsets: [101]f32 = undefined;
    const heights: [100]f32 = @splat(10);
    const run = runOf(&offsets, &heights);

    // Viewport covering rows 5..14, no overscan.
    const w = run.window(50, 100, 0);
    try testing.expectEqual(@as(usize, 5), w.lo);
    try testing.expectEqual(@as(usize, 15), w.hi);
    try testing.expectEqual(@as(f32, 50), w.lead);
    try testing.expectEqual(@as(f32, 850), w.tail);
}

test "variable heights pick the rows the viewport actually crosses" {
    // Tops: 0, 100, 110, 120, 220.
    var offsets: [6]f32 = undefined;
    const run = runOf(&offsets, &.{ 100, 10, 10, 100, 10 });

    // A viewport sitting inside the tall first row sees it and whatever follows within reach.
    const w = run.window(50, 20, 0);
    try testing.expectEqual(@as(usize, 0), w.lo);
    try testing.expectEqual(@as(usize, 1), w.hi);
    try testing.expectEqual(@as(f32, 0), w.lead);
    try testing.expectEqual(@as(f32, 130), w.tail);

    // A viewport over the run of short rows sees all three of them.
    const w2 = run.window(100, 25, 0);
    try testing.expectEqual(@as(usize, 1), w2.lo);
    try testing.expectEqual(@as(usize, 4), w2.hi);
}

test "the three parts always add up to the total" {
    var offsets: [51]f32 = undefined;
    var heights: [50]f32 = undefined;
    for (&heights, 0..) |*h, i| h.* = @floatFromInt(4 + (i % 7) * 3);
    const run = runOf(&offsets, &heights);

    var view_top: f32 = -40;
    while (view_top < run.total() + 40) : (view_top += 7) {
        for ([_]f32{ 0, 15, 200 }) |overscan| {
            const w = run.window(view_top, 60, overscan);
            const block = run.top(w.hi) - run.top(w.lo);
            try testing.expectApproxEqAbs(run.total(), w.lead + block + w.tail, 0.001);
            try testing.expect(w.lo <= w.hi);
            try testing.expect(w.hi <= run.rows());
        }
    }
}

test "overscan clamps at both ends rather than running off" {
    var offsets: [11]f32 = undefined;
    const heights: [10]f32 = @splat(10);
    const run = runOf(&offsets, &heights);

    const top = run.window(0, 30, 1000);
    try testing.expectEqual(@as(usize, 0), top.lo);
    try testing.expectEqual(@as(usize, 10), top.hi);
    try testing.expectEqual(@as(f32, 0), top.lead);
    try testing.expectEqual(@as(f32, 0), top.tail);

    const bottom = run.window(70, 30, 1000);
    try testing.expectEqual(@as(usize, 0), bottom.lo);
    try testing.expectEqual(@as(usize, 10), bottom.hi);
}

test "an empty run windows to nothing" {
    var offsets: [1]f32 = undefined;
    const run = runOf(&offsets, &.{});
    try testing.expectEqual(@as(usize, 0), run.rows());
    try testing.expectEqual(@as(f32, 0), run.total());
    const w = run.window(0, 100, 20);
    try testing.expectEqual(@as(usize, 0), w.count());
    try testing.expectEqual(@as(f32, 0), w.lead);
    try testing.expectEqual(@as(f32, 0), w.tail);
}

test "a viewport past the end of the run still accounts for every row" {
    var offsets: [6]f32 = undefined;
    const heights: [5]f32 = @splat(10);
    const run = runOf(&offsets, &heights);
    const w = run.window(500, 40, 0);
    try testing.expectEqual(@as(usize, 0), w.count());
    try testing.expectApproxEqAbs(run.total(), w.lead + w.tail, 0.001);
}

test "zero-height rows do not break the search" {
    var offsets: [6]f32 = undefined;
    const run = runOf(&offsets, &.{ 10, 0, 0, 10, 10 });
    try testing.expectEqual(@as(f32, 30), run.total());
    const w = run.window(10, 5, 0);
    try testing.expect(w.lo <= 3);
    try testing.expect(w.hi >= 1);
    const block = run.top(w.hi) - run.top(w.lo);
    try testing.expectApproxEqAbs(run.total(), w.lead + block + w.tail, 0.001);
}

test "negative heights are clamped instead of corrupting the offsets" {
    var offsets: [4]f32 = undefined;
    const run = runOf(&offsets, &.{ 10, -5, 10 });
    try testing.expectEqual(@as(f32, 20), run.total());
    // Still non-decreasing, which is what every search here assumes.
    for (1..run.offsets.len) |i| try testing.expect(run.offsets[i] >= run.offsets[i - 1]);
}
