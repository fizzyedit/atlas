# Organic LOD: Stable v1 (topology spine)

Budgeted keep-alive masses over a **point-region quadtree**. Topology + agent presentation for
the overview; **drawing** is now Galaxy LOD soft sprites — see [`galaxy-lod.md`](galaxy-lod.md).

Harness: `render-gpu --mode=organic` (legacy DiscBatch agents) or `--mode=galaxy` (product path).
Zoom tour: `--tour` (galaxy) below.

## Contract

> **Given (tree, view, zoom, budget), the set of drawn cells is determined. Motion only interpolates how those cells appear.**

| Layer | Owns | Must not own |
|-------|------|----------------|
| `quadlod` | Hierarchy, count, centroid, spread, edge lift, **selectSticky** | Springs |
| `quad_agents` | Agent poses/radii chasing targets; birth at parent | Whether a cell is open |
| Draw / hit / web | Paint living set; lift edges | LOD decisions |

Parked camera ⇒ open set **stops changing**. That is the reliability bar.

### Select rules (only topology brain)

1. Cull by view at entry; once a parent opens, **all** children are enqueued. Off-screen
   siblings stay in the living set as closed marks (not dropped) so pan/resize cannot leave a
   half-fine / half-coarse seam through a cluster. Select views are also padded (~0.4× screen).
2. May open if children exist and `screenSpan(zoom) > split_px` (merge hysteresis uses `merge_px` when already open).
3. **Leaf rung:** opening into note leaves requires `~2.8×` the usual threshold so mid-zoom stays masses instead of dissolving into dust / FPS cliffs.
4. Budget: **level-uniform BFS** — at each depth open all want_open cells or none (per-node opens refined the first-built / upper hemisphere and left the opposite half coarse). Opens must fit in `budget`. Over-budget safety ⇒ **merge up** (never drop marks).
5. **No** refine_hold, open_frozen, cooloff, per-group locks, opens_per_frame, zoom-ratio state machine, or density-sort side effects.

### Zoom tour harness

Reproduce the “zoom in → dust → FPS dies” path without hand-driving the window:

```bash
# Headless: select/step timing + diagnostic PPM maps
zig build organic-tour -Doptimize=ReleaseFast -- [N]

# Windowed: real GPU FPS while auto-zooming overview ↔ close
zig build render-gpu -Doptimize=ReleaseFast -- --mode=organic --tour [N]
```

Writes under `zig-out/organic-tour/`:

| Artifact | Meaning |
|----------|---------|
| `tour.csv` / `tour-gpu.csv` | Per-step zoom, timings, agent/single counts, radius span, warn flags |
| `step-*.ppm` / `gpu-*.ppm` | Software LOD map (masses blue, notes grey) at that zoom |

Headless `tour.csv` also records a select/present breakdown: `first_ms`, `select_ms`,
`present_ms`, `frames_ran`, `peak_dying`, `peak_open`, `trim_iters`, `sel_visited`. Prefer
`select_ms` over settle-averaged `ms` when comparing zoom-in vs zoom-out — springs keep every
settle frame "running" and dilute a one-shot select. See scale-plan.md ("Resolved: what out-*
does that in-* does not").

Warn flags: `slow_frame` (>33 ms), `dust_explode` (near budget and majority singles), `radius_runaway` (max r > soft-cap). Headless exits 2 if any warn fires.

### Presentation

- One agent per living **closed** cell.
- Target pose = centroid (live note pos for singletons).
- Target radius: **count==1 → uniform `note_r_px`**; multi-note → `zoom × spread × cover_k`, **soft-capped (~40px)** so unsplit cells cannot inflate forever on dive.
- Birth: merge ← children COM; split ← parent pose. Overdamped springs.
- Retire: fade into living parent (or collapse in place), not instant pop.
- Web: `liftEdges` climbs each note to the nearest **living** agent (skip dying/sticky ghosts). Strided + per-agent degree cap so one dense island cannot monopolize the edge budget.
- Parked camera: skip re-select (reuse living set). Already-open parents are not forced closed at the budget wall (that flip was the idle explode loop).
- Zoom-out sticky prune: before select, clear open bits whose span is ≤ `split_px` when the
  camera is moving outward (`Field.last_zoom`). Stops dive hysteresis from making the BFS
  re-descend — without this, same-zoom select was ~46× slower on the way out.

### Product behaviour

| Zoom | Overview | Interior |
|------|----------|----------|
| Out | Few large dashed masses | Sun / parent |
| Mid | Cell-split into medium blobs | Lattice descent |
| In | Notes (solid); click opens doc | Sections fill panel |

Click mass → `frameCluster` → next split. Dashed = mass/sun; solid = note.

## Module map

| File | Role |
|------|------|
| `src/ui/quadlod.zig` | Tree + `selectSticky` + edge lift |
| `src/ui/quad_agents.zig` | Thin present layer |
| `src/ui/organic_tour.zig` | Shared zoom-tour metrics / CSV / PPM |
| `src/organic_tour_main.zig` | Headless tour exe |
| `src/ui/graph.zig` | Plugin overview (draws via `galaxy` / batch2d) |
| `src/ui/galaxy.zig` | Soft sprites (density mips parked) |
| `src/render_gpu_main.zig` | Interactive + `--tour` GPU harness |
| `src/ui/lod.zig` | Pyramid for `--mode=lod` only |
| `src/ui/_parked/agents.zig` | Retired pyramid field |
| `src/ui/_parked/cloud.zig` | Retired leaf-cloud LOD (look-failed) |

## Rejected (do not reintroduce without a new design note)

| Mechanism | Why rejected |
|-----------|----------------|
| Global afford / `levelFor` open policy | Far dust; dive → undersized singles |
| Sticky global `lf` both directions | Collapse-then-explode on flicker |
| `refine_hold` + freeze + cooloff + locks | Competing loops; pan thrash |
| Zoom-continuous merge progress | Permanently part-merged; 8× marks |
| `merge_t` gating topology | Topology must be discrete |
| `forceCloseDescendants` cascade | Singleton hub panic |
| `mark_max_mult=12` as sole size | Speck masses |
| `max(√count, extent)` dual radius | Size flicker between regimes |
| Density-first open ordering | Non-deterministic branch flicker under budget |
| `force_refine` open-every-multi when span>~18px | Filled budget with dust; thrash with budget wall |
| Budget force-close of already-open parents | Idle reopen forever (explode at rest) |

## Acceptance tests

1. Parked camera: agent keys/counts identical for N frames after settle.
2. Monotone dive: zoom-in never decreases count via closes.
3. Budget: `agents.len ≤ budget` always.
4. Idempotent select: same inputs ⇒ same node id list.
5. Harness: overview O(tens–hundreds) masses; dive one mass → children, stable.
6. Tour: `organic-tour` / `render-gpu --tour` clean of `dust_explode` / `slow_frame` across overview↔close.
