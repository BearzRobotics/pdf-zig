//! Interactive forms (ISO 32000-1:2008, 12.7, "AcroForm"): finding the fields of
//! a document and filling them in.
//!
//! Filling goes through `write.Update`, so the original bytes stay and a filled
//! form is the same file with one more revision. A filled text field gets a
//! new appearance stream, so every viewer shows the value; the field's `/V` is
//! set for programs that read the data.
//!
//! Limits, stated so they are not a surprise:
//! - A generated appearance encodes the text in WinAnsi with Helvetica metrics
//!   (or the font the field's default appearance names, if it is a standard
//!   font): characters outside WinAnsi become `?` in the drawn text. `/V`
//!   keeps the full text.
//! - Text is wrapped at spaces for multi-line fields, never shrunk to fit.
//! - Signature fields are listed, not filled. XFA forms are not read.
//! - Calculation, validation and format scripts are not run.

const std = @import("std");
const Allocator = std.mem.Allocator;
const object = @import("object.zig");
const document = @import("document.zig");
const pages = @import("pages.zig");
const encoding = @import("encoding.zig");
const std14 = @import("std14.zig");
const write = @import("write.zig");

const Object = object.Object;
const Dict = object.Dict;
const Ref = object.Ref;
const Document = document.Document;
const Update = write.Update;

pub const max_depth = 16;
pub const max_fields = 50_000;

pub const Kind = enum { text, checkbox, radio, push_button, combo, list, signature, unknown };

/// Field flags `/Ff` (table 221, 226, 228, 230).
const ff_read_only: u32 = 1 << 0;
const ff_required: u32 = 1 << 1;
const ff_multiline: u32 = 1 << 12;
const ff_password: u32 = 1 << 13;
const ff_radio: u32 = 1 << 15;
const ff_push_button: u32 = 1 << 16;
const ff_combo: u32 = 1 << 17;

/// One place a field is drawn.
pub const Widget = struct {
    /// Object number of the widget annotation (the field itself when merged).
    num: u32,
    /// Page index, when known.
    page: ?usize,
    /// In user space.
    rect: pages.Rect,
    /// Name of the "on" appearance state of a check box or radio button; empty otherwise.
    on_state: []const u8,
    /// A check box or radio button is on in this widget.
    on: bool,
};

pub const Field = struct {
    /// Object number of the field dictionary.
    num: u32,
    /// The fully qualified name, parts joined with `.`.
    name: []const u8,
    kind: Kind,
    /// The value as text (UTF-8): the string of a text or choice field, the
    /// selected export name of a radio group, "Off" or the on state of a check box.
    value: []const u8,
    read_only: bool,
    required: bool,
    multiline: bool,
    password: bool,
    max_len: ?u32,
    /// Choices of a combo or list box (display text).
    options: []const []const u8,
    widgets: []const Widget,
};

const Inherited = struct {
    ft: ?[]const u8 = null,
    ff: ?u32 = null,
    v: ?Object = null,
    da: ?[]const u8 = null,
    q: ?i64 = null,
    max_len: ?i64 = null,
    opt: ?[]const Object = null,
};

/// The fields of `doc`, in tree order. Strings are allocated from `a` (use an arena).
pub fn fields(a: Allocator, doc: *Document, list: pages.PageList) Allocator.Error![]Field {
    var out: std.ArrayList(Field) = .empty;
    errdefer out.deinit(a);
    const cat = doc.catalog() orelse return out.toOwnedSlice(a);
    const form = doc.getDict(cat, "AcroForm") orelse return out.toOwnedSlice(a);
    const roots = doc.getArray(form, "Fields") orelse return out.toOwnedSlice(a);

    // Which page each widget is on: from the pages' /Annots arrays.
    var where: std.AutoHashMapUnmanaged(u32, usize) = .empty;
    defer where.deinit(a);
    for (list.entries, 0..) |_, i| {
        const p = pages.page(doc, list, i) orelse continue;
        const annots = doc.getArray(p.dict, "Annots") orelse continue;
        for (annots) |it| if (it == .ref) try where.put(a, it.ref.num, i);
    }

    var ctx: Walk = .{ .a = a, .doc = doc, .list = list, .where = &where, .out = &out };
    for (roots) |r| try ctx.visit(r, "", .{}, 0);
    return out.toOwnedSlice(a);
}

const Walk = struct {
    a: Allocator,
    doc: *Document,
    list: pages.PageList,
    where: *std.AutoHashMapUnmanaged(u32, usize),
    out: *std.ArrayList(Field),

    fn visit(self: *Walk, node: Object, parent_name: []const u8, inh_in: Inherited, depth: usize) Allocator.Error!void {
        if (depth > max_depth or self.out.items.len >= max_fields) return;
        const doc = self.doc;
        const d = doc.resolve(node).asDict() orelse return;
        var inh = inh_in;
        if (doc.getName(d, "FT")) |v| inh.ft = v;
        if (doc.getInt(d, "Ff")) |v| inh.ff = @intCast(@as(u64, @bitCast(v)) & 0xFFFFFFFF);
        if (doc.get(d, "V")) |v| inh.v = v;
        if (doc.get(d, "DA")) |v| if (v == .string) {
            inh.da = v.string;
        };
        if (doc.getInt(d, "Q")) |v| inh.q = v;
        if (doc.getInt(d, "MaxLen")) |v| inh.max_len = v;
        if (doc.getArray(d, "Opt")) |v| inh.opt = v;

        var name = parent_name;
        if (doc.get(d, "T")) |t| if (t == .string) {
            const part = try write.textToUtf8(self.a, t.string);
            name = if (parent_name.len == 0) part else try std.fmt.allocPrint(self.a, "{s}.{s}", .{ parent_name, part });
        };

        const kids = doc.getArray(d, "Kids");
        // A node is a group when any kid is itself a named field; otherwise the kids are its widgets.
        var group = false;
        if (kids) |ks| for (ks) |k| {
            const kd = doc.resolve(k).asDict() orelse continue;
            if (kd.get("T") != null) group = true;
        };
        if (group) {
            for (kids.?) |k| try self.visit(k, name, inh, depth + 1);
            return;
        }
        try self.terminal(node, d, name, inh, kids);
    }

    fn terminal(self: *Walk, node: Object, d: Dict, name: []const u8, inh: Inherited, kids: ?[]const Object) Allocator.Error!void {
        const doc = self.doc;
        const a = self.a;
        const ff: u32 = inh.ff orelse 0;
        const kind: Kind = if (inh.ft) |ft| blk: {
            if (std.mem.eql(u8, ft, "Tx")) break :blk .text;
            if (std.mem.eql(u8, ft, "Sig")) break :blk .signature;
            if (std.mem.eql(u8, ft, "Ch")) break :blk if (ff & ff_combo != 0) Kind.combo else Kind.list;
            if (std.mem.eql(u8, ft, "Btn")) break :blk if (ff & ff_push_button != 0) Kind.push_button else if (ff & ff_radio != 0) Kind.radio else Kind.checkbox;
            break :blk .unknown;
        } else .unknown;

        var widgets: std.ArrayList(Widget) = .empty;
        if (kids) |ks| {
            for (ks) |k| try self.addWidget(&widgets, k);
        } else try self.addWidget(&widgets, node);

        var value: []const u8 = "";
        if (inh.v) |v| switch (doc.resolve(v)) {
            .string => |s| value = try write.textToUtf8(a, s),
            .name => |n| value = try a.dupe(u8, n),
            else => {},
        };

        var options: std.ArrayList([]const u8) = .empty;
        if (inh.opt) |opt| for (opt) |o| {
            const r = doc.resolve(o);
            switch (r) {
                .string => |s| try options.append(a, try write.textToUtf8(a, s)),
                // [export display]
                .array => |pair| if (pair.len == 2) if (doc.resolve(pair[1]) == .string) {
                    try options.append(a, try write.textToUtf8(a, doc.resolve(pair[1]).string));
                },
                else => {},
            }
        };

        try self.out.append(a, .{
            .num = if (node == .ref) node.ref.num else 0,
            .name = name,
            .kind = kind,
            .value = value,
            .read_only = ff & ff_read_only != 0,
            .required = ff & ff_required != 0,
            .multiline = ff & ff_multiline != 0,
            .password = ff & ff_password != 0,
            .max_len = if (inh.max_len) |m| (if (m > 0 and m < 1 << 24) @as(?u32, @intCast(m)) else null) else null,
            .options = try options.toOwnedSlice(a),
            .widgets = try widgets.toOwnedSlice(a),
        });
        _ = d;
    }

    fn addWidget(self: *Walk, widgets: *std.ArrayList(Widget), node: Object) Allocator.Error!void {
        const doc = self.doc;
        const wd = doc.resolve(node).asDict() orelse return;
        const arr = doc.getArray(wd, "Rect") orelse return;
        if (arr.len < 4) return;
        var v: [4]f64 = undefined;
        for (0..4) |i| v[i] = doc.resolve(arr[i]).asNum() orelse return;
        const num: u32 = if (node == .ref) node.ref.num else 0;

        // The "on" state is the name in the normal appearance that is not Off.
        var on_state: []const u8 = "";
        if (doc.getDict(wd, "AP")) |ap| if (doc.getDict(ap, "N")) |n| {
            for (n.entries) |e| if (!std.mem.eql(u8, e.key, "Off")) {
                on_state = try self.a.dupe(u8, e.key);
                break;
            };
        };
        const state = doc.getName(wd, "AS") orelse "Off";
        try widgets.append(self.a, .{
            .num = num,
            .page = self.where.get(num),
            .rect = .{ .x0 = @min(v[0], v[2]), .y0 = @min(v[1], v[3]), .x1 = @max(v[0], v[2]), .y1 = @max(v[1], v[3]) },
            .on_state = on_state,
            .on = !std.mem.eql(u8, state, "Off"),
        });
    }
};

// ---- filling ---------------------------------------------------------------------------------------

pub const Error = write.Error || error{ ReadOnly, WrongKind, TooLong, NoSuchWidget, NoAppearanceState, DirectObject };

/// Sets the text of a text field or an editable combo box.
pub fn setText(upd: *Update, field: Field, value: []const u8) Error!void {
    if (field.read_only) return error.ReadOnly;
    if (field.kind != .text and field.kind != .combo) return error.WrongKind;
    if (field.num == 0) return error.DirectObject;
    const a = upd.allocator();

    // A single-line field has no line breaks; control characters are dropped.
    var clean: std.ArrayList(u8) = .empty;
    for (value) |c| {
        if (c == '\n' or c == '\r') {
            try clean.append(a, if (field.multiline) '\n' else ' ');
        } else if (c >= 0x20 or c == '\t') try clean.append(a, c);
    }
    const text = clean.items;
    if (field.max_len) |m| {
        const count = std.unicode.utf8CountCodepoints(text) catch text.len;
        if (count > m) return error.TooLong;
    }

    var fd = upd.get(field.num).asDict() orelse return error.DirectObject;
    fd = try write.dictWith(a, fd, "V", .{ .string = try write.textString(a, text) });
    try upd.set(field.num, .{ .dict = fd });

    const da = try defaultAppearance(upd, fd);
    for (field.widgets) |w| {
        if (w.num == 0) continue;
        const ap = try textAppearance(upd, w.rect, text, field.multiline, field.password, da);
        const wd = upd.get(w.num).asDict() orelse continue;
        try upd.set(w.num, .{ .dict = try withNormalAppearance(upd, wd, ap) });
    }
}

/// Turns a check box on or off, or selects radio button `widget` of a group.
/// For a radio group `on` is ignored: the chosen widget is on and the rest are off.
pub fn setChecked(upd: *Update, field: Field, widget: usize, on: bool) Error!void {
    if (field.read_only) return error.ReadOnly;
    if (field.kind != .checkbox and field.kind != .radio) return error.WrongKind;
    if (field.num == 0) return error.DirectObject;
    if (widget >= field.widgets.len) return error.NoSuchWidget;
    const a = upd.allocator();

    var chosen: []const u8 = "Off";
    switch (field.kind) {
        .checkbox => {
            if (on) {
                chosen = field.widgets[widget].on_state;
                if (chosen.len == 0) return error.NoAppearanceState;
            }
        },
        else => {
            chosen = field.widgets[widget].on_state;
            if (chosen.len == 0) return error.NoAppearanceState;
        },
    }
    var fd = upd.get(field.num).asDict() orelse return error.DirectObject;
    fd = try write.dictWith(a, fd, "V", .{ .name = try a.dupe(u8, chosen) });
    // A merged field/widget keeps /AS in the same dictionary.
    for (field.widgets, 0..) |w, i| {
        const state: []const u8 = if (field.kind == .radio)
            (if (i == widget) w.on_state else "Off")
        else if (on) w.on_state else "Off";
        if (w.num == field.num) {
            fd = try write.dictWith(a, fd, "AS", .{ .name = try a.dupe(u8, state) });
        } else if (w.num != 0) {
            const wd = upd.get(w.num).asDict() orelse continue;
            try upd.set(w.num, .{ .dict = try write.dictWith(a, wd, "AS", .{ .name = try a.dupe(u8, state) }) });
        }
    }
    try upd.set(field.num, .{ .dict = fd });
}

/// Picks `choice` in a combo or list box. `/I` (selected indices) is dropped so
/// it cannot disagree with the new value.
pub fn setChoice(upd: *Update, field: Field, choice: []const u8) Error!void {
    if (field.read_only) return error.ReadOnly;
    if (field.kind != .combo and field.kind != .list) return error.WrongKind;
    if (field.kind == .combo) return setText(upd, field, choice);
    if (field.num == 0) return error.DirectObject;
    const a = upd.allocator();
    var fd = upd.get(field.num).asDict() orelse return error.DirectObject;
    fd = try write.dictWith(a, fd, "V", .{ .string = try write.textString(a, choice) });
    fd = try write.dictWithout(a, fd, "I");
    try upd.set(field.num, .{ .dict = fd });
    // A list box has no generated appearance: ask viewers to draw it.
    try setNeedAppearances(upd);
}

/// Sets `/NeedAppearances true` in the AcroForm dictionary.
pub fn setNeedAppearances(upd: *Update) Error!void {
    const a = upd.allocator();
    const root = upd.doc.trailer.get("Root") orelse return;
    if (root != .ref) return;
    const cat = upd.get(root.ref.num).asDict() orelse return;
    const form = cat.get("AcroForm") orelse return;
    if (form == .ref) {
        const fd = upd.get(form.ref.num).asDict() orelse return;
        try upd.set(form.ref.num, .{ .dict = try write.dictWith(a, fd, "NeedAppearances", .{ .boolean = true }) });
    } else if (form.asDict()) |fd| {
        const nf = try write.dictWith(a, fd, "NeedAppearances", .{ .boolean = true });
        try upd.set(root.ref.num, .{ .dict = try write.dictWith(a, cat, "AcroForm", .{ .dict = nf }) });
    }
}

// ---- appearance streams ----------------------------------------------------------------------------

const DefaultAppearance = struct {
    font_name: []const u8 = "Helv",
    size: f64 = 0,
    color_ops: []const u8 = "0 g",
    quad: i64 = 0,
    font: Ref,
};

/// Reads `/DA` and `/Q` of the field and finds (or makes) the font it names.
fn defaultAppearance(upd: *Update, fd: Dict) Error!DefaultAppearance {
    const a = upd.allocator();
    const doc = upd.doc;
    var da_text: []const u8 = "/Helv 0 Tf 0 g";
    var quad: i64 = 0;
    // /DA and /Q may be inherited from a parent or the AcroForm; look up the chain.
    var cur: ?Dict = fd;
    var hops: usize = 0;
    var found_da = false;
    var found_q = false;
    while (cur) |c| : (hops += 1) {
        if (hops > max_depth) break;
        if (!found_da) if (doc.get(c, "DA")) |v| if (v == .string) {
            da_text = v.string;
            found_da = true;
        };
        if (!found_q) if (doc.getInt(c, "Q")) |v| {
            quad = v;
            found_q = true;
        };
        cur = doc.getDict(c, "Parent");
    }
    const cat = doc.catalog();
    const form = if (cat) |c| doc.getDict(c, "AcroForm") else null;
    if (form) |f| {
        if (!found_da) if (doc.get(f, "DA")) |v| if (v == .string) {
            da_text = v.string;
        };
        if (!found_q) quad = doc.getInt(f, "Q") orelse 0;
    }

    var out: DefaultAppearance = .{ .font = undefined, .quad = quad };
    var color: std.ArrayList(u8) = .empty;
    var nums: [4][]const u8 = undefined;
    var n_nums: usize = 0;
    var it = std.mem.tokenizeAny(u8, da_text, " \t\r\n");
    var prev_name: []const u8 = "";
    var prev_size: []const u8 = "";
    while (it.next()) |tok| {
        if (tok[0] == '/') {
            prev_name = tok[1..];
            n_nums = 0;
        } else if (std.fmt.parseFloat(f64, tok)) |_| {
            if (n_nums < nums.len) {
                nums[n_nums] = tok;
                n_nums += 1;
            } else {
                // More than four numbers in a row: keep the last four.
                nums[0] = nums[1];
                nums[1] = nums[2];
                nums[2] = nums[3];
                nums[3] = tok;
            }
            prev_size = tok;
        } else |_| {
            if (std.mem.eql(u8, tok, "Tf")) {
                out.font_name = prev_name;
                out.size = std.fmt.parseFloat(f64, prev_size) catch 0;
            } else if (std.mem.eql(u8, tok, "g") and n_nums >= 1) {
                color.clearRetainingCapacity();
                try color.print(a, "{s} g", .{nums[n_nums - 1]});
            } else if (std.mem.eql(u8, tok, "rg") and n_nums >= 3) {
                color.clearRetainingCapacity();
                try color.print(a, "{s} {s} {s} rg", .{ nums[n_nums - 3], nums[n_nums - 2], nums[n_nums - 1] });
            } else if (std.mem.eql(u8, tok, "k") and n_nums >= 4) {
                color.clearRetainingCapacity();
                try color.print(a, "{s} {s} {s} {s} k", .{ nums[0], nums[1], nums[2], nums[3] });
            }
            n_nums = 0;
        }
    }
    if (color.items.len > 0) out.color_ops = color.items;
    out.font_name = try a.dupe(u8, out.font_name);

    // The font: the form's default resources first, else a new Helvetica.
    var font_ref: ?Ref = null;
    if (form) |f| if (doc.getDict(f, "DR")) |dr| if (doc.getDict(dr, "Font")) |fonts| {
        if (fonts.get(out.font_name)) |fo| if (fo == .ref) {
            font_ref = fo.ref;
        };
    };
    out.font = font_ref orelse try upd.add(.{ .dict = try write.makeDict(a, &.{
        .{ "Type", .{ .name = "Font" } },
        .{ "Subtype", .{ .name = "Type1" } },
        .{ "BaseFont", .{ .name = "Helvetica" } },
        .{ "Encoding", .{ .name = "WinAnsiEncoding" } },
    }) });
    return out;
}

/// The width of Unicode character `u` in Helvetica, in 1/1000 em.
fn helveticaWidth(u: u21) u16 {
    for (std14.fonts) |f| {
        if (!std.mem.eql(u8, f.name, "Helvetica")) continue;
        for (encoding.names, 0..) |n, i| {
            if (n[1] == u and i < f.widths.len) return f.widths[i];
        }
    }
    return 556;
}

/// The WinAnsi byte for `u`, or `?`.
fn winAnsiByte(u: u21) u8 {
    if (u >= 0x20 and u < 0x7F) return @intCast(u);
    if (u >= 0xA0 and u <= 0xFF) return @intCast(u);
    var c: u16 = 0x80;
    while (c < 0xA0) : (c += 1) {
        if (encoding.unicodeOf(.win_ansi, @intCast(c)) == u) return @intCast(c);
    }
    return '?';
}

/// UTF-8 text as WinAnsi bytes. Line breaks are kept as `\n` (CR LF and a
/// lone CR become one), so the appearance can split the text into lines;
/// a tab becomes a space.
pub fn toWinAnsi(a: Allocator, utf8: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var view = std.unicode.Utf8View.init(utf8) catch {
        for (utf8) |c| try out.append(a, if (c == '\n' or (c >= 0x20 and c < 0x80)) c else '?');
        return out.items;
    };
    var it = view.iterator();
    var prev_cr = false;
    while (it.nextCodepoint()) |cp| {
        const was_cr = prev_cr;
        prev_cr = cp == '\r';
        switch (cp) {
            '\r' => try out.append(a, '\n'),
            '\n' => if (!was_cr) try out.append(a, '\n'),
            '\t' => try out.append(a, ' '),
            else => try out.append(a, winAnsiByte(cp)),
        }
    }
    return out.items;
}

test "line breaks survive the WinAnsi conversion, so multi-line fields break" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const out = try toWinAnsi(arena.allocator(), "Jos\u{e9} Doe\r\n12 Main\rSt\tA\nB");
    try std.testing.expectEqualStrings("Jos\xe9 Doe\n12 Main\nSt A\nB", out);
}

/// Width of WinAnsi `bytes` in Helvetica at `size` points.
pub fn textWidth(bytes: []const u8, size: f64) f64 {
    var w: f64 = 0;
    for (bytes) |b| w += @as(f64, @floatFromInt(helveticaWidth(encoding.unicodeOf(.win_ansi, b))));
    return w * size / 1000.0;
}

/// A form XObject that draws `value` inside `rect` (placed at the widget's size).
fn textAppearance(upd: *Update, rect: pages.Rect, value: []const u8, multiline: bool, password: bool, da: DefaultAppearance) Error!Ref {
    const a = upd.allocator();
    const w = rect.width();
    const h = rect.height();
    const pad = 2.0;

    var shown: []const u8 = value;
    if (password) {
        const n = std.unicode.utf8CountCodepoints(value) catch value.len;
        const stars = try a.alloc(u8, n);
        @memset(stars, '*');
        shown = stars;
    }
    const bytes = try toWinAnsi(a, shown);
    const size: f64 = if (da.size > 0) da.size else if (multiline) 12 else std.math.clamp(h - 2 * pad, 4, 12);

    // Lines: explicit breaks, and for multi-line fields a wrap at spaces.
    var lines: std.ArrayList([]const u8) = .empty;
    var paras = std.mem.splitScalar(u8, bytes, '\n');
    while (paras.next()) |para| {
        if (!multiline) {
            try lines.append(a, para);
            continue;
        }
        var start: usize = 0;
        var last_space: ?usize = null;
        var i: usize = 0;
        while (i < para.len) : (i += 1) {
            if (para[i] == ' ') last_space = i;
            if (textWidth(para[start .. i + 1], size) > w - 2 * pad and i > start) {
                const cut = last_space orelse i;
                const brk = if (cut > start) cut else i;
                try lines.append(a, para[start..brk]);
                start = if (para[brk] == ' ') brk + 1 else brk;
                last_space = null;
                i = start;
                if (i > 0) i -= 1;
            }
        }
        try lines.append(a, para[start..]);
    }

    var content: std.ArrayList(u8) = .empty;
    try content.print(a, "/Tx BMC\nq\n{d:.2} {d:.2} {d:.2} {d:.2} re W n\nBT\n{s}\n/{s} {d:.2} Tf\n", .{ pad / 2, pad / 2, w - pad, h - pad, da.color_ops, da.font_name, size });
    const leading = size * 1.15;
    // The first baseline: vertically centred for one line, from the top for several.
    var y: f64 = if (multiline) h - pad - size else (h - size) / 2 + size * 0.22;
    var prev_x: f64 = 0;
    var prev_y: f64 = 0;
    for (lines.items) |line| {
        const lw = textWidth(line, size);
        const x: f64 = switch (da.quad) {
            1 => @max(pad, (w - lw) / 2),
            2 => @max(pad, w - pad - lw),
            else => pad,
        };
        // Td moves relative to the previous line start.
        try content.print(a, "{d:.2} {d:.2} Td\n", .{ x - prev_x, y - prev_y });
        var sb: std.Io.Writer.Allocating = .init(a);
        write.writeString(&sb.writer, line) catch return error.OutOfMemory;
        try content.print(a, "{s} Tj\n", .{sb.written()});
        prev_x = x;
        prev_y = y;
        y -= leading;
    }
    try content.appendSlice(a, "ET\nQ\nEMC\n");

    const fonts = try write.makeDict(a, &.{.{ da.font_name, .{ .ref = da.font } }});
    const res = try write.makeDict(a, &.{.{ "Font", .{ .dict = fonts } }});
    const dict = try write.makeDict(a, &.{
        .{ "Type", .{ .name = "XObject" } },
        .{ "Subtype", .{ .name = "Form" } },
        .{ "BBox", try write.numbers(a, &.{ 0, 0, w, h }) },
        .{ "Resources", .{ .dict = res } },
    });
    return upd.add(.{ .stream = .{ .dict = dict, .data = content.items } });
}

/// `wd` with `/AP << /N ref >>`.
fn withNormalAppearance(upd: *Update, wd: Dict, ap: Ref) Allocator.Error!Dict {
    const a = upd.allocator();
    const ap_dict = try write.makeDict(a, &.{.{ "N", .{ .ref = ap } }});
    return write.dictWith(a, wd, "AP", .{ .dict = ap_dict });
}

// ---- tests -------------------------------------------------------------------------------------------

const testing = std.testing;
const Io = std.Io;
const interp = @import("interp.zig");

/// A one-page form: 1 catalog, 2 pages, 3 page, 4 text field (merged widget), 5 check box,
/// 6 and 7 the check box's appearances, 8 radio group with widgets 9 and 10, 11 a field
/// group "person" with a child "name" (12).
fn formFile(aa: Allocator) ![]u8 {
    const bodies = [_][]const u8{
        "<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [4 0 R 5 0 R 8 0 R 11 0 R] /DA (/Helv 0 Tf 0 g) >> >>",
        "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Annots [4 0 R 5 0 R 9 0 R 10 0 R 12 0 R] >>",
        "<< /Type /Annot /Subtype /Widget /FT /Tx /T (city) /V (Oslo) /Rect [10 150 110 170] /MaxLen 12 /P 3 0 R >>",
        "<< /Type /Annot /Subtype /Widget /FT /Btn /T (agree) /V /Off /AS /Off /Rect [10 100 30 120] /AP << /N << /Yes 6 0 R /Off 7 0 R >> >> >>",
        "<< /Type /XObject /Subtype /Form /BBox [0 0 20 20] /Length 7 >>\nstream\n0 0 5 5 re\nendstream",
        "<< /Type /XObject /Subtype /Form /BBox [0 0 20 20] /Length 1 >>\nstream\n \nendstream",
        "<< /FT /Btn /Ff 32768 /T (size) /V /Off /Kids [9 0 R 10 0 R] >>",
        "<< /Type /Annot /Subtype /Widget /Parent 8 0 R /AS /Off /Rect [10 60 30 80] /AP << /N << /S 6 0 R /Off 7 0 R >> >> >>",
        "<< /Type /Annot /Subtype /Widget /Parent 8 0 R /AS /Off /Rect [50 60 70 80] /AP << /N << /L 6 0 R /Off 7 0 R >> >> >>",
        "<< /T (person) /Kids [12 0 R] >>",
        "<< /Type /Annot /Subtype /Widget /Parent 11 0 R /FT /Tx /Ff 4096 /T (notes) /Rect [10 10 150 50] /Q 0 >>",
    };
    var file: std.ArrayList(u8) = .empty;
    try file.appendSlice(aa, "%PDF-1.7\n");
    var offs: [bodies.len]usize = undefined;
    for (bodies, 0..) |b, i| {
        offs[i] = file.items.len;
        try file.print(aa, "{d} 0 obj\n{s}\nendobj\n", .{ i + 1, b });
    }
    const xpos = file.items.len;
    try file.print(aa, "xref\n0 {d}\n0000000000 65535 f \n", .{bodies.len + 1});
    for (offs) |o| try file.print(aa, "{d:0>10} 00000 n \n", .{o});
    try file.print(aa, "trailer\n<< /Size {d} /Root 1 0 R >>\nstartxref\n{d}\n%%EOF\n", .{ bodies.len + 1, xpos });
    return file.items;
}

fn findField(all: []const Field, name: []const u8) ?Field {
    for (all) |f| if (std.mem.eql(u8, f.name, name)) return f;
    return null;
}

test "fields: names, kinds, values, widgets and pages" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    var doc = try Document.open(testing.allocator, try formFile(aa), .{});
    defer doc.deinit();
    const pl = try pages.PageList.build(&doc);
    const all = try fields(aa, &doc, pl);
    try testing.expectEqual(@as(usize, 4), all.len);

    const city = findField(all, "city").?;
    try testing.expectEqual(Kind.text, city.kind);
    try testing.expectEqualStrings("Oslo", city.value);
    try testing.expectEqual(@as(?u32, 12), city.max_len);
    try testing.expectEqual(@as(?usize, 0), city.widgets[0].page);

    const agree = findField(all, "agree").?;
    try testing.expectEqual(Kind.checkbox, agree.kind);
    try testing.expectEqualStrings("Yes", agree.widgets[0].on_state);
    try testing.expect(!agree.widgets[0].on);

    const size = findField(all, "size").?;
    try testing.expectEqual(Kind.radio, size.kind);
    try testing.expectEqual(@as(usize, 2), size.widgets.len);
    try testing.expectEqualStrings("L", size.widgets[1].on_state);

    // A field inside a group has the group's name as its prefix; flags and type are its own.
    const notes = findField(all, "person.notes").?;
    try testing.expectEqual(Kind.text, notes.kind);
    try testing.expect(notes.multiline);
}

test "filling a text field, a check box and a radio group, then reading and drawing the result" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const bytes = try formFile(aa);
    var doc = try Document.open(testing.allocator, bytes, .{});
    defer doc.deinit();
    const pl = try pages.PageList.build(&doc);
    const all = try fields(aa, &doc, pl);

    var upd = try Update.init(testing.allocator, &doc);
    defer upd.deinit();
    try setText(&upd, findField(all, "city").?, "Bergen \u{e9}");
    try setText(&upd, findField(all, "person.notes").?, "one two three four five six seven eight nine ten eleven twelve");
    try setChecked(&upd, findField(all, "agree").?, 0, true);
    try setChecked(&upd, findField(all, "size").?, 1, true);
    try testing.expectError(error.TooLong, setText(&upd, findField(all, "city").?, "this is much too long"));
    try testing.expectError(error.WrongKind, setText(&upd, findField(all, "agree").?, "x"));

    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try upd.write(testing.allocator, &out.writer);

    var doc2 = try Document.open(testing.allocator, out.written(), .{});
    defer doc2.deinit();
    try testing.expect(!doc2.repaired);
    const pl2 = try pages.PageList.build(&doc2);
    const after = try fields(aa, &doc2, pl2);
    try testing.expectEqualStrings("Bergen \u{e9}", findField(after, "city").?.value);
    try testing.expect(findField(after, "agree").?.widgets[0].on);
    try testing.expectEqualStrings("Yes", findField(after, "agree").?.value);
    const size = findField(after, "size").?;
    try testing.expectEqualStrings("L", size.value);
    try testing.expect(!size.widgets[0].on);
    try testing.expect(size.widgets[1].on);

    // The page draws the typed text through the new appearance streams.
    const page = pages.page(&doc2, pl2, 0).?;
    var rend = interp.Renderer.init(&doc2, .{});
    defer rend.deinit();
    var dl = try rend.render(testing.allocator, page);
    defer dl.deinit();
    const lay = try @import("text.zig").layout(testing.allocator, &dl);
    var lay_mut = lay;
    defer lay_mut.deinit(testing.allocator);
    try testing.expect(std.mem.indexOf(u8, lay.text, "Bergen") != null);
    // The long note wrapped onto several lines.
    try testing.expect(std.mem.count(u8, lay.text, "\n") >= 3);
}

test "read-only fields refuse and a signature is not filled" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    var doc = try Document.open(testing.allocator, try formFile(aa), .{});
    defer doc.deinit();
    const pl = try pages.PageList.build(&doc);
    var all = try fields(aa, &doc, pl);
    var upd = try Update.init(testing.allocator, &doc);
    defer upd.deinit();
    var f = findField(all, "city").?;
    f.read_only = true;
    try testing.expectError(error.ReadOnly, setText(&upd, f, "x"));
    f.kind = .signature;
    f.read_only = false;
    try testing.expectError(error.WrongKind, setText(&upd, f, "x"));
    _ = &all;
}
