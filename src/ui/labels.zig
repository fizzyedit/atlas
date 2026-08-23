//! Graph label placement — which node names get drawn, and where.
//!
//! Nodes sit on a hex lattice, so their *centres* are evenly spread; their *names* are not.
//! "Project Retrospective 2024" is many times wider than the bubble it belongs to, so at any
//! zoom where more than a handful of labels show, the text collides long before the discs do.
//! Growing nodes apart on hover (`graph.updateBubbles`) buys a little room, but it can't fix a
//! label ten times wider than the gap it has to fit into.
//!
//! So placement is greedy, priority-ordered, and allowed to say *no*:
//!
//! 1. Every visible bubble is reserved up front — text never lands on a disc.
//! 2. Visible link segments are remembered too — a name sitting on its own connecting line is
//!    almost as bad as sitting on a bubble, so slots that cross an edge are refused.
//! 3. Candidates are placed in the order the reader wants them (cursor, open docs, proximity,
//!    incumbency, degree — see `graph.labelPriority`).
//! 4. Each tries a short list of anchor slots and takes the first that collides with nothing
//!    already reserved (and no remembered edge). If none fit, that label is suppressed for the
//!    frame.
//! 5. That whole search runs twice: once inside the cloud's own silhouette (`keep_in`), then
//!    against the panel. The camera frames node centres, so without the first pass a long name
//!    on an outermost bubble is the one thing that reaches past the shape the reader reads as
//!    the graph, and a centred cloud looks lopsided.
//!
//! Suppression is the part that actually buys readability: five names you can read beat twenty
//! smeared over each other. The caller fades rather than blinks (`label_vis`) and feeds the
//! previous slot back in as `sticky`, so a settled label doesn't hop sides while its
//! neighbours breathe.
//!
//! The slot list is parity-biased off the node's lattice cell (`slotOrder`), so horizontal
//! neighbours prefer *alternating* distances below their bubble — a sawtooth. That resolves
//! the single most common collision (two names side by side on the same row) up front, with
//! no search and no frame-to-frame instability, because parity is a property of the lattice
//! rather than of who happened to get placed first.
const std = @import("std");
const dvui = @import("dvui");

const Rect = dvui.Rect.Physical;
const Point = dvui.Point.Physical;

/// Anchor positions a label may take relative to its bubble. `_far` sits one label-height
/// further out again.
pub const Slot = enum { below, below_far, above, above_far, right, left };

/// Every slot that touches the bubble is tried before any `_far` one.
///
/// Parity used to separate same-row neighbours by pushing one of them a whole label-height out
/// (`below` against `below_far`), which put the two names on the same side of their nodes at
/// different distances. It reads as a mistake rather than a pattern: one node wears its name
/// and its neighbour's floats in open grid, with nothing between them to explain the gap. The
/// same separation comes free from preferring *opposite* sides — one below, one above — and
/// that keeps both names against their own bubble, which is the thing that says which name
/// belongs to which node.
///
/// The far slots stay as the last resort they should always have been: taken only when all four
/// sides of the bubble are genuinely blocked, which is when a bigger gap is the honest signal
/// that the name had nowhere nearer to go.
const order_even = [_]Slot{ .below, .above, .right, .left, .below_far, .above_far };
const order_odd = [_]Slot{ .above, .below, .left, .right, .above_far, .below_far };

/// Preferred slot order for a node, biased by the parity of its lattice cell so that
/// neighbours on the same row pull apart vertically instead of fighting for the same strip.
pub fn slotOrder(parity: u1) []const Slot {
    return if (parity == 0) &order_even else &order_odd;
}

/// Where a `w`×`h` label lands for a bubble of radius `bubble_r` centred at `anchor`.
pub fn rectFor(anchor: Point, bubble_r: f32, w: f32, h: f32, gap: f32, slot: Slot) Rect {
    const near = bubble_r + gap;
    const far = near + h + gap;
    return switch (slot) {
        .below => .{ .x = anchor.x - w * 0.5, .y = anchor.y + near, .w = w, .h = h },
        .below_far => .{ .x = anchor.x - w * 0.5, .y = anchor.y + far, .w = w, .h = h },
        .above => .{ .x = anchor.x - w * 0.5, .y = anchor.y - near - h, .w = w, .h = h },
        .above_far => .{ .x = anchor.x - w * 0.5, .y = anchor.y - far - h, .w = w, .h = h },
        .right => .{ .x = anchor.x + near, .y = anchor.y - h * 0.5, .w = w, .h = h },
        .left => .{ .x = anchor.x - near - w, .y = anchor.y - h * 0.5, .w = w, .h = h },
    };
}

pub const Placement = struct { slot: Slot, rect: Rect };

/// A link drawn in screen space. Kept as endpoints rather than a fat AABB so a long diagonal
/// doesn't wall off a whole quadrant of the panel from labels that never came near the line.
pub const Segment = struct { a: Point, b: Point };


/// A uniform grid over the panel holding, per cell, the link segments that pass through it.
///
/// The placer's collision test is "does this candidate rect cross a drawn link", and it used to
/// answer that by walking every segment for every slot of every candidate. At the coalesce
/// boundary — the zoom where every note has just resolved and the web is at its densest — that is
/// tens of thousands of segments against a couple of hundred candidates times their slots, so the
/// placer alone ran into the millions of segment/rect tests per frame, on every frame of a pan.
///
/// A label is small, so it covers a handful of cells and only the segments in those need testing.
/// The answer is identical: `segmentHitsRect` still decides, this only decides who it is asked
/// about. Missing a cell would let a name sit on a line, so the walk below is deliberately
/// conservative — per column it takes the segment's exact y-span within that column, widened.
pub const SegGrid = struct {
    bounds: Rect,
    cell: f32,
    cols: u32,
    rows: u32,
    /// `starts[i]..starts[i+1]` indexes `items` for cell `i`.
    starts: []u32,
    items: []u32,

    /// Sized against a label rather than against the panel: a name is roughly 120x24 px, so this
    /// spans a few cells while keeping each cell's segment list short. Larger cells mean fewer
    /// lookups but longer lists, and at the boundary the lists are what hurt. The total is capped
    /// so a very large panel does not turn this into a big allocation.
    const target_cell: f32 = 48;
    const max_cells: u32 = 4096;

    pub fn build(arena: std.mem.Allocator, bounds: Rect, segs: []const Segment) ?SegGrid {
        if (segs.len == 0 or bounds.w <= 0 or bounds.h <= 0) return null;

        var cell = target_cell;
        var cols = spanCells(bounds.w, cell);
        var rows = spanCells(bounds.h, cell);
        while (cols * rows > max_cells) {
            cell *= 2;
            cols = spanCells(bounds.w, cell);
            rows = spanCells(bounds.h, cell);
        }

        const n = cols * rows;
        const starts = arena.alloc(u32, n + 1) catch return null;
        @memset(starts, 0);

        var g: SegGrid = .{
            .bounds = bounds,
            .cell = cell,
            .cols = cols,
            .rows = rows,
            .starts = starts,
            .items = &.{},
        };

        for (segs) |sg| {
            var it = CellWalk.init(&g, sg);
            while (it.next()) |c| starts[c + 1] += 1;
        }
        for (1..n + 1) |i| starts[i] += starts[i - 1];

        const items = arena.alloc(u32, starts[n]) catch return null;
        const cursor = arena.alloc(u32, n) catch return null;
        @memcpy(cursor, starts[0..n]);
        for (segs, 0..) |sg, i| {
            var it = CellWalk.init(&g, sg);
            while (it.next()) |c| {
                items[cursor[c]] = @intCast(i);
                cursor[c] += 1;
            }
        }
        g.items = items;
        return g;
    }

    fn spanCells(extent: f32, cell: f32) u32 {
        return @max(1, @as(u32, @intFromFloat(@ceil(extent / cell))));
    }

    fn colOf(self: SegGrid, x: f32) u32 {
        const i = (x - self.bounds.x) / self.cell;
        if (i < 0) return 0;
        const c: u32 = @intFromFloat(i);
        return @min(c, self.cols - 1);
    }

    fn rowOf(self: SegGrid, y: f32) u32 {
        const i = (y - self.bounds.y) / self.cell;
        if (i < 0) return 0;
        const r: u32 = @intFromFloat(i);
        return @min(r, self.rows - 1);
    }
};

/// The cells one segment passes through, column by column.
const CellWalk = struct {
    g: *const SegGrid,
    seg: Segment,
    /// Clipped to the grid; `done` when the segment never enters it.
    min_x: f32,
    max_x: f32,
    cx: u32,
    cx_end: u32,
    ry: u32,
    ry_end: u32,
    done: bool,

    /// How far the per-column y-span is widened, in pixels. A cell missed here is a name allowed
    /// to sit on a link, so the rounding goes outward.
    const slack: f32 = 2;

    fn init(g: *const SegGrid, seg: Segment) CellWalk {
        var w: CellWalk = .{
            .g = g,
            .seg = seg,
            .min_x = 0,
            .max_x = 0,
            .cx = 0,
            .cx_end = 0,
            .ry = 1,
            .ry_end = 0,
            .done = true,
        };
        const b = g.bounds;
        w.min_x = @max(@min(seg.a.x, seg.b.x), b.x);
        w.max_x = @min(@max(seg.a.x, seg.b.x), b.x + b.w);
        const min_y = @max(@min(seg.a.y, seg.b.y), b.y);
        const max_y = @min(@max(seg.a.y, seg.b.y), b.y + b.h);
        if (w.min_x > w.max_x or min_y > max_y) return w;

        w.done = false;
        // One before the first column: `next` advances and opens, so the walk has a single entry
        // point instead of a special case for the first cell.
        w.cx_end = g.colOf(w.max_x);
        const first = g.colOf(w.min_x);
        if (first == 0) {
            w.cx = 0;
            w.ry = 1;
            w.ry_end = 0;
            if (!w.openColumn()) w.done = true;
            return w;
        }
        w.cx = first - 1;
        w.ry = 1;
        w.ry_end = 0;
        return w;
    }

    fn openColumn(self: *CellWalk) bool {
        if (self.cx > self.cx_end) return false;
        const b = self.g.bounds;
        const x0 = @max(b.x + @as(f32, @floatFromInt(self.cx)) * self.g.cell, self.min_x);
        const x1 = @min(x0 + self.g.cell, self.max_x);

        var y_lo: f32 = undefined;
        var y_hi: f32 = undefined;
        const dx = self.seg.b.x - self.seg.a.x;
        const dy = self.seg.b.y - self.seg.a.y;
        if (@abs(dx) < 1e-6) {
            y_lo = @min(self.seg.a.y, self.seg.b.y);
            y_hi = @max(self.seg.a.y, self.seg.b.y);
        } else {
            const ya = self.seg.a.y + dy * std.math.clamp((x0 - self.seg.a.x) / dx, 0, 1);
            const yb = self.seg.a.y + dy * std.math.clamp((x1 - self.seg.a.x) / dx, 0, 1);
            y_lo = @min(ya, yb);
            y_hi = @max(ya, yb);
        }
        y_lo = @max(y_lo - slack, b.y);
        y_hi = @min(y_hi + slack, b.y + b.h);
        if (y_lo > y_hi) {
            self.cx += 1;
            return self.openColumn();
        }
        self.ry = self.g.rowOf(y_lo);
        self.ry_end = self.g.rowOf(y_hi);
        return true;
    }

    fn next(self: *CellWalk) ?u32 {
        if (self.done) return null;
        while (true) {
            if (self.ry <= self.ry_end) {
                const c = self.ry * self.g.cols + self.cx;
                self.ry += 1;
                return c;
            }
            self.cx += 1;
            if (!self.openColumn()) {
                self.done = true;
                return null;
            }
        }
    }
};

/// Greedy occupancy set for one frame. Linear scan on purpose: the caller caps how much can
/// go in (a viewport only holds so many readable names), and a linear scan over a few hundred
/// rects beats a spatial index that has to be rebuilt every frame anyway.
pub const Placer = struct {
    /// Frame-scratch storage. Capacity *is* the cap on how much can be reserved.
    buf: []Rect,
    n: usize = 0,
    /// Nothing may be placed outside this — labels must not spill out of the panel.
    bounds: Rect,
    /// Breathing room applied to a candidate before testing. Reserved rects are stored raw,
    /// so a pair of labels is separated by `pad` once rather than twice. May be negative to
    /// *tolerate* a little overlap — a text rect is a line box with leading no glyph reaches
    /// into, so rects that graze usually look fine and refusing them costs real names.
    pad: f32,
    /// Link segments in screen space. A candidate whose padded rect crosses one is refused —
    /// same rule as a reserved bubble, just tested geometrically rather than as a rect.
    segs: []const Segment = &.{},
    /// Spatial index over `segs`, when the caller built one. Optional: a small cloud is faster
    /// tested linearly, and the interior view has no gathered web to index.
    seg_grid: ?SegGrid = null,
    /// Half-thickness of the corridor around each segment, in the same space as `pad`.
    seg_pad: f32 = 0,
    /// Retry ignoring links when no slot avoids them. See `place`.
    relax_segments: bool = true,
    /// The cloud's own silhouette, if the caller knows it: a *preferred* limit tried before
    /// `bounds`. The camera frames node centres, not names, so the outermost node's label is the
    /// one thing that can stick out past the shape the reader reads as "the graph" — a long name
    /// on the leftmost bubble runs off toward the pane edge with nothing balancing it on the
    /// right, and the whole cloud looks badly centred even though the nodes are centred exactly.
    ///
    /// Keeping names inside the silhouette fixes that without a feedback loop between placement
    /// and the camera: an edge node simply takes the slot that points *inward* (`right` on the
    /// left flank, `left` on the right flank) instead of the centred one that overhangs.
    keep_in: ?Rect = null,

    pub fn init(buf: []Rect, bounds: Rect, pad: f32) Placer {
        return .{ .buf = buf, .bounds = bounds, .pad = pad };
    }

    pub fn full(self: *const Placer) bool {
        return self.n >= self.buf.len;
    }

    /// Claim `r` unconditionally — used for bubbles, which are drawn whether or not a label
    /// can be fitted around them.
    pub fn reserve(self: *Placer, r: Rect) void {
        if (self.full()) return;
        self.buf[self.n] = r;
        self.n += 1;
    }

    /// True if `r` is inside `bounds` and clear of everything reserved so far.
    pub fn fits(self: *const Placer, r: Rect) bool {
        return self.fitsWithin(r, self.bounds);
    }

    /// `fits`, but against an arbitrary limit — `place` uses it to run the `keep_in` pass.
    fn fitsWithin(self: *const Placer, r: Rect, limit: Rect) bool {
        if (r.x < limit.x or r.y < limit.y) return false;
        if (r.x + r.w > limit.x + limit.w) return false;
        if (r.y + r.h > limit.y + limit.h) return false;
        const padded = r.outsetAll(self.pad);
        for (self.buf[0..self.n]) |o| {
            if (overlaps(o, padded)) return false;
        }
        if (self.segs.len > 0) {
            const against = if (self.seg_pad > 0) padded.outsetAll(self.seg_pad) else padded;
            if (self.seg_grid) |g| {
                // Only the cells the candidate covers. A segment listed in two of them is simply
                // tested twice, which is cheaper than de-duplicating.
                const c0 = g.colOf(against.x);
                const c1 = g.colOf(against.x + against.w);
                const r0 = g.rowOf(against.y);
                const r1 = g.rowOf(against.y + against.h);
                var gy = r0;
                while (gy <= r1) : (gy += 1) {
                    var gx = c0;
                    while (gx <= c1) : (gx += 1) {
                        const cell = gy * g.cols + gx;
                        for (g.items[g.starts[cell]..g.starts[cell + 1]]) |si| {
                            const sg = self.segs[si];
                            if (segmentHitsRect(sg.a, sg.b, against)) return false;
                        }
                    }
                }
            } else {
                for (self.segs) |s| {
                    if (segmentHitsRect(s.a, s.b, against)) return false;
                }
            }
        }
        return true;
    }

    /// Try `sticky` (if given) then `order`, claiming the first slot that fits. Null means
    /// this label has nowhere to go and should be suppressed.
    ///
    /// `sticky` jumps the queue so a label that already found a home keeps it as long as it
    /// remains legal — re-running the preference order every frame would make labels flip
    /// sides the moment a higher-priority neighbour shifted a few pixels.
    ///
    /// When `keep_in` is set the whole order is tried against it first and only then against
    /// `bounds`. Demoting it to a preference rather than a hard limit is deliberate: a cloud of
    /// one or two nodes has a silhouette narrower than a single name, and a hard limit there
    /// would suppress every label in the vault to fix a problem that only exists once there is
    /// enough of a cloud to look off-centre.
    pub fn place(
        self: *Placer,
        anchor: Point,
        bubble_r: f32,
        w: f32,
        h: f32,
        gap: f32,
        order: []const Slot,
        sticky: ?Slot,
    ) ?Placement {
        if (self.full()) return null;
        if (self.keep_in) |inner| {
            // Intersected, never substituted: a cloud zoomed past the pane edges has a
            // silhouette wider than the panel, and the first pass must not be a way around
            // `bounds`.
            const limit = clip(inner, self.bounds);
            if (limit.w > 0 and limit.h > 0) {
                if (self.tryOrder(anchor, bubble_r, w, h, gap, order, sticky, limit)) |got| return got;
            }
        }
        if (self.tryOrder(anchor, bubble_r, w, h, gap, order, sticky, self.bounds)) |got| return got;

        // Last resort: allow the name to cross a link. A node in the middle of an island or a
        // dense nest is ringed by edges on every side, so every slot collides and it never gets a
        // name at any zoom — the label is suppressed to protect a line the reader can still see
        // perfectly well underneath it. Discs and other labels stay hard constraints, since those
        // genuinely make a name unreadable; a line does not.
        if (self.relax_segments and self.segs.len > 0) {
            const saved = self.segs;
            self.segs = &.{};
            defer self.segs = saved;
            // `fitsWithin` gates on `segs`, so the index goes quiet with it — left in place so the
            // restore is one assignment and cannot get out of step with the segment list.
            return self.tryOrder(anchor, bubble_r, w, h, gap, order, sticky, self.bounds);
        }
        return null;
    }

    fn tryOrder(
        self: *Placer,
        anchor: Point,
        bubble_r: f32,
        w: f32,
        h: f32,
        gap: f32,
        order: []const Slot,
        sticky: ?Slot,
        limit: Rect,
    ) ?Placement {
        if (sticky) |s| {
            const r = rectFor(anchor, bubble_r, w, h, gap, s);
            if (self.fitsWithin(r, limit)) {
                self.reserve(r);
                return .{ .slot = s, .rect = r };
            }
        }
        for (order) |s| {
            if (sticky != null and sticky.? == s) continue;
            const r = rectFor(anchor, bubble_r, w, h, gap, s);
            if (self.fitsWithin(r, limit)) {
                self.reserve(r);
                return .{ .slot = s, .rect = r };
            }
        }
        return null;
    }
};

fn clip(a: Rect, b: Rect) Rect {
    const x0 = @max(a.x, b.x);
    const y0 = @max(a.y, b.y);
    const x1 = @min(a.x + a.w, b.x + b.w);
    const y1 = @min(a.y + a.h, b.y + b.h);
    return .{ .x = x0, .y = y0, .w = @max(0, x1 - x0), .h = @max(0, y1 - y0) };
}

fn overlaps(a: Rect, b: Rect) bool {
    return !(a.x + a.w <= b.x or b.x + b.w <= a.x or
        a.y + a.h <= b.y or b.y + b.h <= a.y);
}

/// True when the open segment `a→b` intersects the interior of `r` (or passes through a
/// corner). Separating-axis style: project the segment onto the rect's axes and reject when
/// the closest point on the segment lies outside. Endpoints on the boundary count as a hit —
/// a label whose edge kisses a link still reads as sitting on it.
fn segmentHitsRect(a: Point, b: Point, r: Rect) bool {
    // Either endpoint inside → definite hit.
    if (pointInRect(a, r) or pointInRect(b, r)) return true;
    // Liang–Barsky against the four sides: if the clipped parameter range is non-empty the
    // segment crosses the rect.
    var t0: f32 = 0;
    var t1: f32 = 1;
    const dx = b.x - a.x;
    const dy = b.y - a.y;
    if (!clipEdge(-dx, a.x - r.x, &t0, &t1)) return false; // left
    if (!clipEdge(dx, r.x + r.w - a.x, &t0, &t1)) return false; // right
    if (!clipEdge(-dy, a.y - r.y, &t0, &t1)) return false; // top
    if (!clipEdge(dy, r.y + r.h - a.y, &t0, &t1)) return false; // bottom
    return true;
}

fn clipEdge(p: f32, q: f32, t0: *f32, t1: *f32) bool {
    if (@abs(p) < 1e-8) return q >= 0; // parallel: outside if q < 0
    const t = q / p;
    if (p < 0) {
        if (t > t1.*) return false;
        if (t > t0.*) t0.* = t;
    } else {
        if (t < t0.*) return false;
        if (t < t1.*) t1.* = t;
    }
    return true;
}

fn pointInRect(p: Point, r: Rect) bool {
    return p.x >= r.x and p.x <= r.x + r.w and p.y >= r.y and p.y <= r.y + r.h;
}

// -- tests ------------------------------------------------------------------------

const testing = std.testing;

const big_bounds: Rect = .{ .x = -1000, .y = -1000, .w = 2000, .h = 2000 };

test "the segment grid accepts and rejects exactly what a linear walk does" {
    // The index only decides *which* segments `segmentHitsRect` is asked about, so any disagreement
    // is a cell the walk failed to visit — which shows up as a label sitting on a link, and only at
    // the zooms where the web is dense enough for the index to be used at all.
    var rng = std.Random.DefaultPrng.init(0x5117);
    const r = rng.random();
    const gpa = testing.allocator;

    const bounds: Rect = .{ .x = -37, .y = 11, .w = 1200, .h = 700 };
    const segs = try gpa.alloc(Segment, 900);
    defer gpa.free(segs);
    for (segs) |*sg| {
        // A mix of short local links and long ones running well off the panel, which is what the
        // per-column walk has to get right.
        const ax = bounds.x + r.float(f32) * bounds.w;
        const ay = bounds.y + r.float(f32) * bounds.h;
        const reach: f32 = if (r.boolean()) 60 else 1800;
        sg.* = .{
            .a = .{ .x = ax, .y = ay },
            .b = .{
                .x = ax + (r.float(f32) * 2 - 1) * reach,
                .y = ay + (r.float(f32) * 2 - 1) * reach,
            },
        };
    }

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const grid = SegGrid.build(arena_state.allocator(), bounds, segs) orelse return error.NoGrid;

    var buf: [1]Rect = undefined;
    var linear = Placer.init(buf[0..0], bounds, 2);
    linear.segs = segs;
    linear.seg_pad = 3;
    var indexed = linear;
    indexed.seg_grid = grid;

    var disagreements: usize = 0;
    for (0..20_000) |_| {
        const w = 20 + r.float(f32) * 160;
        const h = 12 + r.float(f32) * 20;
        const q: Rect = .{
            .x = bounds.x + r.float(f32) * (bounds.w - w),
            .y = bounds.y + r.float(f32) * (bounds.h - h),
            .w = w,
            .h = h,
        };
        if (linear.fits(q) != indexed.fits(q)) disagreements += 1;
    }
    try testing.expectEqual(@as(usize, 0), disagreements);
}

test "slots are centred on / clear of the bubble" {
    const anchor: Point = .{ .x = 100, .y = 100 };
    const below = rectFor(anchor, 10, 60, 14, 3, .below);
    try testing.expectApproxEqAbs(@as(f32, 70), below.x, 1e-4); // horizontally centred
    try testing.expectApproxEqAbs(@as(f32, 113), below.y, 1e-4); // clears r + gap

    const above = rectFor(anchor, 10, 60, 14, 3, .above);
    try testing.expectApproxEqAbs(@as(f32, 100 - 13 - 14), above.y, 1e-4);

    // Sides are vertically centred on the bubble.
    const right = rectFor(anchor, 10, 60, 14, 3, .right);
    try testing.expectApproxEqAbs(@as(f32, 113), right.x, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 93), right.y, 1e-4);
}

test "far slots clear the near ones they share a side with" {
    const anchor: Point = .{ .x = 0, .y = 0 };
    const near = rectFor(anchor, 10, 60, 14, 3, .below);
    const far = rectFor(anchor, 10, 60, 14, 3, .below_far);
    try testing.expect(!overlaps(near, far));
    try testing.expect(far.y > near.y);
}

test "second label takes another slot rather than stacking" {
    var buf: [16]Rect = undefined;
    var p = Placer.init(&buf, big_bounds, 2);

    // Two nodes close enough that their labels cannot both sit directly below.
    const a = p.place(.{ .x = 0, .y = 0 }, 8, 80, 14, 3, slotOrder(0), null).?;
    const b = p.place(.{ .x = 20, .y = 0 }, 8, 80, 14, 3, slotOrder(0), null).?;
    try testing.expectEqual(Slot.below, a.slot);
    try testing.expect(b.slot != .below);
    try testing.expect(!overlaps(a.rect, b.rect));
}

test "opposite parity neighbours separate without either being pushed far out" {
    // Same-row neighbours resolve to opposite sides of their own bubbles, not to the same side
    // at two different distances. Both names stay against the bubble they name, which is what
    // says which one they belong to — a label floating a whole label-height out in open grid
    // reads as a mistake rather than as the other tooth of a pattern.
    var buf: [16]Rect = undefined;
    var p = Placer.init(&buf, big_bounds, 2);
    const a = p.place(.{ .x = 0, .y = 0 }, 8, 80, 14, 3, slotOrder(0), null).?;
    const b = p.place(.{ .x = 40, .y = 0 }, 8, 80, 14, 3, slotOrder(1), null).?;
    try testing.expectEqual(Slot.below, a.slot);
    try testing.expectEqual(Slot.above, b.slot);
    try testing.expect(!overlaps(a.rect, b.rect));
}

test "a far slot is only taken when every near one is blocked" {
    var buf: [16]Rect = undefined;
    var p = Placer.init(&buf, big_bounds, 0);
    // Wall off all four sides of the bubble.
    for ([_]Slot{ .below, .above, .right, .left }) |s| {
        p.reserve(rectFor(.{ .x = 0, .y = 0 }, 8, 80, 14, 3, s));
    }
    const got = p.place(.{ .x = 0, .y = 0 }, 8, 80, 14, 3, slotOrder(0), null).?;
    try testing.expect(got.slot == .below_far or got.slot == .above_far);

    // And with room beside the bubble, the far slots stay unused.
    var buf2: [16]Rect = undefined;
    var p2 = Placer.init(&buf2, big_bounds, 0);
    p2.reserve(rectFor(.{ .x = 0, .y = 0 }, 8, 80, 14, 3, .below));
    const near = p2.place(.{ .x = 0, .y = 0 }, 8, 80, 14, 3, slotOrder(0), null).?;
    try testing.expect(near.slot != .below_far and near.slot != .above_far);
}

test "reserved bubbles block labels" {
    var buf: [16]Rect = undefined;
    var p = Placer.init(&buf, big_bounds, 0);
    // A bubble sitting exactly where the `below` slot would land.
    p.reserve(rectFor(.{ .x = 0, .y = 0 }, 8, 80, 14, 3, .below));
    const got = p.place(.{ .x = 0, .y = 0 }, 8, 80, 14, 3, slotOrder(0), null).?;
    try testing.expect(got.slot != .below);
}

test "nothing is placed outside the bounds" {
    var buf: [16]Rect = undefined;
    // Bounds only tall enough for the bubble itself — no slot can fit.
    var p = Placer.init(&buf, .{ .x = -10, .y = -10, .w = 20, .h = 20 }, 0);
    try testing.expect(p.place(.{ .x = 0, .y = 0 }, 8, 80, 14, 3, slotOrder(0), null) == null);
}

test "sticky slot wins over the preference order" {
    var buf: [16]Rect = undefined;
    var p = Placer.init(&buf, big_bounds, 2);
    const got = p.place(.{ .x = 0, .y = 0 }, 8, 80, 14, 3, slotOrder(0), .above).?;
    try testing.expectEqual(Slot.above, got.slot);
}

test "a full placer suppresses rather than overlapping" {
    var buf: [1]Rect = undefined;
    var p = Placer.init(&buf, big_bounds, 2);
    _ = p.place(.{ .x = 0, .y = 0 }, 8, 80, 14, 3, slotOrder(0), null).?;
    try testing.expect(p.full());
    try testing.expect(p.place(.{ .x = 300, .y = 300 }, 8, 80, 14, 3, slotOrder(0), null) == null);
}

test "negative pad tolerates a graze but not a real collision" {
    var buf: [16]Rect = undefined;
    var p = Placer.init(&buf, big_bounds, -2);
    const a = p.place(.{ .x = 0, .y = 0 }, 8, 80, 14, 3, slotOrder(0), null).?;
    try testing.expectEqual(Slot.below, a.slot);

    // Overlapping by less than the tolerance is allowed through...
    const graze = rectFor(.{ .x = 0, .y = 13 }, 8, 80, 14, 3, .below);
    try testing.expect(overlaps(a.rect, graze));
    try testing.expect(p.fits(graze));

    // ...but a rect sitting squarely on top of it is still refused.
    try testing.expect(!p.fits(a.rect));
}

test "placed labels never overlap each other" {
    // Property check over a dense grid — the guarantee the draw pass relies on.
    var buf: [256]Rect = undefined;
    var p = Placer.init(&buf, big_bounds, 2);
    var placed: [64]Rect = undefined;
    var n: usize = 0;
    for (0..8) |gy| {
        for (0..8) |gx| {
            const x: f32 = @as(f32, @floatFromInt(gx)) * 30 - 100;
            const y: f32 = @as(f32, @floatFromInt(gy)) * 30 - 100;
            const parity: u1 = @intCast((gx + gy) & 1);
            const got = p.place(.{ .x = x, .y = y }, 8, 70, 14, 3, slotOrder(parity), null) orelse continue;
            placed[n] = got.rect;
            n += 1;
        }
    }
    try testing.expect(n > 0);
    for (placed[0..n], 0..) |a, i| {
        for (placed[0..n], 0..) |b, j| {
            if (i == j) continue;
            try testing.expect(!overlaps(a, b));
        }
    }
}

test "a flank node's name turns inward rather than overhanging the cloud" {
    // Cloud silhouette spanning x∈[0,200]; the node sits on its left edge. A centred name would
    // hang 40px out into empty pane, so the inward slot is taken instead.
    var buf: [16]Rect = undefined;
    var p = Placer.init(&buf, big_bounds, 2);
    p.keep_in = .{ .x = 0, .y = -100, .w = 200, .h = 200 };
    const got = p.place(.{ .x = 0, .y = 0 }, 8, 80, 14, 3, slotOrder(0), null).?;
    try testing.expectEqual(Slot.right, got.slot);
    try testing.expect(got.rect.x >= 0);
    try testing.expect(got.rect.x + got.rect.w <= 200);
}

test "keep_in is a preference, not a suppression" {
    // A silhouette narrower than the name itself — a one-node vault. Every slot fails the inner
    // pass, so placement falls back to the panel bounds rather than dropping the only label.
    var buf: [16]Rect = undefined;
    var p = Placer.init(&buf, big_bounds, 2);
    p.keep_in = .{ .x = -10, .y = -10, .w = 20, .h = 20 };
    const got = p.place(.{ .x = 0, .y = 0 }, 8, 80, 14, 3, slotOrder(0), null).?;
    try testing.expectEqual(Slot.below, got.slot);
}

test "keep_in never places outside bounds" {
    // A silhouette wider than the panel must not smuggle a label past the panel edge.
    var buf: [16]Rect = undefined;
    var p = Placer.init(&buf, .{ .x = 0, .y = 0, .w = 100, .h = 100 }, 0);
    p.keep_in = .{ .x = -500, .y = -500, .w = 1000, .h = 1000 };
    const got = p.place(.{ .x = 50, .y = 50 }, 8, 80, 14, 3, slotOrder(0), null).?;
    try testing.expect(got.rect.x >= 0 and got.rect.x + got.rect.w <= 100);
    try testing.expect(got.rect.y >= 0 and got.rect.y + got.rect.h <= 100);
}

test "a label refuses a slot that crosses a link" {
    // Bubble at the origin with a horizontal link running right through where `below` lands.
    var buf: [16]Rect = undefined;
    var p = Placer.init(&buf, big_bounds, 0);
    const segs = [_]Segment{.{ .a = .{ .x = -40, .y = 20 }, .b = .{ .x = 40, .y = 20 } }};
    p.segs = &segs;
    p.seg_pad = 2;
    const got = p.place(.{ .x = 0, .y = 0 }, 8, 60, 14, 3, slotOrder(0), null).?;
    try testing.expect(got.slot != .below);
    try testing.expect(!segmentHitsRect(segs[0].a, segs[0].b, got.rect.outsetAll(2)));
}

test "segmentHitsRect catches a diagonal through the box" {
    const r: Rect = .{ .x = 0, .y = 0, .w = 10, .h = 10 };
    try testing.expect(segmentHitsRect(.{ .x = -1, .y = -1 }, .{ .x = 11, .y = 11 }, r));
    try testing.expect(!segmentHitsRect(.{ .x = -1, .y = -1 }, .{ .x = -1, .y = 11 }, r));
    try testing.expect(segmentHitsRect(.{ .x = 5, .y = 5 }, .{ .x = 20, .y = 20 }, r));
}
