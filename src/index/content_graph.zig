//! Neutral per-note content graph shape, produced by both the DB-backed indexer
//! (`query.noteContentGraph`) and the synthetic generator (`vault_synth.synthContentGraph`) with
//! zero special-casing downstream. Pure Zig, no `Db`/`dvui` import — a leaf module both producers
//! import without cross-importing each other, same discipline `src/ui/fold.zig` keeps elsewhere
//! in this codebase.

pub const ItemKind = enum(u8) { root, heading, paragraph, list, code, blockquote, table, tag, embed };
pub const Item = struct { id: i64, kind: ItemKind, level: u32 = 0, line: u32 = 0, text: []const u8 = "", weight: u32 = 1 };
pub const ItemEdge = struct { a: u32, b: u32, kind: enum { outline, link } };
pub const ContentGraph = struct { items: []const Item = &.{}, edges: []const ItemEdge = &.{} };
