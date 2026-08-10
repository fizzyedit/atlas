//! Fossil A/B: leaf-sample point cloud (`--mode=leaves`). Look-failed — identity churn and a
//! web that did not match drawn marks. Kept for comparison / unit tests only; do not extend as
//! the primary LOD spike. Continuity work redirected to impostor tiles (see organic-lod.md).
//!
//! Every mark is a leaf at its true position, sized point→disc by zoom. Membership is sticky in
//! view; the pyramid fills free budget slots (must not replace the whole set each `lf` step).

const std = @import("std");
const dvui = @import("dvui");
const lod = @import("../lod.zig");

/// Hysteresis on `splitT` for opening a cluster into its children. Same spirit as `agents.zig`:
/// a sharp line, not a zoom-wide band of permanent half-states.
const open_enter: f32 = 0.55;
const open_keep: f32 = 0.45;

/// Preferred minimum screen spacing between marks. World distance is `gap_px / zoom`.
/// Pack rounds may densify down to `pack_gap_floor_px`, but not every frame to zero — that
/// fought the stick pass and rebuilt the whole 3k set continuously (27 fps + pop-in).
const sample_gap_px: f32 = 7.0;
const pack_gap_floor_px: f32 = 3.5;

/// Marks this small are “points” — links fade out against them so the far web does not become a
/// hairball over a dot field.
///
/// Kept above the ring width and comfortable on a 2× framebuffer: at 1.25px a mark is mostly
/// border and vanishes into the clear colour the moment zoom dips.
pub const point_r_px: f32 = 2.5;

/// Fade-*in* only. Membership no longer mass-retires each frame (that fought continuous zoom).
const fade_in_seconds: f32 = 0.22;
/// Per-frame membership churn caps — LOD adjusts *while* zooming, but each frame does a slice.
const max_new_per_frame: usize = 48;
const max_thin_per_frame: usize = 48;
const max_probe_per_frame: usize = 1200;
/// How far solved zoom may drift before we treat density as stale (idle skip ends).
const member_zoom_slack: f32 = 1.08;
const max_dt: f32 = 1.0 / 30.0;
const prox_empty: u32 = std.math.maxInt(u32);

const golden: f32 = 0.6180339887;

pub const Frame = struct {
    lf: f32,
    view: dvui.Rect,
    live: []const dvui.Point = &.{},
    zoom: f32 = 1,
    /// Gap-capped resting note radius at this zoom — the large end of the point→disc mix.
    note_r_px: f32,
    /// Lattice gap on screen; drives how “revealed” discs are vs points.
    gap_px: f32,
    dt: f32,
    budget: usize = 3000,
};

/// One drawn leaf. Always level 0 identity; size and alpha are presentation only.
pub const Mark = struct {
    leaf: u32,
    pos: dvui.Point = .{},
    r_px: f32 = point_r_px,
    alpha: f32 = 0,
    /// 1 = wanted this frame; fades toward this.
    target_alpha: f32 = 0,
    seen: u32 = 0,
};

const Group = struct {
    open: bool,
    seen: u32,
};

pub const Field = struct {
    allocator: std.mem.Allocator,
    marks: std.ArrayListUnmanaged(Mark) = .empty,
    index: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    groups: std.AutoHashMapUnmanaged(u64, Group) = .empty,
    stamp: u32 = 0,
    settled: bool = true,
    budget_bound: bool = false,
    /// Zoom density was last adjusted at. Idle frames skip fill/thin while this holds.
    member_zoom: f32 = 0,
    last_target: usize = 0,
    saturated: bool = false,
    last_view: dvui.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    new_this_frame: usize = 0,
    thin_this_frame: usize = 0,
    probe_this_frame: usize = 0,
    /// Spatial hash for spacing — rebuilt on adjust frames.
    prox_cell: f32 = 1,
    prox_head: std.AutoHashMapUnmanaged(u64, u32) = .empty,
    prox_pos: std.ArrayListUnmanaged(dvui.Point) = .empty,
    prox_next: std.ArrayListUnmanaged(u32) = .empty,

    pub fn init(allocator: std.mem.Allocator) Field {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Field) void {
        self.marks.deinit(self.allocator);
        self.index.deinit(self.allocator);
        self.groups.deinit(self.allocator);
        self.prox_head.deinit(self.allocator);
        self.prox_pos.deinit(self.allocator);
        self.prox_next.deinit(self.allocator);
        self.* = .{ .allocator = self.allocator };
    }

    pub fn reset(self: *Field) void {
        self.marks.clearRetainingCapacity();
        self.index.clearRetainingCapacity();
        self.groups.clearRetainingCapacity();
        self.prox_head.clearRetainingCapacity();
        self.prox_pos.clearRetainingCapacity();
        self.prox_next.clearRetainingCapacity();
        self.settled = true;
        self.member_zoom = 0;
        self.last_target = 0;
        self.saturated = false;
        self.last_view = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
        self.new_this_frame = 0;
        self.thin_this_frame = 0;
        self.probe_this_frame = 0;
    }

    /// Screen radius for every mark this frame — zoom only, never count.
    ///
    /// Always at least `point_r_px`. The gap-capped note radius can sit *below* that when zoomed
    /// out (its own floor is 0.6), and mixing toward it would shrink marks as the reader zooms
    /// in through the start of the reveal band — which is exactly “points disappear on zoom.”
    pub fn markRadiusPx(f: Frame) f32 {
        const reveal = detailReveal(f.gap_px);
        const hi = @max(f.note_r_px, point_r_px);
        return point_r_px + (hi - point_r_px) * reveal;
    }

    /// How far marks have grown off the point floor, 0..1. Links use this so the web stays off
    /// until the field reads as discs rather than dots.
    pub fn revealT(f: Frame) f32 {
        return detailReveal(f.gap_px);
    }

    pub fn step(self: *Field, py: lod.Pyramid, scratch: std.mem.Allocator, f: Frame) !void {
        self.budget_bound = false;
        self.settled = true;
        self.new_this_frame = 0;
        self.thin_this_frame = 0;
        self.probe_this_frame = 0;
        if (py.levels.len == 0) {
            self.marks.clearRetainingCapacity();
            self.index.clearRetainingCapacity();
            return;
        }

        const r_px = markRadiusPx(f);
        const keep_view = inflate(f.view, markKeepMargin(f));
        const zoom = @max(f.zoom, 1e-6);
        const target = densityTarget(f);
        const view_moved = viewDrifted(self.last_view, f.view);
        self.last_view = f.view;

        // Always present: radii track zoom every frame (the LOD read), cull leaves the view.
        self.cullAndResize(keep_view, r_px);

        const zoom_drift = self.member_zoom > 1e-12 and
            (f.zoom > self.member_zoom * member_zoom_slack or f.zoom * member_zoom_slack < self.member_zoom);
        const target_drift = self.last_target > 0 and
            (target > self.last_target + 8 or target + 8 < self.last_target);
        const over = self.marks.items.len > target;
        // Idle when this zoom band is solved — including “under target but spacing-full”.
        // Zooming changes `target`/`member_zoom`, so adjust keeps running in slices.
        if (!view_moved and !zoom_drift and !target_drift and self.saturated and !over and self.marks.items.len > 0) {
            self.fadeIn(f);
            return;
        }

        self.stamp +%= 1;
        try self.proxBegin(pack_gap_floor_px / zoom);
        const preferred_dist = sample_gap_px / zoom;

        // Seed prox with survivors so densify/thin see current spacing.
        for (self.marks.items) |*m| {
            m.seen = self.stamp;
            m.target_alpha = 1;
            try self.proxInsert(m.pos);
        }

        // Zoom out / over-dense: peel a slice of too-close marks (continuous, not a freeze).
        if (over or (zoom_drift and f.zoom < self.member_zoom)) {
            self.thinSpacing(preferred_dist, target);
        }

        // Zoom in / under-dense: add a slice of samples toward the zoom's target count.
        var emitted: usize = self.marks.items.len;
        if (emitted < target) {
            var fill_f = f;
            fill_f.budget = target;
            const new0 = self.new_this_frame;
            try self.fillSamples(py, scratch, fill_f, r_px, preferred_dist, &emitted, false);
            if (emitted < target and self.new_this_frame == new0) {
                self.probe_this_frame = @min(self.probe_this_frame, max_probe_per_frame / 2);
                try self.fillSamples(py, scratch, fill_f, r_px, pack_gap_floor_px / zoom, &emitted, true);
            }
            if (emitted < target and self.new_this_frame == new0 and emitted * 2 <= target) {
                self.probe_this_frame = 0;
                try self.fillSamples(py, scratch, fill_f, r_px, 0, &emitted, true);
            }
        }

        if (self.marks.items.len >= f.budget) self.budget_bound = true;
        // Idle when this zoom's density is met, or spacing admits nothing more right now.
        // Still mid-churn → not saturated, so the next frame continues the slice.
        if (self.new_this_frame > 0 or self.thin_this_frame > 0) {
            self.saturated = false;
            self.settled = false;
        } else if (self.marks.items.len >= target) {
            self.saturated = true;
        } else if (self.probe_this_frame >= max_probe_per_frame) {
            // Probe cap hit with room left — continue next frame (do not idle-spin forever).
            self.saturated = false;
            self.settled = false;
        } else {
            // Under target but no adds (preferred spacing full) — stable for this zoom band.
            self.saturated = true;
        }

        self.member_zoom = f.zoom;
        self.last_target = target;
        self.fadeIn(f);
        self.pruneGroups();
    }

    const Pending = struct {
        level: u32,
        index: u32,
    };

    fn cullAndResize(self: *Field, keep_view: dvui.Rect, r_px: f32) void {
        var i: usize = 0;
        while (i < self.marks.items.len) {
            const m = &self.marks.items[i];
            if (!overlaps(keep_view, m.pos, 0)) {
                self.removeAt(i);
                self.saturated = false;
                continue;
            }
            m.r_px = r_px;
            m.target_alpha = 1;
            i += 1;
        }
    }

    fn thinSpacing(self: *Field, min_dist: f32, target: usize) void {
        if (min_dist <= 0 or self.marks.items.len <= target) return;
        // Rebuild prox as we keep marks; drop a capped number of too-close ones.
        self.proxBegin(self.prox_cell) catch return;
        var i: usize = 0;
        while (i < self.marks.items.len) {
            const m = self.marks.items[i];
            const can_thin = self.thin_this_frame < max_thin_per_frame and
                self.marks.items.len > target;
            if (can_thin and self.tooClose(m.pos, min_dist)) {
                self.removeAt(i);
                self.thin_this_frame += 1;
                self.settled = false;
                self.saturated = false;
                continue;
            }
            self.proxInsert(m.pos) catch {};
            i += 1;
        }
    }

    fn removeAt(self: *Field, i: usize) void {
        const leaf = self.marks.items[i].leaf;
        _ = self.index.remove(leaf);
        const last = self.marks.items.len - 1;
        if (i != last) {
            self.marks.items[i] = self.marks.items[last];
            self.index.put(self.allocator, self.marks.items[i].leaf, @intCast(i)) catch {};
        }
        self.marks.items.len = last;
    }

    fn proxBegin(self: *Field, cell: f32) !void {
        self.prox_cell = @max(cell, 1e-6);
        self.prox_pos.clearRetainingCapacity();
        self.prox_next.clearRetainingCapacity();
        self.prox_head.clearRetainingCapacity();
    }

    fn proxInsert(self: *Field, pos: dvui.Point) !void {
        const key = proxKey(pos, self.prox_cell);
        const idx: u32 = @intCast(self.prox_pos.items.len);
        const prev = self.prox_head.get(key) orelse prox_empty;
        try self.prox_pos.append(self.allocator, pos);
        try self.prox_next.append(self.allocator, prev);
        try self.prox_head.put(self.allocator, key, idx);
    }

    fn fillSamples(
        self: *Field,
        py: lod.Pyramid,
        scratch: std.mem.Allocator,
        f: Frame,
        r_px: f32,
        min_dist: f32,
        emitted: *usize,
        pack: bool,
    ) !void {
        // BFS queue — DFS was diving into one island and spending the whole budget on its lattice.
        var queue: std.ArrayListUnmanaged(Pending) = .empty;
        defer queue.deinit(scratch);
        var head: usize = 0;

        const top = py.maxLevel();
        for (0..py.levels[top].len) |i| {
            try queue.append(scratch, .{ .level = @intCast(top), .index = @intCast(i) });
        }

        while (head < queue.items.len) {
            const item = queue.items[head];
            head += 1;
            if (emitted.* >= f.budget) {
                self.budget_bound = true;
                break;
            }
            const level: usize = item.level;
            const c = py.levels[level][item.index];
            if (!overlaps(f.view, c.pos, c.radius)) continue;

            if (level == 0) {
                if (self.probe_this_frame >= max_probe_per_frame) {
                    self.settled = false;
                    return;
                }
                self.probe_this_frame += 1;
                const pos: dvui.Point = if (item.index < f.live.len) f.live[item.index] else c.pos;
                if (self.tooClose(pos, min_dist)) continue;
                if (try self.wantLeaf(item.index, f, r_px)) emitted.* += 1;
                continue;
            }

            const kids = py.kidsOf(level, item.index);
            const key = groupKey(item.level, item.index);
            var g = self.groups.get(key) orelse Group{ .open = false, .seen = 0 };
            const split = py.splitT(level, item.index, f.lf);
            const split_open = kids.len > 0 and (if (g.open) split > open_keep else split > open_enter);
            // Only descend when children are actually resolvable on screen. Otherwise one open
            // island becomes a solid uniform grid of every leaf until the budget dies.
            // Pack rounds densify by sampling more leaves from the closed cluster instead.
            const span = @max(c.spread, c.radius * 0.35) * 2;
            const child_gap_px = (span / @sqrt(@as(f32, @floatFromInt(@max(kids.len, 1))))) * f.zoom;
            const resolvable = child_gap_px >= sample_gap_px * 0.9;
            const affordable = emitted.* + (queue.items.len - head) + kids.len <= f.budget;
            const want_open = split_open and resolvable and affordable;
            if (split_open and resolvable and !affordable) self.budget_bound = true;
            g.open = want_open;
            g.seen = self.stamp;
            try self.groups.put(self.allocator, key, g);

            if (g.open) {
                for (kids) |kid| {
                    try queue.append(scratch, .{ .level = @intCast(level - 1), .index = kid });
                }
                continue;
            }

            const want_k = sampleCount(c, f, f.budget - emitted.*, pack);
            if (want_k == 0) continue;

            const ranks = try scratch.alloc(u32, want_k);
            defer scratch.free(ranks);
            var got: usize = 0;
            const n = fillSampleRanks(c.count, want_k, ranks);
            for (ranks[0..n]) |rank| {
                if (got >= want_k or emitted.* >= f.budget) {
                    if (emitted.* >= f.budget) self.budget_bound = true;
                    break;
                }
                if (self.probe_this_frame >= max_probe_per_frame) {
                    self.settled = false;
                    return;
                }
                self.probe_this_frame += 1;
                const leaf = py.leafAtRank(level, item.index, rank);
                if (self.index.get(leaf)) |slot| {
                    if (self.marks.items[slot].seen == self.stamp) {
                        got += 1;
                        continue;
                    }
                }
                const pos: dvui.Point = if (leaf < f.live.len) f.live[leaf] else .{ .x = 0, .y = 0 };
                if (self.tooClose(pos, min_dist)) continue;
                if (try self.wantLeaf(leaf, f, r_px)) {
                    emitted.* += 1;
                    got += 1;
                }
            }
        }
    }

    fn tooClose(self: *const Field, pos: dvui.Point, min_dist: f32) bool {
        if (min_dist <= 0) return false;
        if (self.prox_pos.items.len == 0) return false;
        const d2 = min_dist * min_dist;
        const cell = self.prox_cell;
        const reach: i32 = @intFromFloat(@ceil(min_dist / cell));
        const ix: i32 = @intFromFloat(@floor(pos.x / cell));
        const iy: i32 = @intFromFloat(@floor(pos.y / cell));
        var dy: i32 = -reach;
        while (dy <= reach) : (dy += 1) {
            var dx: i32 = -reach;
            while (dx <= reach) : (dx += 1) {
                const key = proxCellKey(ix + dx, iy + dy);
                var idx = self.prox_head.get(key) orelse continue;
                while (idx != prox_empty) {
                    const p = self.prox_pos.items[idx];
                    const ox = p.x - pos.x;
                    const oy = p.y - pos.y;
                    if (ox * ox + oy * oy < d2) return true;
                    idx = self.prox_next.items[idx];
                }
            }
        }
        return false;
    }

    /// Mark a leaf as wanted this frame. Returns true when it consumes a budget slot (newly
    /// wanted this stamp — not a duplicate want).
    fn wantLeaf(self: *Field, leaf: u32, f: Frame, r_px: f32) !bool {
        const pos: dvui.Point = if (leaf < f.live.len) f.live[leaf] else .{ .x = 0, .y = 0 };
        if (self.index.get(leaf)) |slot| {
            const m = &self.marks.items[slot];
            if (m.seen == self.stamp) return false; // already counted
            m.pos = pos;
            m.r_px = r_px;
            m.target_alpha = 1;
            m.seen = self.stamp;
            try self.proxInsert(pos);
            return true;
        }
        // Rate-limit brand-new marks so densify trickles in as fading dots.
        if (self.new_this_frame >= max_new_per_frame) {
            self.settled = false;
            return false;
        }
        try self.index.put(self.allocator, leaf, @intCast(self.marks.items.len));
        try self.marks.append(self.allocator, .{
            .leaf = leaf,
            .pos = pos,
            .r_px = r_px,
            .alpha = 0,
            .target_alpha = 1,
            .seen = self.stamp,
        });
        try self.proxInsert(pos);
        self.new_this_frame += 1;
        self.settled = false;
        return true;
    }

    /// Ease newcomers up. Removals are explicit (cull / thin) — not a per-frame want rewrite.
    fn fadeIn(self: *Field, f: Frame) void {
        const dt = @min(@max(f.dt, 0), max_dt);
        const step_a = if (fade_in_seconds > 0 and dt > 0) dt / fade_in_seconds else 1;
        for (self.marks.items) |*m| {
            if (m.alpha < 1) {
                m.alpha = @min(m.alpha + step_a, 1);
                if (m.alpha < 1) self.settled = false;
            }
        }
    }

    fn pruneGroups(self: *Field) void {
        if (self.groups.count() < 4096) return;
        var stale: std.ArrayListUnmanaged(u64) = .empty;
        defer stale.deinit(self.allocator);
        var it = self.groups.iterator();
        while (it.next()) |e| {
            if (self.stamp -% e.value_ptr.seen > 600) {
                stale.append(self.allocator, e.key_ptr.*) catch break;
            }
        }
        for (stale.items) |k| _ = self.groups.remove(k);
    }

    /// For `gatherWeb`: a cluster is open when the cloud field has opened it (hysteresis), so
    /// link refine agrees with which leaves are being sampled vs descended.
    pub fn bind(self: *const Field, py: *const lod.Pyramid) Binding {
        return .{ .field = self, .py = py };
    }
};

pub const Binding = struct {
    field: *const Field,
    py: *const lod.Pyramid,

    pub fn marks(self: *const Binding) lod.Marks {
        return .{ .ctx = self, .isOpen = isOpen, .posOf = posOf };
    }

    fn isOpen(ctx: *const anyopaque, level: u32, index: u32) bool {
        const self: *const Binding = @ptrCast(@alignCast(ctx));
        const g = self.field.groups.get(groupKey(level, index)) orelse return false;
        return g.open;
    }

    fn posOf(ctx: *const anyopaque, level: u32, index: u32) dvui.Point {
        const self: *const Binding = @ptrCast(@alignCast(ctx));
        // Cloud marks are leaves; coarse ends fall back to resting cluster centres.
        if (level == 0) {
            if (self.field.index.get(index)) |slot| return self.field.marks.items[slot].pos;
        }
        if (level < self.py.levels.len and index < self.py.levels[level].len) {
            return self.py.levels[level][index].pos;
        }
        return .{ .x = 0, .y = 0 };
    }
};

fn groupKey(level: u32, index: u32) u64 {
    return (@as(u64, level) << 32) | index;
}

/// How many marks this zoom/view wants — screen area / preferred gap², capped by budget.
fn densityTarget(f: Frame) usize {
    if (f.budget == 0) return 0;
    const sw = @max(f.view.w * f.zoom, 1);
    const sh = @max(f.view.h * f.zoom, 1);
    const cell = sample_gap_px * sample_gap_px;
    const by_gap: usize = @intFromFloat(@max(@floor((sw * sh) / cell), 1));
    return @min(f.budget, by_gap);
}

fn proxKey(pos: dvui.Point, cell: f32) u64 {
    const ix: i32 = @intFromFloat(@floor(pos.x / cell));
    const iy: i32 = @intFromFloat(@floor(pos.y / cell));
    return proxCellKey(ix, iy);
}

fn proxCellKey(ix: i32, iy: i32) u64 {
    const ux: u32 = @bitCast(ix);
    const uy: u32 = @bitCast(iy);
    return (@as(u64, ux) << 32) | uy;
}

fn viewDrifted(prev: dvui.Rect, next: dvui.Rect) bool {
    // Pan only. Zoom changes `w`/`h` every tick and is handled by radius updates + rebalance.
    if (prev.w <= 0 or prev.h <= 0) return true;
    const pcx = prev.x + prev.w * 0.5;
    const pcy = prev.y + prev.h * 0.5;
    const ncx = next.x + next.w * 0.5;
    const ncy = next.y + next.h * 0.5;
    const span = @max(@max(prev.w, prev.h), 1);
    const dx = ncx - pcx;
    const dy = ncy - pcy;
    return dx * dx + dy * dy > (span * 0.08) * (span * 0.08);
}

fn detailReveal(gap_px: f32) f32 {
    // Match render_bench_world's detail band so cloud marks and grid-mode notes agree.
    const lo: f32 = 34;
    const hi: f32 = 64;
    const t = std.math.clamp((gap_px - lo) / (hi - lo), 0, 1);
    return t * t * (3 - 2 * t);
}

fn sampleCount(c: lod.Cluster, f: Frame, remaining: usize, pack: bool) usize {
    if (remaining == 0 or c.count == 0) return 0;
    const screen_span = @max(c.spread, c.radius * 0.35) * f.zoom * 2;
    const by_area: usize = @intFromFloat(@max(@floor(screen_span / sample_gap_px), 1));
    if (pack) {
        // Modest bite per closed cluster per BFS pass so the wave stays fair across islands
        // while still climbing toward the budget over pack rounds.
        const bite = @max(by_area * 4, 16);
        return @min(@min(bite, remaining), c.count);
    }
    return @min(@min(@max(by_area, 1), remaining), c.count);
}

/// Stable sample ranks in `[0, count)`. Slot `s` always maps to the same rank for a given
/// `count`, so raising `k` only *adds* leaves and lowering `k` only drops the highest slots.
fn fillSampleRanks(count: u32, k: usize, out: []u32) usize {
    if (count == 0 or k == 0) return 0;
    if (k >= count) {
        for (0..count) |i| out[i] = @intCast(i);
        return count;
    }
    var n: usize = 0;
    var s: usize = 0;
    while (s < k and n < out.len) : (s += 1) {
        const rank: u32 = @intFromFloat(@mod(
            @as(f32, @floatFromInt(s)) * golden * @as(f32, @floatFromInt(count)),
            @as(f32, @floatFromInt(count)),
        ));
        var unique = true;
        for (out[0..n]) |r| {
            if (r == rank) {
                unique = false;
                break;
            }
        }
        if (!unique) continue;
        out[n] = rank;
        n += 1;
    }
    // If collisions ate slots, fill sequentially from 0.
    var probe: u32 = 0;
    while (n < k and probe < count) : (probe += 1) {
        var unique = true;
        for (out[0..n]) |r| {
            if (r == probe) {
                unique = false;
                break;
            }
        }
        if (!unique) continue;
        out[n] = probe;
        n += 1;
    }
    return n;
}

fn overlaps(view: dvui.Rect, pos: dvui.Point, radius: f32) bool {
    return pos.x + radius >= view.x and pos.x - radius <= view.x + view.w and
        pos.y + radius >= view.y and pos.y - radius <= view.y + view.h;
}

fn inflate(r: dvui.Rect, m: f32) dvui.Rect {
    return .{ .x = r.x - m, .y = r.y - m, .w = r.w + m * 2, .h = r.h + m * 2 };
}

/// World margin for keeping a mark across small camera moves / zoom steps.
fn markKeepMargin(f: Frame) f32 {
    // ~half a panel in world units, floored so a tiny view still has slack.
    const by_view = @min(f.view.w, f.view.h) * 0.25;
    const by_px = 40.0 / @max(f.zoom, 1e-6);
    return @max(by_view, by_px);
}

// -- tests ------------------------------------------------------------------------

const testing = std.testing;
const multilevel = @import("multilevel.zig");

fn fixture(allocator: std.mem.Allocator) !multilevel.Ladder {
    const maps = try allocator.alloc([]u32, 1);
    maps[0] = try allocator.alloc(u32, 4);
    maps[0][0] = 0;
    maps[0][1] = 0;
    maps[0][2] = 1;
    maps[0][3] = 1;
    const counts = try allocator.alloc(usize, 2);
    counts[0] = 4;
    counts[1] = 2;
    return .{ .maps = maps, .counts = counts };
}

const everywhere: dvui.Rect = .{ .x = -1e9, .y = -1e9, .w = 2e9, .h = 2e9 };

fn testPyramid(allocator: std.mem.Allocator) !lod.Pyramid {
    var ladder = try fixture(allocator);
    defer ladder.deinit(allocator);
    const pos = [_]dvui.Point{
        .{ .x = -10, .y = 0 },
        .{ .x = -20, .y = 0 },
        .{ .x = 10, .y = 0 },
        .{ .x = 20, .y = 0 },
    };
    return lod.build(allocator, ladder, &pos, &.{});
}

fn frameAt(lf: f32, gap_px: f32, dt: f32, budget: usize) Frame {
    return .{
        .lf = lf,
        .view = everywhere,
        .zoom = 1,
        .note_r_px = 9,
        .gap_px = gap_px,
        .dt = dt,
        .budget = budget,
    };
}

fn settle(field: *Field, py: lod.Pyramid, lf: f32, gap_px: f32) !void {
    for (0..600) |_| {
        try field.step(py, testing.allocator, frameAt(lf, gap_px, 1.0 / 60.0, 1000));
        if (field.settled) return;
    }
}

test "sample ranks are stable when k grows" {
    var a: [8]u32 = undefined;
    var b: [8]u32 = undefined;
    const n3 = fillSampleRanks(100, 3, a[0..3]);
    const n5 = fillSampleRanks(100, 5, b[0..5]);
    try testing.expect(n3 >= 3);
    try testing.expect(n5 >= 5);
    // Every rank from the smaller set appears in the larger set.
    for (a[0..n3]) |r| {
        var found = false;
        for (b[0..n5]) |r2| {
            if (r == r2) {
                found = true;
                break;
            }
        }
        try testing.expect(found);
    }
}

test "leafAtRank covers every note under a cluster exactly once" {
    var py = try testPyramid(testing.allocator);
    defer py.deinit();
    var seen = [_]bool{false} ** 4;
    for (0..2) |parent| {
        const count = py.levels[1][parent].count;
        for (0..count) |rank| {
            const leaf = py.leafAtRank(1, @intCast(parent), @intCast(rank));
            try testing.expect(leaf < 4);
            try testing.expect(!seen[leaf]);
            seen[leaf] = true;
        }
    }
    for (seen) |s| try testing.expect(s);
}

test "zoomed in, every mark is a leaf and all four notes appear" {
    var py = try testPyramid(testing.allocator);
    defer py.deinit();
    var field = Field.init(testing.allocator);
    defer field.deinit();

    // Large gap → discs revealed; lf 0 → everything open.
    try settle(&field, py, 0, 80);
    try testing.expectEqual(@as(usize, 4), field.marks.items.len);
    for (field.marks.items) |m| {
        try testing.expect(m.leaf < 4);
        try testing.expect(m.alpha > 0.9);
    }
}

test "zoomed out, marks stay leaves — never cluster discs" {
    var py = try testPyramid(testing.allocator);
    defer py.deinit();
    var field = Field.init(testing.allocator);
    defer field.deinit();

    try settle(&field, py, @floatFromInt(py.maxLevel()), 8);
    try testing.expect(field.marks.items.len > 0);
    try testing.expect(field.marks.items.len <= 4);
    for (field.marks.items) |m| try testing.expect(m.leaf < 4);
    // Far: point-sized, not note-sized.
    const r = Field.markRadiusPx(frameAt(1, 8, 0, 1000));
    try testing.expect(r < 3);
}

test "budget caps the cloud" {
    var py = try testPyramid(testing.allocator);
    defer py.deinit();
    var field = Field.init(testing.allocator);
    defer field.deinit();

    for (0..120) |_| {
        try field.step(py, testing.allocator, frameAt(0, 80, 1.0 / 60.0, 2));
    }
    try testing.expect(field.marks.items.len <= 2);
}

test "far zoom still spends the budget when leaves remain" {
    var py = try testPyramid(testing.allocator);
    defer py.deinit();
    var field = Field.init(testing.allocator);
    defer field.deinit();

    // Tiny zoom makes preferred world-gap huge (only one note survives the first pass).
    // Pack rounds must relax spacing and spend the full budget on the remaining leaves.
    for (0..120) |_| {
        var f = frameAt(@floatFromInt(py.maxLevel()), 8, 1.0 / 60.0, 4);
        f.zoom = 0.01;
        try field.step(py, testing.allocator, f);
    }
    try testing.expectEqual(@as(usize, 4), field.marks.items.len);
}

test "spacing-saturated field stops refilling every frame" {
    var py = try testPyramid(testing.allocator);
    defer py.deinit();
    var field = Field.init(testing.allocator);
    defer field.deinit();

    var f = frameAt(@floatFromInt(py.maxLevel()), 8, 1.0 / 60.0, 1000);
    f.zoom = 0.05;
    for (0..30) |_| try field.step(py, testing.allocator, f);
    try testing.expect(field.saturated or field.marks.items.len >= 4);

    const stamp_before = field.stamp;
    for (0..30) |_| try field.step(py, testing.allocator, f);
    // Cheap path must not keep advancing the membership stamp while idle.
    try testing.expectEqual(stamp_before, field.stamp);
}

test "zoom-in densifies membership across frames" {
    var py = try testPyramid(testing.allocator);
    defer py.deinit();
    var field = Field.init(testing.allocator);
    defer field.deinit();

    var f = frameAt(@floatFromInt(py.maxLevel()), 8, 1.0 / 60.0, 1000);
    f.zoom = 0.02;
    for (0..40) |_| try field.step(py, testing.allocator, f);
    const n_lo = field.marks.items.len;
    try testing.expect(n_lo > 0);

    // Continuous zoom-in must keep adjusting (not freeze until quiet).
    f.zoom = 1.0;
    f.gap_px = 40;
    f.lf = 0;
    for (0..80) |_| try field.step(py, testing.allocator, f);
    try testing.expect(field.marks.items.len >= n_lo);
    try testing.expect(field.marks.items.len <= 4);
}

test "per-frame membership churn stays capped" {
    var py = try testPyramid(testing.allocator);
    defer py.deinit();
    var field = Field.init(testing.allocator);
    defer field.deinit();

    var f = frameAt(0, 80, 1.0 / 60.0, 1000);
    f.zoom = 1;
    try field.step(py, testing.allocator, f);
    try testing.expect(field.new_this_frame <= max_new_per_frame);
    try testing.expect(field.thin_this_frame <= max_thin_per_frame);
}

test "survivors keep their leaf identity when the cloud densifies" {
    var py = try testPyramid(testing.allocator);
    defer py.deinit();
    var field = Field.init(testing.allocator);
    defer field.deinit();

    // Coarse first.
    try settle(&field, py, @floatFromInt(py.maxLevel()), 8);
    var before: std.AutoHashMap(u32, void) = .init(testing.allocator);
    defer before.deinit();
    for (field.marks.items) |m| try before.put(m.leaf, {});

    // Open up.
    try settle(&field, py, 0, 80);
    var it = before.keyIterator();
    while (it.next()) |leaf| {
        try testing.expect(field.index.contains(leaf.*));
    }
}

test "rapid zoom does not accumulate ghost marks past the budget" {
    var py = try testPyramid(testing.allocator);
    defer py.deinit();
    var field = Field.init(testing.allocator);
    defer field.deinit();

    const top: f32 = @floatFromInt(py.maxLevel());
    const budget: usize = 3;
    // Alternate coarse/fine every frame — the old fade-out path stacked cohorts here.
    for (0..60) |i| {
        const lf: f32 = if (i % 2 == 0) top else 0;
        try field.step(py, testing.allocator, frameAt(lf, 40, 1.0 / 60.0, budget));
        try testing.expect(field.marks.items.len <= budget);
    }
}

test "in-view marks survive an lf jump that would resample the hierarchy" {
    var py = try testPyramid(testing.allocator);
    defer py.deinit();
    var field = Field.init(testing.allocator);
    defer field.deinit();

    // Coarse sample set.
    try settle(&field, py, @floatFromInt(py.maxLevel()), 8);
    try testing.expect(field.marks.items.len > 0);

    var before: std.AutoHashMap(u32, void) = .init(testing.allocator);
    defer before.deinit();
    for (field.marks.items) |m| try before.put(m.leaf, {});

    // Jump lf as a fast zoom would — hierarchical fill alone used to drop these.
    for (0..10) |_| {
        try field.step(py, testing.allocator, frameAt(0.5, 20, 1.0 / 60.0, 1000));
    }

    var it = before.keyIterator();
    while (it.next()) |leaf| {
        try testing.expect(field.index.contains(leaf.*));
    }
}
