// SPDX-License-Identifier: LGPL-2.0-or-later
//! Annotations (ISO 32000-1:2008, 12.5): reading the annotations of a page and
//! creating text markup (highlight, underline, strike-out), text notes,
//! free-hand ink and text boxes.
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
const forms = @import("form.zig");

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

/// Largest coordinate or size accepted from a caller; real pages are far smaller.
const max_coordinate = 1e7;

fn usable(values: []const f64) bool {
    // False for NaN too.
    for (values) |v| if (!(@abs(v) <= max_coordinate)) return false;
    return true;
}

/// `meta` with its colour components brought into 0 to 1.
fn checkedMeta(meta: Meta) Error!Meta {
    var out = meta;
    for (&out.color) |*c| {
        if (!std.math.isFinite(c.*)) return error.BadGeometry;
        c.* = std.math.clamp(c.*, 0, 1);
    }
    return out;
}

/// Adds a text markup annotation over `rects` (displayed-page rectangles, as
/// `text.Layout.rectsFor` returns them). Returns the new annotation.
pub fn addMarkup(upd: *Update, page: pages.Page, kind: Kind, rects: []const text.Rect, meta_in: Meta) Error!Ref {
    const meta = try checkedMeta(meta_in);
    for (rects) |r| if (!usable(&.{ r.x0, r.y0, r.x1, r.y1 })) return error.BadGeometry;
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
    // A line along an edge of the quads needs room for its own width, or the
    // appearance's box cuts it in half.
    const margin: f64 = if (kind == .highlight) 0 else 1;
    const rect = [4]f64{ bx0 - margin, by0 - margin, bx1 + margin, by1 + margin };

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
pub fn addNote(upd: *Update, page: pages.Page, x: f64, y: f64, meta_in: Meta) Error!Ref {
    const meta = try checkedMeta(meta_in);
    if (!usable(&.{ x, y })) return error.BadGeometry;
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

/// Adds free-hand ink: each stroke a list of points on the displayed page,
/// drawn `width` points wide with round ends in `meta.color`.
pub fn addInk(upd: *Update, page: pages.Page, strokes: []const []const display.Point, width: f64, meta_in: Meta) Error!Ref {
    const meta = try checkedMeta(meta_in);
    if (!(width > 0) or !usable(&.{width})) return error.BadGeometry;
    for (strokes) |st| for (st) |pt| if (!usable(&.{ pt.x, pt.y })) return error.BadGeometry;
    if (page.num == 0) return error.DirectPage;
    var points: usize = 0;
    for (strokes) |st| points += st.len;
    if (strokes.len == 0 or points == 0) return error.BadGeometry;
    const a = upd.allocator();
    const inv = interp.baseMatrix(page).invert() orelse return error.BadGeometry;

    // Strokes in user space, and their bounds widened by the line width.
    const ink = try a.alloc(Object, strokes.len);
    var bx0 = std.math.inf(f64);
    var by0 = std.math.inf(f64);
    var bx1 = -std.math.inf(f64);
    var by1 = -std.math.inf(f64);
    var ap: std.ArrayList(u8) = .empty;
    const c = meta.color;
    try ap.print(a, "{d:.3} {d:.3} {d:.3} RG {d:.2} w 1 J 1 j\n", .{ c[0], c[1], c[2], width });
    for (strokes, 0..) |st, si| {
        const nums = try a.alloc(f64, st.len * 2);
        for (st, 0..) |pt, i| {
            const u = inv.apply(pt.x, pt.y);
            nums[i * 2] = u.x;
            nums[i * 2 + 1] = u.y;
            bx0 = @min(bx0, u.x);
            by0 = @min(by0, u.y);
            bx1 = @max(bx1, u.x);
            by1 = @max(by1, u.y);
            try ap.print(a, "{d:.2} {d:.2} {s}\n", .{ u.x, u.y, if (i == 0) "m" else "l" });
        }
        // A single point still shows: a dot, as a zero-length round-capped line.
        if (st.len == 1) try ap.print(a, "{d:.2} {d:.2} l\n", .{ nums[0], nums[1] });
        try ap.appendSlice(a, "S\n");
        ink[si] = try write.numbers(a, nums);
    }
    const pad = width / 2 + 1;
    const rect = [4]f64{ bx0 - pad, by0 - pad, bx1 + pad, by1 + pad };

    const form_dict = try write.makeDict(a, &.{
        .{ "Type", .{ .name = "XObject" } },
        .{ "Subtype", .{ .name = "Form" } },
        .{ "BBox", try write.numbers(a, &rect) },
    });
    const ap_form = try upd.add(.{ .stream = .{ .dict = form_dict, .data = ap.items } });
    const bs = try write.makeDict(a, &.{.{ "W", .{ .real = width } }});

    var entries: std.ArrayList(object.Entry) = .empty;
    try entries.append(a, .{ .key = "Type", .value = .{ .name = "Annot" } });
    try entries.append(a, .{ .key = "Subtype", .value = .{ .name = "Ink" } });
    try entries.append(a, .{ .key = "Rect", .value = try write.numbers(a, &rect) });
    try entries.append(a, .{ .key = "InkList", .value = .{ .array = ink } });
    try entries.append(a, .{ .key = "BS", .value = .{ .dict = bs } });
    try entries.append(a, .{ .key = "C", .value = try write.numbers(a, &c) });
    try entries.append(a, .{ .key = "F", .value = .{ .integer = 4 } }); // Print
    try appendMeta(a, &entries, meta);
    const ap_dict = try write.makeDict(a, &.{.{ "N", .{ .ref = ap_form } }});
    try entries.append(a, .{ .key = "AP", .value = .{ .dict = ap_dict } });
    const annot = try upd.add(.{ .dict = .{ .entries = entries.items } });
    try attachToPage(upd, page, annot);
    return annot;
}

/// Adds a text box: `meta.contents` written in Helvetica at `size` points in
/// `meta.color`, wrapped to the box (`x`, `y`, `w`, `h` on the displayed page,
/// from its top left) and upright however the page is rotated. Line breaks are
/// kept; characters outside WinAnsi are drawn as `?` (the text itself keeps
/// them).
pub fn addFreeText(upd: *Update, page: pages.Page, x: f64, y: f64, w: f64, h: f64, size: f64, meta_in: Meta) Error!Ref {
    const meta = try checkedMeta(meta_in);
    if (!usable(&.{ x, y, w, h, size })) return error.BadGeometry;
    if (page.num == 0) return error.DirectPage;
    if (w <= 0 or h <= 0 or size <= 0) return error.BadGeometry;
    const a = upd.allocator();
    const inv = interp.baseMatrix(page).invert() orelse return error.BadGeometry;
    const p0 = inv.apply(x, y);
    const p1 = inv.apply(x + w, y + h);
    const rect = [4]f64{ @min(p0.x, p1.x), @min(p0.y, p1.y), @max(p0.x, p1.x), @max(p0.y, p1.y) };

    const c = meta.color;
    const color_ops = try std.fmt.allocPrint(a, "{d:.3} {d:.3} {d:.3} rg", .{ c[0], c[1], c[2] });
    const made = try freeTextAppearance(upd, rect, page.rotate, size, color_ops, meta.contents);
    const da = try std.fmt.allocPrint(a, "/Helv {d:.2} Tf {s}", .{ size, color_ops });
    const dr = try write.makeDict(a, &.{.{ "Font", .{ .dict = made.fonts } }});
    const border = try write.makeDict(a, &.{.{ "W", .{ .integer = 0 } }});

    var entries: std.ArrayList(object.Entry) = .empty;
    try entries.append(a, .{ .key = "Type", .value = .{ .name = "Annot" } });
    try entries.append(a, .{ .key = "Subtype", .value = .{ .name = "FreeText" } });
    try entries.append(a, .{ .key = "Rect", .value = try write.numbers(a, &rect) });
    try entries.append(a, .{ .key = "DA", .value = .{ .string = da } });
    try entries.append(a, .{ .key = "DR", .value = .{ .dict = dr } });
    try entries.append(a, .{ .key = "BS", .value = .{ .dict = border } });
    try entries.append(a, .{ .key = "F", .value = .{ .integer = 4 } }); // Print
    if (page.rotate != 0) try entries.append(a, .{ .key = "Rotate", .value = .{ .integer = page.rotate } });
    try appendMeta(a, &entries, meta);
    const ap_dict = try write.makeDict(a, &.{.{ "N", .{ .ref = made.form } }});
    try entries.append(a, .{ .key = "AP", .value = .{ .dict = ap_dict } });
    const annot = try upd.add(.{ .dict = .{ .entries = entries.items } });
    try attachToPage(upd, page, annot);
    return annot;
}

const FreeTextAppearance = struct { form: Ref, fonts: Dict };

/// The appearance of a text box covering `rect` (user space) on a page turned
/// `rotate` degrees: `contents` laid out as it will be read, then turned in
/// user space so that the page's rotation brings it upright.
fn freeTextAppearance(upd: *Update, rect: [4]f64, rotate: u16, size: f64, color_ops: []const u8, contents: []const u8) Error!FreeTextAppearance {
    const a = upd.allocator();
    const sideways = rotate == 90 or rotate == 270;
    // The box's width and height as displayed.
    const bw = if (sideways) rect[3] - rect[1] else rect[2] - rect[0];
    const bh = if (sideways) rect[2] - rect[0] else rect[3] - rect[1];
    const matrix: [6]f64 = switch (rotate) {
        90 => .{ 0, 1, -1, 0, rect[2], rect[1] },
        180 => .{ -1, 0, 0, -1, rect[2], rect[3] },
        270 => .{ 0, -1, 1, 0, rect[0], rect[3] },
        else => .{ 1, 0, 0, 1, rect[0], rect[1] },
    };

    // Lines: the text's own breaks, then a wrap at spaces to fit the box.
    const pad = 2.0;
    const bytes = try forms.toWinAnsi(a, contents);
    var lines: std.ArrayList([]const u8) = .empty;
    var paras = std.mem.splitScalar(u8, bytes, '\n');
    while (paras.next()) |para| {
        try forms.wrapLine(a, &lines, para, bw - 2 * pad, size);
    }

    var ap: std.ArrayList(u8) = .empty;
    try ap.print(a, "q 0 0 {d:.2} {d:.2} re W n\nBT /Helv {d:.2} Tf {s}\n", .{ bw, bh, size, color_ops });
    const leading = size * 1.15;
    var baseline = bh - pad - size * 0.8;
    var first = true;
    for (lines.items) |line| {
        if (first) {
            try ap.print(a, "{d:.2} {d:.2} Td\n", .{ pad, baseline });
            first = false;
        } else try ap.print(a, "0 {d:.2} Td\n", .{-leading});
        var sb: std.Io.Writer.Allocating = .init(a);
        write.writeString(&sb.writer, line) catch return error.OutOfMemory;
        try ap.print(a, "{s} Tj\n", .{sb.written()});
        baseline -= leading;
    }
    try ap.appendSlice(a, "ET Q\n");

    const font = try write.makeDict(a, &.{
        .{ "Type", .{ .name = "Font" } },
        .{ "Subtype", .{ .name = "Type1" } },
        .{ "BaseFont", .{ .name = "Helvetica" } },
        .{ "Encoding", .{ .name = "WinAnsiEncoding" } },
    });
    const font_ref = try upd.add(.{ .dict = font });
    const fonts = try write.makeDict(a, &.{.{ "Helv", .{ .ref = font_ref } }});
    const res = try write.makeDict(a, &.{.{ "Font", .{ .dict = fonts } }});
    const form_dict = try write.makeDict(a, &.{
        .{ "Type", .{ .name = "XObject" } },
        .{ "Subtype", .{ .name = "Form" } },
        .{ "BBox", try write.numbers(a, &.{ 0, 0, bw, bh }) },
        .{ "Matrix", try write.numbers(a, &matrix) },
        .{ "Resources", .{ .dict = res } },
    });
    const form = try upd.add(.{ .stream = .{ .dict = form_dict, .data = ap.items } });
    return .{ .form = form, .fonts = fonts };
}

fn appendMeta(a: Allocator, entries: *std.ArrayList(object.Entry), meta: Meta) Allocator.Error!void {
    if (meta.contents.len > 0) try entries.append(a, .{ .key = "Contents", .value = .{ .string = try write.textString(a, meta.contents) } });
    if (meta.author.len > 0) try entries.append(a, .{ .key = "T", .value = .{ .string = try write.textString(a, meta.author) } });
    if (meta.date) |d| {
        try entries.append(a, .{ .key = "M", .value = .{ .string = try a.dupe(u8, d) } });
        try entries.append(a, .{ .key = "CreationDate", .value = .{ .string = try a.dupe(u8, d) } });
    }
}

/// The entries of the page's `/Annots`, wherever the array lives: direct, or an
/// object reached through references. Null when it does not lead to an array.
fn annotsOf(upd: *Update, value: Object) ?[]const Object {
    var cur = value;
    var hops: usize = 0;
    while (hops < 32) : (hops += 1) {
        switch (cur) {
            .array => |items| return items,
            .ref => |r| {
                if (r.num == 0 or r.num >= upd.next) return null;
                cur = upd.get(r.num);
            },
            else => return null,
        }
    }
    return null;
}

/// Appends `annot` to the page's annotations. The page gets an array of its
/// own: an array object may be shared with other pages, and a reference that
/// does not lead to an array must be left alone.
fn attachToPage(upd: *Update, page: pages.Page, annot: Ref) Error!void {
    const a = upd.allocator();
    const page_dict = upd.get(page.num).asDict() orelse return error.DirectPage;
    const items: []const Object = if (page_dict.get("Annots")) |existing| (annotsOf(upd, existing) orelse &.{}) else &.{};
    const grown = try a.alloc(Object, items.len + 1);
    @memcpy(grown[0..items.len], items);
    grown[items.len] = .{ .ref = annot };
    try upd.set(page.num, .{ .dict = try write.dictWith(a, page_dict, "Annots", .{ .array = grown }) });
}

/// Changes the text of annotation `num` (its `/Contents`). A text box gets a
/// new appearance in Helvetica with the size and colour of its `/DA`; any
/// other styling its old appearance had is not kept.
pub fn setContents(upd: *Update, num: u32, contents: []const u8, date: ?[]const u8) Error!void {
    const a = upd.allocator();
    // A dictionary of its own (not a stream, whose data would be lost) with an
    // annotation's subtype and rectangle.
    const target = upd.get(num);
    if (target != .dict or !target.dict.has("Subtype") or !target.dict.has("Rect")) return error.NoSuchAnnotation;
    var d = target.dict;
    d = try write.dictWith(a, d, "Contents", .{ .string = try write.textString(a, contents) });
    if (date) |m| d = try write.dictWith(a, d, "M", .{ .string = try a.dupe(u8, m) });
    // Rich text, which some viewers prefer, would still say the old thing.
    d = try write.dictWithout(a, d, "RC");
    // A text box shows its contents, so its appearance is made again.
    if (upd.doc.getName(d, "Subtype")) |subtype| if (std.mem.eql(u8, subtype, "FreeText")) {
        d = try redrawFreeText(upd, d, contents);
    };
    try upd.set(num, .{ .dict = d });
}

/// `d` with a new appearance showing `contents`, from its `/Rect`, `/DA` and
/// `/Rotate`.
fn redrawFreeText(upd: *Update, d: Dict, contents: []const u8) Error!Dict {
    const a = upd.allocator();
    const doc = upd.doc;
    const r = rectOf(doc, d, "Rect") orelse return error.BadGeometry;
    const da_text = if (doc.get(d, "DA")) |v| (if (v == .string) v.string else "") else "";
    const da = try forms.parseDa(a, da_text);
    const turn = @mod(doc.getInt(d, "Rotate") orelse 0, 360);
    const rotate: u16 = if (turn == 90 or turn == 180 or turn == 270) @intCast(turn) else 0;
    const made = try freeTextAppearance(upd, .{ r.x0, r.y0, r.x1, r.y1 }, rotate, if (da.size > 0) da.size else 12, da.color_ops, contents);
    const ap_dict = try write.makeDict(a, &.{.{ "N", .{ .ref = made.form } }});
    return write.dictWith(a, d, "AP", .{ .dict = ap_dict });
}

/// Whether `popup` is the popup window of annotation `num`.
fn isPopupOf(upd: *Update, popup: u32, num: u32) bool {
    const d = upd.get(popup).asDict() orelse return false;
    const subtype = upd.doc.getName(d, "Subtype") orelse return false;
    if (!std.mem.eql(u8, subtype, "Popup")) return false;
    if (d.get("Parent")) |parent| if (parent == .ref and parent.ref.num == num) return true;
    const owner = upd.get(num).asDict() orelse return false;
    const named = owner.get("Popup") orelse return false;
    return named == .ref and named.ref.num == popup;
}

/// Removes annotation `num` and its popup from the page. The object stays in the file but
/// nothing refers to it any more.
pub fn remove(upd: *Update, page: pages.Page, num: u32) Error!void {
    if (page.num == 0) return error.DirectPage;
    const a = upd.allocator();
    const page_dict = upd.get(page.num).asDict() orelse return error.DirectPage;
    const existing = page_dict.get("Annots") orelse return error.NoSuchAnnotation;
    const items = annotsOf(upd, existing) orelse return error.NoSuchAnnotation;

    var kept: std.ArrayList(Object) = .empty;
    var found = false;
    for (items) |it| {
        if (it == .ref and it.ref.num == num) {
            found = true;
            continue;
        }
        if (it == .ref and isPopupOf(upd, it.ref.num, num)) continue;
        try kept.append(a, it);
    }
    if (!found) return error.NoSuchAnnotation;
    try upd.set(page.num, .{ .dict = try write.dictWith(a, page_dict, "Annots", .{ .array = kept.items }) });
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

    try @import("interp_tests.zig").expectSoundFile(out.written());
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
    try @import("interp_tests.zig").expectSoundFile(out.written());
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

    try @import("interp_tests.zig").expectSoundFile(out2.written());
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
    try @import("interp_tests.zig").expectSoundFile(out3.written());
    var doc4 = try Document.open(a, out3.written(), .{});
    defer doc4.deinit();
    const pl4 = try pages.PageList.build(&doc4);
    const none = try list(arena.allocator(), &doc4, pages.page(&doc4, pl4, 0).?);
    try testing.expectEqual(@as(usize, 0), none.len);
    _ = page2;
}

test "ink and a text box are written, read back and drawn" {
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
    const stroke = [_]display.Point{ .{ .x = 10, .y = 10 }, .{ .x = 30, .y = 20 }, .{ .x = 50, .y = 10 } };
    const dot = [_]display.Point{.{ .x = 60, .y = 60 }};
    _ = try addInk(&upd, page, &.{ &stroke, &dot }, 2, .{ .author = "Dakota", .color = .{ 0.9, 0.1, 0.1 } });
    _ = try addFreeText(&upd, page, 10, 30, 80, 40, 10, .{ .contents = "Due Friday\nsee page 2", .color = .{ 0, 0, 0.8 } });
    try testing.expectError(error.BadGeometry, addInk(&upd, page, &.{}, 2, .{}));
    try testing.expectError(error.BadGeometry, addFreeText(&upd, page, 0, 0, 0, 10, 10, .{}));
    var out: Io.Writer.Allocating = .init(a);
    defer out.deinit();
    try roundTrip(a, &upd, &out);

    try @import("interp_tests.zig").expectSoundFile(out.written());
    var doc2 = try Document.open(a, out.written(), .{});
    defer doc2.deinit();
    try testing.expect(!doc2.repaired);
    const pl2 = try pages.PageList.build(&doc2);
    const page2 = pages.page(&doc2, pl2, 0).?;
    const found = try list(arena.allocator(), &doc2, page2);
    try testing.expectEqual(@as(usize, 2), found.len);
    try testing.expectEqual(Kind.ink, found[0].kind);
    try testing.expectEqual(Kind.free_text, found[1].kind);
    try testing.expectEqualStrings("Due Friday\nsee page 2", found[1].contents);
    // The ink's bounds hold its points (displayed y 10..20, the page 100 high: user 80..90).
    try testing.expect(found[0].rect.y0 <= 80 and found[0].rect.y1 >= 90);

    // Both drawn through their appearances: two strokes, two lines of text.
    var rend = pdf_renderer(&doc2);
    defer rend.deinit();
    var dl = try rend.render(a, page2);
    defer dl.deinit();
    var strokes: usize = 0;
    var glyph_runs: usize = 0;
    for (dl.commands) |cmd| switch (cmd) {
        .stroke => strokes += 1,
        .text => glyph_runs += 1,
        else => {},
    };
    try testing.expectEqual(@as(usize, 2), strokes);
    try testing.expectEqual(@as(usize, 2), glyph_runs);
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

test "a bad /Annots reference never overwrites another object" {
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    // 0: the null object; 2: the page tree; 4: the content stream; 5: the first
    // free number (the new appearance stream gets it); 999: far beyond /Size.
    for ([_]u32{ 0, 2, 4, 5, 999 }) |target| {
        const entry = try std.fmt.allocPrint(aa, "/Annots {d} 0 R", .{target});
        const bytes = try tests.page(aa, "0 g", "", &.{}, entry);
        var doc = try Document.open(a, bytes, .{});
        defer doc.deinit();
        const pl = try pages.PageList.build(&doc);
        var upd = try Update.init(a, &doc);
        defer upd.deinit();
        const note = try addNote(&upd, pages.page(&doc, pl, 0).?, 10, 10, .{ .contents = "n" });
        var out: Io.Writer.Allocating = .init(a);
        defer out.deinit();
        try upd.write(a, &out.writer);
        try tests.expectSoundFile(out.written());

        var doc2 = try Document.open(a, out.written(), .{});
        defer doc2.deinit();
        try testing.expectEqualStrings("Pages", doc2.getName(doc2.getObject(2).asDict().?, "Type").?);
        try testing.expect(doc2.getObject(4) == .stream);
        try testing.expect(doc2.getObject(note.num - 1) == .stream);
        const pl2 = try pages.PageList.build(&doc2);
        const found = try list(aa, &doc2, pages.page(&doc2, pl2, 0).?);
        try testing.expectEqual(@as(usize, 1), found.len);
        try testing.expectEqual(note.num, found[0].num);
    }
}

test "an /Annots array behind a chain of references keeps its entries" {
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    const bytes = try tests.page(aa, "0 g", "", &.{ "6 0 R", "[7 0 R]", "<< /Subtype /Text /Rect [0 0 20 20] >>" }, "/Annots 5 0 R");
    var doc = try Document.open(a, bytes, .{});
    defer doc.deinit();
    const pl = try pages.PageList.build(&doc);
    const page = pages.page(&doc, pl, 0).?;
    var upd = try Update.init(a, &doc);
    defer upd.deinit();
    const note = try addNote(&upd, page, 10, 10, .{});
    var out: Io.Writer.Allocating = .init(a);
    defer out.deinit();
    try upd.write(a, &out.writer);
    var doc2 = try Document.open(a, out.written(), .{});
    defer doc2.deinit();
    const pl2 = try pages.PageList.build(&doc2);
    try testing.expectEqual(@as(usize, 2), (try list(aa, &doc2, pages.page(&doc2, pl2, 0).?)).len);

    // Removing works through the chain too.
    var upd2 = try Update.init(a, &doc2);
    defer upd2.deinit();
    try remove(&upd2, pages.page(&doc2, pl2, 0).?, note.num);
}

test "a text box is upright and in place on rotated pages" {
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    for ([_]u16{ 0, 90, 180, 270 }) |rotate| {
        const bytes = try tests.page(aa, "", "", &.{}, try std.fmt.allocPrint(aa, "/Rotate {d}", .{rotate}));
        var doc = try Document.open(a, bytes, .{});
        defer doc.deinit();
        const pl = try pages.PageList.build(&doc);
        var upd = try Update.init(a, &doc);
        defer upd.deinit();
        _ = try addFreeText(&upd, pages.page(&doc, pl, 0).?, 10, 20, 90, 40, 10, .{ .contents = "UPRIGHT BOX", .color = .{ 0, 0, 0 } });
        var out: Io.Writer.Allocating = .init(a);
        defer out.deinit();
        try upd.write(a, &out.writer);
        var doc2 = try Document.open(a, out.written(), .{});
        defer doc2.deinit();
        const pl2 = try pages.PageList.build(&doc2);
        var rend = interp.Renderer.init(&doc2, .{});
        defer rend.deinit();
        var dl = try rend.render(a, pages.page(&doc2, pl2, 0).?);
        defer dl.deinit();
        var lay = try text.layout(a, &dl);
        defer lay.deinit(a);
        try testing.expectEqualStrings("UPRIGHT BOX", std.mem.trim(u8, lay.text, "\n"));
        // The first letter is at the top left of the requested box, on the
        // displayed page, and the last is to its right on the same line.
        const first = lay.boxes[0].rect;
        const last = lay.boxes[lay.boxes.len - 1].rect;
        try testing.expect(first.x0 > 10 and first.x0 < 15 and first.y0 > 18 and first.y1 < 36);
        try testing.expect(last.x0 > first.x1 and last.x1 < 100 and @abs(last.y0 - first.y0) < 0.5);
    }
}

test "setContents redraws a text box and drops rich text" {
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    for ([_]u16{ 0, 90 }) |rotate| {
        const bytes = try tests.page(aa, "", "", &.{}, try std.fmt.allocPrint(aa, "/Rotate {d}", .{rotate}));
        var doc = try Document.open(a, bytes, .{});
        defer doc.deinit();
        const pl = try pages.PageList.build(&doc);
        var upd = try Update.init(a, &doc);
        defer upd.deinit();
        const box = try addFreeText(&upd, pages.page(&doc, pl, 0).?, 10, 20, 90, 40, 10, .{ .contents = "OLD TEXT", .color = .{ 1, 0, 0 } });
        var d = upd.get(box.num).asDict().?;
        d = try write.dictWith(upd.allocator(), d, "RC", .{ .string = "<body>OLD TEXT</body>" });
        try upd.set(box.num, .{ .dict = d });
        try setContents(&upd, box.num, "NEW WORDS", null);
        var out: Io.Writer.Allocating = .init(a);
        defer out.deinit();
        try upd.write(a, &out.writer);
        var doc2 = try Document.open(a, out.written(), .{});
        defer doc2.deinit();
        try testing.expect(doc2.getObject(box.num).asDict().?.get("RC") == null);
        const pl2 = try pages.PageList.build(&doc2);
        var rend = interp.Renderer.init(&doc2, .{});
        defer rend.deinit();
        var dl = try rend.render(a, pages.page(&doc2, pl2, 0).?);
        defer dl.deinit();
        var lay = try text.layout(a, &dl);
        defer lay.deinit(a);
        try testing.expectEqualStrings("NEW WORDS", std.mem.trim(u8, lay.text, "\n"));
        const first = lay.boxes[0].rect;
        try testing.expect(first.x0 > 10 and first.x0 < 15 and first.y1 < 36);
        // Size and colour are kept.
        for (dl.commands) |c| if (c == .text) {
            try testing.expectEqual(@as(f64, 10), c.text.size);
            try testing.expectEqual(@as(f32, 1), c.text.fill.color.r);
            try testing.expectEqual(@as(f32, 0), c.text.fill.color.g);
        };
    }
}

test "numbers that are not usable geometry are refused" {
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var doc = try Document.open(a, try tests.page(arena.allocator(), "", "", &.{}, ""), .{});
    defer doc.deinit();
    const pl = try pages.PageList.build(&doc);
    const page = pages.page(&doc, pl, 0).?;
    var upd = try Update.init(a, &doc);
    defer upd.deinit();
    const nan = std.math.nan(f64);
    const inf = std.math.inf(f64);
    const rect = [_]text.Rect{.{ .x0 = 1, .y0 = 1, .x1 = 20, .y1 = 10 }};
    const stroke = [_]display.Point{.{ .x = 1, .y = 1 }};
    for ([_]f64{ nan, inf, -inf, 1e300 }) |bad| {
        const bad_rect = [_]text.Rect{.{ .x0 = bad, .y0 = 1, .x1 = 20, .y1 = 10 }};
        const bad_stroke = [_]display.Point{.{ .x = 1, .y = bad }};
        try testing.expectError(error.BadGeometry, addMarkup(&upd, page, .highlight, &bad_rect, .{}));
        try testing.expectError(error.BadGeometry, addNote(&upd, page, bad, 1, .{}));
        try testing.expectError(error.BadGeometry, addInk(&upd, page, &.{&bad_stroke}, 1, .{}));
        try testing.expectError(error.BadGeometry, addInk(&upd, page, &.{&stroke}, bad, .{}));
        try testing.expectError(error.BadGeometry, addFreeText(&upd, page, bad, 1, 50, 20, 10, .{}));
        try testing.expectError(error.BadGeometry, addFreeText(&upd, page, 1, 1, 50, bad, 10, .{}));
        try testing.expectError(error.BadGeometry, addFreeText(&upd, page, 1, 1, 50, 20, bad, .{}));
    }
    try testing.expectError(error.BadGeometry, addInk(&upd, page, &.{&stroke}, 0, .{}));
    try testing.expectError(error.BadGeometry, addInk(&upd, page, &.{&stroke}, -100, .{}));
    try testing.expectError(error.BadGeometry, addNote(&upd, page, 1, 1, .{ .color = .{ nan, 0, 0 } }));
    try testing.expectError(error.BadGeometry, addMarkup(&upd, page, .underline, &rect, .{ .color = .{ 0, inf, 0 } }));
    try testing.expectEqual(@as(usize, 0), upd.changed.count());
    // Colour components outside 0..1 are clamped.
    const ref = try addNote(&upd, page, 1, 1, .{ .color = .{ 255, -1, 0.5 } });
    const c = upd.get(ref.num).asDict().?.get("C").?.array;
    try testing.expectEqual(@as(f64, 1), c[0].real);
    try testing.expectEqual(@as(f64, 0), c[1].real);
    // A bookmark position must be a number.
    try testing.expectError(error.BadDestination, @import("outline.zig").add(&upd, page.num, "x", nan));
}

test "editing one page leaves other pages that share its /Annots array alone" {
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    const bytes = try tests.buildFile(aa, &.{
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] /Annots 5 0 R >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] /Annots 5 0 R >>",
        "[6 0 R]",
        "<< /Subtype /Text /Rect [0 0 20 20] >>",
    });
    for ([_]bool{ true, false }) |adding| {
        var doc = try Document.open(a, bytes, .{});
        defer doc.deinit();
        const pl = try pages.PageList.build(&doc);
        var upd = try Update.init(a, &doc);
        defer upd.deinit();
        const first = pages.page(&doc, pl, 0).?;
        if (adding) _ = try addNote(&upd, first, 1, 1, .{}) else try remove(&upd, first, 6);
        var out: Io.Writer.Allocating = .init(a);
        defer out.deinit();
        try upd.write(a, &out.writer);
        try tests.expectSoundFile(out.written());
        var doc2 = try Document.open(a, out.written(), .{});
        defer doc2.deinit();
        const pl2 = try pages.PageList.build(&doc2);
        try testing.expectEqual(@as(usize, if (adding) 2 else 0), (try list(aa, &doc2, pages.page(&doc2, pl2, 0).?)).len);
        try testing.expectEqual(@as(usize, 1), (try list(aa, &doc2, pages.page(&doc2, pl2, 1).?)).len);
    }
}

test "setContents changes only annotations" {
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var doc = try Document.open(a, try tests.page(arena.allocator(), "0 g", "", &.{"<< /Subtype /Text /Rect [0 0 1 1] /Length 3 >>\nstream\nabc\nendstream"}, ""), .{});
    defer doc.deinit();
    var upd = try Update.init(a, &doc);
    defer upd.deinit();
    // The catalog, the page tree, the page, a content stream, a stream that
    // pretends to be an annotation, and nothing at all.
    for ([_]u32{ 1, 2, 3, 4, 5, 99 }) |num| try testing.expectError(error.NoSuchAnnotation, setContents(&upd, num, "x", null));
    try testing.expectEqual(@as(usize, 0), upd.changed.count());
}

test "removing an annotation removes its popup too" {
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const bytes = try tests.page(arena.allocator(), "0 g", "", &.{
        "<< /Subtype /Text /Rect [0 0 9 9] /Popup 6 0 R >>",
        "<< /Subtype /Popup /Rect [0 0 9 9] /Parent 5 0 R >>",
        // A popup that only its own /Parent links.
        "<< /Subtype /Popup /Rect [0 0 9 9] /Parent 5 0 R >>",
        "<< /Subtype /Text /Rect [0 0 9 9] >>",
    }, "/Annots [5 0 R 6 0 R 7 0 R 8 0 R]");
    var doc = try Document.open(a, bytes, .{});
    defer doc.deinit();
    const pl = try pages.PageList.build(&doc);
    var upd = try Update.init(a, &doc);
    defer upd.deinit();
    try remove(&upd, pages.page(&doc, pl, 0).?, 5);
    const left = upd.get(3).asDict().?.get("Annots").?.array;
    try testing.expectEqual(@as(usize, 1), left.len);
    try testing.expectEqual(@as(u32, 8), left[0].ref.num);
}

test "underlines and strike-outs lie inside the appearance's box" {
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var doc = try Document.open(a, try tests.page(arena.allocator(), "0 g", "", &.{}, ""), .{});
    defer doc.deinit();
    const pl = try pages.PageList.build(&doc);
    var upd = try Update.init(a, &doc);
    defer upd.deinit();
    const rects = [_]text.Rect{.{ .x0 = 20, .y0 = 10, .x1 = 180, .y1 = 20 }};
    for ([_]Kind{ .underline, .strikeout, .squiggly }) |kind| {
        const ref = try addMarkup(&upd, pages.page(&doc, pl, 0).?, kind, &rects, .{});
        const d = upd.get(ref.num).asDict().?;
        const ap = upd.get(d.get("AP").?.dict.get("N").?.ref.num).stream;
        // The text spans y 80 to 90 in user space; the 1 point line needs room.
        for ([_][]const object.Object{ ap.dict.get("BBox").?.array, d.get("Rect").?.array }) |box| {
            try testing.expect(box[1].real <= 79.5 and box[3].real >= 90.5);
            try testing.expect(box[0].real <= 20 and box[2].real >= 180);
        }
    }
}
