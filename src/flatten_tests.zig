// SPDX-License-Identifier: LGPL-2.0-or-later
//! Flattening: a flattened page shows what it showed, without the fields.

const std = @import("std");
const pdf = @import("root.zig");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const buildFile = @import("interp_tests.zig").buildFile;
const display = pdf.display;

const w = "/Type /Annot /Subtype /Widget";

/// Two pages with: a text field without an appearance, a turned check box with
/// one, a radio group of two buttons, a field on both pages, a hidden field, a
/// signature, a link, and content that leaves its graphics state changed.
fn sample(a: Allocator) ![]const u8 {
    return buildFile(a, &.{
        "<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [5 0 R 6 0 R 7 0 R 10 0 R 13 0 R 14 0 R] /CO [5 0 R 10 0 R] /XFA (x) >> >>",
        "<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 /MediaBox [0 0 200 200] /Resources << /Font << /F1 16 0 R >> /XObject << /PzF0 17 0 R >> >> >>",
        "<< /Type /Page /Parent 2 0 R /Contents 18 0 R /Annots [5 0 R 6 0 R 8 0 R 9 0 R 11 0 R 13 0 R 14 0 R 15 0 R] >>",
        "<< /Type /Page /Parent 2 0 R /Annots [12 0 R] >>",
        // 5, 6: text and check box.
        "<< " ++ w ++ " /FT /Tx /T (name) /V (Ada) /Rect [10 150 110 170] /DA (/Helv 11 Tf 0 g) >>",
        "<< " ++ w ++ " /FT /Btn /T (agree) /V /Yes /AS /Yes /Rect [10 100 30 140] /AP << /N << /Yes 19 0 R >> >> >>",
        // 7 to 9: radio group.
        "<< /FT /Btn /Ff 32768 /T (size) /V /S /Kids [8 0 R 9 0 R] >>",
        "<< " ++ w ++ " /Parent 7 0 R /AS /S /Rect [40 100 55 115] >>",
        "<< " ++ w ++ " /Parent 7 0 R /AS /Off /Rect [60 100 75 115] /AP << /N << /L 19 0 R >> >> >>",
        // 10 to 12: one field on both pages.
        "<< /FT /Tx /T (both) /V (twice) /Kids [11 0 R 12 0 R] >>",
        "<< " ++ w ++ " /Parent 10 0 R /Rect [10 60 110 80] >>",
        "<< " ++ w ++ " /Parent 10 0 R /Rect [10 60 110 80] >>",
        // 13 to 15: hidden, signature, link.
        "<< " ++ w ++ " /FT /Tx /T (secret) /V (kept) /F 2 /Rect [10 30 110 50] >>",
        "<< " ++ w ++ " /FT /Sig /T (signature) /Rect [120 30 190 50] >>",
        "<< /Type /Annot /Subtype /Link /Rect [0 0 9 9] >>",
        "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
        "<< /Type /XObject /Subtype /Form /BBox [0 0 1 1] /Length 0 >>\nstream\n\nendstream",
        "<< /Length 52 >>\nstream\nBT /F1 9 Tf 10 185 Td (Title) Tj ET 3 0 0 3 5 5 cm q\nendstream",
        // 19: an appearance without /Subtype, whose box is turned by its matrix.
        "<< /BBox [0 0 40 20] /Matrix [0 1 -1 0 20 0] /Resources << >> /Length 14 >>\nstream\n2 2 36 16 re f\nendstream",
    });
}

const Shot = struct {
    text: []const u8,
    /// Where each fill and glyph run lands on the page, rounded.
    marks: []const u8,
};

fn shoot(a: Allocator, doc: *pdf.Document, index: usize) !Shot {
    const list = try pdf.pages.PageList.build(doc);
    var renderer = pdf.Renderer.init(doc, .{});
    var dl = try renderer.render(a, pdf.pages.page(doc, list, index) orelse return error.NoPage);
    var marks: std.ArrayList(u8) = .empty;
    for (dl.commands) |c| switch (c) {
        .fill => |f| {
            for (f.path) |segment| if (segment == .move or segment == .line) {
                const p = f.ctm.apply(if (segment == .move) segment.move.x else segment.line.x, if (segment == .move) segment.move.y else segment.line.y);
                try marks.print(a, "f{d:.1},{d:.1} ", .{ p.x, p.y });
            };
        },
        .stroke => |s| {
            const p = s.ctm.apply(s.path[0].move.x, s.path[0].move.y);
            try marks.print(a, "s{d:.1},{d:.1} ", .{ p.x, p.y });
        },
        .text => |t| {
            const p = t.tm.mul(t.ctm).apply(0, 0);
            try marks.print(a, "t{d:.1},{d:.1} ", .{ p.x, p.y });
        },
        else => {},
    };
    return .{ .text = try pdf.text.extract(a, &dl, .reading), .marks = marks.items };
}

fn save(a: Allocator, upd: *pdf.write.Update) !*pdf.Document {
    var out: std.Io.Writer.Allocating = .init(a);
    try upd.write(testing.allocator, &out.writer);
    const doc = try a.create(pdf.Document);
    doc.* = try pdf.Document.open(a, out.written(), .{});
    return doc;
}

fn pageOf(doc: *pdf.Document, index: usize) !pdf.pages.Page {
    const list = try pdf.pages.PageList.build(doc);
    return pdf.pages.page(doc, list, index).?;
}

test "a flattened page shows what it showed, and the rest of the form stays" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try pdf.Document.open(a, try sample(a), .{});
    const before = try shoot(a, &doc, 0);
    var upd = try pdf.write.Update.init(testing.allocator, &doc);
    defer upd.deinit();
    const result = try pdf.flatten.widgets(&upd, try pageOf(&doc, 0));
    try testing.expectEqual(pdf.flatten.Result{ .flattened = 5, .kept = 2 }, result);
    const after_doc = try save(a, &upd);
    const after = try shoot(a, after_doc, 0);
    try testing.expectEqualStrings(before.text, after.text);
    try testing.expectEqualStrings(before.marks, after.marks);
    try testing.expect(std.mem.indexOf(u8, after.text, "Ada") != null and std.mem.indexOf(u8, after.text, "twice") != null);
    // It is page content now, drawn without the annotations' help.
    var renderer = pdf.Renderer.init(after_doc, .{ .generate_appearances = false });
    var dl = try renderer.render(a, try pageOf(after_doc, 0));
    try testing.expect(std.mem.indexOf(u8, try pdf.text.extract(a, &dl, .reading), "Ada") != null);

    // The hidden field, the signature and the link remain.
    try testing.expectEqual(@as(usize, 3), (try pdf.annot.list(a, after_doc, try pageOf(after_doc, 0))).len);
    const fields = try pdf.form.fields(a, after_doc, try pdf.pages.PageList.build(after_doc));
    try testing.expectEqual(@as(usize, 3), fields.len);
    for (fields, [_][]const u8{ "both", "secret", "signature" }) |f, name| try testing.expectEqualStrings(name, f.name);
    // The field on both pages keeps its widget on the other one.
    try testing.expectEqual(@as(usize, 1), fields[0].widgets.len);
    try testing.expectEqual(@as(?usize, 1), fields[0].widgets[0].page);
    const acro = after_doc.getDict(after_doc.catalog().?, "AcroForm").?;
    try testing.expect(!acro.has("XFA"));
    try testing.expectEqual(@as(usize, 1), after_doc.getArray(acro, "CO").?.len);
    // The page has resources of its own, in which the name already in use still
    // means what it did; the other page's are untouched.
    const own = (try pageOf(after_doc, 0)).resources.get("XObject").?.dict;
    try testing.expectEqual(@as(u32, 17), own.get("PzF0").?.ref.num);
    try testing.expect(own.entries.len > 1);
    try testing.expectEqual(@as(usize, 1), after_doc.getDict((try pageOf(after_doc, 1)).resources, "XObject").?.entries.len);
}

test "flattening after filling draws the new values, on every page" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try pdf.Document.open(a, try sample(a), .{});
    const fields = try pdf.form.fields(a, &doc, try pdf.pages.PageList.build(&doc));
    var upd = try pdf.write.Update.init(testing.allocator, &doc);
    defer upd.deinit();
    try pdf.form.setText(&upd, fields[0], "Grace");
    try pdf.form.setText(&upd, fields[3], "again");
    for (0..2) |i| _ = try pdf.flatten.widgets(&upd, try pageOf(&doc, i));
    // A second pass finds only what stayed.
    try testing.expectEqual(pdf.flatten.Result{ .kept = 2 }, try pdf.flatten.widgets(&upd, try pageOf(&doc, 0)));
    const after = try save(a, &upd);
    const first = try shoot(a, after, 0);
    for ([_][]const u8{ "Title", "Grace", "again" }) |want| try testing.expect(std.mem.indexOf(u8, first.text, want) != null);
    try testing.expect(std.mem.indexOf(u8, first.text, "Ada") == null);
    try testing.expectEqualStrings("again\n", (try shoot(a, after, 1)).text);
    try testing.expectEqual(@as(usize, 2), (try pdf.form.fields(a, after, try pdf.pages.PageList.build(after))).len);
}

test "flattening a damaged file fails or succeeds, and never crashes (seeded mutation)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const base = try sample(arena.allocator());
    var prng = std.Random.DefaultPrng.init(0xf1a7);
    const random = prng.random();
    const copy = try testing.allocator.dupe(u8, base);
    defer testing.allocator.free(copy);
    for (0..1500) |_| {
        @memcpy(copy, base);
        for (0..random.intRangeAtMost(usize, 1, 4)) |_| {
            copy[random.uintLessThan(usize, copy.len)] = "0123456789()<>[]/ .-R"[random.uintLessThan(usize, 20)];
        }
        var each = std.heap.ArenaAllocator.init(testing.allocator);
        defer each.deinit();
        const a = each.allocator();
        var doc = pdf.Document.open(a, copy, .{}) catch continue;
        const list = pdf.pages.PageList.build(&doc) catch continue;
        var upd = pdf.write.Update.init(testing.allocator, &doc) catch continue;
        defer upd.deinit();
        for (0..list.entries.len) |i| _ = pdf.flatten.widgets(&upd, pdf.pages.page(&doc, list, i) orelse continue) catch continue;
        var out: std.Io.Writer.Allocating = .init(a);
        upd.write(testing.allocator, &out.writer) catch continue;
        var again = pdf.Document.open(a, out.written(), .{}) catch continue;
        _ = shoot(a, &again, 0) catch continue;
    }
}

fn flattenUnderAllocationFailure(gpa: Allocator, bytes: []const u8) !void {
    var doc = try pdf.Document.open(gpa, bytes, .{});
    defer doc.deinit();
    const list = try pdf.pages.PageList.build(&doc);
    var upd = try pdf.write.Update.init(gpa, &doc);
    defer upd.deinit();
    const result = try pdf.flatten.widgets(&upd, pdf.pages.page(&doc, list, 0).?);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try upd.write(gpa, &out.writer);
    // A failed allocation must not have turned a widget into one left behind.
    try testing.expectEqual(@as(usize, 5), result.flattened);
}

test "every failed allocation while flattening is reported" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.checkAllAllocationFailures(testing.allocator, flattenUnderAllocationFailure, .{try sample(arena.allocator())});
}

test "whatever the page's content leaves unmatched, the fields land where they were" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{
        "",                            "q 3 0 0 3 5 5 cm",                        "Q 3 0 0 3 5 5 cm", "q q 2 0 0 2 0 0 cm Q 1 0 0 1 50 0 cm q",
        "Q Q 1 0 0 rg 2 0 0 2 0 0 cm", "q 9 0 0 9 0 0 cm Q Q Q q 4 0 0 4 0 0 cm",
    }) |left| {
        const stream = try std.fmt.allocPrint(a, "<< /Length {d} >>\nstream\n{s}\nendstream", .{ left.len, left });
        const bytes = try buildFile(a, &.{
            "<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [4 0 R] >> >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 200 200] >>",
            "<< /Type /Page /Parent 2 0 R /Contents 5 0 R /Annots [4 0 R] >>",
            "<< " ++ w ++ " /FT /Tx /T (n) /V (here) /Rect [10 150 110 170] /DA (/Helv 11 Tf 0 g) >>",
            stream,
        });
        var doc = try pdf.Document.open(a, bytes, .{});
        const before = try shoot(a, &doc, 0);
        var upd = try pdf.write.Update.init(testing.allocator, &doc);
        defer upd.deinit();
        _ = try pdf.flatten.widgets(&upd, try pageOf(&doc, 0));
        const after = try shoot(a, try save(a, &upd), 0);
        try testing.expectEqualStrings(before.marks, after.marks);
    }
}

test "content that cannot be read stops flattening" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try pdf.Document.open(a, try buildFile(a, &.{
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 200 200] >>",
        "<< /Type /Page /Parent 2 0 R /Contents 5 0 R /Annots [4 0 R] >>",
        "<< " ++ w ++ " /FT /Tx /V (x) /Rect [10 150 110 170] >>",
        "<< /Filter /NoSuchDecode /Length 1 >>\nstream\nx\nendstream",
    }), .{});
    var upd = try pdf.write.Update.init(testing.allocator, &doc);
    defer upd.deinit();
    try testing.expectError(error.UnreadableContent, pdf.flatten.widgets(&upd, try pageOf(&doc, 0)));
}
