// SPDX-License-Identifier: LGPL-2.0-or-later
//! Flattening a form: the widgets of a page become part of the page's content,
//! and the fields are taken out of the form. The page looks as before and can
//! no longer be filled in.
//!
//! **This does not erase anything.** The change is an incremental update, so the
//! earlier version of the file, with its fields and values, is still inside it.
//!
//! Left as they are: signature fields (flattening would pass a signature off as
//! page content), hidden and not-to-be-viewed widgets (their values would be
//! lost), widgets in an optional content group, and widgets for which there is
//! nothing to draw with.

const std = @import("std");
const Allocator = std.mem.Allocator;
const object = @import("object.zig");
const pages = @import("pages.zig");
const interp = @import("interp.zig");
const display = @import("display.zig");
const appearance = @import("appearance.zig");
const page_edit = @import("page_edit.zig");
const form = @import("form.zig");
const annot = @import("annot.zig");
const write = @import("write.zig");

const resolve = page_edit.resolve;

const Object = object.Object;
const Dict = object.Dict;
const Ref = object.Ref;
const Update = write.Update;

/// `error.TooLarge` also covers more annotations than flattening handles.
pub const Error = page_edit.Error || error{DirectPage};

pub const Result = struct {
    /// Widgets that are now page content (or, with nothing to show, are gone).
    flattened: usize = 0,
    /// Widgets that stay, for the reasons at the top of this file.
    kept: usize = 0,
};

/// Most annotations of one page that are looked at.
const max_annotations = 1 << 16;

/// Flattens the widgets of `page` in `upd`. Call it for each page wanted, in
/// one update or several. Fill fields first: what is flattened is what `upd`
/// holds.
pub fn widgets(upd: *Update, page: pages.Page) Error!Result {
    if (page.num == 0) return error.DirectPage;
    const a = upd.allocator();
    var page_dict = upd.get(page.num).asDict() orelse return error.DirectPage;
    const items = annot.annotsOf(upd, page_dict.get("Annots") orelse return .{}) orelse return .{};
    if (items.len > max_annotations) return error.TooLarge;
    const need_appearances = needAppearances(upd);

    var result: Result = .{};
    var kept: std.ArrayList(Object) = .empty;
    var removed: std.AutoArrayHashMapUnmanaged(u32, void) = .empty;
    var drawing: std.ArrayList(u8) = .empty;
    var resources: page_edit.Resources = .of(upd, page, page_dict);

    for (items) |item| {
        const d = resolve(upd, item).asDict() orelse {
            try kept.append(a, item);
            continue;
        };
        if (!std.mem.eql(u8, nameOf(upd, d, "Subtype"), "Widget")) {
            try kept.append(a, item);
            continue;
        }
        const flags = if (d.get("F")) |v| (resolve(upd, v).asInt() orelse 0) else 0;
        const field_type = if (form.inheritedIn(upd, d, "FT")) |v| (v.asName() orelse "") else "";
        // Hidden, NoView.
        if (flags & (2 | 32) != 0 or d.has("OC") or std.mem.eql(u8, field_type, "Sig")) {
            try kept.append(a, item);
            result.kept += 1;
            continue;
        }
        const rect = rectOf(upd, d, "Rect");
        const visible = if (rect) |r| r.x1 > r.x0 and r.y1 > r.y0 else false;
        if (visible) {
            switch (try appearanceOf(upd, page, item, d, rect.?, need_appearances)) {
                .none => {
                    try kept.append(a, item);
                    result.kept += 1;
                    continue;
                },
                .empty => {},
                .form => |found| {
                    const name = try resources.add(upd, found.ref);
                    const m = found.matrix;
                    try drawing.print(a, "q {d} {d} {d} {d} {d} {d} cm /{s} Do Q\n", .{ m.a, m.b, m.c, m.d, m.e, m.f, name });
                },
            }
        }
        if (item == .ref) try removed.put(a, item.ref.num, {});
        result.flattened += 1;
    }
    if (result.flattened == 0) return result;

    page_dict = try write.dictWith(a, page_dict, "Annots", .{ .array = kept.items });
    if (drawing.items.len > 0) {
        page_dict = try resources.applyTo(upd, page_dict);
        page_dict = try write.dictWith(a, page_dict, "Contents", try page_edit.drawOver(upd, page_dict.get("Contents"), drawing.items));
    }
    try upd.set(page.num, .{ .dict = page_dict });
    try removeFields(upd, removed.keys());
    return result;
}

fn nameOf(upd: *Update, d: Dict, key: []const u8) []const u8 {
    return resolve(upd, d.get(key) orelse return "").asName() orelse "";
}

fn numbersOf(upd: *Update, d: Dict, key: []const u8, comptime n: usize) ?[n]f64 {
    const arr = resolve(upd, d.get(key) orelse return null).asArray() orelse return null;
    if (arr.len < n) return null;
    var out: [n]f64 = undefined;
    for (&out, arr[0..n]) |*x, v| {
        x.* = resolve(upd, v).asNum() orelse return null;
        if (!(@abs(x.*) <= 1e7)) return null;
    }
    return out;
}

fn rectOf(upd: *Update, d: Dict, key: []const u8) ?pages.Rect {
    const v = numbersOf(upd, d, key, 4) orelse return null;
    return .{ .x0 = @min(v[0], v[2]), .y0 = @min(v[1], v[3]), .x1 = @max(v[0], v[2]), .y1 = @max(v[1], v[3]) };
}

fn needAppearances(upd: *Update) bool {
    const root = upd.doc.trailer.get("Root") orelse return false;
    const catalog = resolve(upd, root).asDict() orelse return false;
    const acro = resolve(upd, catalog.get("AcroForm") orelse return false).asDict() orelse return false;
    const v = resolve(upd, acro.get("NeedAppearances") orelse return false);
    return v == .boolean and v.boolean;
}

const Appearance = union(enum) {
    /// Nothing can be drawn for the widget.
    none,
    /// The widget shows nothing.
    empty,
    form: struct { ref: Ref, matrix: display.Matrix },
};

/// What the widget `d` shows: its stored appearance, or one made as for display.
fn appearanceOf(upd: *Update, page: pages.Page, item: Object, d: Dict, rect: pages.Rect, need_appearances: bool) Error!Appearance {
    const a = upd.allocator();
    var stored: ?Ref = null;
    var states = false;
    if (d.get("AP")) |ap_value| if (resolve(upd, ap_value).asDict()) |ap| if (ap.get("N")) |normal| {
        var n = normal;
        const first = resolve(upd, n);
        if (first == .dict) {
            states = appearance.anyDrawing(upd.doc, first.dict);
            n = first.dict.get(nameOf(upd, d, "AS")) orelse .null;
        }
        if (n == .ref and resolve(upd, n) == .stream) stored = n.ref;
    };
    // A form that asks for new appearances may hold stale ones, but not for
    // what this update has just written.
    const written = item == .ref and upd.changed.contains(item.ref.num);
    const stale = need_appearances and !written and appearance.isStale(upd.doc, d);
    if (stored == null and states and !stale) return .empty;
    if (stored == null or stale) {
        if (try appearance.make(a, upd.doc, d, "Widget", rect, page.rotate)) |made| {
            stored = try upd.add(.{ .stream = made });
        } else if (stored == null) return .none;
    }

    var stream = upd.get(stored.?.num).stream;
    const bbox = rectOf(upd, stream.dict, "BBox") orelse return .none;
    const m: display.Matrix = if (numbersOf(upd, stream.dict, "Matrix", 6)) |v| display.Matrix.fromArray(&v) else .identity;
    // `Do` draws a form XObject only if it says it is one; appearance streams
    // do not always.
    if (!std.mem.eql(u8, nameOf(upd, stream.dict, "Subtype"), "Form")) {
        stream.dict = try write.dictWith(a, stream.dict, "Subtype", .{ .name = "Form" });
        try upd.set(stored.?.num, .{ .stream = stream });
    }
    return .{ .form = .{
        .ref = stored.?,
        .matrix = interp.appearanceMatrix(.{ bbox.x0, bbox.y0, bbox.x1, bbox.y1 }, m, .{ rect.x0, rect.y0, rect.x1, rect.y1 }),
    } };
}

/// Takes the widgets `removed` out of the form: each from its field's kids, and
/// a field left without any from the one above, up to the form itself.
fn removeFields(upd: *Update, removed: []const u32) Error!void {
    const a = upd.allocator();
    const root = upd.doc.trailer.get("Root") orelse return;
    if (root != .ref) return;
    const catalog = upd.get(root.ref.num).asDict() orelse return;
    const acro_value = catalog.get("AcroForm") orelse return;
    var acro = resolve(upd, acro_value).asDict() orelse return;

    // Objects that are gone from the tree, and the top level ones among them.
    var gone: std.AutoHashMapUnmanaged(u32, void) = .empty;
    var tops: std.AutoHashMapUnmanaged(u32, void) = .empty;
    for (removed) |widget| {
        var child = widget;
        for (0..form.max_depth + 1) |_| {
            if ((try gone.getOrPut(a, child)).found_existing) break;
            const d = upd.get(child).asDict() orelse break;
            const parent_value = d.get("Parent") orelse {
                try tops.put(a, child, {});
                break;
            };
            if (parent_value != .ref) break;
            var parent = upd.get(parent_value.ref.num).asDict() orelse break;
            const kids = annot.annotsOf(upd, parent.get("Kids") orelse break) orelse break;
            var left: std.ArrayList(Object) = .empty;
            for (kids) |kid| {
                if (kid == .ref and kid.ref.num == child) continue;
                try left.append(a, kid);
            }
            parent = try write.dictWith(a, parent, "Kids", .{ .array = left.items });
            try upd.set(parent_value.ref.num, .{ .dict = parent });
            if (left.items.len > 0) break;
            child = parent_value.ref.num;
        }
    }

    for ([_][]const u8{ "Fields", "CO" }) |key| {
        const list = annot.annotsOf(upd, acro.get(key) orelse continue) orelse continue;
        var left: std.ArrayList(Object) = .empty;
        for (list) |item| {
            // The calculation order names fields wherever they are in the tree.
            const out = item == .ref and (if (key.len == 2) gone.contains(item.ref.num) and emptied(upd, item.ref.num, tops) else tops.contains(item.ref.num));
            if (!out) try left.append(a, item);
        }
        acro = try write.dictWith(a, acro, key, .{ .array = left.items });
    }
    // XFA holds a second copy of the form, which would be shown instead.
    acro = try write.dictWithout(a, acro, "XFA");
    if (acro_value == .ref) {
        try upd.set(acro_value.ref.num, .{ .dict = acro });
    } else try upd.set(root.ref.num, .{ .dict = try write.dictWith(a, catalog, "AcroForm", .{ .dict = acro }) });
}

/// Whether field `num`, reached by the removal, has nothing left.
fn emptied(upd: *Update, num: u32, tops: std.AutoHashMapUnmanaged(u32, void)) bool {
    if (tops.contains(num)) return true;
    const d = upd.get(num).asDict() orelse return true;
    const kids = d.get("Kids") orelse return true;
    const list = annot.annotsOf(upd, kids) orelse return true;
    return list.len == 0;
}

// Tests live in flatten_tests.zig.
