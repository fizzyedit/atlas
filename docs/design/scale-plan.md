# Scaling to a million: findings, research, and a system breakdown

> Status: **analysis + proposal**, 2026-08-10. Nothing here has landed. Read
> [`galaxy-lod.md`](galaxy-lod.md) and [`organic-lod.md`](organic-lod.md) first — especially the
> rejected tables. This document does not overturn them; it explains *why* they failed in one
> sentence and builds on it.
>
> Update: the central proposal in Part 1 has since shipped, as `fold.zig` + `containment.zig` +
> `world.zig` in this repo rather than in `markworld`. See
> [`scale-architecture.md`](scale-architecture.md) for what actually runs; the status table in
> Part 6 is historical and understates what is built.

---

## Part 0 — Corrections to the working assumptions

### The 16k limit is not SDL3, and it is already solved

`batch2d/src/SpriteBatch.zig`:

```zig
/// `Vertex.Index` is u16 in this dvui pin.
pub const max_sprites: usize = std.math.maxInt(u16) / verts_per;   // = 16383
```

That ceiling is **dvui's vertex index type**, not an `SDL_Renderer` property.
`SDL_RenderGeometryRaw` takes a 32-bit index size and is happy with millions. dvui exposes
`-Dvertex-index=u32` as a build option — but its **web, raylib, and dx11 backends hard-reject
u32** (`dvui/build.zig` returns `error.IncompatibleVertexIndex`), and Fizzy ships a wasm32 target.
So u16 is permanent and app-wide. That is the honest constraint.

It also does not matter:

```zig
/// When set, `add` auto-flushes on u16 capacity so large bakes cannot drop sprites.
```

`SpriteBatch.add` already auto-flushes. Submitting 1M sprites costs 61 `SDL_RenderGeometryRaw`
calls. Sixty-one draw calls is not a bottleneck on any GPU made this century. **There is no reason
to move to SDL3-GPU on account of this**, and moving would cost the web target and the low-end
compatibility that motivated the software renderer in the first place.

The current overview budget is **280 marks**. That is roughly **1/60th of a single batch**. The
system is nowhere near its rendering ceiling.

### The GPU harness data is vsync-locked and has been hiding the real signal

`zig-out/organic-tour/tour-gpu.csv`, every row:

```
step,label,zoom,ms,fps,agents,...
4,in-4,0.0485,8.35,119.8,1032,...
9,in-9,0.5166,8.33,120.0, 272,...
18,out-8,0.0089,8.33,120.1,2076,...
```

`ms` is 8.33 and `fps` is 120.0 at 272 agents and at 2076 agents alike. That is the vsync
interval, exactly. **`tour-gpu.csv` can only ever prove "not worse than vsync."** It cannot
compare two renderers, and every conclusion drawn from it about rendering cost is unsupported.

The headless `tour.csv` — which measures select+step CPU only — carries the real signal. An earlier
reading looked like this (settle-averaged `ms`, which dilutes a one-shot select across spring
frames and made the asymmetry look like a multi-ms every-frame tax):

| step | zoom | avg ms | agents |
|---|---|---|---|
| in-3 | 0.0256 | 0.01 | 278 |
| in-6 | 0.1804 | 0.04 | 399 |
| out-2 | 0.1804 | 0.76 | 399 |
| out-3 | 0.0951 | 4.81 | 399 |

### Resolved: what `out-*` does that `in-*` does not

Instrumented in `Field.step` (`StepProfile`) + `selectStickyEx` (`SelectStats`), surfaced by
`zig build organic-tour` as `select_ms` / `first_ms` / `peak_open` / `trim_iters` / `sel_visited`.

At the **same zoom** (50k synth, ReleaseFast), the breakdown is:

| step | zoom | select_ms | present_ms | peak_open | visited | dying_peak |
|---|---|---|---|---|---|---|
| in-6 | 0.180 | **0.01** | 0.01 | 226 | 276 | 191 |
| out-2 | 0.180 | **0.40** | 0.01 | **390** | **439** | 124 |
| in-5 | 0.095 | 0.22 | 0.02 | 237 | 580 | 48 |
| out-3 | 0.095 | 0.23 | 0.02 | **383** | 580 | 48 |

**Findings:**

1. **The cost is select, not present.** `touch` / `markDying` / `integrate` / `purge` stay
   ~0.01–0.02 ms/frame even with hundreds of dying agents. Fade animation is not the hot spot.
2. **Zoom-out arrives with a deeper sticky-open set** (`peak_open` ~390 vs ~230). Hysteresis
   keeps those nodes on the `merge_px` threshold, so the level-uniform BFS wants more opens,
   visits more nodes, and spends longer resolving the living set. That is the asymmetry.
3. **`trimByMergingUp` is not the villain today** — `trim_iters` is 0–4. The walk itself +
   open-target collection under a deep sticky set is.
4. **Settle-averaged `ms` lied.** Springs keep `settled=false` for the whole `settle_frames`
   window, so the old column divided a one-shot select by 20. Read `select_ms` / `first_ms`.
5. At 200k, the worst select seen was **~1.0 ms** (`out-3`, collapsing 340 agents → 1 mass).
   Still the thing to watch toward 1M, but not a 5 ms every-frame tax.

**Fix landed:** `pruneStickyBelowSpan` runs before the BFS (always at `merge_px`; on zoom-out
also at `split_px` via `Field.last_zoom` so dive hysteresis cannot survive a large outward
step). Same-zoom tour after the fix (50k, ReleaseFast):

| zoom | in select / visited | out select / visited | ratio |
|---|---|---|---|
| 0.180 | 0.04 / 276 | 0.08 / **276** | 2.0× (was 46× / 439 visited) |
| 0.310 | 0.03 / 178 | 0.06 / **178** | 2.0× |
| 0.010 | 0.04 / 246 | 0.06 / **246** | 1.5× |

Visited counts now match. The residual ~2× is the prune pass itself folded into `select_ms`.
`dust_explode` on the outward leg is gone too (out-1 no longer dumps sticky into singles).

### Flecs will not help, and markworld already says so

markworld's own README:

> Topology (`lod.select`) decides the living set. Flecs only stores / moves / extracts those
> marks. **Never put the full vault into flecs.**

And its acceptance criterion: at 1M nodes, living ≤ ~900 and select/sync/draw stay sub-millisecond.
The experiment already succeeded — and what it proved is that **the entity count is capped by
design at ~900**, so ECS iteration cost is irrelevant either way. Iterating 900 structs is free in
any architecture.

The flecs "city with tons of 3D entities" demos are about *GPU instancing of many entities*. Here
the many entities never reach the GPU — the LOD tree collapses them first. That is the correct
design and it is why the renderer is already fast. Flecs buys **scheduling and composition
ergonomics** for the ~900 living marks, which is a real but modest benefit, and it buys nothing at
all on the 1M cold side.

Keep markworld. Use it for what it is good at: the cold SoA + ladder + select spine, decoupled
from dvui, testable headlessly. Do not expect throughput from the ECS.

### So where does 1M actually hurt?

| Stage | Scales with | Status at 1M |
|---|---|---|
| Draw | living set (≤900) | **fine, by construction** |
| Select | tree size + zoom direction | **the measured hot spot** |
| Layout | n log n multilevel, but constants are large | `--place layout` is already "costly past ~50k" |
| Index/build | n, once | needs measuring; probably fine |
| **Semantic quality of coalescing** | n | **the actual product problem** |

The last row is the one that matters most and the one no profiler will report.

---

## Part 1 — The central structural proposal

### The disorientation has a single cause

From the brief:

> It's very disorienting when a coalesced node contains some nodes from one cluster and some from
> another, if they aren't visually very close to the coalesced node. It's also disorienting to
> have a uniform field of nodes, and they coalesce some and not others.

Both symptoms are the same bug. **The LOD hierarchy is a point-region quadtree.** A quadtree
subdivides *space*. A cell is a rectangle. A rectangle drawn over a layout will happily contain
the tail of one island and the edge of another, because nothing in the tree knows what an island
is. Coalescing then merges unrelated notes, and the "density" the user reads off the field is
quadtree cell occupancy, not graph structure.

You cannot fix this by tuning. Every entry in the rejected table — density-first ordering,
`force_refine`, zoom-continuous merge, `merge_t` — is an attempt to make a spatial tree behave
semantically. That's why they all failed the same way.

### The fix: the LOD tree *is* the coarsening ladder

`markworld/src/layout/coarsen.zig` already builds exactly the right structure:

```zig
/// `maps[L][i]` = supernode index of level-L node i at level L+1. Level 0 = original graph.
pub const Ladder = struct { maps: [][]u32, counts: []usize };
```

Link-weighted heavy-edge coarsening: repeatedly merge *linked* pairs into supernodes. That is a
graph-community hierarchy. `brain/src/ui/multilevel.zig` builds the same ladder and uses it to
solve positions — and then **throws the ladder away**. Meanwhile `markworld/src/lod/tree.zig` is
still a point-region quadtree with `children: [4]u32`.

The proposal is one sentence: **stop discarding the ladder, and delete the quadtree.**

Every desirable property follows for free:

| Property | Why it falls out |
|---|---|
| A coalesced node always contains graph-related notes | Supernodes are built *by merging along edges* |
| Coalesced nodes sit where their contents are | The ladder's own refinement already computed a position per node per level |
| Split/join is well-defined and cheap | Split = project down one level, which the layout already does |
| Edge lift is exact | Coarse-level `WEdge` weights are already computed per level |
| Density reads true | Cell membership is community membership |
| Proactive semantic grouping | This *is* the proactive grouping the brief asks for |
| One tree for layout, LOD, and hit-testing | No two structures to keep in sync — the class of bug that killed every handoff |

**Caveat to design around:** heavy-edge matching is binary, so the ladder is ~log₂(n) deep — 20
levels at 1M. Too many for a zoom range. See the hex arity discussion below for the fix.

**Second caveat:** a quadtree gives view culling for free; a community tree does not. Keep a
*separate, dumb* spatial index (a uniform grid over the final positions) purely for "which marks
are on screen." Culling and LOD are different questions and should not share a structure — that
conflation is what made the quadtree look like a good LOD tree in the first place.

### The hex fold, made precise

> We want a hex grid that folds as we currently have, each level a superset of the next. I think we
> can use this somehow to our advantage (1 node at one level is a full hex of nodes at the next?)

That intuition is correct and it has a name. Hierarchical hex grids are classified by **aperture** —
the number of finer cells per coarser cell. Only three apertures give an exact sublattice of the
triangular lattice:

| Aperture | Scale | Rotation per level | Folds to 1M | Total spin | Nesting | Notes |
|---|---|---|---|---|---|---|
| **3** | √3 | 30° | 13 | 390° | exact (centers) | alternates orientation each level |
| **4** | 2 | 0° | 10 | 0° | exact (centers) | **what `hex.zig` does today** |
| **7** | √7 | 19.1066° | **8** | 152.9° | exact (centers) | the "1 hex + its 6 neighbours" intuition |

**Interactive prototype: [`aperture7.html`](aperture7.html)** — a real Eisenstein-generated fold you
can dive through, with an aperture 4/7 toggle and a camera counter-rotation toggle. Open it in a
browser.

`hex.zig` already documents its own case precisely:

> **Powers of two nest.** Scaling the basis by 2 yields a *sublattice*: `P(q,r)` at spacing `2s`
> is exactly `P(2q,2r)` at spacing `s`.

That is aperture 4. Aperture 7 is the one that matches the brief's mental model — a center cell
plus its six neighbours folding into one parent. It is the standard used by **Uber's H3** and by
hexagonal discrete global grid systems generally, where it's called *Class II* or *aperture-7*
hierarchy. The rotation is `atan(√3/5) ≈ 19.106°` per level, with scale √7.

Three things to know before choosing it:

1. **Centers nest exactly; areas do not.** The index-7 sublattice of lattice *points* is exact —
   which is all that matters here, because notes sit on lattice points. But the *region* boundary
   of a 7-fold cell is a fractal **Gosper island**, not a hexagon. H3 lives with "children are
   only approximately contained in their parent" for this reason. Since Atlas snaps nodes to
   points and draws rings rather than filled cells, this cost is avoided entirely — a genuine
   advantage of the current visual language.
2. **Each fold rotates the field by 19.1066°.** This is either the best or the worst property of
   aperture 7. A full 1M dive accumulates **152.9°**. For "fizzy bubbles + galaxy" it could be
   gorgeous — the field *turns* as it opens, like a spiral arm. It could also be nauseating.
   [`aperture7.html`](aperture7.html) exists to answer this; note in particular that
   counter-rotating the camera does **not** remove the spin, it only moves it out of the settled
   state and into the transition, where children arrive 19° off-axis and rotate into place.
3. **8 folds instead of 10 is a real win** for a 1M vault: each zoom octave does more work, the
   ladder is shallower, and there are fewer split events across a full dive.

Aperture 4 (status quo) is the safe choice and already works. Aperture 7 is the one that matches
the design intent. A hybrid — aperture 4 for the ladder, with the *visual* grid staying at
aperture 4 — is also available; the ladder arity and the lattice arity do not strictly have to
match, they just want to.

**Target the coarsening to the chosen arity.** Instead of binary heavy-edge matching, run a
constrained community pass (Leiden, or greedy modularity with a size cap) that targets ~4 or ~7
children per supernode. This is what turns a 20-level binary ladder into a 7-level hex ladder, and
it makes each level's cardinality predictable — which is what lets the mark budget map cleanly
onto a level.

---

## Part 2 — Research: bubbles

The visual language is not arbitrary. There is a real physics here, and it says the current
choices are right for reasons worth knowing.

### Hexagons are the ground state of a 2D foam

**Plateau's laws** (empirical 1873; proved by Jean Taylor, 1976) describe every equilibrium soap
film:

1. Films are smooth surfaces of constant mean curvature.
2. **Exactly three** films meet along an edge, at **exactly 120°**.
3. **Exactly four** edges meet at a vertex, at the tetrahedral angle `arccos(−1/3) ≈ 109.47°`.

In 2D, law 2 forces three edges per vertex at 120°. The only regular tiling satisfying that is the
**hexagonal honeycomb** — and Hales' proof of the **Honeycomb Conjecture** (1999) shows it is the
least-perimeter partition of the plane into equal areas.

**So: a hex lattice is what a 2D foam of equal bubbles relaxes into.** The grid and the bubble
metaphor are not two design choices that happen to coexist; the second implies the first. Worth
knowing when someone proposes replacing the lattice.

### Unequal bubbles → power diagram

When bubbles have different pressures (different sizes), the equilibrium partition is no longer a
Voronoi diagram — it is a **Laguerre / power diagram** (weighted Voronoi, where each site carries a
weight and the bisector shifts toward the smaller one). Equal weights degenerate to Voronoi, which
for a hex lattice of sites is exactly the honeycomb.

This is the right generalization for coalesced nodes of different masses. A power diagram over the
hex-snapped supernode centers, weighted by note count, gives cell boundaries that are physically
correct foam geometry — and it degenerates gracefully to the current uniform hex look when masses
are equal. Useful if cell *regions* are ever drawn (hover halos, selection framing, cluster
shading), which the brief hints at with "framing the open nodes and their connections."

### Young–Laplace, and the radius of a merged node

Pressure across a curved film: `Δp = 2γ/r` for one surface, `4γ/r` for a soap bubble (two
surfaces). Small bubbles are at higher pressure, so gas diffuses small → large. That is the
physical reason foams coarsen.

Merging conserves gas. In 2D, area conservation gives:

```
r_merged = √(r₁² + r₂²)     →     r(cell) = r_note · √count
```

**This is already what the code does** — `galaxy-lod.md` calls it "mass discs (count-scaled)" —
and it is worth recording that it is the physically correct law, not a tuning choice. It also
explains the rejected `max(√count, extent)` dual radius: mixing an area-conserving law with a
spatial-extent law creates two regimes with a flicker boundary between them. Pick the physical
one and soft-cap it; don't blend.

### von Neumann–Mullins: a merge criterion that comes for free

In a 2D dry foam, a bubble's area evolves according to **only its number of sides**:

```
dA/dt = κ (n − 6)
```

More than six neighbours → grows. Fewer → shrinks and eventually vanishes. Exactly six → stable.

This is a remarkably clean rule and it is directly applicable: **at any LOD level, a cell's
stability is a function of its neighbour count in the hex neighbour graph.** Cells with < 6
neighbours are the ones that want to merge away; 6-neighbour cells are stable. It gives a
principled, local, O(1)-per-cell answer to "which nodes should coalesce" that is neither a
threshold hack nor a global sort — and, being local, it cannot produce the non-deterministic
branch flicker that killed density-first ordering.

### T1 and T2: the only two transitions you need

Foam topology changes in exactly two ways:

- **T1 (neighbour swap)** — an edge shrinks to zero length and reopens perpendicular. Four
  bubbles exchange neighbours. Local, continuous, area-preserving.
- **T2 (bubble disappears)** — a three-sided bubble shrinks to a point and vanishes; its
  neighbours close the gap.

**These are exactly the two animation primitives the LOD needs.** T2 is a node coalescing away (or,
reversed, a node being born from a split). T1 is neighbours reordering as the layout settles.
Adopting this vocabulary buys a guarantee worth having: *if every topology change is expressible as
a T1 or a T2, then every topology change is local and continuous, and no global pop is possible.*
That is a much stronger invariant than "we cross-faded it," and it is testable — a transition that
can't be written as T1/T2 is a bug.

### Popping is a rim effect, not a fade

A film ruptures and the rim retracts at the **Taylor–Culick velocity** `v = √(2γ/ρh)` — fast, and
propagating *inward from the puncture*. Real bubbles do not fade uniformly; they unzip.

Directly usable: when a coalesced node bursts into its children, animate it as a **rim opening**,
not an alpha fade. The ring's dashed outline breaks at one point and retracts around the
circumference while children emerge behind it. Same cost as a fade, far better feel, and it makes
"pop" legible as an event rather than a dissolve.

### Soft-bubble repulsion for the mouse

For "nodes scale up near the mouse and push each other around": the standard model is the
**Durian bubble model** — bubbles are soft discs with a pairwise potential that is **exactly zero
beyond contact**:

```
F(d) = k · (1 − d/(rᵢ+rⱼ))^α   for d < rᵢ+rⱼ,   0 otherwise
α = 1 (harmonic) or 3/2 (Hertzian)
```

The finite support is the whole point: unlike gravity, it needs no far-field approximation, so a
uniform grid bucket makes it O(n) over the *living* set only — a few hundred marks. This is cheap
enough to run every frame.

> **Hard constraint:** this must be a **display-space post-transform only.** If mouse repulsion
> feeds back into stored positions, it changes the tree, which changes select, which breaks
> *"parked camera ⇒ the open set stops changing."* Offset at draw time; never write it back.

---

## Part 3 — Research: celestial mechanics

### Barnes–Hut is the same criterion you already use

Barnes–Hut (1986) computes n-body forces in O(n log n) by treating a distant tree cell as a single
point mass when `s/d < θ` (cell size over distance; θ ≈ 0.5–1.0).

The LOD's own rule is "open this cell when its **screen span** exceeds `split_px`" — which is
`s · zoom > split_px`, i.e. size-over-distance with the camera supplying the distance. **These are
the same criterion.** Worth stating explicitly because it means the layout solver and the renderer
can share one traversal and one opening decision, rather than maintaining two. (Fast Multipole gets
to O(n) but the constants and complexity are not worth it at these sizes.)

### Hill sphere: a principled "keep this group together" rule

A satellite is bound to its parent rather than stripped by the primary when it lies within the
**Hill radius**:

```
r_H = a · (m / 3M)^(1/3)
```

Mapped onto the graph: a sub-cluster of mass `m` at distance `a` from its parent cluster of mass
`M` should **stay coalesced** when its own spatial extent fits inside `r_H`. Outside it, the
sub-cluster has been "tidally stripped" and should be promoted to a peer cluster rather than shown
as part of its parent.

This is a scale-free, unit-free answer to the brief's "be proactive and group nodes that make sense
to group together," and it directly attacks the disorientation complaint: a group whose members
sprawl beyond their own Hill radius is exactly the group that reads as "these don't belong
together."

### Roche limit: the matching "split this group" rule

A body is torn apart when tidal shear exceeds self-cohesion:

```
d = R · (2ρ_M/ρ_m)^(1/3)
```

Mapped on: a cluster whose **internal edge density** is lower than the pull from its neighbouring
clusters should split, regardless of what the size threshold says. Roche is the split rule; Hill is
the keep rule. Together they form a symmetric, physically-motivated pair that replaces two
independent magic thresholds with one ratio — and ratios don't need retuning when the vault size
changes, which is precisely the failure mode of the current `split_px` / `merge_px` pair at scale.

### Spiral arms are density waves — a caution, not an idea

Galactic spiral arms are **density waves**; stars flow *through* them and the pattern rotates at a
different speed than the matter. The visual structure is not a material structure.

The relevant lesson is a warning. Density mips were rejected because the bake came from *leaf
positions* while the marks came from *sticky agent centroids*, so the dissolve landed on a
different configuration. The physics says the same thing in different words: **the density field
and the particle field are different objects and will not agree.** If a far-field density
representation is ever revisited, the only version with a chance is one baked *from the agent
centroids themselves* — the same objects that will be drawn on the other side of the handoff.

### Camera travel: use van Wijk–Nuij, not an ease curve

For "clicking a dashed node travels the camera, zooming in until the group explodes": the
established solution is **van Wijk & Nuij (2003), "Smooth and Efficient Zooming and Panning."** It
derives the optimal-path interpolation through combined pan+zoom space, parameterised by ρ (with
ρ ≈ 1.42 measured as perceptually optimal). It produces the effect where a long journey zooms *out*
first, arcs over, and zooms back in — which is exactly right for travelling between two distant
clusters, and which no ease curve on `(x, y, zoom)` will ever produce.

Kepler's second law (equal areas in equal times) gives a similar fast-near/slow-far feel and is
prettier to describe, but van Wijk–Nuij is the one that was actually designed for this problem.

---

## Part 4 — What Obsidian vaults actually look like

From the attached screenshot and the known shape of note graphs, relevant structural facts:

- **A large orphan population.** The outer ring in that image is unlinked notes — typically 20–40%
  of a real vault. They carry no structure, contribute nothing to a force solve, and generate most
  of the visual noise.
- **One giant connected component plus many tiny ones.** Heavy-tailed component size distribution.
- **Heavy-tailed degree distribution** with a few hub notes (MOCs / index notes).
- **High local clustering** — folders and topics produce dense triangles.
- **Folder structure is a strong prior that Obsidian ignores.** Atlas has the folder tree for free
  from the indexer.

Three implications:

1. **Exclude orphans from the solve entirely.** They cannot move usefully. Pack them
   deterministically on the hex lattice — by folder, on the rim of their folder's cluster. This
   removes ~30% of solve cost *and* most of the noise, and it makes orphans legible as "these are
   unfiled" rather than as a meaningless halo.
2. **`layout_full.zig` already has the folder prior** (`folder_k = 0.42`, folder-cohort attraction
   for same-directory notes). That is the right idea and it should be *promoted*: folder path
   should be a tie-break input to the community coarsening, not only a force. Coarsening with a
   folder prior gives clusters that match the user's own mental filing, which is worth more than
   any modularity gain.
3. **The screenshot's field is uniform because Obsidian has no LOD.** It is drawing every node. It
   looks good at that one zoom and has nothing to offer at any other. Fitting the elliptical panel
   and resizing dynamically — which Atlas does and Obsidian does not — is the more valuable
   property. Do not chase that screenshot.

### Shape-specific layout: the direct answer to "chains should look like chains"

> I think we are close visually, we just need a better layout system so chains look more like
> chains, spokes look like spokes, trees look more like trees.

**A general force solver will never do this.** Force-directed layout converges to a
minimum-energy blob; it has no notion of "this subgraph is a path and should be drawn straight."
The gauntlet's own shape list is the giveaway — `chain`, `hub-and-spoke`, `tree`, `grid`,
`bipartite` are named shapes because they *are* recognisably distinct, and a solver that treats
them identically will render them identically.

The fix is to detect the shape of each cluster's induced subgraph and dispatch to a dedicated
placement rule. Hex is unusually well suited here because it has **six exact directions**:

| Detected shape | Test | Hex placement |
|---|---|---|
| **Chain / path** | all degrees ≤ 2, ≤ 2 endpoints | straight along one of the 6 hex axes; gentle arc if it must fit the panel |
| **Star / spoke** | one node holds > 70% of edges | leaves on rings at 60° increments around the hub |
| **Tree** | \|E\| = \|V\| − 1, acyclic | recursive fan, each level ±60° from parent's direction |
| **Grid / lattice** | degree ≈ 4, high girth | direct hex-axis embedding |
| **Clique / dense** | edge density > ~0.5 | tight hex disc, no internal solve needed |
| **Anything else** | — | fall through to the multilevel solve |

Cheap (each test is one pass over a small induced subgraph), local (per cluster, not global), and
composable — the cluster's *position* still comes from the multilevel solve; only its *internal*
arrangement is special-cased. Five special cases will do more for perceived layout quality than any
amount of force-constant tuning, and they are independently testable against the gauntlet shapes
that are already named after them.

---

## Part 5 — The three systems, broken out

Per the brief: three subsystems that can be improved and tested independently, then composed. Each
gets its own harness, its own acceptance criteria, and — critically — its own *failure mode*, so a
regression is attributable.

### System 1 — Rendering

**Owns:** turning a living set into draw calls. **Must not own:** which cells are living.

The renderer is not currently the problem, so the work here is mostly *measurement* and *headroom*.

- **Establish the real ceiling.** Add a synthetic draw-only benchmark: N pre-positioned marks, no
  select, no layout, `--no-vsync`, measure ms/frame across N ∈ {1k, 10k, 50k, 200k}. Estimate is
  ~50k marks at an 8 ms budget (CPU vertex assembly dominating at roughly 40–60 ns/sprite), which
  would put the current 280 budget **~180× below the draw ceiling**. That number is a guess until
  it is measured, and measuring it is the prerequisite for the quality slider being anything but
  arbitrary. **`tour-gpu.csv` cannot answer this — it is vsync-locked.**
- **The quality/budget slider.** Expose the budget as a setting, but note the trap: topology is
  `f(tree, view, zoom, budget)`, so a continuously-dragged budget re-selects every frame and
  thrashes. Fix: **quantize the slider to discrete steps** (280 / 560 / 1120 / 2240 / 4480) and
  re-select only when a step boundary is crossed, cross-fading across it exactly like a zoom split.
  The contract survives: parked camera *and* parked slider ⇒ stable open set.
- **Split the budget.** One number currently governs marks, and edges are capped by a separate
  stride/degree rule. Marks, edges, and labels have different costs and different legibility
  ceilings; give them three budgets derived from one slider position.
- **Keep u16 and keep chunking.** Do not migrate to SDL3-GPU. If a future frame genuinely needs
  >16k marks, the auto-flush already handles it at a cost of one draw call per 16383.

**Acceptance:** ms/frame vs N curve is measured and monotone; no dropped sprites at any N; slider
step transitions produce no topology thrash; draw call count = ceil(marks/16383) + line batches.

**Failure mode to watch:** rendering work that quietly starts making LOD decisions. If
`galaxy.zig` ever needs to know what a cluster *is*, the layering has broken.

### System 2 — Layout

**Owns:** positions, the cluster hierarchy, and cell membership. This is where the product problem
lives and where most of the work is.

1. **Replace the point-region quadtree with the coarsening ladder** (Part 1). Single largest change.
2. **Target the ladder to hex arity** — constrained community detection at ~4 or ~7 children per
   supernode, rather than binary heavy-edge matching.
3. **Decide aperture 4 vs 7** by prototyping the rotation. Cheap to test; impossible to predict.
4. **Add a dumb uniform grid for view culling**, separate from the LOD tree. Different question,
   different structure.
5. **Orphans out of the solve**, packed deterministically by folder.
6. **Promote the folder prior** from a force to a coarsening input.
7. **Shape-specific placement** for chain / star / tree / grid / clique.
8. **Hill/Roche as the keep/split criteria**, replacing independent `split_px` / `merge_px`
   thresholds with a ratio that doesn't need retuning per vault size.

Extractable as **`fizzyedit/hexfold`** once it stabilises: hex lattice + aperture-N fold + ladder,
with no dvui and no vault types. `markworld` is already most of the way there — the split it has
today (cold SoA + ladder, no vault types in `lod/tree.zig`) is exactly the right seam.

**Acceptance:** every coalesced cell's members are connected in the induced subgraph (or explicitly
marked as an orphan pack); the ladder is ≤ 8 levels at 1M; gauntlet `chain` renders as a visible
chain, `hub-and-spoke` as visible spokes, `tree` as a visible tree — judged by eye against the
existing gauntlet corpus, which is exactly why those shapes exist.

**Failure mode to watch:** a second structure creeping back in alongside the ladder. Every rejected
approach in the design docs was a dual-system handoff. One tree.

### System 3 — Animation

**Owns:** how the determined living set *appears* over time. **Must not own:** anything discrete.

- **T1/T2 as the only topology transitions.** Adopt the vocabulary and enforce it — a transition
  that can't be written as a T1 or a T2 is a bug, not a special case.
- **Split animation is free in the new structure.** The 7 (or 4) children of a cell are *in that
  cell*, and their positions are already known from the ladder. Emerge from the parent's pose to
  the known target; no second rendering system, no bake, no handoff. This is why the ladder change
  fixes animation as well as semantics.
- **Rim-retraction pops** rather than alpha fades (Part 2).
- **van Wijk–Nuij camera travel** for click-to-frame (Part 3).
- **Durian-model mouse repulsion**, display-space only, grid-bucketed over the living set.
- **Keep the existing keep-alive-and-refit behaviour** on graph switch. It works and it is the
  right instinct.
- **Budget-step transitions** get the same treatment as zoom splits — one mechanism, not two.

**Acceptance:** the invariants from `organic-lod.md` hold unchanged — parked camera gives identical
agent keys for N frames; monotone dive never decreases count via closes; idempotent select. Plus:
every transition in a recorded dive classifies as T1 or T2.

**Failure mode to watch:** animation state leaking into the select input. The moment a spring
position influences a topology decision, "parked camera ⇒ stable" is gone and the idle-explode
class of bug returns.

---

## Part 6 — Suggested order

Sequenced so each step is independently verifiable and the riskiest structural change is de-risked
by measurement first.

| # | Work | Status | Why here |
|---|---|---|---|
| 0 | **Measure a real vault's component structure** (`bench --stats`) | in progress | Decides whether the never-coarsen-across-components rule survives contact — see the percolation finding below |
| 1 | Fix the harness: `--no-vsync` + draw-only bench | todo | Everything downstream needs honest numbers, and today there are none |
| 2 | Instrument select in/out separately; explain `out-3` = 4.81 ms | **done** | Instrumented; root cause = deep sticky on zoom-out. `pruneStickyBelowSpan` at split_px on outward steps; visited counts now match in/out |
| 3 | Prototype aperture-7 rotation, visually | **done** | [`aperture7.html`](aperture7.html); outcome: build arity-agnostic, defer the call |
| 4 | Ladder-as-LOD-tree in `markworld`, headless, against gauntlet | **done (MVP + eye-check)** | `coalesce` @ 1M: ladder_levels=9, living=701/900, select=0.01ms. `zig build gauntlet`: chain/hub/tree read correctly by eye (PPMs in `markworld/zig-out/gauntlet/`). Impure leftover packs on hub/tree still WARN — need orphan tagging (#5) |
| 5 | Orphan extraction + folder-prior coarsening | partly | `vault_synth.zig` now emits a component-derived folder tree + `bridge_frac`; gauntlet purity WARN = unmarked leftover packs |
| 6 | Shape-specific placement for the 5 named shapes | partly | markworld `place.synth`: chain / hub / tree / islands done; grid + clique still open |
| 7 | Quality slider with quantized steps | todo | Needs #1 to pick sane step values |
| 8 | T1/T2 animation vocabulary + rim pops + van Wijk–Nuij camera | todo | Needs #4 landed, since split animation depends on the ladder |
| 9 | Extract `fizzyedit/hexfold` | todo | Only once #4–#6 have stopped moving |

Step 0 is the gate. Step 4 is the load-bearing one. **Arity (4 vs 7) stays a parameter through #4**
— the ladder work is identical either way; only the slot count and the per-level rotation differ,
so the decision can be made later against real data with real animation.

## Part 7 — What the prototype cost, and what it will cost again

[`aperture7.html`](aperture7.html) went from a bare lattice to a seeded vault with links. Five
problems surfaced. Four are rules already written in [`organic-lod.md`](organic-lod.md) that a fresh
implementation simply will not have; expect to pay for each one again in Zig.

| Rule | What it looks like when missing |
|---|---|
| **Bundle same-component leftovers when coarsening** | Around a hub, every leaf's neighbours get claimed, so nearly all become singleton groups and pass through unchanged. Ladder came out **24 levels deep instead of 5**. `markworld/src/layout/coarsen.zig` uses heavy-edge matching and *will* hit this — scale-free vaults are exactly hub-shaped. Not in any doc; new. |
| **Cull inside select, not at draw** | The whole vault sits on the open-candidate list, the budget test never passes, and the dive stalls partway with nothing but coalesced rings. Children live inside their parent's radius, so the off-screen test is exact. |
| **Level-uniform opening** | Biggest-first-until-budget leaves identical neighbours resolved differently by visit order — the half-fine/half-coarse seam. |
| **Never force-close an open cell at the budget wall** | Closing frees budget → reopen → exceed → close. Visible judder at max zoom. Refuse only *new* opens. |
| **A note is a fixed screen size** (`note_r_px`) | Zoom-scaling notes like masses turns the close view into overlapping discs with the links buried. Only masses are count-and-zoom scaled, and soft-capped. |

And one that is not in any document, worth adding to the acceptance list:

> **The far end of the zoom range must overshoot** the point where the budget could just about hold
> the visible notes. Landing exactly there stalls one level short, because opening that last level
> costs `arity`× what the level above did. Size max zoom off the budget, then multiply by ~1.7.

## Part 8 — The assumption Step 0 is testing

Sweeping cross-island bridges on a seeded 2,193-note vault (islands, avg degree 3, seed 7):

| bridges | components | largest as % of vault |
|---|---|---|
| 0.0% | 29 | 18% |
| 0.2% | 25 | 37% |
| **0.4%** | 22 | **52%** |
| 0.8% | 18 | 74% |
| 5.0% | 9 | 83% |

Four extra links per thousand notes take the largest component from 18% of the vault to 52%.

### Real data settled it: don't build on components

Measured on **Simple English Wikipedia** — 283,997 articles, 3,682,542 undirected wikilinks, parsed
from the dump's own `[[…]]` syntax:

| Measure | Value |
|---|---|
| Largest component | **100.0%** of linked articles (second largest: 2 nodes) |
| Largest after removing top 100 by degree | **99.9%** |
| Degree exponent τ1 | **2.25** (mean 25.9, median 11, max 31,044) |
| Average local clustering | **0.27** |
| Linked pairs sharing ≥1 category | **8.6%** vs **1.93%** random baseline |

It is **one web**, not islands stapled together by map-of-content notes — removing the hundred
most-linked articles barely dents it. **The never-coarsen-across-components rule is therefore not
load-bearing and should not be built on.** Use modularity communities (Leiden) *within* the giant
component; components remain useful only for the orphan pile and genuinely detached notes.

**Caveat that must travel with these numbers:** Wikipedia is far denser than a personal vault (mean
degree 25.9 against a vault's 3–8) and links every proper noun. This is an *upper bound* on
connectedness and a calibration of **shape only** — never of absolute degree.

### Two generator gaps this exposed — and the `lfr` shape that closes them

| Property | Real | `scale-free` (BA) | `lfr` (new) |
|---|---|---|---|
| Degree exponent | τ1 ≈ **2.25** | MLE ≈ 2.75; max degree explodes (4697 @ 20k) | planted `tau_degree=2.25`; √n cap keeps max≈90 @ 20k |
| Avg local clustering | **0.27** | ≈ 0.08 | **≈ 0.24** (wedge-closing pass; config-model alone was ≈0.01) |
| Hub fragility @ K=50 | 99.9% remain | 98.2% remain, but **342 components** (spokes orphaned) | **97.9% remain, 414 components** (≈400 are the planted orphans) |

`zig build bench -Doptimize=ReleaseFast -- --stats synth:20000:scale-free:6 synth:20000:lfr:6`
is the acceptance comparison. `lfr` is the shape to tune LOD against; `scale-free` stays as the
pathological mega-hub control.

**New `Spec` fields** (in `src/ui/vault_synth.zig`, `lfr` only):

| Field | Default | Role |
|---|---|---|
| `tau_degree` | `2.25` | Wikipedia MLE |
| `tau_community` | `2.7` | community-size exponent |
| `mu` | `0.3` | fraction of links that leave the planted community |
| `community_min` / `community_max` | `8` / `400` | planted community size bounds |

Ground-truth community ids land on `Graph.communities` (`orphan_community` sentinel for loners
and for every non-`lfr` shape), so the coarsening ladder can later be scored with NMI/purity
instead of eyeballing.

The category lift (4.5× over random) is weak but real, and independently validates
`folder_k = 0.42` in `layout_full.zig` as a soft nudge rather than a dominant force.

**Still open:** a *measured* μ from real data. Wikipedia categories are too fine-grained
(median 2–3 members → μ ≈ 0.95–0.98 under every partition rule tried). Getting a usable μ
needs Leiden over the giant component. Until then the acceptance matrix is "budget holds and
ladder depth stays ~log_arity(n) for μ ∈ {0.05, 0.15, 0.3, 0.5}", not a single guessed value.

---

## References

- Plateau (1873); **J. Taylor**, *The structure of singularities in soap-bubble-like and
  soap-film-like minimal surfaces*, Ann. Math. 103 (1976) — proof of Plateau's laws.
- **T. Hales**, *The Honeycomb Conjecture* (1999) — hex is the least-perimeter equal-area partition.
- **von Neumann** (1952) / **Mullins** (1956) — `dA/dt = κ(n−6)` in 2D foams.
- **Weaire & Hutzler**, *The Physics of Foams* (1999) — T1/T2 transitions, dry foam structure.
- **Durian** (1995) — soft-disc bubble model with finite-support contact forces.
- **Taylor** (1959) / **Culick** (1960) — film rupture rim velocity.
- **Aurenhammer** (1987) — power/Laguerre diagrams.
- **Barnes & Hut** (1986) — O(n log n) n-body via tree opening angle.
- **Sahr, White & Kimerling** (2003) — discrete global grid systems, aperture-3/4/7 hex hierarchies;
  Uber **H3** is the aperture-7 implementation in wide use.
- **van Wijk & Nuij** (2003) — *Smooth and Efficient Zooming and Panning*, InfoVis.
- **Traag, Waltman & van Eck** (2019) — Leiden algorithm (guarantees well-connected communities,
  which Louvain does not — the guarantee matters here, since a disconnected "community" is exactly
  the disorientation bug).
- **Hu** (2005) — multilevel force-directed layout; the ladder pattern `multilevel.zig` implements.
