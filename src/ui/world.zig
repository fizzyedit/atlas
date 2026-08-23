//! The living set: which cells are on screen this frame, where they are, and how big.
//!
//! This is the third and last piece of the containment path — `fold.zig` decides the hierarchy,
//! `containment.zig` decides where a cell's children sit inside it, and this file decides which
//! cells are *open* right now and turns them into screen-space marks. Together they replace
//! `quadlod.zig` + `quad_agents.zig` + `lod.zig` + `multilevel.zig` + most of `layout_full.zig`.
//!
//! The contract:
//!
//! > Given (tree, view, zoom, budget), the set of living cells is determined. Motion only
//! > interpolates how those cells appear.
//!
//! A parked camera therefore means the open set stops changing. That is the reliability bar and
//! there is a test for it.
//!
//! Six rules are load-bearing. Four are inherited; two were found by rebuilding this from scratch
//! in a prototype and paying for them again, so they are written down here in code:
//!
//! 1. **Cull inside select, not at draw.** Children are placed inside their parent's disc, so an
//!    off-screen cell's whole subtree is off-screen and the test is exact. Without this the
//!    candidate list fills with the entire vault, the budget check never passes, and the dive
//!    stalls partway showing nothing but coalesced rings.
//! 2. **Decide a level by a count threshold, never by visit order.** Opening biggest-first until
//!    the budget runs out leaves identical neighbours resolved differently depending on the walk —
//!    a visible seam. But opening a whole level or none of it wastes most of the budget, since
//!    level sizes go 1, arity, arity²…: the gauntlet drew 57 marks against a budget of 280.
//!    Thresholding on *count* gets both — equal-count cells always agree, and the budget fills.
//! 3. **Never force an open cell closed at the budget wall.** Closing frees budget, which allows
//!    reopening, which exceeds it again. The wall refuses only *new* opens.
//! 4. **A note is a fixed screen size.** Only masses are count-and-zoom scaled, and soft-capped so
//!    a cell the budget refused cannot inflate to fill the screen.
//! 5. Radius is the area-conserving law `√count`, anchored on the note size.
//! 6. Split and merge crossfade through `anim`; topology itself stays discrete.
//!
//! Screen-space out, no dvui in: marks are plain numbers so this stays headless-testable.

const std = @import("std");
pub const fold = @import("fold.zig");
const containment = @import("containment.zig");
const cellweb = @import("cellweb.zig");

pub const Mark = struct {
    cell: u32,
    /// Animated world position. The caller applies its own camera transform, so there is exactly
    /// one place that knows how world maps to screen.
    wx: f32,
    wy: f32,
    /// Screen position (viewport-relative, origin top-left) and radius in pixels.
    x: f32,
    y: f32,
    r: f32,
    alpha: f32,
    /// A real note (draw filled) rather than a coalesced mass (draw dashed).
    is_note: bool,
    /// Valid iff `is_note`.
    note: u32,
};

/// A link between two *living* cells, already lifted from the note pair that produced it.
pub const LiftedLink = struct {
    a: u32,
    b: u32,
    w: f32,
    /// This pair carries one of the *focused note's own* links.
    ///
    /// Not "is incident to the cell the focused note happens to be inside": when that note is
    /// coalesced, its cell is a mass aggregating hundreds of unrelated notes, and highlighting
    /// everything the mass touches paints a starburst that has almost nothing to do with the open
    /// document. The focused note's links are its leaf-level neighbours, which stay knowable at any
    /// zoom — so they are resolved from the leaf and then lifted onto whatever cells currently
    /// stand in for their endpoints.
    focus: bool = false,
    /// At least one endpoint is a note drawn as *itself* rather than inside a mass, which makes
    /// this link exempt from the budget — see the `keep` calculation in `liftLinks`.
    essential: bool = false,
    /// 0..1 crossfade. Links enter and leave the lifted set as the cut changes under a pan, and
    /// without this they blink. Driven by the same rate as the mark crossfade.
    alpha: f32 = 1,
};

/// One of the focused note's own links, at **leaf** precision: both ends are the actual notes,
/// not whatever cells currently stand in for them.
///
/// A separate list from `lifted` because the two answer different questions. The ambient web is a
/// picture of the vault's shape, so aggregating it onto the cut is the whole point — and a pair
/// that lifts onto a single cell is correctly dropped, since a line from a cell to itself says
/// nothing. The focused note's links are a picture of *one document*, and the reader is following
/// them: they must survive whatever the cut does, including both ends landing in the same cell.
///
/// That is exactly what goes wrong at distance. The further the camera stands from the focused
/// note, the shallower the level at which its branch fails the cull, so the cell standing in for it
/// grows — and its neighbours, which are close to it in the hierarchy precisely because they are
/// linked to it, get swallowed by that same cell one after another. Lifted, the note's links quietly
/// vanish as you travel away from it, which is the one moment you are most likely to be tracing one.
pub const FocusLink = struct {
    /// Leaf cells. Both are `ensurePlaced`, so `field.pos` is valid for each.
    a: u32,
    b: u32,
    /// 0..1 reach-out progress, per link and *not* per selection.
    ///
    /// This used to be one scalar on the panel shared by every drawn link, which meant any change
    /// of focus replayed the animation for all of them — including links that were already fully
    /// extended and had nothing to travel. Keyed per link (see `World.focus_grow`), a connection
    /// that survives a focus change keeps the progress it had earned, and only genuinely new ones
    /// start from zero and reach out.
    grow: f32 = 0,
};

/// Centre-to-centre distance between two ring-adjacent leaves, in units of `note_r`.
///
/// A cell of `arity` leaves has radius `√arity · note_r`; its ring sits at
/// `√arity · fill − note_r` and adjacent ring slots are one step apart, whose chord at arity 7 is
/// the ring radius itself. A caller that needs notes a specific world distance apart — to match
/// an existing lattice, say — divides that pitch by this.
pub const leaf_pitch: f32 = 1.381;

/// Liang–Barsky clip of the segment `(ax,ay)-(bx,by)` against the rect `(rx,ry,rw,rh)`.
/// Null when the segment misses the rect entirely.
///
/// Lives here rather than in `world_draw` for one reason: this file is headless, so the math can
/// be tested, and a clipper is all corner cases — parallel-and-outside, both-ends-outside-crossing,
/// both-ends-outside-same-side, degenerate. `world_draw` wraps it in dvui point types.
pub fn clipSegment(
    ax: f32,
    ay: f32,
    bx: f32,
    by: f32,
    rx: f32,
    ry: f32,
    rw: f32,
    rh: f32,
) ?[4]f32 {
    const dx = bx - ax;
    const dy = by - ay;
    // Degenerate input, rejected before the clip rather than by it: with `dx == dy == 0` every
    // Liang–Barsky clause is the parallel case, so a zero-length segment *inside* the rect
    // survives as a zero-length segment — which a line batch cannot take a direction from.
    if (dx == 0 and dy == 0) return null;

    var t0: f32 = 0;
    var t1: f32 = 1;

    const pk = [_]f32{ -dx, dx, -dy, dy };
    const qk = [_]f32{ ax - rx, (rx + rw) - ax, ay - ry, (ry + rh) - ay };

    for (pk, qk) |pv, qv| {
        if (pv == 0) {
            // Parallel to this edge: being outside it means the whole segment is outside.
            if (qv < 0) return null;
            continue;
        }
        const t = qv / pv;
        if (pv < 0) {
            if (t > t1) return null;
            if (t > t0) t0 = t;
        } else {
            if (t < t0) return null;
            if (t < t1) t1 = t;
        }
    }
    if (t1 <= t0) return null;
    return .{ ax + dx * t0, ay + dy * t0, ax + dx * t1, ay + dy * t1 };
}

/// Bench-only per-phase counters for `liftLinks`.
///
/// The `--world --pan` sweep is the only caller that sets `prof_io`; with it null every helper
/// below compiles down to a null test, so the panel pays nothing. It lives at module scope rather
/// than on `World` because the sweep wants totals across frames, not a per-frame snapshot.
pub const Prof = struct {
    calls: u64 = 0,
    recomputes: u64 = 0,
    /// Crossfade bookkeeping, paid on *every* call including the cached one.
    fade_ns: u64 = 0,
    /// Leaf-precision links of the focused and open notes.
    focus_ns: u64 = 0,
    /// The per-cut-cell neighbour scan that produces `lifted`.
    scan_ns: u64 = 0,
    /// Materialising `lifted` out of `acc`.
    build_ns: u64 = 0,
    /// The budget sort, when `lifted` is over `keep`.
    sort_ns: u64 = 0,
};
pub var prof: Prof = .{};
pub var prof_io: ?std.Io = null;

fn pnow() i96 {
    const io = prof_io orelse return 0;
    return std.Io.Clock.boot.now(io).nanoseconds;
}

fn plap(mark: *i96) u64 {
    if (prof_io == null) return 0;
    const n = pnow();
    defer mark.* = n;
    return @intCast(n - mark.*);
}

pub const View = struct {
    w: f32,
    h: f32,
    zoom: f32,
    /// World point at the centre of the screen.
    cx: f32,
    cy: f32,
};

pub const Params = struct {
    /// Marks the frame may draw. Dying cells may briefly exceed it while they fade.
    budget: usize = 280,
    /// A cell opens once its on-screen radius passes this.
    split_px: f32 = 30,
    /// Rule 4: notes never scale with zoom.
    note_r_px: f32 = 8.5,
    /// Soft ceiling on a mass's drawn radius.
    mass_cap_px: f32 = 46,
    /// Crossfade rate per second for open/close.
    rate: f32 = 7,
    /// Reach-out time for the focused note's *shortest* links, in seconds. Separate from `rate`
    /// because a link travelling to its neighbour is a much slower, more deliberate motion than a
    /// crossfade.
    focus_reach_secs: f32 = 0.42,
    /// World length at which a link takes `focus_reach_secs` exactly. Shorter links still take that
    /// long — below this the travel is too short to read as motion at all — and longer ones take
    /// proportionally more, up to `focus_reach_max`.
    ///
    /// Without this the reach is a *fraction* of each link's own length per second, so every link
    /// finishes together whatever its size: a link across half the vault covers a hundred times the
    /// distance of a neighbourly one in the same 0.83 s, and reads as instant precisely because it
    /// is the one you most wanted to follow.
    focus_reach_ref: f32 = 60,
    /// Ceiling on that stretch. A Wikipedia-scale vault has links spanning most of its extent, and
    /// pacing those at a constant speed would take tens of seconds; the cap keeps the longest reach
    /// deliberate rather than interminable.
    focus_reach_max: f32 = 2.5,

    /// Pad the cull test so a cell just off-screen still animates rather than popping in.
    cull_pad_px: f32 = 48,
    /// Neighbours of one cut cell that `liftLinks` will look at, heaviest first.
    ///
    /// A cut cell's aggregated degree is usually tiny, but a hub cell high in the ladder can be
    /// adjacent to a large fraction of its level. This is what keeps the lift bounded by the budget
    /// rather than by the vault's worst-connected cell: `budget × link_scan_cap` pair lookups, hard
    /// ceiling. Truncation is by ascending weight, and the result is capped at `link_budget`
    /// heaviest anyway, so what it drops is what the budget was going to drop.
    link_scan_cap: usize = 256,
    /// Reuse the cached lift even when the cut has changed.
    ///
    /// The lifted set is recomputed whenever the cut changes — which, during a zoom or a camera
    /// flight, is *every frame*, so the cache that makes a parked camera free does nothing exactly
    /// when the frame budget is tightest. Holding it for a few frames while the camera moves trades
    /// a web that lags the marks slightly (covered by the crossfade, and invisible at speed) for
    /// several times less work per frame. The caller is responsible for letting go periodically so
    /// the web cannot drift arbitrarily far, and for dropping it the moment the camera settles.
    lift_hold: bool = false,
    /// Leaves of every *open* note, the focused one included.
    ///
    /// All of them get their links drawn at leaf precision, not just the focused one. They used to
    /// be split across two mechanisms — the focused note through `focus_links`, every other open
    /// tab through the draw's lifted `endpointLit` branch — and the two disagree about what a
    /// note's links *are*: one is the note's actual neighbours, the other is whatever cell pairs
    /// the lift produced, pointing at the masses currently standing in for them. So a note showed
    /// one set of connections while focused and a different set the moment you clicked elsewhere,
    /// and opening a note painted the lifted set for a frame before the leaf-precision set replaced
    /// it — connections that appeared at full length, vanished, and then reached out.
    ///
    /// One mechanism, so there is nothing to hand over and nothing to disagree.
    open_leaves: []const u32 = &.{},
    /// Leaf cell of the note the reader is looking at, or `fold.invalid`.
    ///
    /// Its links are exempt from both halves of the link budget — the per-cell scan depth and the
    /// global truncation — because "show me what this note connects to" is the one question the
    /// panel exists to answer, and answering it approximately is worse than not answering it. The
    /// exemption is bounded: one cell, so the extra scan is `O(degree)` once per frame.
    focus_leaf: u32 = fold.invalid,
    /// How many *highlighted* lines the frame may draw, across every open note.
    ///
    /// Spent focused-note-first. The flat `link_scan_cap` per note was the wrong shape twice over:
    /// it truncated the one note the reader is actually asking about at 256 however much room the
    /// frame had, while placing no limit at all on the total, since every open tab got its own 256.
    /// A budget spent in priority order says what is actually meant — the selected note draws as
    /// much of its web as the frame can afford, and everything else fills what is left.
    ///
    /// A cap is still needed: the vault's worst hub has 29,448 neighbours, and a starburst of that
    /// many highlighted lines is neither legible nor cheap. Sized from the same quality slider the
    /// ambient budget uses, so "more detail" means more of both.
    focus_link_budget: usize = 900,

    /// Links the frame may draw, kept by descending weight.
    ///
    /// Marks and links need separate budgets: n living cells admit up to n(n-1)/2 lifted pairs,
    /// so a dense vault reaches ~25,000 lines behind only 280 marks. That is a hairball, not a
    /// web — it costs draw time and shows nothing, since every cell appears joined to every
    /// other. Keeping the heaviest links keeps the structure that carries information.
    link_budget: usize = 900,

    /// The ambient link budget that goes with a given mark budget.
    ///
    /// Lives here, on `Params`, rather than in the panel, because the `--world` bench builds its
    /// own `Params` and a bench that quietly measures different parameters than the thing it
    /// stands in for is worse than no bench. The panel's `graph.ambientLinkBudget` and the sweep's
    /// default both come through here, so they cannot drift.
    ///
    /// `5/2` reproduces the previous flat 900 at the `graph_detail` default of 360. See
    /// `graph.ambientLinkBudget` for why scaling with the mark budget is defensible now when it
    /// was not before: a note drawn as itself is exempt from this budget entirely, so it governs
    /// only the mass-to-mass aggregate web.
    pub fn ambientLinkBudget(mark_budget: usize) usize {
        return @max(200, mark_budget * 5 / 2);
    }
};

/// Ordering for the ambient link budget: focus first, then a note's own links, then weight.
///
/// A strict total order — the `(a, b)` tie-break is the pair identity, so no two distinct links
/// ever compare equal. `selectTopK` depends on that: with ties possible, which of several equal
/// links survived truncation would depend on partition order, and a parked camera would not keep
/// the same web.
fn heavier(x: LiftedLink, y: LiftedLink) bool {
    if (x.focus != y.focus) return x.focus;
    if (x.essential != y.essential) return x.essential;
    if (x.w != y.w) return x.w > y.w;
    // deterministic tie-break, so a parked camera keeps the same web
    if (x.a != y.a) return x.a < y.a;
    return x.b < y.b;
}

/// Partition `items` so that `items[0..k]` holds the `k` that `heavier` ranks first.
///
/// Introselect: quickselect with a median-of-three pivot, falling back to a full sort of the
/// remaining range if the pivots keep going badly, so the worst case is `n log n` rather than
/// `n²`. Order *within* the kept prefix is unspecified — the caller wants a set, and the drawn
/// ambient web is one colour whose per-line alpha is 1 at rest, so compositing it is
/// order-invariant there. (The branch that keeps everything never sorted at all, so the draw has
/// always taken this list in hash order at most zooms.)
fn selectTopK(items: []LiftedLink, k: usize) void {
    if (k == 0 or k >= items.len) return;
    var lo: usize = 0;
    var hi: usize = items.len; // exclusive
    var budget: usize = 2 * std.math.log2_int_ceil(usize, items.len + 1) + 4;
    while (hi - lo > 16) {
        if (budget == 0) {
            std.mem.sort(LiftedLink, items[lo..hi], {}, struct {
                fn less(_: void, x: LiftedLink, y: LiftedLink) bool {
                    return heavier(x, y);
                }
            }.less);
            return;
        }
        budget -= 1;
        const pivot_at = partitionLinks(items, lo, hi);
        // Everything before `pivot_at` outranks everything after it, so exactly one side can still
        // contain the k'th element; the other is already on its correct side of the cut.
        if (k <= pivot_at) hi = pivot_at else lo = pivot_at + 1;
    }
    std.sort.insertion(LiftedLink, items[lo..hi], {}, struct {
        fn less(_: void, x: LiftedLink, y: LiftedLink) bool {
            return heavier(x, y);
        }
    }.less);
}

/// Lomuto partition of `items[lo..hi]` around a median-of-three pivot. Returns the pivot's final
/// index; everything before it is heavier, everything after it lighter.
fn partitionLinks(items: []LiftedLink, lo: usize, hi: usize) usize {
    const last = hi - 1;
    const mid = lo + (hi - lo) / 2;
    if (heavier(items[mid], items[lo])) std.mem.swap(LiftedLink, &items[mid], &items[lo]);
    if (heavier(items[last], items[lo])) std.mem.swap(LiftedLink, &items[last], &items[lo]);
    if (heavier(items[last], items[mid])) std.mem.swap(LiftedLink, &items[last], &items[mid]);
    // `items[mid]` is now the median of the three; park it at the end as the pivot.
    std.mem.swap(LiftedLink, &items[mid], &items[last]);
    const pivot = items[last];

    var i = lo;
    var j = lo;
    while (j < last) : (j += 1) {
        if (heavier(items[j], pivot)) {
            std.mem.swap(LiftedLink, &items[i], &items[j]);
            i += 1;
        }
    }
    std.mem.swap(LiftedLink, &items[i], &items[last]);
    return i;
}

pub const World = struct {
    gpa: std.mem.Allocator,
    lad: fold.Ladder,
    field: containment.Field,

    /// Per cell: 0 = closed, 1 = fully open. The only state that survives a frame.
    anim: []f32,
    /// Per cell: animated world pose, which is the parent's pose lerped toward the cell's own.
    px: []f32,
    py: []f32,
    /// Per cell: accumulated parent openness, so a subtree fades as one.
    mul: []f32,
    /// Per cell: the *topological* decision for this frame — recomputed from scratch every step
    /// and never read by the decision that produces it. `anim` chases this.
    open: []bool,

    /// Link weight aggregated onto cells at every level, built once per rebuild. The frame's web
    /// is read out of this and the cut; no note-level edge is touched. See `cellweb.zig`.
    web: cellweb.CellWeb,

    marks: std.ArrayListUnmanaged(Mark) = .empty,
    links: std.ArrayListUnmanaged(LiftedLink) = .empty,
    /// The cells the cut settled on this frame — closed, or culled off-screen at whatever level
    /// they were culled. This *is* the drawn set's topology, and `liftLinks` reads nothing else.
    /// It replaces a per-note `owner` array whose every frame cost an `O(notes)` fill.
    cut: std.ArrayListUnmanaged(u32) = .empty,
    /// Per-cell memo for `cutOf`, valid only while `cut_stamp[i] == cut_epoch`. The stamp exists
    /// so a new frame costs nothing to invalidate — no 341k-entry memset.
    cut_of: []u32,
    cut_stamp: []u32,
    cut_epoch: u32 = 0,
    /// Scratch for the lift and the crossfades, kept across frames rather than rebuilt inside it.
    ///
    /// Every one of these used to be `.empty` on entry and freed on exit, so a pan frame — which
    /// misses the lift cache 119 times out of 120 — grew a 17k–29k-entry table up from nothing and
    /// rehashed the whole way, then threw it away, sixty times a second. `clearRetainingCapacity`
    /// pays that growth once for the life of the `World`. Nothing here is state: every field is
    /// cleared before use, and the only thing that survives a frame is the allocation.
    sc_acc: std.AutoHashMapUnmanaged(u64, f32) = .empty,
    sc_focus_pairs: std.AutoHashMapUnmanaged(u64, void) = .empty,
    sc_edge_seen: std.AutoHashMapUnmanaged(u64, void) = .empty,
    sc_live: std.AutoHashMapUnmanaged(u64, void) = .empty,
    sc_dead: std.ArrayListUnmanaged(u64) = .empty,
    sc_grow_live: std.AutoHashMapUnmanaged(u64, void) = .empty,
    sc_grow_dead: std.ArrayListUnmanaged(u64) = .empty,

    /// One cut cell's per-neighbour-cell weight totals, dense and epoch-stamped instead of hashed.
    ///
    /// The inner loop of the lift is "for each of this cell's neighbours, add its weight to
    /// whichever cut cell owns it", which is a scatter-add over cell ids — exactly what an array
    /// indexed by cell id does without hashing anything. The stamp is the same trick `cut_of` uses:
    /// a new accumulation costs an epoch bump, not a memset of one entry per cell in the vault.
    /// `side_hit` records which entries were touched so reading the totals back is O(touched).
    side_w: []f32,
    side_stamp: []u32,
    side_epoch: u32 = 0,
    side_hit: std.ArrayListUnmanaged(u32) = .empty,

    /// Fingerprint of the cut the cached `lifted` set was built from, plus the inputs that change
    /// what the lift produces. See `liftLinks`.
    lift_key: u64 = 0,
    lift_valid: bool = false,
    /// The lifted set itself, cached across frames. `links` is the per-frame *draw* list built
    /// from this plus whatever is still fading out.
    lifted: std.ArrayListUnmanaged(LiftedLink) = .empty,
    /// The focused note's own links at leaf precision — see `FocusLink`. Rebuilt by `liftLinks`
    /// alongside `lifted`, and therefore covered by the same fingerprint early-out: a stale set is
    /// only reachable when the cut *and* the focus are unchanged, in which case it is still correct
    /// (leaf positions do not move between rebuilds).
    focus_links: std.ArrayListUnmanaged(FocusLink) = .empty,
    /// Pair key -> crossfade, surviving across frames so a link that leaves the lifted set fades
    /// out instead of blinking. Bounded: live links are capped by `link_budget`, and a dying entry
    /// is dropped as soon as it is invisible.
    link_fade: std.AutoHashMapUnmanaged(u64, f32) = .empty,
    /// Per-link reach-out progress for the focused note's own links.
    ///
    /// Keyed by the **unordered** leaf pair, which is what lets the reader ride an edge. Following
    /// a link changes the focus from one end to the other, and an ordered key makes that the same
    /// edge under a different name: it would be dropped as the old note's and recreated as the new
    /// note's, blinking out and re-extending exactly while the camera is travelling along it. The
    /// same pair either way means the line the reader is following simply stays drawn until they
    /// arrive.
    focus_grow: std.AutoHashMapUnmanaged(u64, f32) = .empty,
    /// Whether the focused note is actually on screen, recomputed every `step`.
    ///
    /// The reveal is something the reader watches, so it must not run while its note is off screen:
    /// a reach growing from an off-screen point is clipped away entirely, so it played out unseen
    /// during the flight and the reader met a finished web on arrival. "Is it visible" is the
    /// honest test — "has the camera stopped" is not the same question, and gating on it stalled
    /// reveals for as long as the camera kept easing.
    focus_visible: bool = true,
    /// The cut cell holding `Params.focus_leaf`, resolved during `liftLinks`. `fold.invalid` when
    /// there is no focus or its branch was culled. The draw reads it to decide which links are the
    /// focused note's, so the panel does not have to re-derive the same walk.
    focus_cut: u32 = fold.invalid,
    /// True when the budget refused an open this frame (HUD / tests).
    bound: bool = false,
    /// False while any crossfade is still running. The host needs this to keep asking for frames:
    /// a camera chase reports itself, but a split that finishes after the camera stops would
    /// otherwise freeze half-open until some unrelated event woke the app.
    settled: bool = true,


    /// `fold_opts.cancel`, when set, makes this abandonable — see `fold.Options.cancel`. The
    /// checks between phases below matter as much as the one inside the coarsening loop: the web
    /// build and the placement are each a large fraction of the total.
    pub fn init(
        gpa: std.mem.Allocator,
        n_notes: usize,
        links: []const fold.Edge,
        paths: []const []const u8,
        fold_opts: fold.Options,
        place_opts: containment.Options,
    ) !World {
        var lad = try fold.build(gpa, n_notes, links, paths, fold_opts);
        errdefer lad.deinit(gpa);
        const n_cells = lad.cells.len;

        var w: World = .{
            .gpa = gpa,
            .lad = lad,
            .field = undefined,
            .web = undefined,
            .anim = try gpa.alloc(f32, n_cells),
            .px = try gpa.alloc(f32, n_cells),
            .py = try gpa.alloc(f32, n_cells),
            .mul = try gpa.alloc(f32, n_cells),
            .open = try gpa.alloc(bool, n_cells),
            .cut_of = try gpa.alloc(u32, n_cells),
            .cut_stamp = try gpa.alloc(u32, n_cells),
            .side_w = try gpa.alloc(f32, n_cells),
            .side_stamp = try gpa.alloc(u32, n_cells),
        };
        @memset(w.anim, 0);
        @memset(w.px, 0);
        @memset(w.py, 0);
        @memset(w.mul, 1);
        @memset(w.open, false);
        // Zeroed once here so the first frame's `cut_epoch` of 1 cannot collide with uninitialised
        // memory and read a stale memo as valid.
        @memset(w.cut_stamp, 0);
        // Same contract as `cut_stamp`: `side_epoch` is bumped *before* each use, so a stamp of 0
        // can never match the epoch of the first accumulation.
        @memset(w.side_stamp, 0);
        if (fold_opts.cancel) |c| {
            if (c.load(.acquire)) return error.Cancelled;
        }
        w.web = try cellweb.build(gpa, &w.lad, links);
        if (fold_opts.cancel) |c| {
            if (c.load(.acquire)) return error.Cancelled;
        }
        w.field = try containment.init(gpa, n_cells, lad.roots.len, fold_opts.arity, place_opts);
        // Islands are placed relative to each other once; everything below them is lazy.
        containment.placeRoots(&w.field, &w.lad);
        return w;
    }

    pub fn deinit(self: *World) void {
        self.marks.deinit(self.gpa);
        self.links.deinit(self.gpa);
        self.link_fade.deinit(self.gpa);
        self.focus_grow.deinit(self.gpa);
        self.cut.deinit(self.gpa);
        self.web.deinit(self.gpa);
        self.gpa.free(self.anim);
        self.gpa.free(self.px);
        self.gpa.free(self.py);
        self.gpa.free(self.mul);
        self.gpa.free(self.open);
        self.gpa.free(self.cut_of);
        self.gpa.free(self.cut_stamp);
        self.gpa.free(self.side_w);
        self.gpa.free(self.side_stamp);
        self.side_hit.deinit(self.gpa);
        self.sc_acc.deinit(self.gpa);
        self.sc_focus_pairs.deinit(self.gpa);
        self.sc_edge_seen.deinit(self.gpa);
        self.sc_live.deinit(self.gpa);
        self.sc_dead.deinit(self.gpa);
        self.sc_grow_live.deinit(self.gpa);
        self.sc_grow_dead.deinit(self.gpa);
        self.lifted.deinit(self.gpa);
        self.focus_links.deinit(self.gpa);
        self.field.deinit(self.gpa);
        self.lad.deinit(self.gpa);
        self.* = undefined;
    }

    /// Radius of a disc at the origin containing every island, so a caller can frame the vault.
    ///
    /// A disc, not a per-axis box, because the island pack is a disc: `pack_aspect` defaults to 1.
    /// Framing and bounding the vault as a circle is then exact rather than a conservative cover.
    pub fn extent(self: World) f32 {
        var e: f32 = 1;
        for (self.lad.roots) |r| {
            const p = self.field.pos[r];
            e = @max(e, @sqrt(p.x * p.x + p.y * p.y) + self.field.radius(&self.lad, r));
        }
        return e;
    }

    /// Rebuild the living set for this view.
    ///
    /// Two passes, deliberately. Topology first, as a **pure function of (tree, view, zoom,
    /// budget)** with no reference to animation state; then presentation, which only interpolates
    /// toward what the first pass decided.
    ///
    /// Collapsing these into one pass is the mistake that broke this on first contact: the budget
    /// was counted over *emitted marks*, and a mark is only emitted while it is still fading, so
    /// the count moved as animations progressed. That fed back into the open/closed cutoff, so
    /// cells vanished instead of splitting, appeared from nowhere, and — because link ownership
    /// keyed off the same fading state — edges popped in and out. A function that reads its own
    /// output cannot be stable. Keeping the passes apart is what makes "parked camera ⇒ nothing
    /// changes" true by construction rather than by luck.
    pub fn step(self: *World, view: View, p: Params, dt: f32) !void {
        self.focus_visible = self.leafOnScreen(p.focus_leaf, view);
        self.clearFrame();
        if (self.lad.roots.len == 0) return;
        try self.decideTopology(view, p);
        try self.present(view, p, dt);
    }

    /// The three phases of `step`, exposed so the bench can time them individually. Callers other
    /// than the bench should use `step`.
    pub fn clearFrame(self: *World) void {
        self.marks.clearRetainingCapacity();
        self.links.clearRetainingCapacity();
        self.cut.clearRetainingCapacity();
        @memset(self.open, false);
        self.bound = false;
        // Invalidate the `cutOf` memo by moving the epoch, not by clearing 341k entries.
        self.cut_epoch +%= 1;
    }

    /// Pass 1 — which cells are open. Reads only the ladder, the view, and the budget.
    pub fn decideTopology(self: *World, view: View, p: Params) !void {
        var frontier: std.ArrayListUnmanaged(u32) = .empty;
        defer frontier.deinit(self.gpa);
        var next: std.ArrayListUnmanaged(u32) = .empty;
        defer next.deinit(self.gpa);
        var vis: std.ArrayListUnmanaged(u32) = .empty;
        defer vis.deinit(self.gpa);
        for (self.lad.roots) |r| try frontier.append(self.gpa, r);

        // Cells already settled as closed at shallower levels. This is the budget's running
        // total, and it is topological — nothing here depends on a crossfade.
        var closed: usize = 0;
        var guard: u32 = 0;

        while (frontier.items.len > 0 and guard < 64) : (guard += 1) {
            // -- rule 1: cull first. Children live inside their parent's disc, so an off-screen
            // cell's whole subtree is off-screen and this test is exact.
            vis.clearRetainingCapacity();
            for (frontier.items) |id| {
                if (self.onScreen(id, view, p)) {
                    try vis.append(self.gpa, id);
                } else {
                    // Still part of the cut, so a link leaving the viewport keeps a target. This
                    // used to claim the cell's whole note range — an `O(notes)` fill every frame.
                    try self.cut.append(self.gpa, id);
                }
            }
            if (vis.items.len == 0) break;

            // -- rule 2: a count threshold, never visit order (see the module header) --
            var extra: usize = 0;
            var want_open: usize = 0;
            for (vis.items) |id| {
                if (self.wantsSplit(id, view, p)) {
                    extra += self.lad.cells[id].child_count - 1;
                    want_open += 1;
                }
            }

            var cutoff: u32 = 0;
            if (closed + vis.items.len + extra > p.budget and want_open > 0) {
                self.bound = true;
                cutoff = try self.countCutoff(vis.items, view, p, closed, want_open);
            }

            next.clearRetainingCapacity();
            for (vis.items) |id| {
                const c = self.lad.cells[id];
                const will_open = self.wantsSplit(id, view, p) and c.count > cutoff;
                self.open[id] = will_open;
                if (!will_open) {
                    closed += 1;
                    try self.cut.append(self.gpa, id);
                    continue;
                }
                for (self.lad.childrenOf(id)) |k| try next.append(self.gpa, k);
            }
            std.mem.swap(std.ArrayListUnmanaged(u32), &frontier, &next);
        }
    }

    fn onScreen(self: *const World, id: u32, view: View, p: Params) bool {
        const sr = self.field.radius(&self.lad, id) * view.zoom;
        const sx = view.w * 0.5 + (self.px[id] - view.cx) * view.zoom;
        const sy = view.h * 0.5 + (self.py[id] - view.cy) * view.zoom;
        const m = sr + p.cull_pad_px;
        return sx >= -m and sx <= view.w + m and sy >= -m and sy <= view.h + m;
    }

    fn wantsSplit(self: *const World, id: u32, view: View, p: Params) bool {
        const c = self.lad.cells[id];
        return c.child_count > 0 and self.field.radius(&self.lad, id) * view.zoom > p.split_px;
    }

    /// Largest count class that does not fit. That class and every smaller one stay closed, so
    /// cells of equal count never disagree and no order-dependent seam can appear.
    fn countCutoff(
        self: *World,
        vis: []const u32,
        view: View,
        p: Params,
        closed: usize,
        want_open: usize,
    ) !u32 {
        const counts = try self.gpa.alloc(u32, want_open);
        defer self.gpa.free(counts);
        var ci: usize = 0;
        for (vis) |id| {
            if (self.wantsSplit(id, view, p)) {
                counts[ci] = self.lad.cells[id].count;
                ci += 1;
            }
        }
        std.mem.sort(u32, counts, {}, comptime std.sort.desc(u32));

        var spent = closed + vis.len;
        var prev: u32 = std.math.maxInt(u32);
        for (counts) |cnt| {
            if (cnt == prev) continue; // same class, already paid for
            prev = cnt;
            var class_cost: usize = 0;
            for (vis) |id| {
                const c = self.lad.cells[id];
                if (c.count == cnt and self.wantsSplit(id, view, p)) class_cost += c.child_count - 1;
            }
            if (spent + class_cost > p.budget) return cnt;
            spent += class_cost;
        }
        return 0;
    }

    /// Pass 2 — how the decided set looks right now. Chases `anim` toward `open`, lerps poses, and
    /// emits marks. Keeps walking into a *closing* cell's children so a merge crossfades instead
    /// of popping, but never lets any of that feed back into the decision above.
    pub fn present(self: *World, view: View, p: Params, dt: f32) !void {
        const rate = @min(1.0, dt * p.rate);
        self.settled = true;
        var stack: std.ArrayListUnmanaged(u32) = .empty;
        defer stack.deinit(self.gpa);
        for (self.lad.roots) |r| {
            self.px[r] = self.field.pos[r].x;
            self.py[r] = self.field.pos[r].y;
            self.mul[r] = 1;
            try stack.append(self.gpa, r);
        }

        var guard: u32 = 0;
        while (stack.pop()) |id| {
            guard += 1;
            if (guard > 200_000) break;
            const c = self.lad.cells[id];

            const target: f32 = if (self.open[id]) 1 else 0;
            self.anim[id] += (target - self.anim[id]) * rate;
            if (self.anim[id] < 0.004) self.anim[id] = 0;
            if (self.anim[id] > 0.996) self.anim[id] = 1;
            if (self.anim[id] != target) self.settled = false;

            if (self.anim[id] < 1) {
                const alpha = self.mul[id] * (1 - self.anim[id]);
                if (alpha > 0.02 and self.onScreen(id, view, p)) {
                    const sr = self.field.radius(&self.lad, id) * view.zoom;
                    const is_note = c.child_count == 0;
                    // -- rules 4 & 5: a note is a fixed screen size; a mass is count-scaled and
                    // soft-capped so one the budget refused cannot inflate to fill the screen --
                    const r: f32 = if (is_note) p.note_r_px else blk: {
                        const full = @max(1.0, p.mass_cap_px *
                            (1 - @exp(-(sr * 0.82) / p.mass_cap_px)));
                        // A splitting mass shrinks to a single note's size as it fades, rather
                        // than hanging at full radius while children appear inside it. The ring
                        // reads as collapsing into the point its children emerge from, which is
                        // what makes a split look like one object becoming several instead of two
                        // unrelated things crossfading. Runs in reverse on merge, for free.
                        break :blk full + (p.note_r_px - full) * self.anim[id];
                    };
                    try self.marks.append(self.gpa, .{
                        .cell = id,
                        .wx = self.px[id],
                        .wy = self.py[id],
                        .x = view.w * 0.5 + (self.px[id] - view.cx) * view.zoom,
                        .y = view.h * 0.5 + (self.py[id] - view.cy) * view.zoom,
                        .r = r,
                        .alpha = alpha,
                        .is_note = is_note,
                        .note = c.note,
                    });
                }
            }

            if (c.child_count > 0 and self.anim[id] > 0) {
                self.field.ensureChildren(&self.lad, id); // lazy placement pays off here
                for (self.lad.childrenOf(id)) |k| {
                    const own = self.field.pos[k];
                    self.px[k] = self.px[id] + (own.x - self.px[id]) * self.anim[id];
                    self.py[k] = self.py[id] + (own.y - self.py[id]) * self.anim[id];
                    self.mul[k] = self.mul[id] * self.anim[id];
                    try stack.append(self.gpa, k);
                }
            }
        }
    }


    /// The cut cell covering `cell`: the first cell on the root→`cell` path that is not open this
    /// frame. Null when every cell on that path is open, which means the cut is strictly *below*
    /// `cell` — see the pair-discovery argument in `cellweb.zig`.
    /// The exact resting world position of a note, whether or not it is drawn this frame.
    ///
    /// The panel's `GraphNode.pos` is only written for notes that resolved as marks, so a note
    /// sitting inside a coalesced mass carries a stale one — and aiming the camera at that is why
    /// opening a document flew somewhere near the note rather than to it, then found the note
    /// elsewhere on arrival.
    ///
    /// Containment places lazily, so the answer is not sitting in `field.pos` yet; but it is fully
    /// *determined*, and forcing it costs a walk of the ancestor chain. Root-down, because
    /// `ensureChildren` positions a cell's children relative to the cell's own already-known
    /// centre: going leaf-up would read positions that have not been decided. Depth is
    /// `log_arity(n)` — seven levels at 283,878 notes — so this is a few dozen placements, not a
    /// traversal of the vault.
    pub fn noteWorldPos(self: *World, note: u32) ?struct { x: f32, y: f32 } {
        if (note >= self.lad.leaf_cell.len) return null;
        const leaf = self.lad.leaf_cell[note];
        if (leaf == fold.invalid or leaf >= self.lad.cells.len) return null;

        var chain: [64]u32 = undefined;
        var n: usize = 0;
        var c = leaf;
        while (n < chain.len) {
            chain[n] = c;
            n += 1;
            const parent = self.lad.cells[c].parent;
            if (parent == fold.invalid) break;
            c = parent;
        }

        var i = n;
        while (i > 0) {
            i -= 1;
            self.field.ensureChildren(&self.lad, chain[i]);
        }
        const p = self.field.pos[leaf];
        return .{ .x = p.x, .y = p.y };
    }

    /// The smallest zoom at which `note` is drawn as itself rather than inside a mass.
    ///
    /// A cell opens once `radius × zoom > split_px`, so the leaf's *parent* has to clear that bar
    /// for the leaf to exist as a mark. Framing at or above this is what makes "the selected note
    /// never coalesces" a property of the camera rather than a hope.
    pub fn noteResolveZoom(self: *const World, note: u32, p: Params) ?f32 {
        if (note >= self.lad.leaf_cell.len) return null;
        const leaf = self.lad.leaf_cell[note];
        if (leaf == fold.invalid or leaf >= self.lad.cells.len) return null;
        const parent = self.lad.cells[leaf].parent;
        if (parent == fold.invalid) return null;
        const r = self.field.radius(&self.lad, parent);
        if (r <= 0) return null;
        return p.split_px / r;
    }

    /// The cut cell that stands in for `cell` this frame, memoized.
    ///
    /// The walk itself is short — `log_arity(n)`, seven levels at 283,878 notes — but it is called
    /// once per *neighbour* during the lift, so at a high budget it runs tens of thousands of times
    /// a frame, each one chasing parent pointers at random into a 341k-cell array. That is cache
    /// misses, not arithmetic, and it was the bulk of an 8 ms lift.
    ///
    /// The answer is the same for every cell on a chain, so one walk can record all of them.
    /// Stamping against `cut_epoch` means no per-frame clear of a 341k array: a stale stamp is
    /// simply a miss.
    fn cutOf(self: *World, cell: u32) ?u32 {
        if (self.cut_stamp[cell] == self.cut_epoch) {
            const memo = self.cut_of[cell];
            return if (memo == fold.invalid) null else memo;
        }

        // Climb to the root, then read back down. The ladder is at most `max_levels` deep, and a
        // real one is `log_arity(n)` — six levels at a million notes.
        var chain: [64]u32 = undefined;
        var n: usize = 0;
        var c = cell;
        while (n < chain.len) {
            chain[n] = c;
            n += 1;
            const parent = self.lad.cells[c].parent;
            if (parent == fold.invalid) break;
            c = parent;
        }

        // Root-down: the first closed cell on the way down is the cut for *itself and everything
        // below it*, so one pass records the whole chain.
        var answer: u32 = fold.invalid;
        var i = n;
        while (i > 0) {
            i -= 1;
            if (answer == fold.invalid and !self.open[chain[i]]) answer = chain[i];
            self.cut_of[chain[i]] = answer;
            self.cut_stamp[chain[i]] = self.cut_epoch;
        }
        return if (answer == fold.invalid) null else answer;
    }

    /// Build this frame's web from the cut and the precomputed cell adjacency. Call after `step`.
    ///
    /// Costs the cut, not the vault. The previous version walked every note-level edge every frame
    /// to map both endpoints onto their owning cell — `O(E)` regardless of zoom, and at overview on
    /// an islands vault it paid all of it to produce nothing, since every edge was internal to one
    /// root. `cellweb.zig` has the full argument; the short version is that a cell pair's total
    /// weight is precomputed once per rebuild, so a frame reads at most
    /// `cut × link_scan_cap` entries.
    /// Crossfade the lifted set, and keep just-dropped links alive while they fade.
    ///
    /// The set the cut produces is *discrete* — pan a little and a cell is culled, so its links are
    /// simply absent next frame. That is correct topology and terrible to look at: the web blinks
    /// as you move. This is the same treatment marks already get from `anim`, applied to pairs:
    /// present links rise toward 1, absent ones fall toward 0 and are drawn until they are
    /// invisible, then forgotten.
    ///
    /// Bounded by construction — live entries are capped by `link_budget`, and a dying entry is
    /// dropped the moment it falls under the visibility floor, so the map cannot accumulate.
    /// How much longer than the base time this link's reach should take, from its world length.
    ///
    /// Measured in world units, not screen pixels, deliberately: a link's length is a property of
    /// the graph, and pacing off the screen would make the same connection animate differently
    /// depending on the zoom you happened to be at when you clicked.
    fn reachStretch(self: *World, p: Params, fl: FocusLink) f32 {
        if (fl.a >= self.field.pos.len or fl.b >= self.field.pos.len) return 1;
        const pa = self.field.pos[fl.a];
        const pb = self.field.pos[fl.b];
        const dx = pb.x - pa.x;
        const dy = pb.y - pa.y;
        const len = @sqrt(dx * dx + dy * dy);
        return std.math.clamp(len / @max(1, p.focus_reach_ref), 1, p.focus_reach_max);
    }

    /// Is `leaf` inside the viewport right now? Read from the placement field rather than from the
    /// marks, so it answers the same whether the note is drawn as itself or standing in a mass.
    fn leafOnScreen(self: *World, leaf: u32, view: View) bool {
        if (leaf == fold.invalid or leaf >= self.field.pos.len) return false;
        const fp = self.field.pos[leaf];
        const sx = view.w * 0.5 + (fp.x - view.cx) * view.zoom;
        const sy = view.h * 0.5 + (fp.y - view.cy) * view.zoom;
        return sx >= 0 and sx <= view.w and sy >= 0 and sy <= view.h;
    }

    /// Advance each focused link's own reach-out, and forget the ones that are no longer focused.
    ///
    /// Called from `fadeLinks`, which is the one point both the cached and the rebuilt lift paths
    /// pass through every frame — the progress has to keep moving on a frame where the lift itself
    /// was skipped, or a reach would freeze mid-travel whenever the camera was moving.
    fn stepFocusGrow(self: *World, p: Params, dt: f32) !void {
        // Clamped, because this animation exists to be *seen*. A rebuild, a long lift or a frame
        // the app spent asleep hands us a `dt` of hundreds of milliseconds, and an unclamped step
        // spends the whole reach in one frame — the link simply appears, which is the failure this
        // animation was added to fix. Capping the step stretches a hitch instead of skipping it.
        const step_dt = @min(dt, 1.0 / 20.0);
        const base = step_dt / @max(0.01, p.focus_reach_secs);
        const live = &self.sc_grow_live;
        live.clearRetainingCapacity();
        try live.ensureTotalCapacity(self.gpa, @intCast(self.focus_links.items.len));
        for (self.focus_links.items) |*fl| {
            const key = (@as(u64, @min(fl.a, fl.b)) << 32) | @as(u64, @max(fl.a, fl.b));
            live.putAssumeCapacity(key, {});
            const gop = try self.focus_grow.getOrPut(self.gpa, key);
            const prev: f32 = if (gop.found_existing) gop.value_ptr.* else blk: {
                // Zero, always: a key that does not exist is an edge that is not currently
                // highlighted, so it has something to reveal. An edge already in the set — the one
                // the reader just travelled along, or one belonging to another open note — keeps
                // the extension it has and never restarts. The key's existence *is* the memory,
                // which is why there is no "have I revealed this note before" bookkeeping: that
                // question was always a proxy for this one, and every bug in it came from the two
                // disagreeing.
                break :blk 0;
            };
            if (fl.a != p.focus_leaf) {
                // Not the focused note: its web stands. Advancing it instead is what made a reveal
                // appear to play one click late — the previous note was the only one still held, so
                // selecting something else released it and the reader watched the *last* note
                // animate while the new one sat finished.
                gop.value_ptr.* = 1;
            } else if (self.focus_visible) {
                // Longer links take longer, so the reach reads as a line travelling at a speed
                // rather than every link finishing at once regardless of how far it had to go.
                gop.value_ptr.* = @min(1, prev + base / self.reachStretch(p, fl.*));
            }
            fl.grow = gop.value_ptr.*;
            if (fl.grow < 1) self.settled = false;
        }

        // Drop what is no longer focused. The edge just traversed survives this: it is in the new
        // focus note's own link set too, under the same unordered key, so it stays live and keeps
        // the extension it already had.
        var it = self.focus_grow.iterator();
        const dead = &self.sc_grow_dead;
        dead.clearRetainingCapacity();
        while (it.next()) |kv| {
            if (!live.contains(kv.key_ptr.*)) try dead.append(self.gpa, kv.key_ptr.*);
        }
        for (dead.items) |k| _ = self.focus_grow.remove(k);
    }

    fn fadeLinks(self: *World, p: Params, dt: f32) !void {
        try self.stepFocusGrow(p, dt);
        const rate = @min(1.0, dt * p.rate);

        // The draw list is rebuilt every frame from the cached lift plus whatever is still fading;
        // `lifted` itself is only recomputed when the cut changes.
        self.links.clearRetainingCapacity();

        // Rise the ones that are present, and remember them so the sweep below can tell which
        // stored entries no longer are.
        const live = &self.sc_live;
        live.clearRetainingCapacity();
        try live.ensureTotalCapacity(self.gpa, @intCast(self.lifted.items.len));
        for (self.lifted.items) |l| {
            const key = (@as(u64, l.a) << 32) | @as(u64, l.b);
            live.putAssumeCapacity(key, {});
            const gop = try self.link_fade.getOrPut(self.gpa, key);
            const prev: f32 = if (gop.found_existing) gop.value_ptr.* else 0;
            // The focused note's own links do not fade in. Everything else is ambient web whose
            // arrival can be gentle, but these are the answer to a question the reader just asked
            // — a link that eases in over half a second reads as one that was not there.
            const next = if (l.focus) 1 else prev + (1 - prev) * rate;
            gop.value_ptr.* = if (next > 0.996) 1 else next;

            var out = l;
            out.alpha = gop.value_ptr.*;
            if (out.alpha < 1) self.settled = false;
            try self.links.append(self.gpa, out);
        }

        // Fall the ones that are not, and re-emit them until they are gone.
        const dead = &self.sc_dead;
        dead.clearRetainingCapacity();
        var it = self.link_fade.iterator();
        while (it.next()) |kv| {
            if (live.contains(kv.key_ptr.*)) continue;
            const next = kv.value_ptr.* * (1 - rate);
            if (next < 0.02) {
                try dead.append(self.gpa, kv.key_ptr.*);
                continue;
            }
            kv.value_ptr.* = next;
            self.settled = false;
            try self.links.append(self.gpa, .{
                .a = @intCast(kv.key_ptr.* >> 32),
                .b = @intCast(kv.key_ptr.* & 0xffff_ffff),
                .w = 0,
                .alpha = next,
            });
        }
        for (dead.items) |k| _ = self.link_fade.remove(k);
    }

    pub fn liftLinks(self: *World, p: Params, dt: f32) !void {
        self.links.clearRetainingCapacity();
        if (self.lad.roots.len == 0) return;
        prof.calls += 1;
        var pt = pnow();

        // Skip the whole lift when nothing that decides it has changed.
        //
        // The lifted set is a pure function of the cut plus the focus and the budget — cell ids,
        // not positions — so panning within an unchanged cut, or sitting still, produces exactly
        // the set already computed. Recomputing it anyway was 99% of the world's frame cost at a
        // high budget: 5–8 ms against 0.13 ms for selecting and placing every mark.
        //
        // The fingerprint is over the cut's cell ids in order. `decideTopology` builds that list
        // deterministically from (tree, view, zoom, budget), so equal fingerprints mean an equal
        // set — and a hash collision costs a stale web for one camera move, not corruption.
        var fp: u64 = 0xcbf29ce484222325;
        for (self.cut.items) |c| {
            fp ^= c;
            fp *%= 0x100000001b3;
        }
        fp ^= @as(u64, p.focus_leaf);
        fp *%= 0x100000001b3;
        // The open set is part of the lift now that every open note's links are built here, so a
        // tab opening or closing has to invalidate the cache the same way a cut change does.
        for (p.open_leaves) |leaf| {
            fp ^= @as(u64, leaf) +% 1;
            fp *%= 0x100000001b3;
        }
        fp ^= @as(u64, p.link_budget);
        fp *%= 0x100000001b3;

        if (self.lift_valid and (fp == self.lift_key or p.lift_hold)) {
            pt = pnow();
            try self.fadeLinks(p, dt);
            prof.fade_ns += plap(&pt);
            return;
        }
        self.lift_key = fp;
        self.lift_valid = true;
        prof.recomputes += 1;

        // Two maps, because a pair's weight has to be *summed* within one side and *maxed* across
        // the two.
        //
        // Summed within a side: several of `cv`'s descendants can be adjacent to `u` at `u`'s own
        // level, and the drawn line's weight is their total.
        //
        // Maxed across sides: a pair is often visible from both ends, and adding those would double
        // it. An earlier version picked one owner by comparing the two cells' levels — process from
        // the finer side, skip from the coarser. That is only sound on a level-uniform ladder, and
        // this one is not: `fold` bundles same-component leftovers, so a cell's parent is not always
        // exactly one level up and "adjacency at my own level" holds only approximately. The
        // mismatch silently dropped ~23% of the web at some zooms (1502 links where the old
        // note-level lift found 1963) — with no visible seam to hint at it, which is exactly the
        // class of bug the sweep exists to catch. Taking the max needs no level reasoning at all:
        // whichever side sees the whole aggregate wins, a side that sees nothing contributes
        // nothing, and a side that sees part of it is dominated.
        const acc = &self.sc_acc;
        acc.clearRetainingCapacity();
        // How deep into one cell's neighbour list it is worth reading.
        //
        // `link_scan_cap` alone is a fixed ceiling, and a fixed ceiling is the wrong shape: on a
        // sparse vault no cell ever reaches it, and on a dense one every cell does. Simple English
        // Wikipedia (mean degree 23.6, one hub at 29,448) hit it on every cut cell at once —
        // 3771 cells × 256 = ~965k lookups per frame, 98 ms, to produce a web capped at 10,000
        // lines. Two orders of magnitude of the scan was feeding a budget that had already closed.
        //
        // So derive it from the budget instead: with `n` cut cells sharing `link_budget` lines,
        // one cell can only place about `link_budget / n` of them. The ×4 is slack for the uneven
        // case, where a few well-connected cells rightly take more than their share. Because each
        // neighbour list is sorted heaviest-first this stays a good approximation of the global
        // top-`link_budget`: a pair heavy enough to make that cut is in its own cell's head unless
        // that cell already has `cap` heavier neighbours — which are themselves heavy enough to
        // have spent the budget.
        const share = (p.link_budget *| 4) / @max(1, self.cut.items.len);
        const cap = @min(p.link_scan_cap, @max(@as(usize, 8), share));

        // The focused note's own cut cell, exempt from `cap` below. Resolved once here rather than
        // tested per neighbour, and republished on `self` for the draw.
        self.focus_cut = if (p.focus_leaf != fold.invalid and p.focus_leaf < self.lad.cells.len)
            (self.cutOf(p.focus_leaf) orelse fold.invalid)
        else
            fold.invalid;

        // Exactly which lifted pairs are the focused *note's* links.
        //
        // Read from the leaf's own adjacency — that is the note's link set, at any zoom — and then
        // lifted the same way everything else is: each neighbour leaf mapped to whatever cell
        // currently stands in for it. So when the note is coalesced its links still point at the
        // right places, instead of the mass's entire incident set being painted as the document's.
        const focus_pairs = &self.sc_focus_pairs;
        focus_pairs.clearRetainingCapacity();
        // One entry per *edge*, not per (note, neighbour).
        //
        // The highlighted web is a set of edges: `A—B` and `B—A` are the same line. With both notes
        // open it was in the list twice and drawn twice — and worse, the two copies carried
        // different reveal state, so the edge the reader had just travelled along could sweep again
        // from its far end. Claimed first-come, and the focused note is processed first, so an edge
        // belongs to the note being looked at and is drawn outward from it.
        const edge_seen = &self.sc_edge_seen;
        edge_seen.clearRetainingCapacity();
        self.focus_links.clearRetainingCapacity();
        // The focused leaf first and always, then every other open note. `focus_leaf` is not
        // required to appear in `open_leaves` — a caller may set only the focus, and the pinned
        // test "the focused note keeps every link however far the camera travels" does exactly
        // that. Treating the open set as the only source silently emptied its link set.
        var focus_spent: usize = 0;
        var leaf_i: usize = 0;
        while (leaf_i <= p.open_leaves.len) : (leaf_i += 1) {
            const leaf = if (leaf_i == 0) p.focus_leaf else p.open_leaves[leaf_i - 1];
            if (leaf_i > 0 and leaf == p.focus_leaf) continue; // already done as the focus
            if (leaf == fold.invalid or leaf >= self.lad.cells.len) continue;
            if (focus_spent >= p.focus_link_budget) break;
            const leaf_cut = self.cutOf(leaf) orelse continue;
            const flo, const fhi = self.web.range(leaf);
            // The leaf-precision set is capped where the lifted one does not need to be: lifting
            // collapses a hub's thousands of neighbours onto a handful of cells, and not lifting
            // means every one of them is its own line. `link_scan_cap` is already the number that
            // exists to bound exactly this — a 29,448-degree note resolving as a single visible one.
            // The focused note is limited only by what is left of the budget; every other open note
            // still answers to `link_scan_cap`, so one hub sitting in a background tab cannot spend
            // the frame on itself.
            const room = p.focus_link_budget -| focus_spent;
            const leaf_cap = if (leaf == p.focus_leaf) room else @min(room, p.link_scan_cap);
            const fcap = @min(fhi, flo +| leaf_cap);
            self.field.ensurePlaced(&self.lad, leaf);
            for (self.web.nbr[flo..fhi], flo..) |v, i| {
                if (i < fcap and v != leaf) {
                    const ekey = (@as(u64, @min(leaf, v)) << 32) | @as(u64, @max(leaf, v));
                    const eg = try edge_seen.getOrPut(self.gpa, ekey);
                    if (!eg.found_existing) {
                        // Both ends placed on demand: a neighbour in a branch the camera never
                        // opened has no position until asked for one.
                        self.field.ensurePlaced(&self.lad, v);
                        try self.focus_links.append(self.gpa, .{ .a = leaf, .b = v });
                        focus_spent += 1;
                    }
                }
                const cv = self.cutOf(v) orelse continue;
                if (cv == leaf_cut) continue;
                const key = (@as(u64, @min(leaf_cut, cv)) << 32) |
                    @as(u64, @max(leaf_cut, cv));
                try focus_pairs.put(self.gpa, key, {});
            }
        }

        prof.focus_ns += plap(&pt);

        for (self.cut.items) |u| {
            const lo, const hi = self.web.range(u);
            // Saturating: a caller that wants the cap off passes `maxInt`, and `lo + cap` would
            // wrap. The focused cell reads its whole neighbour list: at a `cap` of 8 — which is
            // what a large cut produces — a note's actual links are routinely outside its own
            // cell's heaviest few, so the one thing the reader asked to see is the first casualty
            // of a budget meant for ambient web.
            // Leaves are exempt from the derived share, and coarse cells are not.
            //
            // `cap` exists to bound *aggregated* degree: a cell high in the ladder can be adjacent
            // to a large fraction of its level, and that is what made the lift cost 98 ms. A leaf
            // aggregates nothing — its neighbour list is exactly its one note's links, median 8 on
            // a Wikipedia vault — so truncating it to the derived share (which bottoms out at 8
            // when the cut is large) drops real links from precisely the marks the reader can see
            // individually. That is the "every node is drawn but almost nothing is connected"
            // picture at full zoom. `link_scan_cap` still bounds the pathological case of a
            // 29,448-degree hub resolving as a single visible note.
            const leaf = self.lad.cells[u].child_count == 0;
            const end = if (u == self.focus_cut)
                hi
            else if (leaf)
                @min(hi, lo +| p.link_scan_cap)
            else
                @min(hi, lo +| cap);
            self.side_epoch +%= 1;
            // Wrap is once every 4 billion cut cells — hours of continuous panning — but a stamp
            // left over from the previous lap would read as current and silently drop a cell's
            // whole neighbour weight, so clear on the way past rather than leave it to chance.
            if (self.side_epoch == 0) {
                @memset(self.side_stamp, 0);
                self.side_epoch = 1;
            }
            self.side_hit.clearRetainingCapacity();
            for (self.web.nbr[lo..end], self.web.w[lo..end]) |v, w| {
                const cv = self.cutOf(v) orelse continue; // cut is deeper there; found from it
                if (cv == u) continue; // both ends inside the same cut cell — nothing to draw
                if (self.side_stamp[cv] != self.side_epoch) {
                    self.side_stamp[cv] = self.side_epoch;
                    self.side_w[cv] = 0;
                    try self.side_hit.append(self.gpa, cv);
                }
                self.side_w[cv] += w;
            }
            for (self.side_hit.items) |cv| {
                const key = (@as(u64, @min(u, cv)) << 32) | @as(u64, @max(u, cv));
                const gop = try acc.getOrPut(self.gpa, key);
                const prev = if (gop.found_existing) gop.value_ptr.* else 0;
                gop.value_ptr.* = @max(prev, self.side_w[cv]);
            }
        }
        prof.scan_ns += plap(&pt);
        self.lifted.clearRetainingCapacity();
        var it = acc.iterator();
        while (it.next()) |kv| {
            const la: u32 = @intCast(kv.key_ptr.* >> 32);
            const lb: u32 = @intCast(kv.key_ptr.* & 0xffff_ffff);
            try self.lifted.append(self.gpa, .{
                .a = la,
                .b = lb,
                .w = kv.value_ptr.*,
                .focus = focus_pairs.contains(kv.key_ptr.*),
                // A note drawn as itself owns its whole link set.
                .essential = self.lad.cells[la].child_count == 0 or
                    self.lad.cells[lb].child_count == 0,
            });
        }
        prof.build_ns += plap(&pt);
        // Count what may not be dropped before deciding whether to drop anything.
        var essential_n: usize = 0;
        for (self.lifted.items) |l| {
            if (l.focus or l.essential) essential_n += 1;
        }
        // `link_budget` caps the *ambient* web — the aggregate lines between coalesced masses,
        // where a hairball genuinely says nothing. It must not cap a link belonging to a note the
        // reader can see individually: a node drawn as itself showing three of its seven links is
        // worse than showing none, because there is no way to tell which are missing.
        const keep = @max(p.link_budget, essential_n);
        if (self.lifted.items.len > keep) {
            // Focus-incident pairs sort first, ahead of weight.
            //
            // Truncation is by weight, and a note's own links are usually light — one mention each
            // — so the reader's note is exactly the kind of thing a global "keep the heaviest"
            // rule discards. Ordering by focus first means the budget can no longer take away the
            // one relationship set that was asked for, while everything below it still competes on
            // weight exactly as before. No second list and no second code path: the same sort,
            // with one more key in front, so determinism is unchanged.
            // Select, don't sort. What this needs is the *set* of the `keep` heaviest, and a full
            // sort also puts the ~20,000 links it is about to discard in order — 2.0 ms a frame at
            // 300k notes, the single largest item in a moving frame. `selectTopK` partitions to the
            // same set for a fraction of that. The set is uniquely determined either way, because
            // `heavier` is a strict total order: the `(a, b)` tie-break is the pair itself, so no
            // two links can compare equal and there is no boundary ambiguity to resolve by luck.
            selectTopK(self.lifted.items, keep);
            self.lifted.shrinkRetainingCapacity(keep);
        }
        prof.sort_ns += plap(&pt);

        try self.fadeLinks(p, dt);
        prof.fade_ns += plap(&pt);
    }

    pub fn noteMarks(self: World) usize {
        var n: usize = 0;
        for (self.marks.items) |m| {
            if (m.is_note) n += 1;
        }
        return n;
    }
};

// ---- tests ----------------------------------------------------------------------------------

const testing = std.testing;

test "selectTopK keeps exactly the set a full sort would keep" {
    var rng = std.Random.DefaultPrng.init(0x5eed);
    const r = rng.random();
    const gpa = testing.allocator;

    for ([_]usize{ 1, 2, 17, 64, 1000, 9999 }) |n| {
        const items = try gpa.alloc(LiftedLink, n);
        defer gpa.free(items);
        for (items, 0..) |*l, i| {
            l.* = .{
                .a = @intCast(i),
                .b = r.int(u16),
                // Heavy duplication on purpose: weight ties are the case where a selection can
                // disagree with a sort, and the `(a, b)` tie-break is what stops it.
                .w = @floatFromInt(r.intRangeAtMost(u8, 0, 8)),
                .focus = r.boolean(),
                .essential = r.boolean(),
            };
        }

        const reference = try gpa.dupe(LiftedLink, items);
        defer gpa.free(reference);
        std.mem.sort(LiftedLink, reference, {}, struct {
            fn less(_: void, x: LiftedLink, y: LiftedLink) bool {
                return heavier(x, y);
            }
        }.less);

        for ([_]usize{ 0, 1, n / 3, n / 2, n - 1, n }) |k| {
            const scratch = try gpa.dupe(LiftedLink, items);
            defer gpa.free(scratch);
            selectTopK(scratch, k);
            if (k == 0 or k >= n) continue;

            // Sets, not orders: `selectTopK` promises the prefix holds the same links, not that it
            // holds them in the same sequence.
            var want: std.AutoHashMapUnmanaged(u64, void) = .empty;
            defer want.deinit(gpa);
            for (reference[0..k]) |l| {
                try want.put(gpa, (@as(u64, l.a) << 32) | @as(u64, l.b), {});
            }
            for (scratch[0..k]) |l| {
                try testing.expect(want.remove((@as(u64, l.a) << 32) | @as(u64, l.b)));
            }
            try testing.expectEqual(@as(usize, 0), want.count());
        }
    }
}

fn chainLinks(gpa: std.mem.Allocator, n: u32) ![]fold.Edge {
    const e = try gpa.alloc(fold.Edge, n - 1);
    for (0..n - 1) |i| e[i] = .{ .a = @intCast(i), .b = @intCast(i + 1) };
    return e;
}

fn settle(w: *World, view: View, p: Params, frames: usize) !void {
    for (0..frames) |_| try w.step(view, p, 1.0 / 60.0);
}

test "a parked camera stops changing the open set" {
    // The reliability bar. If this fails, everything else is noise.
    const gpa = testing.allocator;
    const links = try chainLinks(gpa, 3000);
    defer gpa.free(links);
    var w = try World.init(gpa, 3000, links, &.{}, .{}, .{});
    defer w.deinit();

    const view: View = .{ .w = 900, .h = 600, .zoom = 6, .cx = 0, .cy = 0 };
    const p: Params = .{};
    try settle(&w, view, p, 240);

    const first = try gpa.dupe(Mark, w.marks.items);
    defer gpa.free(first);
    for (0..30) |_| {
        try w.step(view, p, 1.0 / 60.0);
        try testing.expectEqual(first.len, w.marks.items.len);
        for (first, w.marks.items) |a, b| try testing.expectEqual(a.cell, b.cell);
    }
}

test "marks stay within budget" {
    const gpa = testing.allocator;
    const links = try chainLinks(gpa, 5000);
    defer gpa.free(links);
    var w = try World.init(gpa, 5000, links, &.{}, .{}, .{});
    defer w.deinit();

    const p: Params = .{ .budget = 120 };
    var zoom: f32 = 0.5;
    while (zoom < 400) : (zoom *= 1.35) {
        try settle(&w, .{ .w = 900, .h = 600, .zoom = zoom, .cx = 0, .cy = 0 }, p, 90);
        // dying marks may briefly exceed; after settling the living set must fit
        try testing.expect(w.marks.items.len <= p.budget * 2);
    }
}

test "the budget wall does not oscillate" {
    // Rule 3. Force-closing an open cell frees budget, which lets it reopen, which exceeds the
    // budget again — visible judder at max zoom. Parked at the wall, the count must be constant.
    const gpa = testing.allocator;
    const links = try chainLinks(gpa, 4000);
    defer gpa.free(links);
    var w = try World.init(gpa, 4000, links, &.{}, .{}, .{});
    defer w.deinit();

    const view: View = .{ .w = 900, .h = 600, .zoom = 30, .cx = 0, .cy = 0 };
    const p: Params = .{ .budget = 60 };
    try settle(&w, view, p, 300);
    const n = w.marks.items.len;
    for (0..60) |_| {
        try w.step(view, p, 1.0 / 60.0);
        try testing.expectEqual(n, w.marks.items.len);
    }
}

test "zooming in eventually resolves to notes" {
    const gpa = testing.allocator;
    const links = try chainLinks(gpa, 2000);
    defer gpa.free(links);
    var w = try World.init(gpa, 2000, links, &.{}, .{}, .{});
    defer w.deinit();

    const p: Params = .{ .budget = 280 };
    // far enough in that the remaining notes comfortably fit the budget
    try settle(&w, .{ .w = 900, .h = 600, .zoom = 120, .cx = 0, .cy = 0 }, p, 400);
    try testing.expect(w.noteMarks() > 0);
    // and at that zoom nothing coalesced is left on screen
    for (w.marks.items) |m| try testing.expect(m.is_note);
}

test "notes are a fixed screen size, masses are not" {
    const gpa = testing.allocator;
    const links = try chainLinks(gpa, 800);
    defer gpa.free(links);
    var w = try World.init(gpa, 800, links, &.{}, .{}, .{});
    defer w.deinit();
    const p: Params = .{};
    try settle(&w, .{ .w = 900, .h = 600, .zoom = 200, .cx = 0, .cy = 0 }, p, 400);
    for (w.marks.items) |m| {
        if (m.is_note) try testing.expectApproxEqAbs(p.note_r_px, m.r, 0.001);
        try testing.expect(m.r <= p.mass_cap_px + 0.001);
    }
}

test "links lift onto living cells" {
    const gpa = testing.allocator;
    const links = try chainLinks(gpa, 1500);
    defer gpa.free(links);
    var w = try World.init(gpa, 1500, links, &.{}, .{}, .{});
    defer w.deinit();

    try settle(&w, .{ .w = 900, .h = 600, .zoom = 8, .cx = 0, .cy = 0 }, .{}, 120);
    try w.liftLinks(.{}, 1.0);
    try testing.expect(w.links.items.len > 0);
    // every lifted endpoint must be a cell that is actually on screen this frame
    for (w.links.items) |l| {
        var found_a = false;
        var found_b = false;
        for (w.marks.items) |m| {
            if (m.cell == l.a) found_a = true;
            if (m.cell == l.b) found_b = true;
        }
        try testing.expect(found_a and found_b);
    }
}

test "the focused note keeps every link however far the camera travels" {
    // The bug this pins down does not present as a wrong number, which is why it survived two
    // fixes: it presents as a *drifting* one. Lifting the focused note's links onto the cut means
    // that as the camera moves away, the cell standing in for the note is culled at a shallower
    // level and grows — and its neighbours, which sit near it in the hierarchy precisely because
    // they link to it, fall inside that same cell and are dropped by `cv == u` one after another.
    // So the set the reader is tracing thins out with distance and is gone by the time they reach
    // the far end, which is the one moment it was needed.
    const gpa = testing.allocator;
    const links = try chainLinks(gpa, 4000);
    defer gpa.free(links);
    var w = try World.init(gpa, 4000, links, &.{}, .{}, .{});
    defer w.deinit();

    // Interior of a chain: exactly two neighbours, and that is true at every camera position.
    const note: u32 = 2000;
    const p: Params = .{ .focus_leaf = w.lad.leaf_cell[note] };

    var dist: f32 = 0;
    while (dist < 100_000) : (dist = if (dist == 0) 25 else dist * 5) {
        try settle(&w, .{ .w = 900, .h = 600, .zoom = 4, .cx = dist, .cy = 0 }, p, 8);
        try w.liftLinks(p, 1.0 / 60.0);
        try testing.expectEqual(@as(usize, 2), w.focus_links.items.len);
        // Always anchored on the note itself, never on a stand-in.
        for (w.focus_links.items) |fl| {
            try testing.expectEqual(p.focus_leaf, fl.a);
            try testing.expect(fl.b != p.focus_leaf);
        }
    }
}

test "a splitting mass shrinks toward a note's size as it fades" {
    const gpa = testing.allocator;
    const links = try chainLinks(gpa, 1200);
    defer gpa.free(links);
    var w = try World.init(gpa, 1200, links, &.{}, .{}, .{});
    defer w.deinit();

    const view: View = .{ .w = 900, .h = 600, .zoom = 14, .cx = 0, .cy = 0 };
    const p: Params = .{};
    // settle closed, so masses are drawn at full radius
    try settle(&w, view, p, 300);

    // find a mass that is about to open, and record its resting radius
    var target: u32 = fold.invalid;
    var full_r: f32 = 0;
    for (w.marks.items) |m| {
        if (!m.is_note and w.open[m.cell]) {
            target = m.cell;
            full_r = m.r;
            break;
        }
    }
    if (target == fold.invalid) return; // nothing splitting at this zoom; nothing to assert

    // part-way through the crossfade it must be smaller than at rest, and never below a note
    var saw_smaller = false;
    for (0..8) |_| {
        try w.step(view, p, 1.0 / 60.0);
        for (w.marks.items) |m| {
            if (m.cell != target) continue;
            try testing.expect(m.r <= full_r + 0.001);
            try testing.expect(m.r >= p.note_r_px - 0.001);
            if (m.r < full_r - 0.5) saw_smaller = true;
        }
    }
    try testing.expect(saw_smaller);
}

test "topology does not depend on animation state" {
    // The contract: given (tree, view, zoom, budget) the open set is determined; motion only
    // interpolates. Breaking it is what made cells vanish instead of splitting and made edges pop
    // — the budget was counted over marks, which only exist while fading, so the decision read its
    // own output. Here: a fully-settled field and a field mid-crossfade must agree exactly.
    const gpa = testing.allocator;
    const links = try chainLinks(gpa, 3000);
    defer gpa.free(links);
    var w = try World.init(gpa, 3000, links, &.{}, .{}, .{});
    defer w.deinit();

    const view: View = .{ .w = 900, .h = 600, .zoom = 12, .cx = 0, .cy = 0 };
    const p: Params = .{ .budget = 140 };
    try settle(&w, view, p, 300);
    const settled = try gpa.dupe(bool, w.open);
    defer gpa.free(settled);

    // slam every crossfade to a half-open state and step once more
    @memset(w.anim, 0.5);
    try w.step(view, p, 1.0 / 60.0);
    try testing.expectEqualSlices(bool, settled, w.open);

    // and from cold, with a single huge dt
    @memset(w.anim, 0);
    try w.step(view, p, 10.0);
    try testing.expectEqualSlices(bool, settled, w.open);
}

test "the lifted link set is stable at a parked camera" {
    const gpa = testing.allocator;
    const links = try chainLinks(gpa, 2500);
    defer gpa.free(links);
    var w = try World.init(gpa, 2500, links, &.{}, .{}, .{});
    defer w.deinit();

    const view: View = .{ .w = 900, .h = 600, .zoom = 10, .cx = 0, .cy = 0 };
    const p: Params = .{};
    try settle(&w, view, p, 300);
    try w.liftLinks(p, 1.0);
    const first = try gpa.dupe(LiftedLink, w.links.items);
    defer gpa.free(first);
    try testing.expect(first.len > 0);

    for (0..30) |_| {
        try w.step(view, p, 1.0 / 60.0);
        try w.liftLinks(p, 1.0);
        try testing.expectEqual(first.len, w.links.items.len);
        for (first, w.links.items) |a, b| {
            try testing.expectEqual(a.a, b.a);
            try testing.expectEqual(a.b, b.b);
        }
    }
}

test "the cell-web lift matches a brute-force note-level lift" {
    // The invariant behind `cellweb.zig`: reading the precomputed cell adjacency from the cut must
    // produce exactly the web that mapping every note-level edge onto its owning cell produces.
    // That brute force *was* the implementation, and it cost O(E) every frame.
    //
    // This test earns its keep: the first cell-web version picked a pair's owning side by comparing
    // ladder levels, which silently lost ~23% of the links at some zooms. Nothing else caught it —
    // marks were identical, there was no seam, and every other test here still passed.
    const gpa = testing.allocator;
    const n: u32 = 1500;
    var prng = std.Random.DefaultPrng.init(0x5EED);
    const rnd = prng.random();
    var edges: std.ArrayListUnmanaged(fold.Edge) = .empty;
    defer edges.deinit(gpa);
    // A chain for connectivity plus random chords, so the ladder is neither a clean tree nor
    // level-uniform — which is the case the level-comparison version got wrong.
    for (0..n - 1) |i| try edges.append(gpa, .{ .a = @intCast(i), .b = @intCast(i + 1), .w = 1 });
    for (0..1200) |_| try edges.append(gpa, .{
        .a = rnd.uintLessThan(u32, n),
        .b = rnd.uintLessThan(u32, n),
        .w = 1,
    });

    var w = try World.init(gpa, n, edges.items, &.{}, .{}, .{});
    defer w.deinit();

    // No caps, so this compares the lift itself rather than two truncations of it.
    const p: Params = .{
        .budget = 280,
        .link_budget = std.math.maxInt(usize),
        .link_scan_cap = std.math.maxInt(usize),
    };

    var zoom: f32 = 0.4;
    while (zoom < 300) : (zoom *= 1.9) {
        try settle(&w, .{ .w = 900, .h = 600, .zoom = zoom, .cx = 0, .cy = 0 }, p, 200);
        try w.liftLinks(p, 1.0);

        // Brute force, over the same cut: every edge onto the cut cell owning each endpoint.
        var want: std.AutoHashMapUnmanaged(u64, f32) = .empty;
        defer want.deinit(gpa);
        for (edges.items) |e| {
            const la = w.lad.leaf_cell[e.a];
            const lb = w.lad.leaf_cell[e.b];
            if (la == fold.invalid or lb == fold.invalid) continue;
            const ca = w.cutOf(la) orelse continue;
            const cb = w.cutOf(lb) orelse continue;
            if (ca == cb) continue;
            const key = (@as(u64, @min(ca, cb)) << 32) | @as(u64, @max(ca, cb));
            const gop = try want.getOrPut(gpa, key);
            gop.value_ptr.* = (if (gop.found_existing) gop.value_ptr.* else 0) + e.w;
        }

        try testing.expectEqual(want.count(), w.links.items.len);
        for (w.links.items) |l| {
            const key = (@as(u64, @min(l.a, l.b)) << 32) | @as(u64, @max(l.a, l.b));
            const expect = want.get(key) orelse return error.LiftedPairNotInBruteForce;
            try testing.expectApproxEqAbs(expect, l.w, 1e-3);
        }
    }
}

test "leaf_pitch matches the geometry it claims to describe" {
    // A caller matching an existing lattice divides its slot spacing by `leaf_pitch` to get
    // `note_r`. If the constant drifts from the real geometry the whole vault comes out at the
    // wrong scale — which reads as a speck at the centre of the view, with every LOD transition
    // crammed into a sliver of the zoom range.
    const gpa = testing.allocator;
    const edges = try gpa.alloc(fold.Edge, 6);
    defer gpa.free(edges);
    for (0..6) |i| edges[i] = .{ .a = 0, .b = @intCast(i + 1) };

    var lad = try fold.build(gpa, 7, edges, &.{}, .{ .arity = .seven });
    defer lad.deinit(gpa);
    var f = try containment.init(gpa, lad.cells.len, lad.roots.len, .seven, .{ .note_r = 1 });
    defer f.deinit(gpa);
    containment.placeAll(&f, &lad);

    // nearest neighbour distance among the leaves of a full cell
    var best: f32 = std.math.floatMax(f32);
    for (lad.cells, 0..) |a, ia| {
        if (a.note == fold.invalid) continue;
        for (lad.cells, 0..) |b, ib| {
            if (ib <= ia or b.note == fold.invalid) continue;
            const d = containment.Vec2.dist(f.pos[ia], f.pos[ib]);
            if (d > 1e-4) best = @min(best, d);
        }
    }
    try testing.expectApproxEqAbs(leaf_pitch, best, 0.05);
}

test "an empty vault does not crash" {
    const gpa = testing.allocator;
    var w = try World.init(gpa, 0, &.{}, &.{}, .{}, .{});
    defer w.deinit();
    try w.step(.{ .w = 800, .h = 600, .zoom = 1, .cx = 0, .cy = 0 }, .{}, 1.0 / 60.0);
    try testing.expectEqual(@as(usize, 0), w.marks.items.len);
}

test "clipSegment keeps what crosses the rect and drops what misses" {
    // Wholly inside: unchanged.
    {
        const c = clipSegment(10, 10, 90, 90, 0, 0, 100, 100).?;
        try testing.expectApproxEqAbs(@as(f32, 10), c[0], 0.001);
        try testing.expectApproxEqAbs(@as(f32, 90), c[2], 0.001);
    }
    // One end outside: cropped at the edge, near end untouched. This is the focused-note case —
    // a link heading off to a neighbour the camera cannot see, which must read as going somewhere
    // rather than as absent.
    {
        const c = clipSegment(50, 50, 500, 50, 0, 0, 100, 100).?;
        try testing.expectApproxEqAbs(@as(f32, 50), c[0], 0.001);
        try testing.expectApproxEqAbs(@as(f32, 100), c[2], 0.001);
    }
    // Both ends outside but crossing: the middle survives.
    {
        const c = clipSegment(-50, 50, 150, 50, 0, 0, 100, 100).?;
        try testing.expectApproxEqAbs(@as(f32, 0), c[0], 0.001);
        try testing.expectApproxEqAbs(@as(f32, 100), c[2], 0.001);
    }
    // Both ends outside on the same side: nothing to draw.
    try testing.expect(clipSegment(-50, 50, -10, 50, 0, 0, 100, 100) == null);
    // Parallel and outside: the `pv == 0` branch must reject rather than divide by zero.
    try testing.expect(clipSegment(-10, 200, 110, 200, 0, 0, 100, 100) == null);
    // Degenerate: a zero-length segment has no interior to keep.
    try testing.expect(clipSegment(50, 50, 50, 50, 0, 0, 100, 100) == null);
}
