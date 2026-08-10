# Atlas

Wiki-style notes for [fizzy](https://github.com/fizzyedit/fizzy). Indexes the markdown under
your open folder, resolves `[[wikilinks]]` between notes, and shows you how they connect.

The open project folder is the vault. Nothing is stored in it — the index is a derived cache
kept in the OS cache directory, and the files on disk are always the source of truth.

## Status

Milestone 1 + Milestone 2 (graph) working. Overview rendering is **Galaxy LOD** (soft-sprite
`batch2d` + budgeted sticky `quadlod` agents; density mips parked) — see
`docs/design/galaxy-lod.md`.

Milestone 1 + 2 details:

- SDK `"wikilink"` service — markdown preview resolves `[[Note]]`, aliases, headings.
- Obsidian-compatible link resolution (`src/index/resolve.zig`).
- Line-scanner note parser (`src/index/Scanner.zig`).
- SQLite index (WAL, rebuild-don't-migrate) in the app cache dir.
- Background indexer fed by fizzy's recursive folder watch (`folderPathsChanged`), an open-doc
  mtime poll, and a periodic quiet sweep as a backstop; snapshot ring publishes node/edge arrays.
- `Atlas: Rebuild Index` / `Atlas: Open Graph` commands.
- Backlinks sidebar: grouped by source note, filter box, click / middle-click to reveal.
- Dirty-buffer overlay from `documentContentChanged` (unsaved `[[links]]` can appear in
  backlinks before save).
- Graph bottom panel: full vault note web (sunflower layout), open docs drawn larger,
  pan/zoom/pinch/fling, click to open, double-click a node to focus it, double-click empty
  space to zoom extents. Drawn from `pos`/`radius` (= `target` in M2) for the M3 seam.
- `[[` trigger in `.md` buffers: type `[[`, pick a note, get a portable CommonMark link
  `[Title](relative/path.md)` (path relative to the source file's directory). Preview opens
  those relative destinations in the editor.

Not yet: unlinked mentions, graph animation (M3), heading/`|alias` completion modes.

## Link format

Atlas writes ordinary markdown links so notes stay portable:

```md
[Claude](claude.md)
[Daily](../notes/daily.md)
[My Note](my%20note.md)
```

| Rule | Choice |
|---|---|
| Syntax | `[Title](path)` — not `[[wikilink]]` |
| Path base | Source note's directory (not vault root) |
| Same folder | `Note.md` (no `./`) |
| Extension | Always included |
| Spaces | Percent-encoded (`%20`) |
| Display text | Front-matter title, else stem |

`[[…]]` remains recognized when present (preview + index), but the editor gesture converts it
on accept so new links are CommonMark by default.

## Building

```sh
zig build            # → zig-out/atlas.<dylib|so|dll>
zig build install    # also installs into fizzy's plugins dir
zig build test       # unit tests
```

`build.zig.zon` pins the fizzy SDK by local path for development. Before tagging a release,
switch it to the `fizzy-sdk-v*.tar.gz` **release asset** URL — CI needs a URL+hash pin, and it
must be the asset, not the git archive of the tag (that one is fizzy's monorepo root, which
pulls in the whole app's dependencies).

## Releasing

Tag `vX.Y.Z` matching `.version` in `plugin.zig.zon`; CI builds every target and publishes the
binaries plus `manifest.json`.
