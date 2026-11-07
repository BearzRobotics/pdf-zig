//! Tests of `Document` on small PDFs built in memory.

const std = @import("std");
const pdf = @import("root.zig");
const testing = std.testing;
const Allocator = std.mem.Allocator;

/// A PDF with the given object bodies (object 1 is `bodies[0]`), a classic
/// cross-reference table and a trailer naming object 1 as the catalog.
fn build(a: Allocator, bodies: []const []const u8) ![]u8 {
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

const simple = [_][]const u8{
    "<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 100] >>",
};

test "a simple file" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const bytes = try build(arena.allocator(), &simple);
    var doc = try pdf.Document.open(testing.allocator, bytes, .{});
    defer doc.deinit();
    try testing.expect(!doc.repaired);
    const cat = doc.catalog().?;
    try testing.expectEqualStrings("Catalog", doc.getName(cat, "Type").?);
    const pages = doc.getDict(cat, "Pages").?;
    try testing.expectEqual(@as(i64, 1), doc.getInt(pages, "Count").?);
    const page = doc.getObject(3).asDict().?;
    try testing.expectEqual(@as(usize, 4), doc.getArray(page, "MediaBox").?.len);
    // A reference to an object that does not exist is null (7.3.9).
    try testing.expect(doc.getObject(99) == .null);
    try testing.expect(doc.getObject(0) == .null);
}

test "streams: direct length, wrong length, indirect length" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const bytes = try build(arena.allocator(), &.{
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [] /Count 0 >>",
        "<< /Length 5 >>\nstream\nhello\nendstream",
        "<< /Length 99 >>\nstream\nworld\nendstream", // too long: scan for endstream
        "<< /Length 6 0 R >>\nstream\r\nthere\r\nendstream",
        "5",
        "<< /Length 4 0 R >>\nstream\nloop\nendstream", // length refers to another stream: not an integer
    });
    var doc = try pdf.Document.open(testing.allocator, bytes, .{});
    defer doc.deinit();
    try testing.expectEqualStrings("hello", doc.getObject(3).stream.data);
    try testing.expectEqualStrings("world", doc.getObject(4).stream.data);
    try testing.expectEqualStrings("there", doc.getObject(5).stream.data);
    try testing.expectEqualStrings("loop", doc.getObject(7).stream.data);
}

test "incremental update: the newest version of an object wins" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const first = try build(a, &.{
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [] /Count 0 >>",
        "(old)",
    });
    const prev = std.mem.lastIndexOf(u8, first, "xref\n0 4").?;
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, first);
    const new_at = out.items.len;
    try out.appendSlice(a, "3 0 obj\n(new)\nendobj\n");
    const xref_at = out.items.len;
    try out.print(a, "xref\n3 1\n{d:0>10} 00000 n \ntrailer\n<< /Size 4 /Root 1 0 R /Prev {d} >>\nstartxref\n{d}\n%%EOF\n", .{ new_at, prev, xref_at });
    var doc = try pdf.Document.open(testing.allocator, out.items, .{});
    defer doc.deinit();
    try testing.expect(!doc.repaired);
    try testing.expectEqualStrings("new", doc.getObject(3).string);
    try testing.expectEqualStrings("Catalog", doc.getName(doc.catalog().?, "Type").?);
}

test "a loop in the /Prev chain ends" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = try build(a, &simple);
    const at = std.mem.lastIndexOf(u8, base, "xref\n0 4").?;
    const patched = try std.mem.replaceOwned(u8, a, base, "/Root 1 0 R >>", try std.fmt.allocPrint(a, "/Root 1 0 R /Prev {d} >>", .{at}));
    var doc = try pdf.Document.open(testing.allocator, patched, .{});
    defer doc.deinit();
    try testing.expect(doc.catalog() != null);
}

test "cross-reference stream and object stream" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Object stream 4 holds objects 1 (catalog), 2 (pages) and 3 (a page).
    const objs = "<< /Type /Catalog /Pages 2 0 R >> << /Type /Pages /Kids [3 0 R] /Count 1 >> << /Type /Page /Parent 2 0 R >>";
    const o1 = "<< /Type /Catalog /Pages 2 0 R >>".len;
    const o2 = "<< /Type /Pages /Kids [3 0 R] /Count 1 >>".len;
    const header = try std.fmt.allocPrint(a, "1 0 2 {d} 3 {d} ", .{ o1 + 1, o1 + 1 + o2 + 1 });
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, "%PDF-1.5\n");
    const stm_at = out.items.len;
    try out.print(a, "4 0 obj\n<< /Type /ObjStm /N 3 /First {d} /Length {d} >>\nstream\n{s}{s}\nendstream\nendobj\n", .{ header.len, header.len + objs.len, header, objs });
    const xs_at = out.items.len;
    // W [1 2 1]: type, offset or stream number, generation or index. Objects 0..5.
    const rows = [_][4]u8{
        .{ 0, 0, 0, 255 }, // 0 free
        .{ 2, 0, 4, 0 }, // 1 in stream 4, index 0
        .{ 2, 0, 4, 1 }, // 2
        .{ 2, 0, 4, 2 }, // 3
        .{ 1, @intCast(stm_at >> 8), @intCast(stm_at & 255), 0 }, // 4 the object stream
        .{ 1, @intCast(xs_at >> 8), @intCast(xs_at & 255), 0 }, // 5 this xref stream
    };
    var table: [24]u8 = undefined;
    for (rows, 0..) |r, i| @memcpy(table[i * 4 .. i * 4 + 4], &r);
    try out.print(a, "5 0 obj\n<< /Type /XRef /Size 6 /W [1 2 1] /Root 1 0 R /Length 24 >>\nstream\n", .{});
    try out.appendSlice(a, &table);
    try out.print(a, "\nendstream\nendobj\nstartxref\n{d}\n%%EOF\n", .{xs_at});
    var doc = try pdf.Document.open(testing.allocator, out.items, .{});
    defer doc.deinit();
    try testing.expect(!doc.repaired);
    const cat = doc.catalog().?;
    try testing.expectEqualStrings("Catalog", doc.getName(cat, "Type").?);
    const page = doc.getObject(3).asDict().?;
    try testing.expectEqualStrings("Page", doc.getName(page, "Type").?);
    try testing.expect(doc.xref.get(3).? == .compressed);
}

test "repair: wrong startxref, garbage offsets, truncated tail" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const good = try build(a, &simple);

    // startxref points into the middle of nowhere.
    const bad_start = try std.mem.replaceOwned(u8, a, good, "startxref\n", "startxref\n9");
    var d1 = try pdf.Document.open(testing.allocator, bad_start, .{});
    defer d1.deinit();
    try testing.expect(d1.repaired);
    try testing.expect(d1.catalog() != null);
    try testing.expect(d1.getObject(3).asDict() != null);

    // The table claims wrong offsets for every object.
    const bad_offsets = try std.mem.replaceOwned(u8, a, good, "0000000009 00000 n", "0000000777 00000 n");
    var d2 = try pdf.Document.open(testing.allocator, bad_offsets, .{});
    defer d2.deinit();
    try testing.expect(d2.catalog() != null);
    try testing.expect(d2.getObject(2).asDict() != null);

    // The file is cut off before the table and trailer: the catalog is found by type.
    const cut = good[0..std.mem.indexOf(u8, good, "xref\n").?];
    var d3 = try pdf.Document.open(testing.allocator, cut, .{});
    defer d3.deinit();
    try testing.expect(d3.repaired);
    try testing.expectEqualStrings("Catalog", d3.getName(d3.catalog().?, "Type").?);
}

test "junk before the header shifts offsets" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const good = try build(a, &simple);
    const shifted = try std.mem.concat(a, u8, &.{ "GARBAGE BEFORE THE HEADER\n", good });
    var doc = try pdf.Document.open(testing.allocator, shifted, .{});
    defer doc.deinit();
    try testing.expect(!doc.repaired);
    try testing.expectEqualStrings("Page", doc.getName(doc.getObject(3).asDict().?, "Type").?);
}

test "errors: not a PDF, no catalog, encrypted, too large" {
    try testing.expectError(error.NotPdf, pdf.Document.open(testing.allocator, "hello, world", .{}));
    try testing.expectError(error.NotPdf, pdf.Document.open(testing.allocator, "", .{}));
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectError(error.NoCatalog, pdf.Document.open(testing.allocator, try build(a, &.{"<< /Type /Pages >>"}), .{}));
    const enc = try std.mem.replaceOwned(u8, a, try build(a, &simple), "/Root 1 0 R >>", "/Root 1 0 R /Encrypt 3 0 R >>");
    try testing.expectError(error.Encrypted, pdf.Document.open(testing.allocator, enc, .{}));
    try testing.expectError(error.InputTooLarge, pdf.Document.open(testing.allocator, try build(a, &simple), .{ .max_bytes = 10 }));
}

test "openReader owns its bytes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const bytes = try build(arena.allocator(), &simple);
    var r: std.Io.Reader = .fixed(bytes);
    var doc = try pdf.Document.openReader(testing.allocator, &r, .{});
    defer doc.deinit();
    try testing.expect(doc.catalog() != null);
}

test "references that loop do not hang" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const bytes = try build(arena.allocator(), &.{
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [] /Count 0 >>",
        "4 0 R",
        "3 0 R",
        "<< /Self 5 0 R >>",
    });
    var doc = try pdf.Document.open(testing.allocator, bytes, .{});
    defer doc.deinit();
    try testing.expect(doc.resolve(.{ .ref = .{ .num = 3 } }) == .null);
    try testing.expect(doc.getObject(5).asDict() != null);
}

test "damaged files never crash (seeded mutation)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const good = try build(a, &.{
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        "<< /Type /Page /Parent 2 0 R /Contents 4 0 R /MediaBox [0 0 10 10] >>",
        "<< /Length 12 >>\nstream\n0 0 m 5 5 l\nendstream",
    });
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const rnd = prng.random();
    var i: usize = 0;
    while (i < 400) : (i += 1) {
        const copy = try a.dupe(u8, good);
        const flips = rnd.intRangeAtMost(usize, 1, 8);
        for (0..flips) |_| copy[rnd.uintLessThan(usize, copy.len)] = rnd.int(u8);
        const len = if (rnd.boolean()) copy.len else rnd.uintLessThan(usize, copy.len) + 1;
        var doc = pdf.Document.open(testing.allocator, copy[0..len], .{}) catch continue;
        defer doc.deinit();
        _ = doc.catalog();
        var n: u32 = 0;
        while (n < 6) : (n += 1) {
            const o = doc.getObject(n);
            if (o == .stream) _ = doc.streamData(o.stream) catch {};
        }
    }
}

test "page tree: inheritance, nesting, wrong counts, cycles" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const bytes = try build(arena.allocator(), &.{
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R 5 0 R 2 0 R] /Count 99 /MediaBox [0 0 300 400] /Rotate 90 /Resources << /Font << >> >> >>",
        "<< /Type /Pages /Parent 2 0 R /Kids [4 0 R] /Count 1 /MediaBox [0 0 100 50] >>",
        "<< /Type /Page /Parent 3 0 R >>",
        "<< /Type /Page /Parent 2 0 R /CropBox [50 50 5000 5000] /Rotate -90 >>",
    });
    var doc = try pdf.Document.open(testing.allocator, bytes, .{});
    defer doc.deinit();
    const list = try pdf.pages.PageList.build(&doc);
    try testing.expectEqual(@as(usize, 2), list.entries.len); // /Count 99 is ignored; the cycle (2 0 R) ends
    const p1 = pdf.pages.page(&doc, list, 0).?;
    try testing.expectEqual(@as(f64, 100), p1.media_box.width()); // nearest /MediaBox wins
    try testing.expectEqual(@as(u16, 90), p1.rotate); // inherited from the root
    try testing.expect(p1.resources.has("Font"));
    const s1 = p1.displaySize();
    try testing.expectEqual(@as(f64, 50), s1.w); // rotated: width and height swap
    const p2 = pdf.pages.page(&doc, list, 1).?;
    try testing.expectEqual(@as(u16, 270), p2.rotate); // -90 is 270
    try testing.expectEqual(@as(f64, 250), p2.crop_box.width()); // clipped to the media box
    try testing.expect(pdf.pages.page(&doc, list, 2) == null);
}

test "page contents: one stream, several streams, none" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const bytes = try build(arena.allocator(), &.{
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R 4 0 R 5 0 R] /Count 3 >>",
        "<< /Type /Page /Contents 6 0 R >>",
        "<< /Type /Page /Contents [6 0 R 7 0 R] >>",
        "<< /Type /Page >>",
        "<< /Length 3 >>\nstream\n0 g\nendstream",
        "<< /Length 6 >>\nstream\n1 0 0 RG\nendstream",
    });
    var doc = try pdf.Document.open(testing.allocator, bytes, .{});
    defer doc.deinit();
    const list = try pdf.pages.PageList.build(&doc);
    try testing.expectEqualStrings("0 g", try pdf.pages.contents(&doc, pdf.pages.page(&doc, list, 0).?));
    try testing.expectEqualStrings("0 g\n1 0 0 RG\n", try pdf.pages.contents(&doc, pdf.pages.page(&doc, list, 1).?));
    try testing.expectEqualStrings("", try pdf.pages.contents(&doc, pdf.pages.page(&doc, list, 2).?));
}

test "page resources given as an indirect object, inherited" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const bytes = try build(arena.allocator(), &.{
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 /Resources 5 0 R >>",
        "<< /Type /Page /Parent 2 0 R >>",
        "<< /Type /Page /Parent 2 0 R /Resources 6 0 R >>",
        "<< /Font << /F1 7 0 R >> >>",
        "<< /XObject << >> >>",
        "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
    });
    var doc = try pdf.Document.open(testing.allocator, bytes, .{});
    defer doc.deinit();
    const list = try pdf.pages.PageList.build(&doc);
    try testing.expect(pdf.pages.page(&doc, list, 0).?.resources.has("Font")); // inherited, through a reference
    try testing.expect(pdf.pages.page(&doc, list, 1).?.resources.has("XObject")); // its own, through a reference
}
