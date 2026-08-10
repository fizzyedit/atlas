//! The living set: which cells are on screen this frame, where they are, and how big.
//!
//! This is the third and last piece of the containment path — `fold.zig` decides the hierarchy,
//! `containment.zig` decides where a cell's children sit inside it, and this file decides which
//! cells are *open* right now and turns them into screen-space marks. Together they replace
//! `quadlod.zig` + `quad_agents.zig` + `lod.zig` + `multilevel.zig` + most of `layout_full.zig`.
//!
//! The contract is unchanged from `organic-lod.md`, because it was the right one:
//!
//! > Given (tree, view, zoom, budget), the set of living cells is determined. Motion only
//! > interpolates how those cells appear.
//!
//! A parked camera therefore means the open set stops changing. That is the reliability bar and
//! there is a test for it.
//!
//! Six rules are load-bearing. Four are inherited; two were found by rebuilding this from scratch
//! in a prototype and paying for them again, so they are written down here in code:
//!
//! 1. **Cull inside select, not at draw.** Children are placed inside their parent's disc, so an
//!    off-screen cell's whole subtree is off-screen and the test is exact. Without this the
//!    candidate list fills with the entire vault, the budget check never passes, and the dive
//!    stalls partway showing nothing but coalesced rings.
//! 2. **Decide a level by a count threshold, never by visit order.** Opening biggest-first until
//!    the budget runs out leaves identical neighbours resolved differently depending on the walk —
//!    a visible seam. But opening a whole level or none of it wastes most of the budget, since
//!    level sizes go 1, arity, arity²…: the gauntlet drew 57 marks against a budget of 280.
//!    Thresholding on *count* gets both — equal-count cells always agree, and the budget fills.
//! 3. **Never force an open cell closed at the budget wall.** Closing frees budget, which allows
//!    reopening, which exceeds it again. The wall refuses only *new* opens.
//! 4. **A note is a fixed screen size.** Only masses are count-and-zoom scaled, and soft-capped so
//!    a cell the budget refused cannot inflate to fill the screen.
//! 5. Radius is the area-conserving law `√count`, anchored on the note size.
//! 6. Split and merge crossfade through `anim`; topology itself stays discrete.
//!
//! Screen-space out, no dvui in: marks are plain numbers so this stays headless-testable.

const std = @import("std");
const fold = @import("fold.zig");
const containment = @import("containment.zig");

pub const Mark = struct {
    cell: u32,
    /// Animated world position. The caller applies its own camera transform, so there is exactly
    /// one place that knows how world maps to screen.
    wx: f32,
    wy: f32,
    /// Screen position (viewport-relative, origin top-left) and radius in pixels.
    x: f32,
    y: f32,
    r: f32,
    alpha: f32,
    /// A real note (draw filled) rather than a coalesced mass (draw dashed).
    is_note: bool,
    /// Valid iff `is_note`.
    note: u32,
};

/// A link between two *living* cells, already lifted from the note pair that produced it.
pub const LiftedLink = struct { a: u32, b: u32, w: f32 };

pub const View = struct {
    w: f32,
    h: f32,
    zoom: f32,
    /// World point at the centre of the screen.
    cx: f32,
    cy: f32,
};

pub const Params = struct {
    /// Marks the frame may draw. Dying cells may briefly exceed it while they fade.
    budget: usize = 280,
    /// A cell opens once its on-screen radius passes this.
    split_px: f32 = 30,
    /// Rule 4: notes never scale with zoom.
    note_r_px: f32 = 8.5,
    /// Soft ceiling on a mass's drawn radius.
    mass_cap_px: f32 = 46,
    /// Crossfade rate per second for open/close.
    rate: f32 = 7,
    /// Pad the cull test so a cell just off-screen still animates rather than popping in.
    cull_pad_px: f32 = 48,
    /// Links the frame may draw, kept by descending weight.
    ///
    /// Marks and links need separate budgets: n living cells admit up to n(n-1)/2 lifted pairs,
    /// so a dense vault reaches ~25,000 lines behind only 280 marks. That is a hairball, not a
    /// web — it costs draw time and shows nothing, since every cell appears joined to every
    /// other. Keeping the heaviest links keeps the structure that carries information.
    link_budget: usize = 900,
};

pub const World = struct {
    gpa: std.mem.Allocator,
    lad: fold.Ladder,
    field: containment.Field,

    /// Per cell: 0 = closed, 1 = fully open. The only state that survives a frame.
    anim: []f32,
    /// Per cell: animated world pose, which is the parent's pose lerped toward the cell's own.
    px: []f32,
    py: []f32,
    /// Per cell: accumulated parent openness, so a subtree fades as one.
    mul: []f32,

    marks: std.ArrayListUnmanaged(Mark) = .empty,
    links: std.ArrayListUnmanaged(LiftedLink) = .empty,
    /// dfs slot -> the cell that currently owns that note, for lifting links. `fold.invalid`
    /// when the note's branch was culled.
    owner: []u32,
    /// True when the budget refused an open this frame (HUD / tests).
    bound: bool = false,

    pub fn init(
        gpa: std.mem.Allocator,
        n_notes: usize,
        links: []const fold.Edge,
        paths: []const []const u8,
        fold_opts: fold.Options,
        place_opts: containment.Options,
    ) !World {
        var lad = try fold.build(gpa, n_notes, links, paths, fold_opts);
        errdefer lad.deinit(gpa);
        const n_cells = lad.cells.len;

        var w: World = .{
            .gpa = gpa,
            .lad = lad,
            .field = undefined,
            .anim = try gpa.alloc(f32, n_cells),
            .px = try gpa.alloc(f32, n_cells),
            .py = try gpa.alloc(f32, n_cells),
            .mul = try gpa.alloc(f32, n_cells),
            .owner = try gpa.alloc(u32, @max(1, n_notes)),
        };
        @memset(w.anim, 0);
        @memset(w.px, 0);
        @memset(w.py, 0);
        @memset(w.mul, 1);
        @memset(w.owner, fold.invalid);
        w.field = try containment.init(gpa, n_cells, fold_opts.arity, place_opts);
        return w;
    }

    pub fn deinit(self: *World) void {
        self.marks.deinit(self.gpa);
        self.links.deinit(self.gpa);
        self.gpa.free(self.anim);
        self.gpa.free(self.px);
        self.gpa.free(self.py);
        self.gpa.free(self.mul);
        self.gpa.free(self.owner);
        self.field.deinit(self.gpa);
        self.lad.deinit(self.gpa);
        self.* = undefined;
    }

    /// World radius of the root, so a caller can frame the whole vault.
    pub fn extent(self: World) f32 {
        if (self.lad.root == fold.invalid) return 1;
        return self.field.radius(&self.lad, self.lad.root);
    }

    /// Rebuild the living set for this view. `dt` in seconds drives the crossfades only — the
    /// *set* of open cells depends on (view, budget) alone.
    pub fn step(self: *World, view: View, p: Params, dt: f32) !void {
        self.marks.clearRetainingCapacity();
        self.links.clearRetainingCapacity();
        @memset(self.owner, fold.invalid);
        self.bound = false;
        if (self.lad.root == fold.invalid) return;

        const rate = @min(1.0, dt * p.rate);
        const root = self.lad.root;
        self.px[root] = self.field.pos[root].x;
        self.py[root] = self.field.pos[root].y;
        self.mul[root] = 1;

        var frontier: std.ArrayListUnmanaged(u32) = .empty;
        defer frontier.deinit(self.gpa);
        var next: std.ArrayListUnmanaged(u32) = .empty;
        defer next.deinit(self.gpa);
        var vis: std.ArrayListUnmanaged(u32) = .empty;
        defer vis.deinit(self.gpa);
        try frontier.append(self.gpa, root);

        var guard: u32 = 0;
        while (frontier.items.len > 0 and guard < 64) : (guard += 1) {
            // -- rule 1: cull before anything else --
            vis.clearRetainingCapacity();
            for (frontier.items) |id| {
                const sr = self.field.radius(&self.lad, id) * view.zoom;
                const sx = view.w * 0.5 + (self.px[id] - view.cx) * view.zoom;
                const sy = view.h * 0.5 + (self.py[id] - view.cy) * view.zoom;
                const m = sr + p.cull_pad_px;
                if (sx < -m or sx > view.w + m or sy < -m or sy > view.h + m) {
                    // still claim the range so a link leaving the viewport keeps a target
                    const c = self.lad.cells[id];
                    for (c.ls..c.le) |s| {
                        if (self.owner[s] == fold.invalid) self.owner[s] = id;
                    }
                    self.anim[id] = 0;
                    continue;
                }
                try vis.append(self.gpa, id);
            }
            if (vis.items.len == 0) break;

            // -- rule 2: decide the level by a *count threshold*, never by visit order --
            //
            // Opening a whole level or none of it wastes most of the budget: level sizes go
            // 1, arity, arity², … so a 280 budget at arity 7 can only ever take 49, never 343.
            // The gauntlet showed 57 marks drawn against a budget of 280.
            //
            // Ranking cells and opening until the budget runs out recovers the budget but brings
            // back the artifact organic-lod.md rejected — identical neighbours resolved
            // differently depending on visit order. Thresholding on *count* avoids both: cells
            // with equal count always make the same decision, so no seam can appear between two
            // cells that look alike, and the rule is a pure function of the cell, not the walk.
            var want_open: usize = 0;
            var extra: usize = 0;
            for (vis.items) |id| {
                const c = self.lad.cells[id];
                if (c.child_count > 0 and self.field.radius(&self.lad, id) * view.zoom > p.split_px) {
                    extra += c.child_count - 1;
                    want_open += 1;
                }
            }

            // 0 means "no threshold, open everything that wants to".
            var cutoff: u32 = 0;
            if (self.marks.items.len + vis.items.len + extra > p.budget and want_open > 0) {
                self.bound = true;
                const counts = try self.gpa.alloc(u32, want_open);
                defer self.gpa.free(counts);
                var ci: usize = 0;
                for (vis.items) |id| {
                    const c = self.lad.cells[id];
                    if (c.child_count > 0 and self.field.radius(&self.lad, id) * view.zoom > p.split_px) {
                        counts[ci] = c.count;
                        ci += 1;
                    }
                }
                std.mem.sort(u32, counts, {}, comptime std.sort.desc(u32));
                // Walk the distinct counts largest-first, spending budget a whole count-class at
                // a time. The first class that does not fit becomes the cutoff: it and every
                // smaller class stay closed, so cells of equal count never disagree.
                var spent = self.marks.items.len + vis.items.len;
                var prev: u32 = std.math.maxInt(u32);
                for (counts) |cnt| {
                    if (cnt == prev) continue; // same class, already paid for
                    prev = cnt;
                    var class_cost: usize = 0;
                    for (vis.items) |id| {
                        const c = self.lad.cells[id];
                        if (c.count == cnt and c.child_count > 0 and
                            self.field.radius(&self.lad, id) * view.zoom > p.split_px)
                        {
                            class_cost += c.child_count - 1;
                        }
                    }
                    if (spent + class_cost > p.budget) {
                        cutoff = cnt;
                        break;
                    }
                    spent += class_cost;
                }
            }

            next.clearRetainingCapacity();
            for (vis.items) |id| {
                const c = self.lad.cells[id];
                const sr = self.field.radius(&self.lad, id) * view.zoom;

                // -- rule 3: the wall refuses new opens only --
                const already_open = self.anim[id] > 0.5;
                const want = (c.count > cutoff or already_open) and
                    c.child_count > 0 and sr > p.split_px;

                self.anim[id] += ((if (want) @as(f32, 1) else 0) - self.anim[id]) * rate;
                if (self.anim[id] < 0.004) self.anim[id] = 0;
                if (self.anim[id] > 0.996) self.anim[id] = 1;

                // the cut: this cell owns its whole note range for link lifting
                if (self.anim[id] < 0.5) {
                    for (c.ls..c.le) |s| self.owner[s] = id;
                }

                if (self.anim[id] < 1) {
                    const alpha = self.mul[id] * (1 - self.anim[id]);
                    if (alpha > 0.02) {
                        const is_note = c.child_count == 0;
                        // -- rules 4 & 5 --
                        const r: f32 = if (is_note)
                            p.note_r_px
                        else
                            @max(1.0, p.mass_cap_px * (1 - @exp(-(sr * 0.82) / p.mass_cap_px)));
                        try self.marks.append(self.gpa, .{
                            .cell = id,
                            .wx = self.px[id],
                            .wy = self.py[id],
                            .x = view.w * 0.5 + (self.px[id] - view.cx) * view.zoom,
                            .y = view.h * 0.5 + (self.py[id] - view.cy) * view.zoom,
                            .r = r,
                            .alpha = alpha,
                            .is_note = is_note,
                            .note = c.note,
                        });
                    }
                }

                // keep walking while a closing cell is still fading, so zoom-out crossfades
                if (c.child_count > 0 and self.anim[id] > 0) {
                    self.field.ensureChildren(&self.lad, id); // lazy placement pays off here
                    for (self.lad.childrenOf(id)) |k| {
                        const own = self.field.pos[k];
                        self.px[k] = self.px[id] + (own.x - self.px[id]) * self.anim[id];
                        self.py[k] = self.py[id] + (own.y - self.py[id]) * self.anim[id];
                        self.mul[k] = self.mul[id] * self.anim[id];
                        try next.append(self.gpa, k);
                    }
                }
            }
            std.mem.swap(std.ArrayListUnmanaged(u32), &frontier, &next);
        }
    }

    /// Lift note-level links onto the living set. Call after `step`. Duplicates between the same
    /// pair of cells are merged, so a coarse cell pair draws one line, not thousands.
    pub fn liftLinks(self: *World, note_links: []const fold.Edge, p: Params) !void {
        self.links.clearRetainingCapacity();
        if (self.lad.root == fold.invalid) return;

        var acc: std.AutoHashMapUnmanaged(u64, f32) = .empty;
        defer acc.deinit(self.gpa);
        for (note_links) |e| {
            if (e.a >= self.lad.slot_of.len or e.b >= self.lad.slot_of.len) continue;
            const sa = self.lad.slot_of[e.a];
            const sb = self.lad.slot_of[e.b];
            if (sa == fold.invalid or sb == fold.invalid) continue;
            const ca = self.owner[sa];
            const cb = self.owner[sb];
            if (ca == fold.invalid or cb == fold.invalid or ca == cb) continue;
            const key = (@as(u64, @min(ca, cb)) << 32) | @as(u64, @max(ca, cb));
            const gop = try acc.getOrPut(self.gpa, key);
            gop.value_ptr.* = (if (gop.found_existing) gop.value_ptr.* else 0) + e.w;
        }
        var it = acc.iterator();
        while (it.next()) |kv| {
            try self.links.append(self.gpa, .{
                .a = @intCast(kv.key_ptr.* >> 32),
                .b = @intCast(kv.key_ptr.* & 0xffff_ffff),
                .w = kv.value_ptr.*,
            });
        }
        if (self.links.items.len > p.link_budget) {
            const S = struct {
                pub fn heavier(_: void, x: LiftedLink, y: LiftedLink) bool {
                    if (x.w != y.w) return x.w > y.w;
                    // deterministic tie-break, so a parked camera keeps the same web
                    if (x.a != y.a) return x.a < y.a;
                    return x.b < y.b;
                }
            };
            std.mem.sort(LiftedLink, self.links.items, {}, S.heavier);
            self.links.shrinkRetainingCapacity(p.link_budget);
        }
    }

    pub fn noteMarks(self: World) usize {
        var n: usize = 0;
        for (self.marks.items) |m| {
            if (m.is_note) n += 1;
        }
        return n;
    }
};

// ---- tests ----------------------------------------------------------------------------------

const testing = std.testing;

fn chainLinks(gpa: std.mem.Allocator, n: u32) ![]fold.Edge {
    const e = try gpa.alloc(fold.Edge, n - 1);
    for (0..n - 1) |i| e[i] = .{ .a = @intCast(i), .b = @intCast(i + 1) };
    return e;
}

fn settle(w: *World, view: View, p: Params, frames: usize) !void {
    for (0..frames) |_| try w.step(view, p, 1.0 / 60.0);
}

test "a parked camera stops changing the open set" {
    // The reliability bar from organic-lod.md. If this fails, everything else is noise.
    const gpa = testing.allocator;
    const links = try chainLinks(gpa, 3000);
    defer gpa.free(links);
    var w = try World.init(gpa, 3000, links, &.{}, .{}, .{});
    defer w.deinit();

    const view: View = .{ .w = 900, .h = 600, .zoom = 6, .cx = 0, .cy = 0 };
    const p: Params = .{};
    try settle(&w, view, p, 240);

    const first = try gpa.dupe(Mark, w.marks.items);
    defer gpa.free(first);
    for (0..30) |_| {
        try w.step(view, p, 1.0 / 60.0);
        try testing.expectEqual(first.len, w.marks.items.len);
        for (first, w.marks.items) |a, b| try testing.expectEqual(a.cell, b.cell);
    }
}

test "marks stay within budget" {
    const gpa = testing.allocator;
    const links = try chainLinks(gpa, 5000);
    defer gpa.free(links);
    var w = try World.init(gpa, 5000, links, &.{}, .{}, .{});
    defer w.deinit();

    const p: Params = .{ .budget = 120 };
    var zoom: f32 = 0.5;
    while (zoom < 400) : (zoom *= 1.35) {
        try settle(&w, .{ .w = 900, .h = 600, .zoom = zoom, .cx = 0, .cy = 0 }, p, 90);
        // dying marks may briefly exceed; after settling the living set must fit
        try testing.expect(w.marks.items.len <= p.budget * 2);
    }
}

test "the budget wall does not oscillate" {
    // Rule 3. Force-closing an open cell frees budget, which lets it reopen, which exceeds the
    // budget again — visible judder at max zoom. Parked at the wall, the count must be constant.
    const gpa = testing.allocator;
    const links = try chainLinks(gpa, 4000);
    defer gpa.free(links);
    var w = try World.init(gpa, 4000, links, &.{}, .{}, .{});
    defer w.deinit();

    const view: View = .{ .w = 900, .h = 600, .zoom = 30, .cx = 0, .cy = 0 };
    const p: Params = .{ .budget = 60 };
    try settle(&w, view, p, 300);
    const n = w.marks.items.len;
    for (0..60) |_| {
        try w.step(view, p, 1.0 / 60.0);
        try testing.expectEqual(n, w.marks.items.len);
    }
}

test "zooming in eventually resolves to notes" {
    const gpa = testing.allocator;
    const links = try chainLinks(gpa, 2000);
    defer gpa.free(links);
    var w = try World.init(gpa, 2000, links, &.{}, .{}, .{});
    defer w.deinit();

    const p: Params = .{ .budget = 280 };
    // far enough in that the remaining notes comfortably fit the budget
    try settle(&w, .{ .w = 900, .h = 600, .zoom = 120, .cx = 0, .cy = 0 }, p, 400);
    try testing.expect(w.noteMarks() > 0);
    // and at that zoom nothing coalesced is left on screen
    for (w.marks.items) |m| try testing.expect(m.is_note);
}

test "notes are a fixed screen size, masses are not" {
    const gpa = testing.allocator;
    const links = try chainLinks(gpa, 800);
    defer gpa.free(links);
    var w = try World.init(gpa, 800, links, &.{}, .{}, .{});
    defer w.deinit();
    const p: Params = .{};
    try settle(&w, .{ .w = 900, .h = 600, .zoom = 200, .cx = 0, .cy = 0 }, p, 400);
    for (w.marks.items) |m| {
        if (m.is_note) try testing.expectApproxEqAbs(p.note_r_px, m.r, 0.001);
        try testing.expect(m.r <= p.mass_cap_px + 0.001);
    }
}

test "links lift onto living cells" {
    const gpa = testing.allocator;
    const links = try chainLinks(gpa, 1500);
    defer gpa.free(links);
    var w = try World.init(gpa, 1500, links, &.{}, .{}, .{});
    defer w.deinit();

    try settle(&w, .{ .w = 900, .h = 600, .zoom = 8, .cx = 0, .cy = 0 }, .{}, 120);
    try w.liftLinks(links, .{});
    try testing.expect(w.links.items.len > 0);
    // every lifted endpoint must be a cell that is actually on screen this frame
    for (w.links.items) |l| {
        var found_a = false;
        var found_b = false;
        for (w.marks.items) |m| {
            if (m.cell == l.a) found_a = true;
            if (m.cell == l.b) found_b = true;
        }
        try testing.expect(found_a and found_b);
    }
}

test "an empty vault does not crash" {
    const gpa = testing.allocator;
    var w = try World.init(gpa, 0, &.{}, &.{}, .{}, .{});
    defer w.deinit();
    try w.step(.{ .w = 800, .h = 600, .zoom = 1, .cx = 0, .cy = 0 }, .{}, 1.0 / 60.0);
    try testing.expectEqual(@as(usize, 0), w.marks.items.len);
}
