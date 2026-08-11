//! The neutral shape of one note's content, as a graph — headings, paragraphs, lists, code
//! blocks, blockquotes, tables, tags, and embeds, each its own node, outline-nested under the
//! nearest enclosing heading (or the document root).
//!
//! Pure: no `Db`, no `dvui`. Two producers build this same shape without cross-importing —
//! `query.noteContentGraph` reads it out of the index for a real document, and a synthetic
//! generator (built separately) fabricates it for stress-testing the interior view against
//! shapes no real vault has yet. Both feed the same downstream layout with zero special-casing,
//! which is the whole reason this type exists on its own rather than living inside `query.zig`.
const std = @import("std");

/// What one node in a note's content graph stands for. `root` is the document itself — the one
/// node that's always present, even for a note with nothing in it.
pub const ItemKind = enum(u8) {
    root,
    heading,
    paragraph,
    list,
    code,
    blockquote,
    table,
    tag,
    embed,
};

pub const Item = struct {
    /// Stable identity within the note. For `.heading` this is the existing
    /// `text_fold`+occurrence hash (`query.sectionId`); non-heading kinds have no natural
    /// title-like identity of their own, so it may collide across edits that reorder or insert
    /// siblings under the same heading — the same imperfection the heading id already accepts
    /// for a repeated heading.
    id: i64,
    kind: ItemKind,
    /// ATX depth 1–6 for `.heading`, 0 for everything else (including the root).
    level: u32 = 0,
    /// 0-based line the item starts at. 0 for the root.
    line: u32 = 0,
    text: []const u8 = "",
    /// Word count for prose, line count for `.code`, 1 for everything without a natural size
    /// (tags, embeds, the root). A draw-time size/kind modifier only — it does not feed layout
    /// world-space area.
    weight: u32 = 1,
};

pub const ItemEdge = struct {
    a: u32,
    b: u32,
    /// `.outline` is document nesting (item `b` hangs off enclosing heading/root `a`); `.link`
    /// is an explicit same-note `[[This Note#Heading]]` between two headings.
    kind: enum { outline, link },
};

pub const ContentGraph = struct {
    items: []const Item = &.{},
    edges: []const ItemEdge = &.{},
};
