//! Thin present layer over Stable v1 `quadlod.selectSticky`.
//!
//! Topology is decided only by select (view / zoom / budget / sticky bits). This file
//! interpolates poses and radii. See docs/design/organic-lod.md.

const std = @import("std");
const dvui = @import("dvui");
const quadlod = @import("quadlod.zig");
const testing = std.testing;

pub const Key = struct { node: u32 };

const cover_k: f32 = 0.85;
const r_min_px: f32 = 0.6;
/// Closed cells used to track `zoom × spread` up to 96px — diving without a split inflated
/// blobs forever ("nodes expanding"). Cap the mark; further zoom must open, not grow.
const r_max_px: f32 = 40.0;

// Slightly overdamped — underdamped pos springs were the mid-zoom wobble.
const pos_freq: f32 = 2.1;
const pos_damping: f32 = 1.05;
const r_freq: f32 = 3.4;
const r_damping: f32 = 1.05;
const max_dt: f32 = 1.0 / 30.0;
const settle_px: f32 = 0.15;
/// Dying agents may briefly exceed the living budget (fade into parent / out).
const dying_slack: usize = 48;
/// Drop a dying mark once it has collapsed this small (screen px).
const dying_r_eps: f32 = 0.8;
/// Hard cut — do not let fade extras accumulate across a zoom gesture.
const dying_max_frames: u16 = 12;

pub const Agent = struct {
    key: Key,
    pos: dvui.Point = .{},
    vel: dvui.Point = .{},
    r_px: f32 = 0,
    r_vel: f32 = 0,
    target_pos: dvui.Point = .{},
    target_r: f32 = 0,
    count: u32 = 1,
    seen: u32 = 0,
    /// Not selected this frame — collapsing into a survivor (or vanishing).
    dying: bool = false,
    die_age: u16 = 0,

    pub fn distanceTo(self: Agent, q: dvui.Point) f32 {
        const dx = self.pos.x - q.x;
        const dy = self.pos.y - q.y;
        return @sqrt(dx * dx + dy * dy);
    }
};

/// Mass / note mark radius. Single notes use a uniform `note_r_px` (leaf cell bboxes are huge
/// empty quads — sizing from extent made "notes" unequal). Multi-note cells use spread × zoom,
/// soft-capped so an unsplit cell cannot keep inflating as the camera dives.
pub fn cellRadiusPx(note_r_px: f32, count: u32, zoom: f32, draw_radius_world: f32) f32 {
    if (count <= 1) return std.math.clamp(note_r_px, r_min_px, r_max_px);
    const r = zoom * draw_radius_world * cover_k;
    // Floor at note size so a tiny mass still reads; never above r_max_px.
    return std.math.clamp(r, r_min_px, r_max_px);
}

pub const Frame = struct {
    view: dvui.Rect,
    live: []const dvui.Point = &.{},
    zoom: f32 = 1,
    note_r_px: f32 = 6,
    dt: f32,
    budget: usize = 3000,
    /// When true, `step` times select/present phases via `dvui.io` (must be initialized — tour
    /// and live app do; unit tests leave this false so they never touch the clock).
    profile: bool = false,
};

/// Per-frame breakdown written by `Field.step` — organic-tour aggregates these to explain why
/// zoom-out settle costs more than zoom-in at the same zoom / agent count.
pub const StepProfile = struct {
    /// True when park-cache early-returned (no select, no present).
    early_out: bool = false,
    did_select: bool = false,
    select_ns: u64 = 0,
    touch_ns: u64 = 0,
    dying_ns: u64 = 0,
    integrate_ns: u64 = 0,
    purge_ns: u64 = 0,
    dying_n: u32 = 0,
    agents_n: u32 = 0,
    living_n: u32 = 0,
    sticky_open_n: u32 = 0,
    select: quadlod.SelectStats = .{},

    pub fn presentNs(self: StepProfile) u64 {
        return self.touch_ns + self.dying_ns + self.integrate_ns + self.purge_ns;
    }
};

pub const Field = struct {
    allocator: std.mem.Allocator,
    agents: std.ArrayListUnmanaged(Agent) = .empty,
    index: std.AutoHashMapUnmanaged(Key, u32) = .empty,
    sticky: quadlod.StickyOpen,
    living: std.ArrayListUnmanaged(u32) = .empty,

    stamp: u32 = 0,
    settled: bool = true,
    /// True when select refused an open for budget (HUD).
    budget_bound: bool = false,
    /// Last select inputs — parked camera reuses living set (no re-solve thrash).
    sel_zoom: f32 = -1,
    sel_view: dvui.Rect = .{},
    sel_budget: usize = 0,
    /// Last quantized zoom seen by `step`, including park-cache hits. Survives a forced
    /// `sel_zoom = -1` (tour harness) so zoom-*out* sticky prune still knows direction.
    last_zoom: f32 = -1,
    /// Lifted web cached while settled (rebuilding every idle frame was an FPS tax).
    edge_cache: std.ArrayListUnmanaged(quadlod.LiftedEdge) = .empty,
    edge_cache_valid: bool = false,
    /// Filled every `step` call (including early-outs).
    last_profile: StepProfile = .{},

    pub fn init(allocator: std.mem.Allocator) Field {
        return .{
            .allocator = allocator,
            .sticky = quadlod.StickyOpen.init(allocator),
        };
    }

    pub fn deinit(self: *Field) void {
        self.agents.deinit(self.allocator);
        self.index.deinit(self.allocator);
        self.sticky.deinit();
        self.living.deinit(self.allocator);
        self.edge_cache.deinit(self.allocator);
        self.* = .{ .allocator = self.allocator, .sticky = quadlod.StickyOpen.init(self.allocator) };
    }

    pub fn reset(self: *Field) void {
        self.agents.clearRetainingCapacity();
        self.index.clearRetainingCapacity();
        self.living.clearRetainingCapacity();
        self.edge_cache.clearRetainingCapacity();
        self.edge_cache_valid = false;
        self.sticky.deinit();
        self.sticky = quadlod.StickyOpen.init(self.allocator);
        self.settled = true;
        self.budget_bound = false;
        self.sel_zoom = -1;
        self.sel_view = .{};
        self.sel_budget = 0;
        self.last_zoom = -1;
    }

    pub fn find(self: *const Field, key: Key) ?*Agent {
        const slot = self.index.get(key) orelse return null;
        return &self.agents.items[slot];
    }

    pub fn groupIsOpen(self: *const Field, node: u32) bool {
        return self.sticky.isOpen(node);
    }

    pub fn step(self: *Field, tree: quadlod.Tree, scratch: std.mem.Allocator, f: Frame) !void {
        _ = scratch;
        var prof: StepProfile = .{};
        defer {
            prof.agents_n = @intCast(self.agents.items.len);
            prof.living_n = @intCast(self.living.items.len);
            prof.dying_n = countDying(self);
            prof.sticky_open_n = @intCast(countOpen(&self.sticky));
            self.last_profile = prof;
        }

        if (tree.nodes.len == 0) {
            self.agents.clearRetainingCapacity();
            self.index.clearRetainingCapacity();
            self.stamp +%= 1;
            return;
        }

        // Quantize so wheel/pan micro-steps do not re-select every frame (mid-zoom idle was
        // 120fps only because select was skipped; extremes re-selected continuously).
        const q_zoom = quantizeZoom(f.zoom);
        const q_view = quantizeView(f.view);
        const cam_same = self.sel_zoom > 0 and
            @abs(q_zoom - self.sel_zoom) < 1e-6 and
            f.budget == self.sel_budget and
            rectNearlyEqual(q_view, self.sel_view);

        // Use prior-frame `settled` — do not clear it before this check.
        if (cam_same and self.living.items.len > 0 and self.settled and !self.hasDying()) {
            prof.early_out = true;
            return;
        }

        self.stamp +%= 1;
        self.budget_bound = false;
        self.settled = true;

        if (!cam_same or self.living.items.len == 0) {
            var sel_stats: quadlod.SelectStats = .{};
            const t0 = if (f.profile) nowNs() else 0;
            // Zoom-out: drop dive hysteresis before select. A deep sticky set from close-up
            // makes the BFS treat mid-levels as `was_open` and re-descend — the measured
            // in/out select asymmetry. Prune at split_px so outward steps match a cold select
            // at the same zoom; the in-selectStickyEx merge_px prune still runs for flicker.
            var pre_pruned: u32 = 0;
            if (self.last_zoom > 0 and q_zoom < self.last_zoom) {
                pre_pruned = quadlod.pruneStickyBelowSpan(
                    tree,
                    f.zoom,
                    quadlod.default_split_px,
                    &self.sticky,
                );
            }
            try quadlod.selectStickyEx(
                tree,
                f.view,
                f.zoom,
                quadlod.default_split_px,
                quadlod.default_merge_px,
                f.note_r_px,
                f.budget,
                &self.sticky,
                self.allocator,
                &self.living,
                &sel_stats,
            );
            sel_stats.sticky_pruned += pre_pruned;
            if (f.profile) prof.select_ns = lap(t0);
            prof.did_select = true;
            prof.select = sel_stats;
            if (self.living.items.len >= quadlod.livingCap(f.budget)) self.budget_bound = true;
            self.sel_zoom = q_zoom;
            self.sel_view = q_view;
            self.sel_budget = f.budget;
            self.edge_cache_valid = false;
        }
        self.last_zoom = q_zoom;

        {
            const t0 = if (f.profile) nowNs() else 0;
            for (self.living.items) |nid| {
                try self.touch(tree, f, nid);
            }
            if (f.profile) prof.touch_ns = lap(t0);
        }
        {
            const t0 = if (f.profile) nowNs() else 0;
            self.markDying(tree);
            if (f.profile) prof.dying_ns = lap(t0);
        }
        {
            const t0 = if (f.profile) nowNs() else 0;
            self.integrate(f);
            if (f.profile) prof.integrate_ns = lap(t0);
        }
        {
            const t0 = if (f.profile) nowNs() else 0;
            self.purgeDead();
            self.trimBudget(f.budget);
            if (f.profile) prof.purge_ns = lap(t0);
        }
    }

    fn countDying(self: *const Field) u32 {
        var n: u32 = 0;
        for (self.agents.items) |a| {
            if (a.dying) n += 1;
        }
        return n;
    }

    fn nowNs() i96 {
        return std.Io.Clock.boot.now(dvui.io).nanoseconds;
    }

    fn lap(start: i96) u64 {
        return @intCast(nowNs() - start);
    }

    fn hasDying(self: *const Field) bool {
        for (self.agents.items) |a| {
            if (a.dying) return true;
        }
        return false;
    }

    fn touch(self: *Field, tree: quadlod.Tree, f: Frame, nid: u32) !void {
        const n = tree.get(nid);
        var rest = n.centroid;
        if (tree.singleNote(nid)) |note| {
            if (note < f.live.len) rest = f.live[note];
        }
        const target_r = cellRadiusPx(f.note_r_px, n.count, f.zoom, n.drawRadius());
        const key = Key{ .node = nid };

        const gop = try self.index.getOrPut(self.allocator, key);
        if (!gop.found_existing) {
            var birth_pos = rest;
            var birth_r = target_r * 0.35;
            // Merge: children are still in the list this frame (retire runs after touch) — birth
            // from their COM so a parent does not pop in at full size in a new place.
            var kx: f32 = 0;
            var ky: f32 = 0;
            var kr: f32 = 0;
            var kn: f32 = 0;
            if (n.hasChildren()) {
                for (n.children) |c| {
                    if (c == quadlod.no_child) continue;
                    if (self.find(.{ .node = c })) |ca| {
                        kx += ca.pos.x;
                        ky += ca.pos.y;
                        kr += ca.r_px;
                        kn += 1;
                    }
                }
            }
            if (kn > 0) {
                birth_pos = .{ .x = kx / kn, .y = ky / kn };
                birth_r = kr / kn;
            } else if (n.parent != quadlod.no_child) {
                // Split: parent agent may still be present from last frame.
                if (self.find(.{ .node = n.parent })) |pa| {
                    birth_pos = pa.pos;
                    birth_r = pa.r_px;
                }
            }
            gop.value_ptr.* = @intCast(self.agents.items.len);
            try self.agents.append(self.allocator, .{
                .key = key,
                .pos = birth_pos,
                .r_px = birth_r,
                .target_pos = rest,
                .target_r = target_r,
                .count = n.count,
                .seen = self.stamp,
                .dying = false,
                .die_age = 0,
            });
            return;
        }

        const a = &self.agents.items[gop.value_ptr.*];
        a.target_pos = rest;
        a.target_r = target_r;
        a.count = n.count;
        a.seen = self.stamp;
        a.dying = false;
        a.die_age = 0;
    }

    /// Unselected agents collapse into a living parent (or vanish in place) instead of popping out.
    fn markDying(self: *Field, tree: quadlod.Tree) void {
        for (self.agents.items) |*a| {
            if (a.seen == self.stamp) continue;
            if (!a.dying) {
                a.dying = true;
                a.die_age = 0;
            } else if (a.die_age < std.math.maxInt(u16)) {
                a.die_age += 1;
            }
            a.target_r = 0;
            var merge = a.target_pos;
            var cur = a.key.node;
            var guard: usize = 0;
            while (guard < quadlod.max_depth + 2) : (guard += 1) {
                const p = tree.parentOf(cur) orelse break;
                if (self.find(.{ .node = p })) |pa| {
                    if (!pa.dying) {
                        merge = pa.pos;
                        break;
                    }
                }
                cur = p;
            }
            a.target_pos = merge;
        }
    }

    fn purgeDead(self: *Field) void {
        var i: usize = 0;
        while (i < self.agents.items.len) {
            const a = self.agents.items[i];
            const dead = a.dying and (a.die_age >= dying_max_frames or
                (a.r_px <= dying_r_eps and @abs(a.r_vel) < settle_px * 2));
            if (!dead) {
                i += 1;
                continue;
            }
            _ = self.index.remove(a.key);
            const last = self.agents.items.len - 1;
            if (i != last) {
                self.agents.items[i] = self.agents.items[last];
                self.index.put(self.allocator, self.agents.items[i].key, @intCast(i)) catch {};
            }
            self.agents.items.len = last;
        }
    }

    fn trimBudget(self: *Field, budget: usize) void {
        const cap = quadlod.livingCap(budget) + dying_slack;
        while (self.agents.items.len > cap) {
            // Prefer dropping the smallest dying marks first.
            var drop_i: ?usize = null;
            var drop_r: f32 = std.math.floatMax(f32);
            for (self.agents.items, 0..) |a, i| {
                if (!a.dying) continue;
                if (a.r_px < drop_r) {
                    drop_r = a.r_px;
                    drop_i = i;
                }
            }
            const i = drop_i orelse (self.agents.items.len - 1);
            _ = self.index.remove(self.agents.items[i].key);
            const last = self.agents.items.len - 1;
            if (i != last) {
                self.agents.items[i] = self.agents.items[last];
                self.index.put(self.allocator, self.agents.items[i].key, @intCast(i)) catch {};
            }
            self.agents.items.len = last;
        }
    }

    /// Living (non-dying) agent count — topology budget, not draw fade extras.
    pub fn livingCount(self: *const Field) usize {
        var n: usize = 0;
        for (self.agents.items) |a| {
            if (!a.dying) n += 1;
        }
        return n;
    }

    fn integrate(self: *Field, f: Frame) void {
        const dt = @min(@max(f.dt, 0), max_dt);
        if (dt <= 0) return;

        const w_pos = std.math.tau * pos_freq;
        const w_r = std.math.tau * r_freq;
        const settle_world = settle_px / @max(f.zoom, 1e-6);

        var moving = false;
        for (self.agents.items) |*a| {
            const ax = w_pos * w_pos * (a.target_pos.x - a.pos.x) - 2 * pos_damping * w_pos * a.vel.x;
            const ay = w_pos * w_pos * (a.target_pos.y - a.pos.y) - 2 * pos_damping * w_pos * a.vel.y;
            a.vel.x += ax * dt;
            a.vel.y += ay * dt;
            a.pos.x += a.vel.x * dt;
            a.pos.y += a.vel.y * dt;

            const ar = w_r * w_r * (a.target_r - a.r_px) - 2 * r_damping * w_r * a.r_vel;
            a.r_vel += ar * dt;
            a.r_px = @max(a.r_px + a.r_vel * dt, 0);

            const dx = a.target_pos.x - a.pos.x;
            const dy = a.target_pos.y - a.pos.y;
            if (@abs(dx) < settle_world and @abs(dy) < settle_world and
                @abs(a.vel.x) < settle_world and @abs(a.vel.y) < settle_world)
            {
                a.pos = a.target_pos;
                a.vel = .{};
            } else moving = true;

            if (@abs(a.target_r - a.r_px) < settle_px and @abs(a.r_vel) < settle_px) {
                a.r_px = a.target_r;
                a.r_vel = 0;
            } else moving = true;
        }
        if (moving) self.settled = false;
    }

    fn rectNearlyEqual(a: dvui.Rect, b: dvui.Rect) bool {
        return @abs(a.x - b.x) < 1e-4 and @abs(a.y - b.y) < 1e-4 and
            @abs(a.w - b.w) < 1e-4 and @abs(a.h - b.h) < 1e-4;
    }

    pub fn gatherLiftedEdges(
        self: *Field,
        tree: quadlod.Tree,
        edges: []const quadlod.Edge,
        allocator: std.mem.Allocator,
        out: *std.ArrayListUnmanaged(quadlod.LiftedEdge),
    ) !void {
        if (self.settled and self.edge_cache_valid and self.edge_cache.items.len > 0) {
            // Refresh endpoints from current poses (settled ⇒ poses match targets, but cheap).
            out.clearRetainingCapacity();
            try out.ensureTotalCapacity(allocator, self.edge_cache.items.len);
            for (self.edge_cache.items) |link| {
                var e = link;
                if (self.find(.{ .node = link.from_node })) |a| e.from = a.pos;
                if (self.find(.{ .node = link.to_node })) |a| e.to = a.pos;
                try out.append(allocator, e);
            }
            return;
        }

        const Ctx = struct {
            field: *const Field,
            fn hasAgent(ctx: *const anyopaque, node: u32) bool {
                const c: *const @This() = @ptrCast(@alignCast(ctx));
                const a = c.field.find(.{ .node = node }) orelse return false;
                // Dying marks are fade extras — climb past them to the living survivor.
                return !a.dying;
            }
            fn posOf(ctx: *const anyopaque, node: u32) dvui.Point {
                const c: *const @This() = @ptrCast(@alignCast(ctx));
                if (c.field.find(.{ .node = node })) |a| return a.pos;
                return .{};
            }
        };
        var ctx = Ctx{ .field = self };
        out.clearRetainingCapacity();
        try quadlod.liftEdgesEx(tree, edges, Ctx.hasAgent, Ctx.posOf, &ctx, allocator, out, .{
            .max_edges = 360,
            .max_degree = 32,
            .max_examine = @min(edges.len, 4_000),
        });
        self.edge_cache.clearRetainingCapacity();
        try self.edge_cache.appendSlice(self.allocator, out.items);
        self.edge_cache_valid = true;
    }
};

fn quantizeZoom(z: f32) f32 {
    const z0 = @max(z, 1e-6);
    // ~4% steps in log space — wheel ticks coalesce; LOD still tracks the gesture.
    const step = @log(1.04);
    return @exp(@round(@log(z0) / step) * step);
}

fn quantizeView(v: dvui.Rect) dvui.Rect {
    const qx = @max(v.w * 0.03, 1e-3);
    const qy = @max(v.h * 0.03, 1e-3);
    return .{
        .x = @round(v.x / qx) * qx,
        .y = @round(v.y / qy) * qy,
        .w = @round(v.w / qx) * qx,
        .h = @round(v.h / qy) * qy,
    };
}

fn countOpen(sticky: *const quadlod.StickyOpen) usize {
    var n: usize = 0;
    for (sticky.open) |o| {
        if (o) n += 1;
    }
    return n;
}

fn gridPositions(allocator: std.mem.Allocator, side: usize, spacing: f32) ![]dvui.Point {
    const pts = try allocator.alloc(dvui.Point, side * side);
    for (0..side) |y| {
        for (0..side) |x| {
            pts[y * side + x] = .{
                .x = @as(f32, @floatFromInt(x)) * spacing,
                .y = @as(f32, @floatFromInt(y)) * spacing,
            };
        }
    }
    return pts;
}

fn fullView(tree: quadlod.Tree) dvui.Rect {
    const root = tree.get(tree.root);
    return .{
        .x = root.min_x - 10,
        .y = root.min_y - 10,
        .w = root.max_x - root.min_x + 20,
        .h = root.max_y - root.min_y + 20,
    };
}

fn settle(field: *Field, tree: quadlod.Tree, zoom: f32, budget: usize) !void {
    const view = fullView(tree);
    for (0..90) |_| {
        try field.step(tree, testing.allocator, .{
            .view = view,
            .zoom = zoom,
            .note_r_px = 6,
            .dt = 1.0 / 60.0,
            .budget = budget,
        });
    }
}

fn agentKeySet(field: *const Field, allocator: std.mem.Allocator) !std.AutoHashMapUnmanaged(u32, void) {
    var set: std.AutoHashMapUnmanaged(u32, void) = .empty;
    try set.ensureTotalCapacity(allocator, @intCast(field.agents.items.len));
    for (field.agents.items) |a| {
        try set.put(allocator, a.key.node, {});
    }
    return set;
}

test "parked camera agent set is stable" {
    const pts = try gridPositions(testing.allocator, 12, 6);
    defer testing.allocator.free(pts);
    var tree = try quadlod.build(testing.allocator, pts);
    defer tree.deinit();
    var field = Field.init(testing.allocator);
    defer field.deinit();

    try settle(&field, tree, 3.0, 200);
    var prev = try agentKeySet(&field, testing.allocator);
    defer prev.deinit(testing.allocator);
    const n = field.agents.items.len;
    try testing.expect(n > 0);

    for (0..60) |_| {
        try field.step(tree, testing.allocator, .{
            .view = fullView(tree),
            .zoom = 3.0,
            .note_r_px = 6,
            .dt = 1.0 / 60.0,
            .budget = 200,
        });
        try testing.expectEqual(n, field.agents.items.len);
        for (field.agents.items) |a| {
            try testing.expect(prev.contains(a.key.node));
        }
    }
}

test "budget caps live agents" {
    const pts = try gridPositions(testing.allocator, 16, 5);
    defer testing.allocator.free(pts);
    var tree = try quadlod.build(testing.allocator, pts);
    defer tree.deinit();
    var field = Field.init(testing.allocator);
    defer field.deinit();

    try settle(&field, tree, 50, 5);
    try testing.expect(field.livingCount() <= 5);
}

test "zoom-in dive does not decrease living agent count" {
    const pts = try gridPositions(testing.allocator, 10, 6);
    defer testing.allocator.free(pts);
    var tree = try quadlod.build(testing.allocator, pts);
    defer tree.deinit();
    var field = Field.init(testing.allocator);
    defer field.deinit();

    try settle(&field, tree, 0.5, 500);
    var prev = field.livingCount();
    var z: f32 = 0.5;
    const view = fullView(tree);
    for (0..40) |_| {
        z *= 1.12;
        try field.step(tree, testing.allocator, .{
            .view = view,
            .zoom = z,
            .note_r_px = 6,
            .dt = 1.0 / 60.0,
            .budget = 500,
        });
        try testing.expect(field.livingCount() >= prev);
        prev = field.livingCount();
    }
}

test "note radius is uniform; mass radius grows then soft-caps" {
    const note_a = cellRadiusPx(6, 1, 1.0, 40);
    const note_b = cellRadiusPx(6, 1, 8.0, 400);
    try testing.expectEqual(note_a, note_b);
    try testing.expectEqual(@as(f32, 6), note_a);
    const mass_a = cellRadiusPx(6, 16, 0.5, 40);
    const mass_b = cellRadiusPx(6, 16, 1.0, 40);
    try testing.expect(mass_b > mass_a);
    const mass_huge = cellRadiusPx(6, 16, 100.0, 400);
    try testing.expectEqual(@as(f32, 40), mass_huge);
}

test "parked camera does not re-select or churn agent keys" {
    const pts = try gridPositions(testing.allocator, 10, 8);
    defer testing.allocator.free(pts);
    var tree = try quadlod.build(testing.allocator, pts);
    defer tree.deinit();
    var field = Field.init(testing.allocator);
    defer field.deinit();
    try settle(&field, tree, 2.0, 200);
    const n = field.agents.items.len;
    const opens = countOpen(&field.sticky);
    for (0..120) |_| {
        try field.step(tree, testing.allocator, .{
            .view = fullView(tree),
            .zoom = 2.0,
            .note_r_px = 6,
            .dt = 1.0 / 60.0,
            .budget = 200,
        });
        try testing.expectEqual(n, field.agents.items.len);
        try testing.expectEqual(opens, countOpen(&field.sticky));
    }
}
