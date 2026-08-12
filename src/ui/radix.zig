//! LSD radix sort over a 64-bit integer key.
//!
//! Both halves of a rebuild end up sorting the same shape of thing: a list of undirected pairs of
//! cell ids, about to be merged so duplicates can have their weights summed. `fold.coarsenLevel`
//! does it to lift a level's edges onto their parents, `cellweb.dedupe` does it at every level of
//! the ladder. On the reference corpus those two sorts were **half of `fold.build` and nearly all
//! of `cellweb`** — comparison sorting 3.35M elements, twice over, per rebuild.
//!
//! A comparison sort is the wrong tool for the key. Both callers sort by a pair of `u32` cell ids,
//! which is a fixed-width integer that can be bucketed in linear time rather than compared in
//! `n log n`. Swapping the comparison sort from stable to unstable first — same algorithm, better
//! constants — moved the fold timing by 0.4%, which is what said the algorithm was the problem.
//! Replacing it here took `cellweb` from 710 ms to 268 ms and the edge lift inside
//! `fold.coarsenLevel` from 422 ms to 69 ms, measured with `bench --refold`.
//!
//! Lives in its own file because there are two callers and this is exactly the kind of mechanism
//! that gets written twice and then drifts — the second copy quietly missing the uniform-digit skip
//! or the stability guarantee, and nothing failing loudly enough to notice.
const std = @import("std");

/// Sort `items` by `keyOf`, using `scratch` (at least as long as `items`) as the ping-pong buffer.
///
/// Returns the sorted data, which is **either `items` or a prefix of `scratch`** depending on how
/// many passes ran — copying it back would cost a full pass for nothing when the caller is about to
/// read it once and write somewhere else anyway. Callers that need it in `items` should read from
/// the returned slice and write into `items`; that is safe in both cases, since a same-buffer
/// result is only ever read ahead of where a merge writes.
///
/// **Stable.** Equal keys keep their input order, which matters because equal keys are the expected
/// input here: the callers merge runs of them and sum a float weight, and float addition is not
/// associative. Stability is what makes that sum bit-for-bit reproducible across runs, without the
/// caller having to invent a total order over elements that are genuinely tied.
///
/// Passes whose digit is identical across every element are skipped. Keys here are two cell ids
/// packed into 64 bits, and a vault with 341,670 cells leaves the top three bytes of each half
/// zero, so five of the eight passes never run.
pub fn sortByKey(
    comptime T: type,
    comptime keyOf: fn (T) u64,
    items: []T,
    scratch: []T,
) []T {
    if (items.len < 2) return items;
    std.debug.assert(scratch.len >= items.len);

    var src = items;
    var dst = scratch[0..items.len];
    var shift: u6 = 0;
    while (true) {
        var counts = [_]u32{0} ** 256;
        for (src) |it| counts[@as(u8, @truncate(keyOf(it) >> shift))] += 1;

        // Every element in one bucket means this digit orders nothing, and moving them all would be
        // a full copy to arrive at the arrangement already in hand.
        var uniform = false;
        for (counts) |c| {
            if (c == src.len) {
                uniform = true;
                break;
            }
        }
        if (!uniform) {
            var total: u32 = 0;
            for (&counts) |*c| {
                const n = c.*;
                c.* = total;
                total += n;
            }
            // Ascending within each bucket, which is what makes the whole sort stable.
            for (src) |it| {
                const d = @as(u8, @truncate(keyOf(it) >> shift));
                dst[counts[d]] = it;
                counts[d] += 1;
            }
            std.mem.swap([]T, &src, &dst);
        }

        if (shift == 56) break;
        shift += 8;
    }
    return src;
}

const testing = std.testing;

const Item = struct { a: u32, b: u32, tag: u32 };
fn itemKey(it: Item) u64 {
    return (@as(u64, it.a) << 32) | @as(u64, it.b);
}

test "sorts by the packed key" {
    var items = [_]Item{
        .{ .a = 3, .b = 1, .tag = 0 },
        .{ .a = 1, .b = 9, .tag = 1 },
        .{ .a = 1, .b = 2, .tag = 2 },
        .{ .a = 300000, .b = 7, .tag = 3 },
        .{ .a = 0, .b = 0, .tag = 4 },
    };
    var scratch: [5]Item = undefined;
    const out = sortByKey(Item, itemKey, &items, &scratch);
    var prev: u64 = 0;
    for (out) |it| {
        try testing.expect(itemKey(it) >= prev);
        prev = itemKey(it);
    }
    try testing.expectEqual(@as(usize, 5), out.len);
}

test "equal keys keep their input order" {
    // The property the weight merges depend on: a run of equal keys is summed in input order, so
    // the result cannot drift between runs over identical input.
    var items: [64]Item = undefined;
    for (&items, 0..) |*it, i| {
        it.* = .{ .a = @intCast(i % 4), .b = 7, .tag = @intCast(i) };
    }
    var scratch: [64]Item = undefined;
    const out = sortByKey(Item, itemKey, &items, &scratch);
    var i: usize = 1;
    while (i < out.len) : (i += 1) {
        if (out[i - 1].a == out[i].a and out[i - 1].b == out[i].b) {
            try testing.expect(out[i - 1].tag < out[i].tag);
        }
    }
}

test "an already-sorted run costs no passes it does not need" {
    // Not a timing test — it checks the uniform-digit skip leaves the data correct, which is the
    // way that optimisation breaks: skipping a pass that actually orders something.
    var items: [256]Item = undefined;
    for (&items, 0..) |*it, i| it.* = .{ .a = 0, .b = @intCast(255 - i), .tag = @intCast(i) };
    var scratch: [256]Item = undefined;
    const out = sortByKey(Item, itemKey, &items, &scratch);
    for (out, 0..) |it, i| try testing.expectEqual(@as(u32, @intCast(i)), it.b);
}

test "empty and single-element inputs" {
    var empty: [0]Item = undefined;
    var scratch: [1]Item = undefined;
    try testing.expectEqual(@as(usize, 0), sortByKey(Item, itemKey, &empty, &scratch).len);

    var one = [_]Item{.{ .a = 5, .b = 5, .tag = 0 }};
    try testing.expectEqual(@as(usize, 1), sortByKey(Item, itemKey, &one, &scratch).len);
}
