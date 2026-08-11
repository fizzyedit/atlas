//! Graph bottom panel — full vault note web.
//!
//! Hand-rolled canvas (not `CanvasWidget`): own `Camera`, draw nodes as paint calls, process
//! events after drawing. Layout writes `target`; proximity writes `pos`/`hover_t`; draw and
//! hit-test read `pos` and a **screen-constant** bubble radius (pixi sprite-bubble idiom).
//!
//! Nodes grow/shrink from mouse proximity, softly space out neighbors, and reveal fixed-size
//! labels. Zooming in also swells nodes and fades labels in (map-style detail reveal).
//!
//! Which names actually get drawn is a separate decision from how much the reader wants them:
//! `updateLabels` runs `labels.Placer` over the revealed nodes in priority order and suppresses
//! whatever won't fit. Spacing nodes apart can't save a title ten times wider than its bubble,
//! so the graph shows fewer names rather than a legible-looking smear of overlapping ones.
//!
//! Everything sits on the hex lattice in `hex.zig`: `dotgrid` paints it as a zoom-aware dot
//! background and `layout_full` force-places linked notes near each other then snaps them
//! onto the lattice, so a node always lands dead centre on a dot. When the index changes,
//! nodes ease from their old home to the new one. Links animate out from their source note
//! on connect and retract on disconnect; the node under the cursor takes the hand cursor
//! and a button-style highlight.
const std = @import("std");
const dvui = @import("dvui");
const core = @import("core");
const sdk = @import("fizzy_sdk");
const icons = @import("icons");

const runtime = @import("../runtime.zig");
const State = @import("../State.zig");
const query = @import("../index/query.zig");
const content_graph = @import("content_graph");
const Indexer = @import("../index/Indexer.zig");
const Camera = @import("camera.zig");
const dotgrid = @import("dotgrid.zig");
const focus = @import("focus.zig");
const hex = @import("hex.zig");
const interior = @import("interior.zig");
const labels = @import("labels.zig");
const layout_full = @import("layout_full.zig");
const multilevel = @import("multilevel.zig");
const galaxy = @import("galaxy.zig");
const world_mod = @import("world.zig");
const world_draw = @import("world_draw.zig");

/// A note the frame resolved as an individual, published by `stepWorld` and consumed by the label
/// placer, the proximity field and hit-testing. `level` is vestigial — everything drawn as itself
/// is level 0 now — but the passes that read it are shared with the interior, so it stays.
const Visible = struct {
    level: u32,
    index: u32,
    alpha: f32,
};
const fold = @import("fold.zig");
const proximity = @import("proximity.zig");
const resolve = @import("../index/resolve.zig");

const Fling = core.Fling;

pub const view_id = "atlas.graph";

/// World-space layout radius (hex-spiral packing). Distinct from the on-screen bubble size.
const min_node_r: f32 = 14;
const max_node_r: f32 = 36;
const open_node_r: f32 = 34;

/// On-screen bubble radii — constant across zoom, like pixi's `/ canvas.scale` buttons.
const base_screen_r: f32 = 9;

/// Interior content. A document is its own fold/containment/world cloud — the same machinery the
/// vault overview uses, fed the note's headings/paragraphs/lists/tags/embeds instead of the
/// vault's notes (see `buildInteriorWorld`). The document itself (item 0, the "sun") is pinned at
/// the cloud's centre outside that system entirely, so it can never be coalesced away.
/// How fast an open note's links reach out to their neighbours, in multiples of full length per
/// second.
const select_reach_rate: f32 = 2.6;

/// Draw-time size multiplier by content kind, layered on top of `bubbleScreenRadius`'s base
/// sizing. Carries the same role-by-size language the old orbit system used (sun > heading >
/// body > tag/embed) without feeding layout — see `content_graph.Item.weight`'s doc comment.
fn contentKindRadiusMul(kind: content_graph.ItemKind) f32 {
    return switch (kind) {
        .root => 1.35,
        .heading => 0.85,
        .paragraph, .list, .code, .blockquote, .table => 0.55,
        .tag, .embed => 0.36,
    };
}
const open_screen_r: f32 = 12;
/// Hard cap — high enough that full hover (~2×) isn't flattened by the clamp.
const max_node_screen_r: f32 = 48;
/// Interior document sun, at rest: pinned to the largest an overview node ever renders (its own
/// hover cap), not a smaller resting size that grows on approach. The sun *is* the node you just
/// clicked — however large it looked at the moment of the click, it should read as exactly that
/// large the instant the descent begins, not snap down to some other resting size and grow back.
const sun_screen_r: f32 = max_node_screen_r;
const max_sun_screen_r: f32 = 58;
/// Proximity grow: `+ grow_factor` at full hover (1.0 = double resting size).
const grow_factor: f32 = 1.0;
/// The same for a merged region, which is drawn at the size of the area it covers rather than at
/// a fixed target size — so it needs far less growth to read as picked out, and much more would
/// bury the regions around it.
const cluster_grow_factor: f32 = 0.18;
/// Sun grows more than a section bubble — approaching the exit should feel generous.
const sun_grow_factor: f32 = 1.45;
/// Screen-space falloff for mouse influence at overview zoom.
const proximity_falloff_px: f32 = 100;
/// Extra falloff multiplier once fully zoom-revealed (more sensitive close-up hover).
const proximity_falloff_zoom_boost: f32 = 1.75;
/// Extra screen-px gap neighbors try to keep from a swollen node.
const neighbor_gap_px: f32 = 6;
/// How hard grown nodes shove neighbors aside (0–1). The hovered node itself stays put.
const neighbor_push: f32 = 0.85;
/// Furthest a swollen node may shove anything, in lattice cells. Node radii are screen sizes
/// divided by zoom, so without this the reach grows without bound as the camera pulls out — see
/// the shove pass in `applyProximity`. Two cells is comfortably more than a bubble ever needs
/// and keeps the effect reading as "nudge the neighbours", never "part the vault".
const max_shove_slots: f32 = 2.0;
/// Same idea for the hover field itself: `falloff_px / zoom` is unbounded as the camera pulls
/// out, so without a cap a dense overview puts thousands of notes inside the cursor's influence
/// and the chase keeps the panel repainting at ~20fps. A few lattice cells is already more than
/// a readable neighbourhood.
const max_hover_slots: f32 = 6.0;
/// Below this `detailRevealT`, proximity is off. The swell exists so names stay readable under
/// the cursor; once notes are too small for that, animating them is pure cost.
const proximity_min_reveal: f32 = 0.2;
/// Chase rate for hover_t (1/s). Higher = snappier.
const hover_chase_k: f32 = 14;
/// Chase rate for the button-style pointer highlight (1/s). Snappier than the proximity
/// swell — this one is a direct answer to "the cursor is on me", so it should feel instant.
const pointer_chase_k: f32 = 22;
/// Chase rate for layout home → target (1/s). Slower than hover so the web "breathes" into
/// a new configuration instead of snapping.
const layout_chase_k: f32 = 5.5;
/// Seconds for a link to extend from its source node to its target (and to retract again).
const edge_grow_s: f32 = 0.64;
/// Seconds for a highlight to sweep the length of a link when its note is opened. Still quicker
/// than a link forming — nothing is being created, and the sweep answers a click the reader just
/// made — but slow enough to actually be watched, which is the point of showing it at all.
const edge_lit_s: f32 = 0.44;
/// Chase rate for camera retargets (1/s) — focus, zoom-extents, resize refits.
const camera_chase_k: f32 = 7;
/// Screen padding for the focus frame, capped against short panels.
const focus_padding_px: f32 = 56;
/// On-screen px between lattice neighbours a focus will not zoom *in* past — the close-up
/// ceiling for a small selection. Zoom-*out* is floored at the extents pose instead: a focus
/// never pulls further back than the center/maximize button, even when the open set spans the
/// vault.
const focus_max_gap_px: f32 = 300;
/// Inner shadow along the panel edges — the pixi viewport idiom. The web reads as sliding
/// *under* the panel border instead of being sheared off flat at it, which is most of what
/// makes a viewport feel like a window onto something bigger.
const edge_shadow_depth: f32 = 18;
const edge_shadow_alpha_dark: f32 = 0.2;
const edge_shadow_alpha_light: f32 = 0.12;
/// Node drop shadow — same disc offset down/right, faded out. Values track dvui's
/// `Options.BoxShadow` defaults; that struct only applies to widget rects, not paths.
const shadow_offset: f32 = 1.5;
const shadow_fade: f32 = 4.0;
const shadow_alpha: f32 = 0.35;
/// Smallest node radius (screen px) still worth drawing a shadow under. Below this the offset
/// and fade are swallowed by the disc's own edge — see `drawNodes`.
const shadow_min_r: f32 = 6.0;
/// Fill alpha of the interior sun — see `nodeFill`.
const sun_fill_opacity: f32 = 0.5;
/// Labels use a fixed natural font size regardless of camera zoom.
const label_font_delta: f32 = -1;
/// Chase rate for a label winning or losing its slot (1/s). Deliberately slower than the
/// pointer highlight — text popping in and out is far more distracting than a disc brightening.
const label_chase_k: f32 = 9;
/// Natural px between a bubble and its label.
const label_gap: f32 = 3;
/// Separation demanded between two labels. Slightly *negative* on purpose: labels draw as
/// bare text with no plate behind them, and a text rect is a line box — it carries leading
/// above and below that no glyph reaches into. Letting rects graze by a pixel or so costs
/// nothing visually and buys a noticeable number of extra names.
const label_slack: f32 = -1.5;
/// Width at which a label that could not be placed at all is retried ellipsised (natural px).
/// Not a cap on normal labels: a full name is always tried first and only clipped when it has
/// nowhere to go, so ellipsis is a last resort rather than the default.
const label_max_w: f32 = 132;
/// Ceiling on labels placed in one frame. A panel only holds so many readable names, and this
/// is what bounds the placer's linear collision scan.
const max_labels: usize = 96;
/// Ceiling on bubbles reserved against. Past this the extra discs go unprotected — at that
/// density nothing is winning a label slot anyway.
const max_reserved_bubbles: usize = 384;
/// Reveal below which a label isn't worth placing (it would draw at near-zero alpha).
const label_reveal_min: f32 = 0.12;
/// Bubble reserve is deflated slightly: a glyph grazing an antialiased rim still reads, and
/// protecting the full disc costs a lot of otherwise-usable slots.
const bubble_reserve_scale: f32 = 0.9;
/// Detail reveal is driven by *on-screen* layout spacing (`layout_slot * zoom`), not raw
/// camera zoom — so extents on a big vault can still show names when nodes are a
/// comfortable gap apart, and a tiny vault zoomed in doesn't wait on absolute zoom units.
/// Values are physical pixels between adjacent layout cells.
const detail_gap_lo: f32 = 34;
const detail_gap_hi: f32 = 64;
/// Floor for on-screen px between lattice neighbours that fit-to-extents will not zoom past.
/// Used as the *minimum* ceiling — large panes raise it further via `fitMaxGapPx` so a small
/// cloud still fills most of a big window instead of sitting in an ocean of empty grid.
///
/// Deliberately *not* shared with `focus_max_gap_px`, though it was. Tying them together meant a
/// focus could never be closer than the overview's own ceiling, so on any vault whose extents
/// already fit inside that ceiling — which is most of them — clicking a note computed the pose the
/// camera was already at and nothing happened. The overview and a focus are opposite intents and
/// want opposite limits: one is "don't zoom in absurdly far on an empty vault", the other is
/// "this is a close-up".
const fit_max_gap_px: f32 = 150;
/// Fraction of the short pane side that fit-to-extents may use as a neighbour-gap ceiling.
/// Dominates `fit_max_gap_px` once the pane is taller/wider than a few hundred px.
const fit_max_gap_frac: f32 = 0.26;
/// Screen room fit-to-extents keeps between the outermost node's *centre* and the panel edge:
/// enough for the bubble itself, which is drawn at a fixed pixel size, plus a little air so the
/// web doesn't read as clipped. Pixels are the honest unit here — see `fitToNodes`.
const fit_edge_px: f32 = open_screen_r + 7;
/// Same, for when the fitted zoom is close enough in to be drawing labels: a label hangs off the
/// bubble rather than adding to it, so this *replaces* `fit_edge_px` and is not added to it.
const fit_label_px: f32 = open_screen_r + label_gap + 15;
/// Target edge margin as a fraction of the short pane side. Higher → zoom-to-extents sits a
/// little further out so outermost nodes aren't tight against the window.
const fit_pad_frac: f32 = 0.16;
/// Resting size boost from zoom alone (additive scale), before proximity stacks on top.
const zoom_rest_swell: f32 = 0.35;
/// Largest a node may be relative to the on-screen gap between lattice cells. Under a half, so
/// two neighbours always have air between them — see `bubbleScreenRadius`.
const gap_radius_frac: f32 = 0.42;
const pan_fling_tuning: Fling.Tuning = .{
    .decay = 4.0,
    .min_start = 80,
    .stop = 40,
    .max = 4000,
    .idle_s = 0.1,
};
const pan_fling_window_s: f32 = 0.08;

const GraphNode = struct {
    note_id: i64,
    /// 0-based source line for interior section nodes (`revealPosition`). Overview notes leave
    /// this at 0 — they open the file, they don't scroll inside it.
    line: u32 = 0,
    /// Interior document root — empty fill, dashed ring, pinned at the cloud's centre.
    is_sun: bool = false,
    path: []const u8,
    title: []const u8,
    phantom: bool,
    degree: u32,
    /// Order-independent hash of this note's neighbours, by *note id* — see `linkSignatures`.
    /// Compared against the next rebuild's to decide whether this node has any reason to move.
    link_sig: u64 = 0,
    /// One step of undo history: the signature this node had before `link_sig`, and the cell it
    /// occupied then. Typing a link and deleting it again has to leave the node where it began,
    /// and the layout can't work that out on its own — it only ever sees the current graph, so
    /// "back where it was" is information only the previous rebuild had. See `rebuildIfNeeded`.
    prev_sig: u64 = 0,
    prev_target: dvui.Point = .{},
    prev_valid: bool = false,
    open: bool = false,
    /// `open` as of the previous `applyOpenSet`. The camera reacts to the *transition* — a
    /// reindex of an already-open note must not re-fly the view.
    was_open: bool = false,
    /// Hex cell the layout wants this note on. Set on rebuild; `home` eases toward it.
    target: dvui.Point = .{},
    target_radius: f32 = min_node_r,
    /// Settled-ish layout position (chases `target`). Proximity shove is applied on top
    /// into `pos`, so hover offsets don't fight the layout animation.
    home: dvui.Point = .{},
    /// Drawn / hit-tested position = `home` + proximity shove.
    pos: dvui.Point = .{},
    radius: f32 = min_node_r,
    alpha: f32 = 1,
    hover_t: f32 = 0,
    /// Button-style highlight: 1 only for the single node actually under the cursor.
    /// Distinct from `hover_t`, which is the soft proximity falloff over many neighbours.
    pointer_t: f32 = 0,
    focus_t: f32 = 0,

    /// Label placement, re-resolved every frame by `updateLabels`.
    ///
    /// `label_vis` is a 0/1 chase on "the placer found room for my name", kept separate from
    /// the reveal fade (hover/zoom) so a *suppressed* label eases out instead of blinking.
    /// `label_slot` is fed back in as the sticky preference so a settled label doesn't hop
    /// sides while its neighbours breathe.
    label_vis: f32 = 0,
    label_slot: labels.Slot = .below,
    label_rect: dvui.Rect.Physical = .{},
    /// Bytes of `title` that fit; `label_ellipsis` appends the "…" at draw time. A length
    /// rather than a slice, so this never points at the frame arena.
    label_len: usize = 0,
    label_ellipsis: bool = false,
};

/// `a` is the link *source* — edges grow outward from it, so direction is not incidental.
const GraphEdge = struct { a: usize, b: usize };

/// Per-node hash of "who am I linked to", used to decide which nodes the layout may hold still.
///
/// Keyed on **note ids**, not graph indices, for the same reason `EdgeKey` is: indices shift
/// whenever any note is added or removed, so an index-based signature would report that every
/// node's links changed the moment the vault grew — which is exactly the false positive that
/// would make anchoring useless.
///
/// Order-independent, because adjacency order follows edge order and that is not meaningful.
/// Summed rather than xored so a note linked to the same target twice doesn't cancel itself out.
/// The node's own id is mixed in so two notes with identical neighbours still differ, and
/// `phantom` because a phantom being promoted to a real note is a change worth re-solving for.
fn linkSignatures(
    arena: std.mem.Allocator,
    n: usize,
    order: []const usize,
    snap_nodes: []const Indexer.SnapNode,
    edges: []const GraphEdge,
) ![]u64 {
    const sigs = try arena.alloc(u64, n);
    for (order, 0..) |si, gi| {
        const info = snap_nodes[si];
        var s = mix64(@bitCast(info.id));
        if (info.phantom) s ^= 0x9e3779b97f4a7c15;
        sigs[gi] = s;
    }
    for (edges) |e| {
        if (e.a >= n or e.b >= n) continue;
        sigs[e.a] +%= mix64(@bitCast(snap_nodes[order[e.b]].id));
        sigs[e.b] +%= mix64(@bitCast(snap_nodes[order[e.a]].id));
    }
    return sigs;
}

fn mix64(v: u64) u64 {
    var h = v;
    h ^= h >> 33;
    h *%= 0xff51afd7ed558ccd;
    h ^= h >> 33;
    h *%= 0xc4ceb9fe1a85ec53;
    h ^= h >> 33;
    return h;
}

/// Identity of a link that survives rebuilds. Note ids, not node indices: indices shift
/// whenever a note is added or removed, and an animation keyed on them would jump.
const EdgeKey = struct { a: i64, b: i64 };

/// Connect/disconnect animation for one link. `t` runs 0 → 1 while extending and back to 0
/// while retracting; `from`/`to` cache the last known world endpoints so a link whose note
/// has already vanished can still animate its way out.
const EdgeAnim = struct {
    t: f32 = 0,
    /// Refreshed on every rebuild. False means the link is gone and should retract.
    alive: bool = true,
    from: dvui.Point = .{},
    to: dvui.Point = .{},
    /// How far the *lit* copy of this link has swept, 0‥1. A separate channel from `t` on
    /// purpose: `t` is whether the link exists, and reusing it would make clicking a note look
    /// like every link it has was created by the click, and would fight a retraction already
    /// under way. The dim web keeps drawing at full length underneath, so this is a highlight
    /// running along a line that is already there rather than the line itself growing.
    lit: f32 = 0,
    /// Which end the sweep starts from — the note that was opened. A highlight that crawls
    /// *into* the note you just clicked reads backwards; it should leave from it, the way the
    /// eye is already travelling.
    lit_from_a: bool = true,
};

/// What the camera is currently framing. Kept so a panel resize can re-apply the same intent
/// instead of falling back to the whole web — dragging the splitter after clicking a note used
/// to throw the focus flight away and snap to extents.
const Framing = union(enum) {
    extents,
    /// Note id, not an index: indices shift on every rebuild.
    note: i64,
    /// Descended into a note: centred on its node and zoomed to where its own lattice is
    /// readable. Distinct from `.note` because a focus frames a note *among its neighbours*,
    /// which is an overview pose — this one is all the way inside.
    interior: i64,
    /// The user panned or zoomed by hand. Nothing re-derives the pose from here — a resize or
    /// a reindex must not yank the view back off a place they went to deliberately. Opening or
    /// closing a note takes control back.
    free,
};

const Touch = struct {
    active: bool = false,
    p: dvui.Point.Physical = .{},
};

/// The note the view has descended into, and the cloud of its own sections.
///
/// Lives alongside the overview rather than replacing it: both are drawn at once for the whole
/// descent, cross-fading past each other, which is what makes the transition read as zooming
/// *into* a node instead of cutting to a different screen. See `interior.zig` for the geometry.
const Interior = struct {
    arena: std.heap.ArenaAllocator,
    /// Note whose sections are laid out here, or null at overview.
    note_id: ?i64 = null,
    /// What the cloud was built from. Any of these moving means it has to be rebuilt: the vault
    /// reindexed, a different note was opened, or the panel changed shape under it.
    built_id: i64 = 0,
    built_gen: u64 = std.math.maxInt(u64),
    built_aspect: f32 = 0,
    /// A note whose cloud could not be built (no sections, no row, no db) at `fail_gen`. Kept so
    /// a hand-driven descent that lands on one doesn't re-attempt the same synchronous layout
    /// every frame — the picker skips it until the index moves under us.
    fail_id: ?i64 = null,
    fail_gen: u64 = std.math.maxInt(u64),
    nodes: []GraphNode = &.{},
    edges: []GraphEdge = &.{},
    nest: interior.Nest = .{ .steps = 0, .scale = 1, .level = 0, .clamped = false },
    /// Local (pre-`nest`/`parent`) position per node, indexed exactly like `nodes`
    /// (`local_pos[0]` unused — the sun is pinned directly at `parent`, not placed in this space).
    /// An "asteroid field": angle is document order swept clockwise around the full circle, radius
    /// is outline depth — headings on inner rings, their own paragraphs/lists/tags/etc a band
    /// further out, deeper headings further still. No containment/fold packing: that algorithm is
    /// built for a tree with real branching, and a typical document's headings are closer to a
    /// flat chain (weakly tied only by document order) than a tree, which packed as a long curling
    /// spiral rather than anything resembling "shape and grouping" — see `buildInteriorWorld`.
    /// Panel-arena owned.
    local_pos: []dvui.Point = &.{},
    /// Content kind per node, indexed exactly like `nodes` (`item_kind[0] == .root`). Panel-arena
    /// owned — drives `contentKindRadiusMul` at draw time.
    item_kind: []content_graph.ItemKind = &.{},
    /// World position of the parent note's own node — the point the cloud is centred on, so the
    /// node and its interior share an origin and the descent has nothing to slide sideways.
    parent: dvui.Point = .{},
    /// Interior lattice spacing in world units, for label reveal and bubble sizing.
    slot: f32 = 0,
    /// World-space radius of the nested cloud, which is what decides how much of the panel it
    /// covers and so how far into the descent the view is.
    radius: f32 = 0,
    /// 0 at overview, 1 when the interior fills the panel. Recomputed every frame from the
    /// camera alone, never accumulated — that is what makes the transition reversible.
    t: f32 = 0,
    /// Last frame's `t`, so `wantsRepaint` can tell a descent that is still arriving from one
    /// that has arrived as far as it is ever going to.
    t_prev: f32 = 0,

    fn deinit(self: *Interior) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// Forget the cloud without dropping the arena's pages — descending again reuses them.
    fn clear(self: *Interior) void {
        _ = self.arena.reset(.retain_capacity);
        self.note_id = null;
        self.built_id = 0;
        self.built_gen = std.math.maxInt(u64);
        self.nodes = &.{};
        self.edges = &.{};
        self.local_pos = &.{};
        self.item_kind = &.{};
        self.t = 0;
        self.t_prev = 0;
    }
};

/// A graph rebuild in flight on a worker thread.
///
/// The solve (`layout_full.targets`) is the one part of a rebuild that scales badly with vault
/// size — seconds on a large vault even after the near-field grid work — and it used to run
/// inside `draw`, which is why opening a big folder froze the whole editor rather than the
/// panel. Everything a rebuild needs is prepared into `arena` up front, the worker solves into
/// `targets`, and the UI thread finishes the job on a later frame.
///
/// The panel's own arena is deliberately *not* reset when a job starts. The previous
/// arrangement stays live and keeps drawing until the new one is ready, so a reindex on an
/// already-open graph never blanks the view.
///
/// Ownership: prep runs on the UI thread and finishes before the thread is spawned; nothing
/// touches `arena` while `done` is false. That is what makes a plain (non-threadsafe) arena
/// safe here.
const LayoutJob = struct {
    arena: std.heap.ArenaAllocator,
    thread: ?std.Thread = null,
    done: std.atomic.Value(bool) = .init(false),
    /// Set by the worker when the solve fails; re-raised on the UI thread at apply time.
    fail: ?anyerror = null,

    /// What this rebuild was for — checked at apply time, since the vault can move underneath.
    gen: u64,
    open_hash: u64,
    first_build: bool,
    reshape: bool,
    aspect: f32,
    prior_slot: ?f32,

    /// Snapshot copy and the draw order over it; both live in `arena`.
    snap: Indexer.Snapshot,
    order: []usize,

    n: usize,
    edges: []GraphEdge,
    layout_edges: []layout_full.Edge,
    seeds: []?dvui.Point,
    degrees: []u32,
    anchored: []bool,
    paths: [][]const u8,
    sigs: []u64,
    hist_sig: []u64,
    hist_target: []dvui.Point,
    hist_valid: []bool,
    changed: []bool,

    targets: []dvui.Point,
    /// When set (synth scale vault), skip `layout_full` and copy these into `targets`.
    /// Parallel to graph indices (id-sorted notes). Lives in `arena`.
    precomputed: ?[]const dvui.Point = null,
    /// Coarsening hierarchy from the solve, which `pyramid` is built from. Lives in `arena`.
    ladder: multilevel.Ladder = .{},
    /// Level-of-detail hierarchy over the solved positions, ready to hand to the panel.
    ///
    /// Built on the worker rather than at apply time, and owning its own memory rather than
    /// borrowing an arena, because it is the largest piece of per-rebuild work left: it walks
    /// every note once per level and coalesces the whole link set the same way. That is fine in
    /// the background and a visible stall on the frame that applies the rebuild.
    /// Quadtree built on the worker for precomputed (synth) jobs so the UI thread only adopts.

    fn run(job: *LayoutJob) void {
        job.solve() catch |e| {
            job.fail = e;
        };
        job.done.store(true, .release);
    }

    fn solve(job: *LayoutJob) !void {
        if (job.precomputed) |pos| {
            if (pos.len != job.n) return error.SynthPosLen;
            @memcpy(job.targets, pos);
            return;
        }

        // Level-of-detail hierarchy, built here rather than taken from the layout: `targets`
        // only produces one when it takes the multilevel path (a full repack), and the view
        // needs the levels on *every* rebuild — otherwise LOD blinks out the moment anything is
        // indexed or edited, which is most of the time while a vault is first being read.
        const ml_edges = try job.arena.allocator().alloc(multilevel.Edge, job.layout_edges.len);
        var m: usize = 0;
        for (job.layout_edges) |e| {
            if (e.a >= job.n or e.b >= job.n or e.a == e.b) continue;
            ml_edges[m] = .{ .a = @intCast(e.a), .b = @intCast(e.b) };
            m += 1;
        }
        job.ladder = try multilevel.coarsen(job.arena.allocator(), job.n, ml_edges[0..m]);

        try layout_full.targets(job.arena.allocator(), job.n, job.layout_edges, job.seeds, job.degrees, .{
            .anchored = job.anchored,
            .prior_slot = job.prior_slot,
            .aspect = job.aspect,
            .reshape_only = job.reshape,
            .paths = job.paths,
        }, job.targets);

        // From the *final* positions: packing and snapping move notes after the ladder exists,
        // and a marker has to sit where its notes actually ended up.
        //
    }

    fn deinit(job: *LayoutJob, gpa: std.mem.Allocator) void {
        if (job.thread) |t| t.join();
        // Only reached if nobody took it — an abandoned solve, or one that failed after this
        // point. `finishRebuild` clears the field when it adopts it.
        job.arena.deinit();
        gpa.destroy(job);
    }
};

/// Vaults at or below this solve inline. Handing a small graph to a worker costs a frame of
/// latency and gains nothing, and keeping the inline path means the common case never has to be
/// reasoned about as concurrent.
///
/// Sized from measurement, not caution: since the multilevel solver landed, 5k notes solve in
/// roughly 50ms and 100k in about 2.5s. 4000 is comfortably inside one frame's budget on the
/// machines this runs on, and it covers most real vaults outright.
const layout_inline_max: usize = 4000;

/// How long the index has to hold still before a large vault re-solves. See `rebuildIfNeeded`.
///
/// Long enough to swallow the gap between commit batches during a vault read, short enough that
/// an edit still lands in the graph while the reader is looking at it.
const rebuild_quiet_s: f32 = 0.6;

const Panel = struct {
    arena: std.heap.ArenaAllocator,
    /// Rebuild being solved on a worker, if any. See `LayoutJob`.
    job: ?*LayoutJob = null,
    /// Level-of-detail hierarchy for the current arrangement, or null for a vault too small to
    /// have been solved multilevel. Allocated from `arena`, so it dies with the arrangement.
    /// Point-region quadtree for organic overview masses (`quad_agents`).
    gen: u64 = std.math.maxInt(u64),
    open_hash: u64 = std.math.maxInt(u64),
    nodes: []GraphNode = &.{},
    edges: []GraphEdge = &.{},
    /// id → index into `nodes` for hit/open updates without scanning.
    id_index: std.AutoHashMapUnmanaged(i64, usize) = .empty,
    note_count: u32 = 0,
    /// World-space radius of the whole web, from layout. Drives `proximityStrength`.
    world_radius: f32 = 0,
    /// World-space bounding box of the whole web. The label placer keeps names inside this
    /// silhouette, and reading it from layout keeps that boundary still while the view moves.
    world_bounds: dvui.Rect = .{},
    /// Layout lattice spacing used on the last rebuild. Passed back in as `prior_slot` so a
    /// level change can uniformly rescale seeds instead of dropping them onto a mismatched grid.
    layout_slot: f32 = 0,
    /// Bucketed panel proportions the cloud was packed into — see `layoutAspect`. A change here
    /// repacks, so it is deliberately coarse.
    layout_aspect: f32 = 0,
    /// Time-averaged raw panel ratio the bucket above is derived from. See `layoutAspect`.
    aspect_smooth: f32 = 0,
    /// Viewport size the settle counter is watching. Reshape waits until this stops moving.
    settle_vp_w: f32 = 0,
    settle_vp_h: f32 = 0,
    /// Frames the viewport has been unchanged. Reshape commits only after `aspect_settle_frames`.
    settle_frames: u16 = 0,
    /// Connected-component count from the last layout — HUD / "why didn't span move?" diagnosis.
    island_count: u32 = 0,
    camera: Camera = .{},
    framing: Framing = .extents,
    /// Viewport size we last fitted against. 0 means "never fitted with a real viewport".
    fitted_vp_w: f32 = 0,
    fitted_vp_h: f32 = 0,
    /// False while any node is still chasing its proximity target — drives continuous frames.
    proximity_settled: bool = true,
    /// False while any `home` is still easing toward its layout `target`.
    layout_settled: bool = true,
    /// False while any node's pointer highlight is still chasing.
    pointer_settled: bool = true,
    /// False while any link is still extending or retracting.
    edges_settled: bool = true,
    /// False while any label is still fading into or out of its slot.
    labels_settled: bool = true,
    /// A rebuild happened and the placer has not run since. Separate from every other reason to
    /// re-place, because it is the only one that is not about something *moving*: a rebuild
    /// reallocates the titles, so `label_len` — which indexes into them — is deliberately not
    /// carried, and a name with no length is not drawn at all. Everything else in the dirty test
    /// asks "has anything shifted", and after a keystroke the honest answer is no: the graph is
    /// the same shape, so nothing eases, nothing chases, and the placer would never run again.
    /// Every label in the vault would stay dark until the reader happened to move the camera.
    labels_stale: bool = false,
    /// Camera pose and panel rect the placer last ran against. A label's slot is stored in
    /// *screen* space, so anything that moves world→screen invalidates every placement even
    /// when nothing in the graph itself is moving — most visibly the pane sliding under a
    /// splitter drag, which translates the viewport without the camera going anywhere.
    labels_center: dvui.Point = .{},
    labels_zoom: f32 = 0,
    labels_vp: dvui.Rect.Physical = .{},
    /// Pane aspect changed and we're waiting for the splitter to hold still before reshaping.
    /// Drives `wantsRepaint` instead of a per-frame `dvui.refresh`, which could not sleep.
    aspect_waiting: bool = false,
    /// Index generation a coalesced rebuild is waiting on, and how long it has held still. See
    /// `rebuild_quiet_s`.
    pending_gen: u64 = std.math.maxInt(u64),
    pending_quiet_s: f32 = 0,
    /// True while a rebuild is being deliberately deferred — keeps frames coming so the quiet
    /// timer can actually run out, the same way `aspect_waiting` does.
    rebuild_waiting: bool = false,
    /// The one node directly under the cursor, if any. Drives the hand cursor and highlight.
    hover_node: ?usize = null,
    /// Eased hover weight for `hover_cluster`, and which region it belongs to. Kept on the panel
    /// rather than per cluster: only one region is ever under the cursor, and the hierarchy is
    /// rebuilt often enough that per-cluster state would not survive to be worth keeping.
    hover_cluster_t: f32 = 0,
    hover_cluster_prev: ?Visible = null,
    /// Bumped by every completed layout solve. The identity of the *arrangement*, as opposed to
    /// `gen`, which is the identity of the index behind it — the two come apart whenever a
    /// reshape re-solves the same notes into new positions.
    layout_epoch: u64 = 0,
    /// Offscreen texture holding the baked note field, tile by tile — see `impostor.zig`. Not in
    /// the panel arena: it outlives an arrangement deliberately, so the texture is created once
    /// rather than per rebuild, and it holds a GPU resource that has to be released by hand.
    /// Which drawing scales the field is shown at this frame, and how much each shows. Computed
    /// once by `updateSelection` before anything reads it, so the tiles, the notes drawn directly,
    /// the hierarchy and the web cannot disagree about the scale in force.
    tiles: TileView = .{},
    /// Set when the atlas was wiped, so the next frame rebuilds the view's pictures in one go
    /// rather than over several. See the end of `drawTiles`.
    bake_burst: bool = false,
    /// Last tile level whose visible set was fully baked. Held under the zoom's target level
    /// until that catches up — see `drawTiles`. Without this the field swaps from sharp vector
    /// marks to soft textures (and between levels) mid-zoom, which is the flash.
    tiles_hold: ?i32 = null,
    /// Arrangement `tiles_hold` belongs to. Cleared with the atlas when layout changes.
    tiles_hold_epoch: u64 = std.math.maxInt(u64),
    /// True while tiles are still baking toward the current zoom. Keeps frames coming.
    tiles_pending: bool = false,
    /// Cluster marker under the cursor, when the cursor is over a merged region rather than an
    /// individual note. Mutually exclusive with `hover_node` — only one of the two is drawn at
    /// any given place on screen.
    hover_cluster: ?Visible = null,
    /// The single level of detail the whole overview is drawn at this frame, as a fraction — see
    /// `lod.Pyramid.levelFor`. Set by `updateSelection` before anything reads it, and shared by
    /// the selection, the web, and the agent field so none of them can disagree about which
    /// level is on screen.
    lod_level: f32 = 0,
    /// Keep-alive coalesced masses for the overview — see `quad_agents.zig`. Owns mid/far
    /// continuity; impostor tiles step aside while this is active.
    /// Soft-sprite atlas + same-language density mips (Galaxy LOD).
    density: ?galaxy.Density = null,

    /// Containment path (`Settings.graph_layout == .containment`): one hierarchy from links +
    /// folder adjacency, positions derived from it, budgeted select. Runs *instead of* the
    /// classic layout/agents/tiles stack, not alongside it — see `drawWorldMarks`.
    world_state: ?world_mod.World = null,
    /// `layout_epoch` the world was last built against, so it rebuilds only when the graph does.
    world_epoch: u64 = std.math.maxInt(u64),
    /// 0→1 after the set of open notes changes, driving the open note's links growing outward.
    select_anim: f32 = 0,
    /// Hash of the open set the animation is currently showing, so it restarts on a real change
    /// rather than every frame.
    select_key: u64 = 0,

    /// `layout_epoch` the agent field was last reset against.
    agents_epoch: u64 = std.math.maxInt(u64),
    /// True when this frame's overview is drawn from `agent_field` rather than tiles/`select`.
    agents_active: bool = false,

    /// What the overview draws this frame: notes where they have separated enough to be told
    /// apart, cluster markers where they have not. Rebuilt every frame by `updateSelection`,
    /// and kept on the panel rather than the frame arena so its capacity survives.
    visible: std.ArrayList(Visible) = .empty,
    /// `visible`'s interior counterpart — which content nodes are drawn as themselves this frame,
    /// rebuilt every frame by `stepInteriorWorld`. Kept on the panel, not the interior's own arena,
    /// since that arena only survives a rebuild, not a frame.
    interior_visible: std.ArrayList(Visible) = .empty,
    /// Per node, whether it is being drawn as itself this frame. Read by the edge pass, which
    /// has no business drawing a link to a note that has been merged into a marker. Lives in the
    /// panel arena, so it is sized with the arrangement.
    at_level0: []bool = &.{},
    /// How many notes `at_level0` marks. Zero means the whole view is merged, which is the case
    /// several per-node passes can skip outright.
    notes_at_level0: u32 = 0,
    /// Set when `visible` lists every note rather than a selection — no hierarchy, or a descent
    /// in progress. The web pass has to know, since it must then not merge either.
    selection_full: bool = false,
    /// Scratch copy of the current node positions, for handing to the hierarchy. Panel arena.
    live_pos: []dvui.Point = &.{},
    /// Overview notes with a non-zero `pointer_t`. See `chasePointer`.
    pointer_warm: std.ArrayList(u32) = .empty,
    /// Overview notes with a non-zero `hover_t`. Same idea as `pointer_warm`: the proximity
    /// field used to chase every visible note every frame the mouse moved, and at overview that
    /// was most of the vault.
    hover_warm: std.ArrayList(u32) = .empty,
    /// Camera pose the selection / web were last built against. Mouse motion alone must not
    /// rebuild either — see `updateSelection` / `updateVisibleEdges`.
    sel_center: dvui.Point = .{},
    sel_zoom: f32 = 0,
    sel_vp: dvui.Rect.Physical = .{},
    web_center: dvui.Point = .{},
    web_zoom: f32 = 0,
    web_vp: dvui.Rect.Physical = .{},

    /// Link animation state, keyed by note-id pair and outliving the arena rebuild.
    /// Entries stay after their link is gone until the retraction finishes.
    edge_anim: std.AutoHashMapUnmanaged(EdgeKey, EdgeAnim) = .empty,

    fling_x: Fling = .{},
    fling_y: Fling = .{},
    drag_active: bool = false,
    moved_since_press: bool = false,
    drag_was_touch: bool = false,
    press_node: ?usize = null,

    interior: Interior,

    touches: [10]Touch = [_]Touch{.{}} ** 10,
    gesture_active: bool = false,
    last_centroid: dvui.Point.Physical = .{},
    last_pinch: f32 = 0,

    fn init(gpa: std.mem.Allocator) Panel {
        return .{
            .arena = std.heap.ArenaAllocator.init(gpa),
            .interior = .{ .arena = std.heap.ArenaAllocator.init(gpa) },
        };
    }

    fn deinit(self: *Panel) void {
        if (self.density) |*d| d.deinit();
        self.visible.deinit(sdk.allocator());
        self.interior_visible.deinit(sdk.allocator());
        self.vis_edges.deinit(sdk.allocator());
        self.pointer_warm.deinit(sdk.allocator());
        self.hover_warm.deinit(sdk.allocator());
        if (self.pyramid) |*py| py.deinit();
        self.edge_anim.deinit(sdk.allocator());
        self.id_index.deinit(sdk.allocator());
        self.interior.deinit();
        self.arena.deinit();
        self.* = undefined;
    }

    fn ensureDensity(self: *Panel) ?*galaxy.Density {
        if (self.density == null) {
            self.density = galaxy.Density.init(sdk.allocator()) catch return null;
        }
        return &(self.density.?);
    }
};

var panel: ?Panel = null;
/// Set by `draw`, consumed by `wantsRepaint`. The host asks for continuous frames *before*
/// drawing, so this is "we painted on the previous pass" — enough to know the bottom panel
/// is open and showing us. Without it, collapsing the panel froze settle flags mid-chase and
/// `needsContinuousRepaint` kept the whole editor at display refresh forever.
var drawn_recently: bool = false;

fn ensurePanel(gpa: std.mem.Allocator) *Panel {
    if (panel == null) panel = Panel.init(gpa);
    return &panel.?;
}

/// Join any layout worker still running. Must be called before the plugin's library can be
/// unloaded: the worker is executing code that lives in this dylib, and a solve on a large vault
/// outlasts a plugin teardown comfortably.
pub fn shutdown() void {
    const p = &(panel orelse return);
    if (p.job) |job| {
        job.deinit(sdk.allocator());
        p.job = null;
    }
    if (p.world_state) |*w| {
        w.deinit();
        p.world_state = null;
    }
}

/// Temporary on-screen readout of everything the reshape depends on.
///
/// Here because the panel's reshaping has been reported broken repeatedly while the layout it
/// calls demonstrably reshapes correctly in isolation — so the fault is somewhere in what the
/// panel *measures*, and that is precisely the part no test can see. Guessing at it blind has
/// already cost several rounds; one look at the real numbers settles it.
///
/// `span` is the cloud's own width-over-height. If `aspect` tracks the pane while `span` does not
/// follow it, the layout is being asked wrongly; if `aspect` itself does not track the pane, the
/// measurement is wrong; if both track and the view still looks unchanged, it is the camera.
/// Aspect/reshape readout used while tuning pane packing. Off in normal use — filling a
/// text HUD and scanning every node for span every frame is pure overhead on the hot path.
const debug_hud = false;
/// Per-frame breakdown of where the panel's time goes, shown by `drawDebugHud`.
///
/// The draw pass is a sequence of passes over the same node and edge arrays, and which of them
/// dominates changes completely with zoom — at overview it is whichever pass is not culled, mid
/// zoom it is the web, close in it is labels. Guessing between them has already been wrong more
/// than once, so each is timed separately and the counts of what actually reached the batch are
/// reported alongside, since a pass being slow and a pass being *large* want different fixes.
const FrameProfile = struct {
    rebuild_ns: u64 = 0,
    bubbles_ns: u64 = 0,
    hover_ns: u64 = 0,
    labels_ns: u64 = 0,
    edge_anim_ns: u64 = 0,
    draw_edges_ns: u64 = 0,
    draw_nodes_ns: u64 = 0,
    draw_clusters_ns: u64 = 0,
    draw_labels_ns: u64 = 0,

    /// Submitted to a batch, i.e. survived culling — not the size of the arrays walked.
    edges_drawn: u32 = 0,
    nodes_drawn: u32 = 0,
    nodes_pathed: u32 = 0,
    clusters_drawn: u32 = 0,
    /// Tile quads submitted this frame, and how many of them were rendered into the atlas rather
    /// than read from it. Baking should fall to zero within a frame or two of any camera move —
    /// a picture outlives every pan and zoom — so a HUD showing it constantly non-zero means
    /// something is invalidating the atlas every frame.
    tiles_drawn: u32 = 0,
    tiles_baked: u32 = 0,
    /// Tiles with no picture yet, drawn straight to the screen this frame. Should fall to zero
    /// within a frame or two of any camera move that reveals new ground.
    tiles_direct: u32 = 0,

    fn total(self: FrameProfile) u64 {
        return self.rebuild_ns + self.bubbles_ns + self.hover_ns + self.labels_ns +
            self.edge_anim_ns + self.draw_edges_ns + self.draw_nodes_ns +
            self.draw_clusters_ns + self.draw_labels_ns;
    }
};
var frame_profile: FrameProfile = .{};

pub fn draw(_: ?*anyopaque) anyerror!void {
    drawn_recently = true;
    const st = runtime.state();
    const gpa = sdk.allocator();
    const p = ensurePanel(gpa);
    _ = ensureWorld(p);

    var root = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .background = false,
        .padding = .all(0),
    });
    defer root.deinit();

    const content = dvui.parentGet().data();
    const vp = content.contentRectScale().r;
    p.camera.viewport = vp;

    if (!st.hasGraphSource()) {
        drawCenteredHint("Open a folder — or Atlas: Load Synth Graph — to see the note graph.");
        return;
    }

    frame_profile = .{};
    var prof = profNow();

    try rebuildIfNeeded(p, st);
    frame_profile.rebuild_ns = profLap(&prof);

    // Nothing to show yet and a solve in flight — the first open of a large vault. Everything
    // below this point reads `p.nodes`, so there is no arrangement to draw or interact with.
    // A rebuild of a graph that *is* already on screen deliberately falls through and keeps
    // drawing the old one; swapping it for a spinner on every reindex would be worse than the
    // wait it reports.
    if ((p.job != null or st.synthBusy()) and p.nodes.len == 0) {
        drawLayoutSpinner(if (st.synthBusy()) @intCast(State.quantizedSynthNotes(st.settings.synth_notes.get())) else p.note_count);
        return;
    }

    // Before anything reads or clamps zoom: how far out this vault may be pulled depends on how
    // big it is, and it just changed if a rebuild landed above.
    p.camera.setContentExtent(p.world_radius, zoom_out_slack);

    updateInterior(p, st);
    maybeFitCamera(p);

    // Pinch before fling/wheel so a trackpad pinch isn't also interpreted as scroll-pan.
    applyTrackpadPinch(p, vp);
    stepFling(p);
    animateCamera(p);
    // *After* updateSelection, which clears `p.visible` and refills it from the classic LOD —
    // whose `Visible.index` is a cluster index at any level above 0, not a note index. Handing
    // that to the label placer put names at positions belonging to no node at all, and left none
    // to place whenever the classic selection was empty at a zoom containment had resolved.
    // Still before updateBubbles/updateHover/updateLabels, all of which read what this publishes.
    stepWorld(p);
    stepInteriorWorld(p);
    applyInteriorFramingIfNeeded(p);
    _ = profLap(&prof);
    updateBubbles(p);
    frame_profile.bubbles_ns = profLap(&prof);
    followParent(p);
    updateHover(p);
    frame_profile.hover_ns = profLap(&prof);
    // After `updateHover` — placement priority is led by which node is under the cursor.
    // Whichever level the reader is mostly looking at owns the names; see `updateLabels`.
    // Skip the placer when nothing that feeds it is moving — it is one of the heaviest idle
    // costs and was enough on its own to hold the editor around 80fps.
    // `chasing()` is not enough on its own: a hand-driven pan/zoom moves the camera with no
    // chase running, and a splitter drag slides the whole pane without moving it at all. Both
    // leave placements that were computed in screen space sitting where the nodes no longer are.
    // A fully merged view has no name on screen to place, and the placer is one of the heaviest
    // per-frame costs there is — running it over every note in the vault to position labels
    // nothing will draw is the worst possible time to pay for it.
    const at_cluster_zoom = p.notes_at_level0 == 0 and p.nodes.len > 0;
    const labels_dirty = !at_cluster_zoom and
        (true or
            p.labels_stale or !p.labels_settled or !p.proximity_settled or
            !p.pointer_settled or !p.layout_settled or p.camera.chasing() or labelViewMoved(p));
    if (at_cluster_zoom) {
        // Do not walk every note — at 100k+ that alone tanks the frame. Labels are not drawn.
        for (p.interior.nodes) |*n| n.label_vis = 0;
        // The arrangement is unchanged but no placement was computed for it, so the next frame
        // that does draw names has to redo them.
        p.labels_stale = true;
    } else if (p.interior.t < 0.5) {
        if (labels_dirty) updateLabels(p, p.nodes, p.edges, p.layout_slot, p.visible.items, 1);
        for (p.interior.nodes) |*n| n.label_vis = 0;
    } else {
        if (labels_dirty) updateLabels(p, p.interior.nodes, p.interior.edges, p.interior.slot, p.interior_visible.items, 0);
        for (p.nodes) |*n| n.label_vis = 0;
    }
    if (labels_dirty) {
        p.labels_stale = false;
        p.labels_center = p.camera.center;
        p.labels_zoom = p.camera.zoom;
        p.labels_vp = p.camera.viewport;
    }
    frame_profile.labels_ns = profLap(&prof);
    frame_profile.edge_anim_ns = profLap(&prof);

    {
        const clip = dvui.clip(vp);
        defer dvui.clipSet(clip);
        // Grid first: it is the surface everything else sits on.
        dotgrid.draw(&p.camera, gridDotColor());
        // Both levels are drawn for the whole descent, passing through each other. The overview
        // gives way as the interior arrives, which is what sells zooming *into* a node rather
        // than cutting to another screen.
        const t = p.interior.t;
        // Zoomed out far enough that individual notes overlap, the vault is drawn as regions
        // instead: one marker per cluster, no links, no names. Nothing is hidden that could
        // have been read — see `lod.Pyramid.levelFor` — and it turns "draw every note in the
        // vault" into "draw a few hundred markers".
        // Notes where they have separated enough to be told apart, merged markers where they
        // have not — decided per region, and cross-faded, by `updateSelection`.
        _ = profLap(&prof);
        // One hierarchy, positions derived from it. Owns the whole overview.
        drawWorldMarks(p, 1 - t);
        frame_profile.draw_edges_ns = profLap(&prof);
        frame_profile.draw_nodes_ns = 0;
        frame_profile.draw_clusters_ns = 0;
        if (p.interior.nodes.len > 0) {
            // No links inside a note: the headings *are* the document's structure, so they orbit
            // the sun rather than being wired to it. Same soft-sprite language as the overview.
            drawInteriorMarks(p, t);
            frame_profile.draw_nodes_ns += profLap(&prof);
        }
        // Labels last, as their own pass: a name must never end up under a bubble drawn
        // after it, and the placer already guaranteed they don't collide with each other.
        drawLabels(p);
        frame_profile.draw_labels_ns = profLap(&prof);
        if (debug_hud) drawDebugHud(p);
    }
    if (st.synthBusy() and p.nodes.len > 0) drawSynthRegenCue();
    // Before `handleInput` so the button consumes its own press rather than the graph
    // treating it as the start of a pan.
    drawFitButton(p, content);
    handleInput(p);
}

/// Layout ease + pixi-bubble proximity: chase `home` toward the hex `target`, then chase
/// `hover_t` from screen-stable mouse distance, grow in place under the cursor, and shove
/// *neighbors* aside so labels stay readable. Nodes never flee the mouse — that made
/// hover/click impossible. Zoom reveal is applied at draw/hit time.
///
/// Whichever level owns the view (overview vs interior) gets the proximity field; the other
/// decays so a faded backdrop doesn't keep swelling behind the cloud you are looking at.
fn updateBubbles(p: *Panel) void {
    if (p.nodes.len == 0) {
        p.proximity_settled = true;
        p.layout_settled = true;
        return;
    }

    const dt = @min(dvui.secondsSinceLastFrame(), 1.0 / 30.0);
    const t_hover = 1.0 - @exp(-hover_chase_k * dt);
    const t_layout = 1.0 - @exp(-layout_chase_k * dt);

    // Fully coalesced (no leaf notes on screen): never chase homes across the whole vault.
    // Key off `notes_at_level0`, not `agents_active` — Galaxy keeps agents on through leaf zoom.
    const coalesced_only = p.notes_at_level0 == 0 and p.nodes.len > 0;
    var layout_unsettled = false;
    if (coalesced_only) {
        if (!p.layout_settled) {
            if (p.nodes.len > layout_inline_max) {
                // Snap without a multi-hundred-ms walk: targets already match poses after synth apply.
                p.layout_settled = true;
            } else {
                for (p.nodes) |*n| {
                    n.home = n.target;
                    n.pos = n.target;
                    n.radius = n.target_radius;
                }
                p.layout_settled = true;
            }
        }
    } else if (p.nodes.len > layout_inline_max) {
        // Large vault with some leaves visible: chase only on-screen leaf notes.
        for (p.visible.items) |vi| {
            if (vi.level != 0 or vi.index >= p.nodes.len) continue;
            const n = &p.nodes[vi.index];
            const ldx = n.target.x - n.home.x;
            const ldy = n.target.y - n.home.y;
            if (@abs(ldx) < 0.05 and @abs(ldy) < 0.05) {
                n.home = n.target;
            } else {
                n.home.x += ldx * t_layout;
                n.home.y += ldy * t_layout;
                layout_unsettled = true;
            }
            n.radius = n.target_radius;
        }
    } else {
        for (p.nodes) |*n| {
            // Ease the layout home toward its hex target. Snap the last sliver so
            // `layout_settled` can actually go false and stop the repaint loop.
            const ldx = n.target.x - n.home.x;
            const ldy = n.target.y - n.home.y;
            if (@abs(ldx) < 0.05 and @abs(ldy) < 0.05) {
                n.home = n.target;
            } else {
                n.home.x += ldx * t_layout;
                n.home.y += ldy * t_layout;
                layout_unsettled = true;
            }
            n.radius = n.target_radius;
        }
    }

    const inside_interior = p.interior.t >= 0.5 and p.interior.nodes.len > 0;
    var hover_unsettled = false;
    if (inside_interior) {
        hover_unsettled = applyProximity(p, p.interior.nodes, p.interior.slot, p.interior.radius, t_hover, p.interior_visible.items) or hover_unsettled;
        // Do not decayProximity over the whole overview vault during interior — O(N).
    } else if (coalesced_only) {
        // Everything is merged: no note is drawn and none can be hovered.
    } else {
        hover_unsettled = applyProximity(p, p.nodes, p.layout_slot, p.world_radius, t_hover, p.visible.items) or hover_unsettled;
        if (p.interior.nodes.len > 0) {
            hover_unsettled = decayProximity(p.interior.nodes, t_hover) or hover_unsettled;
        }
    }

    p.proximity_settled = !hover_unsettled;
    if (!coalesced_only) p.layout_settled = !layout_unsettled;
    // Do *not* re-apply framing when the layout ease finishes. Rebuild already framed the new
    // targets on the same frame the homes started moving; a second fit here is the visible
    // "nodes finish, then the camera recenters" hitch. Camera and nodes ease together instead.
    if (hover_unsettled or layout_unsettled) dvui.refresh(null, @src(), dvui.parentGet().data().id);
}

/// Chase `hover_t` → 0 and reset `pos` to `home` for a cloud that is not the active level.
fn decayProximity(nodes: []GraphNode, t_hover: f32) bool {
    var unsettled = false;
    for (nodes) |*n| {
        n.hover_t += (0 - n.hover_t) * t_hover;
        if (@abs(n.hover_t) > 0.004) unsettled = true else n.hover_t = 0;
        n.pos = n.home;
    }
    return unsettled;
}

/// Soft proximity swell + neighbour shove for one cloud. `slot`/`cloud_radius` are that
/// level's lattice spacing and extent so interior hover scales like the overview at the same
/// on-screen gap.
fn applyProximity(
    p: *Panel,
    nodes: []GraphNode,
    slot: f32,
    cloud_radius: f32,
    t_hover: f32,
    selection: ?[]const Visible,
) bool {
    if (nodes.len == 0) return false;

    const mouse = dvui.currentWindow().mouse_pt;
    const inside = p.camera.viewport.contains(mouse);
    const mouse_w = p.camera.screenToWorld(mouse);
    const zoom = @max(p.camera.zoom, 0.001);
    const zoom_t = detailRevealT(slot, zoom);
    // Wider screen falloff when zoomed in — close-up hover feels more sensitive.
    const falloff_px = proximity_falloff_px * std.math.lerp(1.0, proximity_falloff_zoom_boost, zoom_t);
    const falloff_w = falloff_px / zoom;
    // Fades proximity out once the whole cloud is no bigger than the falloff itself.
    const strength = proximity.strength(cloud_radius * 2 * zoom, falloff_px);

    var hover_unsettled = false;
    var any_shove = false;
    // Only what is on screen as itself. Hover is a screen-space effect on a drawn disc, so a note
    // that is off view or merged into a marker has nothing to swell and nothing to be pushed by.
    // The indices are kept because the shove pass below needs the same set twice.
    const arena = dvui.currentWindow().arena();
    var active: std.ArrayList(u32) = .empty;
    active.ensureTotalCapacity(arena, if (selection) |s| s.len else nodes.len) catch {};
    var walk = NodeIter.init(nodes, selection);
    while (walk.next()) |step| active.append(arena, @intCast(step.index)) catch {};

    for (active.items) |ni| {
        const n = &nodes[ni];
        const want: f32 = if (!inside or strength <= 0.001) 0 else blk: {
            // Hover against `home` (where the node is settling), not the eventual target,
            // so a node mid-flight is still hoverable under the cursor.
            const dx = n.home.x - mouse_w.x;
            const dy = n.home.y - mouse_w.y;
            const d = @sqrt(dx * dx + dy * dy);
            break :blk std.math.clamp(1.0 - d / falloff_w, 0, 1) * strength;
        };
        // Open docs keep a gentle resting swell so they stay findable in the cloud.
        const want_final = if (n.open) @max(want, open_rest_hover) else want;

        const prev = n.hover_t;
        n.hover_t = prev + (want_final - prev) * t_hover;
        if (@abs(n.hover_t - want_final) > 0.004) hover_unsettled = true;

        // Grow in place from the layout home — spacing is applied as neighbor shove below.
        n.pos = n.home;
        // Resting open-doc swell must not count as a shove source. It used to: every open
        // note sat at hover_t ≥ 0.22, so the O(n²) neighbour pass ran *every frame* even with
        // the mouse nowhere near the cloud — the main reason an idle graph ate tens of fps.
        if (shoveHover(n.*) >= 0.08) any_shove = true;
    }

    // Grown nodes push neighbors away from *themselves* (not away from the cursor).
    // Only mouse-swollen nodes act as sources — zoom-rest and open-doc resting size are
    // draw-only so a close-up / open tab doesn't shove the whole vault apart.
    //
    // Two things bound this, and both matter at vault scale:
    //
    //   • Reach is capped at `max_shove_slots` lattice cells. The radii here are *screen* sizes
    //     divided by zoom, so as you zoom out they grow without bound in world units — at far
    //     zoom on a big vault a single swollen node was reaching thousands of world units and
    //     flinging the cloud apart. `proximity.strength` only catches this once the whole web
    //     is smaller than the falloff, which never happens for a large vault at its fitted view.
    //
    //   • Only nodes inside that reach are visited, via a bucket grid. The old pass was every
    //     source against every node, and the number of sources peaks at *mid* zoom — far out,
    //     `strength` is 0; far in, the world-space falloff is tiny so almost nothing swells;
    //     in between, a large share of the cloud is swollen and the whole thing is quadratic.
    //     That band is exactly where the frame rate fell off a cliff.
    if (any_shove and strength > 0.001) {
        const gap_w = neighbor_gap_px / zoom;
        const reach_cap = slot * max_shove_slots;

        var grid = ShoveGrid.init(arena, nodes, active.items, reach_cap) catch null;
        defer if (grid) |*g| g.deinit();

        for (active.items) |si| {
            const src = nodes[si];
            const src_shove = shoveHover(src);
            if (src_shove < 0.08) continue;
            const src_r = @min(bubbleScreenRadius(src, zoom_t, slot * zoom) / zoom, reach_cap);

            if (grid) |g| {
                var it = g.near(src.home);
                while (it.next()) |di| {
                    if (di == si) continue;
                    shovePair(&nodes[di], src, src_r, gap_w, src_shove, zoom_t, zoom, reach_cap, slot * zoom);
                }
            } else {
                for (active.items) |di| {
                    if (di == si) continue;
                    shovePair(&nodes[di], src, src_r, gap_w, src_shove, zoom_t, zoom, reach_cap, slot * zoom);
                }
            }
        }
    }
    return hover_unsettled;
}

/// Push one node clear of a swollen neighbour. `reach_cap` bounds both radii so the shove stays
/// a local nudge in world units no matter how far out the camera is.
fn shovePair(
    dst: *GraphNode,
    src: GraphNode,
    src_r: f32,
    gap_w: f32,
    src_shove: f32,
    zoom_t: f32,
    zoom: f32,
    reach_cap: f32,
    gap_px: f32,
) void {
    const dx = dst.home.x - src.home.x;
    const dy = dst.home.y - src.home.y;
    const d = @sqrt(dx * dx + dy * dy);
    if (d < 1e-3) return;
    const dst_r = @min(bubbleScreenRadius(dst.*, zoom_t, gap_px) / zoom, reach_cap);
    const need = @min(src_r + dst_r + gap_w, reach_cap);
    if (d >= need) return;
    const amt = (need - d) * neighbor_push * src_shove;
    dst.pos.x += (dx / d) * amt;
    dst.pos.y += (dy / d) * amt;
}

/// Bucket grid over node homes for the proximity shove. Cell size is the shove reach, so every
/// node a source can possibly reach lies in the 3×3 block around it.
const ShoveGrid = struct {
    allocator: std.mem.Allocator,
    cell: f32,
    map: std.AutoHashMap([2]i32, std.ArrayList(usize)),

    /// `which` is the set of node indices to bin — the ones on screen, not the whole vault.
    fn init(
        allocator: std.mem.Allocator,
        nodes: []const GraphNode,
        which: []const u32,
        cell: f32,
    ) !ShoveGrid {
        var g: ShoveGrid = .{
            .allocator = allocator,
            .cell = @max(cell, 1e-3),
            .map = std.AutoHashMap([2]i32, std.ArrayList(usize)).init(allocator),
        };
        errdefer g.deinit();
        for (which) |i| {
            const gop = try g.map.getOrPut(g.keyOf(nodes[i].home));
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(allocator, i);
        }
        return g;
    }

    fn deinit(g: *ShoveGrid) void {
        var it = g.map.valueIterator();
        while (it.next()) |list| list.deinit(g.allocator);
        g.map.deinit();
    }

    fn keyOf(g: ShoveGrid, p: dvui.Point) [2]i32 {
        return .{
            @intFromFloat(@floor(p.x / g.cell)),
            @intFromFloat(@floor(p.y / g.cell)),
        };
    }

    fn near(g: *const ShoveGrid, at: dvui.Point) NearIter {
        return .{ .g = g, .key = g.keyOf(at) };
    }

    const NearIter = struct {
        g: *const ShoveGrid,
        key: [2]i32,
        dx: i32 = -1,
        dy: i32 = -1,
        bucket: []const usize = &.{},
        at: usize = 0,

        fn next(it: *NearIter) ?usize {
            while (true) {
                if (it.at < it.bucket.len) {
                    defer it.at += 1;
                    return it.bucket[it.at];
                }
                if (it.dy > 1) return null;
                const k: [2]i32 = .{ it.key[0] + it.dx, it.key[1] + it.dy };
                it.dx += 1;
                if (it.dx > 1) {
                    it.dx = -1;
                    it.dy += 1;
                }
                it.bucket = if (it.g.map.get(k)) |b| b.items else &.{};
                it.at = 0;
            }
        }
    };
};

/// Open notes rest at `open_rest_hover` so they stay visible; shove only cares about the
/// mouse-driven portion above that floor.
const open_rest_hover: f32 = 0.22;

fn shoveHover(n: GraphNode) f32 {
    if (n.open) return @max(0, n.hover_t - open_rest_hover);
    return n.hover_t;
}

/// 0 at sparse overview → 1 when layout neighbours are far enough apart on screen that
/// labels and proximity detail should read clearly.
fn detailRevealT(layout_slot: f32, zoom: f32) f32 {
    const slot = if (layout_slot > 1) layout_slot else hex.layoutSpacingFor(1);
    const gap = slot * zoom; // physical px between adjacent layout cells
    const t = std.math.clamp((gap - detail_gap_lo) / (detail_gap_hi - detail_gap_lo), 0, 1);
    return t * t * (3.0 - 2.0 * t);
}

/// Background dots use the text editor's line-number colour, so the graph reads as the same
/// surface as the gutter you just came from.
fn gridDotColor() dvui.Color {
    return dvui.themeGet().color(.control, .text).opacity(0.5);
}

/// Which node is literally under the cursor, plus the button-style highlight chase for it.
/// Separate from `updateBubbles`: proximity is a soft field over many nodes, this is a
/// single winner, and it must run *after* the neighbour shove so it agrees with what's drawn.
///
/// Hits the active level only — overview when looking at the vault, interior once descent
/// owns the panel — so a section click never lands on a faded note behind it.
fn updateHover(p: *Panel) void {
    const mouse = dvui.currentWindow().mouse_pt;
    // `drag_active`/`gesture_active` are last frame's — close enough, and it means the
    // highlight drops the moment a pan starts rather than a frame later.
    const pointer_ok = p.camera.viewport.contains(mouse) and
        !p.drag_active and !p.gesture_active and
        pointerTargetsMainPane(mouse);
    const inside_interior = p.interior.t >= 0.5 and p.interior.nodes.len > 0;
    if (!pointer_ok) {
        p.hover_node = null;
        p.hover_cluster = null;
    } else if (inside_interior) {
        p.hover_cluster = null;
        p.hover_node = hitTestNodes(p, p.interior.nodes, p.interior.slot, mouse);
    } else {
        // Leaves first — a note on/near a dashed mass must stay the hover target. Masses only
        // when no leaf hits (same order as click).
        // `hitTestAgentLeaves` walks the classic agent field, which containment never fills — so
        // in containment mode every note hover missed, the cursor never became a hand, and clicking
        // a note could not open its document.
        p.hover_node = hitTestNodes(p, p.nodes, p.layout_slot, mouse);
        p.hover_cluster = if (p.hover_node != null) null else hitTestClusters(p, mouse);
    }

    const dt = @min(dvui.secondsSinceLastFrame(), 1.0 / 30.0);
    const t_chase = 1.0 - @exp(-pointer_chase_k * dt);
    var unsettled = false;

    // A merged region swells under the cursor exactly as a note does. It is standing in for notes
    // and sits among them, so the affordance has to be the same one — and because the swell runs
    // through the same eased channel, it grows and settles rather than snapping between sizes.
    // Moving to a different region restarts the ease from nothing, or the new one would appear
    // already grown.
    // Reset only on the way in from nothing. Sweeping from one region straight to the next keeps
    // the ease where it is: the ring follows the cursor continuously over a tiled field, and
    // restarting it at every region boundary would make it pulse the whole way across.
    if (p.hover_cluster != null and p.hover_cluster_prev == null) p.hover_cluster_t = 0;
    p.hover_cluster_prev = p.hover_cluster;
    {
        const want: f32 = if (p.hover_cluster != null) 1 else 0;
        p.hover_cluster_t += (want - p.hover_cluster_t) * t_chase;
        if (@abs(p.hover_cluster_t - want) > 0.004) unsettled = true else p.hover_cluster_t = want;
    }
    // The interior cloud is one section's worth of notes, so it is walked outright. The overview
    // is the whole vault and is not — see `chasePointer`.
    if (inside_interior) {
        for (p.interior.nodes, 0..) |*n, i| {
            const want: f32 = if (p.hover_node == i) 1 else 0;
            n.pointer_t += (want - n.pointer_t) * t_chase;
            if (@abs(n.pointer_t - want) > 0.004) unsettled = true;
        }
        unsettled = chasePointer(p, null, t_chase) or unsettled;
    } else {
        for (p.interior.nodes) |*n| {
            n.pointer_t += (0 - n.pointer_t) * t_chase;
            if (@abs(n.pointer_t) > 0.004) unsettled = true else n.pointer_t = 0;
        }
        unsettled = chasePointer(p, p.hover_node, t_chase) or unsettled;
    }
    p.pointer_settled = !unsettled;
    if (unsettled) dvui.refresh(null, @src(), dvui.parentGet().data().id);
}

/// Chase the overview's `pointer_t` toward `target` without touching the vault.
///
/// Exactly one note is under the cursor, so only a couple ever hold a non-zero value: the one
/// being pointed at, and whichever one was a moment ago and is still fading. Tracking that
/// handful turns a pass over every note in the vault into a pass over two — and the chase is
/// precisely what keeps the panel repainting until it lands, so the full pass was running on
/// every frame of every hover rather than occasionally.
fn chasePointer(p: *Panel, target: ?usize, t_chase: f32) bool {
    if (target) |i| {
        if (i < p.nodes.len and std.mem.indexOfScalar(u32, p.pointer_warm.items, @intCast(i)) == null) {
            p.pointer_warm.append(sdk.allocator(), @intCast(i)) catch {};
        }
    }

    var unsettled = false;
    var w: usize = 0;
    while (w < p.pointer_warm.items.len) {
        const i = p.pointer_warm.items[w];
        if (i >= p.nodes.len) {
            _ = p.pointer_warm.swapRemove(w);
            continue;
        }
        const n = &p.nodes[i];
        const want: f32 = if (target != null and target.? == i) 1 else 0;
        n.pointer_t += (want - n.pointer_t) * t_chase;
        if (@abs(n.pointer_t - want) > 0.004) {
            unsettled = true;
            w += 1;
            continue;
        }
        n.pointer_t = want;
        // At rest and not the target any more: nothing left to chase, so stop tracking it.
        if (want == 0) _ = p.pointer_warm.swapRemove(w) else w += 1;
    }
    return unsettled;
}

/// Re-seed `pointer_warm` after a rebuild, which reallocates `nodes` and renumbers them — the
/// old indices mean nothing, and a note carrying a non-zero `pointer_t` that nobody is chasing
/// would sit lit forever. One pass at rebuild, rather than one per frame.
fn rewarmPointer(p: *Panel) void {
    p.pointer_warm.clearRetainingCapacity();
    for (p.nodes, 0..) |n, i| {
        if (@abs(n.pointer_t) > 0.004) p.pointer_warm.append(sdk.allocator(), @intCast(i)) catch {};
    }
}

/// Refresh `live_pos` from node poses. Coalesced overview stays static (no O(N) copy).
/// When leaf notes are on screen, update those indices so agents / stars track hover shove.
fn syncLivePos(p: *Panel) []const dvui.Point {
    return syncLivePosLeafAware(p, p.notes_at_level0 > 0);
}

fn syncLivePosLeafAware(p: *Panel, leaves_on_screen: bool) []const dvui.Point {
    if (p.live_pos.len != p.nodes.len) return &.{};
    if (leaves_on_screen) {
        for (p.visible.items) |vi| {
            if (vi.level != 0 or vi.index >= p.nodes.len) continue;
            p.live_pos[vi.index] = p.nodes[vi.index].pos;
        }
    } else if (!p.layout_settled or !p.proximity_settled) {
        for (p.nodes, p.live_pos) |n, *q| q.* = n.pos;
    }
    return p.live_pos;
}

fn applyTrackpadPinch(p: *Panel, vp: dvui.Rect.Physical) void {
    const ratio = core.takeTrackpadPinchRatio();
    if (ratio == 1.0) return;
    const cursor = dvui.currentWindow().mouse_pt;
    if (!vp.contains(cursor)) return;
    p.fling_x.cancel();
    p.fling_y.cancel();
    p.camera.zoomAtScreen(ratio, cursor);
    cameraTakenOver(p);
    dvui.refresh(null, @src(), dvui.parentGet().data().id);
}

/// Call from anywhere the user actually moves the camera by hand — not from a mere press, or
/// clicking a node would count as taking manual control and stop it framing anything.
fn cameraTakenOver(p: *Panel) void {
    p.camera.user_driving = true;
    p.framing = .free;
}

/// The panel's proportions, coarsely bucketed, for `layout_full.Opts.aspect`.
///
/// Only the *committed* pack uses this. Live mid-drag reshapes are gated separately (see
/// `updateAspectSettle`) because a splitter chatters and discrete re-parks produce two attractors
/// for homes to lerp between.
fn layoutAspect(vp: dvui.Rect.Physical, current: f32, smooth: *f32) f32 {
    if (vp.w < 32 or vp.h < 32) return if (current > 0) current else 1;
    // Clamped to the layout's own limit, never a separate number — see `layout_full.aspect_limit`.
    const raw = std.math.clamp(vp.w / vp.h, 1.0 / layout_full.aspect_limit, layout_full.aspect_limit);
    if (smooth.* <= 0) smooth.* = raw else smooth.* += (raw - smooth.*) * aspect_smooth_k;
    const m = smooth.*;
    const bucket = @round(m * aspect_buckets_per_unit) / aspect_buckets_per_unit;
    if (current <= 0) return bucket;
    if (@abs(m - current) < aspect_hysteresis) return current;
    return bucket;
}

const aspect_smooth_k: f32 = 0.22;
const aspect_buckets_per_unit: f32 = 4;
const aspect_hysteresis: f32 = 0.18;
/// Frames the pane must hold still before a reshape commits. ~120ms at 60fps — long enough that
/// a splitter's end-of-drag chatter dies, short enough that release still feels immediate.
const aspect_settle_frames: u16 = 8;

/// Watch the viewport. While it is moving, only the camera refits; once it has been unchanged
/// for `aspect_settle_frames`, a pending aspect change is allowed to rebuild the cloud.
fn updateAspectSettle(p: *Panel) void {
    const vp = p.camera.viewport;
    if (vp.w < 32 or vp.h < 32) return;
    // 2px — sub-pixel layout chatter used to reset the counter every frame and, with the
    // refresh below, pin the app awake.
    const moved = p.settle_vp_w <= 0 or
        @abs(vp.w - p.settle_vp_w) > 2.0 or
        @abs(vp.h - p.settle_vp_h) > 2.0;
    if (moved) {
        p.settle_vp_w = vp.w;
        p.settle_vp_h = vp.h;
        p.settle_frames = 0;
    } else if (p.settle_frames < aspect_settle_frames) {
        p.settle_frames += 1;
    }
}

fn rebuildIfNeeded(p: *Panel, st: anytype) !void {
    const gen = st.generation.load(.acquire);
    const open_hash = if (st.vault_root) |root| hashOpenNotes(root) else 0;
    updateAspectSettle(p);
    const desired = layoutAspect(p.camera.viewport, p.layout_aspect, &p.aspect_smooth);
    const pane_settled = p.settle_frames >= aspect_settle_frames;
    const aspect_dirty = desired != p.layout_aspect;
    const same_graph = p.gen == gen and p.nodes.len > 0;
    // Index/gen changes rebuild immediately. Aspect changes wait until the pane stops moving —
    // packing on every splitter tick is what produced the A↔B juggling.
    const reshape = same_graph and aspect_dirty and pane_settled;

    // A solve already running owns this rebuild. Collect it the frame it lands; until then the
    // previous arrangement keeps drawing, so a reindex never blanks a graph that was on screen.
    if (p.job) |job| {
        if (job.done.load(.acquire)) {
            p.job = null;
            defer job.deinit(sdk.allocator());
            if (job.fail) |e| return e;
            try finishRebuild(p, st, job);
        }
        // Whether or not it landed, nothing else may start one this frame.
        p.aspect_waiting = false;
        p.rebuild_waiting = false;
        return;
    }

    var need_rebuild = p.gen != gen or p.nodes.len == 0 or reshape;

    // Coalesce a burst of index commits into one solve.
    //
    // Reading a vault publishes a new generation every batch, and each one used to re-solve the
    // whole graph. On a large vault that is not just wasted work — it is *visible* work: notes
    // arriving unanchored are free to move, so every re-solve lands on a different arrangement
    // and the web churns and stretches for as long as the read takes. Waiting for the index to
    // hold still first means the reader sees the graph they had, then one settled replacement.
    //
    // Small vaults are exempt: they solve inline in well under a frame, so the churn is not
    // perceptible and the delay would be the only thing you could notice. So is the first build
    // — showing a partial graph immediately is the whole point of solving off-thread.
    p.rebuild_waiting = false;
    if (need_rebuild and !reshape and p.nodes.len > layout_inline_max) {
        if (gen != p.pending_gen) {
            p.pending_gen = gen;
            p.pending_quiet_s = 0;
        } else {
            p.pending_quiet_s += @min(dvui.secondsSinceLastFrame(), 1.0 / 30.0);
        }
        if (p.pending_quiet_s < rebuild_quiet_s) {
            need_rebuild = false;
            p.rebuild_waiting = true;
        }
    }

    // `wantsRepaint` reads this — do not `dvui.refresh` every frame while waiting, or the
    // editor cannot sleep even after the pane has stopped moving.
    p.aspect_waiting = same_graph and aspect_dirty and !pane_settled;

    if (!need_rebuild) {
        if (p.open_hash != open_hash) {
            // The vault can be closed while a solve is in flight; the job's data is its own copy and is
    // still fine to apply, but there is no folder left to ask which notes are open.
    if (st.vault_root) |root| applyOpenSet(p, root, open_hash);
        }
        return;
    }
    p.aspect_waiting = false;

    // Always pack to the pane we have now. Aspect-only rebuilds are settle-gated above; index
    // rebuilds take the current bucket immediately.
    const aspect = desired;
    p.layout_aspect = aspect;

    if (reshape) {
        // The panel changed proportions and the entire cloud is about to be re-laid out to suit,
        // so whatever the camera was holding onto stops existing. `.free` is otherwise permanent
        // — one pan and the panel never re-frames again for the rest of the session, which is why
        // resizing appeared not to re-centre at all — but a pan made against an arrangement that
        // no longer exists is not a preference worth preserving. This is the one place
        // `user_driving` is overridden on purpose: the world moved out from under the camera, the
        // camera did not move.
        p.framing = .extents;
        p.camera.user_driving = false;
    }

    // A first build is a population, not a burst of "connect" events — snap links to full
    // length so opening the panel doesn't play the whole vault wiring itself up.
    const first_build = p.gen == std.math.maxInt(u64);

    // Carry animated fields across for surviving ids (M3 seam). Rebuilt again at apply time —
    // `p.nodes` is untouched for as long as a job is in flight, so both reads see the same thing.
    var carry = std.AutoHashMap(i64, GraphNode).init(sdk.allocator());
    defer carry.deinit();
    for (p.nodes) |n| carry.put(n.note_id, n) catch {};

    // Everything below is prepared into the *job's* arena, not the panel's. The panel's arena
    // still holds the arrangement currently on screen and is only recycled once the new one is
    // ready — see `LayoutJob`.
    const gpa = sdk.allocator();
    const job = try gpa.create(LayoutJob);
    errdefer gpa.destroy(job);
    job.* = .{
        .arena = std.heap.ArenaAllocator.init(gpa),
        .gen = gen,
        .open_hash = open_hash,
        .first_build = first_build,
        .reshape = reshape,
        .aspect = aspect,
        .prior_slot = if (p.layout_slot > 1) p.layout_slot else null,
        .snap = .{},
        .order = &.{},
        .n = 0,
        .edges = &.{},
        .layout_edges = &.{},
        .seeds = &.{},
        .degrees = &.{},
        .anchored = &.{},
        .paths = &.{},
        .sigs = &.{},
        .hist_sig = &.{},
        .hist_target = &.{},
        .hist_valid = &.{},
        .changed = &.{},
        .targets = &.{},
        .ladder = .{},
    };
    errdefer job.arena.deinit();
    const arena = job.arena.allocator();

    // Owned copy: the rebuild below walks these strings for as long as the layout solve takes,
    // which on a large vault is many indexer commits — far longer than a borrowed slice lives.
    const snap: Indexer.Snapshot = if (st.indexer_ready) try st.indexer.snapshotCopy(arena) else .{};
    job.snap = snap;
    p.note_count = snap.note_count;

    // Real notes first (id-sorted for a stable force-layout seed order), phantoms after.
    var order: std.ArrayList(usize) = .empty;
    try order.ensureTotalCapacity(arena, snap.nodes.len);
    for (snap.nodes, 0..) |n, i| {
        if (!n.phantom) try order.append(arena, i);
    }
    for (snap.nodes, 0..) |n, i| {
        if (n.phantom) try order.append(arena, i);
    }
    std.mem.sort(usize, order.items, snap.nodes, struct {
        fn less(nodes: []const Indexer.SnapNode, a: usize, b: usize) bool {
            const na = nodes[a];
            const nb = nodes[b];
            if (na.phantom != nb.phantom) return !na.phantom and nb.phantom;
            return na.id < nb.id;
        }
    }.less);

    if (order.items.len == 0) {
        // Empty vault — no solve to run, so the job is finished with here and the panel's own
        // arena can be recycled immediately.
        job.arena.deinit();
        gpa.destroy(job);
        _ = p.arena.reset(.free_all);
        p.id_index.clearRetainingCapacity();
        p.gen = gen;
        p.nodes = &.{};
        p.edges = &.{};
        // Nothing left to key against, so every link is dead — but let them retract rather
        // than blink out.
        var it = p.edge_anim.valueIterator();
        while (it.next()) |v| v.alive = false;
        p.world_radius = 0;
        p.world_bounds = .{};
        p.live_pos = &.{};
        p.pointer_warm.clearRetainingCapacity();
        p.hover_warm.clearRetainingCapacity();
        p.visible.clearRetainingCapacity();
        p.sel_zoom = 0;
        p.web_zoom = 0;
        p.open_hash = open_hash;
        p.fitted_vp_w = 0;
        p.fitted_vp_h = 0;
        p.layout_settled = true;
        return;
    }

    // Map snap note id → graph index before laying out — the force layout needs the edges.
    var snap_to_graph = std.AutoHashMap(i64, usize).init(arena);
    try snap_to_graph.ensureTotalCapacity(@intCast(order.items.len));
    for (order.items, 0..) |si, gi| {
        try snap_to_graph.put(snap.nodes[si].id, gi);
    }

    var edge_list: std.ArrayList(GraphEdge) = .empty;
    var seen = std.AutoHashMap(u64, void).init(arena);
    for (snap.edges) |e| {
        const ai = snap_to_graph.get(e.src_id) orelse continue;
        const bi = snap_to_graph.get(e.dst_id) orelse continue;
        if (ai == bi) continue;
        const lo: u64 = @intCast(@min(ai, bi));
        const hi: u64 = @intCast(@max(ai, bi));
        const key = (lo << 32) | hi;
        const gop = try seen.getOrPut(key);
        if (gop.found_existing) continue;
        // Keep source→dest order for the connect animation; layout treats edges as undirected.
        try edge_list.append(arena, .{ .a = ai, .b = bi });
    }
    const layout_edges = try arena.alloc(layout_full.Edge, edge_list.items.len);
    for (edge_list.items, 0..) |e, i| layout_edges[i] = .{ .a = e.a, .b = e.b };

    const n = order.items.len;
    var seeds = try arena.alloc(?dvui.Point, n);
    var degrees = try arena.alloc(u32, n);
    const sigs = try linkSignatures(arena, n, order.items, snap.nodes, edge_list.items);
    // A node is anchored when nothing about *its own* links moved, so the layout can hold it
    // still. Not carrying a seed means there is nowhere to hold it, and a first build has no
    // previous arrangement worth preserving at all.
    var anchored = try arena.alloc(bool, n);
    // The one-step history each node should carry *out* of this rebuild, decided alongside its
    // seed and applied when the nodes are built below.
    var hist_sig = try arena.alloc(u64, n);
    var hist_target = try arena.alloc(dvui.Point, n);
    var hist_valid = try arena.alloc(bool, n);
    // Whose own links moved this rebuild, and who is being deliberately put back somewhere. Both
    // feed the neighbour pass below; neither is the same as `anchored`, which the undo branch
    // sets true for a node whose links *did* change.
    const changed = try arena.alloc(bool, n);
    const undo_hold = try arena.alloc(bool, n);
    @memset(changed, false);
    @memset(undo_hold, false);
    for (order.items, 0..) |si, gi| {
        const info = snap.nodes[si];
        degrees[gi] = info.degree;
        hist_valid[gi] = false;
        hist_sig[gi] = 0;
        hist_target[gi] = .{};
        const prev = carry.get(info.id) orelse {
            seeds[gi] = null;
            anchored[gi] = false;
            changed[gi] = true;
            continue;
        };
        if (reshape) {
            // Pane settled on new proportions. Nothing is anchored: `reshape_only` skips the force
            // pass so every island keeps its internal arrangement, and the packer re-parks whole
            // islands into a fresh ellipse for the new aspect.
            seeds[gi] = prev.target;
            anchored[gi] = false;
            hist_sig[gi] = prev.prev_sig;
            hist_target[gi] = prev.prev_target;
            hist_valid[gi] = prev.prev_valid;
        } else if (prev.link_sig == sigs[gi]) {
            // Nothing about its own links moved, so hold it where it was and leave its history
            // untouched — an unrelated edit elsewhere shouldn't consume this node's one undo.
            // Seed from the previous *layout home* so a mid-flight animation doesn't bias the
            // next force solve toward a half-travelled position.
            seeds[gi] = prev.target;
            anchored[gi] = !first_build;
            hist_sig[gi] = prev.prev_sig;
            hist_target[gi] = prev.prev_target;
            hist_valid[gi] = prev.prev_valid;
            continue;
        }
        // Its links changed, so the position it held under them is now the history.
        hist_sig[gi] = prev.link_sig;
        hist_target[gi] = prev.target;
        hist_valid[gi] = true;
        if (!first_build and prev.prev_valid and prev.prev_sig == sigs[gi]) {
            // Back to the exact links it had one change ago: this edit undid the last one, so
            // put it back in the cell it had then and hold it there. Re-solving instead would
            // land it somewhere new — the layout only sees the graph as it is now, and a node
            // freshly cut loose from a cluster gets pushed clear of it rather than home.
            seeds[gi] = prev.prev_target;
            anchored[gi] = true;
            undo_hold[gi] = true;
        } else {
            seeds[gi] = prev.target;
            anchored[gi] = false;
        }
        changed[gi] = true;
    }

    // Free the immediate neighbours of anything that changed.
    //
    // Holding a node because *its own* links are unchanged is what makes an edit look local, and
    // it is right for the vault at large — but it is too tight one hop out. A note that gains a
    // link is usually gaining it from a hub, and the hub's other notes are exactly the ones that
    // have to shuffle to make room: only six cells touch a hub, so the seventh note to link to it
    // has to sit on the second ring, and if the first six cannot move, it lands wherever is left
    // — often directly behind one of them, with the link to it drawn straight through that note.
    // Neither the solve nor the uncross pass can undo that, because every node that would have to
    // move is pinned.
    //
    // One hop is still local: these are the notes the edit is *about*. What this deliberately
    // does not do is free their neighbours in turn, which is how a single link ends up towing two
    // islands together — see `layout_full`'s module doc.
    if (!first_build and !reshape) {
        for (edge_list.items) |e| {
            if (changed[e.a] and !undo_hold[e.b]) anchored[e.b] = false;
            if (changed[e.b] and !undo_hold[e.a]) anchored[e.a] = false;
        }
    }

    const targets = try arena.alloc(dvui.Point, n);
    const paths = try arena.alloc([][]const u8, 1);
    paths[0] = try arena.alloc([]const u8, n);
    for (order.items, 0..) |si, gi| paths[0][gi] = snap.nodes[si].path;

    job.n = n;
    job.order = try order.toOwnedSlice(arena);
    job.edges = try edge_list.toOwnedSlice(arena);
    job.layout_edges = layout_edges;
    job.seeds = seeds;
    job.degrees = degrees;
    job.anchored = anchored;
    job.paths = paths[0];
    job.sigs = sigs;
    job.hist_sig = hist_sig;
    job.hist_target = hist_target;
    job.hist_valid = hist_valid;
    job.changed = changed;
    job.targets = targets;
    // Synth: packed positions keyed by note id 1..N → graph index after id-sort is 0..N-1.
    if (st.synth_mode) {
        if (st.synth_pos) |pos| {
            if (pos.len == n) job.precomputed = try arena.dupe(dvui.Point, pos);
        }
    }

    // Small vaults solve here and now: a worker would cost a frame of latency for work that is
    // already too fast to see. Everything bigger goes to a thread, and the panel draws a spinner
    // over whatever it had (see `draw`) instead of locking the editor for the duration.
    // Synth precomputed jobs always use the worker above a few thousand — quadtree build is the cost.
    if (n <= layout_inline_max and job.precomputed == null) {
        defer job.deinit(gpa);
        try job.solve();
        try finishRebuild(p, st, job);
        return;
    }

    job.thread = std.Thread.spawn(.{}, LayoutJob.run, .{job}) catch {
        // No thread available — better a hitch than no graph.
        defer job.deinit(gpa);
        try job.solve();
        try finishRebuild(p, st, job);
        return;
    };
    p.job = job;
}

/// Turn a solved job into the panel's live arrangement. UI thread only, and only once `done`.
fn finishRebuild(p: *Panel, st: anytype, job: *LayoutJob) !void {
    const gpa = sdk.allocator();
    const snap = job.snap;
    const n = job.n;
    const targets = job.targets;
    const first_build = job.first_build;
    const reshape = job.reshape;

    // Same carry the prep pass took — `p.nodes` has not moved since, because the panel's arena
    // is only recycled on the line below.
    var carry = std.AutoHashMap(i64, GraphNode).init(gpa);
    defer carry.deinit();
    for (p.nodes) |node| carry.put(node.note_id, node) catch {};

    _ = p.arena.reset(.free_all);
    p.id_index.clearRetainingCapacity();
    const arena = p.arena.allocator();
    p.gen = job.gen;
    // Every completed solve, whatever prompted it. `gen` tracks the *index*, and a reshape moves
    // every note in the vault without the index having changed at all — so anything cached
    // against positions has to watch this instead. See `Panel.atlas`.
    p.layout_epoch +%= 1;
    p.layout_aspect = job.aspect;
    p.note_count = snap.note_count;

    const sigs = job.sigs;
    const hist_sig = job.hist_sig;
    const hist_target = job.hist_target;
    const hist_valid = job.hist_valid;
    const changed = job.changed;
    const order = job.order;
    const open_hash = job.open_hash;

    p.layout_slot = layout_full.slotSpacingFor(n);
    p.at_level0 = arena.alloc(bool, n) catch &.{};
    p.notes_at_level0 = 0;
    // Union-find over all edges is a multi-second apply hitch at 400k — skip for synth / huge N.
    p.island_count = if (job.precomputed != null or n > 50_000) 0 else countIslands(n, job.layout_edges);

    // Extent of the laid-out web, read from the targets rather than assuming the layout's
    // own radius model.
    var world_r2: f32 = 0;
    var bmin: dvui.Point = .{ .x = 0, .y = 0 };
    var bmax: dvui.Point = .{ .x = 0, .y = 0 };
    for (targets) |t| {
        world_r2 = @max(world_r2, t.x * t.x + t.y * t.y);
        bmin.x = @min(bmin.x, t.x);
        bmin.y = @min(bmin.y, t.y);
        bmax.x = @max(bmax.x, t.x);
        bmax.y = @max(bmax.y, t.y);
    }
    p.world_radius = @sqrt(world_r2);
    p.world_bounds = .{ .x = bmin.x, .y = bmin.y, .w = bmax.x - bmin.x, .h = bmax.y - bmin.y };

    var nodes = try arena.alloc(GraphNode, n);
    var any_layout_move = false;
    // Synth / huge vaults: skip path/title dupes (Galaxy overview never labels all notes).
    const slim_labels = job.precomputed != null or n > 50_000;
    for (order, 0..) |si, gi| {
        const info = snap.nodes[si];
        const path = if (slim_labels) "" else try arena.dupe(u8, info.path);
        const title = if (slim_labels) "" else try arena.dupe(u8, info.title);
        var gn: GraphNode = .{
            .note_id = info.id,
            .path = path,
            .title = title,
            .phantom = info.phantom,
            .degree = info.degree,
            .link_sig = sigs[gi],
            .prev_sig = hist_sig[gi],
            .prev_target = hist_target[gi],
            .prev_valid = hist_valid[gi],
            .target = targets[gi],
            .home = targets[gi],
            .pos = targets[gi],
            .target_radius = radiusFor(info.degree, false, info.phantom),
            .radius = radiusFor(info.degree, false, info.phantom),
            .alpha = if (info.phantom) 0.55 else 1,
        };
        if (carry.get(info.id)) |prev| {
            gn.hover_t = prev.hover_t;
            gn.pointer_t = prev.pointer_t;
            gn.focus_t = prev.focus_t;
            gn.alpha = prev.alpha;
            // Carry the label's fade and chosen side so a reindex doesn't reshuffle every
            // name on screen. `label_len` deliberately does *not* carry — it indexes into
            // `title`, which this rebuild just reallocated and may have changed.
            // `applyOpenSet` recomputes this immediately; it is carried so that pass can see
            // the *previous* open state. Without it every reindex would look like a fresh
            // open and fly the camera.
            gn.open = prev.open;
            gn.label_vis = prev.label_vis;
            gn.label_slot = prev.label_slot;
            gn.label_rect = prev.label_rect;
            if (!first_build) {
                // Continue from where the node was drawn so the web eases into the new
                // configuration instead of teleporting.
                gn.home = prev.home;
                gn.pos = prev.pos;
                const dx = gn.target.x - gn.home.x;
                const dy = gn.target.y - gn.home.y;
                if (@abs(dx) > 0.05 or @abs(dy) > 0.05) any_layout_move = true;
            }
        }
        nodes[gi] = gn;
        try p.id_index.put(gpa, info.id, gi);
    }
    p.nodes = nodes;
    // The edge list lives in the job arena, which is about to go away — copy it across.
    p.edges = try arena.dupe(GraphEdge, job.edges);
    p.live_pos = try arena.alloc(dvui.Point, n);
    for (nodes, p.live_pos) |node, *q| q.* = node.pos;
    rewarmPointer(p);
    p.layout_settled = !any_layout_move;
    // The names have to be re-placed even if nothing moved — see `Panel.labels_stale`.
    p.labels_stale = true;
    p.edge_anim.clearRetainingCapacity();

    // The vault can be closed while a solve is in flight; the job's data is its own copy and is
    // still fine to apply, but there is no folder left to ask which notes are open.
    if (st.vault_root) |root| applyOpenSet(p, root, open_hash);

    // The layout just re-solved, so whatever the camera was framing has moved under it. Track
    // it. This is safe *because* of `.free`: a user who panned by hand is not retargeted, which
    // is what made the old "refit on reindex" behaviour so hostile — the watcher reindexes
    // every time you touch a file, and the view would jump out from under you on every click.
    //
    // `fitted_vp_*` is still deliberately left alone: that governs resize detection, and
    // clearing it here would make the next frame look like a first fit and *snap*.
    if (!first_build) applyFraming(p);

    // A note whose own links just changed is a note whose *neighbourhood* just changed shape —
    // and the neighbourhood is exactly what a focus pose frames (see `focusNode`). So adding a
    // link to the note you are looking at should re-frame it, the same way opening it did.
    // Without this the new neighbour lands somewhere off the edge of the view, or the pose stays
    // fitted to a neighbourhood that no longer exists.
    //
    // Overrides `.free` deliberately, which almost nothing else does: a hand pan is normally a
    // choice to be left alone, but it was a choice made about an arrangement that this edit just
    // changed. Only for the note being framed or read, never for an edit somewhere else in the
    // vault — that would yank the view on every keystroke in any open document.
    //
    // Not while descended. `.interior` means the reader is inside the note; re-framing would
    // eject them to the overview for what is, from in there, a change to the surroundings.
    if (!first_build and !reshape and p.framing != .interior) {
        const framed: ?i64 = switch (p.framing) {
            .note => |id| id,
            else => null,
        };
        var refocus: ?usize = null;
        if (framed) |id| {
            if (p.id_index.get(id)) |idx| {
                if (idx < n and changed[idx]) refocus = idx;
            }
        } else {
            // No note framed (the camera is free, or on extents) — fall back to an open one,
            // which is the closest thing to a selection there is.
            for (p.nodes, 0..) |node, idx| {
                if (node.open and idx < n and changed[idx]) {
                    refocus = idx;
                    break;
                }
            }
        }
        if (refocus) |idx| focusNode(p, idx);
    }
}

/// Which note's interior the view should show, if any. `t` is this frame's descent, measured
/// from the camera before anything is decided.
///
/// When the camera is framing an interior, that note wins — nearest-open used to rebuild
/// whichever tab sat under the camera centre, so a click on B after a failed enter on A could
/// still dive into A.
///
/// Otherwise the camera itself names the note. Zooming is meant to be literal, so aiming at a
/// node and pushing in is the same request as clicking it; only a click used to name one, which
/// left a hand-driven zoom blooming an interior *only* when a cloud happened to still be alive
/// from an earlier click — the "sometimes it works" the descent is reported to have.
fn interiorWant(p: *const Panel, t: f32) ?i64 {
    switch (p.framing) {
        .interior => |id| {
            if (p.id_index.contains(id)) return id;
            return null;
        },
        else => {
            // Fully at the vault: no descent to name anything for, and this is where a cloud
            // left over from a click gets dropped.
            if (t <= 0.002) return null;
            const aim = aimPoint(p);
            // Stay with the note being read while the aim is still on it. Without this the
            // choice would flicker between two nodes whenever the aim sat near the boundary
            // between them, rebuilding the cloud each time.
            if (p.interior.nodes.len > 0) {
                if (p.interior.note_id) |id| {
                    if (p.id_index.get(id)) |idx| {
                        if (withinSteps(p, p.nodes[idx].home, aim, aim_keep_steps)) return id;
                    }
                }
            }
            return nodeAtAim(p, aim) orelse p.interior.note_id;
        },
    }
}

/// The world point a hand-driven descent is aimed at: the cursor when it is over the panel,
/// otherwise the middle of the view.
///
/// The cursor, because that is what the zoom itself is anchored to — `zoomAtScreen` pushes in
/// around the pointer, so the node the reader is pointing at is the node that stays put on
/// screen while everything else slides outward. Choosing from the centre instead meant aiming at
/// a note and pushing in could open the one that happened to be nearest the middle, and getting
/// the one you wanted meant panning it to the centre first. With several notes in view at
/// descent zoom that is most of them.
///
/// Falls back to the centre when the pointer is elsewhere — a trackpad pinch with the cursor off
/// the panel, or a descent still easing after a click — where the middle of the view is the only
/// statement of intent there is.
fn aimPoint(p: *const Panel) dvui.Point {
    const mouse = dvui.currentWindow().mouse_pt;
    if (p.camera.viewport.contains(mouse)) return p.camera.screenToWorld(mouse);
    return p.camera.center;
}

/// True when `world` is within `steps` lattice steps of `aim`.
fn withinSteps(p: *const Panel, world: dvui.Point, aim: dvui.Point, steps: f32) bool {
    const slot = aimSlot(p);
    const dx = world.x - aim.x;
    const dy = world.y - aim.y;
    const r = slot * steps;
    return dx * dx + dy * dy <= r * r;
}

fn aimSlot(p: *const Panel) f32 {
    return if (p.layout_slot > 1) p.layout_slot else layout_full.slotSpacingFor(@max(p.nodes.len, 1));
}

/// How near the aim has to be to a node before its interior is the one that opens, and how far
/// the aim may drift off the note already open before it gives way. The gap between them is the
/// dead band that stops the two swapping back and forth across a boundary — and it is generous
/// on the keep side because leaving is a decision the reader makes by moving somewhere else, not
/// something a few pixels of drift should do for them.
const aim_pick_steps: f32 = 1.0;
const aim_keep_steps: f32 = 1.6;

/// The overview node the reader is pointed at, if any — the note a hand-driven descent opens.
fn nodeAtAim(p: *const Panel, aim: dvui.Point) ?i64 {
    const slot = aimSlot(p);
    // Beyond one step the aim is on empty grid between notes, so blooming the nearest one would
    // open something nobody asked for.
    var best_d2 = slot * slot * aim_pick_steps * aim_pick_steps;
    var best: ?i64 = null;
    for (p.nodes) |n| {
        // A phantom is a link with no file behind it — there are no sections to lay out.
        if (n.phantom) continue;
        if (p.interior.fail_id) |f| {
            if (f == n.note_id) continue;
        }
        const dx = n.home.x - aim.x;
        const dy = n.home.y - aim.y;
        const d2 = dx * dx + dy * dy;
        if (d2 < best_d2) {
            best_d2 = d2;
            best = n.note_id;
        }
    }
    return best;
}

/// Build (or drop) the interior cloud, and recompute how far into it the camera is.
///
/// Only builds when framing an interior (or finishing a cross-fade out). Building the nearest
/// open note's cloud at overview zoom was a sync layout hitch on every file open and kept
/// paying for a cloud nothing was looking at.
fn updateInterior(p: *Panel, st: anytype) void {
    // Measure the descent *first*, from the camera alone. Reading it back off the stored `t` is
    // what made a hand-driven zoom unreliable: with no cloud alive the early-outs below pinned
    // `t` to 0, so "am I descending?" answered no however far in the camera actually was, and
    // nothing ever asked for a cloud to be built.
    const t = interior.descentAt(
        hex.layoutLevelFor(@max(p.nodes.len, 1)),
        p.camera.zoom,
        @min(p.camera.viewport.w, p.camera.viewport.h),
    );

    const gen = st.generation.load(.acquire);
    // A reindex may well have given the note the sections it was missing — let it be tried again.
    if (p.interior.fail_gen != gen) {
        p.interior.fail_id = null;
        p.interior.fail_gen = gen;
    }

    const want = interiorWant(p, t);

    if (want == null) {
        if (p.interior.note_id != null and t <= 0.002) p.interior.clear();
        if (p.interior.note_id == null) {
            p.interior.t_prev = p.interior.t;
            p.interior.t = 0;
            return;
        }
        // Still fading out with no framed target — keep the existing cloud, don't rebuild.
    } else {
        p.interior.note_id = want;
    }

    const id = p.interior.note_id orelse {
        p.interior.t_prev = p.interior.t;
        p.interior.t = 0;
        return;
    };
    // The note has to still be in the overview — the cloud hangs off its node, and a note that
    // was deleted or unindexed while open has nothing left to hang off.
    if (!p.id_index.contains(id)) {
        p.interior.clear();
        return;
    }

    // Only (re)build while we intend to be inside, the camera is on its way in, or the
    // aspect/gen of an in-flight cloud moved. Building at overview zoom was a sync layout hitch
    // on every file open, paid for a cloud nothing was looking at.
    const should_build = p.framing == .interior or p.interior.nodes.len > 0 or t > 0.002;
    if (should_build and (p.interior.built_id != id or p.interior.built_gen != gen or
        p.interior.built_aspect != p.layout_aspect))
    {
        buildInteriorWorld(p, st, id, gen) catch {
            p.interior.clear();
            // Remember the miss, or the picker hands the same note straight back next frame and
            // the failed layout runs again for as long as the camera stays pointed at it.
            p.interior.fail_id = id;
            p.interior.fail_gen = gen;
            return;
        };
    }

    // The actual `fitInteriorSun` call is deferred to `applyInteriorFramingIfNeeded`, run later in
    // the frame after `stepWorld`/`stepInteriorWorld` have refreshed `p.nodes[idx].home` and
    // `p.interior.parent` for *this* frame — see that function's doc comment for why calling it
    // from here, before those run, pinned the camera to a one-frame-stale sun position.
    p.interior.t_prev = p.interior.t;
    p.interior.t = t;
}

/// World-space radial gap between one outline depth and the next, in the interior's own local
/// units — headings on inner rings, their attached content a band further out.
const interior_ring_gap: f32 = 1.6;
/// How far outside its own heading's ring a non-heading item (paragraph, list, tag, ...) sits.
const interior_content_offset: f32 = 0.6;

/// Build a note's interior as an "asteroid field": every content item placed directly by polar
/// position, angle from document order (swept clockwise around the full circle) and radius from
/// outline depth — headings inner, their own content a band further out, deeper headings further
/// still. Not fold/containment: that pipeline packs a *tree* by disc-in-disc containment, which
/// needs real branching to look like anything but a curling spiral — a typical document's
/// headings are tied to each other only by document order (no `[[Note#Heading]]` cross-links most
/// of the time), which is a flat chain topologically, and a chain packed as a tree is a spiral.
/// Measured directly against gauntlet's giant-0.md (401 flat headings): the fold/containment
/// version rendered as one dense curling band; this one is exactly the ring layout it now is.
///
/// Item 0 (the document root) is not part of this field at all: it is pinned at the centre as the
/// "sun," the same invariant `fitInteriorSun` already relies on (`p.interior.nodes[0]` equals
/// `p.interior.parent` by construction). `.outline` edges from the root to a top-level heading are
/// dropped from the fields below (`parent_level`/`item_kind` walks) for the same reason they no
/// longer feed a shared packing structure: root is drawn separately, nothing else needs to know it
/// exists.
fn buildInteriorWorld(p: *Panel, st: anytype, id: i64, gen: u64) !void {
    if (st.db == null) return error.NoDb;
    const db = &st.db.?;
    _ = p.interior.arena.reset(.retain_capacity);
    const arena = p.interior.arena.allocator();

    const idx = p.id_index.get(id) orelse return error.NoNode;
    const cg = try query.noteContentGraph(db, arena, id, p.nodes[idx].title);
    if (cg.items.len == 0) return error.Empty;

    // Absorb a lone top-level heading into the sun. A document whose only top-level content is
    // one heading — the mechanical "# Title" pattern, where that heading's text just repeats the
    // note's own title — would otherwise draw two nodes carrying the same label sitting almost on
    // top of each other: the sun, and that heading. When root has exactly one outline-child and
    // it is a heading, treat it as the document's own entry point instead of a second node: borrow
    // its line for the sun's "reveal position" and drop it from the content graph. Its own children
    // keep their items but lose their one edge to it, which needs no special handling below — an
    // item with no resolved outline-parent just falls back to depth 0, same band as any other
    // now-parentless top-level heading.
    var sun_line: u32 = 0;
    var skip: ?u32 = null;
    {
        var root_child: ?u32 = null;
        var root_children: u32 = 0;
        for (cg.edges) |e| {
            if (e.a != 0) continue;
            root_children += 1;
            root_child = e.b;
        }
        if (root_children == 1) if (root_child) |rc| {
            if (rc < cg.items.len and cg.items[rc].kind == .heading) {
                skip = rc;
                sun_line = cg.items[rc].line;
            }
        };
    }

    const remap = try arena.alloc(i32, cg.items.len);
    var out_n: usize = 0;
    for (0..cg.items.len) |i| {
        if (skip != null and i == skip.?) {
            remap[i] = -1;
        } else {
            remap[i] = @intCast(out_n);
            out_n += 1;
        }
    }
    const items = try arena.alloc(content_graph.Item, out_n);
    for (0..cg.items.len) |i| {
        if (remap[i] >= 0) items[@intCast(remap[i])] = cg.items[i];
    }
    var edges_list: std.ArrayList(content_graph.ItemEdge) = .empty;
    for (cg.edges) |e| {
        if (e.a >= remap.len or e.b >= remap.len) continue;
        if (remap[e.a] < 0 or remap[e.b] < 0) continue;
        try edges_list.append(arena, .{ .a = @intCast(remap[e.a]), .b = @intCast(remap[e.b]), .kind = e.kind });
    }
    const edges = edges_list.items;

    const n = items.len;
    const m = n - 1; // everything but the root

    const item_kind = try arena.alloc(content_graph.ItemKind, n);
    for (items, 0..) |it, i| item_kind[i] = it.kind;

    // Outline depth per item — headings use their own ATX level directly; everything else takes
    // its nearest enclosing heading's level (via the one `.outline` edge every non-root item has)
    // and sits `interior_content_offset` further out, so a section's body reads as *its* band,
    // one step beyond the heading that owns it.
    var parent_level = try arena.alloc(i32, n);
    @memset(parent_level, -1);
    for (edges) |e| {
        if (e.kind != .outline) continue;
        if (e.b < n) parent_level[e.b] = @intCast(items[e.a].level);
    }
    const depth = try arena.alloc(f32, n);
    depth[0] = 0;
    for (1..n) |i| {
        if (items[i].kind == .heading) {
            depth[i] = @floatFromInt(items[i].level);
        } else {
            const pl = if (parent_level[i] >= 0) parent_level[i] else 0;
            depth[i] = @as(f32, @floatFromInt(pl)) + interior_content_offset;
        }
    }

    // Polar position: angle is this item's rank in document order swept clockwise around the full
    // turn (so "next in the document" is also "next around the ring"); radius is its depth band.
    const local_pos = try arena.alloc(dvui.Point, n);
    local_pos[0] = .{}; // unused — the sun is pinned at `parent`, not placed in this space
    var extent: f32 = 1.0;
    for (1..n) |i| {
        const rank: f32 = @floatFromInt(i - 1);
        const a = (rank / @as(f32, @floatFromInt(@max(m, 1)))) * std.math.tau;
        const r = 1.0 + depth[i] * interior_ring_gap;
        local_pos[i] = .{ .x = @cos(a) * r, .y = @sin(a) * r };
        extent = @max(extent, r);
    }
    p.interior.local_pos = local_pos;
    p.interior.item_kind = item_kind;

    // Scale chosen continuously from the field's own extent, not `interior.nest()`'s hex-level
    // quantization plus forced `min_descent_levels` floor. That floor adds shrink-steps a small
    // field never needed — the same fixed minimum "journey" applied whether the cloud held 2
    // items or 2,000, so a two-item note (most of gauntlet's `islands/` demo, once the sun absorbs
    // the lone top-level heading) rendered exactly as zoomed-out as a huge one. `berth` is "how
    // much of the parent's own hex cell this cloud may fill" — the same quantity `interior.nest()`
    // computes it from internally — and `scale` is simply picked so the field's own `extent` fills
    // that berth exactly: a small field sits close, a large one still fits, continuously in
    // between rather than snapping between fixed hex levels.
    const vault_level = hex.layoutLevelFor(@max(p.nodes.len, 1));
    const berth = @max(hex.levelSpacing(vault_level), 1) * interior.default_footprint;
    const scale = berth / @max(extent, 1e-3);
    p.interior.nest = .{ .steps = 0, .scale = scale, .level = vault_level, .clamped = false };
    p.interior.slot = interior_ring_gap * p.interior.nest.scale;
    p.interior.radius = extent * p.interior.nest.scale;
    p.interior.parent = p.nodes[idx].home;

    const nodes = try arena.alloc(GraphNode, n);
    nodes[0] = .{
        .note_id = items[0].id,
        .line = sun_line,
        .is_sun = true,
        .path = p.nodes[idx].path,
        .title = items[0].text,
        .phantom = false,
        .degree = 64,
        .target = p.interior.parent,
        .home = p.interior.parent,
        .pos = p.interior.parent,
        .target_radius = radiusFor(64, false, false),
        .radius = radiusFor(64, false, false),
        .alpha = 1,
    };
    for (items[1..], 1..) |it, i| {
        nodes[i] = .{
            .note_id = it.id,
            // Line for `revealPosition` on click — every content kind has one now, not just
            // headings.
            .line = it.line,
            .is_sun = false,
            .path = p.nodes[idx].path,
            .title = it.text,
            .phantom = false,
            .degree = it.weight,
            .target = p.interior.parent,
            .home = p.interior.parent,
            .pos = p.interior.parent,
            .target_radius = radiusFor(it.weight, false, false),
            .radius = radiusFor(it.weight, false, false),
            // No coalescing in this layout — every item is always drawn as itself.
            .alpha = 1,
        };
    }

    const graph_edges = try arena.alloc(GraphEdge, edges.len);
    for (edges, 0..) |e, i| graph_edges[i] = .{ .a = e.a, .b = e.b };

    p.interior.nodes = nodes;
    p.interior.edges = graph_edges;
    p.interior.built_id = id;
    p.interior.built_gen = gen;
    p.interior.built_aspect = p.layout_aspect;
}

/// Refresh the interior's world positions for this frame from `p.interior.local_pos`, mirroring
/// `stepWorld` one level down but with no LOD to decide — every item is drawn as itself, always
/// (see `buildInteriorWorld`'s doc comment for why there is no coalescing budget here to run).
///
/// The sun (item 0) is repositioned directly from the parent note's *current* position every
/// frame — not carried forward with a delta the way `followParent` carries the old orbit system —
/// so there is nothing left for `followParent` to do here; it still runs, but finds `parent`
/// already current and returns immediately.
fn stepInteriorWorld(p: *Panel) void {
    if (p.interior.nodes.len == 0) return;
    const id = p.interior.note_id orelse return;
    const idx = p.id_index.get(id) orelse return;
    p.interior.parent = p.nodes[idx].home;

    const sun = &p.interior.nodes[0];
    sun.target = p.interior.parent;
    sun.home = p.interior.parent;
    sun.pos = p.interior.parent;

    p.interior_visible.clearRetainingCapacity();
    p.interior_visible.append(sdk.allocator(), .{ .level = 0, .index = 0, .alpha = 1 }) catch {};

    for (p.interior.local_pos, 0..) |local, i| {
        if (i == 0) continue;
        if (i >= p.interior.nodes.len) continue;
        const n = &p.interior.nodes[i];
        const world = interior.toWorld(local, p.interior.nest, p.interior.parent);
        n.home = world;
        n.target = world;
        n.pos = world;
        n.alpha = 1;
        p.interior_visible.append(sdk.allocator(), .{ .level = 0, .index = @intCast(i), .alpha = 1 }) catch {};
    }
}

/// Re-place the interior's nodes after the parent node has eased somewhere new, so the cloud
/// travels with its note instead of being left behind by a relayout.
fn followParent(p: *Panel) void {
    if (p.interior.nodes.len == 0) return;
    const id = p.interior.note_id orelse return;
    const idx = p.id_index.get(id) orelse return;
    const parent = p.nodes[idx].home;
    if (@abs(parent.x - p.interior.parent.x) < 0.01 and
        @abs(parent.y - p.interior.parent.y) < 0.01) return;
    const dx = parent.x - p.interior.parent.x;
    const dy = parent.y - p.interior.parent.y;
    for (p.interior.nodes) |*n| {
        n.target.x += dx;
        n.target.y += dy;
        n.home.x += dx;
        n.home.y += dy;
        n.pos.x += dx;
        n.pos.y += dy;
    }
    p.interior.parent = parent;
}

fn applyOpenSet(p: *Panel, vault: []const u8, open_hash: u64) void {
    // The very first pass is the panel finding out what is already open, not the user opening
    // anything — `maybeFitCamera` owns that frame's pose.
    const first = p.open_hash == std.math.maxInt(u64);

    var was_any = false;
    for (p.nodes) |*n| {
        n.was_open = n.open;
        was_any = was_any or n.open;
        n.open = false;
        n.focus_t = 0;
        n.target_radius = radiusFor(n.degree, false, n.phantom);
    }
    const wb = sdk.host().getServiceTyped(sdk.services.workbench.Api) orelse {
        p.open_hash = open_hash;
        return;
    };
    const n_open = wb.openCount();
    var i: usize = 0;
    while (i < n_open) : (i += 1) {
        const abs = wb.openPathAt(i) orelse continue;
        if (!query.isMarkdownPath(abs)) continue;
        const rel = query.vaultRelative(vault, abs) orelse continue;
        for (p.nodes) |*node| {
            if (!std.mem.eql(u8, node.path, rel)) continue;
            node.open = true;
            node.focus_t = 1;
            node.target_radius = radiusFor(node.degree, true, node.phantom);
            break;
        }
    }
    p.open_hash = open_hash;
    if (first) return;

    const framed_id: ?i64 = switch (p.framing) {
        .note, .interior => |id| id,
        else => null,
    };

    var is_any = false;
    var changed = false;
    var opened: ?usize = null;
    var first_open: ?usize = null;
    var framed_still_open = false;
    for (p.nodes, 0..) |n, idx| {
        if (n.open != n.was_open) changed = true;
        if (!n.open) continue;
        is_any = true;
        if (first_open == null) first_open = idx;
        if (!n.was_open and opened == null) opened = idx;
        if (framed_id) |id| framed_still_open = framed_still_open or id == n.note_id;
    }
    // A reindex that didn't touch the tabs — `rebuildIfNeeded` re-applies the framing itself.
    if (!changed) return;

    // Closing the note we had descended into must eject the camera. `fitToNodes` used to pin
    // to the interior whenever descent `t` was high, so "zoom to extents" on close retargeted
    // the same inner pose and never left — leaving you stranded at interior zoom with no open
    // document. Drop interior framing here; the cloud itself stays until `t` falls so the
    // cross-fade can still play on the way out.
    const leaving_interior = switch (p.framing) {
        .interior => |id| !noteOpen(p, id),
        else => false,
    };
    if (leaving_interior) p.framing = .extents;

    if (!is_any) {
        // Closing the last note leaves nothing to be looking *at* — pull back to the whole
        // web rather than stranding the view wherever the last note happened to be.
        if (was_any) zoomExtents();
        return;
    }
    if (opened) |idx| {
        // Graph clicks already `focusNode` / set interior framing before the open set flips.
        // Re-flying here stacked a second camera retarget on top of the first and hitched the
        // ease whenever the tab list caught up a frame later.
        const id = p.nodes[idx].note_id;
        const already = switch (p.framing) {
            .note, .interior => |fid| fid == id,
            else => false,
        };
        if (!already) focusNode(p, idx);
        return;
    }

    // Nothing opened, but the set changed — a note was closed while others stayed open. Reframe
    // around what is left, so closing a tab tightens onto the remaining ones instead of leaving
    // the camera holding room for a note that is no longer there.
    if (framed_still_open and !leaving_interior) {
        applyFraming(p);
    } else if (first_open) |idx| {
        focusNode(p, idx);
    }
}

fn noteOpen(p: *const Panel, id: i64) bool {
    const idx = p.id_index.get(id) orelse return false;
    return p.nodes[idx].open;
}

/// Fly the camera to the open selection. Retargets only — `animateCamera` does the easing,
/// which is a plain exponential chase and so cannot overshoot.
///
/// The selection is every open document, plus `idx` (graph clicks run before the tab list
/// flips that note open). Open notes are always kept in frame and the camera centres on their
/// centroid — one open note zooms in on it, many open notes frame the whole set. Zoom-*out*
/// is floored at the extents pose so a spread-out selection never pulls further back than the
/// center/maximize button.
fn focusNode(p: *Panel, idx: usize) void {
    if (idx >= p.nodes.len) return;
    const vp = p.camera.viewport;
    if (vp.w < 32 or vp.h < 32) return;

    const arena = dvui.currentWindow().arena();

    // Selection = open docs. Always include `idx`: a graph click focuses before `openNode` runs,
    // and re-clicking an already-open note still means "frame the selection around this".
    const is_must = arena.alloc(bool, p.nodes.len) catch return;
    @memset(is_must, false);
    is_must[idx] = true;
    var must_n: usize = 1;
    for (p.nodes, 0..) |n, i| {
        if (i == idx or !n.open or is_must[i]) continue;
        is_must[i] = true;
        must_n += 1;
    }

    // Soft 1-hop neighbours — sizes the frame so the open-doc star is legible after a click,
    // without forcing every remote spoke into view (percentile coverage in `focus.frame`).
    const is_ctx = arena.alloc(bool, p.nodes.len) catch return;
    @memset(is_ctx, false);
    var ctx_n: usize = 0;
    for (p.edges) |e| {
        if (e.a >= p.nodes.len or e.b >= p.nodes.len) continue;
        const a_must = is_must[e.a];
        const b_must = is_must[e.b];
        if (a_must == b_must) continue;
        const other = if (a_must) e.b else e.a;
        if (is_ctx[other] or is_must[other]) continue;
        is_ctx[other] = true;
        ctx_n += 1;
    }

    const must_pts = arena.alloc(dvui.Point, must_n) catch return;
    var mi: usize = 0;
    for (p.nodes, 0..) |n, i| {
        if (!is_must[i]) continue;
        must_pts[mi] = focusPoseOf(p, i, n);
        mi += 1;
    }
    const ctx_pts = arena.alloc(dvui.Point, ctx_n) catch return;
    var ci: usize = 0;
    for (p.nodes, 0..) |n, i| {
        if (!is_ctx[i]) continue;
        ctx_pts[ci] = focusPoseOf(p, i, n);
        ci += 1;
    }
    const scratch = arena.alloc(f32, ctx_n) catch return;

    const slot = if (p.layout_slot > 1) p.layout_slot else layout_full.slotSpacingFor(p.nodes.len);
    const anchor = focusPoseOf(p, idx, p.nodes[idx]);
    const bounds = focus.bounds(anchor, must_pts, ctx_pts, slot, .{}, scratch);
    const pad = @min(focus_padding_px, vp.h * 0.15);
    var pose = p.camera.poseForBounds(bounds, pad);

    // As close as the selection allows, up to `focus_max_gap_px` (the dinner-plate stop), and
    // never further out than the center/maximize pose. Do not raise zoom past `z_fit` — that is
    // the tightest pose that still holds every open note.
    const z_fit = pose.zoom;
    pose.zoom = p.camera.clamp(@min(z_fit, focus_max_gap_px / slot));
    if (vaultExtentsPose(p)) |extents| {
        pose.zoom = @max(pose.zoom, extents.zoom);
    }

    // Must drop, or `animateCamera` suppresses the chase and the retarget just sits there.
    p.camera.user_driving = false;
    p.framing = .{ .note = p.nodes[idx].note_id };
    // A coasting pan would fight the flight and re-sync the targets out from under it.
    p.fling_x.cancel();
    p.fling_y.cancel();
    p.camera.center_target = pose.center;
    p.camera.zoom_target = pose.zoom;
    dvui.refresh(null, @src(), null);
}

/// World pose used when framing a note.
///
/// Only use a living agent pose when that note is drawn as itself (leaf agent). Climbing to a
/// coalesced mass centroid made focus/open-star framing jump to a random parent COM — the
/// "click pops the node somewhere else" failure.
fn focusPoseOf(p: *const Panel, note_i: usize, n: GraphNode) dvui.Point {
    // `stepWorld` publishes the living pose straight onto the node, so there is nothing to climb.
    _ = p;
    _ = note_i;
    return n.pos;
}


fn hashOpenNotes(vault: []const u8) u64 {
    var h: u64 = 14695981039346656037;
    const wb = sdk.host().getServiceTyped(sdk.services.workbench.Api) orelse return 0;
    const n = wb.openCount();
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const abs = wb.openPathAt(i) orelse continue;
        if (!query.isMarkdownPath(abs)) continue;
        const rel = query.vaultRelative(vault, abs) orelse continue;
        for (rel) |c| {
            h ^= c;
            h *%= 1099511628211;
        }
        h ^= 0xff;
        h *%= 1099511628211;
    }
    return h;
}

fn radiusFor(degree: u32, open: bool, phantom: bool) f32 {
    if (open) return open_node_r;
    const base = min_node_r + @sqrt(@as(f32, @floatFromInt(degree + 1))) * 2.5;
    const clamped = std.math.clamp(base, min_node_r, max_node_r);
    return if (phantom) clamped * 0.7 else clamped;
}

/// Connected-component count for the HUD. Loners / small islands are what carry pane proportions;
/// a single island cannot take a wide or tall shape without stretching its internals.
fn countIslands(n: usize, edges: []const layout_full.Edge) u32 {
    if (n == 0) return 0;
    var parent = sdk.allocator().alloc(usize, n) catch return 0;
    defer sdk.allocator().free(parent);
    for (0..n) |i| parent[i] = i;
    const find = struct {
        fn go(p: []usize, i: usize) usize {
            var x = i;
            while (p[x] != x) {
                p[x] = p[p[x]];
                x = p[x];
            }
            return x;
        }
    }.go;
    for (edges) |e| {
        if (e.a >= n or e.b >= n or e.a == e.b) continue;
        const ra = find(parent, e.a);
        const rb = find(parent, e.b);
        if (ra != rb) parent[rb] = ra;
    }
    var count: u32 = 0;
    for (0..n) |i| {
        if (find(parent, i) == i) count += 1;
    }
    return count;
}

/// Fit when we have never fitted to a real viewport, or the panel was resized a lot and the
/// user isn't driving the camera. Avoids the first-frame 0×0 fit that locked tiny zoom.
fn maybeFitCamera(p: *Panel) void {
    const vp = p.camera.viewport;
    if (vp.w < 32 or vp.h < 32) return;
    if (p.nodes.len == 0) return;

    const never = p.fitted_vp_w < 32 or p.fitted_vp_h < 32;
    // Any change at all, not a threshold. `applyFraming` retargets and lets the chase ease, so
    // running it per frame of a drag is what makes the framing *follow* the panel; the old 35%
    // gate meant a resize either did nothing or arrived as one late jump, and every drag short of
    // a third of the panel's size did nothing at all.
    const resized = !never and (vp.w != p.fitted_vp_w or vp.h != p.fitted_vp_h);
    if (!never and !(resized and !p.camera.user_driving)) return;

    if (never) {
        // No meaningful "from" pose to travel out of — snap it.
        fitToNodes(p, .{ .animate = false });
    } else {
        // A resize re-applies whatever the camera was framing, and eases there. Refitting to
        // extents unconditionally discarded a focus flight the moment the panel was dragged.
        applyFraming(p);
    }
    p.fitted_vp_w = vp.w;
    p.fitted_vp_h = vp.h;
}

/// Re-derive the camera pose for the current `framing`. Called whenever the thing the pose was
/// derived *from* has moved underneath it: the panel resized, or the index rebuilt and the
/// layout re-solved. Idempotent — re-running it against unchanged inputs retargets to where the
/// camera already is, and `chase` then does nothing.
/// Re-run `applyFraming` for an in-progress descent, once this frame's positions are current.
///
/// Must run *after* `stepWorld`/`stepInteriorWorld`, not from inside `updateInterior` (which runs
/// before both). `fitInteriorSun` pins the camera to `p.interior.nodes[0].target`, which is only
/// fresh once `stepInteriorWorld` has copied this frame's `p.nodes[idx].home` into it; calling it
/// from `updateInterior` instead pins the camera to *last* frame's sun position. Harmless while
/// the parent note is sitting still, but a visible one-frame lag while it's still easing — and if
/// framing happens to stop being re-applied (settled, `t` past its threshold) on exactly such a
/// frame, that lag freezes in as a small permanent-looking offset between the sun and the node the
/// reader actually clicked.
fn applyInteriorFramingIfNeeded(p: *Panel) void {
    if (p.framing == .interior and
        (!p.layout_settled or p.camera.chasing() or p.interior.t < 0.98))
    {
        applyFraming(p);
    }
}

fn applyFraming(p: *Panel) void {
    switch (p.framing) {
        .free => {},
        .extents => fitToNodes(p, .{ .animate = true }),
        .interior => |id| {
            // Require the note still open — a closed tab must not keep pinning the camera to a
            // descent that no longer has a document behind it.
            if (noteOpen(p, id) and p.interior.nodes.len > 0) {
                // Keep the exit sun where the doc node was: zoom to the interior cloud, but pin
                // the camera centre on the sun/parent. `fitToNodes` would recenter on the AABB
                // centroid and slide the sun off the point you zoomed into.
                fitInteriorSun(p, .{ .animate = true });
            } else {
                p.framing = .extents;
                fitToNodes(p, .{ .animate = true });
            }
        },
        .note => |id| {
            if (p.id_index.get(id)) |idx| {
                focusNode(p, idx);
            } else {
                // The focused note is gone (deleted, renamed, unindexed) — nothing to hold on
                // to, so fall back to the web.
                p.framing = .extents;
                fitToNodes(p, .{ .animate = true });
            }
        },
    }
}

const FitMode = struct { animate: bool };

/// Screen padding for zoom-to-extents / refit. Fraction of the short pane side so a square panel
/// and a letterbox panel keep the same relative margin; clamped so tiny panes still clear a
/// bubble+label and huge panes don't grow an ocean of empty grid.
fn fitPadPx(vp: dvui.Rect.Physical) f32 {
    const short = @min(vp.w, vp.h);
    const px = short * fit_pad_frac;
    // Let the margin track the pane; only clamp the extremes so tiny panes still clear a
    // bubble+label and enormous ones don't become empty oceans.
    return std.math.clamp(px, fit_edge_px, fit_label_px * 4.0);
}

/// Neighbour-gap ceiling for fit-to-extents. Scales with the pane so a small cloud on a large
/// window is allowed to zoom in and fill the view; the absolute floor keeps modest panels from
/// turning three notes into dinner plates.
fn fitMaxGapPx(vp: dvui.Rect.Physical) f32 {
    const short = @min(vp.w, vp.h);
    return @max(fit_max_gap_px, short * fit_max_gap_frac);
}

/// Zoom to the open note's interior while keeping the sun (parent doc node) fixed on screen.
/// That is what makes zooming *into* a node feel literal: headings bloom around the same point
/// the overview bubble occupied, and the sun is still the exit back out.
fn fitInteriorSun(p: *Panel, mode: FitMode) void {
    if (p.interior.nodes.len == 0) return;
    const slot = @max(p.interior.slot, 1);
    // Sun is interior root (index 0) and equals `interior.parent` by construction.
    const sun = p.interior.nodes[0].target;

    var max_r: f32 = slot;
    for (p.interior.nodes) |n| {
        const dx = n.target.x - sun.x;
        const dy = n.target.y - sun.y;
        max_r = @max(max_r, @sqrt(dx * dx + dy * dy));
    }
    // Square bounds centred on the sun so poseForBounds does not drift toward a lopsided heading
    // cluster. Zoom still fits the furthest heading; pan stays locked on the exit.
    const bounds: dvui.Rect = .{
        .x = sun.x - max_r,
        .y = sun.y - max_r,
        .w = max_r * 2,
        .h = max_r * 2,
    };
    const pad = fitPadPx(p.camera.viewport);
    var pose = p.camera.poseForBounds(bounds, pad);
    const max_gap = fitMaxGapPx(p.camera.viewport);
    if (slot * pose.zoom > max_gap) {
        pose.zoom = p.camera.clamp(@min(pose.zoom, max_gap / slot));
    }
    // Centre is the sun, not the AABB midpoint poseForBounds computed (same here, but keep the
    // invariant explicit so a future non-square berth cannot slide it).
    p.camera.center_target = sun;
    p.camera.zoom_target = pose.zoom;
    if (!mode.animate) {
        p.camera.center = sun;
        p.camera.zoom = pose.zoom;
    }
}

/// The vault pose the center/maximize button lands on. `focusNode` floors against this so a
/// selection never pulls the camera further out than overview.
fn vaultExtentsPose(p: *const Panel) ?Camera.Pose {
    if (p.nodes.len == 0) return null;
    const vp = p.camera.viewport;
    if (vp.w < 32 or vp.h < 32) return null;

    // Containment owns its own positions, and the islands are packed around the origin. Framing
    // `p.nodes` here would fit the classic layout's extent instead — a different arrangement
    // entirely — so read the world's island discs directly. O(islands), and exact.
    {
        if (p.world_state) |*w| {
            if (w.lad.roots.len > 0) {
                const e = w.extent();
                const pad_px: f32 = 24;
                const usable_w = @max(1, vp.w - pad_px * 2);
                const usable_h = @max(1, vp.h - pad_px * 2);
                const z = @min(usable_w, usable_h) / (2 * @max(e, 1e-3));
                return .{
                    .center = .{ .x = 0, .y = 0 },
                    .zoom = std.math.clamp(z, Camera.abs_min_zoom, Camera.max_zoom),
                };
            }
        }
    }

    const slot = if (p.layout_slot > 1) p.layout_slot else layout_full.slotSpacingFor(p.nodes.len);

    // World bounds of the node *centres*. What a node needs beyond its centre — its bubble, its
    // label — is a fixed size on screen, so that room is reserved in pixels below rather than in
    // world units here. Reserving it in slot fractions is what left the overview so far out: a
    // bubble is 9px across at overview while a slot can be 112 world units, so padding by 0.7 of a
    // slot per side asked for roughly eight times the room a bubble actually occupies.
    var min_x: f32 = std.math.floatMax(f32);
    var min_y: f32 = std.math.floatMax(f32);
    var max_x: f32 = -std.math.floatMax(f32);
    var max_y: f32 = -std.math.floatMax(f32);
    for (p.nodes) |n| {
        // Frame where the cloud is *going*, not the union of old and new homes. The union made
        // the first camera pose a loose mid-flight envelope, and the settle-pass re-tighten then
        // played as a second recenter after the nodes arrived. Targeting the destination lets
        // camera and layout ease in one motion; a node still on the way may briefly nick the
        // edge, which reads far better than a two-stage fly.
        const c = n.target;
        min_x = @min(min_x, c.x);
        min_y = @min(min_y, c.y);
        max_x = @max(max_x, c.x);
        max_y = @max(max_y, c.y);
    }

    const bounds: dvui.Rect = .{
        .x = min_x,
        .y = min_y,
        .w = @max(max_x - min_x, slot * 2),
        .h = @max(max_y - min_y, slot * 2),
    };
    // Padding is a fraction of the *short* pane side so square and letterbox panels keep the
    // same relative margin. Fixed pixel pads made squarish panes look emptier (and short wide
    // ones tighter) even when the cloud matched the aspect. Always reserve enough for a label
    // hanging off a bubble — switching pad when labels appear was a second source of the jump.
    const pad = fitPadPx(vp);
    var pose = p.camera.poseForBounds(bounds, pad);

    // Cap how far fit-to-extents may zoom in. The ceiling grows with the pane so a small cloud
    // on a large window still fills most of the view; a fixed 150px gap left big panels looking
    // empty. Never raises `pose.zoom` — only stops a near-empty vault from dinner-plating.
    const max_gap = fitMaxGapPx(vp);
    if (slot * pose.zoom > max_gap) {
        pose.zoom = p.camera.clamp(@min(pose.zoom, max_gap / slot));
    }
    return pose;
}

/// Frame a whole cloud — the vault's, or a note's own once you are inside it.
///
/// Level-agnostic on purpose. Descending is meant to *replace* the vault view rather than sit on
/// top of it, so once a note's cloud owns the panel it has to behave exactly as the vault's did:
/// fit to its own extents, reshape to the panel, respond to a zoom-to-extents. Anything that only
/// ever framed `p.nodes` would leave the inner level as a place you can look at but not use.
fn fitToNodes(p: *Panel, mode: FitMode) void {
    // Pin to the sun only while we *intend* to stay inside a note. Keying this off descent `t`
    // alone trapped the camera after a tab close: framing had already been set to `.extents`,
    // but `t` was still high, so every fit retargeted the interior and never zoomed out.
    // Zoom-to-extents while still inside keeps `.interior` framing (see `zoomExtents`).
    if (p.framing == .interior and p.interior.nodes.len > 0) {
        fitInteriorSun(p, mode);
        return;
    }
    const pose = vaultExtentsPose(p) orelse return;
    p.camera.center_target = pose.center;
    p.camera.zoom_target = pose.zoom;
    if (!mode.animate) {
        p.camera.center = pose.center;
        p.camera.zoom = pose.zoom;
    }
}

pub fn zoomExtents() void {
    if (panel == null) return;
    const p = &panel.?;
    // User-triggered recenter — retarget and let `animateCamera` ease us there.
    // `user_driving` must drop or the chase is suppressed. Record the viewport as fitted so
    // `maybeFitCamera` doesn't see "never fitted" next frame and snap on top of the animation.
    p.camera.user_driving = false;
    // Still inside an open note → tighten on that cloud (same intent as overview extents).
    // Otherwise frame the vault. Closing the descended note clears `.open` first, so this
    // path becomes the eject-to-overview the open-set handler wants.
    if (p.interior.note_id) |id| {
        if (p.interior.t >= 0.5 and p.interior.nodes.len > 0 and noteOpen(p, id)) {
            p.framing = .{ .interior = id };
            fitInteriorSun(p, .{ .animate = true });
            if (p.camera.viewport.w >= 32 and p.camera.viewport.h >= 32) {
                p.fitted_vp_w = p.camera.viewport.w;
                p.fitted_vp_h = p.camera.viewport.h;
            }
            dvui.refresh(null, @src(), null);
            return;
        }
    }
    p.framing = .extents;
    fitToNodes(p, .{ .animate = true });
    if (p.camera.viewport.w >= 32 and p.camera.viewport.h >= 32) {
        p.fitted_vp_w = p.camera.viewport.w;
        p.fitted_vp_h = p.camera.viewport.h;
    }
    dvui.refresh(null, @src(), null);
}

fn stepFling(p: *Panel) void {
    if (p.drag_active or p.gesture_active) return;
    var moved = false;
    if (p.fling_x.coasting) {
        if (p.fling_x.step(pan_fling_tuning)) |dx| {
            p.camera.panScreen(dx, 0);
            moved = true;
        }
    }
    if (p.fling_y.coasting) {
        if (p.fling_y.step(pan_fling_tuning)) |dy| {
            p.camera.panScreen(0, dy);
            moved = true;
        }
    }
    if (moved) {
        p.camera.user_driving = true;
        dvui.refresh(null, @src(), dvui.parentGet().data().id);
    } else if (!p.fling_x.coasting and !p.fling_y.coasting) {
        p.camera.user_driving = p.drag_active or p.gesture_active;
    }
}

/// Ease `center`/`zoom` toward their targets. Pan/zoom input keeps targets synced to the
/// live values, so this is a no-op unless something retargeted (focus, zoom-extents, resize).
fn animateCamera(p: *Panel) void {
    if (p.camera.user_driving) return;
    const dt = @min(dvui.secondsSinceLastFrame(), 1.0 / 30.0);
    if (p.camera.chase(dt, camera_chase_k)) {
        dvui.refresh(null, @src(), dvui.parentGet().data().id);
    }
}

fn drawEdgeSegment(
    batch: *LineBatch,
    sa: dvui.Point.Physical,
    sb: dvui.Point.Physical,
    t: f32,
    thickness: f32,
    color: dvui.Color,
    view: dvui.Rect.Physical,
    agent_web: bool,
) void {
    if (t <= 0.002) return;
    // Accelerate out of the node and settle into the far end. `outCubic` spends most of the
    // travel in the first few frames, which is right for something that should be over before
    // you notice it and wrong for something meant to be watched — at these durations it reads
    // as the line simply appearing, then creeping the last few pixels.
    const grow = dvui.easing.inOutCubic(std.math.clamp(t, 0, 1));
    const tip: dvui.Point.Physical = .{
        .x = sa.x + (sb.x - sa.x) * grow,
        .y = sa.y + (sb.y - sa.y) * grow,
    };
    // Cheap reject: both endpoints outside and on the same side.
    if (!segmentMaybeInView(sa, tip, view)) return;
    // Too short on screen to say anything — see `edgeLengthFade`.
    const len = @sqrt((tip.x - sa.x) * (tip.x - sa.x) + (tip.y - sa.y) * (tip.y - sa.y));
    const short = edgeLengthFade(len, agent_web);
    if (short <= 0.004) return;
    frame_profile.edges_drawn += 1;
    // Fade alongside the extension so a short stub reads as forming, not as a stray tick.
    batch.add(sa, tip, thickness, color.opacity((0.35 + 0.65 * grow) * short));
}

/// The web in one draw call. Same reasoning as `DiscBatch`, and it matters more here: there are
/// several links per note, and a stroke is a longer tessellation than a fill.
///
/// A link is a quad — two triangles across the segment's width. No caps and no join, which a
/// two-point polyline does not need anyway, and no antialiasing along the edge; at the widths
/// the web is drawn at, against a fill this faint, the difference is not visible.
const LineBatch = struct {
    arena: std.mem.Allocator,
    b: ?dvui.Triangles.Builder = null,

    const verts_per: usize = 4;
    const idx_per: usize = 6;
    const max_lines: usize = std.math.maxInt(u16) / verts_per;

    fn init(arena: std.mem.Allocator) LineBatch {
        return .{ .arena = arena };
    }

    fn add(
        self: *LineBatch,
        a: dvui.Point.Physical,
        b_pt: dvui.Point.Physical,
        thickness: f32,
        color: dvui.Color,
    ) void {
        const dx = b_pt.x - a.x;
        const dy = b_pt.y - a.y;
        const len = @sqrt(dx * dx + dy * dy);
        if (len < 1e-3) return;
        // Half-width normal to the segment, which is what turns the line into a quad.
        const h = @max(thickness, 0.75) * 0.5;
        const nx = -dy / len * h;
        const ny = dx / len * h;

        if (self.b) |*bb| {
            if (bb.vertexes.items.len / verts_per >= max_lines) self.flush();
        }
        if (self.b == null) {
            self.b = dvui.Triangles.Builder.init(
                self.arena,
                max_lines * verts_per,
                max_lines * idx_per,
            ) catch return;
        }
        const bb = &(self.b.?);

        const base: u16 = @intCast(bb.vertexes.items.len);
        const col: dvui.Color.PMA = .fromColor(color);
        bb.appendVertex(.{ .pos = .{ .x = a.x + nx, .y = a.y + ny }, .col = col });
        bb.appendVertex(.{ .pos = .{ .x = a.x - nx, .y = a.y - ny }, .col = col });
        bb.appendVertex(.{ .pos = .{ .x = b_pt.x - nx, .y = b_pt.y - ny }, .col = col });
        bb.appendVertex(.{ .pos = .{ .x = b_pt.x + nx, .y = b_pt.y + ny }, .col = col });
        bb.appendTriangles(&.{ base, base + 1, base + 2, base, base + 2, base + 3 });
    }

    fn flush(self: *LineBatch) void {
        var b = self.b orelse return;
        self.b = null;
        if (b.vertexes.items.len == 0) return;
        dvui.renderTriangles(b.build_unowned(), null) catch {};
    }
};

/// World radius of the mark standing for one level, matching what `emitMarks` draws.
fn markWorldRadius(p: *const Panel, level: u32) f32 {
    if (level == 0) return 0;
    const py = p.pyramid orelse return 0;
    if (level >= py.spacing.len) return 0;
    return gap_radius_frac * py.spacing[level];
}

/// Pull a segment's ends in by `ra` and `rb`, or null if there is nothing left of it.
///
/// What is left is the part of the link that runs *between* the two things it joins, which is the
/// only part that says anything: the stretch inside a region is hidden behind that region's own
/// drawing everywhere except where it is drawn as a picture, and there it is a line across the
/// middle of a cluster going nowhere.
fn trimToEnds(
    a: dvui.Point.Physical,
    b: dvui.Point.Physical,
    ra: f32,
    rb: f32,
) ?[2]dvui.Point.Physical {
    if (ra <= 0 and rb <= 0) return .{ a, b };
    const dx = b.x - a.x;
    const dy = b.y - a.y;
    const len = @sqrt(dx * dx + dy * dy);
    // Nothing between them: one region contains the other's centre, so there is no link to see.
    if (len <= ra + rb + 1e-3) return null;
    const ux = dx / len;
    const uy = dy / len;
    return .{
        .{ .x = a.x + ux * ra, .y = a.y + uy * ra },
        .{ .x = b.x - ux * rb, .y = b.y - uy * rb },
    };
}

fn segmentMaybeInView(a: dvui.Point.Physical, b: dvui.Point.Physical, view: dvui.Rect.Physical) bool {
    if (view.contains(a) or view.contains(b)) return true;
    // Bounding-box overlap.
    const min_x = @min(a.x, b.x);
    const max_x = @max(a.x, b.x);
    const min_y = @min(a.y, b.y);
    const max_y = @max(a.y, b.y);
    return !(max_x < view.x or min_x > view.x + view.w or max_y < view.y or min_y > view.y + view.h);
}

const DrawNodesOpts = struct {
    /// Interior root (index 0 / `note_id == 0`): dashed outline marking the exit sun.
    dashed_sun: bool = false,
    /// Draw only these nodes, at these alphas — the level-0 entries of `Panel.visible`. When
    /// null every node in the slice is drawn, which is what the interior cloud wants: it has no
    /// hierarchy and is small enough not to need one.
    selection: ?[]const Visible = null,
};

/// `slot` is the lattice the nodes sit on, which differs per level, and `fade` scales every
/// node's own alpha — that is the whole cross-fade between the overview and an interior.
/// Smallest on-screen gap between neighbouring nodes still worth drawing them individually.
/// Below this they overlap, so a merged marker is both faster and more readable. Asked of each
/// region separately — see `lod.Pyramid.splitT`.
/// Children must clear this much screen gap before a cluster opens into them. Raised from a
/// tight 12px so dense regions stay merged longer — at overview a vault of tiny notes was still
/// drawing thousands of discs because twelve pixels of separation is easy to hit even far out.
const lod_min_gap_px: f32 = 24.0;
/// Most things — markers plus links — the overview may put on screen in one frame. The level of
/// detail rises until the view fits under this, so the per-frame draw cost is a property of the
/// panel rather than of the vault: ten notes and a hundred thousand cost the same to display.
///
/// Sized from what a panel can actually show rather than from what the machine can push. At the
/// zoom where the whole vault is in view, a few thousand markers is already more distinct things
/// than the reader can pick out; past that the extra ones are hidden behind each other.
/// Ceiling on live agents (and so marks + bound links) the overview may put on screen — see
/// `lod.Pyramid.levelFor` and `agents.Field`. Granularity degrades by staying coarse, never by
/// dropping in-view masses. Zoomed in with no pyramid, notes are uncapped by this.
/// Organic overview agent cap — chrome (labels/proximity) needs headroom; harness stress uses 900.
const lod_budget: f32 = @floatFromInt(galaxy.plugin_mark_budget);
/// Hard cap on coalesced overview links after `gatherWeb` — dense hubs must not explode the web.
const max_vis_edges: usize = 480;
/// Open-document stars are drawn in addition to the lifted sample. Caps protect a hub tab
/// (thousands of spokes) from eating the frame; ordinary open notes stay fully linked.
const max_open_star_edges: usize = 240;
/// Screen length under which a link stops being drawn (non-agent / note-dense web).
const edge_min_len_px: f32 = 14.0;
/// Agent overview masses sit closer on screen — a 14px floor erased most of the lifted web.
const agent_edge_min_len_px: f32 = 4.0;
/// How much further than a tight fit the camera may be pulled back — 2 puts the whole vault in
/// half the panel. See `Camera.setContentExtent`.
const zoom_out_slack: f32 = 2.0;
/// Screen-pixel margin when a cluster click frames its region. Generous, so the notes inside
/// arrive with their surroundings rather than pressed against the panel edge.
const cluster_frame_pad_px: f32 = 60.0;


fn worldViewPadded(p: *const Panel, pad_px: f32) dvui.Rect {
    const vp = p.camera.viewport;
    const tl = p.camera.screenToWorld(.{ .x = vp.x, .y = vp.y });
    const br = p.camera.screenToWorld(.{ .x = vp.x + vp.w, .y = vp.y + vp.h });
    const margin = pad_px / @max(p.camera.zoom, 1e-6);
    return .{
        .x = tl.x - margin,
        .y = tl.y - margin,
        .w = (br.x - tl.x) + margin * 2,
        .h = (br.y - tl.y) + margin * 2,
    };
}

fn worldView(p: *const Panel) dvui.Rect {
    return worldViewPadded(p, 48);
}

fn edgeLengthFade(len_px: f32, agent_web: bool) f32 {
    const min_len = if (agent_web) agent_edge_min_len_px else edge_min_len_px;
    return std.math.clamp((len_px - min_len) / min_len, 0, 1);
}


/// Pyramid clusters put into one tile before it stops refining. A guard on the pathological case
/// rather than a working limit: the level a tile draws is already chosen so its marks are pixels
/// apart, so a tile's honest content is bounded by its own area.
const tile_mark_cap: usize = 20000;
/// Tiles baked in one frame while settled. Raised while catching up to a new zoom level — a
/// screenful of 128px tiles is around a hundred and a half, and finishing them in one or two
/// frames is what keeps the hold short enough to feel like the camera is leading rather than
/// waiting.
const bake_per_frame: usize = 48;
const bake_per_frame_catchup: usize = 160;
/// Marks a frame may bake, across all tiles. Companion to `bake_per_frame` so a few dense hub
/// tiles cannot monopolise a catch-up pass.
const bake_mark_budget: i32 = 120000;
/// Most tiles a frame will consider, over all layers. Bounds the enumeration itself against a
/// degenerate camera; a normal view wants a few dozen.
const max_tiles_per_frame: usize = 400;
/// Smallest gap, in tile pixels, between the marks a tile draws. Finer than the on-screen rule —
/// a tile is a cache rather than something being read, so it can afford to hold detail the reader
/// only sees after zooming, and stopping too early is what makes a zoomed-out field look sparse.
const tile_mark_gap_px: f32 = 4.0;
/// Marks a frame may draw straight to the screen. Used only for the cold start — the first
/// moment a tiled view has nothing baked at all. After that, unbaked tiles are skipped and the
/// held level shows through, because a direct draw is sharper than the texture that replaces it
/// and the swap is the flash.
const direct_mark_budget: i32 = 80000;
/// Fraction of a level's on-screen tiles that must be baked before it becomes the held level.
/// Short of 1 so a single empty rim tile cannot pin the view to a stale level forever.
const tile_ready_frac: f32 = 0.92;
/// Extra world drawn around a tile's own patch, as a share of the tile. A mark straddling the
/// boundary belongs to both tiles, and a link's worth of slack keeps its edge from being a seam.
const tile_bleed: f32 = 0.06;
/// Width of a link inside a tile, in tile pixels. A tile is drawn near 1:1, so this lands as about
/// the same width on screen as the live web it replaces.
const tile_link_thickness: f32 = 1.0;
/// Web ink once tiles own the field — same as `drawEdges` (`opacity(0.14)`). Baked over marks
/// (see `bakeTile`), not under them: mid/coarse discs are large and would eat crossing spokes.
const tile_link_alpha: f32 = 0.14;
/// Coarse mark fill opacity. Solid fills at mid band turn the field into a lid over the web and
/// make octave dissolves read as hard layout swaps; a little air lets the under-octave show through.
const tile_mark_fill_alpha: f32 = 0.78;

/// Which drawing scales the field is shown at this frame, and how much each one shows.
///
/// Levels are an octave apart and the nearest is chosen, so a tile is drawn within √2 of the size
/// it was baked at — near enough to 1:1 that it is neither blurred nor aliased. Only near a
/// boundary is a second level mixed in, and there both are within √2 as well, so the cross-fade is
/// between two sharp pictures rather than a sharp one and a soft one.
const TileView = struct {
    levels: [2]i32 = .{ 0, 0 },
    weights: [2]f32 = .{ 0, 0 },
    n: usize = 0,
    /// Weight of drawing real notes instead. 1 when zoomed in past the finest tile level, where a
    /// note is a fixed size on screen and no fixed-scale picture can follow it.
    node_weight: f32 = 1,

    fn active(self: TileView) bool {
        return self.n > 0;
    }

    fn maxWeight(self: TileView) f32 {
        var m: f32 = 0;
        for (0..self.n) |i| m = @max(m, self.weights[i]);
        return m;
    }
};

/// Share of an octave used for live ↔ finest-tile handoff, and the pad at each end of an octave
/// kept as a pure single level. The blend between octaves fills the middle (see `tileViewFor`).
const tile_fade_band: f32 = 0.22;

/// Zoom at which the field stops being drawn from tiles and becomes real notes.
///
/// The gap at which a resting note stops shrinking with the lattice — where the two branches of
/// `bubbleScreenRadius` cross. Below it a note is proportional to the world and a fixed-scale
/// picture can hold it; above it a note is a fixed size on screen and no picture can, since a
/// picture is scaled by whatever the camera is doing. So that crossing is exactly where tiles have
/// to hand over.
fn tileSwitchZoom(p: *const Panel) f32 {
    const settled_gap = base_screen_r * (1.0 + zoom_rest_swell) / gap_radius_frac;
    return settled_gap / @max(p.layout_slot, 1e-6);
}

/// Pixels per world unit at a tile level. Level 0 is the handover scale; each level out halves it.
fn tileDensity(p: *const Panel, level: i32) f32 {
    return tileSwitchZoom(p) * std.math.pow(f32, 2, -@as(f32, @floatFromInt(level)));
}

fn tileLayersForDraw(tv: TileView, hold: ?i32) struct {
    levels: [6]i32,
    weights: [6]f32,
    n: usize,
} {
    var levels: [6]i32 = undefined;
    var weights: [6]f32 = undefined;
    var n: usize = 0;

    const append = struct {
        fn f(levels_mut: *[6]i32, weights_mut: *[6]f32, n_mut: *usize, level: i32, weight: f32) void {
            if (level < 0 or n_mut.* >= levels_mut.len) return;
            for (levels_mut.*[0..n_mut.*], weights_mut.*[0..n_mut.*]) |l, *ww| {
                if (l == level) {
                    ww.* = @max(ww.*, weight);
                    return;
                }
            }
            levels_mut.*[n_mut.*] = level;
            weights_mut.*[n_mut.*] = weight;
            n_mut.* += 1;
        }
    }.f;

    for (0..tv.n) |i| {
        if (tv.weights[i] <= 0.004) continue;
        append(&levels, &weights, &n, tv.levels[i], tv.weights[i]);
    }
    if (hold) |h| append(&levels, &weights, &n, h, 0);
    if (tv.n > 0) {
        append(&levels, &weights, &n, tv.levels[0] - 1, 0);
        append(&levels, &weights, &n, tv.levels[0] + 1, 0);
    }
    return .{ .levels = levels, .weights = weights, .n = n };
}

fn unionRect(a: dvui.Rect, b: dvui.Rect) dvui.Rect {
    const x0 = @min(a.x, b.x);
    const y0 = @min(a.y, b.y);
    const x1 = @max(a.x + a.w, b.x + b.w);
    const y1 = @max(a.y + a.h, b.y + b.h);
    return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
}


fn clusterHoverSwell(p: *const Panel, v: Visible) f32 {
    const h = p.hover_cluster orelse return 1;
    if (h.level != v.level or h.index != v.index) return 1;
    return 1 + cluster_grow_factor * dvui.easing.outBack(std.math.clamp(p.hover_cluster_t, 0, 1));
}



fn restingNodeRadiusPx(p: *Panel) f32 {
    const gap = p.layout_slot * p.camera.zoom;
    const zoom_t = detailRevealT(p.layout_slot, p.camera.zoom);
    const want = base_screen_r * (1.0 + zoom_rest_swell * std.math.clamp(zoom_t, 0, 1));
    return @max(@min(want, gap * gap_radius_frac), 0.6);
}


/// The coalesced mass under `screen_pt`, if any. Among overlapping masses prefer the **tightest**
/// (fewest notes / highest depth) — nearest-centre picked a tiny mass sitting inside a large
/// dashed ring and framed two nodes for a click that looked like the big cluster.
fn hitTestClusters(p: *Panel, screen_pt: dvui.Point.Physical) ?Visible {
    // Containment has no quadtree; its masses are just the non-note marks. `level` carries only
    // "this is a mass" here, and `index` is the fold cell id.
    {
        const w = if (p.world_state) |*ws| ws else return null;
        var hit: ?Visible = null;
        var best_r: f32 = std.math.floatMax(f32);
        for (w.marks.items) |m| {
            if (m.is_note or m.alpha < 0.15) continue;
            const c = p.camera.worldToScreen(.{ .x = m.wx, .y = m.wy });
            const dx = screen_pt.x - c.x;
            const dy = screen_pt.y - c.y;
            const r = @max(m.r, 6);
            if (dx * dx + dy * dy > r * r) continue;
            // smallest containing mass wins, so a click inside nested rings picks the innermost
            if (m.r < best_r) {
                best_r = m.r;
                hit = .{ .level = 1, .index = m.cell, .alpha = m.alpha };
            }
        }
        return hit;
    }

    return null;
}

fn ensureWorld(p: *Panel) ?*world_mod.World {
    if (p.world_epoch == p.layout_epoch and p.world_state != null) return &p.world_state.?;
    if (p.nodes.len == 0) return null;

    const gpa = sdk.allocator();
    const arena = dvui.currentWindow().arena();

    const links = arena.alloc(fold.Edge, p.edges.len) catch return null;
    for (p.edges, 0..) |e, i| links[i] = .{ .a = @intCast(e.a), .b = @intCast(e.b), .w = 1 };
    const paths = arena.alloc([]const u8, p.nodes.len) catch return null;
    for (p.nodes, 0..) |n, i| paths[i] = n.path;

    // World scale has to match the classic layout's, because everything downstream of the panel
    // — camera fit, zoom thresholds, `interiorWant`, label placement — is calibrated in those
    // units. `layout_slot` is the world distance between adjacent notes (224 for a vault over 80
    // notes). Containment puts two ring-adjacent leaves `leaf_pitch × note_r` apart, so solve for
    // `note_r`. Getting this wrong by the default 1.0 made the entire vault smaller than the gap
    // between two classic notes: marks drew as a speck at the centre, every LOD transition
    // happened inside a sliver of the zoom range, and the interior triggered almost immediately.
    const slot = if (p.layout_slot > 1) p.layout_slot else layout_full.slotSpacingFor(@max(p.nodes.len, 1));
    var built = world_mod.World.init(gpa, p.nodes.len, links, paths, .{}, .{
        .note_r = slot / world_mod.leaf_pitch,
    }) catch return null;
    if (p.world_state) |*old| old.deinit();
    p.world_state = built;
    p.world_epoch = p.layout_epoch;
    // `built` is moved into the panel; do not deinit it here.
    _ = &built;
    return &p.world_state.?;
}

/// Advance the living set for this frame's camera and publish it onto `p.nodes`.
///
/// Runs *before* hover, proximity and label placement, not inside the draw. Those all read
/// `node.pos`, so stepping the world inside `drawWorldMarks` left every one of them a frame
/// behind — hover latched onto whatever was under the cursor last frame, the label placer
/// measured collisions against stale positions and refused nearly every slot, and clicks
/// resolved against the wrong node.
fn stepWorld(p: *Panel) void {
    const w = ensureWorld(p) orelse return;
    const arena = dvui.currentWindow().arena();
    const vp = p.camera.viewport;
    const view: world_mod.View = .{
        .w = vp.w,
        .h = vp.h,
        .zoom = p.camera.zoom,
        .cx = p.camera.center.x,
        .cy = p.camera.center.y,
    };
    const params: world_mod.Params = .{ .budget = galaxy.plugin_mark_budget };
    w.step(view, params, dvui.secondsSinceLastFrame()) catch return;
    syncNodesFromWorld(p, w);

    // Restart the reach-out whenever the set of open notes actually changes; otherwise let it run
    // to rest so a settled selection is not permanently animating.
    var key: u64 = 1469598103934665603;
    for (p.nodes, 0..) |node, i| {
        if (!node.open) continue;
        key ^= @as(u64, i +% 1);
        key *%= 1099511628211;
    }
    if (key != p.select_key) {
        p.select_key = key;
        p.select_anim = 0;
    } else if (p.select_anim < 1) {
        p.select_anim = @min(1, p.select_anim + dvui.secondsSinceLastFrame() * select_reach_rate);
    }

    const links = arena.alloc(fold.Edge, p.edges.len) catch return;
    for (p.edges, 0..) |e, i| links[i] = .{ .a = @intCast(e.a), .b = @intCast(e.b), .w = 1 };
    w.liftLinks(links, params) catch {};
}

/// Local (content-cloud) -> vault-world, closing over the panel's current `nest`/`parent` — the
/// interior's counterpart to `identityToWorld`. The overview's `World` is already in vault-world
/// space; the interior's is nested one level down, so this is where that nesting actually happens.
/// The open document as a dashed sun with its content field around it — every item drawn
/// directly, always, since this layout has no coalescing budget to decide who's a mass this frame
/// (see `buildInteriorWorld`'s doc comment). Not through `world_draw.draw`: there is no `World`
/// here, just a fixed array of positions, so a plain loop building one `StyledMark` buffer is the
/// whole draw pass — the sun and every content item go in it together, in one
/// `galaxy.drawStyledMarks` call, rather than the sun-then-content split the fold/containment
/// version needed to keep the root out of its packing.
fn drawInteriorMarks(p: *Panel, fade: f32) void {
    if (fade <= 0.004 or p.interior.nodes.len == 0) return;
    const dens = p.ensureDensity() orelse return;
    const arena = dvui.currentWindow().arena();
    const theme = dvui.themeGet();
    const border_rest = theme.color(.window, .text);
    const hot = theme.color(.highlight, .fill);
    const zoom_t = @max(detailRevealT(p.interior.slot, p.camera.zoom), 1);
    const gap_px = p.interior.slot * p.camera.zoom;

    const buf = arena.alloc(galaxy.StyledMark, p.interior.nodes.len) catch return;
    for (p.interior.nodes, 0..) |node, i| {
        const kind_mul = if (i > 0 and i < p.interior.item_kind.len)
            contentKindRadiusMul(p.interior.item_kind[i])
        else
            1.0;
        buf[i] = .{
            .screen = p.camera.worldToScreen(node.pos),
            .r_px = bubbleScreenRadius(node, zoom_t, gap_px) * kind_mul,
            .fill = nodeFill(theme, node),
            // The sun is the note you are inside — dashed, so leaving reads differently from
            // stepping between content items.
            .border = if (node.is_sun) hot else border_rest,
            .is_note = !node.is_sun,
            .dying = false,
        };
    }
    _ = galaxy.drawStyledMarks(&dens.soft, &p.camera, fade, buf);
    for (buf) |b| {
        if (b.is_note) frame_profile.nodes_drawn += 1 else frame_profile.clusters_drawn += 1;
    }
}

/// Paint the living set stepped by `stepWorld`.
/// Identity: the overview's `World` is already in vault-world space, nothing to nest.
fn identityToWorld(_: *anyopaque, local: dvui.Point) dvui.Point {
    return local;
}

/// A note is drawn at exactly the radius `updateLabels` reserves for it and `nodeAtAim`
/// hit-tests against. `world` reports a flat note size because it is headless and knows nothing
/// about hover or open tabs; the panel does, so the panel decides. Keeping the three in sync is
/// what lets the placer find real gaps — reserving one size and drawing another had it dodging
/// discs that were not there — and it restores the proximity swell, so a note grows under the
/// cursor and carries that size into the interior as a dashed ring.
fn overviewMarkStyle(ctx: *anyopaque, w: *const world_mod.World, m: world_mod.Mark, holds_open: bool) world_draw.MarkStyle {
    const p: *Panel = @ptrCast(@alignCast(ctx));
    _ = w;
    const theme = dvui.themeGet();
    const border_rest = theme.color(.window, .text);
    const hot = theme.color(.highlight, .fill);
    const zoom_t = @max(detailRevealT(p.layout_slot, p.camera.zoom), 1);
    const gap_px = p.layout_slot * p.camera.zoom;
    const radius_px: f32 = if (m.is_note and m.note < p.nodes.len)
        bubbleScreenRadius(p.nodes[m.note], zoom_t, gap_px)
    else
        m.r;
    return .{
        .fill = if (m.is_note) nodeFill(theme, p.nodes[m.note]) else border_rest,
        .border = if (holds_open) hot else border_rest,
        .r_px = radius_px,
        .is_note = m.is_note,
    };
}

fn overviewHoldsOpen(ctx: *anyopaque, w: *const world_mod.World, m: world_mod.Mark) bool {
    const p: *Panel = @ptrCast(@alignCast(ctx));
    return worldMarkHoldsOpen(p, w, m);
}

fn drawWorldMarks(p: *Panel, fade: f32) void {
    const w = if (p.world_state) |*ws| ws else return;
    const dens = p.ensureDensity() orelse return;
    const stats = world_draw.draw(w, &p.camera, dens, fade, p.select_anim, .{
        .ctx = p,
        .toWorld = identityToWorld,
        .style = overviewMarkStyle,
        .holdsOpen = overviewHoldsOpen,
    });
    frame_profile.nodes_drawn += stats.notes_drawn;
    frame_profile.clusters_drawn += stats.clusters_drawn;
}

/// Publish the world's leaf poses back onto `p.nodes`, and mark which notes are drawn as
/// themselves this frame.
///
/// Labels, hover, hit-testing and the click-to-open path all read `node.pos` / `at_level0` and
/// know nothing about which layout produced them. Writing back is what makes them work in
/// containment mode instead of pointing at wherever the classic layout happened to leave the note
/// — which is why labels first appeared scattered across the field while the marks sat in a
/// cluster at the centre.
fn syncNodesFromWorld(p: *Panel, w: *const world_mod.World) void {
    if (p.at_level0.len == p.nodes.len) @memset(p.at_level0, false);
    for (p.nodes) |*n| n.alpha = 0;

    // The label placer works over a *selection*, so hand it exactly the notes this frame resolved
    // as individuals. Bounded by the mark budget, which is what makes re-placing every frame
    // affordable — walking the whole vault to place names is the expensive path the classic
    // gating exists to avoid.
    p.visible.clearRetainingCapacity();

    var notes: u32 = 0;
    for (w.marks.items) |m| {
        if (!m.is_note or m.note >= p.nodes.len) continue;
        const n = &p.nodes[m.note];
        n.home = .{ .x = m.wx, .y = m.wy };
        n.target = n.home;
        n.pos = n.home;
        // World-space radius matching what will be drawn, so hit-testing and framing agree.
        // hover_t is applied later by updateBubbles; the draw pass re-derives the final size.
        n.radius = bubbleScreenRadius(n.*, 1, p.layout_slot * p.camera.zoom) /
            @max(p.camera.zoom, 1e-6);
        n.alpha = m.alpha;
        if (p.at_level0.len == p.nodes.len) p.at_level0[m.note] = true;
        p.visible.append(sdk.allocator(), .{
            .level = 0,
            .index = m.note,
            .alpha = m.alpha,
        }) catch {};
        notes += 1;
    }
    p.notes_at_level0 = notes;
}

/// World position of a living cell, or null when it is not drawn this frame.
fn markWorldPos(w: *const world_mod.World, cell: u32) ?dvui.Point {
    for (w.marks.items) |m| {
        if (m.cell == cell) return .{ .x = m.wx, .y = m.wy };
    }
    return null;
}

/// Screen position of a living cell, or null when it is not currently drawn.
fn markScreen(p: *const Panel, w: *const world_mod.World, cell: u32) ?dvui.Point.Physical {
    for (w.marks.items) |m| {
        if (m.cell == cell) return p.camera.worldToScreen(.{ .x = m.wx, .y = m.wy });
    }
    return null;
}

/// True when this mark covers at least one open document, at any level — so a coalesced mass
/// holding an open note reads as highlight before it has split out as a leaf.
fn worldMarkHoldsOpen(p: *const Panel, w: *const world_mod.World, m: world_mod.Mark) bool {
    const c = w.lad.cells[m.cell];
    for (c.ls..c.le) |slot| {
        const note = w.lad.note_at[slot];
        if (note < p.nodes.len and p.nodes[note].open) return true;
    }
    return false;
}

fn frameCluster(p: *Panel, target: Visible) void {
    if (target.level == 0) return;

    {
        const w = if (p.world_state) |*ws| ws else return;
        if (target.index >= w.lad.cells.len) return;
        if (w.lad.cells[target.index].child_count == 0) return;
        const pos = markWorldPos(w, target.index) orelse blk: {
            const fp = w.field.pos[target.index];
            break :blk dvui.Point{ .x = fp.x, .y = fp.y };
        };
        const rad = w.field.radius(&w.lad, target.index);
        const content = dvui.Rect{
            .x = pos.x - rad,
            .y = pos.y - rad,
            .w = rad * 2,
            .h = rad * 2,
        };
        // Framing the cell's own disc puts its radius at roughly half the viewport, which is well
        // past `split_px` — so the mass actually unfolds rather than sitting there framed and shut.
        const pose = p.camera.poseForBounds(content, cluster_frame_pad_px);
        p.framing = .extents;
        p.camera.center_target = pose.center;
        p.camera.zoom_target = pose.zoom;
        p.camera.user_driving = false;
        // Input is handled at the *end* of the frame, after the host has already asked whether
        // more frames are wanted — so setting a camera target here is invisible until some other
        // event wakes the app. Ask explicitly, exactly as the old path did.
        dvui.refresh(null, @src(), dvui.parentGet().data().id);
        return;
    }


    const py = p.pyramid orelse return;
    if (target.level >= py.levels.len) return;
    if (target.index >= py.levels[target.level].len) return;
    const c = py.levels[target.level][target.index];
    const r = @max(c.radius, p.layout_slot);
    const pose = p.camera.poseForBounds(.{
        .x = c.pos.x - r,
        .y = c.pos.y - r,
        .w = r * 2,
        .h = r * 2,
    }, cluster_frame_pad_px);
    p.camera.center_target = pose.center;
    p.camera.zoom_target = pose.zoom;
    p.framing = .free;
    p.camera.user_driving = false;
    dvui.refresh(null, @src(), dvui.parentGet().data().id);
}

/// Largest screen radius still drawn from the batch. Above it a node is big enough on screen for
/// the polygon's flat sides to read as flat, and big enough that there cannot be many of them.
const batch_max_r: f32 = 9.0;
/// Max sides on a batched disc. Scaled down for tiny marks; large masses need this many or they
/// read as polygons. ~3px chords at r≈30.
const batch_sides: usize = 64;
/// Sides on a disc baked into an impostor cell. A cell is often magnified on its way to the
/// screen, which magnifies the flat sides with it, and unlike the on-screen batch a bake happens
/// once — so the extra vertices buy smoothness at every zoom the picture is later drawn at.
const bake_disc_sides: usize = 48;
/// Width of the transparent skirt on a baked disc, in cell pixels. About a pixel: enough for the
/// edge to resolve smoothly once the cell is resampled onto the screen, and not so much that a
/// small mark is mostly skirt.
const bake_disc_feather: f32 = 0.9;
/// Screen-pixel width of a note's border. Drawn as a ring (outer disc of the border colour,
/// then the fill inset by this) so the batched path can keep it without a stroke call per node.
const node_border_px: f32 = 1.25;

/// Many small discs in one draw call.
///
/// dvui has no batching of its own: every `fillConvex` and every `stroke` tessellates and calls
/// `renderTriangles`, which is one `drawClippedTriangles` on the backend. That is fine for a UI
/// made of a few hundred rects and disastrous here — a vault of ten thousand notes was ten
/// thousand draw calls per frame for the discs alone, before the shadows and the web, and no
/// amount of making each one cheaper changes an order of magnitude of driver overhead.
///
/// The nodes small enough to matter are also the ones that need the least from the drawing:
/// a flat-shaded octagon a few pixels across is indistinguishable from a faded arc. So they go
/// into one shared vertex buffer and out in a single call. Anything larger keeps the pretty
/// path, where quality is visible and the count is bounded by the screen.
const DiscBatch = struct {
    arena: std.mem.Allocator,
    /// Corners on each disc. Eight for the on-screen pass, where discs are a few pixels across
    /// and there may be thousands; more when baking, where a cell can be magnified on its way to
    /// the screen and the cost is paid once.
    sides: usize = batch_sides,
    /// Width of a transparent skirt around each disc, in the units being drawn in. Zero for the
    /// on-screen pass, where a disc is a handful of pixels and lands on the framebuffer at 1:1.
    ///
    /// A baked disc does not. It goes into a cell that is then stretched to wherever its region
    /// falls, so its edge is resampled — and a hard edge that is magnified stays a hard edge with
    /// bigger steps in it, since linear filtering can only blur an aliased edge, never undo it.
    /// The skirt is the antialiasing the batch otherwise has none of: a ring of vertices at zero
    /// alpha, so the hardware interpolates the disc out to nothing across it.
    feather: f32 = 0,
    b: ?dvui.Triangles.Builder = null,

    /// A centre plus one vertex per side, and one triangle per side. Sized for the coarsest
    /// setting so one allocation serves every batch.
    const verts_per: usize = batch_sides + 1;
    const idx_per: usize = batch_sides * 3;
    /// Indices are `u16` in this build of dvui, so a buffer cannot address past 65535 vertices.
    /// Full batches are flushed and a fresh one started, which still leaves thousands of nodes
    /// to a call.
    const max_discs: usize = std.math.maxInt(u16) / verts_per;
    const vtx_cap: usize = max_discs * verts_per;
    const idx_cap: usize = max_discs * idx_per;

    fn init(arena: std.mem.Allocator) DiscBatch {
        return .{ .arena = arena };
    }

    fn initBake(arena: std.mem.Allocator) DiscBatch {
        return .{ .arena = arena, .sides = bake_disc_sides, .feather = bake_disc_feather };
    }

    fn ensure(self: *DiscBatch, need_vtx: usize, need_idx: usize) ?*dvui.Triangles.Builder {
        if (self.b) |*b| {
            // Both buffers, not just one. The allocation is sized for a plain `batch_sides` disc,
            // and a finer or feathered one spends indices faster than vertices — checking
            // vertices alone let it run past the end of the index buffer, which is appended to
            // without bounds checks.
            if (b.vertexes.items.len + need_vtx > vtx_cap or b.indices.items.len + need_idx > idx_cap) {
                self.flush();
            }
        }
        if (self.b == null) {
            self.b = dvui.Triangles.Builder.init(
                self.arena,
                max_discs * verts_per,
                max_discs * idx_per,
            ) catch return null;
        }
        return &(self.b.?);
    }

    fn sideCount(self: DiscBatch, rad: f32) usize {
        // Border ring and fill must share a side count or they fail to nest. Scale with radius so
        // chord length stays ~2–3 px: tiny marks stay cheap; overview masses need the full cap.
        const want = @as(usize, @intFromFloat(@max(rad, 1.5) * 2.5));
        const lo: usize = if (self.feather > 0) 8 else 12;
        return std.math.clamp(want, lo, self.sides);
    }

    fn add(self: *DiscBatch, center: dvui.Point.Physical, r: f32, color: dvui.Color) void {
        // Never smaller than half a pixel: below that the polygon collapses to nothing and the
        // note vanishes rather than fading, which reads as the graph losing notes as you zoom.
        const rad = @max(r, 0.5);
        const n = self.sideCount(rad);
        const soft = self.feather > 0;
        // A centre, a rim, and a second rim at zero alpha when feathered. Triangles: the fan,
        // plus two per side to span the skirt.
        const need_vtx = 1 + n * (if (soft) @as(usize, 2) else 1);
        const need_idx = n * 3 * (if (soft) @as(usize, 3) else 1);
        const b = self.ensure(need_vtx, need_idx) orelse return;

        const base: u16 = @intCast(b.vertexes.items.len);
        const col: dvui.Color.PMA = .fromColor(color);
        const clear: dvui.Color.PMA = .{ .r = 0, .g = 0, .b = 0, .a = 0 };
        b.appendVertex(.{ .pos = center, .col = col });
        for (0..n) |s| {
            const a = std.math.tau * @as(f32, @floatFromInt(s)) / @as(f32, @floatFromInt(n));
            b.appendVertex(.{
                .pos = .{ .x = center.x + @cos(a) * rad, .y = center.y + @sin(a) * rad },
                .col = col,
            });
        }
        if (soft) {
            const outer = rad + self.feather;
            for (0..n) |s| {
                const a = std.math.tau * @as(f32, @floatFromInt(s)) / @as(f32, @floatFromInt(n));
                b.appendVertex(.{
                    .pos = .{ .x = center.x + @cos(a) * outer, .y = center.y + @sin(a) * outer },
                    .col = clear,
                });
            }
        }
        for (0..n) |s| {
            const cur: u16 = @intCast(base + 1 + s);
            const nxt: u16 = @intCast(base + 1 + (s + 1) % n);
            b.appendTriangles(&.{ base, cur, nxt });
            if (soft) {
                const ocur: u16 = @intCast(base + 1 + n + s);
                const onxt: u16 = @intCast(base + 1 + n + (s + 1) % n);
                b.appendTriangles(&.{ cur, ocur, onxt, cur, onxt, nxt });
            }
        }
    }

    /// A closed annular border — outer rim to inner rim, no centre fill.
    ///
    /// Prefer this over "full disc of the border colour, then the fill on top": the two-disc trick
    /// nests only when both polygons share a side count and orientation, and any mismatch reads as
    /// a thicker/thinner stretch. A ring is one closed loop of quads, so the seam that would sit
    /// where a stroke begins and ends does not exist.
    fn addRing(self: *DiscBatch, center: dvui.Point.Physical, outer_r: f32, inner_r: f32, color: dvui.Color) void {
        const outer = @max(outer_r, 0.5);
        const inner = @min(@max(inner_r, 0.0), outer - 0.25);
        if (inner <= 0.01) {
            self.add(center, outer, color);
            return;
        }
        const n = self.sideCount(outer);
        const need_vtx = n * 2;
        const need_idx = n * 6;
        const b = self.ensure(need_vtx, need_idx) orelse return;

        const base: u16 = @intCast(b.vertexes.items.len);
        const col: dvui.Color.PMA = .fromColor(color);
        for (0..n) |s| {
            const a = std.math.tau * @as(f32, @floatFromInt(s)) / @as(f32, @floatFromInt(n));
            const c = @cos(a);
            const sn = @sin(a);
            b.appendVertex(.{ .pos = .{ .x = center.x + c * outer, .y = center.y + sn * outer }, .col = col });
        }
        for (0..n) |s| {
            const a = std.math.tau * @as(f32, @floatFromInt(s)) / @as(f32, @floatFromInt(n));
            const c = @cos(a);
            const sn = @sin(a);
            b.appendVertex(.{ .pos = .{ .x = center.x + c * inner, .y = center.y + sn * inner }, .col = col });
        }
        for (0..n) |s| {
            const o0: u16 = @intCast(base + s);
            const o1: u16 = @intCast(base + (s + 1) % n);
            const r0: u16 = @intCast(base + n + s);
            const r1: u16 = @intCast(base + n + (s + 1) % n);
            b.appendTriangles(&.{ o0, o1, r1, o0, r1, r0 });
        }
    }

    fn flush(self: *DiscBatch) void {
        var b = self.b orelse return;
        self.b = null;
        if (b.vertexes.items.len == 0) return;
        dvui.renderTriangles(b.build_unowned(), null) catch {};
    }
};

/// Walk either a selection's level-0 entries or a whole node slice, so `drawNodes` has one loop
/// instead of two copies of its body.
const NodeIter = struct {
    nodes_len: usize,
    selection: ?[]const Visible,
    i: usize = 0,

    const Step = struct { index: usize, alpha: f32 };

    fn init(nodes: []const GraphNode, selection: ?[]const Visible) NodeIter {
        return .{ .nodes_len = nodes.len, .selection = selection };
    }

    fn next(self: *NodeIter) ?Step {
        if (self.selection) |sel| {
            while (self.i < sel.len) {
                const v = sel[self.i];
                self.i += 1;
                if (v.level != 0 or v.index >= self.nodes_len) continue;
                return .{ .index = v.index, .alpha = v.alpha };
            }
            return null;
        }
        if (self.i >= self.nodes_len) return null;
        defer self.i += 1;
        return .{ .index = self.i, .alpha = 1 };
    }
};

fn strokeCircleDashed(center: dvui.Point.Physical, radius: f32, stroke: dvui.Path.StrokeOptions) void {
    if (radius < 2) return;
    const arena = dvui.currentWindow().arena();
    // Dense enough that short dashes still look curved; scale mildly with size.
    const samples: usize = @max(@as(usize, 36), @as(usize, @intFromFloat(radius * 1.8)));
    const pts = arena.alloc(dvui.Point.Physical, samples + 1) catch return;
    var i: usize = 0;
    while (i < samples) : (i += 1) {
        const a = std.math.tau * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(samples));
        pts[i] = .{
            .x = center.x + @cos(a) * radius,
            .y = center.y + @sin(a) * radius,
        };
    }
    pts[samples] = pts[0];

    const dash = std.math.clamp(radius * 0.45, 4, 10);
    const gap = std.math.clamp(radius * 0.28, 3, 7);
    strokePolylineDashed(pts, dash, gap, stroke);
}

fn strokePolylineDashed(
    points: []const dvui.Point.Physical,
    dash_len: f32,
    gap_len: f32,
    stroke: dvui.Path.StrokeOptions,
) void {
    const n = points.len;
    if (n < 2 or dash_len <= 0) return;
    const gap = @max(0.0, gap_len);
    const pattern = dash_len + gap;
    if (pattern < 1e-5) return;

    const arena = dvui.currentWindow().arena();
    const cum = arena.alloc(f32, n) catch return;
    cum[0] = 0;
    var i: usize = 1;
    while (i < n) : (i += 1) {
        cum[i] = cum[i - 1] + dvui.Point.Physical.diff(points[i], points[i - 1]).length();
    }
    const total = cum[n - 1];
    if (total < 1e-4) return;

    var buf: std.ArrayList(dvui.Point.Physical) = .empty;
    const edge_eps: f32 = 1e-5;
    var s: f32 = 0;
    while (s < total - edge_eps) {
        const dash_end = @min(s + dash_len, total);
        if (dash_end <= s + edge_eps) break;
        buf.clearRetainingCapacity();
        appendDashedSpan(points, cum, s, dash_end, &buf) catch return;
        if (buf.items.len != 0) {
            dvui.Path.stroke(.{ .points = buf.items }, stroke);
        }
        s = dash_end + gap;
    }
}

fn pointAtArcLength(points: []const dvui.Point.Physical, cum: []const f32, dist: f32) dvui.Point.Physical {
    const n = points.len;
    if (n == 0) return .{};
    if (n == 1 or dist <= 0) return points[0];
    if (dist >= cum[n - 1]) return points[n - 1];
    var seg: usize = 1;
    while (seg < n and cum[seg] < dist) : (seg += 1) {}
    const seg_len = cum[seg] - cum[seg - 1];
    const t = if (seg_len < 1e-6) 0 else (dist - cum[seg - 1]) / seg_len;
    return .{
        .x = points[seg - 1].x + (points[seg].x - points[seg - 1].x) * t,
        .y = points[seg - 1].y + (points[seg].y - points[seg - 1].y) * t,
    };
}

fn appendDashedSpan(
    points: []const dvui.Point.Physical,
    cum: []const f32,
    s0: f32,
    s1: f32,
    out: *std.ArrayList(dvui.Point.Physical),
) !void {
    const arena = dvui.currentWindow().arena();
    const eps: f32 = 1e-4;
    if (s1 <= s0 + eps) return;
    try out.append(arena, pointAtArcLength(points, cum, s0));
    var k: usize = 1;
    while (k < points.len) : (k += 1) {
        const d = cum[k];
        if (d <= s0 + eps) continue;
        if (d >= s1 - eps) break;
        try out.append(arena, points[k]);
    }
    const end_pt = pointAtArcLength(points, cum, s1);
    const last = out.items[out.items.len - 1];
    const dx = end_pt.x - last.x;
    const dy = end_pt.y - last.y;
    if (dx * dx + dy * dy > 1e-8) try out.append(arena, end_pt);
}

/// How much the reader wants to see this name at all — proximity, zoom detail reveal, or the
/// standing nudge an open doc gets. Independent of whether the placer can find room for it.
fn labelReveal(n: GraphNode, zoom_t: f32) f32 {
    var t = @max(n.hover_t, zoom_t);
    if (n.open) t = @max(t, 0.55);
    return t;
}

/// Placement order. The scale of each term is what matters: the node under the cursor
/// outranks everything (you asked for that one), open docs outrank the ambient field, and a
/// label that already found a slot carries an incumbency bonus so the set of visible names
/// doesn't reshuffle every time the mouse drifts a pixel.
fn labelPriority(n: GraphNode, reveal: f32) f32 {
    var s: f32 = reveal;
    s += n.pointer_t * 100;
    if (n.open) s += 40;
    s += n.hover_t * 20;
    s += n.label_vis * 6;
    s += @min(@as(f32, @floatFromInt(n.degree)), 24) * 0.1;
    return s;
}

/// Parity of the node's lattice cell — the sawtooth key. Horizontal neighbours differ by one
/// in `q`, so `q + r` alternates along a row and adjacent nodes prefer opposite label
/// distances. Read off `target` rather than `pos`: the shove is transient, and a label that
/// changed which tooth it sits on mid-hover would be worse than the overlap it avoided.
fn latticeParity(n: GraphNode, slot: f32) u1 {
    // Nodes snap to the fine lattice (`snapSpacingFor`); parity has to use the same spacing or
    // neighbours that sit one snap cell apart would share a tooth and fight for the same strip.
    const pack = if (slot > 1) slot else hex.layoutSpacingFor(1);
    const s = pack / 2;
    const c = hex.fromWorld(n.target, s);
    return @intCast(@as(u32, @bitCast(c[0] +% c[1])) & 1);
}

/// Decide which names are drawn this frame and where. See `labels.zig` for the why.
/// Places names for one level's nodes. Only ever run for whichever level is dominant — two
/// placers running at once would each reserve space against bubbles the other owns and neither
/// would find room, so mid-descent both levels' names would drop out exactly when the reader is
/// looking hardest.
/// True when world→screen has moved since the placer last ran, so every stored `label_rect` is
/// stale. Exact comparison on purpose — a slot is a pixel rect and a sub-pixel drift is still a
/// name drawn off its bubble; this is also what stops a settled, motionless graph from replacing
/// the idle path the gate exists for.
fn labelViewMoved(p: *const Panel) bool {
    const vp = p.camera.viewport;
    return p.camera.center.x != p.labels_center.x or
        p.camera.center.y != p.labels_center.y or
        p.camera.zoom != p.labels_zoom or
        vp.x != p.labels_vp.x or vp.y != p.labels_vp.y or
        vp.w != p.labels_vp.w or vp.h != p.labels_vp.h;
}

/// The rect labels should stay inside: the cloud's silhouette rather than the pane.
///
/// `centres` is the screen-space AABB of the node centres — the same thing the camera frames,
/// which is why an overhang shows up as the cloud looking off-centre. Sideways the berth is just
/// the bubble radius, so the limit is the drawn edge of the outermost disc: a centred name on a
/// flank node overhangs it and is pushed to the inward slot instead. Vertically it also has to
/// clear a whole label, or the entire bottom row would be shoved sideways for no reason — the
/// top and bottom of the cloud are not what the eye reads for centring.
///
/// The placer clips this against the panel itself, so a cloud zoomed past the pane edges is
/// handled there rather than here.
fn cloudKeepIn(centres: dvui.Rect.Physical, bubble_r: f32, label_h: f32) dvui.Rect.Physical {
    return .{
        .x = centres.x - bubble_r,
        .y = centres.y - bubble_r - label_h,
        .w = centres.w + bubble_r * 2,
        .h = centres.h + (bubble_r + label_h) * 2,
    };
}

fn updateLabels(
    p: *Panel,
    nodes: []GraphNode,
    edges: []const GraphEdge,
    slot: f32,
    selection: ?[]const Visible,
    /// Minimum reveal for every candidate, regardless of zoom.
    ///
    /// The classic path fades names in as `slot * zoom` crosses a pixel gap, because it draws
    /// every note at every zoom and needs *something* to decide when a name is legible. The
    /// containment path has already made that call: a mark is either an individual note or a
    /// coalesced mass, and it resolved the note precisely because there is room for it. Re-deriving
    /// legibility from a global zoom threshold then disagrees with the LOD — one island resolves
    /// early and another late, but the threshold is the same for both, so names appear only in a
    /// narrow band of zoom. Pass 1 to defer to the LOD instead.
    reveal_floor: f32,
) void {
    const dt = @min(dvui.secondsSinceLastFrame(), 1.0 / 30.0);
    const t_chase = 1.0 - @exp(-label_chase_k * dt);

    if (nodes.len == 0) {
        p.labels_settled = true;
        return;
    }

    const cw = dvui.currentWindow();
    const arena = cw.arena();
    const scale = cw.natural_scale;
    const zoom_t = @max(detailRevealT(slot, p.camera.zoom), reveal_floor);
    const font = dvui.Font.theme(.body).larger(label_font_delta);
    const vp = p.camera.viewport;

    // One slot per node saying "the placer found room for me". Out of memory here means we
    // keep last frame's placement rather than dropping every label at once.
    const want = arena.alloc(bool, nodes.len) catch return;
    @memset(want, false);
    const rect_buf = arena.alloc(dvui.Rect.Physical, max_reserved_bubbles + max_labels) catch return;
    var placer = labels.Placer.init(rect_buf, vp, label_slack * scale);
    // A name sitting on a link is almost as unreadable as one sitting on a bubble. Feed the
    // visible segments in so the placer can refuse those slots the same way it refuses discs.
    // Thickness tracks the stroke, plus a little lead so glyphs don't graze the line.
    // The overview reads the same gathered web the draw pass does, so the placer avoids exactly
    // the lines that exist — and, as with the draw pass, does not walk the vault's whole link set
    // to find them. An interior cloud has no gathered set and is small enough to scan.
    // Containment's web is `world.links`, already lifted onto living cells. Feeding the classic
    // path's `vis_edges` here instead described lines that are not on screen, so the placer
    // refused slot after slot for collisions with a web that was not being drawn.
    const containment_links: ?[]const world_mod.LiftedLink =
        if (p.world_state) |*w| w.links.items else null;
    const seg_cap = if (containment_links) |cl| cl.len else edges.len;
    const seg_buf = arena.alloc(labels.Segment, seg_cap) catch return;
    var seg_n: usize = 0;
    for (0..seg_cap) |i| {
        var wa: dvui.Point = undefined;
        var wb: dvui.Point = undefined;
        if (containment_links) |cl| {
            const w = &p.world_state.?;
            const ca = markWorldPos(w, cl[i].a) orelse continue;
            const cb = markWorldPos(w, cl[i].b) orelse continue;
            wa = ca;
            wb = cb;
        } else {
            const e = edges[i];
            if (e.a >= nodes.len or e.b >= nodes.len) continue;
            wa = nodes[e.a].pos;
            wb = nodes[e.b].pos;
        }
        const a = p.camera.worldToScreen(wa);
        const b = p.camera.worldToScreen(wb);
        // Skip links that don't nick the panel — same cheap reject the draw pass uses.
        if (!segmentMaybeInView(a, b, vp.outsetAll(40))) continue;
        seg_buf[seg_n] = .{ .a = a, .b = b };
        seg_n += 1;
    }
    placer.segs = seg_buf[0..seg_n];
    placer.seg_pad = @max(2.0, @min(3.5, p.camera.zoom)) * scale;

    var cand: std.ArrayList(usize) = .empty;
    var reserved: usize = 0;
    var cloud_r: f32 = 0;
    // Only what is on screen as itself. This loop used to walk the whole vault every frame the
    // pointer or the camera moved, which on a large vault was the single most expensive thing
    // the panel did — and all but a few hundred of those nodes were off screen or merged, so it
    // was computing placement inputs for labels that could not be drawn.
    var it = NodeIter.init(nodes, selection);
    while (it.next()) |step| {
        const n = &nodes[step.index];
        const s = p.camera.worldToScreen(n.pos);
        const r_px = bubbleScreenRadius(n.*, zoom_t, slot * p.camera.zoom);
        cloud_r = @max(cloud_r, r_px);
        if (!vp.outsetAll(r_px).contains(s)) {
            // Off-screen: nothing is drawn, so there is no fade to preserve.
            n.label_vis = 0;
            continue;
        }
        if (reserved < max_reserved_bubbles) {
            const rr = r_px * bubble_reserve_scale;
            placer.reserve(.{ .x = s.x - rr, .y = s.y - rr, .w = rr * 2, .h = rr * 2 });
            reserved += 1;
        }
        if (labelReveal(n.*, zoom_t) > label_reveal_min) cand.append(arena, step.index) catch {};
    }

    // Screen-space silhouette of the cloud, from the arrangement's own world bounds rather than
    // by scanning what is visible: the shape the reader calls "the graph" doesn't shrink because
    // half of it panned off the side, and a silhouette that breathed with scrolling would make
    // labels hop. Transforming two corners is also O(1) where the scan was O(vault).
    const wb = p.world_bounds;
    const tl = p.camera.worldToScreen(.{ .x = wb.x, .y = wb.y });
    const br = p.camera.worldToScreen(.{ .x = wb.x + wb.w, .y = wb.y + wb.h });
    placer.keep_in = cloudKeepIn(
        .{ .x = tl.x, .y = tl.y, .w = br.x - tl.x, .h = br.y - tl.y },
        cloud_r,
        (label_gap + font.textSize("Ag").h) * scale,
    );

    const Order = struct {
        nodes: []const GraphNode,
        zoom_t: f32,
        fn less(c: @This(), a: usize, b: usize) bool {
            const pa = labelPriority(c.nodes[a], labelReveal(c.nodes[a], c.zoom_t));
            const pb = labelPriority(c.nodes[b], labelReveal(c.nodes[b], c.zoom_t));
            // Index tie-break keeps the order total, so equal-priority nodes can't swap
            // places between frames and strobe.
            return if (pa != pb) pa > pb else a < b;
        }
    };
    std.mem.sort(usize, cand.items, Order{ .nodes = nodes, .zoom_t = zoom_t }, Order.less);

    const ellipsis_w = font.textSize("…").w;
    var placed: usize = 0;
    for (cand.items) |i| {
        if (placed >= max_labels) break;
        const n = &nodes[i];

        const screen = p.camera.worldToScreen(n.pos);
        const r_px = bubbleScreenRadius(n.*, zoom_t, slot * p.camera.zoom);
        // Only re-offer the old slot once the label is actually showing — a node that has
        // been dark for a while should re-enter on its parity preference, not on wherever it
        // happened to sit the last time it was visible.
        const sticky: ?labels.Slot = if (n.label_vis > 0.02) n.label_slot else null;
        const order = labels.slotOrder(latticeParity(n.*, p.layout_slot));
        const gap = label_gap * scale;

        // Whole name first. Clipping is a fallback for a title that could not find room
        // anywhere at full width, never a width budget applied up front.
        const full = font.textSize(n.title);
        var draw_len = n.title.len;
        var cut = false;
        var pl = placer.place(screen, r_px, full.w * scale, full.h * scale, gap, order, sticky);

        if (pl == null and full.w > label_max_w) {
            var end_idx: usize = n.title.len;
            const trimmed = font.textSizeEx(n.title, .{
                .max_width = label_max_w - ellipsis_w,
                .end_idx = &end_idx,
                .end_metric = .before,
            });
            pl = placer.place(
                screen,
                r_px,
                (trimmed.w + ellipsis_w) * scale,
                trimmed.h * scale,
                gap,
                order,
                sticky,
            );
            if (pl != null) {
                draw_len = end_idx;
                cut = true;
            }
        }
        const placement = pl orelse continue;

        n.label_slot = placement.slot;
        n.label_rect = placement.rect;
        n.label_len = draw_len;
        n.label_ellipsis = cut;
        want[i] = true;
        placed += 1;
    }

    var unsettled = false;
    for (nodes, 0..) |*n, i| {
        const target: f32 = if (want[i]) 1 else 0;
        n.label_vis += (target - n.label_vis) * t_chase;
        if (@abs(n.label_vis - target) > 0.004) unsettled = true;
    }
    p.labels_settled = !unsettled;
    if (unsettled) dvui.refresh(null, @src(), dvui.parentGet().data().id);
}

fn drawLabels(p: *Panel) void {
    if (p.interior.t >= 0.5) {
        const zoom_t = detailRevealT(p.interior.slot, p.camera.zoom);
        const fade = p.interior.t;
        for (p.interior.nodes, 0..) |n, i| {
            if (p.hover_node == i) continue;
            drawLabel(n, zoom_t, fade);
        }
        if (p.hover_node) |i| {
            if (i < p.interior.nodes.len) drawLabel(p.interior.nodes[i], zoom_t, fade);
        }
        return;
    }
    // Containment defers to the LOD, exactly as placement does — a mark that resolved to an
    // individual note is one, at any zoom. Without the same floor here `drawLabel` multiplies by a
    // near-zero reveal and throws away the label the placer just positioned, which is why names
    // appeared only in the narrow band where the zoom heuristic happened to agree.
    const zoom_t = @max(
        detailRevealT(p.layout_slot, p.camera.zoom),
        @as(f32, 1),
    );
    const fade = 1 - p.interior.t;

    {
        // Only notes resolved *this* frame. `label_rect` is screen space and valid for the frame
        // it was placed in, so drawing a note that has since merged away puts its name at a stale
        // screen position — which is what made labels drift and zoom independently of the field.
        for (p.visible.items) |v| {
            if (v.index >= p.nodes.len) continue;
            if (p.hover_node == v.index) continue;
            drawLabel(p.nodes[v.index], zoom_t, fade);
        }
        if (p.hover_node) |i| {
            if (i < p.nodes.len and p.at_level0.len == p.nodes.len and p.at_level0[i]) {
                drawLabel(p.nodes[i], zoom_t, fade);
            }
        }
        return;
    }

    for (p.nodes, 0..) |n, i| {
        if (p.hover_node == i) continue;
        drawLabel(n, zoom_t, fade);
    }
    // The one you pointed at goes on top — it is the only label allowed to sit over another,
    // and only while a displaced neighbour is still crossfading out.
    if (p.hover_node) |i| drawLabel(p.nodes[i], zoom_t, fade);
}

fn drawLabel(n: GraphNode, zoom_t: f32, fade: f32) void {
    if (n.label_vis <= 0.02 or n.label_len == 0 or n.label_len > n.title.len) return;
    const alpha = labelReveal(n, zoom_t) * n.label_vis * n.alpha * fade;
    if (alpha <= 0.02) return;

    const cw = dvui.currentWindow();
    const scale = cw.natural_scale;
    const theme = dvui.themeGet();

    // Bare text, no backing plate. A plate reads as a chip and blots out the links and dots
    // it sits on — it hides more than the incidental overlap it was there to prevent.
    const body = n.title[0..n.label_len];
    const text = if (n.label_ellipsis)
        std.fmt.allocPrint(cw.arena(), "{s}…", .{body}) catch body
    else
        body;

    dvui.renderText(.{
        .font = dvui.Font.theme(.body).larger(label_font_delta),
        .text = text,
        .color = theme.color(.content, .text).opacity(0.95 * alpha),
        .rs = .{ .r = n.label_rect, .s = scale },
    }) catch {};
}

/// Bubble radius from zoom resting swell + proximity grow stacked on top.
///
/// Important: do **not** feed `max(hover, zoom_rest)` through `outBack` — outBack overshoots
/// above 1 mid-curve then settles to 1 at t=1, so a zoomed-in node would *shrink* on full
/// hover. Zoom and hover are additive layers instead; hover alone can roughly double size.
/// Node radius in screen pixels.
///
/// Deliberately a *screen* size, not a world one: a note should read the same whether the vault
/// has ten notes or ten thousand, and that is what makes labels and hit targets stable.
///
/// But a fixed screen size stops being right once the lattice itself is smaller on screen than
/// the node drawn on it. Past that point every node overlaps its neighbours, nothing is
/// distinguishable, and — because `r_px` never fell — every one of them kept paying for a drop
/// shadow, an outline, and a full tessellated disc. Zoomed out on a large vault that was the
/// entire frame budget, spent drawing a solid blob.
///
/// So the radius is additionally capped at a fraction of the on-screen gap between lattice
/// cells. Zoomed in, `gap_px` is large and this never binds. Zoomed out it shrinks the node
/// smoothly, which lets the cheap-dot path, the shadow cut-off and the outline cut-off all
/// engage on their own.
fn bubbleScreenRadius(n: GraphNode, zoom_t: f32, gap_px: f32) f32 {
    const base: f32 = if (n.is_sun)
        sun_screen_r
    else if (n.open)
        open_screen_r
    else
        base_screen_r;
    const zoom_boost = zoom_rest_swell * std.math.clamp(zoom_t, 0, 1);
    // outBack only on the hover channel — pop on the way in, ends at grow when t=1.
    const hover = std.math.clamp(n.hover_t, 0, 1);
    const grow = if (n.is_sun) sun_grow_factor else grow_factor;
    const hover_boost = grow * dvui.easing.outBack(hover);
    const cap = if (n.is_sun) max_sun_screen_r else max_node_screen_r;
    const want = @min(base * (1.0 + zoom_boost + hover_boost), cap);
    // Hovered and open notes keep a floor: they are the ones the reader is deliberately tracking,
    // and losing them into the crowd is worse than a little overlap.
    const floor: f32 = if (n.is_sun or n.open or n.hover_t > 0.5) 3.0 else 0.6;
    return @max(@min(want, gap_px * gap_radius_frac), floor);
}

/// Resting fill, then the same `fill` → `fill_hover` lift a `ButtonWidget` does under the
/// cursor. Open notes already rest at `fill_hover`, so they lift to `fill_press` instead —
/// otherwise hovering the one node you most want feedback from would do nothing.
///
/// The sun is different: it fills with the graph/content background so edges passing under it
/// are occluded, but the disc itself reads hollow — only the dashed ring announces it.
fn nodeFill(theme: dvui.Theme, n: GraphNode) dvui.Color {
    if (n.is_sun) {
        // Half-transparent: the sun is a hole back out to the vault, so the web behind it
        // should show through rather than be occluded by a solid disc.
        const bg = theme.color(.content, .fill).opacity(sun_fill_opacity);
        const lit = dvui.easing.outQuad(std.math.clamp(n.pointer_t, 0, 1));
        if (lit <= 0.002) return bg;
        // Barely lift so pointer feedback exists without filling the hollow look back in.
        const lift: f32 = if (theme.dark) 10 else -8;
        return bg.lighten(lift * lit);
    }
    const accent = theme.color(.control, .fill_hover);
    const base = theme.color(.control, .fill);
    const rest = if (n.open)
        accent
    else if (n.phantom)
        base.opacity(0.4)
    else
        base.lighten(if (theme.dark) 6 else -6);

    const lit = n.pointer_t;
    if (lit <= 0.002) return rest;
    const target = if (n.open) theme.color(.control, .fill_press) else accent;
    // Phantoms are deliberately translucent; keep that while still letting them light up.
    const to = if (n.phantom) target.opacity(0.55) else target;
    return rest.lerp(to, dvui.easing.outQuad(std.math.clamp(lit, 0, 1)));
}

/// Floating round "zoom to fit" button in the bottom-right of the graph viewport.
///
/// Same shape as pixi's canvas action buttons — `FloatingWidget` + a round `ButtonWidget`
/// with a drop shadow. The `FloatingWidget` also earns its keep on the input side: it
/// registers a subwindow over the button rect, so `pointerTargetsMainPane` in `handleInput`
/// rejects presses here and a click on the button can't also pan the graph.
fn drawFitButton(p: *Panel, container: *dvui.WidgetData) void {
    if (p.nodes.len == 0) return;

    const size: f32 = 32;
    const btn_radius: f32 = size / 2;
    const icon_padding: f32 = size * 0.3;
    const margin: f32 = 10;

    const nat = container.contentRectScale().r.toNatural();
    // Don't cover a panel that's been dragged down to a sliver.
    if (nat.w < size + 2 * margin or nat.h < size + 2 * margin) return;

    var fw: dvui.FloatingWidget = undefined;
    fw.init(@src(), .{}, .{
        .rect = .{
            .x = nat.x + nat.w - margin - size,
            .y = nat.y + nat.h - margin - size,
            .w = size,
            .h = size,
        },
        .expand = .none,
        .background = false,
    });
    defer fw.deinit();

    const theme = dvui.themeGet();
    const fill = theme.color(.content, .fill);

    var btn: dvui.ButtonWidget = undefined;
    btn.init(@src(), .{}, .{
        .expand = .both,
        .min_size_content = .{ .w = size, .h = size },
        .background = true,
        .corners = .round(btn_radius),
        .color_fill = fill,
        .color_fill_hover = fill.lighten(if (theme.dark) 10.0 else -10.0),
        .color_border = .transparent,
        // Pad on the button, not the icon: a uniform pad on the icon forces its content
        // rect square and skews non-square glyphs under `expand = .ratio`.
        .padding = dvui.Rect.all(icon_padding),
        .margin = .{},
        .box_shadow = .{
            .color = .black,
            .alpha = 0.2,
            .fade = 4,
            .offset = .{ .x = 0, .y = 2 },
            .corners = .round(btn_radius),
        },
    });
    defer btn.deinit();
    btn.processEvents();
    btn.drawBackground();

    const icon_color = theme.color(.content, .text);
    dvui.icon(
        @src(),
        "zoom graph to fit",
        icons.tvg.lucide.maximize,
        .{ .stroke_color = icon_color, .fill_color = icon_color },
        .{
            // `min_size_content.h` must be a real height — IconWidget derives width from it
            // and clamps up to `min_size_content.w`, so a placeholder height would square
            // the glyph and `.ratio` would then stretch it.
            .expand = .ratio,
            .gravity_x = 0.5,
            .gravity_y = 0.5,
            .min_size_content = .{ .w = 1.0, .h = size },
        },
    );

    if (btn.clicked()) zoomExtents();
}

fn profNow() i96 {
    if (!debug_hud) return 0;
    return std.Io.Clock.boot.now(dvui.io).nanoseconds;
}

/// Nanoseconds since `mark`, and advance it. Zero when the HUD is off, so every call site
/// compiles down to nothing.
fn profLap(mark: *i96) u64 {
    if (!debug_hud) return 0;
    const now = std.Io.Clock.boot.now(dvui.io).nanoseconds;
    defer mark.* = now;
    return @intCast(now - mark.*);
}

fn drawDebugHud(p: *Panel) void {
    const cw = dvui.currentWindow();
    const vp = p.camera.viewport;

    var min_x: f32 = std.math.floatMax(f32);
    var min_y: f32 = std.math.floatMax(f32);
    var max_x: f32 = -std.math.floatMax(f32);
    var max_y: f32 = -std.math.floatMax(f32);
    for (p.nodes) |n| {
        min_x = @min(min_x, n.target.x);
        min_y = @min(min_y, n.target.y);
        max_x = @max(max_x, n.target.x);
        max_y = @max(max_y, n.target.y);
    }
    const span = if (p.nodes.len > 1 and max_y > min_y)
        (max_x - min_x) / @max(max_y - min_y, 1)
    else
        0;

    const settle_n = @min(p.settle_frames, aspect_settle_frames);
    // Exactly what `wantsRepaint` reads, in the same order — when the app won't sleep, this line
    // names the reason instead of leaving it to be guessed at.
    const awake = std.fmt.allocPrint(cw.arena(), "{s}{s}{s}{s}{s}{s}{s}{s}{s}{s}", .{
        if (p.fling_x.coasting or p.fling_y.coasting) "fling " else "",
        if (p.drag_active) "drag " else "",
        if (p.gesture_active) "gesture " else "",
        if (!p.proximity_settled) "proximity " else "",
        if (!p.layout_settled) "layout " else "",
        if (!p.pointer_settled) "pointer " else "",
        if (!p.edges_settled) "edges " else "",
        if (!p.labels_settled) "labels " else "",
        if (p.camera.chasing()) "camera " else "",
        if (p.aspect_waiting) "aspect " else "",
    }) catch "?";

    const fp = frame_profile;
    const rs = cw.renderStats();
    const us = struct {
        fn f(ns: u64) f64 {
            return @as(f64, @floatFromInt(ns)) / 1000.0;
        }
    }.f;

    const shape = std.fmt.allocPrint(cw.arena(),
        "pane {d:.0}x{d:.0}  raw {d:.2}  smooth {d:.2}  aspect {d:.2}\n" ++
        "span {d:.2}  nodes {d}  islands {d}  slot {d:.0}  zoom {d:.3}\n" ++
        "settle {d}/{d}  framing {s}  interior t {d:.2}\n" ++
        "awake: {s}",
        .{
            vp.w,                 vp.h,
            if (vp.h > 0) vp.w / vp.h else 0,
            p.aspect_smooth,      p.layout_aspect,
            span,                 p.nodes.len,
            p.island_count,       p.layout_slot,
            p.camera.zoom,        settle_n,
            aspect_settle_frames, @tagName(p.framing),
            p.interior.t,         if (awake.len == 0) "(asleep)" else awake,
        },
    ) catch return;

    const perf = std.fmt.allocPrint(cw.arena(),
        "visible {d} ({d} notes)  drawn {d} batched + {d} pathed, {d}/{d} links, {d} markers\n" ++
        "lod {d:.2}/{d}  tiles {d} ({d} direct)  atlas {d}/{d}, {d} baked\n" ++
        "gpu {d} calls  {d} tris\n" ++
        "us total {d:.0} | rebuild {d:.0}  bubbles {d:.0}  hover {d:.0}  labels {d:.0}  anim {d:.0}\n" ++
        "   edges {d:.0}  nodes {d:.0}  clusters {d:.0}  names {d:.0}",
        .{
            p.visible.items.len,  p.notes_at_level0,
            fp.nodes_drawn,       fp.nodes_pathed,
            fp.edges_drawn,       p.vis_edges.items.len,
            fp.clusters_drawn,
            p.lod_level,          if (p.pyramid) |py| py.maxLevel() else 0,
            fp.tiles_drawn,       fp.tiles_direct,
            p.atlas.next,         p.atlas.capacity(),
            fp.tiles_baked,
            rs.draw_calls,        rs.triangles,
            us(fp.total()),       us(fp.rebuild_ns),
            us(fp.bubbles_ns),    us(fp.hover_ns),
            us(fp.labels_ns),     us(fp.edge_anim_ns),
            us(fp.draw_edges_ns), us(fp.draw_nodes_ns),
            us(fp.draw_clusters_ns), us(fp.draw_labels_ns),
        },
    ) catch return;

    const text = std.fmt.allocPrint(cw.arena(), "{s}\n{s}", .{ shape, perf }) catch return;

    const scale = cw.natural_scale;
    const rect: dvui.Rect.Physical = .{
        .x = vp.x + 8 * scale,
        .y = vp.y + 8 * scale,
        .w = vp.w - 16 * scale,
        .h = 132 * scale,
    };
    rect.fill(.{}, .{ .color = dvui.Color.black.opacity(0.55), .fade = 1 });
    dvui.renderText(.{
        .font = dvui.Font.theme(.body).larger(-2),
        .text = text,
        .color = .{ .r = 120, .g = 255, .b = 160, .a = 255 },
        .rs = .{ .r = rect, .s = scale },
    }) catch {};
}

/// Shown while the first layout of a vault is still solving on its worker.
fn drawLayoutSpinner(note_count: u32) void {
    var box = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .background = false,
        .gravity_x = 0.5,
        .gravity_y = 0.5,
    });
    defer box.deinit();

    dvui.spinner(@src(), .{
        .gravity_x = 0.5,
        .min_size_content = .{ .w = 28, .h = 28 },
        .color_text = dvui.themeGet().color(.content, .text).opacity(0.5),
    });

    var buf: [64]u8 = undefined;
    const msg = if (note_count > 0)
        (std.fmt.bufPrint(&buf, "Building {d} notes…", .{note_count}) catch "Building…")
    else
        "Building…";
    dvui.labelNoFmt(@src(), msg, .{}, .{
        .font = dvui.Font.theme(.body).larger(-1),
        .color_text = dvui.themeGet().color(.content, .text).opacity(0.5),
        .gravity_x = 0.5,
        .margin = .{ .y = 8 },
    });
}

/// Corner cue while an async synth rebuild runs — previous graph stays pan/zoomable underneath.
fn drawSynthRegenCue() void {
    var box = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .none,
        .background = false,
        .gravity_x = 0.0,
        .gravity_y = 0.0,
        .margin = .{ .x = 10, .y = 8 },
    });
    defer box.deinit();
    dvui.spinner(@src(), .{
        .min_size_content = .{ .w = 14, .h = 14 },
        .color_text = dvui.themeGet().color(.content, .text).opacity(0.45),
    });
    dvui.labelNoFmt(@src(), "Updating synth…", .{}, .{
        .font = dvui.Font.theme(.body).larger(-2),
        .color_text = dvui.themeGet().color(.content, .text).opacity(0.45),
        .margin = .{ .x = 6 },
    });
}

fn drawCenteredHint(msg: []const u8) void {
    var box = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .background = false,
        .gravity_x = 0.5,
        .gravity_y = 0.5,
    });
    defer box.deinit();
    dvui.labelNoFmt(@src(), msg, .{}, .{
        .font = dvui.Font.theme(.body).larger(-1),
        .color_text = dvui.themeGet().color(.content, .text).opacity(0.5),
        .gravity_x = 0.5,
    });
}

fn handleInput(p: *Panel) void {
    const pane = dvui.parentGet().data();
    const rs = pane.rectScale();
    const id = pane.id;
    const scheme = sdk.host().panZoomScheme();

    if (core.dvui.canvasPointerInputSuppressed()) {
        if (dvui.captured(id)) {
            for (dvui.events()) |*e| {
                if (e.evt == .mouse and e.evt.mouse.action == .release and e.evt.mouse.button.pointer()) {
                    dvui.captureMouse(null, e.num);
                    dvui.dragEnd();
                }
            }
        }
        return;
    }

    updateTouchGesture(p, pane);

    var frame_dx: f32 = 0;
    var frame_dy: f32 = 0;
    var released_moved = false;
    var zoomed_this_frame = false;
    p.drag_active = false;

    // Accumulate zoom over the frame (CanvasWidget idiom) so many small wheel events
    // become one zoom-around-cursor instead of N successive corrections.
    var zoom_factor: f32 = 1.0;
    var zoom_focal: dvui.Point.Physical = dvui.currentWindow().mouse_pt;

    for (dvui.events()) |*e| {
        if (e.handled) continue;
        if (e.evt != .mouse) continue;
        const me = e.evt.mouse;
        if (!pointerTargetsMainPane(me.p)) continue;
        const inside = rs.r.contains(me.p);
        if (!inside and !dvui.captured(id)) continue;
        if (p.gesture_active) continue;

        switch (me.action) {
            .press => {
                if (me.button.pointer() or me.button == .middle) {
                    e.handle(@src(), pane);
                    dvui.captureMouse(pane, e.num);
                    dvui.dragPreStart(me.button, me.p, .{ .name = "atlas_graph_pan", .cursor = .hand });
                    p.moved_since_press = false;
                    p.drag_was_touch = me.button.touch();
                    p.press_node = hitTestActive(p, me.p);
                    p.fling_x.begin();
                    p.fling_y.begin();
                    p.camera.user_driving = true;
                }
            },
            .release => {
                if ((me.button.pointer() or me.button == .middle) and dvui.captured(id)) {
                    e.handle(@src(), pane);
                    dvui.captureMouse(null, e.num);
                    dvui.dragEnd();
                    if (p.moved_since_press) {
                        released_moved = true;
                    } else if (me.button.pointer() or me.button == .middle) {
                        if (p.interior.t >= 0.5) {
                            // Inside a note: sun exits to the vault view; a section scrolls the
                            // editor to that heading (placeholder until richer focus lands).
                            if (hitTestActive(p, me.p)) |ni| {
                                if (ni < p.interior.nodes.len and p.interior.nodes[ni].is_sun) {
                                    exitInterior(p);
                                } else {
                                    revealInteriorSection(p, ni);
                                }
                            }
                        } else if (hitTestActive(p, me.p)) |ni| {
                            // Leaves win over masses — a note drawn on/near a dashed ring must
                            // open in place, not steal into `frameCluster` for the mass under it.
                            const open_side = me.button == .middle or me.mod.matchBind("ctrl/cmd");
                            // Two steps, deliberately. Opening a document is a request to see
                            // it *in context* — where it sits, what it is next to — so the
                            // first click only moves closer. Going inside it is a second,
                            // separate decision, and clicking the node you are already on is
                            // how you say so. Diving on the first click took the context away
                            // at the exact moment it was asked for.
                            const revisit = p.nodes[ni].open;
                            // Camera first, file second — `revealPosition` may kick tab/focus
                            // work that would otherwise hitch the start of the flight.
                            if (revisit) {
                                enterInterior(p, p.nodes[ni].note_id);
                            } else {
                                focusNode(p, ni);
                            }
                            openNode(p, ni, open_side);
                        } else if (hitTestClusters(p, me.p)) |ci| {
                            // Dashed coalesced mass: frame its content and open one sticky level.
                            frameCluster(p, ci);
                        }
                    }
                    p.moved_since_press = false;
                    p.press_node = null;
                }
            },
            .motion => {
                if (!dvui.captured(id)) continue;
                const dps: dvui.Point.Physical = if (me.button.touch())
                    me.action.motion
                else if (dvui.dragging(me.p, "atlas_graph_pan")) |d|
                    d
                else
                    continue;
                p.drag_active = true;
                p.moved_since_press = true;
                cameraTakenOver(p);
                p.camera.panScreen(dps.x, dps.y);
                frame_dx += dps.x;
                frame_dy += dps.y;
                dvui.refresh(null, @src(), id);
            },
            .wheel_y, .wheel_x => {
                if (!inside) continue;
                e.handle(@src(), pane);
                switch (scheme) {
                    .mouse => {
                        // Scroll = zoom around cursor. Bases match CanvasWidget (pixi) —
                        // the old 1.08 made a flick jump an order of magnitude and felt
                        // like a bounce/invert against the zoom clamp.
                        if (me.action == .wheel_y) {
                            const base: f32 = 1.005;
                            const zs = @exp(@log(base) * me.action.wheel_y);
                            if (zs != 1.0) {
                                zoom_factor *= zs;
                                zoom_focal = me.p;
                                zoomed_this_frame = true;
                            }
                        }
                    },
                    .trackpad => {
                        if (me.mod.matchBind("zoom")) {
                            // Modifier-scroll = zoom only. Swallow wheel_x — trackpads emit
                            // residual horizontal deltas during a zoom gesture and panning
                            // those made the focal node slide sideways.
                            if (me.action == .wheel_y) {
                                const base: f32 = if (me.mod.matchBind("shift")) 1.003 else 1.002;
                                const zs = @exp(@log(base) * me.action.wheel_y);
                                if (zs != 1.0) {
                                    zoom_factor *= zs;
                                    zoom_focal = me.p;
                                    zoomed_this_frame = true;
                                }
                            }
                        } else if (!zoomed_this_frame) {
                            // Two-finger scroll pans. Skip if we already zoomed this frame
                            // (pinch + scroll can arrive together).
                            const dx = if (me.action == .wheel_x) me.action.wheel_x else 0;
                            const dy = if (me.action == .wheel_y) me.action.wheel_y else 0;
                            if (dx != 0 or dy != 0) {
                                p.camera.panScreen(dx * 2, dy * 2);
                                cameraTakenOver(p);
                                dvui.refresh(null, @src(), id);
                            }
                        }
                    },
                }
            },
            .position => {
                // One `.position` event lands at the end of each frame, at wherever the
                // mouse finished. Deliberately left unhandled (dvui convention) so other
                // widgets can still do their own hover work.
                if (!inside) continue;
                if (p.hover_node != null or p.hover_cluster != null) dvui.cursorSet(.hand);
            },
            else => {},
        }
    }

    if (zoomed_this_frame and zoom_factor != 1.0) {
        p.fling_x.cancel();
        p.fling_y.cancel();
        p.camera.zoomAtScreen(zoom_factor, zoom_focal);
        cameraTakenOver(p);
        dvui.refresh(null, @src(), id);
    }

    if (p.drag_active) {
        p.fling_x.sampleTimed(frame_dx);
        p.fling_y.sampleTimed(frame_dy);
    }
    if (released_moved) {
        p.drag_active = false;
        _ = p.fling_x.releaseWindowed(pan_fling_tuning, pan_fling_window_s);
        _ = p.fling_y.releaseWindowed(pan_fling_tuning, pan_fling_window_s);
        if (p.fling_x.coasting or p.fling_y.coasting) {
            dvui.refresh(null, @src(), id);
        }
    }
}

fn updateTouchGesture(p: *Panel, pane: *dvui.WidgetData) void {
    var zoom: f32 = 1.0;
    var zoom_p: dvui.Point.Physical = p.last_centroid;

    for (dvui.events()) |*e| {
        if (e.evt != .mouse) continue;
        const me = e.evt.mouse;
        if (!me.button.touch()) continue;
        const slot_signed = @intFromEnum(me.button) - @intFromEnum(dvui.enums.Button.touch0);
        if (slot_signed < 0 or slot_signed >= p.touches.len) continue;
        const slot: usize = @intCast(slot_signed);
        const inside = pane.rectScale().r.contains(me.p);

        switch (me.action) {
            .press => {
                if (!inside and !p.gesture_active) continue;
                p.touches[slot] = .{ .active = true, .p = me.p };
                if (activeTouchCount(p) >= 2 and !p.gesture_active) {
                    p.gesture_active = true;
                    p.fling_x.cancel();
                    p.fling_y.cancel();
                    p.last_centroid = touchCentroid(p);
                    p.last_pinch = touchPinchDistance(p);
                    dvui.captureMouse(pane, e.num);
                    cameraTakenOver(p);
                } else if (p.gesture_active) {
                    p.last_centroid = touchCentroid(p);
                    p.last_pinch = touchPinchDistance(p);
                }
                if (p.gesture_active) e.handle(@src(), pane);
            },
            .release => {
                if (p.touches[slot].active) p.touches[slot].active = false;
                if (p.gesture_active) {
                    e.handle(@src(), pane);
                    if (activeTouchCount(p) == 0) {
                        p.gesture_active = false;
                        if (dvui.captured(pane.id)) dvui.captureMouse(null, e.num);
                    } else {
                        p.last_centroid = touchCentroid(p);
                        p.last_pinch = touchPinchDistance(p);
                    }
                }
            },
            .motion => {
                if (p.touches[slot].active) p.touches[slot].p = me.p;
                if (p.gesture_active) {
                    e.handle(@src(), pane);
                    const new_c = touchCentroid(p);
                    p.camera.panScreen(new_c.x - p.last_centroid.x, new_c.y - p.last_centroid.y);
                    const new_d = touchPinchDistance(p);
                    if (p.last_pinch > 1.0 and new_d > 1.0) {
                        zoom *= new_d / p.last_pinch;
                        zoom_p = new_c;
                    }
                    p.last_centroid = new_c;
                    p.last_pinch = new_d;
                    dvui.refresh(null, @src(), pane.id);
                }
            },
            else => {},
        }
    }

    if (zoom != 1.0) {
        p.camera.zoomAtScreen(zoom, zoom_p);
        dvui.refresh(null, @src(), pane.id);
    }
}

fn activeTouchCount(p: *const Panel) usize {
    var n: usize = 0;
    for (p.touches) |t| {
        if (t.active) n += 1;
    }
    return n;
}

fn touchCentroid(p: *const Panel) dvui.Point.Physical {
    var sx: f32 = 0;
    var sy: f32 = 0;
    var n: f32 = 0;
    for (p.touches) |t| {
        if (!t.active) continue;
        sx += t.p.x;
        sy += t.p.y;
        n += 1;
    }
    if (n == 0) return .{};
    return .{ .x = sx / n, .y = sy / n };
}

fn touchPinchDistance(p: *const Panel) f32 {
    var a: ?dvui.Point.Physical = null;
    var b: ?dvui.Point.Physical = null;
    for (p.touches) |t| {
        if (!t.active) continue;
        if (a == null) {
            a = t.p;
        } else {
            b = t.p;
            break;
        }
    }
    if (a == null or b == null) return 0;
    const dx = a.?.x - b.?.x;
    const dy = a.?.y - b.?.y;
    return @sqrt(dx * dx + dy * dy);
}

fn hitTestActive(p: *Panel, screen: dvui.Point.Physical) ?usize {
    if (p.interior.t >= 0.5 and p.interior.nodes.len > 0) {
        return hitTestNodes(p, p.interior.nodes, p.interior.slot, screen);
    }
    return hitTestNodes(p, p.nodes, p.layout_slot, screen);
}

fn hitTestNodes(p: *Panel, nodes: []const GraphNode, slot: f32, screen: dvui.Point.Physical) ?usize {
    var best: ?usize = null;
    var best_d: f32 = std.math.floatMax(f32);
    const zoom_t = @max(detailRevealT(slot, p.camera.zoom), @as(f32, 1));
    // Only what is actually on screen as itself. A note merged into a marker is not clickable —
    // and walking the selection instead of the whole vault is also what keeps this off the
    // per-frame O(n) list, since the selection is bounded by the viewport. The interior has no
    // such gating: every content item is always drawn as itself (see `buildInteriorWorld`), so
    // `nodes.ptr == p.interior.nodes.ptr` never needs an equivalent to `p.at_level0`.
    const drawn = if (nodes.ptr == p.nodes.ptr and p.at_level0.len == nodes.len)
        p.at_level0
    else
        null;
    for (nodes, 0..) |n, i| {
        if (drawn) |d| {
            if (!d[i]) continue;
        }
        const s = p.camera.worldToScreen(n.pos);
        const dx = s.x - screen.x;
        const dy = s.y - screen.y;
        const d = @sqrt(dx * dx + dy * dy);
        const hit_r = bubbleScreenRadius(n, zoom_t, slot * p.camera.zoom) + 6;
        if (d <= hit_r and d < best_d) {
            best_d = d;
            best = i;
        }
    }
    return best;
}

/// Leave a note's interior and frame that note back in the vault neighbourhood.
///
/// Deliberately not `zoomExtents`: while descent `t` is still high that path re-pins the
/// interior sun. Focusing the parent note is the reverse of the click that brought you in.
fn exitInterior(p: *Panel) void {
    p.camera.user_driving = false;
    const id = p.interior.note_id orelse {
        p.framing = .extents;
        fitToNodes(p, .{ .animate = true });
        return;
    };
    if (p.id_index.get(id)) |idx| {
        focusNode(p, idx);
    } else {
        p.framing = .extents;
        fitToNodes(p, .{ .animate = true });
    }
}

/// Begin descending into `note_id`. `updateInterior` runs earlier in the frame than input, so
/// the cloud is built and the camera retargeted here — otherwise a revisit click only flipped
/// `framing` and waited for a chase/layout gate that never opened.
fn enterInterior(p: *Panel, note_id: i64) void {
    p.framing = .{ .interior = note_id };
    p.camera.user_driving = false;
    p.interior.note_id = note_id;
    const st = runtime.state();
    const gen = st.generation.load(.acquire);
    if (p.interior.built_id != note_id or p.interior.built_gen != gen or
        p.interior.built_aspect != p.layout_aspect)
    {
        buildInteriorWorld(p, st, note_id, gen) catch {
            // Nothing to descend into — keep the neighbourhood focus instead of pinning
            // `wantsRepaint` on an interior that will never arrive.
            if (p.id_index.get(note_id)) |idx| focusNode(p, idx);
            return;
        };
    }
    applyFraming(p);
    dvui.refresh(null, @src(), null);
}

/// Placeholder: scroll the open editor to the heading this section node represents.
/// Richer "focus this heading in the graph" behaviour can replace the body later; the
/// click wiring and stored `line` are what matter now.
fn revealInteriorSection(p: *Panel, idx: usize) void {
    if (idx >= p.interior.nodes.len) return;
    const n = p.interior.nodes[idx];
    const st = runtime.state();
    const root = st.vault_root orelse return;
    const wb = sdk.host().getServiceTyped(sdk.services.workbench.Api) orelse return;
    const abs = std.fs.path.join(dvui.currentWindow().arena(), &.{ root, n.path }) catch return;
    _ = wb.revealPosition(abs, n.line, 0, false) catch |err| {
        dvui.log.err("atlas: revealPosition {s}:{d}: {any}", .{ abs, n.line, err });
    };
}

fn openNode(p: *Panel, idx: usize, open_side: bool) void {
    const st = runtime.state();
    const root = st.vault_root orelse return;
    const n = p.nodes[idx];
    const wb = sdk.host().getServiceTyped(sdk.services.workbench.Api) orelse return;

    if (n.phantom) {
        // Only invent a note for note-like phantoms. Never turn `foo.zig` into `foo.zig.md`.
        if (!resolve.isNoteLikeTarget(n.title)) return;
        const stem = blk: {
            for ([_][]const u8{ ".md", ".markdown" }) |ext| {
                if (n.title.len > ext.len and std.ascii.endsWithIgnoreCase(n.title, ext)) {
                    break :blk n.title[0 .. n.title.len - ext.len];
                }
            }
            break :blk n.title;
        };
        const path = std.fmt.allocPrint(dvui.currentWindow().arena(), "{s}/{s}.md", .{ root, stem }) catch return;
        wb.createFile(path) catch |err| {
            dvui.log.err("atlas: createFile {s}: {any}", .{ path, err });
            return;
        };
        // Index it now rather than waiting on `Watcher`'s 2s poll. `upsertNote` promotes the
        // phantom row in place — same id, `phantom = 0` — so every link already pointing here
        // keeps pointing at it and simply becomes a live edge. Nothing in the source file has
        // to change; the wikilink resolves because its target now exists. Without this the
        // node just sits there looking phantom until the poll happens to catch up.
        if (st.indexer_ready) {
            if (query.vaultRelative(root, path)) |rel| st.indexer.enqueue(rel);
        }
        _ = wb.revealPosition(path, 0, 0, open_side) catch {};
        return;
    }

    const abs = std.fs.path.join(dvui.currentWindow().arena(), &.{ root, n.path }) catch return;
    if (open_side) {
        const g = wb.newGrouping();
        _ = wb.open(abs, g) catch |err| {
            dvui.log.err("atlas: open {s}: {any}", .{ abs, err });
        };
    } else {
        _ = wb.revealPosition(abs, 0, 0, false) catch |err| {
            dvui.log.err("atlas: revealPosition {s}: {any}", .{ abs, err });
        };
    }
}

fn pointerTargetsMainPane(pt: dvui.Point.Physical) bool {
    const cw = dvui.currentWindow();
    const main_id = cw.data().id;
    const target = cw.subwindows.windowFor(pt);
    if (target != .zero and target != main_id) return false;
    for (cw.subwindows.stack.items[1..]) |sub| {
        if (sub.modal) return false;
    }
    return true;
}

/// Continuous frames while flinging/dragging, while layout / proximity / pointer-highlight /
/// label chases are settling, while links are extending/retracting, or while the camera is
/// animating to a target.
pub fn wantsRepaint() bool {
    // Consume visibility from the last paint. If the panel is closed we never draw, so after
    // one poll this goes false and the app can sleep even if settle flags are mid-chase.
    const visible = drawn_recently;
    drawn_recently = false;
    if (!visible) return false;

    const p = panel orelse return false;
    // A solve on a worker publishes nothing the frame loop can wait on, so keep frames coming
    // until it lands — that is also what animates the spinner drawn in its place.
    if (p.job != null) return true;
    return p.fling_x.coasting or p.fling_y.coasting or p.drag_active or p.gesture_active or
        !p.proximity_settled or !p.layout_settled or !p.pointer_settled or !p.edges_settled or
        !p.labels_settled or p.camera.chasing() or p.aspect_waiting or p.rebuild_waiting or
        (if (p.world_state) |*w| !w.settled else false) or
        p.select_anim < 1 or
        // Keep ticking while a descent is still *arriving*. Gating on `t < 0.98` alone never
        // stops for a note whose interior cannot fill the panel — the zoom ceiling
        // (`fitMaxGapPx`) or a clamped nest can leave the descent topping out below 0.98, and
        // then this clause is true for as long as the note stays open and the app never sleeps
        // again. Progress is the honest test: once the camera has arrived, `t` stops moving,
        // whatever value it arrived at.
        (p.framing == .interior and p.interior.nodes.len > 0 and p.interior.t < 0.98 and
            @abs(p.interior.t - p.interior.t_prev) > 0.0005);
}
