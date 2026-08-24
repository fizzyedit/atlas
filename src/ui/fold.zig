//! One hierarchy for the whole vault.
//!
//! Today the graph carries four overlapping structures: `multilevel.Ladder` (link coarsening),
//! `layout_full`'s flat positions, `lod.Pyramid` (the ladder, then continued *by position* once
//! link structure runs out), and `quadlod.Tree` (a component forest rebuilt from those positions).
//! They disagree, which is what a "half-fine/half-coarse" frame actually is.
//!
//! This file is the replacement for all four: a single arity-N coarsening ladder, and nothing
//! else. Positions are derived from it (`containment.zig`) rather than being an input to it.
//!
//! Two design choices carry most of the weight:
//!
//! **Folders are weak links, not a separate mechanism.** Notes are sorted by path and consecutive
//! notes get an edge at `folder_w`. Because lexicographic order on paths *is* a depth-first walk of
//! the folder tree, one edge per note buys: same-directory notes adjacent, sibling directories
//! adjacent, and parent directories next to their children. So "group by links, and by folder when
//! there are no links" needs no code at all — an unlinked note's only edges are to its
//! path-neighbours, so it coarsens with its folder-mates automatically. No orphan special case, no
//! folder-cohesion force, no virtual nodes.
//!
//! An earlier attempt gave each directory a node linked to all its members. That fails: the folder
//! node is itself claimed into a group, so it can only pull `arity - 1` members before the rest are
//! cut adrift and bundled with strangers. A chain has no such bottleneck.
//!
//! `folder_w` is deliberately small. On a real wikilink graph (Simple English Wikipedia, 284k
//! articles) linked pairs shared a category 8.6% of the time against a 1.93% random baseline — a
//! 4.5× lift. Real, but weak, so folder membership is a *weight*, never a constraint.
//!
//! **Arity is a free parameter, independent of the data's shape.** A binary tree of a million
//! notes does not need a 20-level binary hierarchy; it coarsens into a 7-ary ladder of depth ~7,
//! grouping seven tree-nodes per cell. The ladder is a re-grouping of the vault, not a picture of
//! it — which is why depth can become zoom instead of a spatial axis, and why the same system
//! works at 5 notes and at 1,000,000.
//!
//! No dvui, no filesystem, no vault types — this is plain graph math over `Edge` pairs so it can
//! be tested headlessly and eventually lifted into its own package.

const std = @import("std");
const radix = @import("radix.zig");

pub const invalid: u32 = std.math.maxInt(u32);

/// Children per cell. Both nest exactly on the hex lattice (see `hex.zig`); 7 is the
/// centre-plus-six-neighbours fold and reaches 1M in 8 levels against 4's 10.
pub const Arity = enum(u8) {
    four = 4,
    seven = 7,

    pub fn n(self: Arity) usize {
        return @intFromEnum(self);
    }
};

pub const Edge = struct { a: u32, b: u32, w: f32 = 1.0 };

/// Link weight between two children of the same cell, used by `containment.zig` to pick which
/// child lands in which hex slot. Indices are positions within the parent's child list, so they
/// fit in a `u8` for any sane arity.
pub const SibPair = struct { i: u8, j: u8, w: f32 };

/// One cell's pull toward something *outside* it: child `child` of this cell links to the subtree
/// under `toward`, with total weight `w`.
///
/// `SibPair` records a link once, at its LCA, which makes it invisible from below — when
/// `containment` places cell C's children it can see links *among* them and nothing else, so a
/// child whose real neighbours lie one cell over has no reason to sit on that side. This is the
/// missing half: `toward` is always a sibling of C (the other branch at the LCA), and siblings are
/// placed together when their parent expands, so by the time C's own children are placed
/// `field.pos[toward]` is already known. Direction only — see `containment.arrangementCost`.
pub const ExtPull = struct { child: u8, toward: u32, w: f32 };

pub const Cell = struct {
    parent: u32 = invalid,
    child_start: u32 = 0,
    child_count: u16 = 0,
    pair_start: u32 = 0,
    pair_count: u16 = 0,
    ext_start: u32 = 0,
    ext_count: u16 = 0,
    /// Real notes beneath this cell. Folder nodes never count.
    count: u32 = 0,
    /// Depth *below the root*, assigned by `assignRanges` — which overwrites whatever the
    /// coarsening put here, so during a build it counts up from the leaves and after one it counts
    /// down from the root. Read it only after `build` returns.
    level: u16 = 0,
    /// Levels of ladder *beneath* this cell: 0 for a leaf, the subtree's depth for a root. The
    /// counterpart to `level`, and the one anything reasoning about how much room a subtree needs
    /// wants.
    height: u16 = 0,
    /// Total incident link *count* of the notes beneath this cell — raw degree, summed.
    ///
    /// `count` is how many notes a cell holds, which is the right measure of the *area* it needs
    /// and the wrong one for how much it matters. Every leaf has a count of exactly one, so at the
    /// zoom where notes are drawn individually — the one a reader spends most of their time at —
    /// every body in the field has identical mass and nothing can behave like a star. Link weight
    /// is the measure that separates a hub from a stub, and it is free: the edge list is already
    /// here. Real links only; the folder chain is a placement prior, not evidence of importance.
    weight: f32 = 0,
    /// Sum of file sizes (bytes) of notes beneath this cell. Gravity uses a log of this as
    /// extra inertial mass and push — a long note claims more interior-entry room than a stub
    /// with the same degree. 0 when the caller did not pass `Options.bodies`.
    body: f32 = 0,
    /// Set iff this cell is a single real note.
    note: u32 = invalid,
    /// Connected component of the *link* graph this cell belongs to. Coarsening never merges
    /// across it, so a coalesced cell can never mix two unconnected islands.
    comp: u32 = 0,
    /// Contiguous [ls, le) range over `note_at` — every note beneath this cell. Lets a link be
    /// lifted to the cell that currently owns it with two array reads and no ancestor walk.
    ls: u32 = 0,
    le: u32 = 0,

    pub fn isLeaf(self: Cell) bool {
        return self.child_count == 0;
    }
};

pub const Ladder = struct {
    cells: []Cell = &.{},
    children: []u32 = &.{},
    pairs: []SibPair = &.{},
    ext: []ExtPull = &.{},
    /// note id -> the leaf cell holding it (`invalid` if the note was not placed).
    leaf_cell: []u32 = &.{},
    /// dfs slot -> note id, and its inverse.
    note_at: []u32 = &.{},
    slot_of: []u32 = &.{},
    /// One root per connected component of the link graph (plus one for the pooled orphans).
    /// They are *packed* in the plane by `containment.zig` rather than folded under a single
    /// root — folding them would put unrelated islands inside one disc, which is exactly the
    /// overlap that made a vault of discrete islands read as one converging blob.
    roots: []u32 = &.{},
    depth: u16 = 0,

    pub fn deinit(self: *Ladder, gpa: std.mem.Allocator) void {
        gpa.free(self.cells);
        gpa.free(self.children);
        gpa.free(self.pairs);
        gpa.free(self.ext);
        gpa.free(self.leaf_cell);
        gpa.free(self.note_at);
        gpa.free(self.slot_of);
        gpa.free(self.roots);
        self.* = .{};
    }

    pub fn childrenOf(self: Ladder, id: u32) []const u32 {
        const c = self.cells[id];
        return self.children[c.child_start..][0..c.child_count];
    }

    pub fn pairsOf(self: Ladder, id: u32) []const SibPair {
        const c = self.cells[id];
        return self.pairs[c.pair_start..][0..c.pair_count];
    }

    pub fn extOf(self: Ladder, id: u32) []const ExtPull {
        const c = self.cells[id];
        return self.ext[c.ext_start..][0..c.ext_count];
    }
};

pub const Options = struct {
    arity: Arity = .seven,
    /// Weight of note↔folder and folder↔parent-folder edges, against 1.0 for a *typical* real
    /// link — see `degree_norm`, which is what keeps "typical" meaning 1.0.
    folder_w: f32 = 0.25,
    /// How hard to discount a link for the popularity of its endpoints. 0 is off; 1 is the full
    /// `1/√(deg_a · deg_b)` normalisation. See `degreeNormalised`.
    degree_norm: f32 = 1.0,
    /// Safety stop. A correct run terminates in ~log_arity(n) levels.
    max_levels: u16 = 40,
    /// Checked between coarsening levels so a caller running this on a worker can abandon it.
    ///
    /// Coarsening a 283,878-note vault is a double-digit number of seconds, and the one caller
    /// that has to *wait* for it is application shutdown — which joins the worker because the code
    /// it is running lives in a dylib that is about to be unloaded. Without a check in here that
    /// join is the whole build, and closing the editor mid-build looks like a hang.
    cancel: ?*std.atomic.Value(bool) = null,
    /// Parallel to notes `0..n_notes`: file size in bytes. Empty means every body is 0.
    /// Gravity placement uses `log(1+body)` as extra mass and personal space, so a save that
    /// grows a document without adding links still opens more room for its interior.
    bodies: []const f32 = &.{},
};

/// Discount every link by how popular its endpoints are: `w · K^p / (deg_a · deg_b)^(p/2)`.
///
/// On a wiki most links are stopwords. Two thirds of Simple English Wikipedia's edges have an
/// endpoint above degree 128 — links to *France*, *country*, *year* — and they say almost nothing
/// about the note that carries them, because nearly every note carries them. Weighted equally with
/// everything else they dominate three separate decisions at once: which notes coarsen together,
/// which lines the ambient web spends its budget on, and which neighbours a focused note shows.
///
/// This is Salton's cosine normalisation, and the intuition is the same one that makes it work for
/// text: a term that appears everywhere carries no information about the document it appears in. A
/// link between two obscure notes is evidence that they are related; a link to *France* is evidence
/// of nothing.
///
/// `K` is the mean degree, so a link between two typical notes comes out at 1.0 and every constant
/// calibrated against "a real link" — `folder_w` above, the link budgets downstream — keeps its
/// meaning. At `p = 1` on the reference corpus this runs from about 0.06 for a link to the largest
/// hub up to about 4 for a link between two rarely-cited notes.
pub fn degreeNormalised(
    gpa: std.mem.Allocator,
    n_notes: usize,
    links: []const Edge,
    p: f32,
) ![]Edge {
    const out = try gpa.alloc(Edge, links.len);
    errdefer gpa.free(out);
    if (p == 0 or links.len == 0) {
        @memcpy(out, links);
        return out;
    }

    const deg = try gpa.alloc(f32, n_notes);
    defer gpa.free(deg);
    @memset(deg, 0);
    var counted: usize = 0;
    for (links) |e| {
        if (e.a == e.b or e.a >= n_notes or e.b >= n_notes) continue;
        deg[e.a] += 1;
        deg[e.b] += 1;
        counted += 1;
    }
    if (counted == 0) {
        @memcpy(out, links);
        return out;
    }
    const mean_deg: f32 = 2.0 * @as(f32, @floatFromInt(counted)) / @as(f32, @floatFromInt(n_notes));

    const k2 = mean_deg * mean_deg;
    if (p == 1) {
        // The overwhelmingly common case, and `pow(x, 0.5)` is a library call where `@sqrt` is one
        // instruction. Over 3.3M edges that is most of the cost of this function.
        for (links, out) |e, *o| {
            o.* = e;
            if (e.a == e.b or e.a >= n_notes or e.b >= n_notes) continue;
            o.w = e.w * @sqrt(k2 / (@max(deg[e.a], 1) * @max(deg[e.b], 1)));
        }
        return out;
    }
    for (links, out) |e, *o| {
        o.* = e;
        if (e.a == e.b or e.a >= n_notes or e.b >= n_notes) continue;
        const da = @max(deg[e.a], 1);
        const db = @max(deg[e.b], 1);
        o.w = e.w * std.math.pow(f32, k2 / (da * db), p * 0.5);
    }
    return out;
}

/// Build the ladder. `paths` may be empty (no folder nodes); otherwise `paths[i]` is note `i`'s
/// vault-relative path and only its directory part is used.
pub fn build(
    gpa: std.mem.Allocator,
    n_notes: usize,
    links: []const Edge,
    paths: []const []const u8,
    opts: Options,
) !Ladder {
    if (n_notes == 0) return .{};

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // ---- augment: folder nodes -------------------------------------------------------------
    const scored = try degreeNormalised(arena, n_notes, links, opts.degree_norm);

    var edges: std.ArrayListUnmanaged(Edge) = .empty;
    try edges.ensureTotalCapacity(arena, links.len + n_notes * 2);
    for (scored) |e| {
        if (e.a == e.b or e.a >= n_notes or e.b >= n_notes) continue;
        edges.appendAssumeCapacity(.{ .a = e.a, .b = e.b, .w = e.w });
    }

    // Components come from real links only, and are computed *before* the folder chain is added:
    // the chain deliberately connects every note to its path-neighbour, so including it would
    // fuse the whole vault into one component and defeat the constraint below.
    const comp = try arena.alloc(u32, n_notes);
    const n_comps = try linkComponents(arena, comp, edges.items, n_notes);

    const total: u32 = @intCast(n_notes);
    if (paths.len == n_notes and opts.folder_w > 0) {
        if (hasFolders(paths)) {
            try addPathChain(arena, &edges, paths, opts.folder_w);
        } else {
            // Flat vault: no folder tree to express, but the notes with *no links at all* still
            // need something to group on, and their titles are the only information there is.
            try addOrphanChain(arena, &edges, paths, links, n_notes, opts.folder_w);
        }
    }

    // Link mass per note — see `Cell.weight`. Raw degree, deliberately *not* the normalised
    // weight: normalisation exists to stop a hub dominating the *grouping*, while mass exists to
    // make a hub look like the star it is. Counting edges rather than summing weights keeps the two
    // independent, so tuning `degree_norm` never quietly resizes anything.
    const wnote = try arena.alloc(f32, n_notes);
    @memset(wnote, 0);
    for (links) |e| {
        if (e.a == e.b or e.a >= n_notes or e.b >= n_notes) continue;
        wnote[e.a] += 1;
        wnote[e.b] += 1;
    }

    // ---- coarsen ---------------------------------------------------------------------------
    var cells: std.ArrayListUnmanaged(Cell) = .empty;
    try cells.ensureTotalCapacity(gpa, total * 2);
    errdefer cells.deinit(gpa);
    for (0..total) |i| {
        try cells.append(gpa, .{
            .count = 1,
            .note = @intCast(i),
            .comp = comp[i],
            .weight = wnote[i],
            .body = if (opts.bodies.len == n_notes) opts.bodies[i] else 0,
        });
    }

    var children: std.ArrayListUnmanaged(u32) = .empty;
    errdefer children.deinit(gpa);

    var cur = try arena.alloc(u32, total);
    for (cur, 0..) |*c, i| c.* = @intCast(i);
    var level_edges = try arena.dupe(Edge, edges.items);

    var depth: u16 = 0;
    while (depth < opts.max_levels and cur.len > n_comps) {
        if (opts.cancel) |c| {
            if (c.load(.acquire)) return error.Cancelled;
        }
        const res = try coarsenLevel(arena, gpa, &cells, &children, cur, level_edges, opts.arity, depth);
        if (res.cells.len >= cur.len) break; // no progress
        cur = res.cells;
        level_edges = res.edges;
        depth += 1;
    }

    var lad: Ladder = .{
        .cells = try cells.toOwnedSlice(gpa),
        .children = try children.toOwnedSlice(gpa),
        .roots = try gpa.dupe(u32, cur),
        .depth = depth,
    };
    errdefer lad.deinit(gpa);

    // Splice out single-child chains so the ladder stays ~log_arity(n) deep.
    for (lad.roots) |*r| r.* = prune(&lad, r.*) orelse r.*;
    for (lad.roots) |r| lad.cells[r].parent = invalid;

    lad.leaf_cell = try gpa.alloc(u32, n_notes);
    @memset(lad.leaf_cell, invalid);
    lad.note_at = try gpa.alloc(u32, n_notes);
    lad.slot_of = try gpa.alloc(u32, n_notes);
    @memset(lad.slot_of, invalid);
    var cursor: u32 = 0;
    var deepest: u16 = 0;
    for (lad.roots) |r| {
        deepest = @max(deepest, assignRanges(&lad, r, 0, &cursor));
    }
    lad.depth = deepest;

    try buildPairs(gpa, &lad, scored, n_notes);
    return lad;
}

// ---- folder nodes ---------------------------------------------------------------------------

/// Connected components of the link graph, with every isolated note pooled into a single extra
/// component. Fills `comp` with dense ids and returns how many there are.
///
/// Pooling matters: an unlinked note is its own component, so without it a vault with thousands of
/// orphans would have thousands of roots that can never coarsen with anything, each holding its own
/// slot in the pack forever. Pooled, they coarsen among themselves — and since their only edges are
/// the folder chain, they group by directory, which is also how a person reads them: not a topic,
/// just the unfiled drawer.
fn linkComponents(arena: std.mem.Allocator, comp: []u32, links: []const Edge, n_notes: usize) !u32 {
    const uf = try arena.alloc(u32, n_notes);
    for (uf, 0..) |*x, i| x.* = @intCast(i);
    const has_link = try arena.alloc(bool, n_notes);
    @memset(has_link, false);

    const find = struct {
        fn f(u: []u32, x0: u32) u32 {
            var x = x0;
            while (u[x] != x) {
                u[x] = u[u[x]]; // path halving
                x = u[x];
            }
            return x;
        }
    }.f;

    for (links) |e| {
        if (e.a >= n_notes or e.b >= n_notes or e.a == e.b) continue;
        has_link[e.a] = true;
        has_link[e.b] = true;
        const ra = find(uf, e.a);
        const rb = find(uf, e.b);
        if (ra != rb) uf[@max(ra, rb)] = @min(ra, rb);
    }

    // Dense renumbering. `dense[root] + 1` is stored so 0 can mean "unassigned".
    const dense = try arena.alloc(u32, n_notes);
    @memset(dense, 0);
    var next: u32 = 0;
    var pool: u32 = invalid;
    for (0..n_notes) |i| {
        if (!has_link[i]) {
            if (pool == invalid) {
                pool = next;
                next += 1;
            }
            comp[i] = pool;
            continue;
        }
        const r = find(uf, @intCast(i));
        if (dense[r] == 0) {
            next += 1;
            dense[r] = next; // stored +1
        }
        comp[i] = dense[r] - 1;
    }
    return next;
}

/// A title-ordered chain over notes that have **no links whatsoever**.
///
/// This is the other half of `hasFolders`. The module's premise is "group by links, and by folder
/// when there are no links" — and it needs no orphan special case *because* the folder chain
/// supplies those edges. On a flat vault that chain is suppressed (it would group the entire vault
/// alphabetically, drowning real links), which leaves orphans with nothing at all: they pool into
/// one component and coarsen in note-id order, i.e. at random. On a Wikipedia import that is 2,816
/// notes bundled into arbitrary sevens.
///
/// The distinction that makes this safe is exactly the one that made the full chain unsafe. A
/// chain over *every* note adds edges that compete with real links and win often enough to decide
/// the layout. A chain over notes that have no links competes with nothing — it is the only signal
/// available for them, and it makes a coalesced orphan group mean something ("titles around Ka…")
/// instead of nothing.
fn addOrphanChain(
    arena: std.mem.Allocator,
    edges: *std.ArrayListUnmanaged(Edge),
    paths: []const []const u8,
    links: []const Edge,
    n_notes: usize,
    w: f32,
) !void {
    const linked = try arena.alloc(bool, n_notes);
    @memset(linked, false);
    for (links) |e| {
        if (e.a < n_notes) linked[e.a] = true;
        if (e.b < n_notes) linked[e.b] = true;
    }

    var orphans: std.ArrayListUnmanaged(u32) = .empty;
    for (0..n_notes) |i| {
        if (!linked[i]) try orphans.append(arena, @intCast(i));
    }
    if (orphans.items.len < 2) return;

    const ByPath = struct {
        paths: []const []const u8,
        pub fn lessThan(self: @This(), a: u32, b: u32) bool {
            return std.mem.lessThan(u8, self.paths[a], self.paths[b]);
        }
    };
    std.mem.sortUnstable(u32, orphans.items, ByPath{ .paths = paths }, ByPath.lessThan);

    for (orphans.items[1..], 0..) |b, i| {
        try edges.append(arena, .{ .a = orphans.items[i], .b = b, .w = w });
    }
}

/// Whether these paths describe a folder tree at all.
///
/// `addPathChain` leans entirely on lexicographic order being a depth-first walk of the folder
/// hierarchy. In a **flat** vault there is no hierarchy for it to walk, and the chain stops
/// expressing folder structure and starts inventing an *alphabetical* one: 286,000 edges at
/// `folder_w` joining notes whose only relationship is that their titles sort next to each other.
/// On a Simple English Wikipedia import that is exactly what happened — the map clustered
/// `Mitsuhiro Toda` with `Mitsuhiro Kawamoto`, and `Zoe Kazan` with `Zoe Konstantopoulou`, while
/// the notes they actually link to ended up on the other side of the vault.
///
/// One separator anywhere is enough to mean the caller has real structure to contribute. A vault
/// with none has nothing to say about grouping, and saying nothing is strictly better than saying
/// something false — links then decide alone, which is what `folder_w`'s "folders only decide
/// where links don't" was always meant to degrade to.
fn hasFolders(paths: []const []const u8) bool {
    for (paths) |path| {
        if (std.mem.indexOfAny(u8, path, "/\\") != null) return true;
    }
    return false;
}

/// One edge per note, between path-order neighbours. Lexicographic order on vault-relative paths
/// is a depth-first walk of the folder tree, so this single chain expresses the whole hierarchy:
/// same-directory notes are contiguous, sibling directories abut, and a directory sits next to its
/// children. Weight is `folder_w` against 1.0 for a real link, so links always win where they
/// exist and folders only decide where they don't.
fn addPathChain(
    arena: std.mem.Allocator,
    edges: *std.ArrayListUnmanaged(Edge),
    paths: []const []const u8,
    w: f32,
) !void {
    const order = try arena.alloc(u32, paths.len);
    for (order, 0..) |*o, i| o.* = @intCast(i);
    const Ctx = struct {
        paths: []const []const u8,
        pub fn lessThan(self: @This(), a: u32, b: u32) bool {
            return std.mem.lessThan(u8, self.paths[a], self.paths[b]);
        }
    };
    std.mem.sortUnstable(u32, order, Ctx{ .paths = paths }, Ctx.lessThan);

    var i: usize = 1;
    while (i < order.len) : (i += 1) {
        try edges.append(arena, .{ .a = order[i - 1], .b = order[i], .w = w });
    }
}

// ---- one coarsening level -------------------------------------------------------------------

const LevelResult = struct { cells: []u32, edges: []Edge };

/// Pack an edge's endpoints into the key the radix sort orders by. Canonicalised `a <= b` by the
/// caller, so this orders by source then destination.
fn edgeKey(e: Edge) u64 {
    return (@as(u64, e.a) << 32) | @as(u64, e.b);
}


fn coarsenLevel(
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    cells: *std.ArrayListUnmanaged(Cell),
    children: *std.ArrayListUnmanaged(u32),
    cur: []const u32,
    level_edges: []const Edge,
    arity: Arity,
    level: u16,
) !LevelResult {
    const k = arity.n();

    // Dense index over the current cells so adjacency can be a flat CSR.
    //
    // A flat array rather than a hash map, because this is looked up **six times per edge**: twice
    // to count degrees, twice to fill the CSR, and twice again to lift the edges to their parents.
    // On the reference corpus's first level that is 3.35M edges × 6 = ~20 million probes, each one
    // a wyhash of a `u32` followed by a random walk of the map's metadata — and a profile of a
    // rebuild found them, not the sorting the symbol names first suggested. Cell ids are dense
    // integers, so the map was only ever a slow way to index an array.
    //
    // Sized from the cell count *before* this level appends its parents: every id these edges can
    // name already exists, and the parents appended below are ids no `level_edges` entry holds.
    const dense_of = try arena.alloc(u32, cells.items.len);
    @memset(dense_of, invalid);
    for (cur, 0..) |c, i| dense_of[c] = @intCast(i);
    // Cell ids come from `cur` and from `level_edges`, which is this level's own edge list — but
    // bound the read anyway rather than trusting that, since the cost is one compare against a
    // value already in a register.
    const denseOf = struct {
        fn f(map: []const u32, id: u32) ?u32 {
            if (id >= map.len) return null;
            const d = map[id];
            return if (d == invalid) null else d;
        }
    }.f;

    const m = cur.len;
    const deg = try arena.alloc(u32, m);
    @memset(deg, 0);
    for (level_edges) |e| {
        const ia = denseOf(dense_of, e.a) orelse continue;
        const ib = denseOf(dense_of, e.b) orelse continue;
        if (ia == ib) continue;
        deg[ia] += 1;
        deg[ib] += 1;
    }
    const off = try arena.alloc(u32, m + 1);
    off[0] = 0;
    for (0..m) |i| off[i + 1] = off[i] + deg[i];
    const fill = try arena.dupe(u32, off[0..m]);
    const adj = try arena.alloc(u32, off[m]);
    const adjw = try arena.alloc(f32, off[m]);
    for (level_edges) |e| {
        const ia = denseOf(dense_of, e.a) orelse continue;
        const ib = denseOf(dense_of, e.b) orelse continue;
        if (ia == ib) continue;
        adj[fill[ia]] = ib;
        adjw[fill[ia]] = e.w;
        fill[ia] += 1;
        adj[fill[ib]] = ia;
        adjw[fill[ib]] = e.w;
        fill[ib] += 1;
    }

    // Biggest-first is deterministic and keeps hubs at the centre of their group.
    const order = try arena.dupe(u32, cur);
    const Ctx = struct {
        cells: []const Cell,
        pub fn lessThan(self: @This(), a: u32, b: u32) bool {
            const ca = self.cells[a].count;
            const cb = self.cells[b].count;
            if (ca != cb) return ca > cb;
            return a < b;
        }
    };
    std.mem.sortUnstable(u32, order, Ctx{ .cells = cells.items }, Ctx.lessThan);

    const taken = try arena.alloc(bool, m);
    @memset(taken, false);
    // component per dense index, so grouping can be constrained to one island
    const comp_of = try arena.alloc(u32, m);
    for (cur, 0..) |c, i| comp_of[i] = cells.items[c].comp;

    var groups: std.ArrayListUnmanaged([]u32) = .empty;
    var leftovers: std.ArrayListUnmanaged(u32) = .empty;
    var buf = try arena.alloc(u32, k);

    for (order) |cell_id| {
        const u = denseOf(dense_of, cell_id).?;
        if (taken[u]) continue;
        taken[u] = true;
        var len: usize = 1;
        buf[0] = u;

        // 1-hop, heaviest link first. `comp_of` keeps a group inside one island: the folder
        // chain deliberately links every note to its path-neighbour, so without this an island
        // would happily absorb the note that happens to sort next to it.
        const my_comp = cells.items[cell_id].comp;
        len = growFrom(u, adj, adjw, off, taken, buf, len, k, comp_of, my_comp);
        // then the group's own neighbourhood, so a star's rim can still coalesce
        if (len < k) {
            var gi: usize = 1;
            while (gi < len and len < k) : (gi += 1) {
                len = growFrom(buf[gi], adj, adjw, off, taken, buf, len, k, comp_of, my_comp);
            }
        }

        if (len == 1) {
            try leftovers.append(arena, u);
        } else {
            try groups.append(arena, try arena.dupe(u32, buf[0..len]));
        }
    }

    // A cell whose neighbours were all claimed would otherwise pass through unchanged. Around a
    // hub that is *most* of the star, and the ladder degenerates into a chain tens of levels deep
    // instead of log_arity(n) — the leaves never coalesce at all. Bundle them instead, **within a
    // component**: bundling across islands is what made discrete islands overlap into one blob.
    if (leftovers.items.len > 0) {
        const ByComp = struct {
            cells: []const Cell,
            cur: []const u32,
            pub fn lessThan(self: @This(), a: u32, b: u32) bool {
                const ca = self.cells[self.cur[a]].comp;
                const cb = self.cells[self.cur[b]].comp;
                if (ca != cb) return ca < cb;
                return a < b;
            }
        };
        std.mem.sortUnstable(u32, leftovers.items, ByComp{ .cells = cells.items, .cur = cur }, ByComp.lessThan);
        var i: usize = 0;
        while (i < leftovers.items.len) {
            const this_comp = cells.items[cur[leftovers.items[i]]].comp;
            var j = i;
            while (j < leftovers.items.len and
                cells.items[cur[leftovers.items[j]]].comp == this_comp and
                j - i < k) : (j += 1)
            {}
            try groups.append(arena, try arena.dupe(u32, leftovers.items[i..j]));
            i = j;
        }
    }

    // ---- materialise parents ----
    const next = try arena.alloc(u32, groups.items.len);
    const parent_of = try arena.alloc(u32, m);
    for (groups.items, 0..) |grp, gi| {
        if (grp.len == 1) {
            // pass through unchanged; nothing gained by wrapping it
            const id = cur[grp[0]];
            next[gi] = id;
            parent_of[grp[0]] = id;
            continue;
        }
        const id: u32 = @intCast(cells.items.len);
        const start: u32 = @intCast(children.items.len);
        var sum: u32 = 0;
        for (grp) |gi2| {
            const child = cur[gi2];
            cells.items[child].parent = id;
            sum += cells.items[child].count;
            try children.append(gpa, child);
            parent_of[gi2] = id;
        }
        try cells.append(gpa, .{
            .count = sum,
            .level = level + 1,
            .child_start = start,
            .child_count = @intCast(grp.len),
            .comp = cells.items[cur[grp[0]]].comp,
        });
        next[gi] = id;
    }

    // ---- lift edges (sort + merge; no per-edge hashing) ----
    var lifted: std.ArrayListUnmanaged(Edge) = .empty;
    try lifted.ensureTotalCapacity(arena, level_edges.len);
    for (level_edges) |e| {
        const ia = denseOf(dense_of, e.a) orelse continue;
        const ib = denseOf(dense_of, e.b) orelse continue;
        const pa = parent_of[ia];
        const pb = parent_of[ib];
        if (pa == pb) continue;
        lifted.appendAssumeCapacity(.{
            .a = @min(pa, pb),
            .b = @max(pa, pb),
            .w = e.w,
        });
    }
    const radix_scratch = try arena.alloc(Edge, lifted.items.len);
    const sorted = radix.sortByKey(Edge, edgeKey, lifted.items, radix_scratch);
    var merged: std.ArrayListUnmanaged(Edge) = .empty;
    try merged.ensureTotalCapacity(arena, lifted.items.len);
    for (sorted) |e| {
        if (merged.items.len > 0) {
            const last = &merged.items[merged.items.len - 1];
            if (last.a == e.a and last.b == e.b) {
                last.w += e.w;
                continue;
            }
        }
        merged.appendAssumeCapacity(e);
    }

    return .{ .cells = next, .edges = merged.items };
}

fn growFrom(
    u: u32,
    adj: []const u32,
    adjw: []const f32,
    off: []const u32,
    taken: []bool,
    buf: []u32,
    len_in: usize,
    k: usize,
    comp_of: []const u32,
    my_comp: u32,
) usize {
    var len = len_in;
    while (len < k) {
        var best: u32 = invalid;
        var best_w: f32 = -1;
        var e = off[u];
        while (e < off[u + 1]) : (e += 1) {
            const v = adj[e];
            if (taken[v] or comp_of[v] != my_comp) continue;
            if (adjw[e] > best_w) {
                best_w = adjw[e];
                best = v;
            }
        }
        if (best == invalid) break;
        taken[best] = true;
        buf[len] = best;
        len += 1;
    }
    return len;
}

// ---- prune / ranges -------------------------------------------------------------------------

/// Splice out single-child cells. A cell with one child is a zoom level that shows exactly what
/// the level above it showed, which is both a wasted split animation and extra depth.
fn prune(lad: *Ladder, id: u32) ?u32 {
    const c = &lad.cells[id];
    if (c.child_count == 0) return id;

    const start = c.child_start;
    for (0..c.child_count) |i| {
        const child = lad.children[start + i];
        if (prune(lad, child)) |surv| {
            lad.children[start + i] = surv;
            lad.cells[surv].parent = id;
        }
    }
    if (c.child_count == 1) {
        const only = lad.children[start];
        lad.cells[only].parent = c.parent;
        return only;
    }
    return id;
}

/// One walk that assigns depth, note ranges and height. Returns the height so the parent can take
/// the max of its children without a second traversal.
fn assignRanges(lad: *Ladder, id: u32, level: u16, cursor: *u32) u16 {
    var h: u16 = 0;
    {
        const c = &lad.cells[id];
        c.level = level;
        c.ls = cursor.*;
    }
    const child_count = lad.cells[id].child_count;
    var w: f32 = 0;
    var body: f32 = 0;
    if (child_count == 0) {
        const c = &lad.cells[id];
        if (c.note != invalid) {
            lad.note_at[cursor.*] = c.note;
            lad.slot_of[c.note] = cursor.*;
            lad.leaf_cell[c.note] = id;
            cursor.* += 1;
        }
    } else {
        const start = lad.cells[id].child_start;
        for (0..child_count) |i| {
            const kid = lad.children[start + i];
            h = @max(h, 1 + assignRanges(lad, kid, level + 1, cursor));
            w += lad.cells[kid].weight;
            body += lad.cells[kid].body;
        }
    }
    const c = &lad.cells[id];
    c.le = cursor.*;
    c.height = h;
    // Leaves carry the weight/body they were created with; everything above is the sum beneath.
    if (child_count > 0) {
        c.weight = w;
        c.body = body;
    }
    return h;
}

fn maxDepth(lad: Ladder, id: u32) u16 {
    const c = lad.cells[id];
    if (c.child_count == 0) return 0;
    var m: u16 = 0;
    for (0..c.child_count) |i| {
        m = @max(m, maxDepth(lad, lad.children[c.child_start + i]));
    }
    return m + 1;
}

/// Hash context for the `u64`-keyed weight accumulators in `buildPairs`.
///
/// `AutoContext(u64)` runs wyhash over the eight bytes, and `buildPairs` does three `getOrPut`s per
/// link — ~10M hashes on the reference corpus, which makes it the most expensive part of
/// `fold.build`. These keys are packed cell/child ids: dense, structured, and entirely under our own
/// control, never attacker-supplied, so a cheaper mixer than a general-purpose byte hash is enough.
///
/// splitmix64's finalizer, **not** a bare multiply. A single `k *% golden` is a bijection but leaves
/// the low bits determined by the low bits of the input, and this table indexes buckets with the low
/// bits — the packed keys share their low half across whole runs of entries, so every one of them
/// collided into the same bucket. That version ran `buildPairs` at 5,130 ms against 168 ms for
/// wyhash: a 30x regression from a hash that looked obviously faster.
const PackedKeyContext = struct {
    pub fn hash(_: PackedKeyContext, k: u64) u64 {
        var x = k;
        x ^= x >> 30;
        x *%= 0xbf58476d1ce4e5b9;
        x ^= x >> 27;
        x *%= 0x94d049bb133111eb;
        x ^= x >> 31;
        return x;
    }
    pub fn eql(_: PackedKeyContext, a: u64, b: u64) bool {
        return a == b;
    }
};

/// A `u64 -> weight` accumulator keyed on packed ids. See `PackedKeyContext`.
const WeightAcc = std.HashMapUnmanaged(u64, f32, PackedKeyContext, std.hash_map.default_max_load_percentage);

// ---- sibling pair weights -------------------------------------------------------------------

/// For every original link, find the lowest cell that contains both ends and record the weight
/// between the two of its children that the link crosses. `containment.zig` uses this to choose
/// which child gets which hex slot — turning what would be a global force solve into an
/// exhaustive search over at most `arity!` arrangements per cell.
fn buildPairs(gpa: std.mem.Allocator, lad: *Ladder, links: []const Edge, n_notes: usize) !void {
    var acc: WeightAcc = .empty;
    defer acc.deinit(gpa);
    // (cell << 40) | (child << 32) | toward  ->  weight. One level below the LCA on each side:
    // the pair above says "x links to y", this says *which child of x* does — the part
    // `containment` needs to aim a slot, and the part the LCA-only record throws away.
    var ext_acc: WeightAcc = .empty;
    defer ext_acc.deinit(gpa);

    for (links) |e| {
        if (e.a >= n_notes or e.b >= n_notes or e.a == e.b) continue;
        const leaf_a = lad.leaf_cell[e.a];
        const leaf_b = lad.leaf_cell[e.b];
        var x = leaf_a;
        var y = leaf_b;
        if (x == invalid or y == invalid or x == y) continue;

        // Climb to equal depth, then together until the parents meet — tracking the node each
        // side came *from*.
        //
        // That node is what `recordExt` needs: the child of `x` holding this link's endpoint. It
        // used to re-derive it by climbing from the leaf a second time, and a third time for `y`,
        // so the same path through `lad.cells` was walked three times per link. On a vault whose
        // cell array is far larger than L2 those climbs are pointer-chasing cache misses, which is
        // most of what this loop costs at 3.35M links. The climb already passes through the answer.
        var x_from: u32 = invalid;
        var y_from: u32 = invalid;
        while (lad.cells[x].level > lad.cells[y].level) {
            x_from = x;
            x = lad.cells[x].parent;
        }
        while (lad.cells[y].level > lad.cells[x].level) {
            y_from = y;
            y = lad.cells[y].parent;
        }
        while (lad.cells[x].parent != lad.cells[y].parent) {
            if (lad.cells[x].parent == invalid or lad.cells[y].parent == invalid) break;
            x_from = x;
            x = lad.cells[x].parent;
            y_from = y;
            y = lad.cells[y].parent;
        }
        const p = lad.cells[x].parent;
        if (p == invalid or x == y) continue;

        const kids = lad.childrenOf(p);
        var i: u8 = 255;
        var j: u8 = 255;
        for (kids, 0..) |kid, ki| {
            if (kid == x) i = @intCast(ki);
            if (kid == y) j = @intCast(ki);
        }
        if (i == 255 or j == 255) continue;

        // Descend one level from each side of the LCA: which child of `x` actually holds this
        // link's endpoint, and therefore wants to face `y` (and symmetrically). Recorded only
        // when that side has children to aim — a leaf `x` has no slots of its own to arrange.
        recordExt(gpa, &ext_acc, lad, x, x_from, y, e.w) catch {};
        recordExt(gpa, &ext_acc, lad, y, y_from, x, e.w) catch {};

        const lo = @min(i, j);
        const hi = @max(i, j);
        const key = (@as(u64, p) << 16) | (@as(u64, lo) << 8) | hi;
        const gop = try acc.getOrPut(gpa, key);
        gop.value_ptr.* = (if (gop.found_existing) gop.value_ptr.* else 0) + e.w;
    }

    var pairs: std.ArrayListUnmanaged(SibPair) = .empty;
    errdefer pairs.deinit(gpa);
    // group by cell so each cell's pairs are contiguous
    var by_cell: std.AutoHashMapUnmanaged(u32, std.ArrayListUnmanaged(SibPair)) = .empty;
    defer {
        var it = by_cell.valueIterator();
        while (it.next()) |v| v.deinit(gpa);
        by_cell.deinit(gpa);
    }
    var it = acc.iterator();
    while (it.next()) |kv| {
        const cell: u32 = @intCast(kv.key_ptr.* >> 16);
        const lo: u8 = @intCast((kv.key_ptr.* >> 8) & 0xff);
        const hi: u8 = @intCast(kv.key_ptr.* & 0xff);
        const gop = try by_cell.getOrPut(gpa, cell);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(gpa, .{ .i = lo, .j = hi, .w = kv.value_ptr.* });
    }
    var it2 = by_cell.iterator();
    while (it2.next()) |kv| {
        const cell = kv.key_ptr.*;
        lad.cells[cell].pair_start = @intCast(pairs.items.len);
        lad.cells[cell].pair_count = @intCast(kv.value_ptr.items.len);
        try pairs.appendSlice(gpa, kv.value_ptr.items);
    }
    lad.pairs = try pairs.toOwnedSlice(gpa);

    var ext: std.ArrayListUnmanaged(ExtPull) = .empty;
    errdefer ext.deinit(gpa);
    var ext_by_cell: std.AutoHashMapUnmanaged(u32, std.ArrayListUnmanaged(ExtPull)) = .empty;
    defer {
        var eit = ext_by_cell.valueIterator();
        while (eit.next()) |v| v.deinit(gpa);
        ext_by_cell.deinit(gpa);
    }
    var eit = ext_acc.iterator();
    while (eit.next()) |kv| {
        const cell: u32 = @intCast(kv.key_ptr.* >> 40);
        const child: u8 = @intCast((kv.key_ptr.* >> 32) & 0xff);
        const toward: u32 = @intCast(kv.key_ptr.* & 0xffffffff);
        const gop = try ext_by_cell.getOrPut(gpa, cell);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(gpa, .{ .child = child, .toward = toward, .w = kv.value_ptr.* });
    }
    var eit2 = ext_by_cell.iterator();
    while (eit2.next()) |kv| {
        const cell = kv.key_ptr.*;
        lad.cells[cell].ext_start = @intCast(ext.items.len);
        lad.cells[cell].ext_count = std.math.cast(u16, kv.value_ptr.items.len) orelse std.math.maxInt(u16);
        try ext.appendSlice(gpa, kv.value_ptr.items[0..lad.cells[cell].ext_count]);
    }
    lad.ext = try ext.toOwnedSlice(gpa);
}

/// Record that whichever child of `cell` contains `leaf` is pulled toward `toward`.
///
/// `cell` is one side of a link's LCA split and `toward` is the other, so `toward` is always a
/// sibling of `cell` — already positioned by the time `cell` expands. Skipped for a leaf `cell`,
/// which has no children to arrange.
/// `child` is the node the LCA climb came up through — already known to be a child of `cell`, so
/// there is nothing to search for. `invalid` when the climb never moved, which means `cell` is the
/// leaf itself and has no slots of its own to arrange.
fn recordExt(
    gpa: std.mem.Allocator,
    acc: *WeightAcc,
    lad: *const Ladder,
    cell: u32,
    child: u32,
    toward: u32,
    w: f32,
) !void {
    if (lad.cells[cell].child_count == 0) return;
    const node = child;
    if (node == invalid) return;
    std.debug.assert(lad.cells[node].parent == cell);
    const kids = lad.childrenOf(cell);
    var ci: u8 = 255;
    for (kids, 0..) |k, k_i| {
        if (k == node) ci = @intCast(k_i);
    }
    if (ci == 255) return;
    const key = (@as(u64, cell) << 40) | (@as(u64, ci) << 32) | @as(u64, toward);
    const gop = try acc.getOrPut(gpa, key);
    gop.value_ptr.* = (if (gop.found_existing) gop.value_ptr.* else 0) + w;
}

// ---- tests ----------------------------------------------------------------------------------

const testing = std.testing;

test "a flat vault gets no folder chain" {
    // The chain encodes a folder hierarchy by exploiting lexicographic order. With no folders
    // there is no hierarchy, and the chain would instead wire alphabetical neighbours together —
    // which on a real Wikipedia import dominated the coarsening and grouped notes purely by title.
    const gpa = testing.allocator;

    // Two linked pairs, deliberately arranged so that alphabetical order and link structure
    // disagree: A links to C, B links to D.
    const edges = [_]Edge{ .{ .a = 0, .b = 2 }, .{ .a = 1, .b = 3 } };
    const flat: []const []const u8 = &.{ "Aa.md", "Ab.md", "Zy.md", "Zz.md" };

    var lad = try build(gpa, 4, &edges, flat, .{ .arity = .seven });
    defer lad.deinit(gpa);

    // With no chain the only edges are the real ones, so the two link components survive as such.
    // A chain would have joined Aa-Ab and Zy-Zz — alphabetical neighbours — into one component.
    const comp_of = struct {
        fn f(l: Ladder, note: u32) u32 {
            return l.cells[l.leaf_cell[note]].comp;
        }
    }.f;
    try testing.expectEqual(comp_of(lad, 0), comp_of(lad, 2)); // linked
    try testing.expectEqual(comp_of(lad, 1), comp_of(lad, 3)); // linked
    try testing.expect(comp_of(lad, 0) != comp_of(lad, 1)); // only alphabetically adjacent
}

test "orphans on a flat vault group by title, not by note id" {
    // The folder chain is suppressed on a flat vault (it would group everything alphabetically),
    // which leaves unlinked notes with no signal at all. `addOrphanChain` restores exactly the
    // ordering the folder chain used to supply, scoped to notes that have nothing to compete with.
    const gpa = testing.allocator;

    // Six orphans whose id order and title order disagree completely, plus one linked pair so the
    // orphan pool is not the whole vault.
    const edges = [_]Edge{.{ .a = 0, .b = 1 }};
    const flat: []const []const u8 = &.{
        "linked-a.md", "linked-b.md",
        "Zz.md",       "Aa.md",
        "Zy.md",       "Ab.md",
        "Za.md",       "Ac.md",
    };

    var lad = try build(gpa, 8, &edges, flat, .{ .arity = .seven });
    defer lad.deinit(gpa);

    // The `A*` orphans should share a leaf cell with each other rather than with the `Z*` ones.
    const cell_of = struct {
        fn f(l: Ladder, note: u32) u32 {
            return l.cells[l.leaf_cell[note]].parent;
        }
    }.f;
    // Aa(3), Ab(5), Ac(7) are title-adjacent; Zz(2), Zy(4), Za(6) are the other run.
    try testing.expectEqual(cell_of(lad, 3), cell_of(lad, 5));
    try testing.expectEqual(cell_of(lad, 5), cell_of(lad, 7));
}

test "hasFolders distinguishes a flat vault from a nested one" {
    try testing.expect(!hasFolders(&.{ "A.md", "B.md", "C.md" }));
    try testing.expect(hasFolders(&.{ "A.md", "notes/B.md" }));
    try testing.expect(!hasFolders(&.{}));
}


fn totalCount(lad: Ladder) u32 {
    var n: u32 = 0;
    for (lad.roots) |r| n += lad.cells[r].count;
    return n;
}

fn isRoot(lad: Ladder, id: u32) bool {
    for (lad.roots) |r| {
        if (r == id) return true;
    }
    return false;
}

fn star(gpa: std.mem.Allocator, leaves: u32) ![]Edge {
    const e = try gpa.alloc(Edge, leaves);
    for (0..leaves) |i| e[i] = .{ .a = 0, .b = @intCast(i + 1) };
    return e;
}

test "a star does not degenerate into a chain" {
    // The failure this guards: around a hub every leaf's neighbours are claimed by the hub, so
    // each becomes a singleton group and passes through unchanged. Depth goes linear in n.
    const gpa = testing.allocator;
    inline for (.{ Arity.four, Arity.seven }) |ar| {
        const edges = try star(gpa, 200);
        defer gpa.free(edges);
        var lad = try build(gpa, 201, edges, &.{}, .{ .arity = ar });
        defer lad.deinit(gpa);

        const ideal = std.math.log(f64, @floatFromInt(ar.n()), 201.0);
        try testing.expect(@as(f64, @floatFromInt(lad.depth)) <= ideal * 2.5 + 1);
        try testing.expectEqual(@as(u32, 201), totalCount(lad));
    }
}

test "every note lands in exactly one leaf, ranges are contiguous" {
    const gpa = testing.allocator;
    const edges = try star(gpa, 60);
    defer gpa.free(edges);
    var lad = try build(gpa, 61, edges, &.{}, .{});
    defer lad.deinit(gpa);

    var seen = try gpa.alloc(bool, 61);
    defer gpa.free(seen);
    @memset(seen, false);
    for (lad.note_at) |note| {
        try testing.expect(!seen[note]);
        seen[note] = true;
    }
    for (seen) |s| try testing.expect(s);

    // a cell's range covers exactly the notes beneath it
    for (lad.cells, 0..) |c, i| {
        if (c.parent == invalid and !isRoot(lad, @intCast(i))) continue;
        try testing.expectEqual(c.count, c.le - c.ls);
    }
}

test "unlinked notes group by folder" {
    const gpa = testing.allocator;
    const paths = [_][]const u8{
        "a/1.md", "a/2.md", "a/3.md", "a/4.md",
        "b/1.md", "b/2.md", "b/3.md", "b/4.md",
    };
    var lad = try build(gpa, paths.len, &.{}, &paths, .{ .arity = .four });
    defer lad.deinit(gpa);

    // With no links at all, folder edges are the only structure — so the two directories must
    // come out as separate cells rather than being bundled by index order.
    var found_pure_a = false;
    var found_pure_b = false;
    for (lad.cells, 0..) |c, id| {
        if (c.count != 4 or isRoot(lad, @intCast(id))) continue;
        var all_a = true;
        var all_b = true;
        for (c.ls..c.le) |s| {
            const p = paths[lad.note_at[s]];
            if (p[0] != 'a') all_a = false;
            if (p[0] != 'b') all_b = false;
        }
        if (all_a) found_pure_a = true;
        if (all_b) found_pure_b = true;
    }
    try testing.expect(found_pure_a);
    try testing.expect(found_pure_b);
}

test "every drawn leaf is a real note" {
    const gpa = testing.allocator;
    const paths = [_][]const u8{ "x/a.md", "x/b.md", "y/c.md", "y/d.md" };
    var lad = try build(gpa, paths.len, &.{}, &paths, .{ .arity = .four });
    defer lad.deinit(gpa);
    for (lad.cells) |c| {
        if (c.child_count == 0) try testing.expect(c.note != invalid);
    }
    try testing.expectEqual(@as(u32, 4), totalCount(lad));
}

test "a real link outranks folder adjacency" {
    // Two directories, and one link tying a note in each together. The linked pair must land in
    // the same cell before either falls in with its path-neighbours.
    const gpa = testing.allocator;
    const paths = [_][]const u8{
        "a/1.md", "a/2.md", "a/3.md",
        "b/1.md", "b/2.md", "b/3.md",
    };
    const links = [_]Edge{.{ .a = 0, .b = 3, .w = 1 }};
    var lad = try build(gpa, paths.len, &links, &paths, .{ .arity = .four });
    defer lad.deinit(gpa);
    try testing.expectEqual(lad.cells[lad.leaf_cell[0]].parent, lad.cells[lad.leaf_cell[3]].parent);
}

test "islands never share a cell" {
    // The failure this guards: the folder chain links every note to its path-neighbour, so without
    // a component constraint coarsening happily merges two unconnected islands into one cell — and
    // containment then draws them inside one disc, which is what made a vault of discrete islands
    // read as overlapping blobs.
    const gpa = testing.allocator;
    const per = 40;
    const islands = 12;
    const n = per * islands;

    var edges: std.ArrayListUnmanaged(Edge) = .empty;
    defer edges.deinit(gpa);
    for (0..islands) |isl| {
        const base: u32 = @intCast(isl * per);
        for (1..per) |j| try edges.append(gpa, .{ .a = base, .b = base + @as(u32, @intCast(j)) });
    }
    // paths interleave the islands, so path order actively disagrees with link structure
    var paths: [n][]const u8 = undefined;
    var bufs: [n][24]u8 = undefined;
    for (0..n) |i| {
        paths[i] = std.fmt.bufPrint(&bufs[i], "dir/{d:0>4}.md", .{i}) catch unreachable;
    }

    var lad = try build(gpa, n, edges.items, &paths, .{ .arity = .seven });
    defer lad.deinit(gpa);

    try testing.expectEqual(@as(usize, islands), lad.roots.len);
    for (lad.cells) |c| {
        if (c.count == 0) continue;
        // every note beneath a cell must come from the same island
        const first_island = lad.note_at[c.ls] / per;
        for (c.ls..c.le) |s| try testing.expectEqual(first_island, lad.note_at[s] / per);
    }
}

test "orphans pool into one root rather than one root each" {
    const gpa = testing.allocator;
    const n = 64;
    var paths: [n][]const u8 = undefined;
    var bufs: [n][24]u8 = undefined;
    for (0..n) |i| paths[i] = std.fmt.bufPrint(&bufs[i], "d/{d:0>3}.md", .{i}) catch unreachable;

    var lad = try build(gpa, n, &.{}, &paths, .{ .arity = .seven });
    defer lad.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), lad.roots.len);
    try testing.expectEqual(@as(u32, n), lad.cells[lad.roots[0]].count);
}

test "deterministic for the same input" {
    const gpa = testing.allocator;
    const edges = try star(gpa, 90);
    defer gpa.free(edges);
    var a = try build(gpa, 91, edges, &.{}, .{});
    defer a.deinit(gpa);
    var b = try build(gpa, 91, edges, &.{}, .{});
    defer b.deinit(gpa);
    try testing.expectEqual(a.depth, b.depth);
    try testing.expectEqualSlices(u32, a.note_at, b.note_at);
}

test "scale-free 20k stays log depth" {
    // The shape that broke the old coarsener: preferential attachment makes hubs, and around a hub
    // every leaf is a leftover. Depth must stay ~log_7(n), not linear.
    const gpa = testing.allocator;
    const n: u32 = 20_000;
    var prng = std.Random.DefaultPrng.init(0xA71A5);
    const rand = prng.random();

    var pool: std.ArrayListUnmanaged(u32) = .empty;
    defer pool.deinit(gpa);
    var edges: std.ArrayListUnmanaged(Edge) = .empty;
    defer edges.deinit(gpa);
    try pool.append(gpa, 0);
    for (1..n) |i| {
        const j = pool.items[rand.uintLessThan(usize, pool.items.len)];
        try edges.append(gpa, .{ .a = @intCast(i), .b = j });
        try pool.append(gpa, j);
        try pool.append(gpa, @intCast(i));
    }

    var lad = try build(gpa, n, edges.items, &.{}, .{ .arity = .seven });
    defer lad.deinit(gpa);

    const ideal = std.math.log(f64, 7.0, @as(f64, @floatFromInt(n)));
    try testing.expect(@as(f64, @floatFromInt(lad.depth)) <= ideal * 2.5);
    try testing.expectEqual(n, totalCount(lad));
    // and every note is reachable exactly once
    var seen = try gpa.alloc(bool, n);
    defer gpa.free(seen);
    @memset(seen, false);
    for (lad.note_at) |note| {
        try testing.expect(!seen[note]);
        seen[note] = true;
    }
    for (seen) |s| try testing.expect(s);
}

test "chain of 1000 coarsens to log depth, not 1000" {
    const gpa = testing.allocator;
    const n: u32 = 1000;
    const edges = try gpa.alloc(Edge, n - 1);
    defer gpa.free(edges);
    for (0..n - 1) |i| edges[i] = .{ .a = @intCast(i), .b = @intCast(i + 1) };
    var lad = try build(gpa, n, edges, &.{}, .{ .arity = .seven });
    defer lad.deinit(gpa);
    const ideal = std.math.log(f64, 7.0, @as(f64, @floatFromInt(n)));
    try testing.expect(@as(f64, @floatFromInt(lad.depth)) <= ideal * 2.5 + 1);
}

test "all-empty paths do not fabricate a folder chain across unrelated notes" {
    // A caller with no real paths (the vault simulator, before it carried `vault_synth`'s
    // generated ones through) can still hand over a full-length array of empty strings. That
    // satisfies `paths.len == n_notes`, so `addPathChain` runs — and with every path comparing
    // equal, the sort leaves arbitrary index order and the chain wires unrelated notes together.
    // Two disjoint islands must stay disjoint either way: callers pass `&.{}` when they have
    // nothing real (see `graph.zig`'s `ensureWorld`), and components are computed before the
    // chain is added, so the constraint has to hold even if the degenerate array gets through.
    const gpa = testing.allocator;
    const n: u32 = 40;
    var edges: std.ArrayListUnmanaged(Edge) = .empty;
    defer edges.deinit(gpa);
    // Two cliques-ish chains, 0..19 and 20..39, with nothing between them.
    for (0..19) |i| try edges.append(gpa, .{ .a = @intCast(i), .b = @intCast(i + 1) });
    for (20..39) |i| try edges.append(gpa, .{ .a = @intCast(i), .b = @intCast(i + 1) });

    const empty_paths = try gpa.alloc([]const u8, n);
    defer gpa.free(empty_paths);
    @memset(empty_paths, "");

    var lad = try build(gpa, n, edges.items, empty_paths, .{ .arity = .seven });
    defer lad.deinit(gpa);

    try testing.expectEqual(n, totalCount(lad));
    // No cell may mix the two components — the same guarantee "islands never share a cell" makes,
    // re-checked against the degenerate-path input specifically.
    for (lad.cells) |c| {
        if (c.ls >= c.le) continue;
        const first_side = lad.note_at[c.ls] < 20;
        for (c.ls..c.le) |s| {
            try testing.expectEqual(first_side, lad.note_at[s] < 20);
        }
    }
}
