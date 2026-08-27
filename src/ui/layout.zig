//! Where notes actually are.
//!
//! This is the layout, and under the positions-first design it owns the truth: a note's position
//! is decided here, by its links, and everything downstream *derives* from it. `spatial.zig`
//! groups these positions for drawing; `world.zig` decides which groups a given zoom shows. The
//! old arrangement ran the other way — `fold` built a link-derived tree and `containment` placed
//! each note inside its parent's disc — which meant a note had no position of its own, only a
//! slot in whichever cell happened to claim it. That is why notes travelled across the screen as
//! you zoomed, and why the map felt nebulous until you were all the way in.
//!
//! The forces, in the order they matter:
//!
//!   * **Links attract.** Weight is degree-normalised (`w·K/√(dₐ·d_b)`), because a link to a
//!     29,448-degree hub is nearly no evidence of relatedness while a link between two obscure
//!     notes is strong evidence. Measured at ~30% tighter local link spread than raw weights.
//!   * **Everything repels, at short range**, so notes do not pile up — the "bubbles" behaviour.
//!   * **Folder position is a weak tie between orphans only** (`folder_w` against ~1.0 for a real
//!     link), so the notes with no links at all cluster by directory instead of scattering, and
//!     folders never get a say where links already have one.
//!
//! The solve is multilevel (`multilevel.zig`): coarsen, solve the small graph, project down,
//! refine. A single-level solve cannot produce structure larger than the range of its forces,
//! which is the "one massive undifferentiated blob" failure.
//!
//! Two things happen after the solve that the solver cannot do for itself:
//!
//!   * **Each component is scaled to world units before anything is packed.** `multilevel` emits
//!     unit space (~one note per unit); the rest of Atlas is calibrated in note radii. The scale
//!     is chosen so the component's own median leaf spacing is `spacing` note radii — that is
//!     what keeps two notes drawn at radius `r` from overlapping (`< 2r` is overlap by
//!     construction; the old layout sat at 0.95x and sibling overlap was immovable). It has to
//!     happen *per island, before packing*: mixing unit-space cluster radii with a world-space
//!     island margin, then scaling the whole map by the leaf median, multiplies every gap by
//!     `note_r` and sits a linked pair on top of itself while the next island lands tens of
//!     leaf-spacings away. A Wikipedia-scale vault is one component, so it never hit this; a
//!     personal vault of a few dozen notes is almost all islands, and did.
//!   * **Components are then packed as a cloud of discs.** `multilevel`'s repulsion is cut off at
//!     a few times the node spacing, so it cannot hold two unconnected islands apart — they would
//!     drift through each other and a proximity hierarchy would then put them in the same cell.
//!     Packing is the only place the "islands never share a cell" guarantee can be re-established,
//!     because it is the only place that knows the islands are separate. There are no links
//!     between components, so the macro shape is a blob, not a golden-angle spiral. Radii and the
//!     gap between them are world units, same as the positions.

const std = @import("std");
const dvui = @import("dvui");

const fold = @import("fold.zig");
const multilevel = @import("multilevel.zig");
const spatial = @import("spatial.zig");
const louvain = @import("louvain.zig");
const shape_metrics = @import("shape_metrics.zig");
const radix = @import("radix.zig");

pub const Vec2 = spatial.Vec2;
pub const Edge = fold.Edge;

/// Target distance between neighbouring notes, in note radii.
///
/// Above 2.0 because two discs of radius `r` overlap whenever they sit closer than `2r` — the
/// margin above that is what keeps the *tenth* percentile clear, not just the median. `world`
/// exports this as `leaf_pitch`: it is now a chosen number that the solve is calibrated to hit,
/// where it used to be an empirical measurement of `containment`'s settle.
pub const default_spacing: f32 = 2.6;

pub const Options = struct {
    /// World radius one note draws at. Positions come out scaled against this.
    note_r: f32 = 1.0,
    /// Target median distance between neighbouring notes, in note radii. Must exceed 2.0 or
    /// adjacent notes overlap by construction — see the module header. The margin above 2.0 is
    /// what keeps the *tenth* percentile clear, not just the median.
    spacing: f32 = default_spacing,
    /// Stable id per note, for `reuse` to match against across solves. Empty falls back to the
    /// note's index, which is only sound when the note set cannot change — tests and the harness.
    ids: []const u64 = &.{},
    /// Exponent on the degree normalisation; 0 disables it, 0.5 is the Salton cosine.
    degree_norm: f32 = 0.5,
    /// Tie strength along the orphan folder chain, against ~1.0 for a real link.
    folder_w: f32 = 0.25,
    /// Extra gap between packed component discs, as a linear factor on one leaf pitch.
    /// Charged between peers, never as a scale on the whole vault — a Wikipedia-sized giant
    /// must not be pushed out by √gap.
    pack_gap: f32 = 1.15,
    /// Lay the vault out as **territories**: cluster into bounded communities, solve each one's
    /// interior in its own frame, and place the frames as packed discs with ocean between them,
    /// recursively.
    ///
    /// The default. What it buys over one global force solve, measured on simplewiki: co-citation
    /// 0.00x -> 6.58x, link spread 0.124r -> 0.215r, overlap 33% -> 13.4%, radial density 89% ->
    /// 33%, and — the number the whole design exists for — one added link moves the median note 588
    /// note radii under a global solve and 134 under this one. What it costs is crossings: 14.4% of
    /// links span a quarter of the vault against 33% here, which is the seam a rigid frame leaves
    /// and is the honest remaining debt.
    ///
    /// A component the classifier calls a lattice keeps its shape instead — see `isLattice`.
    territories: bool = true,
    /// Largest territory, in notes, before it is subdivided by re-clustering. See
    /// `region_max_default`.
    region_max: u32 = region_max_default,
    /// Smallest territory, in notes, before it is absorbed into a neighbour. See
    /// `region_min_default`.
    region_min: u32 = region_min_default,
    /// Louvain resolution. Above 1 favours many small communities over few large ones.
    resolution: f64 = 1.0,
    /// Most discs placed in one frame before the placement nests another level. See
    /// `frame_max_default` for the trade this sets.
    frame_max: usize = frame_max_default,
    /// Largest component that is treated as *dust* — distributed through the map's gaps rather
    /// than packed as an island of its own. See `redistributeOrphans`.
    dust_max: u32 = 8,
    iters: multilevel.Opts = .{},
    cancel: ?*std.atomic.Value(bool) = null,
    /// The previous solve's interiors, to be reused wherever a territory came back identical.
    ///
    /// **Memoisation, not seeding.** The plan forbids seeding the *clustering* from last time, and
    /// rightly: a partition that depends on history diverges from what a cold open produces, and
    /// then the map you closed is not the map you reopen. This is a different thing. A territory's
    /// interior is a deterministic function of its own subgraph, so when the subgraph comes back
    /// byte-identical the answer is too — reusing it is skipping a computation whose result is
    /// already known, and a cold open reproduces it exactly.
    ///
    /// Identity is by membership hash, checked per territory, so this needs no dirty set and
    /// cannot be wrong about what changed: it is the *inputs* that are compared, not a claim about
    /// them.
    reuse: ?Reuse = null,
};

/// Per-note interior state from a previous `solve`, for `Options.reuse`.
///
/// Carries its own `ids` because a note's *index* is not stable across solves: the caller orders
/// notes by id each rebuild, so inserting one note shifts every index after it. Keyed by index
/// alone, the memo would quietly compare one note's territory against another's. `solve` builds the
/// id → previous-index map itself.
pub const Reuse = struct {
    /// Stable id of each note, in the previous solve's index order.
    ids: []const u64 = &.{},
    /// Each note's offset from its territory's centre.
    inner: []const Vec2 = &.{},
    /// Hash of the membership of the territory each note was in.
    home: []const u64 = &.{},
    /// Where each disc sat inside its frame, keyed by (frame, disc) rather than by index — the
    /// same reasoning as `ids`, one level up. See `FrameSlot`.
    frames: []const FrameSlot = &.{},
};

/// One disc's place inside one frame, from a previous solve.
///
/// `frame` hashes everything the placement is a function of — the members' own signatures, their
/// radii, and the weights between them — so an equal key means equal inputs and the stored offsets
/// are what solving again would produce. `sig` identifies the disc within it: a territory by its
/// membership, a group by its children's signatures.
pub const FrameSlot = struct {
    frame: u64,
    sig: u64,
    x: f32,
    y: f32,
};

pub const Result = struct {
    /// One position per note, in world units.
    pos: []Vec2 = &.{},
    /// Which connected component each note landed in. Components are disjoint discs, so this is
    /// what lets `spatial.build` keep islands out of each other's cells.
    comp: []u32 = &.{},
    n_comp: u32 = 0,
    /// Each note's offset from its territory's centre, and the membership hash of that territory.
    /// Hand both back as `Options.reuse` on the next solve — see `Reuse`.
    inner: []Vec2 = &.{},
    home: []u64 = &.{},
    frames: []FrameSlot = &.{},
    /// The `Options.ids` this solve ran with, copied so the whole `Reuse` can be handed back
    /// without the caller keeping the id array alive separately.
    ids: []u64 = &.{},
    /// Median gap between Hilbert-consecutive notes, in note radii — `spatial.medianSpacing`.
    ///
    /// A *proxy* for leaf spacing, and it reads high: the curve does not always visit a point's
    /// nearest neighbour next, so the gaps it measures are nearest-neighbour distance or more. On
    /// territories it lands around 3.1-3.5 against interiors calibrated to `Options.spacing` of
    /// 2.6. Overlap is decided by whoever is actually closest, which is what `solveInteriors`
    /// scales against (`nearestNeighbourMedian`) and what the harness's `ovlp` column measures
    /// independently — so this staying above `spacing` is the expected reading, not a miss.
    spacing: f32 = 0,

    pub fn deinit(self: *Result, gpa: std.mem.Allocator) void {
        gpa.free(self.pos);
        gpa.free(self.comp);
        gpa.free(self.inner);
        gpa.free(self.home);
        gpa.free(self.ids);
        gpa.free(self.frames);
        self.* = .{};
    }
};

pub fn solve(
    gpa: std.mem.Allocator,
    n_notes: usize,
    links: []const Edge,
    paths: []const []const u8,
    opts: Options,
) !Result {
    reused_interiors = 0;
    solved_interiors = 0;
    var memo: FrameMemo = .{ .gpa = gpa };
    defer {
        memo.prev.deinit(gpa);
        memo.out.deinit(gpa);
    }
    if (opts.reuse) |r| {
        memo.prev.ensureTotalCapacity(gpa, @intCast(r.frames.len)) catch {};
        for (r.frames) |f| {
            memo.prev.putAssumeCapacity(FrameMemo.slotKey(f.frame, f.sig), .{ .x = f.x, .y = f.y });
        }
    }
    var out: Result = .{};
    errdefer out.deinit(gpa);
    out.pos = try gpa.alloc(Vec2, n_notes);
    out.comp = try gpa.alloc(u32, n_notes);
    out.inner = try gpa.alloc(Vec2, n_notes);
    out.home = try gpa.alloc(u64, n_notes);
    out.ids = try gpa.alloc(u64, n_notes);
    for (out.ids, 0..) |*d, i| d.* = if (opts.ids.len > i) opts.ids[i] else i;
    if (n_notes == 0) return out;
    @memset(out.inner, .{});
    @memset(out.home, 0);
    @memset(out.pos, .{});
    @memset(out.comp, 0);
    if (n_notes == 1) return out;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // -- the edge set the solve sees ---------------------------------------------------
    // Degree normalisation applies to real links only. The orphan chain is appended afterwards at
    // its own flat weight, so normalising cannot dilute it and it cannot dilute the links.
    const weighted = try fold.degreeNormalised(arena, n_notes, links, opts.degree_norm);
    var aug: std.ArrayListUnmanaged(Edge) = .empty;
    try aug.ensureTotalCapacity(arena, weighted.len + n_notes);
    aug.appendSliceAssumeCapacity(weighted);
    // Deliberately the orphan drawer and not `addPathChain`: a chain over *every* note would fuse
    // the whole vault into one component and there would be nothing left to pack.
    //
    // Guarded on having a path per note because the chain sorts orphans *by* path — a short or
    // absent path array reads out of bounds, and synthetic corpora supply none.
    if (paths.len == n_notes) {
        try fold.addOrphanDrawer(arena, &aug, paths, links, n_notes, opts.folder_w);
    }
    const edges = aug.items;

    out.n_comp = try fold.linkComponents(arena, out.comp, edges, n_notes);

    // -- group notes and edges by component --------------------------------------------
    const notes_csr = try bucket(arena, out.comp, out.n_comp, n_notes);
    const edge_comp = try arena.alloc(u32, edges.len);
    for (edge_comp, edges) |*c, e| c.* = out.comp[e.a];
    const edges_csr = try bucket(arena, edge_comp, out.n_comp, edges.len);

    // `local[note]` is that note's index within its own component's solve.
    const local = try arena.alloc(u32, n_notes);
    for (0..out.n_comp) |c| {
        for (notes_csr.slice(@intCast(c)), 0..) |note, i| local[note] = @intCast(i);
    }

    // -- solve each component on its own ------------------------------------------------
    const centres = try arena.alloc(Vec2, out.n_comp);
    const radii = try arena.alloc(f32, out.n_comp);
    var sub_edges: std.ArrayListUnmanaged(multilevel.Edge) = .empty;
    var sub_pos: std.ArrayListUnmanaged(dvui.Point) = .empty;

    for (0..out.n_comp) |c| {
        if (opts.cancel) |k| if (k.load(.monotonic)) return error.Canceled;
        const members = notes_csr.slice(@intCast(c));
        centres[c] = .{};
        radii[c] = opts.note_r;
        if (members.len == 0) continue;
        if (members.len == 1) {
            out.pos[members[0]] = .{};
            continue;
        }

        if (opts.territories) {
            radii[c] = try placeComponentTerritories(
                gpa,
                arena,
                members,
                local,
                edges,
                edges_csr.slice(@intCast(c)),
                out.pos,
                out.inner,
                out.home,
                &memo,
                opts,
            );
            continue;
        }

        sub_edges.clearRetainingCapacity();
        for (edges_csr.slice(@intCast(c))) |ei| {
            const e = edges[ei];
            try sub_edges.append(arena, .{ .a = local[e.a], .b = local[e.b], .w = e.w });
        }
        try sub_pos.resize(arena, members.len);
        var sub_opts = opts.iters;
        sub_opts.cancel = opts.cancel;
        try multilevel.solve(arena, members.len, sub_edges.items, sub_pos.items, sub_opts);

        // Recentre on the component's own centroid and record the disc that contains it, so the
        // pack below can treat each component as a single circle.
        var cx: f64 = 0;
        var cy: f64 = 0;
        for (sub_pos.items) |p| {
            cx += p.x;
            cy += p.y;
        }
        const inv = 1.0 / @as(f64, @floatFromInt(members.len));
        const ctr: Vec2 = .{ .x = @floatCast(cx * inv), .y = @floatCast(cy * inv) };
        var rmax: f32 = 0;
        for (members, sub_pos.items) |note, p| {
            const q: Vec2 = .{ .x = p.x - ctr.x, .y = p.y - ctr.y };
            out.pos[note] = q;
            rmax = @max(rmax, @sqrt(q.x * q.x + q.y * q.y));
        }
        radii[c] = rmax;

        // Unit space → world, using this island's own leaves. A later global scale would
        // recouple island gaps into the median and undo the point of packing in world units.
        const target = opts.spacing * opts.note_r;
        const med = if (members.len == n_notes)
            try spatial.medianSpacing(gpa, out.pos, out.comp)
        else
            try componentMedian(gpa, arena, out.pos, members);
        if (med > 0 and target > 0) {
            const s = target / med;
            for (members) |note| {
                out.pos[note].x *= s;
                out.pos[note].y *= s;
            }
            radii[c] *= s;
        }
    }

    // Pack against where each island's notes *are*, not where its furthest one is.
    //
    // A component's radius was the distance to its outermost note. On a vault with one giant and a
    // scatter of pairs, that is the giant's sparse fringe — thousands of world units beyond the
    // dense mass — and `separateDiscs` dutifully places every small island just outside it. The
    // islands end up a screen away from anything, invisible at overview, and they set the extent
    // the camera fits to, so the part of the map with 99% of the notes in it is squeezed into a
    // corner. That is what the reader sees as "orphans float off somewhere unfindable".
    //
    // A high percentile is the honest radius for packing: it tracks the mass rather than the tail.
    // The handful of notes outside it are in the sparsest part of the island, which is exactly
    // where a neighbouring island can sit without looking crowded.
    for (0..out.n_comp) |c| {
        const members = notes_csr.slice(@intCast(c));
        if (members.len < 2) continue;
        radii[c] = @max(robustRadius(arena, out.pos, members) catch radii[c], opts.note_r);
    }
    try packComponents(arena, out, notes_csr, radii, centres, opts);
    try redistributeOrphans(arena, out, links, opts);
    recentre(out.pos);
    out.frames = try memo.out.toOwnedSlice(gpa);
    reused_frames = memo.hits;
    placed_frames = memo.total;
    out.spacing = if (opts.note_r > 0)
        (try spatial.medianSpacing(gpa, out.pos, out.comp)) / opts.note_r
    else
        0;
    return out;
}

/// Distance from an island's centroid that contains all but its sparsest fringe.
///
/// The 99th percentile rather than the maximum: see the call site in `solve` for why the maximum is
/// the wrong number to pack against.
fn robustRadius(arena: std.mem.Allocator, pos: []const Vec2, members: []const u32) !f32 {
    if (members.len == 0) return 0;
    var cx: f64 = 0;
    var cy: f64 = 0;
    for (members) |m| {
        cx += pos[m].x;
        cy += pos[m].y;
    }
    const inv = 1.0 / @as(f64, @floatFromInt(members.len));
    const ctr: Vec2 = .{ .x = @floatCast(cx * inv), .y = @floatCast(cy * inv) };

    const d = try arena.alloc(f32, members.len);
    defer arena.free(d);
    for (members, d) |m, *v| {
        const dx = pos[m].x - ctr.x;
        const dy = pos[m].y - ctr.y;
        v.* = @sqrt(dx * dx + dy * dy);
    }
    std.mem.sort(f32, d, {}, std.sort.asc(f32));
    return d[(d.len * 99) / 100];
}

/// Widest the orphan-placement grid may be, in cells. Bounds the memory and, more usefully, keeps
/// a "free cell" meaning a gap a note can actually sit in.
const grid_side_max: f32 = 1400;

/// Move notes that link to nothing out of their own island and into the map's empty space.
///
/// `fold.addOrphanDrawer` hangs every unlinked note off a single hub so that the coarsener has
/// *something* to group them by. That gives them positions, and it also gives them their own
/// component — so the layout packs them as one more island, off to the side of everything else. On
/// a 284k vault that island is thousands of notes wide, it sets the extent the camera fits to, and
/// a reader looking for one of them has to know to go and find the clump. Worse, it is a claim: it
/// says these notes belong *together*, when the only thing true of them is that each belongs with
/// nothing.
///
/// Being unfiled is not the same as being related to the other unfiled things. So they are placed
/// the way the rest of the map is placed — spread through it, in the gaps between the groups that
/// do have structure. An orphan sits beside real notes, is findable at any zoom because it is
/// wherever you happen to be looking, and contributes nothing to the extent.
///
/// The cells chosen are *free cells that touch an occupied one*: the ocean at a group's edge,
/// rather than the empty middle of nowhere. Deterministic — cell order and the assignment into it
/// are pure functions of the positions and the note order — so a cold open reproduces it.
fn redistributeOrphans(
    arena: std.mem.Allocator,
    out: Result,
    links: []const Edge,
    opts: Options,
) !void {
    const n = out.pos.len;
    if (n == 0) return;
    const pitch = opts.spacing * opts.note_r;
    if (!(pitch > 0)) return;

    const linked = try arena.alloc(bool, n);
    defer arena.free(linked);
    @memset(linked, false);
    for (links) |e| {
        if (e.a < n) linked[e.a] = true;
        if (e.b < n) linked[e.b] = true;
    }

    // Tiny islands are dust too.
    //
    // A pair of notes that link to each other and to nothing else is not an island in any sense a
    // reader cares about — it is two notes. Packed as its own disc it lands out at the giant's
    // bounding radius, invisible at overview, and it drags the extent out with it. The only thing
    // separating it from an orphan is that it has one link, which says something about the pair
    // and nothing about where the pair belongs.
    const comp_size = try arena.alloc(u32, out.n_comp);
    defer arena.free(comp_size);
    @memset(comp_size, 0);
    for (out.comp) |c| comp_size[c] += 1;

    // Dust: an unlinked note, or a whole component small enough to be one.
    const dust = try arena.alloc(bool, n);
    defer arena.free(dust);
    var n_orphan: usize = 0;
    var n_linked: usize = 0;
    for (linked, out.comp, dust, 0..) |l, c, *d, i| {
        _ = i;
        d.* = !l or comp_size[c] <= opts.dust_max;
        if (d.*) n_orphan += 1 else n_linked += 1;
    }
    // Nothing to move, or nothing to move it *among* — a vault that is all orphans has no map to
    // distribute them through, and the island they already form is the honest picture of it.
    if (n_orphan == 0 or n_linked < n_orphan) return;

    // Occupancy over the linked notes only, one cell per note pitch.
    var lo: Vec2 = .{ .x = std.math.floatMax(f32), .y = std.math.floatMax(f32) };
    var hi: Vec2 = .{ .x = -std.math.floatMax(f32), .y = -std.math.floatMax(f32) };
    for (out.pos, dust) |p, d| {
        if (d) continue;
        lo.x = @min(lo.x, p.x);
        lo.y = @min(lo.y, p.y);
        hi.x = @max(hi.x, p.x);
        hi.y = @max(hi.y, p.y);
    }
    if (!(hi.x > lo.x) or !(hi.y > lo.y)) return;

    // Cell size follows the *map*, not the note pitch. A Wikipedia-sized vault spans about 5,400
    // note pitches on a side, which is 29M cells — so a grid at note resolution silently bailed out
    // on the one vault this exists for. A coarser cell is also the better question to ask: a free
    // cell then means a gap genuinely big enough to drop a note into, rather than the sliver
    // between two neighbours.
    const span = @max(hi.x - lo.x, hi.y - lo.y);
    const cell = @max(pitch, span / grid_side_max);
    const w: usize = @intFromFloat(@floor((hi.x - lo.x) / cell) + 3);
    const h: usize = @intFromFloat(@floor((hi.y - lo.y) / cell) + 3);
    if (w < 3 or h < 3) return;

    const owner = try arena.alloc(u32, w * h);
    defer arena.free(owner);
    @memset(owner, std.math.maxInt(u32));
    const cellOf = struct {
        fn f(p: Vec2, o: Vec2, pit: f32, ww: usize, hh: usize) usize {
            const cx: usize = @intFromFloat(std.math.clamp((p.x - o.x) / pit + 1, 0, @as(f32, @floatFromInt(ww - 1))));
            const cy: usize = @intFromFloat(std.math.clamp((p.y - o.y) / pit + 1, 0, @as(f32, @floatFromInt(hh - 1))));
            return cy * ww + cx;
        }
    }.f;
    for (out.pos, dust, 0..) |p, d, i| {
        if (d) continue;
        const c = cellOf(p, lo, cell, w, h);
        if (owner[c] == std.math.maxInt(u32)) owner[c] = @intCast(i);
    }

    // Free cells with an occupied neighbour: the ocean at the edge of a group.
    var shore: std.ArrayListUnmanaged(u32) = .empty;
    defer shore.deinit(arena);
    for (1..h - 1) |cy| {
        for (1..w - 1) |cx| {
            const c = cy * w + cx;
            if (owner[c] != std.math.maxInt(u32)) continue;
            const near = owner[c - 1] != std.math.maxInt(u32) or
                owner[c + 1] != std.math.maxInt(u32) or
                owner[c - w] != std.math.maxInt(u32) or
                owner[c + w] != std.math.maxInt(u32);
            if (near) try shore.append(arena, @intCast(c));
        }
    }
    // Count the groups first: every unlinked note is its own, every small component is one.
    var n_groups: usize = 0;
    {
        const counted = try arena.alloc(bool, out.n_comp);
        defer arena.free(counted);
        @memset(counted, false);
        for (0..n) |i| {
            if (!dust[i]) continue;
            if (!linked[i]) {
                n_groups += 1;
            } else if (!counted[out.comp[i]]) {
                counted[out.comp[i]] = true;
                n_groups += 1;
            }
        }
    }
    // Not enough room to give each group its own gap. Distributing anyway means stacking groups on
    // one cell, which is how a seventeen-note vault came back with 72% of its notes overlapping.
    if (n_groups == 0 or shore.items.len < n_groups) return;

    // Inner gaps first.
    //
    // The shore includes the map's whole outer rim, and spreading dust around it rings the vault:
    // the extent grows back, the density moves outward, and the notes that link to each other end
    // up further apart in relative terms — measured as link spread 0.235r -> 0.366r. Sorting by
    // distance from the centre and drawing from the near end puts dust in the holes *inside* the
    // mass, which is where a reader is already looking.
    const mid: Vec2 = .{ .x = (lo.x + hi.x) * 0.5, .y = (lo.y + hi.y) * 0.5 };
    const Sorter = struct {
        lo: Vec2,
        cell: f32,
        w: usize,
        mid: Vec2,
        fn closer(ctx: @This(), a: u32, b: u32) bool {
            return ctx.d2(a) < ctx.d2(b);
        }
        fn d2(ctx: @This(), c: u32) f32 {
            const cx = @as(f32, @floatFromInt(c % ctx.w)) - 1;
            const cy = @as(f32, @floatFromInt(c / ctx.w)) - 1;
            const x = ctx.lo.x + cx * ctx.cell - ctx.mid.x;
            const y = ctx.lo.y + cy * ctx.cell - ctx.mid.y;
            return x * x + y * y;
        }
    };
    std.mem.sort(u32, shore.items, Sorter{ .lo = lo, .cell = cell, .w = w, .mid = mid }, Sorter.closer);
    // Draw from the innermost band rather than the first `n_groups` outright, so the dust is spread
    // through the interior instead of packed into one hole at the centre.
    const usable = @min(shore.items.len, n_groups * 4);

    // Spread across the whole shore rather than filling it from one corner, so the orphans dust the
    // map evenly instead of banking up along one side of it.
    // A whole dust component goes to *one* shore cell, its members clustered there: a pair that
    // links to each other has to stay a pair, or distributing them says the opposite of what the
    // link says.
    const slot_of = try arena.alloc(u32, out.n_comp);
    defer arena.free(slot_of);
    @memset(slot_of, std.math.maxInt(u32));
    const placed_in = try arena.alloc(u32, out.n_comp);
    defer arena.free(placed_in);
    @memset(placed_in, 0);

    const golden = std.math.pi * (3.0 - @sqrt(5.0));
    const stride = @max(usable / n_groups, 1);
    var taken: usize = 0;
    for (0..n) |i| {
        if (!dust[i]) continue;
        const comp = out.comp[i];
        // An unlinked note is its own group; a small component shares one.
        const grouped = linked[i];
        var slot: usize = undefined;
        if (grouped and slot_of[comp] != std.math.maxInt(u32)) {
            slot = slot_of[comp];
        } else {
            slot = @min(taken * stride, usable - 1);
            taken += 1;
            if (grouped) slot_of[comp] = @intCast(slot);
        }
        const c = shore.items[slot];
        const cx = c % w;
        const cy = c / w;
        // Members after the first fan out around the cell at note pitch.
        const k = placed_in[comp];
        if (grouped) placed_in[comp] += 1;
        const rr = if (k == 0) 0 else pitch * @sqrt(@as(f32, @floatFromInt(k)));
        const th = golden * @as(f32, @floatFromInt(k));
        out.pos[i] = .{
            .x = lo.x + (@as(f32, @floatFromInt(cx)) - 1) * cell + rr * @cos(th),
            .y = lo.y + (@as(f32, @floatFromInt(cy)) - 1) * cell + rr * @sin(th),
        };
        // Take the component of whatever it landed beside. `spatial` groups by proximity *within*
        // a component, so an orphan carrying its old island's id would be grouped with orphans on
        // the far side of the map and the cell bounds would span the vault.
        //
        // Any of the four neighbours: the cell qualified as shore because *one* of them is
        // occupied, and reading only the left one left most orphans on their old island.
        for ([_]usize{ c - 1, c + 1, c - w, c + w }) |nb| {
            const host = owner[nb];
            if (host == std.math.maxInt(u32)) continue;
            out.comp[i] = out.comp[host];
            break;
        }
    }
}

/// Extra gap between packed region discs, in leaf pitches. Charged on top of the two radii so
/// Hilbert gap-chunking can recover community boundaries as geographic gaps — the Stage 2 gate.
const territory_ocean: f32 = 1.5;
/// Is this component a lattice — a shape with no communities to find?
///
/// The Stage 4 classifier, asked one question. `shape_metrics` already grades a graph as chain /
/// tree / grid / star / clique / scale-free and gets every gauntlet corpus right; the three that
/// have no community structure are the three where partitioning invents boundaries. Everything
/// else — a star's hub, a clique, a scale-free web, a real vault — keeps its territories.
///
/// Asked per *component*, before clustering, because that is where the damage is done. Grading the
/// gap between territories after the fact cannot undo a cut that should not have happened, which is
/// what four different gap heuristics failed to work around.
fn isLattice(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    n: usize,
    edges: []const Edge,
    edge_ids: []const u32,
    local: []const u32,
) !bool {
    // A lattice's whole point is that it is uniform, so a small sample cannot be told from the
    // rest; below this the classifier has too little to go on and force is the safe default.
    if (n < 16) return false;
    const sub = try arena.alloc(Edge, edge_ids.len);
    defer arena.free(sub);
    for (edge_ids, sub) |ei, *d| {
        const e = edges[ei];
        d.* = .{ .a = local[e.a], .b = local[e.b], .w = e.w };
    }
    return switch (try shape_metrics.classify(gpa, n, sub)) {
        .chain, .grid => true,
        // Not trees, measured. A tree has no communities either, but leaving it whole brings back
        // the failure the plan named at the start: radial bimodality goes 0.51 -> 0.63, the knot
        // with flung arms, and one added link moves the median note twice as far. A chain and a
        // grid are *uniform* — the force solve lays them out as themselves — while a tree is
        // hierarchical, and cutting it into territories is what stops the hubs collapsing into a
        // knot. Its proper interior is radial, which is the rest of Stage 4.
        else => false,
    };
}

/// Largest a territory may be before it is subdivided, in notes.
///
/// Swept alongside `frame_max_default`: 256 halves the median note's motion after an added link
/// (3.5 radii against 13.8) and reads better by co-citation, for slightly longer highways. 512
/// goes further on both but stretches the highways enough to notice.
///
/// Modularity's resolution limit does not just merge too far at the coarse end — on simplewiki it
/// produces 17,161 communities whose *median* is 3 notes while 143 of them hold two thirds of the
/// vault, one of them 28,336 notes. Neither end of that is a place: the specks are too small to
/// name and the continents are too big to draw as one disc, and packing discs whose radii span
/// 168x is what turned region placement into a 17-second relaxation that never converged. So a
/// region above the cap is clustered again on its own induced subgraph, recursively, until every
/// territory is something a reader could walk across.
const region_max_default: u32 = 256;

/// Subdivide every community over `cap` by re-clustering its own induced subgraph, until none is
/// left or a community proves unsplittable (a 28k-spoke star has no interior structure to find).
///
/// Ids are rewritten in place and stay dense. A community that splits keeps its id for the first
/// part; the rest take fresh ids off the end.
fn splitOversized(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    comm: []u32,
    n_comm_io: *u32,
    ledges: []const louvain.Edge,
    cap: u32,
    resolution: f64,
) !void {
    const n = comm.len;
    var n_comm = n_comm_io.*;

    // Communities that came back from a re-cluster in one piece. Asking them again is the
    // difference between a bounded pass and an infinite one.
    var stuck = std.AutoHashMapUnmanaged(u32, void){};

    var round: u32 = 0;
    while (round < 8) : (round += 1) {
        const count = try arena.alloc(u32, n_comm);
        @memset(count, 0);
        for (comm) |c| count[c] += 1;

        // slot[c] is this round's index for community c, or maxInt when it is not being split.
        const slot = try arena.alloc(u32, n_comm);
        @memset(slot, std.math.maxInt(u32));
        var n_slot: u32 = 0;
        for (count, 0..) |k, c| {
            if (k <= cap) continue;
            if (stuck.contains(@intCast(c))) continue;
            slot[c] = n_slot;
            n_slot += 1;
        }
        if (n_slot == 0) break;

        const slot_comm = try arena.alloc(u32, n_slot);
        for (slot, 0..) |s, c| if (s != std.math.maxInt(u32)) {
            slot_comm[s] = @intCast(c);
        };

        // Members of each split candidate, and each note's index inside its own candidate.
        const sub_n = try arena.alloc(u32, n_slot);
        @memset(sub_n, 0);
        const sub_idx = try arena.alloc(u32, n);
        for (comm, sub_idx) |c, *si| {
            const s = slot[c];
            if (s == std.math.maxInt(u32)) continue;
            si.* = sub_n[s];
            sub_n[s] += 1;
        }
        const members = try arena.alloc([]u32, n_slot);
        for (members, sub_n) |*m, k| m.* = try arena.alloc(u32, k);
        {
            const cur = try arena.alloc(u32, n_slot);
            @memset(cur, 0);
            for (comm, 0..) |c, i| {
                const s = slot[c];
                if (s == std.math.maxInt(u32)) continue;
                members[s][cur[s]] = @intCast(i);
                cur[s] += 1;
            }
        }

        // One pass over the whole edge list bins every candidate's interior edges at once.
        var sub_edges = try arena.alloc(std.ArrayListUnmanaged(louvain.Edge), n_slot);
        for (sub_edges) |*l| l.* = .empty;
        for (ledges) |e| {
            if (e.a >= n or e.b >= n or e.a == e.b) continue;
            const c = comm[e.a];
            if (c != comm[e.b]) continue;
            const s = slot[c];
            if (s == std.math.maxInt(u32)) continue;
            try sub_edges[s].append(arena, .{ .a = sub_idx[e.a], .b = sub_idx[e.b], .w = e.w });
        }

        // Cluster the candidates in parallel.
        //
        // Each one re-clusters its *own* induced subgraph and reads nothing outside it, so the
        // workers share no state at all — the partitions are collected and applied below, on one
        // thread, because the new community ids have to be handed out in a fixed order or the
        // numbering would depend on which worker finished first.
        //
        // Worth threading because this is the largest single item in the solve after the interiors:
        // 505 ms on simplewiki, where the level-0 partition leaves one community of 28,336 notes
        // and about 143 more above the cap, and every one of them is a fresh Louvain run.
        const parts_of = try arena.alloc([]u32, n_slot);
        @memset(parts_of, &.{});
        {
            var ctx: SplitCtx = .{
                .gpa = gpa,
                .arena = arena,
                .members = members,
                .sub_edges = sub_edges,
                .parts_of = parts_of,
                .resolution = resolution,
            };
            const want = @min(@max(std.Thread.getCpuCount() catch 1, 1), max_split_threads);
            if (want <= 1 or n_slot < 4) {
                ctx.range(0, n_slot);
            } else {
                var handles: [max_split_threads]std.Thread = undefined;
                var spawned: usize = 0;
                const step = n_slot / want + 1;
                var lo: usize = 0;
                while (lo < n_slot and spawned < max_split_threads) : (lo += step) {
                    const hi = @min(lo + step, n_slot);
                    handles[spawned] = std.Thread.spawn(.{}, SplitCtx.range, .{ &ctx, lo, hi }) catch {
                        ctx.range(lo, hi);
                        continue;
                    };
                    spawned += 1;
                }
                if (lo < n_slot) ctx.range(lo, n_slot);
                for (handles[0..spawned]) |h| h.join();
            }
        }

        var progress = false;
        for (0..n_slot) |s| {
            const mem = members[s];
            const part = parts_of[s];
            if (mem.len == 0 or part.len != mem.len) {
                if (mem.len != 0) try stuck.put(arena, slot_comm[s], {});
                continue;
            }
            var parts: u32 = 0;
            for (part) |p| parts = @max(parts, p + 1);
            if (parts <= 1) {
                try stuck.put(arena, slot_comm[s], {});
                continue;
            }
            progress = true;
            // Part 0 inherits the id so the untouched notes keep theirs.
            for (mem, 0..) |note, k| {
                const p = part[k];
                comm[note] = if (p == 0) slot_comm[s] else n_comm + p - 1;
            }
            n_comm += parts - 1;
        }
        if (!progress) break;
    }
    n_comm_io.* = n_comm;
}


/// Place one connected component as packed Louvain regions with every note on its region centre.
///
/// Returns the bounding radius of the packed discs, for `packComponents` to treat the whole
/// island as one circle the same way a force-solved island is.
fn placeComponentTerritories(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    members: []const u32,
    local: []const u32,
    edges: []const Edge,
    edge_ids: []const u32,
    pos: []Vec2,
    /// Per note, written for the next solve to reuse: offset from the territory centre, and the
    /// hash of that territory's membership.
    inner: []Vec2,
    home: []u64,
    memo: *FrameMemo,
    opts: Options,
) !f32 {
    const n = members.len;
    const pitch = opts.spacing * opts.note_r;
    if (n == 0) return opts.note_r;

    const ledges = try arena.alloc(louvain.Edge, edge_ids.len);
    for (edge_ids, ledges) |ei, *d| {
        const e = edges[ei];
        d.* = .{ .a = local[e.a], .b = local[e.b], .w = e.w };
    }

    var clustered = try louvain.cluster(gpa, n, ledges, .{ .resolution = opts.resolution });
    defer clustered.deinit(gpa);

    const comm = try arena.alloc(u32, n);
    var n_comm: u32 = 0;
    if (try isLattice(gpa, arena, n, edges, edge_ids, local)) {
        // A lattice is one place, and cutting it makes places that are not there.
        //
        // Modularity does not answer "are there communities here" — it answers "what is the best
        // partition", and for a path or a grid the best partition is contiguous runs, because any
        // cut severs one edge while the runs' interiors count in full. So a chain comes back as
        // ~20-note segments, each is packed as its own disc, and `territory_ocean` draws a moat
        // across something with no seam in it. The boundary looks arbitrary because it is: the
        // links are all equal and nothing chose that offset but the optimiser's starting point.
        //
        // The force solve already lays a chain out as a chain and a grid as a grid — that is what
        // the whole component looked like before it was partitioned. So do not partition it.
        @memset(comm, 0);
        n_comm = 1;
    } else {
        if (clustered.levels.len == 0) {
            for (comm, 0..) |*c, i| c.* = @intCast(i);
        } else {
            const src = clustered.levels[louvain.regionLevel(&clustered, n)];
            @memcpy(comm, src);
        }
        for (comm) |c| n_comm = @max(n_comm, c + 1);
        try splitOversized(gpa, arena, comm, &n_comm, ledges, opts.region_max, opts.resolution);
        try mergeSpecks(arena, comm, &n_comm, ledges, opts.region_min, opts.region_max);
    }
    const count = try arena.alloc(u32, n_comm);
    @memset(count, 0);
    for (comm) |c| count[c] += 1;

    // Each territory's interior, solved in its own frame, before anything is placed. Radii come
    // out of what the interiors actually need rather than from a `√members` guess, so the ocean
    // between two discs is real clearance and not an estimate. These solves share no writes, so
    // this is the loop a thread pool takes over in Stage 4.
    const radius = try arena.alloc(f32, n_comm);
    const coh = try arena.alloc(f32, n_comm);
    const sig = try arena.alloc(u64, n_comm);
    @memset(sig, 0);
    try solveInteriors(arena, gpa, members, comm, n_comm, count, ledges, inner, home, sig, radius, coh, opts);

    const centres = try arena.alloc(Vec2, n_comm);
    @memset(centres, .{});
    if (n_comm > 1) {
        const region_edges = try aggregate(arena, comm, n_comm, ledges);
        try placeNested(gpa, arena, centres, radius, coh, sig, region_edges, pitch * territory_ocean, opts, memo, 0);
    }

    for (members, comm) |note, c| pos[note] = .{ .x = centres[c].x + inner[note].x, .y = centres[c].y + inner[note].y };

    var rmax: f32 = 0;
    for (centres, radius) |c, r| {
        rmax = @max(rmax, @sqrt(c.x * c.x + c.y * c.y) + r);
    }
    return @max(rmax, pitch);
}

/// Most discs one frame places at once.
///
/// Above this the frame is split into sub-frames and placed recursively. This is the number that
/// bounds ripple: a solve of this size is a pure function of its own group's subgraph, so an edit
/// inside one group cannot move a disc in a sibling group at all — the sibling's frame did not
/// change. Placing all 34,744 territories in one force solve is what made a single added link
/// move the median note further than the globally-coupled layout it replaced.
///
/// A measured optimum, and it moved. 64 was chosen when a bigger frame bought tighter links at a
/// steep cost in stability — the 99th percentile of single-edge displacement went from 530 note
/// radii to 3,683 — because a frame is a rigid body and carries everything in it. That cost was
/// not really the frame's: `fold.degreeNormalised` was re-weighting every edge in the vault on
/// every edit, so a bigger frame simply had more to carry when the whole graph shifted underneath
/// it. With the weights stable, 128 is better than 64 on *every* axis measured — link spread
/// 0.330 against 0.366, crossings 36.1% against 38.6%, co-citation 7.73x against 6.42x, and
/// displacement 13.8/39 note radii against 76.9/334.
const frame_max_default: usize = 128;

/// Place discs as nested frames: group them, place each group in its own frame, then place the
/// groups the same way, recursively, and compose.
///
/// `centres` comes back relative to the whole set's own origin. `radius` is read, not written;
/// each level derives its own group radii from what its children actually needed.
fn placeNested(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    centres: []Vec2,
    radius: []const f32,
    /// Total interior link weight of each disc — see `frameGaps`.
    coh: []const f32,
    /// Stable signature of each disc, so a frame can be recognised across solves — see `FrameSlot`.
    sigs: []const u64,
    edges: []const multilevel.Edge,
    ocean: f32,
    opts: Options,
    memo: *FrameMemo,
    /// Guards against a clustering that keeps handing back one group the same size as its input.
    depth: u32,
) !void {
    const n = centres.len;
    if (n == 0) return;
    if (n == 1) {
        centres[0] = .{};
        return;
    }
    if (n <= opts.frame_max or depth >= 16) return placeFrame(arena, centres, radius, coh, sigs, edges, ocean, opts, memo);

    // Group this level with the same clustering that made the territories, bounded to a frame.
    const group = try arena.alloc(u32, n);
    var n_group: u32 = 0;
    {
        const ledges = try arena.alloc(louvain.Edge, edges.len);
        for (edges, ledges) |e, *d| d.* = .{ .a = e.a, .b = e.b, .w = e.w };
        var clustered = try louvain.cluster(gpa, n, ledges, .{});
        defer clustered.deinit(gpa);
        if (clustered.levels.len == 0) {
            for (group, 0..) |*g, i| g.* = @intCast(i);
            n_group = @intCast(n);
        } else {
            @memcpy(group, clustered.levels[louvain.regionLevel(&clustered, n)]);
            for (group) |g| n_group = @max(n_group, g + 1);
        }
        // A group larger than one frame is cut down rather than recursed into. Letting the
        // dendrogram nest freely instead reads better by community measures (co-citation doubles)
        // but the geometry is worse where it matters: highways ran twice as long and the 99th
        // percentile of single-edge displacement went from 530 note radii to 3,320. Deep nesting
        // means a change high in the tree carries everything below it.
        //
        // No speck merge here: a frame of one disc is free, and merging groups would move discs
        // between frames for a reason that has nothing to do with the links.
        try splitOversized(gpa, arena, group, &n_group, ledges, @intCast(opts.frame_max), opts.resolution);
    }
    if (n_group <= 1 or n_group >= n) return placeFrame(arena, centres, radius, coh, sigs, edges, ocean, opts, memo);

    // Members of each group, and each disc's index inside its group.
    const count = try arena.alloc(u32, n_group);
    @memset(count, 0);
    for (group) |g| count[g] += 1;
    const start = try arena.alloc(u32, n_group + 1);
    start[0] = 0;
    for (count, 0..) |k, g| start[g + 1] = start[g] + k;
    const idx = try arena.alloc(u32, n);
    const member = try arena.alloc(u32, n);
    const fill = try arena.alloc(u32, n_group);
    @memcpy(fill, start[0..n_group]);
    for (group, 0..) |g, i| {
        idx[i] = fill[g] - start[g];
        member[fill[g]] = @intCast(i);
        fill[g] += 1;
    }

    // Interior edges of each group, binned in one pass.
    const e_count = try arena.alloc(u32, n_group);
    @memset(e_count, 0);
    for (edges) |e| {
        if (e.a >= n or e.b >= n or e.a == e.b) continue;
        if (group[e.a] == group[e.b]) e_count[group[e.a]] += 1;
    }
    const e_start = try arena.alloc(u32, n_group + 1);
    e_start[0] = 0;
    for (e_count, 0..) |k, g| e_start[g + 1] = e_start[g] + k;
    const sub_edges = try arena.alloc(multilevel.Edge, e_start[n_group]);
    @memcpy(fill, e_start[0..n_group]);
    for (edges) |e| {
        if (e.a >= n or e.b >= n or e.a == e.b) continue;
        const g = group[e.a];
        if (g != group[e.b]) continue;
        sub_edges[fill[g]] = .{ .a = idx[e.a], .b = idx[e.b], .w = e.w };
        fill[g] += 1;
    }

    // Each group in its own frame, bottom up: a group's radius is what its children needed.
    const group_radius = try arena.alloc(f32, n_group);
    // A group's cohesion is what its children hold plus what joins them to each other — the same
    // quantity one level up.
    const group_coh = try arena.alloc(f32, n_group);
    @memset(group_coh, 0);
    for (group, coh) |g, c| group_coh[g] += c;
    for (sub_edges) |e| {
        if (e.a >= n or e.b >= n) continue;
        group_coh[group[member[e.a]]] += e.w;
    }
    // A group's signature is its children's, combined the same order-independent way a
    // territory's is its notes'. That is what lets a frame one level up be recognised.
    const group_sig = try arena.alloc(u64, n_group);
    @memset(group_sig, 0);
    for (group, sigs) |g, sig| {
        var h = sig *% 0xff51afd7ed558ccd;
        h ^= h >> 33;
        group_sig[g] ^= h;
    }
    for (group_sig, 0..) |*g, i| {
        if (g.* == 0) g.* = @as(u64, i) +% 1;
    }
    const sub_c = try arena.alloc(Vec2, n);
    const sub_r = try arena.alloc(f32, n);
    const sub_coh = try arena.alloc(f32, n);
    const sub_sig = try arena.alloc(u64, n);
    for (0..n_group) |g| {
        if (opts.cancel) |k| if (k.load(.monotonic)) return error.Canceled;
        const mem = member[start[g]..start[g + 1]];
        for (mem, 0..) |i, k| {
            sub_r[start[g] + k] = radius[i];
            sub_coh[start[g] + k] = coh[i];
            sub_sig[start[g] + k] = sigs[i];
        }
        const cs = sub_c[start[g]..start[g + 1]];
        try placeNested(gpa, arena, cs, sub_r[start[g]..start[g + 1]], sub_coh[start[g]..start[g + 1]], sub_sig[start[g]..start[g + 1]], sub_edges[e_start[g]..e_start[g + 1]], ocean, opts, memo, depth + 1);
        var rmax: f32 = 0;
        for (cs, mem) |c, i| rmax = @max(rmax, @sqrt(c.x * c.x + c.y * c.y) + radius[i]);
        group_radius[g] = rmax;
    }

    // Then the groups, by the same rule, one level up.
    const group_edges = try aggregate(arena, group, n_group, edges);
    const group_centres = try arena.alloc(Vec2, n_group);
    try placeNested(gpa, arena, group_centres, group_radius, group_coh, group_sig, group_edges, ocean, opts, memo, depth + 1);

    for (0..n_group) |g| {
        const o = group_centres[g];
        for (member[start[g]..start[g + 1]], start[g]..) |i, k| {
            centres[i] = .{ .x = o.x + sub_c[k].x, .y = o.y + sub_c[k].y };
        }
    }
}

/// The frame placements a solve reuses and the ones it records for the next.
///
/// Held by pointer through the recursion rather than returned, because `placeNested` walks a tree
/// of frames and every level contributes.
const FrameMemo = struct {
    prev: std.AutoHashMapUnmanaged(u128, Vec2) = .empty,
    out: std.ArrayListUnmanaged(FrameSlot) = .empty,
    gpa: std.mem.Allocator,
    hits: u32 = 0,
    total: u32 = 0,

    fn slotKey(frame: u64, sig: u64) u128 {
        return (@as(u128, frame) << 64) | sig;
    }

    /// Fill `centres` from the previous solve, if every disc in this frame was there under the
    /// same key. All-or-nothing: a frame half-remembered is worse than one re-solved, because the
    /// discs that were found would sit against discs that were not.
    fn reuse(self: *FrameMemo, key: u64, sigs: []const u64, centres: []Vec2) bool {
        self.total += 1;
        if (self.prev.count() == 0) return false;
        for (sigs) |sig| {
            if (!self.prev.contains(slotKey(key, sig))) return false;
        }
        for (sigs, centres) |sig, *c| c.* = self.prev.get(slotKey(key, sig)).?;
        self.hits += 1;
        return true;
    }

    /// Best-effort: losing a record costs the next solve a re-place, never correctness.
    fn record(self: *FrameMemo, key: u64, sigs: []const u64, centres: []const Vec2) void {
        for (sigs, centres) |sig, c| {
            self.out.append(self.gpa, .{ .frame = key, .sig = sig, .x = c.x, .y = c.y }) catch return;
        }
    }
};

/// Everything a frame's placement depends on, order-independently: which discs are in it, how big
/// each one is, and the weight between each pair.
///
/// Order-independent because the clustering hands the members over in whatever order it produced,
/// and the same frame arrived at two ways is the same frame. Radii are folded in because they are a
/// real input — a territory that kept its members but changed size has to be re-placed.
fn frameKey(sigs: []const u64, radius: []const f32, edges: []const multilevel.Edge) u64 {
    var members: u64 = 0;
    for (sigs, radius) |sig, r| {
        var h = sig ^ (@as(u64, @intCast(@as(u32, @bitCast(r)))) *% 0x9e3779b97f4a7c15);
        h *%= 0xff51afd7ed558ccd;
        h ^= h >> 33;
        members ^= h;
    }
    var web: u64 = 0;
    for (edges) |e| {
        if (e.a >= sigs.len or e.b >= sigs.len) continue;
        const lo = @min(sigs[e.a], sigs[e.b]);
        const hi = @max(sigs[e.a], sigs[e.b]);
        var h = lo *% 0xc4ceb9fe1a85ec53;
        h ^= hi *% 0xff51afd7ed558ccd;
        h ^= @as(u64, @intCast(@as(u32, @bitCast(e.w)))) *% 0x9e3779b97f4a7c15;
        h ^= h >> 31;
        web ^= h;
    }
    var acc = members *% 0x100000001b3;
    acc ^= web;
    acc ^= @as(u64, sigs.len) *% 0x9e3779b97f4a7c15;
    return if (acc == 0) 1 else acc;
}

/// Place one frame's worth of discs: linkage shape if the graph is a tree, force polish otherwise.
///
/// A tree / path / star *is* its layout. Force-from-a-spiral is how those used to come out as
/// pinwheels of the wrong kind. Cyclic graphs (grid, wiki, bipartite) go through the force
/// polish: that is the cloud.
fn placeFrame(
    arena: std.mem.Allocator,
    centres: []Vec2,
    radius: []const f32,
    coh: []const f32,
    sigs: []const u64,
    edges: []const multilevel.Edge,
    ocean: f32,
    opts: Options,
    memo: *FrameMemo,
) !void {
    const n = centres.len;
    @memset(centres, .{});
    if (n <= 1) {
        if (n == 1) memo.record(frameKey(sigs, radius, edges), sigs, centres);
        return;
    }

    // Solved before, from exactly these discs at exactly these sizes. Same argument as the
    // interiors: the placement is a deterministic function of its inputs, and the key hashes all
    // of them, so a hit is what re-solving would produce.
    const key = frameKey(sigs, radius, edges);
    if (memo.reuse(key, sigs, centres)) return;
    defer memo.record(key, sigs, centres);

    if (try placeLinkageIfTree(arena, centres, radius, edges, ocean)) return;

    const seed = try arena.alloc(dvui.Point, n);
    @memset(seed, .{});
    if (edges.len > 0) {
        // Mass is disc *area*: that is what the repulsion has to clear, and unlike a member count
        // it still means the right thing when the node stands for a whole frame of territories.
        const mass = try arena.alloc(f32, n);
        for (radius, mass) |r, *m| m.* = @max(r * r, 1e-6);
        var sub_opts = opts.iters;
        sub_opts.cancel = opts.cancel;
        sub_opts.mass = mass;
        sub_opts.gravity = 0;
        try multilevel.solve(arena, n, edges, seed, sub_opts);
    }
    var extent: f32 = 0;
    for (seed) |p| extent = @max(extent, @sqrt(p.x * p.x + p.y * p.y));
    if (extent < 1e-3) return packDiscsCloud(arena, centres, radius, ocean);

    for (centres, seed) |*c, p| c.* = .{ .x = p.x, .y = p.y };
    jitterCoincident(centres);
    scaleToArea(arena, centres, radius, ocean);

    // Push apart, then pull the coupled pairs back to the clearance they actually want.
    //
    // Grading the gap alone changed nothing measurable, for a reason worth writing down: the gap
    // was never the binding constraint. `scaleToArea` deliberately leaves slack, and
    // `separateDiscs` only ever *pushes* — so lowering a bound that nothing was pressed against is
    // a no-op. Closing a lattice back up needs something that pulls, and the linkage path has had
    // exactly that all along.
    //
    // Alternating, because the two constraints disagree: the pull wants coupled discs touching and
    // the push wants every disc clear. A few rounds settle where both are satisfied. Six is what
    // the linkage path uses, and a frame is at most `frame_max` discs, so the cost is nothing.
    // Seam-closing was tried here and backed out. See `frameGaps` for what the graded gap does
    // reach, and why pulling coupled frames back together — the other half of closing a lattice —
    // could not be made safe.
    separateDiscs(arena, centres, radius, ocean, frameGaps(arena, n, edges, radius, coh, ocean, opts.spacing * opts.note_r));
    recentre(centres);
}

/// Collapse an edge list onto a grouping, summing the weight of every crossing.
///
/// Radix sort and a run-merge, not a hash map. The map was the obvious way to write it and the
/// wrong shape for the input: on simplewiki this folds 3.35M note links into ~1.2M region pairs,
/// which is 3.35M hash lookups with random probes into a table too big for cache — measured at
/// ~500 ms, the second-largest item in the solve after the interiors. The key is two `u32` group
/// ids packed into 64 bits, which buckets in linear time; `radix.zig` exists for exactly this shape
/// and this is its third caller.
///
/// The sort also *is* the determinism. Hash iteration order is not stable, so the previous version
/// had to sort its output anyway before handing it to a force solve that reads edges in order.
fn aggregate(
    arena: std.mem.Allocator,
    group: []const u32,
    n_group: u32,
    edges: anytype,
) ![]multilevel.Edge {
    var pairs: std.ArrayListUnmanaged(multilevel.Edge) = .empty;
    defer pairs.deinit(arena);
    try pairs.ensureTotalCapacity(arena, edges.len);
    for (edges) |e| {
        if (e.a >= group.len or e.b >= group.len or e.a == e.b) continue;
        const ga = group[e.a];
        const gb = group[e.b];
        if (ga == gb or ga >= n_group or gb >= n_group) continue;
        pairs.appendAssumeCapacity(.{ .a = @min(ga, gb), .b = @max(ga, gb), .w = e.w });
    }
    if (pairs.items.len == 0) return &.{};

    const scratch = try arena.alloc(multilevel.Edge, pairs.items.len);
    defer arena.free(scratch);
    const sorted = radix.sortByKey(multilevel.Edge, regionPairKey, pairs.items, scratch);

    // Stable, so equal keys keep their input order and the float sum below is reproducible — the
    // same reason `louvain.contract` needs it.
    const out = try arena.alloc(multilevel.Edge, sorted.len);
    var n: usize = 0;
    for (sorted) |e| {
        if (n > 0 and out[n - 1].a == e.a and out[n - 1].b == e.b) {
            out[n - 1].w += e.w;
            continue;
        }
        out[n] = e;
        n += 1;
    }
    return out[0..n];
}

fn regionPairKey(e: multilevel.Edge) u64 {
    return (@as(u64, e.a) << 32) | e.b;
}

/// Workers `splitOversized` may use. Capped like the interiors: this runs behind an editor.
const max_split_threads: usize = 8;

/// One worker's stripe of oversized communities, each re-clustered on its own induced subgraph.
const SplitCtx = struct {
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    members: []const []u32,
    sub_edges: []std.ArrayListUnmanaged(louvain.Edge),
    /// Out, one per slot: the sub-partition, or empty when the community would not split.
    parts_of: [][]u32,
    resolution: f64,

    fn range(self: *SplitCtx, lo: usize, hi: usize) void {
        for (lo..hi) |s| {
            const mem = self.members[s];
            if (mem.len == 0) continue;
            var sub = louvain.cluster(self.gpa, mem.len, self.sub_edges[s].items, .{ .resolution = self.resolution }) catch continue;
            defer sub.deinit(self.gpa);
            if (sub.levels.len == 0) continue;
            const part = sub.levels[louvain.regionLevel(&sub, mem.len)];
            // Copied out because `sub` is freed here and the caller applies the result later.
            self.parts_of[s] = self.arena.dupe(u32, part) catch continue;
        }
    }
};

/// Smallest a territory may be before it is absorbed into its strongest neighbour, in notes.
///
/// `splitOversized` tightens the size distribution from the top; this tightens it from the
/// bottom. Modularity leaves a long tail of two- and three-note communities — on simplewiki the
/// *median* territory was four notes — and a hamlet of three is not a place you can name, or
/// draw, or navigate to. Absorbing it into whichever neighbour it links to hardest costs nothing
/// in modularity terms (the links were already crossing) and buys a map of provinces.
const region_min_default: u32 = 8;

/// Absorb every community under `floor` into the neighbour it shares the most link weight with,
/// so long as the result stays under `cap`. Ids stay dense.
///
/// A speck with no neighbour at all — an isolated pair in its own component — keeps its id. There
/// is nothing to absorb it into, and inventing a home for it would put two unrelated notes in one
/// territory, which is the one thing a territory must never mean.
fn mergeSpecks(
    arena: std.mem.Allocator,
    comm: []u32,
    n_comm_io: *u32,
    ledges: []const louvain.Edge,
    floor: u32,
    cap: u32,
) !void {
    const n = comm.len;
    var n_comm = n_comm_io.*;
    if (n_comm <= 1 or floor <= 1) return;

    var round: u32 = 0;
    while (round < 4) : (round += 1) {
        const count = try arena.alloc(u32, n_comm);
        @memset(count, 0);
        for (comm) |c| count[c] += 1;

        var any = false;
        for (count) |k| {
            if (k > 0 and k < floor) any = true;
        }
        if (!any) break;

        // Strongest neighbour of each speck, by summed crossing weight. Ties go to the lower id
        // so the answer does not depend on hash iteration order.
        const best_w = try arena.alloc(f32, n_comm);
        const best_c = try arena.alloc(u32, n_comm);
        @memset(best_w, 0);
        @memset(best_c, std.math.maxInt(u32));
        var acc = std.AutoHashMapUnmanaged([2]u32, f32){};
        for (ledges) |e| {
            if (e.a >= n or e.b >= n or e.a == e.b) continue;
            const ca = comm[e.a];
            const cb = comm[e.b];
            if (ca == cb) continue;
            if (count[ca] >= floor and count[cb] >= floor) continue;
            const key: [2]u32 = if (ca < cb) .{ ca, cb } else .{ cb, ca };
            const gop = try acc.getOrPut(arena, key);
            if (!gop.found_existing) gop.value_ptr.* = 0;
            gop.value_ptr.* += e.w;
        }
        var it = acc.iterator();
        while (it.next()) |kv| {
            const pair = kv.key_ptr.*;
            const w = kv.value_ptr.*;
            for (0..2) |side| {
                const me = pair[side];
                const other = pair[1 - side];
                if (count[me] >= floor) continue;
                if (count[me] + count[other] > cap) continue;
                if (w > best_w[me] or (w == best_w[me] and other < best_c[me])) {
                    best_w[me] = w;
                    best_c[me] = other;
                }
            }
        }

        // Follow the chain: a speck may point at a speck. Stop at the first target that is not
        // moving, and break a mutual pair by keeping the lower id.
        const target = try arena.alloc(u32, n_comm);
        for (target, 0..) |*t, c| t.* = @intCast(c);
        var moved = false;
        for (0..n_comm) |c| {
            if (count[c] == 0 or count[c] >= floor) continue;
            var dst = best_c[c];
            if (dst == std.math.maxInt(u32)) continue;
            var hops: u32 = 0;
            while (hops < 8 and count[dst] < floor and best_c[dst] != std.math.maxInt(u32)) : (hops += 1) {
                if (best_c[dst] == c) {
                    dst = @min(@as(u32, @intCast(c)), dst);
                    break;
                }
                dst = best_c[dst];
            }
            if (dst == c) continue;
            target[c] = dst;
            moved = true;
        }
        if (!moved) break;

        for (comm) |*c| {
            var t = target[c.*];
            var hops: u32 = 0;
            while (t != target[t] and hops < 8) : (hops += 1) t = target[t];
            c.* = t;
        }
        n_comm = compactIds(arena, comm, n_comm) catch n_comm;
    }
    n_comm_io.* = n_comm;
}

/// Renumber community ids to `0..k` with no gaps, preserving relative order. Returns `k`.
fn compactIds(arena: std.mem.Allocator, comm: []u32, n_comm: u32) !u32 {
    const map = try arena.alloc(u32, n_comm);
    defer arena.free(map);
    @memset(map, std.math.maxInt(u32));
    var next: u32 = 0;
    for (comm) |c| {
        if (map[c] != std.math.maxInt(u32)) continue;
        map[c] = next;
        next += 1;
    }
    for (comm) |*c| c.* = map[c.*];
    return next;
}

/// Solve every territory's interior in its own frame.
///
/// This is the whole point of a bounded region: a community of at most `region_max` notes is a
/// force solve of microseconds, independent of every other community, so what used to be one
/// 284k-body problem becomes tens of thousands of tiny ones that share no writes. `inner` comes
/// back in world units, centred on the territory's own centroid; `radius` is what the solve
/// actually needed, which is what the packing outside is then given.
fn solveInteriors(
    /// Shared, single-threaded scratch: the CSRs built below. Workers never touch it.
    arena: std.mem.Allocator,
    /// Backing allocator each worker builds its own arena on. Must be thread-safe.
    arena_gpa: std.mem.Allocator,
    /// Global note id of each component-local index, so `inner` / `home` can be written in the
    /// caller's note space and handed straight back as `Options.reuse` next time.
    notes: []const u32,
    comm: []const u32,
    n_comm: u32,
    count: []const u32,
    ledges: []const louvain.Edge,
    inner: []Vec2,
    home: []u64,
    /// Out: each territory's membership hash, so the frames above can be identified by what they
    /// are made of rather than by an index the clustering renumbers every solve.
    sig: []u64,
    radius: []f32,
    /// Out: total interior link weight of each territory. The scale a *crossing* is judged
    /// against — see `frameGaps`.
    coh: []f32,
    opts: Options,
) !void {
    const n = comm.len;
    const pitch = opts.spacing * opts.note_r;
    for (notes) |note| inner[note] = .{};
    @memset(coh, 0);
    for (radius, count) |*r, k| r.* = if (k <= 1) opts.note_r else pitch * @sqrt(@as(f32, @floatFromInt(k)));

    // Members of each territory, and each note's index inside it.
    const idx = try arena.alloc(u32, n);
    const fill = try arena.alloc(u32, n_comm);
    @memset(fill, 0);
    for (comm, idx) |c, *k| {
        k.* = fill[c];
        fill[c] += 1;
    }
    const start = try arena.alloc(u32, n_comm + 1);
    start[0] = 0;
    for (count, 0..) |k, c| start[c + 1] = start[c] + k;
    const member = try arena.alloc(u32, n);
    @memcpy(fill, start[0..n_comm]);
    for (comm, 0..) |c, i| {
        member[fill[c]] = @intCast(i);
        fill[c] += 1;
    }

    // Interior edges, binned by territory in one pass over the whole edge list.
    const e_count = try arena.alloc(u32, n_comm);
    @memset(e_count, 0);
    for (ledges) |e| {
        if (e.a >= n or e.b >= n or e.a == e.b) continue;
        if (comm[e.a] != comm[e.b]) continue;
        e_count[comm[e.a]] += 1;
    }
    const e_start = try arena.alloc(u32, n_comm + 1);
    e_start[0] = 0;
    for (e_count, 0..) |k, c| e_start[c + 1] = e_start[c] + k;
    const sub_edges = try arena.alloc(multilevel.Edge, e_start[n_comm]);
    @memcpy(fill, e_start[0..n_comm]);
    for (ledges) |e| {
        if (e.a >= n or e.b >= n or e.a == e.b) continue;
        const c = comm[e.a];
        if (c != comm[e.b]) continue;
        sub_edges[fill[c]] = .{ .a = idx[e.a], .b = idx[e.b], .w = e.w };
        coh[c] += e.w;
        fill[c] += 1;
    }

    // Solve the interiors in parallel.
    //
    // Every territory reads its own slice of `member` / `sub_edges` and writes its own slice of
    // `inner` and one `radius`, so there is nothing shared to race on — which is the property the
    // whole bounded-region design was for. Measured on simplewiki this was 2,861 ms of a 4,718 ms
    // solve, more than clustering and frame placement together.
    //
    // Each worker gets its *own* arena. One shared arena is not thread-safe, and it is also the
    // wrong shape: these solves allocate and free in a tight cycle, and a per-worker arena reuses
    // the same pages for every territory it handles.
    //
    // Stripes are cut by cumulative note count rather than by territory index, because sizes are
    // heavy-tailed even after `splitOversized` — equal counts of territories would leave one worker
    // holding the large end.

    // id -> index in the previous solve, built once. Without it `reuse` can only be read at the
    // same index, and indices move whenever a note is added or removed.
    var prev_at: std.AutoHashMapUnmanaged(u64, u32) = .empty;
    defer prev_at.deinit(arena_gpa);
    if (opts.reuse) |r| {
        if (r.ids.len == r.inner.len and r.ids.len == r.home.len) {
            prev_at.ensureTotalCapacity(arena_gpa, @intCast(r.ids.len)) catch {};
            for (r.ids, 0..) |id, i| prev_at.putAssumeCapacity(id, @intCast(i));
        }
    }

    var ctx: InteriorCtx = .{
        .prev_at = &prev_at,
        .notes = notes,
        .member = member,
        .start = start,
        .count = count,
        .e_start = e_start,
        .sub_edges = sub_edges,
        .inner = inner,
        .home = home,
        .sig = sig,
        .radius = radius,
        .opts = opts,
        .pitch = pitch,
        .gpa = arena_gpa,
    };

    const want = @min(@max(std.Thread.getCpuCount() catch 1, 1), max_interior_threads);
    if (want <= 1 or n_comm < 64) {
        ctx.run(0, @intCast(n_comm));
    } else {
        var bounds: [max_interior_threads + 1]u32 = undefined;
        stripeByNotes(count, n_comm, want, bounds[0 .. want + 1]);
        var handles: [max_interior_threads]std.Thread = undefined;
        var spawned: usize = 0;
        for (0..want) |t| {
            if (bounds[t] == bounds[t + 1]) continue;
            handles[spawned] = std.Thread.spawn(.{}, InteriorCtx.run, .{ &ctx, bounds[t], bounds[t + 1] }) catch {
                ctx.run(bounds[t], bounds[t + 1]);
                continue;
            };
            spawned += 1;
        }
        for (handles[0..spawned]) |h| h.join();
    }
    if (ctx.failed.load(.monotonic)) return error.OutOfMemory;
    if (opts.cancel) |k| if (k.load(.monotonic)) return error.Canceled;
    // Accumulated, not assigned: `solveInteriors` runs once per *component*, and simplewiki has
    // twenty-four. Overwriting reported whichever island happened to be solved last — a two-note
    // component reading `1/1` while the 281k-note giant went unmentioned.
    reused_interiors += ctx.reused.load(.monotonic);
    solved_interiors += n_comm;
}

/// Interior reuse across the whole of the last `solve`, for the caller's log. Reset by `solve`, so
/// it covers every component. Not per-`Result` because it says something about the *pair* of
/// solves, not about the arrangement.
pub var reused_interiors: u32 = 0;
pub var solved_interiors: u32 = 0;
pub var reused_frames: u32 = 0;
pub var placed_frames: u32 = 0;

/// One worker's slice of the interior solves. At file scope so its methods' locals do not
/// shadow `solveInteriors`, which holds identically-named CSRs.
/// Order-independent hash of a territory's membership, in caller note ids.
///
/// Order-independent because the member list is built in whatever order the clustering produced,
/// and the same set arrived at two different ways is the same territory. The count is mixed in so
/// a set cannot collide with a subset that happens to XOR to the same value.
fn membershipHash(ctx: *const InteriorCtx, mem: []const u32) u64 {
    var acc: u64 = 0x9e3779b97f4a7c15;
    for (mem) |li| {
        var h: u64 = ctx.keyOf(li);
        h *%= 0xff51afd7ed558ccd;
        h ^= h >> 33;
        h *%= 0xc4ceb9fe1a85ec53;
        h ^= h >> 29;
        acc ^= h;
    }
    acc ^= @as(u64, mem.len) *% 0x9e3779b97f4a7c15;
    // Zero is "no previous territory", so never hand it back as a real one.
    return if (acc == 0) 1 else acc;
}

const InteriorCtx = struct {
    /// Stable id -> index in `Options.reuse`. Read-only for the workers.
    prev_at: *const std.AutoHashMapUnmanaged(u64, u32),
    notes: []const u32,
    member: []const u32,
    start: []const u32,
    count: []const u32,
    e_start: []const u32,
    sub_edges: []const multilevel.Edge,
    inner: []Vec2,
    home: []u64,
    sig: []u64,
    radius: []f32,
    opts: Options,
    pitch: f32,
    gpa: std.mem.Allocator,
    /// How many territories came back byte-identical and were copied instead of solved.
    reused: std.atomic.Value(u32) = .init(0),
    failed: std.atomic.Value(bool) = .init(false),

    /// Copy the previous solve's interior for this territory, if it had exactly these members.
    ///
    /// The check is `home[note] == sig` for every member. `sig` encodes the whole membership, so
    /// agreement across every member means the previous territory held these notes and no others:
    /// a larger set would have hashed to something else, and any member that has moved carries its
    /// old territory's hash instead. So this is an equality test on the *inputs*, not a claim about
    /// what changed — it cannot be fooled by a stale dirty set, and it needs none.
    fn reuseInto(self: *const @This(), sig: u64, mem: []const u32, radius_out: *f32) bool {
        const prev = self.opts.reuse orelse return false;
        if (self.prev_at.count() == 0) return false;
        for (mem) |li| {
            const at = self.prev_at.get(self.keyOf(li)) orelse return false;
            if (prev.home[at] != sig) return false;
        }
        var rmax: f32 = 0;
        for (mem) |li| {
            const at = self.prev_at.get(self.keyOf(li)).?;
            const q = prev.inner[at];
            self.inner[self.notes[li]] = q;
            rmax = @max(rmax, @sqrt(q.x * q.x + q.y * q.y));
        }
        radius_out.* = rmax + self.opts.note_r;
        return true;
    }

    /// This note's stable identity. Falls back to the index when the caller supplied none, which
    /// is only sound where the note set cannot change — see `Options.ids`.
    fn keyOf(self: *const @This(), local: u32) u64 {
        const note = self.notes[local];
        return if (self.opts.ids.len > note) self.opts.ids[note] else note;
    }

    fn run(self: *@This(), lo: u32, hi: u32) void {
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        self.range(arena_state.allocator(), lo, hi) catch self.failed.store(true, .monotonic);
    }

    fn range(self: *@This(), wa: std.mem.Allocator, lo: u32, hi: u32) !void {
        const member = self.member;
        const start = self.start;
        const count = self.count;
        const e_start = self.e_start;
        const sub_edges = self.sub_edges;
        const notes = self.notes;
        const inner = self.inner;
        const home = self.home;
        const radius = self.radius;
        const opts = self.opts;
        const pitch = self.pitch;
        var sub_pos: std.ArrayListUnmanaged(dvui.Point) = .empty;
        defer sub_pos.deinit(wa);

for (lo..hi) |c| {
    if (opts.cancel) |k| if (k.load(.monotonic)) return error.Canceled;
    const k = count[c];
    const mem = member[start[c]..start[c + 1]];

    // Identity of this territory: its membership, order-independent.
    const sig = membershipHash(self, mem);
    self.sig[c] = sig;
    for (mem) |li| home[notes[li]] = sig;
    if (k <= 1) continue;

    // Already solved, in a previous solve, from exactly these notes. An interior is a pure
    // function of its own subgraph, so the answer cannot have changed — see `Options.reuse`.
    if (self.reuseInto(sig, mem, &radius[c])) {
        _ = self.reused.fetchAdd(1, .monotonic);
        continue;
    }

    try sub_pos.resize(wa, k);
    var sub_opts = opts.iters;
    sub_opts.cancel = opts.cancel;
    try multilevel.solve(wa, k, sub_edges[e_start[c]..e_start[c + 1]], sub_pos.items, sub_opts);

    var cx: f64 = 0;
    var cy: f64 = 0;
    for (sub_pos.items) |p| {
        cx += p.x;
        cy += p.y;
    }
    const invk = 1.0 / @as(f64, @floatFromInt(k));
    const ctr: Vec2 = .{ .x = @floatCast(cx * invk), .y = @floatCast(cy * invk) };

    // Unit space to world, against this territory's own *nearest* neighbours. Mean edge
    // length is the wrong ruler: in a clique every pair is an edge, so the mean is the
    // diameter, the scale comes out tiny and 80 notes land on top of each other. Taking each
    // note's shortest link and the median of those measures the thing `spacing` is calibrated
    // against — how far apart two adjacent discs actually sit.
    const med = nearestNeighbourMedian(wa, sub_pos.items) catch 0;
    if (!(med > 1e-6)) {
        // Nothing to solve from, and this is common rather than exotic: `addOrphanDrawer` hangs
        // every unlinked note off one hub, so the clustering hands back territories of spokes that
        // are adjacent to nothing inside them. A force solve of an edgeless graph is a pile at the
        // origin, so the arrangement has to be invented — see `scatterDisc` for what shape is
        // honest about that, and which shape is not.
        scatterDisc(wa, inner, notes, mem, pitch, opts.note_r, &radius[c]);
        continue;
    }
    const s: f32 = pitch / med;

    var rmax: f32 = 0;
    for (mem, sub_pos.items) |li, p| {
        const note = notes[li];
        const q: Vec2 = .{
            .x = @as(f32, @floatCast(p.x - ctr.x)) * s,
            .y = @as(f32, @floatCast(p.y - ctr.y)) * s,
        };
        inner[note] = q;
        rmax = @max(rmax, @sqrt(q.x * q.x + q.y * q.y));
    }
    radius[c] = rmax + opts.note_r;
}
    }
};

/// Workers the interior solves may use. Capped rather than unbounded: this runs on a background
/// solve thread inside the host's process, and taking every core would starve the editor it is
/// meant to be running behind.
const max_interior_threads: usize = 8;

/// Cut `0..n` into `bounds.len - 1` stripes of roughly equal *note* count.
fn stripeByNotes(count: []const u32, n: usize, parts: usize, bounds: []u32) void {
    var total: u64 = 0;
    for (count[0..n]) |k| total += k;
    bounds[0] = 0;
    bounds[parts] = @intCast(n);
    var acc: u64 = 0;
    var next: usize = 1;
    for (count[0..n], 0..) |k, c| {
        acc += k;
        while (next < parts and acc * parts >= total * next) : (next += 1) bounds[next] = @intCast(c + 1);
    }
    while (next < parts) : (next += 1) bounds[next] = @intCast(n);
}

/// Median over notes of the distance to the nearest *other note*, in the solve's own units.
///
/// The scale ruler for an interior, and it has to be nearest-neighbour rather than nearest-link.
/// A star's only links are hub-to-spoke, so scaling by them sets the ring radius to one pitch and
/// then packs two hundred spokes around a circle of that radius, every one of them on top of its
/// neighbours. Overlap is decided by whoever is actually closest, linked or not.
///
/// All-pairs is affordable because `region_max` bounds a territory: the total is `Σk² ≤
/// region_max·n`, which is the whole reason the interiors were made small. A *lattice* region is
/// deliberately left whole (see `isLattice`) and can be the size of the component, so above a
/// threshold this strides the pairs instead — a uniform sample of a uniform shape measures the
/// same spacing, and that is exactly the case that gets large.
fn nearestNeighbourMedian(arena: std.mem.Allocator, pos: []const dvui.Point) !f32 {
    const k = pos.len;
    if (k < 2) return 0;
    const stride = @max(1, k / 1024);
    const best = try arena.alloc(f32, k);
    defer arena.free(best);
    @memset(best, std.math.floatMax(f32));
    var i: usize = 0;
    while (i < k) : (i += stride) {
        for (i + 1..k) |j| {
            const dx = pos[i].x - pos[j].x;
            const dy = pos[i].y - pos[j].y;
            const d: f32 = @floatCast(dx * dx + dy * dy);
            best[i] = @min(best[i], d);
            best[j] = @min(best[j], d);
        }
    }
    // Only the sampled rows saw every partner; the rest saw a suffix and would read too far.
    var seen: usize = 0;
    i = 0;
    while (i < k) : (i += stride) {
        best[seen] = best[i];
        seen += 1;
    }
    if (seen == 0) return 0;
    std.mem.sort(f32, best[0..seen], {}, std.sort.asc(f32));
    return @sqrt(best[seen / 2]);
}

/// Lay out notes that have nothing to say about each other: a jittered cloud, separated to pitch.
///
/// Reached when a territory has no interior links at all, which is not the rare case it sounds
/// like — `addOrphanDrawer` wires every unlinked note to a single hub, so the clustering splits
/// those spokes into territories whose members are adjacent to nothing inside them.
///
/// Deliberately *not* a phyllotaxis spiral, which is what this was first. `r = c√i` at the golden
/// angle is the textbook answer for packing a disc, and it looks like one: a hard circular rim, a
/// visible spiral in the interior, and — because index order becomes radius — a gradient from the
/// first note to the last. It reads as a designed object sitting in a map of organic ones, and
/// `packDiscsCloud` had already rejected it for the same reason at component scale.
///
/// A hash-seeded cloud pushed apart to `pitch` reads as what it is: a scatter of notes that happen
/// to belong nowhere in particular. Deterministic, because the seed is a pure function of the
/// note's index, so a cold open reproduces it.
fn scatterDisc(
    arena: std.mem.Allocator,
    inner: []Vec2,
    notes: []const u32,
    mem: []const u32,
    pitch: f32,
    note_r: f32,
    radius_out: *f32,
) void {
    const k = mem.len;
    if (k == 0) return;
    if (k == 1) {
        inner[notes[mem[0]]] = .{};
        radius_out.* = note_r;
        return;
    }

    // Area for `k` discs at `pitch` spacing, seeded tight so the separation below puffs it into a
    // blob rather than leaving a ring of gaps.
    const r_full = pitch * @sqrt(@as(f32, @floatFromInt(k))) * 0.5;
    const centres = arena.alloc(Vec2, k) catch {
        for (mem, 0..) |li, i| {
            const a = @as(f32, @floatFromInt(i));
            inner[notes[li]] = .{ .x = pitch * a, .y = 0 };
        }
        radius_out.* = pitch * @as(f32, @floatFromInt(k)) + note_r;
        return;
    };
    defer arena.free(centres);
    const radii = arena.alloc(f32, k) catch return;
    defer arena.free(radii);

    for (centres, radii, 0..) |*c, *r, i| {
        const h = hash2(@intCast(i));
        // `sqrt` on the radial coordinate, or the cloud bunches at the centre.
        const rr = r_full * @sqrt(@abs(h[0]));
        const th = std.math.pi * (h[1] + 1);
        c.* = .{ .x = rr * @cos(th), .y = rr * @sin(th) };
        r.* = pitch * 0.5;
    }
    // No graded gaps: these notes have no links, so there is no coupling to grade.
    separateDiscs(arena, centres, radii, 0, null);

    var rmax: f32 = 0;
    for (mem, centres) |li, c| {
        inner[notes[li]] = c;
        rmax = @max(rmax, @sqrt(c.x * c.x + c.y * c.y));
    }
    radius_out.* = rmax + note_r;
}

/// Required clearance between every pair of discs in one frame, graded by how strongly they are
/// coupled.
///
/// A constant ocean is being asked to mean two different things. When the clustering separates two
/// genuine communities, the cut is weak and a wide gap is honest — it is the boundary, and it is
/// what lets gap-defined Hilbert chunking recover the community geographically. When it carves a
/// *grid* or a *chain* into frames, the cut is arbitrary: the pieces are joined along a broad front
/// and the same wide gap draws a moat through a lattice that has no seam in it. One number cannot
/// say both, and a shape classifier deciding which is which would only be right as often as the
/// classifier is.
///
/// The question asked instead is **"is this crossing as heavy as the discs' own links, across a
/// border this wide?"** — which needs no classifier and no absolute weight scale, because both
/// sides of the comparison are measured in the same units on the same graph:
///
///   * `coh / n` is a disc's interior weight per note: what one note's worth of links is worth here.
///   * `√n` is its rim in notes: the widest border the pair could share.
///
/// A grid chunk touches its neighbour along its whole edge, carrying about one interior note's
/// worth of link per rim note, so the ratio approaches one and the gap closes — the lattice reads
/// as unbroken. Two cliques joined by a single link touch at a point, the ratio is a fraction, and
/// the ocean stands.
///
/// Two earlier references failed, both for the same reason: they were relative to the frame's
/// *other* crossings. A frame holding two cliques and one link between them has that link as its
/// own maximum and its own upper quartile, so the single weakest crossing in the vault graded as
/// maximal coupling and the two territories closed up against each other.
///
/// **What this does not do is close a lattice back up.** `scaleToArea` leaves slack on purpose and
/// `separateDiscs` only ever pushes, so lowering a bound nothing is pressed against changes
/// nothing — measured on `grid`, which did not move. Closing a seam needs a *pull*, and pulling
/// coupled frames together re-couples a frame into one global solve. Measured on simplewiki, one
/// added link moved the median note 133 radii without it and 214-345 with it, and the 99th
/// percentile went from 508 to 1,500-4,600 — against a `grid` that improved from 0.062 to 0.044
/// link spread and 274 to 108 radii of displacement. Four gates were tried to get one without the
/// other: crossing weight against the frame's quartile, against the shared-border reference below,
/// frame degree regularity, and frame sparsity. None separates the cases — a lattice frame and a
/// wiki frame have the same mean crossings per disc, so the gate that admits `grid` admits the
/// wiki too. The honest fix is the plan's Stage 4, where a classifier looks at the region's own
/// subgraph and picks an interior, rather than a frame-local statistic guessing after the fact.
fn frameGaps(
    arena: std.mem.Allocator,
    n: usize,
    edges: []const multilevel.Edge,
    radius: []const f32,
    coh: []const f32,
    ocean: f32,
    pitch: f32,
) ?[]const f32 {
    if (n == 0 or n > 512 or edges.len == 0 or !(pitch > 0)) return null;
    const g = arena.alloc(f32, n * n) catch return null;
    for (g) |*v| v.* = ocean;

    for (edges) |e| {
        if (e.a >= n or e.b >= n or e.a == e.b) continue;
        // `radius ≈ pitch·√n`, so this is the smaller disc's rim in notes, and its square is that
        // disc's note count. A one-note disc has no interior and nothing to be judged against.
        const rim = @max(@min(radius[e.a], radius[e.b]) / pitch, 1);
        const notes = rim * rim;
        const inner = @min(coh[e.a], coh[e.b]);
        if (!(inner > 0)) continue;
        const ref = (inner / notes) * rim;
        const bound = std.math.clamp(e.w / (border_coupling * ref), 0, 1);
        const gap = ocean * (1 - bound);
        g[e.a * n + e.b] = @min(g[e.a * n + e.b], gap);
        g[e.b * n + e.a] = @min(g[e.b * n + e.a], gap);
    }
    return g;
}

/// Fraction of a full shared border at which two frames are treated as one continuous surface.
///
/// Below one because a real border is never the whole rim: a grid chunk's neighbours divide its
/// edge between them, so any single neighbour holds a share of it. Tuned on `grid` and `chain`
/// closing while `two cliques become two territories that do not overlap` keeps its ocean.
const border_coupling: f32 = 0.5;


fn packDiscsCloud(arena: std.mem.Allocator, centres: []Vec2, radius: []const f32, ocean: f32) void {
    const n = centres.len;
    if (n == 0) return;
    var anchor: usize = 0;
    for (radius, 0..) |r, i| {
        if (r > radius[anchor] or (r == radius[anchor] and i < anchor)) anchor = i;
    }
    var area: f32 = 0;
    for (radius) |r| {
        const rr = r + ocean * 0.5;
        area += rr * rr;
    }
    // Tight overlapping seed so separateDiscs puffs into a blob, not a ring.
    //
    // Direction comes from the golden angle, not from the hash. `hash2` is a fine scatter over
    // thousands of notes and a poor one over twenty-three components: measured on a 24-component
    // vault it put eleven of them in a single quadrant and one in another, and `separateDiscs`
    // preserves the direction each disc started in — so every small island ended up on the same
    // side of the map, which is exactly what a reader reports as "they are all off to the
    // north-east". Twenty-three samples of *any* hash look clumpy; an irrational rotation is even
    // by construction at every count.
    //
    // The radius still comes from the hash, so the seeds do not form a visible ring — the failure
    // the plain golden-angle spiral had here before.
    const golden = std.math.pi * (3.0 - @sqrt(5.0));
    const R = @sqrt(@max(area, 1e-6)) * 0.55;
    var seeded: u32 = 0;
    for (centres, 0..) |*c, i| {
        if (i == anchor) {
            c.* = .{};
            continue;
        }
        const jt = hash2(@intCast(i));
        const ang = golden * @as(f32, @floatFromInt(seeded));
        seeded += 1;
        // `0.35 + …` keeps every seed clear of the anchor's centre, where the direction it is
        // eventually pushed out in would be decided by rounding.
        const rad = R * (0.35 + 0.65 * @abs(jt[0]));
        c.* = .{ .x = rad * @cos(ang), .y = rad * @sin(ang) };
    }
    // Components share no links at all, so there is no coupling to grade — one ocean between
    // every pair is exactly right here.
    separateDiscs(arena, centres, radius, ocean, null);
}

/// If the region graph is a tree, place discs as that tree (path, star, or branching) and
/// return true. Cyclic graphs return false so the caller can force-polish a cloud instead.
fn placeLinkageIfTree(
    arena: std.mem.Allocator,
    centres: []Vec2,
    radius: []const f32,
    edges: []const multilevel.Edge,
    ocean: f32,
) !bool {
    const n = centres.len;
    if (n == 0) return true;
    if (n == 1 or edges.len == 0) {
        packDiscsCloud(arena, centres, radius, ocean);
        return true;
    }

    const deg = try arena.alloc(u32, n);
    @memset(deg, 0);
    var m: u32 = 0;
    for (edges) |e| {
        if (e.a >= n or e.b >= n or e.a == e.b) continue;
        deg[e.a] += 1;
        deg[e.b] += 1;
        m += 1;
    }
    if (m + 1 != n) return false;

    const off = try arena.alloc(u32, n + 1);
    off[0] = 0;
    for (deg, 0..) |d, i| off[i + 1] = off[i] + d;
    const adj = try arena.alloc(u32, off[n]);
    const cur = try arena.alloc(u32, n);
    @memcpy(cur, off[0..n]);
    for (edges) |e| {
        if (e.a >= n or e.b >= n or e.a == e.b) continue;
        adj[cur[e.a]] = e.b;
        cur[e.a] += 1;
        adj[cur[e.b]] = e.a;
        cur[e.b] += 1;
    }

    var root: u32 = 0;
    for (radius, 0..) |r, i| {
        if (r > radius[root] or (r == radius[root] and i < root)) root = @intCast(i);
    }

    const parent = try arena.alloc(u32, n);
    @memset(parent, std.math.maxInt(u32));
    parent[root] = root;
    const order = try arena.alloc(u32, n);
    var qt: usize = 1;
    order[0] = root;
    var qh: usize = 0;
    while (qh < qt) : (qh += 1) {
        const u = order[qh];
        var ei = off[u];
        while (ei < off[u + 1]) : (ei += 1) {
            const v = adj[ei];
            if (parent[v] != std.math.maxInt(u32)) continue;
            parent[v] = u;
            order[qt] = v;
            qt += 1;
        }
    }
    if (qt != n) return false;

    @memset(centres, .{});
    const mass = try arena.alloc(f32, n);
    @memset(mass, 0);
    {
        var i = qt;
        while (i > 0) {
            i -= 1;
            const u = order[i];
            mass[u] = @max(radius[u], 1e-6);
            var ei = off[u];
            while (ei < off[u + 1]) : (ei += 1) {
                const v = adj[ei];
                if (parent[v] == u) mass[u] += mass[v];
            }
        }
    }
    const kids = try arena.alloc(u32, n);
    placeBalloon(centres, radius, mass, off, adj, parent, order, kids, ocean);
    const gaps: ?[]const f32 = null;
    separateDiscs(arena, centres, radius, ocean, gaps);
    pullAdjacent(centres, radius, edges, ocean, gaps);
    separateDiscs(arena, centres, radius, ocean, gaps);
    return true;
}

fn placeBalloon(
    centres: []Vec2,
    radius: []const f32,
    mass: []const f32,
    off: []const u32,
    adj: []const u32,
    parent: []const u32,
    order: []const u32,
    kids: []u32,
    ocean: f32,
) void {
    const tau = 2.0 * std.math.pi;
    for (order) |u| {
        var nk: usize = 0;
        var ei = off[u];
        while (ei < off[u + 1]) : (ei += 1) {
            const v = adj[ei];
            if (parent[v] != u) continue;
            kids[nk] = v;
            nk += 1;
        }
        if (nk == 0) continue;

        const incoming = if (parent[u] == u)
            0.0
        else
            std.math.atan2(centres[u].y - centres[parent[u]].y, centres[u].x - centres[parent[u]].x);

        if (nk == 1) {
            // Path continuation: keep walking the same way. A golden-angle child here is how
            // a chain used to curl into a spiral.
            const a = incoming;
            const v = kids[0];
            const d = radius[u] + radius[v] + ocean;
            centres[v] = .{ .x = centres[u].x + @cos(a) * d, .y = centres[u].y + @sin(a) * d };
            continue;
        }

        var sum_m: f32 = 0;
        var circ: f32 = 0;
        for (kids[0..nk]) |v| {
            sum_m += @max(mass[v], 1e-6);
            circ += 2.0 * radius[v] + ocean;
        }
        const ring = @max(circ / tau, 0);

        if (parent[u] == u) {
            var acc: f32 = 0;
            for (kids[0..nk]) |v| {
                const wedge = tau * (@max(mass[v], 1e-6) / sum_m);
                const a = acc + wedge * 0.5;
                const d = @max(radius[u] + radius[v] + ocean, ring);
                centres[v] = .{ .x = centres[u].x + @cos(a) * d, .y = centres[u].y + @sin(a) * d };
                acc += wedge;
            }
        } else {
            const gap: f32 = 0.8;
            const span = tau - gap;
            const base = incoming + gap * 0.5;
            var acc: f32 = 0;
            for (kids[0..nk]) |v| {
                const wedge = span * (@max(mass[v], 1e-6) / sum_m);
                const a = base + acc + wedge * 0.5;
                const d = @max(radius[u] + radius[v] + ocean, ring);
                centres[v] = .{ .x = centres[u].x + @cos(a) * d, .y = centres[u].y + @sin(a) * d };
                acc += wedge;
            }
        }
    }
}

fn hash2(i: u32) [2]f32 {
    var h = i *% 0x9e3779b9;
    h ^= h >> 16;
    h *%= 0x7feb352d;
    h ^= h >> 15;
    h *%= 0x846ca68b;
    h ^= h >> 16;
    const x = @as(f32, @floatFromInt(h & 0xffff)) / 32768.0 - 1.0;
    const y = @as(f32, @floatFromInt((h >> 16) & 0xffff)) / 32768.0 - 1.0;
    return .{ x, y };
}

/// Push overlapping discs apart until each pair clears `ocean` of extra gap. Positions from the
/// region-graph solve stay as the *arrangement*; this only inflates them into packed discs.
///
/// Pairs are resolved in ascending `(i, j)` order, Gauss-Seidel, so the result is a pure function
/// of the input. `DiscGrid` only decides which pairs are *asked about*; it never changes the order
/// they are answered in.
fn separateDiscs(
    arena: std.mem.Allocator,
    centres: []Vec2,
    radius: []const f32,
    ocean: f32,
    /// Optional `n*n` matrix of required clearance, in world units. Null means one ocean between
    /// every pair — right for components, which share no links at all. See `frameGaps`.
    gaps: ?[]const f32,
) void {
    if (centres.len < grid_min) return separateDiscsPairs(centres, radius, ocean, gaps);
    separateDiscsGrid(arena, centres, radius, ocean, gaps) catch
        separateDiscsPairs(centres, radius, ocean, gaps);
}

/// Below this the all-pairs sweep costs less than building the index, and every gauntlet shape
/// stays on exactly the code path its tests were written against.
const grid_min: usize = 96;

fn separateDiscsPairs(centres: []Vec2, radius: []const f32, ocean: f32, gaps: ?[]const f32) void {
    const n = centres.len;
    var iter: u32 = 0;
    while (iter < 24) : (iter += 1) {
        var moved = false;
        for (0..n) |i| {
            for (i + 1..n) |j| {
                if (resolvePair(centres, radius, ocean, gaps, i, j)) moved = true;
            }
        }
        if (!moved) break;
    }
}

/// Clearance this pair must clear, beyond the two radii.
fn gapOf(gaps: ?[]const f32, n: usize, i: usize, j: usize, ocean: f32) f32 {
    const g = gaps orelse return ocean;
    if (g.len != n * n) return ocean;
    return g[i * n + j];
}

fn resolvePair(
    centres: []Vec2,
    radius: []const f32,
    ocean: f32,
    gaps: ?[]const f32,
    i: usize,
    j: usize,
) bool {
    const dx = centres[j].x - centres[i].x;
    const dy = centres[j].y - centres[i].y;
    var d = @sqrt(dx * dx + dy * dy);
    const need = radius[i] + radius[j] + gapOf(gaps, centres.len, i, j, ocean);
    if (d >= need) return false;
    var ux: f32 = 1;
    var uy: f32 = 0;
    if (d > 1e-6) {
        ux = dx / d;
        uy = dy / d;
    } else {
        const jt = hash2(@intCast(i *% 31 +% @as(u32, @intCast(j))));
        const jd = @sqrt(jt[0] * jt[0] + jt[1] * jt[1]);
        if (jd > 1e-6) {
            ux = jt[0] / jd;
            uy = jt[1] / jd;
        }
        d = 0;
    }
    const push = (need - d) * 0.5;
    centres[i].x -= ux * push;
    centres[i].y -= uy * push;
    centres[j].x += ux * push;
    centres[j].y += uy * push;
    return true;
}

/// One hash grid per radius octave.
///
/// A territory's radius is `pitch·√members`, and community size stays heavy-tailed even after
/// `splitOversized` — so one cell size is either useless to the largest disc or hopeless for the
/// crowd. Each octave gets its own grid, sized to the discs it holds, and a disc queries every
/// octave in turn: a bounded number of queries, each over a 3x3 of cells that fit their contents.
///
/// The grid is hashed rather than dense because the arrangement it indexes is not uniform. A
/// force solve leaves a dense middle and a few far outliers, so a dense grid sized to the *span*
/// puts almost every disc in one cell — which is how the first cut of this ran slower than the
/// all-pairs sweep it replaced.
const Level = struct {
    cell: f32 = 1,
    /// Largest radius on this level, which is the reach a querying disc must allow for.
    maxr: f32 = 0,
    mask: u32 = 0,
    start: []u32 = &.{},
    items: []Item = &.{},

    const Item = struct { cx: i32, cy: i32, idx: u32 };

    fn coordOf(L: Level, p: Vec2) [2]i32 {
        return .{
            @intFromFloat(@floor(p.x / L.cell)),
            @intFromFloat(@floor(p.y / L.cell)),
        };
    }

    fn bucketOf(L: Level, cx: i32, cy: i32) u32 {
        var h: u32 = @bitCast(cx);
        h = h *% 0x9e3779b9;
        h ^= @as(u32, @bitCast(cy)) *% 0x85ebca6b;
        h ^= h >> 15;
        return h & L.mask;
    }
};

fn octaveOf(x: f32, base: f32) u8 {
    if (!(x > base)) return 0;
    return @intCast(@min(@as(i32, @intFromFloat(@floor(std.math.log2(x / base)))), 31));
}

fn separateDiscsGrid(
    arena: std.mem.Allocator,
    centres: []Vec2,
    radius: []const f32,
    ocean: f32,
    gaps: ?[]const f32,
) !void {
    const n = centres.len;

    var rmin: f32 = std.math.floatMax(f32);
    var rmax: f32 = 0;
    for (radius) |r| {
        rmin = @min(rmin, r);
        rmax = @max(rmax, r);
    }
    const base = @max(2 * rmin + ocean, 1e-4);
    const lv = try arena.alloc(u8, n);
    for (radius, lv) |r, *l| l.* = octaveOf(2 * r + ocean, base);
    const n_lv: usize = @as(usize, octaveOf(2 * rmax + ocean, base)) + 1;

    var scratch = std.heap.ArenaAllocator.init(arena);
    defer scratch.deinit();
    var cand: std.ArrayListUnmanaged(u32) = .empty;
    defer cand.deinit(arena);

    var iter: u32 = 0;
    while (iter < 24) : (iter += 1) {
        _ = scratch.reset(.retain_capacity);
        const levels = try buildLevels(scratch.allocator(), centres, radius, lv, n_lv, base);

        var moved = false;
        for (0..n) |i| {
            cand.clearRetainingCapacity();
            for (levels) |L| {
                if (L.items.len == 0) continue;
                const half = radius[i] + L.maxr + ocean;
                const lo = L.coordOf(.{ .x = centres[i].x - half, .y = centres[i].y - half });
                const hi = L.coordOf(.{ .x = centres[i].x + half, .y = centres[i].y + half });
                var cy = lo[1];
                while (cy <= hi[1]) : (cy += 1) {
                    var cx = lo[0];
                    while (cx <= hi[0]) : (cx += 1) {
                        const b = L.bucketOf(cx, cy);
                        for (L.items[L.start[b]..L.start[b + 1]]) |it| {
                            // Cells share buckets; without this a colliding cell would hand the
                            // same disc back twice and it would be pushed twice.
                            if (it.cx != cx or it.cy != cy) continue;
                            if (it.idx > i) try cand.append(arena, it.idx);
                        }
                    }
                }
            }
            std.mem.sort(u32, cand.items, {}, std.sort.asc(u32));
            for (cand.items) |j| {
                if (resolvePair(centres, radius, ocean, gaps, i, j)) moved = true;
            }
        }
        // The index describes where the discs were when this iteration began, so an iteration
        // that pushed nothing was quiet against positions that had not moved since. That is what
        // makes the early exit sound even though pushes land mid-sweep.
        if (!moved) break;
    }
}

fn buildLevels(
    a: std.mem.Allocator,
    centres: []const Vec2,
    radius: []const f32,
    lv: []const u8,
    n_lv: usize,
    base: f32,
) ![]Level {
    const levels = try a.alloc(Level, n_lv);
    const count = try a.alloc(u32, n_lv);
    @memset(count, 0);
    for (levels, 0..) |*L, l| {
        L.* = .{ .cell = base * std.math.pow(f32, 2.0, @floatFromInt(l + 1)) };
    }
    for (radius, lv) |r, l| {
        count[l] += 1;
        levels[l].maxr = @max(levels[l].maxr, r);
    }
    for (levels, count) |*L, c| {
        if (c == 0) continue;
        var buckets: u32 = 16;
        while (buckets < c * 2) buckets *|= 2;
        L.mask = buckets - 1;
        L.start = try a.alloc(u32, buckets + 1);
        @memset(L.start, 0);
        L.items = try a.alloc(Level.Item, c);
    }

    for (centres, lv) |p, l| {
        const L = levels[l];
        if (L.items.len == 0) continue;
        const c = L.coordOf(p);
        levels[l].start[L.bucketOf(c[0], c[1]) + 1] += 1;
    }
    for (levels) |*L| {
        if (L.items.len == 0) continue;
        for (1..L.start.len) |k| L.start[k] += L.start[k - 1];
    }
    const fill = try a.alloc([]u32, n_lv);
    for (fill, levels) |*f, L| {
        f.* = if (L.items.len == 0) &.{} else try a.dupe(u32, L.start[0 .. L.start.len - 1]);
    }
    for (centres, lv, 0..) |p, l, i| {
        const L = levels[l];
        if (L.items.len == 0) continue;
        const c = L.coordOf(p);
        const b = L.bucketOf(c[0], c[1]);
        L.items[fill[l][b]] = .{ .cx = c[0], .cy = c[1], .idx = @intCast(i) };
        fill[l][b] += 1;
    }
    return levels;
}

/// Blow the unit-space arrangement up to world units by matching *area*, not any one pair.
///
/// The mass-weighted region solve already spreads a big territory further than a small one, so
/// what it produces is the right arrangement at the wrong size. Scaling from the tightest linked
/// pair (the first cut) is hostage to a single coincidence: one pair the solve happened to leave
/// touching multiplies the whole map, every highway stretches with it, and the separation pass is
/// then handed a gas cloud to re-collapse. Matching total disc area to a target packing fraction
/// asks the same question of every disc at once, so no single pair can set the answer.
///
/// The extent is taken from trimmed percentiles: a force solve leaves a dense middle and a few
/// far strays, and the strays own the bounding box.
fn scaleToArea(arena: std.mem.Allocator, centres: []Vec2, radius: []const f32, ocean: f32) void {
    const n = centres.len;
    if (n < 2) return;
    const xs = arena.alloc(f32, n) catch return;
    defer arena.free(xs);
    const ys = arena.alloc(f32, n) catch return;
    defer arena.free(ys);
    for (centres, xs, ys) |c, *x, *y| {
        x.* = c.x;
        y.* = c.y;
    }
    std.mem.sort(f32, xs, {}, std.sort.asc(f32));
    std.mem.sort(f32, ys, {}, std.sort.asc(f32));
    const lo = n / 20;
    const hi = n - 1 - lo;
    // The trimmed box holds 90% of the discs in each axis; divide back out to estimate the whole.
    const span_x = @max(xs[hi] - xs[lo], 1e-6);
    const span_y = @max(ys[hi] - ys[lo], 1e-6);
    const area_unit = (span_x * span_y) / 0.81;

    var area_world: f32 = 0;
    for (radius) |r| {
        const rr = r + ocean * 0.5;
        area_world += std.math.pi * rr * rr;
    }
    // Near what a plane of unequal discs can actually reach, and deliberately not lower: frames
    // nest three deep on a Wikipedia-sized vault, so a fill charged per level compounds. At 0.55
    // the map came out 0.55³ dense, every distance inflated by two and a half, and link spread
    // and highway length went with it. The ocean is charged explicitly as `ocean`; it does not
    // need a second helping of slack here.
    const fill: f32 = 0.78;
    const s = @sqrt(area_world / (fill * area_unit));
    if (!(s > 0) or !std.math.isFinite(s)) return;
    for (centres) |*c| {
        c.x *= s;
        c.y *= s;
    }
}

/// Break ties so a uniform scale has a direction to work with. Two regions that the force
/// solve left on top of each other would otherwise demand infinite scale.
fn jitterCoincident(centres: []Vec2) void {
    const n = centres.len;
    for (0..n) |i| {
        for (0..i) |j| {
            const dx = centres[i].x - centres[j].x;
            const dy = centres[i].y - centres[j].y;
            if (dx * dx + dy * dy > 1e-8) continue;
            const jt = hash2(@intCast(i));
            centres[i].x += jt[0] * 0.01;
            centres[i].y += jt[1] * 0.01;
        }
    }
}

/// Short polish: pull region-graph neighbours together until their discs almost touch.
/// Unlinked pairs are left to the scale; this is what stops a highway spanning the vault
/// when the two territories share many notes' links.
fn pullAdjacent(
    centres: []Vec2,
    radius: []const f32,
    edges: []const multilevel.Edge,
    ocean: f32,
    gaps: ?[]const f32,
) void {
    var iter: u32 = 0;
    while (iter < 8) : (iter += 1) {
        var moved = false;
        for (edges) |e| {
            if (e.a >= centres.len or e.b >= centres.len or e.a == e.b) continue;
            const dx = centres[e.b].x - centres[e.a].x;
            const dy = centres[e.b].y - centres[e.a].y;
            const d = @sqrt(dx * dx + dy * dy);
            const need = radius[e.a] + radius[e.b] +
                gapOf(gaps, centres.len, e.a, e.b, ocean);
            if (d <= need * 1.02 or d < 1e-6) continue;
            moved = true;
            const ux = dx / d;
            const uy = dy / d;
            const pull = (d - need) * 0.35;
            centres[e.a].x += ux * pull;
            centres[e.a].y += uy * pull;
            centres[e.b].x -= ux * pull;
            centres[e.b].y -= uy * pull;
        }
        if (!moved) break;
    }
}

/// Lay disconnected component discs in a cloud around the largest one.
///
/// There are no links between components, so there is no linkage shape to honour — a packed
/// blob is the honest macro form. A golden-angle spiral was compact and deterministic, and
/// also the one shape every vault of islands shared, which is why gauntlet orphans looked
/// like a sunflower. `pack_gap` used to inflate the spiral's area accumulator; charging it
/// to the ocean here keeps the same "peers only" rule so a Wikipedia-sized giant is not
/// pushed out by √gap. `+ r` on both discs still puts edges, not centres, on the contact.
fn packComponents(
    arena: std.mem.Allocator,
    out: Result,
    notes_csr: Csr,
    radii: []const f32,
    centres: []Vec2,
    opts: Options,
) !void {
    if (out.n_comp <= 1) return;

    const ocean = opts.spacing * opts.note_r * @sqrt(@max(opts.pack_gap, 1));
    packDiscsCloud(arena, centres, radii, ocean);
    for (0..out.n_comp) |c| {
        const t = centres[c];
        for (notes_csr.slice(@intCast(c))) |note| {
            out.pos[note].x += t.x;
            out.pos[note].y += t.y;
        }
    }
}

/// Median leaf spacing of one component, from its members' already-written positions.
fn componentMedian(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    pos: []const Vec2,
    members: []const u32,
) !f32 {
    if (members.len < 2) return 0;
    if (members.len == 2) return dist(pos[members[0]], pos[members[1]]);
    const tmp = try arena.alloc(Vec2, members.len);
    const keys = try arena.alloc(u32, members.len);
    @memset(keys, 0);
    for (members, tmp) |note, *p| p.* = pos[note];
    return spatial.medianSpacing(gpa, tmp, keys);
}

fn dist(a: Vec2, b: Vec2) f32 {
    const dx = a.x - b.x;
    const dy = a.y - b.y;
    return @sqrt(dx * dx + dy * dy);
}

/// Put the centre of the content at the origin.
///
/// `World.extent` reports a radius *about the origin*, `graph.zig` builds `world_bounds` as
/// `{-r, -r, 2r, 2r}`, and `vaultExtentsPose` hardcodes centre `(0, 0)`. All three were true only
/// because the old packer happened to put the biggest island there. Doing it explicitly here lets
/// those three call sites keep their assumption honestly.
fn recentre(pos: []Vec2) void {
    if (pos.len == 0) return;
    var lo = pos[0];
    var hi = pos[0];
    for (pos) |p| {
        lo.x = @min(lo.x, p.x);
        lo.y = @min(lo.y, p.y);
        hi.x = @max(hi.x, p.x);
        hi.y = @max(hi.y, p.y);
    }
    const cx = (lo.x + hi.x) * 0.5;
    const cy = (lo.y + hi.y) * 0.5;
    for (pos) |*p| {
        p.x -= cx;
        p.y -= cy;
    }
}

// ---- grouping -------------------------------------------------------------------------------

/// Items grouped by key, as one counting-sorted array plus offsets. A plain counting sort rather
/// than a list-of-lists because the component count is tiny and the item count is not.
const Csr = struct {
    items: []u32 = &.{},
    off: []u32 = &.{},

    fn slice(self: Csr, key: u32) []const u32 {
        return self.items[self.off[key]..self.off[key + 1]];
    }
};

fn bucket(arena: std.mem.Allocator, keys: []const u32, n_keys: u32, n: usize) !Csr {
    const off = try arena.alloc(u32, n_keys + 1);
    @memset(off, 0);
    for (keys[0..n]) |k| off[k + 1] += 1;
    for (1..off.len) |i| off[i] += off[i - 1];
    const items = try arena.alloc(u32, n);
    const cur = try arena.alloc(u32, n_keys);
    @memcpy(cur, off[0..n_keys]);
    for (keys[0..n], 0..) |k, i| {
        items[cur[k]] = @intCast(i);
        cur[k] += 1;
    }
    return .{ .items = items, .off = off };
}

// ---- tests ----------------------------------------------------------------------------------

const testing = std.testing;

/// A ring of `n` notes, plus `orphans` notes with no links at all.
fn ringFixture(arena: std.mem.Allocator, n: u32, orphans: u32) !struct { edges: []Edge, paths: [][]const u8 } {
    const edges = try arena.alloc(Edge, n);
    for (edges, 0..) |*e, i| e.* = .{ .a = @intCast(i), .b = @intCast((i + 1) % n) };
    const paths = try arena.alloc([]const u8, n + orphans);
    for (paths, 0..) |*p, i| p.* = try std.fmt.allocPrint(arena, "dir{d}/note{d:0>5}.md", .{ i % 3, i });
    return .{ .edges = edges, .paths = paths };
}

test "leaves are spaced far enough apart not to overlap" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const fx = try ringFixture(arena_state.allocator(), 400, 40);

    var res = try solve(testing.allocator, 440, fx.edges, fx.paths, .{ .note_r = 4, .spacing = 2.6 });
    defer res.deinit(testing.allocator);

    // The whole point of the layout owning positions: it can guarantee this, and no grouping
    // built on top of it can. Two notes drawn at radius r overlap whenever they are closer
    // than 2r, so this is the condition for a non-overlapping map.
    // Above 2.0 is the whole claim: two discs of radius `r` overlap below `2r`. The upper bound
    // is loose because `Result.spacing` is a Hilbert-gap proxy that reads above the true
    // nearest-neighbour spacing the interiors are scaled to — see `Result.spacing`.
    try testing.expect(res.spacing > 2.0);
    try testing.expect(res.spacing < 2.6 * 1.6);
}

test "unconnected islands land in disjoint discs" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Three separate rings of 30, sharing no links.
    const n: u32 = 90;
    var edges: std.ArrayListUnmanaged(Edge) = .empty;
    for (0..3) |g| {
        const base: u32 = @intCast(g * 30);
        for (0..30) |i| {
            try edges.append(arena, .{ .a = base + @as(u32, @intCast(i)), .b = base + @as(u32, @intCast((i + 1) % 30)) });
        }
    }
    const paths = try arena.alloc([]const u8, n);
    for (paths, 0..) |*p, i| p.* = try std.fmt.allocPrint(arena, "n{d}.md", .{i});

    var res = try solve(testing.allocator, n, edges.items, paths, .{ .note_r = 4 });
    defer res.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 3), res.n_comp);

    // Each component's bounding disc must clear every other's. This is the guarantee that used
    // to live in `fold.Cell.comp`; a proximity hierarchy cannot enforce it, so the layout must.
    var ctr: [3]Vec2 = @splat(.{});
    var cnt: [3]f32 = @splat(0);
    for (res.pos, res.comp) |p, c| {
        ctr[c].x += p.x;
        ctr[c].y += p.y;
        cnt[c] += 1;
    }
    for (&ctr, cnt) |*m, k| {
        m.x /= k;
        m.y /= k;
    }
    var rad: [3]f32 = @splat(0);
    for (res.pos, res.comp) |p, c| {
        const dx = p.x - ctr[c].x;
        const dy = p.y - ctr[c].y;
        rad[c] = @max(rad[c], @sqrt(dx * dx + dy * dy));
    }
    for (0..3) |a| {
        for (a + 1..3) |b| {
            const dx = ctr[a].x - ctr[b].x;
            const dy = ctr[a].y - ctr[b].y;
            try testing.expect(@sqrt(dx * dx + dy * dy) > rad[a] + rad[b]);
        }
    }
}

test "a handful of islands keep their leaves apart without emptying the map" {
    // The fizzy-vault shape: a few tiny components, no giant. Packing used to mix the solver's
    // unit space with a world-space island margin and then scale the whole map by the leaf
    // median, which sat each linked pair on top of itself (so they coalesced at every zoom
    // the budget would otherwise have resolved) and threw the next island tens of leaf-spacings
    // away. A Wikipedia-scale vault is one component and never hit this.
    const note_r: f32 = 4;
    const spacing: f32 = 2.6;
    const pitch = spacing * note_r;
    const edges = [_]Edge{
        .{ .a = 0, .b = 1 },
        .{ .a = 2, .b = 3 },
        .{ .a = 4, .b = 5 },
    };
    const paths = [_][]const u8{ "a.md", "b.md", "c.md", "d.md", "e.md", "f.md" };
    var res = try solve(testing.allocator, 6, &edges, &paths, .{ .note_r = note_r, .spacing = spacing });
    defer res.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 3), res.n_comp);

    const pair_d = [_]f32{
        dist(res.pos[0], res.pos[1]),
        dist(res.pos[2], res.pos[3]),
        dist(res.pos[4], res.pos[5]),
    };
    for (pair_d) |d| {
        try testing.expect(d > pitch * 0.5);
        try testing.expect(d < pitch * 2.5);
    }

    var ctr: [3]Vec2 = @splat(.{});
    for (0..3) |g| {
        ctr[g] = .{
            .x = (res.pos[g * 2].x + res.pos[g * 2 + 1].x) * 0.5,
            .y = (res.pos[g * 2].y + res.pos[g * 2 + 1].y) * 0.5,
        };
    }
    var max_island: f32 = 0;
    for (0..3) |a| {
        for (a + 1..3) |b| {
            max_island = @max(max_island, dist(ctr[a], ctr[b]));
        }
    }
    // One-to-two leaf pitches of air between small islands, not the ~50x blow-up mixed units
    // produced. Fit-to-extents then lands at a zoom where a two-note parent clears split_px.
    try testing.expect(max_island < pitch * 8);
}

test "islands pack as a cloud, not a golden spiral" {
    // Twelve linked pairs, no edges between pairs. The old packer planted them on a sunflower
    // at i × golden-angle; a cloud's angles should not line up with that sequence.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const n_islands: u32 = 12;
    const n: u32 = n_islands * 2;
    var edges: std.ArrayListUnmanaged(Edge) = .empty;
    const paths = try arena.alloc([]const u8, n);
    for (0..n_islands) |g| {
        const a: u32 = @intCast(g * 2);
        try edges.append(arena, .{ .a = a, .b = a + 1 });
        paths[a] = try std.fmt.allocPrint(arena, "i{d}/a.md", .{g});
        paths[a + 1] = try std.fmt.allocPrint(arena, "i{d}/b.md", .{g});
    }

    var res = try solve(testing.allocator, n, edges.items, paths, .{ .note_r = 4 });
    defer res.deinit(testing.allocator);
    try testing.expectEqual(n_islands, res.n_comp);

    var ctr: [12]Vec2 = undefined;
    for (0..n_islands) |g| {
        ctr[g] = .{
            .x = (res.pos[g * 2].x + res.pos[g * 2 + 1].x) * 0.5,
            .y = (res.pos[g * 2].y + res.pos[g * 2 + 1].y) * 0.5,
        };
    }
    var cx: f32 = 0;
    var cy: f32 = 0;
    for (ctr) |p| {
        cx += p.x;
        cy += p.y;
    }
    cx /= @floatFromInt(n_islands);
    cy /= @floatFromInt(n_islands);

    const golden = std.math.pi * (3.0 - @sqrt(5.0));
    const tau = 2.0 * std.math.pi;
    var hits: u32 = 0;
    for (ctr, 0..) |p, i| {
        const a = std.math.atan2(p.y - cy, p.x - cx);
        const expect = @as(f32, @floatFromInt(i)) * golden;
        var d = a - expect;
        while (d > std.math.pi) d -= tau;
        while (d < -std.math.pi) d += tau;
        if (@abs(d) < 0.3) hits += 1;
    }
    try testing.expect(hits < n_islands / 2);
}

test "the content is centred on the origin" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const fx = try ringFixture(arena_state.allocator(), 200, 20);

    var res = try solve(testing.allocator, 220, fx.edges, fx.paths, .{ .note_r = 4 });
    defer res.deinit(testing.allocator);

    // `World.extent` reports a radius about the origin and `vaultExtentsPose` hardcodes centre
    // (0, 0); both are only correct if the layout puts the content there.
    var lo = res.pos[0];
    var hi = res.pos[0];
    for (res.pos) |p| {
        lo.x = @min(lo.x, p.x);
        lo.y = @min(lo.y, p.y);
        hi.x = @max(hi.x, p.x);
        hi.y = @max(hi.y, p.y);
    }
    const span = @max(hi.x - lo.x, hi.y - lo.y);
    try testing.expect(@abs(lo.x + hi.x) < span * 1e-3);
    try testing.expect(@abs(lo.y + hi.y) < span * 1e-3);
}

test "the same graph lays out identically twice" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const fx = try ringFixture(arena_state.allocator(), 150, 10);

    var a = try solve(testing.allocator, 160, fx.edges, fx.paths, .{ .note_r = 4 });
    defer a.deinit(testing.allocator);
    var b = try solve(testing.allocator, 160, fx.edges, fx.paths, .{ .note_r = 4 });
    defer b.deinit(testing.allocator);

    // Positions are about to be persisted and diffed against; a solve that wanders between runs
    // would make every republish look like every note moved.
    for (a.pos, b.pos) |p, q| {
        try testing.expectEqual(p.x, q.x);
        try testing.expectEqual(p.y, q.y);
    }
}

test "a cancelled solve gives up" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const fx = try ringFixture(arena_state.allocator(), 300, 0);

    var flag = std.atomic.Value(bool).init(true);
    try testing.expectError(error.Canceled, solve(testing.allocator, 300, fx.edges, fx.paths, .{ .cancel = &flag }));
}

test "an empty or single-note vault is not a special case at the call site" {
    var a = try solve(testing.allocator, 0, &.{}, &.{}, .{});
    defer a.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), a.pos.len);

    var b = try solve(testing.allocator, 1, &.{}, &.{"only.md"}, .{});
    defer b.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), b.pos.len);
}

test "two cliques become two territories that do not overlap" {
    // Stage 2 gate, restated for interiors: a community's notes stay inside their own territory,
    // and the two packed discs clear each other. Before `solveInteriors` every note sat exactly on
    // its region centre, and this test asserted that instead.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const n_each: u32 = 12;
    const n: u32 = n_each * 2;
    var edges: std.ArrayListUnmanaged(Edge) = .empty;
    for (0..2) |g| {
        const base: u32 = @intCast(g * n_each);
        for (0..n_each) |i| {
            for (i + 1..n_each) |j| {
                try edges.append(arena, .{ .a = base + @as(u32, @intCast(i)), .b = base + @as(u32, @intCast(j)) });
            }
        }
    }
    try edges.append(arena, .{ .a = 0, .b = n_each });
    const paths = try arena.alloc([]const u8, n);
    for (paths, 0..) |*p, i| p.* = try std.fmt.allocPrint(arena, "n{d}.md", .{i});

    var res = try solve(testing.allocator, n, edges.items, paths, .{ .note_r = 4, .territories = true });
    defer res.deinit(testing.allocator);

    const a = discOf(res.pos[0..n_each]);
    const b = discOf(res.pos[n_each..]);
    // Ocean, not merely non-overlap: the gap is what Hilbert chunking recovers as a boundary.
    try testing.expect(dist(a.centre, b.centre) > a.r + b.r + default_spacing * 4.0);

    // Every note is nearer its own capital than the other one, which is what makes the two discs
    // two places rather than one smear.
    for (res.pos[0..n_each]) |p| try testing.expect(dist(p, a.centre) < dist(p, b.centre));
    for (res.pos[n_each..]) |p| try testing.expect(dist(p, b.centre) < dist(p, a.centre));
}

/// Centroid and bounding radius of a set of placed notes, for the territory tests.
fn discOf(pts: []const Vec2) struct { centre: Vec2, r: f32 } {
    var cx: f64 = 0;
    var cy: f64 = 0;
    for (pts) |p| {
        cx += p.x;
        cy += p.y;
    }
    const inv = 1.0 / @as(f64, @floatFromInt(pts.len));
    const c: Vec2 = .{ .x = @floatCast(cx * inv), .y = @floatCast(cy * inv) };
    var r: f32 = 0;
    for (pts) |p| r = @max(r, dist(p, c));
    return .{ .centre = c, .r = r };
}

test "a chain of territories stays a chain, not a blown-apart ring" {
    // Three cliques in a path. Uniform scale of the region-graph solve must keep A–C
    // farther than A–B; the old all-pairs shove ignored that and threw them into a ring.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const n_each: u32 = 10;
    const n: u32 = n_each * 3;
    var edges: std.ArrayListUnmanaged(Edge) = .empty;
    for (0..3) |g| {
        const base: u32 = @intCast(g * n_each);
        for (0..n_each) |i| {
            for (i + 1..n_each) |j| {
                try edges.append(arena, .{ .a = base + @as(u32, @intCast(i)), .b = base + @as(u32, @intCast(j)) });
            }
        }
    }
    try edges.append(arena, .{ .a = n_each - 1, .b = n_each });
    try edges.append(arena, .{ .a = n_each * 2 - 1, .b = n_each * 2 });
    const paths = try arena.alloc([]const u8, n);
    for (paths, 0..) |*p, i| p.* = try std.fmt.allocPrint(arena, "n{d}.md", .{i});

    var res = try solve(testing.allocator, n, edges.items, paths, .{ .note_r = 4, .territories = true });
    defer res.deinit(testing.allocator);

    const a = res.pos[0];
    const b = res.pos[n_each];
    const c = res.pos[n_each * 2];
    const ab = dist(a, b);
    const bc = dist(b, c);
    const ac = dist(a, c);
    try testing.expect(ab > 1);
    try testing.expect(bc > 1);
    try testing.expect(ac > ab * 1.15);
    try testing.expect(ac > bc * 1.15);
}

test "a star of territories keeps every spoke near packed length" {
    // Hub clique plus leaf cliques. Scale-from-all-pairs used to let two leaves that the force
    // solve sat close inflate the map until the hub–leaf highways spanned several region radii.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const n_hub: u32 = 12;
    const n_leaf: u32 = 8;
    const n_leaves: u32 = 6;
    const n: u32 = n_hub + n_leaf * n_leaves;
    var edges: std.ArrayListUnmanaged(Edge) = .empty;
    for (0..n_hub) |i| {
        for (i + 1..n_hub) |j| {
            try edges.append(arena, .{ .a = @intCast(i), .b = @intCast(j) });
        }
    }
    var base: u32 = n_hub;
    var spoke_i: u32 = 0;
    while (spoke_i < n_leaves) : (spoke_i += 1) {
        for (0..n_leaf) |i| {
            for (i + 1..n_leaf) |j| {
                try edges.append(arena, .{ .a = base + @as(u32, @intCast(i)), .b = base + @as(u32, @intCast(j)) });
            }
        }
        try edges.append(arena, .{ .a = spoke_i % n_hub, .b = base });
        base += n_leaf;
    }
    const paths = try arena.alloc([]const u8, n);
    for (paths, 0..) |*p, i| p.* = try std.fmt.allocPrint(arena, "n{d}.md", .{i});

    var res = try solve(testing.allocator, n, edges.items, paths, .{ .note_r = 4, .territories = true });
    defer res.deinit(testing.allocator);

    const hub = discOf(res.pos[0..n_hub]);
    var min_spoke: f32 = std.math.floatMax(f32);
    var max_spoke: f32 = 0;
    var leaf: u32 = 0;
    while (leaf < n_leaves) : (leaf += 1) {
        const lo = n_hub + leaf * n_leaf;
        const spoke = discOf(res.pos[lo .. lo + n_leaf]);
        // Centre-to-centre less the two radii: the highway itself, not the territories it joins.
        const d = dist(hub.centre, spoke.centre) - hub.r - spoke.r;
        min_spoke = @min(min_spoke, d);
        max_spoke = @max(max_spoke, d);
    }
    const ocean = default_spacing * 4.0 * territory_ocean;
    // Every spoke sits about one ocean out, and no spoke is flung: the failure this guards is a
    // scale set by one accidental pair, which used to stretch every highway with it.
    try testing.expect(min_spoke > 0);
    try testing.expect(max_spoke < ocean * 4.0);
    try testing.expect(max_spoke < min_spoke * 3.0);
}

test "reusing an unchanged territory gives the same map a cold solve would" {
    // The memo is only legitimate if it changes nothing. `Options.reuse` skips solving a territory
    // whose membership came back identical, on the grounds that an interior is a deterministic
    // function of its own subgraph — so the whole claim is that these two runs agree exactly. If
    // they can differ, this is seeding by another name, and the map you close stops being the map
    // you reopen.
    const gpa = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Two cliques and a bridge: enough that the clustering finds real territories.
    const n_each: u32 = 14;
    const n: u32 = n_each * 3;
    var edges: std.ArrayListUnmanaged(Edge) = .empty;
    for (0..3) |g| {
        const base: u32 = @intCast(g * n_each);
        for (0..n_each) |i| {
            for (i + 1..n_each) |j| {
                try edges.append(arena, .{ .a = base + @as(u32, @intCast(i)), .b = base + @as(u32, @intCast(j)) });
            }
        }
    }
    try edges.append(arena, .{ .a = 0, .b = n_each });
    try edges.append(arena, .{ .a = n_each, .b = n_each * 2 });

    const paths = try arena.alloc([]const u8, n);
    for (paths, 0..) |*p, i| p.* = try std.fmt.allocPrint(arena, "n{d}.md", .{i});
    const ids = try arena.alloc(u64, n);
    for (ids, 0..) |*d, i| d.* = i + 1000;

    var cold = try solve(gpa, n, edges.items, paths, .{ .note_r = 4, .ids = ids });
    defer cold.deinit(gpa);

    var warm = try solve(gpa, n, edges.items, paths, .{
        .note_r = 4,
        .ids = ids,
        .reuse = .{ .ids = cold.ids, .inner = cold.inner, .home = cold.home, .frames = cold.frames },
    });
    defer warm.deinit(gpa);

    try testing.expect(reused_interiors > 0); // otherwise this test proves nothing
    try testing.expect(reused_frames > 0);
    for (cold.pos, warm.pos) |a, b| {
        try testing.expectEqual(a.x, b.x);
        try testing.expectEqual(a.y, b.y);
    }
}

test "a memo from a different note set is refused rather than misapplied" {
    // Note *indices* shift when a note is inserted, so a memo keyed by index would compare one
    // note's territory against another's and silently reuse the wrong interior. Identity is the
    // caller's stable id; a territory whose members are not all present under the same hash has to
    // fall through to a real solve.
    const gpa = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const n: u32 = 40;
    var edges: std.ArrayListUnmanaged(Edge) = .empty;
    for (0..n - 1) |i| try edges.append(arena, .{ .a = @intCast(i), .b = @intCast(i + 1) });
    const paths = try arena.alloc([]const u8, n);
    for (paths, 0..) |*p, i| p.* = try std.fmt.allocPrint(arena, "n{d}.md", .{i});

    // Same graph, completely different ids: nothing can match.
    const ids_a = try arena.alloc(u64, n);
    for (ids_a, 0..) |*d, i| d.* = i + 1;
    const ids_b = try arena.alloc(u64, n);
    for (ids_b, 0..) |*d, i| d.* = i + 500_000;

    var first = try solve(gpa, n, edges.items, paths, .{ .note_r = 4, .ids = ids_a });
    defer first.deinit(gpa);

    var second = try solve(gpa, n, edges.items, paths, .{
        .note_r = 4,
        .ids = ids_b,
        .reuse = .{ .ids = first.ids, .inner = first.inner, .home = first.home },
    });
    defer second.deinit(gpa);
    try testing.expectEqual(@as(u32, 0), reused_interiors);
}
