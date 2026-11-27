// SPDX-License-Identifier: LGPL-2.0-or-later
//! Drawing: what a canvas makes is written, read back and compared.

const std = @import("std");
const pdf = @import("root.zig");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const display = pdf.display;
const draw = pdf.draw;
const Canvas = draw.Canvas;
const Builder = pdf.compose.Builder;

/// A document read back: its first page rendered. Everything lives in `a`.
const Page = struct {
    doc: *pdf.Document,
    page: pdf.pages.Page,
    list: display.DisplayList,
    bytes: []const u8,

    fn text(self: *const Page, a: Allocator) ![]const u8 {
        return pdf.text.extract(a, &self.list, .reading);
    }

    fn nth(self: *const Page, comptime tag: std.meta.Tag(display.Command), n: usize) !@FieldType(display.Command, @tagName(tag)) {
        var left = n;
        for (self.list.commands) |c| if (c == tag) {
            if (left == 0) return @field(c, @tagName(tag));
            left -= 1;
        };
        return error.NoSuchCommand;
    }

    /// Where point (`x`, `y`) of a command's space lands on the page as seen.
    fn seen(self: *const Page, ctm: display.Matrix, x: f64, y: f64) display.Point {
        return ctm.mul(self.list.base).apply(x, y);
    }
};

fn open(a: Allocator, bytes: []const u8, index: usize) !Page {
    const doc = try a.create(pdf.Document);
    doc.* = try pdf.Document.open(a, bytes, .{});
    try testing.expect(!doc.repaired);
    const list = try pdf.pages.PageList.build(doc);
    const page = pdf.pages.page(doc, list, index).?;
    var renderer = pdf.Renderer.init(doc, .{});
    return .{ .doc = doc, .page = page, .list = try renderer.render(a, page), .bytes = bytes };
}

fn written(a: Allocator, builder: *const Builder) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    try builder.write(&out.writer);
    return out.written();
}

fn onePage(a: Allocator, canvas: *const Canvas) !Page {
    var builder = Builder.init(testing.allocator, .{});
    defer builder.deinit();
    try builder.addPage(canvas);
    return open(a, try written(a, &builder), 0);
}

fn expectAt(want_x: f64, want_y: f64, got: display.Point) !void {
    try testing.expectApproxEqAbs(want_x, got.x, 1e-6);
    try testing.expectApproxEqAbs(want_y, got.y, 1e-6);
}

test "paths land where they were drawn, measured from the top left" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var canvas = try Canvas.init(testing.allocator, 300, 200);
    defer canvas.deinit();
    try canvas.setFill(.{ .rgb = .{ 1, 0, 0 } });
    try canvas.rect(10, 20, 100, 30);
    try canvas.fill(.nonzero);
    try canvas.setStroke(.{ .cmyk = .{ 1, 0, 0, 0 } });
    try canvas.setLineWidth(3);
    try canvas.setLineCap(.round);
    try canvas.setLineJoin(.bevel);
    try canvas.setDash(&.{ 4, 2 }, 1);
    try canvas.moveTo(5, 190);
    try canvas.lineTo(50, 150);
    try canvas.curveTo(60, 140, 70, 160, 80, 150);
    try canvas.close();
    try canvas.stroke();
    try canvas.rect(0, 0, 40, 40);
    try canvas.fillStroke(.even_odd);
    const page = try onePage(a, &canvas);
    try testing.expectEqual(@as(f64, 300), page.list.width);
    try testing.expectEqual(@as(f64, 200), page.list.height);
    try testing.expectEqual(display.Omissions{}, page.list.omissions);

    const box = try page.nth(.fill, 0);
    try testing.expectEqual(@as(f32, 1), box.paint.color.r);
    try testing.expectEqual(@as(f32, 0), box.paint.color.g);
    // The corners, top left and bottom right.
    var min: display.Point = .{ .x = 1e9, .y = 1e9 };
    var max: display.Point = .{ .x = -1e9, .y = -1e9 };
    for (box.path) |segment| if (segment == .move or segment == .line) {
        const raw = if (segment == .move) segment.move else segment.line;
        const p = page.seen(box.ctm, raw.x, raw.y);
        min = .{ .x = @min(min.x, p.x), .y = @min(min.y, p.y) };
        max = .{ .x = @max(max.x, p.x), .y = @max(max.y, p.y) };
    };
    try expectAt(10, 20, min);
    try expectAt(110, 50, max);

    const line = try page.nth(.stroke, 0);
    try testing.expectEqual(@as(f64, 3), line.style.width);
    try testing.expectEqual(display.Cap.round, line.style.cap);
    try testing.expectEqual(display.Join.bevel, line.style.join);
    try testing.expectEqualSlices(f64, &.{ 4, 2 }, line.style.dash);
    try testing.expectEqual(@as(f64, 1), line.style.dash_phase);
    try expectAt(5, 190, page.seen(line.ctm, line.path[0].move.x, line.path[0].move.y));
    try expectAt(80, 150, page.seen(line.ctm, line.path[2].curve.p.x, line.path[2].curve.p.y));
    try expectAt(60, 140, page.seen(line.ctm, line.path[2].curve.c1.x, line.path[2].curve.c1.y));
    try testing.expect(line.path[3] == .close);
    try testing.expectEqual(display.FillRule.even_odd, (try page.nth(.fill, 1)).rule);
}

test "text is where it was put, in its font, and can be extracted" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var canvas = try Canvas.init(testing.allocator, 300, 200);
    defer canvas.deinit();
    const line = "Caf\u{e9} (\\) \u{20ac}\u{2022}\u{201c}x\u{201d}";
    try canvas.text(.helvetica_bold, 18, 40, 60, line);
    try canvas.text(.times_italic, 10, 40, 90, "Second line");
    try canvas.textWith(.courier, 10, 40, 120, "squeezed", .{ .fit_width = 24 });
    try canvas.textWith(.helvetica, 10, 40, 150, "hidden words", .{ .mode = .invisible, .fit_width = 150 });
    // The scaling and mode of one line do not carry to the next.
    try canvas.text(.courier, 10, 40, 180, "normal");
    try canvas.text(.helvetica, 10, 0, 0, "");
    const page = try onePage(a, &canvas);
    try testing.expectEqualStrings(line ++ "\nSecond line\nsqueezed\nhidden words\nnormal\n", try page.text(a));

    const first = try page.nth(.text, 0);
    try testing.expectEqualStrings("Helvetica-Bold", first.font.base_font);
    try testing.expectEqual(@as(f64, 18), first.size);
    try expectAt(40, 60, page.seen(first.tm.mul(first.ctm), 0, 0));
    // Upright: text space's y goes up the page.
    try testing.expect(page.seen(first.tm.mul(first.ctm), 0, 1).y < 60);
    // What the canvas measures is what the reader measures.
    for ([_]struct { usize, draw.Font, f64, []const u8 }{
        .{ 0, .helvetica_bold, 18, line },
        .{ 1, .times_italic, 10, "Second line" },
        .{ 4, .courier, 10, "normal" },
    }) |c| {
        const run = try page.nth(.text, c[0]);
        const last = run.glyphs[run.glyphs.len - 1];
        try testing.expectApproxEqAbs(try c[1].textWidth(c[2], c[3]), last.x + last.advance * run.size, 1e-6);
    }
    for ([_]struct { usize, f64 }{ .{ 2, 24 }, .{ 3, 150 } }) |c| {
        const run = try page.nth(.text, c[0]);
        const last = run.glyphs[run.glyphs.len - 1];
        const end = page.seen(run.tm.mul(run.ctm), last.x + last.advance * run.size * run.h_scale, 0);
        try testing.expectApproxEqAbs(40 + c[1], end.x, 1e-6);
    }
    try testing.expectEqual(@as(u8, 3), (try page.nth(.text, 3)).mode);
    try testing.expectEqual(@as(u8, 0), (try page.nth(.text, 4)).mode);
    try testing.expectEqual(@as(f64, 1), (try page.nth(.text, 4)).h_scale);
}

test "each built-in font is the one it names, with the reader's widths" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var canvas = try Canvas.init(testing.allocator, 600, 800);
    defer canvas.deinit();
    // Every character of WinAnsi that has a code of its own.
    var all: std.ArrayList(u8) = .empty;
    var code: u16 = 0x20;
    while (code < 256) : (code += 1) {
        const u = pdf.encoding.unicodeOf(.win_ansi, @intCast(code));
        if (code == 0x7F or code == 0xAD or (u == 0x2022 and code != 0x95)) continue;
        var buffer: [4]u8 = undefined;
        try all.appendSlice(a, buffer[0..try std.unicode.utf8Encode(u, &buffer)]);
    }
    const names = [_][]const u8{ "Courier", "Courier-Bold", "Courier-Oblique", "Courier-BoldOblique", "Helvetica", "Helvetica-Bold", "Helvetica-Oblique", "Helvetica-BoldOblique", "Times-Roman", "Times-Bold", "Times-Italic", "Times-BoldItalic" };
    for (std.enums.values(draw.Builtin), 0..) |builtin, i| {
        const font: draw.Font = .{ .builtin = builtin };
        try testing.expect(font.covers(all.items));
        try canvas.text(font, 2, 0, 20 + 20 * @as(f64, @floatFromInt(i)), all.items);
    }
    const page = try onePage(a, &canvas);
    for (std.enums.values(draw.Builtin), names, 0..) |builtin, name, i| {
        try testing.expectEqualStrings(name, builtin.baseFont());
        const run = try page.nth(.text, i);
        try testing.expectEqualStrings(name, run.font.base_font);
        var shown: std.ArrayList(u8) = .empty;
        for (run.glyphs) |g| try shown.appendSlice(a, g.text);
        // A no-break space reads back as itself.
        try testing.expectEqualStrings(all.items, shown.items);
        const font: draw.Font = .{ .builtin = builtin };
        const last = run.glyphs[run.glyphs.len - 1];
        try testing.expectApproxEqAbs(try font.textWidth(2, all.items), last.x + last.advance * 2, 1e-6);
    }
}

test "transform moves, scales and turns in the canvas's coordinates; save and restore undo it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var canvas = try Canvas.init(testing.allocator, 300, 200);
    defer canvas.deinit();
    try canvas.save();
    // A quarter turn clockwise on screen about (100, 100): x goes to y, down.
    const turn: display.Matrix = .{ .a = 0, .b = 1, .c = -1, .d = 0, .e = 200, .f = 0 };
    try canvas.transform(turn);
    try canvas.moveTo(100, 100);
    try canvas.lineTo(130, 100);
    try canvas.stroke();
    try canvas.text(.helvetica, 10, 100, 100, "turned");
    try canvas.restore();
    try canvas.moveTo(100, 100);
    try canvas.lineTo(130, 100);
    try canvas.stroke();
    const page = try onePage(a, &canvas);
    const turned = try page.nth(.stroke, 0);
    try expectAt(100, 100, page.seen(turned.ctm, turned.path[0].move.x, turned.path[0].move.y));
    try expectAt(100, 130, page.seen(turned.ctm, turned.path[1].line.x, turned.path[1].line.y));
    const run = try page.nth(.text, 0);
    try expectAt(100, 100, page.seen(run.tm.mul(run.ctm), 0, 0));
    // The text runs down the page, its top to the right.
    try testing.expect(page.seen(run.tm.mul(run.ctm), 10, 0).y > 100);
    try testing.expect(page.seen(run.tm.mul(run.ctm), 0, 1).x > 100);
    const plain = try page.nth(.stroke, 1);
    try expectAt(130, 100, page.seen(plain.ctm, plain.path[1].line.x, plain.path[1].line.y));
}

test "alpha, blend modes, clips and saved states" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var canvas = try Canvas.init(testing.allocator, 100, 100);
    defer canvas.deinit();
    try canvas.save();
    try canvas.rect(10, 10, 50, 50);
    try canvas.clip(.even_odd);
    try canvas.setAlpha(0.5, 0.25);
    try canvas.setBlend(.Multiply);
    try canvas.rect(0, 0, 100, 100);
    try canvas.fill(.nonzero);
    try canvas.restore();
    try canvas.rect(0, 0, 10, 10);
    try canvas.fill(.nonzero);
    // The same state again is the same entry.
    try canvas.setAlpha(0.5, 0.25);
    try canvas.setBlend(.Multiply);
    try testing.expectEqual(@as(usize, 2), canvas.states.items.len);
    // Left open: the page closes it.
    try canvas.save();
    const page = try onePage(a, &canvas);
    try testing.expectEqual(display.FillRule.even_odd, (try page.nth(.clip, 0)).rule);
    const veiled = try page.nth(.fill, 0);
    try testing.expectEqual(@as(f64, 0.5), veiled.alpha);
    try testing.expectEqualStrings("Multiply", veiled.blend);
    const after = try page.nth(.fill, 1);
    try testing.expectEqual(@as(f64, 1), after.alpha);
    try testing.expectEqualStrings("Normal", after.blend);
    var saves: usize = 0;
    var restores: usize = 0;
    for (page.list.commands) |c| {
        if (c == .save) saves += 1;
        if (c == .restore) restores += 1;
    }
    try testing.expectEqual(saves, restores);
}

test "a call that would make invalid content is refused and adds nothing" {
    var canvas = try Canvas.init(testing.allocator, 100, 100);
    defer canvas.deinit();
    try testing.expectError(error.BadValue, Canvas.init(testing.allocator, 0, 10));
    try testing.expectError(error.BadValue, Canvas.init(testing.allocator, 10, std.math.inf(f64)));
    const nan = std.math.nan(f64);
    try testing.expectError(error.UnbalancedRestore, canvas.restore());
    try testing.expectError(error.NoCurrentPoint, canvas.lineTo(1, 1));
    try testing.expectError(error.NoCurrentPoint, canvas.close());
    try testing.expectError(error.NoPath, canvas.fill(.nonzero));
    try testing.expectError(error.NoPath, canvas.clip(.nonzero));
    try testing.expectError(error.BadValue, canvas.moveTo(nan, 1));
    try testing.expectError(error.BadValue, canvas.rect(0, 0, -1, 1));
    try testing.expectError(error.BadValue, canvas.rect(0, 0, 1e9, 1));
    try testing.expectError(error.BadValue, canvas.setFill(.{ .gray = 1.5 }));
    try testing.expectError(error.BadValue, canvas.setStroke(.{ .rgb = .{ 0, nan, 0 } }));
    try testing.expectError(error.BadValue, canvas.setLineWidth(-1));
    try testing.expectError(error.BadValue, canvas.setDash(&.{ 0, 0 }, 0));
    try testing.expectError(error.BadValue, canvas.setDash(&.{-1}, 0));
    try testing.expectError(error.BadValue, canvas.setAlpha(2, 1));
    try testing.expectError(error.BadValue, canvas.transform(.{ .a = nan }));
    try testing.expectError(error.BadValue, canvas.text(.helvetica, 0, 1, 1, "x"));
    try testing.expectError(error.BadValue, canvas.text(.helvetica, 10, 1, 1, "two\nlines"));
    try testing.expectError(error.BadValue, canvas.text(.helvetica, 10, 1, 1, "bad \xff"));
    try testing.expectError(error.MissingGlyph, canvas.text(.helvetica, 10, 1, 1, "abc \u{3b1}"));
    try testing.expectError(error.MissingGlyph, canvas.text(.helvetica, 10, 1, 1, "soft\u{ad}hyphen"));
    try testing.expect(!(draw.Font.helvetica).covers("\u{3b1}"));
    try testing.expectError(error.BadValue, canvas.textWith(.helvetica, 10, 1, 1, "x", .{ .fit_width = 0 }));
    try testing.expectEqual(@as(usize, 0), canvas.content.items.len);
    try testing.expect(canvas.fonts.count() == 0 and canvas.states.items.len == 0);

    try canvas.moveTo(1, 1);
    const length = canvas.content.items.len;
    try testing.expectError(error.PathOpen, canvas.setFill(.black));
    try testing.expectError(error.PathOpen, canvas.save());
    try testing.expectError(error.PathOpen, canvas.text(.helvetica, 10, 1, 1, "x"));
    try testing.expectError(error.PathOpen, canvas.setAlpha(1, 1));
    try testing.expectEqual(length, canvas.content.items.len);
    var builder = Builder.init(testing.allocator, .{});
    defer builder.deinit();
    try testing.expectError(error.PathOpen, builder.addPage(&canvas));
    try testing.expectEqual(@as(usize, 0), builder.pageCount());

    var deep = try Canvas.init(testing.allocator, 10, 10);
    defer deep.deinit();
    for (0..draw.max_saved) |_| try deep.save();
    try testing.expectError(error.TooLarge, deep.save());
}

test "JPEG files are stored as they are, and only the kinds that are read" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]struct { []const u8, u32, u32, u8 }{
        .{ @embedFile("jpeg_rgb.jpg"), 16, 8, 3 },
        .{ @embedFile("jpeg_progressive.jpg"), 16, 8, 3 },
        .{ @embedFile("jpeg_gray.jpg"), 5, 7, 1 },
    }) |c| {
        var image = try draw.Image.fromJpeg(testing.allocator, c[0]);
        defer image.deinit();
        try testing.expectEqual(c[1], image.width);
        try testing.expectEqual(c[2], image.height);
        try testing.expectEqual(c[3], image.components);
        var canvas = try Canvas.init(testing.allocator, 100, 100);
        defer canvas.deinit();
        try canvas.image(&image, 10, 20, 32, 16);
        const page = try onePage(a, &canvas);
        const placed = try page.nth(.image, 0);
        try testing.expectEqual(c[1], placed.width);
        // The unit square's top left is the image's first sample.
        try expectAt(10, 20, page.seen(placed.ctm, 0, 1));
        try expectAt(42, 36, page.seen(placed.ctm, 1, 0));
        const decoded = try page.doc.decodeStreamIn(a, placed.stream);
        try testing.expectEqualStrings("DCTDecode", decoded.rest[0].name);
        try testing.expectEqualSlices(u8, c[0], decoded.data);
    }
    try testing.expectError(error.UnsupportedImage, draw.Image.fromJpeg(testing.allocator, @embedFile("jpeg_cmyk.jpg")));
    for ([_][]const u8{ "", "\xff", "\x89PNG\r\n", "\xff\xd8", "\xff\xd8\xff\xd9", "\xff\xd8\xff\xc0\x00\x04\x08\x00" }) |bad| {
        try testing.expectError(error.BadImage, draw.Image.fromJpeg(testing.allocator, bad));
    }
    // A damaged header is an error, never a crash.
    var prng = std.Random.DefaultPrng.init(0x19e9);
    const random = prng.random();
    const source: []const u8 = @embedFile("jpeg_rgb.jpg");
    for (0..4000) |_| {
        const copy = try testing.allocator.dupe(u8, source[0..random.intRangeAtMost(usize, 0, source.len)]);
        defer testing.allocator.free(copy);
        if (copy.len > 0) for (0..random.intRangeAtMost(usize, 1, 8)) |_| {
            copy[random.uintLessThan(usize, copy.len)] = random.int(u8);
        };
        var image = draw.Image.fromJpeg(testing.allocator, copy) catch continue;
        image.deinit();
    }
}

test "raw pixels come back as they went in, with their alpha" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const samples = [_]u8{ 255, 0, 0, 0, 255, 0, 0, 0, 255, 10, 20, 30 };
    const alpha = [_]u8{ 255, 128, 0, 64 };
    var image = try draw.Image.fromPixels(testing.allocator, .{ .width = 2, .height = 2, .format = .rgb, .samples = &samples, .alpha = &alpha });
    var canvas = try Canvas.init(testing.allocator, 100, 100);
    defer canvas.deinit();
    try canvas.image(&image, 0, 0, 50, 50);
    // The canvas has its own copy.
    image.deinit();
    const page = try onePage(a, &canvas);
    const placed = try page.nth(.image, 0);
    const rgba = try pdf.image.decode(page.doc, a, placed);
    try testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255, 0, 255, 0, 128, 0, 0, 255, 0, 10, 20, 30, 64 }, rgba.pixels.rgba);
    for ([_]draw.Image.Pixels{
        .{ .width = 0, .height = 1, .format = .gray, .samples = "" },
        .{ .width = 2, .height = 2, .format = .gray, .samples = "abc" },
        .{ .width = 1, .height = 1, .format = .rgb, .samples = "ab" },
        .{ .width = 1, .height = 1, .format = .gray, .samples = "a", .alpha = "ab" },
    }) |bad| try testing.expectError(error.BadImage, draw.Image.fromPixels(testing.allocator, bad));
    try testing.expectError(error.TooLarge, draw.Image.fromPixels(testing.allocator, .{ .width = 1 << 17, .height = 1, .format = .gray, .samples = "" }));
}

test "fonts and images are stored once, across pages and with imported ones" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var source = try pdf.Document.open(a, @embedFile("plain.pdf"), .{});
    var builder = Builder.init(testing.allocator, .{});
    defer builder.deinit();
    for (0..3) |i| {
        // Equal pictures, made and freed each time.
        var image = try draw.Image.fromJpeg(testing.allocator, @embedFile("jpeg_rgb.jpg"));
        defer image.deinit();
        var other = try draw.Image.fromJpeg(testing.allocator, @embedFile("jpeg_gray.jpg"));
        defer other.deinit();
        var canvas = try Canvas.init(testing.allocator, 200, 100);
        defer canvas.deinit();
        try canvas.image(&image, 0, 0, 16, 8);
        try canvas.image(&image, 20, 0, 16, 8);
        if (i == 2) try canvas.image(&other, 40, 0, 5, 7);
        var label: [16]u8 = undefined;
        try canvas.text(.helvetica, 12, 10, 50, try std.fmt.bufPrint(&label, "Page {d}", .{i + 1}));
        try builder.addPage(&canvas);
    }
    try builder.importPages(&source, &.{0}, .{});
    try builder.addBlankPage(10, 10);
    const bytes = try written(a, &builder);
    for ([_][]const u8{ "Page 1\n", "Page 2\n", "Page 3\n", "Hello encrypted world\n", "" }, 0..) |want, i| {
        try testing.expectEqualStrings(want, try (try open(a, bytes, i)).text(a));
    }
    var first = try open(a, bytes, 0);
    var third = try open(a, bytes, 2);
    try testing.expectEqual((try first.nth(.image, 0)).num, (try first.nth(.image, 1)).num);
    try testing.expectEqual((try first.nth(.image, 0)).num, (try third.nth(.image, 0)).num);
    try testing.expect((try third.nth(.image, 2)).num != (try third.nth(.image, 0)).num);
    var images: usize = 0;
    var it = first.doc.xref.iterator();
    while (it.next()) |entry| {
        const o = first.doc.getObject(entry.key_ptr.*);
        if (o == .stream and std.mem.eql(u8, first.doc.getName(o.stream.dict, "Subtype") orelse "", "Image")) images += 1;
    }
    try testing.expectEqual(@as(usize, 2), images);
    const fonts = first.page.resources.get("Font").?.dict;
    try testing.expectEqual(fonts.entries[0].value.ref.num, third.page.resources.get("Font").?.dict.entries[0].value.ref.num);
}

test "document information is written and read back" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var builder = Builder.init(testing.allocator, .{});
    defer builder.deinit();
    try builder.addBlankPage(10, 10);
    try builder.setInfo(.{ .title = "R\u{e9}sum\u{e9} \u{2013} 2026", .author = "Somebody", .created = "D:20261127120000+01'00'", .modified = "D:2026" });
    for ([_][]const u8{ "2026", "D:202", "D:20261", "D:2026abc", "D:20261127Zx" }) |bad| {
        try testing.expectError(error.BadValue, builder.setInfo(.{ .created = bad }));
    }
    try testing.expectError(error.BadValue, builder.setInfo(.{ .title = "\xff" }));
    // A refused call leaves what was set.
    var page = try open(a, try written(a, &builder), 0);
    const info = page.doc.getDict(page.doc.trailer, "Info").?;
    try testing.expectEqualStrings("R\u{e9}sum\u{e9} \u{2013} 2026", try pdf.write.textToUtf8(a, page.doc.get(info, "Title").?.string));
    try testing.expectEqualStrings("Somebody", page.doc.get(info, "Author").?.string);
    try testing.expectEqualStrings("D:20261127120000+01'00'", page.doc.get(info, "CreationDate").?.string);
    try testing.expectEqualStrings("D:2026", page.doc.get(info, "ModDate").?.string);
    try testing.expect(!info.has("Subject"));
    // None given, none written.
    try builder.setInfo(.{});
    page = try open(a, try written(a, &builder), 0);
    try testing.expect(page.doc.trailer.get("Info") == null);
}

test "a page that does not fit leaves the builder as it was" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var noise: [3000]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(5);
    prng.random().bytes(&noise);
    var image = try draw.Image.fromPixels(testing.allocator, .{ .width = 50, .height = 60, .format = .gray, .samples = &noise });
    defer image.deinit();
    var canvas = try Canvas.init(testing.allocator, 100, 100);
    defer canvas.deinit();
    try canvas.image(&image, 0, 0, 50, 60);
    try canvas.text(.courier, 10, 0, 90, "x");
    var builder = Builder.init(testing.allocator, .{});
    defer builder.deinit();
    try builder.addBlankPage(10, 10);
    const before = try written(a, &builder);
    builder.options.max_bytes = 2000;
    try testing.expectError(error.TooLarge, builder.addPage(&canvas));
    builder.options.max_bytes = 1 << 30;
    try testing.expectEqualSlices(u8, before, try written(a, &builder));
    // What the failed page had made is made again.
    try builder.addPage(&canvas);
    var page = try open(a, try written(a, &builder), 1);
    try testing.expectEqualStrings("x\n", try page.text(a));
    try testing.expectEqual(@as(u32, 50), (try page.nth(.image, 0)).width);
}

fn drawUnderAllocationFailure(gpa: Allocator) !void {
    var image = try draw.Image.fromPixels(gpa, .{ .width = 2, .height = 1, .format = .gray, .samples = "ab", .alpha = "cd" });
    defer image.deinit();
    var canvas = try Canvas.init(gpa, 100, 100);
    defer canvas.deinit();
    try canvas.save();
    try canvas.setAlpha(0.5, 1);
    try canvas.setDash(&.{2}, 0);
    try canvas.image(&image, 0, 0, 9, 9);
    try canvas.text(.helvetica, 10, 5, 50, "words");
    try canvas.restore();
    var builder = Builder.init(gpa, .{});
    defer builder.deinit();
    try builder.setInfo(.{ .title = "t" });
    try builder.addPage(&canvas);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try builder.write(&out.writer);
}

test "every failed allocation while drawing is reported" {
    try testing.checkAllAllocationFailures(testing.allocator, drawUnderAllocationFailure, .{});
}

// ---- stamping existing pages ---------------------------------------------------------------

const buildFile = @import("interp_tests.zig").buildFile;

/// `n` pages with the entries `extra`, each showing the content `body` with
/// font /F1 and a form already named /PzF0.
fn existing(a: Allocator, n: usize, extra: []const u8, body: []const u8) ![]const u8 {
    var bodies: std.ArrayList([]const u8) = .empty;
    var kids: std.ArrayList(u8) = .empty;
    for (0..n) |i| try kids.print(a, "{d} 0 R ", .{i + 6});
    try bodies.append(a, "<< /Type /Catalog /Pages 2 0 R >>");
    try bodies.append(a, try std.fmt.allocPrint(a, "<< /Type /Pages /Kids [{s}] /Count {d} /MediaBox [0 0 300 400] /Resources << /Font << /F1 4 0 R >> /XObject << /PzF0 5 0 R >> >> >>", .{ kids.items, n }));
    try bodies.append(a, try std.fmt.allocPrint(a, "<< /Length {d} >>\nstream\n{s}\nendstream", .{ body.len, body }));
    try bodies.append(a, "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>");
    try bodies.append(a, "<< /Type /XObject /Subtype /Form /BBox [0 0 1 1] /Length 0 >>\nstream\n\nendstream");
    for (0..n) |_| try bodies.append(a, try std.fmt.allocPrint(a, "<< /Type /Page /Parent 2 0 R /Contents 3 0 R {s} >>", .{extra}));
    return buildFile(a, bodies.items);
}

const body_text = "BT /F1 12 Tf 60 100 Td (underneath) Tj ET";

fn mark(canvas: *Canvas) !void {
    try canvas.setFill(.{ .rgb = .{ 1, 0, 0 } });
    try canvas.rect(20, 30, 40, 10);
    try canvas.fill(.nonzero);
    try canvas.text(.helvetica, 10, 25, 60, "STAMP");
}

/// Applies `canvas` to every page of `bytes` and returns the saved file.
fn stamped(a: Allocator, bytes: []const u8, canvas: *const Canvas, layer: draw.Layer) ![]const u8 {
    var doc = try pdf.Document.open(a, bytes, .{});
    const list = try pdf.pages.PageList.build(&doc);
    var upd = try pdf.write.Update.init(testing.allocator, &doc);
    defer upd.deinit();
    var stamp: draw.Stamp = .init(&upd);
    for (0..list.entries.len) |i| try stamp.place(pdf.pages.page(&doc, list, i).?, canvas, layer);
    try stamp.finish();
    var out: std.Io.Writer.Allocating = .init(a);
    try upd.write(testing.allocator, &out.writer);
    try testing.expect(std.mem.startsWith(u8, out.written(), bytes));
    return out.written();
}

/// The stamp's fill and its text as they are seen.
fn expectStamp(page: *const Page) !void {
    var found_box = false;
    var found_text = false;
    for (page.list.commands) |c| switch (c) {
        .fill => |f| if (f.paint == .color and f.paint.color.r == 1 and f.paint.color.g == 0) {
            var min: display.Point = .{ .x = 1e9, .y = 1e9 };
            var max: display.Point = .{ .x = -1e9, .y = -1e9 };
            for (f.path) |segment| if (segment == .move or segment == .line) {
                const raw = if (segment == .move) segment.move else segment.line;
                const p = page.seen(f.ctm, raw.x, raw.y);
                min = .{ .x = @min(min.x, p.x), .y = @min(min.y, p.y) };
                max = .{ .x = @max(max.x, p.x), .y = @max(max.y, p.y) };
            };
            try expectAt(20, 30, min);
            try expectAt(60, 40, max);
            found_box = true;
        },
        .text => |t| if (t.glyphs.len == 5) {
            const m = t.tm.mul(t.ctm);
            try expectAt(25, 60, page.seen(m, 0, 0));
            // Upright and reading to the right, one point to the point.
            const right = page.seen(m, 1, 0);
            const up = page.seen(m, 0, 1);
            try expectAt(26, 60, right);
            try expectAt(25, 59, up);
            found_text = true;
        },
        else => {},
    };
    try testing.expect(found_box and found_text);
}

test "a stamp lies on the page as seen, whatever its rotation, crop box and unit" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var canvas = try Canvas.init(testing.allocator, 200, 100);
    defer canvas.deinit();
    try mark(&canvas);
    for ([_][]const u8{
        "",                         "/Rotate 90",                          "/Rotate 180", "/Rotate 270",
        "/CropBox [15 25 275 365]", "/Rotate 90 /CropBox [15 25 275 365]", "/UserUnit 2", "/Rotate 270 /UserUnit 2.5 /CropBox [15 25 275 365]",
    }) |extra| {
        const bytes = try existing(a, 1, extra, body_text);
        const before = try open(a, bytes, 0);
        const after = try open(a, try stamped(a, bytes, &canvas, .over), 0);
        try expectStamp(&after);
        // What was there is where it was.
        const was = try before.nth(.text, 0);
        const is = try after.nth(.text, 0);
        try testing.expectEqual(before.seen(was.tm.mul(was.ctm), 0, 0), after.seen(is.tm.mul(is.ctm), 0, 0));
        try testing.expectEqualStrings("underneath", blk: {
            var shown: std.ArrayList(u8) = .empty;
            for (is.glyphs) |g| try shown.appendSlice(a, g.text);
            break :blk shown.items;
        });
    }
}

test "over comes after the page's content and under before it, whatever that content leaves open" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var canvas = try Canvas.init(testing.allocator, 200, 100);
    defer canvas.deinit();
    try mark(&canvas);
    for ([_][]const u8{
        body_text,
        body_text ++ " q 3 0 0 3 5 5 cm 0 1 0 rg",
        "Q " ++ body_text ++ " 2 0 0 2 9 9 cm",
        "q 9 0 0 9 0 0 cm Q Q Q " ++ body_text ++ " q 4 0 0 4 0 0 cm 50 Tz 3 Tr",
    }) |left| {
        const bytes = try existing(a, 1, "", left);
        for ([_]draw.Layer{ .over, .under }) |layer| {
            const page = try open(a, try stamped(a, bytes, &canvas, layer), 0);
            try expectStamp(&page);
            var order: std.ArrayList(usize) = .empty;
            for (page.list.commands) |c| if (c == .text) try order.append(a, c.text.glyphs.len);
            try testing.expectEqualSlices(usize, if (layer == .over) &.{ 10, 5 } else &.{ 5, 10 }, order.items);
        }
    }
}

test "one canvas on many pages is stored once, with names the pages do not use" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var image = try draw.Image.fromJpeg(testing.allocator, @embedFile("jpeg_rgb.jpg"));
    defer image.deinit();
    var doc = try pdf.Document.open(a, try existing(a, 4, "", body_text), .{});
    const list = try pdf.pages.PageList.build(&doc);
    var upd = try pdf.write.Update.init(testing.allocator, &doc);
    defer upd.deinit();
    var stamp: draw.Stamp = .init(&upd);
    {
        var shared = try Canvas.init(testing.allocator, 300, 400);
        defer shared.deinit();
        try shared.image(&image, 0, 0, 16, 8);
        try shared.setAlpha(0.5, 0.5);
        try shared.text(.helvetica, 10, 25, 60, "STAMP");
        for (0..4) |i| try stamp.place(pdf.pages.page(&doc, list, i).?, &shared, .over);
        // The canvas changed: another form, which shares the font and image.
        try shared.text(.helvetica, 10, 25, 80, "MORE");
        try stamp.place(pdf.pages.page(&doc, list, 0).?, &shared, .under);
    }
    // The canvas is gone before the update is written.
    try stamp.finish();
    var out: std.Io.Writer.Allocating = .init(a);
    try upd.write(testing.allocator, &out.writer);
    var forms: usize = 0;
    var images: usize = 0;
    var fonts: usize = 0;
    var first = try open(a, out.written(), 0);
    var it = first.doc.xref.iterator();
    while (it.next()) |entry| {
        const d = first.doc.getObject(entry.key_ptr.*).asDict() orelse continue;
        const subtype = first.doc.getName(d, "Subtype") orelse continue;
        if (std.mem.eql(u8, subtype, "Form")) forms += 1;
        if (std.mem.eql(u8, subtype, "Image")) images += 1;
        if (std.mem.eql(u8, subtype, "Type1")) fonts += 1;
    }
    // Two stamps and the form that was there; one image; the page's font and ours.
    try testing.expectEqual(@as(usize, 3), forms);
    try testing.expectEqual(@as(usize, 1), images);
    try testing.expectEqual(@as(usize, 2), fonts);
    for (0..4) |i| {
        const page = try open(a, out.written(), i);
        // In drawing order: the first page has one stamp behind the other.
        const text = try pdf.text.extract(a, &page.list, .content);
        try testing.expect(std.mem.indexOf(u8, text, "STAMP") != null and std.mem.indexOf(u8, text, "underneath") != null);
        try testing.expectEqual(i == 0, std.mem.indexOf(u8, text, "MORE") != null);
        try testing.expectEqual(@as(f64, 0.5), (try page.nth(.text, if (i == 0) 3 else 1)).alpha);
        // The page's own /PzF0 still means what it did.
        try testing.expectEqual(@as(u32, 5), page.page.resources.get("XObject").?.dict.get("PzF0").?.ref.num);
    }
}

test "stamps work with other edits of the same update" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try pdf.Document.open(a, try existing(a, 1, "/Annots [<< /Type /Annot /Subtype /Widget /FT /Tx /V (filled in) /Rect [10 300 90 320] >>]", body_text), .{});
    const page = pdf.pages.page(&doc, try pdf.pages.PageList.build(&doc), 0).?;
    var upd = try pdf.write.Update.init(testing.allocator, &doc);
    defer upd.deinit();
    var canvas = try Canvas.init(testing.allocator, 300, 400);
    defer canvas.deinit();
    try mark(&canvas);
    _ = try pdf.flatten.widgets(&upd, page);
    var stamp: draw.Stamp = .init(&upd);
    try stamp.place(page, &canvas, .over);
    _ = try pdf.annot.addNote(&upd, page, 5, 5, .{ .contents = "n" });
    try stamp.finish();
    var out: std.Io.Writer.Allocating = .init(a);
    try upd.write(testing.allocator, &out.writer);
    const after = try open(a, out.written(), 0);
    try expectStamp(&after);
    const text = try after.text(a);
    for ([_][]const u8{ "filled in", "underneath", "STAMP" }) |want| try testing.expect(std.mem.indexOf(u8, text, want) != null);
    try testing.expectEqual(@as(usize, 1), (try pdf.annot.list(a, after.doc, after.page)).len);
}

test "what cannot be stamped is refused and the page is left alone" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try pdf.Document.open(a, try buildFile(a, &.{
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R << /Type /Page /Parent 2 0 R >>] /Count 2 /MediaBox [0 0 99 99] >>",
        "<< /Type /Page /Parent 2 0 R /Contents 4 0 R >>",
        "<< /Filter /NoSuchDecode /Length 1 >>\nstream\nx\nendstream",
    }), .{});
    const list = try pdf.pages.PageList.build(&doc);
    var upd = try pdf.write.Update.init(testing.allocator, &doc);
    defer upd.deinit();
    var stamp: draw.Stamp = .init(&upd);
    var canvas = try Canvas.init(testing.allocator, 99, 99);
    defer canvas.deinit();
    try canvas.moveTo(1, 1);
    try testing.expectError(error.PathOpen, stamp.place(pdf.pages.page(&doc, list, 0).?, &canvas, .over));
    try canvas.stroke();
    // Content that cannot be read: nothing can safely go over it.
    try testing.expectError(error.UnreadableContent, stamp.place(pdf.pages.page(&doc, list, 0).?, &canvas, .over));
    try testing.expect(!upd.changed.contains(3));
    try testing.expectError(error.DirectPage, stamp.place(pdf.pages.page(&doc, list, 1).?, &canvas, .over));
    // Under it needs no reading.
    try stamp.place(pdf.pages.page(&doc, list, 0).?, &canvas, .under);
    try testing.expect(upd.changed.contains(3));
}

test "stamping a damaged file fails or succeeds, and never crashes (seeded mutation)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const base = try existing(arena.allocator(), 2, "/Rotate 90 /CropBox [5 5 200 300] /UserUnit 2", "q " ++ body_text);
    var prng = std.Random.DefaultPrng.init(0x57a9);
    const random = prng.random();
    const copy = try testing.allocator.dupe(u8, base);
    defer testing.allocator.free(copy);
    var canvas = try Canvas.init(testing.allocator, 100, 100);
    defer canvas.deinit();
    try mark(&canvas);
    for (0..1500) |_| {
        @memcpy(copy, base);
        for (0..random.intRangeAtMost(usize, 1, 4)) |_| {
            copy[random.uintLessThan(usize, copy.len)] = "0123456789()<>[]/ .-RqQ"[random.uintLessThan(usize, 22)];
        }
        var each = std.heap.ArenaAllocator.init(testing.allocator);
        defer each.deinit();
        const a = each.allocator();
        var doc = pdf.Document.open(a, copy, .{}) catch continue;
        const list = pdf.pages.PageList.build(&doc) catch continue;
        var upd = pdf.write.Update.init(testing.allocator, &doc) catch continue;
        defer upd.deinit();
        var stamp: draw.Stamp = .init(&upd);
        for (0..list.entries.len) |i| {
            const page = pdf.pages.page(&doc, list, i) orelse continue;
            stamp.place(page, &canvas, if (random.boolean()) .over else .under) catch continue;
        }
        var out: std.Io.Writer.Allocating = .init(a);
        upd.write(testing.allocator, &out.writer) catch continue;
        var again = pdf.Document.open(a, out.written(), .{}) catch continue;
        const pages_again = pdf.pages.PageList.build(&again) catch continue;
        var renderer = pdf.Renderer.init(&again, .{});
        _ = renderer.render(a, pdf.pages.page(&again, pages_again, 0) orelse continue) catch continue;
    }
}

fn stampUnderAllocationFailure(gpa: Allocator, bytes: []const u8) !void {
    var doc = try pdf.Document.open(gpa, bytes, .{});
    defer doc.deinit();
    const list = try pdf.pages.PageList.build(&doc);
    var upd = try pdf.write.Update.init(gpa, &doc);
    defer upd.deinit();
    var image = try draw.Image.fromPixels(gpa, .{ .width = 1, .height = 1, .format = .gray, .samples = "a", .alpha = "b" });
    defer image.deinit();
    var canvas = try Canvas.init(gpa, 100, 100);
    defer canvas.deinit();
    try mark(&canvas);
    try canvas.image(&image, 0, 0, 5, 5);
    var stamp: draw.Stamp = .init(&upd);
    try stamp.place(pdf.pages.page(&doc, list, 0).?, &canvas, .over);
    try stamp.finish();
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try upd.write(gpa, &out.writer);
    // A failed allocation must not have dropped the old content or the new.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const after = try open(arena.allocator(), out.written(), 0);
    const text = try after.text(arena.allocator());
    try testing.expect(std.mem.indexOf(u8, text, "underneath") != null and std.mem.indexOf(u8, text, "STAMP") != null);
}

test "every failed allocation while stamping is reported" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.checkAllAllocationFailures(testing.allocator, stampUnderAllocationFailure, .{try existing(arena.allocator(), 1, "", body_text)});
}
