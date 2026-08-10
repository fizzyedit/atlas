//! Build a radial-layout neighbourhood from an indexer Snapshot.
//!
//! Pure: no SQLite, no dvui. Given a focus path and the flat node/edge arrays, produce the
//! ring-0/1/2 (+ phantom outer) node list that `layout.targets` expects, plus the edges among
//! those nodes for drawing.
const std = @import("std");
const Indexer = @import("../index/Indexer.zig");
const layout = @import("layout.zig");

pub const max_ring1: usize = 48;
pub const max_ring2_per_parent: usize = 8;

pub const NodeInfo = struct {
    note_id: i64,
    path: []const u8,
    title: []const u8,
    phantom: bool,
    degree: u32,
    kind: layout.Kind,
    /// Index into the returned `nodes` slice of the ring-1 parent (ring-2 only).
    parent: ?usize = null,
    sort_key: u32 = 0,
};

pub const Edge = struct {
    /// Indices into the returned `nodes` slice.
    a: usize,
    b: usize,
};

pub const Result = struct {
    focus_idx: usize,
    nodes: []NodeInfo,
    edges: []Edge,
};

/// Empty / missing focus → empty result (caller shows the empty state).
pub fn aroundFocus(
    arena: std.mem.Allocator,
    snap: Indexer.Snapshot,
    focus_path: []const u8,
) !Result {
    if (focus_path.len == 0 or snap.nodes.len == 0) return .{ .focus_idx = 0, .nodes = &.{}, .edges = &.{} };

    const focus_snap = findByPath(snap.nodes, focus_path) orelse
        return .{ .focus_idx = 0, .nodes = &.{}, .edges = &.{} };

    // id → snap index
    var id_index = std.AutoHashMap(i64, usize).init(arena);
    try id_index.ensureTotalCapacity(@intCast(snap.nodes.len));
    for (snap.nodes, 0..) |n, i| try id_index.put(n.id, i);

    // Adjacency (undirected for neighbourhood; direction kept for ring-1 sort).
    var out_adj = std.AutoHashMap(i64, std.ArrayList(i64)).init(arena);
    var in_adj = std.AutoHashMap(i64, std.ArrayList(i64)).init(arena);
    for (snap.edges) |e| {
        {
            const gop = try out_adj.getOrPut(e.src_id);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(arena, e.dst_id);
        }
        {
            const gop = try in_adj.getOrPut(e.dst_id);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(arena, e.src_id);
        }
    }

    var nodes: std.ArrayList(NodeInfo) = .empty;
    var seen = std.AutoHashMap(i64, usize).init(arena); // id → nodes index

    try nodes.append(arena, .{
        .note_id = focus_snap.id,
        .path = try arena.dupe(u8, focus_snap.path),
        .title = try arena.dupe(u8, focus_snap.title),
        .phantom = focus_snap.phantom,
        .degree = focus_snap.degree,
        .kind = .focus,
    });
    try seen.put(focus_snap.id, 0);

    // Ring 1 candidates: out first (sort_key low), then in, degree desc, title.
    const Ring1Cand = struct {
        id: i64,
        outbound: bool,
        degree: u32,
        title: []const u8,
        phantom: bool,
        path: []const u8,
    };
    var ring1_cands: std.ArrayList(Ring1Cand) = .empty;
    var ring1_seen = std.AutoHashMap(i64, void).init(arena);

    if (out_adj.get(focus_snap.id)) |outs| {
        for (outs.items) |oid| {
            if (oid == focus_snap.id) continue;
            if (ring1_seen.contains(oid)) continue;
            const sn = snap.nodes[id_index.get(oid) orelse continue];
            try ring1_seen.put(oid, {});
            try ring1_cands.append(arena, .{
                .id = oid,
                .outbound = true,
                .degree = sn.degree,
                .title = sn.title,
                .phantom = sn.phantom,
                .path = sn.path,
            });
        }
    }
    if (in_adj.get(focus_snap.id)) |ins| {
        for (ins.items) |iid| {
            if (iid == focus_snap.id) continue;
            if (ring1_seen.contains(iid)) continue;
            const sn = snap.nodes[id_index.get(iid) orelse continue];
            try ring1_seen.put(iid, {});
            try ring1_cands.append(arena, .{
                .id = iid,
                .outbound = false,
                .degree = sn.degree,
                .title = sn.title,
                .phantom = sn.phantom,
                .path = sn.path,
            });
        }
    }

    std.mem.sort(Ring1Cand, ring1_cands.items, {}, struct {
        fn less(_: void, a: Ring1Cand, b: Ring1Cand) bool {
            // Real notes before phantoms; outbound before inbound; degree desc; title.
            if (a.phantom != b.phantom) return !a.phantom and b.phantom;
            if (a.outbound != b.outbound) return a.outbound and !b.outbound;
            if (a.degree != b.degree) return a.degree > b.degree;
            return std.mem.order(u8, a.title, b.title) == .lt;
        }
    }.less);

    // Phantoms go to the outer orphan arc; real notes fill ring 1 (capped).
    var sort_i: u32 = 0;
    for (ring1_cands.items) |c| {
        if (c.phantom) {
            if (seen.contains(c.id)) continue;
            const idx = nodes.items.len;
            try nodes.append(arena, .{
                .note_id = c.id,
                .path = try arena.dupe(u8, c.path),
                .title = try arena.dupe(u8, c.title),
                .phantom = true,
                .degree = c.degree,
                .kind = .orphan,
                .sort_key = sort_i,
            });
            try seen.put(c.id, idx);
            sort_i += 1;
            continue;
        }
        if (countKind(nodes.items, .neighbor) >= max_ring1) continue;
        if (seen.contains(c.id)) continue;
        const idx = nodes.items.len;
        try nodes.append(arena, .{
            .note_id = c.id,
            .path = try arena.dupe(u8, c.path),
            .title = try arena.dupe(u8, c.title),
            .phantom = false,
            .degree = c.degree,
            .kind = .neighbor,
            .sort_key = sort_i,
        });
        try seen.put(c.id, idx);
        sort_i += 1;
    }

    // Ring 2: for each ring-1 node, take neighbours that aren't focus/ring1/orphan.
    // Collect ring-1 indices first (they shift as we append — so snapshot them).
    var ring1_idxs: std.ArrayList(usize) = .empty;
    for (nodes.items, 0..) |n, i| {
        if (n.kind == .neighbor) try ring1_idxs.append(arena, i);
    }
    for (ring1_idxs.items) |pidx| {
        const pid = nodes.items[pidx].note_id;
        var added: usize = 0;
        // Prefer outbound from the parent, then inbound.
        const sides = [_]?[]const i64{
            if (out_adj.get(pid)) |l| l.items else null,
            if (in_adj.get(pid)) |l| l.items else null,
        };
        for (sides) |maybe| {
            const list = maybe orelse continue;
            for (list) |oid| {
                if (added >= max_ring2_per_parent) break;
                if (seen.contains(oid)) continue;
                const sn = snap.nodes[id_index.get(oid) orelse continue];
                if (sn.phantom) continue; // phantoms only appear when linked to focus
                const idx = nodes.items.len;
                try nodes.append(arena, .{
                    .note_id = oid,
                    .path = try arena.dupe(u8, sn.path),
                    .title = try arena.dupe(u8, sn.title),
                    .phantom = false,
                    .degree = sn.degree,
                    .kind = .second,
                    .parent = pidx,
                    .sort_key = @intCast(added),
                });
                try seen.put(oid, idx);
                added += 1;
            }
        }
    }

    // Edges among visible nodes (undirected unique).
    var edge_set = std.AutoHashMap(u64, void).init(arena);
    var edges: std.ArrayList(Edge) = .empty;
    for (snap.edges) |e| {
        const ai = seen.get(e.src_id) orelse continue;
        const bi = seen.get(e.dst_id) orelse continue;
        if (ai == bi) continue;
        const lo: u64 = @intCast(@min(ai, bi));
        const hi: u64 = @intCast(@max(ai, bi));
        const key = (lo << 32) | hi;
        const gop = try edge_set.getOrPut(key);
        if (gop.found_existing) continue;
        try edges.append(arena, .{ .a = ai, .b = bi });
    }

    return .{
        .focus_idx = 0,
        .nodes = try nodes.toOwnedSlice(arena),
        .edges = try edges.toOwnedSlice(arena),
    };
}

/// Convert neighbourhood nodes into the layout module's input shape (borrows titles).
pub fn toLayoutNodes(nodes: []const NodeInfo, out: []layout.Node) void {
    std.debug.assert(out.len >= nodes.len);
    for (nodes, 0..) |n, i| {
        out[i] = .{
            .note_id = n.note_id,
            .kind = n.kind,
            .parent = n.parent,
            .title = n.title,
            .sort_key = n.sort_key,
        };
    }
}

fn findByPath(nodes: []const Indexer.SnapNode, path: []const u8) ?Indexer.SnapNode {
    for (nodes) |n| {
        if (std.mem.eql(u8, n.path, path)) return n;
    }
    return null;
}

fn countKind(nodes: []const NodeInfo, kind: layout.Kind) usize {
    var n: usize = 0;
    for (nodes) |node| {
        if (node.kind == kind) n += 1;
    }
    return n;
}
