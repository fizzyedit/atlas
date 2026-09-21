//! The index's row vocabulary: how a link was written, what shape a body block has. The tables
//! themselves are `Index.zig`'s (in memory); the DDL that used to live here went with SQLite —
//! see `docs/WEB_PLAN.md`.
const std = @import("std");

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

/// A body block's shape, as detected by `Scanner.scan`'s block accumulator. Headings keep
/// their own `headings` table and are not a `BlockKind` — nothing downstream needs them merged.
pub const BlockKind = enum(u8) {
    paragraph = 0,
    list = 1,
    code = 2,
    blockquote = 3,
    table = 4,
};
