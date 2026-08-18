# Tile ↔ live handoff (historical)

**Superseded.** Product overview is `fold` + `containment` + `world` with `batch2d` sprites.
Density mips and impostor N-gon tiles were dual-system handoffs that popped or mismatched
configuration on dive; the `TileView` / `tileSwitchZoom` helpers were later removed from
`graph.zig` as unused.

This note remains as investigation of the earlier impostor bake/fade path — useful failure
modes (PMA double-ink, hold-under-bake, complementary dissolve). The call chain below does
not exist in the current sources.

## Call chain (one overview frame)

```
Panel.draw (overview branch)
  ├─ drawEdges(..., tiles.node_weight)     // live web fades with handoff
  ├─ drawNodes(..., tiles.node_weight)     // live discs fade with handoff
  └─ drawTiles(fade = 1 - interior.t)
       ├─ tileViewFor → TileView            // which octaves + weights
       ├─ atlas.begin(layout_epoch, style)
       ├─ tileLayersForDraw(+ hold + prefetch)
       ├─ bake missing slots (budgeted)
       │    gatherTileLinks → bakeTile → emitMarks into atlas Pass
       └─ QuadBatch: hold underlay, then desired levels
```

`updateSelection` sets `p.tiles = tileViewFor(p)` once per frame so notes, web, and tiles
cannot disagree about the scale in force.

## Zoom model

| Piece | Where | Meaning |
|-------|--------|---------|
| `tileSwitchZoom` | `graph.zig` | Zoom where tiles must hand to live notes — the `bubbleScreenRadius` gap crossing (world-proportional vs fixed screen size). |
| `tileDensity(level)` | `graph.zig` | `tileSwitchZoom * 2^(-level)` — level 0 = handover scale; each level out is an octave coarser. |
| `tile_fade_band` | `0.18` | Share of an octave spent cross-fading. Narrow because both sides sit near 1:1. |
| `out = log2(zs / zoom)` | `tileViewFor` | Octaves out from handover. `out ≤ 0` → live only (`node_weight = 1`). |

### Octave mix (`tileViewFor`)

1. **Just past handover** (`0 < out < fade_band`): live at full weight; level-0 tiles fade in over them (`weights[0] = out / fade_band`).
2. **Settled octave**: primary level at weight 1.
3. **Near midpoint between levels**: keep primary full strength; lay neighbour *over* it at up to `0.5` in the band — dissolve, not split-alpha (0.5+0.5 would dim the field).

### Hold under bake

Unbaked desired tiles are **not** drawn as sharp vector stand-ins (that flashes). Last ready
level (`tiles_hold`) stays under the target until `tile_ready_frac` (0.92) of primary tiles
are baked. Cold start (no hold) may emit direct field geometry once.

## Bake / atlas costs (current knobs)

| Knob | Value | Role |
|------|-------|------|
| `impostor.tile_px` | 128 | Slot size; smaller → more slots, more quads. |
| Atlas sizes | 4096 → 2048 | Target texture; wipe-only reclaim. |
| `bake_per_frame` | 48 | Steady bake tiles/frame. |
| `bake_per_frame_catchup` | 160 | While held or after atlas wipe (`bake_burst`). |
| `bake_mark_budget` | 120k (×4 catchup) | Marks across all bakes in a frame. |
| `max_tiles_per_frame` | 400 | Want-list cap (draw + bake candidates). |
| `direct_mark_budget` | 80k | Cold-start direct emit only. |

Bake path reuses the same CPU-tessellated disc/line batches as live draw (`DiscBatch` /
`LineBatch`), into an offscreen `Pass` — so bake cost scales with marks×tiles, not with a
GPU point path.

Links are gathered **across** tiles before bake (`gatherTileLinks`): a spoke with both ends
outside a tile still belongs in every tile it crosses; per-tile cluster-only gather left
rectangular holes.

## Where continuity can still fail (hypotheses to profile)

1. **Handoff pop at `tileSwitchZoom`** — live discs and finest tiles disagree in density,
   radius, or link weight; `node_weight` fade may be shorter / earlier than the eye wants.
2. **Bake lag under continuous zoom** — hold softens flashes but the field can look soft or
   “stuck” one octave while catchup runs; atlas full → clear + burst.
3. **Octave dissolve seams** — neighbour weight / `tile_fade_band` vs resampling (no mipmaps
   on `SDL_Renderer`); tiles answer resampling by staying near 1:1, so band width matters.
4. **Live web under tiles** — edges use `(1-t)*tiles.node_weight` so they dissolve with
   tiles; any mismatch in baked vs live link placement reads as double or ghost lines.
5. **Layout / style invalidation** — `layout_epoch` or `tileStyleHash` wipe forces cold bake;
   churn here looks like continuity failure.
6. **Mid-band web buried under opaque marks** *(addressed)* — bake draws marks then links;
   coarse fills use `tile_mark_fill_alpha`; web ink is `tile_link_alpha` from the first baked
   octave (`tile_bake_style` bumps the atlas).
7. **Octave pop from `@round` primary flip** *(addressed)* — `tileViewFor` blends with
   complementary weights and switches the pure band before the integer.
8. **Web ink “changes colour” each level** *(addressed)* — line alpha ~0.14; stacking two
   tile (or live+tile, or hold+primary) webs nearly doubles darkness via PMA. Fixes:
   complementary octave weights, live edges fade as `1 - tile_w`, hold underlay only where
   primary tile is not yet baked.

## Compatible upgrades (stay on atlas + `renderTriangles`)

Do these before any greenfield GPU graph renderer:

1. **Profile** around `tileSwitchZoom` and octave crossings: `frame_profile.tiles_*`,
   bake counts, hold time, draw call / triangle spikes.
2. **Richer / faster bake** — fewer marks per coarse tile (pyramid level already chosen via
   `tilePyramidLevel` / `levelForGap`); tighter mark budgets; avoid rebake storms.
3. **Better sampling / fade** — tune `tile_fade_band`, handover band, hold readiness; keep
   dissolve-over-full-strength (not split alpha).
4. **Denser live batching at handoff** — when `node_weight > 0`, keep discs on the triangle
   batch path so the live side of the fade does not cliff FPS.
5. **Prefetch / hold policy** — bake neighbours earlier; reduce clear+burst frequency.

Out of scope for the next spike: 1M live CPU-tessellated discs; new GPU point-sprite
backend (separate bet). 1M as tiles is the intended far path.

## Relation to retired harness spikes

| Approach | Verdict |
|----------|---------|
| `organic` / `cloud` / `leaves` in `render-gpu` | Look-failed; **removed** from harness modes/hotkeys |
| Pyramid `select` cross-fade (`--mode=lod`) | Still the harness control / budget check |
| Impostor tiles ↔ live in `graph.zig` | **Active continuity path** |

Parked sources: `src/ui/_parked/agents.zig`, `src/ui/_parked/cloud.zig` (not in default tests).
