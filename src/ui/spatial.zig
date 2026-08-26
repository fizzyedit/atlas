//! A drawing hierarchy built *from* positions, rather than positions built from a hierarchy.
//!
//! This is the other half of the inversion described in `docs/design/`. `fold.zig` groups notes by
//! links and `containment.zig` then places each cell's children inside the parent's disc, so a
//! note's position is a by-product of the tree. That has two measured consequences: sibling cells
//! overlap 38.7% of the time on the reference corpus (so two notes that look adjacent usually
//! belong to different masses), and a note's largest single level-jump averages a third of the
//! vault radius (so zooming toward one means watching it fly off screen).
//!
//! Here the leaf positions are given. This file only decides *which* notes get drawn together when
//! there are too many to draw at once, and it decides it the way a map does — by proximity.
//!
//! Two properties follow by construction, and they are the whole point:
//!
//!   * **A cell's disc contains its children's discs.** The bound is `max over children of
//!     (distance + child bound)`, so containment is arithmetic rather than a clamp that has to be
//!     enforced and can be violated. `world.restOnScreen` culls whole branches on this and never
//!     revisits them, so it needs a true bound, not a stand-in for one.
//!   * **A cell's radius never changes.** Computed once per rebuild and read from an array. Today
//!     a closed cell reports an estimate and an open one reports a settled bound, so opening a cell
//!     changes its own radius — which is the split/merge oscillation `wantsSplit` has to be
//!     protected from by flooring the settled value at the estimate. That whole mechanism goes.
//!
//! ## Why a space-filling curve and not a k-d tree
//!
//! A recursive median split gives a genuine partition into near-square tiles, and squares bound
//! more tightly than the elongated windows a curve produces — so on overlap alone it wins. It
//! loses on the property that matters more here: a median is a *global* statistic, so one note
//! moving across it re-partitions an entire subtree. Under an incremental layout, where a save
//! perturbs a handful of notes and must not reshuffle the map, that is the wrong shape.
//!
//! A Hilbert key is a pure function of one note's own position. One note moves, one key changes.
//! The usual objection — that cutting every `arity` positions puts boundaries at arbitrary places,
//! and an insert shifts every run after it — is answered by cutting where the data already has a
//! gap, the same trick content-defined chunking uses for deduplication. Boundaries land between
//! clusters instead of through them, and they stay local.
//!
//! Morton order is not an option: its quadrant jumps mean a run can straddle two distant clumps
//! and bound everything in between, which is precisely the pathology being removed.

const std = @import("std");
const fold = @import("fold.zig");
const radix = @import("radix.zig");

pub const Vec2 = struct { x: f32 = 0, y: f32 = 0 };

pub const Options = struct {
    arity: fold.Arity = .seven,
    /// Drawn radius of a single note, in world units. A leaf's bound is this rather than zero:
    /// `restOnScreen` culls on the bound, and a leaf whose bound is zero is culled the moment its
    /// centre leaves the viewport even though the mark drawn for it still overlaps the edge.
    note_r: f32 = 1.0,
    /// The world square the Hilbert grid quantises against.
    ///
    /// Deliberately *not* the current bounding box. Keyed against their own extent, one new
    /// outlier note renumbers every key in the vault and the entire hierarchy churns — which would
    /// defeat the incremental design this exists to serve. The caller persists this and widens it
    /// only when a position falls outside.
    quant_centre: Vec2 = .{},
    quant_half: f32 = 1.0,
};

/// The hierarchy, plus the bound that `containment.Field.radius` becomes a lookup into.
pub const Result = struct {
    lad: fold.Ladder = .{},
    /// Per cell: the true bounding radius of everything beneath it.
    bound_r: []f32 = &.{},
    /// Per cell: the centroid of everything beneath it.
    pos: []Vec2 = &.{},

    pub fn deinit(self: *Result, gpa: std.mem.Allocator) void {
        self.lad.deinit(gpa);
        gpa.free(self.bound_r);
        gpa.free(self.pos);
        self.* = .{};
    }
};

/// Bits per Hilbert axis. 16 gives a 65,536² grid, finer than any vault's note count, so the order
/// is decided by the positions rather than by grid collisions.
const axis_bits: u5 = 16;
const axis_n: u32 = @as(u32, 1) << axis_bits;

pub fn build(
    gpa: std.mem.Allocator,
    n_notes: usize,
    pos: []const Vec2,
    /// Per note: which connected component it belongs to. Runs never straddle one.
    ///
    /// This is the guarantee `fold.Cell.comp` used to enforce during coarsening, and it has to be
    /// kept: a mass that mixes two unconnected islands is the "discrete islands read as one
    /// converging blob" failure. Grouping by proximity cannot enforce it on its own, because the
    /// layout is free to place two unrelated islands near each other — so the layout is expected
    /// to pack components as disjoint discs, and this is the belt to that's braces.
    comp: []const u32,
    /// Per note: incident link count, and file size. Summed up the tree for `Cell.weight`/`.body`.
    weight: []const f32,
    body: []const f32,
    opts: Options,
) !Result {
    var res: Result = .{};
    errdefer res.deinit(gpa);
    if (n_notes == 0) return res;

    const arity = opts.arity.n();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // ---- order the notes along the curve, component-major ------------------------------------
    const keyed = try arena.alloc(Keyed, n_notes);
    for (keyed, 0..) |*k, i| {
        const g = quantise(pos[i], opts);
        // Component in the high bits so a run can never straddle one, then the curve, then the
        // note id so equal positions still order deterministically.
        k.* = .{
            .key = (@as(u64, comp[i]) << 44) | (@as(u64, hilbert(g.x, g.y)) << 12) | (i & 0xfff),
            .note = @intCast(i),
        };
    }
    const scratch = try arena.alloc(Keyed, n_notes);
    const sorted = radix.sortByKey(Keyed, keyOf, keyed, scratch);

    // ---- level 0: one leaf per note, in curve order -------------------------------------------
    //
    // `note_at` *is* the curve order and a cell's `[ls, le)` *is* its run, so the note-range
    // machinery `world.present` uses for the open-note pin keeps working with no changes.
    var cells: std.ArrayListUnmanaged(fold.Cell) = .empty;
    errdefer cells.deinit(gpa);
    var children: std.ArrayListUnmanaged(u32) = .empty;
    errdefer children.deinit(gpa);

    const note_at = try gpa.alloc(u32, n_notes);
    errdefer gpa.free(note_at);
    const slot_of = try gpa.alloc(u32, n_notes);
    errdefer gpa.free(slot_of);
    const leaf_cell = try gpa.alloc(u32, n_notes);
    errdefer gpa.free(leaf_cell);

    var cur = try arena.alloc(u32, n_notes);
    for (sorted, 0..) |k, slot| {
        note_at[slot] = k.note;
        slot_of[k.note] = @intCast(slot);
        leaf_cell[k.note] = @intCast(cells.items.len);
        cur[slot] = @intCast(cells.items.len);
        try cells.append(gpa, .{
            .count = 1,
            .note = k.note,
            .comp = comp[k.note],
            .weight = weight[k.note],
            .body = body[k.note],
            .ls = @intCast(slot),
            .le = @intCast(slot + 1),
        });
    }

    // ---- chunk upward -------------------------------------------------------------------------
    var level_pos = try arena.alloc(Vec2, n_notes);
    for (sorted, 0..) |k, i| level_pos[i] = pos[k.note];

    var depth: u16 = 0;
    while (cur.len > 1 and depth < 64) {
        const next = try chunkLevel(gpa, arena, &cells, &children, cur, level_pos, arity);
        if (next.cells.len >= cur.len) break; // no progress; a component of one, say
        cur = next.cells;
        level_pos = next.pos;
        depth += 1;
    }

    // ---- roots, then the bottom-up bound ------------------------------------------------------
    res.lad = .{
        .cells = try cells.toOwnedSlice(gpa),
        .children = try children.toOwnedSlice(gpa),
        .leaf_cell = leaf_cell,
        .note_at = note_at,
        .slot_of = slot_of,
        .roots = try gpa.dupe(u32, cur),
        .depth = depth,
    };
    for (res.lad.roots) |r| res.lad.cells[r].parent = fold.invalid;

    res.pos = try gpa.alloc(Vec2, res.lad.cells.len);
    res.bound_r = try gpa.alloc(f32, res.lad.cells.len);
    settle(&res, pos, opts.note_r);
    return res;
}

/// One note's place on the curve, plus which note it is. `radix.sortByKey` wants a concrete
/// `fn(T) u64`, so both live at file scope.
const Keyed = struct { key: u64, note: u32 };

fn keyOf(k: Keyed) u64 {
    return k.key;
}

/// Median distance between notes that are adjacent along the curve, **within one component**.
///
/// A stand-in for median nearest-neighbour distance — curve-adjacent is an upper bound on it and
/// close, and it costs the sort this file already does rather than a spatial query. Island jumps
/// are skipped: component-major order puts a packing gap between islands, and that gap is the
/// distance the packer chose, not a leaf spacing.
///
/// This is the number that decides whether any grouping can produce non-overlapping cells. Two
/// notes drawn at radius `r` overlap whenever they sit closer than `2r`, so a layout whose median
/// spacing is below `2·note_r` has already lost — the leaves overlap before the hierarchy sees
/// them, and bounding runs of them only compounds it. Measured at 0.95x on the containment layout.
pub fn medianSpacing(gpa: std.mem.Allocator, pos: []const Vec2, comp: []const u32) !f32 {
    if (pos.len < 2) return 0;
    // The quantisation grid is derived from the points rather than taken from the caller. It is
    // only ever a means to a curve order here, and a grid that does not match the cloud puts every
    // point in one cell — which silently returns a meaningless number instead of failing.
    var opts: Options = .{};
    var half: f32 = 1e-6;
    for (pos) |p| half = @max(half, @max(@abs(p.x), @abs(p.y)));
    opts.quant_half = half;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const keyed = try arena.alloc(Keyed, pos.len);
    for (keyed, 0..) |*k, i| {
        const g = quantise(pos[i], opts);
        k.* = .{
            .key = (@as(u64, comp[i]) << 44) | (@as(u64, hilbert(g.x, g.y)) << 12) | (i & 0xfff),
            .note = @intCast(i),
        };
    }
    const scratch = try arena.alloc(Keyed, pos.len);
    const sorted = radix.sortByKey(Keyed, keyOf, keyed, scratch);

    const gaps = try arena.alloc(f32, sorted.len - 1);
    var n_gaps: usize = 0;
    for (1..sorted.len) |i| {
        // Component-major order puts a packing jump between islands. That gap is the distance
        // the packer chose, not a leaf spacing, and folding it into the median is how a vault
        // of many small islands reported a huge "leaf" pitch and then scaled its clusters away.
        if (comp[sorted[i].note] != comp[sorted[i - 1].note]) continue;
        gaps[n_gaps] = dist(pos[sorted[i - 1].note], pos[sorted[i].note]);
        n_gaps += 1;
    }
    if (n_gaps == 0) return 0;
    std.mem.sort(f32, gaps[0..n_gaps], {}, std.sort.asc(f32));
    return gaps[n_gaps / 2];
}

const LevelResult = struct { cells: []u32, pos: []Vec2 };

/// One level of chunking: runs of `[arity/2, arity]` cells, cut where the data has a gap.
///
/// A fixed run of `arity` puts every boundary at a multiple of the arity, which is a property of
/// the index rather than of the map — so a run straddles two clusters as readily as it covers one,
/// and the bounding circle then spans the space between them. Choosing the cut inside a window
/// costs one pass and puts boundaries where the notes are already apart.
fn chunkLevel(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    cells: *std.ArrayListUnmanaged(fold.Cell),
    children: *std.ArrayListUnmanaged(u32),
    cur: []const u32,
    cur_pos: []const Vec2,
    arity: usize,
) !LevelResult {
    const m = cur.len;
    const min_run = @max(2, arity / 2);

    var out: std.ArrayListUnmanaged(u32) = .empty;
    var out_pos: std.ArrayListUnmanaged(Vec2) = .empty;

    var i: usize = 0;
    while (i < m) {
        const this_comp = cells.items[cur[i]].comp;
        // How far the window may reach: `arity` cells, or the end of this component.
        var hi = @min(i + arity, m);
        var j = i + 1;
        while (j < hi) : (j += 1) {
            if (cells.items[cur[j]].comp != this_comp) {
                hi = j;
                break;
            }
        }

        var cut = hi;
        if (hi - i > min_run and hi < m and cells.items[cur[hi]].comp == this_comp) {
            // Only worth choosing when there is more of this component to come; otherwise the run
            // ends here regardless and the widest gap inside it is not a boundary.
            var best_gap: f32 = -1;
            var c = i + min_run;
            while (c <= hi) : (c += 1) {
                const g = dist(cur_pos[c - 1], cur_pos[@min(c, m - 1)]);
                if (g > best_gap) {
                    best_gap = g;
                    cut = c;
                }
            }
        }

        const start: u32 = @intCast(children.items.len);
        const id: u32 = @intCast(cells.items.len);
        var sum: u32 = 0;
        var w: f32 = 0;
        var b: f32 = 0;
        var k = i;
        while (k < cut) : (k += 1) {
            const child = cur[k];
            cells.items[child].parent = id;
            sum += cells.items[child].count;
            w += cells.items[child].weight;
            b += cells.items[child].body;
            try children.append(gpa, child);
        }
        try cells.append(gpa, .{
            .count = sum,
            .weight = w,
            .body = b,
            .comp = this_comp,
            .child_start = start,
            .child_count = @intCast(cut - i),
            .ls = cells.items[cur[i]].ls,
            .le = cells.items[cur[cut - 1]].le,
        });

        // The parent's provisional position is the count-weighted mean of its children, which is
        // what the next level chunks against. `settle` recomputes it exactly afterwards.
        var cx: f32 = 0;
        var cy: f32 = 0;
        var tot: f32 = 0;
        k = i;
        while (k < cut) : (k += 1) {
            const cw: f32 = @floatFromInt(@max(1, cells.items[cur[k]].count));
            cx += cur_pos[k].x * cw;
            cy += cur_pos[k].y * cw;
            tot += cw;
        }
        try out.append(arena, id);
        try out_pos.append(arena, .{ .x = cx / tot, .y = cy / tot });
        i = cut;
    }

    return .{ .cells = out.items, .pos = out_pos.items };
}

/// Centroid and true bound for every cell, leaves upward.
///
/// Cells are appended leaves first, then each level of parents above it, so a single *forward*
/// pass sees every child before its parent.
fn settle(res: *Result, note_pos: []const Vec2, note_r: f32) void {
    const cells = res.lad.cells;
    for (0..cells.len) |i| {
        const c = cells[i];
        if (c.child_count == 0) {
            res.pos[i] = if (c.note != fold.invalid) note_pos[c.note] else .{};
            res.bound_r[i] = note_r;
            continue;
        }
        var cx: f32 = 0;
        var cy: f32 = 0;
        var tot: f32 = 0;
        for (res.lad.childrenOf(@intCast(i))) |k| {
            const w: f32 = @floatFromInt(@max(1, cells[k].count));
            cx += res.pos[k].x * w;
            cy += res.pos[k].y * w;
            tot += w;
        }
        const centre: Vec2 = .{ .x = cx / tot, .y = cy / tot };
        res.pos[i] = centre;

        // The bound that makes `restOnScreen` exact: far enough to cover every child's own disc.
        var r: f32 = 0;
        for (res.lad.childrenOf(@intCast(i))) |k| {
            r = @max(r, dist(centre, res.pos[k]) + res.bound_r[k]);
        }
        res.bound_r[i] = r;
    }
}

fn dist(a: Vec2, b: Vec2) f32 {
    const dx = a.x - b.x;
    const dy = a.y - b.y;
    return @sqrt(dx * dx + dy * dy);
}

fn quantise(p: Vec2, opts: Options) struct { x: u32, y: u32 } {
    const half = @max(opts.quant_half, 1e-6);
    const fx = (p.x - opts.quant_centre.x) / half * 0.5 + 0.5;
    const fy = (p.y - opts.quant_centre.y) / half * 0.5 + 0.5;
    const span: f32 = @floatFromInt(axis_n - 1);
    return .{
        .x = @intFromFloat(std.math.clamp(fx, 0, 1) * span),
        .y = @intFromFloat(std.math.clamp(fy, 0, 1) * span),
    };
}

/// Distance along a Hilbert curve of `axis_bits` order — the textbook `xy2d`, which rotates
/// against the full side length rather than the current quadrant size.
fn hilbert(x_in: u32, y_in: u32) u32 {
    var x = x_in;
    var y = y_in;
    var d: u32 = 0;
    var s: u32 = axis_n / 2;
    while (s > 0) : (s /= 2) {
        const rx: u32 = if ((x & s) > 0) 1 else 0;
        const ry: u32 = if ((y & s) > 0) 1 else 0;
        d +%= s *% s *% ((3 * rx) ^ ry);
        if (ry == 0) {
            if (rx == 1) {
                x = axis_n - 1 - x;
                y = axis_n - 1 - y;
            }
            const t = x;
            x = y;
            y = t;
        }
    }
    return d;
}

// ---- tests ------------------------------------------------------------------------------------

const testing = std.testing;

/// A grid of `side²` notes, one component, unit spacing.
fn gridVault(gpa: std.mem.Allocator, side: u32) ![]Vec2 {
    const p = try gpa.alloc(Vec2, side * side);
    for (0..side) |gy| {
        for (0..side) |gx| {
            p[gy * side + gx] = .{ .x = @floatFromInt(gx), .y = @floatFromInt(gy) };
        }
    }
    return p;
}

fn buildGrid(gpa: std.mem.Allocator, side: u32) !Result {
    const p = try gridVault(gpa, side);
    defer gpa.free(p);
    const n = p.len;
    const comp = try gpa.alloc(u32, n);
    defer gpa.free(comp);
    @memset(comp, 0);
    const w = try gpa.alloc(f32, n);
    defer gpa.free(w);
    @memset(w, 1);
    const half: f32 = @floatFromInt(side);
    return build(gpa, n, p, comp, w, w, .{
        // Well under half the grid step, so two adjacent notes do not overlap merely by being
        // adjacent. The real system calibrates this the same way — `note_r` is derived from the
        // lattice spacing — and if it ever exceeds half the spacing then *every* neighbouring pair
        // overlaps and no chunker can help.
        .note_r = 0.4,
        .quant_centre = .{ .x = half / 2, .y = half / 2 },
        .quant_half = half,
    });
}

test "a cell's disc contains its children's discs" {
    // The invariant `world.restOnScreen` rests on. It culls a whole branch on the parent's bound
    // and never revisits it, so a child reaching outside that bound is a note that silently cannot
    // be drawn. Here it is arithmetic rather than a clamp, so this should hold exactly.
    const gpa = testing.allocator;
    var res = try buildGrid(gpa, 40);
    defer res.deinit(gpa);

    for (res.lad.cells, 0..) |c, id| {
        if (c.child_count == 0) continue;
        for (res.lad.childrenOf(@intCast(id))) |k| {
            const d = dist(res.pos[id], res.pos[k]);
            try testing.expect(d + res.bound_r[k] <= res.bound_r[id] + 1e-3);
        }
    }
}

test "every note lands in exactly one leaf and ranges are contiguous" {
    const gpa = testing.allocator;
    var res = try buildGrid(gpa, 24);
    defer res.deinit(gpa);
    const n = res.lad.leaf_cell.len;

    var seen = try gpa.alloc(bool, n);
    defer gpa.free(seen);
    @memset(seen, false);
    for (res.lad.leaf_cell, 0..) |leaf, note| {
        try testing.expect(leaf != fold.invalid);
        const c = res.lad.cells[leaf];
        try testing.expectEqual(@as(u32, @intCast(note)), c.note);
        try testing.expectEqual(c.ls + 1, c.le);
        try testing.expect(!seen[c.ls]);
        seen[c.ls] = true;
        try testing.expectEqual(@as(u32, @intCast(note)), res.lad.note_at[c.ls]);
        try testing.expectEqual(c.ls, res.lad.slot_of[note]);
    }
    for (seen) |s| try testing.expect(s);

    // A parent's range is exactly the union of its children's, with no gap.
    for (res.lad.cells, 0..) |c, id| {
        if (c.child_count == 0) continue;
        const kids = res.lad.childrenOf(@intCast(id));
        try testing.expectEqual(c.ls, res.lad.cells[kids[0]].ls);
        try testing.expectEqual(c.le, res.lad.cells[kids[kids.len - 1]].le);
        for (kids[1..], 0..) |k, prev| {
            try testing.expectEqual(res.lad.cells[kids[prev]].le, res.lad.cells[k].ls);
        }
    }
}

test "counts sum up the tree" {
    const gpa = testing.allocator;
    var res = try buildGrid(gpa, 20);
    defer res.deinit(gpa);
    var total: u32 = 0;
    for (res.lad.roots) |r| total += res.lad.cells[r].count;
    try testing.expectEqual(@as(u32, 400), total);

    for (res.lad.cells, 0..) |c, id| {
        if (c.child_count == 0) continue;
        var sum: u32 = 0;
        for (res.lad.childrenOf(@intCast(id))) |k| sum += res.lad.cells[k].count;
        try testing.expectEqual(c.count, sum);
    }
}

test "unconnected components never share a cell" {
    // The guarantee `fold.Cell.comp` used to enforce during coarsening. Grouping by proximity
    // cannot get this for free — the layout is free to place two islands near each other — so it
    // is enforced here as well, and asserted with the components deliberately interleaved in
    // space so nothing but the constraint can separate them.
    const gpa = testing.allocator;
    const n: usize = 400;
    const p = try gpa.alloc(Vec2, n);
    defer gpa.free(p);
    const comp = try gpa.alloc(u32, n);
    defer gpa.free(comp);
    const w = try gpa.alloc(f32, n);
    defer gpa.free(w);
    @memset(w, 1);
    for (0..n) |i| {
        const gx: f32 = @floatFromInt(i % 20);
        const gy: f32 = @floatFromInt(i / 20);
        p[i] = .{ .x = gx, .y = gy };
        comp[i] = @intCast(i % 3); // three islands, thoroughly interleaved
    }

    var res = try build(gpa, n, p, comp, w, w, .{
        .quant_centre = .{ .x = 10, .y = 10 },
        .quant_half = 20,
    });
    defer res.deinit(gpa);

    for (res.lad.cells, 0..) |c, id| {
        if (c.child_count == 0) continue;
        for (res.lad.childrenOf(@intCast(id))) |k| {
            try testing.expectEqual(c.comp, res.lad.cells[k].comp);
        }
    }
    // And every note under a cell really is of that component.
    for (res.lad.cells) |c| {
        for (c.ls..c.le) |slot| {
            try testing.expectEqual(c.comp, comp[res.lad.note_at[slot]]);
        }
    }
}

test "the hierarchy is a pure function of its input" {
    const gpa = testing.allocator;
    var a = try buildGrid(gpa, 18);
    defer a.deinit(gpa);
    var b = try buildGrid(gpa, 18);
    defer b.deinit(gpa);

    try testing.expectEqual(a.lad.cells.len, b.lad.cells.len);
    for (a.pos, b.pos) |pa, pb| {
        try testing.expectEqual(pb.x, pa.x);
        try testing.expectEqual(pb.y, pa.y);
    }
    for (a.bound_r, b.bound_r) |ra, rb| try testing.expectEqual(rb, ra);
}

test "runs stay compact: sibling discs mostly do not overlap" {
    // The number this module exists to move. It currently measures **24.6%** here, against 38.7%
    // for the link-derived hierarchy on the reference corpus.
    //
    // A uniform grid is close to the *worst* case for this chunker, not the best: cutting at the
    // widest gap can only help where the data has gaps, and a grid has none, so every boundary
    // falls back to the fixed arity. It is kept as the fixture precisely because it cannot
    // flatter — a real layout has clusters to cut between. The honest score is the one
    // `bench --world` reports over an actual vault.
    //
    // Note also what this measures: whether two sibling *bounding circles* intersect. That is a
    // stricter question than the one the reader asks, which is whether a note sits inside a
    // neighbouring mass. Circles bound an L-shaped run of seven loosely, so they can intersect
    // while the runs themselves stay disjoint in space — which the link-derived hierarchy could
    // not say, because its groups genuinely interleaved.
    const gpa = testing.allocator;
    var res = try buildGrid(gpa, 60);
    defer res.deinit(gpa);

    var pairs: usize = 0;
    var overlapping: usize = 0;
    for (res.lad.cells, 0..) |c, id| {
        if (c.child_count < 2) continue;
        const kids = res.lad.childrenOf(@intCast(id));
        for (kids, 0..) |ka, ai| {
            for (kids[ai + 1 ..]) |kb| {
                pairs += 1;
                if (dist(res.pos[ka], res.pos[kb]) < res.bound_r[ka] + res.bound_r[kb]) {
                    overlapping += 1;
                }
            }
        }
    }
    try testing.expect(pairs > 0);
    const frac = @as(f32, @floatFromInt(overlapping)) / @as(f32, @floatFromInt(pairs));
    try testing.expect(frac < 0.30);
}
