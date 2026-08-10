//! The index schema, and the policy for what to do when it doesn't match.
//!
//! **Policy: rebuild, don't migrate.** The database is a derived cache — the markdown files are
//! the source of truth, and a full rescan of a large vault is a few seconds on a background
//! thread. So a version mismatch, a corrupt file, or a failed integrity check all take the same
//! path: delete it and scan again. Migrations only earn their keep when a rebuild would be
//! painful enough for the user to notice, and nothing here is close to that yet. The moment
//! that changes, bump `version` and add a migration; until then, carrying migration code for a
//! cache would be maintaining something for no one.
const std = @import("std");

/// Bump on any change to the DDL below. Anything that doesn't match is discarded.
pub const version: u32 = 2;

/// Connection settings, applied on every open.
///
/// WAL is what lets the indexer thread write while the UI thread reads a resolution mid-draw
/// without either blocking the other. `synchronous=NORMAL` because losing the tail of a rebuild
/// to a power cut costs a rescan, which is exactly what we'd do anyway.
pub const pragmas =
    \\PRAGMA journal_mode=WAL;
    \\PRAGMA synchronous=NORMAL;
    \\PRAGMA foreign_keys=ON;
;

/// Full DDL. Idempotent, so opening an existing database of the right version is a no-op.
pub const ddl =
    \\CREATE TABLE IF NOT EXISTS meta (
    \\  key   TEXT PRIMARY KEY,
    \\  value TEXT NOT NULL
    \\);
    \\
    \\-- One row per note. `phantom` rows are notes that don't exist yet: something links to
    \\-- them and nobody has written them. They get real rows so `links.dst_id` is never null,
    \\-- so the graph can show "nine notes point at a page you haven't written", and so that
    \\-- creating the file later is a one-column update rather than a rewrite of every edge.
    \\CREATE TABLE IF NOT EXISTS notes (
    \\  id        INTEGER PRIMARY KEY,
    \\  path      TEXT NOT NULL,          -- vault-relative, '/'-separated, with extension
    \\  stem      TEXT NOT NULL,          -- basename without extension, as written
    \\  stem_fold TEXT NOT NULL,          -- ASCII-folded, for case-insensitive lookup
    \\  title     TEXT NOT NULL DEFAULT '',
    \\  mtime_ns  INTEGER NOT NULL DEFAULT 0,
    \\  size      INTEGER NOT NULL DEFAULT 0,
    \\  hash      INTEGER NOT NULL DEFAULT 0,
    \\  phantom   INTEGER NOT NULL DEFAULT 0
    \\);
    \\-- Partial, so many phantoms can share the empty path while real notes stay unique.
    \\CREATE UNIQUE INDEX IF NOT EXISTS notes_path_real ON notes(path) WHERE phantom = 0;
    \\CREATE INDEX IF NOT EXISTS notes_stem_fold ON notes(stem_fold);
    \\CREATE INDEX IF NOT EXISTS notes_phantom ON notes(phantom) WHERE phantom = 1;
    \\
    \\-- One row per alias, so a note with three aliases is three rows. Resolution only ever
    \\-- asks "does some name match", which makes that the shape it wants.
    \\CREATE TABLE IF NOT EXISTS aliases (
    \\  note_id    INTEGER NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
    \\  alias      TEXT NOT NULL,
    \\  alias_fold TEXT NOT NULL,
    \\  PRIMARY KEY (note_id, alias_fold)
    \\);
    \\CREATE INDEX IF NOT EXISTS aliases_fold ON aliases(alias_fold);
    \\
    \\-- For `[[Note#Heading]]`: which line to scroll to.
    \\CREATE TABLE IF NOT EXISTS headings (
    \\  note_id   INTEGER NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
    \\  text      TEXT NOT NULL,
    \\  text_fold TEXT NOT NULL,
    \\  level     INTEGER NOT NULL,
    \\  line      INTEGER NOT NULL        -- 0-based
    \\);
    \\CREATE INDEX IF NOT EXISTS headings_note ON headings(note_id, text_fold);
    \\
    \\-- One edge table serves both directions: forward links are `WHERE src_id = ?`, backlinks
    \\-- are `WHERE dst_id = ?`, and both are covered by an index.
    \\CREATE TABLE IF NOT EXISTS links (
    \\  src_id    INTEGER NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
    \\  dst_id    INTEGER NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
    \\  raw       TEXT NOT NULL,          -- exactly what was between the brackets
    \\  heading   TEXT NOT NULL DEFAULT '',
    \\  alias     TEXT NOT NULL DEFAULT '',
    \\  kind      INTEGER NOT NULL,       -- see LinkKind
    \\  ambiguous INTEGER NOT NULL DEFAULT 0,
    \\  line      INTEGER NOT NULL,       -- 0-based, in src
    \\  col       INTEGER NOT NULL,       -- 0-based byte column
    \\  context   TEXT NOT NULL DEFAULT ''-- the source line, for the backlinks list
    \\);
    \\CREATE INDEX IF NOT EXISTS links_src ON links(src_id);
    \\CREATE INDEX IF NOT EXISTS links_dst ON links(dst_id);
    \\
    \\-- Unused in the first cut. Present from the start because adding a table later is a
    \\-- schema change and an empty one costs nothing.
    \\CREATE TABLE IF NOT EXISTS tags (
    \\  note_id  INTEGER NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
    \\  tag      TEXT NOT NULL,
    \\  tag_fold TEXT NOT NULL,
    \\  line     INTEGER NOT NULL
    \\);
    \\CREATE INDEX IF NOT EXISTS tags_fold ON tags(tag_fold);
    \\
    \\-- Embeddable media in the vault (images), so `![[diagram.png]]` can resolve and complete.
    \\-- Deliberately *not* the `notes` table: these are attachments, not notes. They must never
    \\-- reach the graph, never become phantoms, and carry none of a note's parsed structure —
    \\-- the indexer records a path for them and never opens them.
    \\CREATE TABLE IF NOT EXISTS media (
    \\  id        INTEGER PRIMARY KEY,
    \\  path      TEXT NOT NULL,          -- vault-relative, '/'-separated, with extension
    \\  stem      TEXT NOT NULL,          -- basename without extension, as written
    \\  stem_fold TEXT NOT NULL,          -- ASCII-folded, for case-insensitive lookup
    \\  name_fold TEXT NOT NULL           -- basename *with* extension, folded: `![[a.png]]`
    \\);
    \\CREATE UNIQUE INDEX IF NOT EXISTS media_path ON media(path);
    \\CREATE INDEX IF NOT EXISTS media_stem_fold ON media(stem_fold);
    \\CREATE INDEX IF NOT EXISTS media_name_fold ON media(name_fold);
;

/// How a link was written. Stored as an integer so the graph can filter on it.
pub const LinkKind = enum(u8) {
    /// `[[Note]]`
    wikilink = 0,
    /// `![[Note]]` — a transclusion request. Recorded as an edge even though nothing
    /// transcludes yet, so the graph is complete when it does.
    embed = 1,
    /// `[text](./Note.md)` — an ordinary markdown link pointing inside the vault.
    markdown = 2,
};

const testing = std.testing;

test "every ddl statement is idempotent" {
    // The invariant that matters: `ddl` is executed on every create, so a statement without
    // IF NOT EXISTS would fail the second time anything reruns it. What the DDL actually
    // *produces* is checked against real sqlite in `db_test.zig` — this just catches the
    // mistake at the point where the error message still names the cause.
    var it = std.mem.splitScalar(u8, ddl, ';');
    var creates: usize = 0;
    while (it.next()) |stmt| {
        if (std.mem.indexOf(u8, stmt, "CREATE") == null) continue;
        creates += 1;
        testing.expect(std.mem.indexOf(u8, stmt, "IF NOT EXISTS") != null) catch |err| {
            std.debug.print("not idempotent:{s}\n", .{stmt});
            return err;
        };
    }
    try testing.expect(creates > 0);
}
