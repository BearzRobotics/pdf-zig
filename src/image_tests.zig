//! Image decoding on hand-built images.

const std = @import("std");
const pdf = @import("root.zig");
const it = @import("interp_tests.zig");
const testing = std.testing;
const Allocator = std.mem.Allocator;

/// A page that draws image object 5 (and 6, 7 as extra objects) and the pixels of
/// the first image command decoded.
fn imageBody(a: Allocator, dict: []const u8, data: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "<< /Type /XObject /Subtype /Image {s} /Length {d} >>\nstream\n{s}\nendstream", .{ dict, data.len, data });
}

fn decodeFirst(a: Allocator, objs: []const []const u8, fill: []const u8) !pdf.image.Pixels {
    const bytes = try it.page(a, try std.fmt.allocPrint(a, "{s} q 10 0 0 10 0 0 cm /Im0 Do Q", .{fill}), "/XObject << /Im0 5 0 R >>", objs, "");
    const r = try it.render(bytes);
    defer it.done(r);
    for (r.list.commands) |c| if (c == .image) {
        const res = try pdf.image.decode(&r.doc, a, c.image);
        switch (res) {
            .pixels => |p| return .{ .width = p.width, .height = p.height, .rgba = try a.dupe(u8, p.rgba) },
            .codec => return error.TestUnexpectedResult,
        }
    };
    return error.TestUnexpectedResult;
}

test "RGB 8 bit" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const px = try decodeFirst(a, &.{try imageBody(a, "/Width 2 /Height 1 /ColorSpace /DeviceRGB /BitsPerComponent 8", "\xff\x00\x00\x00\x00\xff")}, "");
    try testing.expectEqual(@as(u32, 2), px.width);
    try testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255, 0, 0, 255, 255 }, px.rgba);
}

test "gray: 1 bit with /Decode inverted, and 16 bit" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // 4 pixels in one byte: 1 0 1 0 ; with Decode [1 0], 1 is black.
    const px = try decodeFirst(a, &.{try imageBody(a, "/Width 4 /Height 1 /ColorSpace /DeviceGray /BitsPerComponent 1 /Decode [1 0]", "\xa0")}, "");
    try testing.expectEqual(@as(u8, 0), px.rgba[0]);
    try testing.expectEqual(@as(u8, 255), px.rgba[4]);
    const p16 = try decodeFirst(a, &.{try imageBody(a, "/Width 2 /Height 1 /ColorSpace /DeviceGray /BitsPerComponent 16", "\xff\xff\x80\x00")}, "");
    try testing.expectEqual(@as(u8, 255), p16.rgba[0]);
    try testing.expect(p16.rgba[4] >= 127 and p16.rgba[4] <= 129);
}

test "Indexed 4 bit, and an index past the palette" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const px = try decodeFirst(a, &.{try imageBody(a, "/Width 3 /Height 1 /ColorSpace [/Indexed /DeviceRGB 1 <FF0000 0000FF>] /BitsPerComponent 4", "\x01\x50")}, "");
    // Nibbles 0, 1, 5: red, blue, and index 5 (past hival 1) uses the last entry, blue.
    try testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, px.rgba[0..4]);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255 }, px.rgba[4..8]);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255 }, px.rgba[8..12]);
}

test "CMYK 8 bit" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const px = try decodeFirst(a, &.{try imageBody(a, "/Width 2 /Height 1 /ColorSpace /DeviceCMYK /BitsPerComponent 8", "\x00\x00\x00\x00\x00\x00\x00\xff")}, "");
    try testing.expectEqual(@as(u8, 255), px.rgba[0]); // no ink: paper
    try testing.expect(px.rgba[4] < 60); // pure black ink
}

test "stencil masks paint in the fill colour" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // 1 0 1 0: 0 bits are painted.
    const px = try decodeFirst(a, &.{try imageBody(a, "/Width 4 /Height 1 /ImageMask true", "\xa0")}, "1 0 0 rg");
    try testing.expectEqualSlices(u8, &.{ 255, 0, 0, 0 }, px.rgba[0..4]); // 1: not painted
    try testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, px.rgba[4..8]); // 0: painted red
    const inv = try decodeFirst(a, &.{try imageBody(a, "/Width 4 /Height 1 /ImageMask true /Decode [1 0]", "\xa0")}, "0 0 1 rg");
    try testing.expectEqual(@as(u8, 255), inv.rgba[3]); // 1 is painted with Decode [1 0]
    try testing.expectEqual(@as(u8, 255), inv.rgba[2]);
}

test "colour key masking" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const px = try decodeFirst(a, &.{try imageBody(a, "/Width 2 /Height 1 /ColorSpace /DeviceGray /BitsPerComponent 8 /Mask [0 10]", "\x05\x80")}, "");
    try testing.expectEqual(@as(u8, 0), px.rgba[3]); // 5 is within 0..10: transparent
    try testing.expectEqual(@as(u8, 255), px.rgba[7]);
}

test "soft mask of another size gives an enlarged image" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const px = try decodeFirst(a, &.{
        try imageBody(a, "/Width 1 /Height 1 /ColorSpace /DeviceRGB /BitsPerComponent 8 /SMask 6 0 R", "\x10\x20\x30"),
        try imageBody(a, "/Width 2 /Height 2 /ColorSpace /DeviceGray /BitsPerComponent 8", "\x00\x40\x80\xff"),
    }, "");
    try testing.expectEqual(@as(u32, 2), px.width);
    try testing.expectEqual(@as(u32, 2), px.height);
    try testing.expectEqualSlices(u8, &.{ 0x10, 0x20, 0x30 }, px.rgba[0..3]);
    try testing.expectEqual(@as(u8, 0), px.rgba[3]);
    try testing.expectEqual(@as(u8, 0x40), px.rgba[7]);
    try testing.expectEqual(@as(u8, 0xff), px.rgba[15]);
}

test "Separation with a tint transform" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Tint 0 is white, tint 1 is red (C0 [1 1 1] to C1 [1 0 0]).
    const px = try decodeFirst(a, &.{try imageBody(a, "/Width 2 /Height 1 /BitsPerComponent 8 /ColorSpace [/Separation /Spot /DeviceRGB << /FunctionType 2 /Domain [0 1] /C0 [1 1 1] /C1 [1 0 0] /N 1 >>]", "\x00\xff")}, "");
    try testing.expectEqualSlices(u8, &.{ 255, 255, 255 }, px.rgba[0..3]);
    try testing.expectEqualSlices(u8, &.{ 255, 0, 0 }, px.rgba[4..7]);
}

test "filters are applied; JPEG data is handed to the caller" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const px = try decodeFirst(a, &.{try imageBody(a, "/Width 2 /Height 1 /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /ASCIIHexDecode", "00ff>")}, "");
    try testing.expectEqual(@as(u8, 0), px.rgba[0]);
    try testing.expectEqual(@as(u8, 255), px.rgba[4]);

    const bytes = try it.page(a, "q 10 0 0 10 0 0 cm /Im0 Do Q", "/XObject << /Im0 5 0 R >>", &.{try imageBody(a, "/Width 2 /Height 2 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode", "\xff\xd8JPEGDATA")}, "");
    const r = try it.render(bytes);
    defer it.done(r);
    for (r.list.commands) |c| if (c == .image) {
        const res = try pdf.image.decode(&r.doc, a, c.image);
        try testing.expectEqualStrings("DCTDecode", res.codec.name);
        try testing.expectEqualStrings("\xff\xd8JPEGDATA", res.codec.data);
        // The caller decoded 2x2 RGB samples: apply the colour space.
        const px2 = try pdf.image.fromSamples(&r.doc, a, c.image, &[_]u8{ 255, 0, 0, 255, 0, 0, 255, 0, 0, 255, 0, 0 }, 2, 2, 3);
        try testing.expectEqual(@as(u8, 255), px2.rgba[0]);
        try testing.expectEqual(@as(u8, 255), px2.rgba[3]);
    };
}

test "short data and absurd sizes are handled" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Data for one pixel of a 3x3 image: the rest is black, not a crash.
    const px = try decodeFirst(a, &.{try imageBody(a, "/Width 3 /Height 3 /ColorSpace /DeviceRGB /BitsPerComponent 8", "\xff\xff\xff")}, "");
    try testing.expectEqual(@as(usize, 36), px.rgba.len);
    try testing.expectEqual(@as(u8, 255), px.rgba[0]);
    try testing.expectEqual(@as(u8, 0), px.rgba[8]);
    // Too many pixels.
    const bytes = try it.page(a, "q 10 0 0 10 0 0 cm /Im0 Do Q", "/XObject << /Im0 5 0 R >>", &.{try imageBody(a, "/Width 100000 /Height 100000 /ColorSpace /DeviceGray /BitsPerComponent 8", "x")}, "");
    const r = try it.render(bytes);
    defer it.done(r);
    for (r.list.commands) |c| if (c == .image) try testing.expectError(error.TooBig, pdf.image.decode(&r.doc, a, c.image));
}

test "inline images stay valid after other pages are rendered (the scratch arena is reused)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Page 1: an indexed inline image whose palette string lives in the operands.
    // Page 2: lots of text and operands that overwrite the scratch memory page 1 used.
    const c1 = "q 10 0 0 10 0 0 cm BI /W 2 /H 1 /BPC 8 /CS [/I /RGB 1 <FF00000000FF>] ID \x00\x01\nEI Q";
    var c2: std.ArrayList(u8) = .empty;
    for (0..400) |_| try c2.appendSlice(a, "(ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ) [(YYYYYYYYYYYYYYYYYYYYYYYYY)] 1 2 3 4 5 6 cm ");
    const bodies = [_][]const u8{
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R 5 0 R] /Count 2 >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 20 20] /Contents 4 0 R >>",
        try std.fmt.allocPrint(a, "<< /Length {d} >>\nstream\n{s}\nendstream", .{ c1.len, c1 }),
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 20 20] /Contents 6 0 R >>",
        try std.fmt.allocPrint(a, "<< /Length {d} >>\nstream\n{s}\nendstream", .{ c2.items.len, c2.items }),
    };
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, "%PDF-1.7\n");
    var offs: [bodies.len]usize = undefined;
    for (bodies, 0..) |b, i| {
        offs[i] = out.items.len;
        try out.print(a, "{d} 0 obj\n{s}\nendobj\n", .{ i + 1, b });
    }
    const xref_at = out.items.len;
    try out.print(a, "xref\n0 {d}\n0000000000 65535 f \n", .{bodies.len + 1});
    for (offs) |o| try out.print(a, "{d:0>10} 00000 n \n", .{o});
    try out.print(a, "trailer\n<< /Size {d} /Root 1 0 R >>\nstartxref\n{d}\n%%EOF\n", .{ bodies.len + 1, xref_at });

    var doc = try pdf.Document.open(testing.allocator, out.items, .{});
    defer doc.deinit();
    var rend = pdf.Renderer.init(&doc, .{});
    defer rend.deinit();
    const pl = try pdf.pages.PageList.build(&doc);
    var l1 = try rend.render(testing.allocator, pdf.pages.page(&doc, pl, 0).?);
    defer l1.deinit();
    var l2 = try rend.render(testing.allocator, pdf.pages.page(&doc, pl, 1).?);
    defer l2.deinit();
    for (l1.commands) |c| if (c == .image) {
        const px = (try pdf.image.decode(&doc, a, c.image)).pixels;
        try testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255, 0, 0, 255, 255 }, px.rgba);
    };
}

test "CCITT G3 1D, G3 2D and G4 match the bitmap Ghostscript rendered" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ref = @embedFile("fax_ref.pbm");
    const w: usize = 1728;
    const h: usize = 300;
    const row = (w + 7) / 8;
    const bits = ref[ref.len - row * h ..]; // raw PBM: 1 = black
    for ([_][]const u8{ @embedFile("fax_g3_1d.pdf"), @embedFile("fax_g3_2d.pdf"), @embedFile("fax_g4.pdf") }) |bytes| {
        var doc = try pdf.Document.open(a, bytes, .{});
        const list = try pdf.pages.PageList.build(&doc);
        var rend = pdf.Renderer.init(&doc, .{});
        var dl = try rend.render(a, pdf.pages.page(&doc, list, 0).?);
        var seen = false;
        for (dl.commands) |c| if (c == .image) {
            const res = try pdf.image.decode(&doc, a, c.image);
            const p = res.pixels;
            try testing.expectEqual(w, p.width);
            try testing.expectEqual(h, p.height);
            var bad: usize = 0;
            for (0..h) |y| for (0..w) |x| {
                const black = (bits[y * row + x / 8] >> @intCast(7 - x % 8)) & 1 == 1;
                if ((p.rgba[(y * w + x) * 4] < 128) != black) bad += 1;
            };
            try testing.expectEqual(@as(usize, 0), bad);
            seen = true;
        };
        try testing.expect(seen);
        rend.deinit();
        dl.deinit();
        doc.deinit();
    }
}
