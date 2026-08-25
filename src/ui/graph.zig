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
const Camera = @import("Camera.zig");
const dotgrid = @import("dotgrid.zig");
const hex = @import("hex.zig");
const interior = @import("interior.zig");
const labels = @import("labels.zig");
const excerpt = @import("excerpt.zig");
const layout_full = @import("layout_full.zig");
const galaxy = @import("galaxy.zig");
const world_mod = @import("world.zig");
const world_draw = @import("world_draw.zig");
const containment = @import("containment.zig");

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

/// The display scale every `_px` / `_screen_r` constant below is written in.
///
/// They are **physical** pixels on a 2x (hidpi) screen, because that is the machine they were
/// dialled in on and the numbers worth keeping are the ones that were actually looked at.
const tuned_scale: f32 = 2;

/// Converts a tuned constant to the reader's screen. 1 on a hidpi display, 0.5 on an ordinary one.
///
/// The camera converts world units straight to `Point.Physical`, so a constant compared against,
/// added to, or divided into a camera result lands in physical pixels — and a physical pixel is
/// half the size on a hidpi screen. Text never had this problem: `renderText` takes a `RectScale`
/// and the label pass multiplies its gaps by `natural_scale`, so labels have always sized
/// themselves to the display. The bubbles, the hover falloff and the world LOD thresholds did
/// not, so they drew at their tuned size on a 2x screen and at twice that everywhere else — a
/// 1x monitor showed nodes twice as large as intended, against labels that were the right size.
fn dpiScale() f32 {
    return dvui.currentWindow().natural_scale / tuned_scale;
}

/// On-screen bubble radii — constant across zoom, like pixi's `/ canvas.scale` buttons.
/// See `tuned_scale` for the unit.
const base_screen_r: f32 = 9;

/// Interior content. A document is its own fold/containment/world cloud — the same machinery the
/// vault overview uses, fed the note's headings/paragraphs/lists/tags/embeds instead of the
/// vault's notes (see `buildInteriorWorld`). The document itself (item 0, the "sun") is pinned at
/// the cloud's centre outside that system entirely, so it can never be coalesced away.
/// The reach-out rate now lives on `world.Params.focus_reach_rate`, because the animation is per
/// link and advanced by `World.stepFocusGrow` rather than by a panel-wide scalar. Kept as a note
/// rather than a constant so nobody reintroduces a second source of truth for the same timing.
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
/// How far the hovered node's fill travels toward the highlight colour. See `nodeFill`.
const hover_fill_mix: f32 = 0.45;
/// How far into a descent the overview keeps full strength before it begins to give way. The node
/// being zoomed into has to stay solid while it grows. See the draw block in `drawPanel`.
const overview_hold_t: f32 = 0.45;
/// Padding around the two unconditional labels' plate, and how opaque it sits. See
/// `renderTextPlated`.
const label_plate_pad_x: f32 = 6;
const label_plate_pad_y: f32 = 2;
const label_plate_opacity: f32 = 0.6;

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
/// Chase rate for hover_t (1/s). Higher = snappier.
const hover_chase_k: f32 = 14;
/// Dwell before the mass-influence ring appears. A glance should not paint a second disc
/// around every note the cursor skims; 400 ms is long enough to mean "I am looking at this."
/// Chase rate for the button-style pointer highlight (1/s). Snappier than the proximity
/// swell — this one is a direct answer to "the cursor is on me", so it should feel instant.
const pointer_chase_k: f32 = 22;
/// Chase rate for layout home → target (1/s). Slower than hover so the web "breathes" into
/// a new configuration instead of snapping.
const layout_chase_k: f32 = 5.5;
/// Chase rate for camera retargets (1/s) — focus, zoom-extents, resize refits.
const camera_chase_k: f32 = 7;
/// Screen padding for the focus frame, capped against short panels.
/// Half-width of the focus frame, in lattice slots: one note plus a readable ring around it.
const focus_context_slots: f32 = 3.5;
/// How far above the resolve zoom to sit, so the note is comfortably a note and not on the cusp.
const focus_resolve_margin: f32 = 1.15;
const focus_padding_px: f32 = 56;
/// On-screen px between lattice neighbours a focus will not zoom *in* past — the close-up
/// ceiling for a small selection. Zoom-*out* is floored at the extents pose instead: a focus
/// never pulls further back than the center/maximize button, even when the open set spans the
/// vault.
const focus_max_gap_px: f32 = 300;
/// Fill alpha of the interior sun — see `nodeFill`.
const sun_fill_opacity: f32 = 0.5;
/// Labels use a fixed natural font size regardless of camera zoom.
const label_font_delta: f32 = -1;
/// Gap between a mark's rim and an open document's name below it. See `drawOpenNoteLabels`.
/// Clear space between a disc's edge and its name's plate, in logical pixels.
const label_gap_px: f32 = 9;
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
/// Why an opened document did or did not recentre the camera. Off by default; the log line it
/// guards distinguishes "startup discovery pass", "open set never changed" and "note not matched
/// to a graph node", which are indistinguishable from the outside.
const framing_debug = false;
/// Paired with `debug_hud` — see the log line in `updateLabels`. It separates the three causes of
/// a missing label that look identical on screen: no candidates, empty titles, or a placer that
/// found room for nobody.
const label_debug = false;
var label_debug_last: f64 = 0;
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
    /// Compared against the next rebuild's to decide whose links moved, which is what re-frames
    /// the camera on an edit. Positions no longer depend on it: containment derives those from the
    /// link hierarchy, so an unchanged note keeps its cell without being pinned there.
    link_sig: u64 = 0,
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
    /// `label_epoch` of the `updateLabels` run that last gave this node a placement. Lets the
    /// fade pass tell "placed this frame" from "was showing a moment ago" without a per-node
    /// array — see `updateLabels`.
    label_epoch: u32 = 0,
};

/// Bumped once per `updateLabels` call, so a node's `label_epoch` names one specific run.
var label_epoch: u32 = 0;

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

/// The note the camera should stay with across a rebuild: whatever is framed, else the open one.
fn anchorNoteId(p: *Panel) ?i64 {
    switch (p.framing) {
        .note => |id| return id,
        .interior => |id| return id,
        else => {},
    }
    if (p.open_notes.items.len > 0) {
        const idx = p.open_notes.items[0];
        if (idx < p.nodes.len) return p.nodes[idx].note_id;
    }
    return null;
}

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
/// What a running solve is currently doing, for the spinner. Written by the worker, read by the
/// UI thread — the world build is tens of seconds on a large vault, and reporting it as the same
/// "laying out" step the solve uses makes a long but healthy build indistinguishable from a hang.
const JobPhase = enum(u8) { solving, building_map };

const LayoutJob = struct {
    arena: std.heap.ArenaAllocator,
    phase: std.atomic.Value(u8) = .init(@intFromEnum(JobPhase.solving)),
    /// Set by `shutdownPanel` so the worker can abandon a long build instead of making teardown
    /// wait for it. The join itself is not optional — the worker is executing code inside a dylib
    /// that is about to be unloaded — so the only way to make closing the app prompt is to give
    /// the work somewhere to stop.
    cancel: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,
    done: std.atomic.Value(bool) = .init(false),
    /// Set by the worker when the solve fails; re-raised on the UI thread at apply time.
    fail: ?anyerror = null,

    /// What this rebuild was for — checked at apply time, since the vault can move underneath.
    gen: u64,
    open_hash: u64,
    first_build: bool,
    aspect: f32,
    prior_slot: ?f32,

    /// Snapshot copy and the draw order over it; both live in `arena`.
    snap: Indexer.Snapshot,
    order: []usize,

    n: usize,
    edges: []GraphEdge,
    layout_edges: []layout_full.Edge,
    degrees: []u32,
    paths: [][]const u8,
    /// Per-note hash of "which notes am I linked to", carried onto `GraphNode.link_sig` so the
    /// *next* rebuild can tell whose links moved.
    sigs: []u64,
    /// Whose own links changed since the last rebuild. The one consumer is the re-frame in
    /// `finishRebuild`: a note whose neighbourhood just changed shape is a note the camera should
    /// look at again.
    changed: []bool,

    /// Positions for a data source that packs its own (the vault simulator). Parallel to graph
    /// indices (id-sorted notes), and the only way a node gets a start position — everything else
    /// takes its place from the world on the first `syncNodesFromWorld`. Lives in `arena`.
    precomputed: ?[]const dvui.Point = null,

    /// Placement inputs, copied from the panel at spawn so the worker never reads live state.
    place_opts: containment.Options = .{},
    place_rotation: ?f32 = null,

    /// The living world, built here rather than on the UI thread.
    ///
    /// This is the largest single piece of work in a rebuild — `fold.build` coarsens every note
    /// and `cellweb` folds every link, both proportional to notes *and* edges — and it used to run
    /// inside `ensureWorld` at the top of `drawPanel`, freezing the editor for tens of seconds on
    /// a 286k-note vault.
    ///
    /// It belongs to *this* job rather than a job of its own, and that is not a convenience:
    /// `lad.cells[].note` and `Mark.note` are indices into `p.nodes`, and `finishRebuild`
    /// reallocates `p.nodes` in id order. A world built by an independent job could therefore name
    /// different notes than the panel holds — wrong labels, wrong open state, wrong hit-tests, all
    /// silent. Building it as the tail of the solve that produces those very nodes makes the two
    /// adopted together, in one frame, by construction.
    ///
    /// Owns its memory from `sdk.allocator()`, never `job.arena`: a `World` reallocates every
    /// frame (`liftLinks` hashmaps, list growth), so an arena would grow without bound for as long
    /// as the graph is on screen.
    world: ?world_mod.World = null,

    fn run(job: *LayoutJob) void {
        job.solve() catch |e| {
            job.fail = e;
        };
        job.done.store(true, .release);
    }

    fn solve(job: *LayoutJob) !void {
        // No force layout, and no multilevel coarsen.
        //
        // Both are superseded by containment. `fold` + `containment` decide every position from
        // the link hierarchy, and `syncNodesFromWorld` overwrites `target`/`home`/`pos` on every
        // note the world draws — so `layout_full.targets` was solving an arrangement that is
        // immediately thrown away.
        //
        // This was not a small tax. A CPU sample of a 283,881-note vault stuck for minutes on
        // "Preparing graph…" put 1,537 of 3,141 worker samples inside `layout_full.targets`, and
        // 1,361 of those inside `PlacedIndex.overlaps` — the whole multi-minute wait, spent
        // producing positions nothing would read.
        //
        // Building the world is therefore the whole of a solve. `finishRebuild` takes the vault's
        // extent from it too, which is where the drawn positions actually come from.
        if (job.precomputed) |pos| {
            if (pos.len != job.n) return error.SynthPosLen;
        }
        try job.buildWorld();
    }

    /// `World.init` for this job's note set. Mirrors what `ensureWorld` used to do inline.
    fn buildWorld(job: *LayoutJob) !void {
        if (job.n == 0) return;
        job.phase.store(@intFromEnum(JobPhase.building_map), .release);
        const gpa = sdk.allocator();
        const a = job.arena.allocator();

        const links = try a.alloc(fold.Edge, job.edges.len);
        for (job.edges, 0..) |e, i| links[i] = .{ .a = @intCast(e.a), .b = @intCast(e.b), .w = 1 };

        // `fold.build` only runs its folder chain when `paths.len == n_notes`, so a full-length
        // array of *empty* paths is worse than no array at all: every path compares equal, the
        // sort leaves arbitrary index order, and the chain wires unrelated notes together at
        // `folder_w`. Hand it an empty slice instead so it coarsens on real links alone.
        var any_path = false;
        for (job.paths) |path| {
            if (path.len > 0) {
                any_path = true;
                break;
            }
        }
        const path_arg: []const []const u8 = if (any_path) job.paths else &.{};

        // World scale has to match the classic layout's, because everything downstream — camera
        // fit, zoom thresholds, `interiorWant`, label placement — is calibrated in those units.
        // `slotSpacingFor` is the world distance between adjacent notes; containment puts two
        // ring-adjacent leaves `leaf_pitch × note_r` apart, so solve for `note_r`. This is the
        // same value `finishRebuild` assigns to `p.layout_slot`, deliberately computed from `n`
        // in both places rather than read across the thread boundary.
        var place = job.place_opts;
        place.note_r = layout_full.slotSpacingFor(job.n) / world_mod.leaf_pitch;
        place.rotation_per_level = job.place_rotation;

        const bodies = try a.alloc(f32, job.n);
        for (job.order, 0..) |si, gi| {
            bodies[gi] = @floatFromInt(job.snap.nodes[si].size);
        }

        const t0 = std.Io.Clock.boot.now(dvui.io).nanoseconds;
        job.world = try world_mod.World.init(
            gpa,
            job.n,
            links,
            path_arg,
            .{ .cancel = &job.cancel, .bodies = bodies },
            place,
        );
        // Kept (not a temporary diagnostic): this is how long "Building map…" is on screen, it is
        // the largest remaining cost in opening a vault, and it is the number to watch if that
        // wait ever grows. Logged from the worker, same as the indexer's own scan summary.
        dvui.log.info("atlas world: {d} notes / {d} edges coarsened and placed in {d}ms", .{
            job.n,
            links.len,
            @divTrunc(std.Io.Clock.boot.now(dvui.io).nanoseconds - t0, 1_000_000),
        });
    }

    fn deinit(job: *LayoutJob, gpa: std.mem.Allocator) void {
        if (job.thread) |t| t.join();
        // Only reached if nobody took it — an abandoned solve, or one that failed after this
        // point. `finishRebuild` clears the field when it adopts it, so reaching a non-null world
        // here means the job died before adoption; it holds the largest allocation in the plugin
        // and is not in the arena, so it must be freed explicitly.
        if (job.world) |*w| w.deinit();
        job.world = null;
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

/// How long a note takes to travel from where it was to where the new fold put it.
///
/// A re-fold re-derives the hierarchy, so a save can move notes — and an instant jump gives the
/// reader no way to connect the thing they were looking at with the thing that is now on screen.
/// Long enough to follow with your eye, short enough not to feel like waiting for the graph.
const morph_s: f32 = 0.45;

pub const Panel = struct {
    arena: std.heap.ArenaAllocator,
    /// When true, pointer input uses the dialog-canvas policy so pan/zoom works inside a
    /// floating window (Vault Simulator). The main bottom panel leaves this false so editor
    /// floating tool windows still suppress the vault canvas underneath them.
    dialog_canvas: bool = false,
    /// No markdown behind these notes — a generated vault (the simulator). Clicks must never
    /// reach the workbench: the paths are real-looking but resolve to nothing, and asking the
    /// host to open one takes the failed-load path in the document owner. Deliberately an
    /// explicit flag rather than inferring it from an empty `path`, which was the earlier guard
    /// and silently stopped holding the moment the simulator started publishing the generated
    /// folder paths its layout actually needs.
    synthetic: bool = false,
    /// Marks this panel's overview may draw in a frame — `world_mod.Params.budget`. Per panel
    /// rather than the bare `galaxy.plugin_mark_budget` constant so the simulator can expose it
    /// as a live knob (raising it resolves more notes as themselves instead of coalescing them
    /// into masses) without changing what the real bottom panel is tuned to.
    mark_budget: usize = galaxy.plugin_mark_budget,
    /// `containment.Options.rotation_per_level` for this panel's world. Null keeps the
    /// anti-banding half-step default; `containment.aperture7_rotation` nests every level on one
    /// global hex lattice. Baked into the world at build time, so `invalidateWorld` must follow
    /// a change.
    place_rotation: ?f32 = null,
    /// Placement tuning for this panel's world. `note_r` is ignored — `ensureWorld` derives it
    /// from `layout_slot` so world scale stays calibrated to the units everything downstream
    /// (camera fit, zoom thresholds, label placement) already assumes. Everything else is baked
    /// into the world at build time, so `invalidateWorld` must follow a change.
    place_opts: containment.Options = .{},
    /// Rebuild being solved on a worker, if any. See `LayoutJob`.
    job: ?*LayoutJob = null,
    gen: u64 = std.math.maxInt(u64),
    open_hash: u64 = std.math.maxInt(u64),
    nodes: []GraphNode = &.{},
    edges: []GraphEdge = &.{},
    /// id → index into `nodes` for hit/open updates without scanning.
    id_index: std.AutoHashMapUnmanaged(i64, usize) = .empty,
    note_count: u32 = 0,
    /// Markdown files on disk, from the indexer's pre-pass — the `y` in the spinner's "x of y".
    /// Zero when unknown, which falls back to a bare count.
    scan_total: u32 = 0,
    /// Which phase of indexing the spinner is reporting. See `Indexer.Phase`.
    scan_phase: Indexer.Phase = .idle,
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
    /// Index generation a coalesced rebuild is waiting on, and how long it has held still. See
    /// `rebuild_quiet_s`.
    pending_gen: u64 = std.math.maxInt(u64),
    pending_quiet_s: f32 = 0,
    /// Seconds since the last completed rebuild, so an isolated change can be told from a burst.
    /// See the coalesce in `rebuildIfNeeded`.
    since_rebuild_s: f32 = 1e9,
    /// Where notes sat *before* the current rebuild, so they can slide to their new homes rather
    /// than teleport. Note id → old world position; see `morph_s` and `applyMorph`.
    morph_from: std.AutoHashMapUnmanaged(i64, dvui.Point) = .empty,
    /// 0 → 1 across `morph_s` after a rebuild. 1 means settled and `morph_from` is empty.
    morph_t: f32 = 1,
    /// True while a rebuild is being deliberately deferred — keeps frames coming so the quiet
    /// timer can actually run out.
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
    /// Cluster marker under the cursor, when the cursor is over a merged region rather than an
    /// individual note. Mutually exclusive with `hover_node` — only one of the two is drawn at
    /// any given place on screen.
    hover_cluster: ?Visible = null,
    /// Soft-sprite atlas + same-language density mips (Galaxy LOD).
    density: ?galaxy.Density = null,

    /// Containment path (`Settings.graph_layout == .containment`): one hierarchy from links +
    /// folder adjacency, positions derived from it, budgeted select. Runs *instead of* the
    /// classic layout/agents/tiles stack, not alongside it — see `drawWorldMarks`.
    world_state: ?world_mod.World = null,
    /// `layout_epoch` the world was last built against, so it rebuilds only when the graph does.
    world_epoch: u64 = std.math.maxInt(u64),
    /// Set by `invalidateWorld`; consumed once a rebuild is actually started.
    force_rebuild: bool = false,
    /// Consecutive frames the web lift has been held while the camera moves. See `lift_hold_bias`.
    lift_held: u16 = 0,
    /// Id of the workbench document the graph last framed. See `updateActiveDoc`.
    active_doc_id: u64 = 0,
    /// Hash of the vault root this arrangement belongs to, so a folder switch is detectable.
    vault_key: u64 = 0,
    /// Smoothed LOD coarsening factor from camera speed, 1 at rest. See `updateMotionBias`.
    motion_bias: f32 = 1,
    motion_last_center: dvui.Point = .{},
    /// Smoothed |octaves/s| of zoom. Independent of pan so a flick-zoom can hold the LOD
    /// without a pan having to be in progress. See `updateMotionBias`.
    zoom_speed: f32 = 0,
    /// Last zoom-direction that exceeded the noise floor: +1 in, -1 out. Held across still
    /// frames so a just-finished zoom-in keeps holding topology while `zoom_speed` falls.
    zoom_dir: i8 = 0,
    motion_last_zoom: f32 = 0,
    /// Vault-relative note path -> graph index, rebuilt with the nodes. Lets `updateActiveDoc`
    /// and `applyOpenSet` resolve a tab without scanning every node.
    path_index: std.StringHashMapUnmanaged(u32) = .empty,
    /// The graph node whose links are highlighted, held across frames where the workbench reports
    /// no active document. See `focusNodeIndex`.
    focus_node: u32 = fold.invalid,
    /// A focus claimed by a click, outranking the workbench until it agrees. See `focusNodeIndex`.
    focus_claim: u32 = fold.invalid,
    /// Frames the claim has gone unconfirmed, so a click that never opens anything cannot pin the
    /// highlight forever.
    focus_claim_frames: u16 = 0,

    /// What the overview draws this frame: notes where they have separated enough to be told
    /// apart, cluster markers where they have not. Rebuilt every frame by `syncNodesFromWorld`,
    /// and kept on the panel rather than the frame arena so its capacity survives.
    visible: std.ArrayList(Visible) = .empty,
    /// `visible`'s interior counterpart — which content nodes are drawn as themselves this frame,
    /// rebuilt every frame by `stepInteriorWorld`. Kept on the panel, not the interior's own arena,
    /// since that arena only survives a rebuild, not a frame.
    interior_visible: std.ArrayList(Visible) = .empty,
    /// Per node, whether it is being drawn as itself this frame. Read by the edge pass, which
    /// has no business drawing a link to a note that has been merged into a marker. Lives in the
    /// panel arena, so it is sized with the arrangement.
    /// Nodes whose `label_vis` is not yet zero, per cloud.
    ///
    /// The label fade used to be a pass over every node in the vault, every frame the placer ran —
    /// which is every frame of a pan — to move at most `max_labels` non-zero values. `GraphNode` is
    /// 160 bytes, so that is the same whole-vault stride `syncNodesFromWorld` already refuses to
    /// pay. Only a placed name is ever non-zero, so tracking the handful is exact, and `drawLabels`
    /// walks the same list instead of the vault.
    /// Cells covering at least one open document this frame — the ancestor chains of the open
    /// notes' leaves, and nothing else. See `updateHoldsOpen`.
    holds_open: std.AutoHashMapUnmanaged(u32, void) = .empty,
    label_live: std.ArrayListUnmanaged(u32) = .empty,
    interior_label_live: std.ArrayListUnmanaged(u32) = .empty,
    at_level0: []bool = &.{},
    /// `layout_epoch` the `at_level0` array was last cleared wholesale for. `syncNodesFromWorld`
    /// otherwise only clears the entries it set, so a freshly (re)allocated array needs exactly one
    /// full memset before that incremental clearing is sound.
    at_level0_epoch: u64 = std.math.maxInt(u64),
    /// Graph indices of the notes currently open in the workbench, in index order — the same set
    /// `GraphNode.open` marks, kept as a list so per-frame code never has to scan the vault to find
    /// it. Maintained by `applyOpenSet`, which is the only thing that writes `open`.
    open_notes: std.ArrayListUnmanaged(u32) = .empty,
    /// How many notes `at_level0` marks. Zero means the whole view is merged, which is the case
    /// several per-node passes can skip outright.
    notes_at_level0: u32 = 0,
    /// Scratch copy of the current node positions, for handing to the hierarchy. Panel arena.
    live_pos: []dvui.Point = &.{},
    /// Overview notes with a non-zero `pointer_t`. See `chasePointer`.
    pointer_warm: std.ArrayList(u32) = .empty,

    /// Link animation state, keyed by note-id pair and outliving the arena rebuild.
    /// Entries stay after their link is gone until the retraction finishes.
    edge_anim: std.AutoHashMapUnmanaged(EdgeKey, EdgeAnim) = .empty,

    fling_x: Fling = .{},
    fling_y: Fling = .{},
    drag_active: bool = false,
    moved_since_press: bool = false,
    press_node: ?usize = null,

    interior: Interior,

    touches: [10]Touch = [_]Touch{.{}} ** 10,
    gesture_active: bool = false,
    last_centroid: dvui.Point.Physical = .{},
    last_pinch: f32 = 0,

    pub fn init(gpa: std.mem.Allocator) Panel {
        return .{
            .arena = std.heap.ArenaAllocator.init(gpa),
            .interior = .{ .arena = std.heap.ArenaAllocator.init(gpa) },
        };
    }

    pub fn deinit(self: *Panel) void {
        if (self.density) |*d| d.deinit();
        self.visible.deinit(sdk.allocator());
        self.open_notes.deinit(sdk.allocator());
        self.morph_from.deinit(sdk.allocator());
        self.interior_visible.deinit(sdk.allocator());
        self.pointer_warm.deinit(sdk.allocator());
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

/// What a panel actually put on screen this frame, against what it was asked to draw.
///
/// The gap between the two is the whole point of the LOD: `notes` is how many notes resolved as
/// *themselves*, `masses` is how many coalesced markers stood in for the rest, and
/// `notes + masses` is what the budget actually caps — never `total_notes`. A 1M-note vault
/// drawing 300-odd marks is the system working, not a bug, and this is what says so on screen.
pub const PanelStats = struct {
    /// Marks drawn as individual notes.
    notes: usize = 0,
    /// Coalesced markers, each standing in for many notes.
    masses: usize = 0,
    /// Links lifted onto the living set and drawn.
    links: usize = 0,
    /// Everything the arrangement holds, drawn or not.
    total_notes: usize = 0,
    total_edges: usize = 0,
    /// Marks the frame was allowed (`Panel.mark_budget`).
    budget: usize = 0,
    /// True when the budget refused an open this frame — i.e. raising it would show more.
    bound: bool = false,
    /// Last frame's cost, in microseconds, by phase. `world_*` and `rebuild` scale with the vault;
    /// everything else scales with what is drawn. Reading them side by side is the only way to
    /// tell "the budget is too small" apart from "the frame is spent before drawing starts".
    us_total: u64 = 0,
    us_world_step: u64 = 0,
    us_world_sync: u64 = 0,
    us_world_lift: u64 = 0,
    us_rebuild: u64 = 0,
    us_misc: u64 = 0,
    us_bubbles: u64 = 0,
    us_hover: u64 = 0,
    us_labels: u64 = 0,
    us_draw: u64 = 0,
};

/// Rebuild the world once. Needed after changing anything baked into it at construction
/// (`place_opts`, `place_rotation`), as opposed to the per-frame `Params` a step already re-reads.
///
/// This now requests a full rebuild rather than just bumping the world epoch, because the world is
/// no longer built on demand — `LayoutJob.buildWorld` produces it on the worker and `finishRebuild`
/// adopts it together with the notes it indexes. Going through the same path costs a redundant prep
/// pass (the caller is the simulator, whose positions are precomputed, so the "solve" is a memcpy),
/// and buys the guarantee that there is exactly one way a world comes into existence. A second,
/// world-only job would be cheaper and would reintroduce the thing that ordering was chosen to
/// prevent: two producers of `p.world_state`, one of which can be a rebuild behind the note array.
pub fn invalidateWorld(p: *Panel) void {
    p.force_rebuild = true;
    p.world_epoch = p.layout_epoch -% 1;
}

pub fn panelStats(p: *const Panel) PanelStats {
    var s: PanelStats = .{
        .total_notes = p.nodes.len,
        .total_edges = p.edges.len,
        .budget = p.mark_budget,
    };
    const w = if (p.world_state) |*ws| ws else return s;
    for (w.marks.items) |m| {
        if (m.is_note) s.notes += 1 else s.masses += 1;
    }
    s.links = w.links.items.len;
    s.bound = w.bound;
    return s;
}

/// `panelStats` plus last frame's timings. Separate from the loop above only because the counts
/// come from the world and these come from the profile.
pub fn panelTimings(p: *const Panel) PanelStats {
    var s = panelStats(p);
    const fp = frame_profile;
    s.us_total = fp.total() / 1000;
    s.us_world_step = fp.world_step_ns / 1000;
    s.us_world_sync = fp.world_sync_ns / 1000;
    s.us_world_lift = fp.world_lift_ns / 1000;
    s.us_rebuild = fp.rebuild_ns / 1000;
    s.us_misc = fp.misc_ns / 1000;
    s.us_bubbles = fp.bubbles_ns / 1000;
    s.us_hover = fp.hover_ns / 1000;
    s.us_labels = fp.labels_ns / 1000;
    s.us_draw = (fp.draw_edges_ns + fp.draw_nodes_ns + fp.draw_clusters_ns + fp.draw_labels_ns) / 1000;
    return s;
}

/// Join any layout worker still running and drop the living world. Must happen before a `Panel`
/// (or the plugin library backing its worker's code) goes away — `LayoutJob` isn't exported, so
/// this is the only place outside this file that can reach into one to join it; any other owner
/// of a `Panel` (the vault simulator window) calls this too rather than reimplementing it.
pub fn shutdownPanel(p: *Panel) void {
    if (p.job) |job| {
        // Ask first, then join. `deinit` joins unconditionally, and the world build inside the
        // solve is tens of seconds on a large vault — without this, quitting mid-build waits it
        // out with a frozen window.
        job.cancel.store(true, .release);
        job.deinit(sdk.allocator());
        p.job = null;
    }
    p.path_index.deinit(sdk.allocator());
    p.holds_open.deinit(sdk.allocator());
    p.label_live.deinit(sdk.allocator());
    p.interior_label_live.deinit(sdk.allocator());
    if (p.world_state) |*w| {
        w.deinit();
        p.world_state = null;
    }
}

/// Join any layout worker still running. Must be called before the plugin's library can be
/// unloaded: the worker is executing code that lives in this dylib, and a solve on a large vault
/// outlasts a plugin teardown comfortably.
pub fn shutdown() void {
    shutdownPanel(&(panel orelse return));
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
    /// `stepWorld`, split three ways. All three scale with the *vault*, not with the mark budget,
    /// which is what makes them the ceiling on how much can be on screen at once.
    world_step_ns: u64 = 0,
    world_sync_ns: u64 = 0,
    world_lift_ns: u64 = 0,
    /// Everything else between the rebuild and `updateBubbles`: interior, camera, fling, framing.
    misc_ns: u64 = 0,
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

    fn total(self: FrameProfile) u64 {
        return self.rebuild_ns + self.world_step_ns + self.world_sync_ns + self.world_lift_ns +
            self.misc_ns + self.bubbles_ns + self.hover_ns + self.labels_ns +
            self.edge_anim_ns + self.draw_edges_ns + self.draw_nodes_ns +
            self.draw_clusters_ns + self.draw_labels_ns;
    }
};
var frame_profile: FrameProfile = .{};

pub fn draw(_: ?*anyopaque) anyerror!void {
    drawn_recently = true;
    const p = ensurePanel(sdk.allocator());
    // Here rather than in `drawPanel`: that is shared with the vault simulator, which owns its own
    // budget slider and must not have it overwritten from the app's settings every frame.
    p.mark_budget = std.math.clamp(runtime.state().settings.graph_detail.get(), 50, 4000);
    try drawPanel(p, runtime.state());
}

/// The whole panel, one frame: rebuild-if-needed, step the living world, update hover/proximity/
/// labels, draw, handle input. Generic over `st` (duck-typed — `rebuildIfNeeded`/
/// `buildInteriorWorld` read `db`/`generation`/`indexer`/`indexer_ready`/`vault_root`/
/// `hasGraphSource()` off it) so a caller with its own data source and its own `Panel` — the
/// vault simulator window — draws through the exact same pass `draw` above uses for the real
/// bottom panel, rather than a second copy that can drift from it.
pub fn drawPanel(p: *Panel, st: anytype) !void {
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
        drawCenteredHint("Open a folder to see the note graph.");
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
    if ((p.job != null or p.rebuild_waiting) and p.nodes.len == 0) {
        const building_map = if (p.job) |j|
            j.phase.load(.acquire) == @intFromEnum(JobPhase.building_map)
        else
            false;
        if (building_map) {
            drawBuildingMapSpinner(p.note_count);
        } else {
            drawLayoutSpinner(p.note_count, p.scan_total, p.scan_phase);
        }
        return;
    }

    // Before anything reads or clamps zoom: how far out this vault may be pulled depends on how
    // big it is, and it just changed if a rebuild landed above.
    // Against the world that is actually drawn, not `world_radius` — that comes from the classic
    // `layout_full` targets, which for a synthetic vault are in the generator's own coordinate
    // space, and which know nothing about `place_opts.radius_exp` inflating the containment
    // extent. Calibrating the zoom floor on it left large vaults unable to zoom out far enough
    // to see themselves.
    const content_r = if (ensureWorld(p)) |w| w.extent() else p.world_radius;
    p.camera.setContentExtent(content_r, zoom_out_slack);

    frame_profile.misc_ns += profLap(&prof);
    updateActiveDoc(p, st);
    updateInterior(p, st);
    maybeFitCamera(p);

    // Pinch before fling/wheel so a trackpad pinch isn't also interpreted as scroll-pan.
    applyTrackpadPinch(p, vp);
    stepFling(p);
    animateCamera(p);
    // After the camera has moved for this frame and before the world reads it.
    updateMotionBias(p);
    // Publishes `p.visible` — this frame's individually-resolved notes — via
    // `syncNodesFromWorld`. Everything below reads it: updateBubbles, updateHover and the label
    // placer all work over that selection rather than over the whole vault, which is what keeps
    // their cost a property of the mark budget instead of the note count.
    stepWorld(p, &prof);
    stepInteriorWorld(p);
    applyInteriorFramingIfNeeded(p);
    frame_profile.misc_ns += profLap(&prof);
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
    // Only the *overview* can be at cluster zoom. `notes_at_level0` counts leaves resolved by the
    // vault's LOD, which says nothing about a note's interior — that view has its own nodes and
    // draws every one of them. Without the `interior.t` term this gate zeroed every interior
    // label before the interior branch below could place any, so names vanished inside a note
    // whenever the vault behind it happened to be fully coalesced.
    const at_cluster_zoom = p.notes_at_level0 == 0 and p.nodes.len > 0 and p.interior.t < 0.5;
    // A flick-zoom cannot be read at label resolution, and the placer is one of the heaviest
    // per-frame costs there is. Skip it; open/hover names still draw from the notes themselves.
    // A click-to-focus chase is not a flick: skip only while the camera is still flying, then
    // place immediately rather than waiting for `zoom_speed` to decay.
    const motion_busy = p.camera.chasing() or
        (p.camera.user_driving and p.zoom_speed > zoom_hold_oct_ps * 0.45) or
        p.motion_bias > 1.08;
    const labels_dirty = !at_cluster_zoom and !motion_busy and
        (p.labels_stale or !p.labels_settled or !p.proximity_settled or
            !p.pointer_settled or !p.layout_settled or p.camera.chasing() or labelViewMoved(p));
    if (at_cluster_zoom or motion_busy) {
        // Do not walk every note — at 100k+ that alone tanks the frame. Labels are not drawn…
        // except the open document's, which is named below regardless of what the LOD resolved.
        if (motion_busy) {
            for (p.label_live.items) |i| {
                if (i < p.nodes.len and !p.nodes[i].open) p.nodes[i].label_vis = 0;
            }
        }
        for (p.interior.nodes) |*n| n.label_vis = 0;
        // The arrangement is unchanged but no placement was computed for it, so the next frame
        // that does draw names has to redo them.
        p.labels_stale = true;
    } else if (p.interior.t < 0.5) {
        if (labels_dirty) updateLabels(p, p.nodes, p.edges, p.layout_slot, p.visible.items, &p.label_live, 1);
        for (p.interior.nodes) |*n| n.label_vis = 0;
    } else {
        if (labels_dirty) updateLabels(p, p.interior.nodes, p.interior.edges, p.interior.slot, p.interior_visible.items, &p.interior_label_live, 0);
        // Only the overview notes that *have* a name placed, which is the set `visible` names — the
        // whole-vault version of this line is the same 160-byte-stride sweep that cost 3.7 ms a
        // frame at a million notes, and `at_cluster_zoom` above already refuses to pay it.
        for (p.visible.items) |v| {
            if (v.level == 0 and v.index < p.nodes.len) p.nodes[v.index].label_vis = 0;
        }
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
        // How far the overview actually gives way, which is not the same as how far in the camera
        // is.
        //
        // `interior.t` is a pure function of zoom — it rises whether or not there is a cloud to
        // arrive. So a descent toward a note whose interior was never built faded the overview out
        // against nothing: the note went translucent, then invisible, while its links carried on
        // being drawn from `field.pos`, and the reader was left zooming at an empty patch with no
        // way to reach the interior that was supposed to be there. Yielding only when something is
        // arriving makes the fade a handover rather than a countdown.
        //
        // And it holds at full strength through the first part of the descent. The node is the
        // thing being zoomed *into*, so it has to stay solid while it grows — fading it from the
        // moment the camera starts moving reads as the note dissolving and a different screen
        // appearing behind it, which is the cut this crossfade exists to avoid.
        const yield_t: f32 = if (p.interior.nodes.len > 0)
            std.math.clamp((t - overview_hold_t) / (1 - overview_hold_t), 0, 1)
        else
            0;
        // Notes where they have separated enough to be told apart, coalesced masses where they
        // have not — decided per cell, and cross-faded, by the world's own open set. That is what
        // turns "draw every note in the vault" into "draw at most `mark_budget` marks".
        _ = profLap(&prof);
        // One hierarchy, positions derived from it. Owns the whole overview.
        drawWorldMarks(p, 1 - yield_t);
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
    // Before `handleInput` so the button consumes its own press rather than the graph
    // treating it as the start of a pan.
    drawFitButton(p, content);
    handleInput(p, st);
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
    } else if (coalesced_only or p.camera.chasing() or
        (p.camera.user_driving and p.zoom_speed > zoom_hold_oct_ps))
    {
        // Merged, flying to a click, or a flick is in progress: the shove is O(visible²) and
        // unread at that speed. After a click-flight parks, do not keep skipping just because
        // `zoom_speed` is still decaying — that is the "camera settles, then everything jumps"
        // hitch.
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
    const falloff_px = proximity_falloff_px * dpiScale() *
        std.math.lerp(1.0, proximity_falloff_zoom_boost, zoom_t);
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
    // The overview draws its marks from the world's own positions (`Mark.wx/wy`), not from
    // `n.pos` — so a shove applied here is never drawn there. It still moved `n.pos`, which is what
    // hit-testing and the label placer read, so near the cursor the ring you can see and the target
    // you can click drifted apart: the node lights up, the cursor does not become a hand, and the
    // click lands on nothing. Worse at some zooms than others, because the reach is a world-space
    // distance derived from a screen-space radius.
    //
    // Drawing the shove instead would be the other repair, and it is the wrong one: link endpoints
    // come from the same world positions the marks do, so shoved nodes would pull away from their
    // own lines.
    const drawn_from_world = nodes.ptr == p.nodes.ptr;
    if (any_shove and strength > 0.001 and !drawn_from_world) {
        const gap_w = neighbor_gap_px * dpiScale() / zoom;
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
    // `falloff_w` (the hover reach, a fixed *screen* distance) covers a shrinking share of the
    // field as zoom increases, so fewer sources are simultaneously swollen at once at high zoom —
    // but at low zoom_t, a dense field (hundreds of interior content items, all close together in
    // vault-world terms) can have many swollen sources shoving the same neighbour at once, and
    // each pair's shove stacks additively with no normalization between them. Tapering the push
    // itself by zoom_t keeps that far-zoom compounding gentle without touching the near-zoom feel
    // it was tuned for, floored so it never fully disables the effect.
    const push_scale = std.math.clamp(zoom_t, 0.2, 1.0);
    const amt = (need - d) * neighbor_push * src_shove * push_scale;
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
    const s = dpiScale();
    const lo = detail_gap_lo * s;
    const hi = detail_gap_hi * s;
    const t = std.math.clamp((gap - lo) / (hi - lo), 0, 1);
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
        pointerTargetsPanel(p, mouse);
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

/// Re-seed a cloud's label live set after its node array is rebuilt.
///
/// The counterpart to `rewarmPointer`, and for the same reason: a rebuild reallocates and renumbers
/// the nodes, and `finishRebuild` carries `label_vis` across by note id, so the old indices name the
/// wrong nodes. One pass over the new array here, rather than one per frame.
fn rewarmLabels(nodes: []const GraphNode, live: *std.ArrayListUnmanaged(u32)) void {
    live.clearRetainingCapacity();
    for (nodes, 0..) |n, i| {
        if (n.label_vis > 0.004) live.append(sdk.allocator(), @intCast(i)) catch {};
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
/// Recorded on whatever rebuild happens to run; a pane resize on its own no longer starts one
/// (see `rebuildIfNeeded`), so this never re-packs a graph out from under the reader.
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
fn rebuildIfNeeded(p: *Panel, st: anytype) !void {
    // A different vault is a different graph, not a newer version of this one.
    //
    // Nothing tracked the vault's identity here, so switching folders left the previous vault's
    // nodes in place: the panel went on drawing that graph as if it belonged to the folder just
    // opened, and — because the spinner is gated on having no nodes — showed no sign that anything
    // was loading. Dropping the arrangement makes the switch honest and puts the progress spinner
    // back.
    const vault_key: u64 = if (st.vault_root) |root| std.hash.Wyhash.hash(0, root) else 0;
    if (p.vault_key != vault_key) {
        p.vault_key = vault_key;
        // Drop any solve still in flight. It carries the *previous* vault's snapshot, and
        // `finishRebuild` would happily adopt it — repopulating the panel with the old vault's
        // graph after the switch, which is why the old one appeared to stay live and then swap.
        if (p.job) |job| {
            job.cancel.store(true, .release);
            job.deinit(sdk.allocator());
            p.job = null;
        }
        p.nodes = &.{};
        p.edges = &.{};
        p.visible.clearRetainingCapacity();
        p.open_notes.clearRetainingCapacity();
        p.path_index.clearRetainingCapacity();
        p.id_index.clearRetainingCapacity();
        p.active_doc_id = 0;
        p.notes_at_level0 = 0;
        p.at_level0 = &.{};
        if (p.world_state) |*w| {
            w.deinit();
            p.world_state = null;
        }
        p.world_epoch = p.layout_epoch -% 1;
        p.framing = .extents;
        p.open_hash = std.math.maxInt(u64);
    }

    const gen = st.generation.load(.acquire);
    const open_hash = if (st.vault_root) |root| hashOpenNotes(root) else 0;
    const desired = layoutAspect(p.camera.viewport, p.layout_aspect, &p.aspect_smooth);

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
        p.rebuild_waiting = false;
        return;
    }

    var need_rebuild = p.gen != gen or p.nodes.len == 0 or p.force_rebuild;

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
    p.since_rebuild_s += @min(dvui.secondsSinceLastFrame(), 1.0 / 30.0);
    if (need_rebuild and p.nodes.len > layout_inline_max) {
        if (gen != p.pending_gen) {
            p.pending_gen = gen;
            p.pending_quiet_s = 0;
        } else {
            p.pending_quiet_s += @min(dvui.secondsSinceLastFrame(), 1.0 / 30.0);
        }
        // Leading edge, not trailing.
        //
        // Waiting for the index to hold still is right for a *burst* and wrong for a single
        // change: a save publishes exactly one generation, so a trailing window spends its whole
        // length doing nothing and then rebuilds — 0.6 s of latency to coalesce a burst of one. On
        // a vault small enough that the rebuild is tens of milliseconds, that delay *is* the
        // response time the reader feels.
        //
        // An index that has been quiet for longer than the window is not in a burst, so the change
        // that just arrived is an isolated one and rebuilds on the spot. Anything arriving in the
        // wake of a rebuild still coalesces exactly as before, which is the case the window was
        // written for — a vault read, or a `git checkout` touching a hundred files.
        const in_burst = p.since_rebuild_s < rebuild_quiet_s;
        if (in_burst and p.pending_quiet_s < rebuild_quiet_s) {
            need_rebuild = false;
            p.rebuild_waiting = true;
        }
    }

    // Never build a graph from a mid-scan snapshot.
    //
    // `relinkAll` runs once, at the end of the walk — it cannot run earlier, because resolving
    // `[[Paris]]` means knowing whether `Paris.md` exists anywhere in the vault. So a partial
    // publish carries notes whose links have no destination, and a graph built from one has no
    // edges at all. Drawing it is worse than drawing nothing: it looks like a finished vault of
    // isolated notes rather than an unfinished read, and there is no way to tell from the picture.
    //
    // The cost is the other half. A 284k-note scan publishes every 200 files or 250 ms, and each
    // publish used to re-run `fold.build` + containment + the cell web over everything scanned so
    // far — several rebuilds a second, every one of them thrown away, competing with the scan that
    // produced them. That feedback loop is why a large vault appeared never to finish loading.
    //
    // `note_count` still tracks the partial snapshot, so the spinner counts up while this waits.
    if (need_rebuild and st.indexer_ready) {
        const c = st.indexer.counts();
        if (!c.complete) {
            p.note_count = c.note_count;
            p.scan_total = c.scan_total;
            p.scan_phase = c.phase;
            p.rebuild_waiting = true;
            return;
        }
    }

    if (!need_rebuild) {
        if (p.open_hash != open_hash) {
            // The vault can be closed while a solve is in flight; the job's data is its own copy and is
            // still fine to apply, but there is no folder left to ask which notes are open.
            if (st.vault_root) |root| applyOpenSet(p, root, open_hash);
        }
        return;
    }

    // Whatever prompted this rebuild, record the pane we have now.
    const aspect = desired;
    p.layout_aspect = aspect;

    // A reshape deliberately does *not* touch the camera.
    //
    // It used to force `.extents` and clear `user_driving`, on the reasoning that the cloud is
    // about to be re-laid out to suit the new proportions, so a pan made against the old
    // arrangement is not worth preserving. That reasoning applied to `layout_full`, where
    // `Opts.aspect` really did stretch the ring the islands were packed onto. Containment does not
    // read the pane's proportions at all: `place_opts.pack_aspect` is a fixed 1.0 that only the
    // vault simulator's slider ever changes, so a reshape re-solves to the *same arrangement*.
    //
    // Nothing moves out from under the camera, so throwing the reader's place away is pure loss —
    // and dragging the splitter is exactly when someone is arranging their workspace around
    // something they are looking at.

    // A first build is a population, not a burst of "connect" events — snap links to full
    // length so opening the panel doesn't play the whole vault wiring itself up.
    const first_build = p.gen == std.math.maxInt(u64);

    // Carry animated fields across for surviving ids. Rebuilt again at apply time —
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
        .aspect = aspect,
        .prior_slot = if (p.layout_slot > 1) p.layout_slot else null,
        .snap = .{},
        .order = &.{},
        .n = 0,
        .edges = &.{},
        .layout_edges = &.{},
        .degrees = &.{},
        .paths = &.{},
        .sigs = &.{},
        .changed = &.{},
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
        p.visible.clearRetainingCapacity();
        p.open_notes.clearRetainingCapacity();
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

    // Degree from the edge list that was just deduped, not from the database.
    //
    // `loadSnapNodes` used to compute it in SQL, per note, which on a 283,878-note vault with 3.3M
    // links was the single most expensive part of publishing a snapshot. Every form of that query
    // is redundant: `edge_list` above has already collapsed each pair on its unordered `(min,max)`
    // key, so counting entries here *is* "distinct neighbours (in ∪ out)" — the exact definition
    // the SQL was reaching for — for the cost of one pass over an array already in cache.
    var degrees = try arena.alloc(u32, n);
    @memset(degrees, 0);
    for (edge_list.items) |e| {
        degrees[e.a] += 1;
        degrees[e.b] += 1;
    }
    const sigs = try linkSignatures(arena, n, order.items, snap.nodes, edge_list.items);

    // Whose own links moved since the last rebuild.
    //
    // This used to be one output of a much larger pass that also produced `seeds`, `anchored` and
    // a one-step position history per node — the incremental-anchoring inputs to the force solve:
    // hold a node whose links didn't move, free the one-hop neighbours of one that did, and put a
    // node back in its old cell when an edit undid the previous one. All of it computed a starting
    // arrangement for `layout_full.targets`, which no longer runs (see `LayoutJob.solve`), so all
    // of it was being computed and discarded — including three n-sized arrays per rebuild.
    //
    // Containment derives every position from the link hierarchy instead, which is stable across
    // an edit by construction: a note whose links didn't change lands in the same cell without
    // being told to. So the only question left is the one thing that outlived the solver — which
    // notes the reader should be re-framed onto, in `finishRebuild`.
    const changed = try arena.alloc(bool, n);
    for (order.items, 0..) |si, gi| {
        const prev = carry.get(snap.nodes[si].id) orelse {
            changed[gi] = true;
            continue;
        };
        changed[gi] = prev.link_sig != sigs[gi];
    }

    const paths = try arena.alloc([][]const u8, 1);
    paths[0] = try arena.alloc([]const u8, n);
    for (order.items, 0..) |si, gi| paths[0][gi] = snap.nodes[si].path;

    job.n = n;
    job.order = try order.toOwnedSlice(arena);
    job.edges = try edge_list.toOwnedSlice(arena);
    job.layout_edges = layout_edges;
    job.degrees = degrees;
    job.paths = paths[0];
    job.sigs = sigs;
    job.changed = changed;
    job.place_opts = p.place_opts;
    job.place_rotation = p.place_rotation;

    // A data source that already knows where every note goes (the vault simulator, whose
    // generator packs positions itself) hands them over here and the force layout is skipped
    // entirely. Duck-typed on the method rather than a field, so the live `State` — which has no
    // such method — compiles this branch out and is completely unaffected.
    //
    // This is load-bearing at scale, not an optimization: `layout_full` on a few hundred thousand
    // notes takes minutes, and while it runs `p.job` never completes, `rebuildIfNeeded` returns
    // early every frame, and the panel goes on redrawing whatever arrangement last *finished* —
    // which reads exactly like "changing the note count does nothing."
    const StateT = @typeInfo(@TypeOf(st)).pointer.child;
    if (@hasDecl(StateT, "packedPositions")) {
        if (st.packedPositions()) |pos| {
            // Positions are keyed by note id `1..N`, which is graph index `0..N-1` after the
            // id-sort above — so a length match is the whole validity check.
            if (pos.len == n) job.precomputed = try arena.dupe(dvui.Point, pos);
        }
    }

    // Small vaults solve here and now: a worker would cost a frame of latency for work that is
    // already too fast to see. Everything bigger goes to a thread, and the panel draws a spinner
    // over whatever it had (see `draw`) instead of locking the editor for the duration.
    // Synth precomputed jobs always use the worker above a few thousand — quadtree build is the cost.
    // Consumed here, where a rebuild is actually committed to — not at the test, which runs on
    // frames that then bail out on the quiet-coalesce timer or an incomplete index.
    p.force_rebuild = false;

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
    const first_build = job.first_build;

    // Same carry the prep pass took — `p.nodes` has not moved since, because the panel's arena
    // is only recycled on the line below.
    var carry = std.AutoHashMap(i64, GraphNode).init(gpa);
    defer carry.deinit();
    for (p.nodes) |node| carry.put(node.note_id, node) catch {};

    // Adopt the solved world in the same frame as the nodes it indexes. Deinit the old one
    // *first*: at Wikipedia scale two live worlds are a multi-hundred-megabyte spike, and there is
    // nothing to draw between these two statements.
    // Where the note the reader is with sat *before* this rebuild, in world space.
    //
    // A re-fold re-derives the hierarchy from the link graph, so every note in the vault can land
    // somewhere new — including the one being read. The camera is not re-derived when the reader
    // panned by hand (`.free`), which is right for a resize and wrong for this: nothing moved under
    // them then, and everything moves under them now. Captured here because the old world is freed
    // two lines down, and it is the only thing that still knows where anything used to be.
    const anchor_id = anchorNoteId(p);
    const anchor_before: ?dvui.Point = blk: {
        const id = anchor_id orelse break :blk null;
        const w = if (p.world_state) |*ws| ws else break :blk null;
        const idx = p.id_index.get(id) orelse break :blk null;
        // `World.noteWorldPos` already walks the ancestor chain placing what it needs — a leaf in
        // a branch the camera never opened has no position until asked, and the anchored note is
        // very often exactly that.
        const wp = w.noteWorldPos(@intCast(idx)) orelse break :blk null;
        break :blk dvui.Point{ .x = wp.x, .y = wp.y };
    };

    // Where every *drawn* note sits right now, so the new arrangement can be travelled to rather
    // than jumped to. Keyed on note id, because indices shift on every rebuild.
    //
    // Only the marks, never the vault: a note nobody could see has no old position worth
    // preserving — it was not on screen to move *from* — and this way the table is bounded by the
    // mark budget rather than by N. `m.note` indexes the outgoing `p.nodes`, which is still the
    // live array here.
    p.morph_from.clearRetainingCapacity();
    if (!first_build) {
        if (p.world_state) |*old_world| {
            for (old_world.marks.items) |m| {
                if (!m.is_note or m.note >= p.nodes.len) continue;
                p.morph_from.put(gpa, p.nodes[m.note].note_id, .{ .x = m.wx, .y = m.wy }) catch {};
            }
        }
    }

    const adopted_world = job.world != null;
    if (job.world) |w| {
        if (p.world_state) |*old_world| old_world.deinit();
        p.world_state = w;
        job.world = null; // adopted — `LayoutJob.deinit` must not free it too
    }

    _ = p.arena.reset(.free_all);
    p.id_index.clearRetainingCapacity();
    p.path_index.clearRetainingCapacity();
    p.active_doc_id = 0; // ids index the old node array; force a re-resolve against the new one
    const arena = p.arena.allocator();
    p.gen = job.gen;
    p.since_rebuild_s = 0;
    // A first build has nowhere to travel from, and an empty table makes `applyMorph` a no-op
    // anyway — but skipping the clock keeps it from spending `morph_s` frames doing nothing.
    p.morph_t = if (p.morph_from.count() == 0) 1 else 0;
    // Every completed solve, whatever prompted it. `gen` tracks the *index*, and a reshape moves
    // every note in the vault without the index having changed at all — so anything cached
    // against positions has to watch this instead. See `Panel.atlas`.
    p.layout_epoch +%= 1;
    // After the bump, not before: `world_epoch == layout_epoch` is the panel's "the world matches
    // the nodes" test, and stamping it against the previous epoch would make `ensureWorld` rebuild
    // the thing that was just handed to it.
    if (adopted_world) {
        p.world_epoch = p.layout_epoch;
        // Force `maybeFitCamera` to fit again now that there is a real extent to fit to — but only
        // on a first build.
        //
        // The vault extent comes from the world, so any fit that happened before the *first* world
        // arrived used an extent of zero, and sat wrong until something incidental woke the panel
        // and re-framed it: the "opens small, then pops" on first load. That is a genuine one-time
        // problem and this is the fix for it.
        //
        // Doing it on every adoption is not the same thing, and it was the single worst camera bug
        // in the panel. Zeroing `fitted_vp_*` sends `maybeFitCamera` down its `never` branch, which
        // calls `fitToNodes` directly — an *un-animated snap to whole-vault extents that ignores
        // `framing` altogether*. So every reindex, and every splitter drag that tripped a reshape,
        // threw the reader back to the whole map no matter what they were looking at or how
        // carefully the framing rules above had preserved it.
        if (first_build) {
            p.fitted_vp_w = 0;
            p.fitted_vp_h = 0;
        }
    }
    p.layout_aspect = job.aspect;
    p.note_count = snap.note_count;

    const sigs = job.sigs;
    const changed = job.changed;
    const order = job.order;
    const open_hash = job.open_hash;

    p.layout_slot = layout_full.slotSpacingFor(n);
    p.at_level0 = arena.alloc(bool, n) catch &.{};
    p.notes_at_level0 = 0;
    // Union-find over all edges is a multi-second apply hitch at 400k — skip for synth / huge N.
    p.island_count = if (job.precomputed != null or n > 50_000) 0 else countIslands(n, job.layout_edges);

    // Extent of the web, from the world rather than from any solved position array: the world is
    // where the drawn positions come from, and its extent is what the camera frames and what the
    // LOD culls against.
    if (p.world_state) |*w| {
        const r = w.extent();
        p.world_radius = r;
        p.world_bounds = .{ .x = -r, .y = -r, .w = r * 2, .h = r * 2 };
    } else {
        p.world_radius = 0;
        p.world_bounds = .{};
    }

    var nodes = try arena.alloc(GraphNode, n);
    var any_layout_move = false;
    for (order, 0..) |si, gi| {
        const info = snap.nodes[si];
        // Always carry the path and title, at any vault size.
        //
        // These used to be dropped above 50,000 notes, on the reasoning that "Galaxy overview
        // never labels all notes" — true of the pyramid renderer this replaced, and false of
        // containment, which resolves individual notes at *any* vault size. That is the whole
        // point of the LOD. Left in place, the cutoff silently stripped every node's identity on
        // a large vault: no title meant `drawLabel` bailed before drawing a name, and no path
        // meant a click had no file to open and `applyOpenSet` had nothing to match an open tab
        // against. One line, and the graph looked like three unrelated bugs.
        //
        // The cost it was avoiding is real but small next to what a rebuild already allocates:
        // ~60 bytes of strings per note against 160 bytes of `GraphNode` plus the edge list. A
        // vault large enough for that to matter needs the per-note `GraphNode` gone entirely,
        // which is a different change from throwing away the text.
        const path = try arena.dupe(u8, info.path);
        const title = try arena.dupe(u8, info.title);
        // Where the node starts before the world names its real position on the first
        // `syncNodesFromWorld`. Only a data source that packs its own positions has an opinion;
        // everything else starts at the origin for the one frame in between.
        const start = if (job.precomputed) |pos| pos[gi] else dvui.Point{};
        var gn: GraphNode = .{
            .note_id = info.id,
            .path = path,
            .title = title,
            .phantom = info.phantom,
            .degree = job.degrees[gi],
            .link_sig = sigs[gi],
            .target = start,
            .home = start,
            .pos = start,
            .target_radius = radiusFor(job.degrees[gi], false, info.phantom),
            .radius = radiusFor(job.degrees[gi], false, info.phantom),
            .alpha = if (info.phantom) 0.55 else 1,
        };
        if (path.len > 0) p.path_index.put(gpa, path, @intCast(gi)) catch {};
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
    rewarmLabels(nodes, &p.label_live);
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

    // Follow the note the reader is with, when nothing else is going to.
    //
    // `applyFraming` re-derives the pose for `.extents`, `.note` and `.interior`, so those already
    // track. `.free` deliberately re-derives nothing — a hand pan is a place someone chose to be,
    // and yanking it back on every reindex is what made the old "refit on reindex" behaviour
    // hostile. But that reasoning assumes the world stayed still, and a re-fold moves every note in
    // it. Left alone, the note being read slides out of view and the reader has to find it again.
    //
    // So the pan is preserved *relative to the note* rather than to the world: shift the camera by
    // exactly how far the note moved, and the note ends up back under the same pixel it occupied,
    // with everything else rearranged around it. Through `retarget`, not a snap, so it reads as
    // following rather than as the view jumping — and `retarget`'s own epsilon check means a
    // rebuild that did not move the note costs nothing at all.
    if (!first_build and p.framing == .free) {
        if (anchor_before) |before| anchor: {
            const id = anchor_id orelse break :anchor;
            const w = if (p.world_state) |*ws| ws else break :anchor;
            const idx = p.id_index.get(id) orelse break :anchor;
            const after = w.noteWorldPos(@intCast(idx)) orelse break :anchor;
            p.camera.retarget(.{
                .center = .{
                    .x = p.camera.center_target.x + (after.x - before.x),
                    .y = p.camera.center_target.y + (after.y - before.y),
                },
                .zoom = p.camera.zoom_target,
            });
        }
    }

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
    if (!first_build and p.framing != .interior) {
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
/// Otherwise the cursor names the note. Zooming is meant to be literal, so the disc under the
/// pointer (the same one hover already lights) is the one that opens. A keep-band around the
/// previous note's *layout home* used to outrank a closer neighbour, and a walk of every home
/// (including notes still inside a mass) disagreed with what was on screen — aiming at one node
/// and getting another's interior.
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
            return nodeAtAim(p) orelse p.interior.note_id;
        },
    }
}

/// Screen point a hand-driven descent is aimed at: the cursor when it is over the panel,
/// otherwise the middle of the view.
///
/// The cursor, because that is what the zoom itself is anchored to — `zoomAtScreen` pushes in
/// around the pointer, so the node the reader is pointing at is the node that stays put on
/// screen while everything else slides outward.
fn aimScreen(p: *const Panel) dvui.Point.Physical {
    const mouse = dvui.currentWindow().mouse_pt;
    if (p.camera.viewport.contains(mouse)) return mouse;
    const vp = p.camera.viewport;
    return .{ .x = vp.x + vp.w * 0.5, .y = vp.y + vp.h * 0.5 };
}

fn aimEligible(p: *const Panel, n: GraphNode) bool {
    if (n.phantom) return false;
    if (p.interior.fail_id) |f| {
        if (f == n.note_id) return false;
    }
    return true;
}

/// Closest real note under a coalesced mass, using the mass's own leaf positions.
fn closestLeafInCell(p: *const Panel, cell: u32, screen: dvui.Point.Physical) ?i64 {
    const w = if (p.world_state) |*ws| ws else return null;
    if (cell >= w.lad.cells.len) return null;
    const c = w.lad.cells[cell];
    if (c.le <= c.ls or c.le > w.lad.note_at.len) return null;
    var best: ?i64 = null;
    var best_d2: f32 = std.math.floatMax(f32);
    for (w.lad.note_at[c.ls..c.le]) |gi| {
        if (gi >= p.nodes.len) continue;
        const n = p.nodes[gi];
        if (!aimEligible(p, n)) continue;
        const world = if (gi < w.lad.leaf_cell.len) blk: {
            const leaf = w.lad.leaf_cell[gi];
            if (leaf < w.field.pos.len) {
                const fp = w.field.pos[leaf];
                break :blk dvui.Point{ .x = fp.x, .y = fp.y };
            }
            break :blk n.pos;
        } else n.pos;
        const s = p.camera.worldToScreen(world);
        const dx = s.x - screen.x;
        const dy = s.y - screen.y;
        const d2 = dx * dx + dy * dy;
        if (d2 < best_d2) {
            best_d2 = d2;
            best = n.note_id;
        }
    }
    return best;
}

/// The overview node a hand-driven descent opens: the one closest to the mouse on screen.
///
/// Prefers the disc hover already named, then a mass's nearest leaf, then the closest drawn
/// note — always the nearest of what is actually visible, never a keep-band around a previous
/// choice or a walk of every layout home.
fn nodeAtAim(p: *const Panel) ?i64 {
    // Hover is last frame's, which is what the reader was pointing at when this frame's zoom
    // arrived. It indexes the overview only while descent has not taken over the pointer.
    if (p.interior.t < 0.5) {
        if (p.hover_node) |i| {
            if (i < p.nodes.len and aimEligible(p, p.nodes[i])) return p.nodes[i].note_id;
        }
        if (p.hover_cluster) |hc| {
            if (closestLeafInCell(p, hc.index, aimScreen(p))) |id| return id;
        }
    }

    const screen = aimScreen(p);
    if (p.visible.items.len > 0) {
        // Only notes drawn as themselves this frame — a coalesced neighbour's home is not a
        // position the reader can aim at.
        var best: ?i64 = null;
        var best_d2: f32 = std.math.floatMax(f32);
        for (p.visible.items) |v| {
            if (v.level != 0 or v.index >= p.nodes.len) continue;
            const n = p.nodes[v.index];
            if (!aimEligible(p, n)) continue;
            const s = p.camera.worldToScreen(n.pos);
            const dx = s.x - screen.x;
            const dy = s.y - screen.y;
            const d2 = dx * dx + dy * dy;
            if (d2 < best_d2) {
                best_d2 = d2;
                best = n.note_id;
            }
        }
        if (best) |id| return id;
    }

    // Nothing resolved as a note yet — still masses. Closest leaf of the tightest mass under
    // the cursor, else of every living mass.
    if (p.world_state) |*w| {
        if (hitTestClusters(p, screen)) |hit| {
            if (closestLeafInCell(p, hit.index, screen)) |id| return id;
        }
        var best: ?i64 = null;
        var best_d2: f32 = std.math.floatMax(f32);
        for (w.marks.items) |m| {
            if (m.is_note or m.alpha < 0.15) continue;
            const c = p.camera.worldToScreen(.{ .x = m.wx, .y = m.wy });
            const dx = screen.x - c.x;
            const dy = screen.y - c.y;
            const d2 = dx * dx + dy * dy;
            if (d2 < best_d2) {
                best_d2 = d2;
                best = closestLeafInCell(p, m.cell, screen);
            }
        }
        if (best) |id| return id;
    }
    return null;
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
/// Radial jitter within a depth band, as a fraction of `interior_ring_gap` — an asteroid belt
/// scattered roughly at one radius, not every item pinned to exactly one fine circle.
const interior_ring_band: f32 = 0.85;

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
/// Longest label worth trying to place for a non-heading content item — long enough to be
/// recognizable, short enough that `updateLabels`' placer doesn't have to fight a whole paragraph
/// for room. A heading's own `text` is already short (it's the heading itself); everything else
/// — a paragraph, a list, a code block — has `text` set to its raw body, which could run to
/// hundreds of characters and needs cutting down before it's usable as a label at all, the same
/// way `.md` link text gets truncated elsewhere in this file.
const interior_content_label_max: usize = 48;

/// A short label for any content item, headings included — every content kind needs one now
/// ("all linkable contexts", not just headings), not only the ones already short enough to use
/// their raw text directly.
/// What to write next to an interior item's node: the first line of what it actually says.
///
/// Headings, tags and embeds carry their own text out of the index. Body blocks — paragraphs,
/// lists, code, blockquotes, tables — carry **none**: `notes`/`blocks` store a block's kind, line
/// span and weight, never its prose (see `query.noteContentGraph`, which builds them with
/// `.text = ""`). So half the nodes in a typical note's interior had no label at all and
/// `drawLabel` dropped them silently on `label_len == 0`.
///
/// The text comes from the file rather than the index. That is the same trade the backlinks pane
/// already makes (`backlinks.contextFor` reads the source line when it draws a row) and for the
/// same reason: a snippet per block would be a schema change that grows the index by the size of
/// the vault's prose, to cache something one `readFileAlloc` gets on demand. This runs once per
/// interior *build*, not per frame.
///
/// `lines` is the note's source split on newlines, or null when it could not be read — in which
/// case the item is named by kind and size, which is worse but still better than an unlabelled
/// circle.
fn interiorItemLabel(
    arena: std.mem.Allocator,
    it: content_graph.Item,
    lines: ?[]const []const u8,
) []const u8 {
    if (it.text.len > 0) return excerpt.clip(it.text, interior_content_label_max);

    if (lines) |src| {
        if (excerpt.blockExcerpt(src, it.line)) |text| return excerpt.clip(text, interior_content_label_max);
    }

    // No source line to show. Say what the thing is and how big it is; `weight` is a word count for
    // prose and a line count for code and tables (see `content_graph.Item`).
    const n = it.weight;
    const word = if (n == 1) "word" else "words";
    const line = if (n == 1) "line" else "lines";
    return switch (it.kind) {
        .paragraph => std.fmt.allocPrint(arena, "{d} {s}", .{ n, word }) catch "paragraph",
        .list => std.fmt.allocPrint(arena, "list · {d} {s}", .{ n, word }) catch "list",
        .code => std.fmt.allocPrint(arena, "code · {d} {s}", .{ n, line }) catch "code",
        .blockquote => std.fmt.allocPrint(arena, "quote · {d} {s}", .{ n, word }) catch "quote",
        .table => std.fmt.allocPrint(arena, "table · {d} {s}", .{ n, line }) catch "table",
        .root, .heading, .tag, .embed => "",
    };
}

/// The note's source, split into lines, for `blockExcerpt`. Null when it cannot be read — a note
/// open in the editor with unsaved changes still reads its on-disk text, same as the backlinks
/// pane, which is the version the index describes.
fn noteSourceLines(arena: std.mem.Allocator, st: anytype, rel: []const u8) ?[]const []const u8 {
    const root = st.vault_root orelse return null;
    if (rel.len == 0) return null;
    const abs = std.fs.path.join(arena, &.{ root, rel }) catch return null;
    const bytes = std.Io.Dir.cwd().readFileAlloc(
        dvui.io,
        abs,
        arena,
        .limited(Indexer.max_file_bytes),
    ) catch return null;

    var list: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |l| list.append(arena, l) catch return null;
    return list.toOwnedSlice(arena) catch null;
}

/// Node size for an interior item.
///
/// Headings are ranked by their own depth — an `h1` is the biggest thing in the document after the
/// sun, an `h6` barely larger than a paragraph — so the outline reads as an outline from across the
/// cloud, before any label is legible. `depth` already puts them in rings; this makes the rings
/// differ in weight as well as radius.
///
/// Body items are sized by content weight but capped, deliberately: a long paragraph should read as
/// more substantial than a one-liner, and never as more structural than the heading it sits under.
/// Before this they took `weight` raw, so a 400-word paragraph drew larger than every heading in
/// the note and the outline was inverted.
fn interiorItemDegree(it: content_graph.Item) u32 {
    return switch (it.kind) {
        .root => 64,
        .heading => heading_degree[std.math.clamp(it.level, 1, 6) - 1],
        .paragraph, .list, .code, .blockquote, .table => @min(it.weight, interior_body_degree_max),
        .tag, .embed => 1,
    };
}

/// Pseudo-degrees for `h1`…`h6`, fed to `radiusFor` (which is `√degree`-shaped, so the visible
/// steps are gentler than these numbers look).
const heading_degree = [6]u32{ 40, 24, 14, 8, 4, 2 };
/// Ceiling on a body item's size, one step under `h6`.
const interior_body_degree_max: u32 = 6;

fn buildInteriorWorld(p: *Panel, st: anytype, id: i64, gen: u64) !void {
    if (st.db == null) return error.NoDb;
    const db = &st.db.?;
    _ = p.interior.arena.reset(.retain_capacity);
    const arena = p.interior.arena.allocator();

    const idx = p.id_index.get(id) orelse return error.NoNode;
    const cg = try query.noteContentGraph(db, arena, id, p.nodes[idx].title);
    if (cg.items.len == 0) return error.Empty;

    // One read of the note, for the body-block labels the index cannot supply — see
    // `interiorItemLabel`. Best-effort: a note that cannot be read still builds, just with kind
    // labels instead of excerpts.
    const src_lines = noteSourceLines(arena, st, p.nodes[idx].path);

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

    // Polar position: angle is this item's rank in document order, swept clockwise starting from
    // north, around the full turn; radius is its depth band, with a deterministic per-item jitter
    // within that band — a belt of asteroids at roughly one radius, not a single fine line at
    // exactly one radius. Jitter is seeded off the item's own id (`mix64`, the same hash
    // `linkSignatures` already uses for a stable per-item value), not the rank used for angle, so
    // it doesn't correlate with position around the ring.
    //
    // Heading rank and "everything else" rank are counted *separately*, each against its own
    // total, rather than one shared rank across all items. A document that interleaves one
    // heading with one paragraph, over and over, still has to give each *class* the full turn —
    // sharing one rank space only spans the full circle when both classes happen to be counted in
    // exactly matching proportion throughout the document, which is not guaranteed (and wasn't
    // happening here: headings clumped into one hemisphere, content into the other, on gauntlet's
    // giant-0.md). Both classes independently sweeping the full turn is what "headings closer in,
    // content further out, but both wrap all the way around" actually requires.
    var heading_total: u32 = 0;
    var other_total: u32 = 0;
    for (1..n) |i| {
        if (items[i].kind == .heading) heading_total += 1 else other_total += 1;
    }
    const local_pos = try arena.alloc(dvui.Point, n);
    local_pos[0] = .{}; // unused — the sun is pinned at `parent`, not placed in this space
    var extent: f32 = 1.0;
    var heading_rank: u32 = 0;
    var other_rank: u32 = 0;
    for (1..n) |i| {
        const is_heading = items[i].kind == .heading;
        const rank: f32 = @floatFromInt(if (is_heading) heading_rank else other_rank);
        const total: f32 = @floatFromInt(@max(if (is_heading) heading_total else other_total, 1));
        if (is_heading) heading_rank += 1 else other_rank += 1;
        // `- tau/4` starts rank 0 at north (screen-up); increasing angle from there sweeps
        // clockwise, same convention the rest of this file's local-space math already uses.
        const a = (rank / total) * std.math.tau - std.math.tau / 4.0;
        const h = mix64(@bitCast(items[i].id));
        const jitter01 = @as(f32, @floatFromInt(h % 1_000_000)) / 1_000_000.0; // [0, 1)
        const jitter = (jitter01 - 0.5) * interior_ring_gap * interior_ring_band;
        const r = 1.0 + depth[i] * interior_ring_gap + jitter;
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
            .title = interiorItemLabel(arena, it, src_lines),
            .phantom = false,
            .degree = interiorItemDegree(it),
            .target = p.interior.parent,
            .home = p.interior.parent,
            .pos = p.interior.parent,
            .target_radius = radiusFor(interiorItemDegree(it), false, false),
            .radius = radiusFor(interiorItemDegree(it), false, false),
            // No coalescing in this layout — every item is always drawn as itself.
            .alpha = 1,
        };
    }

    const graph_edges = try arena.alloc(GraphEdge, edges.len);
    for (edges, 0..) |e, i| graph_edges[i] = .{ .a = e.a, .b = e.b };

    p.interior.nodes = nodes;
    rewarmLabels(nodes, &p.interior_label_live);
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
    p.open_notes.clearRetainingCapacity();
    const wb = sdk.host().getServiceTyped(sdk.services.workbench.Api) orelse {
        p.open_hash = open_hash;
        return;
    };
    const n_open = wb.openCount();
    if (n_open > 0) {
        // One pass to index by path, rather than a full scan of the vault per open tab. At 286,546
        // notes the nested version was a string compare against every node for each tab, on the
        // frame the tab set changed — which is exactly the frame the reader is watching for the
        // camera to respond to.
        const arena = dvui.currentWindow().arena();
        var by_path: std.StringHashMapUnmanaged(u32) = .empty;
        by_path.ensureTotalCapacity(arena, @intCast(p.nodes.len)) catch {};
        for (p.nodes, 0..) |*node, gi| {
            if (node.path.len == 0) continue;
            by_path.put(arena, node.path, @intCast(gi)) catch {};
        }

        var rel_buf: [query.max_rel_path]u8 = undefined;
        var i: usize = 0;
        while (i < n_open) : (i += 1) {
            const abs = wb.openPathAt(i) orelse continue;
            if (!query.isMarkdownPath(abs)) continue;
            const rel = query.vaultRelative(vault, abs, &rel_buf) orelse continue;
            const gi = by_path.get(rel) orelse continue;
            const node = &p.nodes[gi];
            node.open = true;
            node.focus_t = 1;
            node.target_radius = radiusFor(node.degree, true, node.phantom);
            p.open_notes.append(sdk.allocator(), gi) catch {};
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
        // Closing the last note moves the camera nowhere.
        //
        // This used to `zoomExtents()`, on the reasoning that with no document open there is
        // nothing to be looking *at*. But closing a tab is not a request to go anywhere: you were
        // reading some part of the web, and being thrown back to the whole vault loses the place
        // you were in — on a large vault that is a flight all the way out to a view where nothing
        // you were looking at is legible any more. The camera follows the *focused document*, and
        // closing the last one leaves no new focus to follow.
        //
        // `.free` rather than `.extents`, and that is the whole of the fix. Leaving it `.extents`
        // just defers the recentre: `applyFraming` re-derives the pose on the next resize or
        // layout re-solve, so the view would sit still and then snap out on the next splitter
        // drag. `.free` is what the panel already uses for "the user put the camera here" — a
        // resize or a reindex must not yank it away — and it is exactly the right meaning here.
        // Opening a document takes control back, since `updateActiveDoc`/`applyOpenSet` frame the
        // new focus regardless of the previous framing.
        //
        // Includes the case where the closed note was one we had descended into: `leaving_interior`
        // above has already dropped `.interior` framing so the cross-fade can play out, and the
        // camera simply stays at the pose it fades out on. The recentre button is one click away
        // for a reader who does want the whole web back.
        if (was_any) p.framing = .free;
        return;
    }
    if (framing_debug) {
        dvui.log.info("atlas openset: first={} changed={} any={} opened={?d} framing={s}", .{
            first, changed, is_any, opened, @tagName(p.framing),
        });
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
        // Being *inside* the note counts too — see `insideInterior`.
        if (!already and !insideInterior(p, id)) focusNode(p, idx);
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

/// True when the reader is currently *inside* `id`'s interior, whatever the framing says.
///
/// Both of the reframe-on-open paths — `applyOpenSet` and `updateActiveDoc` — have to ask this, and
/// they ask it for the same reason: a descent driven by hand never sets `.interior` framing, since
/// zooming by hand sets `.free`. Opening a document from in there would otherwise fly the camera
/// out to the note's node in the overview, which is the reader asking to see one paragraph and
/// being ejected from the room to look at the building. `revealPosition` has already scrolled the
/// editor to the line; there is nothing left to go and look at.
///
/// Keyed on the interior actually being on screen rather than merely built, so a cloud that is
/// fading out cannot pin the camera inside a note the reader is leaving.
fn insideInterior(p: *const Panel, id: i64) bool {
    return p.interior.t >= 0.5 and (p.interior.note_id orelse 0) == id;
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
/// Fly the camera to one note — the focused document — and nothing else.
///
/// This used to frame the clicked note *plus every open document*, adding their 1-hop neighbours
/// as context whenever more than one was open. On a personal vault that reads as helpful. On a
/// 283,878-note Wikipedia vault two tabs are routinely in unrelated regions, so the fit that holds
/// both is enormous — and at that zoom the note you just asked for coalesces back into a mass.
/// Clicking a node zoomed *out* and lost it, which is the exact opposite of what a click means.
/// The panel now answers one question: where is the document I am looking at.
///
/// Two positions matter and only one of them used to be right:
///
///   * **Where.** `GraphNode.pos` is only written for notes that resolved as marks this frame, so
///     a note inside a coalesced mass carries a stale one. `World.noteWorldPos` forces the lazy
///     placement down the ancestor chain and returns the exact resting position instead, so the
///     camera aims where the note will actually be when it arrives.
///   * **How close.** `World.noteResolveZoom` is the zoom at which the leaf's parent splits. Below
///     it the note cannot be drawn as itself, whatever else the framing wants — so it is a hard
///     floor, and "the selected note never coalesces" becomes a property of the camera.
fn focusNode(p: *Panel, idx: usize) void {
    if (idx >= p.nodes.len) return;

    // Claim the focus here, before the workbench catches up.
    //
    // A click marks the document *open* immediately but does not make it *active* until a frame or
    // two later, and the two states light its links differently: an open note drawn as itself is
    // painted at full length by the ambient lit branch, while the focused note's links are drawn by
    // the leaf-precision pass and reach out from zero. So the gap showed as the links appearing at
    // full length, blinking out as the focus arrived and the ambient branch handed them over, then
    // animating out again.
    //
    // A *claim* rather than just writing `focus_node`, because `focusNodeIndex` asks the workbench
    // first and would immediately overwrite it with the document that is still active — which is
    // precisely the stale answer this exists to ignore.
    p.focus_claim = @intCast(idx);
    p.focus_claim_frames = 0;

    const vp = p.camera.viewport;
    if (vp.w < 32 or vp.h < 32) return;

    const slot = if (p.layout_slot > 1) p.layout_slot else layout_full.slotSpacingFor(p.nodes.len);

    var centre = focusPoseOf(p, idx, p.nodes[idx]);
    var z_floor: ?f32 = null;
    if (ensureWorld(p)) |w| {
        const note: u32 = @intCast(idx);
        if (w.noteWorldPos(note)) |wp| centre = .{ .x = wp.x, .y = wp.y };
        // Deliberately the *base* split, not the motion-biased one: this is where the camera will
        // come to rest, and at rest the bias is 1. Using the in-flight value would inflate the
        // floor by however fast the camera happened to be moving when the flight began, and land
        // closer than asked for.
        z_floor = w.noteResolveZoom(note, .{ .split_px = base_split_px * dpiScale() });
    }

    // A few slots of room around the note, so it lands in a neighbourhood rather than filling the
    // pane on its own.
    const half = focus_context_slots * slot;
    const bounds: dvui.Rect = .{
        .x = centre.x - half,
        .y = centre.y - half,
        .w = half * 2,
        .h = half * 2,
    };
    const pad = @min(focus_padding_px * dpiScale(), vp.h * 0.15);
    var pose = p.camera.poseForBounds(bounds, pad);
    pose.center = centre;

    // The dinner-plate stop, unchanged: never so close that neighbouring lattice slots are further
    // apart than `focus_max_gap_px`.
    pose.zoom = @min(pose.zoom, focus_max_gap_px * dpiScale() / slot);

    // The whole-vault fit is a **floor**, never a ceiling: a focus flight never pulls further back
    // than the recentre button would, and is otherwise free to go as close as the rules above ask.
    //
    // It used to also be a ceiling whenever the vault already fitted at a zoom where the note was
    // resolved — "small vaults keep their context". That condition is true of every vault up to a
    // few thousand notes, so on those, focusing a note clamped the zoom to the whole-vault fit and
    // the flight did nothing at all: the camera centred on the note and stayed exactly as far out
    // as it was. It only looked correct at Wikipedia scale, where the vault fit is far looser than
    // any note's resolve zoom and the clamp never fired.
    //
    // Context is already accounted for twice over without it — `focus_context_slots` frames a
    // neighbourhood rather than a lone dot, and `focus_max_gap_px` is the close-up stop. A third
    // opinion that overrides both into "stay put" is not a third opinion, it is a bug.
    if (vaultExtentsPose(p)) |extents| pose.zoom = @max(pose.zoom, extents.zoom);
    // Applied last so nothing above can push the note back into a mass. The margin keeps the
    // pin in `decideTopology` a safety net rather than the mechanism.
    if (z_floor) |zf| pose.zoom = @max(pose.zoom, zf * focus_resolve_margin);
    pose.zoom = p.camera.clamp(pose.zoom);

    // Must drop, or `animateCamera` suppresses the chase and the retarget just sits there.
    p.camera.user_driving = false;
    p.framing = .{ .note = p.nodes[idx].note_id };
    // A coasting pan would fight the flight and re-sync the targets out from under it.
    p.fling_x.cancel();
    p.fling_y.cancel();
    p.camera.retarget(pose);
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
    var rel_buf: [query.max_rel_path]u8 = undefined;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const abs = wb.openPathAt(i) orelse continue;
        if (!query.isMarkdownPath(abs)) continue;
        const rel = query.vaultRelative(vault, abs, &rel_buf) orelse continue;
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
    const s = dpiScale();
    const px = short * fit_pad_frac;
    // Let the margin track the pane; only clamp the extremes so tiny panes still clear a
    // bubble+label and enormous ones don't become empty oceans.
    return std.math.clamp(px, fit_edge_px * s, fit_label_px * s * 4.0);
}

/// Neighbour-gap ceiling for fit-to-extents. Scales with the pane so a small cloud on a large
/// window is allowed to zoom in and fill the view; the absolute floor keeps modest panels from
/// turning three notes into dinner plates.
fn fitMaxGapPx(vp: dvui.Rect.Physical) f32 {
    const short = @min(vp.w, vp.h);
    return @max(fit_max_gap_px * dpiScale(), short * fit_max_gap_frac);
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
    zoomExtentsFor(&(panel orelse return));
}

/// User-triggered recenter, parameterized — the real bottom panel's `zoomExtents` is a one-line
/// wrapper over this on the module-global `panel`; the vault simulator's own fit button (inside
/// `drawFitButton`, called with whichever `Panel` it was actually given) calls this directly on
/// its own `Panel` instead, so "recenter" affects the panel the button is drawn over rather than
/// always the real one regardless of which window it was clicked in.
pub fn zoomExtentsFor(p: *Panel) void {
    // Retarget and let `animateCamera` ease us there. `user_driving` must drop or the chase is
    // suppressed. Record the viewport as fitted so `maybeFitCamera` doesn't see "never fitted"
    // next frame and snap on top of the animation.
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
    // A document is open → recentre on *it*, not on the vault.
    //
    // "Zoom to centre" means "show me what I am working on", and once a document is open that is
    // the document — the whole vault is what you want when nothing is. This also makes the button
    // a follow: edit a note's links, let the graph rebuild, press it again and the camera lands on
    // wherever that note moved to.
    if (focusTargetIndex(p)) |idx| {
        focusNode(p, idx);
        if (p.camera.viewport.w >= 32 and p.camera.viewport.h >= 32) {
            p.fitted_vp_w = p.camera.viewport.w;
            p.fitted_vp_h = p.camera.viewport.h;
        }
        dvui.refresh(null, @src(), null);
        return;
    }

    p.framing = .extents;
    fitToNodes(p, .{ .animate = true });
    if (p.camera.viewport.w >= 32 and p.camera.viewport.h >= 32) {
        p.fitted_vp_w = p.camera.viewport.w;
        p.fitted_vp_h = p.camera.viewport.h;
    }
    dvui.refresh(null, @src(), null);
}

/// The note "recentre" should frame, or null when nothing is open.
///
/// Prefers whichever note the camera is already framing, so repeated presses stay on the document
/// you have been following rather than drifting to whatever happens to be first in tab order. One
/// definition, shared by the button and by anything else that needs "the note in view".
fn focusTargetIndex(p: *Panel) ?usize {
    switch (p.framing) {
        .note, .interior => |id| {
            if (noteOpen(p, id)) {
                if (p.id_index.get(id)) |idx| return idx;
            }
        },
        else => {},
    }
    if (p.open_notes.items.len > 0) {
        const idx = p.open_notes.items[0];
        if (idx < p.nodes.len) return idx;
    }
    return null;
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

fn segmentMaybeInView(a: dvui.Point.Physical, b: dvui.Point.Physical, view: dvui.Rect.Physical) bool {
    if (view.contains(a) or view.contains(b)) return true;
    // Bounding-box overlap.
    const min_x = @min(a.x, b.x);
    const max_x = @max(a.x, b.x);
    const min_y = @min(a.y, b.y);
    const max_y = @max(a.y, b.y);
    return !(max_x < view.x or min_x > view.x + view.w or max_y < view.y or min_y > view.y + view.h);
}

/// How much further than a tight fit the camera may be pulled back — 2 puts the whole vault in
/// half the panel. See `Camera.setContentExtent`.
const zoom_out_slack: f32 = 2.0;
/// Screen-pixel margin when a cluster click frames its region. Generous, so the notes inside
/// arrive with their surroundings rather than pressed against the panel edge.
const cluster_frame_pad_px: f32 = 60.0;

/// The coalesced mass under `screen_pt`, if any. Among overlapping masses prefer the **tightest**
/// (fewest notes / highest depth) — nearest-centre picked a tiny mass sitting inside a large
/// dashed ring and framed two nodes for a click that looked like the big cluster.
fn hitTestClusters(p: *const Panel, screen_pt: dvui.Point.Physical) ?Visible {
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

/// The living world for this frame, or null while one is still being built.
///
/// A lookup, not a builder. `World.init` runs on the solve worker (`LayoutJob.buildWorld`) and is
/// adopted by `finishRebuild` in the same frame as the nodes it indexes; building it here — at the
/// top of `drawPanel`, which is where this used to happen — froze the editor for tens of seconds
/// on a large vault, outside every profiling bucket.
///
/// Callers must tolerate null. `drawPanel` already falls back to `p.world_radius` for the camera
/// extent, and `stepWorld` returns early, which leaves the previous frame's marks on screen.
fn ensureWorld(p: *Panel) ?*world_mod.World {
    if (p.world_epoch == p.layout_epoch) {
        if (p.world_state) |*w| return w;
    }
    return null;
}

/// The mark budget the rest of this file's quality curve is anchored to — the `graph_detail`
/// default. At exactly this value every derived quantity below reproduces the constant it replaced,
/// so a reader who never touches the slider sees precisely the tuning that was measured.
const detail_anchor: f32 = 360;

/// Ambient web budget: lines between *coalesced masses*, and nothing else.
///
/// This was a flat 900, and the reasoning against scaling it is still worth knowing, because it is
/// half true. Two different things were once conflated in `mark_budget * 5/2`: a note drawn as
/// itself must show all of its links or the picture lies about what it connects to, while
/// mass-to-mass lines are aggregates. A mass has hundreds of members, so it is adjacent to nearly
/// every other mass on screen, and drawing all of that is a grey wash that says only "everything
/// touches everything".
///
/// What changed is that the first half no longer depends on this number at all — a note drawn as
/// itself is exempt (see `essential` in `world.liftLinks`), which is why a 3000-note vault draws
/// 3879 lines against a budget of 900. So this governs only the aggregate wash, and the slider is
/// now explicitly the control for how much of that you want: at the low end a sparse, cheap map; at
/// the high end an accurate one you are paying for on purpose.
///
/// Measured on `synth:300000:scale-free` (`bench --world --link-budget=N`), lift time per frame:
/// 900 → 0.55 ms, 2500 → ~1.2 ms, 5000 → 2.30 ms, 20000 → 5.82 ms. At the slider's maximum this
/// reaches 10000, which is ~3 ms of lift on a 300k vault — the top of the slider is deliberately
/// past the comfortable point, because that is what a quality control is for. On a small vault it
/// costs nothing either way: there are only ~800 adjacent cut-cell pairs to draw, so 900 and 20000
/// produce 761 and 802 lines respectively.
fn ambientLinkBudget(mark_budget: usize) usize {
    return world_mod.Params.ambientLinkBudget(mark_budget);
}

/// How far the LOD is allowed to coarsen while the camera pans, for a given mark budget.
///
/// The constant this replaces was 3.5 — a fast pan resolved roughly the detail a camera 3.5×
/// further out would. That is what makes notes dissolve into masses while you drag and re-emerge
/// when you stop, and since a link can only be drawn between two *living* cells, it is also the
/// main reason connections appear and vanish during a pan. Trading it against the slider means the
/// low end keeps the cheap, aggressive coarsening that makes a huge vault survive a fling, while
/// the high end holds more detail through the motion.
///
/// The high end stops at 2.0 rather than going to ~1 (no coarsening at all), which was the first
/// attempt and was measurably wrong. Coarsening is not where a fast pan's cost lives: on a 300k
/// vault at quality 4000, opening up to a bias of 3.5 cuts marks from 2827 to 470 and still leaves
/// the frame at ~3 ms, because the *lift* keeps filling its link budget either way. So the mark
/// count is worth relaxing a little for draw cost, and `lift_hold` — which skips the lift outright
/// — is what actually makes the motion cheap.
fn motionSplitMax(mark_budget: usize) f32 {
    const d: f32 = @floatFromInt(mark_budget);
    // Anchored at the default so the shipped feel is unchanged there, and clamped at both ends:
    // below 1 the pan would *sharpen* the LOD, which is not a thing this knob should be able to do.
    return if (d <= detail_anchor)
        std.math.lerp(5.0, 3.5, std.math.clamp((d - 50) / (detail_anchor - 50), 0, 1))
    else
        std.math.lerp(3.5, 2.0, std.math.clamp((d - detail_anchor) / (4000 - detail_anchor), 0, 1));
}

/// How far into the *available* motion bias the camera must be before the web stops being
/// re-lifted. See `world.Params.lift_hold`.
///
/// Gating on *speed* rather than on a frame count is the point. A frame counter re-lifts every N-th
/// frame no matter what, which on a multi-second flight is a 5–10 ms spike at a fixed cadence —
/// a periodic hitch, and exactly the thing it was added to avoid. Speed releases the hold when the
/// camera slows, which is when the web starts being readable again, and never in the middle of a
/// fast move.
///
/// A *fraction* rather than an absolute bias, because the bias can no longer exceed
/// `motionSplitMax`, which falls as the quality slider rises. As an absolute 1.15 this silently
/// stopped engaging at high quality — the bias there tops out at barely above it — so the one
/// mechanism that makes a fast pan cheap switched itself off at exactly the setting that needs it,
/// and the lift is 98% of the world's frame cost (5.46 ms of 5.59 at quality 4000). 0.06 of the
/// range reproduces the old 1.15 exactly at the default's split max of 3.5.
const lift_hold_frac: f32 = 0.06;

fn liftHoldBias(split_max: f32) f32 {
    return 1 + (split_max - 1) * lift_hold_frac;
}
/// Even so, refresh occasionally during a sustained drag so a long slow pan is not frozen. Rare
/// enough that the cost lands once per half-second rather than every fifth frame.
const lift_hold_max_frames: u16 = 30;

/// Base split threshold: a cell opens once its on-screen radius passes this. Mirrors
/// `world.Params.split_px`'s default, named here because the motion bias scales it.
const base_split_px: f32 = 30;
/// Screen-widths per second at which the bias reaches its maximum.
const motion_full_speed: f32 = 2.5;
/// Chase rate for the smoothed speed. Deliberately asymmetric in use: bias rises quickly so a
/// flick does not spike the frame, and falls slowly so detail arrives as a settle rather than a
/// snap the instant the mouse stops.
const motion_rise_k: f32 = 14;
const motion_fall_k: f32 = 3.5;
/// |octaves/s| at which a zoom gesture starts holding / coarsening the LOD. A doubling in ~1.4 s
/// is still a careful dive (splits as you go); a doubling in half a second is a flick.
const zoom_hold_oct_ps: f32 = 0.7;
/// |octaves/s| at which zoom-out coarsening reaches `motionSplitMax`.
const zoom_full_oct_ps: f32 = 2.5;
const zoom_rise_k: f32 = 20;
const zoom_fall_k: f32 = 5;
/// First-time cell placements allowed in one catch-up frame. Already-settled cells still open
/// freely; this only bounds the 128-step boids settle that hitches a flick-zoom.
const zoom_max_expand: usize = 24;

/// Coarsen the LOD while the camera **pans** fast or **zooms out** fast, hold it still while
/// the reader **flicks zoom in**, and let it settle back as the gesture slows.
///
/// Crossing the vault at close zoom drags the whole resolved middle of it through the frame: cells
/// open and close, the cut churns, the web re-lifts, thousands of marks are placed — all to render
/// detail that is a blur at that speed. A camera moving a screen-width every half second cannot be
/// read at note level, so it does not need to be drawn at note level.
///
/// Zoom used to be excluded entirely, because feeding *every* zoom into `split_px` froze the LOD
/// for a careful trackpad dive and then dumped every mark on release. The distinction that was
/// missing is speed. A slow zoom *is* the dive and must split; a flick is a camera move and must
/// not. A **user** zoom-in flick holds the current open set (marks grow with the camera). A
/// **click-to-focus** chase is the dive: holding until the camera parked, then dumping the
/// split, is what made the notes explode after the flight rather than with it. `max_expand`
/// still caps the settle either way. Zoom-out coarsens, because keeping an exploded view while
/// pulling out is the expensive direction.
///
/// Raising `split_px` is the coarsening mechanism: it is already the rule that decides when a cell
/// resolves, so scaling it makes fast motion behave exactly like being further out — the same
/// coalescing, the same crossfade on the way back. No second LOD, no second code path.
///
/// **On the contract.** `decideTopology` is documented as a pure function of (tree, view, zoom,
/// budget), and this makes speed a fifth input. That is a real extension and it is a safe one:
/// speed is an *input*, not the topology reading its own output — which is the feedback that
/// caused the old explode/collapse loops — and it is zero when the camera is parked, so
/// "a parked camera means the open set stops changing" still holds exactly.
///
/// Asymmetric smoothing is what makes it feel like settling rather than popping: coarsen quickly
/// (before the expensive frame, not after it), refine slowly.
fn updateMotionBias(p: *Panel) void {
    const dt = @max(dvui.secondsSinceLastFrame(), 1.0 / 240.0);
    const span = @max(@min(p.camera.viewport.w, p.camera.viewport.h), 1);

    // Measure in *screen* terms, so the same world distance counts for more when zoomed in —
    // which is exactly when crossing it is expensive.
    const dx = (p.camera.center.x - p.motion_last_center.x) * p.camera.zoom;
    const dy = (p.camera.center.y - p.motion_last_center.y) * p.camera.zoom;
    const pan_speed = @sqrt(dx * dx + dy * dy) / span / dt;
    p.motion_last_center = p.camera.center;

    const z = @max(p.camera.zoom, 1e-9);
    const z0 = if (p.motion_last_zoom > 0) p.motion_last_zoom else z;
    const oct_ps = @abs(std.math.log2(z / z0)) / dt;
    if (z > z0 * 1.0005) p.zoom_dir = 1 else if (z < z0 / 1.0005) p.zoom_dir = -1;
    p.motion_last_zoom = z;
    const zk = if (oct_ps > p.zoom_speed) zoom_rise_k else zoom_fall_k;
    p.zoom_speed += (oct_ps - p.zoom_speed) * (1.0 - @exp(-zk * dt));
    if (p.zoom_speed < 0.02) {
        p.zoom_speed = 0;
        p.zoom_dir = 0;
    }

    // Derived from the detail slider rather than fixed: see `motionSplitMax`. At the default it is
    // the 3.5 this used to hardcode.
    const split_max = motionSplitMax(p.mark_budget);
    var want = 1 + (split_max - 1) * std.math.clamp(pan_speed / motion_full_speed, 0, 1);
    // Fast zoom-out coarsens now, so the exploded field is not dragged through a shrinking view.
    if (p.zoom_dir < 0 and p.zoom_speed > zoom_hold_oct_ps) {
        const zt = std.math.clamp(p.zoom_speed / zoom_full_oct_ps, 0, 1);
        want = @max(want, 1 + (split_max - 1) * zt);
    }
    const k = if (want > p.motion_bias) motion_rise_k else motion_fall_k;
    const t = 1.0 - @exp(-k * dt);
    p.motion_bias += (want - p.motion_bias) * t;
    if (@abs(p.motion_bias - 1) < 0.01) p.motion_bias = 1;
}

/// Re-focus the camera when the *focused tab* changes.
///
/// The graph only ever knew the open *set* — `hashOpenNotes` over every open markdown tab — and
/// treated all of them alike, so switching between two open documents changed nothing it could
/// see. `Host.activeDoc` is the missing concept, and Atlas already uses it in the backlinks pane;
/// the graph never did.
///
/// Cheap by construction: the steady-state path is one vtable call and an integer compare. Only a
/// change in document id does any resolution work, and that resolution is a hash lookup because
/// `p.path_index` is built once per rebuild.
fn updateActiveDoc(p: *Panel, st: anytype) void {
    if (p.synthetic) return; // the simulator has no workbench
    const vault = st.vault_root orelse return;

    const doc = sdk.host().activeDoc() orelse {
        p.active_doc_id = 0;
        return;
    };
    if (doc.id == p.active_doc_id) return;
    p.active_doc_id = doc.id;

    const path = doc.owner.documentPath(doc);
    if (path.len == 0) return;
    if (!query.isMarkdownPath(path)) return;
    var rel_buf: [query.max_rel_path]u8 = undefined;
    const rel = query.vaultRelative(vault, path, &rel_buf) orelse return;
    const gi = p.path_index.get(rel) orelse return;

    // Already framing this note — a graph click focuses before the tab list catches up, and
    // re-flying here would restart the ease mid-flight.
    switch (p.framing) {
        .note, .interior => |id| if (id == p.nodes[gi].note_id) return,
        else => {},
    }
    // Nor when the reader is inside it: opening a section from within a hand-driven descent makes
    // that document active, and flying to its node would eject them. See `insideInterior`.
    if (insideInterior(p, p.nodes[gi].note_id)) return;
    focusNode(p, gi);
}

/// The graph node of the workbench's active document, or null.
///
/// Resolved per frame from the document path rather than cached alongside `active_doc_id`: a
/// reindex rebuilds `p.nodes` and `p.path_index` together, and an index cached across that is
/// silently a different note. Two hash lookups on a short string is not worth the risk of being
/// subtly wrong about which note the reader is looking at.
fn activeNodeIndex(p: *Panel) ?u32 {
    if (p.synthetic) return null;
    const st = runtime.state();
    const vault = st.vault_root orelse return null;
    const doc = sdk.host().activeDoc() orelse return null;
    const path = doc.owner.documentPath(doc);
    if (path.len == 0 or !query.isMarkdownPath(path)) return null;
    var rel_buf: [query.max_rel_path]u8 = undefined;
    const rel = query.vaultRelative(vault, path, &rel_buf) orelse return null;
    return p.path_index.get(rel);
}

/// How long a click's claim on the focus outlives the workbench disagreeing with it. Two frames
/// is the observed lag; this is loose enough to cover a slow open and short enough that a claim
/// which never lands is gone within a blink.
const focus_claim_max_frames: u16 = 30;

/// Which node's links are highlighted, held steady across a tab switch.
///
/// `activeNodeIndex` answers for *this frame*, and during a tab change the workbench reports no
/// active document for a frame or two — traced on a 286k-note vault, every click produced a frame
/// with `focus_cut` invalid between two valid ones. Answering "nothing is focused" there clears the
/// focused link set, which drops its per-link reach progress, so the highlight replayed its
/// animation twice per click: once leaving the old note and once arriving at the same new one.
///
/// So a missing active document is treated as "the answer has not changed", not as "there is no
/// answer" — *unless* the workbench has nothing open at all, which is the one signal that tells the
/// two apart. Mid-switch, documents are still open and only the active one is momentarily unset;
/// with everything closed there is no note to be looking at, and a highlight left burning over an
/// empty editor is the obvious tell that this hold went too far.
fn focusNodeIndex(p: *Panel) ?u32 {
    // A click outranks the workbench until the workbench agrees with it.
    if (p.focus_claim != fold.invalid) {
        const active = activeNodeIndex(p);
        if (active != null and active.? == p.focus_claim) {
            // Caught up: drop the claim and let the normal path run from here on.
            p.focus_claim = fold.invalid;
        } else if (p.focus_claim_frames > focus_claim_max_frames) {
            // A click that never became an active document — a failed open, or the reader moved on
            // — must not pin the highlight indefinitely.
            p.focus_claim = fold.invalid;
        } else {
            p.focus_claim_frames +|= 1;
            p.focus_node = p.focus_claim;
            return p.focus_node;
        }
    }
    if (activeNodeIndex(p)) |gi| {
        p.focus_node = gi;
    } else if (p.focus_node == fold.invalid and p.open_notes.items.len > 0) {
        // Tab order, and *only* as a seed when nothing is held yet. Letting it run on every frame
        // with no active document is what made a click on a new node animate twice: the frame
        // between documents fell through to `open_notes[0]`, which is a different note whenever
        // the one just clicked is not first in the tab strip, so the focus went new → tab-order →
        // new, wiping the per-link reach twice. A hold that switches to something else is not a
        // hold.
        p.focus_node = p.open_notes.items[0];
    } else if (!p.synthetic) {
        // Only the workbench knows the difference between "between tabs" and "no tabs". Absent the
        // service there is no way to tell, so the hold stands rather than guessing.
        if (sdk.host().getServiceTyped(sdk.services.workbench.Api)) |wb| {
            if (wb.openCount() == 0) p.focus_node = fold.invalid;
        }
    }
    if (p.focus_node == fold.invalid) return null;
    if (p.focus_node >= p.nodes.len) {
        // A reindex rebuilt the node list and the held index no longer means what it did.
        p.focus_node = fold.invalid;
        return null;
    }
    return p.focus_node;
}

/// The world parameters for this frame. One definition, because `focusNode` needs the same
/// `split_px` the LOD is about to use — deriving the camera's never-coalesce floor from a
/// different value than the one that decides it would be a slow drift into wrongness.
fn worldParams(p: *Panel) world_mod.Params {
    // The note whose links must survive the budget: the *focused* document, falling back to tab
    // order only when there is no active one.
    //
    // This used to be `open_notes[0]` unconditionally, which is right with one tab open and wrong
    // the moment there are two: `open_notes` is in tab order, so clicking a node highlighted
    // whichever note happened to sit first in the tab strip rather than the one just selected. The
    // reader then sees a lit web belonging to a different note, and tracing an edge to its far end
    // lights up nothing — the failure reads as "the highlight was lost" rather than as "the
    // highlight is of something else".
    var focus_leaf: u32 = fold.invalid;
    // Every open note's leaf, focused one first. `liftLinks` draws all of their links at leaf
    // precision, which is what stops a note's connections changing identity depending on whether it
    // happens to be the focused tab — see `world.Params.open_leaves`.
    var open_leaves: std.ArrayListUnmanaged(u32) = .empty;
    if (p.world_state) |*w| {
        const arena = dvui.currentWindow().arena();
        if (focusNodeIndex(p)) |gi| {
            if (gi < w.lad.leaf_cell.len) {
                focus_leaf = w.lad.leaf_cell[gi];
                open_leaves.append(arena, focus_leaf) catch {};
            }
        }
        for (p.open_notes.items) |gi| {
            if (gi >= w.lad.leaf_cell.len) continue;
            const lf = w.lad.leaf_cell[gi];
            if (lf == focus_leaf) continue;
            open_leaves.append(arena, lf) catch {};
        }
    }
    // Hold the web while the camera is moving *fast*, with a rare forced refresh so a sustained
    // drag still catches up. `motion_bias` is already the smoothed speed the LOD uses, so this
    // costs nothing extra and releases at the same moment detail starts coming back.
    var hold = false;
    if ((p.motion_bias > liftHoldBias(motionSplitMax(p.mark_budget)) or
        p.zoom_speed > zoom_hold_oct_ps * 0.5) and
        p.lift_held < lift_hold_max_frames)
    {
        hold = true;
        p.lift_held += 1;
    } else {
        p.lift_held = 0;
    }

    const s = dpiScale();
    const defaults: world_mod.Params = .{};
    return .{
        .budget = p.mark_budget,
        .link_budget = ambientLinkBudget(p.mark_budget),
        // Highlighted lines get the same allowance as the ambient web, spent focused-note-first.
        .focus_link_budget = ambientLinkBudget(p.mark_budget),
        .focus_leaf = focus_leaf,
        .open_leaves = open_leaves.items,
        .lift_hold = hold,
        // Only a hand-driven flick holds the open set. `user_driving` is false for the whole
        // click-to-focus chase, so the split travels with the camera instead of waiting for
        // `zoom_speed` to decay after it parks. `max_expand` is the hitch bound either way.
        .hold_topology = p.camera.user_driving and p.zoom_speed > zoom_hold_oct_ps and p.zoom_dir >= 0,
        .max_expand = zoom_max_expand,
        // The LOD ladder's thresholds are screen sizes too, so they get the same treatment as
        // the bubbles — otherwise cells open at twice the apparent density on a 1x monitor and
        // the mark radii they hand back are twice as large. Scaled here rather than in
        // `world.Params`' own defaults so `bench --world`, which has no window to ask, keeps
        // reading the same numbers it always has.
        .split_px = base_split_px * s * p.motion_bias,
        .note_r_px = defaults.note_r_px * s,
        .mass_cap_px = defaults.mass_cap_px * s,
        .cull_pad_px = defaults.cull_pad_px * s,
    };
}

/// Advance the living set for this frame's camera and publish it onto `p.nodes`.
///
/// Runs *before* hover, proximity and label placement, not inside the draw. Those all read
/// `node.pos`, so stepping the world inside `drawWorldMarks` left every one of them a frame
/// behind — hover latched onto whatever was under the cursor last frame, the label placer
/// measured collisions against stale positions and refused nearly every slot, and clicks
/// resolved against the wrong node.
/// Slide notes from where they were before the last rebuild to where the new fold put them.
///
/// Applied to the marks *after* `World.step` rather than inside it, because the world has no memory
/// of the arrangement it replaced — `present` derives a cell's position from its parent and the
/// open/close crossfade, and a re-fold hands it entirely new cells. The marks are rebuilt every
/// frame, so adjusting them here is transient by construction: nothing downstream has to know, and
/// there is no state to unwind when the travel finishes.
///
/// Notes only. A coalesced mass is a *new aggregate* — the old world had no single thing that
/// became it, so there is no honest position to come from, and inventing one would slide a ring in
/// from somewhere it never was.
fn applyMorph(p: *Panel, w: *world_mod.World) void {
    if (p.morph_t >= 1) return;
    p.morph_t += @min(dvui.secondsSinceLastFrame(), 1.0 / 30.0) / morph_s;
    if (p.morph_t >= 1) {
        p.morph_t = 1;
        p.morph_from.clearRetainingCapacity();
        return;
    }
    // Ease out: most of the distance early, settling into the new home. The same curve the link
    // reach-out uses, so the two read as one movement when a save does both.
    const e = dvui.easing.outCubic(p.morph_t);
    for (w.marks.items) |*m| {
        if (!m.is_note or m.note >= p.nodes.len) continue;
        const from = p.morph_from.get(p.nodes[m.note].note_id) orelse continue;
        m.wx = from.x + (m.wx - from.x) * e;
        m.wy = from.y + (m.wy - from.y) * e;
    }
    dvui.refresh(null, @src(), dvui.parentGet().data().id);
}

fn stepWorld(p: *Panel, prof: *i96) void {
    // Everything between the rebuild and here (interior, camera, fling, framing) belongs to
    // `misc`; the three buckets below are this function's own.
    frame_profile.misc_ns += profLap(prof);
    const w = ensureWorld(p) orelse return;
    const vp = p.camera.viewport;
    const view: world_mod.View = .{
        .w = vp.w,
        .h = vp.h,
        .zoom = p.camera.zoom,
        .cx = p.camera.center.x,
        .cy = p.camera.center.y,
    };
    // Links scale with marks at the same 2.5:1 ratio the defaults use (360 marks / 900 links), so
    // raising the mark budget doesn't leave the web pinned at a cap the marks have outgrown.
    const params = worldParams(p);
    w.step(view, params, dvui.secondsSinceLastFrame()) catch return;
    applyMorph(p, w);
    updateHoldsOpen(p, w);
    frame_profile.world_step_ns = profLap(prof);
    syncNodesFromWorld(p, w);

    frame_profile.world_sync_ns = profLap(prof);

    // No per-frame edge array any more: `liftLinks` reads the cut and the precomputed cell web.
    // Building one cost a 23.5 MB frame-arena allocation and a full rewrite of every edge at a
    // million notes, purely so the lift could look each endpoint up.
    w.liftLinks(params, dvui.secondsSinceLastFrame()) catch {};
    // Ask for the next frame while anything in the world is still moving.
    //
    // `w.settled` alone is not enough: it is read by the *host's* `needsContinuousRepaint` poll,
    // while dvui decides independently whether to sleep, and a sleeping dvui stops delivering
    // frames mid-animation. The reach then froze part-way and only finished when an input event
    // happened to wake the loop — at which point the accumulated `secondsSinceLastFrame` snapped it
    // to the end. Every other animation here already does this (see `applyMorph`); the per-link
    // reach was the one that did not.
    if (!w.settled) dvui.refresh(null, @src(), null);
    frame_profile.world_lift_ns = profLap(prof);
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
            .dashed = node.is_sun,
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

/// The radius a mark is actually drawn at, on screen, this frame.
///
/// `world` reports a flat size for every mark because it is headless: it knows nothing about which
/// note is open or where the cursor is. A note's disc, though, rests larger when it is open and
/// swells further under the pointer, so for anything that resolved to its own note the panel's
/// size is the real one and `Mark.r` is only a floor.
///
/// Anything positioning itself *against* a disc has to ask this rather than read `Mark.r`, or it
/// places itself against a circle that is not the one on screen. The open-note labels did exactly
/// that and sat inside their own discs, which is the size difference between `base_screen_r` and
/// `open_screen_r` plus the whole proximity swell.
fn markDrawnRadius(p: *Panel, m: world_mod.Mark, zoom_t: f32, gap_px: f32) f32 {
    if (m.is_note and m.note < p.nodes.len) return bubbleScreenRadius(p.nodes[m.note], zoom_t, gap_px);
    return m.r;
}

/// A note is drawn at exactly the radius `updateLabels` reserves for it and hover hit-tests
/// against. `world` reports a flat note size because it is headless and knows nothing about
/// hover or open tabs; the panel does, so the panel decides. Keeping those in sync is what lets
/// the placer find real gaps — reserving one size and drawing another had it dodging discs that
/// were not there — and it restores the proximity swell, so a note grows under the cursor and
/// carries that size into the interior as a dashed ring.
fn overviewMarkStyle(ctx: *anyopaque, w: *const world_mod.World, m: world_mod.Mark, holds_open: bool) world_draw.MarkStyle {
    const p: *Panel = @ptrCast(@alignCast(ctx));
    _ = w;
    const theme = dvui.themeGet();
    const border_rest = theme.color(.window, .text);
    const hot = theme.color(.highlight, .fill);
    const zoom_t = @max(detailRevealT(p.layout_slot, p.camera.zoom), 1);
    const gap_px = p.layout_slot * p.camera.zoom;
    const radius_px: f32 = markDrawnRadius(p, m, zoom_t, gap_px);
    // The rim is reserved for *open*, and hover does not touch it.
    //
    // A dashed mark is always highlight-rimmed, which is what makes dashed mean "this one" rather
    // than just "this one is drawn differently". Lighting the rim on hover as well blurred that:
    // half the notes the cursor passed wore a partly-highlighted outline, so a highlighted rim
    // stopped being a reliable sign of anything. Hover says what it needs to say through the fill,
    // which is the larger surface and the one that reads at a glance anyway.
    const border = if (holds_open or (m.is_note and m.note < p.nodes.len and p.nodes[m.note].open))
        hot
    else
        border_rest;

    // The dashed clearing, and the request to be painted last.
    // Dashed means *open*, and nothing else.
    //
    // It is the one shape the reader carries across a zoom: an open note is a dashed rim out here,
    // and the sun at the centre of its interior is a dashed rim too, so diving in continues
    // something rather than cutting to something new. Spending it on hover as well spent the
    // meaning — every note the cursor passed became dashed, so dashed stopped saying "this is the
    // one you are in".
    const is_dashed = m.is_note and m.note < p.nodes.len and p.nodes[m.note].open;

    // Same face as a resting note. Masses used to fill with window text mixed toward the
    // background, so a merge was notes fading to "nothing" against a disc of a different colour.
    // A hovered note still walks to this rest fill as it is absorbed — see `m.alpha`.
    const rest = noteRestFill(theme);
    const fill: dvui.Color = if (m.is_note and m.note < p.nodes.len) blk: {
        const own = nodeFill(theme, p.nodes[m.note]);
        break :blk galaxy.joinFill(own, rest, m.alpha);
    } else rest;

    return .{
        .fill = fill,

        .border = border,
        .r_px = if (m.is_note) radius_px else radius_px * massProximitySwell(p, m),
        .is_note = m.is_note,
        .dashed = is_dashed,
    };
}

/// Proximity swell for a coalesced mass, by screen distance from the cursor.
///
/// Notes get this from `applyProximity`, which walks `p.nodes` — masses are not notes, so at
/// coalesced zoom (most of a large vault, most of the time) nothing on screen responded to the
/// mouse at all and the view felt inert exactly where it is densest.
///
/// Computed at draw time from the cursor rather than eased through stored state like `hover_t`:
/// a note's swell also drives the neighbour shove and label placement, so it has to be a settled
/// value those passes can read, but this is purely visual. Cursor movement is continuous and
/// dvui repaints on it, so a pure function of distance already reads as smooth — and it costs no
/// per-mass state, which matters when the whole point is that there are a lot of them.
fn massProximitySwell(p: *const Panel, m: world_mod.Mark) f32 {
    const mouse = dvui.currentWindow().mouse_pt;
    if (!p.camera.viewport.contains(mouse)) return 1;
    const c = p.camera.worldToScreen(.{ .x = m.wx, .y = m.wy });
    const dx = c.x - mouse.x;
    const dy = c.y - mouse.y;
    const d = @sqrt(dx * dx + dy * dy);
    // Reach from the mass's own rim, not its centre: a big mass should respond when the cursor
    // approaches the shape you can see, not only when it nears a point buried inside it.
    const t = std.math.clamp(1.0 - @max(d - m.r, 0) / (proximity_falloff_px * dpiScale()), 0, 1);
    if (t <= 0.001) return 1;
    return 1 + cluster_grow_factor * dvui.easing.outBack(t);
}

fn overviewHoldsOpen(ctx: *anyopaque, w: *const world_mod.World, m: world_mod.Mark) bool {
    const p: *Panel = @ptrCast(@alignCast(ctx));
    return worldMarkHoldsOpen(p, w, m);
}

fn drawWorldMarks(p: *Panel, fade: f32) void {
    const w = if (p.world_state) |*ws| ws else return;
    const dens = p.ensureDensity() orelse return;
    const stats = world_draw.draw(w, &p.camera, dens, fade, .{
        .ctx = p,
        .toWorld = identityToWorld,
        .style = overviewMarkStyle,
        .holdsOpen = overviewHoldsOpen,
    });
    frame_profile.nodes_drawn += stats.notes_drawn;
    frame_profile.clusters_drawn += stats.clusters_drawn;
}

/// Packed identity for the mass-ring dwell: a note index, or a coalesced cell with the high bit.
/// Publish the world's leaf poses back onto `p.nodes`, and mark which notes are drawn as
/// themselves this frame.
///
/// Labels, hover, hit-testing and the click-to-open path all read `node.pos` / `at_level0` and
/// know nothing about which layout produced them. Writing back is what makes them work in
/// containment mode instead of pointing at wherever the classic layout happened to leave the note
/// — which is why labels first appeared scattered across the field while the marks sat in a
/// cluster at the centre.
fn syncNodesFromWorld(p: *Panel, w: *const world_mod.World) void {
    // Clear only what *this function* lit last frame, which `p.visible` is the exact record of.
    //
    // The whole-vault versions of these two lines (`@memset(p.at_level0, false)` and
    // `for (p.nodes) |*n| n.alpha = 0`) were the single largest per-frame cost in the panel at
    // scale: `GraphNode` is 160 bytes, so zeroing one `f32` field per node walked 160 MB at a
    // million notes — 3.7 ms a frame, every frame, to clear at most a few hundred non-zero values.
    // Nothing else writes an overview node's `alpha` (the rebuild seeds it, this sets it from a
    // mark), so last frame's visible list covers every node that can be non-zero.
    const clear_at_level0 = p.at_level0.len == p.nodes.len;
    for (p.visible.items) |v| {
        if (v.level != 0 or v.index >= p.nodes.len) continue;
        p.nodes[v.index].alpha = 0;
        if (clear_at_level0) p.at_level0[v.index] = false;
    }
    // A rebuild reallocates `at_level0` (arena) without clearing it, and swapping vaults leaves
    // stale trues that no visible entry names. Pay the memset once, on the frame the array is new.
    if (clear_at_level0 and p.at_level0_epoch != p.layout_epoch) {
        @memset(p.at_level0, false);
        p.at_level0_epoch = p.layout_epoch;
    }

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
    const i = w.markIndex(cell) orelse return null;
    const m = w.marks.items[i];
    return .{ .x = m.wx, .y = m.wy };
}

/// Collect the cells covering an open document, once per frame.
///
/// The question the draw asks is "does this mark cover an open note", and it asks it of every mark.
/// Answering it per mark meant walking that cell's whole note range — and the marks partition what
/// is on screen, so at overview the sum of those ranges *is* the vault: 300,000 reads at a 160-byte
/// stride, every frame, to find the two or three notes that are actually open.
///
/// Asked from the other end it is trivial. A cell covers an open note exactly when it is an
/// ancestor of that note's leaf, so the answer set is the union of the open notes' ancestor chains
/// — a handful of tabs times the ladder's seven levels. Identical answers, and the cost is now a
/// property of how many documents are open rather than of how large the vault is.
fn updateHoldsOpen(p: *Panel, w: *const world_mod.World) void {
    p.holds_open.clearRetainingCapacity();
    for (p.open_notes.items) |gi| {
        if (gi >= w.lad.leaf_cell.len) continue;
        var c = w.lad.leaf_cell[gi];
        var guard: u8 = 0;
        while (c != fold.invalid and c < w.lad.cells.len and guard < 64) : (guard += 1) {
            const gop = p.holds_open.getOrPut(sdk.allocator(), c) catch break;
            // Another open note already claimed this cell, so it claimed everything above it too.
            if (gop.found_existing) break;
            c = w.lad.cells[c].parent;
        }
    }
}

/// True when this mark covers at least one open document, at any level — so a coalesced mass
/// holding an open note reads as highlight before it has split out as a leaf.
fn worldMarkHoldsOpen(p: *const Panel, w: *const world_mod.World, m: world_mod.Mark) bool {
    _ = w;
    return p.holds_open.contains(m.cell);
}

fn frameCluster(p: *Panel, target: Visible) void {
    if (target.level == 0) return;
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
    // `.free`, not `.extents`. Framing is what the camera is *holding onto*, and after this it
    // is holding a cluster — but `.extents` means "the whole vault", so the next thing to call
    // `applyFraming` (a pane resize, a rebuild) re-fits to the entire graph and throws the
    // cluster away. That reads as "clicking a mass zooms out", which is the opposite of what
    // the click asked for.
    p.framing = .free;
    p.camera.retarget(pose);
    p.camera.user_driving = false;
    // Input is handled at the *end* of the frame, after the host has already asked whether
    // more frames are wanted — so setting a camera target here is invisible until some other
    // event wakes the app. Ask explicitly.
    dvui.refresh(null, @src(), dvui.parentGet().data().id);
}

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
    /// This cloud's set of nodes with a non-zero `label_vis` — read and rewritten here. See
    /// `Panel.label_live`.
    live: *std.ArrayListUnmanaged(u32),
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

    // Which nodes the placer found room for, as a list rather than one bool per note in the vault.
    // The allocation and its memset were themselves whole-vault work on every frame of a pan.
    label_epoch +%= 1;
    const epoch = label_epoch;
    var placed_now: std.ArrayList(u32) = .empty;
    placed_now.ensureTotalCapacity(arena, max_labels) catch {};
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
    // Cell -> world position for this frame's marks, so resolving a link's two endpoints is two
    // lookups rather than two scans of the mark list. `markWorldPos` is linear, and at the
    // 4000-mark budget the slider allows that came to ~80 million comparisons a frame — a cost
    // that grows with the *budget*, so raising it to see more punished you quadratically.
    // The lookup is `World.markIndex`, the same dense stamped array `world_draw.zig` reads; this
    // used to be a second `AutoHashMapUnmanaged` built from the same mark list every frame.
    var seg_n: usize = 0;
    for (0..seg_cap) |i| {
        var wa: dvui.Point = undefined;
        var wb: dvui.Point = undefined;
        if (containment_links) |cl| {
            const w = &p.world_state.?;
            const ia = w.markIndex(cl[i].a) orelse continue;
            const ib = w.markIndex(cl[i].b) orelse continue;
            const ma = w.marks.items[ia];
            const mb = w.marks.items[ib];
            wa = .{ .x = ma.wx, .y = ma.wy };
            wb = .{ .x = mb.wx, .y = mb.wy };
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
    // Index them once rather than have every candidate slot walk the whole web. At the coalesce
    // boundary this is twenty thousand segments against a couple of hundred candidates and their
    // slots — the placer's own collision test was the largest single cost of a panning frame.
    // Below a few hundred segments the linear walk is the cheaper answer and the index is skipped.
    if (seg_n > 256) placer.seg_grid = labels.SegGrid.build(arena, vp, placer.segs);

    // Diagnostic for "notes resolve but carry no names". Throttled to once a second: the three
    // things that can each independently produce no label are an empty candidate list, titles that
    // are empty strings, and a placer that finds room for nobody — and from the outside all three
    // look identical.
    if (label_debug) {
        const now_s = @as(f64, @floatFromInt(std.Io.Clock.boot.now(dvui.io).nanoseconds)) / 1e9;
        if (now_s - label_debug_last > 1.0) {
            label_debug_last = now_s;
            var titled: usize = 0;
            var first_title: []const u8 = "";
            var dit = NodeIter.init(nodes, selection);
            while (dit.next()) |st| {
                const t = nodes[st.index].title;
                if (t.len > 0) {
                    titled += 1;
                    if (first_title.len == 0) first_title = t;
                }
            }
            dvui.log.info(
                "atlas labels: {d} candidates, {d} with a title, first=\"{s}\", zoom_t {d:.2}, segs {d}",
                .{ if (selection) |sel| sel.len else nodes.len, titled, first_title, zoom_t, seg_n },
            );
        }
    }

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
        n.label_epoch = epoch;
        placed_now.append(arena, @intCast(i)) catch {};
        placed += 1;
    }

    // Fade in what was just placed, fade out only what was showing a moment ago, and leave the
    // rest of the vault alone — nothing else can hold a non-zero `label_vis`, because this is the
    // only code that ever raises one.
    var unsettled = false;
    var next: std.ArrayList(u32) = .empty;
    next.ensureTotalCapacity(arena, placed_now.items.len + live.items.len) catch {};
    for (placed_now.items) |i| {
        const n = &nodes[i];
        n.label_vis += (1 - n.label_vis) * t_chase;
        if (@abs(n.label_vis - 1) > 0.004) unsettled = true;
        next.append(arena, i) catch {};
    }
    for (live.items) |i| {
        if (i >= nodes.len) continue;
        const n = &nodes[i];
        if (n.label_epoch == epoch) continue; // placed above, already stepped
        n.label_vis += (0 - n.label_vis) * t_chase;
        if (@abs(n.label_vis) > 0.004) {
            unsettled = true;
            next.append(arena, i) catch {};
        } else {
            // Snap the last sliver so the node leaves the tracked set instead of decaying
            // forever below the threshold anything draws at.
            n.label_vis = 0;
        }
    }
    live.clearRetainingCapacity();
    live.appendSlice(sdk.allocator(), next.items) catch {};
    p.labels_settled = !unsettled;
    if (unsettled) dvui.refresh(null, @src(), dvui.parentGet().data().id);
}

fn drawLabels(p: *Panel) void {
    if (p.interior.t >= 0.5) {
        // Same floor the overview uses below, and for the same reason: the interior draws every
        // item it holds, so legibility is already decided — re-deriving it from a zoom heuristic
        // multiplies the placer's work by a near-zero reveal and throws the label away.
        const zoom_t = @max(detailRevealT(p.interior.slot, p.camera.zoom), @as(f32, 1));
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
        // Open notes are skipped here and drawn by `drawOpenNoteLabels` below, which uses its own
        // styling and does not depend on the placer having found them a slot. Without this they get
        // both — the placed one and the plated one, on top of each other.
        for (p.visible.items) |v| {
            if (v.index >= p.nodes.len) continue;
            if (p.hover_node == v.index) continue; // `drawHoverLabel` owns this one
            // *Every* open note, not just the focused one. Skipping only the focus left every
            // other open tab with two names: the placer's, in the ambient weight and unplated,
            // sitting just above the plated one `drawOpenNoteLabels` draws.
            if (p.nodes[v.index].open) continue;
            drawLabel(p.nodes[v.index], zoom_t, fade);
        }
        drawOpenNoteLabels(p, fade);
        drawHoverLabel(p, fade);
    }
}

/// Draw a name on a rounded plate, both easing in together.
///
/// Only the two unconditional labels get one — the focused note's and the hovered note's. They are
/// drawn wherever the note happens to be rather than wherever the placer found a gap, so they land
/// on that note's own links as often as not, and a hub's starburst is not a translucency problem
/// that can be tuned away: dozens of lines overlap near the note and `1 - (1 - a)^n` reaches 1.000
/// by about twenty-five of them whatever `a` is. Thinning the lines takes the composite under the
/// text from 1.000 to 0.999.
///
/// The ambient labels still get nothing, and the reason they were refused a plate stands — a chip
/// behind every name blots out the web it is describing. Two of them is a different proposition:
/// the reader is looking at exactly these, and everywhere else the web is untouched.
///
/// `t` drives both the sweep and the fade, so the plate opens from its own centre as the text
/// arrives rather than snapping in at full width.
fn renderTextPlated(
    font: dvui.Font,
    text: []const u8,
    /// Centre of the disc this name belongs to, in physical pixels.
    anchor: dvui.Point.Physical,
    /// That disc's radius *as drawn* — see `markDrawnRadius`.
    radius_px: f32,
    /// Where the label is allowed to go; a name that would leave it flips to the other side.
    bounds: dvui.Rect.Physical,
    scale: f32,
    col: dvui.Color,
    plate: dvui.Color,
    t: f32,
) void {
    const eased = dvui.easing.outCubic(std.math.clamp(t, 0, 1));
    if (eased <= 0.004) return;

    // `Font.textSize` reports *logical* pixels and the glyphs are drawn at `scale`, so the extent
    // on screen is the product. Both callers used to pass the logical size straight through as
    // physical, which centred every one of these names half a text-width off on any display with a
    // scale above 1 — and sized the plate to a quarter of the area it was supposed to back.
    const size = font.textSize(text);
    const tw = size.w * scale;
    const th = size.h * scale;

    const s = dpiScale();
    const h = th + label_plate_pad_y * s * 2;
    const w = (tw + label_plate_pad_x * s * 2) * eased;

    // Above by preference, below only when there is no room.
    //
    // A name under a disc sits on whatever the disc is sitting on — in a dense field that is the
    // next row of notes and the links running between them. Above, the name is far more often
    // against empty sky, and the eye reads a title over a marker the way a caption sits over a
    // point on a map. The flip is a fallback for notes near the top edge, not the normal case, so
    // the label stays on one side for the whole time a note is hovered unless the view moves.
    //
    // `label_gap_px` is the gap to the *plate*, which is what is visible; the text sits
    // `label_plate_pad_y` further in on each side.
    const clear = radius_px + label_gap_px * s;
    const above_plate_y = anchor.y - clear - h;
    const fits_above = above_plate_y >= bounds.y;
    const plate_y = if (fits_above) above_plate_y else anchor.y + clear;

    const r: dvui.Rect.Physical = .{
        .x = anchor.x - tw * 0.5,
        .y = plate_y + label_plate_pad_y * s,
        .w = tw,
        .h = th,
    };
    const box: dvui.Rect.Physical = .{
        .x = anchor.x - w * 0.5,
        .y = plate_y,
        .w = w,
        .h = h,
    };
    box.fill(.all(h * 0.5), .{ .color = plate.opacity(eased), .fade = 1 });

    dvui.renderText(.{
        .font = font,
        .text = text,
        .rs = .{ .r = r, .s = scale },
        .color = col.opacity(eased),
    }) catch {};
}

/// The hovered note's name, drawn last and unconditionally, just outside its halo.
///
/// Not routed through the placer like every other label. The placer decides which names fit, which
/// is right for the ambient field and wrong for this one: whether the reader can read the name of
/// the thing under their cursor must not depend on how crowded that part of the vault is, and at
/// any zoom where names are being suppressed it is the only way to tell what a click would open.
///
/// In the highlight colour, like everything else the reader is being pointed at. This was the
/// ordinary text colour for one revision, because at the time the hovered disc went *fully* to the
/// highlight and the name sat on top of it, which is the one combination that cannot be read. The
/// disc only mixes part of the way now and the ring puts the name outside it either way, so the
/// original reason is gone.
fn drawHoverLabel(p: *Panel, fade: f32) void {
    if (fade <= 0.02) return;
    const i = p.hover_node orelse return;
    if (i >= p.nodes.len) return;
    if (p.at_level0.len != p.nodes.len or !p.at_level0[i]) return;
    // The focused note already has its own unconditional name; two would sit on each other.
    if (focusNodeIndex(p)) |oi| {
        if (oi == i) return;
    }
    const n = p.nodes[i];
    if (n.title.len == 0) return;

    const zoom_t = @max(detailRevealT(p.layout_slot, p.camera.zoom), @as(f32, 1));
    const gap_px = p.layout_slot * p.camera.zoom;
    const r = bubbleScreenRadius(n, zoom_t, gap_px);

    const cw = dvui.currentWindow();
    const font = dvui.Font.theme(.body).larger(label_font_delta).withWeight(.bold);
    const centre = p.camera.worldToScreen(n.pos);
    const theme = dvui.themeGet();
    renderTextPlated(
        font,
        n.title,
        .{ .x = centre.x, .y = centre.y },
        r,
        p.camera.viewport,
        cw.natural_scale,
        theme.color(.highlight, .fill).opacity(fade),
        theme.color(.window, .fill).opacity(label_plate_opacity * fade),
        // The plate opens on the same channel the fill lights on, so approaching a note and its
        // name arriving are one motion.
        n.pointer_t,
    );
}

/// The focused document's name, drawn last and unconditionally.
///
/// Everything else on this pass is a note the LOD resolved *this frame*, positioned by the placer.
/// The focused document has to escape both of those rules: it is the one thing the reader is
/// definitely looking for, and when it is inside a coalesced mass there is no leaf mark to hang a
/// name on and no placer run to have chosen a slot. So it is drawn at the mark that currently
/// stands in for it — the note itself when resolved, otherwise the mass containing it — in the
/// highlight colour, on top of everything.
///
/// The name and the position must come from the *same* note, which is the whole reason this reads
/// `focusNodeIndex`. It used to take the title from `open_notes[0]` — tab order — while placing it
/// at the mark standing in for `focus_cut`, the focused note. With one tab open those are the same
/// note and it looked right; with two, the graph drew the first tab's title on top of the note you
/// had just selected, and skipped that first tab's own label at its own position. The focused note
/// then carried two names: its placed one and the wrong highlighted one.
/// Every open document's name, drawn last and unconditionally, one treatment for all of them.
///
/// The focused note used to be the only one that got this — bold, plated, always drawn — while
/// every other open tab went through the placer with the rest of the vault. That gave them a
/// different weight, no plate, and no guarantee of being drawn at all, so a note being *open* looked
/// like several different things depending on which one the workbench happened to consider active.
/// Open is one state and it gets one presentation: highlight-rimmed dashed mark out here, and a
/// bold highlight name on a plate underneath it.
///
/// Positioned at whatever mark currently stands in for the note — its own if the LOD resolved it,
/// otherwise the nearest drawn ancestor — so the name follows the thing it is naming all the way
/// out to full coalescence instead of vanishing when the note stops being its own mark.
fn drawOpenNoteLabels(p: *Panel, fade: f32) void {
    if (fade <= 0.02) return;
    const w = if (p.world_state) |*ws| ws else return;
    const cw = dvui.currentWindow();
    const theme = dvui.themeGet();
    // A step larger and bold, against the ambient labels' `label_font_delta`. These names have to
    // be findable at a glance in a field of hundreds, and highlight colour alone was not carrying
    // it — the hue reads as emphasis only once the glyphs are heavy enough to hold it.
    const font = dvui.Font.theme(.body).larger(label_font_delta + 1).withWeight(.bold);

    const focus_idx = focusNodeIndex(p);
    var drawn_focus = false;
    for (p.open_notes.items) |gi| {
        if (gi >= p.nodes.len) continue;
        if (focus_idx) |fi| {
            if (fi == gi) drawn_focus = true;
        }
        drawOneOpenLabel(p, w, gi, font, theme, cw.natural_scale, fade);
    }
    // `focus_leaf` is not required to appear in the open set — a caller may set only the focus, and
    // the note being read is exactly the one that must never be missing a name.
    if (!drawn_focus) {
        if (focus_idx) |fi| drawOneOpenLabel(p, w, fi, font, theme, cw.natural_scale, fade);
    }
}

fn drawOneOpenLabel(
    p: *Panel,
    w: *const world_mod.World,
    gi: u32,
    font: dvui.Font,
    theme: dvui.Theme,
    scale: f32,
    fade: f32,
) void {
    const n = p.nodes[gi];
    if (n.title.len == 0) return;
    if (gi >= w.lad.leaf_cell.len) return;

    // The deepest drawn ancestor of this note's leaf — what the reader is currently looking at in
    // its place. Walks the ladder rather than asking the cut, so it answers with what is actually
    // on screen this frame, including mid-crossfade.
    var cell = w.lad.leaf_cell[gi];
    var guard: u8 = 0;
    const found: ?u32 = while (cell != fold.invalid and guard < 64) : (guard += 1) {
        if (w.markIndex(cell)) |mi| break mi;
        if (cell >= w.lad.cells.len) break null;
        cell = w.lad.cells[cell].parent;
    } else null;
    const mi = found orelse return;

    const m = w.marks.items[mi];
    const centre = p.camera.worldToScreen(.{ .x = m.wx, .y = m.wy });
    const zoom_t = @max(detailRevealT(p.layout_slot, p.camera.zoom), @as(f32, 1));
    const r = markDrawnRadius(p, m, zoom_t, p.layout_slot * p.camera.zoom);
    renderTextPlated(
        font,
        n.title,
        .{ .x = centre.x, .y = centre.y },
        r,
        p.camera.viewport,
        scale,
        theme.color(.highlight, .fill).opacity(fade),
        theme.color(.window, .fill).opacity(label_plate_opacity * fade),
        1,
    );
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

    // An open document's name is highlighted, like its disc.
    //
    // The panel has one colour for "this one matters to you right now" — the focused note's links,
    // its name, the ring under the cursor — and a note you have open belongs in that set. Leaving
    // its name the same grey as the thousand notes around it makes the reader hunt for the tab they
    // already have open. The hovered note's name is not handled here at all; `drawHoverLabel` draws
    // it without going through the placer.
    const base = if (n.open)
        theme.color(.highlight, .fill)
    else
        theme.color(.content, .text);
    dvui.renderText(.{
        .font = dvui.Font.theme(.body).larger(label_font_delta),
        .text = text,
        .color = base.opacity(0.95 * alpha),
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
    // `gap_px` comes from the camera and is already physical, so the tuned sizes join it there.
    const s = dpiScale();
    const cap = (if (n.is_sun) max_sun_screen_r else max_node_screen_r) * s;
    const want = @min(base * s * (1.0 + zoom_boost + hover_boost), cap);
    // Hovered and open notes keep a floor: they are the ones the reader is deliberately tracking,
    // and losing them into the crowd is worse than a little overlap.
    const floor: f32 = @as(f32, if (n.is_sun or n.open or n.hover_t > 0.5) 3.0 else 0.6) * s;
    return @max(@min(want, gap_px * gap_radius_frac), floor);
}

/// The disc colour notes and coalesced masses share at rest.
///
/// A mass used to fill with window-text mixed into the background, while a note sat on a
/// slightly lifted control fill — close enough to the window that a merge looked like notes
/// dissolving into nothing against a tinted blob. One colour, and the dashed ring is what
/// says "this one is many".
fn noteRestFill(theme: dvui.Theme) dvui.Color {
    const base = theme.color(.control, .fill);
    return base.lighten(if (theme.dark) 6 else -6);
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
        galaxy.intoBg(base, theme.color(.window, .fill), 0.4)
    else
        noteRestFill(theme);

    const lit = n.pointer_t;
    if (lit <= 0.002) return rest;
    // The highlight colour, not a lifted control fill.
    //
    // A `fill` → `fill_hover` step is the right feedback for a button in a row of buttons, where
    // position already says which one you are on. In a field of thousands of near-identical discs
    // it says almost nothing: the lift is a few percent of luminance against neighbours that are
    // already every shade the proximity swell makes them. The highlight is the colour this panel
    // already uses to mean "this is the one" — the focused note's links, the focused note's name —
    // so hover joins that vocabulary instead of inventing a quieter one.
    const target = theme.color(.highlight, .fill);
    // Phantoms stay mixed toward the background; keep that while still letting them light up.
    const to = if (n.phantom) galaxy.intoBg(target, theme.color(.window, .fill), 0.55) else target;
    // Part way, not all the way.
    //
    // Going fully to the highlight makes the disc the same colour as the things that mean
    // "selected" — including its own label, which then becomes unreadable sitting on top of it.
    // Mixed, the node still clearly lifts out of the field while staying a node rather than
    // turning into a solid chip of accent.
    return rest.lerp(to, hover_fill_mix * dvui.easing.outQuad(std.math.clamp(lit, 0, 1)));
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

    if (btn.clicked()) zoomExtentsFor(p);
}

fn profNow() i96 {
    return std.Io.Clock.boot.now(dvui.io).nanoseconds;
}

/// Nanoseconds since `mark`, and advance it.
///
/// These used to compile out unless `debug_hud` was set, which is why the single most expensive
/// thing the panel does per frame — `stepWorld`, and the whole-vault walks around it — went
/// unmeasured for so long: the region between `rebuild_ns` and `bubbles_ns` was discarded with a
/// bare `_ = profLap(&prof)`, so the HUD's "us total" could report a healthy frame while most of
/// the frame was spent outside every bucket. A clock read is ~20ns and there are a dozen per
/// frame; that is not worth being unable to see the hot path.
fn profLap(mark: *i96) u64 {
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
    // Only what is on screen. Walking all 286,546 nodes every frame for a diagnostic readout is
    // itself a real part of the sluggishness the diagnostic exists to explain.
    for (p.visible.items) |v| {
        if (v.index >= p.nodes.len) continue;
        const n = p.nodes[v.index];
        min_x = @min(min_x, n.target.x);
        min_y = @min(min_y, n.target.y);
        max_x = @max(max_x, n.target.x);
        max_y = @max(max_y, n.target.y);
    }
    const span = if (p.nodes.len > 1 and max_y > min_y)
        (max_x - min_x) / @max(max_y - min_y, 1)
    else
        0;

    // Exactly what `wantsRepaint` reads, in the same order — when the app won't sleep, this line
    // names the reason instead of leaving it to be guessed at.
    const awake = std.fmt.allocPrint(cw.arena(), "{s}{s}{s}{s}{s}{s}{s}{s}{s}{s}{s}", .{
        if (p.job != null) "job " else "",
        if (p.fling_x.coasting or p.fling_y.coasting) "fling " else "",
        if (p.drag_active) "drag " else "",
        if (p.gesture_active) "gesture " else "",
        if (!p.proximity_settled) "proximity " else "",
        if (!p.layout_settled) "layout " else "",
        if (!p.pointer_settled) "pointer " else "",
        if (!p.labels_settled) "labels " else "",
        if (p.camera.chasing()) "camera " else "",
        if (p.rebuild_waiting) "rebuild " else "",
        if (if (p.world_state) |*w| !w.settled else false) "world " else "",
    }) catch "?";

    const fp = frame_profile;
    const rs = cw.renderStats();
    const us = struct {
        fn f(ns: u64) f64 {
            return @as(f64, @floatFromInt(ns)) / 1000.0;
        }
    }.f;

    const shape = std.fmt.allocPrint(
        cw.arena(),
        "pane {d:.0}x{d:.0}  raw {d:.2}  smooth {d:.2}  aspect {d:.2}\n" ++
            "nodes {d}  edges {d}  slot {d:.0}  zoom {d:.3}  span {d:.2}  islands {d}\n" ++
            "framing {s}  interior t {d:.2}\n" ++
            "awake: {s}",
        .{
            vp.w,                             vp.h,
            if (vp.h > 0) vp.w / vp.h else 0, p.aspect_smooth,
            p.layout_aspect,                  p.nodes.len,
            p.edges.len,                      p.layout_slot,
            p.camera.zoom,                    span,
            p.island_count,                   @tagName(p.framing),
            p.interior.t,                     if (awake.len == 0) "(asleep)" else awake,
        },
    ) catch return;

    const perf = std.fmt.allocPrint(
        cw.arena(),
        "visible {d} ({d} notes)  drawn {d} batched + {d} pathed, {d}/{d} links, {d} markers\n" ++
            "marks {d}  world cells {d}  bound {}  panel edges {d}\n" ++
            "gpu {d} calls  {d} tris\n" ++
            "us total {d:.0} | rebuild {d:.0}  misc {d:.0}  bubbles {d:.0}  hover {d:.0}  labels {d:.0}  anim {d:.0}\n" ++
            "   world step {d:.0}  sync {d:.0}  lift {d:.0}\n" ++
            "   edges {d:.0}  nodes {d:.0}  clusters {d:.0}  names {d:.0}",
        .{
            p.visible.items.len,                            p.notes_at_level0,
            fp.nodes_drawn,                                 fp.nodes_pathed,
            fp.edges_drawn,                                 if (p.world_state) |*w| w.links.items.len else 0,
            fp.clusters_drawn,
                // The classic pyramid/tile readouts died with the containment rewrite; what matters
                // now is how many marks the living set holds and whether the budget refused an open.
                                         if (p.world_state) |*w| w.marks.items.len else 0,
            if (p.world_state) |*w| w.lad.cells.len else 0, if (p.world_state) |*w| w.bound else false,
            p.edges.len,                                    rs.draw_calls,
            rs.triangles,                                   us(fp.total()),
            us(fp.rebuild_ns),                              us(fp.misc_ns),
            us(fp.bubbles_ns),                              us(fp.hover_ns),
            us(fp.labels_ns),                               us(fp.edge_anim_ns),
            // The three buckets that were computed every frame and never printed. `world_lift_ns`
            // is the one the `--world --pan` sweep names as the pan-time ceiling, so leaving it
            // out of the only live readout there is meant the hot path could not be seen at all.
            us(fp.world_step_ns),                           us(fp.world_sync_ns),
            us(fp.world_lift_ns),                           us(fp.draw_edges_ns),
            us(fp.draw_nodes_ns),                           us(fp.draw_clusters_ns),
            us(fp.draw_labels_ns),
        },
    ) catch return;

    const text = std.fmt.allocPrint(cw.arena(), "{s}\n{s}", .{ shape, perf }) catch return;

    const scale = cw.natural_scale;
    const rect: dvui.Rect.Physical = .{
        .x = vp.x + 8 * scale,
        .y = vp.y + 8 * scale,
        .w = vp.w - 16 * scale,
        .h = 146 * scale,
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
/// The world-construction half of a rebuild: coarsening and placing the whole vault. Its own
/// message because at 286k notes it is the longest single wait in opening a vault, and it follows
/// a counter that has already reached its total — which reads as a freeze without a label.
fn drawBuildingMapSpinner(note_count: u32) void {
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
        (std.fmt.bufPrint(&buf, "Building map of {d} notes…", .{note_count}) catch "Building map…")
    else
        "Building map…";
    dvui.labelNoFmt(@src(), msg, .{}, .{
        .font = dvui.Font.theme(.body).larger(-1),
        .color_text = dvui.themeGet().color(.content, .text).opacity(0.5),
        .gravity_x = 0.5,
    });
}

fn drawLayoutSpinner(note_count: u32, scan_total: u32, phase: Indexer.Phase) void {
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
    // Name the phase. Resolving links is its own multi-minute stretch on a large vault, and
    // during it the note count is finished and frozen — reporting that as "building notes" is
    // indistinguishable from a hang, which is exactly how it was read.
    const msg = if (phase == .publishing)
        "Preparing graph…"
    else if (phase == .resolving)
        (std.fmt.bufPrint(&buf, "Resolving links… {d} of {d}", .{
            @min(note_count, scan_total), scan_total,
        }) catch "Resolving links…")
        // "x of y" once the pre-pass has a total to count against. Clamped, because the two numbers
        // come from different walks — a file created between them would otherwise read as 5 of 4.
    else if (scan_total > 0)
        (std.fmt.bufPrint(&buf, "Building {d} of {d} notes…", .{
            @min(note_count, scan_total), scan_total,
        }) catch "Building…")
    else if (note_count > 0)
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

fn handleInput(p: *Panel, st: anytype) void {
    const pane = dvui.parentGet().data();
    const rs = pane.rectScale();
    const id = pane.id;
    const scheme = sdk.host().panZoomScheme();

    const suppressed = if (p.dialog_canvas)
        core.dvui.dialogCanvasPointerInputSuppressed()
    else
        core.dvui.canvasPointerInputSuppressed();
    if (suppressed) {
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
        if (!pointerTargetsPanel(p, me.p)) continue;
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
                            // editor to that heading.
                            if (hitTestActive(p, me.p)) |ni| {
                                if (ni < p.interior.nodes.len and p.interior.nodes[ni].is_sun) {
                                    exitInterior(p);
                                } else {
                                    revealInteriorSection(p, st, ni);
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
                                enterInterior(p, st, p.nodes[ni].note_id);
                            } else {
                                focusNode(p, ni);
                            }
                            openNode(p, st, ni, open_side);
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
        const hit_r = bubbleScreenRadius(n, zoom_t, slot * p.camera.zoom) + 6 * dpiScale();
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
fn enterInterior(p: *Panel, st: anytype, note_id: i64) void {
    p.framing = .{ .interior = note_id };
    p.camera.user_driving = false;
    p.interior.note_id = note_id;
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
fn revealInteriorSection(p: *Panel, st: anytype, idx: usize) void {
    if (idx >= p.interior.nodes.len) return;
    const n = p.interior.nodes[idx];
    // Generated notes have no backing file — nothing to reveal.
    if (p.synthetic or n.path.len == 0) return;
    const root = st.vault_root orelse return;
    const wb = sdk.host().getServiceTyped(sdk.services.workbench.Api) orelse return;
    const abs = std.fs.path.join(dvui.currentWindow().arena(), &.{ root, n.path }) catch return;
    _ = wb.revealPosition(abs, n.line, 0, false) catch |err| {
        dvui.log.err("atlas: revealPosition {s}:{d}: {any}", .{ abs, n.line, err });
    };
}

fn openNode(p: *Panel, st: anytype, idx: usize, open_side: bool) void {
    // Generated notes have no backing file. Checked before anything else, and on the panel
    // rather than the node: the simulator's paths look real (they have to — the fold ladder
    // groups on them), so there is nothing about a node itself that says "don't open this."
    if (p.synthetic) return;
    const root = st.vault_root orelse return;
    const n = p.nodes[idx];
    if (n.path.len == 0 and !n.phantom) return;
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
            var rel_buf: [query.max_rel_path]u8 = undefined;
            if (query.vaultRelative(root, path, &rel_buf)) |rel| st.indexer.enqueue(rel);
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

/// Same hit policy as `handleInput`: main pane vs owning dialog subwindow.
fn pointerTargetsPanel(p: *const Panel, pt: dvui.Point.Physical) bool {
    if (!p.dialog_canvas) return pointerTargetsMainPane(pt);
    const cw = dvui.currentWindow();
    const sub = cw.subwindows.current() orelse return false;
    const target = cw.subwindows.windowFor(pt);
    return target == sub.id;
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
    return wantsRepaintFor(&(panel orelse return false));
}

/// The actual "does this panel need another frame" check, parameterized — the real bottom
/// panel's `wantsRepaint` above adds the `drawn_recently` visibility gate (specific to a
/// registered-view panel that might not be drawn at all some frames) and calls this on the
/// module-global `panel`; the vault simulator's window always draws while open, so it has no
/// analogous visibility gate to add and calls this directly on its own `Panel`. Without this,
/// the simulator only ever knew about its *own* background regen job finishing — a note-count
/// change large enough to push the graph's own layout solve onto a worker (`p.job`, above
/// `layout_inline_max`) never got polled to completion, since nothing kept asking for frames
/// once the regen job itself was done and the wrapping `Sim.job` had already gone null.
pub fn wantsRepaintFor(p: *Panel) bool {
    // A solve on a worker publishes nothing the frame loop can wait on, so keep frames coming
    // until it lands — that is also what animates the spinner drawn in its place.
    if (p.job != null) return true;
    return p.fling_x.coasting or p.fling_y.coasting or p.drag_active or p.gesture_active or
        !p.proximity_settled or !p.layout_settled or !p.pointer_settled or
        !p.labels_settled or p.camera.chasing() or p.rebuild_waiting or
        (if (p.world_state) |*w| !w.settled else false) or
        // Keep ticking while a descent is still *arriving*. Gating on `t < 0.98` alone never
        // stops for a note whose interior cannot fill the panel — the zoom ceiling
        // (`fitMaxGapPx`) or a clamped nest can leave the descent topping out below 0.98, and
        // then this clause is true for as long as the note stays open and the app never sleeps
        // again. Progress is the honest test: once the camera has arrived, `t` stops moving,
        // whatever value it arrived at.
        (p.framing == .interior and p.interior.nodes.len > 0 and p.interior.t < 0.98 and
            @abs(p.interior.t - p.interior.t_prev) > 0.0005);
}
