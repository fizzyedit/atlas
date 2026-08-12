# How Atlas holds a Wikipedia-scale vault

> Status: **what shipped**, 2026-08-14. The companion to [`scale-plan.md`](scale-plan.md), which is
> analysis and proposal. This one describes the system as it actually runs.
>
> Reference corpus throughout: a Simple English Wikipedia import — 286,546 notes and 3,083,114
> links, flat, produced by `src/wiki_import.zig`. Every number below was measured on it.

---

## The idea in one sentence

Opening a vault is allowed to take minutes and hundreds of megabytes. **Drawing a frame is not
allowed to depend on how big the vault is.**

Those are two different budgets, and most of the confusion about this system comes from mixing them
up. So, plainly:

- **Loading is O(N).** Every note and every link is read off disk, written to SQLite, and later
  materialized in memory. There is no way around this — you cannot know the shape of a graph without
  reading all of it.
- **Drawing is O(budget).** A frame draws at most ~360 marks and ~900 links, whatever N is. Ten
  notes and a million notes cost the same to display.

Everything below is either "how the loading stays off the UI thread" or "how the frame stays bounded".

---

## Where the data actually lives

Follow one note — `Paris.md` — from disk to screen.

### On disk: the vault, then the index

The markdown file is the source of truth. The index (`~/Library/Caches/fizzy/atlas/<hash>/index.db`)
is a derived cache — delete it and it rebuilds. For the reference corpus it is **409 MB** of SQLite
holding eight tables:

| table | rows | what it holds |
|---|---:|---|
| `notes` | 286,546 | one row per note: path, stem, title, mtime, size, hash, phantom flag |
| `links` | 3,083,114 | one row per wikilink: source, resolved destination, raw text, line, column, context |
| `blocks` | 1,220,821 | paragraph/code/list spans, for the interior view |
| `headings` | 1,009,602 | every heading, with its line |
| `tags` | 205,469 | every `#tag`, with its line |
| `aliases`, `media`, `meta` | — | front-matter aliases, attachments, schema version |

### In memory: only the skeleton

**This is the part your question is really about.** The snapshot does *not* copy the database. It
copies the two columns of the two tables that describe graph *shape*:

```
notes  ──> SnapNode { id, path, title, phantom }        286,546 × 48 B  ≈  13.7 MB
                     + the path and title strings                       ≈  10.2 MB
links  ──> SnapEdge { src_id, dst_id }                3,083,114 × 16 B  ≈  49.3 MB
                                                                          ───────
                                                                          ≈  73 MB
```

That is ~18% of the 409 MB index. Everything else — every heading, every block, every tag, and for
links the raw text, line, column and surrounding context — **stays on disk**. Those are queried one
note at a time, on demand: `backlinksFor` when the backlinks pane draws, `noteContentGraph` when you
descend into a note's interior. A note you never open costs nothing beyond its skeleton.

So the answer is: no, the whole DB is not copied — but the whole *graph* is, because there is no
useful subset of a graph. You cannot decide which nodes matter without the edges, and you cannot
decide which edges matter without the nodes.

### Why it is copied at all (and three times over)

The copies exist because of a **thread boundary**, not because drawing needs them.

1. The indexer worker builds the snapshot into its own arena. It has to own this memory, because the
   UI thread will read it while the worker is already writing the next one.
2. `snapshotCopy` deep-copies it into the layout job's arena. Returning borrowed slices instead is a
   use-after-free the moment a reader holds them across two commits — and a rebuild on a large vault
   takes far longer than that.
3. `finishRebuild` turns it into `p.nodes` (`GraphNode`, ~160 B each — the animation state: position,
   radius, hover, label slot) and `p.edges`.

Add the 2-deep snapshot ring and the peak during a rebuild is a few hundred megabytes. That is the
real memory cost of this design, it is known, and the next scale step is removing the per-note
`GraphNode` entirely — it exists so that every note *could* be individually animated, when at most a
few hundred ever are at once.

### On screen: a few hundred marks

Of those 286,546 nodes, a frame draws at most `mark_budget` of them — **360 by default**, 4,000 at
the slider's maximum. The rest are represented by coalesced masses: one dashed circle standing for a
whole region, sized by `√count`.

---

## The pipeline

Five stages. Two run on workers, three run per frame. The per-frame three never touch N.

```
disk ──(1)──> SQLite ──(2)──> Snapshot ──(3)──> World ──(4)──> marks ──(5)──> screen
      worker           worker            worker         frame          frame
      O(files)         O(N+E)            O(N+E)         O(budget)      O(budget)
      ~70 s            seconds           seconds        <1 ms          one draw call
```

### 1. Disk → index (worker)

One writer thread owns the DB connection. It walks the vault, parses each note, and writes rows in
batches of 200 files / 250 ms.

Links are written before they can be resolved. `[[Paris]]` cannot be turned into a destination until
you know whether `Paris.md` exists *anywhere* in the vault, so each new link is parked on
`dst_id = src_id` as a stand-in, and one `relinkAll` pass at the end of the walk resolves all of
them. This is why link resolution is a distinct phase the spinner has to name — on this corpus it is
26 s of work with no per-file counter to show.

Where a cold build's time goes, measured by `zig build bench -- --index <vault>` (which runs this
exact path headlessly, so the breakdown is not a guess):

```
prepass  0.5s   walk 42.7s  (stat 2.5  read 28.1  parse 1.0  db 6.8)
drop     0.0s   relink 25.6s   publish 0.3s          TOTAL 69.2s
```

Two things are worth reading off that. **Parsing markdown is free** — 1 second for 1.2 GB — so the
scan is not a parser problem and never was; and what remains is file reads and link resolution, in
that order. Re-opening an unchanged vault is 3 s, because the walk stats every file, finds nothing
moved, and skips the relink entirely.

**The index only ever reflects saved files.** Fizzy broadcasts an open document's contents on a
typing lull, and atlas used to feed those straight into the index so the graph moved as you typed.
That is worse than slow, it is wrong: half a wikilink resolves to nothing and *materialises a
phantom note* for it, so `[[Paris]]` arrives as `[[P]]`, `[[Pa]]`, `[[Par]]` — real rows in `notes`,
real nodes in the graph, and a full rebuild behind each one. The unsaved bytes are still recorded as
an overlay for the backlinks panel, but the graph waits for the save, which reaches the indexer
through `Watcher` layers 1 and 2 without any help.

### 2. Index → snapshot (worker)

One read of the two skeleton columns above, into an arena, published into a 2-slot ring so the UI can
hold one while the worker fills the other.

Two rules make this affordable:

- **Progress publishes carry counts only.** A scan publishes every 200 files. Building the full
  graph each time is quadratic in the note count, and nothing ever read those intermediate graphs.
- **A snapshot is marked `complete` only after `relinkAll`.** The graph panel refuses incomplete
  ones. Drawing a mid-scan snapshot is worse than drawing nothing: its links have no destinations
  yet, so you get an *edgeless* graph that looks exactly like a finished vault of unconnected notes,
  with no way to tell from the picture that it is wrong.

The wikilink candidate lists are built here too and handed to the UI thread by ownership transfer,
rather than being queried on demand during a frame.

**The camera follows the note you are reading.** A re-fold re-derives the hierarchy from the link
graph, so an edit can move every note in the vault — including the one on screen. `applyFraming`
re-derives the pose for `.extents`, `.note` and `.interior`, but `.free` (the reader panned by hand)
deliberately re-derives nothing, on the grounds that a hand pan is a place someone chose to be. That
reasoning assumes the world stayed still. So `finishRebuild` records where the anchor note sat
before the rebuild and shifts the camera by exactly how far it moved: the pan is preserved
*relative to the note* rather than to the world, and the note ends up back under the same pixel with
everything else rearranged around it. Through `Camera.retarget`, so it eases rather than jumps, and
so a rebuild that did not move the note costs nothing.

### 3. Snapshot → world (layout worker)

The "Building map…" wait, and the largest single piece of work in a rebuild.

- **`fold.zig`** coarsens the link graph into a ladder of cells. This is a *hierarchy*, not a layout:
  which notes belong together, nested.
- **`containment.zig`** places each cell's children inside its parent's disc. Position is *derived*
  from the hierarchy — there is no force simulation and nothing to converge.
- **`cellweb.zig`** folds every link onto cell pairs once, so the web can be drawn at any level of
  the hierarchy without re-walking 3M edges.

Deriving position from structure buys a property that used to be bought with a lot of machinery: a
note whose links did not change lands in the same cell, so an edit somewhere else in the vault does
not shuffle your view. The old force layout needed an incremental-anchoring pass to fake that;
containment gets it for free.

Vaults of 4,000 notes or fewer skip the worker and solve inline — a thread would cost a frame of
latency for work too fast to see.

### 4. World → marks (per frame)

The living set. Given `(hierarchy, viewport, zoom, budget)` the set of open cells is **determined** —
motion only interpolates how they appear. A parked camera means the open set stops changing, and
there is a test for that.

Two rules do the heavy lifting:

- **Cull inside the selection, not at draw time.** Children are placed inside their parent's disc, so
  if a cell is off screen its entire subtree is off screen, and the test is exact. This is what makes
  the walk proportional to what is visible rather than to the vault.
- **Open a level by a count threshold, never by visit order.** Opening biggest-first until the budget
  runs out means two identical neighbours resolve differently depending on walk order — a visible
  seam. Thresholding on count means equal cells always agree, and the budget still fills.

### 5. Marks → screen (per frame)

Marks are plain numbers — no dvui types — so this stage stays headless-testable. The panel applies
the camera transform and every disc goes into one shared vertex buffer, flushed in a single draw
call. dvui has no batching of its own: every `fillConvex` is a separate backend call, so without this
a vault is one draw call per note.

---

## The optimizations, ranked

Ranked by "how much worse would it be without this" on the reference corpus. All measured.

**1. The mark budget.** Turns per-frame cost from O(N + E) into O(budget). Nothing else on this list
would matter without it.

**2. An index on `tags(note_id)`.** `writeNote` replaces a note's derived rows with five deletes,
all `WHERE note_id = ?`, and `tags` was the one table of the five with no index to serve it — so
`DELETE FROM tags WHERE note_id = ?` planned as `SCAN tags`, a full scan of a table that grows for
the whole walk, once per note. A CPU sample of a cold build found **66% of all samples** in that one
statement, inside `sqlite3BtreeNext`. Adding the index took the walk's database time from **316s to
6.9s** and the whole cold build from 419s to 84s. A missing index is not a tuning knob; it is a
quadratic term, and the only reason this one hid so long is that it costs nothing on a vault small
enough to scan quickly.

**3. Page cache and checkpoint interval sized for a build, not a database at rest.** SQLite's
defaults — 2 MB of cache, a checkpoint every 1000 WAL pages — assume occasional writes. A cold build
writes gigabytes: at 2 MB the random-order index inserts fault a page in per row (**505s → 419s** to
fix), and since `synchronous=NORMAL` makes the checkpoint the only thing that `fsync`s, the
checkpoint interval *is* the fsync interval — a sample of `relinkAll` was **6,367 of ~8,800 samples
in `fsync`** (**84s → 69s** to fix). See `Db.cache_size_pragma` and `Db.wal_autocheckpoint_pages`.

**4. Radix-sorting the cell pairs.** A rebuild sorts undirected pairs of cell ids twice over —
`fold.coarsenLevel` lifting each level's edges onto their parents, `cellweb.dedupe` at every level
of the ladder — and both were comparison sorts over 3.35M elements. The key is two `u32` cell ids,
which buckets in linear time. `cellweb` went **710 ms → 265 ms** and the edge lift **422 ms → 69
ms**; a whole `World.init` went 1,694 ms → 666 ms. Worth reading for the method as much as the
result: the profile named `std.sort.block`, so the first fix was stable → unstable, which moved the
total by 0.4%. That non-result is what said the algorithm was wrong rather than its constants.
Phase timers, not symbol names, found it. See `ui/radix.zig`.

**5. `buildPairs`, cheaper per link.** It runs once per link — 3.35M times — to find the lowest cell
containing both ends, and it walked that path through `lad.cells` *three* times: once for the LCA
climb and twice more inside `recordExt`, re-deriving which child held each endpoint. The climb
already passes through the answer, so it now carries it. Plus a cheaper hash for the packed-id
accumulators. **168 ms → 141 ms**; worth less than it looks, because what remains is 3.35M
cache-missing walks of a cell array far larger than L2, not arithmetic.

A cautionary result lives in `PackedKeyContext`: replacing wyhash with a bare `k *% golden` — the
obvious "cheaper hash" — made `buildPairs` **30x slower**, 5,130 ms against 168 ms. A single
multiply is a bijection but leaves the low bits determined by the input's low bits, and the table
indexes buckets on exactly those. splitmix64's finalizer mixes properly and is still cheap.

**6. Scoping an edit's relink, and caching what resolution reads.** A keystroke's debounce used to
cost **3.7 s**: 3.4 s re-resolving all 3.35M links to discover where *one* note points, plus a full
snapshot rebuild, against 0.6 ms to write the note's own rows. Three changes, each measured with
`bench --index-edit`: `relinkNote` resolves only `WHERE src_id = ?` (3381 → 250 ms); `ResolveCache`
keeps resolution's whole-vault inputs between edits instead of rebuilding them per call (250 → 0.8
ms); and the candidate hand-off copies that cache rather than re-running the same query a second
time in the same publish (319 → 183 ms). **3717 ms → 184 ms.**

The boundary is deliberate and worth knowing: an edit re-resolves its own links, not other notes'.
A note that declares front-matter aliases is treated as structural for that reason — an alias is a
name others resolve against — so the fast path covers the ordinary edit and the rare one falls back
to the full pass.

**7. Deleting the force layout.** `layout_full.targets` was **1,537 of 3,141 worker samples** on a
vault stuck for minutes on "Preparing graph…", 1,361 of them inside `PlacedIndex.overlaps` alone.
Containment derives positions from the hierarchy, and the drawn positions come from the world — so
the solve was computing an arrangement that was immediately overwritten. The entire wait, for nothing.

**8. `relinkAll`'s id-by-path map.** Resolving 3M links used to run `SELECT id FROM notes WHERE
path = ?` per link. A CPU sample put **79% of all samples** in that one query, almost all inside
`walFindFrame` — a b-tree probe is cheap in principle, but each page has to be found in a
write-ahead log the walk just made enormous. One query plus a hash map replaced 3M b-tree descents.

**9. Counts-only progress publishes.** Roughly **4×10⁸ correlated subqueries** at this scale if you
build the full graph every batch. Minutes versus hours.

**10. The `complete` gate.** The same problem one layer up: every partial publish re-ran fold +
containment + cellweb over everything scanned so far. Several full rebuilds a second, all discarded,
competing with the scan that triggered them. That feedback loop is why a large vault appeared never
to finish loading.

**11. A second, read-only SQLite connection.** The UI runs big reads while the worker runs millions of
tiny writes; one connection serializes them into each other's worst case. A sample found **2,648 of
~2,900 worker samples parked in `__psynch_mutexwait`** — not doing database work, waiting for the UI
thread's turn. WAL exists precisely so a second handle removes the contention instead of rationing it.

**12. Batched write transactions.** A note write is several statements, and SQLite wraps each one in
its own transaction unless told otherwise — millions of commits, each with its own WAL frame and
locking, over a full scan.

**13. Skipping the link lift when the cut has not changed.** The lifted set is a pure function of
`(cut, focus, budget)` — cell ids, not positions — so panning inside an unchanged cut produces
exactly the set already computed. Recomputing anyway was **99% of the world's frame cost at a high
budget: 5–8 ms against 0.13 ms** for selecting and placing every mark.

**14. Per-frame whole-vault sweeps, removed.** `GraphNode` is ~160 B, so `for (p.nodes) |*n| n.alpha
= 0` walks 160 MB at a million notes — **3.7 ms every frame** to clear a few hundred non-zero values.
The visible list is an exact record of what was lit, so clearing only that covers everything. Two
more of the same shape: the open-notes hash (**3.3 ms**) and the label placer's endpoint lookup,
which was linear per link and came to **~80 million comparisons a frame** at a 4,000-mark budget —
growing with the budget, so raising it to see more punished you quadratically.

**15. Degree from the deduped edge list.** Computing it in SQL means touching all 3M links to answer
a question the consumer already has the answer to: the rebuild has collapsed every edge onto its
unordered `(min,max)` pair, which *is* "distinct neighbours".

**16. Candidate lists built on the worker.** Every wikilink the preview renders resolves against a
list of every note's path and stem — a multi-second walk that used to run on the UI thread the first
time a document rendered a link.

**17. The quiet-coalesce timer.** Reading a vault publishes a new generation every batch, and each
one re-solved the graph. Not just wasted work but *visible* work — the web churned for the whole
read. 0.6 s of stillness buys one settled replacement.

**18. Skipping `relinkAll` when nothing changed.** Resolved destinations are durable, so re-opening
an unchanged vault has nothing to recompute. This is what makes the second open fast.

**19. WAL checkpoint before reading across the walk.** `walFindFrame` again — the second-largest cost
in a sample of a scan that looked stuck. `PASSIVE`, not `TRUNCATE`: truncation needs exclusive access
and fails whenever a reader is live, which is almost always.

  This one spent a while not working at all, and said so only in a log line that was easy to read as
  noise: `SQLITE_LOCKED` on every *re-open*. The reader blocking it was this connection. `one` stops
  as soon as it has a row, and the per-note statements are reset before use and never after — so a
  metadata lookup that **found** its note left a read cursor open on `notes` until the next lookup,
  and after the walk's last file there was no next lookup. A cold build hid it, because there the
  last lookups find nothing and step to `DONE`. An open read transaction also pins the WAL against
  reset, so the cost was not only the skipped checkpoint. See `lookupNoteMeta`.

**20. Reserve-then-fill on the bulk loaders.** Growing a list to 3M entries reallocates and copies a
50 MB buffer a couple of dozen times. One `COUNT` is cheaper. Same family: `next` instead of
`nextAlloc` for the edge load, which was running the allocating row path 3M times for two integers.

**21. Label placement gating.** Skipped entirely when the view is fully coalesced — there is no name
on screen to place — and otherwise only when something feeding it moved.

---

## What is still O(N)

| work | cost at 286k | thread | why it is acceptable |
|---|---|---|---|
| Full scan | ~70 s | worker | Bounded by disk. Reports progress; never blocks a frame. |
| `relinkAll` | one pass over 3M links | worker | Once per scan, skipped when nothing changed. An *edit* uses `relinkNote` instead. |
| `commitAndPublish` | ~180 ms, ~73 MB copy | worker | Once per settled generation, not per batch. The last whole-vault step on the edit path. |
| fold + containment + cellweb | ~610 ms | layout worker | Once per rebuild, coalesced by the quiet timer. |
| `snapshotCopy` | ~73 MB copy | **UI thread** | Once per rebuild. The alternative is a use-after-free. |
| `p.nodes` | ~46 MB | **UI thread** | Once per rebuild. The next scale step is deleting this array. |

Two of these are on the UI thread, which is the honest weak spot: a rebuild has a visible cost
proportional to the vault, and the quiet-coalesce timer exists to make sure you pay it once rather
than continuously. The **per-frame** row is the one that has to stay empty, and it is.

---

## Verifying it

- `zig build bench -- --world <vault>` sweeps the containment path at a fixed budget and reports
  marks and links per frame. **Diff the marks and links columns** — that is the draw budget holding
  or not holding. Do not try to verify this from a live window: `tour-gpu.csv` timings are
  vsync-locked and prove nothing about cost.
- `--budget=N` / `--scan-cap=N` show what the budget and the link-scan cap are actually buying.
- `--stats` reports graph structure — degree distribution, components, the coarsening ladder, folder
  correlation — without running layout, so it is fast at any vault size.
- Do not run two builds at once while benching; the numbers are not usable.

One structural fact worth holding onto when reading those numbers: **islands are a knife edge.** Four
cross-topic links per 1,000 notes are enough to fuse 29 separate islands into a single component
covering 52% of the vault. A real Wikipedia import is one giant component, so any strategy that
assumes separable islands does not survive contact with it.
