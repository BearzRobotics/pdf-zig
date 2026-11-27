// SPDX-License-Identifier: LGPL-2.0-or-later
//! Overlapping integer ranges made disjoint, so that a lookup is one binary
//! search. CMaps and CID width tables may define a range and then redefine
//! parts of it; the later definition applies.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// `lo..=hi`, and which definition it comes from: of two spans that cover a
/// value, the one with the larger `source` wins.
pub const Span = struct { lo: u32, hi: u32, source: u32 };

fn byStart(_: void, x: Span, y: Span) bool {
    return if (x.lo != y.lo) x.lo < y.lo else x.source < y.source;
}

fn latestFirst(_: void, x: Span, y: Span) std.math.Order {
    return std.math.order(y.source, x.source);
}

/// Disjoint spans in increasing order that cover what `spans` cover, each
/// naming the latest definition for its values. At most twice as many as
/// given. Reorders `spans`; a span with `hi < lo` covers nothing. The result
/// is allocated from `a`.
pub fn disjoint(a: Allocator, spans: []Span) Allocator.Error![]Span {
    std.mem.sort(Span, spans, {}, byStart);
    var out: std.ArrayList(Span) = .empty;
    errdefer out.deinit(a);
    // The spans that have started, latest definition on top. Those that have
    // ended are removed when they reach the top.
    var active: std.PriorityQueue(Span, void, latestFirst) = .empty;
    defer active.deinit(a);
    var next: usize = 0;
    // The first value not yet covered; one past u32 at the end.
    var at: u64 = 0;
    while (true) {
        while (next < spans.len and spans[next].lo <= at) : (next += 1) {
            if (spans[next].hi >= spans[next].lo) try active.push(a, spans[next]);
        }
        while (active.peek()) |top| {
            if (top.hi >= at) break;
            _ = active.pop();
        }
        const top = active.peek() orelse {
            if (next >= spans.len) break;
            at = spans[next].lo;
            continue;
        };
        // The winner holds until it ends or another span starts.
        var end: u64 = top.hi;
        if (next < spans.len) end = @min(end, spans[next].lo - 1);
        if (out.items.len > 0 and out.items[out.items.len - 1].source == top.source and @as(u64, out.items[out.items.len - 1].hi) + 1 == at) {
            out.items[out.items.len - 1].hi = @intCast(end);
        } else try out.append(a, .{ .lo = @intCast(at), .hi = @intCast(end), .source = top.source });
        at = end + 1;
    }
    return out.toOwnedSlice(a);
}

test "disjoint spans agree with checking every definition" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var prng = std.Random.DefaultPrng.init(5);
    const rnd = prng.random();
    for (0..500) |_| {
        const n = rnd.uintLessThan(usize, 12);
        const spans = try a.alloc(Span, n);
        for (spans, 0..) |*s, i| {
            const lo = rnd.uintLessThan(u32, 40);
            s.* = .{ .lo = lo, .hi = lo + rnd.uintLessThan(u32, 12) -| 1, .source = @intCast(i) };
        }
        const original = try a.dupe(Span, spans);
        const out = try disjoint(a, spans);
        for (out, 0..) |span, i| if (i > 0) try std.testing.expect(out[i - 1].hi < span.lo);
        for (0..64) |v| {
            var want: ?u32 = null;
            for (original) |s| if (v >= s.lo and v <= s.hi) {
                want = s.source;
            };
            var got: ?u32 = null;
            for (out) |s| if (v >= s.lo and v <= s.hi) {
                got = s.source;
            };
            try std.testing.expectEqual(want, got);
        }
    }
    // The ends of the number range.
    var edge = [_]Span{ .{ .lo = 0, .hi = std.math.maxInt(u32), .source = 0 }, .{ .lo = std.math.maxInt(u32), .hi = std.math.maxInt(u32), .source = 1 } };
    const out = try disjoint(a, &edge);
    try std.testing.expectEqual(@as(usize, 2), out.len);
}
