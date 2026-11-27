// SPDX-License-Identifier: LGPL-2.0-or-later
//! Filling forms and writing text boxes with an embedded font.

const std = @import("std");
const pdf = @import("root.zig");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const display = pdf.display;
const form = pdf.form;
const TrueType = pdf.truetype.Font;
const test_font = @import("test_font.zig");
const buildFile = @import("interp_tests.zig").buildFile;

const w = "/Type /Annot /Subtype /Widget";

/// Fields: 0 text (right aligned), 1 multi-line, 2 comb, 3 password, 4 list,
/// 5 combo, 6 another text field with a value and a stale appearance. The form
/// asks readers to make appearances when `need` is set.
fn sample(a: Allocator, need: bool) ![]const u8 {
    return buildFile(a, &.{
        try std.fmt.allocPrint(a, "<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [4 0 R 5 0 R 6 0 R 7 0 R 8 0 R 9 0 R 10 0 R] /DR << /Font << /Helv 11 0 R >> >> /DA (/Helv 0 Tf 0 g){s} >> >>", .{if (need) " /NeedAppearances true" else ""}),
        "<< /Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 300 300] >>",
        "<< /Type /Page /Parent 2 0 R /Annots [4 0 R 5 0 R 6 0 R 7 0 R 8 0 R 9 0 R 10 0 R] >>",
        "<< " ++ w ++ " /FT /Tx /T (text) /Rect [10 260 210 280] /Q 2 /DA (/Helv 10 Tf 0 0 1 rg) /DV (BAD) >>",
        "<< " ++ w ++ " /FT /Tx /T (multi) /Ff 4096 /Rect [10 180 70 250] /DA (/Helv 10 Tf 0 g) >>",
        "<< " ++ w ++ " /FT /Tx /T (comb) /Ff 16777216 /MaxLen 4 /Rect [10 150 90 170] /DA (/Helv 10 Tf 0 g) >>",
        "<< " ++ w ++ " /FT /Tx /T (password) /Ff 8192 /Rect [10 120 90 140] >>",
        "<< " ++ w ++ " /FT /Ch /T (list) /Rect [10 50 90 110] /DA (/Helv 10 Tf 0 g) /Opt [(AB) (CD) [(x) (BA)]] >>",
        "<< " ++ w ++ " /FT /Ch /Ff 131072 /T (combo) /Rect [10 20 90 40] /Opt [[(one) (ABC)] [(two) (D)]] >>",
        "<< " ++ w ++ " /FT /Tx /T (other) /V (kept value) /Rect [150 20 290 40] /AP << /N 12 0 R >> >>",
        "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
        "<< /Type /XObject /Subtype /Form /BBox [0 0 140 20] /Length 14 >>\nstream\n0 0 9 9 re f  \nendstream",
    });
}

const Saved = struct {
    doc: *pdf.Document,
    fields: []const form.Field,
    list: display.DisplayList,
    bytes: []const u8,

    /// The text runs inside rectangle `r` (user space).
    fn runs(self: *const Saved, a: Allocator, r: pdf.pages.Rect) ![]const display.Text {
        var out: std.ArrayList(display.Text) = .empty;
        for (self.list.commands) |c| if (c == .text) {
            const at = c.text.tm.mul(c.text.ctm).apply(0, 0);
            if (at.x >= r.x0 - 1 and at.x <= r.x1 and at.y >= r.y0 and at.y <= r.y1) try out.append(a, c.text);
        };
        return out.items;
    }

    fn shown(a: Allocator, text: []const display.Text) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        for (text, 0..) |run, i| {
            if (i > 0) try out.append(a, '|');
            for (run.glyphs) |g| try out.appendSlice(a, g.text);
        }
        return out.items;
    }
};

fn open(a: Allocator, bytes: []const u8, generate: bool) !Saved {
    const doc = try a.create(pdf.Document);
    doc.* = try pdf.Document.open(a, bytes, .{});
    try testing.expect(!doc.repaired);
    const pl = try pdf.pages.PageList.build(doc);
    var renderer = pdf.Renderer.init(doc, .{ .generate_appearances = generate });
    return .{ .doc = doc, .fields = try form.fields(a, doc, pl), .list = try renderer.render(a, pdf.pages.page(doc, pl, 0).?), .bytes = bytes };
}

fn save(a: Allocator, upd: *pdf.write.Update) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    try upd.write(testing.allocator, &out.writer);
    return out.written();
}

fn font(a: Allocator, options: test_font.Options) !TrueType {
    var o = options;
    o.format12 = true;
    o.space = true;
    return TrueType.init(testing.allocator, try test_font.make(a, o), .{ .permission_obtained = true });
}

test "fields filled with an embedded font show its characters, measured with its widths" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var face = try font(a, .{});
    defer face.deinit();
    var doc = try pdf.Document.open(a, try sample(a, false), .{});
    const fields = try form.fields(a, &doc, try pdf.pages.PageList.build(&doc));
    var upd = try pdf.write.Update.init(testing.allocator, &doc);
    defer upd.deinit();
    var fonts: pdf.draw.Embedder = .init(&upd);
    const typeface: form.Typeface = .{ .embedder = &fonts, .font = &face };

    // U+1F600 is two UTF-16 units: one character, which WinAnsi lacks.
    const value = "AB\u{e9}\u{1f600}";
    try form.setTextWith(&upd, fields[0], value, typeface);
    try form.setTextWith(&upd, fields[1], "ABC ABC AB\r\nD", typeface);
    try form.setTextWith(&upd, fields[2], "ABCD", typeface);
    try form.setChoicesWith(&upd, fields[4], &.{"x"}, typeface);
    try form.setTextWith(&upd, fields[5], "one", typeface);
    var out: std.Io.Writer.Allocating = .init(a);
    try testing.expectError(error.UnfinishedFonts, upd.write(testing.allocator, &out.writer));
    try fonts.finish();
    const after = try open(a, try save(a, &upd), false);

    try testing.expectEqualStrings(value, after.fields[0].value);
    const one = try after.runs(a, fields[0].widgets[0].rect);
    try testing.expectEqualStrings(value, try Saved.shown(a, one));
    try testing.expectEqual(.type0, one[0].font.subtype);
    try testing.expectEqual(@as(f32, 1), one[0].fill.color.b);
    // Right aligned: the line ends two units inside the field, by the font's widths.
    const last = one[0].glyphs[one[0].glyphs.len - 1];
    try testing.expectApproxEqAbs(@as(f64, 208), one[0].tm.mul(one[0].ctm).apply(last.x + last.advance * 10, 0).x, 0.02);
    // The field keeps its default appearance.
    try testing.expectEqualStrings("(/Helv 10 Tf 0 0 1 rg)"[1..21], after.doc.get(after.doc.getObject(4).asDict().?, "DA").?.string);

    // 60 units wide at 10 points: "ABC" is 18 units, "ABC ABC" is 43.5, and a
    // third word does not fit in the 56.
    try testing.expectEqualStrings("ABC ABC|AB|D", try Saved.shown(a, try after.runs(a, fields[1].widgets[0].rect)));
    // A comb: one run in each of four cells 20 units wide.
    const comb = try after.runs(a, fields[2].widgets[0].rect);
    try testing.expectEqualStrings("A|B|C|D", try Saved.shown(a, comb));
    for (comb, 0..) |run, i| {
        const middle = run.tm.mul(run.ctm).apply(run.glyphs[0].advance * 5, 0).x;
        try testing.expectApproxEqAbs(10 + 20 * @as(f64, @floatFromInt(i)) + 10, middle, 0.02);
    }
    try testing.expectEqualStrings("AB|CD|BA", try Saved.shown(a, try after.runs(a, fields[4].widgets[0].rect)));
    try testing.expectEqualStrings("x", after.fields[4].value);
    // The combo shows the entry's text and stores its export value.
    try testing.expectEqualStrings("ABC", try Saved.shown(a, try after.runs(a, fields[5].widgets[0].rect)));
    try testing.expectEqualStrings("one", after.fields[5].value);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, after.bytes, "/CIDFontType2"));

    // Resetting draws the default with the same font.
    var upd2 = try pdf.write.Update.init(testing.allocator, after.doc);
    defer upd2.deinit();
    var fonts2: pdf.draw.Embedder = .init(&upd2);
    try form.resetWith(&upd2, after.fields[0], .{ .embedder = &fonts2, .font = &face });
    try fonts2.finish();
    const reset = try open(a, try save(a, &upd2), false);
    try testing.expectEqualStrings("BAD", try Saved.shown(a, try reset.runs(a, fields[0].widgets[0].rect)));
}

test "what the font cannot write, or may not, is refused before anything changes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var face = try font(a, .{});
    defer face.deinit();
    var viewing = try font(a, .{ .fs_type = 4 });
    defer viewing.deinit();
    var permitted = try font(a, .{ .fs_type = 2 });
    defer permitted.deinit();
    var doc = try pdf.Document.open(a, try sample(a, true), .{});
    const pl = try pdf.pages.PageList.build(&doc);
    const fields = try form.fields(a, &doc, pl);
    const page = pdf.pages.page(&doc, pl, 0).?;
    var upd = try pdf.write.Update.init(testing.allocator, &doc);
    defer upd.deinit();
    var fonts: pdf.draw.Embedder = .init(&upd);
    const typeface: form.Typeface = .{ .embedder = &fonts, .font = &face };
    try testing.expectError(error.MissingGlyph, form.setTextWith(&upd, fields[0], "ABxyz", typeface));
    try testing.expectError(error.MissingGlyph, form.setTextWith(&upd, fields[0], "A\xff", typeface));
    // A password shows as asterisks, which this font lacks.
    try testing.expectError(error.MissingGlyph, form.setTextWith(&upd, fields[3], "AB", typeface));
    try testing.expectError(error.MissingGlyph, pdf.annot.addFreeTextWith(&upd, page, 1, 1, 90, 40, 12, .{ .contents = "no z" }, typeface));
    const no: form.Typeface = .{ .embedder = &fonts, .font = &viewing };
    try testing.expectError(error.FontNotForForms, form.setTextWith(&upd, fields[0], "AB", no));
    try testing.expectError(error.FontNotForForms, form.setChoicesWith(&upd, fields[4], &.{"AB"}, no));
    try testing.expectError(error.FontNotForForms, pdf.annot.addFreeTextWith(&upd, page, 1, 1, 90, 40, 12, .{ .contents = "AB" }, no));
    try testing.expectEqual(@as(usize, 0), upd.changed.count());
    try testing.expectEqual(@as(u32, 0), upd.unfinished);
    // A restricted font whose owner's permission the caller has is used.
    try form.setTextWith(&upd, fields[0], "AB", .{ .embedder = &fonts, .font = &permitted });
}

test "a form that asks for appearances is stopped from redrawing the embedded text" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var face = try font(a, .{});
    defer face.deinit();
    var doc = try pdf.Document.open(a, try sample(a, true), .{});
    const fields = try form.fields(a, &doc, try pdf.pages.PageList.build(&doc));
    var upd = try pdf.write.Update.init(testing.allocator, &doc);
    defer upd.deinit();
    var fonts: pdf.draw.Embedder = .init(&upd);
    try form.setTextWith(&upd, fields[0], "AB\u{1f600}", .{ .embedder = &fonts, .font = &face });
    try fonts.finish();
    // As a reader would show it, making what is asked of it.
    const after = try open(a, try save(a, &upd), true);
    const acro = after.doc.getDict(after.doc.catalog().?, "AcroForm").?;
    try testing.expectEqual(false, after.doc.get(acro, "NeedAppearances").?.boolean);
    try testing.expectEqualStrings("AB\u{1f600}", try Saved.shown(a, try after.runs(a, fields[0].widgets[0].rect)));
    // The other field, which relied on the flag, was given the appearance it was
    // shown with, in place of the stale one it had.
    try testing.expectEqualStrings("kept value", try Saved.shown(a, try after.runs(a, fields[6].widgets[0].rect)));
    const stored = try open(a, after.bytes, false);
    try testing.expectEqualStrings("kept value", try Saved.shown(a, try stored.runs(a, fields[6].widgets[0].rect)));
    try testing.expect(after.doc.getDict(after.doc.getObject(10).asDict().?, "AP").?.get("N").?.ref.num != 12);
}

test "fields, text boxes and stamps share one copy of a font, and flattening keeps it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var face = try font(a, .{});
    defer face.deinit();
    var doc = try pdf.Document.open(a, try sample(a, false), .{});
    const pl = try pdf.pages.PageList.build(&doc);
    const fields = try form.fields(a, &doc, pl);
    const page = pdf.pages.page(&doc, pl, 0).?;
    var upd = try pdf.write.Update.init(testing.allocator, &doc);
    defer upd.deinit();
    var stamp: pdf.draw.Stamp = .init(&upd);
    const typeface: form.Typeface = .{ .embedder = &stamp.fonts_embedded, .font = &face };
    try form.setTextWith(&upd, fields[0], "A", typeface);
    const box = try pdf.annot.addFreeTextWith(&upd, page, 100, 100, 150, 60, 14, .{ .contents = "B\u{e9}" }, typeface);
    var canvas = try pdf.draw.Canvas.init(testing.allocator, 300, 300);
    defer canvas.deinit();
    try canvas.text(.{ .embedded = &face }, 10, 200, 20, "C");
    try stamp.place(page, &canvas, .over);
    try pdf.annot.setContentsWith(&upd, box.num, "D D", null, typeface);
    _ = try pdf.flatten.widgets(&upd, page);
    try stamp.finish();
    const after = try open(a, try save(a, &upd), false);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, after.bytes, "/CIDFontType2"));
    const text = try pdf.text.extract(a, &after.list, .content);
    for ([_][]const u8{ "A", "C", "D D" }) |want| try testing.expect(std.mem.indexOf(u8, text, want) != null);
    // The box keeps its text, and Helvetica for a program that edits it.
    const annots = try pdf.annot.list(a, after.doc, pdf.pages.page(after.doc, try pdf.pages.PageList.build(after.doc), 0).?);
    try testing.expectEqualStrings("D D", annots[0].contents);

    // Without a typeface the box is drawn in Helvetica again.
    var upd2 = try pdf.write.Update.init(testing.allocator, after.doc);
    defer upd2.deinit();
    try pdf.annot.setContents(&upd2, annots[0].num, "plain", null);
    const plain = try open(a, try save(a, &upd2), false);
    try testing.expect(std.mem.indexOf(u8, try pdf.text.extract(a, &plain.list, .content), "plain") != null);
}

test "buttons that only the flag made visible are given appearances, and still toggle" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var face = try font(a, .{});
    defer face.deinit();
    var doc = try pdf.Document.open(a, try buildFile(a, &.{
        "<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [4 0 R 5 0 R 6 0 R 7 0 R] /NeedAppearances true >> >>",
        "<< /Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 300 300] >>",
        "<< /Type /Page /Parent 2 0 R /Annots [4 0 R 5 0 R 6 0 R 7 0 R] >>",
        "<< " ++ w ++ " /FT /Tx /T (text) /Rect [10 260 210 280] >>",
        // A check box whose "on" state is not a drawing, one with no
        // appearance at all, and a push button with none.
        "<< " ++ w ++ " /FT /Btn /T (odd) /AS /Off /Rect [10 200 30 220] /MK << /BC [0] >> /AP << /N << /0a << >> >> >> >>",
        "<< " ++ w ++ " /FT /Btn /T (bare) /V /Yes /Rect [50 200 70 220] /MK << /BC [0] >> >>",
        "<< " ++ w ++ " /FT /Btn /Ff 65536 /T (push) /Rect [90 200 150 220] /MK << /BG [0.5] /CA (Push) >> >>",
    }), .{});
    const before = try pdf.form.fields(a, &doc, try pdf.pages.PageList.build(&doc));
    var upd = try pdf.write.Update.init(testing.allocator, &doc);
    defer upd.deinit();
    var fonts: pdf.draw.Embedder = .init(&upd);
    try form.setTextWith(&upd, before[0], "AB", .{ .embedder = &fonts, .font = &face });
    try fonts.finish();
    // With generation off, only what is stored shows: as a reader that makes
    // nothing would see it.
    const after = try open(a, try save(a, &upd), false);
    var strokes: usize = 0;
    var fills: usize = 0;
    for (after.list.commands) |c| {
        if (c == .stroke) strokes += 1;
        if (c == .fill) fills += 1;
    }
    // Two borders, the tick of the box that is on, and the button's background.
    try testing.expectEqual(@as(usize, 3), strokes);
    try testing.expectEqual(@as(usize, 1), fills);
    // The caption is written with a font that is in the file.
    try testing.expect(std.mem.indexOf(u8, try pdf.text.extract(a, &after.list, .content), "Push") != null);
    const push = after.doc.getObject(7).asDict().?;
    const stored = after.doc.get(after.doc.getDict(push, "AP").?, "N").?.stream;
    const resources = after.doc.getDict(stored.dict, "Resources").?;
    const helvetica = after.doc.getDict(after.doc.getDict(resources, "Font").?, "Helv").?;
    try testing.expectEqualStrings("Helvetica", after.doc.getName(helvetica, "BaseFont").?);
    // The boxes kept their state names, so they can still be ticked.
    try testing.expectEqualStrings("0a", after.fields[1].widgets[0].on_state);
    try testing.expectEqualStrings("Yes", after.fields[2].widgets[0].on_state);
    try testing.expect(!after.fields[1].widgets[0].on and after.fields[2].widgets[0].on);
    var upd2 = try pdf.write.Update.init(testing.allocator, after.doc);
    defer upd2.deinit();
    try form.setChecked(&upd2, after.fields[1], 0, true);
    const ticked = try open(a, try save(a, &upd2), false);
    var more: usize = 0;
    for (ticked.list.commands) |c| if (c == .stroke) {
        more += 1;
    };
    try testing.expectEqual(strokes + 1, more);
}

fn fillUnderAllocationFailure(gpa: Allocator, font_file: []const u8, bytes: []const u8) !void {
    var face = try TrueType.init(gpa, font_file, .{});
    defer face.deinit();
    var doc = try pdf.Document.open(gpa, bytes, .{});
    defer doc.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const pl = try pdf.pages.PageList.build(&doc);
    const fields = try form.fields(arena.allocator(), &doc, pl);
    var upd = try pdf.write.Update.init(gpa, &doc);
    defer upd.deinit();
    var fonts: pdf.draw.Embedder = .init(&upd);
    const typeface: form.Typeface = .{ .embedder = &fonts, .font = &face };
    try form.setTextWith(&upd, fields[0], "AB CD", typeface);
    try form.setChoicesWith(&upd, fields[4], &.{"CD"}, typeface);
    _ = try pdf.annot.addFreeTextWith(&upd, pdf.pages.page(&doc, pl, 0).?, 100, 100, 90, 40, 12, .{ .contents = "DC" }, typeface);
    try fonts.finish();
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try upd.write(gpa, &out.writer);
    var check = std.heap.ArenaAllocator.init(testing.allocator);
    defer check.deinit();
    const after = try open(check.allocator(), out.written(), true);
    const text = try pdf.text.extract(check.allocator(), &after.list, .content);
    for ([_][]const u8{ "AB CD", "CD", "DC", "kept value" }) |want| try testing.expect(std.mem.indexOf(u8, text, want) != null);
}

test "every failed allocation while filling with an embedded font is reported" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.checkAllAllocationFailures(testing.allocator, fillUnderAllocationFailure, .{ try test_font.make(a, .{ .format12 = true, .space = true }), try sample(a, true) });
}

test "of a repeated dictionary key the last counts, as other readers have it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var face = try font(a, .{});
    defer face.deinit();
    // As a LaTeX package writes it: the catalog names the form twice.
    var doc = try pdf.Document.open(a, try buildFile(a, &.{
        "<< /Type /Catalog /Pages 2 0 R /AcroForm 5 0 R /AcroForm 6 0 R >>",
        "<< /Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 300 300] >>",
        "<< /Type /Page /Parent 2 0 R /Annots [4 0 R] >>",
        "<< " ++ w ++ " /FT /Tx /T (text) /Rect [10 260 210 280] >>",
        "<< /Fields [4 0 R] /NeedAppearances true /DA (first) >>",
        "<< /Fields [4 0 R] /NeedAppearances true >>",
    }), .{});
    const catalog = doc.catalog().?;
    try testing.expectEqual(@as(u32, 6), catalog.get("AcroForm").?.ref.num);
    // Setting a key leaves one entry, so that no reader sees an old one.
    const changed = try pdf.write.dictWith(a, catalog, "AcroForm", .{ .integer = 1 });
    var count: usize = 0;
    for (changed.entries) |e| if (std.mem.eql(u8, e.key, "AcroForm")) {
        count += 1;
    };
    try testing.expectEqual(@as(usize, 1), count);
    try testing.expectEqual(@as(i64, 1), changed.get("AcroForm").?.integer);
    try testing.expect(!(try pdf.write.dictWithout(a, catalog, "AcroForm")).has("AcroForm"));

    var upd = try pdf.write.Update.init(testing.allocator, &doc);
    defer upd.deinit();
    var fonts: pdf.draw.Embedder = .init(&upd);
    const fields = try form.fields(a, &doc, try pdf.pages.PageList.build(&doc));
    try form.setTextWith(&upd, fields[0], "AB", .{ .embedder = &fonts, .font = &face });
    try fonts.finish();
    // The flag is turned off in the dictionary that counts.
    try testing.expectEqual(false, upd.get(6).dict.get("NeedAppearances").?.boolean);
    try testing.expect(!upd.changed.contains(5));
}

test "filling damaged forms fails or succeeds, and never crashes (seeded mutation)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const base = try sample(arena.allocator(), true);
    var face = try font(arena.allocator(), .{});
    defer face.deinit();
    var prng = std.Random.DefaultPrng.init(0xb4);
    const random = prng.random();
    const copy = try testing.allocator.dupe(u8, base);
    defer testing.allocator.free(copy);
    var written: usize = 0;
    for (0..1500) |_| {
        @memcpy(copy, base);
        for (0..random.intRangeAtMost(usize, 1, 4)) |_| {
            copy[random.uintLessThan(usize, copy.len)] = "0123456789()<>[]/ .-RTF"[random.uintLessThan(usize, 22)];
        }
        var each = std.heap.ArenaAllocator.init(testing.allocator);
        defer each.deinit();
        const a = each.allocator();
        var doc = pdf.Document.open(a, copy, .{}) catch continue;
        const pl = pdf.pages.PageList.build(&doc) catch continue;
        const fields = form.fields(a, &doc, pl) catch continue;
        var upd = pdf.write.Update.init(testing.allocator, &doc) catch continue;
        defer upd.deinit();
        var fonts: pdf.draw.Embedder = .init(&upd);
        const typeface: form.Typeface = .{ .embedder = &fonts, .font = &face };
        for (fields) |f| switch (f.kind) {
            .text, .combo => form.setTextWith(&upd, f, "AB CD", typeface) catch continue,
            .list => form.setChoicesWith(&upd, f, &.{"AB"}, typeface) catch continue,
            else => {},
        };
        fonts.finish() catch continue;
        var out: std.Io.Writer.Allocating = .init(a);
        upd.write(testing.allocator, &out.writer) catch continue;
        written += 1;
        var again = pdf.Document.open(a, out.written(), .{}) catch continue;
        const pages_again = pdf.pages.PageList.build(&again) catch continue;
        var renderer = pdf.Renderer.init(&again, .{});
        _ = renderer.render(a, pdf.pages.page(&again, pages_again, 0) orelse continue) catch continue;
    }
    try testing.expect(written > 200);
}
