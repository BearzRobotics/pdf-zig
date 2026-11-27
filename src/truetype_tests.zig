// SPDX-License-Identifier: LGPL-2.0-or-later
//! Reading and subsetting TrueType fonts.

const std = @import("std");
const pdf = @import("root.zig");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Font = pdf.truetype.Font;
const test_font = @import("test_font.zig");

fn load(a: Allocator, options: test_font.Options) !Font {
    return Font.init(testing.allocator, try test_font.make(a, options), .{});
}

test "characters, widths and what a descriptor needs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]test_font.Options{ .{}, .{ .long_loca = true }, .{ .format12 = true } }) |options| {
        var font = try load(a, options);
        defer font.deinit();
        try testing.expectEqual(@as(u16, 2000), font.units_per_em);
        try testing.expectEqual(@as(u16, 8), font.num_glyphs);
        for ([_]struct { u21, ?u16 }{
            .{ 'A', 1 },                                     .{ 'B', 2 },        .{ 'C', 3 },     .{ 'D', 4 },     .{ 0xE9, 6 },
            .{ '@', null },                                  .{ 'E', null },     .{ 0xE8, null }, .{ 0xEA, null }, .{ 0xFFFF, null },
            .{ 0x1F600, if (options.format12) 7 else null }, .{ 0x1F601, null },
        }) |c| try testing.expectEqual(c[1], font.glyphFor(c[0]));
        // 2000 units to the em, given in thousandths.
        try testing.expectEqual(@as(f64, 550), font.width(1));
        try testing.expectEqual(@as(f64, 800), font.width(6));
        try testing.expectEqualStrings("TestFont1-Bold", font.name);
        try testing.expectEqual(@as(i16, 1500), font.ascender);
        try testing.expectEqual(@as(i16, -500), font.descender);
        try testing.expectEqual(@as(i16, 1400), font.cap_height);
        try testing.expectEqual(@as(u16, 700), font.weight);
        try testing.expectEqual(@as(f64, -12), font.italic_angle);
        try testing.expectEqualSlices(i16, &.{ 0, -400, 1600, 1400 }, &font.bbox);
    }
    // Glyphs past the full metrics are as wide as the last of them.
    var short = try load(a, .{ .metrics = 3 });
    defer short.deinit();
    try testing.expectEqual(@as(f64, 600), short.width(2));
    try testing.expectEqual(@as(f64, 600), short.width(7));
}

test "fsType says what may be embedded" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]struct { u16, pdf.truetype.Permission, bool }{
        .{ 0, .installable, false },            .{ 8, .editable, false },     .{ 4, .preview_and_print, false },
        .{ 0x0100, .installable, true },        .{ 0x0108, .editable, true },
        // Several bits, as old fonts had them: the most permissive counts.
        .{ 0x000A, .editable, false },
        .{ 0x0006, .preview_and_print, false },
    }) |c| {
        var font = try load(a, .{ .fs_type = c[0] });
        defer font.deinit();
        try testing.expectEqual(c[1], font.permission);
        try testing.expectEqual(c[2], font.whole_only);
    }
    const restricted = try test_font.make(a, .{ .fs_type = 2 });
    try testing.expectError(error.FontNotEmbeddable, Font.init(testing.allocator, restricted, .{}));
    var allowed = try Font.init(testing.allocator, restricted, .{ .permission_obtained = true });
    defer allowed.deinit();
    try testing.expectEqual(pdf.truetype.Permission.restricted, allowed.permission);
    var copy = try allowed.clone(testing.allocator);
    defer copy.deinit();
    try testing.expectEqual(pdf.truetype.Permission.restricted, copy.permission);
    // Bitmaps only: outlines may not be embedded, whatever the caller says.
    for ([_]u16{ 0x0200, 0x0208 }) |bits| {
        try testing.expectError(error.FontNotEmbeddable, Font.init(testing.allocator, try test_font.make(a, .{ .fs_type = bits }), .{ .permission_obtained = true }));
    }
    // A font that says nothing restricts nothing.
    var silent = try load(a, .{ .os2 = false });
    defer silent.deinit();
    try testing.expectEqual(pdf.truetype.Permission.installable, silent.permission);
}

/// The bytes of table `tag` of a font file, or null.
fn tableOf(font: []const u8, tag: []const u8) ?[]const u8 {
    for (0..std.mem.readInt(u16, font[4..6], .big)) |i| {
        const record = font[12 + i * 16 ..][0..16];
        if (!std.mem.eql(u8, record[0..4], tag)) continue;
        return font[std.mem.readInt(u32, record[8..12], .big)..][0..std.mem.readInt(u32, record[12..16], .big)];
    }
    return null;
}

/// The data of glyph `i` in a subset, whose `loca` is long.
fn glyphOf(font: []const u8, i: usize) []const u8 {
    const loca = tableOf(font, "loca").?;
    const from = std.mem.readInt(u32, loca[i * 4 ..][0..4], .big);
    const to = std.mem.readInt(u32, loca[i * 4 + 4 ..][0..4], .big);
    return tableOf(font, "glyf").?[from..to];
}

test "a subset keeps the glyphs used and what they are made of, under their numbers" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]bool{ false, true }) |long| {
        for ([_]u16{ 8, 2 }) |metrics| {
            const original = try test_font.make(a, .{ .long_loca = long, .metrics = metrics });
            var font = try Font.init(testing.allocator, original, .{});
            defer font.deinit();
            // "C" is made of "A" and "B".
            const subset = try font.subset(a, &.{3});
            try testing.expectEqual(@as(u32, 0x00010000), std.mem.readInt(u32, subset[0..4], .big));
            // It ends after glyph 3, and keeps the hinting program.
            try testing.expectEqual(@as(u16, 4), std.mem.readInt(u16, tableOf(subset, "maxp").?[4..6], .big));
            try testing.expectEqual(@min(metrics, 4), std.mem.readInt(u16, tableOf(subset, "hhea").?[34..36], .big));
            const full: usize = @min(metrics, 4);
            try testing.expectEqual(full * 4 + (4 - full) * 2, tableOf(subset, "hmtx").?.len);
            try testing.expect(tableOf(subset, "fpgm") != null and tableOf(subset, "cvt ") == null);
            try testing.expect(tableOf(subset, "cmap") == null and tableOf(subset, "name") == null);
            for (0..4) |i| try testing.expect(glyphOf(subset, i).len > 0);
            // The file's checksum comes out as the specification says.
            try testing.expectEqual(@as(u32, 0xB1B0AFBA), pdf.truetype.checksum(subset));

            const only_d = try font.subset(a, &.{4});
            try testing.expectEqual(@as(usize, 0), glyphOf(only_d, 1).len);
            try testing.expectEqual(@as(usize, 0), glyphOf(only_d, 3).len);
            try testing.expect(glyphOf(only_d, 0).len > 0 and glyphOf(only_d, 4).len > 0);
        }
    }
    var font = try load(a, .{});
    defer font.deinit();
    try testing.expectError(error.BadFont, font.subset(a, &.{8}));
}

test "other kinds of file are told apart from damaged ones" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectError(error.UnsupportedFont, Font.init(testing.allocator, "OTTO\x00\x01", .{}));
    try testing.expectError(error.UnsupportedFont, Font.init(testing.allocator, "ttcf\x00\x01\x00\x00", .{}));
    for ([_][]const u8{ "", "\x00\x01", "%PDF-1.7", "\x00\x01\x00\x00\x00\x09" }) |bad| {
        try testing.expectError(error.BadFont, Font.init(testing.allocator, bad, .{}));
    }
    // A symbol font's map is not Unicode.
    const symbol = try test_font.make(a, .{});
    const cmap_at = @intFromPtr(tableOf(symbol, "cmap").?.ptr) - @intFromPtr(symbol.ptr);
    std.mem.writeInt(u16, symbol[cmap_at + 6 ..][0..2], 0, .big);
    try testing.expectError(error.UnsupportedFont, Font.init(testing.allocator, symbol, .{}));
}

test "a composite glyph that contains itself ends" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bytes = try test_font.make(a, .{ .long_loca = true });
    // The first part of glyph 3 becomes glyph 3, and then a glyph that is not there.
    const glyph = glyphOf(bytes, 3);
    const at = @intFromPtr(glyph.ptr) - @intFromPtr(bytes.ptr);
    std.mem.writeInt(u16, bytes[at + 12 ..][0..2], 3, .big);
    var loops = try Font.init(testing.allocator, bytes, .{});
    defer loops.deinit();
    _ = try loops.subset(a, &.{3});
    std.mem.writeInt(u16, bytes[at + 12 ..][0..2], 900, .big);
    var missing = try Font.init(testing.allocator, bytes, .{});
    defer missing.deinit();
    try testing.expectError(error.BadFont, missing.subset(a, &.{3}));
}

test "damaged fonts are errors, never crashes (seeded mutation)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sources = [_][]const u8{
        try test_font.make(a, .{}),
        try test_font.make(a, .{ .format12 = true, .long_loca = true, .metrics = 2 }),
    };
    var prng = std.Random.DefaultPrng.init(0x7f07);
    const random = prng.random();
    var loaded: usize = 0;
    var cut: usize = 0;
    for (0..60_000) |round| {
        const source = sources[round % 2];
        const length = if (random.uintLessThan(u8, 8) == 0) random.intRangeAtMost(usize, 0, source.len) else source.len;
        // Exactly as long as it is, so that reading past the end is caught.
        const copy = try testing.allocator.dupe(u8, source[0..length]);
        defer testing.allocator.free(copy);
        if (copy.len > 0) for (0..random.intRangeAtMost(usize, 1, 4)) |_| {
            const at = random.uintLessThan(usize, copy.len);
            // Large values stress offsets and counts more than random bytes.
            copy[at] = if (random.boolean()) 0xFF else random.int(u8);
        };
        var font = Font.init(testing.allocator, copy, .{ .permission_obtained = true }) catch continue;
        defer font.deinit();
        loaded += 1;
        for ([_]u21{ 0, 'A', 'C', 0xE9, 0xFFFF, 0x1F600, 0x10FFFF }) |c| {
            if (font.glyphFor(c)) |g| {
                try testing.expect(g > 0 and g < font.num_glyphs);
                _ = font.width(g);
            }
        }
        var glyphs: [3]u16 = undefined;
        for (&glyphs) |*g| g.* = random.uintLessThan(u16, @min(font.num_glyphs, 64));
        const subset = font.subset(testing.allocator, &glyphs) catch continue;
        defer testing.allocator.free(subset);
        cut += 1;
    }
    // The mutations leave enough standing to reach the later code.
    try testing.expect(loaded > 5000 and cut > 3000);
}

fn useUnderAllocationFailure(gpa: Allocator, bytes: []const u8) !void {
    var font = try Font.init(gpa, bytes, .{});
    defer font.deinit();
    const subset = try font.subset(gpa, &.{ 3, 6 });
    gpa.free(subset);
}

test "every failed allocation while reading and subsetting is reported" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.checkAllAllocationFailures(testing.allocator, useUnderAllocationFailure, .{try test_font.make(arena.allocator(), .{})});
}
