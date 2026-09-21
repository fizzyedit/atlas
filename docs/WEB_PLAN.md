# Atlas on the web

Goal: the fizzy web build bundles two plugins, **drive** and **atlas**, so that signing in to
Google Drive and opening a vault folder shows the note graph in the browser, with edits
landing in the cloud. Same source on native, where the vault may be on disk or on Drive.

This is a rebuild of atlas's index layer, not a port: the parts that block the web are the
parts that were written for one machine with a disk and threads, and every one of them is also
what stops a vault on Drive from working natively today.

## What blocks, found by reading

| Where | What | Web | Drive on native |
|---|---|---|---|
| `src/index/Db.zig`, `schema.zig`, `query.zig`, most of `Indexer.zig` | SQLite (C amalgamation, file-backed, ~90 call sites) | no libc on `wasm32-freestanding`; no file | works, but it is a disk cache of a disk |
| `Indexer.walk/countMarkdown/probeFile/flushReads`, `Watcher.tick`, `plugin.zig:322` | `std.Io.Dir` reads, stats, walks | no filesystem | reads the disk, not the mount |
| `cache_dir.zig` | per-vault cache folder from `$HOME`/env | none | fine |
| `Indexer.worker` | a `std.Thread` + `Io.Mutex/Condition`, `runFullScan` blocking for the whole vault | no threads | fine |
| `Indexer.markNs`, `Watcher.tick` | `std.Io.Clock.boot.now(dvui.io)` | `dvui.io` is `std.Io.failing` on web | fine |
| `batch2d`, the graph renderer | render targets, `u16` vertex indices | targets drew icons soft on the web backend (see fizzy `core/gfx/icon.zig`); indices already chunked | — |

Nothing in `src/ui/**`, `resolve.zig`, `Scanner.scan` (parse) or `content_graph.zig` touches
any of this: the parser and the graph are pure over bytes and snapshots. That is the boundary
the rebuild keeps.

## On `std.Io`: what it gives us and what it does not

The pitch is right for **I/O**: code written against `std.Io` (files, clocks, sleeps, mutexes)
runs unchanged under a threaded `Io` on native and a single-threaded one elsewhere — atlas's
tests already drive the indexer with their own `Io`. It is **not** a way to get background work
on the web:

- `Io.Threaded` in single-threaded mode runs `io.async(f)` **inline, to completion**, at the
  call site; `io.concurrent` returns `error.ConcurrencyUnavailable`. There is no yield. A full
  scan wrapped in `io.async` would still run inside one frame and hang the tab.
- The evented `Io` implementations (`std.Io.Evented`, `fiber.zig`) switch stacks, which needs
  `x86_64`/`aarch64`/`riscv64` — not wasm.
- wasm threads exist (atomics + `SharedArrayBuffer`) but need COOP/COEP headers on the site,
  a threads-enabled wasm build and a dvui web backend that tolerates it. Not this pass.

So the single implementation we can write is one that **does bounded work per call and keeps
its own state between calls** — a state machine, not a blocking loop. Given that shape, the
same code runs two ways:

- **native**: a worker thread (`io.concurrent`, or the existing `std.Thread`) calls
  `step()` in a tight loop until done; file completions from `core.LocalFs` arrive inline, so
  it is exactly as fast as today's loop;
- **web**: fizzy's frame pump calls `step()` with a time budget (say 4 ms) each frame; file
  completions come from the Drive mount's transport as they land.

That is a small library, not a big one, and it belongs in fizzy's `core` so drive, atlas and
anything else share it:

```zig
// core/work.zig (proposed)
pub const Task = struct {
    ctx: *anyopaque,
    /// Do up to `budget_ns` of work (0 = as much as is ready); say whether more remains.
    step: *const fn (ctx: *anyopaque, io: std.Io, budget_ns: u64) Status,
    cancel: *const fn (ctx: *anyopaque) void,
    pub const Status = enum { more, waiting, done };
};
pub const Runner = struct {
    /// Native: runs `task` on a worker until `done`, waking the host on progress.
    /// Web: registers `task` to be stepped from the host's per-frame pump.
    pub fn start(io: std.Io, task: Task, wake: *const fn () void) !void;
    pub fn pump(budget_ns: u64) void; // web only; no-op on native
};
```

`waiting` is the state a task is in when it has asked the mount for bytes and nothing is ready
— the runner then sleeps on the transport's wake (native) or returns until next frame (web).
Everything the Drive client does today (`drive.Client.Job`) is already this shape; `core.vfs`
is completion-based for exactly this reason.

## The index store: SQLite or not

Two options.

**A. SQLite to wasm.** Build the amalgamation for `wasm32-freestanding` with
`SQLITE_OS_OTHER=1`, `SQLITE_THREADSAFE=0`, `SQLITE_OMIT_WAL`, an in-memory VFS
(`SQLITE_ENABLE_MEMDB` + a stub `sqlite3_os_init`), and supply the libc surface it needs
(`memcpy/strlen/qsort/snprintf/localtime…`) ourselves or from wasi-libc with the WASI imports
shimmed in JS. Keeps all 90 call sites. Unknown-sized rabbit hole; every build-graph problem it
creates is permanent.

**B. An in-memory index in Zig.** The schema is seven plain tables — notes, aliases, headings,
links, tags, blocks, media — with lookups by path, folded stem, note id and link endpoint. That
is a struct of `ArrayList`s and `HashMap`s, and the queries `query.zig` and `Indexer.zig` run
against it are lookups and joins over those keys, not SQL that needs a planner. The snapshot
the graph draws from (`SnapNode`/`SnapEdge`) is then a view over the index, not a query that
copies it. Persistence, which SQLite gave for free, becomes a serialized index file:

- **native**: the same cache folder, one file, written after a publish; loading it skips the
  scan for unchanged files exactly as the mtime/size/hash rows do today;
- **Drive / web**: the same file *in the vault* (`.atlas/index`), so the web build loads a
  prebuilt index in one read and reconciles against `changes.list` instead of reading every
  note on every visit. This is the single biggest performance lever for a cloud vault, and
  SQLite could never have given it.

Recommendation: **B**, measured first. `Indexer.Timings` already separates `write_ns` and
`publish_ns` from `read/parse`; a run over the real vault says what SQLite costs today, and
the `db_test.zig` suite (773 lines) is the acceptance test the new store has to pass.

## Step 0 — measured (2026-09-21, ReleaseFast, `zig build bench -- --index`)

| vault | notes / links | cold total | of which SQLite | parse | read+stat |
|---|---|---|---|---|---|
| foxnne's Vault (Drive-synced folder) | 16 / 38 | 0.00 s | — | — | — |
| gauntlet `tree` | 1 365 / 1 364 | 0.11 s | 0.01 s | 0.00 s | 0.08 s |
| simplewiki | 283 892 / 3 351 076 | **45.1 s** | **~31.7 s** (db 6.8 + relink 24.9) | 0.9 s | 8.2 s |

Warm open of simplewiki: 2.9 s (2.0 s of it `stat`); one edit at steady state: 1.2 ms.

So on the scale case SQLite is 70 % of a cold index and the parse is 2 %: the relink pass
alone (rewriting `links.dst_id` row by row) costs 27× the parse. An in-memory index makes the
relink a pass over an adjacency list and the note writes a hash-map upsert; the cold floor
becomes read + parse, ~9 s here and mostly the disk. Option B, confirmed.

The store's operation set, from every statement in `Db.zig`, `Indexer.zig`, `query.zig`:

| group | operations |
|---|---|
| notes | get by path (real only) → id/mtime/size/hash; get phantom by folded stem; insert real / insert phantom; update fields; promote phantom to real; touch (mtime, size); retire real to phantom (keeping inbound links) or delete; merge duplicate phantoms; count real / phantom; iterate real (path, stem, id); iterate phantoms (id, stem, title) |
| per-note children | replace all aliases / headings / tags / blocks of a note; read headings (by line; by folded text → line), tags, blocks of a note |
| links | replace a note's outbound links; iterate outbound (dst, raw, heading, alias, kind, line, col); inbound existence / backlinks (src path, title, stem, line, col, raw, alias) for a dst; iterate all (src, dst); count all / non-self; re-target every link of a dst (merge); relink: iterate unresolved-or-all with src path, set dst + ambiguous |
| media | upsert by path (stem, folded stem/name); iterate all; delete by id; prefix scan on folded name / stem (completion) |
| resolve inputs | all real (path, stem) + all aliases (path, stem, alias) → `resolve.Candidate` list; same for media |
| completion | prefix scans on notes (folded stem) and aliases (folded alias) with a limit; headings of a note by prefix |
| bookkeeping | meta (schema version, vault stamp); orphan-phantom purge (phantom with no inbound) |

Every one of these is a hash-map lookup, an adjacency-list walk or a sorted-prefix scan
(folded stems/aliases/media names kept in sorted arrays for the completion scans). Readers on
the UI thread take a short mutex; the graph reads snapshots, as now.

### Step 3 — landed (same day)

`Index.zig` replaces `Db.zig`/`schema.zig`'s DDL/`cache_dir.zig`; SQLite is out of the build.
Same vault, same machine, ReleaseFast, identical counts (283 892 notes, 3 351 076 links,
2 656 phantoms):

| | before (SQLite) | after (`Index`) |
|---|---|---|
| cold build | 45.1 s | **10.8 s** — read 3.9 + stat 2.6 + parse 0.9 + write 0.2 + relink 2.3 |
| warm re-scan (nothing changed) | 2.9 s | 1.5 s |
| one edit, steady state | 1.2 ms | 1.1 ms |
| peak RSS during the bench | — | 1.33 GB |

The floor is now the disk (stat + read = 6.4 s of 10.8), which is what step 2's pipelined
reads and the `.atlas/index` file are for. The RSS is the scale case's price and has an
obvious lever left unpulled: `Index.Link` is 88 bytes with three slices for strings that
average a few bytes; packing them as offsets into the note's `derived` blob would take it
under 40. Not done until a vault needs it.

### Steps 2 + 4 — landed together

`Scan.zig` is the pass over the vault as a stepped `core.work.Task` over a `core.vfs.Fs`:
listings, stats and reads through a window of 16 in-flight jobs, applied as they land, one
budget at a time. `Indexer` is the long-lived task around it (a scan in progress, else the
queue: full scan / sweep / a batch of saved paths as a scoped scan, else park). `State`
picks the source: a mount's filesystem (pumped by the host; the task runs from the frame,
4 ms a frame) or an indexer-owned `core.LocalFs` (the task runs on a thread; reads overlap on
the host's `Io` pool via `io.concurrent`). The 12-thread batch reader, `runFullScan`'s
walk, the worker loop and every `std.Io.Dir` call on the runtime path are gone.

| simplewiki, cold | SQLite + walk | `Index` + walk | `Index` + `Scan` |
|---|---|---|---|
| total | 45.1 s | 10.8 s | **7.5 s** (walk 5.3, relink 2.0) |
| warm re-scan | 2.9 s | 1.5 s | 1.1 s |

One trap on the way: the scan's queues were `orderedRemove(0)` and a 284k-file directory
made that quadratic (33 s); they pop from the end now.

Still to do from this pair: the backlinks pane reads a source line from the disk to show a
row's context (`ui/backlinks.zig`) — on a mount it shows nothing; and a mount has no per-path
change events (the disk watcher's `onPathsChanged`), so a vault on Drive learns of outside
edits only from the 2-minute sweep. Both are host follow-ups.

## Steps, each with a gate

0. **Measure.** Full scan of the vault with timings logged; count the `Db` API surface
   actually used (`Indexer` 38, `Db` 32, `query` 18 statement sites). Output: the list of
   index operations the store must provide. *Gate: a table in this doc.*
1. **`core.work`** (fizzy). `Task`/`Runner` as above, native runner on `io.concurrent`, web
   runner on the frame pump, with a test that runs one task both ways to the same result.
   *Gate: `zig build test` + `check-web`.*
2. **Vault access through `core.vfs`** (atlas). `walk`, `countMarkdown`, `probeFile`,
   `flushReads` and `Watcher.tick` read through `host.files`/the mount — `listDir`, `stat`,
   `readFile` — never `std.Io.Dir`. A concurrency window of reads in flight (8–16) so a Drive
   vault is bounded by bandwidth, not round trips. `Watcher` keeps `onPathsChanged` for the
   disk and takes the mount's listing invalidations (the Drive change feed) for the cloud.
   *Gate: a vault on Drive indexes natively, same graph as from disk.*
3. **`Index` replaces `Db`** (atlas). One struct, the operations from step 0, `query.zig`
   rewritten over it, `db_test.zig` ported. Persistence file (versioned, little-endian, a
   header with vault stamp + generation). *Gate: db tests pass; scan timings no worse.*
4. **Indexer as a `Task`** (atlas). `runFullScan` becomes phases with explicit state
   (`count → walk → read → parse → write → drop-missing → relink → publish`), each phase a
   loop that returns when out of budget or waiting on bytes. The worker thread is deleted;
   `Runner` drives it. Progress and `busy` unchanged. *Gate: native scan speed unchanged;
   the web build indexes a small vault without a dropped frame over 16 ms.*
5. **Web bundle** (fizzy). `web_plugin_dirs = { zig-drive, atlas }`; `dvui.io` on web gets a
   clock (`Io.Threaded.global_single_threaded` is enough for clocks and mutexes); check the
   graph's render targets on the web backend (the icon-target softness suggests a real
   backend difference to find, not to route around). *Gate: `zig build web`, graph draws.*
6. **End to end.** Sign in → Open Drive Folder → vault indexes from `.atlas/index` + changes
   → open a note, edit, ⌘S → link appears in the graph → reload the page → index loads in one
   read. *Gate: this sequence, timed.*

## Performance, specifically

- The parse (`Scanner.scan`) is the floor and stays where it is; everything else is arranged
  so the scan is parse-bound: reads pipelined (step 2), writes to memory (step 3), no SQL
  round trip per note.
- On the web, work is budgeted per frame; a 10k-note vault at ~50 µs/parse is ~0.5 s of parse
  spread over frames, plus reads — which the prebuilt `.atlas/index` makes zero for unchanged
  notes.
- Memory: a wasm module has one linear memory; the index for a large vault is a few tens of
  MB of strings and edges, fine. Two snapshots (the ring) stay; the index itself is not copied
  into them.

## Web housekeeping that is not code (but blocks shipping)

- **Google's consent screen** needs a privacy-policy URL and a terms URL on the app's
  branding page, and the site they live on must be a verified domain of the project. A
  static page in `fizzyedit/website` (`/privacy`, `/terms`) is enough; it should say what the
  Drive plugin does with the token (kept in the browser's memory for the session, never sent
  anywhere but Google) and that fizzy stores no user data server-side. Full-drive scope is
  *restricted*: publishing past "Testing" means Google's verification, which reads that page.
- **Cookies**: the web app sets none; `localStorage` holds settings (see below). No banner is
  required for storage that is strictly necessary for the app the user asked for, and nothing
  here is tracking — say so on the privacy page and do not add a banner.
- **Credentials on the web**: an implicit-grant access token lives in wasm memory for the
  hour it is valid; there is no refresh token in a browser flow, so there is nothing to
  persist and `Host.setSecret` on wasm should stay a no-op (or be session-only). A user signs
  in again per visit, silently when Google still has a session (`prompt=none`).
- **Settings on the web**: `settings.zon` needs a home — `localStorage` behind the same
  `app/settings` file API (a JS shim like `fizzy_web_request`), per origin, so each plugin's
  settings persist across visits without a server. Same for `recents.zon`; `layout.zon` too.

### Step 5 — landed

The web build links atlas (`web_plugin_dirs` names the modules atlas's own `build.zig` adds:
`batch2d`, `content_graph`, the `threads` shim). What wasm needed of atlas: a `std.Thread`
stand-in whose `spawn` refuses (every site already had the inline fallback), a plain
generation counter (wasm32 atomics stop at 32 bits), the frame's clock instead of the host
`Io`'s, no environment, no disk poll in the watcher, and the backlinks pane reading a source
line through the host's filesystem. The end-to-end mount path is a headless test now
(`Indexer.zig`, "a mounted vault is indexed from the frame"): a `vfs.Mem` mount pumped by
"the host", the task stepped a millisecond at a time, a save as a queued path.

Open: the layout solve runs inline on the web (it was a thread); a large vault will hitch
once per rebuild there until it is a `Task` too.

## Step 7: the store loads plugins on the web (no static list)

The static `web_plugin_dirs` list is the interim the review called step 1 (§2.4 of
`fizzy/docs/REVIEW_2026-09.md`). What the user actually wants is its step 2: a plugin built
as a wasm **side module** (`-dynamic -fPIC`, `dylink.0`), the web host built with
`--import-table` + exported `__stack_pointer`, a ~200-line JS loader that fetches, relocates
and registers it, a `WebDynLib` behind the existing `PluginLoader.loadAndRegister` sequence,
and `web-wasm32` as a store target. The mechanism was demonstrated under node; the review's
estimate is 2–3 weeks. Then the web build ships exactly the built-ins native does, and drive
and atlas arrive from the store like everywhere else. Nothing in the index work above
changes for it: a side module is the dylib model with table indices for function pointers.

### Step 7 — first milestones landed (same day)

- `fizzy.plugin.create` for `-Dtarget=wasm32-freestanding` emits a side module (PIC, no
  entry, undefined symbols as `env` imports; dvui's proxy backend with libc/freetype/stb/
  tree-sitter off). `zig build -Dtarget=wasm32-freestanding` in drive or atlas → `zig-out/<id>.wasm`
  (drive 0.6 MB ReleaseSmall, atlas 12.6 MB Debug).
- The web host imports the page's growable function table and exports what a side module
  links against; `web/index.html`'s `loadPlugin` fetches, reads `dylink.0`, carves the data
  segment out of the host heap, grows the table, instantiates against the host's exports (the
  `fizzy` JS shims bound per instance, since a plugin exports its own callbacks), applies
  relocations and hands one table index per entry point to `app/store/PluginLoader_web.zig`,
  which runs the desktop loader's sequence unchanged.
- Verified in the browser: `?plugin=drive&plugin=atlas` on a web build with **no** statically
  bundled third-party plugins loads both — the account glyph, the ATLAS panel and the
  backlinks icon appear, no console errors. `web_plugin_dirs` is empty now.
- The store: `hostKey()` is `web-wasm32` on wasm; install goes through
  `PluginManager.installFromUrl` → `Editor.loadWebPlugin` straight from the release URL;
  `plugin-build-action` has the seventh, best-effort target (uncommitted in that checkout).

Still open in step 7: a plugin's *own* drawing through the render bridge is unexercised in the
browser (drive and atlas draw little of their own until a vault is open); the enabled/installed
set persists nowhere on the web yet (`localStorage`); the web host must ship the store's
optimize class (ReleaseFast) for fingerprints to match release builds; CORS on GitHub release
assets is assumed, not yet tried.

## A further step: plugins as their own web apps

Two things fizzy already has make this cheap: a plugin bundles into an app through
`fizzy.buildApp` (`examples/minimal-app`), and `docs/REVIEW_2026-09.md` proved loading a
plugin as a separate wasm side module at runtime feasible. So each plugin could get, for
free from the build helper, (a) a `zig build web` that emits a page of *just that plugin on
a minimal fizzy* — atlas-as-a-site, drive-as-a-site — and (b) a side-module build the full
web app loads on demand. (a) is build glue over what exists; (b) is the review's follow-up.
Both come after the index and the vfs work, which they need anyway.

## Out of scope for this pass

wasm threads; SQLite on wasm; a Drive-side search API (the index is local by design);
IndexedDB persistence for a vault that has no `.atlas/index` yet (first visit reads the vault,
then writes the file *to Drive*, so the second visit is fast everywhere).
