//! Annotations (ISO 32000-1:2008, 12.5): reading the annotations of a page and
//! creating text markup (highlight, underline, strike-out) and text notes.
//!
//! These are real PDF annotations. Each one gets an appearance stream, so
//! every viewer draws it, and the page's `/Annots` array points at it. Writing
//! goes through `write.Update`: the file is extended, never rewritten.
//!
//! Coordinates. Reading returns rectangles in the page's *user space* (the
//! PDF's own, y up). Creating takes rectangles on the *displayed page* (points,
//! top left origin, y down, the space `text.Layout` and `DisplayList.base`
//! use) and converts them with the page's base matrix.

const std = @import("std");
const Allocator = std.mem.Allocator;
const object = @import("object.zig");
const document = @import("document.zig");
const pages = @import("pages.zig");
const display = @import("display.zig");
const interp = @import("interp.zig");
const text = @import("text.zig");
const write = @import("write.zig");

const Object = object.Object;
const Dict = object.Dict;
const Ref = object.Ref;
const Document = document.Document;
const Update = write.Update;

pub const Kind = enum { highlight, underline, strikeout, squiggly, note, free_text, ink, link, widget, popup, other };

fn kindOf(subtype: []const u8) Kind {
    const map = .{
        .{ "Highlight", Kind.highlight },
        .{ "Underline", Kind.underline },
        .{ "StrikeOut", Kind.strikeout },
        .{ "Squiggly", Kind.squiggly },
        .{ "Text", Kind.note },
        .{ "FreeText", Kind.free_text },
        .{ "Ink", Kind.ink },
        .{ "Link", Kind.link },
        .{ "Widget", Kind.widget },
        .{ "Popup", Kind.popup },
    };
    inline for (map) |m| if (std.mem.eql(u8, subtype, m[0])) return m[1];
    return .other;
}

fn subtypeOf(kind: Kind) []const u8 {
    return switch (kind) {
        .highlight => "Highlight",
        .underline => "Underline",
        .strikeout => "StrikeOut",
        .squiggly => "Squiggly",
        .note => "Text",
        else => "Text",
    };
}

pub const Annotation = struct {
    /// Object number, or 0 for a direct dictionary (which cannot be edited).
    num: u32,
    kind: Kind,
    subtype: []const u8,
    /// The annotation rectangle in user space.
    rect: pages.Rect,
    /// `/Contents` as UTF-8; empty when there is none.
    contents: []const u8,
    /// `/T`, the author, as UTF-8.
    author: []const u8,
    color: ?[3]f64,
    /// `/QuadPoints` of text markup, in user space, eight numbers per quad.
    quads: []const f64,
    flags: i64,
};

/// The annotations of `page`, in page order. Strings are allocated from `a`.
pub fn list(a: Allocator, doc: *Document, page: pages.Page) Allocator.Error![]Annotation {
    var out: std.ArrayList(Annotation) = .empty;
    errdefer out.deinit(a);
    const items = doc.getArray(page.dict, "Annots") orelse return out.toOwnedSlice(a);
    for (items) |item| {
        const d = doc.resolve(item).asDict() orelse continue;
        const sub = doc.getName(d, "Subtype") orelse continue;
        const r = rectOf(doc, d, "Rect") orelse continue;
        var color: ?[3]f64 = null;
        if (doc.getArray(d, "C")) |c| if (c.len == 3) {
            color = .{ doc.resolve(c[0]).asNum() orelse 0, doc.resolve(c[1]).asNum() orelse 0, doc.resolve(c[2]).asNum() orelse 0 };
        };
        var quads: []f64 = &.{};
        if (doc.getArray(d, "QuadPoints")) |q| {
            const n = q.len - q.len % 8;
            quads = try a.alloc(f64, n);
            for (q[0..n], 0..) |v, i| quads[i] = doc.resolve(v).asNum() orelse 0;
        }
        try out.append(a, .{
            .num = if (item == .ref) item.ref.num else 0,
            .kind = kindOf(sub),
            .subtype = try a.dupe(u8, sub),
            .rect = r,
            .contents = if (doc.get(d, "Contents")) |c| (if (c == .string) try write.textToUtf8(a, c.string) else "") else "",
            .author = if (doc.get(d, "T")) |c| (if (c == .string) try write.textToUtf8(a, c.string) else "") else "",
            .color = color,
            .quads = quads,
            .flags = doc.getInt(d, "F") orelse 0,
        });
    }
    return out.toOwnedSlice(a);
}

fn rectOf(doc: *Document, d: Dict, key: []const u8) ?pages.Rect {
    const arr = doc.getArray(d, key) orelse return null;
    if (arr.len < 4) return null;
    var v: [4]f64 = undefined;
    for (0..4) |i| v[i] = doc.resolve(arr[i]).asNum() orelse return null;
    return .{ .x0 = @min(v[0], v[2]), .y0 = @min(v[1], v[3]), .x1 = @max(v[0], v[2]), .y1 = @max(v[1], v[3]) };
}

pub const Error = write.Error || error{ DirectPage, NoSuchAnnotation, BadGeometry };

/// What a new annotation carries besides its shape.
pub const Meta = struct {
    /// Shown by viewers as the note's text or the markup's comment (UTF-8).
    contents: []const u8 = "",
    /// Who made it (UTF-8).
    author: []const u8 = "",
    /// Modification date as a PDF date string, e.g. `D:20261107120000Z`.
    date: ?[]const u8 = null,
    /// RGB, 0 to 1.
    color: [3]f64 = .{ 1, 0.92, 0.2 },
};

/// Adds a text markup annotation over `rects` (displayed-page rectangles, as
/// `text.Layout.rectsFor` returns them). Returns the new annotation.
pub fn addMarkup(upd: *Update, page: pages.Page, kind: Kind, rects: []const text.Rect, meta: Meta) Error!Ref {
    if (page.num == 0) return error.DirectPage;
    if (rects.len == 0) return error.BadGeometry;
    switch (kind) {
        .highlight, .underline, .strikeout, .squiggly => {},
        else => return error.BadGeometry,
    }
    const a = upd.allocator();
    const inv = interp.baseMatrix(page).invert() orelse return error.BadGeometry;

    // Quads in user space: top left, top right, bottom left, bottom right.
    const quads = try a.alloc(f64, rects.len * 8);
    var bx0 = std.math.inf(f64);
    var by0 = std.math.inf(f64);
    var bx1 = -std.math.inf(f64);
    var by1 = -std.math.inf(f64);
    for (rects, 0..) |r, i| {
        const tl = inv.apply(r.x0, r.y0);
        const tr = inv.apply(r.x1, r.y0);
        const bl = inv.apply(r.x0, r.y1);
        const br = inv.apply(r.x1, r.y1);
        // "Top" is the side of the glyph's top whatever the page rotation: order by user y.
        const pts = [4]display.Point{ tl, tr, bl, br };
        @memcpy(quads[i * 8 ..][0..8], &[8]f64{ pts[0].x, pts[0].y, pts[1].x, pts[1].y, pts[2].x, pts[2].y, pts[3].x, pts[3].y });
        for (pts) |p| {
            bx0 = @min(bx0, p.x);
            by0 = @min(by0, p.y);
            bx1 = @max(bx1, p.x);
            by1 = @max(by1, p.y);
        }
    }
    const rect = [4]f64{ bx0, by0, bx1, by1 };

    // The appearance: coloured quads multiplied onto the page, or lines.
    var ap: std.ArrayList(u8) = .empty;
    const c = meta.color;
    switch (kind) {
        .highlight => {
            try ap.print(a, "/GS gs {d:.3} {d:.3} {d:.3} rg\n", .{ c[0], c[1], c[2] });
            for (0..rects.len) |i| {
                const q = quads[i * 8 ..][0..8];
                try ap.print(a, "{d:.3} {d:.3} m {d:.3} {d:.3} l {d:.3} {d:.3} l {d:.3} {d:.3} l h f\n", .{ q[0], q[1], q[2], q[3], q[6], q[7], q[4], q[5] });
            }
        },
        else => {
            try ap.print(a, "{d:.3} {d:.3} {d:.3} RG 1 w\n", .{ c[0], c[1], c[2] });
            for (0..rects.len) |i| {
                const q = quads[i * 8 ..][0..8];
                // Bottom edge for underline and squiggly, the middle for strike-out.
                const mid = kind == .strikeout;
                const lx = if (mid) (q[0] + q[4]) / 2 else q[4];
                const ly = if (mid) (q[1] + q[5]) / 2 else q[5];
                const rx = if (mid) (q[2] + q[6]) / 2 else q[6];
                const ry = if (mid) (q[3] + q[7]) / 2 else q[7];
                try ap.print(a, "{d:.3} {d:.3} m {d:.3} {d:.3} l S\n", .{ lx, ly, rx, ry });
            }
        },
    }
    const gs = try write.makeDict(a, &.{ .{ "Type", .{ .name = "ExtGState" } }, .{ "BM", .{ .name = "Multiply" } } });
    const gs_map = try write.makeDict(a, &.{.{ "GS", .{ .dict = gs } }});
    const res = try write.makeDict(a, &.{.{ "ExtGState", .{ .dict = gs_map } }});
    const form_dict = try write.makeDict(a, &.{
        .{ "Type", .{ .name = "XObject" } },
        .{ "Subtype", .{ .name = "Form" } },
        .{ "BBox", try write.numbers(a, &rect) },
        .{ "Resources", .{ .dict = res } },
    });
    const form = try upd.add(.{ .stream = .{ .dict = form_dict, .data = ap.items } });

    var entries: std.ArrayList(object.Entry) = .empty;
    try entries.append(a, .{ .key = "Type", .value = .{ .name = "Annot" } });
    try entries.append(a, .{ .key = "Subtype", .value = .{ .name = subtypeOf(kind) } });
    try entries.append(a, .{ .key = "Rect", .value = try write.numbers(a, &rect) });
    try entries.append(a, .{ .key = "QuadPoints", .value = try write.numbers(a, quads) });
    try entries.append(a, .{ .key = "C", .value = try write.numbers(a, &c) });
    try entries.append(a, .{ .key = "F", .value = .{ .integer = 4 } }); // Print
    try appendMeta(a, &entries, meta);
    const ap_dict = try write.makeDict(a, &.{.{ "N", .{ .ref = form } }});
    try entries.append(a, .{ .key = "AP", .value = .{ .dict = ap_dict } });
    const annot = try upd.add(.{ .dict = .{ .entries = entries.items } });
    try attachToPage(upd, page, annot);
    return annot;
}

/// Adds a sticky note whose top left corner is at (`x`, `y`) on the displayed page.
pub fn addNote(upd: *Update, page: pages.Page, x: f64, y: f64, meta: Meta) Error!Ref {
    if (page.num == 0) return error.DirectPage;
    const a = upd.allocator();
    const inv = interp.baseMatrix(page).invert() orelse return error.BadGeometry;
    const p = inv.apply(x, y);
    // The icon is 20 x 20 points hanging down from the click (NoZoom and
    // NoRotate keep it that size and upright, anchored at the top left).
    const rect = [4]f64{ p.x, p.y - 20, p.x + 20, p.y };

    const c = meta.color;
    const ap = try std.fmt.allocPrint(a,
        \\{d:.3} {d:.3} {d:.3} rg 0.35 0.3 0 RG 1 w
        \\0.5 4.5 19 15 re B
        \\0.2 g 4 15 m 16 15 l S 4 11 m 16 11 l S 4 7 m 11 7 l S
        \\
    , .{ c[0], c[1], c[2] });
    const form_dict = try write.makeDict(a, &.{
        .{ "Type", .{ .name = "XObject" } },
        .{ "Subtype", .{ .name = "Form" } },
        .{ "BBox", try write.numbers(a, &.{ 0, 0, 20, 20 }) },
    });
    const form = try upd.add(.{ .stream = .{ .dict = form_dict, .data = ap } });

    var entries: std.ArrayList(object.Entry) = .empty;
    try entries.append(a, .{ .key = "Type", .value = .{ .name = "Annot" } });
    try entries.append(a, .{ .key = "Subtype", .value = .{ .name = "Text" } });
    try entries.append(a, .{ .key = "Rect", .value = try write.numbers(a, &rect) });
    try entries.append(a, .{ .key = "Name", .value = .{ .name = "Note" } });
    try entries.append(a, .{ .key = "C", .value = try write.numbers(a, &c) });
    try entries.append(a, .{ .key = "F", .value = .{ .integer = 4 | 8 | 16 } }); // Print, NoZoom, NoRotate
    try appendMeta(a, &entries, meta);
    const ap_dict = try write.makeDict(a, &.{.{ "N", .{ .ref = form } }});
    try entries.append(a, .{ .key = "AP", .value = .{ .dict = ap_dict } });
    const annot = try upd.add(.{ .dict = .{ .entries = entries.items } });
    try attachToPage(upd, page, annot);
    return annot;
}

fn appendMeta(a: Allocator, entries: *std.ArrayList(object.Entry), meta: Meta) Allocator.Error!void {
    if (meta.contents.len > 0) try entries.append(a, .{ .key = "Contents", .value = .{ .string = try write.textString(a, meta.contents) } });
    if (meta.author.len > 0) try entries.append(a, .{ .key = "T", .value = .{ .string = try write.textString(a, meta.author) } });
    if (meta.date) |d| {
        try entries.append(a, .{ .key = "M", .value = .{ .string = try a.dupe(u8, d) } });
        try entries.append(a, .{ .key = "CreationDate", .value = .{ .string = try a.dupe(u8, d) } });
    }
}

/// Appends `annot` to the page's `/Annots`, wherever that array lives.
fn attachToPage(upd: *Update, page: pages.Page, annot: Ref) Error!void {
    const a = upd.allocator();
    const page_dict = upd.get(page.num).asDict() orelse return error.DirectPage;
    const existing = page_dict.get("Annots");
    if (existing) |e| if (e == .ref) {
        // The array is its own object: change that object.
        const items = upd.get(e.ref.num).asArray() orelse &[_]Object{};
        const grown = try a.alloc(Object, items.len + 1);
        @memcpy(grown[0..items.len], items);
        grown[items.len] = .{ .ref = annot };
        try upd.set(e.ref.num, .{ .array = grown });
        return;
    };
    const items = if (existing) |e| (e.asArray() orelse &[_]Object{}) else &[_]Object{};
    const grown = try a.alloc(Object, items.len + 1);
    @memcpy(grown[0..items.len], items);
    grown[items.len] = .{ .ref = annot };
    try upd.set(page.num, .{ .dict = try write.dictWith(a, page_dict, "Annots", .{ .array = grown }) });
}

/// Changes the text of annotation `num` (its `/Contents`).
pub fn setContents(upd: *Update, num: u32, contents: []const u8, date: ?[]const u8) Error!void {
    const a = upd.allocator();
    var d = upd.get(num).asDict() orelse return error.NoSuchAnnotation;
    d = try write.dictWith(a, d, "Contents", .{ .string = try write.textString(a, contents) });
    if (date) |m| d = try write.dictWith(a, d, "M", .{ .string = try a.dupe(u8, m) });
    try upd.set(num, .{ .dict = d });
}

/// Removes annotation `num` from the page. The object stays in the file but
/// nothing refers to it any more.
pub fn remove(upd: *Update, page: pages.Page, num: u32) Error!void {
    if (page.num == 0) return error.DirectPage;
    const a = upd.allocator();
    const page_dict = upd.get(page.num).asDict() orelse return error.DirectPage;
    const existing = page_dict.get("Annots") orelse return error.NoSuchAnnotation;
    var holder: ?u32 = null;
    var items: []const Object = &.{};
    if (existing == .ref) {
        holder = existing.ref.num;
        items = upd.get(existing.ref.num).asArray() orelse return error.NoSuchAnnotation;
    } else items = existing.asArray() orelse return error.NoSuchAnnotation;

    var kept: std.ArrayList(Object) = .empty;
    var found = false;
    for (items) |it| {
        if (it == .ref and it.ref.num == num) {
            found = true;
            continue;
        }
        try kept.append(a, it);
    }
    if (!found) return error.NoSuchAnnotation;
    if (holder) |h| {
        try upd.set(h, .{ .array = kept.items });
    } else {
        try upd.set(page.num, .{ .dict = try write.dictWith(a, page_dict, "Annots", .{ .array = kept.items }) });
    }
}

// ---- tests -----------------------------------------------------------------------------------

const testing = std.testing;
const tests = @import("interp_tests.zig");
const Io = std.Io;

fn roundTrip(a: Allocator, upd: *Update, out: *Io.Writer.Allocating) !void {
    try upd.write(a, &out.writer);
}

test "a highlight is written, read back and drawn" {
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const bytes = try tests.page(arena.allocator(), "BT /F1 12 Tf 10 50 Td (Hello world) Tj ET", "/Font << /F1 5 0 R >>", &.{"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"}, "");

    var doc = try Document.open(a, bytes, .{});
    defer doc.deinit();
    var pl = try pages.PageList.build(&doc);
    const page = pages.page(&doc, pl, 0).?;
    _ = &pl;

    var upd = try Update.init(a, &doc);
    defer upd.deinit();
    // The word "Hello" on the displayed page: the page is 100 high, the baseline at y = 50 from the bottom.
    const rect: text.Rect = .{ .x0 = 10, .y0 = 40, .x1 = 40, .y1 = 52 };
    const ref = try addMarkup(&upd, page, .highlight, &.{rect}, .{ .contents = "check this", .author = "Dakota", .color = .{ 1, 1, 0 } });
    var out: Io.Writer.Allocating = .init(a);
    defer out.deinit();
    try roundTrip(a, &upd, &out);

    var doc2 = try Document.open(a, out.written(), .{});
    defer doc2.deinit();
    try testing.expect(!doc2.repaired);
    const pl2 = try pages.PageList.build(&doc2);
    const page2 = pages.page(&doc2, pl2, 0).?;
    const found = try list(arena.allocator(), &doc2, page2);
    try testing.expectEqual(@as(usize, 1), found.len);
    try testing.expectEqual(Kind.highlight, found[0].kind);
    try testing.expectEqual(ref.num, found[0].num);
    try testing.expectEqualStrings("check this", found[0].contents);
    try testing.expectEqualStrings("Dakota", found[0].author);
    try testing.expectEqual(@as(usize, 8), found[0].quads.len);
    // User space: y from the bottom, so the rectangle (y 40..52 from the top) is 48..60.
    try testing.expectApproxEqAbs(@as(f64, 48), found[0].rect.y0, 0.01);
    try testing.expectApproxEqAbs(@as(f64, 60), found[0].rect.y1, 0.01);

    // Drawn: the page text plus a multiplied fill.
    var rend = pdf_renderer(&doc2);
    defer rend.deinit();
    var dl = try rend.render(a, page2);
    defer dl.deinit();
    var fills: usize = 0;
    for (dl.commands) |c| switch (c) {
        .fill => |f| {
            fills += 1;
            try testing.expectEqualStrings("Multiply", f.blend);
        },
        else => {},
    };
    try testing.expectEqual(@as(usize, 1), fills);
}

fn pdf_renderer(doc: *Document) interp.Renderer {
    return interp.Renderer.init(doc, .{});
}

test "a note, then its text edited, then removed" {
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const bytes = try tests.page(arena.allocator(), "0 g", "", &.{}, "");

    var doc = try Document.open(a, bytes, .{});
    defer doc.deinit();
    const pl = try pages.PageList.build(&doc);
    const page = pages.page(&doc, pl, 0).?;
    var upd = try Update.init(a, &doc);
    defer upd.deinit();
    const note = try addNote(&upd, page, 30, 20, .{ .contents = "caf\u{e9}", .author = "me" });
    var out: Io.Writer.Allocating = .init(a);
    defer out.deinit();
    try upd.write(a, &out.writer);

    // Second revision on top of the first: edit the text.
    var doc2 = try Document.open(a, out.written(), .{});
    defer doc2.deinit();
    const pl2 = try pages.PageList.build(&doc2);
    const page2 = pages.page(&doc2, pl2, 0).?;
    var upd2 = try Update.init(a, &doc2);
    defer upd2.deinit();
    try setContents(&upd2, note.num, "changed \u{1F600}", null);
    var out2: Io.Writer.Allocating = .init(a);
    defer out2.deinit();
    try upd2.write(a, &out2.writer);

    var doc3 = try Document.open(a, out2.written(), .{});
    defer doc3.deinit();
    const pl3 = try pages.PageList.build(&doc3);
    const page3 = pages.page(&doc3, pl3, 0).?;
    const found = try list(arena.allocator(), &doc3, page3);
    try testing.expectEqual(@as(usize, 1), found.len);
    try testing.expectEqual(Kind.note, found[0].kind);
    try testing.expectEqualStrings("changed \u{1F600}", found[0].contents);
    // Anchored at the click: top left at y = 100 - 20 = 80 in user space.
    try testing.expectApproxEqAbs(@as(f64, 80), found[0].rect.y1, 0.01);
    try testing.expectApproxEqAbs(@as(f64, 30), found[0].rect.x0, 0.01);

    var upd3 = try Update.init(a, &doc3);
    defer upd3.deinit();
    try remove(&upd3, page3, note.num);
    var out3: Io.Writer.Allocating = .init(a);
    defer out3.deinit();
    try upd3.write(a, &out3.writer);
    var doc4 = try Document.open(a, out3.written(), .{});
    defer doc4.deinit();
    const pl4 = try pages.PageList.build(&doc4);
    const none = try list(arena.allocator(), &doc4, pages.page(&doc4, pl4, 0).?);
    try testing.expectEqual(@as(usize, 0), none.len);
    _ = page2;
}

test "markup with no rectangles or a wrong kind is refused" {
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const bytes = try tests.page(arena.allocator(), "0 g", "", &.{}, "");
    var doc = try Document.open(a, bytes, .{});
    defer doc.deinit();
    const pl = try pages.PageList.build(&doc);
    const page = pages.page(&doc, pl, 0).?;
    var upd = try Update.init(a, &doc);
    defer upd.deinit();
    try testing.expectError(error.BadGeometry, addMarkup(&upd, page, .highlight, &.{}, .{}));
    try testing.expectError(error.BadGeometry, addMarkup(&upd, page, .note, &.{.{ .x0 = 0, .y0 = 0, .x1 = 1, .y1 = 1 }}, .{}));
}
