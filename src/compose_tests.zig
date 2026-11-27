// SPDX-License-Identifier: LGPL-2.0-or-later
//! Page operations: what `compose.Builder` writes is opened again and compared.

const std = @import("std");
const pdf = @import("root.zig");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Builder = pdf.compose.Builder;

/// A file with objects 1, 2, ... given by `bodies`; object 1 is the catalog.
/// It has no cross-reference table, so opening it repairs it.
fn file(a: Allocator, bodies: []const []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, "%PDF-1.7\n");
    for (bodies, 1..) |body, n| try out.print(a, "{d} 0 obj\n{s}\nendobj\n", .{ n, body });
    try out.appendSlice(a, "trailer\n<< /Root 1 0 R >>\n%%EOF\n");
    return out.items;
}

fn stream(a: Allocator, dict: []const u8, data: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "<< {s} /Length {d} >>\nstream\n{s}\nendstream", .{ dict, data.len, data });
}

/// Three pages that inherit their size and resources. Page 1 has links of
/// several kinds and a widget whose field has another widget on page 3.
fn sample(a: Allocator) ![]const u8 {
    return file(a, &.{
        // 1 to 2: the catalog and the root of the page tree.
        "<< /Type /Catalog /Pages 2 0 R /Names << /Dests << /Names [(third) [5 0 R /XYZ 10 90 0]] >> >> /AcroForm << /Fields [12 0 R] >> /Outlines << >> >>",
        "<< /Type /Pages /Kids [3 0 R 4 0 R 5 0 R] /Count 3 /MediaBox [0 0 200 100] /Resources 9 0 R >>",
        // 3 to 5: the pages.
        "<< /Type /Page /Parent 2 0 R /Contents 6 0 R /AA << /O << /S /JavaScript /JS (pageopen) >> >> /Annots [10 0 R 11 0 R 13 0 R 14 0 R << /Type /Annot /Subtype /Link /Rect [0 0 9 9] /Dest [4 0 R /Fit] >>] >>",
        "<< /Type /Page /Parent 2 0 R /Contents 7 0 R /Rotate 90 >>",
        "<< /Type /Page /Parent 2 0 R /Contents 8 0 R /CropBox [0 0 150 100] /Annots [15 0 R] >>",
        try stream(a, "", "BT /F1 10 Tf 10 50 Td (First page) Tj ET"),
        try stream(a, "", "BT /F1 10 Tf 10 50 Td (Second page) Tj ET"),
        try stream(a, "", "BT /F1 10 Tf 10 50 Td (Third page) Tj ET"),
        "<< /Font << /F1 16 0 R >> >>",
        // 10 and 11: a link by name and a web link.
        "<< /Type /Annot /Subtype /Link /Rect [10 10 20 20] /P 3 0 R /A << /S /GoTo /D (third) >> >>",
        "<< /Type /Annot /Subtype /Link /Rect [30 10 40 20] /A << /S /URI /URI (https://example.org/) /Next << /S /JavaScript /JS (chained) >> >> >>",
        // 12 to 15: a field with a widget on page 1 and one on page 3.
        "<< /FT /Tx /T (name) /V (fieldvalue) /Kids [13 0 R 15 0 R] >>",
        "<< /Type /Annot /Subtype /Widget /Rect [50 10 90 20] /Parent 12 0 R /P 3 0 R >>",
        "<< /Type /Annot /Subtype /Link /Rect [60 30 70 40] /A << /S /JavaScript /JS (linkscript) >> >>",
        "<< /Type /Annot /Subtype /Widget /Rect [50 10 90 20] /Parent 12 0 R /P 5 0 R >>",
        "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
    });
}

const Opened = struct {
    doc: pdf.Document,
    pages: pdf.pages.PageList,

    fn page(self: *Opened, i: usize) pdf.pages.Page {
        return pdf.pages.page(&self.doc, self.pages, i).?;
    }

    fn text(self: *Opened, a: Allocator, i: usize) ![]const u8 {
        var rend = pdf.Renderer.init(&self.doc, .{});
        defer rend.deinit();
        var dl = try rend.render(testing.allocator, self.page(i));
        defer dl.deinit();
        return pdf.text.extract(a, &dl, .reading);
    }
};

fn written(a: Allocator, b: *const Builder) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    try b.write(&out.writer);
    return out.written();
}

fn reopen(a: Allocator, bytes: []const u8) !Opened {
    var doc = try pdf.Document.open(a, bytes, .{});
    const list = try pdf.pages.PageList.build(&doc);
    // The output has to be good as it stands.
    try testing.expect(!doc.repaired);
    return .{ .doc = doc, .pages = list };
}

/// The pages of `sample` at `indices`, written out.
fn imported(a: Allocator, indices: []const usize) ![]const u8 {
    var doc = try pdf.Document.open(a, try sample(a), .{});
    var b = Builder.init(testing.allocator, .{});
    defer b.deinit();
    try b.importPages(&doc, indices, .{});
    // Nothing is borrowed from the source.
    doc.deinit();
    return written(a, &b);
}

fn has(bytes: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, bytes, needle) != null;
}

test "reordering keeps each page's content, size, rotation and resources" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bytes = try imported(a, &.{ 2, 0, 1 });
    var out = try reopen(a, bytes);
    try testing.expectEqual(@as(usize, 3), out.pages.entries.len);
    for ([_][]const u8{ "Third page\n", "First page\n", "Second page\n" }, 0..) |want, i| {
        try testing.expectEqualStrings(want, try out.text(a, i));
    }
    try testing.expectEqual(@as(f64, 150), out.page(0).crop_box.width());
    try testing.expectEqual(@as(f64, 200), out.page(0).media_box.width());
    try testing.expectEqual(@as(u16, 90), out.page(2).rotate);
    // The pages shared one resource dictionary and font, and still do.
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, bytes, "/BaseFont"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, bytes, "/Font <<"));
}

test "a page that is left out is not in the file, whatever refers to it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Page 1 links to pages 2 and 3, and shares a field with page 3.
    const bytes = try imported(a, &.{0});
    for ([_][]const u8{ "Second page", "Third page" }) |gone| try testing.expect(!has(bytes, gone));
    // No script comes along, nor an outline without a bookmark to keep.
    for ([_][]const u8{ "JavaScript", "pageopen", "linkscript", "chained", "Outlines", "/Names", "/AA" }) |gone| {
        try testing.expect(!has(bytes, gone));
    }
    var out = try reopen(a, bytes);
    try testing.expectEqual(@as(usize, 1), out.pages.entries.len);
    const links = try pdf.link.list(a, &out.doc, out.pages, out.page(0));
    try testing.expectEqual(@as(usize, 1), links.len);
    try testing.expectEqualStrings("https://example.org/", links[0].target.uri);
    // The annotations themselves are kept.
    try testing.expectEqual(@as(usize, 5), (try pdf.annot.list(a, &out.doc, out.page(0))).len);
}

test "links between pages imported together lead to their new places" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out = try reopen(a, try imported(a, &.{ 2, 1, 0 }));
    const links = try pdf.link.list(a, &out.doc, out.pages, out.page(2));
    try testing.expectEqual(@as(usize, 3), links.len);
    // By name, which became a direct destination.
    try testing.expectEqual(pdf.outline.Destination{ .page = 0, .x = 10, .y = 90 }, links[0].target.page);
    try testing.expectEqualStrings("https://example.org/", links[1].target.uri);
    // A direct annotation dictionary with a direct destination.
    try testing.expectEqual(@as(usize, 1), links[2].target.page.page);
    // `/P` names the page the annotation is now on.
    const first = out.doc.getArray(out.page(2).dict, "Annots").?[0];
    try testing.expectEqual(out.page(2).num, out.doc.resolve(first).asDict().?.get("P").?.ref.num);
}

test "blank pages, merging and rotation" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var one = try pdf.Document.open(a, try sample(a), .{});
    defer one.deinit();
    var two = try pdf.Document.open(a, @embedFile("plain.pdf"), .{});
    defer two.deinit();
    var b = Builder.init(testing.allocator, .{});
    defer b.deinit();
    try b.importPages(&one, &.{1}, .{});
    try b.addBlankPage(300, 400);
    try b.importPages(&two, &.{0}, .{});
    // A second call for the same page makes a copy of it.
    try b.importPages(&one, &.{1}, .{});
    try testing.expectEqual(@as(usize, 4), b.pageCount());
    try b.setRotation(0, 0);
    try b.setRotation(1, -90);
    const bytes = try written(a, &b);
    try testing.expectEqualSlices(u8, bytes, try written(a, &b));
    var out = try reopen(a, bytes);
    for ([_][]const u8{ "Second page\n", "", "Hello encrypted world\n", "Second page\n" }, 0..) |want, i| {
        try testing.expectEqualStrings(want, try out.text(a, i));
    }
    try testing.expectEqual(@as(u16, 0), out.page(0).rotate);
    try testing.expectEqual(@as(u16, 270), out.page(1).rotate);
    try testing.expectEqual(@as(u16, 90), out.page(3).rotate);
    try testing.expectEqual(@as(f64, 400), out.page(1).displaySize().w);

    // The result can be annotated like any document.
    var upd = try pdf.write.Update.init(testing.allocator, &out.doc);
    defer upd.deinit();
    _ = try pdf.annot.addNote(&upd, out.page(1), 5, 5, .{ .contents = "on a blank page" });
    var annotated: std.Io.Writer.Allocating = .init(a);
    try upd.write(testing.allocator, &annotated.writer);
    var again = try reopen(a, annotated.written());
    try testing.expectEqual(@as(usize, 1), (try pdf.annot.list(a, &again.doc, again.page(1))).len);
}

test "what cannot be done fails and adds nothing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try pdf.Document.open(a, try sample(a), .{});
    defer doc.deinit();
    var b = Builder.init(testing.allocator, .{});
    defer b.deinit();
    var sink: std.Io.Writer.Allocating = .init(a);
    try testing.expectError(error.NoPages, b.write(&sink.writer));
    try b.importPages(&doc, &.{1}, .{});
    const before = try written(a, &b);
    try testing.expectError(error.NoSuchPage, b.importPages(&doc, &.{ 0, 3 }, .{}));
    try testing.expectError(error.DuplicatePage, b.importPages(&doc, &.{ 0, 0 }, .{}));
    for ([_][2]f64{ .{ 0, 10 }, .{ 10, -1 }, .{ std.math.nan(f64), 10 }, .{ 10, std.math.inf(f64) } }) |size| {
        try testing.expectError(error.BadGeometry, b.addBlankPage(size[0], size[1]));
    }
    try testing.expectError(error.BadGeometry, b.setRotation(0, 45));
    try testing.expectError(error.NoSuchPage, b.setRotation(1, 90));
    try testing.expectEqualSlices(u8, before, try written(a, &b));
}

test "the size and object limits hold" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try pdf.Document.open(a, try sample(a), .{});
    defer doc.deinit();
    {
        var b = Builder.init(testing.allocator, .{ .max_bytes = 200 });
        defer b.deinit();
        try testing.expectError(error.TooLarge, b.importPages(&doc, &.{0}, .{}));
        try testing.expectEqual(@as(usize, 0), b.pageCount());
        try b.addBlankPage(10, 10);
        var sink: std.Io.Writer.Allocating = .init(a);
        try testing.expectError(error.TooLarge, b.write(&sink.writer));
    }
    var b = Builder.init(testing.allocator, .{ .max_objects = 6 });
    defer b.deinit();
    try testing.expectError(error.TooManyObjects, b.importPages(&doc, &.{0}, .{}));
}

test "an encrypted source is refused unless the caller allows an unencrypted copy" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]struct { []const u8, []const u8 }{
        .{ @embedFile("enc_rc4_40.pdf"), "" },
        .{ @embedFile("enc_rc4_128.pdf"), "" },
        .{ @embedFile("enc_aes_128.pdf"), "" },
        .{ @embedFile("enc_aes_256.pdf"), "" },
        .{ @embedFile("enc_aes_256_pw.pdf"), "pw" },
        .{ @embedFile("enc_aes_256_r5.pdf"), "" },
        .{ @embedFile("enc_aes_128_objstm.pdf"), "" },
        .{ @embedFile("enc_rc4_v4_clearmeta.pdf"), "" },
        .{ @embedFile("enc_aes_128_clearmeta.pdf"), "" },
    }) |case| {
        var doc = try pdf.Document.open(a, case[0], .{ .password = case[1] });
        defer doc.deinit();
        var b = Builder.init(testing.allocator, .{});
        defer b.deinit();
        try testing.expectError(error.Encrypted, b.importPages(&doc, &.{0}, .{}));
        try testing.expectEqual(@as(usize, 0), b.pageCount());
        try b.importPages(&doc, &.{0}, .{ .allow_decrypted_output = true });
        const bytes = try written(a, &b);
        try testing.expect(!has(bytes, "/Encrypt"));
        var out = try reopen(a, bytes);
        try testing.expect(out.doc.crypt == null);
        try testing.expectEqualStrings("Hello encrypted world\n", try out.text(a, 0));
    }
}

test "a stream's own crypt filter is not carried over" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try pdf.Document.open(a, try file(a, &.{
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 99 99] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
        try stream(a, "/Filter [/Crypt /ASCIIHexDecode] /DecodeParms [<< /Name /Identity >> null]", "42542f4631203130205466203130203530205464202868692920546a204554>"),
        "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
    }), .{});
    defer doc.deinit();
    var b = Builder.init(testing.allocator, .{});
    defer b.deinit();
    try b.importPages(&doc, &.{0}, .{});
    const bytes = try written(a, &b);
    try testing.expect(!has(bytes, "Crypt"));
    var out = try reopen(a, bytes);
    try testing.expectEqualStrings("hi\n", try out.text(a, 0));
}

test "layers keep their default state" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try pdf.Document.open(a, try file(a, &.{
        "<< /Type /Catalog /Pages 2 0 R /OCProperties << /OCGs [6 0 R 7 0 R 8 0 R] /D << /OFF [7 0 R] >> >> >>",
        "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 99 99] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> /Properties << /On 6 0 R /Off 7 0 R >> >> >>",
        try stream(a, "", "BT /F1 10 Tf 10 50 Td /OC /On BDC (shown) Tj EMC /OC /Off BDC 0 -20 Td (hidden) Tj EMC ET"),
        "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
        "<< /Type /OCG /Name (visible layer) >>",
        "<< /Type /OCG /Name (hidden layer) >>",
        "<< /Type /OCG /Name (unused layer) >>",
    }), .{});
    defer doc.deinit();
    var b = Builder.init(testing.allocator, .{});
    defer b.deinit();
    try b.importPages(&doc, &.{0}, .{});
    const bytes = try written(a, &b);
    try testing.expect(!has(bytes, "unused layer"));
    var out = try reopen(a, bytes);
    try testing.expectEqualStrings("shown\n", try out.text(a, 0));
    const props = out.doc.getDict(out.doc.catalog().?, "OCProperties").?;
    try testing.expectEqual(@as(usize, 2), out.doc.getArray(props, "OCGs").?.len);
}

test "references that lead to structure, nowhere or around in circles" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try pdf.Document.open(a, try file(a, &.{
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R] /Count 1 /Secret (treenode) >>",
        // The page names the catalog, the tree, itself, a missing object, a
        // cycle, and lists the page tree as an annotation.
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 99 99] /X [1 0 R 2 0 R 3 0 R 99 0 R 4 0 R] /Annots [2 0 R 3 0 R 42] >>",
        "<< /Next 5 0 R >>",
        "<< /Next 4 0 R >>",
    }), .{});
    defer doc.deinit();
    var b = Builder.init(testing.allocator, .{});
    defer b.deinit();
    try b.importPages(&doc, &.{0}, .{});
    const bytes = try written(a, &b);
    try testing.expect(!has(bytes, "treenode"));
    var out = try reopen(a, bytes);
    const x = out.doc.getArray(out.page(0).dict, "X").?;
    try testing.expect(x[0] == .null and x[1] == .null and x[3] == .null);
    try testing.expectEqual(out.page(0).num, x[2].ref.num);
    try testing.expect(x[4] == .ref);
    try testing.expect(!out.page(0).dict.has("Annots"));
}

fn importUnderAllocationFailure(gpa: Allocator, bytes: []const u8) !void {
    var doc = try pdf.Document.open(gpa, bytes, .{});
    defer doc.deinit();
    var b = Builder.init(gpa, .{});
    defer b.deinit();
    try b.importPages(&doc, &.{ 0, 2 }, .{});
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try b.write(&out.writer);
    // A failed allocation must not have turned into a missing object.
    try testing.expect(has(out.written(), "First page") and has(out.written(), "/BaseFont") and has(out.written(), "https://example.org/"));
}

test "every failed allocation is reported" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.checkAllAllocationFailures(testing.allocator, importUnderAllocationFailure, .{try sample(arena.allocator())});
}

test "a left-out page without a /Type is still not copied" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try pdf.Document.open(a, try file(a, &.{
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 /MediaBox [0 0 99 99] >>",
        "<< /Type /Page /Parent 2 0 R /Annots [<< /Subtype /Link /Rect [0 0 9 9] /Dest [4 0 R /Fit] >>] /X 4 0 R >>",
        "<< /Parent 2 0 R /Y (untypedpage) >>",
    }), .{});
    defer doc.deinit();
    var b = Builder.init(testing.allocator, .{});
    defer b.deinit();
    try b.importPages(&doc, &.{0}, .{});
    try testing.expect(!has(try written(a, &b), "untypedpage"));
}

test "pages that share large direct objects stay within the size limit" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // 200 pages name one annotation array of 200 direct dictionaries.
    var kids: std.ArrayList(u8) = .empty;
    for (0..200) |i| try kids.print(a, "{d} 0 R ", .{i + 4});
    var annots: std.ArrayList(u8) = .empty;
    try annots.append(a, '[');
    for (0..200) |_| try annots.appendSlice(a, "<< /Subtype /Square /Rect [0 0 1 1] >> ");
    try annots.append(a, ']');
    var bodies: std.ArrayList([]const u8) = .empty;
    try bodies.append(a, "<< /Type /Catalog /Pages 2 0 R >>");
    try bodies.append(a, try std.fmt.allocPrint(a, "<< /Type /Pages /Kids [{s}] /Count 200 /MediaBox [0 0 9 9] >>", .{kids.items}));
    try bodies.append(a, annots.items);
    for (0..200) |_| try bodies.append(a, "<< /Type /Page /Parent 2 0 R /Annots 3 0 R >>");
    var doc = try pdf.Document.open(a, try file(a, bodies.items), .{});
    defer doc.deinit();
    var indices: [200]usize = undefined;
    for (&indices, 0..) |*v, i| v.* = i;

    var counting: std.testing.FailingAllocator = .init(testing.allocator, .{});
    var b = Builder.init(counting.allocator(), .{ .max_bytes = 64 << 10 });
    defer b.deinit();
    try testing.expectError(error.TooLarge, b.importPages(&doc, &indices, .{}));
    // What was requested stays near the limit, not near the 1.6 MB of output.
    try testing.expect(counting.allocated_bytes < 1 << 20);
    try testing.expectEqual(@as(usize, 0), b.pageCount());
}

/// Two pages; page 1 has `links` links to the name `last`, which `tree` holds.
fn namedLinks(a: Allocator, links: usize, tree: []const []const u8) ![]const u8 {
    var annots: std.ArrayList(u8) = .empty;
    for (0..links) |_| try annots.appendSlice(a, "<< /Subtype /Link /Rect [0 0 1 1] /Dest (last) >> ");
    var bodies: std.ArrayList([]const u8) = .empty;
    try bodies.append(a, "<< /Type /Catalog /Pages 2 0 R /Names << /Dests 5 0 R >> >>");
    try bodies.append(a, "<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 /MediaBox [0 0 9 9] >>");
    try bodies.append(a, try std.fmt.allocPrint(a, "<< /Type /Page /Parent 2 0 R /Annots [{s}] >>", .{annots.items}));
    try bodies.append(a, "<< /Type /Page /Parent 2 0 R >>");
    try bodies.appendSlice(a, tree);
    return file(a, bodies.items);
}

fn expectNamedLinks(a: Allocator, bytes: []const u8, links: usize) !void {
    var doc = try pdf.Document.open(a, bytes, .{});
    defer doc.deinit();
    var b = Builder.init(testing.allocator, .{});
    defer b.deinit();
    try b.importPages(&doc, &.{ 0, 1 }, .{});
    var out = try reopen(a, try written(a, &b));
    const items = out.doc.getArray(out.page(0).dict, "Annots").?;
    try testing.expectEqual(links, items.len);
    for (items) |item| try testing.expect(out.doc.resolve(item).asDict().?.has("Dest"));
}

test "every link by name is kept, however badly the name tree is built" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // 2000 leaves in a row without /Limits: finding the last takes 2000 steps,
    // and 3000 links to it six million.
    var kids: std.ArrayList(u8) = .empty;
    for (0..2000) |i| try kids.print(a, "<< /Names [(k{d}) [3 0 R /Fit]] >> ", .{i});
    const tree = try std.fmt.allocPrint(a, "<< /Kids [{s}<< /Names [(last) [4 0 R /Fit]] >>] >>", .{kids.items});
    try expectNamedLinks(a, try namedLinks(a, 3000, &.{tree}), 3000);
}

test "an attachment encrypted in a way that is not read is not copied as noise" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]bool{ false, true }) |own_filter| {
        var doc = try pdf.Document.open(a, @embedFile("enc_aes_128.pdf"), .{});
        defer doc.deinit();
        const kept = doc.arena.allocator();
        // No fixture has an attachment, so the page's contents are made to
        // call themselves one.
        const list = try pdf.pages.PageList.build(&doc);
        const num = pdf.pages.page(&doc, list, 0).?.dict.get("Contents").?.ref.num;
        var contents = doc.getObject(num).stream;
        contents.dict = try pdf.write.dictWith(kept, contents.dict, "Type", .{ .name = "EmbeddedFile" });
        try doc.cache.put(kept, num, .{ .stream = contents });
        if (own_filter) doc.encrypt_dict = try pdf.write.dictWith(kept, doc.encrypt_dict, "EFF", .{ .name = "Identity" });
        var b = Builder.init(testing.allocator, .{});
        defer b.deinit();
        const result = b.importPages(&doc, &.{0}, .{ .allow_decrypted_output = true });
        if (own_filter) try testing.expectError(error.UnsupportedFilter, result) else try result;
    }
}

/// Two pages with a form and bookmarks. Fields: a group `who` holding `name`
/// (a widget on each page), a check box on page 2, and a signature on page 1.
/// The font `F1` of the form has its default appearance in an object.
fn formSample(a: Allocator, value: []const u8) ![]const u8 {
    return file(a, &.{
        "<< /Type /Catalog /Pages 2 0 R /AcroForm 5 0 R /Outlines 15 0 R /Names << /Dests << /Names [(two) [4 0 R /FitH 50]] >> >> >>",
        "<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 /MediaBox [0 0 200 100] >>",
        "<< /Type /Page /Parent 2 0 R /Annots [8 0 R 11 0 R] >>",
        "<< /Type /Page /Parent 2 0 R /Annots [9 0 R 10 0 R] >>",
        "<< /Fields [6 0 R 10 0 R 11 0 R] /DR << /Font << /F1 13 0 R >> >> /DA 14 0 R /Q 1 /CO [6 0 R] /XFA (xfadata) /SigFlags 3 >>",
        // 6 to 9: the group, its field and the field's two widgets.
        "<< /T (who) /Kids [7 0 R] /AA << /C << /S /JavaScript /JS (calc) >> >> >>",
        try std.fmt.allocPrint(a, "<< /FT /Tx /T (name) /Parent 6 0 R /V ({s}) /Kids [8 0 R 9 0 R] >>", .{value}),
        "<< /Type /Annot /Subtype /Widget /Rect [10 70 90 90] /Parent 7 0 R /P 3 0 R >>",
        "<< /Type /Annot /Subtype /Widget /Rect [10 40 90 60] /Parent 7 0 R /P 4 0 R /MK << /CA (secondwidget) >> >>",
        "<< /Type /Annot /Subtype /Widget /FT /Btn /T (agree) /V /Off /Rect [10 10 20 20] >>",
        "<< /Type /Annot /Subtype /Widget /FT /Sig /T (signed) /V 12 0 R /Rect [100 10 190 30] >>",
        "<< /Type /Sig /Contents (signaturebytes) >>",
        "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
        "(/F1 9 Tf 0 g)",
        // 15 to 20: the bookmarks.
        "<< /Type /Outlines /First 16 0 R /Last 19 0 R /Count 4 >>",
        "<< /Title (Chapter) /Parent 15 0 R /Next 19 0 R /First 17 0 R /Last 18 0 R /Count -2 /C [1 0 0] /F 2 >>",
        "<< /Title (Section on two) /Parent 16 0 R /Next 18 0 R /Dest (two) >>",
        "<< /Title (Website) /Parent 16 0 R /Prev 17 0 R /A << /S /URI /URI (https://example.org/) >> >>",
        "<< /Title (Start) /Parent 15 0 R /Prev 16 0 R /A << /S /GoTo /D [3 0 R /XYZ 0 100 0] >> >>",
    });
}

fn fieldNamed(fields: []const pdf.form.Field, name: []const u8) ?pdf.form.Field {
    for (fields) |f| if (std.mem.eql(u8, f.name, name)) return f;
    return null;
}

test "forms stay fillable, with only the widgets of imported pages" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try pdf.Document.open(a, try formSample(a, "Ada"), .{});
    defer doc.deinit();
    var b = Builder.init(testing.allocator, .{});
    defer b.deinit();
    try b.importPages(&doc, &.{0}, .{});
    const bytes = try written(a, &b);
    for ([_][]const u8{ "secondwidget", "signaturebytes", "xfadata", "JavaScript", "/CO ", "SigFlags", "agree" }) |gone| {
        try testing.expect(!has(bytes, gone));
    }
    var out = try reopen(a, bytes);
    const fields = try pdf.form.fields(a, &out.doc, out.pages);
    try testing.expectEqual(@as(usize, 2), fields.len);
    const name = fieldNamed(fields, "who.name").?;
    try testing.expectEqualStrings("Ada", name.value);
    try testing.expectEqual(@as(usize, 1), name.widgets.len);
    try testing.expectEqual(@as(?usize, 0), name.widgets[0].page);
    try testing.expectEqualStrings("", fieldNamed(fields, "signed").?.value);
    // What the form dictionary supplied is on the top level fields.
    const form = out.doc.getDict(out.doc.catalog().?, "AcroForm").?;
    const root = out.doc.resolve(out.doc.getArray(form, "Fields").?[0]).asDict().?;
    try testing.expectEqualStrings("/F1 9 Tf 0 g", out.doc.get(root, "DA").?.string);
    try testing.expectEqual(@as(i64, 1), out.doc.getInt(root, "Q").?);

    // And it can be filled.
    var upd = try pdf.write.Update.init(testing.allocator, &out.doc);
    defer upd.deinit();
    try pdf.form.setText(&upd, name, "Grace");
    var filled: std.Io.Writer.Allocating = .init(a);
    try upd.write(testing.allocator, &filled.writer);
    var again = try reopen(a, filled.written());
    try testing.expectEqualStrings("Grace", fieldNamed(try pdf.form.fields(a, &again.doc, again.pages), "who.name").?.value);
    try testing.expectEqualStrings("Grace\n", try again.text(a, 0));
}

test "merged forms keep their fields apart, and their fonts" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var one = try pdf.Document.open(a, try formSample(a, "first"), .{});
    defer one.deinit();
    var two = try pdf.Document.open(a, try formSample(a, "second"), .{});
    defer two.deinit();
    var b = Builder.init(testing.allocator, .{});
    defer b.deinit();
    try b.importPages(&one, &.{ 0, 1 }, .{});
    try b.importPages(&two, &.{ 0, 1 }, .{});
    var out = try reopen(a, try written(a, &b));
    const fields = try pdf.form.fields(a, &out.doc, out.pages);
    try testing.expectEqual(@as(usize, 6), fields.len);
    for ([_][]const u8{ "who.name", "agree", "signed", "who_2.name", "agree_2", "signed_2" }) |name| {
        try testing.expect(fieldNamed(fields, name) != null);
    }
    const second = fieldNamed(fields, "who_2.name").?;
    try testing.expectEqualStrings("second", second.value);
    try testing.expectEqual(@as(usize, 2), second.widgets.len);
    try testing.expectEqual(@as(?usize, 2), second.widgets[0].page);
    try testing.expectEqual(@as(?usize, 3), second.widgets[1].page);
    const form = out.doc.getDict(out.doc.catalog().?, "AcroForm").?;
    const font_names = out.doc.getDict(out.doc.getDict(form, "DR").?, "Font").?;
    try testing.expect(font_names.has("F1") and font_names.has("F1_2"));
    const roots = out.doc.getArray(form, "Fields").?;
    var renamed_font = false;
    for (roots) |r| {
        const d = out.doc.resolve(r).asDict().?;
        if (std.mem.eql(u8, out.doc.get(d, "T").?.string, "who_2")) renamed_font = std.mem.eql(u8, out.doc.get(d, "DA").?.string, "/F1_2 9 Tf 0 g");
    }
    try testing.expect(renamed_font);
}

test "bookmarks that lead to imported pages are kept, under their headings" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try pdf.Document.open(a, try formSample(a, "x"), .{});
    defer doc.deinit();
    {
        var b = Builder.init(testing.allocator, .{});
        defer b.deinit();
        try b.importPages(&doc, &.{ 1, 0 }, .{});
        try b.addBlankPage(10, 10);
        try b.importPages(&doc, &.{0}, .{});
        var out = try reopen(a, try written(a, &b));
        const items = try pdf.outline.read(a, &out.doc, out.pages);
        try testing.expectEqual(@as(usize, 3), items.len);
        // The heading has no destination of its own. The web link is dropped.
        try testing.expectEqualStrings("Chapter", items[0].title);
        try testing.expect(items[0].dest == null and !items[0].open);
        try testing.expectEqual(@as(usize, 1), items[0].children.len);
        try testing.expectEqualStrings("Section on two", items[0].children[0].title);
        try testing.expectEqual(pdf.outline.Destination{ .page = 0, .y = 50 }, items[0].children[0].dest.?);
        try testing.expectEqual(pdf.outline.Destination{ .page = 1, .x = 0, .y = 100 }, items[1].dest.?);
        // From the second call, which had only the first page.
        try testing.expectEqualStrings("Start", items[2].title);
        try testing.expectEqual(@as(usize, 3), items[2].dest.?.page);
        const root = out.doc.getDict(out.doc.catalog().?, "Outlines").?;
        // Three at the top; the closed chapter hides its section.
        try testing.expectEqual(@as(i64, 3), out.doc.getInt(root, "Count").?);
        const chapter = out.doc.getDict(root, "First").?;
        try testing.expectEqual(@as(i64, -1), out.doc.getInt(chapter, "Count").?);
        try testing.expectEqual(@as(i64, 2), out.doc.getInt(chapter, "F").?);
        try testing.expect(chapter.has("C") and !chapter.has("Prev"));

        // A written outline can be edited.
        var upd = try pdf.write.Update.init(testing.allocator, &out.doc);
        defer upd.deinit();
        try pdf.outline.remove(&upd, items[1].num);
    }
    var b = Builder.init(testing.allocator, .{});
    defer b.deinit();
    try b.importPages(&doc, &.{0}, .{});
    var out = try reopen(a, try written(a, &b));
    const items = try pdf.outline.read(a, &out.doc, out.pages);
    try testing.expectEqual(@as(usize, 1), items.len);
    try testing.expectEqualStrings("Start", items[0].title);
}

test "damaged form and outline trees are copied within limits" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try pdf.Document.open(a, try file(a, &.{
        // The form lists a page, a loop and a direct dictionary; the outline loops.
        "<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [3 0 R 4 0 R << /T (direct) >> 99 0 R] >> /Outlines << /First 6 0 R >> >>",
        "<< /Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 9 9] >>",
        "<< /Type /Page /Parent 2 0 R /Annots [5 0 R] >>",
        "<< /T (loop) /Kids [5 0 R 4 0 R] >>",
        "<< /Subtype /Widget /FT /Tx /Rect [0 0 1 1] /Parent 4 0 R /Kids [4 0 R] >>",
        "<< /Title (self) /First 6 0 R /Next 6 0 R /Dest [3 0 R /Fit] >>",
    }), .{});
    defer doc.deinit();
    var b = Builder.init(testing.allocator, .{});
    defer b.deinit();
    try b.importPages(&doc, &.{0}, .{});
    var out = try reopen(a, try written(a, &b));
    try testing.expectEqual(@as(usize, 1), (try pdf.outline.read(a, &out.doc, out.pages)).len);
    try testing.expectEqual(@as(usize, 1), (try pdf.form.fields(a, &out.doc, out.pages)).len);
}

test "a failed call adds no fields or bookmarks" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try pdf.Document.open(a, try formSample(a, "x"), .{});
    defer doc.deinit();
    var b = Builder.init(testing.allocator, .{});
    defer b.deinit();
    try b.importPages(&doc, &.{0}, .{});
    const before = try written(a, &b);
    // Every size limit short of what a second import needs, so that it fails at
    // each place that counts.
    const held = before.len;
    var limit: usize = 0;
    var failures: usize = 0;
    while (limit < held) : (limit += 40) {
        b.options.max_bytes = b.body.items.len + b.page_bytes.items.len + b.extra_bytes + limit;
        b.importPages(&doc, &.{ 0, 1 }, .{}) catch |err| {
            try testing.expectEqual(error.TooLarge, err);
            failures += 1;
            b.options.max_bytes = 1 << 30;
            try testing.expectEqualSlices(u8, before, try written(a, &b));
            continue;
        };
        break;
    }
    try testing.expect(failures > 5);
}

fn importFormUnderAllocationFailure(gpa: Allocator, bytes: []const u8) !void {
    var doc = try pdf.Document.open(gpa, bytes, .{});
    defer doc.deinit();
    var b = Builder.init(gpa, .{});
    defer b.deinit();
    try b.importPages(&doc, &.{ 0, 1 }, .{});
    try b.importPages(&doc, &.{0}, .{});
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try b.write(&out.writer);
    const bytes_out = out.written();
    for ([_][]const u8{ "Section on two", "who_2", "/F1_2 9 Tf", "Helvetica", "AcroForm" }) |want| try testing.expect(has(bytes_out, want));
}

test "every failed allocation while copying a form is reported" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.checkAllAllocationFailures(testing.allocator, importFormUnderAllocationFailure, .{try formSample(arena.allocator(), "x")});
}

test "a field that needs no change is copied as it is" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // A form with no defaults: nothing has to be added to its field.
    var doc = try pdf.Document.open(a, try file(a, &.{
        "<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [4 0 R] >> >>",
        "<< /Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 99 99] >>",
        "<< /Type /Page /Parent 2 0 R /Annots [4 0 R] >>",
        "<< /Type /Annot /Subtype /Widget /FT /Btn /T (box) /V /Off /Rect [1 1 9 9] >>",
    }), .{});
    defer doc.deinit();
    var b = Builder.init(testing.allocator, .{});
    defer b.deinit();
    try b.importPages(&doc, &.{0}, .{});
    var out = try reopen(a, try written(a, &b));
    const fields = try pdf.form.fields(a, &out.doc, out.pages);
    try testing.expectEqual(@as(usize, 1), fields.len);
    try testing.expectEqualStrings("box", fields[0].name);
    try testing.expectEqual(@as(usize, 1), fields[0].widgets.len);
}
