//! Radial "solar system" layout for the graph panel.
//!
//! Pure: `(focus, nodes, edges, prior_angles) → target positions`. Nothing here touches the
//! camera or the DB. Ring-1 neighbours sit on a circle around the focus; ring-2 nodes sit in
//! their parent's angular wedge; phantoms/orphans go on a dimmer outer arc.
//!
//! Angular slots are **stable across relayouts** via `prior_angle`: a surviving note keeps its
//! previous angle, and a brand-new note lands in the largest free gap. Without that, adding one
//! note spins the whole graph.
const std = @import("std");
const dvui = @import("dvui");

pub const ring1_radius: f32 = 180;
pub const ring2_radius: f32 = 300;
pub const orphan_radius: f32 = 380;

pub const Kind = enum { focus, neighbor, second, orphan };

pub const Node = struct {
    note_id: i64,
    kind: Kind,
    /// For ring-2: index into the node slice of the ring-1 parent. Ignored otherwise.
    parent: ?usize = null,
    /// Stable sort key (title) — used when seeding angles for a fresh layout.
    title: []const u8 = "",
    /// Outbound-from-focus first, then inbound, then by degree desc — encoding the plan's
    /// ring-1 sort. Layout itself only uses this for initial angle order.
    sort_key: u32 = 0,
};

pub const PriorAngle = struct {
    note_id: i64,
    angle: f32,
};

/// Write one world-space target per node into `out` (must be `nodes.len` long).
/// `priors` may be empty on the first layout.
pub fn targets(
    nodes: []const Node,
    priors: []const PriorAngle,
    out: []dvui.Point,
) void {
    std.debug.assert(out.len >= nodes.len);
    if (nodes.len == 0) return;

    // Focus at origin.
    for (nodes, 0..) |n, i| {
        if (n.kind == .focus) {
            out[i] = .{};
            break;
        }
    }

    // Ring 1: assign stable angles, then place.
    var ring1_buf: [256]usize = undefined;
    var ring1_n: usize = 0;
    for (nodes, 0..) |n, i| {
        if (n.kind == .neighbor) {
            if (ring1_n < ring1_buf.len) {
                ring1_buf[ring1_n] = i;
                ring1_n += 1;
            }
        }
    }
    const ring1 = ring1_buf[0..ring1_n];
    sortRing1(nodes, ring1);

    var angles: [256]f32 = undefined;
    assignAngles(nodes, ring1, priors, angles[0..ring1_n]);

    for (ring1, 0..) |ni, k| {
        const a = angles[k];
        out[ni] = .{
            .x = @cos(a) * ring1_radius,
            .y = @sin(a) * ring1_radius,
        };
    }

    // Ring 2: place inside the parent's angular wedge.
    for (nodes, 0..) |n, i| {
        if (n.kind != .second) continue;
        const parent = n.parent orelse {
            out[i] = .{ .x = ring2_radius, .y = 0 };
            continue;
        };
        const parent_angle = angleOf(out[parent]);
        // Count siblings sharing this parent to spread them.
        var sib_i: usize = 0;
        var sib_n: usize = 0;
        for (nodes, 0..) |s, si| {
            if (s.kind == .second and s.parent == parent) {
                if (si == i) sib_i = sib_n;
                sib_n += 1;
            }
        }
        const spread: f32 = if (sib_n <= 1) 0 else (@as(f32, @floatFromInt(sib_i)) - @as(f32, @floatFromInt(sib_n - 1)) * 0.5) * (0.35);
        const a = parent_angle + spread;
        out[i] = .{
            .x = @cos(a) * ring2_radius,
            .y = @sin(a) * ring2_radius,
        };
    }

    // Orphans / phantoms on the outer arc, stable by note_id.
    var orphan_buf: [128]usize = undefined;
    var orphan_n: usize = 0;
    for (nodes, 0..) |n, i| {
        if (n.kind == .orphan and orphan_n < orphan_buf.len) {
            orphan_buf[orphan_n] = i;
            orphan_n += 1;
        }
    }
    const orphans = orphan_buf[0..orphan_n];
    std.mem.sort(usize, orphans, nodes, struct {
        fn less(ns: []const Node, a: usize, b: usize) bool {
            return ns[a].note_id < ns[b].note_id;
        }
    }.less);
    for (orphans, 0..) |ni, k| {
        const a = if (orphan_n == 0) @as(f32, 0) else @as(f32, @floatFromInt(k)) / @as(f32, @floatFromInt(orphan_n)) * std.math.tau;
        // Prefer prior angle when we have one.
        const angle = if (findPrior(priors, nodes[ni].note_id)) |p| p else a;
        out[ni] = .{
            .x = @cos(angle) * orphan_radius,
            .y = @sin(angle) * orphan_radius,
        };
    }
}

fn sortRing1(nodes: []const Node, idxs: []usize) void {
    std.mem.sort(usize, idxs, nodes, struct {
        fn less(ns: []const Node, a: usize, b: usize) bool {
            if (ns[a].sort_key != ns[b].sort_key) return ns[a].sort_key < ns[b].sort_key;
            return std.mem.order(u8, ns[a].title, ns[b].title) == .lt;
        }
    }.less);
}

fn assignAngles(
    nodes: []const Node,
    ring1: []const usize,
    priors: []const PriorAngle,
    out_angles: []f32,
) void {
    std.debug.assert(out_angles.len == ring1.len);
    if (ring1.len == 0) return;

    // First pass: reclaim prior angles for survivors.
    var placed: [256]bool = .{false} ** 256;
    for (ring1, 0..) |ni, k| {
        if (findPrior(priors, nodes[ni].note_id)) |a| {
            out_angles[k] = a;
            placed[k] = true;
        }
    }

    // Evenly spaced defaults for anyone without a prior, then push new nodes into largest gaps.
    const step = std.math.tau / @as(f32, @floatFromInt(ring1.len));
    for (ring1, 0..) |_, k| {
        if (placed[k]) continue;
        // Find the largest angular gap among already-placed angles.
        var best_angle = step * @as(f32, @floatFromInt(k));
        if (countPlaced(placed[0..ring1.len]) > 0) {
            best_angle = largestGapAngle(out_angles[0..ring1.len], placed[0..ring1.len]);
        }
        out_angles[k] = best_angle;
        placed[k] = true;
    }
}

fn countPlaced(placed: []const bool) usize {
    var n: usize = 0;
    for (placed) |p| {
        if (p) n += 1;
    }
    return n;
}

fn largestGapAngle(angles: []const f32, placed: []const bool) f32 {
    var buf: [256]f32 = undefined;
    var n: usize = 0;
    for (angles, 0..) |a, i| {
        if (!placed[i]) continue;
        buf[n] = normalizeAngle(a);
        n += 1;
    }
    if (n == 0) return 0;
    std.mem.sort(f32, buf[0..n], {}, std.sort.asc(f32));
    var best_gap: f32 = -1;
    var best_mid: f32 = buf[0] + std.math.pi; // opposite of only point
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const a = buf[i];
        const b = if (i + 1 < n) buf[i + 1] else buf[0] + std.math.tau;
        const gap = b - a;
        if (gap > best_gap) {
            best_gap = gap;
            best_mid = normalizeAngle(a + gap * 0.5);
        }
        
    }
    return best_mid;
}

fn findPrior(priors: []const PriorAngle, note_id: i64) ?f32 {
    for (priors) |p| {
        if (p.note_id == note_id) return p.angle;
    }
    return null;
}

fn angleOf(p: dvui.Point) f32 {
    return std.math.atan2(p.y, p.x);
}

fn normalizeAngle(a: f32) f32 {
    var x = a;
    while (x < 0) x += std.math.tau;
    while (x >= std.math.tau) x -= std.math.tau;
    return x;
}

/// Record prior angles from a previous layout's positions, for the next call.
pub fn capturePriors(nodes: []const Node, positions: []const dvui.Point, out: []PriorAngle) []PriorAngle {
    std.debug.assert(out.len >= nodes.len);
    var n: usize = 0;
    for (nodes, 0..) |node, i| {
        if (node.kind == .focus) continue;
        out[n] = .{ .note_id = node.note_id, .angle = angleOf(positions[i]) };
        n += 1;
    }
    return out[0..n];
}

// -- tests ------------------------------------------------------------------------

const testing = std.testing;

test "focus sits at the origin" {
    const nodes = [_]Node{
        .{ .note_id = 1, .kind = .focus, .title = "A" },
        .{ .note_id = 2, .kind = .neighbor, .title = "B", .sort_key = 0 },
    };
    var out: [2]dvui.Point = undefined;
    targets(&nodes, &.{}, &out);
    try testing.expectEqual(@as(f32, 0), out[0].x);
    try testing.expectEqual(@as(f32, 0), out[0].y);
    const r = @sqrt(out[1].x * out[1].x + out[1].y * out[1].y);
    try testing.expectApproxEqAbs(ring1_radius, r, 1e-3);
}

test "ring-1 nodes are evenly spaced on first layout" {
    var nodes = [_]Node{
        .{ .note_id = 1, .kind = .focus, .title = "Focus" },
        .{ .note_id = 2, .kind = .neighbor, .title = "A", .sort_key = 0 },
        .{ .note_id = 3, .kind = .neighbor, .title = "B", .sort_key = 1 },
        .{ .note_id = 4, .kind = .neighbor, .title = "C", .sort_key = 2 },
    };
    var out: [4]dvui.Point = undefined;
    targets(&nodes, &.{}, &out);
    // Three neighbours → 120° apart.
    const a2 = angleOf(out[1]);
    const a3 = angleOf(out[2]);
    const a4 = angleOf(out[3]);
    var angles = [_]f32{ normalizeAngle(a2), normalizeAngle(a3), normalizeAngle(a4) };
    std.mem.sort(f32, &angles, {}, std.sort.asc(f32));
    const gap01 = angles[1] - angles[0];
    const gap12 = angles[2] - angles[1];
    try testing.expectApproxEqAbs(gap01, gap12, 1e-3);
}

test "prior angles keep a surviving node from rotating" {
    const nodes = [_]Node{
        .{ .note_id = 1, .kind = .focus, .title = "Focus" },
        .{ .note_id = 2, .kind = .neighbor, .title = "A", .sort_key = 0 },
        .{ .note_id = 3, .kind = .neighbor, .title = "B", .sort_key = 1 },
    };
    var out1: [3]dvui.Point = undefined;
    targets(&nodes, &.{}, &out1);
    var prior_buf: [3]PriorAngle = undefined;
    const priors = capturePriors(&nodes, &out1, &prior_buf);

    // Relayout with the same nodes — angles must match.
    var out2: [3]dvui.Point = undefined;
    targets(&nodes, priors, &out2);
    try testing.expectApproxEqAbs(out1[1].x, out2[1].x, 1e-3);
    try testing.expectApproxEqAbs(out1[1].y, out2[1].y, 1e-3);
    try testing.expectApproxEqAbs(out1[2].x, out2[2].x, 1e-3);
    try testing.expectApproxEqAbs(out1[2].y, out2[2].y, 1e-3);
}

test "adding a node does not spin existing ones" {
    const first = [_]Node{
        .{ .note_id = 1, .kind = .focus, .title = "Focus" },
        .{ .note_id = 2, .kind = .neighbor, .title = "A", .sort_key = 0 },
        .{ .note_id = 3, .kind = .neighbor, .title = "B", .sort_key = 1 },
    };
    var out1: [3]dvui.Point = undefined;
    targets(&first, &.{}, &out1);
    var prior_buf: [4]PriorAngle = undefined;
    const priors = capturePriors(&first, &out1, &prior_buf);

    const second = [_]Node{
        .{ .note_id = 1, .kind = .focus, .title = "Focus" },
        .{ .note_id = 2, .kind = .neighbor, .title = "A", .sort_key = 0 },
        .{ .note_id = 3, .kind = .neighbor, .title = "B", .sort_key = 1 },
        .{ .note_id = 4, .kind = .neighbor, .title = "C", .sort_key = 2 },
    };
    var out2: [4]dvui.Point = undefined;
    targets(&second, priors, &out2);

    // Nodes 2 and 3 keep their angles (within a small tolerance — gap insertion shouldn't move them).
    try testing.expectApproxEqAbs(angleOf(out1[1]), angleOf(out2[1]), 1e-3);
    try testing.expectApproxEqAbs(angleOf(out1[2]), angleOf(out2[2]), 1e-3);
}

test "ring-2 sits farther out than ring-1" {
    const nodes = [_]Node{
        .{ .note_id = 1, .kind = .focus, .title = "F" },
        .{ .note_id = 2, .kind = .neighbor, .title = "N", .sort_key = 0 },
        .{ .note_id = 3, .kind = .second, .title = "S", .parent = 1 },
    };
    var out: [3]dvui.Point = undefined;
    targets(&nodes, &.{}, &out);
    const r1 = @sqrt(out[1].x * out[1].x + out[1].y * out[1].y);
    const r2 = @sqrt(out[2].x * out[2].x + out[2].y * out[2].y);
    try testing.expectApproxEqAbs(ring1_radius, r1, 1e-3);
    try testing.expectApproxEqAbs(ring2_radius, r2, 1e-3);
}
