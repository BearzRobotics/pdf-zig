// SPDX-License-Identifier: LGPL-2.0-or-later
//! The objects of an embedded TrueType font (ISO 32000-1:2008, 9.7 to 9.10): a
//! Type 0 font with `Identity-H` over a `CIDFontType2`, whose character codes
//! are glyph numbers, with a `/ToUnicode` map so that the text can be selected
//! and searched.

const std = @import("std");
const Allocator = std.mem.Allocator;
const object = @import("object.zig");
const serial = @import("write.zig");
const pack = @import("compose_pack.zig");
const truetype = @import("truetype.zig");

const Object = object.Object;
const Dict = object.Dict;
const Ref = object.Ref;

/// Whether `new` should replace `old` as the text of a glyph. A PDF gives a
/// code one text, and a font may use one glyph for two characters (a space and
/// a no-break space, the Greek capital delta and the increment sign). Between
/// single characters the one with the lower number stands, which is the
/// ordinary one, whatever is drawn first; otherwise the first stands.
pub fn preferred(new: []const u8, old: []const u8) bool {
    const n = single(new) orelse return false;
    const o = single(old) orelse return old.len == 0;
    return n < o;
}

/// The character that `text` is, when it is just one.
fn single(text: []const u8) ?u21 {
    if (text.len == 0) return null;
    const length = std.unicode.utf8ByteSequenceLength(text[0]) catch return null;
    if (length != text.len) return null;
    return std.unicode.utf8Decode(text) catch null;
}

/// The glyphs of one font that were drawn, each with the text it stands for
/// (UTF-8), chosen by `preferred`.
pub const Usage = std.AutoArrayHashMapUnmanaged(u16, []const u8);

/// Writes the font: `font_ref` names the Type 0 dictionary, and the other
/// objects are new. `sink.add(object)` makes an object and `sink.set(ref,
/// object)` gives the reserved one its value. Temporaries come from `a`, which
/// must live as long as what `sink` keeps.
pub fn write(a: Allocator, font: *const truetype.Font, used: *const Usage, font_ref: Ref, sink: anytype) !void {
    const glyphs = try a.dupe(u16, used.keys());
    std.mem.sort(u16, glyphs, {}, std.sort.asc(u16));

    // A subset says so with six capitals before its name (9.6.4), which differ
    // when the glyphs do.
    const name = if (font.whole_only) font.name else blk: {
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hash.update(&font.digest);
        hash.update(std.mem.sliceAsBytes(glyphs));
        var digest: [32]u8 = undefined;
        hash.final(&digest);
        var tag: [6]u8 = undefined;
        for (&tag, digest[0..6]) |*t, d| t.* = 'A' + d % 26;
        break :blk try std.fmt.allocPrint(a, "{s}+{s}", .{ &tag, font.name });
    };

    const file: []const u8 = if (font.whole_only) font.data else try font.subset(a, glyphs);
    const file_ref: Ref = try sink.add(Object{ .stream = .{
        .dict = try serial.makeDict(a, &.{
            .{ "Length1", .{ .integer = @intCast(file.len) } },
            .{ "Filter", .{ .name = "FlateDecode" } },
        }),
        .data = try pack.compress(a, file),
    } });

    var box: [4]f64 = undefined;
    for (&box, font.bbox) |*out, v| out.* = font.scale(v);
    // Table 123: fixed pitch (1), symbolic (3), italic (7). Codes that are
    // glyph numbers use no standard encoding, hence symbolic.
    var flags: i64 = 4;
    if (font.fixed_pitch) flags |= 1;
    if (font.italic or font.italic_angle != 0) flags |= 64;
    // Fonts do not record the width of their stems; this follows the weight.
    const thickness: f64 = @as(f64, @floatFromInt(std.math.clamp(font.weight, 100, 900))) / 65;
    const descriptor: Ref = try sink.add(Object{ .dict = try serial.makeDict(a, &.{
        .{ "Type", .{ .name = "FontDescriptor" } },
        .{ "FontName", .{ .name = name } },
        .{ "Flags", .{ .integer = flags } },
        .{ "FontBBox", try serial.numbers(a, &box) },
        .{ "ItalicAngle", .{ .real = font.italic_angle } },
        .{ "Ascent", .{ .real = font.scale(font.ascender) } },
        .{ "Descent", .{ .real = font.scale(font.descender) } },
        .{ "CapHeight", .{ .real = font.scale(font.cap_height) } },
        .{ "StemV", .{ .integer = @intFromFloat(50 + @round(thickness * thickness)) } },
        .{ "FontFile2", .{ .ref = file_ref } },
    }) });

    // Widths by runs of consecutive glyphs: `first [w w ...]` (9.7.4.3).
    var widths: std.ArrayList(Object) = .empty;
    var i: usize = 0;
    while (i < glyphs.len) {
        var j = i + 1;
        while (j < glyphs.len and glyphs[j] == glyphs[j - 1] + 1) j += 1;
        const run = try a.alloc(Object, j - i);
        for (run, glyphs[i..j]) |*w, g| w.* = .{ .real = font.width(g) };
        try widths.append(a, .{ .integer = glyphs[i] });
        try widths.append(a, .{ .array = run });
        i = j;
    }
    const system = try serial.makeDict(a, &.{
        .{ "Registry", .{ .string = "Adobe" } },
        .{ "Ordering", .{ .string = "Identity" } },
        .{ "Supplement", .{ .integer = 0 } },
    });
    const descendant: Ref = try sink.add(Object{ .dict = try serial.makeDict(a, &.{
        .{ "Type", .{ .name = "Font" } },
        .{ "Subtype", .{ .name = "CIDFontType2" } },
        .{ "BaseFont", .{ .name = name } },
        .{ "CIDSystemInfo", .{ .dict = system } },
        .{ "FontDescriptor", .{ .ref = descriptor } },
        .{ "W", .{ .array = widths.items } },
        .{ "CIDToGIDMap", .{ .name = "Identity" } },
    }) });

    const map = try toUnicode(a, glyphs, used);
    const map_ref: Ref = try sink.add(Object{ .stream = .{
        .dict = try serial.makeDict(a, &.{.{ "Filter", .{ .name = "FlateDecode" } }}),
        .data = try pack.compress(a, map),
    } });

    try sink.set(font_ref, Object{ .dict = try serial.makeDict(a, &.{
        .{ "Type", .{ .name = "Font" } },
        .{ "Subtype", .{ .name = "Type0" } },
        .{ "BaseFont", .{ .name = name } },
        .{ "Encoding", .{ .name = "Identity-H" } },
        .{ "DescendantFonts", .{ .array = try a.dupe(Object, &.{.{ .ref = descendant }}) } },
        .{ "ToUnicode", .{ .ref = map_ref } },
    }) });
}

/// The CMap that gives each code its text (9.10.3).
fn toUnicode(a: Allocator, glyphs: []const u16, used: *const Usage) Allocator.Error![]const u8 {
    var entries: std.ArrayList(u8) = .empty;
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a,
        \\/CIDInit /ProcSet findresource begin 12 dict begin begincmap
        \\/CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def
        \\/CMapName /Adobe-Identity-UCS def /CMapType 2 def
        \\1 begincodespacerange <0000> <FFFF> endcodespacerange
        \\
    );
    var count: usize = 0;
    for (glyphs, 0..) |glyph, i| {
        const text = used.get(glyph).?;
        if (text.len > 0) {
            try entries.print(a, "<{X:0>4}> <", .{glyph});
            var view = std.unicode.Utf8View.initUnchecked(text);
            var it = view.iterator();
            while (it.nextCodepoint()) |c| {
                if (c < 0x10000) {
                    try entries.print(a, "{X:0>4}", .{c});
                } else {
                    // A surrogate pair of UTF-16.
                    const v = c - 0x10000;
                    try entries.print(a, "{X:0>4}{X:0>4}", .{ 0xD800 + (v >> 10), 0xDC00 + (v & 0x3FF) });
                }
            }
            try entries.appendSlice(a, ">\n");
            count += 1;
        }
        // A block holds at most 100 entries.
        if (count == 100 or (i + 1 == glyphs.len and count > 0)) {
            try out.print(a, "{d} beginbfchar\n{s}endbfchar\n", .{ count, entries.items });
            entries.clearRetainingCapacity();
            count = 0;
        }
    }
    try out.appendSlice(a, "endcmap CMapName currentdict /CMap defineresource pop end end\n");
    return out.items;
}

// Tests live in draw_tests.zig.
