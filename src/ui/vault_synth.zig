//! In-memory synthetic vaults for scale benches — no million markdown files.
//!
//! Shapes mirror gauntlet folders (`islands`, `hub`, `scale-free`, …) but N and average
//! degree are knobs. Positions come from a fast component pack (same idea as
//! `layout_full.packComponents` / `render_bench_world`) so Galaxy/LOD can be measured at
//! 100k–1M without waiting on a full force layout.
//!
//! `lfr` is the odd one out: it's an LFR-benchmark-style generator (Lancichinetti-Fortunato-
//! Radicchi) calibrated against a real wikilink graph measurement (see `bench_stats.zig`'s
//! power-law/clustering report) rather than a hand-tuned shape. It plants ground-truth
//! communities (`Graph.communities`) so the coarsening ladder can later be scored against them.
//!
//! Spec string: `synth:N`, `synth:N:shape`, or `synth:N:shape:avg_deg`
//!   shapes: scale-free | islands | hub | bipartite | chain | orphans | lfr

const std = @import("std");
const dvui = @import("dvui");
const hex = @import("hex.zig");
const layout_full = @import("layout_full.zig");
const content_graph = @import("content_graph");
const testing = std.testing;

const golden_angle: f32 = std.math.pi * (3.0 - @sqrt(5.0));
const component_gap_slots: f32 = 1.35;
const lone_air_slots: f32 = 0.55;

pub const Shape = enum {
    scale_free,
    islands,
    hub,
    bipartite,
    chain,
    orphans,
    lfr,

    pub fn parse(s: []const u8) !Shape {
        if (std.mem.eql(u8, s, "scale-free") or std.mem.eql(u8, s, "scalefree")) return .scale_free;
        if (std.mem.eql(u8, s, "islands") or std.mem.eql(u8, s, "isle")) return .islands;
        if (std.mem.eql(u8, s, "hub") or std.mem.eql(u8, s, "hub-and-spoke")) return .hub;
        if (std.mem.eql(u8, s, "bipartite") or std.mem.eql(u8, s, "tags")) return .bipartite;
        if (std.mem.eql(u8, s, "chain") or std.mem.eql(u8, s, "path")) return .chain;
        if (std.mem.eql(u8, s, "orphans") or std.mem.eql(u8, s, "loners")) return .orphans;
        if (std.mem.eql(u8, s, "lfr") or std.mem.eql(u8, s, "realistic")) return .lfr;
        return error.UnknownSynthShape;
    }

    pub fn label(self: Shape) []const u8 {
        return switch (self) {
            .scale_free => "scale-free",
            .islands => "islands",
            .hub => "hub",
            .bipartite => "bipartite",
            .chain => "chain",
            .orphans => "orphans",
            .lfr => "lfr",
        };
    }
};

/// Sentinel community id for notes outside every planted community — orphans reserved by
/// `orphan_frac`, and (for non-`lfr` shapes, which have no communities at all) every note.
pub const orphan_community: u32 = std.math.maxInt(u32);

pub const Place = enum {
    /// Fast: sunflower discs per component + elliptical pack (Galaxy / LOD curve).
    pack,
    /// Full `layout_full.targets` solve (layout scaling curve; costly past ~50k).
    layout,

    pub fn parse(s: []const u8) !Place {
        if (std.mem.eql(u8, s, "pack")) return .pack;
        if (std.mem.eql(u8, s, "layout")) return .layout;
        return error.UnknownPlace;
    }
};

pub const Spec = struct {
    n: usize,
    shape: Shape = .scale_free,
    /// Target mean undirected degree ≈ 2|E|/N. Clamped per shape.
    avg_deg: f32 = 3.0,
    place: Place = .pack,
    /// Loners as a fraction of N. Keep low for large-N Galaxy budgets (each orphan is a CC).
    orphan_frac: f32 = 0.02,
    island_min: u32 = 5,
    island_max: u32 = 10_000,
    /// Bipartite tag count (clamped to ≤ n/2).
    tag_count: u32 = 40,
    /// Extra cross-component links as a fraction of `n` — real vaults are rarely perfectly
    /// disconnected islands; a few "map of content" notes tie unrelated topics together.
    /// Clamped to [0, 0.25]. No-op in practice for shapes that are already one component
    /// (`scale-free`, `hub`, `chain`, `bipartite`) since there is nothing left to bridge.
    bridge_frac: f32 = 0.0,
    /// Fraction of notes deliberately filed under another component's folder, simulating a
    /// messy real vault. Clamped to [0, 0.9].
    folder_leak_frac: f32 = 0.08,
    seed: u64 = 0xA71A5,
    aspect: f32 = 1.6,

    /// `lfr` shape only, below. Defaults calibrated against Simple English Wikipedia's wikilink
    /// graph (283,997 articles / 3,682,542 undirected links) — see `bench_stats.zig`'s
    /// power-law/clustering report. Pure configuration-model internals under-cluster; the
    /// generator closes within-community wedges after stub pairing to approach the measured
    /// avg local clustering of ~0.27 (at vault-like `avg_deg`, not Wikipedia's denser regime).
    /// Degree power-law exponent (discrete MLE tail estimate on real data: 2.25).
    tau_degree: f32 = 2.25,
    /// Community-size power-law exponent.
    tau_community: f32 = 2.7,
    /// Fraction of each node's links that leave its own community. Clamped to [0, 1].
    mu: f32 = 0.3,
    community_min: u32 = 8,
    community_max: u32 = 400,

    /// Parse `synth:N[:shape[:avg_deg]]`. Does not set `place`.
    pub fn parse(s: []const u8) !Spec {
        if (!std.mem.startsWith(u8, s, "synth:")) return error.NotSynth;
        var it = std.mem.splitScalar(u8, s["synth:".len..], ':');
        const n_s = it.next() orelse return error.BadSynthSpec;
        const n = try std.fmt.parseInt(usize, n_s, 10);
        if (n == 0) return error.BadSynthSpec;
        var spec: Spec = .{ .n = n };
        if (it.next()) |shape_s| {
            if (shape_s.len != 0) spec.shape = try Shape.parse(shape_s);
        }
        if (it.next()) |deg_s| {
            if (deg_s.len != 0) spec.avg_deg = try std.fmt.parseFloat(f32, deg_s);
        }
        if (it.next() != null) return error.BadSynthSpec;
        spec.avg_deg = std.math.clamp(spec.avg_deg, 0, 64);
        return spec;
    }

    pub fn nameBuf(self: Spec, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "synth:{d}:{s}:{d:.1}", .{ self.n, self.shape.label(), self.avg_deg }) catch "synth";
    }
};

/// Controls synthetic per-note *content* shape — headings, paragraphs, lists, code blocks,
/// blockquotes, tables, tags, embeds — for stress-testing the interior view's document-content
/// layout (`buildInteriorWorld`) without needing real markdown files. Produces the same
/// `content_graph.ContentGraph` shape `query.noteContentGraph` produces from a real indexed
/// document (see `synthContentGraph` below). Deliberately not wired into `generate`'s
/// whole-vault loop — see that function's doc comment for why.
///
/// Defaults are calibrated toward "a realistic document has a few headers, a few paragraphs"
/// (this file's own framing, carried over from the containment/interior plan) — contrast with
/// `flatHeadingsExtreme()`, a deliberately-reachable degenerate shape at the other end.
pub const DocSpec = struct {
    /// Heading count range (inclusive).
    heading_min: u32 = 2,
    heading_max: u32 = 6,
    /// Deepest ATX level headings may nest to. Clamped to [1, 6] (ATX only goes to h6).
    max_depth: u32 = 3,
    /// Paragraphs attached per heading (inclusive range).
    para_min: u32 = 1,
    para_max: u32 = 3,
    /// Word count per paragraph — feeds `Item.weight` directly (weight = word count, mirroring
    /// the real indexer's planned `blocks.weight` = word count for prose, per the schema in the
    /// containment/interior plan).
    words_min: u32 = 15,
    words_max: u32 = 80,
    /// Independent per-heading probability of attaching one list/code/blockquote/table item.
    list_prob: f32 = 0.25,
    code_prob: f32 = 0.15,
    quote_prob: f32 = 0.1,
    table_prob: f32 = 0.08,
    /// Sizing when a list/code block is rolled, feeding `Item.weight` for those kinds. The real
    /// indexer weights a code block by line count and a list has no natural line count, so item
    /// count is the closest analogue — `weight` = item count for `.list`, line count for `.code`.
    /// `.blockquote`/`.table` get a flat `weight = 1` (no natural size knob in this pass).
    list_items_min: u32 = 2,
    list_items_max: u32 = 8,
    code_lines_min: u32 = 3,
    code_lines_max: u32 = 25,
    /// Tags scattered across the document (outline-children of randomly-chosen headings).
    tags_min: u32 = 0,
    tags_max: u32 = 4,
    /// Embeds scattered across the document (outline-children of randomly-chosen headings).
    embeds_min: u32 = 0,
    embeds_max: u32 = 2,
    seed: u64 = 0xC0FFEE,

    /// Reproduces `gauntlet/vault/giant-docs/giant-2.md`'s exact degenerate shape: one root, N
    /// flat (depth-1, unnested) headings, each with exactly one paragraph child and nothing
    /// else — no lists, code, tags, or embeds. This is the edge case the interior redesign is
    /// specifically meant to handle well (12,000 undifferentiated same-size planets on one ring,
    /// under the old orbit layout). The real fixture is 12,000 headings; this preset uses 800 —
    /// enough to exercise containment's coalescing at interior scale without paying the real
    /// fixture's full cost on every test/bench run. Override `.heading_min`/`.heading_max` on
    /// the returned value (both together, so the range stays a point) if the exact fixture size
    /// is needed.
    pub fn flatHeadingsExtreme() DocSpec {
        return .{
            .heading_min = 800,
            .heading_max = 800,
            .max_depth = 1,
            .para_min = 1,
            .para_max = 1,
            .list_prob = 0,
            .code_prob = 0,
            .quote_prob = 0,
            .table_prob = 0,
            .tags_min = 0,
            .tags_max = 0,
            .embeds_min = 0,
            .embeds_max = 0,
        };
    }
};

fn randRangeU32(rand: std.Random, min: u32, max: u32) u32 {
    const hi = @max(min, max);
    if (hi <= min) return min;
    return min + rand.uintLessThan(u32, hi - min + 1);
}

/// Synthetic per-note content graph — the same `ContentGraph` shape `query.noteContentGraph`
/// produces from a real indexed document, so the interior's `buildInteriorWorld` (containment/
/// interior plan, Part 2) consumes either with zero special-casing downstream. Pure, headless: no
/// filesystem, no db, matching this file's existing ethos.
///
/// Only `.outline` edges are emitted — synthetic documents in this pass have no explicit
/// `[[same-note#links]]` between sections. That's a deliberate simplification, noted here rather
/// than silently omitting `.link` edges from the output.
///
/// Algorithm: draw a heading count in `[heading_min, heading_max]`; walk each heading's depth via
/// a bounded random walk clamped to `[1, max_depth]`, biased toward staying or going shallower;
/// derive each heading's outline parent as the nearest *earlier* heading with a strictly smaller
/// depth (or root), the same rule real markdown ATX nesting implies; attach paragraphs (and,
/// per-heading independent rolls, at most one list/code/blockquote/table) as outline-children in
/// document order; finally scatter tags/embeds as outline-children of randomly-chosen headings.
/// Every item gets a strictly-increasing `line` in emission order and a simple incrementing `id`
/// (synthetic, no cross-session identity concern).
///
/// Determinism: same `rand` state + `spec` always produces the same graph. `rand` is the caller's
/// responsibility to seed — mirrors `Spec.seed` being consumed by `generate`'s *caller*, not
/// hidden inside this function — so the plan's per-note use (`spec.seed ^ mix64(note_id)`) can
/// derive a note-specific `std.Random` before calling in.
pub fn synthContentGraph(arena: std.mem.Allocator, rand: std.Random, spec: DocSpec) !content_graph.ContentGraph {
    const max_depth = std.math.clamp(spec.max_depth, 1, 6);

    var items: std.ArrayListUnmanaged(content_graph.Item) = .empty;
    var edges: std.ArrayListUnmanaged(content_graph.ItemEdge) = .empty;

    var next_id: i64 = 0;
    var next_line: u32 = 0;
    const newId = struct {
        fn go(id: *i64) i64 {
            const v = id.*;
            id.* += 1;
            return v;
        }
    }.go;
    const newLine = struct {
        fn go(l: *u32) u32 {
            const v = l.*;
            l.* += 1;
            return v;
        }
    }.go;

    // Root, always item index 0.
    try items.append(arena, .{ .id = newId(&next_id), .kind = .root, .line = newLine(&next_line) });
    const root_idx: u32 = 0;

    const heading_count = randRangeU32(rand, spec.heading_min, spec.heading_max);
    if (heading_count == 0) {
        return .{ .items = try items.toOwnedSlice(arena), .edges = try edges.toOwnedSlice(arena) };
    }

    // Stack of (depth, item_idx) tracks the nearest-earlier-smaller-depth parent — the same rule
    // real markdown ATX nesting implies.
    var stack: std.ArrayListUnmanaged(struct { depth: u32, idx: u32 }) = .empty;
    var heading_idx: std.ArrayListUnmanaged(u32) = .empty; // item index per heading, doc order

    var depth: u32 = 1;
    var h: u32 = 0;
    while (h < heading_count) : (h += 1) {
        if (h > 0) {
            // Biased random walk: mostly stay or go shallower, occasionally one deeper — "a
            // realistic document has a few headers" implies mostly-flat-ish structure.
            const r = rand.float(f32);
            var step: i32 = 0;
            if (r < 0.2) step = 1 else if (r < 0.45) step = -1;
            const nd = @as(i32, @intCast(depth)) + step;
            depth = @intCast(std.math.clamp(nd, 1, @as(i32, @intCast(max_depth))));
        }

        while (stack.items.len > 0 and stack.items[stack.items.len - 1].depth >= depth) {
            stack.shrinkRetainingCapacity(stack.items.len - 1);
        }
        const parent_idx: u32 = if (stack.items.len > 0) stack.items[stack.items.len - 1].idx else root_idx;

        const item_idx: u32 = @intCast(items.items.len);
        try items.append(arena, .{ .id = newId(&next_id), .kind = .heading, .level = depth, .line = newLine(&next_line) });
        try edges.append(arena, .{ .a = parent_idx, .b = item_idx, .kind = .outline });

        try stack.append(arena, .{ .depth = depth, .idx = item_idx });
        try heading_idx.append(arena, item_idx);

        // Paragraphs, in document order under this heading.
        const para_count = randRangeU32(rand, spec.para_min, spec.para_max);
        var p: u32 = 0;
        while (p < para_count) : (p += 1) {
            const words = randRangeU32(rand, spec.words_min, spec.words_max);
            const pi: u32 = @intCast(items.items.len);
            try items.append(arena, .{ .id = newId(&next_id), .kind = .paragraph, .line = newLine(&next_line), .weight = words });
            try edges.append(arena, .{ .a = item_idx, .b = pi, .kind = .outline });
        }

        if (rand.float(f32) < spec.list_prob) {
            const count = randRangeU32(rand, spec.list_items_min, spec.list_items_max);
            const li: u32 = @intCast(items.items.len);
            try items.append(arena, .{ .id = newId(&next_id), .kind = .list, .line = newLine(&next_line), .weight = count });
            try edges.append(arena, .{ .a = item_idx, .b = li, .kind = .outline });
        }
        if (rand.float(f32) < spec.code_prob) {
            const lines = randRangeU32(rand, spec.code_lines_min, spec.code_lines_max);
            const ci: u32 = @intCast(items.items.len);
            try items.append(arena, .{ .id = newId(&next_id), .kind = .code, .line = newLine(&next_line), .weight = lines });
            try edges.append(arena, .{ .a = item_idx, .b = ci, .kind = .outline });
        }
        if (rand.float(f32) < spec.quote_prob) {
            const qi: u32 = @intCast(items.items.len);
            try items.append(arena, .{ .id = newId(&next_id), .kind = .blockquote, .line = newLine(&next_line), .weight = 1 });
            try edges.append(arena, .{ .a = item_idx, .b = qi, .kind = .outline });
        }
        if (rand.float(f32) < spec.table_prob) {
            const ti: u32 = @intCast(items.items.len);
            try items.append(arena, .{ .id = newId(&next_id), .kind = .table, .line = newLine(&next_line), .weight = 1 });
            try edges.append(arena, .{ .a = item_idx, .b = ti, .kind = .outline });
        }
    }

    // Tags/embeds are scattered by parentage (attached to a randomly-chosen existing heading) but
    // appended at the end of emission order — only `kind`/`weight` reach layout today (nothing
    // downstream renders real text yet, per the plan), so physical mid-document placement doesn't
    // matter and this keeps the algorithm a simple two-pass build.
    const tag_count = randRangeU32(rand, spec.tags_min, spec.tags_max);
    var t: u32 = 0;
    while (t < tag_count) : (t += 1) {
        const parent = heading_idx.items[rand.uintLessThan(usize, heading_idx.items.len)];
        const text = try std.fmt.allocPrint(arena, "tag{d}", .{t});
        const ti: u32 = @intCast(items.items.len);
        try items.append(arena, .{ .id = newId(&next_id), .kind = .tag, .line = newLine(&next_line), .text = text });
        try edges.append(arena, .{ .a = parent, .b = ti, .kind = .outline });
    }

    const embed_count = randRangeU32(rand, spec.embeds_min, spec.embeds_max);
    var e: u32 = 0;
    while (e < embed_count) : (e += 1) {
        const parent = heading_idx.items[rand.uintLessThan(usize, heading_idx.items.len)];
        const text = try std.fmt.allocPrint(arena, "embed{d}", .{e});
        const ei: u32 = @intCast(items.items.len);
        try items.append(arena, .{ .id = newId(&next_id), .kind = .embed, .line = newLine(&next_line), .text = text });
        try edges.append(arena, .{ .a = parent, .b = ei, .kind = .outline });
    }

    return .{ .items = try items.toOwnedSlice(arena), .edges = try edges.toOwnedSlice(arena) };
}

pub const Graph = struct {
    positions: []dvui.Point,
    edges: []layout_full.Edge,
    degrees: []u32,
    paths: []const []const u8,
    components: usize,
    orphans: usize,
    max_degree: u32,
    shape: Shape,
    avg_deg_actual: f32,
    /// Ground-truth community id per note (`orphan_community` sentinel for notes with none).
    /// Only `lfr` plants real communities; every other shape fills this with the sentinel.
    communities: []u32,

    pub fn deinit(self: *Graph, gpa: std.mem.Allocator) void {
        gpa.free(self.positions);
        gpa.free(self.edges);
        gpa.free(self.degrees);
        gpa.free(self.communities);
        // paths live in the caller's arena.
        self.* = undefined;
    }
};

/// Build graph. When `spec.place == .pack`, fills packed positions; for `.layout`, positions
/// are zeroed (caller runs `layout_full.targets`). `arena` holds path strings; `gpa` owns
/// positions/edges/degrees — call `deinit`.
pub fn generate(gpa: std.mem.Allocator, arena: std.mem.Allocator, spec: Spec) !Graph {
    var rng = std.Random.DefaultPrng.init(spec.seed);
    const rand = rng.random();

    var edges: std.ArrayListUnmanaged(layout_full.Edge) = .empty;
    errdefer edges.deinit(gpa);

    const communities = try gpa.alloc(u32, spec.n);
    errdefer gpa.free(communities);
    @memset(communities, orphan_community);

    switch (spec.shape) {
        .scale_free => try genScaleFree(gpa, rand, spec, &edges),
        .islands => try genIslands(gpa, rand, spec, &edges),
        .hub => try genHub(gpa, rand, spec, &edges),
        .bipartite => try genBipartite(gpa, rand, spec, &edges),
        .chain => try genChain(gpa, spec, &edges),
        .orphans => {},
        .lfr => try genLfr(gpa, arena, rand, spec, &edges, communities),
    }

    // Cross-island bridges, before anything downstream counts components or derives folders
    // from them, so both see the post-bridge structure.
    try addBridges(gpa, rand, spec, &edges);

    // Folders are derived from the (post-bridge) component structure, so they need their own
    // pass over `edges` — kept on a seed-derived stream separate from `rand` so path generation
    // never perturbs the edge topology that shapes above already committed to.
    var path_rng = std.Random.DefaultPrng.init(spec.seed ^ 0xF00D_FACE);
    const paths = try fakePaths(arena, gpa, path_rng.random(), spec, edges.items);

    const degrees = try noteDegrees(gpa, spec.n, edges.items);
    errdefer gpa.free(degrees);

    var max_degree: u32 = 0;
    for (degrees) |d| max_degree = @max(max_degree, d);

    const positions = try gpa.alloc(dvui.Point, spec.n);
    errdefer gpa.free(positions);
    @memset(positions, .{ .x = 0, .y = 0 });

    var comps: usize = 0;
    if (spec.place == .pack) {
        comps = try packComponents(gpa, positions, edges.items, spec.n, spec.aspect);
    } else {
        // Cheap CC count for the summary line (no placement).
        comps = try countComponents(gpa, edges.items, spec.n);
    }
    const orphans = countDegreeZero(degrees);
    const avg: f32 = if (spec.n == 0) 0 else @as(f32, @floatFromInt(edges.items.len * 2)) / @as(f32, @floatFromInt(spec.n));

    return .{
        .positions = positions,
        .edges = try edges.toOwnedSlice(gpa),
        .degrees = degrees,
        .paths = paths,
        .components = comps,
        .orphans = orphans,
        .max_degree = max_degree,
        .shape = spec.shape,
        .avg_deg_actual = avg,
        .communities = communities,
    };
}

fn countComponents(gpa: std.mem.Allocator, edges: []const layout_full.Edge, n: usize) !usize {
    if (n == 0) return 0;
    var parent = try gpa.alloc(u32, n);
    defer gpa.free(parent);
    for (0..n) |i| parent[i] = @intCast(i);
    const find = struct {
        fn go(p: []u32, x: u32) u32 {
            var cur = x;
            while (p[cur] != cur) {
                p[cur] = p[p[cur]];
                cur = p[cur];
            }
            return cur;
        }
    }.go;
    for (edges) |e| {
        if (e.a >= n or e.b >= n) continue;
        const ra = find(parent, @intCast(e.a));
        const rb = find(parent, @intCast(e.b));
        if (ra != rb) parent[rb] = ra;
    }
    var comps: usize = 0;
    for (0..n) |i| {
        if (find(parent, @intCast(i)) == i) comps += 1;
    }
    return comps;
}

/// Derive a folder tree from the graph's component structure instead of assigning paths at
/// random. `layout_full`'s folder-cohesion force (`applyFolderCohesion`, gated on `paths`) pulls
/// same-directory notes together regardless of links, so random paths just fight that force with
/// noise — benches built on them measure the folder force against garbage. Here, each component
/// gets one "home" directory, nested 1-3 levels deep depending on how big it is (a lone note
/// doesn't need three folders; a several-thousand-note island does), and `folder_leak_frac` of
/// notes are deliberately filed under a different component's directory, the way real vaults
/// accumulate misplaced notes over time.
fn fakePaths(
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    rand: std.Random,
    spec: Spec,
    edges: []const layout_full.Edge,
) ![]const []const u8 {
    const n = spec.n;
    const paths = try arena.alloc([]const u8, n);
    // Large synths never open real files — skip path string traffic (hundreds of MB at 1M).
    if (n > 50_000) {
        @memset(paths, "");
        return paths;
    }
    if (n == 0) return paths;

    var parent = try gpa.alloc(u32, n);
    defer gpa.free(parent);
    for (0..n) |i| parent[i] = @intCast(i);
    const find = struct {
        fn go(p: []u32, x: u32) u32 {
            var cur = x;
            while (p[cur] != cur) {
                p[cur] = p[p[cur]];
                cur = p[cur];
            }
            return cur;
        }
    }.go;
    for (edges) |e| {
        if (e.a >= n or e.b >= n) continue;
        const ra = find(parent, @intCast(e.a));
        const rb = find(parent, @intCast(e.b));
        if (ra != rb) parent[rb] = ra;
    }

    // Stable small id per component, in first-seen order (deterministic given `seed`).
    var comp_of_root: std.AutoHashMapUnmanaged(u32, u32) = .{};
    defer comp_of_root.deinit(gpa);
    const comp_id = try gpa.alloc(u32, n);
    defer gpa.free(comp_id);
    var comp_count: u32 = 0;
    for (0..n) |i| {
        const root = find(parent, @intCast(i));
        const gop = try comp_of_root.getOrPut(gpa, root);
        if (!gop.found_existing) {
            gop.value_ptr.* = comp_count;
            comp_count += 1;
        }
        comp_id[i] = gop.value_ptr.*;
    }

    const sizes = try gpa.alloc(u32, comp_count);
    defer gpa.free(sizes);
    @memset(sizes, 0);
    for (comp_id) |c| sizes[c] += 1;

    // One home directory per component: depth grows with size so a handful of small islands
    // don't each claim a private top-level folder, and a huge one doesn't dump everything flat.
    const top_folders: u32 = @min(10, @max(1, comp_count));
    const home_dirs = try arena.alloc([]const u8, comp_count);
    for (0..comp_count) |c| {
        const size = sizes[c];
        const top = @as(u32, @intCast(c)) % top_folders;
        home_dirs[c] = if (size <= 6)
            try std.fmt.allocPrint(arena, "area{d}", .{top})
        else if (size <= 200)
            try std.fmt.allocPrint(arena, "area{d}/topic{d}", .{ top, c })
        else
            try std.fmt.allocPrint(arena, "area{d}/topic{d}/part{d}", .{ top, c, size % 5 });
    }

    const leak_frac = std.math.clamp(spec.folder_leak_frac, 0, 0.9);
    for (0..n) |i| {
        var c = comp_id[i];
        if (comp_count > 1 and rand.float(f32) < leak_frac) {
            // Filed wrong: land in some other component's directory, same as a human misfile.
            var other = rand.uintLessThan(u32, comp_count - 1);
            if (other >= c) other += 1;
            c = other;
        }
        paths[i] = try std.fmt.allocPrint(arena, "{s}/note-{d}.md", .{ home_dirs[c], i });
    }
    return paths;
}

/// A handful of extra links between different components — the way a "map of content" note
/// ties otherwise-separate topics together in a real vault. Biases toward already-high-degree
/// endpoints via a cheap best-of-3 tournament (matches the rest of this file's habit of picking
/// randomly rather than building a sorted degree distribution).
fn addBridges(
    gpa: std.mem.Allocator,
    rand: std.Random,
    spec: Spec,
    edges: *std.ArrayListUnmanaged(layout_full.Edge),
) !void {
    const n = spec.n;
    if (n < 2) return;
    const bridge_frac = std.math.clamp(spec.bridge_frac, 0, 0.25);
    const want: usize = @intFromFloat(@round(bridge_frac * @as(f32, @floatFromInt(n))));
    if (want == 0) return;

    var parent = try gpa.alloc(u32, n);
    defer gpa.free(parent);
    for (0..n) |i| parent[i] = @intCast(i);
    const find = struct {
        fn go(p: []u32, x: u32) u32 {
            var cur = x;
            while (p[cur] != cur) {
                p[cur] = p[p[cur]];
                cur = p[cur];
            }
            return cur;
        }
    }.go;
    for (edges.items) |e| {
        if (e.a >= n or e.b >= n) continue;
        const ra = find(parent, @intCast(e.a));
        const rb = find(parent, @intCast(e.b));
        if (ra != rb) parent[rb] = ra;
    }

    const degree = try noteDegrees(gpa, n, edges.items);
    defer gpa.free(degree);

    const pickHighDegree = struct {
        fn go(r: std.Random, deg: []const u32, n_nodes: usize) u32 {
            var best: u32 = @intCast(r.uintLessThan(usize, n_nodes));
            var best_deg = deg[best];
            var t: usize = 0;
            while (t < 2) : (t += 1) {
                const cand: u32 = @intCast(r.uintLessThan(usize, n_nodes));
                if (deg[cand] > best_deg) {
                    best = cand;
                    best_deg = deg[cand];
                }
            }
            return best;
        }
    }.go;

    var added: usize = 0;
    var guard: usize = 0;
    while (added < want and guard < want * 32) : (guard += 1) {
        const a = pickHighDegree(rand, degree, n);
        const b = pickHighDegree(rand, degree, n);
        if (a == b) continue;
        const ra = find(parent, a);
        const rb = find(parent, b);
        if (ra == rb) continue; // already share a component
        try edges.append(gpa, .{ .a = a, .b = b });
        parent[rb] = ra;
        degree[a] += 1;
        degree[b] += 1;
        added += 1;
    }
}

fn noteDegrees(gpa: std.mem.Allocator, n: usize, edges: []const layout_full.Edge) ![]u32 {
    const deg = try gpa.alloc(u32, n);
    @memset(deg, 0);
    for (edges) |e| {
        if (e.a < n) deg[e.a] += 1;
        if (e.b < n) deg[e.b] += 1;
    }
    return deg;
}

fn countDegreeZero(deg: []const u32) usize {
    var n: usize = 0;
    for (deg) |d| {
        if (d == 0) n += 1;
    }
    return n;
}

fn attachmentsPerNew(avg_deg: f32, rand: std.Random) usize {
    // Preferential attachment: each new node adds ~m edges ⇒ mean degree → 2m.
    const m_f = std.math.clamp(avg_deg * 0.5, 0.5, 32);
    var m: usize = @intFromFloat(@floor(m_f));
    if (rand.float(f32) < m_f - @as(f32, @floatFromInt(m))) m += 1;
    return @max(m, 1);
}

fn genScaleFree(
    gpa: std.mem.Allocator,
    rand: std.Random,
    spec: Spec,
    edges: *std.ArrayListUnmanaged(layout_full.Edge),
) !void {
    const n = spec.n;
    if (n < 2 or spec.avg_deg < 0.5) return;
    var pool: std.ArrayListUnmanaged(u32) = .empty;
    defer pool.deinit(gpa);
    try pool.append(gpa, 0);
    for (1..n) |i| {
        const k = attachmentsPerNew(spec.avg_deg, rand);
        var added: usize = 0;
        var guard: usize = 0;
        while (added < k and guard < k * 16) : (guard += 1) {
            const j = pool.items[rand.uintLessThan(usize, pool.items.len)];
            if (j == i) continue;
            try edges.append(gpa, .{ .a = @intCast(i), .b = j });
            try pool.append(gpa, j);
            added += 1;
        }
        try pool.append(gpa, @intCast(i));
    }
}

fn genIslands(
    gpa: std.mem.Allocator,
    rand: std.Random,
    spec: Spec,
    edges: *std.ArrayListUnmanaged(layout_full.Edge),
) !void {
    var o_min = spec.island_min;
    var o_max = spec.island_max;
    if (o_min < 2) o_min = 2;
    if (o_max < o_min) o_max = o_min;
    const orphan_frac = std.math.clamp(spec.orphan_frac, 0, 0.9);

    var sizes: std.ArrayListUnmanaged(u32) = .empty;
    defer sizes.deinit(gpa);

    const orphan_target: usize = @intFromFloat(@as(f32, @floatFromInt(spec.n)) * orphan_frac);
    var remaining = spec.n;
    var orphan_n: usize = 0;
    while (orphan_n < orphan_target and remaining > 0) : (orphan_n += 1) {
        try sizes.append(gpa, 1);
        remaining -= 1;
    }
    const log_lo = @log(@as(f32, @floatFromInt(o_min)));
    const log_hi = @log(@as(f32, @floatFromInt(o_max)));
    while (remaining > 0) {
        if (remaining < o_min) {
            try sizes.append(gpa, 1);
            remaining -= 1;
            continue;
        }
        const u = rand.float(f32);
        var sz: u32 = @intFromFloat(@round(@exp(log_lo + u * (log_hi - log_lo))));
        sz = std.math.clamp(sz, o_min, o_max);
        if (sz > remaining) sz = @intCast(remaining);
        try sizes.append(gpa, sz);
        remaining -= sz;
    }

    var cursor: u32 = 0;
    var pool: std.ArrayListUnmanaged(u32) = .empty;
    defer pool.deinit(gpa);
    for (sizes.items) |sz| {
        if (sz >= 2) {
            pool.clearRetainingCapacity();
            try pool.append(gpa, cursor);
            for (1..sz) |k| {
                const ni: u32 = cursor + @as(u32, @intCast(k));
                const k_attach = attachmentsPerNew(spec.avg_deg, rand);
                var added: usize = 0;
                var guard: usize = 0;
                while (added < k_attach and guard < k_attach * 16) : (guard += 1) {
                    const j = pool.items[rand.uintLessThan(usize, pool.items.len)];
                    if (j == ni) continue;
                    try edges.append(gpa, .{ .a = ni, .b = j });
                    try pool.append(gpa, j);
                    added += 1;
                }
                try pool.append(gpa, ni);
            }
        }
        cursor += sz;
    }
}

fn genHub(
    gpa: std.mem.Allocator,
    rand: std.Random,
    spec: Spec,
    edges: *std.ArrayListUnmanaged(layout_full.Edge),
) !void {
    const n = spec.n;
    if (n < 2) return;
    // Star: hub 0 ↔ every spoke. Extra avg_deg budget → a few spoke–spoke chords.
    for (1..n) |i| {
        try edges.append(gpa, .{ .a = 0, .b = @intCast(i) });
    }
    const star_avg = 2.0 * @as(f32, @floatFromInt(n - 1)) / @as(f32, @floatFromInt(n));
    if (spec.avg_deg <= star_avg + 0.05) return;
    const want_extra: usize = @intFromFloat(@max(0, (spec.avg_deg - star_avg) * @as(f32, @floatFromInt(n)) * 0.5));
    var added: usize = 0;
    var guard: usize = 0;
    while (added < want_extra and guard < want_extra * 8) : (guard += 1) {
        const a = 1 + rand.uintLessThan(usize, n - 1);
        const b = 1 + rand.uintLessThan(usize, n - 1);
        if (a == b) continue;
        try edges.append(gpa, .{ .a = @intCast(a), .b = @intCast(b) });
        added += 1;
    }
}

fn genBipartite(
    gpa: std.mem.Allocator,
    rand: std.Random,
    spec: Spec,
    edges: *std.ArrayListUnmanaged(layout_full.Edge),
) !void {
    const n = spec.n;
    if (n < 3) return;
    var tags = spec.tag_count;
    tags = @max(tags, 2);
    if (tags >= n) tags = @intCast(n / 2);
    if (tags < 2) return;
    const notes = n - tags;
    // Notes are [0, notes), tags [notes, n). Each note links to ~avg_deg/2 tags (tags absorb the rest).
    const links_per_note = @max(@as(usize, @intFromFloat(@round(std.math.clamp(spec.avg_deg * 0.5, 1, 8)))), 1);
    for (0..notes) |i| {
        var linked: usize = 0;
        var guard: usize = 0;
        while (linked < links_per_note and guard < links_per_note * 8) : (guard += 1) {
            const t = notes + rand.uintLessThan(usize, tags);
            try edges.append(gpa, .{ .a = @intCast(i), .b = @intCast(t) });
            linked += 1;
        }
    }
}

fn genChain(gpa: std.mem.Allocator, spec: Spec, edges: *std.ArrayListUnmanaged(layout_full.Edge)) !void {
    const n = spec.n;
    if (n < 2) return;
    for (0..n - 1) |i| {
        try edges.append(gpa, .{ .a = @intCast(i), .b = @intCast(i + 1) });
    }
    // Optional skip links when avg_deg > ~2.
    if (spec.avg_deg <= 2.1) return;
    const skip = @as(usize, @intFromFloat(@max(0, (spec.avg_deg - 2) * @as(f32, @floatFromInt(n)) * 0.25)));
    var i: usize = 0;
    var added: usize = 0;
    while (i + 2 < n and added < skip) : (i += 2) {
        try edges.append(gpa, .{ .a = @intCast(i), .b = @intCast(i + 2) });
        added += 1;
    }
}

/// Inverse-transform sample from a bounded discrete-ish power law with exponent `tau` on
/// `[lo, hi]` (both inclusive, continuous form — caller rounds/clamps). Shared by the degree and
/// community-size draws below.
fn boundedPowerLawSample(rand: std.Random, tau: f64, lo: f64, hi: f64) f64 {
    const u = rand.float(f64);
    if (@abs(tau - 1.0) < 1e-9) return lo * @exp(u * @log(hi / lo));
    const p = 1.0 - tau;
    const lo_p = std.math.pow(f64, lo, p);
    const hi_p = std.math.pow(f64, hi, p);
    return std.math.pow(f64, (hi_p - lo_p) * u + lo_p, 1.0 / p);
}

fn drawPowerLawInt(rand: std.Random, tau: f64, lo: u32, hi: u32) u32 {
    if (hi <= lo) return lo;
    const x = boundedPowerLawSample(rand, tau, @floatFromInt(lo), @floatFromInt(hi));
    var xi: i64 = @intFromFloat(@round(x));
    xi = std.math.clamp(xi, @as(i64, lo), @as(i64, hi));
    return @intCast(xi);
}

/// Community sizes drawn from a bounded power law until their sum reaches `target_sum`, then the
/// last draw is trimmed down to match exactly (never below 1, so no community ends up empty).
/// `target_sum` is always reachable in a bounded number of draws since every draw is >= `lo` >= 1.
fn drawCommunitySizes(arena: std.mem.Allocator, rand: std.Random, target_sum: usize, tau: f32, lo: u32, hi: u32) ![]u32 {
    var sizes: std.ArrayListUnmanaged(u32) = .empty;
    if (target_sum == 0) return sizes.toOwnedSlice(arena);
    var sum: usize = 0;
    while (sum < target_sum) {
        const sz = drawPowerLawInt(rand, tau, lo, hi);
        try sizes.append(arena, sz);
        sum += sz;
    }
    const overshoot = sum - target_sum;
    const last = &sizes.items[sizes.items.len - 1];
    last.* = if (overshoot < last.*) last.* - @as(u32, @intCast(overshoot)) else 1;
    return sizes.toOwnedSlice(arena);
}

/// Configuration-model pairing over a (shuffled) stub list: pair consecutive stubs, and when a
/// pair is rejected by `reject`, try swapping in one of the next few stubs instead (bounded
/// retries) rather than rewiring the whole list. Unpaired stubs left over after retries are
/// dropped — a slightly-off realised degree beats an unbounded search for a perfect pairing.
fn pairStubs(
    stubs: []u32,
    base: usize,
    edges: *std.ArrayListUnmanaged(layout_full.Edge),
    gpa: std.mem.Allocator,
    ctx: anytype,
    reject: fn (@TypeOf(ctx), u32, u32) bool,
) !void {
    const max_retries = 6;
    var i: usize = 0;
    while (i + 1 < stubs.len) : (i += 2) {
        var b = stubs[i + 1];
        var tries: usize = 0;
        while (reject(ctx, stubs[i], b) and tries < max_retries and i + 2 + tries < stubs.len) : (tries += 1) {
            const swap_idx = i + 2 + tries;
            std.mem.swap(u32, &stubs[i + 1], &stubs[swap_idx]);
            b = stubs[i + 1];
        }
        if (reject(ctx, stubs[i], b)) continue;
        try edges.append(gpa, .{ .a = base + @as(usize, stubs[i]), .b = base + @as(usize, b) });
    }
}

/// Drops self-loops (already excluded during pairing) and exact duplicate edges from `edges[0..]`
/// in place via sort + unique-scan — one O(m log m) pass instead of a per-edge hash-map lookup in
/// the generation hot loop. Returns the deduplicated length.
fn dedupeEdgesInPlace(edges: []layout_full.Edge) usize {
    if (edges.len == 0) return 0;
    for (edges) |*e| {
        if (e.a > e.b) std.mem.swap(usize, &e.a, &e.b);
    }
    std.mem.sort(layout_full.Edge, edges, {}, struct {
        fn less(_: void, x: layout_full.Edge, y: layout_full.Edge) bool {
            if (x.a != y.a) return x.a < y.a;
            return x.b < y.b;
        }
    }.less);
    var w: usize = 1;
    for (edges[1..]) |e| {
        if (e.a != edges[w - 1].a or e.b != edges[w - 1].b) {
            edges[w] = e;
            w += 1;
        }
    }
    return w;
}

/// LFR-benchmark-style generator (Lancichinetti-Fortunato-Radicchi): power-law degrees AND
/// power-law community sizes, with a tunable mixing parameter `mu`. Configuration-model
/// internals alone leave clustering near zero (same failure mode as `genScaleFree`); a
/// within-community wedge-closing pass brings local clustering up toward the Wikipedia
/// calibration target. See the module doc comment.
///
/// Node ids `[0, orphan_n)` are reserved orphans (outside every community, degree 0); ids
/// `[orphan_n, n)` are "active" and get degrees + a community. This mirrors `genIslands`, whose
/// orphan singletons are likewise laid down before the real structure.
fn genLfr(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    rand: std.Random,
    spec: Spec,
    edges: *std.ArrayListUnmanaged(layout_full.Edge),
    communities_out: []u32,
) !void {
    const n = spec.n;
    if (n < 2) return;
    const orphan_frac = std.math.clamp(spec.orphan_frac, 0, 0.9);
    const orphan_n: usize = @intFromFloat(@round(@as(f32, @floatFromInt(n)) * orphan_frac));
    const active_n: usize = n - orphan_n;
    if (active_n < 2) return;
    const base: usize = orphan_n;
    const mu: f64 = std.math.clamp(spec.mu, 0, 1);
    // active_n fits comfortably in u32 (n is bounded by usize but never exceeds a few million in
    // practice); node-local ids and degrees stay u32 throughout, only edge/allocation indices are
    // usize.
    const active_n32: u32 = @intCast(active_n);

    // -- 1. degree sequence, rescaled so the realised mean tracks avg_deg --
    const k_min: u32 = @max(1, @as(u32, @intFromFloat(@round(spec.avg_deg * 0.5))));
    // Config-model structural cutoff. Keeps the heaviest hub far below BA's "one note owns a
    // quarter of the vault" failure mode; the planted `tau_degree` still shapes the body of
    // the distribution even though a post-hoc MLE on the truncated tail reads high.
    var k_max: u32 = @intFromFloat(@round(@sqrt(@as(f64, @floatFromInt(active_n)))));
    if (k_max <= k_min) k_max = k_min + 1;
    if (k_max > active_n32 - 1) k_max = @max(k_min, active_n32 - 1);

    const degrees = try arena.alloc(u32, active_n);
    for (degrees) |*d| d.* = drawPowerLawInt(rand, spec.tau_degree, k_min, k_max);
    {
        var sum: u64 = 0;
        for (degrees) |d| sum += d;
        if (sum > 0) {
            const mean = @as(f64, @floatFromInt(sum)) / @as(f64, @floatFromInt(active_n));
            const factor = @as(f64, spec.avg_deg) / mean;
            for (degrees) |*d| {
                var v: i64 = @intFromFloat(@round(@as(f64, @floatFromInt(d.*)) * factor));
                v = std.math.clamp(v, 1, @as(i64, @intCast(active_n32 - 1)));
                d.* = @intCast(v);
            }
        }
    }

    // -- 2. community sizes --
    const cmin = @min(@max(@as(u32, 1), spec.community_min), active_n32);
    const cmax = std.math.clamp(spec.community_max, cmin, active_n32);
    const sizes = try drawCommunitySizes(arena, rand, active_n, spec.tau_community, cmin, cmax);
    if (sizes.len == 0) return;

    // -- 3. assignment: highest-degree nodes into the largest communities --
    const node_order = try arena.alloc(u32, active_n);
    for (node_order, 0..) |*v, i| v.* = @intCast(i);
    std.mem.sort(u32, node_order, degrees, struct {
        fn less(ctx: []const u32, a: u32, b: u32) bool {
            if (ctx[a] != ctx[b]) return ctx[a] > ctx[b];
            return a < b;
        }
    }.less);

    const comm_order = try arena.alloc(u32, sizes.len);
    for (comm_order, 0..) |*v, i| v.* = @intCast(i);
    std.mem.sort(u32, comm_order, sizes, struct {
        fn less(ctx: []const u32, a: u32, b: u32) bool {
            if (ctx[a] != ctx[b]) return ctx[a] > ctx[b];
            return a < b;
        }
    }.less);

    const community_of = try arena.alloc(u32, active_n);
    var cursor: usize = 0;
    for (comm_order) |ci| {
        var taken: u32 = 0;
        while (taken < sizes[ci] and cursor < node_order.len) : (taken += 1) {
            community_of[node_order[cursor]] = ci;
            cursor += 1;
        }
    }
    // Rounding in drawCommunitySizes can leave a handful of nodes unplaced; fold them into the
    // smallest community rather than looping to find a perfect-fit home.
    while (cursor < node_order.len) : (cursor += 1) community_of[node_order[cursor]] = comm_order[comm_order.len - 1];

    for (0..active_n) |i| communities_out[base + i] = community_of[i];

    // Internal degree must be < the node's community size; downgrade rather than retry-loop.
    const internal_deg = try arena.alloc(u32, active_n);
    for (0..active_n) |i| {
        const csize = sizes[community_of[i]];
        var id_: u32 = @intFromFloat(@round((1.0 - mu) * @as(f64, @floatFromInt(degrees[i]))));
        if (id_ > csize - 1) id_ = csize - 1;
        internal_deg[i] = id_;
    }

    // -- 4a. internal edges: configuration-model pairing per community --
    var members = try arena.alloc(std.ArrayListUnmanaged(u32), sizes.len);
    for (members) |*m| m.* = .empty;
    for (0..active_n) |i| try members[community_of[i]].append(arena, @intCast(i));

    const SelfLoopOnly = struct {
        fn reject(_: void, a: u32, b: u32) bool {
            return a == b;
        }
    };
    for (members) |mem| {
        var stubs: std.ArrayListUnmanaged(u32) = .empty;
        for (mem.items) |node| {
            var k: u32 = 0;
            while (k < internal_deg[node]) : (k += 1) try stubs.append(arena, node);
        }
        rand.shuffle(u32, stubs.items);
        try pairStubs(stubs.items, base, edges, gpa, {}, SelfLoopOnly.reject);
    }

    // -- 4a2. close within-community wedges (Holme–Kim style) so local clustering isn't ~0 --
    // Budget ~1.0 mean-degree of extras: enough to push C toward the Wikipedia ~0.27 band
    // while keeping realised avg_deg inside the ±40% acceptance window.
    const wedge_budget: usize = active_n;
    try closeCommunityWedges(gpa, arena, rand, edges, members, community_of, base, wedge_budget);

    // -- 4b. external edges: global pairing, rejecting same-community pairs --
    var ext_stubs: std.ArrayListUnmanaged(u32) = .empty;
    for (0..active_n) |i| {
        const ext = degrees[i] - internal_deg[i];
        var k: u32 = 0;
        while (k < ext) : (k += 1) try ext_stubs.append(arena, @intCast(i));
    }
    rand.shuffle(u32, ext_stubs.items);
    const SameCommunity = struct {
        fn reject(cof: []const u32, a: u32, b: u32) bool {
            return a == b or cof[a] == cof[b];
        }
    };
    try pairStubs(ext_stubs.items, base, edges, gpa, @as([]const u32, community_of), SameCommunity.reject);

    // -- 5. drop self-loops (already excluded above) and deduplicate --
    const new_len = dedupeEdgesInPlace(edges.items);
    edges.shrinkRetainingCapacity(new_len);
}

fn packUndirected(a: u32, b: u32) u64 {
    const lo = @min(a, b);
    const hi = @max(a, b);
    return (@as(u64, hi) << 32) | @as(u64, lo);
}

/// Add edges that close wedges inside each planted community. Pure configuration-model
/// pairing yields almost no triangles once multi-edges collapse; this pass is what makes
/// `lfr` measurably more clustered than `scale-free`. Capped by `budget` so mean degree
/// stays inside the acceptance band.
fn closeCommunityWedges(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    rand: std.Random,
    edges: *std.ArrayListUnmanaged(layout_full.Edge),
    members: []const std.ArrayListUnmanaged(u32),
    community_of: []const u32,
    base: usize,
    budget: usize,
) !void {
    if (budget == 0 or members.len == 0) return;

    var edge_set: std.AutoHashMapUnmanaged(u64, void) = .{};
    defer edge_set.deinit(gpa);
    try edge_set.ensureTotalCapacity(gpa, @intCast(edges.items.len + budget + 8));

    const active_n = community_of.len;
    var adj = try arena.alloc(std.ArrayListUnmanaged(u32), active_n);
    for (adj) |*row| row.* = .empty;

    for (edges.items) |e| {
        if (e.a < base or e.b < base) continue;
        const a: u32 = @intCast(e.a - base);
        const b: u32 = @intCast(e.b - base);
        if (a >= active_n or b >= active_n) continue;
        try edge_set.put(gpa, packUndirected(a, b), {});
        // Only keep same-community adjacencies — wedges across communities are never closed.
        if (community_of[a] != community_of[b]) continue;
        try adj[a].append(arena, b);
        try adj[b].append(arena, a);
    }

    // Round-robin across communities so a few giant ones can't spend the whole budget.
    var added: usize = 0;
    var guard: usize = 0;
    const guard_max = budget * 8 + members.len * 4;
    var ci: usize = 0;
    while (added < budget and guard < guard_max) : (guard += 1) {
        const mem = members[ci % members.len];
        ci += 1;
        if (mem.items.len < 3) continue;
        const u = mem.items[rand.uintLessThan(usize, mem.items.len)];
        const nbrs = adj[u].items;
        if (nbrs.len < 2) continue;
        const i = rand.uintLessThan(usize, nbrs.len);
        var j = rand.uintLessThan(usize, nbrs.len);
        if (j == i) j = (j + 1) % nbrs.len;
        const v = nbrs[i];
        const w = nbrs[j];
        if (v == w) continue;
        if (community_of[v] != community_of[u] or community_of[w] != community_of[u]) continue;
        const key = packUndirected(v, w);
        if (edge_set.contains(key)) continue;
        try edge_set.put(gpa, key, {});
        try edges.append(gpa, .{ .a = base + v, .b = base + w });
        try adj[v].append(arena, w);
        try adj[w].append(arena, v);
        added += 1;
    }
}

/// Union-find components, place each as a sunflower disc, pack discs on an ellipse.
fn packComponents(
    gpa: std.mem.Allocator,
    positions: []dvui.Point,
    edges: []const layout_full.Edge,
    n: usize,
    aspect: f32,
) !usize {
    if (n == 0) return 0;
    var parent = try gpa.alloc(u32, n);
    defer gpa.free(parent);
    var rank = try gpa.alloc(u8, n);
    defer gpa.free(rank);
    for (0..n) |i| {
        parent[i] = @intCast(i);
        rank[i] = 0;
    }
    const Find = struct {
        fn find(p: []u32, x: u32) u32 {
            var cur = x;
            while (p[cur] != cur) {
                p[cur] = p[p[cur]];
                cur = p[cur];
            }
            return cur;
        }
        fn unite(p: []u32, r: []u8, a: u32, b: u32) void {
            var ra = find(p, a);
            var rb = find(p, b);
            if (ra == rb) return;
            if (r[ra] < r[rb]) std.mem.swap(u32, &ra, &rb);
            p[rb] = ra;
            if (r[ra] == r[rb]) r[ra] += 1;
        }
    };
    for (edges) |e| {
        if (e.a >= n or e.b >= n) continue;
        Find.unite(parent, rank, @intCast(e.a), @intCast(e.b));
    }

    var members: std.AutoHashMapUnmanaged(u32, std.ArrayListUnmanaged(u32)) = .{};
    defer {
        var it = members.iterator();
        while (it.next()) |entry| entry.value_ptr.deinit(gpa);
        members.deinit(gpa);
    }
    for (0..n) |i| {
        const root = Find.find(parent, @intCast(i));
        const gop = try members.getOrPut(gpa, root);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(gpa, @intCast(i));
    }

    const comp_n = members.count();
    var roots = try gpa.alloc(u32, comp_n);
    defer gpa.free(roots);
    var size_by_root: std.AutoHashMapUnmanaged(u32, u32) = .{};
    defer size_by_root.deinit(gpa);
    {
        var i: usize = 0;
        var it = members.iterator();
        while (it.next()) |entry| : (i += 1) {
            roots[i] = entry.key_ptr.*;
            try size_by_root.put(gpa, entry.key_ptr.*, @intCast(entry.value_ptr.items.len));
        }
    }
    // Largest first — denser core, loners on the fringe (matches layout_full pack).
    const SortCtx = struct {
        roots: []const u32,
        sz: *const std.AutoHashMapUnmanaged(u32, u32),
        fn less(ctx: @This(), a: usize, b: usize) bool {
            const sa = ctx.sz.get(ctx.roots[a]) orelse 0;
            const sb = ctx.sz.get(ctx.roots[b]) orelse 0;
            return sa > sb;
        }
    };
    var order = try gpa.alloc(usize, comp_n);
    defer gpa.free(order);
    for (0..comp_n) |i| order[i] = i;
    std.mem.sort(usize, order, SortCtx{ .roots = roots, .sz = &size_by_root }, SortCtx.less);

    const slot = hex.layoutSpacingFor(n);
    var total_area: f32 = 0;
    var core_r: f32 = 0;
    var footprints = try gpa.alloc(f32, comp_n);
    defer gpa.free(footprints);
    for (order, 0..) |oi, ii| {
        const sz = size_by_root.get(roots[oi]) orelse 1;
        const r = if (sz == 1)
            slot * 0.5
        else
            slot * @sqrt(@as(f32, @floatFromInt(sz)) / std.math.pi);
        footprints[ii] = r;
        const air = if (sz == 1) slot * lone_air_slots else slot * component_gap_slots;
        const claim = r + air * 0.5;
        total_area += std.math.pi * claim * claim;
        core_r = @max(core_r, claim);
    }
    const a = std.math.clamp(aspect, 1.0 / 3.5, 3.5);
    const isle_r = slot * (0.5 + lone_air_slots * 0.5);
    const axes = packEllipseAxes(a, total_area, core_r, isle_r);

    var area_used: f32 = 0;
    for (order, 0..) |oi, ii| {
        const root = roots[oi];
        const mem = members.getPtr(root) orelse continue;
        const sz = mem.items.len;
        const alone = sz == 1;
        const frac = if (alone) blk: {
            const phase = @mod(@as(f32, @floatFromInt(ii)) * 0.6180339887, 1.0);
            break :blk 0.72 + 0.22 * phase;
        } else @sqrt(std.math.clamp(area_used / @max(total_area, 1), 0, 1));
        const theta = @as(f32, @floatFromInt(ii)) * golden_angle;
        const cx = @cos(theta) * axes.x * frac;
        const cy = @sin(theta) * axes.y * frac;
        const r = footprints[ii];
        const air = if (alone) slot * lone_air_slots else slot * component_gap_slots;
        area_used += std.math.pi * (r + air * 0.5) * (r + air * 0.5);

        if (sz == 1) {
            positions[mem.items[0]] = .{ .x = cx, .y = cy };
        } else {
            for (mem.items, 0..) |note, k| {
                const rk = slot * @sqrt((@as(f32, @floatFromInt(k)) + 0.5) / std.math.pi);
                const th = @as(f32, @floatFromInt(k)) * golden_angle;
                positions[note] = .{ .x = cx + rk * @cos(th), .y = cy + rk * @sin(th) };
            }
        }
    }
    return comp_n;
}

fn packEllipseAxes(a: f32, total_area: f32, core_r: f32, isle_r: f32) struct { x: f32, y: f32 } {
    const area_r = @sqrt(@max(total_area, 1) / std.math.pi);
    const base = @max(area_r, core_r + isle_r);
    if (a >= 1) return .{ .x = base * a, .y = base };
    return .{ .x = base, .y = base / a };
}

test "parse synth spec" {
    const a = try Spec.parse("synth:1000");
    try testing.expectEqual(@as(usize, 1000), a.n);
    try testing.expect(a.shape == .scale_free);

    const b = try Spec.parse("synth:50000:islands:4.5");
    try testing.expectEqual(@as(usize, 50_000), b.n);
    try testing.expect(b.shape == .islands);
    try testing.expect(@abs(b.avg_deg - 4.5) < 1e-4);
}

test "islands synth respects component purity and degree ballpark" {
    const spec = Spec{ .n = 2000, .shape = .islands, .avg_deg = 4, .orphan_frac = 0.1, .island_max = 80 };
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var g = try generate(testing.allocator, arena_state.allocator(), spec);
    defer g.deinit(testing.allocator);
    try testing.expect(g.components > 10);
    try testing.expect(g.avg_deg_actual > 1.5);
    try testing.expect(g.avg_deg_actual < 8);
    try testing.expect(g.positions.len == 2000);
}

test "hub synth pins a dominant degree" {
    const spec = Spec{ .n = 500, .shape = .hub, .avg_deg = 2 };
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var g = try generate(testing.allocator, arena_state.allocator(), spec);
    defer g.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 499), g.max_degree);
    try testing.expectEqual(@as(usize, 1), g.components);
}

test "bridges reduce component count" {
    const base = Spec{ .n = 2000, .shape = .islands, .avg_deg = 4, .orphan_frac = 0.1, .island_max = 80 };

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var no_bridges = try generate(testing.allocator, arena_state.allocator(), base);
    defer no_bridges.deinit(testing.allocator);

    var bridged_spec = base;
    bridged_spec.bridge_frac = 0.05;
    var bridged = try generate(testing.allocator, arena_state.allocator(), bridged_spec);
    defer bridged.deinit(testing.allocator);

    try testing.expect(bridged.components < no_bridges.components);
}

test "bridge_frac is a no-op on an already single-component shape" {
    const spec = Spec{ .n = 500, .shape = .scale_free, .avg_deg = 3, .bridge_frac = 0.2 };
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var g = try generate(testing.allocator, arena_state.allocator(), spec);
    defer g.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), g.components);
}

test "same seed gives identical output" {
    const spec = Spec{
        .n = 1500,
        .shape = .islands,
        .avg_deg = 4,
        .orphan_frac = 0.1,
        .island_max = 80,
        .bridge_frac = 0.05,
        .folder_leak_frac = 0.1,
    };

    var arena_a = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_a.deinit();
    var a = try generate(testing.allocator, arena_a.allocator(), spec);
    defer a.deinit(testing.allocator);

    var arena_b = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_b.deinit();
    var b = try generate(testing.allocator, arena_b.allocator(), spec);
    defer b.deinit(testing.allocator);

    try testing.expectEqual(a.components, b.components);
    try testing.expectEqual(a.edges.len, b.edges.len);
    for (a.edges, b.edges) |ea, eb| {
        try testing.expectEqual(ea.a, eb.a);
        try testing.expectEqual(ea.b, eb.b);
    }
    try testing.expectEqual(a.paths.len, b.paths.len);
    for (a.paths, b.paths) |pa, pb| {
        try testing.expectEqualStrings(pa, pb);
    }
}

test "folder paths correlate with components" {
    const spec = Spec{ .n = 1200, .shape = .islands, .avg_deg = 4, .orphan_frac = 0.05, .island_max = 60, .folder_leak_frac = 0.1 };
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var g = try generate(testing.allocator, arena_state.allocator(), spec);
    defer g.deinit(testing.allocator);

    // Union-find over the (post-bridge) edges to know which notes actually share a component.
    var parent = try testing.allocator.alloc(u32, spec.n);
    defer testing.allocator.free(parent);
    for (0..spec.n) |i| parent[i] = @intCast(i);
    const find = struct {
        fn go(p: []u32, x: u32) u32 {
            var cur = x;
            while (p[cur] != cur) {
                p[cur] = p[p[cur]];
                cur = p[cur];
            }
            return cur;
        }
    }.go;
    for (g.edges) |e| {
        const ra = find(parent, @intCast(e.a));
        const rb = find(parent, @intCast(e.b));
        if (ra != rb) parent[rb] = ra;
    }

    const dirOf = struct {
        fn go(path: []const u8) []const u8 {
            if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| return path[0..i];
            return path;
        }
    }.go;

    var rng = std.Random.DefaultPrng.init(7);
    const rand = rng.random();
    var same_comp_match: usize = 0;
    var same_comp_total: usize = 0;
    var cross_comp_match: usize = 0;
    var cross_comp_total: usize = 0;
    var trials: usize = 0;
    while (trials < 4000) : (trials += 1) {
        const i = rand.uintLessThan(usize, spec.n);
        const j = rand.uintLessThan(usize, spec.n);
        if (i == j) continue;
        const same = find(parent, @intCast(i)) == find(parent, @intCast(j));
        const same_dir = std.mem.eql(u8, dirOf(g.paths[i]), dirOf(g.paths[j]));
        if (same) {
            same_comp_total += 1;
            if (same_dir) same_comp_match += 1;
        } else {
            cross_comp_total += 1;
            if (same_dir) cross_comp_match += 1;
        }
    }

    try testing.expect(same_comp_total > 0);
    try testing.expect(cross_comp_total > 0);
    const same_rate = @as(f32, @floatFromInt(same_comp_match)) / @as(f32, @floatFromInt(same_comp_total));
    const cross_rate = @as(f32, @floatFromInt(cross_comp_match)) / @as(f32, @floatFromInt(cross_comp_total));
    try testing.expect(same_rate > cross_rate);
}

test "lfr: realised mean degree lands near avg_deg" {
    const spec = Spec{ .n = 4000, .shape = .lfr, .avg_deg = 6 };
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var g = try generate(testing.allocator, arena_state.allocator(), spec);
    defer g.deinit(testing.allocator);
    try testing.expect(g.avg_deg_actual > spec.avg_deg * 0.6);
    try testing.expect(g.avg_deg_actual < spec.avg_deg * 1.4);
}

test "lfr: wedge closing produces non-trivial clustering" {
    // Regression for the config-model-only failure mode: without closeCommunityWedges, C≈0.
    // Floor is intentionally below the Wikipedia 0.27 target — that number is denser-regime —
    // but must clear scale-free's ~0.08 so the shape earns its keep.
    const spec = Spec{ .n = 5000, .shape = .lfr, .avg_deg = 6 };
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var g = try generate(testing.allocator, arena_state.allocator(), spec);
    defer g.deinit(testing.allocator);

    // Local clustering, sampled — mirrors bench_stats.clusteringCoefficient.
    var adj = try testing.allocator.alloc(std.ArrayListUnmanaged(u32), g.positions.len);
    defer {
        for (adj) |*row| row.deinit(testing.allocator);
        testing.allocator.free(adj);
    }
    for (adj) |*row| row.* = .empty;
    var edge_set: std.AutoHashMapUnmanaged(u64, void) = .{};
    defer edge_set.deinit(testing.allocator);
    for (g.edges) |e| {
        try adj[e.a].append(testing.allocator, @intCast(e.b));
        try adj[e.b].append(testing.allocator, @intCast(e.a));
        try edge_set.put(testing.allocator, packUndirected(@intCast(e.a), @intCast(e.b)), {});
    }
    var sum_c: f64 = 0;
    var cnt: usize = 0;
    var i: usize = 0;
    while (i < g.positions.len and cnt < 2000) : (i += 1) {
        const d = adj[i].items.len;
        if (d < 2 or d > 400) continue;
        var connected: u64 = 0;
        var p: usize = 0;
        while (p < adj[i].items.len) : (p += 1) {
            var q = p + 1;
            while (q < adj[i].items.len) : (q += 1) {
                if (edge_set.contains(packUndirected(adj[i].items[p], adj[i].items[q]))) connected += 1;
            }
        }
        const denom = @as(f64, @floatFromInt(d * (d - 1)));
        sum_c += 2.0 * @as(f64, @floatFromInt(connected)) / denom;
        cnt += 1;
    }
    try testing.expect(cnt > 100);
    const avg = sum_c / @as(f64, @floatFromInt(cnt));
    try testing.expect(avg > 0.12);
}

test "lfr: every planted community is non-empty" {
    const spec = Spec{ .n = 3000, .shape = .lfr, .avg_deg = 5 };
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var g = try generate(testing.allocator, arena_state.allocator(), spec);
    defer g.deinit(testing.allocator);

    var max_id: u32 = 0;
    var any_planted = false;
    for (g.communities) |c| {
        if (c == orphan_community) continue;
        any_planted = true;
        max_id = @max(max_id, c);
    }
    try testing.expect(any_planted);

    const counts = try testing.allocator.alloc(u32, max_id + 1);
    defer testing.allocator.free(counts);
    @memset(counts, 0);
    for (g.communities) |c| {
        if (c == orphan_community) continue;
        counts[c] += 1;
    }
    for (counts) |cnt| try testing.expect(cnt > 0);
}

test "lfr: determinism for a fixed seed" {
    const spec = Spec{ .n = 2500, .shape = .lfr, .avg_deg = 5, .seed = 12345 };

    var arena_a = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_a.deinit();
    var a = try generate(testing.allocator, arena_a.allocator(), spec);
    defer a.deinit(testing.allocator);

    var arena_b = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_b.deinit();
    var b = try generate(testing.allocator, arena_b.allocator(), spec);
    defer b.deinit(testing.allocator);

    try testing.expectEqual(a.edges.len, b.edges.len);
    for (a.edges, b.edges) |ea, eb| {
        try testing.expectEqual(ea.a, eb.a);
        try testing.expectEqual(ea.b, eb.b);
    }
    try testing.expectEqual(a.communities.len, b.communities.len);
    for (a.communities, b.communities) |ca, cb| try testing.expectEqual(ca, cb);
}

test "lfr: no self-loops" {
    const spec = Spec{ .n = 3000, .shape = .lfr, .avg_deg = 6 };
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var g = try generate(testing.allocator, arena_state.allocator(), spec);
    defer g.deinit(testing.allocator);
    for (g.edges) |e| try testing.expect(e.a != e.b);
}

test "lfr: mu = 0 produces no cross-community edges" {
    // community_max stays far above sqrt(n) so no node's internal-degree target is clamped down
    // by a too-small community — otherwise even mu=0 would be forced to spill some links out.
    const spec = Spec{ .n = 2000, .shape = .lfr, .avg_deg = 4, .mu = 0 };
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var g = try generate(testing.allocator, arena_state.allocator(), spec);
    defer g.deinit(testing.allocator);

    for (g.edges) |e| {
        const ca = g.communities[e.a];
        const cb = g.communities[e.b];
        if (ca == orphan_community or cb == orphan_community) continue;
        try testing.expectEqual(ca, cb);
    }
}

test "lfr shape is parsed from both spellings" {
    const a = try Shape.parse("lfr");
    try testing.expect(a == .lfr);
    const b = try Shape.parse("realistic");
    try testing.expect(b == .lfr);
}

test "non-lfr shapes fill communities with the orphan sentinel" {
    const spec = Spec{ .n = 500, .shape = .scale_free, .avg_deg = 3 };
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var g = try generate(testing.allocator, arena_state.allocator(), spec);
    defer g.deinit(testing.allocator);
    for (g.communities) |c| try testing.expectEqual(orphan_community, c);
}

test "synthContentGraph produces a well-formed document graph" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var rng = std.Random.DefaultPrng.init(42);
    const spec = DocSpec{ .heading_min = 5, .heading_max = 12, .max_depth = 4, .tags_max = 4, .embeds_max = 2 };
    const g = try synthContentGraph(arena_state.allocator(), rng.random(), spec);

    try testing.expect(g.items.len > 1);
    try testing.expectEqual(content_graph.ItemKind.root, g.items[0].kind);

    var counts = [_]usize{0} ** 9; // indexed by @intFromEnum(ItemKind)
    for (g.items) |it| counts[@intFromEnum(it.kind)] += 1;
    try testing.expect(counts[@intFromEnum(content_graph.ItemKind.heading)] > 0);
    try testing.expect(counts[@intFromEnum(content_graph.ItemKind.paragraph)] > 0);

    // Only .outline edges in this pass.
    for (g.edges) |e| try testing.expect(e.kind == .outline);

    // Every non-root item is reachable back to root via outline edges (no orphaned subtrees):
    // walk each item's parent chain and confirm it terminates at root index 0.
    var parent_of = try testing.allocator.alloc(?u32, g.items.len);
    defer testing.allocator.free(parent_of);
    @memset(parent_of, null);
    for (g.edges) |e| parent_of[e.b] = e.a;

    for (1..g.items.len) |i| {
        var cur: u32 = @intCast(i);
        var hops: usize = 0;
        while (cur != 0) {
            cur = parent_of[cur] orelse return error.OrphanedItem;
            hops += 1;
            try testing.expect(hops < g.items.len); // guard against a cycle
        }
    }
}

test "synthContentGraph is deterministic for a fixed seed" {
    const spec = DocSpec{ .heading_min = 6, .heading_max = 20, .max_depth = 5, .tags_max = 5, .embeds_max = 3 };

    var arena_a = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_a.deinit();
    var rng_a = std.Random.DefaultPrng.init(777);
    const a = try synthContentGraph(arena_a.allocator(), rng_a.random(), spec);

    var arena_b = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_b.deinit();
    var rng_b = std.Random.DefaultPrng.init(777);
    const b = try synthContentGraph(arena_b.allocator(), rng_b.random(), spec);

    try testing.expectEqual(a.items.len, b.items.len);
    for (a.items, b.items) |ia, ib| {
        try testing.expectEqual(ia.id, ib.id);
        try testing.expectEqual(ia.kind, ib.kind);
        try testing.expectEqual(ia.level, ib.level);
        try testing.expectEqual(ia.line, ib.line);
        try testing.expectEqual(ia.weight, ib.weight);
        try testing.expectEqualStrings(ia.text, ib.text);
    }
    try testing.expectEqual(a.edges.len, b.edges.len);
    for (a.edges, b.edges) |ea, eb| {
        try testing.expectEqual(ea.a, eb.a);
        try testing.expectEqual(ea.b, eb.b);
        try testing.expectEqual(ea.kind, eb.kind);
    }
}

test "flatHeadingsExtreme produces exactly the giant-2.md shape" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var rng = std.Random.DefaultPrng.init(1);
    const spec = DocSpec.flatHeadingsExtreme();
    const g = try synthContentGraph(arena_state.allocator(), rng.random(), spec);

    const n = spec.heading_min;
    try testing.expectEqual(n, spec.heading_max);
    try testing.expectEqual(@as(usize, 1 + n * 2), g.items.len); // root + N headings + N paragraphs

    try testing.expectEqual(content_graph.ItemKind.root, g.items[0].kind);

    var heading_count: usize = 0;
    var paragraph_count: usize = 0;
    for (g.items[1..]) |it| {
        switch (it.kind) {
            .heading => {
                heading_count += 1;
                try testing.expectEqual(@as(u32, 1), it.level);
            },
            .paragraph => paragraph_count += 1,
            else => return error.UnexpectedItemKind,
        }
    }
    try testing.expectEqual(@as(usize, n), heading_count);
    try testing.expectEqual(@as(usize, n), paragraph_count);

    // Every heading is a direct outline-child of root, and has exactly one paragraph child.
    var child_count = try testing.allocator.alloc(u32, g.items.len);
    defer testing.allocator.free(child_count);
    @memset(child_count, 0);
    for (g.edges) |e| {
        try testing.expect(e.kind == .outline);
        child_count[e.a] += 1;
        if (g.items[e.a].kind == .heading) {
            try testing.expectEqual(content_graph.ItemKind.paragraph, g.items[e.b].kind);
        } else {
            try testing.expectEqual(content_graph.ItemKind.heading, g.items[e.b].kind);
            try testing.expectEqual(@as(u32, 0), e.a); // only root parents headings here
        }
    }
    for (g.items, 0..) |it, i| {
        if (it.kind == .heading) try testing.expectEqual(@as(u32, 1), child_count[i]);
    }
}
