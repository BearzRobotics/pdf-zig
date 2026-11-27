// SPDX-License-Identifier: LGPL-2.0-or-later
//! Appearances made in memory for annotations and form fields that need one
//! while a page is rendered (ISO 32000-1:2008, 12.5.5 and 12.7.3.3; decision
//! 0004). The file is not changed.
//!
//! An annotation is untrusted and many can share one large object, so the
//! numbers and text taken from each one are capped. What is made is then
//! interpreted like any content, under the page's limits.

const std = @import("std");
const Allocator = std.mem.Allocator;
const object = @import("object.zig");
const document = @import("document.zig");
const pages = @import("pages.zig");
const serial = @import("write.zig");
const form = @import("form.zig");
const annot = @import("annot.zig");

const Object = object.Object;
const Dict = object.Dict;
const Stream = object.Stream;
const Document = document.Document;
const Content = std.ArrayList(u8);

/// Most numbers read from the arrays of one annotation.
const max_numbers = 1 << 16;
/// Most bytes of text drawn in one annotation.
const max_text = 1 << 14;
/// Most rows of a list box that are drawn.
const max_rows = 500;

const ff_multiline: u32 = 1 << 12;
const ff_password: u32 = 1 << 13;
const ff_radio: u32 = 1 << 15;
const ff_push_button: u32 = 1 << 16;
const ff_combo: u32 = 1 << 17;
const ff_file_select: u32 = 1 << 20;
const ff_comb: u32 = 1 << 24;

/// The attributes of a widget's field, which it may inherit from fields above.
const Field = struct {
    type: []const u8 = "",
    flags: u32 = 0,
    value: Object = .null,
    max_len: ?u32 = null,
    options: []const Object = &.{},
    top: usize = 0,

    fn read(doc: *Document, widget: Dict) Field {
        var self: Field = .{};
        var have_flags = false;
        var cur: ?Dict = widget;
        var hops: usize = 0;
        while (cur) |d| : (hops += 1) {
            if (hops > form.max_depth) break;
            if (self.type.len == 0) self.type = doc.getName(d, "FT") orelse "";
            if (!have_flags) if (doc.getInt(d, "Ff")) |v| {
                self.flags = @intCast(@as(u64, @bitCast(v)) & 0xFFFF_FFFF);
                have_flags = true;
            };
            if (self.value == .null) self.value = doc.get(d, "V") orelse .null;
            if (self.max_len == null) if (doc.getInt(d, "MaxLen")) |v| {
                if (v > 0 and v < 1 << 24) self.max_len = @intCast(v);
            };
            if (self.options.len == 0) self.options = doc.getArray(d, "Opt") orelse &.{};
            if (self.top == 0) if (doc.getInt(d, "TI")) |v| {
                self.top = std.math.cast(usize, v) orelse 0;
            };
            cur = doc.getDict(d, "Parent");
        }
        return self;
    }

    fn isText(self: Field) bool {
        return std.mem.eql(u8, self.type, "Tx") or std.mem.eql(u8, self.type, "Ch");
    }
};

/// Whether a widget whose form sets `NeedAppearances` should be made again: a
/// text or choice field with a value, which a stored appearance may not show.
pub fn isStale(doc: *Document, widget: Dict) bool {
    const field = Field.read(doc, widget);
    return field.isText() and field.value != .null;
}

/// The appearance of annotation `d` of `subtype` with rectangle `rect`, on a
/// page displayed turned by `rotate`, or null when none can be made. Allocated
/// from `a`. Its `/BBox` and `/Matrix` are used like those of a stored one.
pub fn make(a: Allocator, doc: *Document, d: Dict, subtype: []const u8, rect: pages.Rect, rotate: u16) Allocator.Error!?Stream {
    if (std.mem.eql(u8, subtype, "Widget")) return try widgetAppearance(a, doc, d, rect);
    if (std.mem.eql(u8, subtype, "FreeText")) return try freeText(a, doc, d, rect, rotate);
    if (std.mem.eql(u8, subtype, "Text")) return try note(a, doc, d);

    var out: Content = .empty;
    const markups = [_]struct { []const u8, annot.Kind }{
        .{ "Highlight", .highlight },
        .{ "Underline", .underline },
        .{ "StrikeOut", .strikeout },
        .{ "Squiggly", .squiggly },
    };
    const box = [4]f64{ rect.x0, rect.y0, rect.x1, rect.y1 };
    for (markups) |m| {
        if (!std.mem.eql(u8, subtype, m[0])) continue;
        var quads = try numbersOf(a, doc, d, "QuadPoints");
        // Without them the rectangle is the one thing marked.
        if (quads.len < 8) quads = try a.dupe(f64, &.{ rect.x0, rect.y1, rect.x1, rect.y1, rect.x0, rect.y0, rect.x1, rect.y0 });
        const standard: [3]f64 = if (m[1] == .highlight) .{ 1, 0.92, 0.2 } else .{ 0, 0, 0 };
        try annot.writeMarkup(a, &out, m[1], quads[0 .. quads.len - quads.len % 8], colorOf(doc, d, "C") orelse standard, 1);
        return .{ .dict = try annot.markupDict(a, box), .data = out.items };
    }

    const stroke = colorOf(doc, d, "C");
    const fill = colorOf(doc, d, "IC");
    const width = borderWidth(doc, d);
    const stroked = stroke != null and width > 0;
    if (stroke) |c| try out.print(a, "{d:.3} {d:.3} {d:.3} RG ", .{ c[0], c[1], c[2] });
    if (fill) |c| try out.print(a, "{d:.3} {d:.3} {d:.3} rg ", .{ c[0], c[1], c[2] });
    try out.print(a, "{d:.3} w\n", .{width});
    if (std.mem.eql(u8, subtype, "Square") or std.mem.eql(u8, subtype, "Circle")) {
        if (!stroked and fill == null) return .{ .dict = try plainDict(a, box), .data = "" };
        // The line lies inside the rectangle.
        const inset = if (stroked) width / 2 else 0;
        const x = rect.x0 + inset;
        const y = rect.y0 + inset;
        const w = @max(rect.width() - 2 * inset, 0);
        const h = @max(rect.height() - 2 * inset, 0);
        if (subtype[0] == 'S') {
            try out.print(a, "{d:.3} {d:.3} {d:.3} {d:.3} re ", .{ x, y, w, h });
        } else try ellipse(a, &out, x + w / 2, y + h / 2, w / 2, h / 2);
        try out.appendSlice(a, paintOperator(stroked, fill != null));
    } else if (std.mem.eql(u8, subtype, "Line")) {
        const l = try numbersOf(a, doc, d, "L");
        if (l.len < 4) return null;
        if (stroked) try out.print(a, "{d:.3} {d:.3} m {d:.3} {d:.3} l S\n", .{ l[0], l[1], l[2], l[3] });
    } else if (std.mem.eql(u8, subtype, "Polygon") or std.mem.eql(u8, subtype, "PolyLine")) {
        const v = try numbersOf(a, doc, d, "Vertices");
        if (v.len < 4) return null;
        const closed = subtype.len == "Polygon".len;
        try polyline(a, &out, v);
        if (closed) {
            try out.appendSlice(a, "h ");
            try out.appendSlice(a, if (stroked or fill != null) paintOperator(stroked, fill != null) else "n\n");
        } else try out.appendSlice(a, if (stroked) "S\n" else "n\n");
    } else if (std.mem.eql(u8, subtype, "Ink")) {
        const strokes = doc.getArray(d, "InkList") orelse return null;
        var left: usize = max_numbers;
        try out.appendSlice(a, "1 J 1 j\n");
        for (strokes) |item| {
            const arr = doc.resolve(item).asArray() orelse continue;
            if (arr.len > left) break;
            left -= @max(arr.len, 1);
            const v = try readNumbers(a, doc, arr);
            if (v.len < 2) continue;
            try polyline(a, &out, v);
            // One point shows as a dot.
            if (v.len < 4) try out.print(a, "{d:.3} {d:.3} l ", .{ v[0], v[1] });
            try out.appendSlice(a, if (stroked) "S\n" else "n\n");
        }
    } else return null;
    return .{ .dict = try plainDict(a, box), .data = out.items };
}

fn plainDict(a: Allocator, bbox: [4]f64) Allocator.Error!Dict {
    return serial.makeDict(a, &.{
        .{ "Type", .{ .name = "XObject" } },
        .{ "Subtype", .{ .name = "Form" } },
        .{ "BBox", try serial.numbers(a, &bbox) },
    });
}

fn paintOperator(stroke: bool, fill: bool) []const u8 {
    return if (stroke and fill) "B\n" else if (fill) "f\n" else "S\n";
}

fn polyline(a: Allocator, out: *Content, v: []const f64) Allocator.Error!void {
    var i: usize = 0;
    while (i + 1 < v.len) : (i += 2) try out.print(a, "{d:.3} {d:.3} {c} ", .{ v[i], v[i + 1], @as(u8, if (i == 0) 'm' else 'l') });
}

/// An ellipse about (`cx`, `cy`) with radii `rx` and `ry`, as four curves.
fn ellipse(a: Allocator, out: *Content, cx: f64, cy: f64, rx: f64, ry: f64) Allocator.Error!void {
    // The control distance that makes a Bezier quarter circle.
    const k = 0.5522847498;
    try out.print(a, "{d:.3} {d:.3} m ", .{ cx + rx, cy });
    const quarters = [4][6]f64{
        .{ 1, k, k, 1, 0, 1 },
        .{ -k, 1, -1, k, -1, 0 },
        .{ -1, -k, -k, -1, 0, -1 },
        .{ k, -1, 1, -k, 1, 0 },
    };
    for (quarters) |q| try out.print(a, "{d:.3} {d:.3} {d:.3} {d:.3} {d:.3} {d:.3} c ", .{
        cx + q[0] * rx, cy + q[1] * ry, cx + q[2] * rx, cy + q[3] * ry, cx + q[4] * rx, cy + q[5] * ry,
    });
    try out.appendSlice(a, "h ");
}

fn readNumbers(a: Allocator, doc: *Document, arr: []const Object) Allocator.Error![]f64 {
    const out = try a.alloc(f64, arr.len);
    for (arr, out) |v, *n| {
        const x = doc.resolve(v).asNum() orelse 0;
        n.* = if (@abs(x) <= 1e7) x else 0;
    }
    return out;
}

/// The numbers of array `key`, none when it is missing or longer than allowed.
fn numbersOf(a: Allocator, doc: *Document, d: Dict, key: []const u8) Allocator.Error![]f64 {
    const arr = doc.getArray(d, key) orelse return &.{};
    if (arr.len > max_numbers) return &.{};
    return readNumbers(a, doc, arr);
}

/// A colour of 1, 3 or 4 components as RGB; null for none (table 164).
fn colorOf(doc: *Document, d: Dict, key: []const u8) ?[3]f64 {
    const arr = doc.getArray(d, key) orelse return null;
    var v: [4]f64 = @splat(0);
    if (arr.len > 4) return null;
    for (arr, 0..) |item, i| v[i] = std.math.clamp(doc.resolve(item).asNum() orelse 0, 0, 1);
    return switch (arr.len) {
        1 => .{ v[0], v[0], v[0] },
        3 => .{ v[0], v[1], v[2] },
        4 => .{ (1 - v[0]) * (1 - v[3]), (1 - v[1]) * (1 - v[3]), (1 - v[2]) * (1 - v[3]) },
        else => null,
    };
}

/// The width of an annotation's border, 1 unless it says otherwise (12.5.4).
fn borderWidth(doc: *Document, d: Dict) f64 {
    var width: ?f64 = null;
    if (doc.getDict(d, "BS")) |bs| width = doc.getNum(bs, "W");
    if (width == null) if (doc.getArray(d, "Border")) |b| if (b.len >= 3) {
        width = doc.resolve(b[2]).asNum();
    };
    const w = width orelse return 1;
    return if (w >= 0 and w <= 100) w else 1;
}

/// A text string as UTF-8, cut to what one annotation may draw.
fn textOf(a: Allocator, doc: *Document, v: Object) Allocator.Error![]const u8 {
    const o = doc.resolve(v);
    const s = switch (o) {
        .string => |s| s,
        .name => |s| s,
        else => return "",
    };
    var cut = s[0..@min(s.len, max_text)];
    // A UTF-16 string is cut between code units.
    if (cut.len < s.len) cut = cut[0 .. cut.len & ~@as(usize, 1)];
    return serial.textToUtf8(a, cut);
}

fn freeText(a: Allocator, doc: *Document, d: Dict, rect: pages.Rect, rotate: u16) Allocator.Error!Stream {
    const da = try form.parseDa(a, if (doc.get(d, "DA")) |v| (if (v == .string) v.string[0..@min(v.string.len, max_text)] else "") else "");
    const own = if (doc.getInt(d, "Rotate")) |r| @mod(r, 360) else rotate;
    const turn: u16 = if (own == 90 or own == 180 or own == 270) @intCast(own) else 0;
    const contents = try textOf(a, doc, d.get("Contents") orelse .null);
    const size = if (da.size > 0) da.size else 12;
    return annot.freeTextForm(a, .{ rect.x0, rect.y0, rect.x1, rect.y1 }, turn, size, da.color_ops, contents, form.helvetica) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        // Building in memory has nothing else to fail at.
        else => unreachable,
    };
}

fn note(a: Allocator, doc: *Document, d: Dict) Allocator.Error!Stream {
    return .{
        .dict = try plainDict(a, .{ 0, 0, 20, 20 }),
        .data = try annot.noteIcon(a, colorOf(doc, d, "C") orelse .{ 1, 0.92, 0.2 }),
    };
}

fn widgetAppearance(a: Allocator, doc: *Document, d: Dict, rect: pages.Rect) Allocator.Error!?Stream {
    const field = Field.read(doc, d);
    const style = try form.widgetStyle(doc, a, d);
    const sideways = style.rotate == 90 or style.rotate == 270;
    const w = if (sideways) rect.height() else rect.width();
    const h = if (sideways) rect.width() else rect.height();

    if (std.mem.eql(u8, field.type, "Tx") or (std.mem.eql(u8, field.type, "Ch") and field.flags & ff_combo != 0)) {
        var value = try textOf(a, doc, field.value);
        // A choice stores the export value and shows the text beside it.
        if (field.type[0] == 'C') {
            if (try shownOption(a, doc, field.options, value)) |shown| value = shown;
        }
        const password = field.flags & ff_password != 0;
        const comb = field.type[0] == 'T' and field.max_len != null and field.flags & ff_comb != 0 and
            field.flags & (ff_multiline | ff_password | ff_file_select) == 0;
        const da = try form.findDefaultAppearance(a, doc, d, try form.toWinAnsi(a, value));
        return try form.textForm(a, rect, style, value, .{
            .multiline = field.type[0] == 'T' and field.flags & ff_multiline != 0,
            .password = password,
            .cells = if (comb) field.max_len else null,
        }, da);
    }

    var out: Content = .empty;
    if (style.background) |paint| try out.print(a, "q {s} 0 0 {d:.2} {d:.2} re f Q\n", .{ paint, w, h });
    const radio = std.mem.eql(u8, field.type, "Btn") and field.flags & (ff_radio | ff_push_button) == ff_radio;
    if (style.border) |paint| if (style.border_width > 0) {
        const bw = style.border_width;
        try out.print(a, "q {s} {d:.2} w ", .{ paint, bw });
        if (radio) {
            try ellipse(a, &out, w / 2, h / 2, @max(w - bw, 0) / 2, @max(h - bw, 0) / 2);
        } else try out.print(a, "{d:.2} {d:.2} {d:.2} {d:.2} re ", .{ bw / 2, bw / 2, w - bw, h - bw });
        try out.appendSlice(a, "S Q\n");
    };

    if (std.mem.eql(u8, field.type, "Ch")) {
        try listRows(a, doc, &out, field, w, h);
    } else if (std.mem.eql(u8, field.type, "Btn")) {
        if (field.flags & ff_push_button != 0) {
            const mk = doc.getDict(d, "MK");
            const caption = if (mk) |m| try textOf(a, doc, m.get("CA") orelse .null) else "";
            try centred(a, &out, try form.toWinAnsi(a, caption), w, h);
        } else if (isOn(doc, d, field)) {
            // Drawn as paths, so that no symbol font is needed.
            const side = @min(w, h);
            if (radio) {
                try out.appendSlice(a, "q 0 g ");
                try ellipse(a, &out, w / 2, h / 2, side * 0.22, side * 0.22);
                try out.appendSlice(a, "f Q\n");
            } else try out.print(a, "q 0 G {d:.3} w 1 J 1 j {d:.3} {d:.3} m {d:.3} {d:.3} l {d:.3} {d:.3} l S Q\n", .{
                side * 0.12,
                w / 2 - side * 0.30,
                h / 2 + side * 0.02,
                w / 2 - side * 0.08,
                h / 2 - side * 0.22,
                w / 2 + side * 0.30,
                h / 2 + side * 0.24,
            });
        }
    } else if (!std.mem.eql(u8, field.type, "Sig")) return null;
    // A signature field gets its background and border only: nothing here may
    // look like a signature.

    var dict = try plainDict(a, .{ 0, 0, w, h });
    dict = try serial.dictWith(a, dict, "Matrix", try serial.numbers(a, &switch (style.rotate) {
        90 => [6]f64{ 0, 1, -1, 0, h, 0 },
        180 => [6]f64{ -1, 0, 0, -1, w, h },
        270 => [6]f64{ 0, -1, 1, 0, 0, w },
        else => [6]f64{ 1, 0, 0, 1, 0, 0 },
    }));
    const fonts = try serial.makeDict(a, &.{.{ "Helv", form.helvetica }});
    dict = try serial.dictWith(a, dict, "Resources", .{ .dict = try serial.makeDict(a, &.{.{ "Font", .{ .dict = fonts } }}) });
    return .{ .dict = dict, .data = out.items };
}

/// Whether a check box or radio button is on: its own state says (`/AS`), or
/// without one, the field's value.
fn isOn(doc: *Document, d: Dict, field: Field) bool {
    if (doc.getName(d, "AS")) |state| return !std.mem.eql(u8, state, "Off");
    // A radio group's value does not say which of its buttons is meant.
    if (field.flags & ff_radio != 0) return false;
    const v = field.value.asName() orelse return false;
    return !std.mem.eql(u8, v, "Off");
}

/// One line of WinAnsi `bytes` in the middle of a box.
fn centred(a: Allocator, out: *Content, bytes: []const u8, w: f64, h: f64) Allocator.Error!void {
    if (bytes.len == 0) return;
    const size = std.math.clamp(h - 4, 4, 12);
    const x = @max((w - form.textWidth(bytes, size)) / 2, 1);
    try out.print(a, "q 0 g BT /Helv {d:.2} Tf {d:.2} {d:.2} Td ", .{ size, x, (h - size) / 2 + size * 0.22 });
    try putString(a, out, bytes);
    try out.appendSlice(a, " Tj ET Q\n");
}

fn putString(a: Allocator, out: *Content, bytes: []const u8) Allocator.Error!void {
    var w: std.Io.Writer.Allocating = .fromArrayList(a, out);
    defer out.* = w.toArrayList();
    serial.writeString(&w.writer, bytes) catch return error.OutOfMemory;
}

/// The two strings of choice `option`: what is stored and what is shown.
fn optionStrings(a: Allocator, doc: *Document, option: Object) Allocator.Error!struct { []const u8, []const u8 } {
    const o = doc.resolve(option);
    if (o == .array and o.array.len == 2) return .{ try textOf(a, doc, o.array[0]), try textOf(a, doc, o.array[1]) };
    const s = try textOf(a, doc, o);
    return .{ s, s };
}

fn shownOption(a: Allocator, doc: *Document, options: []const Object, value: []const u8) Allocator.Error!?[]const u8 {
    for (options[0..@min(options.len, max_rows)]) |option| {
        const pair = try optionStrings(a, doc, option);
        if (std.mem.eql(u8, pair[0], value)) return pair[1];
    }
    return null;
}

/// The rows of a list box from its top index, the selected ones highlighted.
fn listRows(a: Allocator, doc: *Document, out: *Content, field: Field, w: f64, h: f64) Allocator.Error!void {
    const size: f64 = std.math.clamp(h / 2, 4, 12);
    const leading = size * 1.25;
    var chosen: std.ArrayList([]const u8) = .empty;
    if (field.value == .array) {
        for (field.value.array[0..@min(field.value.array.len, max_rows)]) |v| try chosen.append(a, try textOf(a, doc, v));
    } else if (field.value != .null) try chosen.append(a, try textOf(a, doc, field.value));

    try out.print(a, "q 1 1 {d:.2} {d:.2} re W n\n", .{ @max(w - 2, 0), @max(h - 2, 0) });
    var y = h - 1 - leading;
    var i = @min(field.top, field.options.len);
    var drawn: usize = 0;
    while (i < field.options.len and y > -leading and drawn < max_rows) : ({
        i += 1;
        drawn += 1;
        y -= leading;
    }) {
        const pair = try optionStrings(a, doc, field.options[i]);
        for (chosen.items) |value| {
            if (!std.mem.eql(u8, value, pair[0])) continue;
            try out.print(a, "0.6 0.757 0.855 rg 1 {d:.2} {d:.2} {d:.2} re f\n", .{ y, @max(w - 2, 0), leading });
            break;
        }
        try out.print(a, "0 g BT /Helv {d:.2} Tf 3 {d:.2} Td ", .{ size, y + size * 0.3 });
        try putString(a, out, try form.toWinAnsi(a, pair[1]));
        try out.appendSlice(a, " Tj ET\n");
    }
    try out.appendSlice(a, "Q\n");
}
