// SPDX-License-Identifier: LGPL-2.0-or-later
//! Tests of the interpreter, text extraction and fonts on hand-built pages.

const std = @import("std");
const pdf = @import("root.zig");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const display = pdf.display;

/// A one-page PDF. Objects: 1 catalog, 2 pages, 3 page, 4 content stream,
/// 5 and up: `extra` bodies (referenced from `resources`).
pub fn page(a: Allocator, content: []const u8, resources: []const u8, extra: []const []const u8, page_extra: []const u8) ![]u8 {
    var bodies: std.ArrayList([]const u8) = .empty;
    try bodies.append(a, "<< /Type /Catalog /Pages 2 0 R >>");
    try bodies.append(a, "<< /Type /Pages /Kids [3 0 R] /Count 1 >>");
    try bodies.append(a, try std.fmt.allocPrint(a, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 100] /Contents 4 0 R /Resources << {s} >> {s} >>", .{ resources, page_extra }));
    try bodies.append(a, try std.fmt.allocPrint(a, "<< /Length {d} >>\nstream\n{s}\nendstream", .{ content.len, content }));
    for (extra) |e| try bodies.append(a, e);
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, "%PDF-1.7\n");
    const offsets = try a.alloc(usize, bodies.items.len);
    for (bodies.items, 0..) |b, i| {
        offsets[i] = out.items.len;
        try out.print(a, "{d} 0 obj\n{s}\nendobj\n", .{ i + 1, b });
    }
    const xref_at = out.items.len;
    try out.print(a, "xref\n0 {d}\n0000000000 65535 f \n", .{bodies.items.len + 1});
    for (offsets) |o| try out.print(a, "{d:0>10} 00000 n \n", .{o});
    try out.print(a, "trailer\n<< /Size {d} /Root 1 0 R >>\nstartxref\n{d}\n%%EOF\n", .{ bodies.items.len + 1, xref_at });
    return out.items;
}

/// Checks that the cross-reference data of a written file is right by itself:
/// every in-use entry points at the header `N G obj` of its object, and loading
/// all of them needs no repair. (Reading alone would hide a wrong offset: the
/// library repairs the file on first use of the bad entry.)
pub fn expectSoundFile(bytes: []const u8) !void {
    var doc = try pdf.Document.open(testing.allocator, bytes, .{});
    defer doc.deinit();
    var it = doc.xref.iterator();
    while (it.next()) |kv| switch (kv.value_ptr.*) {
        .free => {},
        .in_use => |e| {
            var buf: [48]u8 = undefined;
            const header = try std.fmt.bufPrint(&buf, "{d} {d} obj", .{ kv.key_ptr.*, e.gen });
            const at = doc.base + @as(usize, @intCast(e.offset));
            try testing.expect(at < bytes.len);
            try testing.expectEqualStrings(header, bytes[at..@min(bytes.len, at + header.len)]);
        },
        .compressed => {},
    };
    var nums = doc.xref.keyIterator();
    var list: std.ArrayList(u32) = .empty;
    defer list.deinit(testing.allocator);
    while (nums.next()) |k| try list.append(testing.allocator, k.*);
    try expectRefs(&doc, .{ .dict = doc.trailer });
    for (list.items) |n| try expectRefs(&doc, doc.getObject(n));
    try testing.expect(!doc.repaired);
}

/// Every reference to an object in use carries that object's generation; with
/// any other generation it means null to a conforming reader (7.3.10).
fn expectRefs(doc: *pdf.Document, o: pdf.Object) !void {
    switch (o) {
        .ref => |r| if (doc.xref.get(r.num)) |e| switch (e) {
            .free => {},
            .in_use => |u| try testing.expectEqual(u.gen, r.gen),
            .compressed => try testing.expectEqual(@as(u16, 0), r.gen),
        },
        .array => |arr| for (arr) |item| try expectRefs(doc, item),
        .dict => |d| for (d.entries) |e| try expectRefs(doc, e.value),
        .stream => |s| try expectRefs(doc, .{ .dict = s.dict }),
        else => {},
    }
}

/// A file from object bodies (objects 1, 2, ...; object 1 is the catalog).
pub fn buildFile(a: Allocator, bodies: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, "%PDF-1.7\n");
    const offsets = try a.alloc(usize, bodies.len);
    for (bodies, 0..) |b, i| {
        offsets[i] = out.items.len;
        try out.print(a, "{d} 0 obj\n{s}\nendobj\n", .{ i + 1, b });
    }
    const xref_at = out.items.len;
    try out.print(a, "xref\n0 {d}\n0000000000 65535 f \n", .{bodies.len + 1});
    for (offsets) |o| try out.print(a, "{d:0>10} 00000 n \n", .{o});
    try out.print(a, "trailer\n<< /Size {d} /Root 1 0 R >>\nstartxref\n{d}\n%%EOF\n", .{ bodies.len + 1, xref_at });
    return out.items;
}

pub const Rendered = struct {
    doc: pdf.Document,
    rend: pdf.Renderer,
    list: display.DisplayList,

    fn deinit(self: *Rendered) void {
        self.list.deinit();
        self.rend.deinit();
        self.doc.deinit();
    }
};

pub fn render(bytes: []const u8) !*Rendered {
    const r = try testing.allocator.create(Rendered);
    errdefer testing.allocator.destroy(r);
    r.doc = try pdf.Document.open(testing.allocator, bytes, .{});
    errdefer r.doc.deinit();
    r.rend = pdf.Renderer.init(&r.doc, .{});
    errdefer r.rend.deinit();
    const pl = try pdf.pages.PageList.build(&r.doc);
    const p = pdf.pages.page(&r.doc, pl, 0).?;
    r.list = try r.rend.render(testing.allocator, p);
    return r;
}

pub fn done(r: *Rendered) void {
    r.deinit();
    testing.allocator.destroy(r);
}

fn countKind(list: display.DisplayList, comptime tag: std.meta.Tag(display.Command)) usize {
    var n: usize = 0;
    for (list.commands) |c| if (c == tag) {
        n += 1;
    };
    return n;
}

const helv = "/Font << /F1 5 0 R >>";
const helv_obj = "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>";

test "a filled rectangle, colour and the page matrix" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = try render(try page(arena.allocator(), "1 0 0 rg 10 20 100 50 re f", "", &.{}, ""));
    defer done(r);
    try testing.expectEqual(@as(usize, 1), countKind(r.list, .fill));
    const f = r.list.commands[0].fill;
    try testing.expectEqual(@as(usize, 5), f.path.len);
    try testing.expectEqual(@as(f32, 1), f.paint.color.r);
    try testing.expectEqual(@as(f32, 0), f.paint.color.g);
    try testing.expectEqual(display.FillRule.nonzero, f.rule);
    try testing.expectEqual(@as(f64, 200), r.list.width);
    // User space (10, 20) lands at (10, 80) on the page (y down, height 100).
    const p = r.list.base.apply(10, 20);
    try testing.expectEqual(@as(f64, 10), p.x);
    try testing.expectEqual(@as(f64, 80), p.y);
}

test "cm, q and Q" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = try render(try page(arena.allocator(), "q 2 0 0 2 5 5 cm 0 0 1 1 re f Q 0 0 1 1 re f", "", &.{}, ""));
    defer done(r);
    var ctms: [2]display.Matrix = undefined;
    var n: usize = 0;
    for (r.list.commands) |c| if (c == .fill) {
        ctms[n] = c.fill.ctm;
        n += 1;
    };
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqual(@as(f64, 2), ctms[0].a);
    try testing.expectEqual(@as(f64, 5), ctms[0].e);
    try testing.expectEqual(@as(f64, 1), ctms[1].a);
    try testing.expectEqual(@as(usize, 1), countKind(r.list, .save));
    try testing.expectEqual(@as(usize, 1), countKind(r.list, .restore));
}

test "stroke style, dash and the clip operators" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = try render(try page(arena.allocator(), "3 w 1 J 2 j [4 2] 1 d 0 0 m 10 10 l S 0 0 10 10 re W n 5 5 20 20 re f*", "", &.{}, ""));
    defer done(r);
    const s = r.list.commands[0].stroke;
    try testing.expectEqual(@as(f64, 3), s.style.width);
    try testing.expectEqual(display.Cap.round, s.style.cap);
    try testing.expectEqual(display.Join.bevel, s.style.join);
    try testing.expectEqual(@as(usize, 2), s.style.dash.len);
    try testing.expectEqual(@as(f64, 1), s.style.dash_phase);
    try testing.expect(r.list.commands[1] == .clip);
    try testing.expectEqual(display.FillRule.even_odd, r.list.commands[2].fill.rule);
}

test "colour operators: gray, CMYK, Indexed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = try render(try page(arena.allocator(),
        \\0.5 g 0 0 1 1 re f 0 0 0 1 k 0 0 1 1 re f /Pal cs 1 sc 0 0 1 1 re f
    , "/ColorSpace << /Pal [/Indexed /DeviceRGB 1 <FF0000 0000FF>] >>", &.{}, ""));
    defer done(r);
    try testing.expectEqual(@as(f32, 0.5), r.list.commands[0].fill.paint.color.r);
    try testing.expect(r.list.commands[1].fill.paint.color.r < 0.2); // 0 0 0 1 k is black (a soft one)
    try testing.expectEqual(@as(f32, 1), r.list.commands[2].fill.paint.color.b);
    try testing.expectEqual(@as(f32, 0), r.list.commands[2].fill.paint.color.r);
}

test "text: standard 14 metrics, TJ adjustments, spacing, extraction" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = try render(try page(arena.allocator(),
        \\BT /F1 10 Tf 20 80 Td (Hi) Tj [(A) -1000 (B)] TJ ET
    , helv, &.{helv_obj}, ""));
    defer done(r);
    try testing.expectEqual(@as(usize, 2), countKind(r.list, .text));
    const t1 = r.list.commands[0].text;
    try testing.expectEqual(@as(usize, 2), t1.glyphs.len);
    try testing.expectEqualStrings("H", t1.glyphs[0].text);
    try testing.expectApproxEqAbs(@as(f64, 7.22), t1.glyphs[1].x, 1e-9); // Helvetica H = 722
    const t2 = r.list.commands[1].text;
    // The second string starts after "Hi" (722 + 222) at 10 pt: 9.44.
    try testing.expectApproxEqAbs(@as(f64, 9.44), t2.tm.e - t1.tm.e, 1e-9);
    // A (667) then -1000/1000 * 10 = +10 before B.
    try testing.expectApproxEqAbs(@as(f64, 6.67 + 10), t2.glyphs[1].x, 1e-9);
    const text = try pdf.text.extract(testing.allocator, &r.list, .reading);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("HiA B\n", text);
}

test "text: Tc, Tw, Tz, TL, T*, quote operators" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = try render(try page(arena.allocator(),
        \\BT /F1 10 Tf 2 Tc 5 Tw 50 Tz 12 TL 10 90 Td (a b) Tj T* (c) Tj (d) ' ET
    , helv, &.{helv_obj}, ""));
    defer done(r);
    const t = r.list.commands[0].text;
    // 'a' = 556: (5.56 + 2) * 0.5; the space = 278: (2.78 + 2 + 5) * 0.5.
    try testing.expectApproxEqAbs(@as(f64, 3.78), t.glyphs[1].x, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 3.78 + 4.89), t.glyphs[2].x, 1e-9);
    const t2 = r.list.commands[1].text;
    try testing.expectApproxEqAbs(@as(f64, 10 - 0), t2.tm.e, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 90 - 12), t2.tm.f, 1e-9);
    const t3 = r.list.commands[2].text; // ' moves down a line first
    try testing.expectApproxEqAbs(@as(f64, 90 - 24), t3.tm.f, 1e-9);
    const text = try pdf.text.extract(testing.allocator, &r.list, .reading);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("a b\nc\nd\n", text);
}

test "text: WinAnsi, Differences and ToUnicode" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = try render(try page(arena.allocator(),
        \\BT /F1 10 Tf 10 50 Td (caf\351) Tj /F2 10 Tf 10 30 Td (\001\002) Tj ET
    , "/Font << /F1 5 0 R /F2 6 0 R >>", &.{
        "<< /Type /Font /Subtype /Type1 /BaseFont /Times-Roman /Encoding /WinAnsiEncoding >>",
        "<< /Type /Font /Subtype /Type1 /BaseFont /Foo /FirstChar 1 /LastChar 2 /Widths [500 500] /Encoding << /Type /Encoding /Differences [1 /fi /uni20AC] >> >>",
    }, ""));
    defer done(r);
    const text = try pdf.text.extract(testing.allocator, &r.list, .reading);
    defer testing.allocator.free(text);
    // `Td` is relative to the start of the previous line: the second string is
    // at y = 80, above the first (y = 50), and reading order is top to bottom.
    try testing.expectEqualStrings("fi\u{20AC}\ncafé\n", text);
}

test "text: ToUnicode wins over the encoding, composite fonts and CIDs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const tu = "/CIDInit begincmap 1 begincodespacerange <0000> <FFFF> endcodespacerange 2 beginbfchar <0001> <0058> <0002> <0059> endbfchar endcmap";
    const r = try render(try page(arena.allocator(), "BT /F1 10 Tf 10 50 Td <00010002> Tj ET", "/Font << /F1 5 0 R >>", &.{
        "<< /Type /Font /Subtype /Type0 /BaseFont /Bar /Encoding /Identity-H /DescendantFonts [6 0 R] /ToUnicode 7 0 R >>",
        "<< /Type /Font /Subtype /CIDFontType2 /BaseFont /Bar /DW 500 /W [1 [600] 2 2 700] /CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >> >>",
        try std.fmt.allocPrint(arena.allocator(), "<< /Length {d} >>\nstream\n{s}\nendstream", .{ tu.len, tu }),
    }, ""));
    defer done(r);
    const t = r.list.commands[0].text;
    try testing.expectEqual(@as(usize, 2), t.glyphs.len);
    try testing.expectEqual(@as(u32, 1), t.glyphs[0].cid);
    try testing.expectApproxEqAbs(@as(f64, 6.0), t.glyphs[1].x, 1e-9); // W: cid 1 = 600
    try testing.expectApproxEqAbs(@as(f64, 0.7), t.glyphs[1].advance, 1e-9); // cid 2 = 700 via a range
    const text = try pdf.text.extract(testing.allocator, &r.list, .reading);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("XY\n", text);
}

test "form XObjects: matrix, bounding box clip, resources, self reference" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const form = "0 0 1 rg 0 0 10 10 re f /Fm0 Do";
    const r = try render(try page(arena.allocator(), "q 1 0 0 1 100 20 cm /Fm0 Do Q", "/XObject << /Fm0 5 0 R >>", &.{
        try std.fmt.allocPrint(arena.allocator(), "<< /Type /XObject /Subtype /Form /BBox [0 0 5 5] /Matrix [2 0 0 2 0 0] /Resources << /XObject << /Fm0 5 0 R >> >> /Length {d} >>\nstream\n{s}\nendstream", .{ form.len, form }),
    }, ""));
    defer done(r);
    try testing.expectEqual(@as(usize, 1), countKind(r.list, .fill)); // the self reference is not drawn again
    for (r.list.commands) |c| if (c == .fill) {
        try testing.expectEqual(@as(f64, 2), c.fill.ctm.a);
        try testing.expectEqual(@as(f64, 100), c.fill.ctm.e);
        try testing.expectEqual(@as(f32, 1), c.fill.paint.color.b);
    };
    try testing.expectEqual(@as(usize, 1), countKind(r.list, .clip)); // the BBox
}

test "image XObjects and inline images" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = try render(try page(arena.allocator(),
        \\q 50 0 0 50 10 10 cm /Im0 Do Q q 10 0 0 10 70 10 cm BI /W 2 /H 2 /BPC 8 /CS /G ID abcd
        \\EI Q
    , "/XObject << /Im0 5 0 R >>", &.{
        "<< /Type /XObject /Subtype /Image /Width 4 /Height 3 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Length 0 >>\nstream\n\nendstream",
    }, ""));
    defer done(r);
    try testing.expectEqual(@as(usize, 2), countKind(r.list, .image));
    const im = r.list.commands[1].image;
    try testing.expectEqual(@as(u32, 4), im.width);
    try testing.expectEqual(@as(f64, 50), im.ctm.a);
    try testing.expectEqual(@as(u32, 5), im.num);
    // The second image is the inline one, which has no object number.
    const inline_image = r.list.commands[4].image;
    try testing.expectEqual(@as(u32, 0), inline_image.num);
    try testing.expectEqual(@as(u32, 2), inline_image.width);
    try testing.expectEqualStrings("abcd", inline_image.stream.data);
}

test "optional content: a hidden layer draws nothing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const bytes = blk: {
        const base = try page(arena.allocator(),
            \\/OC /L1 BDC 0 0 5 5 re f EMC 0 0 6 6 re f /OC /L2 BDC 0 0 7 7 re f EMC
        , "/Properties << /L1 5 0 R /L2 6 0 R >>", &.{ "<< /Type /OCG /Name (off) >>", "<< /Type /OCG /Name (on) >>" }, "");
        // The catalog lists layer 5 as OFF in the default configuration.
        break :blk try std.mem.replaceOwned(u8, arena.allocator(), base, "<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Catalog /Pages 2 0 R /OCProperties << /OCGs [5 0 R 6 0 R] /D << /OFF [5 0 R] >> >> >>");
    };
    const r = try render(bytes);
    defer done(r);
    try testing.expectEqual(@as(usize, 2), countKind(r.list, .fill)); // the layer-off fill is gone
}

test "annotations: appearance stream mapped onto the rectangle" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ap = "1 0 0 rg 0 0 10 10 re f";
    const r = try render(try page(arena.allocator(), "0 g", "", &.{
        try std.fmt.allocPrint(arena.allocator(), "<< /Type /Annot /Subtype /Square /Rect [100 50 120 80] /AP << /N 6 0 R >> >>", .{}),
        try std.fmt.allocPrint(arena.allocator(), "<< /Type /XObject /Subtype /Form /BBox [0 0 10 10] /Length {d} >>\nstream\n{s}\nendstream", .{ ap.len, ap }),
    }, "/Annots [5 0 R]"));
    defer done(r);
    try testing.expectEqual(@as(usize, 1), countKind(r.list, .fill));
    const f = r.list.commands[2].fill; // save, clip(BBox), fill
    // BBox 10x10 onto a 20x30 rectangle at (100, 50).
    try testing.expectEqual(@as(f64, 2), f.ctm.a);
    try testing.expectEqual(@as(f64, 3), f.ctm.d);
    try testing.expectEqual(@as(f64, 100), f.ctm.e);
    try testing.expectEqual(@as(f64, 50), f.ctm.f);
}

test "Type 3 fonts: glyph procedures are drawn and the text stays extractable" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const proc = "500 0 0 0 400 700 d1 0 0 400 700 re f";
    const r = try render(try page(arena.allocator(), "BT /F1 10 Tf 10 50 Td (a) Tj ET", "/Font << /F1 5 0 R >>", &.{
        "<< /Type /Font /Subtype /Type3 /FontBBox [0 0 500 700] /FontMatrix [0.001 0 0 0.001 0 0] /CharProcs << /ga 6 0 R >> /Encoding << /Type /Encoding /Differences [97 /ga] >> /FirstChar 97 /LastChar 97 /Widths [500] /ToUnicode 7 0 R >>",
        try std.fmt.allocPrint(arena.allocator(), "<< /Length {d} >>\nstream\n{s}\nendstream", .{ proc.len, proc }),
        "<< /Length 80 >>\nstream\n1 begincodespacerange <00> <FF> endcodespacerange 1 beginbfchar <61> <0041> endbfchar\nendstream",
    }, ""));
    defer done(r);
    try testing.expectEqual(@as(usize, 1), countKind(r.list, .fill));
    const f = blk: {
        for (r.list.commands) |c| if (c == .fill) break :blk c.fill;
        return error.TestUnexpectedResult;
    };
    // Glyph space 1000 units per em at 10 pt: scale 0.01, origin at (10, 50).
    try testing.expectApproxEqAbs(@as(f64, 0.01), f.ctm.a, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 10), f.ctm.e, 1e-9);
    const text = try pdf.text.extract(testing.allocator, &r.list, .reading);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("A\n", text);
    for (r.list.commands) |c| if (c == .text) try testing.expectEqual(@as(u8, 3), c.text.mode);
}

test "axial shading becomes colour stops" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = try render(try page(arena.allocator(), "/Sh0 sh", "/Shading << /Sh0 5 0 R >>", &.{
        "<< /ShadingType 2 /ColorSpace /DeviceRGB /Coords [0 0 100 0] /Extend [true false] /Function << /FunctionType 2 /Domain [0 1] /C0 [1 0 0] /C1 [0 0 1] /N 1 >> >>",
    }, ""));
    defer done(r);
    const sh = r.list.commands[0].shading.shading;
    try testing.expectEqual(display.ShadingKind.axial, sh.kind);
    try testing.expect(sh.extend_start and !sh.extend_end);
    try testing.expectEqual(@as(f32, 1), sh.stops[0].color.r);
    try testing.expectEqual(@as(f32, 1), sh.stops[sh.stops.len - 1].color.b);
    try testing.expect(sh.stops[sh.stops.len / 2].color.r > 0.3 and sh.stops[sh.stops.len / 2].color.r < 0.7);
}

test "page rotation and crop box in the base matrix" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = try render(try page(arena.allocator(), "0 0 1 1 re f", "", &.{}, "/Rotate 90 /CropBox [10 10 110 60]"));
    defer done(r);
    try testing.expectEqual(@as(f64, 50), r.list.width); // 100 x 50 crop, rotated: 50 wide, 100 high
    try testing.expectEqual(@as(f64, 100), r.list.height);
    // The crop box's bottom-left corner is the top-left of a page turned clockwise.
    const p = r.list.base.apply(10, 10);
    try testing.expectEqual(@as(f64, 0), p.x);
    try testing.expectEqual(@as(f64, 0), p.y);
    // Its top-left corner (10, 60) goes to the top right.
    const q = r.list.base.apply(10, 60);
    try testing.expectEqual(@as(f64, 50), q.x);
    try testing.expectEqual(@as(f64, 0), q.y);
}

test "limits: too many operators stops the page" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const bytes = try page(arena.allocator(), "0 0 1 1 re f 0 0 1 1 re f 0 0 1 1 re f 0 0 1 1 re f", "", &.{}, "");
    var doc = try pdf.Document.open(testing.allocator, bytes, .{});
    defer doc.deinit();
    var rend = pdf.Renderer.init(&doc, .{ .max_ops = 5 });
    defer rend.deinit();
    const pl = try pdf.pages.PageList.build(&doc);
    try testing.expectError(error.LimitExceeded, rend.render(testing.allocator, pdf.pages.page(&doc, pl, 0).?));
}

test "damaged content streams never crash (seeded mutation)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const good = "q 1 0 0 1 5 5 cm 0.5 g 0 0 50 50 re f Q BT /F1 12 Tf 10 10 Td [(Hel) -20 (lo)] TJ ET /Fm0 Do /Im0 Do 1 0 0 RG 2 w 0 0 m 10 10 20 20 30 0 c S";
    var prng = std.Random.DefaultPrng.init(0xbeef);
    const rnd = prng.random();
    for (0..300) |_| {
        const copy = try a.dupe(u8, good);
        for (0..rnd.intRangeAtMost(usize, 1, 6)) |_| copy[rnd.uintLessThan(usize, copy.len)] = rnd.int(u8);
        const bytes = try page(a, copy, helv ++ " /XObject << /Fm0 6 0 R >>", &.{ helv_obj, "<< /Type /XObject /Subtype /Form /BBox [0 0 10 10] /Length 3 >>\nstream\n0 g\nendstream" }, "");
        var doc = pdf.Document.open(testing.allocator, bytes, .{}) catch continue;
        defer doc.deinit();
        var rend = pdf.Renderer.init(&doc, .{});
        defer rend.deinit();
        const pl = pdf.pages.PageList.build(&doc) catch continue;
        const p = pdf.pages.page(&doc, pl, 0) orelse continue;
        var dl = rend.render(testing.allocator, p) catch continue;
        dl.deinit();
    }
}

test "graphics off: only text is produced" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const bytes = try page(arena.allocator(), "0 0 50 50 re f BT /F1 10 Tf 10 10 Td (ok) Tj ET 0 0 m 5 5 l S", helv, &.{helv_obj}, "");
    var doc = try pdf.Document.open(testing.allocator, bytes, .{});
    defer doc.deinit();
    var rend = pdf.Renderer.init(&doc, .{ .graphics = false });
    defer rend.deinit();
    const pl = try pdf.pages.PageList.build(&doc);
    var dl = try rend.render(testing.allocator, pdf.pages.page(&doc, pl, 0).?);
    defer dl.deinit();
    try testing.expectEqual(@as(usize, 1), dl.commands.len);
    try testing.expect(dl.commands[0] == .text);
    const text = try pdf.text.extract(testing.allocator, &dl, .reading);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("ok\n", text);
}

test "huge, infinite and negative operands of J, j and Tr" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const nines: [400]u8 = @splat('9'); // parses as infinity
    const huge: []const u8 = &nines;
    for ([_][]const u8{ "99999999999999999999", "-99999999999999999999", huge, try std.mem.concat(a, u8, &.{ "-", huge }) }) |v| {
        const stream = try std.fmt.allocPrint(a, "{s} J {s} j {s} Tr 0 0 m 1 1 l S BT /F1 10 Tf (A) Tj ET", .{ v, v, v });
        const r = try render(try page(a, stream, helv, &.{helv_obj}, ""));
        defer done(r);
        try testing.expectEqual(display.Cap.butt, r.list.commands[0].stroke.style.cap);
        try testing.expectEqual(display.Join.miter, r.list.commands[0].stroke.style.join);
        try testing.expectEqual(@as(u8, if (v[0] == '-') 0 else 7), r.list.commands[1].text.mode);
    }
    // Ordinary values, including fractions, still select what they did.
    const r = try render(try page(a, "1 J 2.9 j 0 0 m 1 1 l S", "", &.{}, ""));
    defer done(r);
    try testing.expectEqual(display.Cap.round, r.list.commands[0].stroke.style.cap);
    try testing.expectEqual(display.Join.bevel, r.list.commands[0].stroke.style.join);
}

/// Renders the first page of `bytes` and returns how many bytes were requested
/// from the allocators (the document's and the list's) while doing it.
fn renderCost(bytes: []const u8, options: pdf.interp.Options) !usize {
    var counting = std.testing.FailingAllocator.init(testing.allocator, .{});
    var doc = try pdf.Document.open(counting.allocator(), bytes, .{});
    defer doc.deinit();
    const pl = try pdf.pages.PageList.build(&doc);
    const before = counting.allocated_bytes;
    var rend = pdf.Renderer.init(&doc, options);
    defer rend.deinit();
    var dl = try rend.render(counting.allocator(), pdf.pages.page(&doc, pl, 0).?);
    dl.deinit();
    return counting.allocated_bytes - before;
}

test "a form or Type 3 glyph used many times is decoded once and counted every time" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // 100,000 spaces, hex encoded: no operators, so only a byte budget can count it.
    const hex = try a.alloc(u8, 200_000);
    for (hex, 0..) |*c, i| c.* = if (i % 2 == 0) '2' else '0';
    const form = try std.fmt.allocPrint(a, "<< /Subtype /Form /BBox [0 0 1 1] /Filter /ASCIIHexDecode /Length {d} >>\nstream\n{s}>\nendstream", .{ hex.len + 1, hex });
    const uses = 500;
    const dos = try std.mem.join(a, " ", &(@as([uses][]const u8, @splat("/F Do"))));
    const forms = try page(a, dos, "/XObject << /F 5 0 R >>", &.{form}, "");

    const glyphs: [uses]u8 = @splat('a');
    const type3 = try page(a, try std.fmt.allocPrint(a, "BT /F1 10 Tf ({s}) Tj ET", .{&glyphs}), "/Font << /F1 5 0 R >>", &.{
        "<< /Type /Font /Subtype /Type3 /FontBBox [0 0 500 700] /FontMatrix [0.001 0 0 0.001 0 0] /CharProcs << /ga 6 0 R >> /Encoding << /Differences [97 /ga] >> /FirstChar 97 /Widths [500] >>",
        form,
    }, "");

    for ([_][]const u8{ forms, type3 }) |bytes| {
        // 500 uses of 100 KB would be 50 MB if each use decoded again.
        try testing.expect(try renderCost(bytes, .{}) < 8 << 20);
        // And the page's content budget counts each use.
        try testing.expectError(error.LimitExceeded, renderCost(bytes, .{ .max_content_bytes = 1 << 20 }));
    }
}

test "font dictionary numbers outside their ranges never crash" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cid = "<< /Type /Font /Subtype /Type0 /BaseFont /X /Encoding /Identity-H /DescendantFonts [<< /Subtype /CIDFontType2 /W ";
    for ([_][]const u8{
        "<< /Type /Font /Subtype /Type1 /BaseFont /X /FontDescriptor << /Flags 4294967296 >> >>",
        "<< /Type /Font /Subtype /Type1 /BaseFont /X /FontDescriptor << /Flags -9223372036854775807 >> >>",
        "<< /Type /Font /Subtype /Type1 /BaseFont /X /FirstChar 4294967296 /Widths [500] >>",
        cid ++ "[4294967296 [500]] >>] >>",
        cid ++ "[4294967296 4294967297 500] >>] >>",
        cid ++ "[0 4294967296 500] >>] >>",
        cid ++ "[9223372036854775807 [500 500]] >>] >>",
        cid ++ "[4294967295 [500 500]] >>] >>",
    }) |font| {
        const r = try render(try page(a, "BT /F1 10 Tf (AB) Tj ET", helv, &.{font}, ""));
        done(r);
    }
    // /Flags written as a signed 32-bit number keeps its bits (4: symbolic).
    const r = try render(try page(a, "BT /F1 10 Tf (A) Tj ET", helv, &.{"<< /Type /Font /Subtype /Type1 /BaseFont /X /FontDescriptor << /Flags -2147483644 >> >>"}, ""));
    defer done(r);
    try testing.expect(r.list.commands[0].text.font.isSymbolic());
}

test "a Lab /Range with minimum above maximum falls back to the default" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const huge: [400]u8 = @splat('9');
    for ([_][]const u8{
        "[100 -100 -100 100]",
        "[-100 100 100 -100]",
        try std.fmt.allocPrint(arena.allocator(), "[{s} 100 -100 100]", .{&huge}),
    }) |range| {
        const cs = try std.fmt.allocPrint(arena.allocator(), "/ColorSpace << /CS0 [/Lab << /WhitePoint [0.9642 1 0.8249] /Range {s} >>] >>", .{range});
        const r = try render(try page(arena.allocator(), "/CS0 cs 100 0 0 sc 0 0 10 10 re f", cs, &.{}, ""));
        defer done(r);
        // L* 100 with no chroma is white.
        const c = r.list.commands[0].fill.paint.color;
        try testing.expect(c.r > 0.9 and c.g > 0.9);
    }
}

test "an extra Q in a form cannot pop the caller's graphics state" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const body = "Q Q 0 1 0 rg 0 0 5 5 re f";
    const form = try std.fmt.allocPrint(a, "<< /Subtype /Form /BBox [0 0 10 10] /Matrix [1 0 0 1 70 0] /Length {d} >>\nstream\n{s}\nendstream", .{ body.len, body });
    const r = try render(try page(a, "q 1 0 0 rg 0 0 50 50 re W n /Fm Do 0 0 100 100 re f Q", "/XObject << /Fm 5 0 R >>", &.{form}, ""));
    defer done(r);
    // save, page clip, save, form clip, form fill, restore, page fill, restore
    const want = [_]std.meta.Tag(display.Command){ .save, .clip, .save, .clip, .fill, .restore, .fill, .restore };
    try testing.expectEqual(want.len, r.list.commands.len);
    for (want, r.list.commands) |w, c| try testing.expectEqual(w, std.meta.activeTag(c));
    try testing.expectEqual(@as(f64, 70), r.list.commands[4].fill.ctm.e);
    try testing.expectEqual(@as(f32, 1), r.list.commands[6].fill.paint.color.r);
    try testing.expectEqual(@as(f64, 0), r.list.commands[6].fill.ctm.e);
}

test "Type 3: every glyph of a run is placed by its own offset" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const proc = "500 0 d0 0 0 400 700 re f";
    // Size 10, horizontal scale 50%, rise 3, with a TJ adjustment.
    const r = try render(try page(arena.allocator(), "BT /F1 10 Tf 50 Tz 3 Ts 10 50 Td [(aa) -1000 (a)] TJ ET", "/Font << /F1 5 0 R >>", &.{
        "<< /Type /Font /Subtype /Type3 /FontBBox [0 0 500 700] /FontMatrix [0.001 0 0 0.001 0 0] /CharProcs << /ga 6 0 R >> /Encoding << /Differences [97 /ga] >> /FirstChar 97 /Widths [500] >>",
        try std.fmt.allocPrint(arena.allocator(), "<< /Length {d} >>\nstream\n{s}\nendstream", .{ proc.len, proc }),
    }, ""));
    defer done(r);
    // Advance: 0.5 em * 10 * 0.5 = 2.5; the adjustment adds 1 em * 10 * 0.5 = 5.
    const want = [_]f64{ 10, 12.5, 20 };
    var n: usize = 0;
    for (r.list.commands) |c| if (c == .fill) {
        try testing.expectApproxEqAbs(want[n], c.fill.ctm.e, 1e-9);
        try testing.expectApproxEqAbs(@as(f64, 53), c.fill.ctm.f, 1e-9);
        try testing.expectApproxEqAbs(@as(f64, 0.005), c.fill.ctm.a, 1e-12);
        n += 1;
    };
    try testing.expectEqual(want.len, n);
}

test "the renderer keeps nothing of the allocator a page was rendered with" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fills: [200][]const u8 = @splat("0 0 1 1 re f");
    const bytes = try page(a, try std.mem.join(a, " ", &fills), "", &.{}, "");
    var doc = try pdf.Document.open(testing.allocator, bytes, .{});
    defer doc.deinit();
    const pl = try pdf.pages.PageList.build(&doc);
    const p = pdf.pages.page(&doc, pl, 0).?;
    var rend = pdf.Renderer.init(&doc, .{});
    defer rend.deinit();
    // An allocator that lives only for the first page, and must get everything back.
    var first: std.heap.DebugAllocator(.{}) = .init;
    {
        var dl = try rend.render(first.allocator(), p);
        dl.deinit();
    }
    try testing.expectEqual(std.heap.Check.ok, first.deinit());
    var dl = try rend.render(testing.allocator, p);
    defer dl.deinit();
    try testing.expectEqual(@as(usize, 200), dl.commands.len);
}

test "repeated operators and re-rendering do not grow the document" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // A hex stream of 50,000 bytes, used as a calculator program, a ToUnicode
    // map and a palette.
    const hex = try a.alloc(u8, 100_000);
    for (hex, 0..) |*c, i| c.* = if (i % 2 == 0) '2' else '0';
    const program = try std.fmt.allocPrint(a, "<< /FunctionType 4 /Domain [0 1] /Range [0 1] /Filter /AHx /Length {d} >>\nstream\n{s}7B7D>\nendstream", .{ hex.len + 5, hex });
    const blob = try std.fmt.allocPrint(a, "<< /Filter /AHx /Length {d} >>\nstream\n{s}>\nendstream", .{ hex.len + 1, hex });
    const image = "<< /Subtype /Image /Width 1 /Height 1 /BitsPerComponent 8 /ColorSpace [/Indexed /DeviceGray 1 6 0 R] /Length 1 >>\nstream\n\x00\nendstream";
    const resources = "/ColorSpace << /Ref 7 0 R /Direct [/Separation /x /DeviceGray 5 0 R] >> " ++
        "/Font << /D << /Subtype /Type1 /BaseFont /Helvetica /ToUnicode 6 0 R >> >> " ++
        "/Shading << /Sh << /ShadingType 2 /ColorSpace /DeviceGray /Coords [0 0 1 0] /Function << /FunctionType 2 /Domain [0 1] >> >> >> " ++
        "/XObject << /Im 8 0 R >>";
    const once = "/Ref cs /Direct cs /D 1 Tf /Sh sh /Im Do ";
    const many: [300][]const u8 = @splat(once);
    const bytes = try page(a, try std.mem.concat(a, u8, &many), resources, &.{ program, blob, "[/Separation /x /DeviceGray 5 0 R]", image }, "");
    var doc = try pdf.Document.open(testing.allocator, bytes, .{});
    defer doc.deinit();
    const pl = try pdf.pages.PageList.build(&doc);
    const p = pdf.pages.page(&doc, pl, 0).?;
    const before = doc.arena.queryCapacity();
    var after_first: usize = 0;
    for (0..10) |i| {
        var rend = pdf.Renderer.init(&doc, .{});
        defer rend.deinit();
        var dl = try rend.render(testing.allocator, p);
        dl.deinit();
        if (i == 0) after_first = doc.arena.queryCapacity();
    }
    try testing.expect(after_first - before < 2 << 20);
    try testing.expect(doc.arena.queryCapacity() - after_first < 64 << 10);
}

test "a colour space that names a resource, or sits in an inline image, is not shared" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The same indirect array, whose base is a name each form defines differently.
    const form = "<< /Subtype /Form /BBox [0 0 9 9] /Resources << /ColorSpace << /Base /{s} /I 7 0 R >> >> /Length 25 >>\nstream\n/I cs 0 sc 0 0 1 1 re f \n\nendstream";
    const bytes = try page(a, "/A Do /B Do BI /W 1 /H 1 /BPC 8 /CS [/I /G 0 <FF>] ID x\nEI BI /W 1 /H 1 /BPC 8 /CS [/I /RGB 0 <FF0000>] ID x\nEI", "/XObject << /A 5 0 R /B 6 0 R >>", &.{
        try std.fmt.allocPrint(a, form, .{"DeviceGray"}),
        try std.fmt.allocPrint(a, form, .{"DeviceRGB"}),
        "[/Indexed /Base 0 <FF0000>]",
    }, "");
    const r = try render(bytes);
    defer done(r);
    var fills: [2]pdf.color.Rgb = undefined;
    var bases: [2]std.meta.Tag(pdf.color.Space) = undefined;
    var nf: usize = 0;
    var ni: usize = 0;
    for (r.list.commands) |c| switch (c) {
        .fill => |f| {
            fills[nf] = f.paint.color;
            nf += 1;
        },
        .image => |im| {
            bases[ni] = std.meta.activeTag(im.space.indexed.base.*);
            ni += 1;
        },
        else => {},
    };
    try testing.expectEqual(@as(f32, 1), fills[0].g); // gray 1.0: white
    try testing.expectEqual(@as(f32, 0), fills[1].g); // red
    try testing.expect(bases[0] == .gray and bases[1] == .rgb);
}

test "limits: glyphs, path segments and commands are counted for the whole page" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const form = struct {
        fn make(al: Allocator, body: []const u8) ![]const u8 {
            return std.fmt.allocPrint(al, "<< /Subtype /Form /BBox [0 0 9 9] /Length {d} >>\nstream\n{s}\nendstream", .{ body.len, body });
        }
    }.make;
    const dos: [50][]const u8 = @splat("/F Do");
    const many = try std.mem.join(a, " ", &dos);
    const letters: [100]u8 = @splat('a');
    const text_page = try page(a, many, "/XObject << /F 5 0 R >>", &.{
        try form(a, try std.fmt.allocPrint(a, "BT /H 10 Tf ({s}) Tj ET", .{&letters})),
    }, "");
    const lines: [100][]const u8 = @splat("1 1 l");
    const path_page = try page(a, many, "/XObject << /F 5 0 R >>", &.{
        try form(a, try std.fmt.allocPrint(a, "0 0 m {s} S", .{try std.mem.join(a, " ", &lines)})),
    }, "");
    // Fifty colours make fifty cells of fifty fills each.
    var content: std.ArrayList(u8) = .empty;
    try content.appendSlice(a, "/CS cs ");
    for (0..50) |i| try content.print(a, "0.{d:0>2} 0 0 /P scn 0 0 1 1 re f ", .{i * 2});
    const fills: [50][]const u8 = @splat("0 0 1 1 re f");
    const cell = try std.mem.join(a, " ", &fills);
    const tiled = try page(a, content.items, "/ColorSpace << /CS [/Pattern /DeviceRGB] >> /Pattern << /P 5 0 R >>", &.{
        try std.fmt.allocPrint(a, "<< /PatternType 1 /PaintType 2 /BBox [0 0 1 1] /XStep 1 /YStep 1 /Length {d} >>\nstream\n{s}\nendstream", .{ cell.len, cell }),
    }, "");
    // The text page needs the font in the form's inherited resources.
    const with_font = try std.mem.replaceOwned(u8, a, text_page, "/XObject << /F 5 0 R >>", "/XObject << /F 5 0 R >> /Font << /H << /Subtype /Type1 /BaseFont /Helvetica >> >>");

    _ = try renderCost(with_font, .{});
    _ = try renderCost(path_page, .{});
    _ = try renderCost(tiled, .{});
    try testing.expectError(error.LimitExceeded, renderCost(with_font, .{ .max_glyphs = 1000 }));
    try testing.expectError(error.LimitExceeded, renderCost(path_page, .{ .max_path_segments = 1000 }));
    try testing.expectError(error.LimitExceeded, renderCost(tiled, .{ .max_commands = 1000 }));
}

test "reading order keeps small lines intact next to a large letter" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = try render(try page(arena.allocator(), "BT /F1 36 Tf 10 38 Td (T) Tj /F1 10 Tf 1 0 0 1 40 56 Tm (he first line) Tj 1 0 0 1 40 44 Tm (second line) Tj ET", helv, &.{helv_obj}, ""));
    defer done(r);
    const got = try pdf.text.extract(testing.allocator, &r.list, .reading);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("he first line\nT second line\n", got);
}

test "reading order: superscripts stay on their line and runs sort by position" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = try render(try page(arena.allocator(), "BT /F1 10 Tf 1 0 0 1 60 50 Tm (world) Tj 1 0 0 1 10 50 Tm (hello) Tj " ++
        "/F1 6 Tf 1 0 0 1 90 54 Tm (2) Tj /F1 10 Tf 1 0 0 1 10 30 Tm (next) Tj ET", helv, &.{helv_obj}, ""));
    defer done(r);
    const got = try pdf.text.extract(testing.allocator, &r.list, .reading);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("hello world 2\nnext\n", got);
}

test "a function tree that repeats references is loaded once per function" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Eight levels, each naming the next eight times: 8^8 leaves.
    var objects: std.ArrayList([]const u8) = .empty;
    for (0..8) |level| {
        const next: [8][]const u8 = @splat(try std.fmt.allocPrint(a, "{d} 0 R", .{level + 6}));
        try objects.append(a, try std.fmt.allocPrint(a, "<< /FunctionType 3 /Domain [0 1] /Functions [{s}] /Bounds [] /Encode [] >>", .{try std.mem.join(a, " ", &next)}));
    }
    try objects.append(a, "<< /FunctionType 2 /Domain [0 1] /N 1 >>");
    const bytes = try page(a, "/CS0 cs 0.5 sc 0 0 1 1 re f", "/ColorSpace << /CS0 [/Separation /S /DeviceGray 5 0 R] >>", objects.items, "");
    try testing.expect(try renderCost(bytes, .{}) < 1 << 20);
}

test "gidOfCid decodes the CID to glyph map once" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // 128 KiB of map, hex encoded; CID 1 is glyph 0x0102.
    const hex = try a.alloc(u8, 262_144);
    @memset(hex, '0');
    @memcpy(hex[4..8], "0102");
    const r = try render(try page(a, "BT /F1 10 Tf <0001> Tj ET", helv, &.{
        "<< /Type /Font /Subtype /Type0 /BaseFont /X /Encoding /Identity-H /DescendantFonts [<< /Subtype /CIDFontType2 /CIDToGIDMap 6 0 R >>] >>",
        try std.fmt.allocPrint(a, "<< /Filter /AHx /Length {d} >>\nstream\n{s}>\nendstream", .{ hex.len + 1, hex }),
    }, ""));
    defer done(r);
    const f = r.list.commands[0].text.font;
    const before = r.doc.arena.queryCapacity();
    for (0..500) |_| try testing.expectEqual(@as(u32, 0x0102), f.gidOfCid(&r.doc, 1));
    try testing.expectEqual(@as(u32, 0), f.gidOfCid(&r.doc, 2));
    // Past the end of the map: no glyph.
    try testing.expectEqual(@as(u32, 0), f.gidOfCid(&r.doc, 70_000));
    try testing.expect(r.doc.arena.queryCapacity() - before < 512 << 10);
}

test "a TJ holding only numbers still moves the text position" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = try render(try page(arena.allocator(), "BT /F1 10 Tf 10 50 Td (A) Tj [-5000] TJ (B) Tj ET", helv, &.{helv_obj}, ""));
    defer done(r);
    const b = r.list.commands[1].text;
    try testing.expectApproxEqAbs(@as(f64, 66.67), b.tm.e, 1e-9);
}

/// A page using a Type 3 font /T whose glyph "a" runs `proc`. The page
/// resources name the Type 3 font /T and Helvetica /H.
fn type3Page(a: Allocator, content: []const u8, proc: []const u8) ![]u8 {
    return page(a, content, "/Font << /T 5 0 R /H 7 0 R >>", &.{
        "<< /Type /Font /Subtype /Type3 /FontBBox [0 0 500 700] /FontMatrix [0.001 0 0 0.001 0 0] /CharProcs << /ga 6 0 R >> /Encoding << /Differences [97 /ga] >> /FirstChar 97 /Widths [500] /Resources << /Font << /H 7 0 R >> >> >>",
        try std.fmt.allocPrint(a, "<< /Length {d} >>\nstream\n{s}\nendstream", .{ proc.len, proc }),
        helv_obj,
    }, "");
}

test "text operators in a Type 3 glyph do not move the page's text" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = try render(try type3Page(arena.allocator(), "BT /T 10 Tf 10 50 Td (a) Tj /H 10 Tf (Z) Tj ET", "500 0 d0 BT /H 500 Tf 3 4 Td (q) Tj ET"));
    defer done(r);
    var last: display.Text = undefined;
    for (r.list.commands) |c| if (c == .text) {
        last = c.text;
    };
    try testing.expectEqualStrings("Z", last.glyphs[0].text);
    try testing.expectApproxEqAbs(@as(f64, 15), last.tm.e, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 50), last.tm.f, 1e-9);
}

test "Type 3 glyphs are not painted in the invisible rendering modes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    for ([_]struct { u8, usize }{ .{ 0, 1 }, .{ 3, 0 }, .{ 7, 0 } }) |case| {
        const stream = try std.fmt.allocPrint(arena.allocator(), "BT /T 10 Tf {d} Tr 10 50 Td (a) Tj ET", .{case[0]});
        const r = try render(try type3Page(arena.allocator(), stream, "500 0 d0 0 0 400 700 re f"));
        defer done(r);
        try testing.expectEqual(case[1], countKind(r.list, .fill));
        try testing.expectEqual(@as(usize, 1), countKind(r.list, .text));
    }
}

test "a clip set inside hidden optional content still applies" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bytes = try page(a, "q /OC /L BDC 0 0 10 10 re W n 0 0 5 5 re f EMC 0 0 100 100 re f Q", "/Properties << /L 5 0 R >>", &.{"<< /Type /OCG /Name (hidden) >>"}, "");
    const with_oc = try std.mem.replaceOwned(u8, a, bytes, "/Type /Catalog /Pages 2 0 R", "/Type /Catalog /Pages 2 0 R /OCProperties << /OCGs [5 0 R] /D << /OFF [5 0 R] >> >>");
    const r = try render(with_oc);
    defer done(r);
    // save, clip, the visible fill, restore. The hidden fill is gone.
    const want = [_]std.meta.Tag(display.Command){ .save, .clip, .fill, .restore };
    try testing.expectEqual(want.len, r.list.commands.len);
    for (want, r.list.commands) |w, c| try testing.expectEqual(w, std.meta.activeTag(c));
    try testing.expectEqual(@as(f64, 100), r.list.commands[2].fill.path[1].line.x);
}

/// A page whose content draws a square under the optional-content entry /X,
/// object 7. Group 5 is on; group 6 is off.
fn ocPage(a: Allocator, entry: []const u8, content: []const u8, extra: []const []const u8) ![]u8 {
    var objects: std.ArrayList([]const u8) = .empty;
    try objects.appendSlice(a, &.{ "<< /Type /OCG /Name (on) >>", "<< /Type /OCG /Name (off) >>", entry });
    try objects.appendSlice(a, extra);
    const bytes = try page(a, content, "/Properties << /X 7 0 R /Off 6 0 R >> /XObject << /Fm 8 0 R >>", objects.items, "");
    return std.mem.replaceOwned(u8, a, bytes, "/Type /Catalog /Pages 2 0 R", "/Type /Catalog /Pages 2 0 R /OCProperties << /OCGs [5 0 R 6 0 R] /D << /OFF [6 0 R] >> >>");
}

test "optional content membership: every policy, direct and indirect /OCGs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { ocgs: []const u8, policy: []const u8, visible: bool }{
        .{ .ocgs = "[5 0 R]", .policy = "AllOff", .visible = false },
        .{ .ocgs = "[5 0 R]", .policy = "AnyOff", .visible = false },
        .{ .ocgs = "[5 0 R]", .policy = "AllOn", .visible = true },
        .{ .ocgs = "[6 0 R]", .policy = "AllOff", .visible = true },
        .{ .ocgs = "[5 0 R 6 0 R]", .policy = "AnyOn", .visible = true },
        .{ .ocgs = "[5 0 R 6 0 R]", .policy = "AllOn", .visible = false },
        .{ .ocgs = "[5 0 R 6 0 R]", .policy = "AnyOff", .visible = true },
        .{ .ocgs = "5 0 R", .policy = "AnyOn", .visible = true },
        .{ .ocgs = "6 0 R", .policy = "AnyOn", .visible = false },
        // An indirect array of groups.
        .{ .ocgs = "8 0 R", .policy = "AnyOn", .visible = false },
        // No groups at all: no effect.
        .{ .ocgs = "[]", .policy = "AllOff", .visible = true },
    };
    for (cases) |c| {
        const entry = try std.fmt.allocPrint(a, "<< /Type /OCMD /P /{s} /OCGs {s} >>", .{ c.policy, c.ocgs });
        const r = try render(try ocPage(a, entry, "/OC /X BDC 0 0 1 1 re f EMC", &.{"[6 0 R]"}));
        defer done(r);
        try testing.expectEqual(@as(usize, @intFromBool(c.visible)), countKind(r.list, .fill));
    }
    // With no group off at all, the policies still apply.
    const bytes = try ocPage(a, "<< /Type /OCMD /P /AllOff /OCGs [5 0 R] >>", "/OC /X BDC 0 0 1 1 re f EMC", &.{});
    const none_off = try std.mem.replaceOwned(u8, a, bytes, "/OFF [6 0 R]", "/OFF [       ]");
    const r = try render(none_off);
    defer done(r);
    try testing.expectEqual(@as(usize, 0), countKind(r.list, .fill));
}

test "marked content opened or closed in a form stays in the form" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The form leaves a hidden section open.
    const open_body = "/OC /Off BDC 0 0 1 1 re f";
    const open_form = try std.fmt.allocPrint(a, "<< /Subtype /Form /BBox [0 0 9 9] /Length {d} >>\nstream\n{s}\nendstream", .{ open_body.len, open_body });
    const r = try render(try ocPage(a, "<< /Type /OCG >>", "/Fm Do 0 0 9 9 re f", &.{open_form}));
    defer done(r);
    try testing.expectEqual(@as(usize, 1), countKind(r.list, .fill));
    // The form's stray EMC cannot end the page's hidden section.
    const close_body = "EMC 0 0 1 1 re f";
    const close_form = try std.fmt.allocPrint(a, "<< /Subtype /Form /BBox [0 0 9 9] /Length {d} >>\nstream\n{s}\nendstream", .{ close_body.len, close_body });
    const r2 = try render(try ocPage(a, "<< /Type /OCG >>", "/OC /Off BDC /Fm Do 0 0 9 9 re f EMC 0 0 3 3 re f", &.{close_form}));
    defer done(r2);
    try testing.expectEqual(@as(usize, 1), countKind(r2.list, .fill));
}

test "deeply nested q keeps the right state, and too deep is an error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const qs: [256][]const u8 = @splat("q");
    const stream = try std.fmt.allocPrint(a, "{s} 0 1 0 rg q 1 0 0 rg Q 0 0 1 1 re f", .{try std.mem.join(a, " ", &qs)});
    const r = try render(try page(a, stream, "", &.{}, ""));
    defer done(r);
    for (r.list.commands) |c| if (c == .fill) {
        try testing.expectEqual(@as(f32, 1), c.fill.paint.color.g);
        try testing.expectEqual(@as(f32, 0), c.fill.paint.color.r);
    };
    try testing.expectEqual(countKind(r.list, .save), countKind(r.list, .restore));
    const too_many: [5000][]const u8 = @splat("q");
    try testing.expectError(error.LimitExceeded, renderCost(try page(a, try std.mem.join(a, " ", &too_many), "", &.{}, ""), .{}));
}

test "a display list says when something was left out" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const good = "<< /Subtype /Form /BBox [0 0 9 9] /Length 12 >>\nstream\n0 0 1 1 re f\nendstream";
    const bad = "<< /Subtype /Form /BBox [0 0 9 9] /Filter /NoSuchDecode /Length 1 >>\nstream\nx\nendstream";
    {
        const r = try render(try page(a, "/F Do", "/XObject << /F 5 0 R >>", &.{good}, ""));
        defer done(r);
        try testing.expect(!r.list.incomplete);
    }
    {
        const r = try render(try page(a, "/F Do 0 0 1 1 re f", "/XObject << /F 5 0 R >>", &.{bad}, ""));
        defer done(r);
        try testing.expect(r.list.incomplete);
        try testing.expectEqual(@as(usize, 1), countKind(r.list, .fill));
    }
    // A form nested deeper than max_depth is left out, and said to be.
    var doc = try pdf.Document.open(testing.allocator, try page(a, "/F Do", "/XObject << /F 5 0 R >>", &.{good}, ""), .{});
    defer doc.deinit();
    const pl = try pdf.pages.PageList.build(&doc);
    var rend = pdf.Renderer.init(&doc, .{ .max_depth = 0 });
    defer rend.deinit();
    var dl = try rend.render(testing.allocator, pdf.pages.page(&doc, pl, 0).?);
    defer dl.deinit();
    try testing.expect(dl.incomplete);
}

test "the text size on the page comes from the vertical axis of text space" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // Sheared: the x axis maps to (0, 40) and the em height is 5 across it.
    const r = try render(try page(arena.allocator(), "BT /F1 1 Tf 40 0 0 5 10 50 Tm (A) Tj 40 0 0 5 10 38 Tm (B) Tj ET", helv, &.{helv_obj}, ""));
    defer done(r);
    const got = try pdf.text.extract(testing.allocator, &r.list, .content);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("A\nB\n", got);
    const sheared = try render(try page(arena.allocator(), "BT /F1 1 Tf 10 40 0 5 10 50 Tm (A) Tj 10 40 0 5 10 38 Tm (B) Tj ET", helv, &.{helv_obj}, ""));
    defer done(sheared);
    var lay = try pdf.text.layout(testing.allocator, &sheared.list);
    defer lay.deinit(testing.allocator);
    // Size 5, not 40: lines 12 apart stay apart.
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, lay.text, "\n"));
}

test "the box of a tilted glyph covers all four corners" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // Turned by 45 degrees: the box of a wide, tall glyph is as wide as it is high.
    const r = try render(try page(arena.allocator(), "BT /F1 12 Tf 0.70710678 0.70710678 -0.70710678 0.70710678 50 50 Tm (m) Tj ET", helv, &.{helv_obj}, ""));
    defer done(r);
    var lay = try pdf.text.layout(testing.allocator, &r.list);
    defer lay.deinit(testing.allocator);
    const b = lay.boxes[0].rect;
    // (width + height) / sqrt 2, in both directions.
    const want = (0.833 * 12 + 12) / @sqrt(2.0);
    try testing.expectApproxEqAbs(@as(f64, want), b.x1 - b.x0, 0.01);
    try testing.expectApproxEqAbs(@as(f64, want), b.y1 - b.y0, 0.01);
}

test "content order separates words drawn from right to left" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = try render(try page(arena.allocator(), "BT /F1 10 Tf 100 50 Td (world) Tj -80 0 Td (hello) Tj ET", helv, &.{helv_obj}, ""));
    defer done(r);
    const got = try pdf.text.extract(testing.allocator, &r.list, .content);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("world hello\n", got);
}

test "rotated text reads along its own baseline" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { content: []const u8, page_extra: []const u8 = "", want: []const u8 }{
        .{ .content = "BT /F1 10 Tf 0 1 -1 0 50 10 Tm (Hello) Tj ET", .want = "Hello\n" },
        .{ .content = "BT /F1 10 Tf -1 0 0 -1 150 50 Tm (Hello) Tj ET", .want = "Hello\n" },
        .{ .content = "BT /F1 10 Tf 0 -1 1 0 50 90 Tm (Hello) Tj ET", .want = "Hello\n" },
        .{ .content = "BT /F1 10 Tf 10 50 Td (Hello) Tj ET", .page_extra = "/Rotate 90", .want = "Hello\n" },
        .{ .content = "BT /F1 10 Tf 0.8 0.6 -0.6 0.8 20 20 Tm (Hello world) Tj ET", .want = "Hello world\n" },
        // Two upward lines read left to right, after the horizontal text.
        .{ .content = "BT /F1 10 Tf 0 1 -1 0 40 10 Tm (second) Tj 0 1 -1 0 25 10 Tm (first) Tj 1 0 0 1 80 80 Tm (level) Tj ET", .want = "level\nfirst\nsecond\n" },
    };
    for (cases) |c| {
        const r = try render(try page(a, c.content, helv, &.{helv_obj}, c.page_extra));
        defer done(r);
        const got = try pdf.text.extract(a, &r.list, .reading);
        try testing.expectEqualStrings(c.want, got);
    }
    const r = try render(try page(a, cases[0].content, helv, &.{helv_obj}, ""));
    defer done(r);
    try testing.expectEqualStrings("Hello\n", try pdf.text.extract(a, &r.list, .content));
}

test "a width range is found behind many entries inside it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var w: std.ArrayList(u8) = .empty;
    try w.appendSlice(a, "0 1000 500");
    for (1..40) |cid| try w.print(a, " {d} [600]", .{cid});
    const font = try std.fmt.allocPrint(a, "<< /Type /Font /Subtype /Type0 /BaseFont /X /Encoding /Identity-H /DescendantFonts [<< /Subtype /CIDFontType2 /W [{s}] >>] >>", .{w.items});
    const r = try render(try page(a, "BT /F1 10 Tf <00320005> Tj ET", helv, &.{font}, ""));
    defer done(r);
    const glyphs = r.list.commands[0].text.glyphs;
    try testing.expectEqual(@as(f64, 0.5), glyphs[0].advance);
    try testing.expectEqual(@as(f64, 0.6), glyphs[1].advance);
}

test "ToUnicode keys of another width still apply when none of the right width does" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cmap_text = "1 begincodespacerange <0000> <FFFF> endcodespacerange 2 beginbfchar <0001> <0048> <0041> <005A> endbfchar";
    const bytes = try page(a, "BT /F1 10 Tf <0141> Tj ET", helv, &.{
        "<< /Type /Font /Subtype /TrueType /BaseFont /X /FirstChar 1 /Widths [700] /ToUnicode 6 0 R >>",
        try std.fmt.allocPrint(a, "<< /Length {d} >>\nstream\n{s}\nendstream", .{ cmap_text.len, cmap_text }),
    }, "");
    const r = try render(bytes);
    defer done(r);
    const got = try pdf.text.extract(a, &r.list, .content);
    try testing.expectEqualStrings("HZ\n", got);
}

test "painting in a None separation leaves no mark" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const tint = "<< /FunctionType 2 /Domain [0 1] /C0 [1] /C1 [0] /N 1 >>";
    const resources = "/ColorSpace << /N [/Separation /None /DeviceGray " ++ tint ++ "] /DN [/DeviceN [/None /None] /DeviceGray " ++ tint ++ "] >> /Font << /F1 5 0 R >>";
    const r = try render(try page(arena.allocator(), "/N cs 0 0 9 9 re f 1 sc 0 0 9 9 re f /DN CS 1 1 SC 0 0 9 9 re S BT /F1 10 Tf (x) Tj ET " ++
        "BI /W 1 /H 1 /BPC 8 /CS /N ID a\nEI", resources, &.{helv_obj}, ""));
    defer done(r);
    for (r.list.commands) |c| switch (c) {
        .fill => |f| try testing.expect(f.paint == .none),
        .stroke => |s| try testing.expect(s.paint == .none),
        .text => |t| try testing.expect(t.fill == .none),
        .image => return error.TestUnexpectedResult,
        else => {},
    };
}

test "an embedded symbolic font keeps its built-in encoding for glyph names" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try render(try page(a, "BT /F1 10 Tf <2741> Tj ET", helv, &.{
        "<< /Type /Font /Subtype /Type1 /BaseFont /ABCDEF+CMSY10 /FirstChar 39 /Widths [500] /Encoding << /Differences [65 /Alpha] >> /FontDescriptor << /Flags 4 /FontFile 6 0 R >> >>",
        "<< /Length 0 >>\nstream\n\nendstream",
    }, ""));
    defer done(r);
    const f = r.list.commands[0].text.font;
    // The renderer takes unnamed codes from the font program.
    try testing.expect(f.names[39] == null);
    try testing.expectEqualStrings("Alpha", f.names[65].?);
    // Text extraction keeps its best guess without a ToUnicode map.
    try testing.expect(r.list.commands[0].text.glyphs[0].text.len > 0);
    // A symbolic font that is not embedded is unchanged.
    const bare = try render(try page(a, "BT /F1 10 Tf <41> Tj ET", helv, &.{"<< /Type /Font /Subtype /Type1 /BaseFont /X /FontDescriptor << /Flags 4 >> >>"}, ""));
    defer done(bare);
    try testing.expectEqualStrings("A", bare.list.commands[0].text.font.names[65].?);
}

test "standard fonts without /Widths never give a glyph no width" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { font: []const u8, code: []const u8, advance: f64 }{
        .{ .font = "/BaseFont /Courier /Encoding << /Differences [1 /Amacron] >>", .code = "01", .advance = 0.6 },
        .{ .font = "/BaseFont /Courier", .code = "81", .advance = 0.6 },
        .{ .font = "/BaseFont /Helvetica /Encoding << /Differences [1 /nosuchglyph] >>", .code = "01", .advance = 0.5 },
        // The soft hyphen and no-break space are a hyphen and a space.
        .{ .font = "/BaseFont /Helvetica /Encoding /WinAnsiEncoding", .code = "AD", .advance = 0.333 },
        .{ .font = "/BaseFont /Helvetica /Encoding /WinAnsiEncoding", .code = "A0", .advance = 0.278 },
        .{ .font = "/BaseFont /Symbol", .code = "41", .advance = 0.6 },
        .{ .font = "/BaseFont /ZapfDingbats", .code = "41", .advance = 0.6 },
    };
    for (cases) |c| {
        const r = try render(try page(a, try std.fmt.allocPrint(a, "BT /F1 10 Tf <{s}> Tj ET", .{c.code}), helv, &.{try std.fmt.allocPrint(a, "<< /Type /Font /Subtype /Type1 {s} >>", .{c.font})}, ""));
        defer done(r);
        try testing.expectApproxEqAbs(c.advance, r.list.commands[0].text.glyphs[0].advance, 1e-9);
    }
}

test "text and shadings carry the blend mode" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = try render(try page(arena.allocator(), "/M gs BT /F1 10 Tf (x) Tj ET /S sh", helv ++ " /ExtGState << /M << /BM /Multiply >> >> /Shading << /S 6 0 R >>", &.{
        helv_obj,
        "<< /ShadingType 2 /ColorSpace /DeviceGray /Coords [0 0 1 0] /Function << /FunctionType 2 /Domain [0 1] >> >>",
    }, ""));
    defer done(r);
    try testing.expectEqualStrings("Multiply", r.list.commands[0].text.blend);
    try testing.expectEqualStrings("Multiply", r.list.commands[1].shading.blend);
}

test "Type 3 text is sized by its font matrix, not by Tf alone" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Glyph space is user space: with Tf 1 the glyphs are about 10 points high.
    const r = try render(try page(a, "BT /F1 1 Tf 10 50 Td [(a) -500 (a) -500 (a)] TJ ET", helv, &.{
        "<< /Type /Font /Subtype /Type3 /FontBBox [0 -2 6 8] /FontMatrix [1 0 0 1 0 0] /CharProcs << /ga 6 0 R >> /Encoding << /Differences [97 /a] >> /FirstChar 97 /Widths [6] >>",
        "<< /Length 0 >>\nstream\n\nendstream",
    }, ""));
    defer done(r);
    const lay = try pdf.text.layout(a, &r.list);
    try testing.expectEqualStrings("aaa\n", lay.text);
    try testing.expectApproxEqAbs(@as(f64, 10), lay.boxes[0].rect.y1 - lay.boxes[0].rect.y0, 0.01);
}

test "shadings without a usable function and tiling without steps paint nothing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "", "/Function << /FunctionType 99 >>" }) |function| {
        const r = try render(try page(a, "/S sh", "/Shading << /S 5 0 R >>", &.{try std.fmt.allocPrint(a, "<< /ShadingType 2 /ColorSpace /DeviceRGB /Coords [0 0 1 0] {s} >>", .{function})}, ""));
        defer done(r);
        try testing.expectEqual(@as(usize, 0), countKind(r.list, .shading));
    }
    const nines: [400]u8 = @splat('9');
    for ([_][]const u8{ "/BBox [0 0 1 1] /XStep 0 /YStep 1", "/BBox [0 0 1 1] /XStep 1 /YStep 0", try std.fmt.allocPrint(a, "/BBox [0 0 1 1] /XStep {s} /YStep 1", .{&nines}), "/BBox [0 0 0 0]" }) |geometry| {
        const r = try render(try page(a, "/Pattern cs /P scn 0 0 9 9 re f", "/Pattern << /P 5 0 R >>", &.{try std.fmt.allocPrint(a, "<< /PatternType 1 /PaintType 1 {s} /Length 0 >>\nstream\n\nendstream", .{geometry})}, ""));
        defer done(r);
        for (r.list.commands) |c| if (c == .fill) try testing.expect(c.fill.paint == .none);
    }
}

test "a tiling cell holds no pointer into render's stack frame" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = try render(try page(arena.allocator(), "/Pattern cs /P scn 0 0 9 9 re f", "/Pattern << /P 5 0 R >>", &.{"<< /PatternType 1 /PaintType 1 /BBox [0 0 1 1] /XStep 1 /YStep 1 /Length 12 >>\nstream\n0 0 1 1 re f\nendstream"}, ""));
    defer done(r);
    const cell = r.list.commands[0].fill.paint.tiling.cell;
    try testing.expectEqual(testing.allocator.ptr, cell.arena.child_allocator.ptr);
    try testing.expectEqual(testing.allocator.vtable, cell.arena.child_allocator.vtable);
    try testing.expectEqual(@as(usize, 1), cell.commands.len);
}

test "a DeviceN space with more than eight colorants keeps its component count" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const names = "[/a /b /c /d /e /f /g /h /i /j]";
    const program = "{ pop pop pop pop pop pop pop pop pop }";
    var limits: std.ArrayList(u8) = .empty;
    for (0..10) |_| try limits.appendSlice(a, "0 1 ");
    const function = try std.fmt.allocPrint(a, "<< /FunctionType 4 /Domain [{s}] /Range [0 1] /Length {d} >>\nstream\n{s}\nendstream", .{ limits.items, program.len, program });
    const image = "<< /Subtype /Image /Width 1 /Height 2 /BitsPerComponent 8 /ColorSpace 7 0 R /Length 20 >>\nstream\n\xff\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\nendstream";
    const r = try render(try page(a, "q 10 0 0 10 0 0 cm /Im Do Q", "/XObject << /Im 5 0 R >>", &.{ image, function, try std.fmt.allocPrint(a, "[/DeviceN {s} /DeviceGray 6 0 R]", .{names}) }, ""));
    defer done(r);
    var img: display.Image = undefined;
    for (r.list.commands) |c| if (c == .image) {
        img = c.image;
    };
    try testing.expectEqual(@as(u8, 10), img.space.components());
    // The program keeps the first tint: white for the first row, black for the second.
    const px = (try pdf.image.decode(&r.doc, a, img)).pixels;
    try testing.expectEqual(@as(u8, 255), px.rgba[0]);
    try testing.expectEqual(@as(u8, 0), px.rgba[4]);
}

test "encoding edge cases: unused and special WinAnsi codes, expert and Type 3 names" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const enc = pdf.encoding;
    try testing.expectEqual(@as(u21, 0x2022), enc.unicodeOf(.win_ansi, 0x7F));
    // PDFDocEncoding is its own table, not WinAnsi.
    try testing.expectEqual(@as(u21, 0x2022), enc.unicodeOf(.pdf_doc, 0x80));
    try testing.expectEqual(@as(u21, 0x20AC), enc.unicodeOf(.pdf_doc, 0xA0));
    try testing.expectEqual(@as(u21, 0), enc.unicodeOf(.pdf_doc, 0x9F));
    const r = try render(try page(a, "BT /F1 10 Tf (x) Tj /F2 10 Tf (x) Tj /F3 10 Tf (a) Tj ET", "/Font << /F1 5 0 R /F2 6 0 R /F3 7 0 R >>", &.{
        "<< /Type /Font /Subtype /TrueType /BaseFont /X /Encoding /WinAnsiEncoding >>",
        "<< /Type /Font /Subtype /Type1 /BaseFont /X /Encoding /MacExpertEncoding >>",
        "<< /Type /Font /Subtype /Type3 /FontMatrix [0.001 0 0 0.001 0 0] /CharProcs << >> /Encoding << /Differences [97 /ga] >> /FirstChar 97 /Widths [500] >>",
    }, ""));
    defer done(r);
    var fonts: [3]*const pdf.font.Font = undefined;
    var n: usize = 0;
    for (r.list.commands) |c| if (c == .text) {
        fonts[n] = c.text.font;
        n += 1;
    };
    // The names a font program has for the no-break space and soft hyphen.
    try testing.expectEqualStrings("space", fonts[0].names[0xA0].?);
    try testing.expectEqualStrings("hyphen", fonts[0].names[0xAD].?);
    try testing.expectEqualStrings("bullet", fonts[0].names[0x7F].?);
    // No expert glyph tables: nothing is invented.
    try testing.expect(fonts[1].names['x'] == null);
    // A Type 3 font has only the names of its Differences.
    try testing.expect(fonts[2].names['b'] == null);
    try testing.expectEqualStrings("ga", fonts[2].names['a'].?);
}

test "operands keep their values through the scanner" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var scanner = pdf.content.Scanner.init(arena.allocator(), "1 2 3 4 5.5 -6 cm [(A) -120 (B)] TJ true false null foo");
    const cm = (try scanner.next()).?;
    for ([_]f64{ 1, 2, 3, 4, 5.5, -6 }, cm.operands) |want, got| try testing.expectEqual(want, got.asNum().?);
    const tj = (try scanner.next()).?.operands[0].array;
    try testing.expectEqualStrings("A", tj[0].string);
    try testing.expectEqual(@as(i64, -120), tj[1].integer);
    try testing.expectEqualStrings("B", tj[2].string);
    const foo = (try scanner.next()).?;
    try testing.expect(foo.operands[0].boolean and !foo.operands[1].boolean and foo.operands[2] == .null);
}

test "scanning continues with the operators after damage" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var scanner = pdf.content.Scanner.init(arena.allocator(), ") ] >> (unterminated\n1 2 m 12abc 3 4 l q");
    var names: std.ArrayList(u8) = .empty;
    while (try scanner.next()) |op| {
        if (std.mem.eql(u8, op.name, "m") or std.mem.eql(u8, op.name, "l") or std.mem.eql(u8, op.name, "q")) try names.appendSlice(arena.allocator(), op.name);
    }
    try testing.expectEqualStrings("mlq", names.items);
}

test "cm concatenates in order, and Q restores the whole state" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = try render(try page(arena.allocator(), "q 2 0 0 3 0 0 cm 1 0 0 1 5 7 cm 1 0 0 rg 4 w 0 0 1 1 re f Q 0 0 1 1 re B", "", &.{}, ""));
    defer done(r);
    // The translation is inside the scaling.
    const inner = r.list.commands[1].fill;
    try testing.expectEqual(@as(f64, 10), inner.ctm.e);
    try testing.expectEqual(@as(f64, 21), inner.ctm.f);
    try testing.expectEqual(@as(f32, 1), inner.paint.color.r);
    const outer = r.list.commands[3].fill;
    try testing.expectEqual(@as(f64, 1), outer.ctm.a);
    try testing.expectEqual(@as(f32, 0), outer.paint.color.r);
    try testing.expectEqual(@as(f64, 1), r.list.commands[4].stroke.style.width);
}

test "text: the double quote operator, TD, Ts and TJ under Tz" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = try render(try page(arena.allocator(), "BT /F1 10 Tf 10 90 Td 0 -20 TD 3 2 (a b) \" 4 Ts 50 Tz [(a) -1000 (b)] TJ T* (c) Tj ET", helv, &.{helv_obj}, ""));
    defer done(r);
    const quoted = r.list.commands[0].text;
    // TD sets the leading to 20, which " moves down by.
    try testing.expectApproxEqAbs(@as(f64, 50), quoted.tm.f, 1e-9);
    // Word spacing 3, character spacing 2: a (556), then the space (278).
    try testing.expectApproxEqAbs(@as(f64, 7.56), quoted.glyphs[1].x, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 7.56 + 2.78 + 2 + 3), quoted.glyphs[2].x, 1e-9);
    const adjusted = r.list.commands[1].text;
    try testing.expectEqual(@as(f64, 4), adjusted.rise);
    // (5.56 + 2) * 0.5, then the adjustment of 10 * 0.5.
    try testing.expectApproxEqAbs(@as(f64, 3.78 + 5), adjusted.glyphs[1].x, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 30), r.list.commands[2].text.tm.f, 1e-9);
}

test "ToUnicode wins over a simple font's encoding" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const text = "1 beginbfchar <41> <005A> endbfchar";
    const r = try render(try page(arena.allocator(), "BT /F1 10 Tf (AB) Tj ET", helv, &.{
        "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding /ToUnicode 6 0 R >>",
        try std.fmt.allocPrint(arena.allocator(), "<< /Length {d} >>\nstream\n{s}\nendstream", .{ text.len, text }),
    }, ""));
    defer done(r);
    const glyphs = r.list.commands[0].text.glyphs;
    try testing.expectEqualStrings("Z", glyphs[0].text);
    try testing.expectEqualStrings("B", glyphs[1].text);
}

test "a form uses its own resources and is clipped to its bounding box" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const body = "/C cs 1 sc 0 0 50 50 re f";
    const r = try render(try page(a, "/F Do", "/XObject << /F 5 0 R >> /ColorSpace << /C [/Indexed /DeviceRGB 1 <000000FF0000>] >>", &.{
        try std.fmt.allocPrint(a, "<< /Subtype /Form /BBox [1 2 30 40] /Resources << /ColorSpace << /C [/Indexed /DeviceRGB 1 <0000000000FF>] >> >> /Length {d} >>\nstream\n{s}\nendstream", .{ body.len, body }),
    }, ""));
    defer done(r);
    const clip = r.list.commands[1].clip.path;
    try testing.expectEqual(display.Point{ .x = 1, .y = 2 }, clip[0].move);
    try testing.expectEqual(display.Point{ .x = 30, .y = 2 }, clip[1].line);
    try testing.expectEqual(display.Point{ .x = 30, .y = 40 }, clip[2].line);
    try testing.expectEqual(display.Point{ .x = 1, .y = 40 }, clip[3].line);
    const fill = r.list.commands[2].fill;
    try testing.expectEqual(@as(f32, 1), fill.paint.color.b);
    try testing.expectEqual(@as(f32, 0), fill.paint.color.r);
}

test "optional content: the right layer is hidden, for content, XObjects, annotations and BaseState" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Layer 5 (/A) and layer 6 (/B). Squares of different sizes say which show.
    const form = "<< /Subtype /Form /BBox [0 0 9 9] /OC 6 0 R /Length 12 >>\nstream\n0 0 3 3 re f\nendstream";
    const appearance = "<< /Subtype /Form /BBox [0 0 9 9] /Length 12 >>\nstream\n0 0 4 4 re f\nendstream";
    const content = "/OC /A BDC 0 0 1 1 re f EMC /OC /B BDC 0 0 2 2 re f EMC /F Do";
    for ([_]struct { config: []const u8, shown: []const f64 }{
        .{ .config = "/OFF [6 0 R]", .shown = &.{1} },
        .{ .config = "/OFF [5 0 R]", .shown = &.{ 2, 3, 4 } },
        .{ .config = "/BaseState /OFF /ON [6 0 R]", .shown = &.{ 2, 3, 4 } },
    }) |case| {
        const bytes = try buildFile(a, &.{
            try std.fmt.allocPrint(a, "<< /Type /Catalog /Pages 2 0 R /OCProperties << /OCGs [5 0 R 6 0 R] /D << {s} >> >> >>", .{case.config}),
            "<< /Type /Pages /Kids [3 0 R] >>",
            "<< /Type /Page /MediaBox [0 0 100 100] /Contents 4 0 R /Annots [9 0 R] /Resources << /Properties << /A 5 0 R /B 6 0 R >> /XObject << /F 7 0 R >> >> >>",
            try std.fmt.allocPrint(a, "<< /Length {d} >>\nstream\n{s}\nendstream", .{ content.len, content }),
            "<< /Type /OCG >>",
            "<< /Type /OCG >>",
            form,
            appearance,
            "<< /Subtype /Square /Rect [0 0 9 9] /OC 6 0 R /AP << /N 8 0 R >> >>",
        });
        const r = try render(bytes);
        defer done(r);
        try testing.expect(!r.doc.repaired);
        var shown: std.ArrayList(f64) = .empty;
        for (r.list.commands) |c| if (c == .fill) try shown.append(a, c.fill.path[1].line.x);
        try testing.expectEqualSlices(f64, case.shown, shown.items);
    }
}

test "paths, clips and dashes carry their coordinates and rules" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = try render(try page(arena.allocator(), "[4 2.5] 1 d 10 20 100 50 re S 1 2 3 4 re W n 0 0 m 1 2 3 4 v 5 6 7 8 y h f 0 0 9 9 re W* n", "", &.{}, ""));
    defer done(r);
    const stroke = r.list.commands[0].stroke;
    try testing.expectEqualSlices(f64, &.{ 4, 2.5 }, stroke.style.dash);
    try testing.expectEqual(display.Point{ .x = 10, .y = 20 }, stroke.path[0].move);
    try testing.expectEqual(display.Point{ .x = 110, .y = 70 }, stroke.path[2].line);
    const clip = r.list.commands[1].clip;
    try testing.expectEqual(display.FillRule.nonzero, clip.rule);
    try testing.expectEqual(display.Point{ .x = 4, .y = 6 }, clip.path[2].line);
    const curves = r.list.commands[2].fill.path;
    // v: the current point is the first control point. y: the end is the second.
    try testing.expectEqual(display.Point{ .x = 0, .y = 0 }, curves[1].curve.c1);
    try testing.expectEqual(display.Point{ .x = 1, .y = 2 }, curves[1].curve.c2);
    try testing.expectEqual(display.Point{ .x = 7, .y = 8 }, curves[2].curve.c2);
    try testing.expectEqual(display.Point{ .x = 7, .y = 8 }, curves[2].curve.p);
    try testing.expectEqual(display.FillRule.even_odd, r.list.commands[3].clip.rule);
}

test "every page rotation puts the crop box on the displayed page" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // Crop box 100 x 50 with its lower left corner at (10, 10). For each
    // rotation, where that corner lands.
    for ([_]struct { rotate: u16, x: f64, y: f64, width: f64 }{
        .{ .rotate = 0, .x = 0, .y = 50, .width = 100 },
        .{ .rotate = 90, .x = 0, .y = 0, .width = 50 },
        .{ .rotate = 180, .x = 100, .y = 0, .width = 100 },
        .{ .rotate = 270, .x = 50, .y = 100, .width = 50 },
    }) |c| {
        const r = try render(try page(arena.allocator(), "", "", &.{}, try std.fmt.allocPrint(arena.allocator(), "/Rotate {d} /CropBox [10 10 110 60]", .{c.rotate})));
        defer done(r);
        try testing.expectEqual(c.width, r.list.width);
        const p = r.list.base.apply(10, 10);
        try testing.expectEqual(c.x, p.x);
        try testing.expectEqual(c.y, p.y);
        // The whole crop box stays on the page.
        const far = r.list.base.apply(110, 60);
        try testing.expect(far.x >= 0 and far.x <= r.list.width and far.y >= 0 and far.y <= r.list.height);
    }
}

test "layout: out-of-order runs are sorted, and a selection over two lines gives two rectangles" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try render(try page(a, "BT /F1 10 Tf 1 0 0 1 60 80 Tm (two) Tj 1 0 0 1 20 80 Tm (one) Tj 1 0 0 1 20 60 Tm (three) Tj ET", helv, &.{helv_obj}, ""));
    defer done(r);
    var lay = try pdf.text.layout(a, &r.list);
    try testing.expectEqualStrings("one two\nthree\n", lay.text);
    var rects: std.ArrayList(pdf.text.Rect) = .empty;
    try lay.rectsFor(a, 0, @intCast(lay.text.len), &rects);
    try testing.expectEqual(@as(usize, 2), rects.items.len);
    try testing.expect(rects.items[0].y1 <= rects.items[1].y0 + 1);
    try testing.expectEqualStrings("two one\nthree\n", try pdf.text.extract(a, &r.list, .content));
}

test "a matrix times its inverse is the identity in every component" {
    const m: display.Matrix = .{ .a = 2, .b = 1, .c = -3, .d = 4, .e = 5, .f = -6 };
    for ([_]display.Matrix{ m.mul(m.invert().?), m.invert().?.mul(m) }) |i| {
        for ([_][2]f64{ .{ i.a, 1 }, .{ i.b, 0 }, .{ i.c, 0 }, .{ i.d, 1 }, .{ i.e, 0 }, .{ i.f, 0 } }) |pair| try testing.expectApproxEqAbs(pair[1], pair[0], 1e-12);
    }
}

test "graphics state dictionaries, patterns, radial shadings and annotation states" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const square = "<< /Subtype /Form /BBox [0 0 9 9] /Length 12 >>\nstream\n0 0 7 7 re f\nendstream";
    const other = "<< /Subtype /Form /BBox [0 0 9 9] /Length 12 >>\nstream\n0 0 8 8 re f\nendstream";
    const r = try render(try page(a, "/G gs 0 0 1 1 re B /Pattern cs /P scn 0 0 2 2 re f /S sh", "/ExtGState << /G << /LW 7 /LC 1 /LJ 2 /ML 3 /ca 0.25 /CA 0.5 /BM /Screen /D [[5] 2] >> >> /Pattern << /P 5 0 R >> /Shading << /S 6 0 R >>", &.{
        "<< /PatternType 1 /PaintType 1 /BBox [0 0 2 3] /XStep 4 /YStep 5 /Matrix [1 0 0 1 6 7] /Length 12 >>\nstream\n0 0 1 1 re f\nendstream",
        // Two one-output functions, a background and a bounding box.
        "<< /ShadingType 3 /ColorSpace /DeviceRGB /Coords [1 2 3 4 5 6] /Background [0 1 0] /BBox [0 0 5 5] /Function [<< /FunctionType 2 /Domain [0 1] /C0 [1] /C1 [0] >> << /FunctionType 2 /Domain [0 1] /C0 [0] /C1 [0] >> << /FunctionType 2 /Domain [0 1] /C0 [0] /C1 [1] >>] >>",
        // Hidden, NoView, and one that shows the state /AS names.
        "<< /Subtype /Square /F 2 /Rect [0 0 9 9] /AP << /N 10 0 R >> >>",
        "<< /Subtype /Square /F 32 /Rect [0 0 9 9] /AP << /N 10 0 R >> >>",
        "<< /Subtype /Widget /Rect [0 0 9 9] /AS /On /AP << /N << /On 10 0 R /Off 11 0 R >> >> >>",
        square,
        other,
    }, "/Annots [7 0 R 8 0 R 9 0 R]"));
    defer done(r);
    const fill = r.list.commands[0].fill;
    const stroke = r.list.commands[1].stroke;
    try testing.expectEqual(@as(f64, 0.25), fill.alpha);
    try testing.expectEqual(@as(f64, 0.5), stroke.alpha);
    try testing.expectEqualStrings("Screen", fill.blend);
    try testing.expectEqual(@as(f64, 7), stroke.style.width);
    try testing.expectEqual(display.Cap.round, stroke.style.cap);
    try testing.expectEqual(display.Join.bevel, stroke.style.join);
    try testing.expectEqual(@as(f64, 3), stroke.style.miter_limit);
    try testing.expectEqualSlices(f64, &.{5}, stroke.style.dash);
    const tiling = r.list.commands[2].fill.paint.tiling;
    try testing.expectEqual([4]f64{ 0, 0, 2, 3 }, tiling.bbox);
    try testing.expectEqual(@as(f64, 4), tiling.xstep);
    try testing.expectEqual(@as(f64, 5), tiling.ystep);
    try testing.expectEqual(@as(f64, 6), tiling.matrix.e);
    try testing.expectEqual(@as(usize, 1), tiling.cell.commands.len);
    const shading = r.list.commands[3].shading.shading;
    try testing.expectEqual(display.ShadingKind.radial, shading.kind);
    try testing.expectEqual([6]f64{ 1, 2, 3, 4, 5, 6 }, shading.coords);
    try testing.expectEqual(@as(f32, 1), shading.stops[0].color.r);
    try testing.expectEqual(@as(f32, 1), shading.stops[shading.stops.len - 1].color.b);
    try testing.expectEqual(@as(f32, 1), shading.background.?.g);
    try testing.expect(shading.bbox != null);
    var annotation_squares: usize = 0;
    for (r.list.commands[4..]) |c| if (c == .fill) {
        try testing.expectEqual(@as(f64, 7), c.fill.path[1].line.x);
        annotation_squares += 1;
    };
    try testing.expectEqual(@as(usize, 1), annotation_squares);
}
