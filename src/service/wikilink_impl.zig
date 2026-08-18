//! atlas's implementation of the SDK's `"wikilink"` service — the answer to *which file does
//! `[[Note]]` mean*.
//!
//! Called from the UI thread inside the markdown renderer's draw, so nothing here may block
//! on I/O beyond a sqlite SELECT (WAL + Serialized keeps that cheap against the indexer).
//! Callers memoize against `generation`, so the steady-state cost is a hash lookup on their
//! side and a candidate-list reuse on ours.
const std = @import("std");
const sdk = @import("fizzy_sdk");
const State = @import("../State.zig");
const resolve = @import("../index/resolve.zig");
const query = @import("../index/query.zig");

const Api = sdk.services.wikilink.Api;

pub const vtable: Api.VTable = .{
    .resolve = resolveFn,
    .generation = generation,
    .complete = complete,
    .indexing = indexing,
};

fn resolveFn(
    ctx: *anyopaque,
    target: []const u8,
    heading: []const u8,
    source_path: []const u8,
    gpa: std.mem.Allocator,
) anyerror!Api.Resolution {
    const st: *State = @ptrCast(@alignCast(ctx));
    const root = st.vault_root orelse return .{ .status = .unresolved };
    if (st.db == null) return .{ .status = .unresolved };

    // First open: the walk hasn't committed anything yet. Prefer "not sure" over a flash of red.
    if (st.busy.load(.acquire) and st.indexer.counts().note_count == 0) {
        return .{ .status = .indexing };
    }

    const cands = try st.ensureCandidates();
    var rel_buf: [query.max_rel_path]u8 = undefined;
    const src_rel = query.vaultRelative(root, source_path, &rel_buf) orelse
        (if (source_path.len == 0) "" else source_path);

    var buf: [resolve.max_path_len]u8 = undefined;
    const match = resolve.resolve(target, src_rel, cands, &buf) orelse {
        return .{ .status = .unresolved };
    };

    const rel = cands[match.index].path;
    const abs = try std.fs.path.join(gpa, &.{ root, rel });
    errdefer gpa.free(abs);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const title_src = query.noteTitle(&st.db.?, arena.allocator(), rel) catch "";
    const title = try gpa.dupe(u8, if (title_src.len > 0) title_src else query.stemOf(rel));

    const line: u32 = if (heading.len > 0)
        (query.headingLine(&st.db.?, rel, heading) catch 0)
    else
        0;

    return .{
        .status = if (match.ambiguous) .ambiguous else .resolved,
        .path = abs,
        .line = line,
        .title = title,
    };
}

fn generation(ctx: *anyopaque) u64 {
    const st: *State = @ptrCast(@alignCast(ctx));
    return st.generation.load(.acquire);
}

fn complete(
    ctx: *anyopaque,
    prefix: []const u8,
    source_path: []const u8,
    limit: usize,
    gpa: std.mem.Allocator,
) anyerror![]Api.Candidate {
    _ = source_path;
    const st: *State = @ptrCast(@alignCast(ctx));
    const root = st.vault_root orelse return &.{};
    const db = if (st.db) |*d| d else return &.{};

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const rows = try query.complete(db, arena.allocator(), prefix, limit);

    var out: std.ArrayList(Api.Candidate) = .empty;
    errdefer {
        for (out.items) |c| {
            gpa.free(c.target);
            gpa.free(c.path);
            gpa.free(c.title);
        }
        out.deinit(gpa);
    }
    for (rows) |r| {
        const abs = try std.fs.path.join(gpa, &.{ root, r.path });
        errdefer gpa.free(abs);
        try out.append(gpa, .{
            .target = try gpa.dupe(u8, r.target),
            .path = abs,
            .title = try gpa.dupe(u8, r.title),
            .phantom = false,
        });
    }
    return out.toOwnedSlice(gpa);
}

fn indexing(ctx: *anyopaque) bool {
    const st: *State = @ptrCast(@alignCast(ctx));
    return st.busy.load(.acquire);
}
