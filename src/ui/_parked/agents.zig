//! PARKED — retired pyramid agent field. Organic overview uses `quadlod` + `quad_agents`
//! (Stable v1). Not wired into graph/harness; not in default `zig build test`.
//! See docs/design/organic-lod.md (Rejected).
//!
//! Interactive coalesced mass LOD — budgeted keep-alive agents over the pyramid.
//!
//! Organic level of detail: the pyramid's merges, drawn as bubbles that join and split.
//!
//! `lod.zig` answers what the view should be made of — which regions merge into which, where a
//! cloud's mass sits, how much a frame can afford. It does not answer how the reader *sees* a
//! merge happen. Drawing `select`'s output directly gives a cross-fade: parent and children both
//! on screen, alpha-blended, at layout positions that never move toward each other. The eye reads
//! that as a cut between two pictures, not as matter joining.
//!
//! This file keeps the pyramid as topology and puts a layer of presentation in front of it. One
//! *agent* is one thing the reader can see and click. Agents are allowed to be between states:
//! part-way through a merge a group's children are still the things drawn, huddled toward their
//! parent's centre and grown until they overlap into one mass, and only once they are effectively
//! coincident does the parent take over. Zooming in runs the same thing backwards — the parent
//! retires and its children spring outward from where it stood.
//!
//! Three properties are load-bearing, and each one is a departure from the cross-fade:
//!
//!   • *One set of marks, never two.* A group in transition draws its children and not its parent.
//!     Alpha is not how a handoff is expressed here; position and radius are. This is also cheaper
//!     than the cross-fade it replaces, which drew both levels at once through the whole band.
//!
//!   • *Continuity through the swap.* Children commit to a parent only when they have converged on
//!     the parent's own position and radius, so the frame where the swap happens looks identical
//!     either side of it. That is what lets the swap be instant and invisible instead of faded.
//!
//!   • *A bound on what exists.* `emit` never returns more agents than its budget, because a group
//!     that would push past it simply stays closed — coarser, which is exactly the right way to
//!     degrade. The guarantee `lod.Pyramid.levelFor` makes about drawn things per frame survives
//!     the animation layer rather than being negotiated away by it.
//!
//! The camera never waits on any of this. Targets are recomputed every frame from the zoom, and
//! agents chase them with springs; a fast wheel spin moves the targets faster than the springs
//! converge and the picture catches up a moment later, which is the intended read.

const std = @import("std");
const dvui = @import("dvui");
const lod = @import("../lod.zig");

/// Identifies a cluster in the pyramid, and so an agent: a note when `level` is 0, otherwise a
/// merged region. Stable across frames, which is what lets an agent persist and be animated.
pub const Key = struct {
    level: u32,
    index: u32,
};

/// Where a group belongs at this zoom, as a threshold on `lod.Pyramid.splitT`, with a gap between
/// the two directions so a camera parked on the boundary cannot flip it every frame.
///
/// A near-step, deliberately, and this is the one place the design in `docs/design/organic-lod.md`
/// turned out to be wrong. It made merge progress a smooth function of zoom, reusing the cross-fade
/// band `splitT` already eases over. But that band is most of a level wide, so at any fixed zoom a
/// large share of the boundary groups sit permanently part-merged — children huddled at a centroid
/// forever, eight discs drawn where one would do, and the web refined a level deeper than it needs
/// to be. Measured against `select` at overview on a 50k vault that was 2408 marks and 28k links
/// against 311 and 1.7k: the animation layer had quietly bought back the cost the hierarchy exists
/// to avoid.
///
/// Progress is a function of *time* instead — see `merge_seconds`. Zoom decides which side of a
/// sharp line a group is on; the clock carries it across. So the count of part-merged groups is
/// bounded by how many crossed the line recently rather than by how wide the band is, and at rest
/// it is zero: every group is decisively open or closed and the frame costs what `select` costs.
/// Base hysteresis on `splitT` for a singleton-scale group. Larger masses shift these down via
/// `openThresholds` so they resist absorbing their children — zoom-out becomes a cloud of several
/// medium discs, not one slightly-bigger hub.
const open_enter: f32 = 0.62;
const open_keep: f32 = 0.42;
/// How far mass shifts the band (log2 count 0…8 → 0…1). Heavy groups stay open longer.
const open_mass_shift: f32 = 0.28;
const open_band: f32 = 0.18;

/// Seconds a group takes to gather into its parent, or to spread back out of it. The whole read —
/// bubbles closing, swelling, committing — happens in this window, so it wants to be long enough
/// to see and short enough that a zoom does not feel like it is dragging something behind it.
const merge_seconds: f32 = 0.42;

/// How far a group must have finished opening before the web refines into it. See
/// `Binding.isOpen` — the coarse web is held until the children have nearly arrived.
const link_open_t: f32 = 0.15;

/// Groups that may *open* in one frame. Natural zoom-driven closes are never rate-limited —
/// holding children open while the viewport expands (fast zoom-out) is what blew the budget into
/// a single mega-hub. Budget closes are also instant. Refine stays granular via this cap +
/// `merge_seconds`.
const opens_per_frame: usize = 32;
/// Slack below `budget` required before a *new* open is allowed. Already-open groups may sit in
/// this band; only the hard ceiling forces closes.
const open_slack: usize = 64;
/// After a hard budget close, briefly refuse *all* new opens (burst brake). Topology freeze +
/// lf-only locks are what stop parked-camera flip-flop once this expires.
const budget_cooloff_frames: u32 = 24;
/// `|Δlf|` that counts as an intentional zoom: updates sticky topology lf, clears locks / freeze.
/// Below this, `levelFor` jitter must not re-solve the field. Sticky updates are directional —
/// refine follows immediately past this slop; coarsen needs the same slop *and*
/// `coarsen_confirm_frames` of sustained samples so a single coarser blip mid-dive cannot
/// collapse the field and then explode it when the fine sample returns.
const lock_lf_slop: f32 = 0.12;
/// Frames `cam_lf` must stay coarser than sticky by `lock_lf_slop` before emit thresholds
/// follow the camera (zoom-out merges). Shorter than sticky confirm so merges start promptly
/// without letting a 1–2 frame blip collapse the dive.
const coarsen_emit_frames: u32 = 3;
/// Frames before sticky itself rises / locks clear. Longer than emit so a noisy blip cannot
/// retarget topology settle state.
const coarsen_confirm_frames: u32 = 8;
/// When the zoom wants a group closed, gather this much faster than a normal merge so zoom-out
/// does not linger in a fine-children / coarse-lf state long enough to panic the budget.
const merge_out_scale: f32 = 2.5;

/// Position spring. Frequency is in cycles per second, so convergence takes about the same *time*
/// however far the target is and whatever the zoom — a merge reads at one speed across the whole
/// vault. Damping under 1 leaves the overshoot the design asks for: bubbles arrive, wobble once,
/// and settle.
const pos_freq: f32 = 2.6;
const pos_damping: f32 = 0.62;
/// Radius spring. Faster and nearly critical: a bubble that keeps pulsing after it has arrived
/// reads as a rendering fault rather than as motion.
const r_freq: f32 = 4.2;
const r_damping: f32 = 0.95;

/// Largest step the springs are integrated over. A stalled frame must not launch every agent
/// across the vault; it costs a moment of lag instead, which nobody sees.
const max_dt: f32 = 1.0 / 30.0;

/// Below this, an agent is treated as having arrived and is snapped, so `settled` can go true and
/// the panel can stop repainting. In world units for position — scaled by the caller's zoom on the
/// way in so the test is really "less than a fraction of a pixel".
const settle_px: f32 = 0.15;

/// One drawn, clickable thing, part-way between what it was and what it is becoming.
pub const Agent = struct {
    key: Key,
    /// Animated world position. Chases `target_pos`, which is itself part-way toward the parent
    /// centroid when the group is merging.
    pos: dvui.Point = .{},
    vel: dvui.Point = .{},
    /// Animated screen radius, in pixels. Screen rather than world on purpose — see `markRadiusPx`.
    r_px: f32 = 0,
    r_vel: f32 = 0,

    target_pos: dvui.Point = .{},
    target_r: f32 = 0,

    /// How merged the group this agent belongs to is, 0 to 1. Not the agent's own state: siblings
    /// in one group share it, and it is what the attraction and the swelling are driven from. Zero
    /// for anything at rest.
    merge_t: f32 = 0,
    /// Notes underneath. 1 for a leaf.
    count: u32 = 1,

    /// Frame this agent was last asked for. Anything missing after a pass is gone from the view.
    seen: u32 = 0,

    /// Position an agent should be *born* at, which is the whole trick behind an invisible swap:
    /// a parent taking over from its children appears where they had gathered, and children
    /// opening out of a parent appear where it stood.
    pub fn distanceTo(self: Agent, q: dvui.Point) f32 {
        const dx = self.pos.x - q.x;
        const dy = self.pos.y - q.y;
        return @sqrt(dx * dx + dy * dy);
    }
};

/// What a group of agents needs to remember between frames.
///
/// `open` is whether the children are the drawn things. `t` is how gathered they are while it is:
/// 1 with them coincident on the parent's centre and at the parent's size, 0 with them out at
/// their own positions. A group that has just opened starts at 1 and runs down; one on its way to
/// closing runs up to 1 and commits when it arrives, which is the frame where swapping the
/// children for the parent changes nothing on screen.
///
/// `locked` / `lock_lf` stop mid-range budget thrash: after a hard close, the same key must not
/// reopen while sticky topology lf is unchanged. Timed unlock was wrong — at a parked camera it
/// reopened forever every N frames. Size (area ∝ count) only reads as mass when topology holds.
const Group = struct {
    open: bool,
    t: f32,
    seen: u32,
    /// Set after a hard budget close; clears only when sticky lf moves past `lock_lf_slop`.
    locked: bool = false,
    /// Sticky lf when the lock was armed.
    lock_lf: f32 = 0,
};

/// Largest a mark may be on screen, as a multiple of the resting note radius.
///
/// Pure area conservation has no ceiling — a 7k-note island is `sqrt(7000) ≈ 84×` a note, which
/// at even a few pixels per note eats the panel. Cap enough for FPS, but high enough that a
/// mid-level mass still reads clearly larger than a note (6× was "slightly bigger" dust→speck).
const mark_max_mult: f32 = 12.0;

/// How big a mark stands for `count` notes, in screen pixels.
///
/// Water-droplet mass: N discs of radius `note_r` join into one disc whose *area* is the sum of
/// theirs, so the radius is `note_r * sqrt(N)`. That is what makes a merge read as matter pooling
/// rather than as a level swap — the parent is the size of its children put together, and a split
/// is that mass coming apart, not a speck exploding into an island.
///
/// The older log bump (≈ +35% for a hub) was chosen for an even far tessellation. It made the
/// join jarring: a whole island collapsed to a mark barely bigger than a singleton, then the
/// reverse on the way in. Area is the honest size for the animation; the far-view calm has to
/// come from there being few marks, not from every mark being the same size.
///
/// `note_r_px` is what a resting note is drawn at right now (already gap-capped by the caller).
pub fn markRadiusPx(note_r_px: f32, count: u32) f32 {
    const n: f32 = @floatFromInt(@max(count, 1));
    const mult = @min(@sqrt(n), mark_max_mult);
    return @max(note_r_px * mult, 0.6);
}

/// Mix two radii in *area* space. Linear radius lerp under-weights the join — half way on radius
/// is only a quarter of the way on mass — and the droplet read wants mass to flow.
pub fn mixRadiusPx(a: f32, b: f32, t: f32) f32 {
    const u = std.math.clamp(t, 0, 1);
    return @sqrt(a * a * (1 - u) + b * b * u);
}

/// Everything the caller has to tell the field about this frame's view.
pub const Frame = struct {
    /// Chosen level of detail, as `lod.Pyramid.levelFor` returns it. Targets are derived from it;
    /// it may move as fast as the camera does.
    lf: f32,
    /// Visible region in world space, already inflated by whatever the caller draws beyond it.
    view: dvui.Rect,
    /// Current level-0 positions — notes have been eased and shoved since layout, and a level-0
    /// agent has to sit where its note actually is. Empty is fine; the pyramid's own positions are
    /// used instead.
    live: []const dvui.Point = &.{},
    /// Pixels per world unit, for turning a screen radius into the world-space settle test.
    zoom: f32 = 1,
    /// Screen radius of a resting note here. See `markRadiusPx`.
    note_r_px: f32,
    /// Seconds since the last pass.
    dt: f32,
    /// Hard ceiling on live agents. Groups stop opening as it is approached, so the field degrades
    /// by staying coarse rather than by dropping things that should be on screen.
    budget: usize = 3000,
};

/// The live agent set, and the group states behind it. One per view.
pub const Field = struct {
    allocator: std.mem.Allocator,
    agents: std.ArrayListUnmanaged(Agent) = .empty,
    /// `agents` indexed by key. Rebuilt in place as agents are added and swap-removed.
    index: std.AutoHashMapUnmanaged(Key, u32) = .empty,
    /// Open/closed state per parent cluster, so a merge does not restart every time the reader
    /// nudges the camera across a threshold.
    groups: std.AutoHashMapUnmanaged(Key, Group) = .empty,

    stamp: u32 = 0,
    /// True when every agent has reached its target and the caller may stop repainting.
    settled: bool = true,
    /// Set when the budget stopped a group from opening / forced a close this frame.
    budget_bound: bool = false,
    /// Frames remaining where new opens are refused after a budget event (anti-thrash).
    budget_cooloff: u32 = 0,
    /// Topology lf actually used for open/close (sticky). Mirrored for HUD / web callers.
    lf_shown: f32 = 0,
    /// Last camera `Frame.lf` sample (may jitter within slop of sticky).
    lf_cam: f32 = 0,
    /// Held topology lf — ignores `levelFor` jitter smaller than `lock_lf_slop`.
    lf_sticky: f32 = 0,
    topo_inited: bool = false,
    /// After a hard budget close: no new opens until sticky lf retargets from the camera.
    open_frozen: bool = false,
    /// Sticky just refined (zoom-in). Hard budget closes are suppressed so diving in cannot
    /// collapse open groups; only further opens freeze. Cleared on zoom-out, or once parked
    /// under budget again.
    refine_hold: bool = false,
    /// Sustained coarser-than-sticky samples; sticky only rises once this hits confirm.
    coarsen_ticks: u32 = 0,

    pub fn init(allocator: std.mem.Allocator) Field {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Field) void {
        self.agents.deinit(self.allocator);
        self.index.deinit(self.allocator);
        self.groups.deinit(self.allocator);
        self.* = .{ .allocator = self.allocator };
    }

    /// Drop everything. For a rebuilt layout, where every position and every index has changed
    /// underneath and animating from the old ones would fling agents across the vault.
    pub fn reset(self: *Field) void {
        self.agents.clearRetainingCapacity();
        self.index.clearRetainingCapacity();
        self.groups.clearRetainingCapacity();
        self.settled = true;
        self.budget_cooloff = 0;
        self.lf_shown = 0;
        self.lf_cam = 0;
        self.lf_sticky = 0;
        self.topo_inited = false;
        self.open_frozen = false;
        self.refine_hold = false;
        self.coarsen_ticks = 0;
    }

    pub fn find(self: *const Field, key: Key) ?*Agent {
        const slot = self.index.get(key) orelse return null;
        return &self.agents.items[slot];
    }

    /// Groups still holding a reopen lock at the current sticky lf (HUD / diagnostics).
    pub fn lockedCount(self: *const Field) usize {
        var n: usize = 0;
        var it = self.groups.iterator();
        while (it.next()) |e| {
            if (!groupUnlocked(e.value_ptr.*, self.lf_shown)) n += 1;
        }
        return n;
    }

    fn clearAllLocks(self: *Field) void {
        var it = self.groups.iterator();
        while (it.next()) |e| {
            e.value_ptr.locked = false;
        }
    }

    /// Where a drawn thing at `key` actually is this frame — the agent's animated position if it
    /// has one, otherwise the pyramid's resting position for it.
    ///
    /// What the web asks so a link meets the bubble where it currently is rather than where the
    /// hierarchy would have put it. An end with no agent is one the descent never reached, which
    /// is off screen, and its resting position is the right answer there.
    pub fn resolve(self: *const Field, py: lod.Pyramid, live: []const dvui.Point, key: Key) dvui.Point {
        if (self.find(key)) |a| return a.pos;
        if (key.level == 0 and key.index < live.len) return live[key.index];
        if (key.level < py.levels.len and key.index < py.levels[key.level].len) {
            return py.levels[key.level][key.index].pos;
        }
        return .{};
    }

    /// The field as `lod.Pyramid.gatherWeb` wants to see it, so lines terminate on the bubbles
    /// rather than on the hierarchy's resting positions.
    ///
    /// Openness is answered from the group states rather than from `splitT`, which is the only way
    /// the two can agree: the field's thresholds are hysteretic and rate-limited, so a group can
    /// legitimately be closed at a zoom where `splitT` alone would have opened it, and a link that
    /// refined anyway would end on a marker that is not being drawn.
    ///
    /// Nothing here delays the refine the way `link_refine_t` had to. Children are born *at* their
    /// parent's position, so the links between them are zero-length at the moment they appear and
    /// grow as the group opens — and a link too short to read is already faded out by the caller's
    /// own length rule. The delay the fade needed is a property of this motion instead of a
    /// constant.
    pub fn bind(self: *const Field, py: *const lod.Pyramid) Binding {
        return .{ .field = self, .py = py };
    }

    /// Advance the field one frame: decide what should exist, spawn and retire against that, and
    /// integrate the springs. `scratch` holds the descent's working set only and suits a frame
    /// arena.
    ///
    /// After this returns, `agents.items` is what to draw, in no particular order.
    pub fn step(self: *Field, py: lod.Pyramid, scratch: std.mem.Allocator, f: Frame) !void {
        self.stamp +%= 1;
        self.budget_bound = false;
        self.settled = true;
        if (py.levels.len == 0) {
            self.agents.clearRetainingCapacity();
            self.index.clearRetainingCapacity();
            return;
        }

        // Sticky topology lf: ignore `levelFor` jitter while the camera is parked, and move
        // *monotonically with zoom direction*. Raising sticky above the camera trapped "high zoom,
        // few huge nodes"; jumping sticky coarser on a zoom-in flicker collapsed then exploded.
        const max_lf: f32 = @floatFromInt(py.maxLevel());
        const cam_lf = std.math.clamp(f.lf, 0, max_lf);
        self.lf_cam = cam_lf;
        if (!self.topo_inited) {
            self.lf_sticky = cam_lf;
            self.topo_inited = true;
            self.coarsen_ticks = 0;
        } else if (cam_lf < self.lf_sticky - lock_lf_slop) {
            // Zoom in — sticky follows finer immediately; cancel any pending coarsen.
            self.lf_sticky = cam_lf;
            self.refine_hold = true;
            self.coarsen_ticks = 0;
            self.open_frozen = false;
            self.clearAllLocks();
        } else if (cam_lf > self.lf_sticky + lock_lf_slop) {
            // Zoom out — require sustained coarser samples (not a one-frame levelFor spike).
            self.coarsen_ticks += 1;
            // Once emit is allowed to coarsen, budget hard-closes may run again (pan / zoom-out).
            if (self.coarsen_ticks >= coarsen_emit_frames) self.refine_hold = false;
            if (self.coarsen_ticks >= coarsen_confirm_frames) {
                self.lf_sticky = cam_lf;
                self.refine_hold = false;
                self.coarsen_ticks = 0;
                self.open_frozen = false;
                self.clearAllLocks();
            }
        } else {
            self.coarsen_ticks = 0;
        }

        // Emit follows sticky while diving / parked. After a few sustained coarser samples, use
        // camera lf so zoom-out merges promptly — without a 1-frame blip collapsing the dive.
        var topo = f;
        const pending_coarsen = cam_lf > self.lf_sticky + lock_lf_slop;
        topo.lf = if (pending_coarsen and self.coarsen_ticks >= coarsen_emit_frames) cam_lf else self.lf_sticky;
        self.lf_shown = topo.lf;

        try self.emit(py, scratch, topo);
        self.retire();
        self.integrate(f);
        self.pruneGroups();

        if (self.budget_cooloff > 0) {
            self.budget_cooloff -= 1;
            self.settled = false;
        }
        // `open_frozen` must not keep the panel awake forever — only active motion / cooloff.
        if (self.budget_bound) self.settled = false;
        // Parked after a dive and under budget — resume normal hard-close rules (pan ratchet).
        // Cleared *after* emit so the dive frame itself cannot collapse what it just opened.
        if (self.refine_hold and !self.budget_bound and self.budget_cooloff == 0 and !self.open_frozen) {
            self.refine_hold = false;
        }
    }

    // -- the descent ---------------------------------------------------------------

    /// One cluster still to be considered, and the group it belongs to.
    const Pending = struct {
        key: Key,
        /// The parent whose merge this cluster is taking part in, if any. Top-level clusters have
        /// none and simply sit still.
        parent: ?Key,
        /// The parent group's `merge_t`, carried down so a child does not have to look it up.
        merge_t: f32,
    };

    /// Walk the pyramid and mark everything that should exist this frame, spawning what is new.
    ///
    /// Mirrors `lod.Pyramid.select` — same descent, same view culling, same stopping places — with
    /// two changes that are the whole point of this file. The stopping rule is hysteretic and
    /// stateful rather than a bare threshold on `splitT`, so a group commits once and stays
    /// committed until the zoom has moved meaningfully back. And a group in transition yields its
    /// *children only*, never both levels: the merge is carried by where those children are and
    /// how big they are, not by fading a second copy of the region over them.
    fn emit(self: *Field, py: lod.Pyramid, scratch: std.mem.Allocator, f: Frame) !void {
        var stack: std.ArrayListUnmanaged(Pending) = .empty;
        defer stack.deinit(scratch);

        const top = py.maxLevel();
        for (0..py.levels[top].len) |i| {
            const tc = py.levels[top][i];
            if (!overlaps(f.view, tc.pos, tc.radius)) continue;
            try stack.append(scratch, .{
                .key = .{ .level = @intCast(top), .index = @intCast(i) },
                .parent = null,
                .merge_t = 0,
            });
        }

        var opens: usize = 0;
        var emitted: usize = 0;
        // A group part-way through gathering or spreading. Keeps the panel repainting even when
        // every spring has already reached its (still-moving) target.
        var ramping = false;
        const opens_allowed = self.budget_cooloff == 0 and !self.open_frozen;

        while (stack.pop()) |item| {
            const level: usize = item.key.level;
            const c = py.levels[level][item.key.index];
            // A cluster covers `radius` around its centre; a note covers nothing, and the caller
            // has already inflated `view` by what a note is drawn at.
            if (!overlaps(f.view, c.pos, c.radius)) continue;

            // Level 0 cannot open any further — it is the note.
            if (level > 0) {
                const kids = py.kidsOf(level, item.key.index);
                var g = self.groups.get(item.key) orelse Group{ .open = false, .t = 1, .seen = 0 };

                // Which side of the line the zoom puts this group on. Nothing here is animated;
                // the clock below does that. Mass-weighted hysteresis: heavy parents resist
                // swallowing their children (harder to join into).
                const split = py.splitT(level, item.key.index, f.lf);
                const th = openThresholds(c.count);
                // Sliding scale: only open down to ~floor(lf). At lf=2.3, level-3→2 may open but
                // level-2→1 may not — so a zoom step reveals one coarseness rung, not hubs→dust.
                const finest_open: u32 = @intFromFloat(@floor(@max(f.lf, 0)));
                const depth_ok = (@as(u32, @intCast(level)) - 1) >= finest_open;
                const want_open = kids.len > 0 and depth_ok and (if (g.open) split > th.keep else split > th.enter);

                // Budget against *in-view* children only. Counting every child of a vault-sized
                // mass that merely nicks the frustum made mid-zoom look over budget and panic into
                // a handful of hubs even when the camera was fairly close.
                const kid_level = level - 1;
                var in_view_kids: usize = 0;
                for (kids) |ki| {
                    const kc = py.levels[kid_level][ki];
                    if (overlaps(f.view, kc.pos, kc.radius)) in_view_kids += 1;
                }
                const projected = emitted + stack.items.len + in_view_kids;
                const over_hard = projected > f.budget;
                const fits_soft = projected + open_slack <= f.budget;
                const unlocked = groupUnlocked(g, f.lf);
                const can_open = opens_allowed and unlocked and fits_soft and in_view_kids > 0;

                if (over_hard and g.open) {
                    // Always stop opening more. Hard-close (collapse) only when we are not in a
                    // zoom-in refine hold — diving in must never coarsen, even if the soft budget
                    // is briefly exceeded while children spread.
                    self.budget_bound = true;
                    self.open_frozen = true;
                    self.budget_cooloff = budget_cooloff_frames;
                    if (!self.refine_hold) {
                        // Close only this group. Cascading `forced_coarsen` across the DFS slammed
                        // whole views into a singleton hub — mass-resistance is meant to avoid that.
                        g.open = false;
                        g.t = 1;
                        armGroupLock(&g, f.lf);
                        self.forceCloseDescendants(py, item.key, f.lf);
                    }
                }

                if (want_open and !g.open and can_open and opens < opens_per_frame) {
                    // Children are born gathered on the parent and spread out from there, so the
                    // frame the parent disappears on looks exactly like the one before it.
                    g.open = true;
                    g.t = 1;
                    opens += 1;
                } else if (want_open and !g.open and !can_open) {
                    // Soft pressure, cooloff, freeze, or lock. Mark bound only for headroom.
                    if (opens_allowed and unlocked and !fits_soft) self.budget_bound = true;
                    self.settled = false;
                }

                if (g.open) {
                    // Toward apart while the zoom wants them open; toward gathered — and faster —
                    // once it does not. Zoom-out must not sit in a fine-children state while the
                    // viewport grows, or the hard budget slams everything to one hub.
                    // Sticky: only start gathering when firmly past `open_keep` (want_open false).
                    const base = if (f.dt > 0) f.dt / merge_seconds else 0;
                    const step_t = if (want_open) base else base * merge_out_scale;
                    g.t = if (want_open) @max(g.t - step_t, 0) else @min(g.t + step_t, 1);
                    if (g.t > 0 and g.t < 1) ramping = true;

                    // Fully gathered and no longer wanted open: the children are now coincident
                    // with the parent and the same size as it, so this swap is invisible.
                    // Unlimited — rate-limiting closes was the zoom-out collapse loop.
                    if (!want_open and g.t >= 1) {
                        g.open = false;
                    }
                }

                g.seen = self.stamp;
                try self.groups.put(self.allocator, item.key, g);

                if (g.open) {
                    // Only descend into children that meet the view — pushing the whole child
                    // list bloated the stack and the budget projection with off-screen work.
                    for (kids) |k| {
                        const kc = py.levels[kid_level][k];
                        if (!overlaps(f.view, kc.pos, kc.radius)) continue;
                        try stack.append(scratch, .{
                            .key = .{ .level = @intCast(kid_level), .index = k },
                            .parent = item.key,
                            .merge_t = g.t,
                        });
                    }
                    continue;
                }
            }

            try self.touch(py, f, item, c);
            emitted += 1;
        }
        if (ramping) self.settled = false;
    }

    /// After a hard budget close, clear open state under `root` so the next refine cannot inherit
    /// a half-open subtree the descent never revisited. Arms the same reopen lock on descendants.
    fn forceCloseDescendants(self: *Field, py: lod.Pyramid, root: Key, lf: f32) void {
        if (root.level == 0) return;
        const kids = py.kidsOf(root.level, root.index);
        for (kids) |ki| {
            const child: Key = .{ .level = root.level - 1, .index = ki };
            if (self.groups.getPtr(child)) |g| {
                g.open = false;
                g.t = 1;
                armGroupLock(g, lf);
            }
            self.forceCloseDescendants(py, child, lf);
        }
    }

    /// Bring one agent up to date, creating it if this is the frame it appears on.
    ///
    /// A new agent is born where its predecessor left off rather than at its target: children
    /// opening out of a parent start at the parent's position and at the parent's radius, and a
    /// parent taking over from children starts where they had gathered. Both make the frame of the
    /// swap identical either side of it, which is what lets the swap be a cut with nothing fading.
    fn touch(self: *Field, py: lod.Pyramid, f: Frame, item: Pending, c: lod.Cluster) !void {
        const rest = if (item.key.level == 0 and item.key.index < f.live.len)
            f.live[item.key.index]
        else
            c.pos;

        // Where the group is pulling this agent to, and how big it has to be by the time it gets
        // there. At full merge every child is a disc identical to the parent it becomes — same
        // centre, same radius — so the opaque swap is invisible. Radius is mixed in area space:
        // the children's mass pools into the joined droplet rather than the radius sliding linearly
        // (which would leave the group looking half-empty most of the way).
        var target_pos = rest;
        var target_r = markRadiusPx(f.note_r_px, c.count);
        if (item.parent) |pk| {
            const parent = py.levels[pk.level][pk.index];
            // Position leads and radius follows: the bubbles have to be visibly closing before
            // they start to swell, or the group inflates first and then slides together, which
            // reads as two separate events rather than one join.
            const tp = smoothstep(item.merge_t);
            const tr = item.merge_t * item.merge_t;
            target_pos = .{
                .x = rest.x + (parent.pos.x - rest.x) * tp,
                .y = rest.y + (parent.pos.y - rest.y) * tp,
            };
            const merged_r = markRadiusPx(f.note_r_px, parent.count);
            target_r = mixRadiusPx(target_r, merged_r, tr);
        }

        const gop = try self.index.getOrPut(self.allocator, item.key);
        if (!gop.found_existing) {
            // Born from whatever stood here a frame ago. A child inherits its parent's pose; a
            // parent inherits the pose of the first of its children still around, which is where
            // the whole group had converged.
            var birth_pos = target_pos;
            var birth_r = target_r;
            if (item.parent != null and self.find(item.parent.?) != null) {
                const pa = self.find(item.parent.?).?;
                birth_pos = pa.pos;
                birth_r = pa.r_px;
            } else if (item.key.level > 0) {
                if (self.firstLivingChild(py, item.key)) |kid| {
                    birth_pos = kid.pos;
                    birth_r = kid.r_px;
                }
            }
            gop.value_ptr.* = @intCast(self.agents.items.len);
            try self.agents.append(self.allocator, .{
                .key = item.key,
                .pos = birth_pos,
                .r_px = birth_r,
                .target_pos = target_pos,
                .target_r = target_r,
                .merge_t = item.merge_t,
                .count = c.count,
                .seen = self.stamp,
            });
            return;
        }

        const a = &self.agents.items[gop.value_ptr.*];
        a.target_pos = target_pos;
        a.target_r = target_r;
        a.merge_t = item.merge_t;
        a.count = c.count;
        a.seen = self.stamp;
    }

    /// Any child of `key` that still has an agent, for a parent to be born from. Scans only the
    /// direct children, which is the group being retired this very frame.
    fn firstLivingChild(self: *const Field, py: lod.Pyramid, key: Key) ?*Agent {
        for (py.kidsOf(key.level, key.index)) |k| {
            if (self.find(.{ .level = key.level - 1, .index = k })) |a| return a;
        }
        return null;
    }

    fn groupOpen(self: *const Field, key: Key) bool {
        const g = self.groups.get(key) orelse return false;
        return g.open;
    }

    // -- retire, integrate, prune -------------------------------------------------

    /// Drop every agent the descent did not reach.
    ///
    /// Immediately, with no fade. Two things end up here and neither wants one: an agent that has
    /// left the view, which must cost nothing off screen, and one that has just committed into its
    /// parent or its children, which is already geometrically indistinguishable from whatever took
    /// its place.
    fn retire(self: *Field) void {
        var i: usize = 0;
        while (i < self.agents.items.len) {
            if (self.agents.items[i].seen == self.stamp) {
                i += 1;
                continue;
            }
            _ = self.index.remove(self.agents.items[i].key);
            const last = self.agents.items.len - 1;
            if (i != last) {
                self.agents.items[i] = self.agents.items[last];
                self.index.put(self.allocator, self.agents.items[i].key, @intCast(i)) catch {};
            }
            self.agents.items.len = last;
        }
    }

    fn integrate(self: *Field, f: Frame) void {
        const dt = @min(@max(f.dt, 0), max_dt);
        if (dt <= 0) return;

        const w_pos = std.math.tau * pos_freq;
        const w_r = std.math.tau * r_freq;
        // A settle test in pixels, expressed in the world units position is integrated in.
        const settle_world = settle_px / @max(f.zoom, 1e-6);

        var moving = false;
        for (self.agents.items) |*a| {
            // Semi-implicit Euler. Stable at these frequencies and one frame time, and unlike an
            // exponential chase it can overshoot, which is the part that reads as bubbles.
            const ax = w_pos * w_pos * (a.target_pos.x - a.pos.x) - 2 * pos_damping * w_pos * a.vel.x;
            const ay = w_pos * w_pos * (a.target_pos.y - a.pos.y) - 2 * pos_damping * w_pos * a.vel.y;
            a.vel.x += ax * dt;
            a.vel.y += ay * dt;
            a.pos.x += a.vel.x * dt;
            a.pos.y += a.vel.y * dt;

            const ar = w_r * w_r * (a.target_r - a.r_px) - 2 * r_damping * w_r * a.r_vel;
            a.r_vel += ar * dt;
            a.r_px += a.r_vel * dt;

            const dx = a.target_pos.x - a.pos.x;
            const dy = a.target_pos.y - a.pos.y;
            if (@abs(dx) < settle_world and @abs(dy) < settle_world and
                @abs(a.vel.x) < settle_world and @abs(a.vel.y) < settle_world)
            {
                a.pos = a.target_pos;
                a.vel = .{};
            } else moving = true;

            if (@abs(a.target_r - a.r_px) < settle_px and @abs(a.r_vel) < settle_px) {
                a.r_px = a.target_r;
                a.r_vel = 0;
            } else moving = true;
        }
        // `emit` may already have cleared this because a group is mid-ramp; only ever tighten.
        if (moving) self.settled = false;
    }

    /// Forget group states for regions the reader has left. Kept for a while rather than dropped
    /// with the agents, so panning away and back does not restart a merge that was under way.
    fn pruneGroups(self: *Field) void {
        if (self.groups.count() < group_prune_floor) return;
        var it = self.groups.iterator();
        var stale: std.ArrayListUnmanaged(Key) = .empty;
        defer stale.deinit(self.allocator);
        while (it.next()) |e| {
            if (self.stamp -% e.value_ptr.seen > group_ttl_frames) {
                stale.append(self.allocator, e.key_ptr.*) catch break;
            }
        }
        for (stale.items) |k| _ = self.groups.remove(k);
    }
};

/// The field paired with the pyramid it was stepped against, as `lod.Marks`.
///
/// A value the caller keeps on the stack for the length of the `gatherWeb` call, rather than
/// something the field stores: the two callbacks need both halves and `lod.Marks` carries one
/// context pointer, so *something* has to hold the pair, and a temporary the caller owns is the
/// honest place for it.
pub const Binding = struct {
    field: *const Field,
    py: *const lod.Pyramid,

    pub fn marks(self: *const Binding) lod.Marks {
        return .{ .ctx = self, .isOpen = isOpen, .posOf = posOf };
    }

    fn isOpen(ctx: *const anyopaque, level: u32, index: u32) bool {
        const self: *const Binding = @ptrCast(@alignCast(ctx));
        const g = self.field.groups.get(.{ .level = level, .index = index }) orelse return false;
        // Not merely open — open and nearly finished opening. A group that has just split has its
        // children still piled on the parent's centre, and refining the web there replaces one
        // line between two regions with every line inside them, all of them a few pixels long and
        // none of them readable. Holding the coarse web until the children have almost reached
        // their places is what `link_refine_t` was doing with a constant; here the same delay
        // falls out of the motion itself, and ends when the motion does.
        //
        // While it is held, an end resolves to the parent — which has no agent any more, so
        // `posOf` falls back to the parent's resting centroid. That is within a few pixels of
        // where the children still are, and the two converge as the group finishes opening.
        return g.open and g.t <= link_open_t;
    }

    fn posOf(ctx: *const anyopaque, level: u32, index: u32) dvui.Point {
        const self: *const Binding = @ptrCast(@alignCast(ctx));
        if (self.field.find(.{ .level = level, .index = index })) |a| return a.pos;
        // An end the descent never reached, i.e. off screen. Its resting position is right there.
        if (level < self.py.levels.len and index < self.py.levels[level].len) {
            return self.py.levels[level][index].pos;
        }
        return .{};
    }
};

/// Group entries below this are not worth walking the map to prune.
const group_prune_floor: usize = 4096;
/// Frames a group's state survives without being looked at. A few seconds — long enough that
/// panning away and back is continuous, short enough that a tour of a large vault does not
/// accumulate state for all of it.
const group_ttl_frames: u32 = 600;

fn smoothstep(t: f32) f32 {
    const x = std.math.clamp(t, 0, 1);
    return x * x * (3 - 2 * x);
}

fn overlaps(view: dvui.Rect, pos: dvui.Point, radius: f32) bool {
    return pos.x + radius >= view.x and pos.x - radius <= view.x + view.w and
        pos.y + radius >= view.y and pos.y - radius <= view.y + view.h;
}

/// Enter/keep thresholds on `splitT`. Heavier parents need more zoom-out before children join
/// into them — so a fine cloud coarsens into several medium masses, not one speck.
fn openThresholds(count: u32) struct { enter: f32, keep: f32 } {
    const n: f32 = @floatFromInt(@max(count, 1));
    const w = std.math.clamp(std.math.log2(n), 0, 8) / 8;
    const enter = open_enter - open_mass_shift * w;
    const keep = @max(enter - open_band, 0.10);
    return .{ .enter = enter, .keep = keep };
}

fn armGroupLock(g: *Group, lf: f32) void {
    g.locked = true;
    g.lock_lf = lf;
}

/// A hard-closed group stays closed until sticky topology lf moves enough to count as an
/// intentional zoom. No timed unlock — that reopened forever while sitting still.
fn groupUnlocked(g: Group, lf: f32) bool {
    if (!g.locked) return true;
    return @abs(lf - g.lock_lf) > lock_lf_slop;
}

// -- tests ------------------------------------------------------------------------

const testing = std.testing;
const multilevel = @import("../multilevel.zig");

/// Four notes pairing into two clusters, then one.
fn fixture(allocator: std.mem.Allocator) !multilevel.Ladder {
    const maps = try allocator.alloc([]u32, 1);
    maps[0] = try allocator.alloc(u32, 4);
    maps[0][0] = 0;
    maps[0][1] = 0;
    maps[0][2] = 1;
    maps[0][3] = 1;
    const counts = try allocator.alloc(usize, 2);
    counts[0] = 4;
    counts[1] = 2;
    return .{ .maps = maps, .counts = counts };
}

const everywhere: dvui.Rect = .{ .x = -1e9, .y = -1e9, .w = 2e9, .h = 2e9 };

fn testPyramid(allocator: std.mem.Allocator) !lod.Pyramid {
    var ladder = try fixture(allocator);
    defer ladder.deinit(allocator);
    const pos = [_]dvui.Point{
        .{ .x = -10, .y = 0 },
        .{ .x = -20, .y = 0 },
        .{ .x = 10, .y = 0 },
        .{ .x = 20, .y = 0 },
    };
    return lod.build(allocator, ladder, &pos, &.{});
}

fn frameAt(lf: f32, dt: f32) Frame {
    return .{ .lf = lf, .view = everywhere, .zoom = 1, .note_r_px = 9, .dt = dt, .budget = 1000 };
}

/// Run the field to rest at a fixed level, so a test can look at where things ended up rather
/// than where they were passing through.
fn settle(field: *Field, py: lod.Pyramid, lf: f32) !void {
    for (0..600) |_| {
        try field.step(py, testing.allocator, frameAt(lf, 1.0 / 60.0));
        if (field.settled) return;
    }
}

test "mark radius conserves area across a join" {
    const leaf = markRadiusPx(10, 1);
    try testing.expectApproxEqAbs(@as(f32, 10), leaf, 1e-4);
    // Four notes → one disc of twice the radius (area ×4).
    try testing.expectApproxEqAbs(@as(f32, 20), markRadiusPx(10, 4), 1e-4);
    // Parent of two count-2 children has the same area as those children combined.
    const child = markRadiusPx(10, 2);
    const parent = markRadiusPx(10, 4);
    try testing.expectApproxEqAbs(parent * parent, 2 * child * child, 1e-3);
    // Area mix at the midpoint is half the mass, not half the radius.
    const mid = mixRadiusPx(10, 20, 0.5);
    try testing.expectApproxEqAbs(@as(f32, 10 * 10 * 0.5 + 20 * 20 * 0.5), mid * mid, 1e-2);
}

test "zoomed in, every note is its own agent" {
    var py = try testPyramid(testing.allocator);
    defer py.deinit();
    var field = Field.init(testing.allocator);
    defer field.deinit();

    try settle(&field, py, 0);
    try testing.expectEqual(@as(usize, 4), field.agents.items.len);
    for (field.agents.items) |a| try testing.expectEqual(@as(u32, 0), a.key.level);
}

test "zoomed out, the notes have committed into their regions" {
    var py = try testPyramid(testing.allocator);
    defer py.deinit();
    var field = Field.init(testing.allocator);
    defer field.deinit();

    try settle(&field, py, @floatFromInt(py.maxLevel()));
    for (field.agents.items) |a| try testing.expect(a.key.level > 0);
}

test "every note is represented exactly once at every zoom" {
    var py = try testPyramid(testing.allocator);
    defer py.deinit();
    var field = Field.init(testing.allocator);
    defer field.deinit();

    const top: f32 = @floatFromInt(py.maxLevel());
    var lf: f32 = 0;
    while (lf <= top + 0.001) : (lf += 0.05) {
        // Several frames per step, so the field is asked mid-animation as well as at rest.
        for (0..4) |_| try field.step(py, testing.allocator, frameAt(lf, 1.0 / 60.0));
        var total: u32 = 0;
        for (field.agents.items) |a| total += a.count;
        try testing.expectEqual(@as(u32, 4), total);
    }
}

test "a merging group's children converge on the parent's pose before it takes over" {
    var py = try testPyramid(testing.allocator);
    defer py.deinit();
    var field = Field.init(testing.allocator);
    defer field.deinit();

    // Open, then coarsen and catch the huddle mid-ramp. Progress is on the clock (and faster on
    // zoom-out), so poll rather than guess a frame count.
    try settle(&field, py, 0);
    const top: f32 = @floatFromInt(py.maxLevel());
    var saw_huddle = false;
    for (0..180) |_| {
        try field.step(py, testing.allocator, frameAt(top, 1.0 / 60.0));
        var kids: usize = 0;
        var huddled: usize = 0;
        for (field.agents.items) |a| {
            if (a.key.level != 0) continue;
            kids += 1;
            const parent = py.levels[1][py.maps[0][a.key.index]];
            // The notes sit 5 from their region's centre; well inside that is the join happening.
            if (a.distanceTo(parent.pos) < 2.5 and a.r_px > markRadiusPx(9, 1)) huddled += 1;
        }
        if (kids > 0 and huddled == kids) {
            saw_huddle = true;
            break;
        }
        // Swap already happened — missed the mid-ramp window.
        if (kids == 0) break;
    }
    try testing.expect(saw_huddle);

    // Let it finish: the parent takes over and the children are gone.
    try settle(&field, py, top);
    for (field.agents.items) |a| try testing.expect(a.key.level > 0);
}

test "a group left alone finishes its merge and stops asking for frames" {
    var py = try testPyramid(testing.allocator);
    defer py.deinit();
    var field = Field.init(testing.allocator);
    defer field.deinit();

    // The point of running progress on the clock: at any fixed zoom the field converges, so no
    // group is left permanently part-merged drawing children where one parent would do.
    try settle(&field, py, 0);
    try settle(&field, py, @floatFromInt(py.maxLevel()));
    try testing.expect(field.settled);

    var it = field.groups.iterator();
    while (it.next()) |e| {
        try testing.expect(e.value_ptr.t == 0 or e.value_ptr.t == 1);
    }
}

test "the budget caps live agents by keeping groups closed" {
    var py = try testPyramid(testing.allocator);
    defer py.deinit();
    var field = Field.init(testing.allocator);
    defer field.deinit();

    var f = frameAt(0, 1.0 / 60.0);
    f.budget = 2;
    for (0..120) |_| try field.step(py, testing.allocator, f);
    try testing.expect(field.agents.items.len <= 2);
    try testing.expect(field.open_frozen or field.budget_bound);
}

test "a budget cut pulls already-open groups back shut" {
    var py = try testPyramid(testing.allocator);
    defer py.deinit();
    var field = Field.init(testing.allocator);
    defer field.deinit();

    // Open with room to spare, then take the room away. Checking the *transition* to open is not
    // enough: a group opened while there was budget has to be closable once there is not, or
    // panning around a vault ratchets the agent count up with nothing to bring it down.
    try settle(&field, py, 0);
    try testing.expectEqual(@as(usize, 4), field.agents.items.len);

    var f = frameAt(0, 1.0 / 60.0);
    f.budget = 2;
    for (0..120) |_| try field.step(py, testing.allocator, f);
    try testing.expect(field.agents.items.len <= 2);
    try testing.expect(field.open_frozen);
}

test "agents retire the moment they leave the view" {
    var py = try testPyramid(testing.allocator);
    defer py.deinit();
    var field = Field.init(testing.allocator);
    defer field.deinit();

    try settle(&field, py, 0);
    try testing.expect(field.agents.items.len > 0);

    var f = frameAt(0, 1.0 / 60.0);
    f.view = .{ .x = 1e6, .y = 1e6, .w = 10, .h = 10 };
    try field.step(py, testing.allocator, f);
    try testing.expectEqual(@as(usize, 0), field.agents.items.len);
}

test "panning a dense view cannot ratchet agents past the budget" {
    // Scale invariant: viewport cull + instant over-budget close. Opening while there is room,
    // then sliding the view so more clusters compete, must pull the count back — not accumulate.
    var py = try testPyramid(testing.allocator);
    defer py.deinit();
    var field = Field.init(testing.allocator);
    defer field.deinit();

    const budget: usize = 2;
    var f = frameAt(0, 1.0 / 60.0);
    f.budget = budget;
    // First the left pair (notes around x=-10,-20).
    f.view = .{ .x = -40, .y = -20, .w = 40, .h = 40 };
    for (0..180) |_| try field.step(py, testing.allocator, f);
    try testing.expect(field.agents.items.len <= budget);

    // Slide to cover everything — still capped; surplus groups shut immediately.
    f.view = everywhere;
    for (0..180) |_| try field.step(py, testing.allocator, f);
    try testing.expect(field.agents.items.len <= budget);
    try testing.expect(field.open_frozen or field.budget_bound);
}

test "a tiny vault still represents every note under budget" {
    // Scale invariant: tens of notes — shallow hierarchy, every leaf present when zoomed in.
    var py = try testPyramid(testing.allocator);
    defer py.deinit();
    var field = Field.init(testing.allocator);
    defer field.deinit();

    try settle(&field, py, 0);
    try testing.expectEqual(@as(usize, 4), field.agents.items.len);
    var total: u32 = 0;
    for (field.agents.items) |a| total += a.count;
    try testing.expectEqual(@as(u32, 4), total);
}

test "off-screen half of the vault costs nothing while the near half is open" {
    // Scale invariant: O(visible) — opening one side must not emit the other.
    var py = try testPyramid(testing.allocator);
    defer py.deinit();
    var field = Field.init(testing.allocator);
    defer field.deinit();

    var f = frameAt(0, 1.0 / 60.0);
    f.view = .{ .x = -40, .y = -20, .w = 35, .h = 40 }; // left pair only
    for (0..180) |_| try field.step(py, testing.allocator, f);
    try testing.expect(field.agents.items.len > 0);
    try testing.expect(field.agents.items.len <= 2);
    for (field.agents.items) |a| {
        try testing.expect(a.pos.x < 0);
    }
}

test "budget events cool off new opens so the field cannot thrash" {
    var py = try testPyramid(testing.allocator);
    defer py.deinit();
    var field = Field.init(testing.allocator);
    defer field.deinit();

    try settle(&field, py, 0);
    var f = frameAt(0, 1.0 / 60.0);
    f.budget = 2;
    try field.step(py, testing.allocator, f);
    try testing.expect(field.budget_cooloff > 0);
    const agents_while_cool = field.agents.items.len;

    // Even with room restored, cooloff must block reopening past the soft edge immediately.
    f.budget = 1000;
    try field.step(py, testing.allocator, f);
    try testing.expect(field.budget_cooloff > 0);
    try testing.expect(field.agents.items.len <= agents_while_cool + opens_per_frame);
}

test "after a budget coalesce zoom must move before the field can split again" {
    // Locks / open_freeze clear only when camera lf moves — not on a timer (timers thrashed at rest).
    var py = try testPyramid(testing.allocator);
    defer py.deinit();
    var field = Field.init(testing.allocator);
    defer field.deinit();

    try settle(&field, py, 0);
    try testing.expectEqual(@as(usize, 4), field.agents.items.len);

    var f = frameAt(0, 1.0 / 60.0);
    f.budget = 2;
    try field.step(py, testing.allocator, f);
    try testing.expect(field.agents.items.len <= 2);
    try testing.expect(field.open_frozen or field.lockedCount() > 0);

    f.budget = 1000;
    for (0..180) |_| try field.step(py, testing.allocator, f);
    // Still frozen at parked lf — must not return to 4 notes.
    try testing.expect(field.agents.items.len <= 2);

    // Intentional zoom (lf move) clears freeze/locks and refine resumes.
    f.lf = lock_lf_slop + 0.05;
    for (0..120) |_| try field.step(py, testing.allocator, f);
    try testing.expectEqual(@as(usize, 4), field.agents.items.len);
}

test "hard-closed groups stay locked at a parked lf after cooloff ends" {
    var py = try testPyramid(testing.allocator);
    defer py.deinit();
    var field = Field.init(testing.allocator);
    defer field.deinit();

    try settle(&field, py, 0);
    var f = frameAt(0, 1.0 / 60.0);
    f.budget = 2;
    try field.step(py, testing.allocator, f);
    const closed = field.agents.items.len;
    try testing.expect(closed <= 2);

    // Past global cooloff, parked lf — must not flap back open.
    f.budget = 1000;
    for (0..budget_cooloff_frames + 120) |_| try field.step(py, testing.allocator, f);
    try testing.expectEqual(@as(u32, 0), field.budget_cooloff);
    try testing.expect(field.agents.items.len <= closed);
}

test "moving lf past lock slop clears reopen locks so zoom-in can split" {
    var py = try testPyramid(testing.allocator);
    defer py.deinit();
    var field = Field.init(testing.allocator);
    defer field.deinit();

    try settle(&field, py, 0);
    var f = frameAt(0, 1.0 / 60.0);
    f.budget = 2;
    try field.step(py, testing.allocator, f);
    try testing.expect(field.open_frozen or field.lockedCount() > 0);

    f.budget = 1000;
    f.lf = lock_lf_slop + 0.05;
    for (0..budget_cooloff_frames + 60) |_| try field.step(py, testing.allocator, f);
    try testing.expectEqual(@as(usize, 4), field.agents.items.len);
}

test "tight mid-budget topology stops alternating agent counts at rest" {
    var py = try testPyramid(testing.allocator);
    defer py.deinit();
    var field = Field.init(testing.allocator);
    defer field.deinit();

    // Mid lf + tight budget used to reopen/close forever once cooloff/locks expired on a timer.
    const top: f32 = @floatFromInt(py.maxLevel());
    const mid = top * 0.5;
    var f = frameAt(mid, 1.0 / 60.0);
    f.budget = 2;
    for (0..120) |_| try field.step(py, testing.allocator, f);

    const n = field.agents.items.len;
    for (0..90) |_| {
        try field.step(py, testing.allocator, f);
        try testing.expectEqual(n, field.agents.items.len);
    }
}

test "heavier parents resist merging more than light ones" {
    const light = openThresholds(2);
    const heavy = openThresholds(256);
    try testing.expect(heavy.enter < light.enter);
    try testing.expect(heavy.keep < light.keep);
    // Same mid split: light wants closed, heavy still wants open.
    const mid = (light.enter + heavy.enter) * 0.5;
    try testing.expect(mid < light.enter);
    try testing.expect(mid > heavy.enter);
}

test "mid lf only reveals one coarseness rung not leaves" {
    // Sliding scale: at lf in (1, 2), floor(lf)=1 so level-1 groups must not open to notes.
    var py = try testPyramid(testing.allocator);
    defer py.deinit();
    try testing.expect(py.maxLevel() >= 1);
    var field = Field.init(testing.allocator);
    defer field.deinit();

    const lf: f32 = 1.25;
    for (0..180) |_| try field.step(py, testing.allocator, frameAt(lf, 1.0 / 60.0));
    try testing.expect(field.agents.items.len > 0);
    for (field.agents.items) |a| {
        try testing.expect(a.key.level >= 1);
    }
}

test "levelFor jitter smaller than slop does not retarget sticky topology" {
    var py = try testPyramid(testing.allocator);
    defer py.deinit();
    var field = Field.init(testing.allocator);
    defer field.deinit();

    try settle(&field, py, 0);
    const n = field.agents.items.len;
    var f = frameAt(0, 1.0 / 60.0);
    for (0..60) |i| {
        // Oscillate below slop — parked camera with noisy levelFor.
        f.lf = if (i % 2 == 0) 0 else lock_lf_slop * 0.5;
        try field.step(py, testing.allocator, f);
        try testing.expectEqual(n, field.agents.items.len);
    }
}

test "zoom-in sticky lf never jumps coarser from levelFor flicker" {
    // Far zoom looks right; diving in must only refine. A coarser blip mid-dive used to raise
    // sticky lf, collapse masses, then explode when the fine sample returned.
    var py = try testPyramid(testing.allocator);
    defer py.deinit();
    var field = Field.init(testing.allocator);
    defer field.deinit();

    const top: f32 = @floatFromInt(py.maxLevel());
    try settle(&field, py, top);
    try testing.expect(field.lf_sticky >= top - 1e-3);

    // Dive with single-frame coarse spikes — sticky must track the fine envelope only.
    const samples = [_]f32{ top - 0.5, top, top - 1.0, top - 0.1, top - 1.5, top - 0.4, 0.5, 0 };
    var prev_sticky = field.lf_sticky;
    var finest_seen: u32 = std.math.maxInt(u32);
    for (field.agents.items) |a| finest_seen = @min(finest_seen, a.key.level);

    for (samples) |lf| {
        try field.step(py, testing.allocator, frameAt(lf, 1.0 / 60.0));
        try testing.expect(field.lf_sticky <= prev_sticky + 1e-4);
        prev_sticky = field.lf_sticky;
        var frame_finest: u32 = std.math.maxInt(u32);
        for (field.agents.items) |a| frame_finest = @min(frame_finest, a.key.level);
        // Living agents must not jump coarser (higher level) than the finest rung already reached.
        try testing.expect(frame_finest <= finest_seen);
        finest_seen = @min(finest_seen, frame_finest);
    }
    try testing.expect(field.lf_sticky <= 0 + lock_lf_slop);
}

test "sustained zoom-out still raises sticky lf after confirm frames" {
    var py = try testPyramid(testing.allocator);
    defer py.deinit();
    var field = Field.init(testing.allocator);
    defer field.deinit();

    try settle(&field, py, 0);
    try testing.expect(field.lf_sticky <= lock_lf_slop);

    const top: f32 = @floatFromInt(py.maxLevel());
    for (0..coarsen_confirm_frames - 1) |_| {
        try field.step(py, testing.allocator, frameAt(top, 1.0 / 60.0));
        try testing.expect(field.lf_sticky <= lock_lf_slop);
    }
    try field.step(py, testing.allocator, frameAt(top, 1.0 / 60.0));
    try testing.expect(field.lf_sticky >= top - 1e-3);
}

test "zoom-in refine hold does not hard-close open groups under budget pressure" {
    var py = try testPyramid(testing.allocator);
    defer py.deinit();
    var field = Field.init(testing.allocator);
    defer field.deinit();

    const top: f32 = @floatFromInt(py.maxLevel());
    try settle(&field, py, top);
    const coarse_n = field.agents.items.len;

    // Dive toward notes with a tight budget — may freeze opens, but must not collapse finer
    // topology back to the far-zoom agent count.
    var f = frameAt(0, 1.0 / 60.0);
    f.budget = 2;
    for (0..90) |_| try field.step(py, testing.allocator, f);
    try testing.expect(field.refine_hold or field.open_frozen or field.agents.items.len >= coarse_n);
    // Sticky followed the dive; it did not jump back coarse.
    try testing.expect(field.lf_sticky <= lock_lf_slop);
}

test "zoom-out closes are not rate-limited the way opens are" {
    // Holding children open across a fast coarsen was the mega-hub failure mode: viewport grows,
    // still-fine open groups blow the budget, hard close collapses to one mass.
    var py = try testPyramid(testing.allocator);
    defer py.deinit();
    var field = Field.init(testing.allocator);
    defer field.deinit();

    try settle(&field, py, 0);
    try testing.expectEqual(@as(usize, 4), field.agents.items.len);

    const top: f32 = @floatFromInt(py.maxLevel());
    // One frame at coarse lf is enough for gather+swap when merge_out_scale is active and closes
    // are unlimited — several frames covers spring settle too.
    for (0..45) |_| try field.step(py, testing.allocator, frameAt(top, 1.0 / 60.0));
    try testing.expect(field.agents.items.len < 4);
    for (field.agents.items) |a| try testing.expect(a.key.level > 0);
}
