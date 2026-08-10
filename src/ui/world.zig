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

/// Centre-to-centre distance between two ring-adjacent leaves, in units of `note_r`.
///
/// A cell of `arity` leaves has radius `√arity · note_r`; its ring sits at
/// `√arity · fill − note_r` and adjacent ring slots are one step apart, whose chord at arity 7 is
/// the ring radius itself. A caller that needs notes a specific world distance apart — to match
/// an existing lattice, say — divides that pitch by this.
pub const leaf_pitch: f32 = 1.381;

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
    /// Per cell: the *topological* decision for this frame — recomputed from scratch every step
    /// and never read by the decision that produces it. `anim` chases this.
    open: []bool,

    marks: std.ArrayListUnmanaged(Mark) = .empty,
    links: std.ArrayListUnmanaged(LiftedLink) = .empty,
    /// dfs slot -> the cell that currently owns that note, for lifting links. `fold.invalid`
    /// when the note's branch was culled.
    owner: []u32,
    /// True when the budget refused an open this frame (HUD / tests).
    bound: bool = false,
    /// False while any crossfade is still running. The host needs this to keep asking for frames:
    /// a camera chase reports itself, but a split that finishes after the camera stops would
    /// otherwise freeze half-open until some unrelated event woke the app.
    settled: bool = true,

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
            .open = try gpa.alloc(bool, n_cells),
        };
        @memset(w.anim, 0);
        @memset(w.px, 0);
        @memset(w.py, 0);
        @memset(w.mul, 1);
        @memset(w.owner, fold.invalid);
        @memset(w.open, false);
        w.field = try containment.init(gpa, n_cells, lad.roots.len, fold_opts.arity, place_opts);
        // Islands are placed relative to each other once; everything below them is lazy.
        containment.placeRoots(&w.field, &w.lad);
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
        self.gpa.free(self.open);
        self.field.deinit(self.gpa);
        self.lad.deinit(self.gpa);
        self.* = undefined;
    }

    /// Radius of a disc at the origin containing every island, so a caller can frame the vault.
    pub fn extent(self: World) f32 {
        var e: f32 = 1;
        for (self.lad.roots) |r| {
            const p = self.field.pos[r];
            e = @max(e, @sqrt(p.x * p.x + p.y * p.y) + self.field.radius(&self.lad, r));
        }
        return e;
    }

    /// Rebuild the living set for this view.
    ///
    /// Two passes, deliberately. Topology first, as a **pure function of (tree, view, zoom,
    /// budget)** with no reference to animation state; then presentation, which only interpolates
    /// toward what the first pass decided.
    ///
    /// Collapsing these into one pass is the mistake that broke this on first contact: the budget
    /// was counted over *emitted marks*, and a mark is only emitted while it is still fading, so
    /// the count moved as animations progressed. That fed back into the open/closed cutoff, so
    /// cells vanished instead of splitting, appeared from nowhere, and — because link ownership
    /// keyed off the same fading state — edges popped in and out. A function that reads its own
    /// output cannot be stable. Keeping the passes apart is what makes "parked camera ⇒ nothing
    /// changes" true by construction rather than by luck.
    pub fn step(self: *World, view: View, p: Params, dt: f32) !void {
        self.marks.clearRetainingCapacity();
        self.links.clearRetainingCapacity();
        @memset(self.owner, fold.invalid);
        @memset(self.open, false);
        self.bound = false;
        if (self.lad.roots.len == 0) return;

        try self.decideTopology(view, p);
        try self.present(view, p, dt);
    }

    /// Pass 1 — which cells are open. Reads only the ladder, the view, and the budget.
    fn decideTopology(self: *World, view: View, p: Params) !void {
        var frontier: std.ArrayListUnmanaged(u32) = .empty;
        defer frontier.deinit(self.gpa);
        var next: std.ArrayListUnmanaged(u32) = .empty;
        defer next.deinit(self.gpa);
        var vis: std.ArrayListUnmanaged(u32) = .empty;
        defer vis.deinit(self.gpa);
        for (self.lad.roots) |r| try frontier.append(self.gpa, r);

        // Cells already settled as closed at shallower levels. This is the budget's running
        // total, and it is topological — nothing here depends on a crossfade.
        var closed: usize = 0;
        var guard: u32 = 0;

        while (frontier.items.len > 0 and guard < 64) : (guard += 1) {
            // -- rule 1: cull first. Children live inside their parent's disc, so an off-screen
            // cell's whole subtree is off-screen and this test is exact.
            vis.clearRetainingCapacity();
            for (frontier.items) |id| {
                if (self.onScreen(id, view, p)) {
                    try vis.append(self.gpa, id);
                } else {
                    // still claim the range so a link leaving the viewport keeps a target
                    const c = self.lad.cells[id];
                    for (c.ls..c.le) |s| {
                        if (self.owner[s] == fold.invalid) self.owner[s] = id;
                    }
                }
            }
            if (vis.items.len == 0) break;

            // -- rule 2: a count threshold, never visit order (see the module header) --
            var extra: usize = 0;
            var want_open: usize = 0;
            for (vis.items) |id| {
                if (self.wantsSplit(id, view, p)) {
                    extra += self.lad.cells[id].child_count - 1;
                    want_open += 1;
                }
            }

            var cutoff: u32 = 0;
            if (closed + vis.items.len + extra > p.budget and want_open > 0) {
                self.bound = true;
                cutoff = try self.countCutoff(vis.items, view, p, closed, want_open);
            }

            next.clearRetainingCapacity();
            for (vis.items) |id| {
                const c = self.lad.cells[id];
                const will_open = self.wantsSplit(id, view, p) and c.count > cutoff;
                self.open[id] = will_open;
                if (!will_open) {
                    closed += 1;
                    // the cut: this cell owns its whole note range for link lifting
                    for (c.ls..c.le) |s| self.owner[s] = id;
                    continue;
                }
                for (self.lad.childrenOf(id)) |k| try next.append(self.gpa, k);
            }
            std.mem.swap(std.ArrayListUnmanaged(u32), &frontier, &next);
        }
    }

    fn onScreen(self: *const World, id: u32, view: View, p: Params) bool {
        const sr = self.field.radius(&self.lad, id) * view.zoom;
        const sx = view.w * 0.5 + (self.px[id] - view.cx) * view.zoom;
        const sy = view.h * 0.5 + (self.py[id] - view.cy) * view.zoom;
        const m = sr + p.cull_pad_px;
        return sx >= -m and sx <= view.w + m and sy >= -m and sy <= view.h + m;
    }

    fn wantsSplit(self: *const World, id: u32, view: View, p: Params) bool {
        const c = self.lad.cells[id];
        return c.child_count > 0 and self.field.radius(&self.lad, id) * view.zoom > p.split_px;
    }

    /// Largest count class that does not fit. That class and every smaller one stay closed, so
    /// cells of equal count never disagree and no order-dependent seam can appear.
    fn countCutoff(
        self: *World,
        vis: []const u32,
        view: View,
        p: Params,
        closed: usize,
        want_open: usize,
    ) !u32 {
        const counts = try self.gpa.alloc(u32, want_open);
        defer self.gpa.free(counts);
        var ci: usize = 0;
        for (vis) |id| {
            if (self.wantsSplit(id, view, p)) {
                counts[ci] = self.lad.cells[id].count;
                ci += 1;
            }
        }
        std.mem.sort(u32, counts, {}, comptime std.sort.desc(u32));

        var spent = closed + vis.len;
        var prev: u32 = std.math.maxInt(u32);
        for (counts) |cnt| {
            if (cnt == prev) continue; // same class, already paid for
            prev = cnt;
            var class_cost: usize = 0;
            for (vis) |id| {
                const c = self.lad.cells[id];
                if (c.count == cnt and self.wantsSplit(id, view, p)) class_cost += c.child_count - 1;
            }
            if (spent + class_cost > p.budget) return cnt;
            spent += class_cost;
        }
        return 0;
    }

    /// Pass 2 — how the decided set looks right now. Chases `anim` toward `open`, lerps poses, and
    /// emits marks. Keeps walking into a *closing* cell's children so a merge crossfades instead
    /// of popping, but never lets any of that feed back into the decision above.
    fn present(self: *World, view: View, p: Params, dt: f32) !void {
        const rate = @min(1.0, dt * p.rate);
        self.settled = true;
        var stack: std.ArrayListUnmanaged(u32) = .empty;
        defer stack.deinit(self.gpa);
        for (self.lad.roots) |r| {
            self.px[r] = self.field.pos[r].x;
            self.py[r] = self.field.pos[r].y;
            self.mul[r] = 1;
            try stack.append(self.gpa, r);
        }

        var guard: u32 = 0;
        while (stack.pop()) |id| {
            guard += 1;
            if (guard > 200_000) break;
            const c = self.lad.cells[id];

            const target: f32 = if (self.open[id]) 1 else 0;
            self.anim[id] += (target - self.anim[id]) * rate;
            if (self.anim[id] < 0.004) self.anim[id] = 0;
            if (self.anim[id] > 0.996) self.anim[id] = 1;
            if (self.anim[id] != target) self.settled = false;

            if (self.anim[id] < 1) {
                const alpha = self.mul[id] * (1 - self.anim[id]);
                if (alpha > 0.02 and self.onScreen(id, view, p)) {
                    const sr = self.field.radius(&self.lad, id) * view.zoom;
                    const is_note = c.child_count == 0;
                    // -- rules 4 & 5: a note is a fixed screen size; a mass is count-scaled and
                    // soft-capped so one the budget refused cannot inflate to fill the screen --
                    const r: f32 = if (is_note) p.note_r_px else blk: {
                        const full = @max(1.0, p.mass_cap_px *
                            (1 - @exp(-(sr * 0.82) / p.mass_cap_px)));
                        // A splitting mass shrinks to a single note's size as it fades, rather
                        // than hanging at full radius while children appear inside it. The ring
                        // reads as collapsing into the point its children emerge from, which is
                        // what makes a split look like one object becoming several instead of two
                        // unrelated things crossfading. Runs in reverse on merge, for free.
                        break :blk full + (p.note_r_px - full) * self.anim[id];
                    };
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

            if (c.child_count > 0 and self.anim[id] > 0) {
                self.field.ensureChildren(&self.lad, id); // lazy placement pays off here
                for (self.lad.childrenOf(id)) |k| {
                    const own = self.field.pos[k];
                    self.px[k] = self.px[id] + (own.x - self.px[id]) * self.anim[id];
                    self.py[k] = self.py[id] + (own.y - self.py[id]) * self.anim[id];
                    self.mul[k] = self.mul[id] * self.anim[id];
                    try stack.append(self.gpa, k);
                }
            }
        }
    }


    /// Lift note-level links onto the living set. Call after `step`. Duplicates between the same
    /// pair of cells are merged, so a coarse cell pair draws one line, not thousands.
    pub fn liftLinks(self: *World, note_links: []const fold.Edge, p: Params) !void {
        self.links.clearRetainingCapacity();
        if (self.lad.roots.len == 0) return;

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

test "a splitting mass shrinks toward a note's size as it fades" {
    const gpa = testing.allocator;
    const links = try chainLinks(gpa, 1200);
    defer gpa.free(links);
    var w = try World.init(gpa, 1200, links, &.{}, .{}, .{});
    defer w.deinit();

    const view: View = .{ .w = 900, .h = 600, .zoom = 14, .cx = 0, .cy = 0 };
    const p: Params = .{};
    // settle closed, so masses are drawn at full radius
    try settle(&w, view, p, 300);

    // find a mass that is about to open, and record its resting radius
    var target: u32 = fold.invalid;
    var full_r: f32 = 0;
    for (w.marks.items) |m| {
        if (!m.is_note and w.open[m.cell]) {
            target = m.cell;
            full_r = m.r;
            break;
        }
    }
    if (target == fold.invalid) return; // nothing splitting at this zoom; nothing to assert

    // part-way through the crossfade it must be smaller than at rest, and never below a note
    var saw_smaller = false;
    for (0..8) |_| {
        try w.step(view, p, 1.0 / 60.0);
        for (w.marks.items) |m| {
            if (m.cell != target) continue;
            try testing.expect(m.r <= full_r + 0.001);
            try testing.expect(m.r >= p.note_r_px - 0.001);
            if (m.r < full_r - 0.5) saw_smaller = true;
        }
    }
    try testing.expect(saw_smaller);
}

test "topology does not depend on animation state" {
    // The contract: given (tree, view, zoom, budget) the open set is determined; motion only
    // interpolates. Breaking it is what made cells vanish instead of splitting and made edges pop
    // — the budget was counted over marks, which only exist while fading, so the decision read its
    // own output. Here: a fully-settled field and a field mid-crossfade must agree exactly.
    const gpa = testing.allocator;
    const links = try chainLinks(gpa, 3000);
    defer gpa.free(links);
    var w = try World.init(gpa, 3000, links, &.{}, .{}, .{});
    defer w.deinit();

    const view: View = .{ .w = 900, .h = 600, .zoom = 12, .cx = 0, .cy = 0 };
    const p: Params = .{ .budget = 140 };
    try settle(&w, view, p, 300);
    const settled = try gpa.dupe(bool, w.open);
    defer gpa.free(settled);

    // slam every crossfade to a half-open state and step once more
    @memset(w.anim, 0.5);
    try w.step(view, p, 1.0 / 60.0);
    try testing.expectEqualSlices(bool, settled, w.open);

    // and from cold, with a single huge dt
    @memset(w.anim, 0);
    try w.step(view, p, 10.0);
    try testing.expectEqualSlices(bool, settled, w.open);
}

test "the lifted link set is stable at a parked camera" {
    const gpa = testing.allocator;
    const links = try chainLinks(gpa, 2500);
    defer gpa.free(links);
    var w = try World.init(gpa, 2500, links, &.{}, .{}, .{});
    defer w.deinit();

    const view: View = .{ .w = 900, .h = 600, .zoom = 10, .cx = 0, .cy = 0 };
    const p: Params = .{};
    try settle(&w, view, p, 300);
    try w.liftLinks(links, p);
    const first = try gpa.dupe(LiftedLink, w.links.items);
    defer gpa.free(first);
    try testing.expect(first.len > 0);

    for (0..30) |_| {
        try w.step(view, p, 1.0 / 60.0);
        try w.liftLinks(links, p);
        try testing.expectEqual(first.len, w.links.items.len);
        for (first, w.links.items) |a, b| {
            try testing.expectEqual(a.a, b.a);
            try testing.expectEqual(a.b, b.b);
        }
    }
}

test "leaf_pitch matches the geometry it claims to describe" {
    // A caller matching an existing lattice divides its slot spacing by `leaf_pitch` to get
    // `note_r`. If the constant drifts from the real geometry the whole vault comes out at the
    // wrong scale — which reads as a speck at the centre of the view, with every LOD transition
    // crammed into a sliver of the zoom range.
    const gpa = testing.allocator;
    const edges = try gpa.alloc(fold.Edge, 6);
    defer gpa.free(edges);
    for (0..6) |i| edges[i] = .{ .a = 0, .b = @intCast(i + 1) };

    var lad = try fold.build(gpa, 7, edges, &.{}, .{ .arity = .seven });
    defer lad.deinit(gpa);
    var f = try containment.init(gpa, lad.cells.len, lad.roots.len, .seven, .{ .note_r = 1 });
    defer f.deinit(gpa);
    containment.placeAll(&f, &lad);

    // nearest neighbour distance among the leaves of a full cell
    var best: f32 = std.math.floatMax(f32);
    for (lad.cells, 0..) |a, ia| {
        if (a.note == fold.invalid) continue;
        for (lad.cells, 0..) |b, ib| {
            if (ib <= ia or b.note == fold.invalid) continue;
            const d = containment.Vec2.dist(f.pos[ia], f.pos[ib]);
            if (d > 1e-4) best = @min(best, d);
        }
    }
    try testing.expectApproxEqAbs(leaf_pitch, best, 0.05);
}

test "an empty vault does not crash" {
    const gpa = testing.allocator;
    var w = try World.init(gpa, 0, &.{}, &.{}, .{}, .{});
    defer w.deinit();
    try w.step(.{ .w = 800, .h = 600, .zoom = 1, .cx = 0, .cy = 0 }, .{}, 1.0 / 60.0);
    try testing.expectEqual(@as(usize, 0), w.marks.items.len);
}
