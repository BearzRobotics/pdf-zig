// SPDX-License-Identifier: LGPL-2.0-or-later
//! TrueType fonts made for the tests, so that none has to be shipped.
//!
//! Glyphs: 0 `.notdef`, 1 "A" (a triangle), 2 "B" (a square), 3 "C" (made of
//! glyphs 1 and 2), 4 "D", 5 a ligature without a character, 6 "é", 7 U+1F600
//! (only with a format 12 map).

const std = @import("std");
const Allocator = std.mem.Allocator;
const List = std.ArrayList(u8);

pub const Options = struct {
    fs_type: u16 = 0,
    os2: bool = true,
    /// Add a format 12 character map, which also has U+1F600.
    format12: bool = false,
    /// With `format12`: a space, drawn as glyph 5.
    space: bool = false,
    /// Long `loca` entries.
    long_loca: bool = false,
    /// Full metrics for this many glyphs; the rest share the last advance.
    metrics: u16 = 8,
};

pub const glyph_count = 8;
/// The advance of glyph `i` in the font's 2000 units per em.
pub fn advance(i: u16) u16 {
    return 1000 + 100 * i;
}

fn put(a: Allocator, out: *List, comptime T: type, v: T) !void {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, v, .big);
    try out.appendSlice(a, &bytes);
}

fn words(a: Allocator, out: *List, values: []const i32) !void {
    for (values) |v| try put(a, out, u16, @bitCast(@as(i16, @intCast(v))));
}

/// One closed contour through `points`, all on the curve.
fn simple(a: Allocator, points: []const [2]i32) ![]const u8 {
    var out: List = .empty;
    try words(a, &out, &.{ 1, 0, 0, 1000, 1400, @intCast(points.len - 1), 0 });
    // Each coordinate is a 16 bit difference from the one before.
    for (points) |_| try out.append(a, 1);
    for (0..2) |axis| {
        var last: i32 = 0;
        for (points) |p| {
            try words(a, &out, &.{p[axis] - last});
            last = p[axis];
        }
    }
    return out.items;
}

/// A composite of `parts`, each moved right by its offset.
fn composite(a: Allocator, parts: []const [2]i32) ![]const u8 {
    var out: List = .empty;
    try words(a, &out, &.{ -1, 0, 0, 1600, 1400 });
    for (parts, 0..) |part, i| {
        // Arguments are words and are offsets; more follow but for the last.
        const flags: i32 = 0x0001 | 0x0002 | @as(i32, if (i + 1 < parts.len) 0x0020 else 0);
        try words(a, &out, &.{ flags, part[0], part[1], 0 });
    }
    return out.items;
}

/// The font as a file, allocated from `a`, an arena.
pub fn make(a: Allocator, options: Options) ![]u8 {
    const box = [_][2]i32{ .{ 100, 0 }, .{ 100, 1400 }, .{ 900, 1400 }, .{ 900, 0 } };
    const glyphs = [glyph_count][]const u8{
        try simple(a, &box),
        try simple(a, &.{ .{ 0, 0 }, .{ 500, 1400 }, .{ 1000, 0 } }),
        try simple(a, &.{ .{ 100, 100 }, .{ 100, 900 }, .{ 900, 900 }, .{ 900, 100 } }),
        try composite(a, &.{ .{ 1, 0 }, .{ 2, 600 } }),
        try simple(a, &.{ .{ 0, 0 }, .{ 0, 1400 }, .{ 1000, 700 } }),
        try simple(a, &.{ .{ 0, 0 }, .{ 1000, 1400 }, .{ 1000, 0 } }),
        try simple(a, &.{ .{ 200, 200 }, .{ 800, 1200 }, .{ 800, 200 } }),
        try simple(a, &.{ .{ 0, 700 }, .{ 500, 1400 }, .{ 1000, 700 }, .{ 500, 0 } }),
    };

    var glyf: List = .empty;
    var loca: List = .empty;
    for (glyphs) |g| {
        if (options.long_loca) try put(a, &loca, u32, @intCast(glyf.items.len)) else try put(a, &loca, u16, @intCast(glyf.items.len / 2));
        try glyf.appendSlice(a, g);
        while (glyf.items.len % 4 != 0) try glyf.append(a, 0);
    }
    if (options.long_loca) try put(a, &loca, u32, @intCast(glyf.items.len)) else try put(a, &loca, u16, @intCast(glyf.items.len / 2));

    var head: List = .empty;
    try head.appendNTimes(a, 0, 54);
    std.mem.writeInt(u32, head.items[0..4], 0x00010000, .big);
    std.mem.writeInt(u32, head.items[12..16], 0x5F0F3CF5, .big);
    std.mem.writeInt(u16, head.items[18..20], 2000, .big);
    for ([_]i16{ 0, -400, 1600, 1400 }, 0..) |v, i| std.mem.writeInt(i16, head.items[36 + i * 2 ..][0..2], v, .big);
    std.mem.writeInt(u16, head.items[50..52], @intFromBool(options.long_loca), .big);

    var hhea: List = .empty;
    try hhea.appendNTimes(a, 0, 36);
    std.mem.writeInt(u32, hhea.items[0..4], 0x00010000, .big);
    std.mem.writeInt(i16, hhea.items[4..6], 1500, .big);
    std.mem.writeInt(i16, hhea.items[6..8], -500, .big);
    std.mem.writeInt(u16, hhea.items[34..36], options.metrics, .big);

    var hmtx: List = .empty;
    for (0..glyph_count) |i| {
        if (i < options.metrics) try put(a, &hmtx, u16, advance(@intCast(i)));
        try put(a, &hmtx, u16, 0);
    }

    var maxp: List = .empty;
    try maxp.appendNTimes(a, 0, 32);
    std.mem.writeInt(u32, maxp.items[0..4], 0x00010000, .big);
    std.mem.writeInt(u16, maxp.items[4..6], glyph_count, .big);

    // Format 4: "A" to "D" in one segment by a delta, "é" through the glyph
    // array, and the closing segment.
    var four: List = .empty;
    try words(a, &four, &.{ 4, 0, 0, 6, 4, 1, 2 });
    for ([_]u16{ 'D', 0xE9, 0xFFFF }) |v| try put(a, &four, u16, v);
    try put(a, &four, u16, 0);
    for ([_]u16{ 'A', 0xE9, 0xFFFF }) |v| try put(a, &four, u16, v);
    for ([_]u16{ @bitCast(@as(i16, 1 - 'A')), 0, 1 }) |v| try put(a, &four, u16, v);
    // The second entry's offset leads to the word after the third.
    for ([_]u16{ 0, 4, 0, 6 }) |v| try put(a, &four, u16, v);
    std.mem.writeInt(u16, four.items[2..4], @intCast(four.items.len), .big);

    var twelve: List = .empty;
    const all_groups = [_][3]u32{ .{ ' ', ' ', 5 }, .{ 'A', 'D', 1 }, .{ 0xE9, 0xE9, 6 }, .{ 0x1F600, 0x1F600, 7 } };
    const groups: []const [3]u32 = all_groups[if (options.space) 0 else 1..];
    try put(a, &twelve, u16, 12);
    try put(a, &twelve, u16, 0);
    try put(a, &twelve, u32, @intCast(16 + groups.len * 12));
    try put(a, &twelve, u32, 0);
    try put(a, &twelve, u32, @intCast(groups.len));
    for (groups) |g| for (g) |v| try put(a, &twelve, u32, v);

    var cmap: List = .empty;
    const tables: u16 = if (options.format12) 2 else 1;
    try words(a, &cmap, &.{ 0, tables });
    const first: u32 = 4 + 8 * @as(u32, tables);
    try words(a, &cmap, &.{ 3, 1 });
    try put(a, &cmap, u32, first);
    if (options.format12) {
        try words(a, &cmap, &.{ 3, 10 });
        try put(a, &cmap, u32, first + @as(u32, @intCast(four.items.len)));
    }
    try cmap.appendSlice(a, four.items);
    if (options.format12) try cmap.appendSlice(a, twelve.items);

    var os2: List = .empty;
    try os2.appendNTimes(a, 0, 96);
    std.mem.writeInt(u16, os2.items[0..2], 4, .big);
    std.mem.writeInt(u16, os2.items[4..6], 700, .big);
    std.mem.writeInt(u16, os2.items[8..10], options.fs_type, .big);
    std.mem.writeInt(i16, os2.items[88..90], 1400, .big);

    var post: List = .empty;
    try post.appendNTimes(a, 0, 32);
    std.mem.writeInt(u32, post.items[0..4], 0x00030000, .big);
    std.mem.writeInt(i32, post.items[4..8], -12 * 65536, .big);

    // Name 6, in UTF-16, with characters a PDF name would have to escape.
    var name: List = .empty;
    const text = "Test Font(1)-Bold";
    try words(a, &name, &.{ 0, 1, 18, 3, 1, 0x409, 6, @intCast(text.len * 2), 0 });
    for (text) |c| try put(a, &name, u16, c);

    const Part = struct { tag: *const [4]u8, bytes: []const u8 };
    var parts: std.ArrayList(Part) = .empty;
    if (options.os2) try parts.append(a, .{ .tag = "OS/2", .bytes = os2.items });
    try parts.appendSlice(a, &.{
        .{ .tag = "cmap", .bytes = cmap.items }, .{ .tag = "fpgm", .bytes = "\xb0\x00\x2c\x2d" },
        .{ .tag = "glyf", .bytes = glyf.items }, .{ .tag = "head", .bytes = head.items },
        .{ .tag = "hhea", .bytes = hhea.items }, .{ .tag = "hmtx", .bytes = hmtx.items },
        .{ .tag = "loca", .bytes = loca.items }, .{ .tag = "maxp", .bytes = maxp.items },
        .{ .tag = "name", .bytes = name.items }, .{ .tag = "post", .bytes = post.items },
    });

    var out: List = .empty;
    try put(a, &out, u32, 0x00010000);
    try words(a, &out, &.{ @intCast(parts.items.len), 0, 0, 0 });
    var offset: u32 = @intCast(12 + parts.items.len * 16);
    for (parts.items) |part| {
        try out.appendSlice(a, part.tag);
        try put(a, &out, u32, 0);
        try put(a, &out, u32, offset);
        try put(a, &out, u32, @intCast(part.bytes.len));
        offset += @intCast(std.mem.alignForward(usize, part.bytes.len, 4));
    }
    for (parts.items) |part| {
        try out.appendSlice(a, part.bytes);
        while (out.items.len % 4 != 0) try out.append(a, 0);
    }
    return out.items;
}
