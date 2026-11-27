// SPDX-License-Identifier: LGPL-2.0-or-later
//! The part of `compose.Builder.importPages` that carries a form over (ISO
//! 32000-1:2008, 12.7).
//!
//! A field is kept when one of its widgets is on an imported page, and so are
//! the groups above it. A kept field keeps its value but only those kids, so a
//! widget on a page left out cannot come along. When a later call brings a top
//! level field or a form font whose name is taken, it is renamed: fields with
//! one name are one field (12.7.3.2), and `/DA` names fonts in one shared
//! dictionary.

const std = @import("std");
const Allocator = std.mem.Allocator;
const object = @import("object.zig");
const forms = @import("form.zig");
const serial = @import("write.zig");
const compose = @import("compose.zig");

const Object = object.Object;
const Dict = object.Dict;
const Copy = compose.Copy;
const Error = compose.Error;

const Node = struct {
    /// The source object number of the field above, or 0 at the top.
    parent: u32,
    /// A signature field (`/FT` is inherited).
    signature: bool,
    kept: bool = false,
};

/// What one call takes from its source's form.
pub const Plan = struct {
    /// Every object of the source's field tree.
    nodes: std.AutoArrayHashMapUnmanaged(u32, Node) = .empty,
    /// The source's `/Fields` entries that are objects, in order.
    roots: std.ArrayList(u32) = .empty,
    /// Original top level name (as stored) to the name used in the new file.
    renamed: std.StringHashMapUnmanaged([]const u8) = .empty,
    /// Form fonts that had to be renamed: old resource name to new.
    fonts: std.StringHashMapUnmanaged([]const u8) = .empty,
    form: Dict = .{},

    pub fn isKept(self: *const Plan, source: u32) bool {
        return if (self.nodes.get(source)) |n| n.kept else false;
    }

    /// Reads the source's field tree, following `/Kids` as `form.fields` does.
    pub fn read(copy: *Copy) Error!Plan {
        var self: Plan = .{};
        const doc = copy.doc;
        const cat = doc.catalog() orelse return self;
        self.form = doc.getDict(cat, "AcroForm") orelse return self;
        for (doc.getArray(self.form, "Fields") orelse &.{}) |item| {
            if (item != .ref) continue;
            const before = self.nodes.count();
            try self.walk(copy, item.ref.num, 0, false, 0);
            if (self.nodes.count() > before) try self.roots.append(copy.a, item.ref.num);
        }
        return self;
    }

    fn walk(self: *Plan, copy: *Copy, num: u32, parent: u32, signature: bool, depth: usize) Error!void {
        if (depth > forms.max_depth or self.nodes.count() >= 4 * forms.max_fields) return;
        const doc = copy.doc;
        const d = doc.getObject(num).asDict() orelse return;
        if (compose.isDocumentNode(doc, d)) return;
        // A field has one parent: an object met again is not walked again.
        const gop = try self.nodes.getOrPut(copy.a, num);
        if (gop.found_existing) return;
        const is_signature = if (doc.getName(d, "FT")) |ft| std.mem.eql(u8, ft, "Sig") else signature;
        gop.value_ptr.* = .{ .parent = parent, .signature = is_signature };
        for (doc.getArray(d, "Kids") orelse &.{}) |kid| {
            if (kid == .ref) try self.walk(copy, kid.ref.num, num, is_signature, depth + 1);
        }
    }

    /// Keeps the field of widget `source` and every group above it.
    pub fn keep(self: *Plan, source: u32) void {
        var cur = source;
        while (cur != 0) {
            const node = self.nodes.getPtr(cur) orelse return;
            if (node.kept) return;
            node.kept = true;
            cur = node.parent;
        }
    }

    /// Numbers the kept fields that are not annotations of an imported page, and
    /// rules the rest of the tree out, before anything can refer to either.
    pub fn number(self: *Plan, copy: *Copy, groups: *std.ArrayList(u32)) Error!void {
        var it = self.nodes.iterator();
        while (it.next()) |kv| {
            const gop = try copy.map.getOrPut(copy.a, kv.key_ptr.*);
            if (gop.found_existing) continue;
            if (kv.value_ptr.kept) {
                gop.value_ptr.* = try copy.builder.newNumber();
                try groups.append(copy.a, kv.key_ptr.*);
            } else gop.value_ptr.* = compose.excluded;
        }
    }

    /// Whether any of the form comes along.
    fn used(self: *const Plan) bool {
        for (self.roots.items) |num| if (self.isKept(num)) return true;
        return false;
    }

    /// Brings over the form's fonts and gives every kept top level field a name
    /// that no earlier call has used.
    pub fn merge(self: *Plan, copy: *Copy) Error!void {
        if (!self.used()) return;
        const doc = copy.doc;
        const builder = copy.builder;
        const arena = builder.arena.allocator();

        if (doc.getDict(self.form, "DR")) |dr| if (doc.getDict(dr, "Font")) |source_fonts| {
            for (source_fonts.entries) |e| {
                var num: u32 = undefined;
                if (e.value == .ref) {
                    const target = try copy.reference(e.value.ref.num);
                    if (target != .ref) continue;
                    num = target.ref.num;
                } else {
                    if (e.value != .dict) continue;
                    num = try builder.newNumber();
                    const value = try copy.value(copy.a, e.value);
                    try builder.emit(num, value);
                }
                var name: []const u8 = e.key;
                var n: u32 = 2;
                while (builder.form_fonts.contains(name)) : (n += 1) {
                    name = try std.fmt.allocPrint(copy.a, "{s}_{d}", .{ e.key, n });
                }
                if (name.ptr != e.key.ptr) try self.fonts.put(copy.a, e.key, name);
                try builder.charge(name.len);
                try builder.form_fonts.put(builder.gpa, try arena.dupe(u8, name), num);
            }
        };
        if (doc.get(self.form, "NeedAppearances")) |v| {
            if (v == .boolean and v.boolean) builder.need_appearances = true;
        }

        // The names this source uses: a new one must not be one of them either.
        var here: std.StringHashMapUnmanaged(void) = .empty;
        for (self.roots.items) |num| {
            if (!self.isKept(num)) continue;
            const name = try fieldName(copy, num) orelse continue;
            try here.put(copy.a, name, {});
        }
        var it = here.keyIterator();
        var added: std.ArrayList([]const u8) = .empty;
        while (it.next()) |original| {
            var name: []const u8 = original.*;
            var n: u32 = 2;
            while (builder.field_names.contains(name) or (name.ptr != original.ptr and here.contains(name))) : (n += 1) {
                name = try std.fmt.allocPrint(copy.a, "{s}_{d}", .{ original.*, n });
            }
            try self.renamed.put(copy.a, original.*, name);
            try added.append(copy.a, name);
        }
        for (added.items) |name| {
            try builder.charge(name.len);
            try builder.field_names.put(builder.gpa, try arena.dupe(u8, name), {});
        }
        for (self.roots.items) |num| {
            if (self.isKept(num)) try builder.field_roots.append(builder.gpa, copy.map.get(num).?);
        }
    }

    /// The partial name `/T` of field `num` as UTF-8, or null without one.
    fn fieldName(copy: *Copy, num: u32) Allocator.Error!?[]const u8 {
        const d = copy.doc.getObject(num).asDict() orelse return null;
        const t = copy.doc.get(d, "T") orelse return null;
        if (t != .string) return null;
        return try serial.textToUtf8(copy.a, t.string);
    }

    /// The keys of `source` that must not be copied as they stand, because
    /// what they refer to would come along. `finish` writes those that stay.
    pub fn omitted(self: *const Plan, source: u32) []const []const u8 {
        const node = self.nodes.get(source) orelse return &.{};
        if (!node.kept) return &.{};
        // A signature signs the bytes of its own file, so it cannot hold here.
        return if (node.signature) &.{ "Parent", "Kids", "DA", "V", "DV" } else &.{ "Parent", "Kids", "DA" };
    }

    /// Finishes the copied dictionary `out` of field or widget `source`: its
    /// place in the tree, and at the top what the form dictionary supplied.
    pub fn finish(self: *const Plan, copy: *Copy, a: Allocator, source: u32, copied: Dict) Error!Dict {
        const node = self.nodes.get(source) orelse return copied;
        if (!node.kept) return copied;
        const doc = copy.doc;
        const d = doc.getObject(source).asDict() orelse return copied;
        var dict = copied;
        if (node.parent != 0) {
            dict = try serial.dictWith(a, dict, "Parent", try copy.reference(node.parent));
        }
        if (doc.getArray(d, "Kids")) |kids| {
            var kept: std.ArrayList(Object) = .empty;
            for (kids) |kid| {
                if (kid != .ref) continue;
                const child = self.nodes.get(kid.ref.num) orelse continue;
                if (child.kept and child.parent == source) try kept.append(a, try copy.reference(kid.ref.num));
            }
            if (kept.items.len > 0) dict = try serial.dictWith(a, dict, "Kids", .{ .array = kept.items });
        }
        if (node.parent == 0) {
            if (try fieldName(copy, source)) |original| if (self.renamed.get(original)) |name| {
                if (!std.mem.eql(u8, name, original)) dict = try serial.dictWith(a, dict, "T", .{ .string = try serial.textString(a, name) });
            };
            // The new form dictionary has no defaults of its own.
            if (!d.has("Q")) if (doc.getInt(self.form, "Q")) |v| {
                dict = try serial.dictWith(a, dict, "Q", .{ .integer = v });
            };
        }
        // `/DA` is read from the source, where it may be an object of its own,
        // and written directly, with the new names of its fonts.
        const da = doc.get(d, "DA") orelse if (node.parent == 0) doc.get(self.form, "DA") else null;
        if (da) |v| if (v == .string) {
            dict = try serial.dictWith(a, dict, "DA", .{ .string = try self.renameFonts(a, v.string) });
        };
        return dict;
    }

    /// `da` with the names of renamed fonts replaced.
    fn renameFonts(self: *const Plan, a: Allocator, da: []const u8) Allocator.Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < da.len) {
            if (da[i] != '/') {
                try out.append(a, da[i]);
                i += 1;
                continue;
            }
            var end = i + 1;
            while (end < da.len and object.isRegular(da[end])) end += 1;
            var p = object.Parser.init(a, da[i..end], 0);
            const parsed: Object = p.parseObject() catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => .null,
            };
            const replacement = if (parsed == .name) self.fonts.get(parsed.name) else null;
            if (replacement) |name| {
                var w: std.Io.Writer.Allocating = .fromArrayList(a, &out);
                defer out = w.toArrayList();
                serial.writeName(&w.writer, name) catch return error.OutOfMemory;
            } else try out.appendSlice(a, da[i..end]);
            i = end;
        }
        return out.items;
    }
};
