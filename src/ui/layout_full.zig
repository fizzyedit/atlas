//! Full-vault graph layout — clustered, link-aware, hex-snapped.
//!
//! The goal is islands of related notes, not a uniform crystal:
//!
//! 1. **Seed.** Anchored nodes keep their previous layout home; everyone else is derived from
//!    the centroid of their already-placed neighbours (or their own last position, or a
//!    hex-spiral fallback, in that order).
//! 2. **Force.** LinLog-style attraction along links (and a weaker 2-hop pull for friends-
//!    of-friends), short-range-only repulsion so clusters don't shove each other into a
//!    lattice, and very weak gravity. Linked groups collapse into tight blobs; unrelated
//!    notes are free to sit apart.
//! 3. **Component pack.** Connected components are greedily packed around the origin, biggest
//!    first, with clear air between clusters — that's what makes separate topics read as separate
//!    islands, and it puts clusters in the middle with loose notes orbiting the rim. Packing is by
//!    *area*, so the vault's radius grows as √count rather than with the number of islands.
//! 4. **Snap.** Round to the nearest free hex cell (hubs claim first).
//! 5. **Uncross.** Greedy local swaps when that shortens links or removes a crossing.
//!
//! **Proportions are applied to island *placement*, never to node coordinates.** `Opts.aspect`
//! stretches the ring that components are parked on, and the search that resolves their
//! collisions — so islands spread along a wide panel while each island keeps whatever shape the
//! force pass gave it. Stretching coordinates instead is tempting and much more direct, and it is
//! wrong: it reshapes every cluster along with the cloud, and a triangle of three linked notes
//! comes out as a flat line with its nodes sitting on top of their own connecting edges.
//!
//! The limit of this, worth knowing before reaching for it: a vault that is one big connected
//! component has only one island to place, so there is nothing for `aspect` to arrange and the
//! cloud stays round however the panel is dragged.
//!
//! **Anchoring.** Every step above is global: left alone, adding one link re-solves the whole
//! vault, and a note on the far side that was perfectly well placed slides anyway. Nobody
//! reading the graph wants that — a change should look local because it *is* local. So the
//! caller marks the nodes whose own neighbours didn't change (`anchored`), and those are held
//! exactly where they were: they still push and pull on everyone else, but nothing pushes them.
//! Their islands aren't re-parked, and they claim their old cell before any mobile node can take
//! it. When nothing changed at all every node is anchored, which makes the whole pipeline a
//! no-op and costs a frame nothing.
//!
//! The knob to be careful with is how much you anchor. An earlier attempt at stability lived
//! down at the snap step — keep your old cell if it's within two — and it went too far the other
//! way: a note that had just *gained* a link couldn't leave home to join its new cluster. Tying
//! anchoring to "this node's own edges are unchanged" is what avoids that, since the two
//! endpoints of a new link are exactly the nodes that stop being anchored.
//!
//! **A changed node is re-derived, not nudged.** This is the other half, and without it anchoring
//! is actively worse than no stability at all. A node that is free to move does *not* start from
//! where it currently is — it starts from the centroid of its current neighbours. Relaxing from
//! the current position makes the layout path-dependent: link a note into a cluster and it moves
//! in, unlink it and short-range repulsion from that cluster throws it clear, landing it somewhere
//! it has never been and nowhere near where it started. Two edits that cancel out have to cancel
//! out on screen too. Deriving from the neighbours it has *now* gives that, because on the way
//! back out those neighbours are the ones it had before, still anchored and still where they were.
//!
//! The trade this accepts: one link between two established islands no longer tows the islands
//! together, because only its two endpoints are free to move. They stretch toward each other and
//! the islands stay put. That is the intended reading — a single link is not evidence that two
//! topics are one topic — and it resolves itself as more cross-links unanchor more members. A
//! genuinely large change (a fresh vault, a rename cascade) leaves few nodes anchored and gets
//! the fully global solve it needs.
//!
//! Pure: no camera, no DB, no dvui frame state. `graph.zig` owns the animation from the old
//! home to the new target.
const std = @import("std");
const dvui = @import("dvui");

const hex = @import("hex.zig");
const multilevel = @import("multilevel.zig");

/// LinLog attraction strength along real links. Higher → tighter clusters.
/// Tuned so a linked pair settles near one *snap* cell (`slot / snap_div`) rather than one
/// packing slot — otherwise the hex lattice puts linked neighbours the same distance apart as
/// two unrelated notes the packer happened to park next to each other.
const spring_k: f32 = 0.95;
/// Friends-of-friends cohesion, as a fraction of `spring_k`. Pulls communities together
/// without forcing a clique to become a single point.
const hop2_k: f32 = 0.28;
/// Soft pull between notes that share a folder (even with no wikilink), as a fraction of
/// `spring_k` at full kinship (same directory). Weaker than a real link on purpose — folder
/// cohorts should huddle, not crystallize into a second graph on top of the link graph.
const folder_k: f32 = 0.42;
/// Barely enough to stop the whole cloud drifting; strong gravity is what flattened
/// everything into one uniform disc before.
const gravity_k: f32 = 0.008;
const force_iters_cap: usize = 100;
const force_iters_floor: usize = 40;
const uncross_passes: usize = 6;
/// Work budget for the uncross pass, as `nodes · edges²` — see `refine`. Sized so the pass stays
/// in the low tens of milliseconds; beyond it the layout keeps the snapped result untouched.
const refine_budget: usize = 3_000_000;
/// How close a node has to sit to a link, as a share of a snap cell, before that link counts as
/// hidden behind it — see `countOccluded`. Under half a cell, so it means "on the line", not
/// "near it": a lattice full of nodes has links passing reasonably close to their neighbours all
/// the time, and calling that a tangle would have `refine` trying to unpick the whole cloud.
const occlude_frac: f32 = 0.45;
/// Longest link, in lattice steps, still worth checking for occlusion. A link that reaches across
/// a dozen cells is passing over whatever happens to be in the way, and a one-cell swap at either
/// end cannot clear it — so counting the notes it runs over only makes `refine` pay for something
/// it cannot fix. The tangles this pass *can* undo are all local.
const occlude_max_steps: i32 = 12;
/// A hidden link relative to a crossing. Slightly less: a crossing is two links made ambiguous,
/// occlusion is one made invisible, and unlike a crossing it can sometimes only be resolved by
/// pushing a cluster apart — which is a worse trade than the tangle it fixes.
const occlude_weight: f32 = 0.75;
/// Repulsion dies beyond this many slot lengths — past that, clusters ignore each other
/// so they can sit with empty grid between them.
const repulse_cutoff_slots: f32 = 2.4;
/// Largest folder that still gets exact pairwise cohort attraction. Above this, the cohort pulls
/// toward its own centre of mass instead — see `applyFolderCohesion`. Chosen well above the size
/// of an ordinary vault directory so the common case is unchanged.
const exact_cohort_max: usize = 96;
/// How far under the lattice's own density a freshly seeded cloud has to be before
/// `spreadToDensity` scales it out. Well under 1 so it only catches the neighbour-seeding
/// collapse (which lands orders of magnitude too dense), not merely-tight arrangements.
const collapse_ratio: f32 = 0.25;
/// Smallest vault laid out by the multilevel solver. Below this a single-level solve reaches
/// across the whole graph on its own, so the coarsening ladder buys nothing.
const multilevel_min: usize = 250;
/// Share of nodes (percent) that has to be held for a rebuild to still count as incremental.
/// Below it the solve repacks globally instead — see where it is used in `targets`.
const hold_min_pct: usize = 60;
/// Ceiling on `fitToLattice`'s expansion, so a degenerate graph cannot push the cloud so far out
/// that the fitted view is empty space.
const lattice_fit_max_scale: f32 = 6.0;
/// Minimum air between two component bounding circles, in slot units. Kept tight so
/// fit-to-extents doesn't have to pull way out past empty ocean between islands.
const component_gap_slots: f32 = 1.35;
/// Air around a *lone* note, which needs far less than a cluster does — see `Component.air`.
const lone_air_slots: f32 = 0.3;
/// Nodes snap to a lattice this many times finer than the island-packing unit. Packing and
/// fit still think in `slot` (so loose notes keep the spacing that reads well), but linked
/// neighbours can sit on adjacent *fine* cells and read as a denser cloud than the loners
/// around them. Still a power-of-two of `hex.spacing`, so every node lands on a grid dot.
const snap_div: f32 = 2;
/// How far a free cluster slides toward the origin, and a free lone note away from it, each time
/// it gets re-parked. A nudge rather than a jump: an island keeps its bearings across an edit and
/// drifts to where it belongs over a few of them.
const migrate_frac: f32 = 0.35;
const drift_frac: f32 = 0.12;
/// How far `Opts.aspect` is allowed to stretch the packing, either way. A panel dragged to a
/// letterbox sliver shouldn't string the whole vault out into a single line.
///
/// Has to cover the range the caller can actually *ask* for. The graph lives in a bottom panel,
/// which on a wide window runs past 8:1 when dragged short and only reaches 3:1 or so when dragged
/// tall — so a limit set for a squarish panel silently eats most of the useful range: every aspect
/// above it clamps to the same number and yields a byte-identical layout, and dragging the panel
/// does nothing at all to the cloud. That looks exactly like broken shaping rather than saturation,
/// which is what made it so hard to see.
///
/// **This is the single source of truth.** `graph.layoutAspect` clamps to it rather than carrying
/// its own number: two independent clamps is how this went wrong twice, because raising one while
/// the other still capped the input is indistinguishable from not having fixed it.
pub const aspect_limit: f32 = 8.0;


pub const Edge = struct { a: usize, b: usize };

/// Layout lattice spacing for a vault of `n` notes — see `hex.layoutSpacingFor`.
/// Island packing and camera hints use this; node snap uses `snapSpacingFor`.
pub fn slotSpacingFor(n: usize) f32 {
    return hex.layoutSpacingFor(n);
}

/// Hex spacing nodes actually land on — finer than `slotSpacingFor` so a linked pair can sit
/// closer than two loose notes the packer parks a full slot apart.
pub fn snapSpacingFor(n: usize) f32 {
    return slotSpacingFor(n) / snap_div;
}

/// World-space radius the outermost of `n` nodes sits near after a spiral packing of the
/// same count — useful as a soft upper bound for tests / camera hints. The force layout
/// can be tighter or looser depending on connectivity.
pub fn packRadius(n: usize) f32 {
    if (n <= 1) return 0;
    const nf: f32 = @floatFromInt(n);
    const k = (@sqrt(12.0 * nf) - 3.0) / 6.0;
    return @max(k, 0) * slotSpacingFor(n);
}

/// What the caller knows about the arrangement these targets are replacing, and the shape it
/// should end up. All optional: the defaults describe a first build into a square, which is the
/// honest answer when there is no history and no panel to fit.
pub const Opts = struct {
    /// `anchored[i]` says node `i`'s own link set is unchanged since the layout `seeds` came from,
    /// so it should be held in place — see the module doc. `null` means "no idea", which gives the
    /// fully global solve.
    anchored: ?[]const bool = null,
    /// The spacing `seeds` were laid out at, from the previous rebuild. When the vault grows or
    /// shrinks enough to change lattice level, seeds are uniformly rescaled so the web breathes
    /// instead of teleporting onto a mismatched lattice.
    prior_slot: ?f32 = null,
    /// Width-over-height of the region to pack into. The layout packs into a disc by default,
    /// which wastes most of a wide short panel: fitting a disc to a 2.3:1 viewport is
    /// height-limited, so nearly half the width goes to margin no matter how tightly the disc
    /// itself is packed. Packing to the panel's own proportions spends that width on zoom instead.
    /// Area-preserving, so this changes the cloud's shape and not how densely it is packed.
    ///
    /// Takes effect when nothing is `anchored`, or on a `reshape_only` pass — where anchoring is
    /// how the caller says which islands the reshape is allowed to move. An ordinary incremental
    /// rebuild ignores this and inherits the current shape through its `seeds` instead, so a
    /// reshape has to be asked for deliberately.
    aspect: f32 = 1,
    /// The graph is unchanged and only `aspect` moved — the caller is resizing, not reindexing.
    ///
    /// Skips the force pass entirely, which is the whole point: what a solve works out is each
    /// island's *internal* arrangement, and that is a function of the links alone. Nothing about
    /// it depends on the panel's proportions. Re-deriving it on every step of a drag is not just
    /// wasted work — it is the expensive part of this file, and paying it per step is what would
    /// otherwise force resizing to be chunky rather than continuous.
    ///
    /// So the islands are kept exactly as last solved and only re-parked and re-snapped, which is
    /// also why they hold their shape through a resize instead of subtly rearranging every time.
    ///
    /// The caller is expected to fire this once when the pane *settles*, not on every splitter
    /// tick — a fresh ellipse park is discontinuous, and doing it live is what produced the
    /// A↔B juggling. (The panel no longer reshapes on a resize at all: containment ignores the
    /// pane's proportions, so the re-solve only replayed the arrival animation.)
    reshape_only: bool = false,
    /// Vault-relative paths aligned with node indices, used for folder-cohort cohesion. Notes in
    /// the same directory (and, more weakly, parent/child folders) get a soft pull even when no
    /// wikilink joins them. `null` disables that bias.
    paths: ?[]const []const u8 = null,
    /// When set, the multilevel solver's coarsening ladder is handed back rather than freed —
    /// it is the level-of-detail hierarchy the draw pass uses when zoomed out. Allocated from
    /// this call's `allocator`, so the caller must copy it out before that arena dies. Only
    /// filled when the solve actually goes multilevel (see `multilevel_min`).
    keep_ladder: ?*multilevel.Ladder = null,
    /// Filled with per-phase nanoseconds when non-null. Costs one `Timer.read` per phase, so it
    /// is left in rather than gated on a build flag — the bench (`zig build bench`) is the only
    /// caller that passes it, and knowing which phase ate a rebuild is otherwise guesswork.
    profile: ?*Profile = null,
};

/// Where a `targets` call spent its time. All values nanoseconds.
pub const Profile = struct {
    seed_ns: u64 = 0,
    hop2_ns: u64 = 0,
    force_ns: u64 = 0,
    pack_ns: u64 = 0,
    relax_ns: u64 = 0,
    snap_ns: u64 = 0,
    refine_ns: u64 = 0,
    total_ns: u64 = 0,
    /// Counters that explain the timings — the pair counts the O(n²) passes actually walked.
    hop2_pairs: u64 = 0,
    force_iters: u64 = 0,
    /// Breakdown *within* the force loop, summed over iterations.
    f_grid_ns: u64 = 0,
    f_repulse_ns: u64 = 0,
    f_spring_ns: u64 = 0,
    f_folder_ns: u64 = 0,
    /// Repulsion pairs actually evaluated, and grid cells used, on the last iteration.
    repulse_cells: u64 = 0,
};

/// Write hex-snapped targets for `n` nodes into `out`.
///
/// `edges` are undirected index pairs into `0..n`. `seeds[i]` is the previous layout home
/// for a survivor, or `null` for a newcomer. `degrees[i]` weights gravity (pass 0 if unknown).
pub fn targets(
    allocator: std.mem.Allocator,
    n: usize,
    edges: []const Edge,
    seeds: []const ?dvui.Point,
    degrees: []const u32,
    opts: Opts,
    out: []dvui.Point,
) !void {
    const anchored = opts.anchored;
    const prior_slot = opts.prior_slot;
    std.debug.assert(out.len >= n);
    std.debug.assert(seeds.len >= n);
    std.debug.assert(degrees.len >= n);
    if (n == 0) return;

    const slot = slotSpacingFor(n);
    if (n == 1) {
        out[0] = .{};
        return;
    }

    // Elapsed nanoseconds since the last `lap`, against the monotonic boot clock. Only read when
    // `opts.profile` is set — `dvui.io` is only initialized inside a live app or by the bench.
    var phase_start: i96 = if (opts.profile != null) std.Io.Clock.boot.now(dvui.io).nanoseconds else 0;
    const lap = struct {
        fn f(mark: *i96) u64 {
            const now = std.Io.Clock.boot.now(dvui.io).nanoseconds;
            defer mark.* = now;
            return @intCast(now - mark.*);
        }
    }.f;

    // Near-field repulsion only — strong enough that a linked pair settles around one *snap*
    // cell under LinLog attraction, not so strong that the whole vault crystallizes.
    const snap = slot / snap_div;
    const repulse_k = slot * slot * 0.32;
    const repulse_cut = slot * repulse_cutoff_slots;
    const cross_penalty = snap * 8;

    // -- seed --------------------------------------------------------------------
    var pos = try allocator.alloc(dvui.Point, n);
    defer allocator.free(pos);
    var has_seed = try allocator.alloc(bool, n);
    defer allocator.free(has_seed);

    // When the lattice level steps, scale survivors so relative structure is preserved in
    // the new units — otherwise a jump 56→112 would leave everyone stacked in one quadrant.
    const seed_scale: f32 = if (prior_slot) |ps|
        if (ps > 1 and @abs(ps - slot) > 0.5) slot / ps else 1.0
    else
        1.0;

    // Anchoring needs somewhere to hold the node, so it takes a seed as well as the caller's
    // say-so — there is no "where it was" for a note that wasn't there.
    var pinned = try allocator.alloc(bool, n);
    defer allocator.free(pinned);
    for (0..n) |i| {
        pinned[i] = seeds[i] != null and
            if (anchored) |a| i < a.len and a[i] else false;
    }

    // Whether the caller is holding *anything* still. When it isn't, this is a deliberate full
    // repack — a first build, or the panel changing proportions — and nothing may quietly pin
    // itself, or the repack has no room to actually move the cloud. See the link-less case below.
    var held: usize = 0;
    for (0..n) |i| {
        if (pinned[i]) held += 1;
    }

    // Too little is being held for holding it to mean anything, so stop pretending this is an
    // incremental rebuild.
    //
    // Anchoring exists to make an *edit* look local: a handful of notes move, the rest of the
    // vault stays put. Reading a vault is the opposite shape of change — thousands of notes
    // arrive at once, all unanchored, and the few hundred already placed are not a frame the
    // newcomers can be positioned against. Taking the incremental path there gives the worst of
    // both: the single-level force pass, which cannot produce structure wider than its repulsion
    // cutoff, is asked to arrange nearly the whole vault, and it lands somewhere different every
    // batch. That is the churn — the web stretching and reshaping for the length of the read.
    //
    // Below this share of held nodes the solve gives up locality and repacks globally, which is
    // both stabler (the multilevel solver is deterministic in the graph, not in arrival order)
    // and far faster at this size.
    if (n >= multilevel_min and held * 100 < n * hold_min_pct) {
        @memset(pinned, false);
        held = 0;
    }

    const any_anchored = held > 0;
    // Nothing is being held, so this solve owns the whole board and may shape it globally —
    // a first build, the panel changing proportions, or a vault being read in. The opposite of
    // the incremental case the anchoring machinery exists for.
    const full_repack = !any_anchored;

    // The proportions the shape pass below aims for. `packComponents` clamps the same way, so the
    // two steps agree on the target even though they reach it by different means.

    // Anchored nodes start (and stay) exactly where they were. Everything else starts
    // *unplaced* — including survivors that carry a seed, which is the part that matters. A
    // node whose links changed is re-derived from its current neighbours below rather than
    // relaxed from wherever it currently sits, so its position is a function of the graph and
    // not of the order the edits arrived in. That is what makes add-link then remove-link put
    // it back: on the way out its neighbours are the ones it had before, unmoved, so it lands
    // back among them instead of being shoved off by the cluster it no longer belongs to.
    for (0..n) |i| {
        if (pinned[i]) {
            const s = seeds[i].?;
            pos[i] = .{ .x = s.x * seed_scale, .y = s.y * seed_scale };
            has_seed[i] = true;
        } else {
            pos[i] = .{};
            has_seed[i] = false;
        }
    }

    // Neighbour lists for seeding newcomers next to their linked survivors.
    var adj = try allocator.alloc(std.ArrayList(usize), n);
    defer {
        for (adj) |*list| list.deinit(allocator);
        allocator.free(adj);
    }
    for (adj) |*list| list.* = .empty;
    for (edges) |e| {
        if (e.a >= n or e.b >= n or e.a == e.b) continue;
        try adj[e.a].append(allocator, e.b);
        try adj[e.b].append(allocator, e.a);
    }
    // Sorted so `isNeighbor` can binary-search — see there.
    for (adj) |*list| std.mem.sort(usize, list.items, {}, std.sort.asc(usize));

    var spiral_i: usize = 0;
    for (0..n) |i| {
        if (has_seed[i]) continue;
        var sx: f32 = 0;
        var sy: f32 = 0;
        var sc: f32 = 0;
        for (adj[i].items) |j| {
            if (!has_seed[j]) continue;
            sx += pos[j].x;
            sy += pos[j].y;
            sc += 1;
        }
        if (full_repack and seeds[i] != null) {
            // Full repack: nothing is held, so there is no anchored frame for a neighbour
            // centroid to be *relative to*. Every node runs through this loop, and each one
            // derives from whichever of its neighbours happened to sit earlier in index order —
            // so node 1 lands on top of node 0, node 2 on top of that, and index order cascades
            // through the whole cloud as a scramble the force pass then has to undo. Its own
            // last position is the honest starting point when it has one; the solve does the rest.
            const s = seeds[i].?;
            pos[i] = .{ .x = s.x * seed_scale, .y = s.y * seed_scale };
        } else if (sc > 0) {
            // Jitter by a deterministic hash of the index so two newcomers sharing the
            // same neighbour centroid don't start on top of each other.
            const jitter = hashJitter(i);
            pos[i] = .{
                .x = sx / sc + jitter[0] * slot * 0.35,
                .y = sy / sc + jitter[1] * slot * 0.35,
            };
        } else if (seeds[i]) |s| {
            // Nothing placed to derive from, but it has been here before. Its own last position
            // is the best answer available and the only stable one — the alternative is a spiral
            // cell chosen by how many other nodes happened to need one this pass, which is how a
            // note that merely lost its last link ends up flung across the vault.
            pos[i] = .{ .x = s.x * seed_scale, .y = s.y * seed_scale };
            // With no links at all there is genuinely nothing to solve for it, so hold it there
            // rather than letting repulsion and the component packer carry it off — but only
            // while the rest of the board is being held for an *incremental* rebuild. Two cases
            // where this self-pin is exactly wrong:
            //
            //   • full repack — nothing is anchored, loose notes *are* the shape;
            //   • reshape_only — the caller is holding clusters on purpose and freeing loners
            //     so they can re-park into new proportions. Pinning every degree-0 note because
            //     a cluster is held freezes the entire rim, the cloud's span never tracks the
            //     panel, and the only thing left free to shimmer is the cluster itself (snap /
            //     refine fighting over its cells as the aspect bucket flips). That is precisely
            //     "outer nodes don't move, inner triangle jitters, shape never changes".
            if (adj[i].items.len == 0 and any_anchored and !opts.reshape_only) pinned[i] = true;
        } else {
            const c = hex.spiral(spiral_i);
            spiral_i += 1;
            pos[i] = hex.toWorld(c[0], c[1], slot);
        }
        has_seed[i] = true;
    }

    // Give the seeded cloud the area a vault of this size actually needs, before any solving.
    //
    // Newcomers are seeded onto their neighbours' centroid plus a fraction-of-a-cell jitter,
    // which is right for one note joining a settled vault. On a *first* build of a connected
    // graph it compounds: node 1 lands on node 0, node 2 on those, and the whole vault ends up
    // in a blob a few cells across regardless of how many notes it has. The force pass then has
    // to blow it back up from nothing, which is slow (every node is inside every other node's
    // repulsion cutoff, so the near-field grid degenerates to all-pairs and the solve is O(n²)
    // again) and looks like what it is — one dense hex clump that never opens out.
    //
    // A uniform scale about the centroid fixes the density without touching relative structure:
    // clusters keep their shape and their neighbours, the cloud just starts out at roughly the
    // size it wants to end up. Only on a full repack — an incremental rebuild is positioned
    // against anchored nodes in real coordinates and must not be rescaled out from under them.
    // A full repack of a vault big enough to have communities goes through the multilevel
    // solver, which is the only thing here that can produce structure larger than the repulsion
    // cutoff — see `multilevel.zig`. Incremental rebuilds deliberately do not: they are anchored
    // to real positions and want locality, not a fresh global arrangement.
    const use_multilevel = full_repack and n >= multilevel_min and !opts.reshape_only;
    if (use_multilevel) {
        const ml_edges = try allocator.alloc(multilevel.Edge, edges.len);
        defer allocator.free(ml_edges);
        var m: usize = 0;
        for (edges) |e| {
            if (e.a >= n or e.b >= n or e.a == e.b) continue;
            ml_edges[m] = .{ .a = @intCast(e.a), .b = @intCast(e.b) };
            m += 1;
        }
        try multilevel.solve(allocator, n, ml_edges[0..m], pos, .{ .keep_ladder = opts.keep_ladder });
        // Unit space is ~one node per unit²; the lattice wants one per `slot`².
        for (pos[0..n]) |*p| {
            p.x *= slot;
            p.y *= slot;
        }
        try fitToLattice(allocator, pos[0..n], snap);
    } else if (full_repack and n > 1) {
        spreadToDensity(pos[0..n], slot);
    }

    var mobile: usize = 0;
    for (0..n) |i| {
        if (!pinned[i]) mobile += 1;
    }

    if (opts.profile) |pr| pr.seed_ns = lap(&phase_start);

    // 2-hop pairs (friends-of-friends), deduped. Built once; the force loop just reads it.
    var hop2_list: std.ArrayList(Edge) = .empty;
    defer hop2_list.deinit(allocator);
    var hop2_seen = std.AutoHashMap(u64, void).init(allocator);
    defer hop2_seen.deinit();
    // Only the single-level force pass and `relaxLocal` consume this, and a multilevel solve
    // runs neither. Building it anyway is pure waste, and it is not cheap: the pair count grows
    // with the square of hub degree, which on a 100k vault is two seconds to produce a list
    // nothing reads.
    if (!use_multilevel) for (0..n) |i| {
        for (adj[i].items) |mid| {
            for (adj[mid].items) |j| {
                if (j <= i) continue;
                // Skip real edges — those already get the full spring.
                if (isNeighbor(adj[i].items, j)) continue;
                const key = (@as(u64, @intCast(i)) << 32) | @as(u64, @intCast(j));
                const gop = try hop2_seen.getOrPut(key);
                if (gop.found_existing) continue;
                try hop2_list.append(allocator, .{ .a = i, .b = j });
            }
        }
    };

    if (opts.profile) |pr| {
        pr.hop2_ns = lap(&phase_start);
        pr.hop2_pairs = hop2_list.items.len;
    }

    // Directory grouping is a function of the paths alone, so it is built once here and reused
    // by the force pass and the post-pack relax.
    var dir_buckets: ?DirBuckets = if (opts.paths) |ps|
        if (ps.len >= n) try DirBuckets.init(allocator, ps, n) else null
    else
        null;
    defer if (dir_buckets) |*b| b.deinit(allocator);

    // -- force -------------------------------------------------------------------
    // Nothing free to move means nothing to solve: every node is sitting where the last solve
    // left it, and the steps below will hand back exactly that.
    // The multilevel solve already ran the force model at every scale; a single-level pass on
    // top would only re-compress what it just opened up.
    const iters = if (mobile == 0 or opts.reshape_only or use_multilevel) 0 else forceIters(n);
    var force = try allocator.alloc(dvui.Point, n);
    defer allocator.free(force);

    for (0..iters) |it| {
        @memset(force, .{});
        const temp = 1.0 - @as(f32, @floatFromInt(it)) / @as(f32, @floatFromInt(iters));
        // Early iters take big steps so a new long spring can close; late iters settle.
        const step = slot * (0.70 * temp + 0.20);

        // Short-range repulsion only. Beyond the cutoff, clusters don't push on each other
        // — that's what lets empty hex cells open up between groups instead of everything
        // settling into one uniform lattice. The grid finds exactly the pairs inside the
        // cutoff; rebuilt each iteration because positions move.
        var sub: i96 = if (opts.profile != null) std.Io.Clock.boot.now(dvui.io).nanoseconds else 0;
        {
            var grid = try Grid.init(allocator, pos, n, repulse_cut);
            defer grid.deinit(allocator);
            if (opts.profile) |pr| {
                pr.f_grid_ns += lap(&sub);
                pr.repulse_cells = grid.cols * grid.rows;
            }
            applyRepulsion(grid, pos, force, repulse_k, repulse_cut, snap);
        }
        if (opts.profile) |pr| pr.f_repulse_ns += lap(&sub);

        // LinLog attraction along links: always pulls, stronger when far. Length is in *snap*
        // cells so a linked pair settles next to each other on the fine lattice rather than a
        // full packing slot apart (which is what made clusters read the same density as loners).
        for (edges) |e| {
            if (e.a >= n or e.b >= n or e.a == e.b) continue;
            applyAttract(force, pos, e.a, e.b, spring_k, snap);
        }
        for (hop2_list.items) |e| {
            applyAttract(force, pos, e.a, e.b, spring_k * hop2_k, snap);
        }
        if (opts.profile) |pr| pr.f_spring_ns += lap(&sub);

        // Folder cohorts: same-directory notes huddle even without a link; parent/child folders
        // pull more weakly. Skipped for pairs that already have a real edge — the spring covers
        // them. Walks directory buckets, not all pairs — see `applyFolderCohesion`.
        if (dir_buckets) |b| {
            applyFolderCohesion(b, adj, pos, force, spring_k * folder_k, snap);
        }
        if (opts.profile) |pr| pr.f_folder_ns += lap(&sub);

        // Tiny gravity + integrate. Anchored nodes were summed into `force` above — they pull
        // their neighbours and hold their neighbours off — but they are not integrated, so the
        // solve rearranges what changed around a fixed frame of what didn't.
        for (0..n) |i| {
            if (pinned[i]) continue;
            force[i].x -= pos[i].x * gravity_k;
            force[i].y -= pos[i].y * gravity_k;

            var fx = force[i].x;
            var fy = force[i].y;
            const fl = @sqrt(fx * fx + fy * fy);
            if (fl > step and fl > 1e-6) {
                fx *= step / fl;
                fy *= step / fl;
            }
            pos[i].x += fx;
            pos[i].y += fy;
        }

    }

    if (opts.profile) |pr| {
        pr.force_ns = lap(&phase_start);
        pr.force_iters = iters;
    }

    // Squeeze each island back down to lattice density before anything is parked or snapped.
    // Pull connected components apart into distinct islands. Within each component the
    // force pass already made a tight blob; this just parks those blobs with air between.
    try packComponents(allocator, n, adj, pos, pinned, slot, opts.aspect, opts.reshape_only, opts.paths);

    // Re-assert folder cohorts after packing. The ellipse park places islands for proportions;
    // without this pass, same-directory loners that the force huddle built get re-scattered by
    // golden-angle spokes. A short folder-weighted relax pulls cohorts back together without
    // undoing the overall outline.
    if (opts.profile) |pr| pr.pack_ns = lap(&phase_start);

    // Deliberately skipped after a multilevel solve. This pass is the single-level force model,
    // and running it on top of the ladder's answer re-compresses the whole cloud back to uniform
    // density — undoing precisely the large-scale structure the ladder exists to produce.
    if (opts.paths != null and mobile > 0 and !use_multilevel) {
        try relaxLocal(allocator, n, edges, hop2_list.items, adj, pos, pinned, slot, snap, repulse_k, repulse_cut, dir_buckets, 18);
    }

    if (opts.profile) |pr| pr.relax_ns = lap(&phase_start);

    // Settle reshape: park islands into the pane ellipse when there are several; when there is
    // only one connected blob the packer has nothing to arrange (early return), so the cloud's
    // span would stay forever round and the camera would only zoom — which is exactly the
    // "never becomes tall or wide" report. In that case (or whenever the park still missed the
    // ask by a wide margin) stretch the envelope to the pane aspect, then briefly re-relax
    // springs so local clusters round themselves back out instead of staying flattened.
    if (opts.reshape_only) {
        const want_a = std.math.clamp(opts.aspect, 1.0 / aspect_limit, aspect_limit);
        const got_a = pointsSpanAspect(pos[0..n]);
        const mismatch = got_a < 1e-3 or @max(got_a / want_a, want_a / got_a) > 1.35;
        if (mismatch) {
            enforceAspectEnvelope(pos[0..n], want_a);
            try relaxLocal(allocator, n, edges, hop2_list.items, adj, pos, pinned, slot, snap, repulse_k, repulse_cut, dir_buckets, 28);
        }
        // Falls through to the snap. A reshape used to hand back the continuous positions
        // directly, which quietly made it the one path that leaves the vault *off* the lattice —
        // and it is the path that runs every time the panel is resized, so after the first drag
        // nothing was on a grid dot again for the rest of the session.
        //
        // That is what makes a resized graph stop looking uniform. On the lattice every angle in
        // a group is a multiple of 60°, so a triangle of three linked notes is equilateral
        // because there is nowhere else for it to be; off it, a group keeps whatever angles the
        // envelope stretch and the relax happened to leave it with, and the stretch is
        // non-uniform by construction — it is squeezing one axis to make the cloud fit the pane.
        // Groups come out sheared toward the axis that was stretched, which is exactly "the
        // triangles go tall and skinny when the window is dragged vertically".
    }

    // -- snap to hex -------------------------------------------------------------
    // Claim order: high degree first, then stable by index. Hubs keep the cell nearest
    // their continuous position; leaves fill in around them. Snapping uses the finer
    // `snap` lattice — see `snap_div`.
    var order = try allocator.alloc(usize, n);
    defer allocator.free(order);
    for (0..n) |i| order[i] = i;
    std.mem.sort(usize, order, degrees, struct {
        fn less(deg: []const u32, a: usize, b: usize) bool {
            if (deg[a] != deg[b]) return deg[a] > deg[b];
            return a < b;
        }
    }.less);

    var occupied = std.AutoHashMap([2]i32, usize).init(allocator);
    defer occupied.deinit();
    try occupied.ensureTotalCapacity(@intCast(n));

    var cell = try allocator.alloc([2]i32, n);
    defer allocator.free(cell);

    // Anchored nodes claim first, ahead of even the biggest hub. Their position is the fixed
    // frame everything else was just solved against, so letting a mobile node take one of their
    // cells would push it off its home for a reason that has nothing to do with it.
    for (order) |i| {
        if (!pinned[i]) continue;
        const got = findFreeCell(hex.fromWorld(pos[i], snap), pos[i], snap, &occupied);
        try occupied.put(got, i);
        cell[i] = got;
        out[i] = hex.toWorld(got[0], got[1], snap);
    }

    for (order) |i| {
        if (pinned[i]) continue;
        const want = hex.fromWorld(pos[i], snap);
        // Prefer the previous cell only when the continuous solve still rounds there —
        // that kills shimmer on a no-op reindex without swallowing a real spring pull.
        const got = blk: {
            if (seeds[i]) |s| {
                const scaled: dvui.Point = .{ .x = s.x * seed_scale, .y = s.y * seed_scale };
                const prev_cell = hex.fromWorld(scaled, snap);
                if (!occupied.contains(prev_cell) and prev_cell[0] == want[0] and prev_cell[1] == want[1]) {
                    break :blk prev_cell;
                }
            }
            break :blk findFreeCell(want, pos[i], snap, &occupied);
        };
        try occupied.put(got, i);
        cell[i] = got;
        out[i] = hex.toWorld(got[0], got[1], snap);
    }

    if (opts.profile) |pr| pr.snap_ns = lap(&phase_start);

    // -- uncross / shorten -------------------------------------------------------
    if (mobile > 0) try refine(n, edges, cell, out, &occupied, pinned, snap, cross_penalty);

    if (opts.profile) |pr| {
        pr.refine_ns = lap(&phase_start);
        pr.total_ns = pr.seed_ns + pr.hop2_ns + pr.force_ns + pr.pack_ns +
            pr.relax_ns + pr.snap_ns + pr.refine_ns;
    }
}

/// Uniform bucket grid over the current positions, sized so that every pair within
/// `repulse_cut` of each other lands in the same cell or in touching cells.
///
/// Repulsion already dies at `repulse_cut` (see `repulse_cutoff_slots`), so the all-pairs loop
/// this replaces was spending nearly all of its time computing distances only to `continue`.
/// Walking 3×3 cells finds exactly the same pairs — this is not an approximation like
/// Barnes-Hut, it just stops looking where the answer is known to be zero. At vault scale it is
/// the difference between O(n²) and O(n·k) with k ≈ 20, which is most of what made a large
/// vault's first layout a multi-second freeze.
const Grid = struct {
    cell: f32,
    min_x: f32,
    min_y: f32,
    cols: usize,
    rows: usize,
    /// CSR-style buckets: `items[starts[c]..starts[c + 1]]` are the nodes in cell `c`.
    starts: []u32,
    items: []u32,

    /// Cap on cells so a far-flung outlier can't turn a tight cloud into a giant sparse grid.
    const max_cells: usize = 1 << 20;

    fn init(allocator: std.mem.Allocator, pos: []const dvui.Point, n: usize, cell: f32) !Grid {
        var min_x: f32 = std.math.floatMax(f32);
        var min_y: f32 = std.math.floatMax(f32);
        var max_x: f32 = -std.math.floatMax(f32);
        var max_y: f32 = -std.math.floatMax(f32);
        for (pos[0..n]) |p| {
            min_x = @min(min_x, p.x);
            min_y = @min(min_y, p.y);
            max_x = @max(max_x, p.x);
            max_y = @max(max_y, p.y);
        }

        const c = @max(cell, 1e-3);
        var cols = @as(usize, @intFromFloat(@floor((max_x - min_x) / c))) + 1;
        var rows = @as(usize, @intFromFloat(@floor((max_y - min_y) / c))) + 1;
        // Degenerate spreads (everything stacked, or one node a mile away) collapse to a single
        // cell rather than allocating a grid the size of the gap.
        if (cols * rows > max_cells or cols == 0 or rows == 0) {
            cols = 1;
            rows = 1;
        }

        const starts = try allocator.alloc(u32, cols * rows + 1);
        errdefer allocator.free(starts);
        const items = try allocator.alloc(u32, n);
        errdefer allocator.free(items);

        var g: Grid = .{
            .cell = c,
            .min_x = min_x,
            .min_y = min_y,
            .cols = cols,
            .rows = rows,
            .starts = starts,
            .items = items,
        };

        // Counting sort: tally per cell, prefix-sum, then scatter.
        @memset(starts, 0);
        for (pos[0..n]) |p| starts[g.cellOf(p) + 1] += 1;
        for (1..starts.len) |i| starts[i] += starts[i - 1];
        var cursor = try allocator.alloc(u32, cols * rows);
        defer allocator.free(cursor);
        for (0..cols * rows) |i| cursor[i] = starts[i];
        for (pos[0..n], 0..) |p, i| {
            const ci = g.cellOf(p);
            items[cursor[ci]] = @intCast(i);
            cursor[ci] += 1;
        }
        return g;
    }

    fn deinit(g: *Grid, allocator: std.mem.Allocator) void {
        allocator.free(g.starts);
        allocator.free(g.items);
    }

    fn cellOf(g: Grid, p: dvui.Point) usize {
        const cx = std.math.clamp(
            @as(isize, @intFromFloat(@floor((p.x - g.min_x) / g.cell))),
            0,
            @as(isize, @intCast(g.cols - 1)),
        );
        const cy = std.math.clamp(
            @as(isize, @intFromFloat(@floor((p.y - g.min_y) / g.cell))),
            0,
            @as(isize, @intCast(g.rows - 1)),
        );
        return @as(usize, @intCast(cy)) * g.cols + @as(usize, @intCast(cx));
    }
};

/// Short-range repulsion over every pair within `repulse_cut`, found through `g`.
///
/// Each unordered pair is visited once: within a cell only `j > i`, and across cells only the
/// four forward neighbours, which together with the cell itself cover all nine.
fn applyRepulsion(
    g: Grid,
    pos: []const dvui.Point,
    force: []dvui.Point,
    repulse_k: f32,
    repulse_cut: f32,
    snap: f32,
) void {
    const offsets = [_][2]isize{ .{ 1, 0 }, .{ -1, 1 }, .{ 0, 1 }, .{ 1, 1 } };
    for (0..g.rows) |cy| {
        for (0..g.cols) |cx| {
            const c = cy * g.cols + cx;
            const mine = g.items[g.starts[c]..g.starts[c + 1]];

            for (mine, 0..) |ia, k| {
                for (mine[k + 1 ..]) |ib| pair(pos, force, ia, ib, repulse_k, repulse_cut, snap);
            }

            for (offsets) |off| {
                const nx = @as(isize, @intCast(cx)) + off[0];
                const ny = @as(isize, @intCast(cy)) + off[1];
                if (nx < 0 or ny < 0 or nx >= g.cols or ny >= g.rows) continue;
                const nc = @as(usize, @intCast(ny)) * g.cols + @as(usize, @intCast(nx));
                const theirs = g.items[g.starts[nc]..g.starts[nc + 1]];
                for (mine) |ia| {
                    for (theirs) |ib| pair(pos, force, ia, ib, repulse_k, repulse_cut, snap);
                }
            }
        }
    }
}

fn pair(
    pos: []const dvui.Point,
    force: []dvui.Point,
    ia: u32,
    ib: u32,
    repulse_k: f32,
    repulse_cut: f32,
    snap: f32,
) void {
    const i = @as(usize, ia);
    const j = @as(usize, ib);
    var dx = pos[i].x - pos[j].x;
    var dy = pos[i].y - pos[j].y;
    var d2 = dx * dx + dy * dy;
    if (d2 < 1e-4) {
        // Deterministic in the *pair*, not in visit order — the grid does not walk pairs in the
        // same order the old all-pairs loop did, and a jitter keyed on that order would make the
        // layout depend on the bucketing.
        const lo = @min(i, j);
        const hi = @max(i, j);
        const jtr = hashJitter(lo * 31 + hi);
        dx = jtr[0] * 0.01;
        dy = jtr[1] * 0.01;
        d2 = dx * dx + dy * dy;
    }
    const d = @sqrt(d2);
    if (d > repulse_cut) return;
    const soft = @max(d, snap * 0.55);
    const inv = repulse_k / (soft * soft);
    const fade = 1.0 - (d / repulse_cut);
    const fx = (dx / d) * inv * fade;
    const fy = (dy / d) * inv * fade;
    force[i].x += fx;
    force[i].y += fy;
    force[j].x -= fx;
    force[j].y -= fy;
}

/// Scale `pts` about their centroid until they occupy roughly one lattice cell each.
///
/// Only ever expands — a cloud that is already spread out is left alone, so this cannot undo a
/// deliberate arrangement. See the call site for why a first build needs it.
fn spreadToDensity(pts: []dvui.Point, slot: f32) void {
    var min_x: f32 = std.math.floatMax(f32);
    var min_y: f32 = std.math.floatMax(f32);
    var max_x: f32 = -std.math.floatMax(f32);
    var max_y: f32 = -std.math.floatMax(f32);
    var cx: f32 = 0;
    var cy: f32 = 0;
    for (pts) |p| {
        min_x = @min(min_x, p.x);
        min_y = @min(min_y, p.y);
        max_x = @max(max_x, p.x);
        max_y = @max(max_y, p.y);
        cx += p.x;
        cy += p.y;
    }
    const inv_n = 1.0 / @as(f32, @floatFromInt(pts.len));
    cx *= inv_n;
    cy *= inv_n;

    // Hex packing puts one node per ~0.866·slot² of area; the extra slack is what leaves room
    // for the empty cells between islands that make groups read as groups.
    const want_area = @as(f32, @floatFromInt(pts.len)) * slot * slot * 0.87;
    const have_area = @max((max_x - min_x) * (max_y - min_y), 1e-6);
    // Only rescue an outright collapse. A seeding that is merely a bit tight is a legitimate
    // starting arrangement and the solve will open it out; scaling those too would perturb
    // layouts that are already fine — including the island ring the aspect fit depends on.
    if (have_area >= want_area * collapse_ratio) return;

    const scale = @sqrt(want_area / have_area);
    for (pts) |*p| {
        p.x = cx + (p.x - cx) * scale;
        p.y = cy + (p.y - cy) * scale;
    }
}

/// Scale `pts` about the origin until even their densest neighbourhood fits on a `cell` lattice.
///
/// The snap stage puts every node on its own lattice cell, taking the nearest *free* one. Where
/// the solve packed nodes closer together than the lattice can hold, the surplus cascades
/// outward, and each displaced node displaces another — so a single over-dense core is enough to
/// fill the entire disc solid and erase every void the solve worked out. That is the last thing
/// standing between a structured layout and "one massive hex".
///
/// Scaling up rather than thinning out is the honest fix: nothing is dropped, the arrangement is
/// preserved exactly, and the map simply occupies more world. A big vault opens further zoomed
/// out, which is what a big vault should do.
///
/// A high percentile rather than the true maximum, so one pathological cluster cannot blow the
/// whole map up on its own.
fn fitToLattice(allocator: std.mem.Allocator, pts: []dvui.Point, cell: f32) !void {
    if (pts.len < 2) return;

    var counts = std.AutoHashMap([2]i32, u32).init(allocator);
    defer counts.deinit();
    for (pts) |p| {
        const key: [2]i32 = .{
            @intFromFloat(@floor(p.x / cell)),
            @intFromFloat(@floor(p.y / cell)),
        };
        const gop = try counts.getOrPut(key);
        gop.value_ptr.* = if (gop.found_existing) gop.value_ptr.* + 1 else 1;
    }

    var occ: std.ArrayList(u32) = .empty;
    defer occ.deinit(allocator);
    var it = counts.valueIterator();
    while (it.next()) |v| try occ.append(allocator, v.*);
    if (occ.items.len == 0) return;
    std.mem.sort(u32, occ.items, {}, std.sort.asc(u32));
    const p99 = occ.items[(occ.items.len * 99) / 100];
    if (p99 <= 1) return;

    // One cell holding `p99` nodes needs `sqrt(p99)` times the linear room to hold one each.
    const scale = @min(@sqrt(@as(f32, @floatFromInt(p99))), lattice_fit_max_scale);
    for (pts) |*p| {
        p.x *= scale;
        p.y *= scale;
    }
}

fn forceIters(n: usize) usize {
    // More nodes → each iter is dearer; also a well-seeded big graph needs less settling.
    if (n <= 40) return force_iters_cap;
    if (n >= 800) return force_iters_floor;
    const t = @as(f32, @floatFromInt(n - 40)) / 760.0;
    const v = @as(f32, @floatFromInt(force_iters_cap)) * (1.0 - t) +
        @as(f32, @floatFromInt(force_iters_floor)) * t;
    return @intFromFloat(@round(v));
}

fn hashJitter(i: usize) [2]f32 {
    // Tiny deterministic unit-ish vector in [-1, 1]^2 from the index alone.
    var h: u32 = @truncate(i);
    h ^= h >> 16;
    h *%= 0x7feb352d;
    h ^= h >> 15;
    h *%= 0x846ca68b;
    h ^= h >> 16;
    const x = @as(f32, @floatFromInt(h & 0xffff)) / 32768.0 - 1.0;
    const y = @as(f32, @floatFromInt((h >> 16) & 0xffff)) / 32768.0 - 1.0;
    return .{ x, y };
}

/// Adjacency lists are kept sorted (see `sortAdj`) so this is a binary search rather than the
/// linear scan it used to be. It sits inside the folder-cohort pass, which visits far more pairs
/// than there are edges, so on a hub-heavy vault the scan was a large share of the solve.
fn isNeighbor(nbrs: []const usize, j: usize) bool {
    var lo: usize = 0;
    var hi: usize = nbrs.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (nbrs[mid] == j) return true;
        if (nbrs[mid] < j) lo = mid + 1 else hi = mid;
    }
    return false;
}

/// Directory buckets over `paths`, so the folder-cohort pass can walk *related* pairs instead of
/// all pairs. `folderKinship` is zero for two directories that share no leading segment and are
/// not parent/child, which is nearly every pair in a vault with more than a couple of folders —
/// the all-pairs loop existed only to rediscover that.
const DirBuckets = struct {
    /// Node indices grouped by directory: `items[starts[b]..starts[b + 1]]`.
    starts: []u32,
    items: []u32,
    /// One representative path per bucket, for the pairwise `folderKinship` call.
    dirs: [][]const u8,

    fn init(allocator: std.mem.Allocator, paths: []const []const u8, n: usize) !DirBuckets {
        var map: std.StringHashMapUnmanaged(u32) = .empty;
        defer map.deinit(allocator);

        var dirs: std.ArrayList([]const u8) = .empty;
        errdefer dirs.deinit(allocator);
        const bucket_of = try allocator.alloc(u32, n);
        defer allocator.free(bucket_of);

        for (0..n) |i| {
            const d = dirOf(paths[i]);
            const gop = try map.getOrPut(allocator, d);
            if (!gop.found_existing) {
                gop.value_ptr.* = @intCast(dirs.items.len);
                try dirs.append(allocator, paths[i]);
            }
            bucket_of[i] = gop.value_ptr.*;
        }

        const nb = dirs.items.len;
        const starts = try allocator.alloc(u32, nb + 1);
        errdefer allocator.free(starts);
        const items = try allocator.alloc(u32, n);
        errdefer allocator.free(items);

        @memset(starts, 0);
        for (bucket_of) |b| starts[b + 1] += 1;
        for (1..starts.len) |i| starts[i] += starts[i - 1];
        var cursor = try allocator.alloc(u32, nb);
        defer allocator.free(cursor);
        for (0..nb) |i| cursor[i] = starts[i];
        for (bucket_of, 0..) |b, i| {
            items[cursor[b]] = @intCast(i);
            cursor[b] += 1;
        }

        return .{ .starts = starts, .items = items, .dirs = try dirs.toOwnedSlice(allocator) };
    }

    fn deinit(b: *DirBuckets, allocator: std.mem.Allocator) void {
        allocator.free(b.starts);
        allocator.free(b.items);
        allocator.free(b.dirs);
    }
};

/// The folder-cohort attraction, over directory buckets. Same forces as the all-pairs version:
/// a pair is skipped when it already has a real edge (the spring covers it) or when its kinship
/// is below the old 0.05 floor.
fn applyFolderCohesion(
    b: DirBuckets,
    adj: []const std.ArrayList(usize),
    pos: []const dvui.Point,
    force: []dvui.Point,
    k: f32,
    snap: f32,
) void {
    const nb = b.dirs.len;
    for (0..nb) |bi| {
        for (bi..nb) |bj| {
            const kin = if (bi == bj) folderKinship(b.dirs[bi], b.dirs[bi]) else folderKinship(b.dirs[bi], b.dirs[bj]);
            if (kin < 0.05) continue;
            const strength = k * kin;

            const first = b.items[b.starts[bi]..b.starts[bi + 1]];
            const second = if (bi == bj) first else b.items[b.starts[bj]..b.starts[bj + 1]];

            // A folder small enough to keep the exact pairwise pull gets it — that is the shape
            // of an ordinary vault directory, and it is what tunes the cohort huddle. Past the
            // threshold the cost is quadratic in a way no vault should have to pay (one flat
            // folder of 2000 notes is 2M pairs *per iteration*), so those fall back to pulling
            // each member toward the cohort's centre of mass instead.
            //
            // The centroid form is also the better shape for what the map is meant to read as: a
            // big folder becomes one bright core with its notes gathered around it, rather than a
            // uniformly-spaced crystal of every note tugging on every other. Galaxies have
            // centres; crystals do not.
            if (first.len <= exact_cohort_max and second.len <= exact_cohort_max) {
                if (bi == bj) {
                    for (first, 0..) |ia32, x| {
                        const ia: usize = ia32;
                        for (first[x + 1 ..]) |ib32| {
                            const ib: usize = ib32;
                            if (isNeighbor(adj[ia].items, ib)) continue;
                            applyAttract(force, pos, ia, ib, strength, snap);
                        }
                    }
                } else {
                    for (first) |ia32| {
                        const ia: usize = ia32;
                        for (second) |ib32| {
                            const ib: usize = ib32;
                            if (isNeighbor(adj[ia].items, ib)) continue;
                            applyAttract(force, pos, ia, ib, strength, snap);
                        }
                    }
                }
                continue;
            }

            // Each member is pulled toward the *other* group's centre (its own, when bi == bj).
            // Strength is scaled by how many pairwise pulls it stands in for, capped so a huge
            // folder doesn't out-pull the real links.
            const target = centroid(pos, second);
            const scale = @min(@as(f32, @floatFromInt(second.len)), exact_cohort_max);
            for (first) |ia32| {
                const ia: usize = ia32;
                applyAttractToPoint(force, pos, ia, target, strength * scale, snap);
            }
            if (bi != bj) {
                const back = centroid(pos, first);
                const back_scale = @min(@as(f32, @floatFromInt(first.len)), exact_cohort_max);
                for (second) |ib32| {
                    const ib: usize = ib32;
                    applyAttractToPoint(force, pos, ib, back, strength * back_scale, snap);
                }
            }
        }
    }
}

/// LinLog-style attraction: always pulls `a` and `b` together, stronger when far.
fn applyAttract(force: []dvui.Point, pos: []const dvui.Point, a: usize, b: usize, k: f32, slot: f32) void {
    const dx = pos[b].x - pos[a].x;
    const dy = pos[b].y - pos[a].y;
    const d = @sqrt(dx * dx + dy * dy);
    if (d < 1e-4) return;
    const mag = k * @log(1.0 + d / slot);
    const fx = (dx / d) * mag;
    const fy = (dy / d) * mag;
    force[a].x += fx;
    force[a].y += fy;
    force[b].x -= fx;
    force[b].y -= fy;
}

/// One-sided variant of `applyAttract`: pulls `a` toward a fixed point. Used for the centroid
/// form of folder cohesion, where the "other end" is a centre of mass rather than a node.
fn applyAttractToPoint(force: []dvui.Point, pos: []const dvui.Point, a: usize, to: dvui.Point, k: f32, slot: f32) void {
    const dx = to.x - pos[a].x;
    const dy = to.y - pos[a].y;
    const d = @sqrt(dx * dx + dy * dy);
    if (d < 1e-4) return;
    const mag = k * @log(1.0 + d / slot);
    force[a].x += (dx / d) * mag;
    force[a].y += (dy / d) * mag;
}

fn centroid(pos: []const dvui.Point, members: []const u32) dvui.Point {
    if (members.len == 0) return .{};
    var sx: f32 = 0;
    var sy: f32 = 0;
    for (members) |m| {
        sx += pos[m].x;
        sy += pos[m].y;
    }
    const inv = 1.0 / @as(f32, @floatFromInt(members.len));
    return .{ .x = sx * inv, .y = sy * inv };
}

const Component = struct {
    members: std.ArrayList(usize) = .empty,
    cx: f32 = 0,
    cy: f32 = 0,
    radius: f32 = 0,
    /// Air this island wants around it. A cluster needs to read as a distinct blob, but a lone
    /// note is already a full lattice step from its neighbours and charging it the same berth as a
    /// cluster is what turns a vault of mostly-unlinked notes into a vast empty cloud.
    air: f32 = 0,
    /// Holds at least one anchored node, so its place on the board is already settled.
    fixed: bool = false,
};

/// Golden angle — successive multiples never repeat a direction, which is what keeps spiral
/// placement from laying components out along spokes.
const golden_angle: f32 = std.math.pi * (3.0 - @sqrt(5.0));

/// Area this island claims once its berth is counted, sharing the air with whoever it ends up
/// next to. Summed to decide how far out the next island should start looking.
fn footprintArea(c: *const Component) f32 {
    const r = c.radius + c.air * 0.5;
    return std.math.pi * r * r;
}

/// Translate each connected component so their bounding circles pack around the origin without
/// overlapping. Biggest first, so clusters take the middle and loose notes end up orbiting on the
/// rim — which is both the reading you want and the tightest arrangement, since single notes fill
/// the awkward gaps a cluster can't.
///
/// Placement is greedy: each island gets a *preferred* spot and then rings outward from it until
/// it isn't touching anything already down. Because collisions resolve by pushing outward, the
/// preferred spot can afford to be optimistic — so it comes off a ring sized by the total area
/// packed so far, which grows as √count the way a disc filling up actually does. Growing it by
/// diameter instead is what made the cloud so sparse: the radius climbed *linearly* with island
/// count, so forty loose notes were strewn over forty slots of empty ocean and fit-to-extents had
/// to pull back until the vault was a speck.
///
/// This is also the step that used to make the whole vault shuffle: one island gaining a note grows
/// its radius, which shifts its own spiral slot *and* the running orbit of every island after
/// it, so all of them slide. A component containing an anchored node is therefore left exactly
/// where it is, and the ones that do need parking are fitted into the space around them.
fn packComponents(
    allocator: std.mem.Allocator,
    n: usize,
    adj: []const std.ArrayList(usize),
    pos: []dvui.Point,
    pinned: []const bool,
    slot: f32,
    aspect: f32,
    /// The panel changed shape and the graph did not. Free islands are re-parked into a fresh
    /// ellipse for `aspect` (clusters inward, loners outer band).
    reshaping: bool,
    paths: ?[]const []const u8,
) !void {
    var comp_of = try allocator.alloc(usize, n);
    defer allocator.free(comp_of);
    @memset(comp_of, std.math.maxInt(usize));

    var comps: std.ArrayList(Component) = .empty;
    defer {
        for (comps.items) |*c| c.members.deinit(allocator);
        comps.deinit(allocator);
    }

    var stack: std.ArrayList(usize) = .empty;
    defer stack.deinit(allocator);

    for (0..n) |start| {
        if (comp_of[start] != std.math.maxInt(usize)) continue;
        const id = comps.items.len;
        try comps.append(allocator, .{});
        try stack.append(allocator, start);
        comp_of[start] = id;
        while (stack.items.len > 0) {
            const u = stack.pop().?;
            try comps.items[id].members.append(allocator, u);
            for (adj[u].items) |v| {
                if (comp_of[v] != std.math.maxInt(usize)) continue;
                comp_of[v] = id;
                try stack.append(allocator, v);
            }
        }
    }

    // One island: nothing to arrange against anything else. Proportions come from *where*
    // islands sit, and a single rigid blob has no degrees of freedom there — stretching its
    // internals would flatten clusters (the triangle→line bug). Loners / other islands are what
    // carry wide vs tall; with none, the cloud stays roughly round and the early return is honest.
    if (comps.items.len <= 1) return;

    // Measure each blob.
    for (comps.items) |*c| {
        var sx: f32 = 0;
        var sy: f32 = 0;
        for (c.members.items) |i| {
            sx += pos[i].x;
            sy += pos[i].y;
        }
        const m: f32 = @floatFromInt(c.members.items.len);
        c.cx = sx / m;
        c.cy = sy / m;
        var r: f32 = 0;
        for (c.members.items) |i| {
            const dx = pos[i].x - c.cx;
            const dy = pos[i].y - c.cy;
            r = @max(r, @sqrt(dx * dx + dy * dy));
        }
        // A single node still needs a slot of personal space.
        c.radius = @max(r, slot * 0.5);
        c.air = if (c.members.items.len > 1) slot * component_gap_slots else slot * lone_air_slots;
        c.fixed = blk: {
            for (c.members.items) |i| if (pinned[i]) break :blk true;
            break :blk false;
        };
    }

    // Largest components claim the centre; isolates fan out on the rim.
    std.mem.sort(Component, comps.items, {}, struct {
        fn less(_: void, a: Component, b: Component) bool {
            if (a.members.items.len != b.members.items.len)
                return a.members.items.len > b.members.items.len;
            return a.members.items[0] < b.members.items[0];
        }
    }.less);

    // Anything already anchored is on the board and part of what the rest has to fit around,
    // so its area counts from the start — and it goes into the collision index up front, since
    // every island parked below has to miss it.
    var placed = PlacedIndex.init(allocator, comps.items);
    defer placed.deinit();

    var any_fixed = false;
    var area: f32 = 0;
    for (comps.items, 0..) |*c, ci| {
        if (!c.fixed) continue;
        any_fixed = true;
        area += footprintArea(c);
        try placed.insert(comps.items, ci, .{ .x = c.cx, .y = c.cy });
    }

    // The region islands are parked into: an ellipse with the panel's proportions.
    //
    // This is the *only* place proportions are applied, and deliberately so — it moves whole
    // islands around without ever touching the shape of one. Stretching node coordinates instead
    // reshapes every cluster along with the cloud, and a triangle of three linked notes comes out
    // as a flat line with its nodes sitting on their own connecting edges.
    //
    // The subtlety is the floor. Sizing the ellipse purely by area and stretching it
    // area-preservingly (`√a` and `1/√a`) is wrong whenever one component is big: that component
    // sets the cloud's height on its own, the islands get parked on a ring no taller than it, and
    // the *width* grows by only `√a`. So the finished cloud saturates at `√aspect` however wide
    // the panel gets — a 3.5:1 panel yielding a 1.9:1 cloud, and pulling the panel wider doing
    // almost nothing. Which is precisely what "resizing doesn't reshape the cloud" looks like from
    // the outside, and why it survived so long: it *was* responding, just to the square root.
    //
    // So the minor axis is floored at the largest island's own radius, and the major derived from
    // it. The islands then have to reach out far enough to make the requested proportions real
    // rather than merely being smeared along a ring the core already decided the size of.
    const a = std.math.clamp(aspect, 1.0 / aspect_limit, aspect_limit);
    var total_area: f32 = 0;
    var core_r: f32 = 0;
    for (comps.items) |*c| {
        total_area += footprintArea(c);
        core_r = @max(core_r, c.radius + c.air * 0.5);
    }
    const isle_r = slot * (0.5 + lone_air_slots * 0.5);
    const axes = ellipseAxes(a, total_area, core_r, isle_r);
    const semi_x = axes.x;
    const semi_y = axes.y;

    // The search that resolves island collisions has to lean the same way the region does, or the
    // accumulated resolutions pull the cloud back toward round.
    const geo = @sqrt(@max(semi_x * semi_y, 1e-6));
    const sx = semi_x / geo;
    const sy = semi_y / geo;

    for (comps.items, 0..) |*c, ci| {
        if (c.fixed) continue;
        const want: dvui.Point = if (!any_fixed or reshaping) blk: {
            // First build, or a settle reshape: lay the board out cleanly into the pane ellipse.
            //
            // Clusters work inward and lone notes go to the outer band, which is both the reading
            // you want and what makes the requested proportions actually happen. Spreading
            // everything evenly through the region instead — radius by √(area used), the obvious
            // thing — quietly fails: with the biggest cluster pinning the cloud's height at its
            // own diameter, the far ends of the *width* only get reached if something is actually
            // placed out there, and points scattered through an ellipse's interior sample its
            // extremes poorly. The cloud then comes out markedly rounder than asked for however
            // wide the region is, which is most of why widening the panel did so little.
            //
            // A lone note has nothing tying it anywhere, so it is free to be the thing that goes
            // out and defines the shape. It sits in the *outer band* rather than exactly on the
            // rim: parking every loner at frac=1.0 squeezed them against the camera's clip edge
            // (and against each other once `freeSpotNear` started resolving collisions by
            // stepping further out), which is what "nodes jammed on the boundary" looked like.
            const alone = c.members.items.len == 1;
            const frac = if (alone) blk2: {
                // Spread 0.72‥0.94 around the ring so successive loners don't all claim the
                // same radius and then shove each other past the ellipse.
                const phase = @mod(@as(f32, @floatFromInt(ci)) * 0.6180339887, 1.0);
                break :blk2 0.72 + 0.22 * phase;
            } else @sqrt(std.math.clamp(area / @max(total_area, 1), 0, 1));
            const theta = @as(f32, @floatFromInt(ci)) * golden_angle;
            var spot: dvui.Point = .{ .x = @cos(theta) * semi_x * frac, .y = @sin(theta) * semi_y * frac };
            // Bias toward already-placed folder kin so same-directory loners land as a cohort
            // instead of being sprinkled around the ellipse by golden angle alone.
            if (paths) |ps| {
                if (ps.len >= n) {
                    if (folderKinCentroid(comps.items, c, ps, n)) |kin| {
                        // Prefer the cohort heavily — golden angle only breaks ties / fills the
                        // outline. Otherwise packComponents undoes the force pass's folder huddle
                        // by sprinkling same-directory loners around the ellipse.
                        spot.x = spot.x * 0.2 + kin.x * 0.8;
                        spot.y = spot.y * 0.2 + kin.y * 0.8;
                    }
                }
            }
            break :blk spot;
        } else blk: {
            // Islands are already placed around this one, so start from where it is rather than
            // from the rim — parking a newly linked pair outside the entire vault is how two notes
            // finding each other ended up flung to the far edge. The nudge along the line to the
            // origin is what sorts the board over time: clusters work their way in, lone notes
            // ease out.
            const d2 = c.cx * c.cx + c.cy * c.cy;
            if (d2 < 1e-6) break :blk .{ .x = c.cx, .y = c.cy };
            const f: f32 = if (c.members.items.len > 1) 1 - migrate_frac else 1 + drift_frac;
            break :blk .{ .x = c.cx * f, .y = c.cy * f };
        };

        translateComponent(c, pos, freeSpotNear(placed, comps.items, c, want, slot * 0.5, sx, sy));
        c.fixed = true;
        try placed.insert(comps.items, ci, .{ .x = c.cx, .y = c.cy });
        area += footprintArea(c);
    }
}

/// Width-over-height of the axis-aligned bounds of `pts`. 1 when empty or degenerate.
fn pointsSpanAspect(pts: []const dvui.Point) f32 {
    if (pts.len == 0) return 1;
    var min_x: f32 = std.math.floatMax(f32);
    var min_y: f32 = std.math.floatMax(f32);
    var max_x: f32 = -std.math.floatMax(f32);
    var max_y: f32 = -std.math.floatMax(f32);
    for (pts) |p| {
        min_x = @min(min_x, p.x);
        min_y = @min(min_y, p.y);
        max_x = @max(max_x, p.x);
        max_y = @max(max_y, p.y);
    }
    const w = max_x - min_x;
    const h = max_y - min_y;
    if (h < 1e-3) return if (w < 1e-3) 1 else aspect_limit;
    return w / h;
}

/// Non-uniform scale about the centroid so the cloud's AABB matches `aspect`, area-preserving.
/// Used when island packing cannot carry the shape (one connected component). Springs must be
/// re-relaxed afterward — raw, this is exactly the stretch that flattens a triangle into a line.
fn enforceAspectEnvelope(pos: []dvui.Point, aspect: f32) void {
    if (pos.len < 2) return;
    const a = std.math.clamp(aspect, 1.0 / aspect_limit, aspect_limit);
    var cx: f32 = 0;
    var cy: f32 = 0;
    for (pos) |p| {
        cx += p.x;
        cy += p.y;
    }
    const inv_n = 1.0 / @as(f32, @floatFromInt(pos.len));
    cx *= inv_n;
    cy *= inv_n;
    var min_x: f32 = std.math.floatMax(f32);
    var min_y: f32 = std.math.floatMax(f32);
    var max_x: f32 = -std.math.floatMax(f32);
    var max_y: f32 = -std.math.floatMax(f32);
    for (pos) |p| {
        min_x = @min(min_x, p.x);
        min_y = @min(min_y, p.y);
        max_x = @max(max_x, p.x);
        max_y = @max(max_y, p.y);
    }
    const hw = @max((max_x - min_x) * 0.5, 1e-3);
    const hh = @max((max_y - min_y) * 0.5, 1e-3);
    // Same geometric-mean radius, new proportions.
    const geo = @sqrt(hw * hh);
    const th = geo / @sqrt(a);
    const tw = a * th;
    const sx = tw / hw;
    const sy = th / hh;
    for (pos) |*p| {
        p.x = cx + (p.x - cx) * sx;
        p.y = cy + (p.y - cy) * sy;
    }
}

/// Relax a *part* of an existing arrangement, holding the rest still.
///
/// The incremental half of the layout. A rebuild that reuses last build's positions is fast and
/// completely static: link two notes that both already have a place and nothing moves, because
/// nothing recomputes — the new edge is simply drawn across whatever distance already separated
/// them. Re-solving the whole vault instead is correct and unaffordable, since a rebuild runs on
/// every save.
///
/// So the notes whose links changed, and their neighbours, are unpinned and allowed to settle
/// against a frozen vault. Pinned nodes still push and pull — they are in `edges` and in the
/// repulsion grid — they just are not integrated, so the edit stays local and everything the
/// reader was not editing keeps the position they already knew.
///
/// `iters` is small on purpose: this runs on the rebuild path, and the free set is a
/// neighbourhood rather than a vault.
pub fn relaxDirty(
    allocator: std.mem.Allocator,
    n: usize,
    edges: []const Edge,
    pos: []dvui.Point,
    pinned: []const bool,
    iters: usize,
) !void {
    if (n < 2 or iters == 0) return;
    var adj = try allocator.alloc(std.ArrayList(usize), n);
    defer {
        for (adj) |*list| list.deinit(allocator);
        allocator.free(adj);
    }
    for (adj) |*list| list.* = .empty;
    for (edges) |e| {
        if (e.a >= n or e.b >= n or e.a == e.b) continue;
        try adj[e.a].append(allocator, e.b);
        try adj[e.b].append(allocator, e.a);
    }
    for (adj) |*list| std.mem.sort(usize, list.items, {}, std.sort.asc(usize));

    // The same scale the full solve works in, so a relaxed neighbourhood settles at the same
    // density as the vault around it rather than at one of its own.
    const slot = slotSpacingFor(n);
    try relaxLocal(
        allocator,
        n,
        edges,
        &.{}, // no second-hop pairs: those shape a whole-vault solve, not a local settle
        adj,
        pos,
        pinned,
        slot,
        slot / snap_div,
        slot * slot * 0.32,
        slot * repulse_cutoff_slots,
        null,
        iters,
    );
}

/// Short force pass used after an envelope stretch: restore local spring lengths / repulsion so
/// clusters round out again while the overall outline mostly keeps the pane's proportions.
fn relaxLocal(
    allocator: std.mem.Allocator,
    n: usize,
    edges: []const Edge,
    hop2: []const Edge,
    adj: []const std.ArrayList(usize),
    pos: []dvui.Point,
    pinned: []const bool,
    slot: f32,
    snap: f32,
    repulse_k: f32,
    repulse_cut: f32,
    buckets: ?DirBuckets,
    iters: usize,
) !void {
    if (iters == 0 or n < 2) return;
    const force = try allocator.alloc(dvui.Point, n);
    defer allocator.free(force);
    for (0..iters) |it| {
        @memset(force, .{});
        const temp = 1.0 - @as(f32, @floatFromInt(it)) / @as(f32, @floatFromInt(iters));
        const step = slot * (0.45 * temp + 0.12);
        {
            var grid = try Grid.init(allocator, pos, n, repulse_cut);
            defer grid.deinit(allocator);
            applyRepulsion(grid, pos, force, repulse_k, repulse_cut, snap);
        }
        for (edges) |e| {
            if (e.a >= n or e.b >= n or e.a == e.b) continue;
            applyAttract(force, pos, e.a, e.b, spring_k, snap);
        }
        for (hop2) |e| {
            applyAttract(force, pos, e.a, e.b, spring_k * hop2_k, snap);
        }
        if (buckets) |b| {
            applyFolderCohesion(b, adj, pos, force, spring_k * folder_k, snap);
        }
        for (0..n) |i| {
            if (pinned[i]) continue;
            var fx = force[i].x - pos[i].x * gravity_k;
            var fy = force[i].y - pos[i].y * gravity_k;
            const fl = @sqrt(fx * fx + fy * fy);
            if (fl > step and fl > 1e-6) {
                fx *= step / fl;
                fy *= step / fl;
            }
            pos[i].x += fx;
            pos[i].y += fy;
        }
    }
}

/// Directory portion of a vault-relative note path (`a/b/Note.md` → `a/b`). Empty = vault root.
fn dirOf(path: []const u8) []const u8 {
    return std.fs.path.dirnamePosix(path) orelse "";
}

/// Count shared leading path segments between two directories (`a/b` vs `a/c` → 1).
fn sharedDirSegments(a: []const u8, b: []const u8) usize {
    var i: usize = 0;
    var segs: usize = 0;
    const n = @min(a.len, b.len);
    while (i < n) : (i += 1) {
        if (a[i] != b[i]) break;
        if (a[i] == '/') segs += 1;
    }
    if (i == n and a.len == b.len) {
        // Exact directory match — count the final segment too when non-empty.
        if (n > 0) segs += 1;
    } else if (i == n) {
        // One path is a prefix of the other at a segment boundary.
        const longer = if (a.len > b.len) a else b;
        if (n == 0 or longer[n] == '/') segs += 1;
    }
    return segs;
}

/// 0‥1 kinship from folder proximity. Same directory → 1; parent/child → ~0.55; shared
/// ancestor → weaker; unrelated → 0. Used as a multiplier on `folder_k`.
fn folderKinship(path_a: []const u8, path_b: []const u8) f32 {
    if (path_a.len == 0 or path_b.len == 0) return 0; // phantoms / unknown
    const a = dirOf(path_a);
    const b = dirOf(path_b);
    if (a.len == 0 and b.len == 0) return 0.22; // both at vault root
    if (a.len == 0 or b.len == 0) return 0.08; // root vs nested — barely
    if (std.mem.eql(u8, a, b)) return 1.0;
    // Direct parent/child folder.
    if (a.len < b.len and std.mem.startsWith(u8, b, a) and b[a.len] == '/') return 0.55;
    if (b.len < a.len and std.mem.startsWith(u8, a, b) and a[b.len] == '/') return 0.55;
    const segs = sharedDirSegments(a, b);
    if (segs == 0) return 0;
    return 0.12 + 0.12 * @min(@as(f32, @floatFromInt(segs)), 3);
}

/// Centroid of already-placed islands that share meaningful folder kinship with `c`, if any.
fn folderKinCentroid(
    comps: []const Component,
    c: *const Component,
    paths: []const []const u8,
    n: usize,
) ?dvui.Point {
    if (c.members.items.len == 0) return null;
    const my = paths[c.members.items[0]];
    var sx: f32 = 0;
    var sy: f32 = 0;
    var wsum: f32 = 0;
    for (comps) |*other| {
        if (other == c or !other.fixed or other.members.items.len == 0) continue;
        const oi = other.members.items[0];
        if (oi >= n) continue;
        const kin = folderKinship(my, paths[oi]);
        if (kin < 0.4) continue; // same-folder / parent-child only for park bias
        sx += other.cx * kin;
        sy += other.cy * kin;
        wsum += kin;
    }
    if (wsum < 1e-3) return null;
    return .{ .x = sx / wsum, .y = sy / wsum };
}

/// Semi-axes of the island-packing ellipse for aspect `a` (already clamped), given the islands'
/// total footprint and the largest one's clearance radius.
fn ellipseAxes(a: f32, total_area: f32, core_r: f32, isle_r: f32) struct { x: f32, y: f32 } {
    var semi_y = @sqrt(@max(total_area, 1) / (std.math.pi * a));
    var semi_x = a * semi_y;
    const shorter = @min(semi_x, semi_y);
    if (shorter > 1e-3 and core_r > shorter) {
        const grow = core_r / shorter;
        semi_x *= grow;
        semi_y *= grow;
    }
    // Islands are parked by their *centres*, but what the panel sees is their outer edge.
    // Solve for the axis that makes the *outer* proportions come out at `a`.
    const half_h = @max(semi_y + isle_r, core_r);
    const half_w = @max(semi_x + isle_r, core_r);
    if (a >= 1) {
        semi_x = @max(semi_x, a * half_h - isle_r);
    } else {
        semi_y = @max(semi_y, half_w / a - isle_r);
    }
    return .{ .x = semi_x, .y = semi_y };
}

/// Nearest position at or outside `want` where `c` clears everything already placed. Rings
/// outward in `step` increments, sampling more angles as the ring grows so the search stays
/// roughly even in arc length. Bounded; on giving up it returns `want`, which may overlap — the
/// hex snap resolves cell collisions regardless, so that is ugly rather than wrong.
///
/// `sx`/`sy` stretch the search the same way the placement ring is stretched. Searching in circles
/// while placing on an ellipse throws the shape away: every collision is resolved by stepping in
/// whichever direction happens to be free, so on a board with lots of same-sized islands the
/// accumulated resolutions pull the cloud back toward round.
fn freeSpotNear(
    placed: PlacedIndex,
    comps: []const Component,
    c: *const Component,
    want: dvui.Point,
    step: f32,
    sx: f32,
    sy: f32,
) dvui.Point {
    if (!placed.overlaps(comps, c, want)) return want;
    var k: usize = 1;
    while (k <= 256) : (k += 1) {
        const kf: f32 = @floatFromInt(k);
        const ring = step * kf;
        const samples = 6 * k;
        for (0..samples) |s| {
            const frac = @as(f32, @floatFromInt(s)) / @as(f32, @floatFromInt(samples));
            // Golden-angle phase per ring so successive rings don't line their samples up.
            const theta = frac * std.math.tau + kf * golden_angle;
            const dest: dvui.Point = .{
                .x = want.x + @cos(theta) * ring * sx,
                .y = want.y + @sin(theta) * ring * sy,
            };
            if (!placed.overlaps(comps, c, dest)) return dest;
        }
    }
    return want;
}

fn translateComponent(c: *Component, pos: []dvui.Point, dest: dvui.Point) void {
    const dx = dest.x - c.cx;
    const dy = dest.y - c.cy;
    if (@abs(dx) < 1e-4 and @abs(dy) < 1e-4) return;
    for (c.members.items) |i| {
        pos[i].x += dx;
        pos[i].y += dy;
    }
    c.cx = dest.x;
    c.cy = dest.y;
}

/// Would `c` centred at `dest` collide with any component already on the board? The berth between
/// two islands is whichever of them wants *less* room: the wide cluster gap exists so two clusters
/// read as separate blobs, and charging it against a lone note as well would wall a cluster out of
/// any populated part of the board — which is what stopped clusters working their way inward.
/// Spatial hash over islands already parked on the board, so an overlap test looks at the
/// handful of islands that could actually be in the way instead of every one placed so far.
///
/// Parking is inherently incremental — each island is placed against everything before it — so
/// the linear `overlapsPlaced` made the pack O(components²), and `freeSpotNear`'s ring search
/// multiplies that by however many candidate spots it tries. On a vault with a few thousand
/// islands (lots of unlinked notes, which is the normal state of a real vault) that was the
/// single most expensive phase of a rebuild, well past the force solve.
///
/// Cell size is `2 * (max radius + max air)`, so two islands can only overlap if their centres
/// fall in the same or adjacent cells — a 3×3 lookup is exact, not a heuristic.
const PlacedIndex = struct {
    cell: f32,
    map: std.AutoHashMap([2]i32, std.ArrayList(usize)),
    allocator: std.mem.Allocator,

    /// Reach of the largest island that still goes in the grid; anything bigger is held in
    /// `big` and checked directly.
    small_reach: f32,
    big: std.ArrayList(usize),

    /// Sizing the cell off the *largest* island is what a first attempt does, and it does not
    /// work: a vault is typically thousands of single-note islands plus one giant connected
    /// component, and that one component's radius makes the cell big enough to swallow the
    /// entire board — every island lands in one bucket and the lookup is linear again.
    ///
    /// So the grid is sized for the common small island, and the handful of genuinely large
    /// ones are kept in a list that is short enough to scan. `small_reach` is a mid-range
    /// value rather than a true median: it only has to separate "one note" from "a cluster",
    /// and a full sort of every component to find the exact middle would cost more than it saves.
    fn init(allocator: std.mem.Allocator, comps: []const Component) PlacedIndex {
        var sum: f32 = 0;
        for (comps) |*c| sum += c.radius + c.air;
        const mean = if (comps.len > 0) sum / @as(f32, @floatFromInt(comps.len)) else 0;
        // Twice the mean keeps ordinary islands in the grid while still excluding the outliers
        // that a mean over a long tail is pulled up by.
        const small_reach = @max(mean * 2, 1e-3);
        return .{
            .cell = small_reach * 2,
            .small_reach = small_reach,
            .big = .empty,
            .map = std.AutoHashMap([2]i32, std.ArrayList(usize)).init(allocator),
            .allocator = allocator,
        };
    }

    fn deinit(self: *PlacedIndex) void {
        var it = self.map.valueIterator();
        while (it.next()) |list| list.deinit(self.allocator);
        self.map.deinit();
        self.big.deinit(self.allocator);
    }

    fn keyOf(self: PlacedIndex, p: dvui.Point) [2]i32 {
        return .{
            @intFromFloat(@floor(p.x / self.cell)),
            @intFromFloat(@floor(p.y / self.cell)),
        };
    }

    fn insert(self: *PlacedIndex, comps: []const Component, index: usize, at: dvui.Point) !void {
        if (comps[index].radius + comps[index].air > self.small_reach) {
            try self.big.append(self.allocator, index);
            return;
        }
        const gop = try self.map.getOrPut(self.keyOf(at));
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(self.allocator, index);
    }

    fn hits(comps: []const Component, oi: usize, c: *const Component, dest: dvui.Point) bool {
        const other = &comps[oi];
        if (other == c) return false;
        const ox = other.cx - dest.x;
        const oy = other.cy - dest.y;
        const need = other.radius + c.radius + @min(other.air, c.air);
        return ox * ox + oy * oy < need * need;
    }

    fn overlaps(self: PlacedIndex, comps: []const Component, c: *const Component, dest: dvui.Point) bool {
        for (self.big.items) |oi| if (hits(comps, oi, c, dest)) return true;

        // How many cells out a gridded island could still reach this query from. One for a
        // small island (the 3×3 block); more only when `c` itself is large, which is rare.
        const span = c.radius + c.air + self.small_reach;
        const r: i32 = @max(1, @as(i32, @intFromFloat(@ceil(span / self.cell))));

        const k = self.keyOf(dest);
        var dy: i32 = -r;
        while (dy <= r) : (dy += 1) {
            var dx: i32 = -r;
            while (dx <= r) : (dx += 1) {
                const bucket = self.map.get(.{ k[0] + dx, k[1] + dy }) orelse continue;
                for (bucket.items) |oi| if (hits(comps, oi, c, dest)) return true;
            }
        }
        return false;
    }
};

/// Round to the nearest *free* hex cell. Always succeeds — the lattice is infinite and we only
/// place `n` nodes.
///
/// `from` is the continuous position being snapped, and picking the closest cell on the ring to
/// it — rather than the first one a fixed-direction ring walk happens to hit — is what keeps a
/// tight group's arrangement through the snap. Contention is the normal case for a cluster: the
/// force pass settles linked notes well under one cell apart, so most of them can't have the cell
/// they want and get displaced. Displacing them all the same way collapses the group along that
/// direction, which is how three mutually-linked notes came out as three in a row with the middle
/// one sitting on top of the edge joining the other two. Sending each one out the way it was
/// already leaning keeps the angles the solve worked out.
fn findFreeCell(
    want: [2]i32,
    from: dvui.Point,
    spacing: f32,
    occupied: *std.AutoHashMap([2]i32, usize),
) [2]i32 {
    if (!occupied.contains(want)) return want;
    var k: i32 = 1;
    while (k < 10_000) : (k += 1) {
        // Standard hex-ring walk starting at dirs[4]*k.
        var q = want[0] + hex.dirs[4][0] * k;
        var r = want[1] + hex.dirs[4][1] * k;
        var best: ?[2]i32 = null;
        var best_d2: f32 = std.math.floatMax(f32);
        for (0..6) |side| {
            var step: i32 = 0;
            while (step < k) : (step += 1) {
                const c = [2]i32{ q, r };
                if (!occupied.contains(c)) {
                    const w = hex.toWorld(c[0], c[1], spacing);
                    const dx = w.x - from.x;
                    const dy = w.y - from.y;
                    const d2 = dx * dx + dy * dy;
                    // Strict, so an exact tie keeps the ring's own order and the choice stays
                    // deterministic across rebuilds.
                    if (d2 < best_d2) {
                        best_d2 = d2;
                        best = c;
                    }
                }
                q += hex.dirs[side][0];
                r += hex.dirs[side][1];
            }
        }
        if (best) |c| return c;
    }
    return want; // unreachable in practice
}

fn refine(
    n: usize,
    edges: []const Edge,
    cell: [][2]i32,
    out: []dvui.Point,
    occupied: *std.AutoHashMap([2]i32, usize),
    pinned: []const bool,
    slot: f32,
    cross_penalty: f32,
) !void {
    if (n < 2 or edges.len == 0) return;

    // `cost` is O(e²) and is evaluated once per candidate move — six neighbours per node, per
    // pass — so the real work here is `passes · n · 6 · e²`. Two independent caps on `n` and
    // `edges` do not bound that product: 300 nodes with 598 edges sits under both and still
    // costs about four billion operations (three seconds on a 300-note vault). Budget the
    // product instead, and skip the pass when it cannot be afforded — the snapped layout is
    // still link-aware, just not crossing-optimised.
    const e = edges.len;
    if (n * e * e > refine_budget) return;

    const occlude_r = slot * occlude_frac;
    var best_cost = cost(edges, out, cell, occupied, slot, cross_penalty, occlude_r);
    var pass: usize = 0;
    while (pass < uncross_passes) : (pass += 1) {
        var improved = false;

        // Try swapping every pair of hex-neighbours. Adjacent swaps keep the packing tight
        // while letting crossings resolve locally.
        for (0..n) |i| {
            // An anchored node isn't a candidate to move, and shortening a link by dragging one
            // off its home is the churn this whole pass is supposed to stay out of.
            if (pinned[i]) continue;
            for (hex.dirs) |d| {
                const nb = [2]i32{ cell[i][0] + d[0], cell[i][1] + d[1] };
                const j = occupied.get(nb) orelse {
                    // Empty neighbour: try moving i into it.
                    const saved = cell[i];
                    _ = occupied.remove(saved);
                    cell[i] = nb;
                    occupied.put(nb, i) catch {};
                    out[i] = hex.toWorld(nb[0], nb[1], slot);
                    const c = cost(edges, out, cell, occupied, slot, cross_penalty, occlude_r);
                    if (c + 1e-3 < best_cost) {
                        best_cost = c;
                        improved = true;
                    } else {
                        _ = occupied.remove(nb);
                        cell[i] = saved;
                        occupied.put(saved, i) catch {};
                        out[i] = hex.toWorld(saved[0], saved[1], slot);
                    }
                    continue;
                };
                if (j <= i) continue; // each pair once
                if (pinned[j]) continue;

                // Swap i and j.
                swapCells(i, j, cell, out, occupied, slot);
                const c = cost(edges, out, cell, occupied, slot, cross_penalty, occlude_r);
                if (c + 1e-3 < best_cost) {
                    best_cost = c;
                    improved = true;
                } else {
                    swapCells(i, j, cell, out, occupied, slot); // revert
                }
            }
        }
        if (!improved) break;
    }
}

fn swapCells(
    i: usize,
    j: usize,
    cell: [][2]i32,
    out: []dvui.Point,
    occupied: *std.AutoHashMap([2]i32, usize),
    slot: f32,
) void {
    const ci = cell[i];
    const cj = cell[j];
    cell[i] = cj;
    cell[j] = ci;
    out[i] = hex.toWorld(cj[0], cj[1], slot);
    out[j] = hex.toWorld(ci[0], ci[1], slot);
    occupied.put(cj, i) catch {};
    occupied.put(ci, j) catch {};
}

fn cost(
    edges: []const Edge,
    pos: []const dvui.Point,
    cell: []const [2]i32,
    occupied: *const std.AutoHashMap([2]i32, usize),
    spacing: f32,
    cross_penalty: f32,
    occlude_r: f32,
) f32 {
    var total: f32 = 0;
    for (edges) |e| {
        if (e.a >= pos.len or e.b >= pos.len) continue;
        const dx = pos[e.a].x - pos[e.b].x;
        const dy = pos[e.a].y - pos[e.b].y;
        total += @sqrt(dx * dx + dy * dy);
    }
    total += cross_penalty * @as(f32, @floatFromInt(countCrossings(edges, pos)));
    const hidden = countOccluded(edges, pos, cell, occupied, spacing, occlude_r);
    total += cross_penalty * occlude_weight * @as(f32, @floatFromInt(hidden));
    return total;
}

/// How many (edge, node) pairs have the node sitting on top of the edge — near the segment, and
/// between its ends rather than off one of them.
///
/// A link that runs under a third note is not a link anyone can see, so this is as much a tangle
/// as a crossing is, and total length alone has no opinion about it: three mutually-linked notes
/// in a row satisfy every spring while showing two of their three connections as one line.
///
/// Walks the lattice cells the link passes through rather than testing every node against every
/// edge. Nodes are *on* cells by this point, so the only ones that can be hiding a link are the
/// ones it runs over — a handful of hash lookups per edge, against a pass over the whole vault.
/// The straightforward version made a large solve ~70% dearer all on its own, which is not what a
/// tidying pass is worth.
fn countOccluded(
    edges: []const Edge,
    pos: []const dvui.Point,
    cell: []const [2]i32,
    occupied: *const std.AutoHashMap([2]i32, usize),
    spacing: f32,
    radius: f32,
) usize {
    if (!(radius > 0) or !(spacing > 0)) return 0;
    const r2 = radius * radius;
    var n: usize = 0;
    for (edges) |e| {
        if (e.a >= pos.len or e.b >= pos.len or e.a == e.b) continue;
        if (e.a >= cell.len or e.b >= cell.len) continue;
        // Neighbouring cells have nothing between them to hide behind.
        const steps = hex.axialDistance(cell[e.a], cell[e.b]);
        if (steps < 2 or steps > occlude_max_steps) continue;
        const a = pos[e.a];
        const b = pos[e.b];
        const vx = b.x - a.x;
        const vy = b.y - a.y;
        const len2 = vx * vx + vy * vy;
        if (len2 < 1e-6) continue;
        var prev: [2]i32 = cell[e.a];
        var step: i32 = 1;
        while (step < steps) : (step += 1) {
            const t = @as(f32, @floatFromInt(step)) / @as(f32, @floatFromInt(steps));
            const on: dvui.Point = .{ .x = a.x + vx * t, .y = a.y + vy * t };
            const c = hex.fromWorld(on, spacing);
            // Consecutive steps can round to the same cell — one node, counted once.
            if (c[0] == prev[0] and c[1] == prev[1]) continue;
            prev = c;
            const k = occupied.get(c) orelse continue;
            if (k == e.a or k == e.b or k >= pos.len) continue;
            // The walk only says which cell is nearest the line here; whether that node is
            // actually *on* the link is the same distance test either way.
            const q = pos[k];
            const tq = ((q.x - a.x) * vx + (q.y - a.y) * vy) / len2;
            if (tq <= 0.02 or tq >= 0.98) continue;
            const px = q.x - (a.x + vx * tq);
            const py = q.y - (a.y + vy * tq);
            if (px * px + py * py < r2) n += 1;
        }
    }
    return n;
}

fn countCrossings(edges: []const Edge, pos: []const dvui.Point) usize {
    var n: usize = 0;
    for (edges, 0..) |e1, i| {
        if (e1.a >= pos.len or e1.b >= pos.len) continue;
        for (edges[i + 1 ..]) |e2| {
            if (e2.a >= pos.len or e2.b >= pos.len) continue;
            // Share a vertex → adjacent edges, not a crossing.
            if (e1.a == e2.a or e1.a == e2.b or e1.b == e2.a or e1.b == e2.b) continue;
            if (segmentsCross(pos[e1.a], pos[e1.b], pos[e2.a], pos[e2.b])) n += 1;
        }
    }
    return n;
}

fn segmentsCross(a: dvui.Point, b: dvui.Point, c: dvui.Point, d: dvui.Point) bool {
    const d1 = orient(a, b, c);
    const d2 = orient(a, b, d);
    const d3 = orient(c, d, a);
    const d4 = orient(c, d, b);
    // Proper intersection: each segment straddles the other.
    return d1 * d2 < 0 and d3 * d4 < 0;
}

fn orient(a: dvui.Point, b: dvui.Point, c: dvui.Point) f32 {
    return (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x);
}

// -- tests ------------------------------------------------------------------------

const testing = std.testing;

test "slotSpacingFor matches hex.layoutSpacingFor" {
    for ([_]usize{ 1, 8, 24, 100 }) |n| {
        try testing.expectApproxEqAbs(hex.layoutSpacingFor(n), slotSpacingFor(n), 1e-3);
    }
}

test "larger vaults use a coarser or equal lattice" {
    try testing.expect(slotSpacingFor(100) >= slotSpacingFor(5));
    try testing.expect(slotSpacingFor(500) >= slotSpacingFor(100));
}

test "single node at origin" {
    var out: [1]dvui.Point = undefined;
    var seeds: [1]?dvui.Point = .{null};
    var deg: [1]u32 = .{0};
    try targets(testing.allocator, 1, &.{}, &seeds, &deg, .{}, &out);
    try testing.expectEqual(@as(f32, 0), out[0].x);
    try testing.expectEqual(@as(f32, 0), out[0].y);
}

test "every slot lands on the hex lattice and is unique" {
    const n = 24;
    const snap = snapSpacingFor(n);
    var out: [n]dvui.Point = undefined;
    var seeds: [n]?dvui.Point = .{null} ** n;
    var deg: [n]u32 = .{0} ** n;
    // A path so the force layout has something to pull on.
    var edges: [n - 1]Edge = undefined;
    for (0..n - 1) |i| edges[i] = .{ .a = i, .b = i + 1 };
    for (0..n) |i| deg[i] = if (i == 0 or i == n - 1) 1 else 2;

    try targets(testing.allocator, n, &edges, &seeds, &deg, .{}, &out);

    var seen = std.AutoHashMap([2]i32, void).init(testing.allocator);
    defer seen.deinit();
    for (out) |p| {
        try testing.expect(std.math.isFinite(p.x));
        try testing.expect(std.math.isFinite(p.y));
        const c = hex.fromWorld(p, snap);
        const back = hex.toWorld(c[0], c[1], snap);
        try testing.expectApproxEqAbs(back.x, p.x, 1e-3);
        try testing.expectApproxEqAbs(back.y, p.y, 1e-3);
        try testing.expect(seen.get(c) == null);
        try seen.put(c, {});
    }
}

test "linked nodes end up closer than unrelated ones" {
    // Two disjoint edges: (0-1) and (2-3). Each pair should be nearer within than across —
    // and meaningfully so: the snap lattice is half a packing slot, and springs are tuned so
    // a link settles near one snap cell while islands sit a packing slot apart.
    var out: [4]dvui.Point = undefined;
    var seeds: [4]?dvui.Point = .{null} ** 4;
    var deg: [4]u32 = .{ 1, 1, 1, 1 };
    const edges = [_]Edge{ .{ .a = 0, .b = 1 }, .{ .a = 2, .b = 3 } };
    try targets(testing.allocator, 4, &edges, &seeds, &deg, .{}, &out);

    const d01 = dist(out[0], out[1]);
    const d23 = dist(out[2], out[3]);
    const d02 = dist(out[0], out[2]);
    const d03 = dist(out[0], out[3]);
    const d12 = dist(out[1], out[2]);
    const d13 = dist(out[1], out[3]);
    const linked = (d01 + d23) * 0.5;
    const unlinked = (d02 + d03 + d12 + d13) * 0.25;
    try testing.expect(linked < unlinked * 0.85);
    try testing.expect(linked < snapSpacingFor(4) * 1.6);
}

test "survivors keep their cell when nothing changed" {
    const n = 8;
    const slot = slotSpacingFor(n);
    var out1: [n]dvui.Point = undefined;
    var seeds: [n]?dvui.Point = .{null} ** n;
    var deg: [n]u32 = .{0} ** n;
    var edges: [n - 1]Edge = undefined;
    for (0..n - 1) |i| {
        edges[i] = .{ .a = i, .b = i + 1 };
        deg[i] += 1;
        deg[i + 1] += 1;
    }
    try targets(testing.allocator, n, &edges, &seeds, &deg, .{}, &out1);

    var seeds2: [n]?dvui.Point = undefined;
    for (0..n) |i| seeds2[i] = out1[i];
    var out2: [n]dvui.Point = undefined;
    try targets(testing.allocator, n, &edges, &seeds2, &deg, .{ .prior_slot = slot }, &out2);

    // With identical topology and seeds already on-lattice, nodes may settle one cell over
    // (force+uncross is not bit-identical) but must not teleport across the web.
    for (0..n) |i| {
        try testing.expect(dist(out1[i], out2[i]) <= slot * 1.01 + 0.1);
    }
}

test "adding a link pulls the endpoints closer" {
    const n = 5;
    const slot = slotSpacingFor(n);
    var out1: [n]dvui.Point = undefined;
    var seeds: [n]?dvui.Point = .{null} ** n;
    var deg: [n]u32 = .{ 1, 2, 2, 2, 1 };
    const path = [_]Edge{
        .{ .a = 0, .b = 1 },
        .{ .a = 1, .b = 2 },
        .{ .a = 2, .b = 3 },
        .{ .a = 3, .b = 4 },
    };
    try targets(testing.allocator, n, &path, &seeds, &deg, .{}, &out1);
    const before = dist(out1[0], out1[4]);

    var seeds2: [n]?dvui.Point = undefined;
    for (0..n) |i| seeds2[i] = out1[i];
    const with_chord = [_]Edge{
        .{ .a = 0, .b = 1 },
        .{ .a = 1, .b = 2 },
        .{ .a = 2, .b = 3 },
        .{ .a = 3, .b = 4 },
        .{ .a = 0, .b = 4 },
    };
    var deg2: [n]u32 = .{ 2, 2, 2, 2, 2 };
    var out2: [n]dvui.Point = undefined;
    try targets(testing.allocator, n, &with_chord, &seeds2, &deg2, .{ .prior_slot = slot }, &out2);
    const after = dist(out2[0], out2[4]);
    try testing.expect(after <= before + slot * 0.5);
}

test "anchoring everything makes a reindex a no-op" {
    // The common case by far: something in the vault changed that the graph doesn't draw — a
    // title, a body edit with no links in it — and the answer has to be that nothing moves at
    // all, not that everything moves a little.
    const n = 10;
    const slot = slotSpacingFor(n);
    var out1: [n]dvui.Point = undefined;
    var seeds: [n]?dvui.Point = .{null} ** n;
    var deg: [n]u32 = .{0} ** n;
    var edges: [6]Edge = undefined;
    for (0..6) |i| {
        edges[i] = .{ .a = i, .b = i + 1 };
        deg[i] += 1;
        deg[i + 1] += 1;
    }
    try targets(testing.allocator, n, &edges, &seeds, &deg, .{}, &out1);

    var seeds2: [n]?dvui.Point = undefined;
    for (0..n) |i| seeds2[i] = out1[i];
    const all_anchored: [n]bool = .{true} ** n;
    var out2: [n]dvui.Point = undefined;
    try targets(testing.allocator, n, &edges, &seeds2, &deg, .{ .anchored = &all_anchored, .prior_slot = slot }, &out2);

    for (0..n) |i| {
        try testing.expectEqual(out1[i].x, out2[i].x);
        try testing.expectEqual(out1[i].y, out2[i].y);
    }
}

test "a new link moves its endpoints and leaves the rest of the vault alone" {
    // Two separate chains. Linking one node of the first to one node of the second is a real
    // structural change for those two, and no reason whatsoever for the other six to budge.
    const n = 8;
    const slot = slotSpacingFor(n);
    var deg: [n]u32 = .{ 1, 2, 2, 1, 1, 2, 2, 1 };
    const before = [_]Edge{
        .{ .a = 0, .b = 1 },
        .{ .a = 1, .b = 2 },
        .{ .a = 2, .b = 3 },
        .{ .a = 4, .b = 5 },
        .{ .a = 5, .b = 6 },
        .{ .a = 6, .b = 7 },
    };
    var seeds: [n]?dvui.Point = .{null} ** n;
    var out1: [n]dvui.Point = undefined;
    try targets(testing.allocator, n, &before, &seeds, &deg, .{}, &out1);
    const gap_before = dist(out1[3], out1[4]);

    var seeds2: [n]?dvui.Point = undefined;
    for (0..n) |i| seeds2[i] = out1[i];
    const after = before ++ [_]Edge{.{ .a = 3, .b = 4 }};
    var deg2: [n]u32 = .{ 1, 2, 2, 2, 2, 2, 2, 1 };
    // Only the two endpoints of the new link have a changed neighbour set.
    var anchored: [n]bool = .{true} ** n;
    anchored[3] = false;
    anchored[4] = false;
    var out2: [n]dvui.Point = undefined;
    try targets(testing.allocator, n, &after, &seeds2, &deg2, .{ .anchored = &anchored, .prior_slot = slot }, &out2);

    for (0..n) |i| {
        if (i == 3 or i == 4) continue;
        try testing.expectEqual(out1[i].x, out2[i].x);
        try testing.expectEqual(out1[i].y, out2[i].y);
    }
    // The new link still had an effect — but only as far as two nodes can carry it. Closing the
    // gap completely would mean towing both chains toward each other, i.e. moving six nodes that
    // gained nothing, which is the whole thing anchoring exists to prevent. The islands migrate
    // as more cross-links appear and unanchor more of their members.
    try testing.expect(dist(out2[3], out2[4]) < gap_before);
}

test "restoring a node's pre-change cell honours it exactly" {
    // The contract `graph.zig` leans on to undo an edit: hand back the position the node held one
    // change ago, anchored, and the layout must reproduce it to the cell even though the node's
    // links just changed. Two chains; node 3 is linked across to node 4 and then unlinked, with
    // the restore standing in for what `rebuildIfNeeded` does from its one-step history.
    const n = 8;
    const slot = slotSpacingFor(n);
    var deg: [n]u32 = .{ 1, 2, 2, 1, 1, 2, 2, 1 };
    const plain = [_]Edge{
        .{ .a = 0, .b = 1 },
        .{ .a = 1, .b = 2 },
        .{ .a = 2, .b = 3 },
        .{ .a = 4, .b = 5 },
        .{ .a = 5, .b = 6 },
        .{ .a = 6, .b = 7 },
    };
    var seeds: [n]?dvui.Point = .{null} ** n;
    var start: [n]dvui.Point = undefined;
    try targets(testing.allocator, n, &plain, &seeds, &deg, .{}, &start);

    // Link 3—4: only those two are mobile.
    const linked = plain ++ [_]Edge{.{ .a = 3, .b = 4 }};
    var deg_linked: [n]u32 = .{ 1, 2, 2, 2, 2, 2, 2, 1 };
    var anchored: [n]bool = .{true} ** n;
    anchored[3] = false;
    anchored[4] = false;
    var seeds_linked: [n]?dvui.Point = undefined;
    for (0..n) |i| seeds_linked[i] = start[i];
    var mid: [n]dvui.Point = undefined;
    try targets(testing.allocator, n, &linked, &seeds_linked, &deg_linked, .{ .anchored = &anchored, .prior_slot = slot }, &mid);

    // Unlink it again. 3 and 4 are seeded with the cells they held *before* the link and anchored,
    // rather than with where the link left them.
    var seeds_back: [n]?dvui.Point = undefined;
    for (0..n) |i| seeds_back[i] = mid[i];
    seeds_back[3] = start[3];
    seeds_back[4] = start[4];
    var all_anchored: [n]bool = .{true} ** n;
    var back: [n]dvui.Point = undefined;
    try targets(testing.allocator, n, &plain, &seeds_back, &deg, .{ .anchored = &all_anchored, .prior_slot = slot }, &back);

    for (0..n) |i| {
        try testing.expectEqual(start[i].x, back[i].x);
        try testing.expectEqual(start[i].y, back[i].y);
    }
}

test "a node that loses its only link stays put instead of being flung out" {
    // With no neighbours left there is nothing to derive a position from, and the spiral
    // fallback would hand out a cell based on how many other nodes needed one this pass. Its own
    // last position is the only stable answer.
    const n = 5;
    const slot = slotSpacingFor(n);
    var deg: [n]u32 = .{ 1, 2, 2, 2, 1 };
    const chain = [_]Edge{
        .{ .a = 0, .b = 1 },
        .{ .a = 1, .b = 2 },
        .{ .a = 2, .b = 3 },
        .{ .a = 3, .b = 4 },
    };
    var seeds: [n]?dvui.Point = .{null} ** n;
    var out1: [n]dvui.Point = undefined;
    try targets(testing.allocator, n, &chain, &seeds, &deg, .{}, &out1);

    // Drop 4's only link, leaving it isolated.
    const cut = chain[0..3];
    var deg2: [n]u32 = .{ 1, 2, 2, 1, 0 };
    var anchored: [n]bool = .{true} ** n;
    anchored[3] = false;
    anchored[4] = false;
    var seeds2: [n]?dvui.Point = undefined;
    for (0..n) |i| seeds2[i] = out1[i];
    var out2: [n]dvui.Point = undefined;
    try targets(testing.allocator, n, cut, &seeds2, &deg2, .{ .anchored = &anchored, .prior_slot = slot }, &out2);

    try testing.expectEqual(out1[4].x, out2[4].x);
    try testing.expectEqual(out1[4].y, out2[4].y);
}

test "an anchored node yields its cell to nobody" {
    // Anchored nodes claim before the degree-ordered pass, so a mobile hub landing on the same
    // cell is the one that gets moved along. Without that ordering, "held in place" would be a
    // suggestion rather than a guarantee.
    const n = 4;
    const slot = slotSpacingFor(n);
    var deg: [n]u32 = .{ 3, 1, 1, 1 };
    const edges = [_]Edge{
        .{ .a = 0, .b = 1 },
        .{ .a = 0, .b = 2 },
        .{ .a = 0, .b = 3 },
    };
    var seeds: [n]?dvui.Point = .{null} ** n;
    var out1: [n]dvui.Point = undefined;
    try targets(testing.allocator, n, &edges, &seeds, &deg, .{}, &out1);

    // Aim the high-degree hub straight at an anchored leaf's cell.
    var seeds2: [n]?dvui.Point = undefined;
    for (0..n) |i| seeds2[i] = out1[i];
    seeds2[0] = out1[1];
    var anchored: [n]bool = .{true} ** n;
    anchored[0] = false;
    var out2: [n]dvui.Point = undefined;
    try targets(testing.allocator, n, &edges, &seeds2, &deg, .{ .anchored = &anchored, .prior_slot = slot }, &out2);

    try testing.expectEqual(out1[1].x, out2[1].x);
    try testing.expectEqual(out1[1].y, out2[1].y);
    // Distinct cells: the hub had to settle elsewhere. Nearest-neighbour on the snap lattice
    // is exactly one snap step, so the floor is just under that rather than half a packing slot
    // (which *is* one snap step, and `>` against it falsely failed once snap went finer).
    try testing.expect(dist(out2[0], out2[1]) > snapSpacingFor(n) * 0.5);
}

fn dist(a: dvui.Point, b: dvui.Point) f32 {
    const dx = a.x - b.x;
    const dy = a.y - b.y;
    return @sqrt(dx * dx + dy * dy);
}

test "a vault of mostly-unlinked notes packs densely" {
    // The shape of a real project: one small cluster and a lot of loose notes. Those loose notes
    // used to each add their own diameter plus a full cluster's berth to a running orbit, so the
    // radius grew linearly and this vault sprawled over ~70 slots of mostly empty grid — which is
    // what forced fit-to-extents to pull back until nothing was readable. Packing by area holds it
    // near the lattice minimum instead.
    const n = 33;
    const slot = slotSpacingFor(n);
    var deg: [n]u32 = .{0} ** n;
    deg[0] = 1;
    deg[1] = 2;
    deg[2] = 1;
    const edges = [_]Edge{ .{ .a = 0, .b = 1 }, .{ .a = 1, .b = 2 } };
    var seeds: [n]?dvui.Point = .{null} ** n;
    var out: [n]dvui.Point = undefined;
    try targets(testing.allocator, n, &edges, &seeds, &deg, .{}, &out);

    var r: f32 = 0;
    for (out) |p| r = @max(r, @sqrt(p.x * p.x + p.y * p.y));
    // `packRadius` is the radius a plain spiral of `n` cells reaches, so it stands in for "as tight
    // as this lattice gets". Some slack for the cluster's air and the greedy search.
    try testing.expect(r < packRadius(n) * 2.4);
    try testing.expect(r < slot * 7);
}

test "packing follows the panel's proportions" {
    // A disc fits a wide short panel badly: the fit is height-limited and most of the width goes to
    // margin. Packing to the panel's shape spends that width on zoom instead.
    const n = 40;
    var deg: [n]u32 = .{0} ** n;
    var no_edges: [0]Edge = .{};
    var seeds: [n]?dvui.Point = .{null} ** n;

    var round: [n]dvui.Point = undefined;
    try targets(testing.allocator, n, &no_edges, &seeds, &deg, .{}, &round);
    var wide: [n]dvui.Point = undefined;
    try targets(testing.allocator, n, &no_edges, &seeds, &deg, .{ .aspect = 2.25 }, &wide);

    const round_ar = spanAspect(&round);
    const wide_ar = spanAspect(&wide);
    try testing.expect(wide_ar > round_ar);
    // A disc comes out near 1:1 and this lands around 2.0 for a requested 2.25 — the shortfall is
    // collision resolution, which can only ever give ground. A floor well above 1:1 so that losing
    // the stretch fails here rather than quietly reverting to margin.
    try testing.expect(wide_ar > 1.7);

    // Area-preserving: a stretched cloud is a different shape, not a sparser one.
    try testing.expect(spanArea(&wide) < spanArea(&round) * 1.35);
}

test "a reshape repacks a cloud that is already laid out" {
    // The case the panel actually hits: the cloud exists, the panel changed proportions, so the
    // caller re-solves with every seed carried and *nothing* anchored. Loose notes used to pin
    // themselves to their old seed here, which both froze them and tripped `any_fixed` in
    // `packComponents` — so `aspect` was thrown away and a resize reshaped nothing.
    const n = 40;
    var deg: [n]u32 = .{0} ** n;
    var no_edges: [0]Edge = .{};
    var no_seeds: [n]?dvui.Point = .{null} ** n;

    var round: [n]dvui.Point = undefined;
    try targets(testing.allocator, n, &no_edges, &no_seeds, &deg, .{}, &round);

    // Now reshape *that* arrangement, exactly as `rebuildIfNeeded` does on a bucket change.
    var seeds: [n]?dvui.Point = undefined;
    for (round, 0..) |p, i| seeds[i] = p;
    const anchored: [n]bool = .{false} ** n;
    var wide: [n]dvui.Point = undefined;
    try targets(testing.allocator, n, &no_edges, &seeds, &deg, .{
        .anchored = &anchored,
        .aspect = 2.25,
    }, &wide);

    try testing.expect(spanAspect(&wide) > spanAspect(&round));
    try testing.expect(spanAspect(&wide) > 1.7);
}

test "the whole range a panel can ask for produces distinct shapes" {
    // The graph lives in a bottom panel, which is wider than it is tall for most of its height
    // range. When `aspect_limit` sat below that range, every ratio up there clamped to the same
    // number and gave a byte-identical layout — so dragging the panel reshaped nothing at all, and
    // the shaping looked broken when it was only saturated.
    const n = 40;
    var deg: [n]u32 = .{0} ** n;
    var no_edges: [0]Edge = .{};
    var seeds: [n]?dvui.Point = .{null} ** n;

    const ratios = [_]f32{ 1.0, 2.0, 3.0, 4.0 };
    var spans: [ratios.len]f32 = undefined;
    for (ratios, 0..) |asp, i| {
        var out: [n]dvui.Point = undefined;
        try targets(testing.allocator, n, &no_edges, &seeds, &deg, .{ .aspect = asp }, &out);
        spans[i] = spanAspect(&out);
    }
    // Strictly wider each step. Equality here is the saturation bug.
    for (1..ratios.len) |i| try testing.expect(spans[i] > spans[i - 1] * 1.05);
}

test "a cluster keeps its own shape through a reshape" {
    // The bug this guards: shaping the cloud by stretching node coordinates reshapes every cluster
    // along with it, so three mutually-linked notes come out collinear — a triangle drawn as a flat
    // line with its nodes sitting on top of their own connecting edges. Proportions belong to where
    // islands are *placed*, never to the coordinates inside one.
    const n = 24;
    var deg: [n]u32 = .{0} ** n;
    // A triangle, and 21 loose notes for the packer to spread around it.
    const edges = [_]Edge{ .{ .a = 0, .b = 1 }, .{ .a = 1, .b = 2 }, .{ .a = 2, .b = 0 } };
    for (0..3) |i| deg[i] = 2;
    var seeds: [n]?dvui.Point = .{null} ** n;

    var square: [n]dvui.Point = undefined;
    try targets(testing.allocator, n, &edges, &seeds, &deg, .{ .aspect = 1 }, &square);

    // Reshape hard, the way dragging a bottom panel wide does.
    var carried: [n]?dvui.Point = undefined;
    for (square, 0..) |q, i| carried[i] = q;
    const anchored: [n]bool = .{false} ** n;
    var wide: [n]dvui.Point = undefined;
    try targets(testing.allocator, n, &edges, &carried, &deg, .{
        .anchored = &anchored,
        .aspect = 4,
        .reshape_only = true,
    }, &wide);

    // The cloud did reshape...
    try testing.expect(spanAspect(&wide) > spanAspect(&square) * 1.3);

    // ...but the triangle is still a triangle. Twice the area of the triangle on those three
    // points; a collinear "triangle" has area zero.
    const area = @abs((wide[1].x - wide[0].x) * (wide[2].y - wide[0].y) -
        (wide[1].y - wide[0].y) * (wide[2].x - wide[0].x));
    const was = @abs((square[1].x - square[0].x) * (square[2].y - square[0].y) -
        (square[1].y - square[0].y) * (square[2].x - square[0].x));
    try testing.expect(was > 0);
    try testing.expect(area > was * 0.7);

    // And its sides are the same lengths — the island was carried, not redrawn.
    for ([_][2]usize{ .{ 0, 1 }, .{ 1, 2 }, .{ 2, 0 } }) |e| {
        const a = @sqrt((square[e[0]].x - square[e[1]].x) * (square[e[0]].x - square[e[1]].x) +
            (square[e[0]].y - square[e[1]].y) * (square[e[0]].y - square[e[1]].y));
        const b = @sqrt((wide[e[0]].x - wide[e[1]].x) * (wide[e[0]].x - wide[e[1]].x) +
            (wide[e[0]].y - wide[e[1]].y) * (wide[e[0]].y - wide[e[1]].y));
        try testing.expectApproxEqAbs(a, b, slotSpacingFor(n) * 0.5);
    }
}

test "one dominant cluster does not pin the cloud's shape" {
    // The failure this pins, and it hid for a long time because the cloud *was* responding — just
    // to the square root of what was asked. With one component big enough to set the height on its
    // own, an area-preserving stretch only widened the island ring by √a, so a 3.5:1 panel gave a
    // ~1.9:1 cloud and pulling the panel wider did almost nothing visible.
    const n = 90;
    var deg: [n]u32 = .{0} ** n;
    var el: [44]Edge = undefined;
    // Half the vault in one cluster, half loose — the loose ones are what carry the shape.
    for (1..45) |i| {
        const parent = (i - 1) / 2;
        el[i - 1] = .{ .a = parent, .b = i };
        deg[parent] += 1;
        deg[i] += 1;
    }
    var seeds: [n]?dvui.Point = .{null} ** n;

    var prev: f32 = 0;
    for ([_]f32{ 1.0, 2.0, 3.5, 5.0, 8.0 }) |asp| {
        var out: [n]dvui.Point = undefined;
        try targets(testing.allocator, n, &el, &seeds, &deg, .{ .aspect = asp }, &out);
        const span = spanAspect(&out);
        // Within a quarter of what was asked, in log terms — not merely "wider than last time",
        // which √a also satisfies and which is what let this through before.
        try testing.expect(span > asp * 0.75);
        try testing.expect(span < asp * 1.35);
        try testing.expect(span > prev);
        prev = span;
    }
}

test "an incremental rebuild still holds link-less notes still" {
    // The flip side of the reshape fix: when the caller *is* anchoring, a note with no links has
    // nothing to solve for it and must not be carried off by the packer.
    const n = 12;
    var deg: [n]u32 = .{0} ** n;
    deg[0] = 1;
    deg[1] = 1;
    const edges = [_]Edge{.{ .a = 0, .b = 1 }};
    var no_seeds: [n]?dvui.Point = .{null} ** n;
    var base: [n]dvui.Point = undefined;
    try targets(testing.allocator, n, &edges, &no_seeds, &deg, .{}, &base);

    var seeds: [n]?dvui.Point = undefined;
    for (base, 0..) |p, i| seeds[i] = p;
    // Everything anchored except one loose note, which carries a seed but no say-so of its own.
    var anchored: [n]bool = .{true} ** n;
    anchored[n - 1] = false;
    var out: [n]dvui.Point = undefined;
    try targets(testing.allocator, n, &edges, &seeds, &deg, .{ .anchored = &anchored }, &out);

    try testing.expectApproxEqAbs(base[n - 1].x, out[n - 1].x, 0.001);
    try testing.expectApproxEqAbs(base[n - 1].y, out[n - 1].y, 0.001);
}

test "a settle reshape parks islands into new proportions without reshaping clusters" {
    // What the panel does after the pane settles: skip the force pass, re-park every island into
    // a fresh ellipse for the new aspect. Clusters stay rigid (triangle side lengths hold);
    // loners carry the wide/tall outline.
    const n = 24;
    var deg: [n]u32 = .{0} ** n;
    const edges = [_]Edge{ .{ .a = 0, .b = 1 }, .{ .a = 1, .b = 2 }, .{ .a = 2, .b = 0 } };
    for (0..3) |i| deg[i] = 2;
    var no_seeds: [n]?dvui.Point = .{null} ** n;
    var square: [n]dvui.Point = undefined;
    try targets(testing.allocator, n, &edges, &no_seeds, &deg, .{ .aspect = 1 }, &square);

    var seeds: [n]?dvui.Point = undefined;
    for (0..n) |i| seeds[i] = square[i];
    const free: [n]bool = .{false} ** n;
    var wide: [n]dvui.Point = undefined;
    try targets(testing.allocator, n, &edges, &seeds, &deg, .{
        .anchored = &free,
        .aspect = 4,
        .reshape_only = true,
        .prior_slot = slotSpacingFor(n),
    }, &wide);

    const area = @abs((wide[1].x - wide[0].x) * (wide[2].y - wide[0].y) -
        (wide[1].y - wide[0].y) * (wide[2].x - wide[0].x));
    const was = @abs((square[1].x - square[0].x) * (square[2].y - square[0].y) -
        (square[1].y - square[0].y) * (square[2].x - square[0].x));
    try testing.expect(was > 0);
    try testing.expect(area > was * 0.7);
    for ([_][2]usize{ .{ 0, 1 }, .{ 1, 2 }, .{ 2, 0 } }) |e| {
        try testing.expectApproxEqAbs(dist(square[e[0]], square[e[1]]), dist(wide[e[0]], wide[e[1]]), snapSpacingFor(n) * 0.55);
    }
    try testing.expect(spanAspect(&wide) > spanAspect(&square) * 1.4);
    try testing.expect(spanAspect(&wide) > 2.5);

    // Tall panel: span must go below 1, not leave empty vertical margin under a wide cloud.
    for (0..n) |i| seeds[i] = wide[i];
    var tall: [n]dvui.Point = undefined;
    try targets(testing.allocator, n, &edges, &seeds, &deg, .{
        .anchored = &free,
        .aspect = 0.4,
        .reshape_only = true,
        .prior_slot = slotSpacingFor(n),
    }, &tall);
    try testing.expect(spanAspect(&tall) < 0.7);
    try testing.expect(spanAspect(&tall) < spanAspect(&wide) * 0.35);
}

test "a settle reshape into the same aspect is idempotent" {
    // Two packs at the same aspect with the same seeds must agree. Otherwise a settle that
    // fires twice (or a chattering end-of-drag) hands the ease two homes to thrash between.
    const n = 20;
    var deg: [n]u32 = .{0} ** n;
    var no_edges: [0]Edge = .{};
    var no_seeds: [n]?dvui.Point = .{null} ** n;
    var base: [n]dvui.Point = undefined;
    try targets(testing.allocator, n, &no_edges, &no_seeds, &deg, .{ .aspect = 1.5 }, &base);

    var seeds: [n]?dvui.Point = undefined;
    for (0..n) |i| seeds[i] = base[i];
    const free: [n]bool = .{false} ** n;
    var a: [n]dvui.Point = undefined;
    var b: [n]dvui.Point = undefined;
    try targets(testing.allocator, n, &no_edges, &seeds, &deg, .{
        .anchored = &free,
        .aspect = 3.0,
        .reshape_only = true,
        .prior_slot = slotSpacingFor(n),
    }, &a);
    for (0..n) |i| seeds[i] = a[i];
    try targets(testing.allocator, n, &no_edges, &seeds, &deg, .{
        .anchored = &free,
        .aspect = 3.0,
        .reshape_only = true,
        .prior_slot = slotSpacingFor(n),
    }, &b);
    for (0..n) |i| {
        try testing.expectApproxEqAbs(a[i].x, b[i].x, 0.001);
        try testing.expectApproxEqAbs(a[i].y, b[i].y, 0.001);
    }
}

test "a single connected component still takes the pane aspect on reshape" {
    // One island: the packer has nothing to rearrange, so the settle path stretches the envelope
    // to the pane and re-relaxes springs. Without that, a fully-linked vault could never become
    // wide or tall — only zoom with the camera.
    const n = 12;
    var deg: [n]u32 = .{0} ** n;
    var edges: [n - 1]Edge = undefined;
    for (0..n - 1) |i| {
        edges[i] = .{ .a = i, .b = i + 1 };
        deg[i] += 1;
        deg[i + 1] += 1;
    }
    var no_seeds: [n]?dvui.Point = .{null} ** n;
    var base: [n]dvui.Point = undefined;
    try targets(testing.allocator, n, &edges, &no_seeds, &deg, .{ .aspect = 1 }, &base);

    var seeds: [n]?dvui.Point = undefined;
    for (0..n) |i| seeds[i] = base[i];
    const free: [n]bool = .{false} ** n;
    var wide: [n]dvui.Point = undefined;
    try targets(testing.allocator, n, &edges, &seeds, &deg, .{
        .anchored = &free,
        .aspect = 4,
        .reshape_only = true,
        .prior_slot = slotSpacingFor(n),
    }, &wide);
    try testing.expect(spanAspect(&wide) > spanAspect(&base) * 1.5);
    try testing.expect(spanAspect(&wide) > 2.0);
}

fn spanAspect(pts: []const dvui.Point) f32 {
    var min_x: f32 = std.math.floatMax(f32);
    var min_y: f32 = std.math.floatMax(f32);
    var max_x: f32 = -std.math.floatMax(f32);
    var max_y: f32 = -std.math.floatMax(f32);
    for (pts) |p| {
        min_x = @min(min_x, p.x);
        min_y = @min(min_y, p.y);
        max_x = @max(max_x, p.x);
        max_y = @max(max_y, p.y);
    }
    return (max_x - min_x) / @max(max_y - min_y, 1);
}

fn spanArea(pts: []const dvui.Point) f32 {
    var min_x: f32 = std.math.floatMax(f32);
    var min_y: f32 = std.math.floatMax(f32);
    var max_x: f32 = -std.math.floatMax(f32);
    var max_y: f32 = -std.math.floatMax(f32);
    for (pts) |p| {
        min_x = @min(min_x, p.x);
        min_y = @min(min_y, p.y);
        max_x = @max(max_x, p.x);
        max_y = @max(max_y, p.y);
    }
    return (max_x - min_x) * (max_y - min_y);
}

test "same-folder notes huddle closer than cross-folder peers" {
    // Three notes in `proj/` and three in `other/`, no wikilinks. Folder kinship alone should
    // pull each cohort together — without it they scatter like any other loners.
    const n = 6;
    var deg: [n]u32 = .{0} ** n;
    var no_edges: [0]Edge = .{};
    const paths = [_][]const u8{
        "proj/a.md", "proj/b.md", "proj/c.md",
        "other/x.md", "other/y.md", "other/z.md",
    };
    var seeds: [n]?dvui.Point = .{null} ** n;
    var out: [n]dvui.Point = undefined;
    try targets(testing.allocator, n, &no_edges, &seeds, &deg, .{ .paths = &paths }, &out);

    var within: f32 = 0;
    var within_n: f32 = 0;
    for ([_][2]usize{ .{ 0, 1 }, .{ 0, 2 }, .{ 1, 2 }, .{ 3, 4 }, .{ 3, 5 }, .{ 4, 5 } }) |e| {
        within += dist(out[e[0]], out[e[1]]);
        within_n += 1;
    }
    var across: f32 = 0;
    var across_n: f32 = 0;
    for (0..3) |i| {
        for (3..6) |j| {
            across += dist(out[i], out[j]);
            across_n += 1;
        }
    }
    try testing.expect((within / within_n) < (across / across_n) * 0.92);
}

test "folderKinship ranks same-dir above parent-child above strangers" {
    try testing.expect(folderKinship("a/x.md", "a/y.md") > folderKinship("a/x.md", "a/b/y.md"));
    try testing.expect(folderKinship("a/x.md", "a/b/y.md") > folderKinship("a/x.md", "z/y.md"));
    try testing.expectApproxEqAbs(@as(f32, 1.0), folderKinship("dir/n.md", "dir/m.md"), 1e-4);
    try testing.expect(folderKinship("a/x.md", "z/y.md") < 0.05);
}

test "a linked pair sits tighter than neighbouring loners" {
    // The reading this protects: connected notes should form a denser cloud than the ambient
    // spacing of unlinked ones. Same packing slot for everyone used to put both at one lattice
    // step, which is why clusters never looked tighter than the loners around them.
    const n = 18;
    var deg: [n]u32 = .{0} ** n;
    const edges = [_]Edge{ .{ .a = 0, .b = 1 }, .{ .a = 1, .b = 2 }, .{ .a = 2, .b = 0 } };
    for (0..3) |i| deg[i] = 2;
    var seeds: [n]?dvui.Point = .{null} ** n;
    var out: [n]dvui.Point = undefined;
    try targets(testing.allocator, n, &edges, &seeds, &deg, .{}, &out);

    const linked = (dist(out[0], out[1]) + dist(out[1], out[2]) + dist(out[2], out[0])) / 3;
    // Nearest-neighbour among the loners (indices 3..).
    var lone_nn: f32 = std.math.floatMax(f32);
    for (3..n) |i| {
        for (i + 1..n) |j| {
            lone_nn = @min(lone_nn, dist(out[i], out[j]));
        }
    }
    try testing.expect(linked < lone_nn * 0.85);
    try testing.expect(linked < snapSpacingFor(n) * 1.5);
}

test "a cluster sits nearer the middle than the loose notes do" {
    // Clusters in, singles out — the reading the user gets from the shape of the board.
    const n = 24;
    var deg: [n]u32 = .{0} ** n;
    for (0..6) |i| deg[i] = 2;
    const edges = [_]Edge{
        .{ .a = 0, .b = 1 },
        .{ .a = 1, .b = 2 },
        .{ .a = 2, .b = 3 },
        .{ .a = 3, .b = 4 },
        .{ .a = 4, .b = 5 },
        .{ .a = 5, .b = 0 },
    };
    var seeds: [n]?dvui.Point = .{null} ** n;
    var out: [n]dvui.Point = undefined;
    try targets(testing.allocator, n, &edges, &seeds, &deg, .{}, &out);

    var cluster_max: f32 = 0;
    for (out[0..6]) |p| cluster_max = @max(cluster_max, @sqrt(p.x * p.x + p.y * p.y));
    var lone_max: f32 = 0;
    for (out[6..]) |p| lone_max = @max(lone_max, @sqrt(p.x * p.x + p.y * p.y));
    try testing.expect(cluster_max < lone_max);
}

test "a newly linked pair is parked near itself, not out past the vault" {
    // Two loose notes on opposite sides of a settled vault link up. They become one free island
    // among anchored ones, and the free island used to be parked beyond the outermost thing on the
    // board — so two notes finding each other threw them both to the rim.
    const n = 20;
    const slot = slotSpacingFor(n);
    var deg: [n]u32 = .{0} ** n;
    var no_edges: [0]Edge = .{};
    var seeds: [n]?dvui.Point = .{null} ** n;
    var out1: [n]dvui.Point = undefined;
    try targets(testing.allocator, n, &no_edges, &seeds, &deg, .{}, &out1);

    var far: f32 = 0;
    for (out1) |p| far = @max(far, @sqrt(p.x * p.x + p.y * p.y));

    // Link 4—5, anchor everyone else.
    const linked = [_]Edge{.{ .a = 4, .b = 5 }};
    var deg2: [n]u32 = .{0} ** n;
    deg2[4] = 1;
    deg2[5] = 1;
    var anchored: [n]bool = .{true} ** n;
    anchored[4] = false;
    anchored[5] = false;
    var seeds2: [n]?dvui.Point = undefined;
    for (0..n) |i| seeds2[i] = out1[i];
    var out2: [n]dvui.Point = undefined;
    try targets(testing.allocator, n, &linked, &seeds2, &deg2, .{ .anchored = &anchored, .prior_slot = slot }, &out2);

    // Neither endpoint may end up outside the vault it belongs to.
    for ([2]usize{ 4, 5 }) |i| {
        const d = @sqrt(out2[i].x * out2[i].x + out2[i].y * out2[i].y);
        try testing.expect(d <= far + slot);
    }
    // And being a cluster now, the pair should be no further out than the loose notes' rim.
    const mid_x = (out2[4].x + out2[5].x) * 0.5;
    const mid_y = (out2[4].y + out2[5].y) * 0.5;
    try testing.expect(@sqrt(mid_x * mid_x + mid_y * mid_y) <= far);
}


test "a triangle inside a cluster does not snap into a straight line" {
    // The report this pins: three notes linking to one another, drawn as three in a row with the
    // middle one sitting on the edge joining the other two — every connection hidden. The force
    // pass was never the problem; it settles the three well under a cell apart, and *that* is what
    // makes them contend for cells at snap time. Displacing every contender the same fixed
    // direction is what lined them up. See `findFreeCell`.
    const n = 12;
    var deg: [n]u32 = .{0} ** n;
    var edges: std.ArrayList(Edge) = .empty;
    defer edges.deinit(testing.allocator);
    try edges.appendSlice(testing.allocator, &.{
        .{ .a = 0, .b = 1 }, .{ .a = 1, .b = 2 }, .{ .a = 2, .b = 0 },
    });
    // Everyone else links to two of the three, so the triangle sits inside a crowd that is
    // pulling on it from every side — the case a bare triangle never reproduces.
    for (3..n) |k| {
        try edges.append(testing.allocator, .{ .a = k, .b = k % 3 });
        try edges.append(testing.allocator, .{ .a = k, .b = (k + 1) % 3 });
    }
    for (edges.items) |e| {
        deg[e.a] += 1;
        deg[e.b] += 1;
    }

    var seeds: [n]?dvui.Point = .{null} ** n;
    var out: [n]dvui.Point = undefined;
    try targets(testing.allocator, n, edges.items, &seeds, &deg, .{ .aspect = 2 }, &out);

    // Twice the triangle's area; zero means collinear, which is what this used to be exactly.
    const area2 = @abs((out[1].x - out[0].x) * (out[2].y - out[0].y) -
        (out[1].y - out[0].y) * (out[2].x - out[0].x));
    const snap = snapSpacingFor(n);
    // A hex triangle one cell on a side has area2 = √3/2 · snap². Anything at least that big is
    // unambiguously a triangle on screen rather than a line with a kink in it.
    try testing.expect(area2 > @sqrt(3.0) / 2.0 * snap * snap);
}

test "countOccluded sees a node sitting on a link, and only then" {
    const spacing: f32 = 100;
    var occupied = std.AutoHashMap([2]i32, usize).init(testing.allocator);
    defer occupied.deinit();

    // Three cells in a row: 0 — 1 — 2, with the link running 0→2 straight through 1.
    const cells = [_][2]i32{ .{ 0, 0 }, .{ 1, 0 }, .{ 2, 0 }, .{ 0, 2 } };
    var pos: [4]dvui.Point = undefined;
    for (cells, 0..) |c, i| {
        pos[i] = hex.toWorld(c[0], c[1], spacing);
        try occupied.put(c, i);
    }

    const through = [_]Edge{.{ .a = 0, .b = 2 }};
    try testing.expectEqual(
        @as(usize, 1),
        countOccluded(&through, &pos, &cells, &occupied, spacing, spacing * occlude_frac),
    );

    // Same two endpoints, nothing between them: adjacent cells can't hide anything.
    const adjacent = [_]Edge{.{ .a = 0, .b = 1 }};
    try testing.expectEqual(
        @as(usize, 0),
        countOccluded(&adjacent, &pos, &cells, &occupied, spacing, spacing * occlude_frac),
    );

    // A node off to the side of the link is not hiding it, however close it is to an end.
    const clear = [_]Edge{.{ .a = 0, .b = 3 }};
    try testing.expectEqual(
        @as(usize, 0),
        countOccluded(&clear, &pos, &cells, &occupied, spacing, spacing * occlude_frac),
    );
}






test "a group's links stay near the tightest the lattice allows" {
    // Bounds on how long a group's own connections come out, measured in snap cells. They are
    // here because "groups have long connection lines" is easy to see and hard to argue about
    // without numbers, and because two plausible fixes for it both made these worse:
    //
    //   * matching members to cells instead of claiming them one at a time, to kill the
    //     displacement cascade in the snap;
    //   * weakening repulsion between members of the same island, so a hub's own leaves stop
    //     pushing it apart.
    //
    // Neither is in the code, and this test is what says so. A hub cannot have more than six
    // notes one cell away from it, so for a group built around a few hubs some long links are
    // the lattice, not a bug — the mean below is already close to the mean radius of a hex disc
    // holding that many cells. Chains and rings, which have no such constraint, come out tight
    // and stay that way.
    const gpa = testing.allocator;
    const n = 60;

    // A chain of triangles: nothing forces a long link, so nothing should be long.
    {
        var deg: [n]u32 = .{0} ** n;
        var edges: std.ArrayList(Edge) = .empty;
        defer edges.deinit(gpa);
        var k: usize = 0;
        while (k + 2 < 24) : (k += 3) {
            try edges.append(gpa, .{ .a = k, .b = k + 1 });
            try edges.append(gpa, .{ .a = k + 1, .b = k + 2 });
            try edges.append(gpa, .{ .a = k + 2, .b = k });
            if (k + 3 < 24) try edges.append(gpa, .{ .a = k + 2, .b = k + 3 });
        }
        for (edges.items) |e| {
            deg[e.a] += 1;
            deg[e.b] += 1;
        }
        var seeds: [n]?dvui.Point = .{null} ** n;
        var out: [n]dvui.Point = undefined;
        try targets(gpa, n, edges.items, &seeds, &deg, .{ .aspect = 1.6 }, &out);

        const snap = snapSpacingFor(n);
        var sum: f32 = 0;
        var worst: f32 = 0;
        for (edges.items) |e| {
            const d = dist(out[e.a], out[e.b]) / snap;
            sum += d;
            worst = @max(worst, d);
        }
        const mean = sum / @as(f32, @floatFromInt(edges.items.len));
        try testing.expect(mean < 1.35);
        try testing.expect(worst < 2.6);
    }

    // A hub with twenty-three spokes. Six can touch it; the rest are on rings further out, and
    // that is geometry rather than slack — so this only guards against the mean drifting well
    // past what a disc of that many cells measures (~1.7 cells).
    {
        var deg: [n]u32 = .{0} ** n;
        var edges: std.ArrayList(Edge) = .empty;
        defer edges.deinit(gpa);
        for (1..24) |k| try edges.append(gpa, .{ .a = 0, .b = k });
        for (1..24) |k| if (k + 2 < 24) try edges.append(gpa, .{ .a = k, .b = k + 2 });
        for (edges.items) |e| {
            deg[e.a] += 1;
            deg[e.b] += 1;
        }
        var seeds: [n]?dvui.Point = .{null} ** n;
        var out: [n]dvui.Point = undefined;
        try targets(gpa, n, edges.items, &seeds, &deg, .{ .aspect = 1.6 }, &out);

        const snap = snapSpacingFor(n);
        var sum: f32 = 0;
        for (edges.items) |e| sum += dist(out[e.a], out[e.b]) / snap;
        try testing.expect(sum / @as(f32, @floatFromInt(edges.items.len)) < 2.4);
    }
}

test "a reshape leaves the vault on the lattice" {
    // What a resize used to do, and why a resized graph stopped looking uniform: the reshape
    // path handed back the continuous positions directly, so it was the one path that skipped
    // the snap. Every node in the vault came off the grid the first time the panel was dragged
    // and stayed off it for the rest of the session.
    //
    // On the lattice every angle inside a group is a multiple of 60° and every link is a lattice
    // distance, so groups across the whole graph share a handful of shapes — that shared
    // vocabulary is what reads as uniform. Off it, each group keeps whatever the envelope
    // stretch and the relax left it with, and the stretch is non-uniform by construction: it is
    // squeezing one axis to make the cloud match the pane. Groups end up sheared toward the axis
    // that was stretched.
    const gpa = testing.allocator;
    const n = 30;
    var deg: [n]u32 = .{0} ** n;
    var edges: std.ArrayList(Edge) = .empty;
    defer edges.deinit(gpa);
    for ([_]usize{ 0, 5, 10 }) |b| {
        try edges.append(gpa, .{ .a = b, .b = b + 1 });
        try edges.append(gpa, .{ .a = b + 1, .b = b + 2 });
        try edges.append(gpa, .{ .a = b + 2, .b = b });
    }
    // Wired into one component, which is the case that reaches `enforceAspectEnvelope` — the
    // packer has nothing to arrange, so the stretch is the only thing left to carry the aspect.
    for (15..n) |k| try edges.append(gpa, .{ .a = k, .b = k % 15 });
    try edges.append(gpa, .{ .a = 0, .b = 5 });
    try edges.append(gpa, .{ .a = 5, .b = 10 });
    for (edges.items) |e| {
        deg[e.a] += 1;
        deg[e.b] += 1;
    }

    var seeds: [n]?dvui.Point = .{null} ** n;
    var cur: [n]dvui.Point = undefined;
    try targets(gpa, n, edges.items, &seeds, &deg, .{ .aspect = 3.0 }, &cur);

    const snap = snapSpacingFor(n);
    var carried: [n]?dvui.Point = undefined;
    const free: [n]bool = .{false} ** n;
    // Drag the pane from wide through square to tall, carrying each result into the next the way
    // the panel does.
    for ([_]f32{ 1.6, 1.0, 0.6 }) |a| {
        for (cur, 0..) |q, i| carried[i] = q;
        try targets(gpa, n, edges.items, &carried, &deg, .{
            .aspect = a,
            .reshape_only = true,
            .anchored = &free,
            .prior_slot = slotSpacingFor(n),
        }, &cur);

        for (cur) |q| {
            const c = hex.fromWorld(q, snap);
            try testing.expectApproxEqAbs(0, dist(q, hex.toWorld(c[0], c[1], snap)), snap * 0.06);
        }
        // And the reshape still does its job — the cloud takes the proportions it was asked
        // for. Loose on purpose: 1.35 is the very ratio `mismatch` treats as close enough to
        // leave alone, so landing near it is the algorithm working, and the snap moves each node
        // up to half a cell afterwards. This is here to catch a reshape that stopped reshaping,
        // not to pin the last few percent.
        try testing.expect(@max(spanAspect(&cur) / a, a / spanAspect(&cur)) < 1.45);
    }
}

test "files added to a hub one at a time do not end up behind each other" {
    // The reported shape: create several notes that all link to one document, one file at a
    // time. Only six cells touch a hub, so the seventh note to link to it sits on the second
    // ring — and if it lands on a cell in line with a first-ring note, the link to it is drawn
    // straight through that note.
    //
    // What made this stick was anchoring, not geometry. Each new file changes the links of two
    // notes, so every earlier spoke stayed pinned and neither the solve nor the uncross pass
    // could shuffle them aside. Freeing the immediate neighbours of what changed is what gives
    // them the room; the second ring has cells *between* the first-ring notes as well as behind
    // them, and those are both shorter and clear.
    const gpa = testing.allocator;
    const n = 24;
    var deg: [n]u32 = .{0} ** n;
    var edges: std.ArrayList(Edge) = .empty;
    defer edges.deinit(gpa);
    try edges.append(gpa, .{ .a = 20, .b = 21 });
    for (edges.items) |e| {
        deg[e.a] += 1;
        deg[e.b] += 1;
    }
    var seeds: [n]?dvui.Point = .{null} ** n;
    var cur: [n]dvui.Point = undefined;
    try targets(gpa, n, edges.items, &seeds, &deg, .{ .aspect = 2.2 }, &cur);

    var carried: [n]?dvui.Point = undefined;
    for (1..10) |k| {
        try edges.append(gpa, .{ .a = 0, .b = k });
        deg[0] += 1;
        deg[k] += 1;

        // The anchoring `graph.zig` hands over: the two endpoints of the new link, plus the
        // immediate neighbours of both.
        var anchored: [n]bool = .{true} ** n;
        anchored[0] = false;
        anchored[k] = false;
        for (edges.items) |e| {
            if (e.a == 0 or e.a == k) anchored[e.b] = false;
            if (e.b == 0 or e.b == k) anchored[e.a] = false;
        }

        for (cur, 0..) |q, i| carried[i] = q;
        try targets(gpa, n, edges.items, &carried, &deg, .{
            .aspect = 2.2,
            .anchored = &anchored,
            .prior_slot = slotSpacingFor(n),
        }, &cur);

        const snap = snapSpacingFor(n);
        for (edges.items) |e| {
            for (cur, 0..) |q, i| {
                if (i == e.a or i == e.b) continue;
                const a = cur[e.a];
                const vx = cur[e.b].x - a.x;
                const vy = cur[e.b].y - a.y;
                const len2 = vx * vx + vy * vy;
                if (len2 < 1e-6) continue;
                const t = ((q.x - a.x) * vx + (q.y - a.y) * vy) / len2;
                if (t <= 0.02 or t >= 0.98) continue;
                const px = q.x - (a.x + vx * t);
                const py = q.y - (a.y + vy * t);
                try testing.expect(@sqrt(px * px + py * py) >= snap * occlude_frac);
            }
        }
    }
}

test "a rebuild that holds almost nothing repacks globally instead" {
    // A vault being read in: a few hundred notes already placed, thousands arriving at once. The
    // handful still anchored is not a frame worth positioning the rest against, so the solve is
    // expected to ignore them and produce the same arrangement it would from scratch — which is
    // what stops the graph churning into a different shape on every commit during a read.
    const gpa = testing.allocator;
    const n = 400;
    var edges: std.ArrayList(Edge) = .empty;
    defer edges.deinit(gpa);
    var deg = try gpa.alloc(u32, n);
    defer gpa.free(deg);
    @memset(deg, 0);
    // Ring plus chords, so there is real structure to be stable about.
    for (0..n) |i| {
        try edges.append(gpa, .{ .a = i, .b = (i + 1) % n });
        if (i % 7 == 0) try edges.append(gpa, .{ .a = i, .b = (i + 53) % n });
    }
    for (edges.items) |e| {
        deg[e.a] += 1;
        deg[e.b] += 1;
    }

    const seeds = try gpa.alloc(?dvui.Point, n);
    defer gpa.free(seeds);
    for (seeds, 0..) |*s, i| {
        const f: f32 = @floatFromInt(i);
        s.* = .{ .x = @sin(f) * 300, .y = @cos(f) * 300 };
    }

    const free = try gpa.alloc(dvui.Point, n);
    defer gpa.free(free);
    try targets(gpa, n, edges.items, seeds, deg, .{}, free);

    // Ten held out of four hundred is far under `hold_min_pct`.
    const anchored = try gpa.alloc(bool, n);
    defer gpa.free(anchored);
    @memset(anchored, false);
    for (0..10) |i| anchored[i] = true;

    const sparse = try gpa.alloc(dvui.Point, n);
    defer gpa.free(sparse);
    try targets(gpa, n, edges.items, seeds, deg, .{ .anchored = anchored }, sparse);

    for (free, sparse) |a, b| {
        try testing.expectApproxEqAbs(a.x, b.x, 0.001);
        try testing.expectApproxEqAbs(a.y, b.y, 0.001);
    }

    // Held above the threshold, anchoring still means what it always did. Seeded from the
    // settled arrangement above, since holding a node only means anything if where it is being
    // held is somewhere it could legitimately sit.
    const settled = try gpa.alloc(?dvui.Point, n);
    defer gpa.free(settled);
    for (settled, free) |*s, q| s.* = q;

    @memset(anchored, true);
    for (0..40) |i| anchored[i] = false;
    const incremental = try gpa.alloc(dvui.Point, n);
    defer gpa.free(incremental);
    try targets(gpa, n, edges.items, settled, deg, .{
        .anchored = anchored,
        .prior_slot = slotSpacingFor(n),
    }, incremental);
    for (40..n) |i| {
        try testing.expectApproxEqAbs(free[i].x, incremental[i].x, 0.001);
        try testing.expectApproxEqAbs(free[i].y, incremental[i].y, 0.001);
    }
}
