# Galaxy LOD v1

> **Superseded.** The quadtree/agent LOD described here was replaced by `fold` + `containment` + `world`; `quadlod.zig`, `quad_agents.zig` and `lod.zig` no longer exist. Kept for the rejected-approach tables, which still hold. For how the system works now see [`scale-architecture.md`](scale-architecture.md).
>
> The harness commands, build steps and file paths below no longer resolve either; read this for the rejected mechanisms, not for anything runnable.

Product overview path for Atlas’s note map. One visual language of **soft textured sprites**
(`batch2d`) over discrete sticky topology (`quadlod.selectSticky`); motion is presentation-only
(`quad_agents`). Split/join of living cells is the LOD language end-to-end.


## Contract

> **Given (tree, view, zoom, budget), the set of living cells is determined. Motion only
> interpolates how those cells appear.**

| Layer | Owns | Must not own |
|-------|------|----------------|
| `quadlod` | Hierarchy, sticky select, edge lift | Springs / draw |
| `quad_agents` | Agent poses/radii; settle skip; edge cache | Whether a cell is open |
| `galaxy` / `batch2d` | Soft atlas, `drawStyledMarks`, line batches | Topology |
| Draw / hit / proximity | Paint living set; hover tint/scale in-batch | LOD decisions |

Parked camera ⇒ open set **stops changing**.

## Bands

| Band | Selection | Draw |
|------|-----------|------|
| Far / mid | `selectSticky` + agents | Mass discs (count-scaled) + lifted edges |
| Near (notes) | Leaf agents in view | Disc + ring sprites; proximity tint/scale |

## Budgets

| Context | Mark budget | Notes |
|---------|------------:|-------|
| Plugin overview | `plugin_mark_budget` (280) | Headroom for labels / proximity / interior |
| Harness stress | `mark_budget` (900) | 500k synth FPS gate only |

Select view pad ≈ 0.2× screen. Zoom/view quantized in `quad_agents.step`. Lifted edges use
`lod.no_edge` and a short length floor (~4px) so mass webs stay visible.

## Parked: density mips

World-tile density atlases (`galaxy.Density`, `density_enabled = false`) were tried as a far-field
underlay. They failed the same way as the old impostor path:

- Bake from leaf positions ≠ sticky agent centroids → dissolve lands on a different configuration
- Upscaled low-res tiles go blurry on dive before agents take over
- Tile seams / UV cuts through clusters
- Live web was skipped while density-primary → no readable connections

Code remains behind `density_enabled` for experiments; product overview does not draw it.

## Batching layer

`SoftAtlas`, `SpriteBatch`, `LineBatch`, `Camera`, `HitIndex` — vendored in-tree at
`src/batch2d/`, built against whichever `dvui` module the consumer supplies.

## Rejected (still)

See [`organic-lod.md`](organic-lod.md) rejected table, plus:

| Mechanism | Why |
|-----------|-----|
| CPU N-gon `DiscBatch` for overview | Vertex fill cliffs under Release zoom |
| Live discs + differently styled impostors | Dual-system pop |
| Density mip dissolve under sticky agents | Dual-system pop (blurry texture → wrong dots) |
| Zoom-continuous merge / interactive coalesce | Budget thrash |
| Path-stroked dashed rings at scale | Draw-call cliffs |

## Acceptance

### Harness

1. `render-gpu --mode=galaxy --frames=90` @ 50k overview: ≤ ~8.3 ms frame, few draw calls.
2. `--tour` ReleaseFast @ 500k: no `slow_frame` / `dust_explode` across overview↔close.

### Plugin overview

1. Soft-sprite agents + lifted edges only; no impostor tile draw while `agents_active`.
2. One mark language through zoom (split/join only) — no density underlay.
3. Labels only when `notes_at_level0 > 0`; proximity only on leaf agents.
4. Mass click → `frameCluster`; note click uses **living agent poses** (same as hover).
5. Idle parked camera: select skipped when quantized view/zoom unchanged and field settled.
6. Marks ≤ `plugin_mark_budget`; edges degree/stride capped.

### Gauntlet (Fizzy)

Open each shape under `fizzyedit/gauntlet/vault/<shape>` as the vault root. Order:

1. `islands` → 2. `scale-free` → 3. `hub-and-spoke` + `dense-cluster` → 4. `bipartite` →
5. `grid` → 6. `tree` / `chain` / `orphans` → 7. `giant-docs` / `edge-cases` → 8. full `vault/`.

Per shape (interactive): settle FPS, dive continuity, pan/resize without LOD seam, mass vs note
click, labels near notes, open note → interior still works.

Headless gate (layout + plugin LOD path, no window):

```
zig build bench -Doptimize=ReleaseFast -- --galaxy \
  …/gauntlet/vault/islands …/gauntlet/vault/scale-free … # per shape, then full vault/
```

Asserts agents ≤ `plugin_mark_budget` (280), non-empty living set, settle within 90 frames at
overview and dive. Regenerated vault + smoke (2026-08-09): all shapes + full `vault/` (~10.9k)
passed; peak overview agents ~210 (`bipartite`), dive ~268 (`scale-free` / `bipartite` / `tree`).

### Scale simulator (100k–1M, in-memory)

Gauntlet stays ~10k on disk for correctness. Large Obsidian-class vaults are simulated without
writing markdown.

**In Fizzy (preferred for interactive LOD work):**

1. Command palette → **Atlas: Vault Simulator** — a floating window with live controls for note
   count, shape, and average degree; changes apply immediately, with no rebuild.

Raise N toward 1 000 000 and slide avg degree to thin/thicken links. Galaxy must stay within
`plugin_mark_budget` and settle under pan/zoom.

**Headless gate:**

```
# Shape + N + mean degree. Pack placement — Galaxy/LOD at scale.
zig build bench -Doptimize=ReleaseFast -- --galaxy --place pack \
  synth:100000:islands:4 \
  synth:100000:islands:8 \
  synth:500000:islands:3 \
  synth:1000000:scale-free:2

# Full force-layout curve (costly past ~50k):
zig build bench -Doptimize=ReleaseFast -- --place layout synth:20000:scale-free:3
```

Spec: `synth:N[:shape[:avg_deg]]` with shapes `scale-free|islands|hub|bipartite|chain|orphans`.
See `src/ui/vault_synth.zig`, `src/bench_main.zig`, and `State.loadSynth`.
