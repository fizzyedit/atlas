//! `Db` against real sqlite. Structural checks on the DDL string can't tell you whether sqlite
//! accepts it, whether reopening is a no-op, or whether a stale schema is actually discarded —
//! only sqlite can, so these tests run it.
const std = @import("std");
const sqlite = @import("sqlite");

const Db = @import("Db.zig");
const schema = @import("schema.zig");
const query = @import("query.zig");
// Named, not relative — must match query.zig's own import mechanism for this file, or
// content_graph.zig becomes reachable two ways within this test's module tree at once. See the
// comment on query.zig's own `content_graph` import.
const content_graph = @import("content_graph");

const testing = std.testing;

/// A throwaway directory that cleans itself up, so a failing test can't leave a database behind
/// for the next run to trip over. `Db` takes a path rather than a `Dir`, so this resolves one.
const TempDir = struct {
    tmp: std.testing.TmpDir,
    /// `realPathFileAlloc` returns a sentinel slice; keep that type so free matches the alloc.
    path: [:0]u8,
    threaded: std.Io.Threaded,

    fn create(gpa: std.mem.Allocator, _: []const u8) !TempDir {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var threaded = std.Io.Threaded.init_single_threaded;
        const path = try tmp.dir.realPathFileAlloc(threaded.io(), ".", gpa);
        return .{ .tmp = tmp, .path = path, .threaded = threaded };
    }

    fn io(self: *TempDir) std.Io {
        return self.threaded.io();
    }

    fn destroy(self: *TempDir, gpa: std.mem.Allocator) void {
        gpa.free(self.path);
        self.tmp.cleanup();
    }

    fn open(self: *TempDir, gpa: std.mem.Allocator, vault: []const u8) !Db {
        return Db.openIn(gpa, self.io(), self.path, vault);
    }
};

fn countRows(db: *Db, comptime sql: []const u8) !usize {
    const n = try db.conn.one(usize, sql, .{}, .{});
    return n orelse 0;
}

test "creating an index produces every table" {
    const gpa = testing.allocator;
    var tmp = try TempDir.create(gpa, "create");
    defer tmp.destroy(gpa);

    var db = try tmp.open(gpa, "/some/vault");
    defer db.close(gpa);

    // sqlite_master is the authority on what actually got created.
    const n = try countRows(&db, "SELECT count(*) FROM sqlite_master WHERE type='table'");
    try testing.expectEqual(@as(usize, 8), n); // meta, notes, aliases, headings, links, tags, blocks, media
}

test "media rows are independent of notes" {
    // Attachments must never reach the note graph: no phantom, no link, no cascade from a
    // note deletion. They exist only so `![[diagram.png]]` can resolve to a file.
    const gpa = testing.allocator;
    var tmp = try TempDir.create(gpa, "media");
    defer tmp.destroy(gpa);

    var db = try tmp.open(gpa, "/some/vault");
    defer db.close(gpa);

    try db.conn.exec("INSERT INTO notes(id, path, stem, stem_fold) VALUES(1,'a.md','a','a')", .{}, .{});
    try db.conn.exec(
        "INSERT INTO media(path, stem, stem_fold, name_fold) VALUES('assets/d.png','d','d','d.png')",
        .{},
        .{},
    );

    try db.conn.exec("DELETE FROM notes WHERE id = 1", .{}, .{});
    try testing.expectEqual(@as(usize, 1), try countRows(&db, "SELECT count(*) FROM media"));
    try testing.expectEqual(@as(usize, 0), try countRows(&db, "SELECT count(*) FROM notes"));
}

test "media has the unique index its upsert depends on" {
    // Asserted through the *upsert*, not by provoking the violation.
    //
    // `Indexer.upsertMedia` writes `ON CONFLICT(path) DO UPDATE`, and sqlite only accepts a
    // conflict target that a unique index actually covers — so "is `media.path` unique" and "does
    // re-indexing an attachment update instead of duplicating it" are the same question, and this
    // asks the one the app depends on.
    //
    // The older version inserted twice and expected `error.SQLiteConstraint`. It passed, but the
    // wrapper logs at error level whenever a statement finalizes non-OK, and Zig's test runner
    // fails any test that logs an error — so a correct build exited nonzero. There is no way to
    // trip a constraint through this wrapper quietly: `reset` reports the same code that `deinit`
    // does.
    const gpa = testing.allocator;
    var tmp = try TempDir.create(gpa, "media-unique");
    defer tmp.destroy(gpa);

    var db = try tmp.open(gpa, "/some/vault");
    defer db.close(gpa);

    const unique_on_path = (try db.conn.one(
        i64,
        \\SELECT count(*) FROM pragma_index_list('media') li
        \\JOIN pragma_index_info(li.name) ii
        \\WHERE li."unique" = 1 AND ii.name = 'path'
    ,
        .{},
        .{},
    )) orelse 0;
    try testing.expect(unique_on_path >= 1);

    const upsert =
        \\INSERT INTO media(path, stem, stem_fold, name_fold) VALUES('a.png', ?, ?, 'a.png')
        \\ON CONFLICT(path) DO UPDATE SET stem = excluded.stem, stem_fold = excluded.stem_fold
    ;
    try db.conn.exec(upsert, .{}, .{ "first", "first" });
    try db.conn.exec(upsert, .{}, .{ "second", "second" });

    const rows = (try db.conn.one(i64, "SELECT count(*) FROM media", .{}, .{})) orelse 0;
    try testing.expectEqual(@as(i64, 1), rows);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const stem = try db.conn.oneAlloc([]const u8, arena.allocator(), "SELECT stem FROM media", .{}, .{});
    try testing.expectEqualStrings("second", stem orelse "");
}

test "the schema version is stamped" {
    const gpa = testing.allocator;
    var tmp = try TempDir.create(gpa, "version");
    defer tmp.destroy(gpa);

    var db = try tmp.open(gpa, "/some/vault");
    defer db.close(gpa);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const v = try db.conn.oneAlloc([]const u8, arena.allocator(), "SELECT value FROM meta WHERE key='schema_version'", .{}, .{});
    try testing.expect(v != null);
    try testing.expectEqual(schema.version, try std.fmt.parseInt(u32, v.?, 10));
}

test "reopening keeps the data" {
    const gpa = testing.allocator;
    var tmp = try TempDir.create(gpa, "reopen");
    defer tmp.destroy(gpa);

    {
        var db = try tmp.open(gpa, "/some/vault");
        defer db.close(gpa);
        try db.conn.exec(
            "INSERT INTO notes(path, stem, stem_fold) VALUES('a/Note.md', 'Note', 'note')",
            .{},
            .{},
        );
    }
    {
        var db = try tmp.open(gpa, "/some/vault");
        defer db.close(gpa);
        // Survived — so the reopen path really did reuse the file rather than rebuild it.
        try testing.expectEqual(@as(usize, 1), try countRows(&db, "SELECT count(*) FROM notes"));
    }
}

test "a stale schema version is discarded" {
    const gpa = testing.allocator;
    var tmp = try TempDir.create(gpa, "stale");
    defer tmp.destroy(gpa);

    {
        var db = try tmp.open(gpa, "/some/vault");
        defer db.close(gpa);
        try db.conn.exec("INSERT INTO notes(path, stem, stem_fold) VALUES('x.md','x','x')", .{}, .{});
        try db.conn.exec("UPDATE meta SET value = '99999' WHERE key = 'schema_version'", .{}, .{});
    }
    {
        var db = try tmp.open(gpa, "/some/vault");
        defer db.close(gpa);
        // Rebuilt from scratch: the row is gone and the version is ours again.
        try testing.expectEqual(@as(usize, 0), try countRows(&db, "SELECT count(*) FROM notes"));
    }
}

test "a corrupt file is discarded rather than failing the open" {
    const gpa = testing.allocator;
    var tmp = try TempDir.create(gpa, "corrupt");
    defer tmp.destroy(gpa);

    const db_path = try std.fs.path.join(gpa, &.{ tmp.path, "index.db" });
    defer gpa.free(db_path);
    try std.Io.Dir.cwd().writeFile(tmp.io(), .{
        .sub_path = db_path,
        .data = "this is definitely not a sqlite database",
        .flags = .{ .truncate = true },
    });

    var db = try tmp.open(gpa, "/some/vault");
    defer db.close(gpa);
    try testing.expectEqual(@as(usize, 0), try countRows(&db, "SELECT count(*) FROM notes"));
}

test "a different vault behind the same directory wipes the index" {
    const gpa = testing.allocator;
    var tmp = try TempDir.create(gpa, "collision");
    defer tmp.destroy(gpa);

    {
        var db = try tmp.open(gpa, "/vault/one");
        defer db.close(gpa);
        try db.conn.exec("INSERT INTO notes(path, stem, stem_fold) VALUES('x.md','x','x')", .{}, .{});
    }
    {
        // Same cache directory, different vault — the stored notes describe somebody else's
        // files, so reusing them would be silently wrong.
        var db = try tmp.open(gpa, "/vault/two");
        defer db.close(gpa);
        try testing.expectEqual(@as(usize, 0), try countRows(&db, "SELECT count(*) FROM notes"));
    }
}

test "the same vault reopening does not wipe the index" {
    const gpa = testing.allocator;
    var tmp = try TempDir.create(gpa, "same-vault");
    defer tmp.destroy(gpa);

    {
        var db = try tmp.open(gpa, "/vault/one");
        defer db.close(gpa);
        try db.conn.exec("INSERT INTO notes(path, stem, stem_fold) VALUES('x.md','x','x')", .{}, .{});
    }
    {
        var db = try tmp.open(gpa, "/vault/one");
        defer db.close(gpa);
        try testing.expectEqual(@as(usize, 1), try countRows(&db, "SELECT count(*) FROM notes"));
    }
}

test "real notes must have unique paths but phantoms need not" {
    const gpa = testing.allocator;
    var tmp = try TempDir.create(gpa, "unique");
    defer tmp.destroy(gpa);

    var db = try tmp.open(gpa, "/some/vault");
    defer db.close(gpa);

    // The uniqueness rule lives in the partial index. Triggering a constraint violation makes
    // zig-sqlite log at err, which the test runner treats as a failure — so check the index
    // is there, then prove the partial carve-out with two phantoms that share a path.
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const idx = try db.conn.oneAlloc(
        []const u8,
        arena.allocator(),
        "SELECT sql FROM sqlite_master WHERE type='index' AND name='notes_path_real'",
        .{},
        .{},
    );
    try testing.expect(idx != null);
    try testing.expect(std.mem.indexOf(u8, idx.?, "phantom = 0") != null);

    try db.conn.exec("INSERT INTO notes(path, stem, stem_fold, phantom) VALUES('','Ghost','ghost',1)", .{}, .{});
    try db.conn.exec("INSERT INTO notes(path, stem, stem_fold, phantom) VALUES('','Other','other',1)", .{}, .{});
    try testing.expectEqual(@as(usize, 2), try countRows(&db, "SELECT count(*) FROM notes WHERE phantom = 1"));
}

test "deleting a note cascades to its links" {
    const gpa = testing.allocator;
    var tmp = try TempDir.create(gpa, "cascade");
    defer tmp.destroy(gpa);

    var db = try tmp.open(gpa, "/some/vault");
    defer db.close(gpa);

    try db.conn.exec("INSERT INTO notes(id, path, stem, stem_fold) VALUES(1,'a.md','a','a')", .{}, .{});
    try db.conn.exec("INSERT INTO notes(id, path, stem, stem_fold) VALUES(2,'b.md','b','b')", .{}, .{});
    try db.conn.exec(
        "INSERT INTO links(src_id, dst_id, raw, kind, line, col) VALUES(1, 2, 'b', 0, 0, 0)",
        .{},
        .{},
    );

    try db.conn.exec("DELETE FROM notes WHERE id = 1", .{}, .{});
    // Without `PRAGMA foreign_keys=ON` this would be 1, and the graph would accumulate edges
    // from notes that no longer exist.
    try testing.expectEqual(@as(usize, 0), try countRows(&db, "SELECT count(*) FROM links"));
}

test "orphan phantoms are purged but linked ones survive" {
    // The bug: editing `[[test]]` into `[[testi]]` replaced the link but left the `test`
    // phantom behind forever, so every intermediate state of a link you typed became a
    // permanent floating node in the graph that offered to create a file when clicked.
    const gpa = testing.allocator;
    var tmp = try TempDir.create(gpa, "orphan-phantoms");
    defer tmp.destroy(gpa);

    var db = try tmp.open(gpa, "/some/vault");
    defer db.close(gpa);

    // A real note, a phantom it still links to, and two orphaned phantoms.
    try db.conn.exec("INSERT INTO notes(id, path, stem, stem_fold) VALUES(1,'a.md','a','a')", .{}, .{});
    try db.conn.exec("INSERT INTO notes(id, path, stem, stem_fold, phantom) VALUES(2,'','testi','testi',1)", .{}, .{});
    try db.conn.exec("INSERT INTO notes(id, path, stem, stem_fold, phantom) VALUES(3,'','test','test',1)", .{}, .{});
    try db.conn.exec("INSERT INTO notes(id, path, stem, stem_fold, phantom) VALUES(4,'','markdown','markdown',1)", .{}, .{});
    try db.conn.exec(
        "INSERT INTO links(src_id, dst_id, raw, kind, line, col) VALUES(1, 2, 'testi', 0, 0, 0)",
        .{},
        .{},
    );

    try query.purgeOrphanPhantoms(&db);

    try testing.expectEqual(@as(usize, 1), try countRows(&db, "SELECT count(*) FROM notes WHERE phantom = 1"));
    try testing.expectEqual(@as(usize, 1), try countRows(&db, "SELECT count(*) FROM notes WHERE id = 2"));
    // The real note and the surviving link are untouched.
    try testing.expectEqual(@as(usize, 1), try countRows(&db, "SELECT count(*) FROM notes WHERE phantom = 0"));
    try testing.expectEqual(@as(usize, 1), try countRows(&db, "SELECT count(*) FROM links"));
}

test "fts5 is compiled in" {
    // Not used yet, but the build pins it now precisely so this can't quietly stop being true
    // and cost a re-verified C build across six release targets later.
    const gpa = testing.allocator;
    var tmp = try TempDir.create(gpa, "fts5");
    defer tmp.destroy(gpa);

    var db = try tmp.open(gpa, "/some/vault");
    defer db.close(gpa);

    try db.conn.exec("CREATE VIRTUAL TABLE probe USING fts5(body)", .{}, .{});
}

// -- note interior ----------------------------------------------------------------

/// One note with an outline, so the section tests don't each rebuild the same fixture.
/// Lines are what attribute a link to a section, so they matter as much as the text.
fn seedOutline(db: *Db) !void {
    try db.conn.exec("INSERT INTO notes(id, path, stem, stem_fold) VALUES(1,'a.md','a','a')", .{}, .{});
    try db.conn.exec("INSERT INTO notes(id, path, stem, stem_fold) VALUES(2,'b.md','b','b')", .{}, .{});
    const rows = [_]struct { t: []const u8, f: []const u8, l: i64, ln: i64 }{
        .{ .t = "Alpha", .f = "alpha", .l = 1, .ln = 4 },
        .{ .t = "Beta", .f = "beta", .l = 2, .ln = 9 },
        .{ .t = "Gamma", .f = "gamma", .l = 2, .ln = 14 },
        .{ .t = "Delta", .f = "delta", .l = 1, .ln = 20 },
    };
    for (rows) |r| {
        try db.conn.exec(
            "INSERT INTO headings(note_id, text, text_fold, level, line) VALUES(1,?,?,?,?)",
            .{},
            .{ r.t, r.f, r.l, r.ln },
        );
    }
}

/// Distinct neighbours of `idx` — the `Item.degree` field the old `SectionNode` had, recomputed
/// straight from the edge list now that `content_graph.Item` doesn't carry it.
fn degreeOf(edges: []const content_graph.ItemEdge, idx: u32) u32 {
    var n: u32 = 0;
    for (edges) |e| {
        if (e.a == idx or e.b == idx) n += 1;
    }
    return n;
}

test "a note's interior is its outline, hung off a root" {
    const gpa = testing.allocator;
    var tmp = try TempDir.create(gpa, "sections");
    defer tmp.destroy(gpa);
    var db = try tmp.open(gpa, "/some/vault");
    defer db.close(gpa);
    try seedOutline(&db);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const cg = try query.noteContentGraph(&db, arena.allocator(), 1, "A");

    // Root plus four headings.
    try testing.expectEqual(@as(usize, 5), cg.items.len);
    try testing.expectEqual(@as(u32, 0), cg.items[0].level);
    try testing.expect(cg.items[0].kind == .root);
    try testing.expectEqualStrings("A", cg.items[0].text);
    try testing.expectEqualStrings("Alpha", cg.items[1].text);

    // Beta and Gamma are `##` under Alpha; Delta is `#` and goes back to the root.
    try testing.expectEqual(@as(usize, 4), cg.edges.len);
    for (cg.edges) |e| try testing.expect(e.kind == .outline);
    const parent_of = struct {
        fn f(g: content_graph.ContentGraph, child: u32) u32 {
            for (g.edges) |e| if (e.b == child) return e.a;
            return 999;
        }
    }.f;
    try testing.expectEqual(@as(u32, 0), parent_of(cg, 1)); // Alpha -> root
    try testing.expectEqual(@as(u32, 1), parent_of(cg, 2)); // Beta  -> Alpha
    try testing.expectEqual(@as(u32, 1), parent_of(cg, 3)); // Gamma -> Alpha
    try testing.expectEqual(@as(u32, 0), parent_of(cg, 4)); // Delta -> root
}

test "a note with no headings is still one item, not an empty graph" {
    // What makes descending into any note safe to do unconditionally.
    const gpa = testing.allocator;
    var tmp = try TempDir.create(gpa, "bare");
    defer tmp.destroy(gpa);
    var db = try tmp.open(gpa, "/some/vault");
    defer db.close(gpa);
    try db.conn.exec("INSERT INTO notes(id, path, stem, stem_fold) VALUES(1,'a.md','a','a')", .{}, .{});

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const cg = try query.noteContentGraph(&db, arena.allocator(), 1, "Bare");
    try testing.expectEqual(@as(usize, 1), cg.items.len);
    try testing.expectEqual(@as(usize, 0), cg.edges.len);
    try testing.expectEqualStrings("Bare", cg.items[0].text);
}

test "links to another note never become content-graph items or edges" {
    // Only headings/blocks/tags/embeds of *this* note, plus this note's own self-links, belong
    // in its content graph — an ordinary outgoing wikilink leaves the note entirely.
    const gpa = testing.allocator;
    var tmp = try TempDir.create(gpa, "attrib");
    defer tmp.destroy(gpa);
    var db = try tmp.open(gpa, "/some/vault");
    defer db.close(gpa);
    try seedOutline(&db);

    for ([_]i64{ 1, 10, 11, 22 }) |line| {
        try db.conn.exec(
            "INSERT INTO links(src_id, dst_id, raw, kind, line, col) VALUES(1, 2, 'b', 0, ?, 0)",
            .{},
            .{line},
        );
    }

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const cg = try query.noteContentGraph(&db, arena.allocator(), 1, "A");

    // Root plus four headings only — none of the four outgoing links added an item or an edge.
    try testing.expectEqual(@as(usize, 5), cg.items.len);
    try testing.expectEqual(@as(usize, 4), cg.edges.len);
    for (cg.edges) |e| try testing.expect(e.kind == .outline);
}

test "a note linking to its own heading draws an edge inside the graph" {
    const gpa = testing.allocator;
    var tmp = try TempDir.create(gpa, "selflink");
    defer tmp.destroy(gpa);
    var db = try tmp.open(gpa, "/some/vault");
    defer db.close(gpa);
    try seedOutline(&db);

    // From inside Delta (line 22) back up to Beta, by heading, case-insensitively.
    try db.conn.exec(
        "INSERT INTO links(src_id, dst_id, raw, heading, kind, line, col) VALUES(1, 1, 'a#Beta', 'beta', 0, 22, 0)",
        .{},
        .{},
    );

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const cg = try query.noteContentGraph(&db, arena.allocator(), 1, "A");

    var found = false;
    for (cg.edges) |e| {
        if (e.kind != .link) continue;
        found = true;
        try testing.expectEqual(@as(u32, 4), e.a); // Delta
        try testing.expectEqual(@as(u32, 2), e.b); // Beta
    }
    try testing.expect(found);
    // Recomputed from edges: Beta has its outline parent plus this link, Delta has its own
    // parent plus this link, so both read as heavier bodies.
    try testing.expectEqual(@as(u32, 2), degreeOf(cg.edges, 2));
    try testing.expectEqual(@as(u32, 2), degreeOf(cg.edges, 4));
}

test "a repeated heading still gets its own identity" {
    // Ids key animation state across a reindex, so two `## Notes` sections must not collide.
    const gpa = testing.allocator;
    var tmp = try TempDir.create(gpa, "dupe");
    defer tmp.destroy(gpa);
    var db = try tmp.open(gpa, "/some/vault");
    defer db.close(gpa);
    try db.conn.exec("INSERT INTO notes(id, path, stem, stem_fold) VALUES(1,'a.md','a','a')", .{}, .{});
    for ([_]i64{ 2, 8 }) |line| {
        try db.conn.exec(
            "INSERT INTO headings(note_id, text, text_fold, level, line) VALUES(1,'Notes','notes',2,?)",
            .{},
            .{line},
        );
    }

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const cg = try query.noteContentGraph(&db, arena.allocator(), 1, "A");
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
    var tmp = try TempDir.create(gpa, "stableid");
    defer tmp.destroy(gpa);
    var db = try tmp.open(gpa, "/some/vault");
    defer db.close(gpa);
    try db.conn.exec("INSERT INTO notes(id, path, stem, stem_fold) VALUES(1,'a.md','a','a')", .{}, .{});
    try db.conn.exec(
        "INSERT INTO headings(note_id, text, text_fold, level, line) VALUES(1,'Alpha','alpha',1,3)",
        .{},
        .{},
    );

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const before = try query.noteContentGraph(&db, arena.allocator(), 1, "A");

    // Same heading, pushed down the file.
    try db.conn.exec("UPDATE headings SET line = 17 WHERE note_id = 1", .{}, .{});
    const after = try query.noteContentGraph(&db, arena.allocator(), 1, "A");

    try testing.expectEqual(before.items[1].id, after.items[1].id);
    try testing.expectEqual(@as(u32, 3), before.items[1].line);
    try testing.expectEqual(@as(u32, 17), after.items[1].line);
}

test "blocks, tags, and embeds attach to the nearest enclosing heading" {
    const gpa = testing.allocator;
    var tmp = try TempDir.create(gpa, "content-graph");
    defer tmp.destroy(gpa);
    var db = try tmp.open(gpa, "/some/vault");
    defer db.close(gpa);
    try seedOutline(&db);

    // A paragraph before any heading (belongs to root), a list under Alpha, a tag under Beta,
    // and an embed under Delta.
    try db.conn.exec(
        "INSERT INTO blocks(note_id, kind, line_start, line_end, weight) VALUES(1, 0, 0, 0, 3)",
        .{},
        .{},
    );
    try db.conn.exec(
        "INSERT INTO blocks(note_id, kind, line_start, line_end, weight) VALUES(1, 1, 5, 6, 4)",
        .{},
        .{},
    );
    try db.conn.exec(
        "INSERT INTO tags(note_id, tag, tag_fold, line) VALUES(1, 'todo', 'todo', 10)",
        .{},
        .{},
    );
    try db.conn.exec(
        "INSERT INTO links(src_id, dst_id, raw, alias, kind, line, col) VALUES(1, 2, 'diagram.png', '', 1, 21, 0)",
        .{},
        .{},
    );

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const cg = try query.noteContentGraph(&db, arena.allocator(), 1, "A");

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

test "completion seeks the stem index instead of scanning the table" {
    // The regression this guards is a UI freeze, not a wrong answer: `stem_fold LIKE 'ab%'`
    // returns exactly the right rows, but sqlite's case-insensitive LIKE refuses the
    // BINARY-collated index, so every keystroke scanned all 286k rows of a Wikipedia-sized
    // vault and sorted the survivors — ~270 ms of stalled typing. Only the plan can tell the
    // two apart, so the plan is what's asserted.
    const gpa = testing.allocator;
    var tmp = try TempDir.create(gpa, "complete-plan");
    defer tmp.destroy(gpa);

    var db = try tmp.open(gpa, "/some/vault");
    defer db.close(gpa);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const Step = struct { id: i64, parent: i64, notused: i64, detail: []const u8 };
    var stmt = try db.conn.prepare(
        \\EXPLAIN QUERY PLAN
        \\SELECT stem, path, title FROM notes
        \\WHERE phantom = 0 AND stem_fold >= 'ab' AND stem_fold < 'ac'
        \\ORDER BY stem_fold LIMIT 64
    );
    defer stmt.deinit();
    var iter = try stmt.iterator(Step, .{});

    var seeks: usize = 0;
    while (try iter.nextAlloc(arena.allocator(), .{})) |step| {
        // A full scan, or a temp b-tree that has to see every matching row before the LIMIT
        // can take 64 of them — either one is the freeze coming back.
        try testing.expect(std.mem.indexOf(u8, step.detail, "SCAN notes") == null);
        try testing.expect(std.mem.indexOf(u8, step.detail, "TEMP B-TREE") == null);
        if (std.mem.indexOf(u8, step.detail, "SEARCH") != null and
            std.mem.indexOf(u8, step.detail, "notes_stem_fold") != null) seeks += 1;
    }
    try testing.expectEqual(@as(usize, 1), seeks);
}

test "completion matches case-insensitively and treats LIKE wildcards as text" {
    const gpa = testing.allocator;
    var tmp = try TempDir.create(gpa, "complete-rows");
    defer tmp.destroy(gpa);

    var db = try tmp.open(gpa, "/some/vault");
    defer db.close(gpa);

    try db.conn.exec("INSERT INTO notes(id,path,stem,stem_fold,title) VALUES(1,'AB Aurigae.md','AB Aurigae','ab aurigae','')", .{}, .{});
    try db.conn.exec("INSERT INTO notes(id,path,stem,stem_fold,title) VALUES(2,'Ab Anar.md','Ab Anar','ab anar','')", .{}, .{});
    try db.conn.exec("INSERT INTO notes(id,path,stem,stem_fold,title) VALUES(3,'Zebra.md','Zebra','zebra','Zebra')", .{}, .{});
    try db.conn.exec("INSERT INTO notes(id,path,stem,stem_fold,title) VALUES(4,'Ghost.md','Ghost','ghost','')", .{}, .{});
    try db.conn.exec("UPDATE notes SET phantom = 1 WHERE id = 4", .{}, .{});

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    // Folded order, so the two spellings of `ab` sort together rather than splitting on case.
    const ab = try query.complete(&db, a, "AB", 64);
    try testing.expectEqual(@as(usize, 2), ab.len);
    try testing.expectEqualStrings("Ab Anar", ab[0].target);
    try testing.expectEqualStrings("AB Aurigae", ab[1].target);
    // Title falls back to the stem when the note has none.
    try testing.expectEqualStrings("Ab Anar", ab[0].title);

    // An empty prefix is every real note, still capped by the limit; phantoms stay out.
    const all = try query.complete(&db, a, "", 64);
    try testing.expectEqual(@as(usize, 3), all.len);
    try testing.expectEqual(@as(usize, 1), (try query.complete(&db, a, "", 1)).len);

    // `%` used to be a wildcard the user could type by accident and match the whole vault.
    try testing.expectEqual(@as(usize, 0), (try query.complete(&db, a, "%", 64)).len);
    try testing.expectEqual(@as(usize, 0), (try query.complete(&db, a, "_ebra", 64)).len);
}

test "heading completion is one note's outline, in document order" {
    const gpa = testing.allocator;
    var tmp = try TempDir.create(gpa, "complete-headings");
    defer tmp.destroy(gpa);
    var db = try tmp.open(gpa, "/some/vault");
    defer db.close(gpa);
    try seedOutline(&db);
    // A heading on the *other* note, to prove the query is scoped to the one asked for.
    try db.conn.exec(
        "INSERT INTO headings(note_id, text, text_fold, level, line) VALUES(2,'Alpha','alpha',1,0)",
        .{},
        .{},
    );

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const all = try query.completeHeadings(&db, a, "a.md", "", 64);
    try testing.expectEqual(@as(usize, 4), all.len);
    try testing.expectEqualStrings("Alpha", all[0].text);
    try testing.expectEqualStrings("Delta", all[3].text);
    try testing.expectEqual(@as(u32, 1), all[0].level);
    try testing.expectEqual(@as(u32, 2), all[1].level);
    try testing.expectEqual(@as(u32, 20), all[3].line);

    // Case-insensitive, and a substring rather than only a prefix.
    const beta = try query.completeHeadings(&db, a, "a.md", "et", 64);
    try testing.expectEqual(@as(usize, 1), beta.len);
    try testing.expectEqualStrings("Beta", beta[0].text);

    try testing.expectEqual(@as(usize, 2), (try query.completeHeadings(&db, a, "a.md", "", 2)).len);
    try testing.expectEqual(@as(usize, 0), (try query.completeHeadings(&db, a, "a.md", "zzz", 64)).len);
    try testing.expectEqual(@as(usize, 0), (try query.completeHeadings(&db, a, "gone.md", "", 64)).len);
}
