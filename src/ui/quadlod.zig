//! Point-region quadtree LOD spine for organic overview.
//!
//! Each cell stores `count`, `centroid`, and a bbox. Zoom / budget decide which cells stay closed
//! (one mass) vs open into children. Empty quadrants are omitted. See docs/design/organic-lod.md.

const std = @import("std");
const dvui = @import("dvui");
const testing = std.testing;

/// Sentinel: no child in that quadrant.
pub const no_child: u32 = std.math.maxInt(u32);

/// Max notes in a leaf before we stop subdividing (still one cell).
pub const leaf_max: u32 = 1;
/// Hard depth cap so degenerate stacks cannot explode node count.
pub const max_depth: u32 = 24;
/// Notes at or above this link degree are pinned as singleton siblings of the remaining
/// spatial tree, so hub–spoke edges lift as soon as the parent opens (not only at leaf rung).
/// High enough that gauntlet isles (max deg ~10) stay whole; hub-and-spoke (deg hundreds) still pins.
pub const hub_pin_degree: u32 = 16;
/// Masses at or below this note count are "bundles" (typical gauntlet isle). Sticky keeps them
/// closed until the leaf rung, then opens straight to leaves — no sticky stop on 2-note shards.
pub const bundle_max: u32 = 12;
/// Minimum notes in a geometric child; tinier shards are absorbed so we don't emit pair-masses.
pub const min_split_part: u32 = 3;

pub const Node = struct {
    /// Axis-aligned cell (world).
    min_x: f32,
    min_y: f32,
    max_x: f32,
    max_y: f32,
    /// Mass centre of contained notes.
    centroid: dvui.Point = .{},
    count: u32 = 0,
    /// RMS distance from centroid — draw mass when smaller than the bbox half-diagonal.
    spread: f32 = 0,
    /// Distance from centroid to furthest note — camera framing.
    radius: f32 = 0,
    depth: u16 = 0,
    /// Parent node index, or `no_child` for the root.
    parent: u32 = no_child,
    /// Four children: SW, SE, NW, NE. `no_child` if empty / leaf.
    children: [4]u32 = .{ no_child, no_child, no_child, no_child },
    /// Contiguous range into `Tree.note_ids` for notes under this node (build fills leaves;
    /// internals get the union of children after build).
    leaf_start: u32 = 0,
    leaf_count: u32 = 0,
    /// True for spatial-forest glue that joins multiple link components. Never a sticky mass —
    /// select always opens these so coalesced agents stay component-pure (gauntlet islands).
    cross_isle: bool = false,

    pub fn isLeaf(self: Node) bool {
        return self.children[0] == no_child and self.children[1] == no_child and
            self.children[2] == no_child and self.children[3] == no_child;
    }

    pub fn hasChildren(self: Node) bool {
        return !self.isLeaf();
    }

    /// Half-diagonal of the bbox — world span used for screen-size open tests.
    pub fn extent(self: Node) f32 {
        const hx = (self.max_x - self.min_x) * 0.5;
        const hy = (self.max_y - self.min_y) * 0.5;
        return @sqrt(hx * hx + hy * hy);
    }

    /// World radius used for drawing: prefer spread (bulk), fall back to extent.
    pub fn drawRadius(self: Node) f32 {
        if (self.spread > 1e-6) return self.spread;
        if (self.radius > 1e-6) return self.radius;
        return @max(self.extent() * 0.35, 1e-3);
    }

    pub fn screenSpan(self: Node, zoom: f32) f32 {
        return self.extent() * zoom * 2;
    }

    /// Screen size of the drawn mass (spread), not the empty cell bbox. Small linked isles often
    /// sit in oversized cells after mid-split; opening on `screenSpan` shattered them too early.
    pub fn massSpan(self: Node, zoom: f32) f32 {
        return self.drawRadius() * zoom * 2;
    }

    /// Invert `screenSpan(z) > thresh` — minimum zoom at which sticky will *want* to open this
    /// node. Callers still need budget room; framing the children usually provides it.
    pub fn zoomToExceedSpan(self: Node, thresh_px: f32) f32 {
        const ext = @max(self.extent(), 1e-6);
        // Strict `>` in selectSticky — land a hair past the line.
        return (thresh_px * 1.001) / (ext * 2);
    }

    pub fn overlaps(self: Node, view: dvui.Rect) bool {
        return !(self.max_x < view.x or self.min_x > view.x + view.w or
            self.max_y < view.y or self.min_y > view.y + view.h);
    }
};

pub const Tree = struct {
    allocator: std.mem.Allocator,
    nodes: []Node = &.{},
    /// Note indices in leaf ranges (and rolled up for internals).
    note_ids: []u32 = &.{},
    /// `note_owner[note] =` deepest leaf node containing it.
    note_owner: []u32 = &.{},
    root: u32 = 0,

    pub fn deinit(self: *Tree) void {
        self.allocator.free(self.nodes);
        self.allocator.free(self.note_ids);
        self.allocator.free(self.note_owner);
        self.* = .{ .allocator = self.allocator };
    }

    pub fn nodeCount(self: Tree) usize {
        return self.nodes.len;
    }

    pub fn get(self: Tree, i: u32) Node {
        return self.nodes[i];
    }

    /// Single note index when this leaf holds exactly one note; else null.
    pub fn singleNote(self: Tree, node: u32) ?u32 {
        const n = self.nodes[node];
        if (n.count != 1 or n.leaf_count != 1) return null;
        return self.note_ids[n.leaf_start];
    }

    pub fn kidsOf(self: Tree, node: u32) [4]u32 {
        return self.nodes[node].children;
    }

    /// Walk ancestors from a leaf note up to root (root last). `out` must be large enough
    /// (`max_depth + 1`). Returns the slice written.
    pub fn ancestorsOfNote(self: Tree, note: u32, out: []u32) []u32 {
        if (note >= self.note_owner.len) return out[0..0];
        var i: u32 = self.note_owner[note];
        var n: usize = 0;
        while (true) {
            if (n >= out.len) break;
            out[n] = i;
            n += 1;
            if (i == self.root) break;
            i = parentOf(self, i) orelse break;
        }
        return out[0..n];
    }

    pub fn parentOf(self: Tree, node: u32) ?u32 {
        if (node >= self.nodes.len) return null;
        const p = self.nodes[node].parent;
        if (p == no_child) return null;
        return p;
    }
};

/// Build a point-region quadtree. `positions[i]` is note `i`.
/// Prefer `buildEx` with layout edges so link-islands stay pure under sticky masses.
pub fn build(allocator: std.mem.Allocator, positions: []const dvui.Point) !Tree {
    return buildEx(allocator, positions, &.{});
}

/// Galaxy LOD spine. When `edges` is non-empty, each **link component** gets its own spatial
/// subtree first; island roots are then hung under proximity glue (`cross_isle`). Sticky select
/// never emits glue as a mass, so coalesced agents stay inside one isle.
pub fn buildEx(
    allocator: std.mem.Allocator,
    positions: []const dvui.Point,
    edges: []const Edge,
) !Tree {
    var tree: Tree = .{ .allocator = allocator };
    if (positions.len == 0) {
        tree.nodes = try allocator.alloc(Node, 0);
        tree.note_ids = try allocator.alloc(u32, 0);
        tree.note_owner = try allocator.alloc(u32, 0);
        return tree;
    }

    var nodes: std.ArrayListUnmanaged(Node) = .empty;
    errdefer nodes.deinit(allocator);
    var note_ids: std.ArrayListUnmanaged(u32) = .empty;
    errdefer note_ids.deinit(allocator);

    const note_owner = try allocator.alloc(u32, positions.len);
    errdefer allocator.free(note_owner);
    @memset(note_owner, 0);

    const degrees = try noteDegrees(allocator, positions.len, edges);
    defer allocator.free(degrees);
    const adj = try buildAdj(allocator, positions.len, edges);
    defer allocator.free(adj.off);
    defer allocator.free(adj.to);

    const root = if (edges.len == 0)
        try buildSpatialRoot(allocator, &nodes, &note_ids, note_owner, positions, degrees, adj)
    else
        try buildComponentForest(allocator, &nodes, &note_ids, note_owner, positions, edges, degrees, adj);

    try rollupLeaves(allocator, nodes.items, note_ids.items);

    tree.nodes = try nodes.toOwnedSlice(allocator);
    tree.note_ids = try note_ids.toOwnedSlice(allocator);
    tree.note_owner = note_owner;
    tree.root = root;
    return tree;
}

fn noteDegrees(allocator: std.mem.Allocator, n: usize, edges: []const Edge) ![]u32 {
    const deg = try allocator.alloc(u32, n);
    @memset(deg, 0);
    for (edges) |e| {
        if (e.a >= n or e.b >= n or e.a == e.b) continue;
        deg[e.a] += 1;
        deg[e.b] += 1;
    }
    return deg;
}

const Adj = struct {
    off: []u32,
    to: []u32,

    fn nbrs(self: Adj, i: u32) []const u32 {
        return self.to[self.off[i]..self.off[i + 1]];
    }
};

fn buildAdj(allocator: std.mem.Allocator, n: usize, edges: []const Edge) !Adj {
    const off = try allocator.alloc(u32, n + 1);
    errdefer allocator.free(off);
    @memset(off, 0);
    for (edges) |e| {
        if (e.a >= n or e.b >= n or e.a == e.b) continue;
        off[e.a] += 1;
        off[e.b] += 1;
    }
    var sum: u32 = 0;
    for (off) |*o| {
        const d = o.*;
        o.* = sum;
        sum += d;
    }
    const to = try allocator.alloc(u32, sum);
    errdefer allocator.free(to);
    var cursor = try allocator.alloc(u32, n);
    defer allocator.free(cursor);
    @memcpy(cursor, off[0..n]);
    for (edges) |e| {
        if (e.a >= n or e.b >= n or e.a == e.b) continue;
        to[cursor[e.a]] = e.b;
        cursor[e.a] += 1;
        to[cursor[e.b]] = e.a;
        cursor[e.b] += 1;
    }
    return .{ .off = off, .to = to };
}

fn buildSpatialRoot(
    allocator: std.mem.Allocator,
    nodes: *std.ArrayListUnmanaged(Node),
    note_ids: *std.ArrayListUnmanaged(u32),
    note_owner: []u32,
    positions: []const dvui.Point,
    degrees: []const u32,
    adj: Adj,
) !u32 {
    var scratch: std.ArrayListUnmanaged(u32) = .empty;
    defer scratch.deinit(allocator);
    try scratch.ensureTotalCapacity(allocator, positions.len);
    for (0..positions.len) |i| scratch.appendAssumeCapacity(@intCast(i));

    const bb = contentBounds(positions, scratch.items);
    return buildNode(
        allocator,
        nodes,
        note_ids,
        note_owner,
        positions,
        degrees,
        adj,
        scratch.items,
        bb.min_x,
        bb.min_y,
        bb.max_x,
        bb.max_y,
        0,
    );
}

const Bounds = struct { min_x: f32, min_y: f32, max_x: f32, max_y: f32 };

fn contentBounds(positions: []const dvui.Point, indices: []const u32) Bounds {
    var min_x: f32 = std.math.floatMax(f32);
    var min_y: f32 = std.math.floatMax(f32);
    var max_x: f32 = -std.math.floatMax(f32);
    var max_y: f32 = -std.math.floatMax(f32);
    for (indices) |ni| {
        const p = positions[ni];
        min_x = @min(min_x, p.x);
        min_y = @min(min_y, p.y);
        max_x = @max(max_x, p.x);
        max_y = @max(max_y, p.y);
    }
    const pad = @max(@max(max_x - min_x, max_y - min_y) * 0.01, 1e-3);
    return .{
        .min_x = min_x - pad,
        .min_y = min_y - pad,
        .max_x = max_x + pad,
        .max_y = max_y + pad,
    };
}

fn buildComponentForest(
    allocator: std.mem.Allocator,
    nodes: *std.ArrayListUnmanaged(Node),
    note_ids: *std.ArrayListUnmanaged(u32),
    note_owner: []u32,
    positions: []const dvui.Point,
    edges: []const Edge,
    degrees: []const u32,
    adj: Adj,
) !u32 {
    const n = positions.len;
    const parent_uf = try allocator.alloc(u32, n);
    defer allocator.free(parent_uf);
    for (parent_uf, 0..) |*p, i| p.* = @intCast(i);

    const find = struct {
        fn f(uf: []u32, x: u32) u32 {
            var i = x;
            while (uf[i] != i) {
                uf[i] = uf[uf[i]];
                i = uf[i];
            }
            return i;
        }
    }.f;
    const unite = struct {
        fn f(uf: []u32, a: u32, b: u32) void {
            const ra = find(uf, a);
            const rb = find(uf, b);
            if (ra != rb) uf[rb] = ra;
        }
    }.f;

    for (edges) |e| {
        if (e.a >= n or e.b >= n) continue;
        unite(parent_uf, e.a, e.b);
    }

    // root → list of note indices
    var buckets = std.AutoHashMapUnmanaged(u32, std.ArrayListUnmanaged(u32)){};
    defer {
        var it = buckets.valueIterator();
        while (it.next()) |list| list.deinit(allocator);
        buckets.deinit(allocator);
    }
    for (0..n) |i| {
        const r = find(parent_uf, @intCast(i));
        const gop = try buckets.getOrPut(allocator, r);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(allocator, @intCast(i));
    }

    var island_roots: std.ArrayListUnmanaged(u32) = .empty;
    defer island_roots.deinit(allocator);
    try island_roots.ensureTotalCapacity(allocator, buckets.count());

    var it = buckets.iterator();
    while (it.next()) |entry| {
        const indices = entry.value_ptr.items;
        const bb = contentBounds(positions, indices);
        const isle = try buildNode(
            allocator,
            nodes,
            note_ids,
            note_owner,
            positions,
            degrees,
            adj,
            indices,
            bb.min_x,
            bb.min_y,
            bb.max_x,
            bb.max_y,
            0,
        );
        island_roots.appendAssumeCapacity(isle);
    }

    if (island_roots.items.len == 1) {
        setDepthTree(nodes.items, island_roots.items[0], 0);
        return island_roots.items[0];
    }

    return buildForestOverIslands(allocator, nodes, island_roots.items, 0);
}

/// Spatial quadtree whose leaves are pre-built island subtree roots (not raw notes).
fn buildForestOverIslands(
    allocator: std.mem.Allocator,
    nodes: *std.ArrayListUnmanaged(Node),
    island_roots: []const u32,
    depth: u16,
) !u32 {
    if (island_roots.len == 0) return error.EmptyForest;
    if (island_roots.len == 1) {
        setDepthTree(nodes.items, island_roots[0], depth);
        return island_roots[0];
    }

    var min_x: f32 = std.math.floatMax(f32);
    var min_y: f32 = std.math.floatMax(f32);
    var max_x: f32 = -std.math.floatMax(f32);
    var max_y: f32 = -std.math.floatMax(f32);
    var cx: f32 = 0;
    var cy: f32 = 0;
    var count: u32 = 0;
    var sum_d2: f32 = 0;
    var max_r: f32 = 0;
    for (island_roots) |id| {
        const isle = nodes.items[id];
        min_x = @min(min_x, isle.min_x);
        min_y = @min(min_y, isle.min_y);
        max_x = @max(max_x, isle.max_x);
        max_y = @max(max_y, isle.max_y);
        cx += isle.centroid.x * @as(f32, @floatFromInt(isle.count));
        cy += isle.centroid.y * @as(f32, @floatFromInt(isle.count));
        count += isle.count;
    }
    const inv: f32 = 1.0 / @as(f32, @floatFromInt(@max(count, 1)));
    cx *= inv;
    cy *= inv;
    for (island_roots) |id| {
        const isle = nodes.items[id];
        const dx = isle.centroid.x - cx;
        const dy = isle.centroid.y - cy;
        const d = @sqrt(dx * dx + dy * dy) + isle.radius;
        sum_d2 += (dx * dx + dy * dy) * @as(f32, @floatFromInt(isle.count));
        max_r = @max(max_r, d);
    }
    const spread = @sqrt(sum_d2 * inv);

    const my_index: u32 = @intCast(nodes.items.len);
    try nodes.append(allocator, .{
        .min_x = min_x,
        .min_y = min_y,
        .max_x = max_x,
        .max_y = max_y,
        .centroid = .{ .x = cx, .y = cy },
        .count = count,
        .spread = spread,
        .radius = max_r,
        .depth = depth,
        .cross_isle = true,
    });

    if (depth >= max_depth) {
        // Degenerate: hang every island as… we only have 4 child slots. Keep splitting by
        // mid even at max depth via forced binary-ish recursion on halves if needed.
    }

    const mid_x = (min_x + max_x) * 0.5;
    const mid_y = (min_y + max_y) * 0.5;
    var buckets: [4]std.ArrayListUnmanaged(u32) = .{ .empty, .empty, .empty, .empty };
    defer for (&buckets) |*b| b.deinit(allocator);

    for (island_roots) |id| {
        const p = nodes.items[id].centroid;
        const east = p.x >= mid_x;
        const north = p.y >= mid_y;
        const q: usize = (@as(usize, @intFromBool(north)) << 1) | @as(usize, @intFromBool(east));
        try buckets[q].append(allocator, id);
    }

    // If everything landed in one quadrant, split by count median on the wider axis instead of
    // looping forever on the same mid.
    var nonempty: usize = 0;
    for (buckets) |b| {
        if (b.items.len != 0) nonempty += 1;
    }
    if (nonempty == 1 and island_roots.len > 1) {
        for (&buckets) |*b| b.clearRetainingCapacity();
        const wide_x = (max_x - min_x) >= (max_y - min_y);
        // Sort island ids by centroid along the axis, split in half.
        var order = try allocator.alloc(u32, island_roots.len);
        defer allocator.free(order);
        @memcpy(order, island_roots);
        const SortCtx = struct { ns: []const Node, wide_x: bool };
        std.mem.sort(u32, order, SortCtx{ .ns = nodes.items, .wide_x = wide_x }, struct {
            fn less(ctx: SortCtx, a: u32, b: u32) bool {
                if (ctx.wide_x) return ctx.ns[a].centroid.x < ctx.ns[b].centroid.x;
                return ctx.ns[a].centroid.y < ctx.ns[b].centroid.y;
            }
        }.less);
        const mid = order.len / 2;
        try buckets[0].appendSlice(allocator, order[0..mid]);
        try buckets[1].appendSlice(allocator, order[mid..]);
    }

    var any_child = false;
    for (0..4) |q| {
        if (buckets[q].items.len == 0) continue;
        const child = try buildForestOverIslands(allocator, nodes, buckets[q].items, depth + 1);
        nodes.items[my_index].children[q] = child;
        nodes.items[child].parent = my_index;
        any_child = true;
    }
    if (!any_child) {
        // Should not happen with len >= 2.
        setDepthTree(nodes.items, island_roots[0], depth);
        return island_roots[0];
    }
    return my_index;
}

fn setDepthTree(nodes: []Node, id: u32, depth: u16) void {
    nodes[id].depth = depth;
    for (nodes[id].children) |c| {
        if (c == no_child) continue;
        setDepthTree(nodes, c, depth + 1);
    }
}

fn buildNode(
    allocator: std.mem.Allocator,
    nodes: *std.ArrayListUnmanaged(Node),
    note_ids: *std.ArrayListUnmanaged(u32),
    note_owner: []u32,
    positions: []const dvui.Point,
    degrees: []const u32,
    adj: Adj,
    indices: []const u32,
    min_x: f32,
    min_y: f32,
    max_x: f32,
    max_y: f32,
    depth: u16,
) anyerror!u32 {
    var cx: f32 = 0;
    var cy: f32 = 0;
    for (indices) |ni| {
        cx += positions[ni].x;
        cy += positions[ni].y;
    }
    const inv: f32 = 1.0 / @as(f32, @floatFromInt(indices.len));
    cx *= inv;
    cy *= inv;

    var sum_d2: f32 = 0;
    var max_r: f32 = 0;
    for (indices) |ni| {
        const dx = positions[ni].x - cx;
        const dy = positions[ni].y - cy;
        const d2 = dx * dx + dy * dy;
        sum_d2 += d2;
        max_r = @max(max_r, @sqrt(d2));
    }
    const spread = @sqrt(sum_d2 * inv);

    const my_index: u32 = @intCast(nodes.items.len);
    try nodes.append(allocator, .{
        .min_x = min_x,
        .min_y = min_y,
        .max_x = max_x,
        .max_y = max_y,
        .centroid = .{ .x = cx, .y = cy },
        .count = @intCast(indices.len),
        .spread = spread,
        .radius = max_r,
        .depth = depth,
    });

    const stop = indices.len <= leaf_max or depth >= max_depth or
        (max_x - min_x) < 1e-5 or (max_y - min_y) < 1e-5;
    if (stop) {
        const start: u32 = @intCast(note_ids.items.len);
        try note_ids.appendSlice(allocator, indices);
        nodes.items[my_index].leaf_start = start;
        nodes.items[my_index].leaf_count = @intCast(indices.len);
        for (indices) |ni| note_owner[ni] = my_index;
        return my_index;
    }

    // Pin high-degree notes as singleton siblings so a star is readable as soon as this cell
    // opens — geometric mid-split alone buries the hub with its nearest spokes until leaf rung.
    if (try pinHubsUnder(
        allocator,
        nodes,
        note_ids,
        note_owner,
        positions,
        degrees,
        adj,
        indices,
        my_index,
        depth,
    )) return my_index;

    const mid_x = (min_x + max_x) * 0.5;
    const mid_y = (min_y + max_y) * 0.5;
    // SW, SE, NW, NE
    var buckets: [4]std.ArrayListUnmanaged(u32) = .{ .empty, .empty, .empty, .empty };
    defer for (&buckets) |*b| b.deinit(allocator);

    for (indices) |ni| {
        const p = positions[ni];
        const east = p.x >= mid_x;
        const north = p.y >= mid_y;
        const q: usize = (@as(usize, @intFromBool(north)) << 1) | @as(usize, @intFromBool(east));
        try buckets[q].append(allocator, ni);
    }
    // Linked neighbours pull notes across the mid-split so an isle does not shatter into
    // unlinked geometric pairs (gauntlet islands of 5–10).
    try linkPullBuckets(allocator, positions, adj, indices, &buckets);
    try absorbTinyBuckets(allocator, positions, adj, indices, &buckets);

    // Degenerate: everything in one bucket after pull/absorb — split by count on the wide axis.
    var nonempty: usize = 0;
    var only: usize = 0;
    for (buckets, 0..) |b, qi| {
        if (b.items.len != 0) {
            nonempty += 1;
            only = qi;
        }
    }
    if (nonempty == 1 and buckets[only].items.len == indices.len and indices.len > leaf_max) {
        for (&buckets) |*b| b.clearRetainingCapacity();
        const wide_x = (max_x - min_x) >= (max_y - min_y);
        var order = try allocator.alloc(u32, indices.len);
        defer allocator.free(order);
        @memcpy(order, indices);
        std.mem.sort(u32, order, SortPos{ .pts = positions, .wide_x = wide_x }, struct {
            fn less(ctx: SortPos, a: u32, b: u32) bool {
                if (ctx.wide_x) return ctx.pts[a].x < ctx.pts[b].x;
                return ctx.pts[a].y < ctx.pts[b].y;
            }
        }.less);
        const mid = order.len / 2;
        try buckets[0].appendSlice(allocator, order[0..mid]);
        try buckets[1].appendSlice(allocator, order[mid..]);
    }

    var any_child = false;
    for (0..4) |q| {
        if (buckets[q].items.len == 0) continue;
        const bb = contentBounds(positions, buckets[q].items);
        const child = try buildNode(
            allocator,
            nodes,
            note_ids,
            note_owner,
            positions,
            degrees,
            adj,
            buckets[q].items,
            bb.min_x,
            bb.min_y,
            bb.max_x,
            bb.max_y,
            depth + 1,
        );
        nodes.items[my_index].children[q] = child;
        nodes.items[child].parent = my_index;
        any_child = true;
    }

    if (!any_child) {
        const start: u32 = @intCast(note_ids.items.len);
        try note_ids.appendSlice(allocator, indices);
        nodes.items[my_index].leaf_start = start;
        nodes.items[my_index].leaf_count = @intCast(indices.len);
        for (indices) |ni| note_owner[ni] = my_index;
    }
    return my_index;
}

const SortPos = struct { pts: []const dvui.Point, wide_x: bool };

/// After a geometric mid-split, move each note toward the bucket holding more of its neighbours.
fn linkPullBuckets(
    allocator: std.mem.Allocator,
    positions: []const dvui.Point,
    adj: Adj,
    indices: []const u32,
    buckets: *[4]std.ArrayListUnmanaged(u32),
) !void {
    if (adj.to.len == 0 or indices.len < 3) return;

    var in_set = std.AutoHashMapUnmanaged(u32, void){};
    defer in_set.deinit(allocator);
    try in_set.ensureTotalCapacity(allocator, @intCast(indices.len));
    for (indices) |ni| try in_set.put(allocator, ni, {});

    var assign = std.AutoHashMapUnmanaged(u32, u8){};
    defer assign.deinit(allocator);
    try assign.ensureTotalCapacity(allocator, @intCast(indices.len));

    var pass: usize = 0;
    while (pass < 3) : (pass += 1) {
        assign.clearRetainingCapacity();
        for (0..4) |q| {
            for (buckets[q].items) |ni| try assign.put(allocator, ni, @intCast(q));
        }
        var moves: [4]std.ArrayListUnmanaged(u32) = .{ .empty, .empty, .empty, .empty };
        defer for (&moves) |*m| m.deinit(allocator);

        for (0..4) |q| {
            for (buckets[q].items) |ni| {
                var w: [4]f32 = .{ 0, 0, 0, 0 };
                w[q] += 0.25; // stay bias
                for (adj.nbrs(ni)) |nb| {
                    if (!in_set.contains(nb)) continue;
                    const bq = assign.get(nb) orelse continue;
                    w[bq] += 1;
                }
                var best: usize = q;
                var best_w = w[q];
                for (0..4) |cand| {
                    if (w[cand] > best_w) {
                        best_w = w[cand];
                        best = cand;
                    }
                }
                if (best != q) try moves[best].append(allocator, ni);
            }
        }
        // Apply moves (rebuild buckets from assign + moves).
        var moved = false;
        for (0..4) |dst| {
            for (moves[dst].items) |ni| {
                const src = assign.get(ni) orelse continue;
                if (src == dst) continue;
                // Remove from src
                const sb = &buckets[src];
                for (sb.items, 0..) |x, i| {
                    if (x == ni) {
                        _ = sb.swapRemove(i);
                        break;
                    }
                }
                try buckets[dst].append(allocator, ni);
                try assign.put(allocator, ni, @intCast(dst));
                moved = true;
            }
        }
        if (!moved) break;
    }
    _ = positions;
}

/// Fold shards smaller than `min_split_part` into the best non-empty bucket.
/// Prefer the destination that already holds more of the shard's neighbours (link weight),
/// then fall back to nearest centroid — so a 2-note geometric cut rejoins its linked isle.
fn absorbTinyBuckets(
    allocator: std.mem.Allocator,
    positions: []const dvui.Point,
    adj: Adj,
    indices: []const u32,
    buckets: *[4]std.ArrayListUnmanaged(u32),
) !void {
    var in_set = std.AutoHashMapUnmanaged(u32, void){};
    defer in_set.deinit(allocator);
    try in_set.ensureTotalCapacity(allocator, @intCast(indices.len));
    for (indices) |ni| try in_set.put(allocator, ni, {});

    var assign = std.AutoHashMapUnmanaged(u32, u8){};
    defer assign.deinit(allocator);

    var guard: usize = 0;
    while (guard < 4) : (guard += 1) {
        var tiny: ?usize = null;
        for (0..4) |q| {
            if (buckets[q].items.len > 0 and buckets[q].items.len < min_split_part) {
                tiny = q;
                break;
            }
        }
        const t = tiny orelse break;

        assign.clearRetainingCapacity();
        for (0..4) |q| {
            for (buckets[q].items) |ni| try assign.put(allocator, ni, @intCast(q));
        }

        var link_w: [4]f32 = .{ 0, 0, 0, 0 };
        for (buckets[t].items) |ni| {
            for (adj.nbrs(ni)) |nb| {
                if (!in_set.contains(nb)) continue;
                const bq = assign.get(nb) orelse continue;
                if (bq == t) continue;
                link_w[bq] += 1;
            }
        }

        var tx: f32 = 0;
        var ty: f32 = 0;
        for (buckets[t].items) |ni| {
            tx += positions[ni].x;
            ty += positions[ni].y;
        }
        const inv = 1.0 / @as(f32, @floatFromInt(buckets[t].items.len));
        tx *= inv;
        ty *= inv;

        var best: ?usize = null;
        var best_link: f32 = -1;
        var best_d: f32 = std.math.floatMax(f32);
        for (0..4) |q| {
            if (q == t or buckets[q].items.len == 0) continue;
            var cx: f32 = 0;
            var cy: f32 = 0;
            for (buckets[q].items) |ni| {
                cx += positions[ni].x;
                cy += positions[ni].y;
            }
            const iq = 1.0 / @as(f32, @floatFromInt(buckets[q].items.len));
            cx *= iq;
            cy *= iq;
            const dx = cx - tx;
            const dy = cy - ty;
            const d = dx * dx + dy * dy;
            const lw = link_w[q];
            if (lw > best_link or (lw == best_link and d < best_d)) {
                best_link = lw;
                best_d = d;
                best = q;
            }
        }
        const dst = best orelse break;
        try buckets[dst].appendSlice(allocator, buckets[t].items);
        buckets[t].clearRetainingCapacity();
    }
}

/// When `indices` mixes hubs and non-hubs, hang hub singletons + one spatial remainder under
/// `parent`. Returns true if children were attached.
fn pinHubsUnder(
    allocator: std.mem.Allocator,
    nodes: *std.ArrayListUnmanaged(Node),
    note_ids: *std.ArrayListUnmanaged(u32),
    note_owner: []u32,
    positions: []const dvui.Point,
    degrees: []const u32,
    adj: Adj,
    indices: []const u32,
    parent: u32,
    depth: u16,
) anyerror!bool {
    if (degrees.len == 0 or indices.len < 3) return false;

    var hubs: std.ArrayListUnmanaged(u32) = .empty;
    defer hubs.deinit(allocator);
    var rest: std.ArrayListUnmanaged(u32) = .empty;
    defer rest.deinit(allocator);
    try rest.ensureTotalCapacity(allocator, indices.len);

    for (indices) |ni| {
        const d = if (ni < degrees.len) degrees[ni] else 0;
        if (d >= hub_pin_degree) {
            try hubs.append(allocator, ni);
        } else {
            rest.appendAssumeCapacity(ni);
        }
    }
    if (hubs.items.len == 0 or rest.items.len == 0) return false;

    std.mem.sort(u32, hubs.items, degrees, struct {
        fn less(deg: []const u32, a: u32, b: u32) bool {
            return deg[a] > deg[b];
        }
    }.less);

    const max_pin = @min(hubs.items.len, @as(usize, 3));
    var slot: usize = 0;
    while (slot < max_pin) : (slot += 1) {
        const hub = hubs.items[slot];
        const p = positions[hub];
        const pad: f32 = 1e-3;
        const hub_only = [_]u32{hub};
        const child = try buildNode(
            allocator,
            nodes,
            note_ids,
            note_owner,
            positions,
            degrees,
            adj,
            &hub_only,
            p.x - pad,
            p.y - pad,
            p.x + pad,
            p.y + pad,
            depth + 1,
        );
        nodes.items[parent].children[slot] = child;
        nodes.items[child].parent = parent;
    }

    if (slot < 4) {
        if (max_pin < hubs.items.len) {
            try rest.ensureUnusedCapacity(allocator, hubs.items.len - max_pin);
            for (hubs.items[max_pin..]) |h| rest.appendAssumeCapacity(h);
        }
        const bb = contentBounds(positions, rest.items);
        const child = try buildNode(
            allocator,
            nodes,
            note_ids,
            note_owner,
            positions,
            degrees,
            adj,
            rest.items,
            bb.min_x,
            bb.min_y,
            bb.max_x,
            bb.max_y,
            depth + 1,
        );
        nodes.items[parent].children[slot] = child;
        nodes.items[child].parent = parent;
    }
    return true;
}

/// Fill internal `leaf_start/count` by concatenating children into a fresh packed list.
/// Rebuilds `note_ids` so ranges are contiguous per node (post-order).
fn rollupLeaves(allocator: std.mem.Allocator, nodes: []Node, old_ids: []u32) !void {
    _ = old_ids;
    _ = allocator;
    // Leaves already have ranges. Internals: leave leaf_count 0 and rely on note_owner +
    // children for edge lift (livingAncestor). Avoid a second giant rewrite of note_ids.
    // Mark internals explicitly.
    for (nodes) |*n| {
        if (n.hasChildren()) {
            n.leaf_start = 0;
            n.leaf_count = 0;
        }
    }
}

/// Map a note to the living **agent** that covers it: climb from the note's leaf toward the
/// root until `has_agent` is true. This matches the culled draw set (sticky-open walk does not —
/// off-screen branches are open in sticky but never emitted, so endpoints used to miss and
/// collapse to the origin / one center cell).
pub fn livingAgent(
    tree: Tree,
    note: u32,
    has_agent: *const fn (ctx: *const anyopaque, node: u32) bool,
    ctx: *const anyopaque,
) ?u32 {
    if (note >= tree.note_owner.len) return null;
    var cur = tree.note_owner[note];
    var guard: usize = 0;
    while (guard < max_depth + 2) : (guard += 1) {
        if (has_agent(ctx, cur)) return cur;
        cur = findParent(tree, cur) orelse break;
    }
    if (has_agent(ctx, tree.root)) return tree.root;
    return null;
}

/// Deprecated name kept for call sites that still pass open-bits; prefer `livingAgent`.
pub fn livingAncestor(
    tree: Tree,
    note: u32,
    is_open: *const fn (ctx: *const anyopaque, node: u32) bool,
    ctx: *const anyopaque,
) u32 {
    // Old semantics (open-walk) — only used by tests if any; product uses livingAgent.
    if (note >= tree.note_owner.len) return tree.root;
    var chain: [max_depth + 2]u32 = undefined;
    var depth: usize = 0;
    var cur = tree.note_owner[note];
    while (true) {
        chain[depth] = cur;
        depth += 1;
        if (cur == tree.root or depth >= chain.len) break;
        cur = findParent(tree, cur) orelse break;
    }
    if (depth == 0) return tree.root;
    var living = chain[depth - 1];
    var i: usize = depth;
    while (i > 0) {
        i -= 1;
        const node = chain[i];
        if (!is_open(ctx, living)) break;
        living = node;
    }
    return living;
}

fn findParent(tree: Tree, node: u32) ?u32 {
    return tree.parentOf(node);
}

pub const Edge = struct { a: u32, b: u32 };

pub const LiftedEdge = struct {
    from_node: u32,
    to_node: u32,
    from: dvui.Point,
    to: dvui.Point,
};

pub const LiftOpts = struct {
    /// Global unique agent-pair cap.
    max_edges: usize = 480,
    /// Per-agent incident cap. High enough for a readable hub star; mesh graphs still diversify
    /// via strided examine + the global max_edges cap.
    max_degree: u16 = 24,
    /// Hard cap on edge examinations per frame (each does two ancestor climbs).
    max_examine: usize = 4_000,
};

/// Lift note–note edges onto living **agents**. Skips ends that have no drawn agent (culled).
/// Dedupes unordered pairs. Strides the edge list and caps per-agent degree so the web
/// samples across the whole vault instead of saturating on the first dense component.
pub fn liftEdges(
    tree: Tree,
    edges: []const Edge,
    has_agent: *const fn (ctx: *const anyopaque, node: u32) bool,
    pos_of: *const fn (ctx: *const anyopaque, node: u32) dvui.Point,
    ctx: *const anyopaque,
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(LiftedEdge),
) !void {
    try liftEdgesEx(tree, edges, has_agent, pos_of, ctx, allocator, out, .{});
}

pub fn liftEdgesEx(
    tree: Tree,
    edges: []const Edge,
    has_agent: *const fn (ctx: *const anyopaque, node: u32) bool,
    pos_of: *const fn (ctx: *const anyopaque, node: u32) dvui.Point,
    ctx: *const anyopaque,
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(LiftedEdge),
    opts: LiftOpts,
) !void {
    if (edges.len == 0 or opts.max_edges == 0) return;

    var seen = std.AutoHashMapUnmanaged(u64, void){};
    defer seen.deinit(allocator);
    var degree = std.AutoHashMapUnmanaged(u32, u16){};
    defer degree.deinit(allocator);

    // One strided pass over the vault (not `stride` full rescans — that was O(E)×passes when
    // degree caps rejected most candidates, and ate frames on large graphs).
    const stride = @max(1, edges.len / @max(opts.max_edges * 6, 1));
    var examined: usize = 0;
    var i: usize = 0;
    while (i < edges.len and out.items.len < opts.max_edges and examined < opts.max_examine) : ({
        i += stride;
        examined += 1;
    }) {
        const e = edges[i];
        if (e.a == e.b) continue;
        if (e.a >= tree.note_owner.len or e.b >= tree.note_owner.len) continue;
        const na = livingAgent(tree, e.a, has_agent, ctx) orelse continue;
        const nb = livingAgent(tree, e.b, has_agent, ctx) orelse continue;
        if (na == nb) continue;
        const lo = @min(na, nb);
        const hi = @max(na, nb);
        const key = (@as(u64, lo) << 32) | hi;
        const gop = try seen.getOrPut(allocator, key);
        if (gop.found_existing) continue;

        const da = degree.get(na) orelse 0;
        const db = degree.get(nb) orelse 0;
        if (da >= opts.max_degree or db >= opts.max_degree) continue;

        try degree.put(allocator, na, da + 1);
        try degree.put(allocator, nb, db + 1);
        try out.append(allocator, .{
            .from_node = na,
            .to_node = nb,
            .from = pos_of(ctx, na),
            .to = pos_of(ctx, nb),
        });
    }
}

/// Off-screen sibling marks kept for pan LOD seams on top of the in-view `budget`.
pub fn fringeAllowance(budget: usize) usize {
    return @max(budget / 4, 16);
}

/// Total living-mark ceiling: in-view budget + fringe.
pub fn livingCap(budget: usize) usize {
    return budget + fringeAllowance(budget);
}

/// Default screen-span thresholds for Stable v1 select.
/// Higher split ⇒ coarser overview (far zoom stays masses, not 3k dust at budget).
pub const default_split_px: f32 = 100;
/// Leaf-rung multiplier over mid-cell split/merge. Kept modest so hub/spoke webs appear across
/// a usable zoom band (2.8× made the connection-readable window a thin sliver before close-up).
pub const leaf_open_mult: f32 = 1.6;
/// Merge below split for hysteresis; lower ⇒ leaves stay open further when zooming out.
pub const default_merge_px: f32 = 48;

/// Screen-span threshold sticky uses for a closed node (`selectStickyEx`).
pub fn openThresholdPx(kids_are_leaves: bool) f32 {
    const base = default_split_px;
    return if (kids_are_leaves) base * leaf_open_mult else base;
}

/// Per-node sticky open bits for hysteretic select. Sized to `tree.nodeCount()`.
pub const StickyOpen = struct {
    allocator: std.mem.Allocator,
    open: []bool = &.{},

    pub fn init(allocator: std.mem.Allocator) StickyOpen {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *StickyOpen) void {
        self.allocator.free(self.open);
        self.open = &.{};
    }

    pub fn ensure(self: *StickyOpen, node_count: usize) !void {
        if (self.open.len == node_count) return;
        self.allocator.free(self.open);
        self.open = try self.allocator.alloc(bool, node_count);
        @memset(self.open, false);
    }

    pub fn isOpen(self: StickyOpen, node: u32) bool {
        if (node >= self.open.len) return false;
        return self.open[node];
    }

    pub fn setOpen(self: *StickyOpen, node: u32, value: bool) void {
        if (node >= self.open.len) return;
        self.open[node] = value;
    }
};

/// Budgeted view walk without hysteresis (tests / one-shot). Prefer `selectSticky` for product.
pub fn select(
    tree: Tree,
    view: dvui.Rect,
    zoom: f32,
    split_px: f32,
    budget: usize,
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u32),
) !void {
    var sticky = StickyOpen.init(allocator);
    defer sticky.deinit();
    try sticky.ensure(tree.nodeCount());
    try selectSticky(tree, view, zoom, split_px, split_px, budget, &sticky, allocator, out);
}

/// Stable v1 topology: same (tree, view, zoom, budget, sticky) ⇒ same living cells.
/// Updates `sticky` open bits. Writes living **closed** cell ids into `out`.
///
/// `note_r_px` drives a secondary refine: multi-note cells larger than a few note diameters on
/// Sticky hysteresis between `split_px` / `merge_px`. Leaf rung uses `leaf_open_mult`.
pub fn selectSticky(
    tree: Tree,
    view: dvui.Rect,
    zoom: f32,
    split_px: f32,
    merge_px: f32,
    budget: usize,
    sticky: *StickyOpen,
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u32),
) !void {
    try selectStickyEx(tree, view, zoom, split_px, merge_px, 6, budget, sticky, allocator, out, null);
}

/// Counters filled by `selectStickyEx` when a non-null `stats` pointer is passed — used by the
/// organic-tour harness to explain zoom-out vs zoom-in cost asymmetry.
pub const SelectStats = struct {
    levels: u32 = 0,
    visited: u32 = 0,
    opens_wanted: u32 = 0,
    trim_iters: u32 = 0,
    out_len: u32 = 0,
    /// Sticky bits cleared by `pruneStickyBelowSpan` before the BFS.
    sticky_pruned: u32 = 0,
};

/// Clear sticky-open bits whose screen span is ≤ `span_limit_px` (× `leaf_open_mult` on the
/// leaf/bundle rung — same rule the select walk uses).
///
/// On zoom-out the sticky set is still deep from the dive; leaving those bits set makes the
/// level-uniform BFS treat mid-level cells as `was_open` (merge threshold) and descend much
/// further than the camera warrants — the measured in/out select asymmetry. Pre-clearing
/// collapses that set in one O(nodes) pass before the walk. Cross-isle glue is left alone
/// (force-open for purity).
///
/// Callers: pass `merge_px` for a gentle always-on prune; pass `split_px` when the camera is
/// zooming out so hysteresis cannot keep a dive alive across a large outward step.
pub fn pruneStickyBelowSpan(
    tree: Tree,
    zoom: f32,
    span_limit_px: f32,
    sticky: *StickyOpen,
) u32 {
    const n = @min(sticky.open.len, tree.nodes.len);
    var pruned: u32 = 0;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        if (!sticky.open[i]) continue;
        const node = tree.nodes[i];
        if (node.cross_isle) continue;
        if (!node.hasChildren()) {
            // Leaves are never "open" in the sticky sense the walk cares about — clear dust.
            sticky.open[i] = false;
            pruned += 1;
            continue;
        }
        var kids_are_leaves = true;
        var kn: usize = 0;
        for (node.children) |c| {
            if (c == no_child) continue;
            kn += 1;
            if (tree.nodes[c].hasChildren()) kids_are_leaves = false;
        }
        if (kn == 0) {
            sticky.open[i] = false;
            pruned += 1;
            continue;
        }
        const bundle = node.count <= bundle_max;
        const thresh = if (kids_are_leaves or bundle) span_limit_px * leaf_open_mult else span_limit_px;
        const span = if (bundle) node.massSpan(zoom) else node.screenSpan(zoom);
        if (span <= thresh) {
            sticky.open[i] = false;
            pruned += 1;
        }
    }
    return pruned;
}

/// Gentle always-on prune — bits hysteresis would close at `merge_px` anyway.
pub fn pruneStickyBelowMerge(tree: Tree, zoom: f32, merge_px: f32, sticky: *StickyOpen) u32 {
    return pruneStickyBelowSpan(tree, zoom, merge_px, sticky);
}

const LevelOpen = struct {
    node: u32,
};

pub fn selectStickyEx(
    tree: Tree,
    view: dvui.Rect,
    zoom: f32,
    split_px: f32,
    merge_px: f32,
    note_r_px: f32,
    budget: usize,
    sticky: *StickyOpen,
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u32),
    stats: ?*SelectStats,
) !void {
    _ = note_r_px; // reserved for a future refine heuristic; force-refine thrashed overview.
    out.clearRetainingCapacity();
    if (stats) |s| s.* = .{};
    if (tree.nodes.len == 0) return;
    try sticky.ensure(tree.nodeCount());

    // Collapse sticky bits the walk would close anyway — see `pruneStickyBelowSpan`.
    const pruned = pruneStickyBelowSpan(tree, zoom, merge_px, sticky);
    if (stats) |s| s.sticky_pruned = pruned;

    // Level-uniform BFS: at each depth, open *all* want_open nodes or *none*.
    // Per-node budget checks refined SW/upper (lowest ids, built first) and left the opposite
    // hemisphere as one fat mass — even on even point distributions.
    var q: std.ArrayListUnmanaged(u32) = .empty;
    defer q.deinit(allocator);
    try q.append(allocator, tree.root);

    var opens: std.ArrayListUnmanaged(LevelOpen) = .empty;
    defer opens.deinit(allocator);
    var emits: std.ArrayListUnmanaged(u32) = .empty;
    defer emits.deinit(allocator);

    var head: usize = 0;
    while (head < q.items.len) {
        const level_end = q.items.len;
        opens.clearRetainingCapacity();
        emits.clearRetainingCapacity();
        if (stats) |s| s.levels += 1;

        var i = head;
        while (i < level_end) : (i += 1) {
            const ni = q.items[i];
            const n = tree.nodes[ni];
            if (stats) |s| s.visited += 1;
            // Root / entry cull: ignore subtrees that never touched the view. Nodes already in
            // `q` were enqueued because an in-view parent opened — keep them as closed marks
            // even when they sit off-screen, so sibling LOD stays uniform under pan/resize.
            if (!n.overlaps(view)) {
                if (ni == tree.root) continue;
                sticky.setOpen(ni, false);
                try emits.append(allocator, ni);
                continue;
            }

            if (!n.hasChildren()) {
                sticky.setOpen(ni, false);
                try emits.append(allocator, ni);
                continue;
            }

            var kids_buf: [4]u32 = undefined;
            var kn: usize = 0;
            var kids_are_leaves = true;
            for (n.children) |c| {
                if (c == no_child) continue;
                kids_buf[kn] = c;
                kn += 1;
                if (tree.nodes[c].hasChildren()) kids_are_leaves = false;
            }
            if (kn == 0) {
                sticky.setOpen(ni, false);
                try emits.append(allocator, ni);
                continue;
            }

            const was_open = sticky.isOpen(ni);
            const base_thresh = if (was_open) merge_px else split_px;
            // Bundles (small isles) stay closed until the leaf rung — avoids sticky stops on
            // 2-note geometric shards inside a 5–10 note linked component.
            const bundle = n.count <= bundle_max;
            const thresh = if (kids_are_leaves or bundle) base_thresh * leaf_open_mult else base_thresh;
            // Cross-isle glue must never stick closed — it would draw a mixed-island mass.
            // Bundles open on massSpan (visual size); large cells still use bbox screenSpan.
            const span = if (bundle) n.massSpan(zoom) else n.screenSpan(zoom);
            const want_open = n.cross_isle or span > thresh;

            if (want_open) {
                try opens.append(allocator, .{ .node = ni });
            } else {
                sticky.setOpen(ni, false);
                try emits.append(allocator, ni);
            }
        }
        head = level_end;
        if (stats) |s| s.opens_wanted += @intCast(opens.items.len);

        // Budget the **in-view** set. Off-screen siblings stay in `out` for pan LOD seams, but must
        // not freeze the focused region at one fat mass (full-vault failure mode).
        const base_iv = countOverlapping(tree, out.items, view);
        const emit_iv = countOverlapping(tree, emits.items, view);

        // Resolve open targets (bundle parents expand straight to leaves).
        var targets: std.ArrayListUnmanaged(u32) = .empty;
        defer targets.deinit(allocator);
        var target_ranges: std.ArrayListUnmanaged(struct { start: u32, len: u32 }) = .empty;
        defer target_ranges.deinit(allocator);
        try target_ranges.ensureTotalCapacity(allocator, opens.items.len);
        for (opens.items) |o| {
            const start: u32 = @intCast(targets.items.len);
            // Cascade only inside a pure link-bundle. Cross-isle glue with a small total count
            // must still stop at isle roots — cascading there skipped pure masses into leaves.
            const cascade = !tree.nodes[o.node].cross_isle and tree.nodes[o.node].count <= bundle_max;
            // Dry collect — only mark thin nodes open when the parent actually opens below.
            try collectOpenTargets(tree, o.node, null, allocator, &targets, cascade);
            target_ranges.appendAssumeCapacity(.{ .start = start, .len = @intCast(targets.items.len - start) });
        }

        var forced_kids_iv: usize = 0;
        var optional_n: usize = 0;
        for (opens.items, target_ranges.items) |o, tr| {
            const slice = targets.items[tr.start .. tr.start + tr.len];
            if (tree.nodes[o.node].cross_isle) {
                forced_kids_iv += countKidsOverlapping(tree, slice, view);
            } else {
                optional_n += 1;
            }
        }

        // Keep a fringe of off-screen siblings for pan LOD seams, but do not let far-away
        // component dust fill the living set before in-view refine runs.
        const max_fringe = fringeAllowance(budget);
        var off_kept: usize = 0;
        for (out.items) |nid| {
            if (!tree.nodes[nid].overlaps(view)) off_kept += 1;
        }
        for (emits.items) |ni| {
            const on = tree.nodes[ni].overlaps(view);
            if (!on and off_kept >= max_fringe) continue;
            try out.append(allocator, ni);
            if (!on) off_kept += 1;
        }

        // Cross-isle glue in view always expands (purity). Optional: open all if they fit, else
        // greedily open largest spans so a focused cluster can refine under global pressure.
        const after_forced_iv = base_iv + emit_iv + forced_kids_iv;
        var optional_kids_iv: usize = 0;
        for (opens.items, target_ranges.items) |o, tr| {
            if (tree.nodes[o.node].cross_isle) continue;
            const slice = targets.items[tr.start .. tr.start + tr.len];
            optional_kids_iv += countKidsOverlapping(tree, slice, view);
        }
        const can_open_all_optional = optional_n > 0 and after_forced_iv + optional_kids_iv <= budget;

        // Stable order: forced first (as stored), then optional by descending screen span.
        var order = try allocator.alloc(u32, opens.items.len);
        defer allocator.free(order);
        for (opens.items, 0..) |_, oi| order[oi] = @intCast(oi);
        const SortCtx = struct { tree: Tree, opens: []const LevelOpen, zoom: f32 };
        std.mem.sort(u32, order, SortCtx{ .tree = tree, .opens = opens.items, .zoom = zoom }, struct {
            fn less(ctx: SortCtx, a: u32, b: u32) bool {
                const na = ctx.opens[a].node;
                const nb = ctx.opens[b].node;
                const fa = ctx.tree.nodes[na].cross_isle;
                const fb = ctx.tree.nodes[nb].cross_isle;
                if (fa != fb) return fa and !fb; // forced first
                return ctx.tree.nodes[na].screenSpan(ctx.zoom) > ctx.tree.nodes[nb].screenSpan(ctx.zoom);
            }
        }.less);

        var iv = after_forced_iv;
        for (order) |oi| {
            const o = opens.items[oi];
            const tr = target_ranges.items[oi];
            const slice = targets.items[tr.start .. tr.start + tr.len];
            const force = tree.nodes[o.node].cross_isle;
            const cascade = !force and tree.nodes[o.node].count <= bundle_max;
            if (force or can_open_all_optional) {
                sticky.setOpen(o.node, true);
                try collectOpenTargets(tree, o.node, sticky, allocator, &q, cascade);
                continue;
            }
            const kid_iv = countKidsOverlapping(tree, slice, view);
            if (kid_iv > 0 and iv + kid_iv <= budget) {
                sticky.setOpen(o.node, true);
                try collectOpenTargets(tree, o.node, sticky, allocator, &q, cascade);
                iv += kid_iv;
            } else {
                sticky.setOpen(o.node, false);
                try out.append(allocator, o.node);
                if (tree.nodes[o.node].overlaps(view)) iv += 1;
            }
        }
    }

    const trim_iters = try trimByMergingUp(tree, sticky, budget, allocator, out, view);
    if (stats) |s| {
        s.trim_iters = @intCast(trim_iters);
        s.out_len = @intCast(out.items.len);
    }
}

/// Children to enqueue when opening `node`. For small link-bundles (`cascade`), skip thin
/// internals so a 5–10 note isle becomes leaves in one sticky step.
fn collectOpenTargets(
    tree: Tree,
    node: u32,
    sticky: ?*StickyOpen,
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u32),
    cascade: bool,
) !void {
    for (tree.nodes[node].children) |c| {
        if (c == no_child) continue;
        const ch = tree.nodes[c];
        if (cascade and !ch.cross_isle and ch.hasChildren() and ch.count <= bundle_max) {
            if (sticky) |s| s.setOpen(c, true);
            try collectOpenTargets(tree, c, sticky, allocator, out, cascade);
        } else {
            try out.append(allocator, c);
        }
    }
}

fn countOverlapping(tree: Tree, ids: []const u32, view: dvui.Rect) usize {
    var n: usize = 0;
    for (ids) |id| {
        if (tree.nodes[id].overlaps(view)) n += 1;
    }
    return n;
}

fn countKidsOverlapping(tree: Tree, kids: []const u32, view: dvui.Rect) usize {
    var n: usize = 0;
    for (kids) |c| {
        if (tree.nodes[c].overlaps(view)) n += 1;
    }
    return n;
}

fn nodeIsUnder(tree: Tree, node: u32, ancestor: u32) bool {
    var cur = node;
    var guard: usize = 0;
    while (guard < max_depth + 2) : (guard += 1) {
        if (cur == ancestor) return true;
        cur = tree.parentOf(cur) orelse return false;
    }
    return false;
}

/// Safety net if the walk ever overshoots. With a strict walk budget this rarely runs;
/// kept so notes coalesce instead of vanishing if it does.
///
/// Caps **in-view** marks at `budget`, and keeps up to `budget/4` off-screen fringe marks for
/// pan LOD seams (so focus refine is not starved, and siblings do not vanish on clip).
fn trimByMergingUp(
    tree: Tree,
    sticky: *StickyOpen,
    budget: usize,
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u32),
    view: dvui.Rect,
) !usize {
    if (budget == 0) {
        out.clearRetainingCapacity();
        return 0;
    }
    const max_fringe = fringeAllowance(budget);

    var under_counts: std.AutoHashMapUnmanaged(u32, u16) = .empty;
    defer under_counts.deinit(allocator);

    // Many-component vaults (50k+ orphans) need one merge per coalesced pair — allow O(living).
    const max_iters = @max(out.items.len * 2 + 8, tree.nodeCount() + 8);
    var guard: usize = 0;
    while (guard < max_iters) : (guard += 1) {
        const iv = countOverlapping(tree, out.items, view);
        const off = out.items.len - iv;
        if (iv <= budget and off <= max_fringe) return guard;

        // Excess fringe first — never steal in-view mid-levels to keep far dust.
        if (off > max_fringe) {
            if (dropSmallest(out, tree, true, view)) continue;
        }

        under_counts.clearRetainingCapacity();
        for (out.items) |nid| {
            var cur = tree.parentOf(nid) orelse continue;
            var climb: usize = 0;
            while (climb < max_depth + 2) : (climb += 1) {
                if (sticky.isOpen(cur)) {
                    const gop = try under_counts.getOrPut(allocator, cur);
                    if (!gop.found_existing) gop.value_ptr.* = 0;
                    gop.value_ptr.* +|= 1;
                }
                cur = tree.parentOf(cur) orelse break;
            }
        }

        // Prefer pure merges; under budget pressure allow cross-isle glue (far overview of
        // thousands of components cannot stay one-agent-per-isle inside the mark budget).
        const parent = findMergeParent(tree, under_counts, out.items, view, false) orelse
            findMergeParent(tree, under_counts, out.items, view, true);

        if (parent) |p| {
            var i: usize = 0;
            while (i < out.items.len) {
                if (nodeIsUnder(tree, out.items[i], p)) {
                    _ = out.swapRemove(i);
                } else {
                    i += 1;
                }
            }
            sticky.setOpen(p, false);
            try out.append(allocator, p);
        } else if (iv > budget) {
            // Last resort: close the open sticky ancestor covering the most living marks.
            if (try forceMergeLargest(tree, sticky, allocator, out, &under_counts)) continue;
            if (!dropSmallest(out, tree, false, view)) break;
        } else if (!dropSmallest(out, tree, true, view)) {
            break;
        }
    }
    return guard;
}

/// When pairwise merge scoring finds nothing, collapse the open parent that covers the most
/// living agents (including cross-isle glue). Needed for orphan-heavy synth vaults.
fn forceMergeLargest(
    tree: Tree,
    sticky: *StickyOpen,
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u32),
    under_counts: *const std.AutoHashMapUnmanaged(u32, u16),
) !bool {
    var best: ?u32 = null;
    var best_n: u16 = 0;
    var it = under_counts.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.* < 2) continue;
        if (e.value_ptr.* > best_n or (e.value_ptr.* == best_n and (best == null or e.key_ptr.* < best.?))) {
            best_n = e.value_ptr.*;
            best = e.key_ptr.*;
        }
    }
    const p = best orelse return false;
    var i: usize = 0;
    while (i < out.items.len) {
        if (nodeIsUnder(tree, out.items[i], p)) {
            _ = out.swapRemove(i);
        } else {
            i += 1;
        }
    }
    sticky.setOpen(p, false);
    try out.append(allocator, p);
    return true;
}

fn dropSmallest(
    out: *std.ArrayListUnmanaged(u32),
    tree: Tree,
    off_screen_only: bool,
    view: dvui.Rect,
) bool {
    var drop_i: ?usize = null;
    var drop_count: u32 = std.math.maxInt(u32);
    var drop_id: u32 = std.math.maxInt(u32);
    for (out.items, 0..) |nid, i| {
        if (off_screen_only and tree.nodes[nid].overlaps(view)) continue;
        const c = tree.nodes[nid].count;
        if (c < drop_count or (c == drop_count and nid < drop_id)) {
            drop_count = c;
            drop_id = nid;
            drop_i = i;
        }
    }
    const i = drop_i orelse return false;
    _ = out.swapRemove(i);
    return true;
}

fn findMergeParent(
    tree: Tree,
    under_counts: std.AutoHashMapUnmanaged(u32, u16),
    living: []const u32,
    view: dvui.Rect,
    allow_cross_isle: bool,
) ?u32 {
    var best: ?u32 = null;
    var best_score: i32 = std.math.minInt(i32);
    var it = under_counts.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.* < 2) continue;
        if (!allow_cross_isle and tree.nodes[e.key_ptr.*].cross_isle) continue;
        // Score: prefer deeper parents whose living children are off-screen.
        var off: i32 = 0;
        var on: i32 = 0;
        for (living) |nid| {
            if (!nodeIsUnder(tree, nid, e.key_ptr.*)) continue;
            if (tree.nodes[nid].overlaps(view)) on += 1 else off += 1;
        }
        const d: i32 = @intCast(tree.nodes[e.key_ptr.*].depth);
        // Prefer collapsing off-screen fringe first; when everything is in view (full overview
        // of many components), prefer parents that absorb the most living marks per step.
        const score = if (on + off > 0 and off == 0)
            @as(i32, e.value_ptr.*) * 1000 + d
        else
            off * 1000 - on * 100 + d;
        if (score > best_score or (score == best_score and (best == null or e.key_ptr.* < best.?))) {
            best = e.key_ptr.*;
            best_score = score;
        }
    }
    return best;
}

// --- tests -----------------------------------------------------------------

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

test "quadtree mass sums to N" {
    const pts = try gridPositions(testing.allocator, 8, 10);
    defer testing.allocator.free(pts);
    var tree = try build(testing.allocator, pts);
    defer tree.deinit();
    try testing.expect(tree.nodes.len > 0);
    try testing.expectEqual(@as(u32, @intCast(pts.len)), tree.get(tree.root).count);
    var leaf_notes: usize = 0;
    for (tree.nodes) |n| {
        if (n.isLeaf()) leaf_notes += n.count;
    }
    try testing.expectEqual(pts.len, leaf_notes);
}

test "empty quadrants are omitted" {
    // Collinear points → north or south half of many cells stays empty.
    const pts = [_]dvui.Point{
        .{ .x = 0, .y = 0 },
        .{ .x = 1, .y = 0 },
        .{ .x = 2, .y = 0 },
        .{ .x = 3, .y = 0 },
    };
    var tree = try build(testing.allocator, &pts);
    defer tree.deinit();
    var saw_empty = false;
    for (tree.nodes) |n| {
        if (!n.hasChildren()) continue;
        for (n.children) |c| {
            if (c == no_child) saw_empty = true;
        }
    }
    try testing.expect(saw_empty);
}

test "select respects budget" {
    const pts = try gridPositions(testing.allocator, 16, 5);
    defer testing.allocator.free(pts);
    var tree = try build(testing.allocator, pts);
    defer tree.deinit();

    const root = tree.get(tree.root);
    const view = dvui.Rect{
        .x = root.min_x - 1,
        .y = root.min_y - 1,
        .w = root.max_x - root.min_x + 2,
        .h = root.max_y - root.min_y + 2,
    };
    var out: std.ArrayListUnmanaged(u32) = .empty;
    defer out.deinit(testing.allocator);
    try select(tree, view, 100, 8, 7, testing.allocator, &out);
    try testing.expect(out.items.len <= 7);
    try testing.expect(out.items.len > 0);
}

test "select refines when zoomed in" {
    const pts = try gridPositions(testing.allocator, 8, 10);
    defer testing.allocator.free(pts);
    var tree = try build(testing.allocator, pts);
    defer tree.deinit();
    const root = tree.get(tree.root);
    const view = dvui.Rect{
        .x = root.min_x - 1,
        .y = root.min_y - 1,
        .w = root.max_x - root.min_x + 2,
        .h = root.max_y - root.min_y + 2,
    };
    var coarse: std.ArrayListUnmanaged(u32) = .empty;
    defer coarse.deinit(testing.allocator);
    var fine: std.ArrayListUnmanaged(u32) = .empty;
    defer fine.deinit(testing.allocator);
    try select(tree, view, 0.5, 40, 1000, testing.allocator, &coarse);
    try select(tree, view, 20, 40, 1000, testing.allocator, &fine);
    try testing.expect(fine.items.len >= coarse.items.len);
}

test "note_owner points at leaf containing the note" {
    const pts = try gridPositions(testing.allocator, 4, 3);
    defer testing.allocator.free(pts);
    var tree = try build(testing.allocator, pts);
    defer tree.deinit();
    for (pts, 0..) |p, i| {
        const owner = tree.note_owner[i];
        const n = tree.get(owner);
        try testing.expect(n.isLeaf());
        try testing.expect(n.count >= 1);
        try testing.expect(p.x >= n.min_x and p.x <= n.max_x);
        try testing.expect(p.y >= n.min_y and p.y <= n.max_y);
    }
}

test "small linked isle stays one mass until leaf rung" {
    // 6-note ring (typical gauntlet isle size). Mid-band zoom must not show pair-masses.
    var pts: [6]dvui.Point = undefined;
    var edges: [6]Edge = undefined;
    for (0..6) |i| {
        const a = @as(f32, @floatFromInt(i)) * (std.math.tau / 6.0);
        pts[i] = .{ .x = @cos(a) * 4, .y = @sin(a) * 4 };
        edges[i] = .{ .a = @intCast(i), .b = @intCast((i + 1) % 6) };
    }
    var tree = try buildEx(testing.allocator, &pts, &edges);
    defer tree.deinit();
    const root = tree.get(tree.root);
    const view = dvui.Rect{
        .x = root.min_x - 1,
        .y = root.min_y - 1,
        .w = root.max_x - root.min_x + 2,
        .h = root.max_y - root.min_y + 2,
    };
    // Just below massSpan leaf-rung: closed as one mass.
    const z_leaf = (openThresholdPx(true) * 1.001) / (@max(root.drawRadius(), 1e-6) * 2);
    var sticky = StickyOpen.init(testing.allocator);
    defer sticky.deinit();
    var out: std.ArrayListUnmanaged(u32) = .empty;
    defer out.deinit(testing.allocator);
    try selectSticky(tree, view, z_leaf * 0.85, default_split_px, default_merge_px, 80, &sticky, testing.allocator, &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expectEqual(@as(u32, 6), tree.get(out.items[0]).count);

    // Past leaf rung: individuals (bundle cascade), not a handful of pair-masses.
    try selectSticky(tree, view, z_leaf * 1.25, default_split_px, default_merge_px, 80, &sticky, testing.allocator, &out);
    var max_c: u32 = 0;
    for (out.items) |nid| max_c = @max(max_c, tree.get(nid).count);
    try testing.expect(max_c <= 1);
    try testing.expect(out.items.len >= 4);
}

test "pruneStickyBelowSpan clears deep sticky on zoom-out" {
    // Dive opens a deep sticky set; at overview zoom those mid-level bits sit well below
    // merge_px and must be cleared so the next select doesn't re-descend the whole dive.
    const pts = try gridPositions(testing.allocator, 12, 6);
    defer testing.allocator.free(pts);
    var tree = try build(testing.allocator, pts);
    defer tree.deinit();
    const root = tree.get(tree.root);
    const view = dvui.Rect{
        .x = root.min_x - 1,
        .y = root.min_y - 1,
        .w = root.max_x - root.min_x + 2,
        .h = root.max_y - root.min_y + 2,
    };
    var sticky = StickyOpen.init(testing.allocator);
    defer sticky.deinit();
    var out: std.ArrayListUnmanaged(u32) = .empty;
    defer out.deinit(testing.allocator);

    try selectSticky(tree, view, 40, default_split_px, default_merge_px, 200, &sticky, testing.allocator, &out);
    var open_close: u32 = 0;
    for (sticky.open) |o| {
        if (o) open_close += 1;
    }
    try testing.expect(open_close > 8);

    const pruned = pruneStickyBelowSpan(tree, 0.5, default_merge_px, &sticky);
    try testing.expect(pruned > 0);
    var open_far: u32 = 0;
    for (sticky.open) |o| {
        if (o) open_far += 1;
    }
    try testing.expect(open_far < open_close);
    // Survivors (if any) must still clear the merge threshold at this zoom.
    for (sticky.open, 0..) |o, i| {
        if (!o) continue;
        const n = tree.nodes[i];
        if (n.cross_isle) continue;
        const bundle = n.count <= bundle_max;
        const span = if (bundle) n.massSpan(0.5) else n.screenSpan(0.5);
        try testing.expect(span > default_merge_px);
    }
}

test "zoom-out prune at split_px matches cold select depth" {
    // The in/out asymmetry: sticky from a close dive kept mid-levels on the merge threshold
    // so an outward step visited far more nodes than a cold select at the same zoom. Pruning
    // at split_px before the outward select must bring visited counts in line.
    const pts = try gridPositions(testing.allocator, 16, 5);
    defer testing.allocator.free(pts);
    var tree = try build(testing.allocator, pts);
    defer tree.deinit();
    const root = tree.get(tree.root);
    const view = dvui.Rect{
        .x = root.min_x - 1,
        .y = root.min_y - 1,
        .w = root.max_x - root.min_x + 2,
        .h = root.max_y - root.min_y + 2,
    };

    var cold_sticky = StickyOpen.init(testing.allocator);
    defer cold_sticky.deinit();
    var cold_out: std.ArrayListUnmanaged(u32) = .empty;
    defer cold_out.deinit(testing.allocator);
    var cold_stats: SelectStats = .{};
    try selectStickyEx(tree, view, 8, default_split_px, default_merge_px, 6, 200, &cold_sticky, testing.allocator, &cold_out, &cold_stats);

    var hot_sticky = StickyOpen.init(testing.allocator);
    defer hot_sticky.deinit();
    var hot_out: std.ArrayListUnmanaged(u32) = .empty;
    defer hot_out.deinit(testing.allocator);
    // Dive first.
    try selectSticky(tree, view, 60, default_split_px, default_merge_px, 200, &hot_sticky, testing.allocator, &hot_out);
    _ = pruneStickyBelowSpan(tree, 8, default_split_px, &hot_sticky);
    var hot_stats: SelectStats = .{};
    try selectStickyEx(tree, view, 8, default_split_px, default_merge_px, 6, 200, &hot_sticky, testing.allocator, &hot_out, &hot_stats);

    // Visited should be within a small factor of a cold select — not the 2–10× blowup seen
    // when dive sticky was left intact.
    try testing.expect(hot_stats.visited <= cold_stats.visited + cold_stats.visited / 2 + 8);
    try testing.expectEqual(cold_out.items.len, hot_out.items.len);
}

test "in-view cluster refines under many far components" {
    // Full-vault shape: hundreds of far singletons + one tight pack. Focusing the pack must
    // still open mid-levels — off-screen orphans must not spend the whole mark budget.
    const pack_n: usize = 64;
    const far_n: usize = 400;
    var pts = try testing.allocator.alloc(dvui.Point, pack_n + far_n);
    defer testing.allocator.free(pts);
    var edges: std.ArrayListUnmanaged(Edge) = .empty;
    defer edges.deinit(testing.allocator);
    for (0..pack_n) |i| {
        const r: f32 = @floatFromInt(i / 8);
        const c: f32 = @floatFromInt(i % 8);
        pts[i] = .{ .x = c * 2, .y = r * 2 };
        if (i + 1 < pack_n) try edges.append(testing.allocator, .{ .a = @intCast(i), .b = @intCast(i + 1) });
    }
    for (0..far_n) |i| {
        pts[pack_n + i] = .{ .x = 500 + @as(f32, @floatFromInt(i)) * 3, .y = 500 };
    }
    var tree = try buildEx(testing.allocator, pts, edges.items);
    defer tree.deinit();

    // Frame just the pack.
    var min_x: f32 = std.math.floatMax(f32);
    var min_y: f32 = std.math.floatMax(f32);
    var max_x: f32 = -std.math.floatMax(f32);
    var max_y: f32 = -std.math.floatMax(f32);
    for (pts[0..pack_n]) |p| {
        min_x = @min(min_x, p.x);
        min_y = @min(min_y, p.y);
        max_x = @max(max_x, p.x);
        max_y = @max(max_y, p.y);
    }
    const view = dvui.Rect{
        .x = min_x - 2,
        .y = min_y - 2,
        .w = max_x - min_x + 4,
        .h = max_y - min_y + 4,
    };
    const budget: usize = 80;
    var sticky = StickyOpen.init(testing.allocator);
    defer sticky.deinit();
    var out: std.ArrayListUnmanaged(u32) = .empty;
    defer out.deinit(testing.allocator);
    // Zoom high enough that pack cells want to open.
    try selectSticky(tree, view, 40, default_split_px, default_merge_px, budget, &sticky, testing.allocator, &out);

    var in_pack: usize = 0;
    var max_in_view: u32 = 0;
    for (out.items) |nid| {
        if (!tree.nodes[nid].overlaps(view)) continue;
        in_pack += 1;
        max_in_view = @max(max_in_view, tree.nodes[nid].count);
    }
    try testing.expect(in_pack >= 4);
    // Must not be a single fat mass over the whole pack.
    try testing.expect(max_in_view < pack_n);
}

test "open parent keeps off-screen siblings in the living set" {
    // Clipping a cluster must not drop the off-screen half of an opened parent — that was the
    // pan/resize LOD seam (visible half refined; hidden siblings absent; pan mixed both).
    const pts = try gridPositions(testing.allocator, 16, 5);
    defer testing.allocator.free(pts);
    var tree = try build(testing.allocator, pts);
    defer tree.deinit();
    const root = tree.get(tree.root);
    const full_h = root.max_y - root.min_y + 2;
    const half = dvui.Rect{
        .x = root.min_x - 1,
        .y = root.min_y - 1,
        .w = root.max_x - root.min_x + 2,
        .h = full_h * 0.45,
    };
    var sticky = StickyOpen.init(testing.allocator);
    defer sticky.deinit();
    var out: std.ArrayListUnmanaged(u32) = .empty;
    defer out.deinit(testing.allocator);
    try selectSticky(tree, half, 20, default_split_px, default_merge_px, 80, &sticky, testing.allocator, &out);

    var offscreen_living: usize = 0;
    for (out.items) |nid| {
        if (!tree.nodes[nid].overlaps(half)) offscreen_living += 1;
    }
    try testing.expect(offscreen_living > 0);
}

test "selectSticky is idempotent at a parked camera" {
    const pts = try gridPositions(testing.allocator, 12, 6);
    defer testing.allocator.free(pts);
    var tree = try build(testing.allocator, pts);
    defer tree.deinit();
    const root = tree.get(tree.root);
    const view = dvui.Rect{
        .x = root.min_x - 1,
        .y = root.min_y - 1,
        .w = root.max_x - root.min_x + 2,
        .h = root.max_y - root.min_y + 2,
    };
    var sticky = StickyOpen.init(testing.allocator);
    defer sticky.deinit();
    var a: std.ArrayListUnmanaged(u32) = .empty;
    defer a.deinit(testing.allocator);
    var b: std.ArrayListUnmanaged(u32) = .empty;
    defer b.deinit(testing.allocator);
    const zoom: f32 = 4;
    try selectSticky(tree, view, zoom, default_split_px, default_merge_px, 80, &sticky, testing.allocator, &a);
    try selectSticky(tree, view, zoom, default_split_px, default_merge_px, 80, &sticky, testing.allocator, &b);
    try testing.expectEqual(a.items.len, b.items.len);
    for (a.items, b.items) |x, y| try testing.expectEqual(x, y);
}

test "livingAgent climbs to a drawn cell not sticky-open ghosts" {
    const pts = try gridPositions(testing.allocator, 4, 8);
    defer testing.allocator.free(pts);
    var tree = try build(testing.allocator, pts);
    defer tree.deinit();
    // Only root is a "drawn agent".
    const Ctx = struct {
        root: u32,
        fn has(ctx: *const anyopaque, node: u32) bool {
            const c: *const @This() = @ptrCast(@alignCast(ctx));
            return node == c.root;
        }
    };
    var ctx = Ctx{ .root = tree.root };
    const living = livingAgent(tree, 0, Ctx.has, &ctx) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(tree.root, living);
}

test "budget trim merges up — every note still has a living agent" {
    const pts = try gridPositions(testing.allocator, 16, 5);
    defer testing.allocator.free(pts);
    var tree = try build(testing.allocator, pts);
    defer tree.deinit();
    const root = tree.get(tree.root);
    const view = dvui.Rect{
        .x = root.min_x - 1,
        .y = root.min_y - 1,
        .w = root.max_x - root.min_x + 2,
        .h = root.max_y - root.min_y + 2,
    };
    var sticky = StickyOpen.init(testing.allocator);
    defer sticky.deinit();
    var out: std.ArrayListUnmanaged(u32) = .empty;
    defer out.deinit(testing.allocator);
    // Dive deep then clamp hard — must coalesce, not drop notes.
    try selectSticky(tree, view, 80, 8, 4, 12, &sticky, testing.allocator, &out);
    try testing.expect(out.items.len <= 12);
    try testing.expect(out.items.len > 0);

    const Ctx = struct {
        living: []const u32,
        fn has(ctx: *const anyopaque, node: u32) bool {
            const c: *const @This() = @ptrCast(@alignCast(ctx));
            for (c.living) |n| if (n == node) return true;
            return false;
        }
    };
    var ctx = Ctx{ .living = out.items };
    for (0..pts.len) |note| {
        const agent = livingAgent(tree, @intCast(note), Ctx.has, &ctx);
        try testing.expect(agent != null);
    }
}

test "living frontier depths stay level-uniform under budget" {
    const pts = try gridPositions(testing.allocator, 12, 6);
    defer testing.allocator.free(pts);
    var tree = try build(testing.allocator, pts);
    defer tree.deinit();
    const root = tree.get(tree.root);
    const view = dvui.Rect{
        .x = root.min_x - 1,
        .y = root.min_y - 1,
        .w = root.max_x - root.min_x + 2,
        .h = root.max_y - root.min_y + 2,
    };
    var sticky = StickyOpen.init(testing.allocator);
    defer sticky.deinit();
    var out: std.ArrayListUnmanaged(u32) = .empty;
    defer out.deinit(testing.allocator);
    try selectSticky(tree, view, 6.0, default_split_px, default_merge_px, 48, &sticky, testing.allocator, &out);

    // All-or-nothing levels ⇒ living marks occupy at most two consecutive depths
    // (frontier + an occasional leaf rung), never "top fine / bottom coarse".
    var min_d: i32 = std.math.maxInt(i32);
    var max_d: i32 = std.math.minInt(i32);
    for (out.items) |lid| {
        const d: i32 = @intCast(tree.nodes[lid].depth);
        min_d = @min(min_d, d);
        max_d = @max(max_d, d);
    }
    try testing.expect(out.items.len > 0);
    try testing.expect((max_d - min_d) <= 1);
}

test "selectSticky respects budget" {
    const pts = try gridPositions(testing.allocator, 16, 5);
    defer testing.allocator.free(pts);
    var tree = try build(testing.allocator, pts);
    defer tree.deinit();
    const root = tree.get(tree.root);
    const view = dvui.Rect{
        .x = root.min_x - 1,
        .y = root.min_y - 1,
        .w = root.max_x - root.min_x + 2,
        .h = root.max_y - root.min_y + 2,
    };
    var sticky = StickyOpen.init(testing.allocator);
    defer sticky.deinit();
    var out: std.ArrayListUnmanaged(u32) = .empty;
    defer out.deinit(testing.allocator);
    try selectSticky(tree, view, 100, 8, 4, 6, &sticky, testing.allocator, &out);
    try testing.expect(out.items.len <= 6);
}

test "zoomToExceedSpan matches selectSticky open line" {
    const pts = try gridPositions(testing.allocator, 8, 4);
    defer testing.allocator.free(pts);
    var tree = try build(testing.allocator, pts);
    defer tree.deinit();
    const root = tree.get(tree.root);
    try testing.expect(root.hasChildren());
    const thresh = openThresholdPx(false);
    const z = root.zoomToExceedSpan(thresh);
    try testing.expect(root.screenSpan(z * 0.99) <= thresh);
    try testing.expect(root.screenSpan(z) > thresh);
}

test "hub pin exposes star edges above leaf rung" {
    // Hub at origin, spokes on a ring — without pinning, mid-split buries the hub until leaves.
    // Degree must clear `hub_pin_degree` (gauntlet isles top out ~10; real hubs are denser).
    const spoke_n: usize = 20;
    var pts: [spoke_n + 1]dvui.Point = undefined;
    pts[0] = .{ .x = 0, .y = 0 };
    var edges: [spoke_n]Edge = undefined;
    for (0..spoke_n) |i| {
        const a = @as(f32, @floatFromInt(i)) * (std.math.tau / @as(f32, @floatFromInt(spoke_n)));
        pts[i + 1] = .{ .x = @cos(a) * 10, .y = @sin(a) * 10 };
        edges[i] = .{ .a = 0, .b = @intCast(i + 1) };
    }
    var tree = try buildEx(testing.allocator, &pts, &edges);
    defer tree.deinit();

    const root = tree.get(tree.root);
    try testing.expect(root.hasChildren());
    // Hub note must be a direct singleton child of some openable ancestor (pinned).
    const hub_leaf = tree.note_owner[0];
    try testing.expectEqual(@as(u32, 1), tree.get(hub_leaf).count);
    const hub_parent = tree.parentOf(hub_leaf) orelse return error.HubOrphan;
    var saw_hub_sibling_mass = false;
    for (tree.get(hub_parent).children) |c| {
        if (c == no_child or c == hub_leaf) continue;
        if (tree.get(c).count > 1) saw_hub_sibling_mass = true;
    }
    try testing.expect(saw_hub_sibling_mass);

    const view = dvui.Rect{
        .x = root.min_x - 1,
        .y = root.min_y - 1,
        .w = root.max_x - root.min_x + 2,
        .h = root.max_y - root.min_y + 2,
    };
    // Past leaf rung so spoke-side children open too (hub is pinned; rest is a ≤12 bundle).
    const z = root.zoomToExceedSpan(openThresholdPx(true));
    var sticky = StickyOpen.init(testing.allocator);
    defer sticky.deinit();
    var out: std.ArrayListUnmanaged(u32) = .empty;
    defer out.deinit(testing.allocator);
    try selectSticky(tree, view, z * 1.2, default_split_px, default_merge_px, 80, &sticky, testing.allocator, &out);

    var hub_living = false;
    for (out.items) |nid| {
        if (tree.singleNote(nid)) |note| {
            if (note == 0) hub_living = true;
        }
    }
    try testing.expect(hub_living);

    const LiftCtx = struct {
        agents: []const u32,
        tree: Tree,
        fn hasAgent(ctx: *const anyopaque, node: u32) bool {
            const c: *const @This() = @ptrCast(@alignCast(ctx));
            for (c.agents) |a| if (a == node) return true;
            return false;
        }
        fn posOf(ctx: *const anyopaque, node: u32) dvui.Point {
            const c: *const @This() = @ptrCast(@alignCast(ctx));
            return c.tree.get(node).centroid;
        }
    };
    var ctx = LiftCtx{ .agents = out.items, .tree = tree };
    var lifted: std.ArrayListUnmanaged(LiftedEdge) = .empty;
    defer lifted.deinit(testing.allocator);
    try liftEdgesEx(tree, &edges, LiftCtx.hasAgent, LiftCtx.posOf, &ctx, testing.allocator, &lifted, .{
        .max_edges = 48,
        .max_degree = 24,
    });
    try testing.expect(lifted.items.len >= 4);
}

test "link components stay pure under sticky masses" {
    // Two packed islands: notes 0..2 and 3..5. Geometric mid-split mixes them; component-first
    // + cross_isle glue must keep every non-glue node (and every sticky agent) CC-pure.
    var pts = [_]dvui.Point{
        .{ .x = 0, .y = 0 },
        .{ .x = 1, .y = 0 },
        .{ .x = 0.5, .y = 1 },
        .{ .x = 10, .y = 10 },
        .{ .x = 11, .y = 10 },
        .{ .x = 10.5, .y = 11 },
    };
    const edges = [_]Edge{
        .{ .a = 0, .b = 1 }, .{ .a = 1, .b = 2 }, .{ .a = 2, .b = 0 },
        .{ .a = 3, .b = 4 }, .{ .a = 4, .b = 5 }, .{ .a = 5, .b = 3 },
    };
    var tree = try buildEx(testing.allocator, &pts, &edges);
    defer tree.deinit();

    const cc = [_]u8{ 0, 0, 0, 1, 1, 1 };
    var saw_glue = false;
    for (tree.nodes, 0..) |n, ni| {
        var seen0 = false;
        var seen1 = false;
        for (tree.note_owner, 0..) |owner, note| {
            if (!isAncestor(tree, @intCast(ni), owner) and owner != ni) continue;
            if (cc[note] == 0) seen0 = true;
            if (cc[note] == 1) seen1 = true;
        }
        if (seen0 and seen1) {
            try testing.expect(n.cross_isle);
            saw_glue = true;
        } else {
            try testing.expect(!n.cross_isle);
        }
    }
    try testing.expect(saw_glue);

    const root = tree.get(tree.root);
    const view = dvui.Rect{
        .x = root.min_x - 1,
        .y = root.min_y - 1,
        .w = root.max_x - root.min_x + 2,
        .h = root.max_y - root.min_y + 2,
    };
    var sticky = StickyOpen.init(testing.allocator);
    defer sticky.deinit();
    var out: std.ArrayListUnmanaged(u32) = .empty;
    defer out.deinit(testing.allocator);
    // Far zoom: glue must open; living agents are the two isle roots — not cascaded leaves.
    // (Small glue totals ≤ bundle_max and used to skip straight through to individuals.)
    try selectSticky(tree, view, 0.01, default_split_px, default_merge_px, 80, &sticky, testing.allocator, &out);
    try testing.expectEqual(@as(usize, 2), out.items.len);
    for (out.items) |nid| {
        try testing.expect(!tree.nodes[nid].cross_isle);
        try testing.expectEqual(@as(u32, 3), tree.nodes[nid].count);
        var seen0 = false;
        var seen1 = false;
        for (tree.note_owner, 0..) |owner, note| {
            if (!isAncestor(tree, nid, owner) and owner != nid) continue;
            if (cc[note] == 0) seen0 = true;
            if (cc[note] == 1) seen1 = true;
        }
        try testing.expect(!(seen0 and seen1));
    }
}

fn isAncestor(tree: Tree, anc: u32, node: u32) bool {
    var cur = node;
    var guard: usize = 0;
    while (guard < max_depth + 4) : (guard += 1) {
        if (cur == anc) return true;
        cur = tree.parentOf(cur) orelse return false;
    }
    return false;
}
