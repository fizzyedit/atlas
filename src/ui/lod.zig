//! Zoom levels of detail for the graph, built from the layout's own coarsening ladder.
//!
//! Zoomed out far enough, individual notes are smaller than the gap between them — they overlap,
//! nothing is readable, and drawing all of them is both slow and useless. What the reader wants
//! there is regions, not notes.
//!
//! The multilevel solver already computes exactly that hierarchy on its way to a layout (see
//! `multilevel.Ladder`): each level is a coarser grouping of the one below, and groups are formed
//! by *link* structure, so a cluster marker stands for a set of notes that genuinely belong
//! together rather than an arbitrary spatial bucket. This file turns that ladder into something
//! the draw pass can use: a position and a radius per group, and a rule for which level suits
//! the current zoom.
//!
//! Positions are derived bottom-up from the *final* node positions rather than kept from the
//! coarse solve, so a marker always sits at the centre of what it actually represents — the two
//! can drift apart, because packing and snapping move nodes after the ladder is built.
//!
//! One level is chosen for the whole view — see `levelFor` — from two things: whether that
//! level's clusters are far enough apart on screen to be told apart, and whether drawing them
//! fits a fixed per-frame budget. The budget is the half that makes this scale: a vault of any
//! size draws a bounded number of things per frame, because the level rises until it does.
//!
//! Deciding it per *region* instead is the more honest answer to the legibility half, and this
//! file used to do that — a vault is never uniformly dense, and one level has to be wrong
//! somewhere. It was given up for two reasons. A per-region answer puts merged and unmerged
//! things on screen beside each other, and it offers no handle on total cost: every region can be
//! locally reasonable while the frame as a whole draws far too much. What makes being locally
//! wrong tolerable is that a merged region is not drawn as an abstract marker but as a baked
//! picture of itself — see `impostor.zig` — so a dense cluster at a coarse level still looks like
//! that dense cluster.

const std = @import("std");
const dvui = @import("dvui");
const multilevel = @import("multilevel.zig");

/// Stop coarsening once a level is this small — few enough that drawing all of them is free at
/// any zoom, and coarser groupings would say nothing about the vault's shape.
const coarsest_clusters: usize = 48;
/// Share of the level below a spatial pass aims for. See `bucketByPosition`.
///
/// Was 0.2 (≈5× drop per level), which left too few rungs between overview masses and notes —
/// zoom felt like large hubs bursting into dust. ~0.5 aims for roughly half each pass so the
/// pyramid is a sliding scale of coarseness; clumped vaults still take several passes.
const spatial_shrink: f32 = 0.5;
/// Hard ceiling on levels, so a pathological arrangement cannot build an unbounded pyramid.
const max_levels: usize = 48;

/// A link between two clusters at the same level. At level 0 these are the vault's own links,
/// index for index; above that, one stands for every link running between the two regions.
pub const CEdge = struct { a: u32, b: u32 };

/// One drawn link, with its ends already resolved to whatever stands for them.
pub const Link = struct {
    from: dvui.Point,
    to: dvui.Point,
    /// The level each end came to rest at. What the drawn mark at that end is *sized* from, so
    /// the caller can stop the line at the mark's edge instead of running it to the centre.
    from_level: u32 = 0,
    to_level: u32 = 0,
    /// Which cluster at that level each end resolved to. Carried alongside the position because a
    /// caller animating the marks — see `agents.zig` — has to look each end up by identity to find
    /// where its bubble currently is, and a point cannot be looked up.
    from_index: u32 = 0,
    to_index: u32 = 0,
    /// Index into the level-0 link list when this *is* one, otherwise `no_edge` — a coarse link
    /// stands for many and has no single animation state to sweep.
    edge: u32,
};

pub const no_edge: u32 = std.math.maxInt(u32);

/// Where the drawn marks are, asked of something outside the pyramid.
///
/// `gatherWeb` has to terminate every line on whatever the reader can actually see at that end,
/// and by default it works that out from `splitT` and the hierarchy's resting positions. A caller
/// that animates the marks instead — merging them, springing them about — knows both answers
/// better than the pyramid does, and a web computed from the pyramid's answers while the marks sit
/// somewhere else is a web whose lines miss their ends.
///
/// `isOpen` says whether a cluster has dissolved into its children; `posOf` says where the mark
/// for one currently is. Both are asked only about clusters the descent reaches, which is what is
/// on screen.
pub const Marks = struct {
    ctx: *const anyopaque,
    isOpen: *const fn (ctx: *const anyopaque, level: u32, index: u32) bool,
    posOf: *const fn (ctx: *const anyopaque, level: u32, index: u32) dvui.Point,
};

/// One coarse node: where to draw it, how big the region it stands for is, and how many notes
/// are inside it.
pub const Cluster = struct {
    pos: dvui.Point = .{},
    /// Distance from `pos` to the furthest note it contains. What a click zooms the camera to
    /// frame — framing has to include everything, outliers and all.
    radius: f32 = 0,
    /// RMS distance of the notes inside from `pos` — where the *mass* is, rather than where the
    /// furthest straggler is.
    ///
    /// `radius` is the wrong size to draw at. One note off on its own stretches it across the
    /// whole vault while saying nothing about where the cluster actually is, so markers sized
    /// that way overlap enormously and, being translucent, pile up into flat fog with no
    /// structure left in it. Spread is dominated by the bulk instead, so a marker covers the
    /// part of the region that is actually populated.
    spread: f32 = 0,
    count: u32 = 0,
};

pub const Pyramid = struct {
    allocator: std.mem.Allocator,
    /// `levels[0]` is the original notes; each subsequent level is coarser. Always at least one.
    levels: [][]Cluster = &.{},
    /// `maps[L][i]` is the index at level `L + 1` of level-`L` cluster `i`. Owned, because the
    /// pyramid outlives the ladder it starts from and continues past where the ladder ends.
    maps: [][]u32 = &.{},
    /// `maps` inverted, in CSR form: the children of level-`L` cluster `i` are the level-`L - 1`
    /// indices `kids[L][kid_start[L][i]..kid_start[L][i + 1]]`. Entry 0 of each is empty — level
    /// 0 has no children. Descending is what `select` does on every frame, so it is worth the
    /// one-off O(n) per level to make it a slice lookup.
    kid_start: [][]u32 = &.{},
    kids: [][]u32 = &.{},

    /// Links between the clusters of each level. `edges[0]` is the vault's own link list; each
    /// level above coalesces it, so two regions are joined once if anything inside them is
    /// linked at all, however many links that stands for.
    edges: [][]CEdge = &.{},
    /// `edges[L]` refined onto the level below, in CSR form: coarse link `i` at level `L` stands
    /// for the level-`L - 1` links `edge_kids[L][edge_kid_start[L][i]..[i + 1]]`.
    edge_kid_start: [][]u32 = &.{},
    edge_kids: [][]u32 = &.{},
    /// Links that vanish into a cluster rather than joining two of them: for level-`L` cluster
    /// `i`, the level-`L - 1` links with both ends inside it, as
    /// `inner[L][inner_start[L][i]..[i + 1]]`. These have no coarse link to hang off — a link
    /// inside a region isn't between regions — so they are reached by descending the cluster,
    /// and are what makes a region's own web appear as it opens up.
    inner_start: [][]u32 = &.{},
    inner: [][]u32 = &.{},
    /// `edges[L]` indexed the other way, in CSR form: the links touching level-`L` cluster `i` are
    /// `inc[L][inc_start[L][i]..[i + 1]]`.
    ///
    /// What lets a patch of the world find its own links. A tile has to draw the links crossing it
    /// and knows only which clusters are in it, and scanning a level's whole link list once per
    /// tile is the one cost that would make tiles worse than drawing everything. Each link appears
    /// under both its ends, so a tile that holds only one of them still finds it.
    inc_start: [][]u32 = &.{},
    inc: [][]u32 = &.{},

    /// World-space extent of the whole graph.
    world_span: f32 = 0,
    /// Typical world-space distance between neighbouring clusters at each level. Increases with
    /// level; multiply by zoom for the gap on screen. Both halves of `levelFor` rest on it — it
    /// says whether a level is legible, and, squared, how many of its clusters a view holds.
    ///
    /// Measured as the *median distance from a cluster to its nearest neighbour at the same level*
    /// — see `measureLevels`. That is literally the question both halves ask, and measuring
    /// anything else is how the budget stops being a budget.
    ///
    /// It used to be read off the hierarchy instead: a level's clusters are its parents' children,
    /// so how far apart they sit is `2 * spread / sqrt(kids)` averaged over the parents. That is
    /// only true when a parent's children are its spatial neighbours, and the ladder does not
    /// promise that — it matches by *link* structure, so a note's partner is wherever the layout
    /// happened to put the thing it links to, across the island or in another one. On a 500k synth
    /// vault of packed islands it made `spacing[0]` 4315 world units where neighbouring notes are
    /// about one lattice cell apart, so `levelFor` believed 308 notes were on screen where 38 747
    /// were, dropped to level 0, and drew a quarter of a million discs at 6 fps. The bound the
    /// whole hierarchy exists to provide was measured against a number that did not mean what it
    /// said.
    ///
    /// Nearest-neighbour distance is a *local* measure, so where a vault is islands with air
    /// between them it reports the density inside an island and `view_area / spacing²` therefore
    /// over-estimates how many are on screen. That bias is deliberate and is the safe direction:
    /// it makes the level coarser than strictly needed over empty space, where there is nothing to
    /// look at anyway, rather than finer than affordable over a dense one.
    spacing: []f32 = &.{},
    /// Drawn things per cluster at each level: the cluster itself plus its share of that level's
    /// coalesced links. What turns a count of visible clusters into a count of visible *work*.
    per_cluster: []f32 = &.{},

    pub fn deinit(self: *Pyramid) void {
        self.allocator.free(self.spacing);
        self.allocator.free(self.per_cluster);
        for (self.levels) |l| self.allocator.free(l);
        self.allocator.free(self.levels);
        for (self.maps) |m| self.allocator.free(m);
        self.allocator.free(self.maps);
        for (self.kid_start) |s| self.allocator.free(s);
        self.allocator.free(self.kid_start);
        for (self.kids) |k| self.allocator.free(k);
        self.allocator.free(self.kids);
        freeJagged(self.allocator, CEdge, self.edges);
        freeJagged(self.allocator, u32, self.edge_kid_start);
        freeJagged(self.allocator, u32, self.edge_kids);
        freeJagged(self.allocator, u32, self.inner_start);
        freeJagged(self.allocator, u32, self.inner);
        freeJagged(self.allocator, u32, self.inc_start);
        freeJagged(self.allocator, u32, self.inc);
        self.* = .{ .allocator = self.allocator };
    }

    /// Coarsest level is the last one.
    pub fn maxLevel(self: Pyramid) usize {
        return self.levels.len - 1;
    }

    /// The cluster at `level` containing level-0 node `i`.
    pub fn clusterOf(self: Pyramid, i: usize, level: usize) usize {
        var idx: u32 = @intCast(i);
        for (self.maps[0..@min(level, self.maps.len)]) |m| idx = m[idx];
        return idx;
    }

    /// The one level the whole view is drawn at, as a fraction — 2.35 means "level 2, a third of
    /// the way toward level 3", and the two are cross-faded.
    ///
    /// Two things decide it, and the coarser of the two wins.
    ///
    ///   • *Legibility.* Clusters at level `L` sit about `spacing[L]` apart in the world, so
    ///     `spacing[L] * zoom` apart on screen. Below `min_gap_px` they overlap and the level is
    ///     showing detail no reader can extract; the finest level clearing that gap is the finest
    ///     one worth drawing.
    ///
    ///   • *Cost.* A view of `view_area` holds about `view_area / spacing[L]²` of level `L`'s
    ///     clusters — never more than the level has — and each one costs itself plus its links.
    ///     A level whose total exceeds `budget` is refused however legible it would be. This is
    ///     the guarantee: whatever the vault's size and however far in the reader goes, the
    ///     number of drawn things per frame is bounded, because the level rises to meet the
    ///     budget rather than the budget hoping the level was low enough.
    ///
    /// Legibility alone would let a hundred-thousand-note vault put every note on screen at the
    /// zoom where they happen to be 24px apart. Cost alone would merge a small vault that had
    /// every right to be sharp. Taking the maximum gives each one a veto over the other.
    pub fn levelFor(self: Pyramid, zoom: f32, min_gap_px: f32, view: dvui.Rect, budget: f32) f32 {
        if (self.levels.len <= 1) return 0;
        const top: f32 = @floatFromInt(self.maxLevel());

        const legible = if (zoom > 1e-6 and min_gap_px > 0)
            crossUp(self.spacing, min_gap_px / zoom)
        else
            0;

        // What each level would cost in this view. Built per frame because it depends on the
        // view, and forced monotone as it goes: a coarser level must never be counted as dearer
        // than a finer one, or the crossing search below could stop at the wrong place.
        var cost: [max_levels]f32 = undefined;
        var running: f32 = std.math.floatMax(f32);
        for (self.levels, 0..) |lvl, l| {
            const in_view = (view.w * view.h) / (self.spacing[l] * self.spacing[l]);
            const n = @min(@as(f32, @floatFromInt(lvl.len)), @max(in_view, 1));
            const weight: f32 = if (l == 0) note_cost else 1;
            running = @min(running, n * self.per_cluster[l] * weight);
            cost[l] = running;
        }
        const affordable = crossDown(cost[0..self.levels.len], budget);

        return std.math.clamp(@max(legible, affordable), 0, top);
    }

    /// How far a cluster is toward being drawn as its children instead of as itself, 0 to 1.
    ///
    /// With a global level this is almost entirely `level - lf`: a cluster above the chosen level
    /// dissolves, one at or below it is drawn, and the fractional part is the cross-fade between
    /// the two levels either side. Splitting on a single frame makes the whole view blink.
    ///
    /// This used to ask each region about its own density instead, which is a better question —
    /// a vault is never uniformly dense, and one level has to be wrong somewhere. But a per-region
    /// answer puts merged and unmerged things on screen together, and, more to the point, it gives
    /// no handle on total cost: every region can be individually reasonable while the frame as a
    /// whole draws far too much. One level for the view is what makes the budget in `levelFor`
    /// enforceable, and impostors are what make being locally wrong cheap — a baked cluster still
    /// looks like the cluster rather than collapsing to an abstract marker.
    pub fn splitT(self: Pyramid, level: usize, i: usize, lf: f32) f32 {
        if (level == 0) return 0;
        if (level >= self.levels.len) return 1;
        // Nothing is merged here; drawing the child is drawing this.
        if (self.kidsOf(level, i).len <= 1) return 1;

        // The fade runs over part of the step between levels rather than all of it, so that most
        // zooms have one level on screen and only the crossings have two. Two levels at once is
        // both a third more to draw and twice as many pictures to hold, which is a cost worth
        // paying briefly and not worth paying continuously.
        const raw = (@as(f32, @floatFromInt(level)) - lf) / split_fade_band;
        const t = std.math.clamp(raw, 0, 1);
        // Eased rather than linear: a linear cross-fade spends its first and last moments making
        // a change of a few percent per frame, which is exactly where the eye catches the start
        // and the end of it as two separate events.
        return t * t * (3 - 2 * t);
    }

    /// The finest level whose clusters are at least `min_gap_px` apart when the world is drawn at
    /// `density` pixels per world unit.
    ///
    /// The same legibility question `levelFor` asks, asked of a fixed drawing scale rather than of
    /// the camera. A tile is baked at a density of its own, so what is worth putting into it is
    /// decided by that density and not by how far the reader happens to be zoomed.
    pub fn levelForGap(self: Pyramid, density: f32, min_gap_px: f32) f32 {
        if (self.levels.len <= 1 or density <= 0 or min_gap_px <= 0) return 0;
        const top: f32 = @floatFromInt(self.maxLevel());
        return std.math.clamp(crossUp(self.spacing, min_gap_px / density), 0, top);
    }

    /// The clusters at `level` whose region meets `rect`.
    ///
    /// Found by descending from the coarsest level rather than by scanning the level itself: a
    /// patch of a large vault holds a tiny share of it, so the descent costs what is in the patch
    /// where a scan costs what exists. `out` is cleared first.
    pub fn collectAt(
        self: Pyramid,
        scratch: std.mem.Allocator,
        level: usize,
        rect: dvui.Rect,
        out: *std.ArrayList(u32),
    ) !void {
        out.clearRetainingCapacity();
        if (level >= self.levels.len) return;

        var stack: std.ArrayList(Visible) = .empty;
        defer stack.deinit(scratch);
        const top = self.maxLevel();
        for (0..self.levels[top].len) |i| {
            try stack.append(scratch, .{ .level = @intCast(top), .index = @intCast(i), .alpha = 1 });
        }
        while (stack.pop()) |item| {
            const l: usize = item.level;
            const c = self.levels[l][item.index];
            if (!overlaps(rect, c.pos, c.radius)) continue;
            if (l == level) {
                try out.append(scratch, item.index);
                continue;
            }
            if (l < level) continue;
            for (self.kidsOf(l, item.index)) |k| {
                try stack.append(scratch, .{ .level = @intCast(l - 1), .index = k, .alpha = 1 });
            }
        }
    }

    /// The links at `level` touching cluster `i`, either end.
    pub fn incidentOf(self: Pyramid, level: usize, i: usize) []const u32 {
        if (level >= self.inc.len) return &.{};
        const s = self.inc_start[level];
        if (i + 1 >= s.len) return &.{};
        return self.inc[level][s[i]..s[i + 1]];
    }

    pub fn kidsOf(self: Pyramid, level: usize, i: usize) []const u32 {
        if (level == 0 or level >= self.kids.len) return &.{};
        const s = self.kid_start[level];
        return self.kids[level][s[i]..s[i + 1]];
    }

    /// The `rank`-th leaf (0-based, CSR kid order) under cluster `level`/`index`.
    /// Stable: the same cluster always yields the same leaf for a given rank — used so coarse
    /// field marks sit on a real note instead of the centroid (centroids jump when children open).
    pub fn leafAtRank(self: Pyramid, level: usize, index: u32, rank: u32) u32 {
        var l = level;
        var i = index;
        var r = rank;
        while (l > 0) {
            const kids = self.kidsOf(l, i);
            var found = false;
            for (kids) |kid| {
                const kc = self.levels[l - 1][kid].count;
                if (r < kc) {
                    l -= 1;
                    i = kid;
                    found = true;
                    break;
                }
                r -= kc;
            }
            if (!found) {
                if (kids.len == 0) return i;
                l -= 1;
                i = kids[kids.len - 1];
                r = 0;
            }
        }
        return i;
    }

    /// World position for a hierarchical field mark: always a leaf under the cluster (or the
    /// note itself at level 0). `live` supplies animated level-0 positions when present.
    pub fn emissaryPos(self: Pyramid, live: []const dvui.Point, level: u32, index: u32) dvui.Point {
        if (level == 0) {
            if (index < live.len) return live[index];
            if (self.levels.len > 0 and index < self.levels[0].len) return self.levels[0][index].pos;
            return .{ .x = 0, .y = 0 };
        }
        const leaf = self.leafAtRank(level, index, 0);
        if (leaf < live.len) return live[leaf];
        if (self.levels.len > 0 and leaf < self.levels[0].len) return self.levels[0][leaf].pos;
        return .{ .x = 0, .y = 0 };
    }

    /// The level-`L - 1` links that coarse link `i` at level `L` stands for.
    pub fn edgeKidsOf(self: Pyramid, level: usize, i: usize) []const u32 {
        if (level == 0 or level >= self.edge_kids.len) return &.{};
        const s = self.edge_kid_start[level];
        return self.edge_kids[level][s[i]..s[i + 1]];
    }

    /// The level-`L - 1` links wholly inside level-`L` cluster `i`.
    pub fn innerOf(self: Pyramid, level: usize, i: usize) []const u32 {
        if (level == 0 or level >= self.inner.len) return &.{};
        const s = self.inner_start[level];
        return self.inner[level][s[i]..s[i + 1]];
    }

    /// The thing actually drawn at `level`/`i`, or null if it dissolves into its children.
    ///
    /// Refines later than the midpoint of the marker cross-fade so the web stays coalesced while
    /// markers are still mostly the parent — refining at 0.5 popped thousands of fine links in the
    /// same band where `select` is already drawing both levels.
    fn restingAt(self: Pyramid, level: usize, i: u32, lf: f32, marks: ?Marks) ?Visible {
        if (self.dissolved(level, i, lf, marks)) return null;
        return .{ .level = @intCast(level), .index = i, .alpha = 1 };
    }

    /// Is `level`/`i` drawn as its children rather than as itself?
    ///
    /// With animated marks the caller owns this answer outright, and the web has to take it: a line
    /// that stops at a marker the mark layer has already retired stops at nothing. Without them it
    /// comes from `splitT`, refined later than the midpoint of the marker cross-fade so the web
    /// stays coalesced while the markers are still mostly the parent.
    fn dissolved(self: Pyramid, level: usize, i: u32, lf: f32, marks: ?Marks) bool {
        if (marks) |m| return m.isOpen(m.ctx, @intCast(level), i);
        return self.splitT(level, i, lf) >= link_refine_t;
    }

    /// Where to draw `level`/`i`. Level 0 prefers `live` — the notes have been eased and shoved
    /// since layout, and a link has to meet the disc where it ended up, not where it was placed.
    fn posOf(self: Pyramid, live: []const dvui.Point, level: usize, i: u32, marks: ?Marks) dvui.Point {
        if (marks) |m| return m.posOf(m.ctx, @intCast(level), i);
        if (level == 0 and i < live.len) return live[i];
        return self.levels[level][i].pos;
    }

    /// The web to draw for `view`, one entry per line, with both ends resolved to what stands
    /// for them.
    ///
    /// Descends from the coarsest level like `select` does, but over links rather than clusters,
    /// and it is the descent that gives the right answer to three separate things at once:
    ///
    ///   • *Coalescing.* A coarse link between two regions is one line however many underlying
    ///     links it stands for. Merging notes into a marker is pointless if all their links are
    ///     still drawn individually, which is what used to make a zoomed-out dense vault slow.
    ///
    ///   • *Links that only pass through.* A line is kept when the *segment* meets the view, not
    ///     when an endpoint does. Zoomed into a dense region most of the lines crossing the
    ///     screen have both ends outside it, and gathering from visible notes could not find
    ///     them — they simply vanished. Here a long link is present at some coarse level as a
    ///     link between two big regions, that segment crosses the view, and refining it walks
    ///     down to the real one.
    ///
    ///   • *Cost.* Anything whose segment misses the view is dropped along with everything
    ///     beneath it, so the traversal costs what crosses the screen rather than what exists.
    ///
    /// `live` are the current level-0 positions. `out` is cleared first and grown with
    /// `allocator`, which the caller is expected to keep; `scratch` holds the traversal's own
    /// working set and is touched only during the call, so a frame arena suits it.
    pub fn gatherWeb(
        self: Pyramid,
        allocator: std.mem.Allocator,
        scratch: std.mem.Allocator,
        lf: f32,
        view: dvui.Rect,
        live: []const dvui.Point,
        marks: ?Marks,
        out: *std.ArrayList(Link),
    ) !void {
        out.clearRetainingCapacity();
        if (self.levels.len == 0 or self.edges.len != self.levels.len) return;

        const top = self.maxLevel();
        var links: std.ArrayList(Pending) = .empty;
        defer links.deinit(scratch);

        // Links inside a region have no coarse link to hang off, so they are reached by opening
        // the region. This walk mirrors `select` exactly, and stops at the same places.
        {
            var clusters: std.ArrayList(Visible) = .empty;
            defer clusters.deinit(scratch);
            for (0..self.levels[top].len) |i| {
                try clusters.append(scratch, .{ .level = @intCast(top), .index = @intCast(i), .alpha = 1 });
            }
            while (clusters.pop()) |c| {
                const level: usize = c.level;
                if (level == 0) continue;
                const cl = self.levels[level][c.index];
                if (!overlaps(view, cl.pos, cl.radius)) continue;
                if (!self.dissolved(level, c.index, lf, marks)) continue;
                for (self.innerOf(level, c.index)) |ei| {
                    try links.append(scratch, .{ .level = @intCast(level - 1), .index = ei });
                }
                for (self.kidsOf(level, c.index)) |k| {
                    try clusters.append(scratch, .{ .level = @intCast(level - 1), .index = k, .alpha = 1 });
                }
            }
        }
        for (0..self.edges[top].len) |e| {
            try links.append(scratch, .{ .level = @intCast(top), .index = @intCast(e) });
        }

        // Two fine links can resolve onto the same pair of drawn things — several notes of one
        // region linking to the same note outside it, say — and that is one line, not several.
        var seen = std.AutoHashMap(LinkKey, void).init(scratch);
        defer seen.deinit();

        while (links.pop()) |item| {
            const level: usize = item.level;
            const e = self.edges[level][item.index];
            const ra = item.fa orelse self.restingAt(level, e.a, lf, marks);
            const rb = item.fb orelse self.restingAt(level, e.b, lf, marks);

            // Cull against where this link is *about* to be, padded by how far its ends may yet
            // move as it refines — which is the radius of the regions it currently joins.
            const ea = self.levels[level][e.a];
            const eb = self.levels[level][e.b];
            const from = if (ra) |r| self.posOf(live, r.level, r.index, marks) else ea.pos;
            const to = if (rb) |r| self.posOf(live, r.level, r.index, marks) else eb.pos;
            if (!segmentHitsRect(from, to, view, @max(ea.radius, eb.radius))) continue;

            if (ra != null and rb != null) {
                const a = ra.?;
                const b = rb.?;
                // Both ends inside the same marker: nothing for the line to span.
                if (a.level == b.level and a.index == b.index) continue;
                const key = linkKey(a, b);
                if ((try seen.getOrPut(key)).found_existing) continue;
                try out.append(allocator, .{
                    .from = from,
                    .to = to,
                    .from_level = a.level,
                    .to_level = b.level,
                    .from_index = a.index,
                    .to_index = b.index,
                    .edge = if (level == 0 and a.level == 0 and b.level == 0) item.index else no_edge,
                });
                continue;
            }

            // One end is already a drawn mark, the other still wants to dissolve. Refining the
            // open side past the frozen end's level fans one mass into every fine note on the
            // other side (starburst). Stop at the frozen end's coarseness so many underlying
            // links stay one spoke into that group.
            if (ra != null and rb == null and level <= ra.?.level) {
                const b_rest: Visible = .{ .level = @intCast(level), .index = e.b, .alpha = 1 };
                if (ra.?.level == b_rest.level and ra.?.index == b_rest.index) continue;
                const key = linkKey(ra.?, b_rest);
                if ((try seen.getOrPut(key)).found_existing) continue;
                const to_b = self.posOf(live, b_rest.level, b_rest.index, marks);
                try out.append(allocator, .{
                    .from = from,
                    .to = to_b,
                    .from_level = ra.?.level,
                    .to_level = b_rest.level,
                    .from_index = ra.?.index,
                    .to_index = b_rest.index,
                    .edge = no_edge,
                });
                continue;
            }
            if (rb != null and ra == null and level <= rb.?.level) {
                const a_rest: Visible = .{ .level = @intCast(level), .index = e.a, .alpha = 1 };
                if (rb.?.level == a_rest.level and rb.?.index == a_rest.index) continue;
                const key = linkKey(a_rest, rb.?);
                if ((try seen.getOrPut(key)).found_existing) continue;
                const from_a = self.posOf(live, a_rest.level, a_rest.index, marks);
                try out.append(allocator, .{
                    .from = from_a,
                    .to = to,
                    .from_level = a_rest.level,
                    .to_level = rb.?.level,
                    .from_index = a_rest.index,
                    .to_index = rb.?.index,
                    .edge = no_edge,
                });
                continue;
            }

            // At level 0 nothing can split, so both ends always resolve and this cannot recur.
            //
            // Re-home each frozen end onto the child endpoint that actually sits under it.
            // Coarse links are stored with `a < b`, but a child link can run either way, and
            // carrying `fa`/`fb` by slot would pin a resting marker to the wrong end of a
            // reversed child — which is how a long link into a dense cluster was vanishing:
            // the segment was being evaluated against the wrong geometry and culled.
            const map = self.maps[level - 1];
            for (self.edgeKidsOf(level, item.index)) |ci| {
                const child = self.edges[level - 1][ci];
                const pa = map[child.a];
                const pb = map[child.b];
                try links.append(scratch, .{
                    .level = @intCast(level - 1),
                    .index = ci,
                    .fa = if (pa == e.a) ra else if (pa == e.b) rb else null,
                    .fb = if (pb == e.a) ra else if (pb == e.b) rb else null,
                });
            }
        }
    }

    /// What to draw for the region `view` (world space), one entry per thing.
    ///
    /// Descends from the coarsest level, splitting a cluster into its children wherever
    /// `splitT` says its contents have separated, and stopping wherever they have not. Clusters
    /// that fall outside `view` are dropped along with everything beneath them, which is most of
    /// a large vault at most zooms — the traversal costs what is on screen, not what exists.
    pub fn select(
        self: Pyramid,
        allocator: std.mem.Allocator,
        lf: f32,
        view: dvui.Rect,
        out: *std.ArrayList(Visible),
    ) !void {
        out.clearRetainingCapacity();
        if (self.levels.len == 0) return;

        const top = self.maxLevel();
        var stack: std.ArrayList(Visible) = .empty;
        defer stack.deinit(allocator);
        for (0..self.levels[top].len) |i| {
            try stack.append(allocator, .{ .level = @intCast(top), .index = @intCast(i), .alpha = 1 });
        }

        while (stack.pop()) |item| {
            const level: usize = item.level;
            const c = self.levels[level][item.index];
            if (item.alpha <= 0.004) continue;
            // A cluster covers `radius` around its centre, and a level-0 note covers nothing —
            // the caller insets `view` by whatever a note is drawn at.
            if (!overlaps(view, c.pos, c.radius)) continue;

            if (level == 0) {
                try out.append(allocator, item);
                continue;
            }
            const t = self.splitT(level, item.index, lf);
            if (t < 0.996) try out.append(allocator, .{
                .level = item.level,
                .index = item.index,
                .alpha = item.alpha * (1 - t),
            });
            if (t > 0.004) {
                for (self.kidsOf(level, item.index)) |k| {
                    try stack.append(allocator, .{
                        .level = @intCast(level - 1),
                        .index = k,
                        .alpha = item.alpha * t,
                    });
                }
            }
        }
    }
};

/// One thing to draw: a note when `level` is 0, otherwise a cluster marker at that level.
/// `alpha` is its share of a cross-fade, and is 1 for anything not mid-split.
pub const Visible = struct {
    level: u32,
    index: u32,
    alpha: f32,
};

fn freeJagged(allocator: std.mem.Allocator, comptime T: type, rows: [][]T) void {
    for (rows) |r| allocator.free(r);
    allocator.free(rows);
}

/// A link part-way down `gatherWeb`'s descent. An end that has already come to rest is carried
/// along frozen: the descent continues for the *other* end, and a note whose region is still one
/// marker must keep joining the marker, not the note.
const Pending = struct {
    level: u32,
    index: u32,
    fa: ?Visible = null,
    fb: ?Visible = null,
};

/// Identifies a drawn line by what it joins, for collapsing duplicates. Ordered, so the same
/// pair reached from either side is the same key.
const LinkKey = struct { al: u32, ai: u32, bl: u32, bi: u32 };

fn linkKey(a: Visible, b: Visible) LinkKey {
    const swap = a.level > b.level or (a.level == b.level and a.index > b.index);
    const lo = if (swap) b else a;
    const hi = if (swap) a else b;
    return .{ .al = lo.level, .ai = lo.index, .bl = hi.level, .bi = hi.index };
}

/// Does the segment `a`–`b` come within `pad` of `r`? Bounding-box reject, then the one
/// separating axis a box and a segment can have that the box's own axes don't cover.
pub fn segmentHitsRect(a: dvui.Point, b: dvui.Point, r: dvui.Rect, pad: f32) bool {
    const min_x = r.x - pad;
    const max_x = r.x + r.w + pad;
    const min_y = r.y - pad;
    const max_y = r.y + r.h + pad;
    if (@max(a.x, b.x) < min_x or @min(a.x, b.x) > max_x) return false;
    if (@max(a.y, b.y) < min_y or @min(a.y, b.y) > max_y) return false;

    const dx = b.x - a.x;
    const dy = b.y - a.y;
    const cx = (min_x + max_x) * 0.5;
    const cy = (min_y + max_y) * 0.5;
    // Distance from the box centre to the segment's line, against the box's reach along the
    // same normal. Both are scaled by the segment length, which cancels.
    const dist = @abs(-dy * (cx - a.x) + dx * (cy - a.y));
    const reach = @abs(dy) * (max_x - min_x) * 0.5 + @abs(dx) * (max_y - min_y) * 0.5;
    return dist <= reach;
}

/// Share of the step between two levels that the cross-fade occupies. Below 1, so a zoom range
/// exists at each level where only that level is on screen. Wider = longer dissolve (smoother
/// handoff); still leaves a plateau per level for the "step" look.
const split_fade_band: f32 = 0.75;

/// `splitT` at which `gatherWeb` opens a cluster into finer links. Kept past the middle of the
/// marker fade so link count does not spike while both parent and children are still on screen.
const link_refine_t: f32 = 0.88;

/// What a note drawn as itself costs, against an impostor quad as the unit.
///
/// Level 0 is not merely a level with more things in it — it is a different and far dearer kind
/// of drawing. A merged region is one quad out of a shared batch and nothing else. A note is a
/// disc and a ring, a drop shadow once it is large enough, a candidate for the label placer with
/// a title to measure and a slot to find, and a participant in the hover and proximity chases
/// that run every frame the pointer moves. Counting it as one thing alongside a quad is what let
/// the level fall to 0 while the frame was still affordable on paper and plainly was not in fact.
///
/// Kept mild. The temptation is to raise it until the level rises out of every expensive frame,
/// but coarsening past what legibility asks for merges regions at zooms where a note is drawn at
/// a fixed screen size and a baked mark cannot be — see `mergeCeiling` in `graph.zig`, which
/// refuses to go there at all. The impostors are the thing that makes the far view cheap; this is
/// only meant to stop the level falling to 0 a notch before it can be afforded.
const note_cost: f32 = 1.5;

/// Fractional index where an increasing series first reaches `target`, or 0 if it starts there
/// already and `len - 1` if it never does.
///
/// Both series `levelFor` consults are geometric — each level is a roughly constant factor
/// coarser than the one below — so the interpolation is done on logarithms. Linear interpolation
/// between 40 and 2000 would put the halfway mark at 1020, which is not halfway between them in
/// any sense the zoom cares about.
fn crossUp(vals: []const f32, target: f32) f32 {
    if (vals.len == 0) return 0;
    for (vals, 0..) |v, i| {
        if (v < target) continue;
        if (i == 0) return 0;
        return @as(f32, @floatFromInt(i - 1)) + logFrac(vals[i - 1], v, target);
    }
    return @floatFromInt(vals.len - 1);
}

/// `crossUp` for a decreasing series: where it first falls to `target`.
fn crossDown(vals: []const f32, target: f32) f32 {
    if (vals.len == 0) return 0;
    for (vals, 0..) |v, i| {
        if (v > target) continue;
        if (i == 0) return 0;
        return @as(f32, @floatFromInt(i - 1)) + logFrac(vals[i - 1], v, target);
    }
    return @floatFromInt(vals.len - 1);
}

/// Where `target` sits between `a` and `b` on a log scale, 0 to 1. Direction-agnostic, so it
/// serves both crossings.
fn logFrac(a: f32, b: f32, target: f32) f32 {
    if (a <= 0 or b <= 0 or target <= 0) return 1;
    const la = @log(a);
    const lb = @log(b);
    if (@abs(lb - la) < 1e-6) return 1;
    return std.math.clamp((@log(target) - la) / (lb - la), 0, 1);
}

fn overlaps(view: dvui.Rect, pos: dvui.Point, radius: f32) bool {
    return pos.x + radius >= view.x and pos.x - radius <= view.x + view.w and
        pos.y + radius >= view.y and pos.y - radius <= view.y + view.h;
}

/// Build the pyramid from a solved layout.
///
/// `pos` are the final level-0 positions — after packing and snapping, not the solver's raw
/// output — so markers line up with the notes actually on screen.
/// `edges` are the vault's own links, which are coalesced up the same hierarchy — see
/// `buildEdges`.
pub fn build(
    allocator: std.mem.Allocator,
    ladder: multilevel.Ladder,
    pos: []const dvui.Point,
    edges: []const CEdge,
) !Pyramid {
    var p: Pyramid = .{ .allocator = allocator };
    errdefer p.deinit();

    var levels: std.ArrayList([]Cluster) = .empty;
    defer levels.deinit(allocator);
    var maps: std.ArrayList([]u32) = .empty;
    defer maps.deinit(allocator);

    // Level 0 is the notes themselves.
    const base = try allocator.alloc(Cluster, pos.len);
    for (pos, base) |q, *c| c.* = .{ .pos = q, .radius = 0, .spread = 0, .count = 1 };
    try levels.append(allocator, base);

    // Follow the layout's own coarsening for as far as it goes. These levels are the good ones:
    // groups formed by link structure, so a marker stands for notes that belong together.
    for (1..ladder.levelCount()) |l| {
        const map = try allocator.dupe(u32, ladder.maps[l - 1]);
        errdefer allocator.free(map);
        try levels.append(allocator, try coarsenBy(allocator, levels.items[l - 1], map, ladder.counts[l]));
        try maps.append(allocator, map);
    }

    // Then keep going on position alone, until the coarsest level is small enough to draw
    // without thinking about it.
    //
    // The ladder cannot be relied on to get there, and on a real vault it usually doesn't.
    // Matching merges *linked* pairs, so anything with no unmatched neighbour — an orphan note,
    // a phantom, the leaf of an already-matched star — survives every pass untouched, and one
    // pass that fails to shrink the graph enough ends the ladder outright. A vault with a few
    // thousand orphans in it therefore gets a one-level ladder and no level-of-detail at all,
    // which is the "zooming out never merges anything" case exactly.
    //
    // Position is the honest fallback: at the zoom where this matters, two notes a few world
    // units apart are the same pixel whether or not they are linked, so a spatial bucket is
    // both what the reader sees and what the draw pass wants.
    while (levels.items.len < max_levels) {
        const child = levels.items[levels.items.len - 1];
        if (child.len <= coarsest_clusters) break;
        const map = try allocator.alloc(u32, child.len);
        errdefer allocator.free(map);
        const count = try bucketByPosition(allocator, child, map);
        // No progress — everything landed in its own bucket even at the coarsest cell this
        // level's extent allows. Nothing further to say about it.
        if (count >= child.len) {
            allocator.free(map);
            break;
        }
        try levels.append(allocator, try coarsenBy(allocator, child, map, count));
        try maps.append(allocator, map);
    }

    p.levels = try levels.toOwnedSlice(allocator);
    p.maps = try maps.toOwnedSlice(allocator);
    try buildKidIndex(allocator, &p);
    try buildEdges(allocator, &p, edges);

    // Span is the bounding box, not the distance from the origin: the packer is free to leave a
    // vault off-centre, and measuring from the origin then reports a span far larger than the
    // notes actually occupy — which makes `levelFor` think everything is comfortably spaced and
    // hold level 0 no matter how far out the reader pulls.
    var min_x: f32 = std.math.floatMax(f32);
    var min_y: f32 = std.math.floatMax(f32);
    var max_x: f32 = -std.math.floatMax(f32);
    var max_y: f32 = -std.math.floatMax(f32);
    for (pos) |q| {
        min_x = @min(min_x, q.x);
        min_y = @min(min_y, q.y);
        max_x = @max(max_x, q.x);
        max_y = @max(max_y, q.y);
    }
    p.world_span = if (pos.len == 0) 0 else @max(max_x - min_x, max_y - min_y);
    // Area, not span squared: a vault packed into a wide strip has far less area than its longest
    // side suggests, and `levelFor` divides the view by this to decide what share of the graph is
    // on screen. A floor keeps a degenerate layout (everything on one line) from dividing by zero.

    try measureLevels(allocator, &p);
    return p;
}

/// Fill in `spacing` and `per_cluster`, the two per-level summaries `levelFor` reads.
fn measureLevels(allocator: std.mem.Allocator, p: *Pyramid) !void {
    p.spacing = try allocator.alloc(f32, p.levels.len);
    p.per_cluster = try allocator.alloc(f32, p.levels.len);

    for (p.levels, 0..) |lvl, l| {
        const n: f32 = @floatFromInt(@max(lvl.len, 1));
        p.per_cluster[l] = (n + @as(f32, @floatFromInt(p.edges[l].len))) / n;
    }

    // How far apart level `l`'s clusters sit, measured directly from where they are.
    for (p.levels, 0..) |lvl, l| {
        p.spacing[l] = try nearestNeighbourSpacing(allocator, lvl);
    }

    // Two gaps to fill, both by carrying the trend forward. A level with fewer than two clusters
    // has no neighbour distance to measure, and a level that reported a smaller spacing than the
    // one below it has measured badly rather than found something real — a level is coarser than
    // its child by construction, so its marks cannot be closer together.
    var prev_ratio: f32 = 2;
    for (p.spacing, 0..) |*s, l| {
        if (l == 0) {
            if (s.* <= 0) s.* = 1;
            continue;
        }
        if (s.* > p.spacing[l - 1]) {
            prev_ratio = s.* / p.spacing[l - 1];
        } else {
            s.* = p.spacing[l - 1] * prev_ratio;
        }
    }
}

/// Clusters sampled when measuring a level's spacing. A median over a couple of thousand points is
/// as stable as one over half a million and costs nothing next to building the layout that
/// produced them.
const spacing_samples: usize = 2048;
/// Rings of grid cells searched outward before giving up on a point. A cell holds about one
/// cluster on average, so a neighbour is normally in the first ring or two; the cap only bounds
/// the pathological case of a lone outlier with the whole vault's width between it and anything
/// else, which contributes nothing to a median anyway.
const spacing_max_rings: usize = 6;

/// Median distance from a cluster to the nearest other cluster at the same level.
///
/// The honest answer to both of `levelFor`'s questions: whether two marks can be told apart, and
/// how many of them a screenful holds. Taken as a *median* rather than a mean because a vault's
/// outliers are exactly the points with no neighbour anywhere near them — a handful of orphans
/// parked out in the packing's air can pull a mean across the whole graph, and they are not what
/// decides whether the crowded part of the view is legible.
///
/// Uniform grid, sized so a cell holds about one cluster, then a ring search outward from each
/// sampled point's own cell. The search stops as soon as the best distance found is closer than
/// the next ring can possibly be, which is what makes it an exact nearest neighbour and not an
/// approximation of one.
fn nearestNeighbourSpacing(allocator: std.mem.Allocator, level: []const Cluster) !f32 {
    if (level.len < 2) return 0;

    var min_x: f32 = std.math.floatMax(f32);
    var min_y: f32 = std.math.floatMax(f32);
    var max_x: f32 = -std.math.floatMax(f32);
    var max_y: f32 = -std.math.floatMax(f32);
    for (level) |c| {
        min_x = @min(min_x, c.pos.x);
        min_y = @min(min_y, c.pos.y);
        max_x = @max(max_x, c.pos.x);
        max_y = @max(max_y, c.pos.y);
    }
    const w = @max(max_x - min_x, 1e-3);
    const h = @max(max_y - min_y, 1e-3);
    const n: f32 = @floatFromInt(level.len);
    const cell = @max(@sqrt(w * h / n), 1e-6);
    const cols: usize = @min(@as(usize, @intFromFloat(@floor(w / cell))) + 1, 1 << 16);
    const rows: usize = @min(@as(usize, @intFromFloat(@floor(h / cell))) + 1, 1 << 16);

    // Bucket every cluster into its cell, CSR by counting sort — no hashing, and one pass each way
    // over a level that may hold half a million points.
    const cell_of = try allocator.alloc(u32, level.len);
    defer allocator.free(cell_of);
    const start = try allocator.alloc(u32, cols * rows + 1);
    defer allocator.free(start);
    @memset(start, 0);
    for (level, cell_of) |c, *slot| {
        const cx = @min(@as(usize, @intFromFloat(@max((c.pos.x - min_x) / cell, 0))), cols - 1);
        const cy = @min(@as(usize, @intFromFloat(@max((c.pos.y - min_y) / cell, 0))), rows - 1);
        slot.* = @intCast(cy * cols + cx);
        start[slot.* + 1] += 1;
    }
    for (1..start.len) |i| start[i] += start[i - 1];
    const items = try allocator.alloc(u32, level.len);
    defer allocator.free(items);
    {
        const cursor = try allocator.alloc(u32, cols * rows);
        defer allocator.free(cursor);
        @memcpy(cursor, start[0 .. cols * rows]);
        for (cell_of, 0..) |c, i| {
            items[cursor[c]] = @intCast(i);
            cursor[c] += 1;
        }
    }

    const stride = @max(level.len / spacing_samples, 1);
    var dists: std.ArrayList(f32) = .empty;
    defer dists.deinit(allocator);

    var i: usize = 0;
    while (i < level.len) : (i += stride) {
        const me = level[i].pos;
        const cx: i64 = @intCast(cell_of[i] % cols);
        const cy: i64 = @intCast(cell_of[i] / cols);
        var best: f32 = std.math.floatMax(f32);

        var r: usize = 0;
        while (r < spacing_max_rings) : (r += 1) {
            // Everything in ring `r + 1` and beyond is at least `r * cell` away, so once the best
            // so far beats that, no further ring can improve on it.
            if (best < @as(f32, @floatFromInt(r)) * cell) break;
            const ri: i64 = @intCast(r);
            var gy: i64 = cy - ri;
            while (gy <= cy + ri) : (gy += 1) {
                if (gy < 0 or gy >= rows) continue;
                var gx: i64 = cx - ri;
                while (gx <= cx + ri) : (gx += 1) {
                    if (gx < 0 or gx >= cols) continue;
                    // Only the ring itself; the interior was covered by an earlier pass.
                    if (r > 0 and @abs(gx - cx) != ri and @abs(gy - cy) != ri) continue;
                    const c: usize = @intCast(gy * @as(i64, @intCast(cols)) + gx);
                    for (items[start[c]..start[c + 1]]) |j| {
                        if (j == i) continue;
                        const dx = level[j].pos.x - me.x;
                        const dy = level[j].pos.y - me.y;
                        best = @min(best, @sqrt(dx * dx + dy * dy));
                    }
                }
            }
        }
        if (best < std.math.floatMax(f32)) try dists.append(allocator, best);
    }

    if (dists.items.len == 0) return 0;
    std.mem.sort(f32, dists.items, {}, std.sort.asc(f32));
    return dists.items[dists.items.len / 2];
}

/// Coalesce the link set up the pyramid, one level at a time.
///
/// A link between two clusters is drawn once no matter how many underlying links it stands for —
/// which is both what the reader means by "these two regions are connected" and the only way the
/// web can survive being zoomed out, since the whole point of merging notes is undone if every
/// one of their links is still drawn.
///
/// Two things fall out of each level, and both are needed to put the web back together on the way
/// down. A link whose ends land in *different* parents becomes a coarse link, and remembers the
/// finer links it absorbed. A link whose ends land in the *same* parent is not a link between
/// regions at all; it belongs to that parent, and reappears only once the parent opens up.
pub fn buildEdges(allocator: std.mem.Allocator, p: *Pyramid, base: []const CEdge) !void {
    const n_levels = p.levels.len;
    p.edges = try allocator.alloc([]CEdge, n_levels);
    @memset(p.edges, &.{});
    p.edge_kid_start = try allocator.alloc([]u32, n_levels);
    @memset(p.edge_kid_start, &.{});
    p.edge_kids = try allocator.alloc([]u32, n_levels);
    @memset(p.edge_kids, &.{});
    p.inner_start = try allocator.alloc([]u32, n_levels);
    @memset(p.inner_start, &.{});
    p.inner = try allocator.alloc([]u32, n_levels);
    @memset(p.inner, &.{});

    p.inc_start = try allocator.alloc([]u32, n_levels);
    @memset(p.inc_start, &.{});
    p.inc = try allocator.alloc([]u32, n_levels);
    @memset(p.inc, &.{});

    p.edges[0] = try allocator.dupe(CEdge, base);

    for (1..n_levels) |l| {
        const map = p.maps[l - 1];
        const child = p.edges[l - 1];
        const parents = p.levels[l].len;

        // Where each child link went: a coarse link's index, or `no_edge` if it turned inward.
        const owner = try allocator.alloc(u32, child.len);
        defer allocator.free(owner);
        const host = try allocator.alloc(u32, child.len);
        defer allocator.free(host);

        var seen = std.AutoHashMap(CEdge, u32).init(allocator);
        defer seen.deinit();
        var coarse: std.ArrayList(CEdge) = .empty;
        defer coarse.deinit(allocator);

        for (child, 0..) |e, ci| {
            if (e.a >= map.len or e.b >= map.len) {
                owner[ci] = no_edge;
                host[ci] = no_edge;
                continue;
            }
            const pa = map[e.a];
            const pb = map[e.b];
            if (pa == pb) {
                owner[ci] = no_edge;
                host[ci] = pa;
                continue;
            }
            host[ci] = no_edge;
            const key: CEdge = if (pa < pb) .{ .a = pa, .b = pb } else .{ .a = pb, .b = pa };
            const gop = try seen.getOrPut(key);
            if (!gop.found_existing) {
                gop.value_ptr.* = @intCast(coarse.items.len);
                try coarse.append(allocator, key);
            }
            owner[ci] = gop.value_ptr.*;
        }

        p.edges[l] = try coarse.toOwnedSlice(allocator);
        const csr_out = try invert(allocator, owner, p.edges[l].len);
        p.edge_kid_start[l] = csr_out.start;
        p.edge_kids[l] = csr_out.items;
        const csr_in = try invert(allocator, host, parents);
        p.inner_start[l] = csr_in.start;
        p.inner[l] = csr_in.items;
    }

    for (0..n_levels) |l| {
        const csr = try incidence(allocator, p.edges[l], p.levels[l].len);
        p.inc_start[l] = csr.start;
        p.inc[l] = csr.items;
    }
}

/// Index a level's links by the clusters they touch. Counting sort into CSR, exactly like
/// `invert`, except each link is filed twice — once under each end.
fn incidence(allocator: std.mem.Allocator, edges: []const CEdge, clusters: usize) !struct {
    start: []u32,
    items: []u32,
} {
    const start = try allocator.alloc(u32, clusters + 1);
    errdefer allocator.free(start);
    @memset(start, 0);
    for (edges) |e| {
        if (e.a < clusters) start[e.a + 1] += 1;
        if (e.b < clusters) start[e.b + 1] += 1;
    }
    for (1..start.len) |i| start[i] += start[i - 1];

    const items = try allocator.alloc(u32, if (clusters == 0) 0 else start[clusters]);
    errdefer allocator.free(items);
    const cursor = try allocator.alloc(u32, clusters);
    defer allocator.free(cursor);
    if (clusters > 0) @memcpy(cursor, start[0..clusters]);
    for (edges, 0..) |e, i| {
        if (e.a < clusters) {
            items[cursor[e.a]] = @intCast(i);
            cursor[e.a] += 1;
        }
        if (e.b < clusters) {
            items[cursor[e.b]] = @intCast(i);
            cursor[e.b] += 1;
        }
    }
    return .{ .start = start, .items = items };
}

/// Group the positions of `bucket` by its values, skipping `no_edge`. Counting sort into CSR.
fn invert(allocator: std.mem.Allocator, bucket: []const u32, groups: usize) !struct {
    start: []u32,
    items: []u32,
} {
    const start = try allocator.alloc(u32, groups + 1);
    errdefer allocator.free(start);
    @memset(start, 0);
    var total: usize = 0;
    for (bucket) |b| {
        if (b == no_edge) continue;
        start[b + 1] += 1;
        total += 1;
    }
    for (1..start.len) |i| start[i] += start[i - 1];

    const items = try allocator.alloc(u32, total);
    errdefer allocator.free(items);
    const cursor = try allocator.alloc(u32, groups);
    defer allocator.free(cursor);
    @memcpy(cursor, start[0..groups]);
    for (bucket, 0..) |b, i| {
        if (b == no_edge) continue;
        items[cursor[b]] = @intCast(i);
        cursor[b] += 1;
    }
    return .{ .start = start, .items = items };
}

/// Invert `maps` into per-level CSR child lists. Counting sort: one pass to size each parent's
/// run, a prefix sum, then one pass to fill.
fn buildKidIndex(allocator: std.mem.Allocator, p: *Pyramid) !void {
    p.kid_start = try allocator.alloc([]u32, p.levels.len);
    @memset(p.kid_start, &.{});
    p.kids = try allocator.alloc([]u32, p.levels.len);
    @memset(p.kids, &.{});

    for (1..p.levels.len) |l| {
        const map = p.maps[l - 1];
        const starts = try allocator.alloc(u32, p.levels[l].len + 1);
        @memset(starts, 0);
        for (map) |parent| starts[parent + 1] += 1;
        for (1..starts.len) |i| starts[i] += starts[i - 1];

        const items = try allocator.alloc(u32, map.len);
        const cursor = try allocator.alloc(u32, p.levels[l].len);
        defer allocator.free(cursor);
        @memcpy(cursor, starts[0..p.levels[l].len]);
        for (map, 0..) |parent, child| {
            items[cursor[parent]] = @intCast(child);
            cursor[parent] += 1;
        }

        p.kid_start[l] = starts;
        p.kids[l] = items;
    }
}

/// One coarser level: centroid of each group weighted by how many notes it stands for, then a
/// second pass for the radius, which needs the centroid to exist first.
fn coarsenBy(
    allocator: std.mem.Allocator,
    child: []const Cluster,
    map: []const u32,
    count: usize,
) ![]Cluster {
    const level = try allocator.alloc(Cluster, count);
    @memset(level, .{});

    for (child, 0..) |c, ci| {
        const parent = map[ci];
        const w: f32 = @floatFromInt(c.count);
        level[parent].pos.x += c.pos.x * w;
        level[parent].pos.y += c.pos.y * w;
        level[parent].count += c.count;
    }
    for (level) |*c| {
        if (c.count == 0) continue;
        const inv = 1.0 / @as(f32, @floatFromInt(c.count));
        c.pos.x *= inv;
        c.pos.y *= inv;
    }
    // Radius has to reach every *note* underneath, not just the immediate children, so it takes
    // the child's own radius into account.
    //
    // Spread combines exactly rather than approximately: the variance of a union of groups is
    // the weighted mean of their own variances plus the weighted spread of their centres about
    // the combined centre (the parallel-axis theorem). So one pass up the hierarchy gives the
    // true RMS over every note underneath, without ever revisiting the notes themselves.
    var var_acc = try allocator.alloc(f32, count);
    defer allocator.free(var_acc);
    @memset(var_acc, 0);

    for (child, 0..) |c, ci| {
        const parent = map[ci];
        const dx = c.pos.x - level[parent].pos.x;
        const dy = c.pos.y - level[parent].pos.y;
        const d2 = dx * dx + dy * dy;
        level[parent].radius = @max(level[parent].radius, @sqrt(d2) + c.radius);
        const w: f32 = @floatFromInt(c.count);
        var_acc[parent] += w * (c.spread * c.spread + d2);
    }
    for (level, var_acc) |*c, v| {
        if (c.count == 0) continue;
        c.spread = @sqrt(v / @as(f32, @floatFromInt(c.count)));
    }
    return level;
}

/// Group `child` into a square grid, writing each one's bucket into `map`. Returns the number of
/// occupied buckets.
///
/// Cell size targets `spatial_shrink` of the input count *if the clusters were spread evenly*.
/// They never are, so the real shrink is milder than asked for — which is fine, since the caller
/// simply runs another level. Prefer a mild ratio so mid-zoom has many intermediate masses.
fn bucketByPosition(allocator: std.mem.Allocator, child: []const Cluster, map: []u32) !usize {
    var min_x: f32 = std.math.floatMax(f32);
    var min_y: f32 = std.math.floatMax(f32);
    var max_x: f32 = -std.math.floatMax(f32);
    var max_y: f32 = -std.math.floatMax(f32);
    for (child) |c| {
        min_x = @min(min_x, c.pos.x);
        min_y = @min(min_y, c.pos.y);
        max_x = @max(max_x, c.pos.x);
        max_y = @max(max_y, c.pos.y);
    }
    const w = @max(max_x - min_x, 1e-3);
    const h = @max(max_y - min_y, 1e-3);
    const want: f32 = @max(@as(f32, @floatFromInt(child.len)) * spatial_shrink, 1);
    const cell = @max(@sqrt(w * h / want), 1e-6);

    // Grid dimensions come from the same cell size, so a bucket key is a plain row-major index —
    // no hashing, and the whole pass is one allocation-free sweep.
    const cols: usize = @intFromFloat(@floor(w / cell) + 1);
    const rows: usize = @intFromFloat(@floor(h / cell) + 1);

    var seen = std.AutoHashMap(usize, u32).init(allocator);
    defer seen.deinit();
    try seen.ensureTotalCapacity(@intCast(@min(child.len, cols *| rows)));

    var next: u32 = 0;
    for (child, map) |c, *slot| {
        const cx: usize = @intFromFloat(@min(@floor((c.pos.x - min_x) / cell), @as(f32, @floatFromInt(cols - 1))));
        const cy: usize = @intFromFloat(@min(@floor((c.pos.y - min_y) / cell), @as(f32, @floatFromInt(rows - 1))));
        const gop = try seen.getOrPut(cy *| cols +| cx);
        if (!gop.found_existing) {
            gop.value_ptr.* = next;
            next += 1;
        }
        slot.* = gop.value_ptr.*;
    }
    return next;
}

// -- tests ------------------------------------------------------------------------

const testing = std.testing;

/// Two levels: four notes pairing into two clusters.
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

test "a cluster sits at the centre of its notes and covers them" {
    var ladder = try fixture(testing.allocator);
    defer ladder.deinit(testing.allocator);

    const pos = [_]dvui.Point{
        .{ .x = -10, .y = 0 },
        .{ .x = -20, .y = 0 },
        .{ .x = 10, .y = 0 },
        .{ .x = 20, .y = 0 },
    };
    var p = try build(testing.allocator, ladder, &pos, &.{});
    defer p.deinit();

    try testing.expectEqual(@as(usize, 2), p.levels.len);
    try testing.expectEqual(@as(usize, 2), p.levels[1].len);
    try testing.expectApproxEqAbs(@as(f32, -15), p.levels[1][0].pos.x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 15), p.levels[1][1].pos.x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 5), p.levels[1][0].radius, 0.001);
    try testing.expectEqual(@as(u32, 2), p.levels[1][0].count);
}

test "every note is accounted for exactly once at every level" {
    var ladder = try fixture(testing.allocator);
    defer ladder.deinit(testing.allocator);
    const pos = [_]dvui.Point{ .{}, .{ .x = 1 }, .{ .x = 2 }, .{ .x = 3 } };
    var p = try build(testing.allocator, ladder, &pos, &.{});
    defer p.deinit();

    for (p.levels) |level| {
        var total: u32 = 0;
        for (level) |c| total += c.count;
        try testing.expectEqual(@as(u32, 4), total);
    }
}

/// Everything, at any zoom.
const everywhere: dvui.Rect = .{ .x = -1e9, .y = -1e9, .w = 2e9, .h = 2e9 };

/// The level a view would be drawn at, with the budget effectively lifted so legibility alone
/// decides. Most tests here are about what merges and when, which is the legibility half; the
/// budget has its own tests below.
fn lfAt(p: Pyramid, zoom: f32, view: dvui.Rect) f32 {
    return p.levelFor(zoom, 12, view, 1e9);
}

/// Notes accounted for by a selection, i.e. summed over both the individual ones and the
/// contents of every marker. Should always be the whole vault.
fn selectedCount(p: Pyramid, sel: []const Visible) u32 {
    var total: u32 = 0;
    for (sel) |v| {
        if (v.alpha < 0.5) continue; // Only the dominant side of a cross-fade.
        total += p.levels[v.level][v.index].count;
    }
    return total;
}

test "zooming out merges, zooming in separates, and nothing is lost either way" {
    var ladder = try fixture(testing.allocator);
    defer ladder.deinit(testing.allocator);
    const pos = [_]dvui.Point{
        .{ .x = -10, .y = 0 },
        .{ .x = -20, .y = 0 },
        .{ .x = 10, .y = 0 },
        .{ .x = 20, .y = 0 },
    };
    var p = try build(testing.allocator, ladder, &pos, &.{});
    defer p.deinit();

    var sel: std.ArrayList(Visible) = .empty;
    defer sel.deinit(testing.allocator);

    // Zoomed right in, the notes are far enough apart to draw individually.
    try p.select(testing.allocator, lfAt(p, 10.0, everywhere), everywhere, &sel);
    for (sel.items) |v| try testing.expectEqual(@as(u32, 0), v.level);
    try testing.expectEqual(@as(usize, 4), sel.items.len);

    // Zoomed out, they collide and the pairs merge.
    try p.select(testing.allocator, lfAt(p, 0.02, everywhere), everywhere, &sel);
    for (sel.items) |v| try testing.expect(v.level > 0);

    // At every zoom in between, every note is still represented exactly once — either as itself
    // or inside exactly one marker. A hierarchy that double-counts draws the vault twice.
    var z: f32 = 10;
    while (z > 0.001) : (z *= 0.7) {
        try p.select(testing.allocator, lfAt(p, z, everywhere), everywhere, &sel);
        try testing.expectEqual(@as(u32, 4), selectedCount(p, sel.items));
    }
}

test "one level for the whole view, whatever the local density" {
    // Two groups of the same size at the same zoom: one tight, one spread over a hundred times
    // the distance. This used to be the case for a per-region decision — the tight group staying
    // merged while the loose one resolved — and it is exactly what a global level gives up. What
    // has to survive is the invariant that outlived it: whichever way the one level falls, every
    // note is still represented exactly once, and both groups fall the same way.
    const gpa = testing.allocator;
    const maps = try gpa.alloc([]u32, 1);
    maps[0] = try gpa.alloc(u32, 8);
    for (0..4) |i| maps[0][i] = 0;
    for (4..8) |i| maps[0][i] = 1;
    const counts = try gpa.alloc(usize, 2);
    counts[0] = 8;
    counts[1] = 2;
    var ladder: multilevel.Ladder = .{ .maps = maps, .counts = counts };
    defer ladder.deinit(gpa);

    const pos = [_]dvui.Point{
        // Tight: four notes within one unit of each other.
        .{ .x = -500, .y = 0 },  .{ .x = -499, .y = 0 },
        .{ .x = -500, .y = 1 },  .{ .x = -499, .y = 1 },
        // Loose: four notes a hundred units apart.
        .{ .x = 400, .y = 0 },   .{ .x = 500, .y = 0 },
        .{ .x = 400, .y = 100 }, .{ .x = 500, .y = 100 },
    };
    var p = try build(gpa, ladder, &pos, &.{});
    defer p.deinit();

    // Both groups are asked the same question and give the same answer.
    const lf = lfAt(p, 1.0, everywhere);
    try testing.expectEqual(p.splitT(1, 0, lf), p.splitT(1, 1, lf));

    var sel: std.ArrayList(Visible) = .empty;
    defer sel.deinit(gpa);

    // Across the whole zoom range, in either regime, nothing is drawn twice and nothing is lost.
    var z: f32 = 100;
    while (z > 0.0001) : (z *= 0.7) {
        try p.select(gpa, lfAt(p, z, everywhere), everywhere, &sel);
        try testing.expectEqual(@as(u32, 8), selectedCount(p, sel.items));
    }
}

test "the draw budget bounds the frame however large the vault" {
    // The guarantee the global level exists for. A vault far too big to draw note-by-note is
    // pulled up the hierarchy until what reaches the screen fits the budget — and the budget is
    // what decides it, not the zoom, so the same bound holds at every zoom.
    const gpa = testing.allocator;
    const n = 20000;

    // A plain spatial pyramid: no link structure, so `build`'s positional fallback does the
    // coarsening, which is also the worst case for how well the levels shrink.
    var ladder: multilevel.Ladder = .{};
    ladder.counts = try gpa.alloc(usize, 1);
    ladder.counts[0] = n;
    ladder.maps = try gpa.alloc([]u32, 0);
    defer ladder.deinit(gpa);

    const pos = try gpa.alloc(dvui.Point, n);
    defer gpa.free(pos);
    var rnd = std.Random.DefaultPrng.init(0x515ed);
    for (pos) |*q| q.* = .{
        .x = rnd.random().float(f32) * 1000,
        .y = rnd.random().float(f32) * 1000,
    };
    var p = try build(gpa, ladder, pos, &.{});
    defer p.deinit();

    var sel: std.ArrayList(Visible) = .empty;
    defer sel.deinit(gpa);

    const budget: f32 = 500;
    var z: f32 = 0.01;
    while (z < 100) : (z *= 1.7) {
        // The view, in world units, is a fixed panel at this zoom — so zooming in shrinks what it
        // covers, which is the other half of why a finer level becomes affordable.
        const half = 500 / z;
        const view: dvui.Rect = .{ .x = 500 - half, .y = 500 - half, .w = half * 2, .h = half * 2 };
        try p.select(gpa, p.levelFor(z, 12, view, budget), view, &sel);
        // Generous slack over the budget: the estimate assumes clusters are spread evenly, and a
        // random layout is only roughly that. The claim being tested is that the count is bounded
        // by the budget rather than by the vault — 20000 notes, and never a fraction of them.
        try testing.expect(sel.items.len < budget * 4);
    }
}

test "selection culls to the view" {
    var ladder = try fixture(testing.allocator);
    defer ladder.deinit(testing.allocator);
    const pos = [_]dvui.Point{
        .{ .x = -10, .y = 0 },
        .{ .x = -20, .y = 0 },
        .{ .x = 10, .y = 0 },
        .{ .x = 20, .y = 0 },
    };
    var p = try build(testing.allocator, ladder, &pos, &.{});
    defer p.deinit();

    var sel: std.ArrayList(Visible) = .empty;
    defer sel.deinit(testing.allocator);
    // A window over the right-hand pair only.
    try p.select(testing.allocator, lfAt(p, 10.0, .{ .x = 5, .y = -5, .w = 30, .h = 10 }), .{ .x = 5, .y = -5, .w = 30, .h = 10 }, &sel);
    try testing.expectEqual(@as(usize, 2), sel.items.len);
    for (sel.items) |v| try testing.expect(pos[v.index].x > 0);
}

test "a vault with no coarsenable link structure still gets levels" {
    // The orphan case: the layout's matching cannot merge unlinked notes, so it hands back a
    // one-level ladder. Position has to carry the rest, or zooming out never merges anything.
    const gpa = testing.allocator;
    const n = 2000;
    var ladder: multilevel.Ladder = .{};
    ladder.counts = try gpa.alloc(usize, 1);
    ladder.counts[0] = n;
    ladder.maps = try gpa.alloc([]u32, 0);
    defer ladder.deinit(gpa);

    const pos = try gpa.alloc(dvui.Point, n);
    defer gpa.free(pos);
    for (pos, 0..) |*q, i| {
        const f: f32 = @floatFromInt(i);
        q.* = .{ .x = @mod(f * 37, 800) - 400, .y = @floor(f / 40) * 20 - 400 };
    }

    var p = try build(gpa, ladder, pos, &.{});
    defer p.deinit();

    try testing.expect(p.levels.len > 1);
    try testing.expect(p.levels[p.maxLevel()].len <= coarsest_clusters);
    // Every note is still represented exactly once at every level.
    for (p.levels) |level| {
        var total: u32 = 0;
        for (level) |c| total += c.count;
        try testing.expectEqual(@as(u32, n), total);
    }
    // Levels shrink, and pulling far enough out reaches the coarsest one.
    for (1..p.levels.len) |l| try testing.expect(p.levels[l].len < p.levels[l - 1].len);

    var sel: std.ArrayList(Visible) = .empty;
    defer sel.deinit(gpa);
    try p.select(gpa, lfAt(p, 0.0001, everywhere), everywhere, &sel);
    try testing.expectEqual(p.levels[p.maxLevel()].len, sel.items.len);
    try testing.expectEqual(@as(u32, n), selectedCount(p, sel.items));

    // `clusterOf` agrees with the counts: gathering every note by its level-1 cluster reproduces
    // that level's membership.
    const tally = try gpa.alloc(u32, p.levels[1].len);
    defer gpa.free(tally);
    @memset(tally, 0);
    for (0..n) |i| tally[p.clusterOf(i, 1)] += 1;
    for (p.levels[1], tally) |c, t| try testing.expectEqual(c.count, t);
}

/// The four-note fixture, with both pairs internally linked and three links running across.
fn webFixture(gpa: std.mem.Allocator) !Pyramid {
    var ladder = try fixture(gpa);
    defer ladder.deinit(gpa);
    const pos = [_]dvui.Point{
        .{ .x = -10, .y = 0 },
        .{ .x = -20, .y = 0 },
        .{ .x = 10, .y = 0 },
        .{ .x = 20, .y = 0 },
    };
    const edges = [_]CEdge{
        .{ .a = 0, .b = 1 }, // inside the left pair
        .{ .a = 2, .b = 3 }, // inside the right pair
        .{ .a = 0, .b = 2 }, // across
        .{ .a = 0, .b = 3 }, // across
        .{ .a = 1, .b = 2 }, // across
    };
    return build(gpa, ladder, &pos, &edges);
}

test "a coarse mark does not grow a starburst of fine spokes into an open neighbor" {
    // Marks: left cluster closed (one mass), right cluster open (its notes drawn). Without
    // level-matched coalescing, every leaf link into the mass becomes its own spoke.
    const gpa = testing.allocator;
    var p = try webFixture(gpa);
    defer p.deinit();

    const ClosedLeft = struct {
        fn isOpen(_: *const anyopaque, level: u32, index: u32) bool {
            // Only the right level-1 cluster is open.
            return level == 1 and index == 1;
        }
        fn posOf(ctx: *const anyopaque, level: u32, index: u32) dvui.Point {
            const py: *const Pyramid = @ptrCast(@alignCast(ctx));
            return py.levels[level][index].pos;
        }
    };
    const marks: Marks = .{
        .ctx = &p,
        .isOpen = ClosedLeft.isOpen,
        .posOf = ClosedLeft.posOf,
    };

    var web: std.ArrayList(Link) = .empty;
    defer web.deinit(gpa);
    // lf fine enough that without marks the right side would fully refine.
    try p.gatherWeb(gpa, gpa, lfAt(p, 10.0, everywhere), everywhere, &.{}, marks, &web);
    // Three underlying cross links into the left mass → one spoke (inners on the open
    // right side may still draw). Without level-match this was three spokes.
    var into_mass: usize = 0;
    for (web.items) |l| {
        const hit = (l.from_level == 1 and l.from_index == 0) or (l.to_level == 1 and l.to_index == 0);
        if (hit) into_mass += 1;
    }
    try testing.expectEqual(@as(usize, 1), into_mass);
}

test "links between two regions coalesce into one" {
    const gpa = testing.allocator;
    var p = try webFixture(gpa);
    defer p.deinit();

    // Three links run between the pairs; at level 1 they are one link between two clusters.
    try testing.expectEqual(@as(usize, 1), p.edges[1].len);
    try testing.expectEqual(@as(usize, 3), p.edgeKidsOf(1, 0).len);
    // The two within-pair links belong to their clusters, not to any coarse link.
    try testing.expectEqual(@as(usize, 1), p.innerOf(1, 0).len);
    try testing.expectEqual(@as(usize, 1), p.innerOf(1, 1).len);

    var web: std.ArrayList(Link) = .empty;
    defer web.deinit(gpa);

    // Zoomed out, both pairs are markers: one line between them, and the links inside each
    // pair are not drawn at all because there is nothing for them to span.
    try p.gatherWeb(gpa, gpa, lfAt(p, 0.02, everywhere), everywhere, &.{}, null, &web);
    try testing.expectEqual(@as(usize, 1), web.items.len);
    try testing.expectEqual(no_edge, web.items[0].edge);

    // Zoomed in, every link is its own line again — and each exactly once.
    try p.gatherWeb(gpa, gpa, lfAt(p, 10.0, everywhere), everywhere, &.{}, null, &web);
    try testing.expectEqual(@as(usize, 5), web.items.len);
    var got = [_]bool{false} ** 5;
    for (web.items) |l| {
        try testing.expect(l.edge != no_edge);
        try testing.expect(!got[l.edge]);
        got[l.edge] = true;
    }
}

test "a reversed child link still joins the resting marker it belongs under" {
    // Parent link stored a < b; the only underlying link runs the other way. Freezing the
    // left marker and opening the right must still attach the left end to the marker, not swap
    // it onto the child that happens to sit in slot `a`.
    const gpa = testing.allocator;
    const maps = try gpa.alloc([]u32, 1);
    maps[0] = try gpa.alloc(u32, 3);
    maps[0][0] = 0; // left leaf → left marker
    maps[0][1] = 1; // right pair → right marker
    maps[0][2] = 1;
    const counts = try gpa.alloc(usize, 2);
    counts[0] = 3;
    counts[1] = 2;
    var ladder: multilevel.Ladder = .{ .maps = maps, .counts = counts };
    defer ladder.deinit(gpa);

    // Left note far left; right pair close together so they stay merged while the left is alone.
    const pos = [_]dvui.Point{
        .{ .x = -200, .y = 0 },
        .{ .x = 10, .y = 0 },
        .{ .x = 12, .y = 0 },
    };
    // Only link runs from a right note *into* the left — opposite the coarse a<b order.
    const edges = [_]CEdge{.{ .a = 2, .b = 0 }};
    var p = try build(gpa, ladder, &pos, &edges);
    defer p.deinit();

    try testing.expectEqual(@as(usize, 1), p.edges[1].len);

    var web: std.ArrayList(Link) = .empty;
    defer web.deinit(gpa);
    // Zoom where the right pair is still one marker and the left note is itself.
    try p.gatherWeb(gpa, gpa, lfAt(p, 1.0, everywhere), everywhere, &pos, null, &web);
    try testing.expectEqual(@as(usize, 1), web.items.len);
    // One end on the left note, the other on the right marker's centre (~11).
    const l = web.items[0];
    const left_x = @min(l.from.x, l.to.x);
    const right_x = @max(l.from.x, l.to.x);
    try testing.expectApproxEqAbs(@as(f32, -200), left_x, 0.5);
    try testing.expectApproxEqAbs(@as(f32, 11), right_x, 1.0);
}

test "a link is kept when it crosses the view, not when an end is inside it" {
    // The vanishing-links case that gathering from visible notes could not reach: a long link
    // whose two ends are both well outside the window it passes through.
    const gpa = testing.allocator;
    const maps = try gpa.alloc([]u32, 1);
    maps[0] = try gpa.alloc(u32, 2);
    maps[0][0] = 0;
    maps[0][1] = 1;
    const counts = try gpa.alloc(usize, 2);
    counts[0] = 2;
    counts[1] = 2;
    var ladder: multilevel.Ladder = .{ .maps = maps, .counts = counts };
    defer ladder.deinit(gpa);

    const pos = [_]dvui.Point{ .{ .x = -1000, .y = 0 }, .{ .x = 1000, .y = 0 } };
    const edges = [_]CEdge{.{ .a = 0, .b = 1 }};
    var p = try build(gpa, ladder, &pos, &edges);
    defer p.deinit();

    var web: std.ArrayList(Link) = .empty;
    defer web.deinit(gpa);

    // A small window at the origin: neither end is within a thousand units of it, but the line
    // runs straight through.
    const window: dvui.Rect = .{ .x = -20, .y = -20, .w = 40, .h = 40 };
    try p.gatherWeb(gpa, gpa, lfAt(p, 10.0, window), window, &.{}, null, &web);
    try testing.expectEqual(@as(usize, 1), web.items.len);

    // A window the line misses entirely is still culled.
    const elsewhere: dvui.Rect = .{ .x = -20, .y = 500, .w = 40, .h = 40 };
    try p.gatherWeb(gpa, gpa, lfAt(p, 10.0, elsewhere), elsewhere, &.{}, null, &web);
    try testing.expectEqual(@as(usize, 0), web.items.len);
}

test "a link from a note into a merged region joins the marker" {
    const gpa = testing.allocator;
    var p = try webFixture(gpa);
    defer p.deinit();

    var web: std.ArrayList(Link) = .empty;
    defer web.deinit(gpa);

    // Sweeping zoom: whatever the mix of notes and markers, no line is ever drawn twice and
    // every line joins two distinct things.
    var z: f32 = 20;
    while (z > 0.001) : (z *= 0.6) {
        try p.gatherWeb(gpa, gpa, lfAt(p, z, everywhere), everywhere, &.{}, null, &web);
        for (web.items) |l| {
            try testing.expect(l.from.x != l.to.x or l.from.y != l.to.y);
        }
    }
}

test "live positions win over the ones layout left behind" {
    const gpa = testing.allocator;
    var p = try webFixture(gpa);
    defer p.deinit();

    var web: std.ArrayList(Link) = .empty;
    defer web.deinit(gpa);
    const live = [_]dvui.Point{
        .{ .x = -10, .y = 7 },
        .{ .x = -20, .y = 7 },
        .{ .x = 10, .y = 7 },
        .{ .x = 20, .y = 7 },
    };
    try p.gatherWeb(gpa, gpa, lfAt(p, 10.0, everywhere), everywhere, &live, null, &web);
    try testing.expectEqual(@as(usize, 5), web.items.len);
    for (web.items) |l| {
        try testing.expectApproxEqAbs(@as(f32, 7), l.from.y, 0.001);
        try testing.expectApproxEqAbs(@as(f32, 7), l.to.y, 0.001);
    }
}

test "a vault too small to have a hierarchy always draws its notes" {
    var ladder: multilevel.Ladder = .{};
    const counts = try testing.allocator.alloc(usize, 1);
    counts[0] = 3;
    ladder.counts = counts;
    ladder.maps = try testing.allocator.alloc([]u32, 0);
    defer ladder.deinit(testing.allocator);

    const pos = [_]dvui.Point{ .{}, .{ .x = 1 }, .{ .x = 2 } };
    var p = try build(testing.allocator, ladder, &pos, &.{});
    defer p.deinit();

    var sel: std.ArrayList(Visible) = .empty;
    defer sel.deinit(testing.allocator);
    try p.select(testing.allocator, lfAt(p, 0.0001, everywhere), everywhere, &sel);
    try testing.expectEqual(@as(usize, 3), sel.items.len);
    for (sel.items) |v| try testing.expectEqual(@as(u32, 0), v.level);
}
