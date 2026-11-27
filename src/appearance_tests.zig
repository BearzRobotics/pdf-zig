// SPDX-License-Identifier: LGPL-2.0-or-later
//! Appearances made while rendering (decision 0004).

const std = @import("std");
const pdf = @import("root.zig");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const display = pdf.display;

/// A 200 by 100 page with the annotations `annots`. `acro` is put inside the
/// form dictionary, and `objects` become objects 4 onwards.
fn file(a: Allocator, annots: []const u8, acro: []const u8, objects: []const []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.print(a, "%PDF-1.7\n1 0 obj\n<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [] {s} >> >>\nendobj\n", .{acro});
    try out.appendSlice(a, "2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 200 100] >>\nendobj\n");
    try out.print(a, "3 0 obj\n<< /Type /Page /Parent 2 0 R /Annots [{s}] >>\nendobj\n", .{annots});
    for (objects, 4..) |body, n| try out.print(a, "{d} 0 obj\n{s}\nendobj\n", .{ n, body });
    try out.appendSlice(a, "trailer\n<< /Root 1 0 R >>\n%%EOF\n");
    return out.items;
}

const Page = struct {
    text: []const u8,
    commands: []const display.Command,
    omissions: display.Omissions,

    fn count(self: Page, comptime tag: std.meta.Tag(display.Command)) usize {
        var n: usize = 0;
        for (self.commands) |c| if (c == tag) {
            n += 1;
        };
        return n;
    }

    fn first(self: Page, comptime tag: std.meta.Tag(display.Command)) !@FieldType(display.Command, @tagName(tag)) {
        for (self.commands) |c| if (c == tag) return @field(c, @tagName(tag));
        return error.NoSuchCommand;
    }
};

/// Renders page 1 of `bytes`. Everything returned lives in `a`, an arena.
fn render(a: Allocator, bytes: []const u8, options: pdf.interp.Options) !Page {
    const doc = try a.create(pdf.Document);
    doc.* = try pdf.Document.open(a, bytes, .{});
    const list = try pdf.pages.PageList.build(doc);
    var renderer = pdf.Renderer.init(doc, options);
    var dl = try renderer.render(a, pdf.pages.page(doc, list, 0) orelse return error.NoPage);
    return .{ .text = try pdf.text.extract(a, &dl, .reading), .commands = dl.commands, .omissions = dl.omissions };
}

fn one(a: Allocator, annotation: []const u8) !Page {
    return render(a, try file(a, annotation, "", &.{}), .{});
}

const widget = "/Type /Annot /Subtype /Widget /Rect [10 40 110 60]";

fn field(a: Allocator, entries: []const u8) !Page {
    return one(a, try std.fmt.allocPrint(a, "<< " ++ widget ++ " {s} >>", .{entries}));
}

test "a text field without an appearance shows its value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bytes = try file(a, "<< " ++ widget ++ " /FT /Tx /V (Ada Lovelace) /DA (/Nope 10 Tf 0 0 1 rg) >>", "", &.{});
    const page = try render(a, bytes, .{});
    try testing.expectEqualStrings("Ada Lovelace\n", page.text);
    try testing.expectEqual(display.Omissions{}, page.omissions);
    const t = try page.first(.text);
    try testing.expectEqual(@as(f32, 1), t.fill.color.b);
    try testing.expectEqual(@as(f64, 10), t.size);
    // Inside the widget's rectangle.
    const at = t.tm.mul(t.ctm).apply(0, 0);
    try testing.expect(at.x >= 10 and at.x < 20 and at.y > 40 and at.y < 60);
    // With generation off it is left out, and said to be.
    const off = try render(a, bytes, .{ .generate_appearances = false });
    try testing.expectEqualStrings("", off.text);
    try testing.expect(off.omissions.no_appearance);
}

test "field attributes are inherited, passwords are masked and choices show their text" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const child = try render(a, try file(a, "<< " ++ widget ++ " /Parent 4 0 R >>", "", &.{"<< /FT /Tx /V (inherited) >>"}), .{});
    try testing.expectEqualStrings("inherited\n", child.text);
    // Password: bit 14.
    try testing.expectEqualStrings("****\n", (try field(a, "/FT /Tx /Ff 8192 /V (pass)")).text);
    // A combo box (bit 18) stores the export value and shows the other text.
    try testing.expectEqualStrings("The Netherlands\n", (try field(a, "/FT /Ch /Ff 131072 /V (nl) /Opt [[(be) (Belgium)] [(nl) (The Netherlands)]]")).text);
    // A comb (bit 25) spreads one character over each cell of 20 units.
    const comb = try field(a, "/FT /Tx /Ff 16777216 /MaxLen 5 /V (123)");
    var xs: [3]f64 = undefined;
    var n: usize = 0;
    for (comb.commands) |c| if (c == .text) {
        xs[n] = c.text.tm.mul(c.text.ctm).apply(0, 0).x;
        n += 1;
    };
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectApproxEqAbs(@as(f64, 20), xs[1] - xs[0], 0.02);
}

test "a list box shows its rows from the top index, with the selection marked" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const page = try one(a, "<< /Subtype /Widget /Rect [0 0 100 80] /FT /Ch /Opt [(one) (two) (three) (four)] /V [(two) (four)] /TI 1 >>");
    try testing.expectEqualStrings("two\nthree\nfour\n", page.text);
    try testing.expectEqual(@as(usize, 2), page.count(.fill));
}

test "check boxes, radio buttons and push buttons" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqual(@as(usize, 1), (try field(a, "/FT /Btn /V /Yes")).count(.stroke));
    try testing.expectEqual(@as(usize, 0), (try field(a, "/FT /Btn /V /Off")).count(.stroke));
    // /AS says what this widget shows, whatever the field's value.
    try testing.expectEqual(@as(usize, 0), (try field(a, "/FT /Btn /V /Yes /AS /Off")).count(.stroke));
    // A radio button (bit 16) that is on is a filled circle.
    const radio = try field(a, "/FT /Btn /Ff 32768 /AS /b /MK << /BC [0] >>");
    try testing.expectEqual(@as(usize, 1), radio.count(.fill));
    try testing.expectEqual(@as(usize, 1), radio.count(.stroke));
    try testing.expect((try radio.first(.fill)).path.len > 4);
    // Without /AS, a radio group's value does not say which button it is.
    try testing.expectEqual(@as(usize, 0), (try field(a, "/FT /Btn /Ff 32768 /V /b")).count(.fill));
    const button = try field(a, "/FT /Btn /Ff 65536 /MK << /BG [0.5] /CA (Send) >>");
    try testing.expectEqualStrings("Send\n", button.text);
    try testing.expectEqual(@as(usize, 1), button.count(.fill));
    // Nothing is drawn that could pass for a signature.
    const signed = try field(a, "/FT /Sig /V << /Name (Somebody) >>");
    try testing.expectEqualStrings("", signed.text);
    try testing.expectEqual(@as(usize, 0), signed.count(.fill) + signed.count(.stroke));
    try testing.expect(!signed.omissions.no_appearance);
}

test "stored appearances are used, and a state without a drawing stays empty" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const stored = "<< /Subtype /Form /BBox [0 0 100 20] /Resources << >> /Length 14 >>\nstream\n0 0 50 20 re f\nendstream";
    const page = try render(a, try file(a, "<< " ++ widget ++ " /FT /Tx /V (value) /AP << /N 4 0 R >> >>", "", &.{stored}), .{});
    try testing.expectEqualStrings("", page.text);
    try testing.expectEqual(@as(usize, 1), page.count(.fill));
    // An unchecked box often has a drawing for its "on" state only.
    const off = try render(a, try file(a, "<< " ++ widget ++ " /FT /Btn /AS /Off /V /Yes /AP << /N << /Yes 4 0 R >> >> >>", "", &.{stored}), .{});
    try testing.expectEqual(@as(usize, 0), off.count(.fill) + off.count(.stroke));
    try testing.expect(!off.omissions.no_appearance);
}

test "NeedAppearances makes text fields again, and only those with a value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const stored = "<< /Subtype /Form /BBox [0 0 100 20] /Resources << >> /Length 14 >>\nstream\n0 0 50 20 re f\nendstream";
    const need = "/NeedAppearances true";
    const text = try render(a, try file(a, "<< " ++ widget ++ " /FT /Tx /V (new value) /AP << /N 4 0 R >> >>", need, &.{stored}), .{});
    try testing.expectEqualStrings("new value\n", text.text);
    try testing.expectEqual(@as(usize, 0), text.count(.fill));
    for ([_][]const u8{ "/FT /Tx", "/FT /Btn /V /Yes" }) |kept| {
        const entries = try std.fmt.allocPrint(a, "<< " ++ widget ++ " {s} /AP << /N 4 0 R >> >>", .{kept});
        const page = try render(a, try file(a, entries, need, &.{stored}), .{});
        try testing.expectEqual(@as(usize, 1), page.count(.fill));
    }
}

test "markup, shapes, notes and text boxes without appearances are drawn" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const highlight = try one(a, "<< /Subtype /Highlight /Rect [10 10 60 20] /C [0 1 0] /QuadPoints [10 20 60 20 10 10 60 10] >>");
    const mark = try highlight.first(.fill);
    try testing.expectEqualStrings("Multiply", mark.blend);
    try testing.expectEqual(@as(f32, 1), mark.paint.color.g);
    const where = mark.ctm.apply(mark.path[0].move.x, mark.path[0].move.y);
    try testing.expectEqual(display.Point{ .x = 10, .y = 20 }, where);
    for ([_][]const u8{ "Underline", "StrikeOut", "Squiggly" }) |kind| {
        const page = try one(a, try std.fmt.allocPrint(a, "<< /Subtype /{s} /Rect [10 10 60 20] >>", .{kind}));
        try testing.expectEqual(@as(usize, 1), page.count(.stroke));
    }
    const square = try one(a, "<< /Subtype /Square /Rect [10 10 60 40] /C [1 0 0] /IC [0 0 1] /BS << /W 4 >> >>");
    try testing.expectEqual(@as(f64, 4), (try square.first(.stroke)).style.width);
    try testing.expectEqual(@as(usize, 1), square.count(.fill));
    // The line lies inside the rectangle.
    try testing.expectEqual(display.Point{ .x = 12, .y = 12 }, (try square.first(.stroke)).path[0].move);
    const circle = try one(a, "<< /Subtype /Circle /Rect [10 10 60 40] /C [0] >>");
    try testing.expect((try circle.first(.stroke)).path[1] == .curve);
    // Neither colour: nothing to see, and nothing missing.
    const empty = try one(a, "<< /Subtype /Square /Rect [10 10 60 40] >>");
    try testing.expect(empty.count(.stroke) == 0 and empty.count(.fill) == 0 and !empty.omissions.no_appearance);
    const line = try one(a, "<< /Subtype /Line /Rect [0 0 100 100] /L [5 6 70 80] /C [0] >>");
    try testing.expectEqual(display.Point{ .x = 70, .y = 80 }, (try line.first(.stroke)).path[1].line);
    const polygon = try one(a, "<< /Subtype /Polygon /Rect [0 0 100 100] /Vertices [1 1 50 1 25 40] /C [0] >>");
    try testing.expect((try polygon.first(.stroke)).path[3] == .close);
    const open = try one(a, "<< /Subtype /PolyLine /Rect [0 0 100 100] /Vertices [1 1 50 1 25 40] /C [0] >>");
    try testing.expectEqual(@as(usize, 3), (try open.first(.stroke)).path.len);
    const ink = try one(a, "<< /Subtype /Ink /Rect [0 0 100 100] /InkList [[1 1 9 9] [20 20]] /C [0] >>");
    try testing.expectEqual(@as(usize, 2), ink.count(.stroke));
    try testing.expect((try one(a, "<< /Subtype /Text /Rect [10 10 30 30] >>")).count(.fill) > 0);
    const box = try one(a, "<< /Subtype /FreeText /Rect [10 10 190 90] /DA (/Helv 14 Tf 1 0 0 rg) /Contents (A comment) >>");
    try testing.expectEqualStrings("A comment\n", box.text);
    try testing.expectEqual(@as(f64, 14), (try box.first(.text)).size);
    // What cannot be made is still reported; links have nothing to show.
    try testing.expect((try one(a, "<< /Subtype /Stamp /Rect [1 1 9 9] >>")).omissions.no_appearance);
    try testing.expect(!(try one(a, "<< /Subtype /Link /Rect [1 1 9 9] >>")).omissions.no_appearance);
}

test "many annotations sharing one large object stay within the page's limits" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var points: std.ArrayList(u8) = .empty;
    try points.append(a, '[');
    for (0..60_000) |_| try points.appendSlice(a, "1 ");
    try points.append(a, ']');
    var long: std.ArrayList(u8) = .empty;
    try long.append(a, '(');
    for (0..200_000) |_| try long.appendSlice(a, "word ");
    try long.append(a, ')');
    for ([_][]const u8{
        "<< /Subtype /PolyLine /Rect [0 0 9 9] /C [0] /Vertices 4 0 R >> ",
        "<< /Subtype /Widget /Rect [0 0 90 90] /FT /Tx /Ff 4096 /V 5 0 R >> ",
    }) |one_annotation| {
        var annots: std.ArrayList(u8) = .empty;
        for (0..400) |_| try annots.appendSlice(a, one_annotation);
        const bytes = try file(a, annots.items, "", &.{ points.items, long.items });
        try testing.expectError(error.LimitExceeded, render(a, bytes, .{ .max_content_bytes = 4 << 20, .max_path_segments = 1 << 20 }));
    }
}

test "damaged annotations never crash the page (seeded mutation)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const base = try file(arena.allocator(), "<< " ++ widget ++ " /FT /Tx /V (text) /DA (/Helv 9 Tf 0 g) /MK << /BC [0] /BG [1] /R 90 >> /Q 2 /MaxLen 6 /Ff 16777216 >> " ++
        "<< /Subtype /Widget /Rect [0 0 50 50] /FT /Ch /Opt [(a) [(b) (c)]] /V (b) /TI 1 >> << /Subtype /Ink /Rect [0 0 9 9] /InkList [[1 2 3 4]] /C [0 0 0 1] >> " ++
        "<< /Subtype /Highlight /Rect [0 0 9 9] /QuadPoints [1 2 3 4 5 6 7 8 9] >> << /Subtype /Polygon /Rect [0 0 9 9] /Vertices [1 2 3 4 5] /IC [1] >> " ++
        "<< /Subtype /FreeText /Rect [0 0 90 40] /Contents (x) /Rotate 270 >>", "/NeedAppearances true", &.{});
    var prng = std.Random.DefaultPrng.init(0xa99);
    const random = prng.random();
    const copy = try testing.allocator.dupe(u8, base);
    defer testing.allocator.free(copy);
    for (0..1500) |_| {
        @memcpy(copy, base);
        for (0..random.intRangeAtMost(usize, 1, 5)) |_| {
            copy[random.uintLessThan(usize, copy.len)] = "0123456789()<>[]/ .-R"[random.uintLessThan(usize, 20)];
        }
        var each = std.heap.ArenaAllocator.init(testing.allocator);
        defer each.deinit();
        _ = render(each.allocator(), copy, .{}) catch continue;
    }
}

fn renderUnderAllocationFailure(gpa: Allocator, bytes: []const u8) !void {
    var doc = try pdf.Document.open(gpa, bytes, .{});
    defer doc.deinit();
    const list = try pdf.pages.PageList.build(&doc);
    var renderer = pdf.Renderer.init(&doc, .{});
    defer renderer.deinit();
    var dl = try renderer.render(gpa, pdf.pages.page(&doc, list, 0).?);
    defer dl.deinit();
    const text = try pdf.text.extract(gpa, &dl, .reading);
    defer gpa.free(text);
    // A failed allocation must not pass for a field without a value.
    try testing.expect(std.mem.indexOf(u8, text, "shown") != null and std.mem.indexOf(u8, text, "row") != null);
}

test "every failed allocation while making appearances is reported" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const bytes = try file(arena.allocator(), "<< " ++ widget ++ " /FT /Tx /V (shown) >> << /Subtype /Widget /Rect [0 0 50 30] /FT /Ch /Opt [(row)] /V (row) >> << /Subtype /Highlight /Rect [0 0 9 9] >>", "", &.{});
    try testing.checkAllAllocationFailures(testing.allocator, renderUnderAllocationFailure, .{bytes});
}
