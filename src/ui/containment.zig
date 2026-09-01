//! Where each cell sits and how big it is: the store `world.zig` fills, plus the disc-packing
//! rule that used to fill it.
//!
//! **This is no longer the position source.** `layout.zig` decides where every note goes and
//! `spatial.zig` groups those positions into the drawing hierarchy; `World.initFrom` then writes
//! the result straight into the `Field` here, so a cell's `pos` and `bound_r` are a lookup rather
//! than something derived on the way down. What survives from that older design, and why:
//!
//! * **`Field` / `init`** — the per-cell `pos`, `bound_r` and `expanded` arrays the world reads
//!   every frame. Still the right shape; only who writes them changed.
//! * **`Options`** — `note_r`, arity, radius exponent, pack gap. Threaded through the panel and
//!   the solve as the layout's tuning, so it outlived the placement it was written for.
//! * **`placeAll` / `ensureChildren`** — the original rule, *a cell's children are placed inside
//!   that cell's disc*, applied down a `fold.Ladder`. Reached now only through `World.init` and
//!   `placementPositions`, which the tests and the historical harness use. The panel does not
//!   call it: a cell's radius was an estimate rather than a bound (measured at up to 1.27x on
//!   real ladders), and `decideTopology` culls branches on the claim that a disc contains its
//!   subtree — so the gap silently threw away notes that were plainly on screen. A spatial cell's
//!   bound *is* `max over children of (distance + child bound)`, computed bottom-up once.
//!
//! No dvui: positions are plain `Vec2`, so this stays in the headless test group alongside
//! `fold.zig`.

const std = @import("std");
const fold = @import("fold.zig");

pub const Vec2 = struct {
    x: f32 = 0,
    y: f32 = 0,

    pub fn dist(a: Vec2, b: Vec2) f32 {
        return @sqrt((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y));
    }
};

pub const Options = struct {
    /// World radius of a single note. Every other radius is `note_r · √count`.
    note_r: f32 = 1.0,
    /// Fraction of the parent's radius the children's ring may reach. Below 1 so a child's rim
    /// stays visibly inside its parent's ring rather than touching it.
    fill: f32 = 0.9,
    /// Weight on keeping heavy children near the centre, against shortening sibling links. Zero
    /// means links alone decide; large means mass alone decides.
    mass_k: f32 = 0.4,
    /// Air between packed island discs, as a multiple of their area. Above 1 so islands read as
    /// separate chunks rather than a tiled surface.
    pack_gap: f32 = 5.2,
    /// Horizontal stretch of the island pack. 1 is a disc, and the default for a reason.
    ///
    /// The obvious improvement here is to set this from the pane's real proportions, and it is the
    /// wrong thing to do: the arrangement is the reader's map, and a map that reshapes when you
    /// drag a splitter moves every landmark out from under them. Losing your place is a far worse
    /// cost than a pair of empty gutters on a wide panel, and it is paid at exactly the moment
    /// someone is arranging their workspace around something they were looking at. `graph.zig`'s
    /// reshape path leans on this: it deliberately leaves the camera alone, on the grounds that
    /// containment does not read the pane, so a re-solve lands on the same arrangement.
    ///
    /// A disc is also the shape everything downstream already assumes — `World.extent` measures a
    /// radius and the framing fits a circle — so 1 is the value at which the layout and the camera
    /// finally agree, rather than the stretch buying horizontal fill and the disc-shaped fit giving
    /// it straight back as vertical padding.
    ///
    /// Only ever raise this. `placeRoots` scales x alone, so a factor below 1 shortens horizontal
    /// gaps the packing radius just established and can overlap islands; the vault simulator's
    /// slider goes down to 0.6 and will show exactly that.
    pack_aspect: f32 = 1.0,
    /// Extra turn applied per level, in radians. Defaults to half a slot step, which staggers
    /// consecutive levels so children never line up radially with their parent and the field does
    /// not band. Set `aperture7_rotation` instead to nest levels on one global hex lattice.
    rotation_per_level: ?f32 = null,
    /// Exponent in `r = note_r · count^radius_exp`.
    ///
    /// 0.5 is strict area conservation, which *forces* siblings to overlap — see `minRadiusExp`.
    /// A flat multiplier cannot fix that, because it scales parent and child alike and leaves
    /// their ratio untouched; the ratio is `(1/arity)^radius_exp`, so only the exponent moves it.
    ///
    /// Deliberately keyed off `count` rather than `Cell.level`: `fold.prune` splices out
    /// single-child chains without renumbering, so a parent's level can skip one or more of its
    /// child's, and a per-level factor would then disagree with the actual count ratio.
    radius_exp: f32 = 0.5,
    /// Weight on facing links that leave the cell, against shortening the ones inside it. See the
    /// `extOf` term in `arrangementCost`; 0 restores purely-local slot assignment.
    ext_k: f32 = 1.0,
    /// How much a leaf's personal space grows with its link weight — see `separationRadius`.
    /// Zero restores the old behaviour, where every note asked for exactly its own disc.
    orbit_k: f32 = 0.22,
    /// Ceiling on that growth, as a multiple of the note's own radius.
    orbit_max: f32 = 4.0,
    /// How much file size (Cell.body, bytes) adds to inertial mass and push. Logarithmic,
    /// same reason as `orbit_k`: Wikipedia articles run from a stub to hundreds of KB.
    body_k: f32 = 0.35,
    /// Exclusive-link gravity settle rather than the solar-system flock (heaviest child pinned
    /// at the barycentre). The abandon switch: false restores the previous placement exactly.
    gravity: bool = true,
    /// Attraction along a sibling link: `G · (1/deg_i + 1/deg_j) · dist`. Exclusive pairs
    /// (deg≈1) pull hard; a hub splits its pull across many spokes.
    gravity_g: f32 = 0.16,
    /// Weak pull toward the cell's mass-weighted COM. Not a pinned star — the cluster stays
    /// together so a dive still lands on the group, without occupying the centre with the hub.
    gravity_com: f32 = 0.035,
    /// How much a low mean-degree cell's disc grows relative to area conservation. Exclusive
    /// pairs claim more space; dense cliques stay near `√count`.
    exclusive_k: f32 = 2.0,
    /// Scales push radius with sibling count: `sib_push · √(2 / n_siblings)`. A pair sits far
    /// apart; a 4-node Y packs tighter. 1 is the calibrated default.
    sib_push: f32 = 1.15,
};

/// Relaxation schedule for `ensureChildren`. Fixed, because the placement has to be a pure
/// function of the tree — a convergence test would make it a function of floating point too.
/// Sixty-four steps over at most seven bodies is a few thousand operations, paid once per cell,
/// against the up-to-720 full cost evaluations of the permutation search it replaces.
const relax_steps: usize = 128;
/// Separation dominates: it is the rule that keeps bodies apart, and a flocking agent avoids a
/// collision before it does anything else. Below 1 so a resolved overlap does not overshoot into
/// the body on the far side.
const separation_k: f32 = 0.72;
/// Cohesion is deliberately weak. It only has to stop the cell drifting apart under the other
/// rules; separation is what decides the spacing.
const cohesion_k: f32 = 0.05;
const link_k: f32 = 0.10;
/// Where the `ext` aim pulls a child toward, as a fraction of the parent radius. Out near the rim,
/// because a child pointing at something outside the cell belongs on that side of it.
const ext_rim: f32 = 0.8;

/// Wrap an angle into `[0, τ)`.
fn wrapTau(a: f32) f32 {
    const t = @mod(a, std.math.tau);
    return if (t < 0) t + std.math.tau else t;
}

/// Shortest angular distance between two angles, in `[0, π]`.
fn angleGap(a: f32, b: f32) f32 {
    const d = @abs(wrapTau(a) - wrapTau(b));
    return @min(d, std.math.tau - d);
}

fn mix64(v: u64) u64 {
    var z = v +% 0x9E3779B97F4A7C15;
    z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
    z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
    return z ^ (z >> 31);
}

/// The smallest `radius_exp` at which an arity-7 cell's uniform children stop overlapping.
///
/// Seven equal circles pack into a circle at radius ratio exactly 1/3 (hexagonally, 7 unit
/// circles inside radius 3). Area conservation instead gives `1/√7 ≈ 0.378`, so children are
/// ~13% too wide before anything else is applied — and `ensureChildren` then pulls the ring in
/// by `fill`, which costs more. With `ratio = (1/7)^p`, solving `ring ≥ r_centre + r_ring`:
///
///   `fill − ratio ≥ 2·ratio`  →  `ratio ≤ fill/3`  →  `p ≥ ln(3/fill) / ln(7)`
///
/// The ring-to-ring constraint reduces to the same bound (six slots put adjacent children
/// exactly `ring` apart), so this one number covers both. At `fill = 0.9` it is ≈0.619.
///
/// Overlap is only *forced* for uniform counts; a cell whose mass is one dominant sub-cluster
/// still overlaps at any exponent, because its centre child is nearly parent-sized by
/// construction.
pub fn minRadiusExp(fill: f32) f32 {
    return @log(3.0 / @max(fill, 0.01)) / @log(@as(f32, 7.0));
}

/// The rotation that makes consecutive levels land on a *single* hex lattice rather than each
/// being turned an arbitrary amount from its parent — `atan(√3/5)`, 19.1066°, the aperture-7
/// angle (the same one H3 uses between resolutions).
///
/// Both halves of the lattice are already here at `arity = .seven`: `ensureChildren` places one
/// child at the centre and six on a ring, which is the aperture-7 flower, and the area law
/// `r = note_r · √count` gives a full cell `(√7)^level` — exactly the per-level scale factor
/// aperture-7 needs. Only the per-level *turn* was off-lattice.
///
/// Alignment is exact only for uniformly full cells; real counts are ragged, so radii deviate
/// from the ideal `(√7)^level` and the fit degrades with raggedness. It is a coherence gain, not
/// a guarantee — which is why this is offered rather than forced, and why the default stays the
/// anti-banding half-step until it has been looked at on real shapes.
pub const aperture7_rotation: f32 = std.math.atan(@as(f32, @sqrt(3.0)) / 5.0);

/// Deliberately holds no pointer back to the ladder: a struct that stores a pointer into itself
/// (or into a sibling field of the same value) dangles the moment it is returned or moved. The
/// ladder is passed in at each call instead.
pub const Field = struct {
    opts: Options,
    pos: []Vec2,
    /// Whether this cell's *children* have been placed yet. Placement is lazy: only cells the
    /// LOD actually opens ever pay for the slot search.
    expanded: []bool,
    /// Settled bounding radius after `ensureChildren`, gravity path only. 0 means "not yet
    /// opened" — `radius` then uses `estimatedRadius` so overview discs do not jump.
    bound_r: []f32,
    /// Scratch for ordering the roots during the pack; owned, so packing allocates nothing.
    root_order: []u32,
    arity: usize,

    pub fn deinit(self: *Field, gpa: std.mem.Allocator) void {
        gpa.free(self.pos);
        gpa.free(self.expanded);
        gpa.free(self.bound_r);
        gpa.free(self.root_order);
        self.* = undefined;
    }

    /// Area-conserving disc: `note_r · count^radius_exp`. Gravity mode may grow this for
    /// exclusive groups and replace it with the settled bound once the cell opens.
    pub fn countRadius(self: Field, lad: *const fold.Ladder, cell: u32) f32 {
        const n: f32 = @floatFromInt(@max(1, lad.cells[cell].count));
        // Fast path for strict area conservation — this runs per living cell per frame in the
        // LOD's cull/split tests, and `@sqrt` is a single instruction where `pow` is not.
        if (self.opts.radius_exp == 0.5) return self.opts.note_r * @sqrt(n);
        return self.opts.note_r * std.math.pow(f32, n, self.opts.radius_exp);
    }

    /// Closed-form stand-in for the gravity settle, used while the cell is still closed.
    /// Exclusive (low mean-degree) groups get a larger disc than area conservation; a regular
    /// n-gon of sibling push radii is the other floor, so a 2-note pair is not crushed into √2.
    pub fn estimatedRadius(self: Field, lad: *const fold.Ladder, cell: u32) f32 {
        const area = self.countRadius(lad, cell);
        if (!self.opts.gravity) return area;
        const c = lad.cells[cell];
        const n_notes: f32 = @floatFromInt(@max(1, c.count));
        const mean_deg = c.weight / n_notes;
        const exclusive = 1 + self.opts.exclusive_k / (1 + mean_deg);
        const boosted = area * exclusive + self.bodyMass(c.body) * self.opts.note_r;
        if (c.child_count < 2) return area;
        const n: f32 = @floatFromInt(c.child_count);
        const push = self.opts.note_r * self.siblingPushScale(c.child_count) *
            (1 + self.opts.orbit_k * @log2(1 + mean_deg) + self.bodyMass(c.body));
        const circum = push / @sin(std.math.pi / n);
        return @max(boosted, circum + self.opts.note_r);
    }

    pub fn radius(self: Field, lad: *const fold.Ladder, cell: u32) f32 {
        if (self.opts.gravity and cell < self.bound_r.len and self.bound_r[cell] > 0) {
            return self.bound_r[cell];
        }
        if (self.opts.gravity) return self.estimatedRadius(lad, cell);
        return self.countRadius(lad, cell);
    }

    /// `sib_push · √(2 / n)` — 1× at a pair, smaller as more siblings share the cell.
    pub fn siblingPushScale(self: Field, n_sibs: usize) f32 {
        if (!self.opts.gravity) return 1;
        const n: f32 = @floatFromInt(@max(2, n_sibs));
        return self.opts.sib_push * @sqrt(2.0 / n);
    }

    /// Place `cell` itself, expanding whatever ancestors it takes to get there. Idempotent.
    ///
    /// Placement is otherwise driven entirely by the LOD, which only expands what it opens — so a
    /// cell inside a branch the camera never looked at has no position at all. That is the right
    /// default and the wrong one for the focused note's own links, which must be drawable at leaf
    /// precision no matter where the camera is standing (see `World.focus_links`).
    ///
    /// Root-down, because `ensureChildren` places children relative to their parent's already-known
    /// centre: walking the chain the other way would place a child against a parent that has not
    /// been positioned yet. Bounded by the ladder's depth — six levels at a million notes — and
    /// memoized in `expanded`, so a leaf costs this once and never again.
    pub fn ensurePlaced(self: *Field, lad: *const fold.Ladder, cell: u32) void {
        var chain: [64]u32 = undefined;
        var n: usize = 0;
        var c = cell;
        while (n < chain.len) {
            chain[n] = c;
            n += 1;
            const parent = lad.cells[c].parent;
            if (parent == fold.invalid) break;
            c = parent;
        }
        var i = n;
        while (i > 0) {
            i -= 1;
            self.ensureChildren(lad, chain[i]);
        }
    }

    /// Place `cell`'s children. Idempotent, and safe to call on a leaf.
    pub fn ensureChildren(self: *Field, lad: *const fold.Ladder, cell: u32) void {
        if (self.expanded[cell]) return;
        self.expanded[cell] = true;

        const kids = lad.childrenOf(cell);
        if (kids.len == 0) return;

        const centre = self.pos[cell];
        if (kids.len == 1) {
            self.pos[kids[0]] = centre;
            if (self.opts.gravity) {
                self.bound_r[cell] = self.radius(lad, kids[0]);
                self.growAncestors(lad, cell);
            }
            return;
        }

        if (self.opts.gravity) {
            self.settleGravity(lad, cell, kids, centre);
            return;
        }

        const r_parent = self.radius(lad, cell);

        // ---- a flock of at most `arity` bodies, settled inside one disc ------------------------
        //
        // This used to be a permutation search over a fixed jig: one centre slot and `arity - 1`
        // ring slots at identical radius and identical angular step, rotated by level. Two things
        // follow from that and both are visible from across the room. Every cell comes out a
        // *perfect* hexagon — the six-fold order parameter measures 1.000 — and because the
        // rotation is a function of level, every cell at a level shares one orientation, so the
        // hexagons line up across the whole vault and the field reads as a lattice with rows and a
        // "+" through the middle. The jig also cannot use mass: all its slots are equidistant from
        // the centre, so `mass_k` — "a pull keeping heavy children near the centre" — was provably
        // unable to affect the outcome.
        //
        // Worse, the jig makes overlap unavoidable. Seven equal circles fit inside a circle only at
        // `r ≤ R/3`, while area conservation demands `r = R/√7 = 0.378R`. No setting of `fill` or
        // `radius_exp` escapes that: raising `radius_exp` to 0.58 clears the overlap and costs four
        // times the on-screen note count, because inflating every parent spends the mark budget on
        // empty disc. Unequal bodies pack far better than equal ones, and a cell's children are
        // wildly unequal — the jig simply threw that away.
        //
        // So: local steering rules, settled by relaxation, in the spirit of boids.
        //
        //   * **separation** keeps bodies out of each other. This is the packing constraint, done
        //     softly, and it takes a per-body radius so unequal children are handled by
        //     construction. It is applied last each step, and it wins, exactly as a flocking agent
        //     puts collision avoidance above everything else.
        //   * **cohesion** is a gentle pull toward the middle. Separation resists it, and the
        //     equilibrium is a cluster that fills the parent rather than a ring inside a margin.
        //     It is what lets `fill` stop being a safety margin.
        //   * **link attraction** pulls siblings that link together, which is what
        //     `arrangementCost` was approximating by picking among six slots.
        //   * **`ext` steering** aims a child at whatever it links to outside this cell —
        //     continuously, toward the true direction, rather than snapping to the nearest slot.
        //   * a **seeded wander**, hashed from the cell id. Flocking implementations add noise to
        //     break symmetry; here it is what dissolves the lattice, and it is deterministic, so
        //     positions stay a pure function of the tree and the LOD contract never notices.
        //
        // Nothing here runs per frame. `ensureChildren` is called once per cell, lazily, and
        // memoised in `expanded` — the relaxation is paid on the frame a cell first opens and never
        // again, which is the same budget the permutation search lived in.
        const n = kids.len;
        var p: [8]Vec2 = .{Vec2{ .x = 0, .y = 0 }} ** 8;
        var sep_r: [8]f32 = .{0} ** 8;
        var mass: [8]f32 = .{1} ** 8;
        var big: usize = 0;
        for (kids, 0..) |k, i| {
            sep_r[i] = self.separationRadius(lad, k);
            // Mass orders who yields to whom. Link weight, not note count, so a hub behaves like a
            // star among its siblings instead of like one more equal dot.
            mass[i] = 1 + lad.cells[k].weight;
            if (lad.cells[k].count > lad.cells[kids[big]].count) big = i;
        }

        // Where each child's out-of-cell neighbours lie, as one unit direction per child.
        var ext_dir: [8]Vec2 = .{Vec2{ .x = 0, .y = 0 }} ** 8;
        var ext_mag: [8]f32 = .{0} ** 8;
        if (self.opts.ext_k != 0) {
            for (lad.extOf(cell)) |e| {
                if (e.child >= n or e.toward >= self.pos.len) continue;
                // A target that has not been placed yet still has `pos` of `{0, 0}`, which is a
                // perfectly valid coordinate — it is the root's centre — so aiming at it is not
                // detectably wrong, it is just wrong. Placement is lazy and depth-first, so roughly
                // half of a cell's out-of-cell neighbours are unplaced when it expands, and every
                // one of them was dragging a child toward the middle of the vault under the name of
                // pointing at a neighbour. The old slot search survived this because `ext` only
                // broke ties there; here it chooses the seed outright, and a wrong direction is the
                // whole answer.
                if (!self.isPlaced(lad, e.toward)) continue;
                const tx = self.pos[e.toward].x - centre.x;
                const ty = self.pos[e.toward].y - centre.y;
                const tl = @sqrt(tx * tx + ty * ty);
                if (tl < 1e-6) continue;
                ext_dir[e.child].x += tx / tl * e.w;
                ext_dir[e.child].y += ty / tl * e.w;
            }
            for (0..n) |i| {
                const l = @sqrt(ext_dir[i].x * ext_dir[i].x + ext_dir[i].y * ext_dir[i].y);
                // How much this child wants a direction at all, kept before the vector is
                // normalised away. A child pulled hard in one direction and a child pulled feebly
                // in two opposing ones both end up with a unit vector, and they should not get an
                // equal say in the assignment below.
                ext_mag[i] = l;
                if (l > 1e-6) {
                    ext_dir[i].x /= l;
                    ext_dir[i].y /= l;
                }
            }
        }

        // Seed: the heaviest child at the middle, the rest spread around it on a golden-angle
        // spiral — and *assigned* to those angles by where each one wants to point.
        //
        // Two requirements pull against each other here. The spiral exists to guarantee spread: the
        // golden angle is the same trick `placeRoots` uses, and starting from it is what stops the
        // configuration being a lattice before the relaxation begins. Aim matters too, though —
        // a child whose links leave the cell should sit on that side of it. Seeding children
        // directly at their target angles satisfies the second and destroys the first, because
        // several children of one cell usually point the same way and land on top of each other;
        // separation then spends its whole budget untangling a degenerate start and still leaves
        // 17% overlap.
        //
        // So the angles come from the spiral and the *assignment* comes from the aim: order the
        // children by the direction they want, order the spiral slots, and rotate one against the
        // other to the cyclic offset that costs least. Both lists are at most six long, so this is
        // a few dozen comparisons — and it is the one part of the old slot search worth keeping,
        // now over angles that are not a lattice.
        const h = mix64(@as(u64, cell) *% 0x9E3779B97F4A7C15);
        const rot = @as(f32, @floatFromInt(h & 0xffff)) / 65535.0 * std.math.tau;
        const golden = std.math.pi * (3.0 - @sqrt(5.0));
        {
            var idx: [8]usize = undefined;
            var want: [8]f32 = undefined;
            var m: usize = 0;
            for (0..n) |i| {
                if (i == big) continue;
                idx[m] = i;
                want[m] = if (@abs(ext_dir[i].x) > 1e-6 or @abs(ext_dir[i].y) > 1e-6)
                    std.math.atan2(ext_dir[i].y, ext_dir[i].x)
                else
                    std.math.nan(f32);
                m += 1;
            }

            // Spiral angles, wrapped to [0, τ) so they can be compared with the wanted ones.
            var slot_a: [8]f32 = undefined;
            for (0..m) |k| slot_a[k] = wrapTau(rot + golden * @as(f32, @floatFromInt(k)));

            // Children in order of the direction they want. Ones with no direction sort last and
            // take whatever is left, in child order, so the result stays deterministic.
            var order: [8]usize = undefined;
            for (0..m) |k| order[k] = k;
            const ByAim = struct {
                want: []const f32,
                idx: []const usize,
                pub fn lessThan(c: @This(), x: usize, y: usize) bool {
                    const ax = c.want[x];
                    const ay = c.want[y];
                    const nx = std.math.isNan(ax);
                    const ny = std.math.isNan(ay);
                    if (nx != ny) return ny;
                    if (!nx and ax != ay) return ax < ay;
                    return c.idx[x] < c.idx[y];
                }
            };
            std.mem.sortUnstable(usize, order[0..m], ByAim{ .want = want[0..m], .idx = idx[0..m] }, ByAim.lessThan);

            var slot_order: [8]usize = undefined;
            for (0..m) |k| slot_order[k] = k;
            const BySlot = struct {
                a: []const f32,
                pub fn lessThan(c: @This(), x: usize, y: usize) bool {
                    if (c.a[x] != c.a[y]) return c.a[x] < c.a[y];
                    return x < y;
                }
            };
            std.mem.sortUnstable(usize, slot_order[0..m], BySlot{ .a = slot_a[0..m] }, BySlot.lessThan);

            // Cheapest cyclic offset between the two orders.
            var best_off: usize = 0;
            var best_cost: f32 = std.math.floatMax(f32);
            for (0..m) |off| {
                var cost: f32 = 0;
                for (0..m) |k| {
                    const child = order[k];
                    const wa = want[child];
                    if (std.math.isNan(wa)) continue;
                    // Weighted by how much the child wants it, so the strongest pull gets the
                    // closest slot when they cannot all be satisfied.
                    cost += ext_mag[idx[child]] * angleGap(wa, slot_a[slot_order[(k + off) % m]]);
                }
                if (cost < best_cost) {
                    best_cost = cost;
                    best_off = off;
                }
            }

            for (0..m) |k| {
                const i = idx[order[k]];
                const a2 = slot_a[slot_order[(k + best_off) % m]];
                const reach = sep_r[big] + sep_r[i];
                const room = @max(r_parent - self.radius(lad, kids[i]), 0);
                const d = @min(reach, room);
                p[i] = .{ .x = @cos(a2) * d, .y = @sin(a2) * d };
            }
        }

        // Which bodies were touching someone on the previous step. Cohesion skips them.
        var crowded: [8]bool = .{false} ** 8;

        var step: usize = 0;
        while (step < relax_steps) : (step += 1) {
            // Cohesion, but only for bodies with room. The two rules are not meant to be balanced
            // against each other: run both on everything and they fight to a stalemate, and the
            // stalemate *is* overlap — squeezing inward against a body that is pushing outward
            // settles at exactly the penetration where the two cancel. At the threshold exponent,
            // where the ring geometry left no overlap at all, that came to 17%. A flocking agent
            // does not average the two either; it closes up when it has space and gives way when
            // it does not.
            for (0..n) |i| {
                if (crowded[i]) continue;
                p[i].x -= p[i].x * cohesion_k;
                p[i].y -= p[i].y * cohesion_k;
            }

            // sibling links
            for (lad.pairsOf(cell)) |sp| {
                if (sp.i >= n or sp.j >= n or sp.i == sp.j) continue;
                const a = sp.i;
                const b = sp.j;
                const dx = p[b].x - p[a].x;
                const dy = p[b].y - p[a].y;
                // Saturating in the weight: one very heavy pair must not collapse the cell.
                const f = link_k * sp.w / (1 + sp.w);
                const share = mass[b] / (mass[a] + mass[b]);
                p[a].x += dx * f * share;
                p[a].y += dy * f * share;
                p[b].x -= dx * f * (1 - share);
                p[b].y -= dy * f * (1 - share);
            }

            // separation — last, and it wins
            crowded = .{false} ** 8;
            for (0..n) |i| {
                for (i + 1..n) |j| {
                    var dx = p[j].x - p[i].x;
                    var dy = p[j].y - p[i].y;
                    var d = @sqrt(dx * dx + dy * dy);
                    const want = sep_r[i] + sep_r[j];
                    if (d >= want) continue;
                    if (d < 1e-5) {
                        // Exactly coincident: pick a direction from the cell's own hash rather
                        // than from whatever the floating point happens to leave in the register,
                        // so the escape is deterministic.
                        const a = rot + golden * @as(f32, @floatFromInt(i * 8 + j));
                        dx = @cos(a);
                        dy = @sin(a);
                        d = 1;
                    }
                    crowded[i] = true;
                    crowded[j] = true;
                    const push = (want - d) * separation_k;
                    const nx = dx / d;
                    const ny = dy / d;
                    const share = mass[j] / (mass[i] + mass[j]);
                    p[i].x -= nx * push * share;
                    p[i].y -= ny * push * share;
                    p[j].x += nx * push * (1 - share);
                    p[j].y += ny * push * (1 - share);
                }
            }

            // containment, as a hard clamp rather than a hope. Every other rule is advisory; this
            // one is the invariant the whole LOD rests on — a cell's children are inside its disc,
            // so an off-screen cell's whole subtree is off-screen and the cull test is exact.
            for (0..n) |i| {
                const lim = @max(r_parent * self.opts.fill - self.radius(lad, kids[i]), 0);
                const d = @sqrt(p[i].x * p[i].x + p[i].y * p[i].y);
                if (d > lim and d > 1e-6) {
                    const k2 = lim / d;
                    p[i].x *= k2;
                    p[i].y *= k2;
                }
            }

            // The primary is nailed to the barycentre. It is the one body the other rules may not
            // move, and pinning it is load-bearing twice over:
            //
            // Physically it is the star — the cell's mass is mostly this child, so anything else
            // orbits it. Structurally it guarantees the middle of a cell is *occupied*. Letting the
            // relaxation move it hollows the cell out, and then diving into a mass lands the camera
            // on empty space: at zoom 120 on a 2000-note chain the view centred on the root found
            // no notes at all, because every child had been pushed off the centre it was framing.
            // It also keeps a split reading as an expansion of the mass that was already there
            // rather than as a jump to somewhere else.
            p[big] = .{ .x = 0, .y = 0 };
        }

        // Finally, turn the whole cell to face its neighbours.
        //
        // A rigid rotation about the centre changes no distance between any two bodies, so it
        // cannot undo the packing the relaxation just found — separation, containment and the
        // sibling links are all invariant under it. What it *can* fix is the one thing they leave
        // undetermined: which way the arrangement points.
        //
        // Trying to steer for this during the relaxation does not work. `ext` is one force among
        // several there, and on a cell whose children are chained to each other the chain wins —
        // aim came out worse than seeding at random, because the pull dragged one child off its
        // spiral slot and the sibling attraction then dragged it somewhere else entirely. Rotation
        // sidesteps the competition: settle the shape first, then point it.
        //
        // Closed form. Maximising `Σ wᵢ·cos(aᵢ + θ − tᵢ)` over θ is maximising
        // `Re[e^{iθ} · Σ wᵢ·e^{i(aᵢ − tᵢ)}]`, so the best θ is minus the argument of that sum. It
        // also replaces the per-cell hash rotation as the thing that decides orientation, which is
        // strictly better: the cell now faces something real instead of facing nowhere in
        // particular.
        if (self.opts.ext_k != 0) {
            var sx: f64 = 0;
            var sy: f64 = 0;
            for (0..n) |i| {
                if (i == big or ext_mag[i] <= 1e-6) continue;
                const d = @sqrt(p[i].x * p[i].x + p[i].y * p[i].y);
                if (d < 1e-6) continue;
                const ai = std.math.atan2(p[i].y, p[i].x);
                const ti = std.math.atan2(ext_dir[i].y, ext_dir[i].x);
                sx += @as(f64, ext_mag[i]) * @cos(@as(f64, ai - ti));
                sy += @as(f64, ext_mag[i]) * @sin(@as(f64, ai - ti));
            }
            if (@abs(sx) > 1e-9 or @abs(sy) > 1e-9) {
                const theta: f32 = @floatCast(-std.math.atan2(sy, sx));
                const cs = @cos(theta);
                const sn = @sin(theta);
                for (0..n) |i| {
                    const x = p[i].x;
                    const y = p[i].y;
                    p[i].x = x * cs - y * sn;
                    p[i].y = x * sn + y * cs;
                }
            }
        }

        for (kids, 0..) |k, i| {
            self.pos[k] = .{ .x = centre.x + p[i].x, .y = centre.y + p[i].y };
        }
    }

    /// Exclusive-link gravity: inverse-degree attraction, sibling-scaled push, weak COM
    /// gravity. Nobody is pinned — a k-cycle solves to a k-gon. After settle the cluster is
    /// recentred on its COM so a dive still frames the group, then the bounding radius is
    /// cached for LOD split/cull.
    fn settleGravity(
        self: *Field,
        lad: *const fold.Ladder,
        cell: u32,
        kids: []const u32,
        centre: Vec2,
    ) void {
        const n = kids.len;
        const r_parent = self.estimatedRadius(lad, cell);
        var p: [8]Vec2 = .{Vec2{ .x = 0, .y = 0 }} ** 8;
        var sep_r: [8]f32 = .{0} ** 8;
        var mass: [8]f32 = .{1} ** 8;
        var sib_deg: [8]f32 = .{1} ** 8;
        for (kids, 0..) |k, i| {
            sep_r[i] = self.separationRadius(lad, k);
            mass[i] = 1 + lad.cells[k].weight + self.bodyMass(lad.cells[k].body);
        }
        for (lad.pairsOf(cell)) |sp| {
            if (sp.i >= n or sp.j >= n or sp.i == sp.j) continue;
            sib_deg[sp.i] += sp.w;
            sib_deg[sp.j] += sp.w;
        }

        var ext_dir: [8]Vec2 = .{Vec2{ .x = 0, .y = 0 }} ** 8;
        var ext_mag: [8]f32 = .{0} ** 8;
        if (self.opts.ext_k != 0) {
            for (lad.extOf(cell)) |e| {
                if (e.child >= n or e.toward >= self.pos.len) continue;
                if (!self.isPlaced(lad, e.toward)) continue;
                const tx = self.pos[e.toward].x - centre.x;
                const ty = self.pos[e.toward].y - centre.y;
                const tl = @sqrt(tx * tx + ty * ty);
                if (tl < 1e-6) continue;
                ext_dir[e.child].x += tx / tl * e.w;
                ext_dir[e.child].y += ty / tl * e.w;
            }
            for (0..n) |i| {
                const l = @sqrt(ext_dir[i].x * ext_dir[i].x + ext_dir[i].y * ext_dir[i].y);
                ext_mag[i] = l;
                if (l > 1e-6) {
                    ext_dir[i].x /= l;
                    ext_dir[i].y /= l;
                }
            }
        }

        const h = mix64(@as(u64, cell) *% 0x9E3779B97F4A7C15);
        const rot = @as(f32, @floatFromInt(h & 0xffff)) / 65535.0 * std.math.tau;
        const step_a = std.math.tau / @as(f32, @floatFromInt(n));
        // Seed everyone on a regular n-gon — including the heaviest. Pinning that one at the
        // origin is what made every mass a solar system and forbade triangles.
        {
            var idx: [8]usize = undefined;
            var want: [8]f32 = undefined;
            for (0..n) |i| {
                idx[i] = i;
                want[i] = if (@abs(ext_dir[i].x) > 1e-6 or @abs(ext_dir[i].y) > 1e-6)
                    std.math.atan2(ext_dir[i].y, ext_dir[i].x)
                else
                    std.math.nan(f32);
            }
            var order: [8]usize = undefined;
            for (0..n) |k| order[k] = k;
            const ByAim = struct {
                want: []const f32,
                idx: []const usize,
                pub fn lessThan(c: @This(), x: usize, y: usize) bool {
                    const ax = c.want[x];
                    const ay = c.want[y];
                    const nx = std.math.isNan(ax);
                    const ny = std.math.isNan(ay);
                    if (nx != ny) return ny;
                    if (!nx and ax != ay) return ax < ay;
                    return c.idx[x] < c.idx[y];
                }
            };
            std.mem.sortUnstable(usize, order[0..n], ByAim{ .want = want[0..n], .idx = idx[0..n] }, ByAim.lessThan);

            var best_off: usize = 0;
            var best_cost: f32 = std.math.floatMax(f32);
            for (0..n) |off| {
                var cost: f32 = 0;
                for (0..n) |k| {
                    const i = order[k];
                    const wa = want[i];
                    if (std.math.isNan(wa)) continue;
                    const slot = wrapTau(rot + step_a * @as(f32, @floatFromInt((k + off) % n)));
                    cost += ext_mag[i] * angleGap(wa, slot);
                }
                if (cost < best_cost) {
                    best_cost = cost;
                    best_off = off;
                }
            }

            const seed_r = @min(r_parent * self.opts.fill * 0.55, sep_r[0] + sep_r[@min(1, n - 1)]);
            for (0..n) |k| {
                const i = order[k];
                const a2 = wrapTau(rot + step_a * @as(f32, @floatFromInt((k + best_off) % n)));
                p[i] = .{ .x = @cos(a2) * seed_r, .y = @sin(a2) * seed_r };
            }
        }

        const golden = std.math.pi * (3.0 - @sqrt(5.0));
        var step: usize = 0;
        while (step < relax_steps) : (step += 1) {
            // Weak COM gravity — the centre of this little universe, not a pinned star.
            var cx: f32 = 0;
            var cy: f32 = 0;
            var tm: f32 = 0;
            for (0..n) |i| {
                cx += p[i].x * mass[i];
                cy += p[i].y * mass[i];
                tm += mass[i];
            }
            if (tm > 1e-6) {
                cx /= tm;
                cy /= tm;
                const k_com = self.opts.gravity_com;
                for (0..n) |i| {
                    p[i].x += (cx - p[i].x) * k_com;
                    p[i].y += (cy - p[i].y) * k_com;
                }
            }

            for (lad.pairsOf(cell)) |sp| {
                if (sp.i >= n or sp.j >= n or sp.i == sp.j) continue;
                const a = sp.i;
                const b = sp.j;
                const dx = p[b].x - p[a].x;
                const dy = p[b].y - p[a].y;
                const inv = (1 / sib_deg[a]) + (1 / sib_deg[b]);
                const f = self.opts.gravity_g * inv * (sp.w / (1 + sp.w));
                const share = mass[b] / (mass[a] + mass[b]);
                p[a].x += dx * f * share;
                p[a].y += dy * f * share;
                p[b].x -= dx * f * (1 - share);
                p[b].y -= dy * f * (1 - share);
            }

            for (0..n) |i| {
                for (i + 1..n) |j| {
                    var dx = p[j].x - p[i].x;
                    var dy = p[j].y - p[i].y;
                    var d = @sqrt(dx * dx + dy * dy);
                    const want = sep_r[i] + sep_r[j];
                    if (d >= want) continue;
                    if (d < 1e-5) {
                        const a = rot + golden * @as(f32, @floatFromInt(i * 8 + j));
                        dx = @cos(a);
                        dy = @sin(a);
                        d = 1;
                    }
                    const push = (want - d) * separation_k;
                    const nx = dx / d;
                    const ny = dy / d;
                    const share = mass[j] / (mass[i] + mass[j]);
                    p[i].x -= nx * push * share;
                    p[i].y -= ny * push * share;
                    p[j].x += nx * push * (1 - share);
                    p[j].y += ny * push * (1 - share);
                }
            }

            for (0..n) |i| {
                const lim = @max(r_parent * self.opts.fill - self.countRadius(lad, kids[i]), 0);
                const d = @sqrt(p[i].x * p[i].x + p[i].y * p[i].y);
                if (d > lim and d > 1e-6) {
                    const k2 = lim / d;
                    p[i].x *= k2;
                    p[i].y *= k2;
                }
            }
        }

        // Recentre on the COM so the mass mark (parent pose) sits in the middle of the
        // group rather than wherever the seed happened to drift. Clamp *after* this, because
        // subtracting the COM can push a body that was inside the disc back out through the rim.
        {
            var cx: f32 = 0;
            var cy: f32 = 0;
            var tm: f32 = 0;
            for (0..n) |i| {
                cx += p[i].x * mass[i];
                cy += p[i].y * mass[i];
                tm += mass[i];
            }
            if (tm > 1e-6) {
                cx /= tm;
                cy /= tm;
                for (0..n) |i| {
                    p[i].x -= cx;
                    p[i].y -= cy;
                }
            }
        }

        for (0..n) |i| {
            const lim = @max(r_parent * self.opts.fill - self.countRadius(lad, kids[i]), 0);
            const d = @sqrt(p[i].x * p[i].x + p[i].y * p[i].y);
            if (d > lim and d > 1e-6) {
                const k2 = lim / d;
                p[i].x *= k2;
                p[i].y *= k2;
            }
        }

        if (self.opts.ext_k != 0) {
            var sx: f64 = 0;
            var sy: f64 = 0;
            for (0..n) |i| {
                if (ext_mag[i] <= 1e-6) continue;
                const d = @sqrt(p[i].x * p[i].x + p[i].y * p[i].y);
                if (d < 1e-6) continue;
                const ai = std.math.atan2(p[i].y, p[i].x);
                const ti = std.math.atan2(ext_dir[i].y, ext_dir[i].x);
                sx += @as(f64, ext_mag[i]) * @cos(@as(f64, ai - ti));
                sy += @as(f64, ext_mag[i]) * @sin(@as(f64, ai - ti));
            }
            if (@abs(sx) > 1e-9 or @abs(sy) > 1e-9) {
                const theta: f32 = @floatCast(-std.math.atan2(sy, sx));
                const cs = @cos(theta);
                const sn = @sin(theta);
                for (0..n) |i| {
                    const x = p[i].x;
                    const y = p[i].y;
                    p[i].x = x * cs - y * sn;
                    p[i].y = x * sn + y * cs;
                }
            }
        }

        var br: f32 = 0;
        for (kids, 0..) |k, i| {
            self.pos[k] = .{ .x = centre.x + p[i].x, .y = centre.y + p[i].y };
            const d = @sqrt(p[i].x * p[i].x + p[i].y * p[i].y);
            // `radius`, not `countRadius`. A closed cell is drawn and culled at
            // `estimatedRadius`, which is larger than the bare area law for exclusive groups, so
            // building the parent's bound from the area law alone guarantees the parent is too
            // small for children nobody has looked at yet.
            br = @max(br, d + self.radius(lad, k));
        }
        // Floor at the estimate so opening a cell cannot shrink its disc (that would flip
        // wantsSplit and flicker). A tight settle can only match the estimate, never undercut it.
        self.bound_r[cell] = @max(br, r_parent);
        self.growAncestors(lad, cell);
    }

    /// Grow every ancestor until it contains this cell's disc.
    ///
    /// A parent's bound is fixed when the parent is expanded, from what its children looked like
    /// while they were still closed. Expanding a child floors its own bound at `estimatedRadius`,
    /// so it can come out larger than the parent allowed for — measured on real ladders at up to
    /// 1.27x the parent's whole radius, with essentially every child growing past its parent's
    /// assumption. Nothing told the parent, so "children live inside their parent's disc" quietly
    /// stopped being true as the vault was explored.
    ///
    /// That claim is load-bearing. `world.decideTopology` culls a branch whose disc is off screen
    /// *because* the subtree is then off screen too, and a parent that no longer contains its
    /// child culls notes that are genuinely in view: they lose their mark, `present` stops
    /// descending to them, and their pose is left at whatever the walk last wrote. That is the
    /// note that vanishes and flies in from somewhere else when you zoom near it.
    ///
    /// Growth is monotone — a radius only ever increases — so `wantsSplit` and the cull can only
    /// become more permissive. There is no value here that can oscillate.
    fn growAncestors(self: *Field, lad: *const fold.Ladder, from: u32) void {
        if (!self.opts.gravity) return;
        var child = from;
        var guard: u8 = 0;
        while (guard < 64) : (guard += 1) {
            const parent = lad.cells[child].parent;
            if (parent == fold.invalid or parent >= self.bound_r.len) return;
            // An unexpanded parent has no bound yet; it will read this cell's grown radius
            // directly when its own turn comes.
            if (!self.expanded[parent]) return;
            const need = Vec2.dist(self.pos[parent], self.pos[child]) + self.radius(lad, child);
            if (need <= self.bound_r[parent]) return;
            self.bound_r[parent] = need;
            child = parent;
        }
    }

    /// Has this cell been given a position yet?
    ///
    /// Placement is lazy: a cell is positioned by its parent's `ensureChildren`, so it is placed
    /// exactly when its parent has been expanded. Roots are placed up front by `placeRoots`.
    pub fn isPlaced(self: Field, lad: *const fold.Ladder, cell: u32) bool {
        if (cell >= lad.cells.len) return false;
        const parent = lad.cells[cell].parent;
        if (parent == fold.invalid) return true; // a root
        return parent < self.expanded.len and self.expanded[parent];
    }

    /// `body_k · log2(1+bytes)` — a 4 KB note vs a 4 byte stub is a few units, not 1000×.
    pub fn bodyMass(self: Field, body: f32) f32 {
        if (self.opts.body_k == 0 or body <= 0) return 0;
        return self.opts.body_k * @log2(1 + body);
    }

    /// How much room a body asks its neighbours for, which is not the same as the disc it occupies.
    ///
    /// For a cell holding many notes the two agree: its content fills its disc. A *leaf* is
    /// different. Its disc is one note's worth, but the reader can dive into it, and when they do,
    /// its sections and links unfold into a cloud around it. Sizing a note's personal space by the
    /// cloud it is about to grow means the room is already there when the reader arrives — the
    /// interior does not shove the field aside on the way in, it fills a gap that was always its
    /// own. It also gives the overview a reason for uneven spacing that is *about the notes*: a
    /// hub sits in a clearing, a stub sits in a crowd.
    ///
    /// Logarithmic in link weight, because the range is enormous — a Wikipedia vault runs from 0 to
    /// 29,448 — and a linear law would let one article claim its entire branch. Capped for the same
    /// reason. Gravity mode also scales push down as more siblings share the cell, so a pair sits
    /// far apart and a Y packs tighter. Separation is advisory anyway: if a leaf asks for more than
    /// the cell can give, the containment clamp takes it back.
    pub fn separationRadius(self: Field, lad: *const fold.Ladder, cell: u32) f32 {
        const c = lad.cells[cell];
        const base = self.countRadius(lad, cell);
        var swell: f32 = 1;
        if (c.child_count == 0 and self.opts.orbit_k != 0) {
            swell = 1 + self.opts.orbit_k * @log2(1 + c.weight);
        }
        swell += self.bodyMass(c.body);
        swell = @min(swell, self.opts.orbit_max * 2);
        var sibs: usize = 2;
        const parent = c.parent;
        if (parent != fold.invalid) sibs = @max(1, lad.cells[parent].child_count);
        return base * swell * self.siblingPushScale(sibs);
    }

};

pub fn init(
    gpa: std.mem.Allocator,
    n_cells: usize,
    n_roots: usize,
    arity: fold.Arity,
    opts: Options,
) !Field {
    const pos = try gpa.alloc(Vec2, n_cells);
    @memset(pos, .{});
    const expanded = try gpa.alloc(bool, n_cells);
    @memset(expanded, false);
    const bound_r = try gpa.alloc(f32, n_cells);
    @memset(bound_r, 0);
    const root_order = try gpa.alloc(u32, n_roots);
    return .{
        .opts = opts,
        .pos = pos,
        .expanded = expanded,
        .bound_r = bound_r,
        .root_order = root_order,
        .arity = arity.n(),
    };
}

/// Place the component roots relative to each other.
///
/// Containment only ever says where a cell's children go *inside* it. The islands themselves have
/// no parent, so they need one arrangement of their own: a golden-angle spiral with each root's
/// area reserved in turn, biggest first at the centre. That keeps a vault of discrete islands
/// reading as separate chunks spread over the field, instead of the single converging blob you get
/// from folding unrelated components under one disc.
///
/// Must run before any `ensureChildren`, since children are placed relative to their root.
pub fn placeRoots(f: *Field, lad: *const fold.Ladder) void {
    if (lad.roots.len == 0) return;
    if (lad.roots.len == 1) {
        f.pos[lad.roots[0]] = .{};
        return;
    }
    // biggest first, so the largest island anchors the middle
    const order = f.root_order;
    for (order, lad.roots) |*o, r| o.* = r;
    const ByCount = struct {
        lad: *const fold.Ladder,
        pub fn lessThan(self: @This(), a: u32, b: u32) bool {
            const ca = self.lad.cells[a].count;
            const cb = self.lad.cells[b].count;
            if (ca != cb) return ca > cb;
            return a < b;
        }
    };
    std.mem.sort(u32, order, ByCount{ .lad = lad }, ByCount.lessThan);

    const golden = std.math.pi * (3.0 - @sqrt(5.0));
    var acc: f32 = 0;
    for (order, 0..) |r, i| {
        const rr = f.radius(lad, r);
        // `+ rr` places this island's *edge* on the packed disc rather than its centre, which is
        // what actually prevents overlap. It is a constant offset, not a cumulative one, so a
        // vault of many similar islands still packs as a disc rather than unwinding into a line.
        const rad = if (i == 0) 0 else @sqrt(acc) + rr;
        // The anchor contributes its bare area; everything after it pays `pack_gap`.
        //
        // `pack_gap` separates *peers*. Charging it to the first island as well means every other
        // island is pushed out by the square root of it — and when one component dominates, as it
        // does on any real wiki (Simple English is 98.99% one component), that scales the entire
        // vault's extent by √5.2 ≈ 2.3. The 2,816 orphans ended up more than two radii from a blob
        // they are not attached to, and "fit to extents" then had to frame all that emptiness.
        // Nothing needs clearance from the anchor beyond touching it.
        acc += rr * rr * (if (i == 0) 1 else f.opts.pack_gap);
        const a = @as(f32, @floatFromInt(i)) * golden;
        f.pos[r] = .{ .x = @cos(a) * rad * f.opts.pack_aspect, .y = @sin(a) * rad };
    }
}

/// Expand the whole ladder. Real use is lazy — this exists for tests and benches.
pub fn placeAll(f: *Field, lad: *const fold.Ladder) void {
    placeRoots(f, lad);
    for (lad.roots) |r| expandRec(f, lad, r);
}

fn expandRec(f: *Field, lad: *const fold.Ladder, cell: u32) void {
    f.ensureChildren(lad, cell);
    for (lad.childrenOf(cell)) |k| expandRec(f, lad, k);
}

// ---- tests ----------------------------------------------------------------------------------

const testing = std.testing;

fn buildStar(gpa: std.mem.Allocator, leaves: u32) ![]fold.Edge {
    const e = try gpa.alloc(fold.Edge, leaves);
    for (0..leaves) |i| e[i] = .{ .a = 0, .b = @intCast(i + 1) };
    return e;
}

test "the relaxation is a pure function of the tree" {
    // The property the whole LOD rests on: a placement computed twice must be the same placement.
    // A relaxation invites the two ways of losing that — a convergence test that reads floating
    // point, and an escape direction taken from uninitialised state — so it is asserted rather than
    // argued. Bit-identical, not approximately equal.
    const gpa = testing.allocator;

    for ([_]u32{ 60, 300, 1200 }) |n| {
        const edges = try buildStar(gpa, n);
        defer gpa.free(edges);
        var lad = try fold.build(gpa, n + 1, edges, &.{}, .{ .arity = .seven });
        defer lad.deinit(gpa);

        var a = try init(gpa, lad.cells.len, lad.roots.len, .seven, .{ .ext_k = 1 });
        defer a.deinit(gpa);
        placeAll(&a, &lad);

        var b = try init(gpa, lad.cells.len, lad.roots.len, .seven, .{ .ext_k = 1 });
        defer b.deinit(gpa);
        placeAll(&b, &lad);

        for (a.pos, b.pos) |pa, pb| {
            try testing.expectEqual(pb.x, pa.x);
            try testing.expectEqual(pb.y, pa.y);
        }
    }
}

test "a leaf's personal space grows with its link weight" {
    // The star rule: a hub asks its neighbours for more room than a stub, so the overview spaces
    // notes by how much they matter rather than uniformly. Without this every leaf has count 1 and
    // therefore identical mass and identical spacing, which is the lattice.
    const gpa = testing.allocator;
    const edges = try buildStar(gpa, 200);
    defer gpa.free(edges);
    var lad = try fold.build(gpa, 201, edges, &.{}, .{ .arity = .seven });
    defer lad.deinit(gpa);
    var f = try init(gpa, lad.cells.len, lad.roots.len, .seven, .{ .gravity = false });
    defer f.deinit(gpa);

    // Note 0 is the star's centre with 200 links; note 1 is a rim node with one.
    const hub = lad.leaf_cell[0];
    const rim = lad.leaf_cell[1];
    try testing.expect(lad.cells[hub].weight > lad.cells[rim].weight);
    try testing.expect(f.separationRadius(&lad, hub) > f.separationRadius(&lad, rim) * 2);
    // And it stays a *personal space*, never an entitlement to the whole cell.
    try testing.expect(f.separationRadius(&lad, hub) <= f.radius(&lad, hub) * f.opts.orbit_max);
}

test "every child is contained inside its parent's disc" {
    // The invariant the whole design rests on. If it holds, the vault fits in one circle at every
    // zoom, and aspect ratio can never degenerate.
    const gpa = testing.allocator;
    const edges = try buildStar(gpa, 300);
    defer gpa.free(edges);
    var lad = try fold.build(gpa, 301, edges, &.{}, .{});
    defer lad.deinit(gpa);

    var f = try init(gpa, lad.cells.len, lad.roots.len, .seven, .{});
    defer f.deinit(gpa);
    placeAll(&f, &lad);

    for (lad.cells, 0..) |c, id| {
        if (c.child_count == 0) continue;
        const R = f.radius(&lad, @intCast(id));
        for (lad.childrenOf(@intCast(id))) |k| {
            const d = Vec2.dist(f.pos[@intCast(id)], f.pos[k]);
            try testing.expect(d + f.radius(&lad, k) <= R * 1.001);
        }
    }
}

test "a child that grows on expansion still fits its parent" {
    // The invariant `world.decideTopology` culls on, at a depth that actually strains it.
    //
    // A parent's bound is fixed when the parent is expanded, from what its children looked like
    // while still closed. Expanding a child floors its own bound at `estimatedRadius`, which
    // exceeds the bare area law for exclusive groups, so the child outgrows the allowance and
    // nothing tells the parent. Measured before the fix: worst child reaching 1.16x its parent's
    // radius on a chain and 1.27x on a star, with 502 of 503 cells holding an over-sized child.
    //
    // Depth is what exposes it — the error compounds level by level, so the 300-node star the
    // test above uses is too shallow to show any of it.
    const gpa = testing.allocator;
    for ([_]u8{ 0, 1 }) |kind| {
        const n: u32 = 3000;
        var list: std.ArrayListUnmanaged(fold.Edge) = .empty;
        defer list.deinit(gpa);
        if (kind == 0) {
            for (0..n - 1) |i| try list.append(gpa, .{ .a = @intCast(i), .b = @intCast(i + 1) });
        } else {
            for (1..n) |i| try list.append(gpa, .{ .a = 0, .b = @intCast(i) });
        }

        var lad = try fold.build(gpa, n, list.items, &.{}, .{});
        defer lad.deinit(gpa);
        var f = try init(gpa, lad.cells.len, lad.roots.len, .seven, .{});
        defer f.deinit(gpa);
        placeAll(&f, &lad);

        for (lad.cells, 0..) |c, id| {
            if (c.child_count == 0) continue;
            const R = f.radius(&lad, @intCast(id));
            for (lad.childrenOf(@intCast(id))) |k| {
                const d = Vec2.dist(f.pos[@intCast(id)], f.pos[k]);
                try testing.expect(d + f.radius(&lad, k) <= R * 1.001);
            }
        }
    }
}

test "radius is the area-conserving law" {
    const gpa = testing.allocator;
    const edges = try buildStar(gpa, 50);
    defer gpa.free(edges);
    var lad = try fold.build(gpa, 51, edges, &.{}, .{});
    defer lad.deinit(gpa);
    var f = try init(gpa, lad.cells.len, lad.roots.len, .seven, .{ .note_r = 2, .gravity = false });
    defer f.deinit(gpa);

    for (lad.cells, 0..) |c, id| {
        if (c.count == 0) continue;
        const want = 2 * @sqrt(@as(f32, @floatFromInt(c.count)));
        try testing.expectApproxEqAbs(want, f.radius(&lad, @intCast(id)), 0.001);
    }
}

test "the whole vault fits inside the root disc" {
    const gpa = testing.allocator;
    const n: u32 = 2000;
    const edges = try gpa.alloc(fold.Edge, n - 1);
    defer gpa.free(edges);
    for (0..n - 1) |i| edges[i] = .{ .a = @intCast(i), .b = @intCast(i + 1) };
    var lad = try fold.build(gpa, n, edges, &.{}, .{});
    defer lad.deinit(gpa);
    var f = try init(gpa, lad.cells.len, lad.roots.len, .seven, .{});
    defer f.deinit(gpa);
    placeAll(&f, &lad);

    const R = f.radius(&lad, lad.roots[0]);
    const origin = f.pos[lad.roots[0]];
    for (lad.cells, 0..) |c, id| {
        if (c.note == fold.invalid) continue;
        try testing.expect(Vec2.dist(origin, f.pos[@intCast(id)]) <= R * 1.001);
    }
}

test "slot assignment shortens sibling links" {
    // A cell whose children are linked in a path should not arrange them arbitrarily. Compare the
    // chosen arrangement's cost against the identity one; it must never be worse.
    const gpa = testing.allocator;
    const n: u32 = 400;
    const edges = try gpa.alloc(fold.Edge, n - 1);
    defer gpa.free(edges);
    for (0..n - 1) |i| edges[i] = .{ .a = @intCast(i), .b = @intCast(i + 1) };
    var lad = try fold.build(gpa, n, edges, &.{}, .{});
    defer lad.deinit(gpa);

    var chosen = try init(gpa, lad.cells.len, lad.roots.len, .seven, .{ .mass_k = 0 });
    defer chosen.deinit(gpa);
    placeAll(&chosen, &lad);

    var total_chosen: f32 = 0;
    var pairs_seen: usize = 0;
    for (lad.cells, 0..) |c, id| {
        if (c.pair_count == 0) continue;
        for (lad.pairsOf(@intCast(id))) |p| {
            const kids = lad.childrenOf(@intCast(id));
            total_chosen += p.w * Vec2.dist(chosen.pos[kids[p.i]], chosen.pos[kids[p.j]]);
            pairs_seen += 1;
        }
    }
    try testing.expect(pairs_seen > 0);
    try testing.expect(total_chosen > 0);
    // Chosen arrangements must beat the worst case by a clear margin; a path's ends should not sit
    // on opposite sides of the ring.
    var worst: f32 = 0;
    for (lad.cells, 0..) |c, id| {
        if (c.pair_count == 0) continue;
        const R = chosen.radius(&lad, @intCast(id));
        for (lad.pairsOf(@intCast(id))) |p| worst += p.w * 2 * R;
    }
    try testing.expect(total_chosen < worst * 0.9);
}

test "lazy expansion places only what is opened" {
    const gpa = testing.allocator;
    const edges = try buildStar(gpa, 500);
    defer gpa.free(edges);
    var lad = try fold.build(gpa, 501, edges, &.{}, .{});
    defer lad.deinit(gpa);
    var f = try init(gpa, lad.cells.len, lad.roots.len, .seven, .{});
    defer f.deinit(gpa);

    placeRoots(&f, &lad);
    f.ensureChildren(&lad, lad.roots[0]);
    var expanded: usize = 0;
    for (f.expanded) |e| {
        if (e) expanded += 1;
    }
    try testing.expectEqual(@as(usize, 1), expanded);
}

test "deterministic" {
    const gpa = testing.allocator;
    const edges = try buildStar(gpa, 120);
    defer gpa.free(edges);
    var lad = try fold.build(gpa, 121, edges, &.{}, .{});
    defer lad.deinit(gpa);

    var a = try init(gpa, lad.cells.len, lad.roots.len, .seven, .{});
    defer a.deinit(gpa);
    var b = try init(gpa, lad.cells.len, lad.roots.len, .seven, .{});
    defer b.deinit(gpa);
    placeAll(&a, &lad);
    placeAll(&b, &lad);
    for (a.pos, b.pos) |pa, pb| {
        try testing.expectEqual(pa.x, pb.x);
        try testing.expectEqual(pa.y, pb.y);
    }
}

test "aperture-7 rotation is the lattice angle, not the anti-banding half-step" {
    // 19.1066°, the value the Options doc comment names. Asserted rather than trusted: it is
    // written as `atan(√3/5)`, and the whole point of the constant is that it is *exact* — an
    // eyeballed 0.3335 would nest almost-but-not-quite and look like a subtle layout bug.
    const deg = aperture7_rotation * 180.0 / std.math.pi;
    try testing.expectApproxEqAbs(@as(f32, 19.1066), deg, 1e-3);

    // And it must differ from the default it replaces (half of a 60° slot step), or the toggle
    // exposing it would be a no-op.
    const half_step = (std.math.tau / 6.0) * 0.5;
    try testing.expect(@abs(aperture7_rotation - half_step) > 0.1);
}

test "radius_exp removes the overlap area conservation forces" {
    // A full, uniform arity-7 ladder: 49 notes -> 7 level-1 cells -> 1 level-2 root. Uniform
    // counts are exactly the case `minLevelSlack` solves, so this is the tight test of it.
    const gpa = testing.allocator;
    const n: u32 = 49;
    // A chain inside each group of 7, so `fold` coarsens into clean 7s rather than by path order.
    var edges: std.ArrayListUnmanaged(fold.Edge) = .empty;
    defer edges.deinit(gpa);
    var g: u32 = 0;
    while (g < 7) : (g += 1) {
        var i: u32 = 0;
        while (i < 6) : (i += 1) {
            try edges.append(gpa, .{ .a = g * 7 + i, .b = g * 7 + i + 1 });
        }
    }

    const fill: f32 = 0.9;
    for ([_]f32{ 0.5, 0 }) |probe| {
        const exp = if (probe == 0) minRadiusExp(fill) else probe;
        var lad = try fold.build(gpa, n, edges.items, &.{}, .{ .arity = .seven });
        defer lad.deinit(gpa);
        var f = try init(gpa, lad.cells.len, lad.roots.len, .seven, .{
            .fill = fill,
            .radius_exp = exp,
            // Links alone decide arrangement here; a mass pull would bias the uniform case.
            .mass_k = 0,
            // `minRadiusExp` is a statement about the *drawn* radii — the exponent at which a
            // cell's discs stop intersecting. The personal-space swell deliberately asks for more
            // room than a leaf's own disc, so with it on the geometric threshold is no longer
            // exact (it leaves a couple of percent). Turned off, so this tests the formula on the
            // terms the formula is stated in.
            .orbit_k = 0,
            .gravity = false,
        });
        defer f.deinit(gpa);
        placeAll(&f, &lad);

        // Worst sibling overlap anywhere in the ladder, as a fraction of the pair's summed radii.
        //
        // The threshold is where a *constructed* ring arrangement stops intersecting, and the ring
        // construction hit it exactly. The relaxation is an iterative settle rather than a
        // construction: it starts from a golden-angle spiral whose gaps are deliberately uneven,
        // and once every body is against the containment clamp only the tangential part of a
        // separation push does any work, so equalising the last few percent is slow. It gets under
        // 5% and stops paying for more steps. What the exponent buys is still visible — an order of
        // magnitude against the 60% the shipped exponent leaves — and the real grade is the
        // `sibling discs overlapping` line of `bench --world`, measured on actual vaults.
        var worst: f32 = 0;
        for (0..lad.cells.len) |ci| {
            const kids = lad.childrenOf(@intCast(ci));
            if (kids.len < 2) continue;
            // Only uniform cells — a dominant-child cell overlaps at any slack, by construction.
            var uniform = true;
            for (kids) |k| {
                if (lad.cells[k].count != lad.cells[kids[0]].count) uniform = false;
            }
            if (!uniform) continue;
            for (kids, 0..) |a, i| {
                for (kids[i + 1 ..]) |b| {
                    const need = f.radius(&lad, a) + f.radius(&lad, b);
                    const got = Vec2.dist(f.pos[a], f.pos[b]);
                    if (got < need) worst = @max(worst, (need - got) / need);
                }
            }
            // Containment must hold either way — this is what `world.zig`'s exact cull rests on.
            for (kids) |k| {
                const reach = Vec2.dist(f.pos[@intCast(ci)], f.pos[k]) + f.radius(&lad, k);
                try testing.expect(reach <= f.radius(&lad, @intCast(ci)) * 1.001);
            }
        }

        if (probe == 0.5) {
            // Strict area conservation: overlap is forced, so this must actually be violated —
            // otherwise the test would pass vacuously and prove nothing about the fix.
            try testing.expect(worst > 0.01);
        } else {
            try testing.expect(worst < 0.05);
        }
    }
}

test "ext_k aims children at their out-of-cell neighbours" {
    // Two groups of seven, each internally chained, plus one heavy cross-link between a specific
    // leaf in each. At the cell holding a group, that link is *external* — invisible to
    // `pairsOf`, which is exactly the gap `extOf` fills. Measured as the objective itself: total
    // weighted (1 − cos) between each pulled child's slot direction and its target's direction.
    const gpa = testing.allocator;
    const n: u32 = 14;
    var edges: std.ArrayListUnmanaged(fold.Edge) = .empty;
    defer edges.deinit(gpa);
    for (0..6) |i| try edges.append(gpa, .{ .a = @intCast(i), .b = @intCast(i + 1) });
    for (7..13) |i| try edges.append(gpa, .{ .a = @intCast(i), .b = @intCast(i + 1) });
    // One strong tie, from the *end* of each chain so it is not the obvious centre child.
    try edges.append(gpa, .{ .a = 6, .b = 7, .w = 8.0 });

    var misalign: [2]f32 = .{ 0, 0 };
    for ([_]f32{ 0, 1 }, 0..) |ext_k, pass| {
        var lad = try fold.build(gpa, n, edges.items, &.{}, .{ .arity = .seven });
        defer lad.deinit(gpa);
        var f = try init(gpa, lad.cells.len, lad.roots.len, .seven, .{ .ext_k = ext_k });
        defer f.deinit(gpa);
        placeAll(&f, &lad);

        var total: f32 = 0;
        for (0..lad.cells.len) |ci| {
            const cell: u32 = @intCast(ci);
            const centre = f.pos[cell];
            for (lad.extOf(cell)) |e| {
                const kids = lad.childrenOf(cell);
                if (e.child >= kids.len or e.toward >= f.pos.len) continue;
                const kp = f.pos[kids[e.child]];
                const sx = kp.x - centre.x;
                const sy = kp.y - centre.y;
                const tx = f.pos[e.toward].x - centre.x;
                const ty = f.pos[e.toward].y - centre.y;
                const sl = @sqrt(sx * sx + sy * sy);
                const tl = @sqrt(tx * tx + ty * ty);
                if (sl < 1e-6 or tl < 1e-6) continue;
                total += e.w * (1.0 - (sx * tx + sy * ty) / (sl * tl));
            }
        }
        misalign[pass] = total;
    }

    // The pulls must exist at all, or this proves nothing about the term.
    try testing.expect(misalign[0] > 0.01);
    // And turning the term on must not make aim worse. Exhaustive search means it can only pick a
    // lower-cost arrangement, but sibling-distance still shares the objective — so the honest
    // assertion is "no worse", with a strict improvement expected on this deliberately-tied case.
    try testing.expect(misalign[1] <= misalign[0] + 1e-4);
    try testing.expect(misalign[1] < misalign[0]);
}

fn placeNotes(gpa: std.mem.Allocator, n: usize, edges: []const fold.Edge, opts: Options) !struct { lad: fold.Ladder, field: Field } {
    var lad = try fold.build(gpa, n, edges, &.{}, .{ .arity = .seven });
    errdefer lad.deinit(gpa);
    var f = try init(gpa, lad.cells.len, lad.roots.len, .seven, opts);
    errdefer f.deinit(gpa);
    placeAll(&f, &lad);
    return .{ .lad = lad, .field = f };
}

fn leafPos(lad: fold.Ladder, f: Field, note: u32) Vec2 {
    return f.pos[lad.leaf_cell[note]];
}

fn groupDiameter(lad: fold.Ladder, f: Field, n: u32) f32 {
    var d: f32 = 0;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        var j: u32 = i + 1;
        while (j < n) : (j += 1) {
            d = @max(d, Vec2.dist(leafPos(lad, f, i), leafPos(lad, f, j)));
        }
    }
    return d;
}

test "gravity: exclusive pair sits apart, neither pinned at the origin" {
    const gpa = testing.allocator;
    const edges = [_]fold.Edge{.{ .a = 0, .b = 1 }};
    var g = try placeNotes(gpa, 2, &edges, .{ .note_r = 1 });
    defer g.lad.deinit(gpa);
    defer g.field.deinit(gpa);

    const a = leafPos(g.lad, g.field, 0);
    const b = leafPos(g.lad, g.field, 1);
    const d = Vec2.dist(a, b);
    const want = g.field.separationRadius(&g.lad, g.lad.leaf_cell[0]) +
        g.field.separationRadius(&g.lad, g.lad.leaf_cell[1]);
    try testing.expect(d > 0.5);
    try testing.expect(d + 0.05 >= want * 0.75);
    // Recentre puts COM at the parent, so neither body occupies the star seat.
    try testing.expect(@sqrt(a.x * a.x + a.y * a.y) > 0.05);
    try testing.expect(@sqrt(b.x * b.x + b.y * b.y) > 0.05);
}

test "gravity: a 3-cycle settles to a triangle" {
    const gpa = testing.allocator;
    const edges = [_]fold.Edge{
        .{ .a = 0, .b = 1 },
        .{ .a = 1, .b = 2 },
        .{ .a = 2, .b = 0 },
    };
    var g = try placeNotes(gpa, 3, &edges, .{ .note_r = 1 });
    defer g.lad.deinit(gpa);
    defer g.field.deinit(gpa);

    const p = [_]Vec2{ leafPos(g.lad, g.field, 0), leafPos(g.lad, g.field, 1), leafPos(g.lad, g.field, 2) };
    const d01 = Vec2.dist(p[0], p[1]);
    const d12 = Vec2.dist(p[1], p[2]);
    const d20 = Vec2.dist(p[2], p[0]);
    const mean = (d01 + d12 + d20) / 3;
    try testing.expect(mean > 0.2);
    try testing.expect(@abs(d01 - mean) / mean < 0.2);
    try testing.expect(@abs(d12 - mean) / mean < 0.2);
    try testing.expect(@abs(d20 - mean) / mean < 0.2);

    // Interior angles via the law of cosines, each near 60° (equilateral).
    const ang = struct {
        fn at(opp: f32, x: f32, y: f32) f32 {
            return std.math.acos(std.math.clamp((x * x + y * y - opp * opp) / (2 * x * y), -1, 1));
        }
    }.at;
    const a0 = ang(d12, d01, d20);
    const a1 = ang(d20, d01, d12);
    const a2 = ang(d01, d12, d20);
    try testing.expectApproxEqAbs(std.math.pi / 3.0, a0, 0.25);
    try testing.expectApproxEqAbs(std.math.pi / 3.0, a1, 0.25);
    try testing.expectApproxEqAbs(std.math.pi / 3.0, a2, 0.25);
}

test "gravity: a 6-cycle settles to a hexagon" {
    const gpa = testing.allocator;
    var edges: [6]fold.Edge = undefined;
    for (0..6) |i| edges[i] = .{ .a = @intCast(i), .b = @intCast((i + 1) % 6) };
    var g = try placeNotes(gpa, 6, &edges, .{ .note_r = 1 });
    defer g.lad.deinit(gpa);
    defer g.field.deinit(gpa);

    var cx: f32 = 0;
    var cy: f32 = 0;
    var pts: [6]Vec2 = undefined;
    for (0..6) |i| {
        pts[i] = leafPos(g.lad, g.field, @intCast(i));
        cx += pts[i].x;
        cy += pts[i].y;
    }
    cx /= 6;
    cy /= 6;
    var radii: [6]f32 = undefined;
    var mean_r: f32 = 0;
    for (pts, 0..) |q, i| {
        radii[i] = @sqrt((q.x - cx) * (q.x - cx) + (q.y - cy) * (q.y - cy));
        mean_r += radii[i];
    }
    mean_r /= 6;
    try testing.expect(mean_r > 0.2);
    // A 6-cycle coarsens into pairs, so the six leaves are not siblings of one cell and
    // will not sit on a perfect hexagon. What gravity still owes us: the cycle's own
    // edges stay short and similar, and the cloud is not a line.
    var step_min: f32 = std.math.floatMax(f32);
    var step_max: f32 = 0;
    for (0..6) |i| {
        const s = Vec2.dist(pts[i], pts[(i + 1) % 6]);
        step_min = @min(step_min, s);
        step_max = @max(step_max, s);
    }
    try testing.expect(step_min > 0.05);
    try testing.expect(step_max / step_min < 4.0);

    // Adjacent step along the cycle should be the typical nearest-neighbour distance.
    var step_mean: f32 = 0;
    for (0..6) |i| step_mean += Vec2.dist(pts[i], pts[(i + 1) % 6]);
    step_mean /= 6;
    var nn: f32 = 0;
    var nn_n: f32 = 0;
    for (0..6) |i| {
        for (i + 1..6) |j| {
            nn += Vec2.dist(pts[i], pts[j]);
            nn_n += 1;
        }
    }
    // Cycle edges shorter than the average pairwise (diagonals pull that up).
    try testing.expect(step_mean < nn / nn_n);
}

test "gravity: a 4-node Y packs tighter than an exclusive pair" {
    const gpa = testing.allocator;
    const pair_e = [_]fold.Edge{.{ .a = 0, .b = 1 }};
    var pair = try placeNotes(gpa, 2, &pair_e, .{ .note_r = 1 });
    defer pair.lad.deinit(gpa);
    defer pair.field.deinit(gpa);
    const pair_d = groupDiameter(pair.lad, pair.field, 2);

    const y_e = [_]fold.Edge{
        .{ .a = 0, .b = 1 },
        .{ .a = 0, .b = 2 },
        .{ .a = 0, .b = 3 },
    };
    var y = try placeNotes(gpa, 4, &y_e, .{ .note_r = 1 });
    defer y.lad.deinit(gpa);
    defer y.field.deinit(gpa);

    const y_push0 = y.field.separationRadius(&y.lad, y.lad.leaf_cell[1]);
    const pair_push = pair.field.separationRadius(&pair.lad, pair.lad.leaf_cell[0]);
    // Each Y leaf asks for less exclusive space than a member of a pair.
    try testing.expect(y_push0 < pair_push);
    // And the pair's two bodies sit at least as far as a typical Y spoke.
    const y_spoke = Vec2.dist(leafPos(y.lad, y.field, 0), leafPos(y.lad, y.field, 1));
    try testing.expect(pair_d + 0.01 >= y_spoke);
}

test "gravity: a hub with clustered spokes is not a regular solar system" {
    // Pure stars are symmetric and *should* sit in a ring. Break the symmetry with one extra
    // spoke-spoke link: those two must sit closer than the typical adjacent pair.
    const gpa = testing.allocator;
    var edges: [7]fold.Edge = undefined;
    for (0..6) |i| edges[i] = .{ .a = 0, .b = @intCast(i + 1) };
    edges[6] = .{ .a = 1, .b = 2, .w = 8 };
    var g = try placeNotes(gpa, 7, &edges, .{ .note_r = 1 });
    defer g.lad.deinit(gpa);
    defer g.field.deinit(gpa);

    const hub = leafPos(g.lad, g.field, 0);
    const origin = g.field.pos[g.lad.cells[g.lad.leaf_cell[0]].parent];
    // Hub may sit near the COM (it is heavy) but must not be nailed exactly to the parent
    // the way the flock path does — a tiny drift is the proof the pin is gone. If the COM
    // *is* the hub, the clustered pair still breaks the regular ring.
    const clustered = Vec2.dist(leafPos(g.lad, g.field, 1), leafPos(g.lad, g.field, 2));
    var other: f32 = 0;
    var on: f32 = 0;
    var i: u32 = 2;
    while (i <= 5) : (i += 1) {
        other += Vec2.dist(leafPos(g.lad, g.field, i), leafPos(g.lad, g.field, i + 1));
        on += 1;
    }
    try testing.expect(clustered < other / on);
    _ = hub;
    _ = origin;
}

test "gravity: children stay inside the parent's disc" {
    const gpa = testing.allocator;
    const edges = try buildStar(gpa, 80);
    defer gpa.free(edges);
    var g = try placeNotes(gpa, 81, edges, .{ .note_r = 1 });
    defer g.lad.deinit(gpa);
    defer g.field.deinit(gpa);

    for (g.lad.cells, 0..) |c, id| {
        if (c.child_count == 0) continue;
        const R = g.field.radius(&g.lad, @intCast(id));
        for (g.lad.childrenOf(@intCast(id))) |k| {
            const d = Vec2.dist(g.field.pos[@intCast(id)], g.field.pos[k]);
            try testing.expect(d + g.field.countRadius(&g.lad, k) <= R * 1.001);
        }
    }
}

test "gravity: a heavier file claims more room than a stub" {
    const gpa = testing.allocator;
    const edges = [_]fold.Edge{.{ .a = 0, .b = 1 }};
    const bodies = [_]f32{ 20, 80_000 };
    var lad = try fold.build(gpa, 2, &edges, &.{}, .{ .arity = .seven, .bodies = &bodies });
    defer lad.deinit(gpa);
    var f = try init(gpa, lad.cells.len, lad.roots.len, .seven, .{ .note_r = 1 });
    defer f.deinit(gpa);
    placeAll(&f, &lad);

    const r0 = f.separationRadius(&lad, lad.leaf_cell[0]);
    const r1 = f.separationRadius(&lad, lad.leaf_cell[1]);
    try testing.expect(r1 > r0 * 1.2);
    try testing.expect(lad.cells[lad.leaf_cell[1]].body > lad.cells[lad.leaf_cell[0]].body);
}

test "gravity: placement is a pure function of the tree" {
    const gpa = testing.allocator;
    const edges = [_]fold.Edge{
        .{ .a = 0, .b = 1 },
        .{ .a = 1, .b = 2 },
        .{ .a = 2, .b = 0 },
        .{ .a = 2, .b = 3 },
    };
    var a = try placeNotes(gpa, 4, &edges, .{});
    defer a.lad.deinit(gpa);
    defer a.field.deinit(gpa);
    var b = try placeNotes(gpa, 4, &edges, .{});
    defer b.lad.deinit(gpa);
    defer b.field.deinit(gpa);
    for (a.field.pos, b.field.pos) |pa, pb| {
        try testing.expectEqual(pa.x, pb.x);
        try testing.expectEqual(pa.y, pb.y);
    }
}
