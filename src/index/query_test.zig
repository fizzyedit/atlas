//! The read side (`query.zig`) against an in-memory `Index`: the interior content graph, the
//! completers, heading lookup. These were SQLite tests once; what they check is the same.
const std = @import("std");

const Index = @import("Index.zig");
const query = @import("query.zig");
// Named, not relative — must match query.zig's own import mechanism for this file, or
// content_graph.zig becomes reachable two ways within this test's module tree at once. See the
// comment on query.zig's own `content_graph` import.
const content_graph = @import("content_graph");

const testing = std.testing;

fn realNote(index: *Index, path: []const u8, stem: []const u8, title: []const u8) !i64 {
    return index.upsertNote(.{ .path = path, .stem = stem, .title = title, .mtime_ns = 0, .size = 0, .hash = 0 });
}

/// One note with an outline, so the section tests don't each rebuild the same fixture.
/// Lines are what attribute a link to a section, so they matter as much as the text.
/// `extra` rows are appended to the outline; `links` are the note's own.
fn seedOutline(index: *Index, extra_headings: []const Index.HeadingIn, links: []const Index.LinkIn, blocks: []const Index.Block, tags: []const Index.TagIn) !void {
    const a = try realNote(index, "a.md", "a", "");
    _ = try realNote(index, "b.md", "b", "");
    var headings: std.ArrayListUnmanaged(Index.HeadingIn) = .empty;
    defer headings.deinit(testing.allocator);
    try headings.appendSlice(testing.allocator, &.{
        .{ .text = "Alpha", .level = 1, .line = 4 },
        .{ .text = "Beta", .level = 2, .line = 9 },
        .{ .text = "Gamma", .level = 2, .line = 14 },
        .{ .text = "Delta", .level = 1, .line = 20 },
    });
    try headings.appendSlice(testing.allocator, extra_headings);
    // Document order, as the parser would produce them.
    std.mem.sort(Index.HeadingIn, headings.items, {}, struct {
        fn lt(_: void, x: Index.HeadingIn, y: Index.HeadingIn) bool {
            return x.line < y.line;
        }
    }.lt);
    try index.setDerived(a, .{ .headings = headings.items, .links = links, .blocks = blocks, .tags = tags });
}

/// Point every link of note `src` at `dst` (the resolver's job, done by hand here).
fn pointLinks(index: *Index, src: i64, dst: i64) !void {
    const n = index.note(src).?;
    for (n.links, 0..) |_, i| try index.setLinkDst(src, i, dst, false);
}

fn degreeOf(edges: []const content_graph.ItemEdge, idx: u32) u32 {
    var n: u32 = 0;
    for (edges) |e| {
        if (e.a == idx or e.b == idx) n += 1;
    }
    return n;
}

test "a note's interior is its outline, hung off a root" {
    const gpa = testing.allocator;
    var index = Index.init(gpa, testing.io);
    defer index.deinit();
    try seedOutline(&index, &.{}, &.{}, &.{}, &.{});

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const cg = try query.noteContentGraph(&index, arena.allocator(), 1, "A");

    // Root + four headings, four outline edges.
    try testing.expectEqual(@as(usize, 5), cg.items.len);
    try testing.expectEqual(@as(usize, 4), cg.edges.len);
    try testing.expect(cg.items[0].kind == .root);
    try testing.expectEqualStrings("A", cg.items[0].text);
    try testing.expectEqualStrings("Alpha", cg.items[1].text);
    try testing.expectEqualStrings("Delta", cg.items[4].text);

    const parent_of = struct {
        fn f(g: content_graph.ContentGraph, child: u32) u32 {
            for (g.edges) |e| if (e.b == child) return e.a;
            return 999;
        }
    }.f;
    try testing.expectEqual(@as(u32, 0), parent_of(cg, 1)); // Alpha -> root
    try testing.expectEqual(@as(u32, 1), parent_of(cg, 2)); // Beta -> Alpha
    try testing.expectEqual(@as(u32, 1), parent_of(cg, 3)); // Gamma -> Alpha
    try testing.expectEqual(@as(u32, 0), parent_of(cg, 4)); // Delta -> root
    try testing.expectEqual(@as(u32, 3), degreeOf(cg.edges, 1));
}

test "a note with no headings is still one item, not an empty graph" {
    // What makes descending into any note safe to do unconditionally.
    const gpa = testing.allocator;
    var index = Index.init(gpa, testing.io);
    defer index.deinit();
    _ = try realNote(&index, "a.md", "a", "");

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const cg = try query.noteContentGraph(&index, arena.allocator(), 1, "Bare");
    try testing.expectEqual(@as(usize, 1), cg.items.len);
    try testing.expectEqual(@as(usize, 0), cg.edges.len);
    try testing.expectEqualStrings("Bare", cg.items[0].text);
}

test "links to another note never become content-graph items or edges" {
    // Only headings/blocks/tags/embeds of *this* note, plus this note's own self-links, belong
    // in its content graph — an ordinary outgoing wikilink leaves the note entirely.
    const gpa = testing.allocator;
    var index = Index.init(gpa, testing.io);
    defer index.deinit();
    try seedOutline(&index, &.{}, &.{
        .{ .raw = "b", .kind = .wikilink, .line = 1, .col = 0 },
        .{ .raw = "b", .kind = .wikilink, .line = 10, .col = 0 },
        .{ .raw = "b", .kind = .wikilink, .line = 11, .col = 0 },
        .{ .raw = "b", .kind = .wikilink, .line = 22, .col = 0 },
    }, &.{}, &.{});
    try pointLinks(&index, 1, 2);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const cg = try query.noteContentGraph(&index, arena.allocator(), 1, "A");

    // Root plus four headings only — none of the four outgoing links added an item or an edge.
    try testing.expectEqual(@as(usize, 5), cg.items.len);
    try testing.expectEqual(@as(usize, 4), cg.edges.len);
    for (cg.edges) |e| try testing.expect(e.kind == .outline);
}

test "a note linking to its own heading draws an edge inside the graph" {
    const gpa = testing.allocator;
    var index = Index.init(gpa, testing.io);
    defer index.deinit();
    // From inside Delta (line 22) back up to Beta, by heading, case-insensitively.
    try seedOutline(&index, &.{}, &.{.{ .raw = "a#Beta", .heading = "beta", .kind = .wikilink, .line = 22, .col = 0 }}, &.{}, &.{});
    try pointLinks(&index, 1, 1);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const cg = try query.noteContentGraph(&index, arena.allocator(), 1, "A");

    var found = false;
    for (cg.edges) |e| {
        if (e.kind != .link) continue;
        found = true;
        try testing.expectEqual(@as(u32, 4), e.a); // Delta, the section holding line 22
        try testing.expectEqual(@as(u32, 2), e.b); // Beta
    }
    try testing.expect(found);
}

test "a repeated heading still gets its own identity" {
    // Ids key animation state across a reindex, so two `## Notes` sections must not collide.
    const gpa = testing.allocator;
    var index = Index.init(gpa, testing.io);
    defer index.deinit();
    const a = try realNote(&index, "a.md", "a", "");
    try index.setDerived(a, .{ .headings = &.{
        .{ .text = "Notes", .level = 2, .line = 2 },
        .{ .text = "Notes", .level = 2, .line = 8 },
    } });

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const cg = try query.noteContentGraph(&index, arena.allocator(), 1, "A");
    try testing.expectEqual(@as(usize, 3), cg.items.len);
    try testing.expect(cg.items[1].id != cg.items[2].id);
    // And neither collides with the root.
    try testing.expect(cg.items[1].id != 0);
    try testing.expect(cg.items[2].id != 0);
}

test "section identity survives edits that only move lines" {
    // The reason ids come from heading text and not line numbers: typing above a heading
    // renumbers it, and the graph must not lose its animation state for that.
    const gpa = testing.allocator;
    var index = Index.init(gpa, testing.io);
    defer index.deinit();
    const a = try realNote(&index, "a.md", "a", "");
    try index.setDerived(a, .{ .headings = &.{.{ .text = "Alpha", .level = 1, .line = 3 }} });

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const before = try query.noteContentGraph(&index, arena.allocator(), 1, "A");

    // Same heading, pushed down the file.
    try index.setDerived(a, .{ .headings = &.{.{ .text = "Alpha", .level = 1, .line = 17 }} });
    const after = try query.noteContentGraph(&index, arena.allocator(), 1, "A");

    try testing.expectEqual(before.items[1].id, after.items[1].id);
    try testing.expectEqual(@as(u32, 3), before.items[1].line);
    try testing.expectEqual(@as(u32, 17), after.items[1].line);
}

test "blocks, tags, and embeds attach to the nearest enclosing heading" {
    const gpa = testing.allocator;
    var index = Index.init(gpa, testing.io);
    defer index.deinit();
    // A paragraph before any heading (belongs to root), a list under Alpha, a tag under Beta,
    // and an embed under Delta.
    try seedOutline(
        &index,
        &.{},
        &.{.{ .raw = "diagram.png", .kind = .embed, .line = 21, .col = 0 }},
        &.{ .{ .kind = .paragraph, .line_start = 0, .line_end = 0, .weight = 3 }, .{ .kind = .list, .line_start = 5, .line_end = 6, .weight = 4 } },
        &.{.{ .tag = "todo", .line = 10 }},
    );
    try pointLinks(&index, 1, 2);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const cg = try query.noteContentGraph(&index, arena.allocator(), 1, "A");

    // Root(0) + 4 headings(1-4) + paragraph + list + tag + embed = 9.
    try testing.expectEqual(@as(usize, 9), cg.items.len);

    const parent_of = struct {
        fn f(g: content_graph.ContentGraph, child: u32) u32 {
            for (g.edges) |e| if (e.b == child) return e.a;
            return 999;
        }
    }.f;

    var paragraph_idx: ?u32 = null;
    var list_idx: ?u32 = null;
    var tag_idx: ?u32 = null;
    var embed_idx: ?u32 = null;
    for (cg.items, 0..) |it, i| {
        switch (it.kind) {
            .paragraph => paragraph_idx = @intCast(i),
            .list => list_idx = @intCast(i),
            .tag => tag_idx = @intCast(i),
            .embed => embed_idx = @intCast(i),
            else => {},
        }
    }
    try testing.expect(paragraph_idx != null and list_idx != null and tag_idx != null and embed_idx != null);

    try testing.expectEqual(@as(u32, 0), parent_of(cg, paragraph_idx.?)); // root
    try testing.expectEqual(@as(u32, 1), parent_of(cg, list_idx.?)); // Alpha
    try testing.expectEqual(@as(u32, 2), parent_of(cg, tag_idx.?)); // Beta
    try testing.expectEqual(@as(u32, 4), parent_of(cg, embed_idx.?)); // Delta

    try testing.expectEqualStrings("todo", cg.items[tag_idx.?].text);
    try testing.expectEqualStrings("diagram.png", cg.items[embed_idx.?].text);
    try testing.expectEqual(@as(u32, 3), cg.items[paragraph_idx.?].weight);
    try testing.expectEqual(@as(u32, 4), cg.items[list_idx.?].weight);
}

test "completion matches case-insensitively, in folded order, and treats wildcards as text" {
    const gpa = testing.allocator;
    var index = Index.init(gpa, testing.io);
    defer index.deinit();
    _ = try realNote(&index, "AB Aurigae.md", "AB Aurigae", "");
    _ = try realNote(&index, "Ab Anar.md", "Ab Anar", "");
    _ = try realNote(&index, "Zebra.md", "Zebra", "Zebra");
    var created = false;
    _ = try index.ensurePhantom("Ghost", &created);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    // Folded order, so the two spellings of `ab` sort together rather than splitting on case.
    const ab = try query.complete(&index, a, "AB", 64);
    try testing.expectEqual(@as(usize, 2), ab.len);
    try testing.expectEqualStrings("Ab Anar", ab[0].target);
    try testing.expectEqualStrings("AB Aurigae", ab[1].target);
    // Title falls back to the stem when the note has none.
    try testing.expectEqualStrings("Ab Anar", ab[0].title);

    // An empty prefix is every real note, still capped by the limit; phantoms stay out.
    const all = try query.complete(&index, a, "", 64);
    try testing.expectEqual(@as(usize, 3), all.len);
    try testing.expectEqual(@as(usize, 1), (try query.complete(&index, a, "", 1)).len);

    // `%` and `_` are ordinary characters, never wildcards.
    try testing.expectEqual(@as(usize, 0), (try query.complete(&index, a, "%", 64)).len);
    try testing.expectEqual(@as(usize, 0), (try query.complete(&index, a, "_ebra", 64)).len);
}

test "completion offers aliases after stems" {
    const gpa = testing.allocator;
    var index = Index.init(gpa, testing.io);
    defer index.deinit();
    const n = try realNote(&index, "Abacus.md", "Abacus", "");
    try index.setDerived(n, .{ .aliases = &.{ "Counting frame", "abc" } });
    _ = try realNote(&index, "Abbey.md", "Abbey", "");

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const rows = try query.complete(&index, arena.allocator(), "ab", 64);
    try testing.expectEqual(@as(usize, 3), rows.len);
    try testing.expectEqualStrings("Abacus", rows[0].target);
    try testing.expectEqualStrings("Abbey", rows[1].target);
    try testing.expectEqualStrings("abc", rows[2].target);
    try testing.expectEqualStrings("Abacus.md", rows[2].path);
}

test "media completion seeks by name and by stem, once per file" {
    const gpa = testing.allocator;
    var index = Index.init(gpa, testing.io);
    defer index.deinit();
    try index.upsertMedia("img/Diagram.png");
    try index.upsertMedia("img/dog.jpg");
    try index.upsertMedia("cat.png");

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const d = try query.completeMedia(&index, arena.allocator(), "d", 64);
    try testing.expectEqual(@as(usize, 2), d.len);
    try testing.expectEqualStrings("Diagram.png", d[0].target);
    try testing.expectEqualStrings("img/dog.jpg", d[1].path);
    const full = try query.completeMedia(&index, arena.allocator(), "diagram.png", 64);
    try testing.expectEqual(@as(usize, 1), full.len);
    try testing.expectEqual(@as(usize, 0), (try query.completeMedia(&index, arena.allocator(), "zzz", 64)).len);
}

test "heading completion is one note's outline, in document order" {
    const gpa = testing.allocator;
    var index = Index.init(gpa, testing.io);
    defer index.deinit();
    try seedOutline(&index, &.{}, &.{}, &.{}, &.{});
    // A heading on the *other* note, to prove the query is scoped to the one asked for.
    try index.setDerived(2, .{ .headings = &.{.{ .text = "Alpha", .level = 1, .line = 0 }} });

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const all = try query.completeHeadings(&index, a, "a.md", "", 64);
    try testing.expectEqual(@as(usize, 4), all.len);
    try testing.expectEqualStrings("Alpha", all[0].text);
    try testing.expectEqualStrings("Delta", all[3].text);
    try testing.expectEqual(@as(u32, 1), all[0].level);
    try testing.expectEqual(@as(u32, 2), all[1].level);
    try testing.expectEqual(@as(u32, 20), all[3].line);

    // Case-insensitive, and a substring rather than only a prefix.
    const beta = try query.completeHeadings(&index, a, "a.md", "et", 64);
    try testing.expectEqual(@as(usize, 1), beta.len);
    try testing.expectEqualStrings("Beta", beta[0].text);

    try testing.expectEqual(@as(usize, 2), (try query.completeHeadings(&index, a, "a.md", "", 2)).len);
    try testing.expectEqual(@as(usize, 0), (try query.completeHeadings(&index, a, "a.md", "zzz", 64)).len);
    try testing.expectEqual(@as(usize, 0), (try query.completeHeadings(&index, a, "gone.md", "", 64)).len);
}

test "a portable markdown link into a section draws the same interior edge" {
    // The completer writes `[A > Habitat and Range](a.md#habitat-and-range)`, so the anchor
    // reaching the index is a slug, not the heading as written. The interior view has to see
    // that as the same section-to-section edge a `[[A#Habitat and Range]]` would draw.
    const gpa = testing.allocator;
    var index = Index.init(gpa, testing.io);
    defer index.deinit();
    try seedOutline(
        &index,
        &.{.{ .text = "Habitat and Range", .level = 2, .line = 6 }},
        &.{.{ .raw = "a.md#habitat-and-range", .heading = "habitat-and-range", .kind = .markdown, .line = 22, .col = 0 }},
        &.{},
        &.{},
    );
    try pointLinks(&index, 1, 1);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const cg = try query.noteContentGraph(&index, arena.allocator(), 1, "A");

    // Headings are ordered by line, so the new one sits between Alpha (4) and Beta (9): items
    // are root, Alpha, Habitat and Range, Beta, Gamma, Delta.
    try testing.expectEqualStrings("Habitat and Range", cg.items[2].text);
    var found = false;
    for (cg.edges) |e| {
        if (e.kind != .link) continue;
        found = true;
        try testing.expectEqual(@as(u32, 5), e.a); // Delta, the section holding line 22
        try testing.expectEqual(@as(u32, 2), e.b); // Habitat and Range
    }
    try testing.expect(found);
}

test "heading lookup accepts the slug spelling as well as the text" {
    const gpa = testing.allocator;
    var index = Index.init(gpa, testing.io);
    defer index.deinit();
    try seedOutline(&index, &.{.{ .text = "Habitat and Range", .level = 2, .line = 6 }}, &.{}, &.{}, &.{});

    try testing.expectEqual(@as(u32, 9), try query.headingLine(&index, "a.md", "Beta"));
    try testing.expectEqual(@as(u32, 6), try query.headingLine(&index, "a.md", "Habitat and Range"));
    try testing.expectEqual(@as(u32, 6), try query.headingLine(&index, "a.md", "habitat-and-range"));
    try testing.expectEqual(@as(u32, 0), try query.headingLine(&index, "a.md", "nope"));
}

test "backlinks list every mention, grouped by source path then position" {
    const gpa = testing.allocator;
    var index = Index.init(gpa, testing.io);
    defer index.deinit();
    const a = try realNote(&index, "a.md", "a", "Alpha");
    const b = try realNote(&index, "b.md", "b", "");
    const c = try realNote(&index, "c.md", "c", "");
    try index.setDerived(b, .{ .links = &.{ .{ .raw = "a", .kind = .wikilink, .line = 5, .col = 2 }, .{ .raw = "a", .alias = "first", .kind = .wikilink, .line = 1, .col = 0 } } });
    try index.setDerived(c, .{ .links = &.{.{ .raw = "a", .kind = .wikilink, .line = 0, .col = 0 }} });
    try pointLinks(&index, b, a);
    try pointLinks(&index, c, a);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const rows = try query.backlinksFor(&index, arena.allocator(), "a.md");
    try testing.expectEqual(@as(usize, 3), rows.len);
    try testing.expectEqualStrings("b.md", rows[0].path);
    try testing.expectEqual(@as(u32, 1), rows[0].line);
    try testing.expectEqualStrings("first", rows[0].alias);
    try testing.expectEqual(@as(u32, 5), rows[1].line);
    try testing.expectEqualStrings("c.md", rows[2].path);
    try testing.expectEqual(@as(usize, 0), (try query.backlinksFor(&index, arena.allocator(), "b.md")).len);
}
