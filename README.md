# Atlas

<img width="1800" height="1169" alt="Screenshot 2026-08-18 at 1 05 24 PM" src="https://github.com/user-attachments/assets/030ee0c9-5a0b-4ece-9213-ca95a9f36ab6" />

Wiki-style notes for [fizzy](https://github.com/fizzyedit/fizzy). Indexes the markdown under
your open folder, resolves `[[wikilinks]]` between notes, and shows you how they connect.

The open project folder is the vault. Nothing is stored in it — the index is a derived cache
kept in the OS cache directory, and the files on disk are always the source of truth. Delete the
cache and the next open rebuilds it.

## What it does

- **Backlinks sidebar** — every note that points at the one you're reading, grouped by source,
  with a filter box. Click to reveal the line.
- **Graph panel** — the whole vault as a note web in the bottom panel. Pan, zoom, click to open,
  zoom into a note to see its own structure. What a frame draws is bounded by a budget rather
  than by vault size, so a ten-note folder and a three-hundred-thousand-note one cost the same
  to display.
- **`[[` completion** — type `[[` in a markdown buffer, pick a note, and get a portable
  CommonMark link back.
- **Wikilink resolution** for fizzy's markdown preview, through the SDK's `wikilink` service:
  `[[Note]]`, `[[Note|alias]]`, `[[Note#Heading]]`, and front-matter aliases.
- **Convert wikilinks** — a command that rewrites every resolvable `[[link]]` in the open
  document to a markdown link.

Atlas owns no documents. The `text` plugin keeps owning `.md`; Atlas contributes the link layer
around it, which is why it can index markdown it never renders.

## Link format

Atlas writes ordinary markdown links so notes stay portable outside fizzy:

```md
[Physics](physics.md)
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

`[[…]]` stays recognized wherever it appears — the index and the preview both resolve it — but
the completion gesture writes CommonMark, so new links are portable by default.

## When the index updates

On **save**, and on any change to the folder that fizzy's watcher reports (an agent writing
files, a `git checkout`, another editor). A periodic sweep re-walks the vault as a backstop for
platforms where the watcher is unreliable.

Deliberately **not** on every keystroke: a half-typed `[[Par` resolves to nothing and would
create a placeholder note for a page that will never exist. Unsaved edits still show up in the
backlinks pane, which reads the live buffer directly.

## Building

```sh
zig build            # → zig-out/atlas.<dylib|so|dll>
zig build install    # also installs into fizzy's plugins dir
zig build test       # unit tests
```

`build.zig.zon` pins the fizzy SDK by its `fizzy-sdk-v*.tar.gz` **release asset** URL. It has to
be the asset, not the git archive of the tag — that one is fizzy's monorepo root and pulls in the
whole app's dependencies. Bump the `sdk-vX.Y.Z` URL and hash together when moving to a newer SDK,
and keep `min_sdk_version` in `plugin.zig.zon` in step with it.

`batch2d` (the sprite/line batching under the graph) is vendored in `src/batch2d/` rather than
pinned as a package, so a release build needs no dependency outside the three pins above.

### Developer tools

The **Atlas: Vault Simulator** command is in every build — synthetic vaults of 100k–1M notes with
live controls over the layout constants, for working on the graph without needing a corpus that
size on disk. The rest below are separate build steps, not part of the plugin.

- `zig build bench -Doptimize=ReleaseFast -- <flags> <vault>` is a headless timing harness:
  `--index` builds the SQLite index and reports where the time went, `--index-edit` times one
  edit against a built index, `--layout-edit` mirrors a save (cold solve vs reuse), `--refold`
  times a full spatial rebuild, `--world` sweeps the level of detail across a zoom range, and
  `--stats` reports graph structure. Run it against a real folder of markdown or a `synth:N:shape`
  spec.
- `zig build wiki-import -- <dump.xml> <out-dir>` turns a MediaWiki XML dump into a vault, which
  is where the reference corpus in `docs/design/scale-architecture.md` comes from.

## Releasing

Tag `vX.Y.Z` matching `.version` in `plugin.zig.zon`; CI builds every target and publishes the
binaries plus `manifest.json`.
