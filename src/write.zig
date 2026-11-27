// SPDX-License-Identifier: LGPL-2.0-or-later
//! Writing PDF: serializing objects and appending an incremental update
//! (ISO 32000-1:2008, 7.3 and 7.5.6).
//!
//! An update never changes the bytes of the original file. It appends the new
//! and changed objects, a cross-reference section that points back at the
//! previous one (`/Prev`) and a new trailer, so every earlier revision stays
//! intact and other readers see the change as the newest version of each
//! object. The new section is a classic table when the file's last section is a
//! table, and a cross-reference stream when it is a stream.
//!
//! Not supported (the call fails instead of writing a damaged file):
//! encrypted files, whose new strings and streams would need encrypting, and
//! files that had to be repaired when they were opened, whose cross-reference
//! data cannot be pointed at.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const object = @import("object.zig");
const document = @import("document.zig");
const Object = object.Object;
const Dict = object.Dict;
const Entry = object.Entry;
const Ref = object.Ref;
const Document = document.Document;

// ---- serializing objects ---------------------------------------------------------------

/// Writes `o` in PDF syntax. A stream is written with a correct `/Length`
/// (any `/Length` in its dictionary is replaced) and its data as it is.
pub fn writeObject(w: *Io.Writer, o: Object) Io.Writer.Error!void {
    switch (o) {
        .null => try w.writeAll("null"),
        .boolean => |b| try w.writeAll(if (b) "true" else "false"),
        .integer => |i| try w.print("{d}", .{i}),
        .real => |r| try writeReal(w, r),
        .string => |s| try writeString(w, s),
        .name => |n| try writeName(w, n),
        .array => |arr| {
            try w.writeByte('[');
            for (arr, 0..) |item, i| {
                if (i > 0) try w.writeByte(' ');
                try writeObject(w, item);
            }
            try w.writeByte(']');
        },
        .dict => |d| try writeDict(w, d, null),
        .stream => |s| {
            try writeDict(w, s.dict, s.data.len);
            try w.writeAll("\nstream\n");
            try w.writeAll(s.data);
            try w.writeAll("\nendstream");
        },
        .ref => |r| try w.print("{d} {d} R", .{ r.num, r.gen }),
    }
}

fn writeDict(w: *Io.Writer, d: Dict, length: ?usize) Io.Writer.Error!void {
    try w.writeAll("<<");
    for (d.entries) |e| {
        if (length != null and std.mem.eql(u8, e.key, "Length")) continue;
        try w.writeByte(' ');
        try writeName(w, e.key);
        try w.writeByte(' ');
        try writeObject(w, e.value);
    }
    if (length) |n| try w.print(" /Length {d}", .{n});
    try w.writeAll(" >>");
}

fn writeReal(w: *Io.Writer, r: f64) Io.Writer.Error!void {
    // PDF has no infinity or NaN. Magnitudes far below its smallest real are
    // zero, which also bounds how many leading zeros are written.
    if (!std.math.isFinite(r) or @abs(r) < 1e-38) return w.writeByte('0');
    if (@abs(r) < 9e15 and r == @trunc(r)) return w.print("{d}", .{@as(i64, @intFromFloat(r))});
    // The shortest digits that read back as the same value, in decimal
    // notation: PDF has no exponents.
    try w.print("{d}", .{r});
}

/// A name: bytes outside the printable regular range, delimiters and `#` are written as `#xx`.
pub fn writeName(w: *Io.Writer, n: []const u8) Io.Writer.Error!void {
    try w.writeByte('/');
    for (n) |c| {
        if (c <= 32 or c >= 127 or c == '#' or object.isDelim(c)) {
            try w.print("#{x:0>2}", .{c});
        } else try w.writeByte(c);
    }
}

/// A string: literal when it is printable ASCII, hexadecimal otherwise.
pub fn writeString(w: *Io.Writer, s: []const u8) Io.Writer.Error!void {
    var plain = true;
    for (s) |c| {
        if (c < 32 or c >= 127) plain = false;
    }
    if (plain) {
        try w.writeByte('(');
        for (s) |c| {
            if (c == '(' or c == ')' or c == '\\') try w.writeByte('\\');
            try w.writeByte(c);
        }
        try w.writeByte(')');
    } else {
        try w.writeByte('<');
        for (s) |c| try w.print("{x:0>2}", .{c});
        try w.writeByte('>');
    }
}

/// UTF-8 text as a PDF text string (7.9.2.2): the bytes themselves when they
/// are ASCII, otherwise UTF-16BE with a byte order mark. Allocated from `a`.
pub fn textString(a: Allocator, utf8: []const u8) Allocator.Error![]u8 {
    var ascii = true;
    for (utf8) |c| {
        if (c >= 0x80) ascii = false;
    }
    if (ascii) return a.dupe(u8, utf8);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, &.{ 0xFE, 0xFF });
    var view = std.unicode.Utf8View.init(utf8) catch {
        // Not valid UTF-8: keep what can be kept.
        out.items.len = 0;
        for (utf8) |c| try out.append(a, if (c < 0x80) c else '?');
        return out.toOwnedSlice(a);
    };
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        if (cp >= 0x10000) {
            const v = cp - 0x10000;
            const hi: u16 = @intCast(0xD800 + (v >> 10));
            const lo: u16 = @intCast(0xDC00 + (v & 0x3FF));
            try out.appendSlice(a, &.{ @intCast(hi >> 8), @intCast(hi & 0xFF), @intCast(lo >> 8), @intCast(lo & 0xFF) });
        } else {
            try out.appendSlice(a, &.{ @intCast(cp >> 8), @intCast(cp & 0xFF) });
        }
    }
    return out.toOwnedSlice(a);
}

/// A text string (7.9.2.2) read back as UTF-8: UTF-16BE or UTF-8 when it
/// starts with that byte order mark, else PDFDocEncoding. What cannot be
/// decoded becomes U+FFFD.
pub fn textToUtf8(a: Allocator, s: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    if (std.mem.startsWith(u8, s, "\xFE\xFF")) {
        var i: usize = 2;
        // Inside a language escape (ESC code ESC), which is not text.
        var escaped = false;
        while (i + 1 < s.len) : (i += 2) {
            var cp: u21 = (@as(u21, s[i]) << 8) | s[i + 1];
            if (cp == 0x1B) {
                escaped = !escaped;
                continue;
            }
            if (escaped) continue;
            if (cp >= 0xD800 and cp < 0xDC00 and i + 3 < s.len) {
                const lo: u21 = (@as(u21, s[i + 2]) << 8) | s[i + 3];
                if (lo >= 0xDC00 and lo < 0xE000) {
                    cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                    i += 2;
                }
            }
            try appendCodepoint(a, &out, cp);
        }
    } else if (std.mem.startsWith(u8, s, "\xEF\xBB\xBF")) {
        var i: usize = 3;
        while (i < s.len) {
            const len = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
            const valid = len <= s.len - i and std.unicode.utf8ValidateSlice(s[i .. i + len]);
            if (valid) try out.appendSlice(a, s[i .. i + len]) else try appendCodepoint(a, &out, 0xFFFD);
            i += if (valid) len else 1;
        }
    } else {
        for (s) |c| try appendCodepoint(a, &out, pdfDocCodepoint(c));
    }
    return out.toOwnedSlice(a);
}

/// Appends `cp` as UTF-8; a surrogate on its own becomes U+FFFD.
fn appendCodepoint(a: Allocator, out: *std.ArrayList(u8), cp: u21) Allocator.Error!void {
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &buf) catch std.unicode.utf8Encode(0xFFFD, &buf) catch unreachable;
    try out.appendSlice(a, buf[0..n]);
}

/// PDFDocEncoding (Annex D). It is Latin-1 except from 0x18 to 0x1F and from
/// 0x80 to 0xA0, and has a few undefined codes.
fn pdfDocCodepoint(c: u8) u21 {
    const low = [8]u21{ 0x2D8, 0x2C7, 0x2C6, 0x2D9, 0x2DD, 0x2DB, 0x2DA, 0x2DC };
    const high = [33]u21{
        0x2022, 0x2020, 0x2021, 0x2026, 0x2014, 0x2013, 0x192, 0x2044, // 80
        0x2039, 0x203A, 0x2212, 0x2030, 0x201E, 0x201C, 0x201D, 0x2018, // 88
        0x2019, 0x201A, 0x2122, 0xFB01, 0xFB02, 0x141, 0x152, 0x160, // 90
        0x178, 0x17D, 0x131, 0x142, 0x153, 0x161, 0x17E, 0xFFFD, // 98
        0x20AC, // A0
    };
    return switch (c) {
        0x18...0x1F => low[c - 0x18],
        0x80...0xA0 => high[c - 0x80],
        0x7F, 0xAD => 0xFFFD,
        else => c,
    };
}

// ---- building objects --------------------------------------------------------------------

/// A copy of `d` with `key` set to `value` (replaced if present, else added), allocated from `a`.
pub fn dictWith(a: Allocator, d: Dict, key: []const u8, value: Object) Allocator.Error!Dict {
    for (d.entries, 0..) |e, i| {
        if (!std.mem.eql(u8, e.key, key)) continue;
        const out = try a.dupe(Entry, d.entries);
        out[i].value = value;
        return .{ .entries = out };
    }
    const out = try a.alloc(Entry, d.entries.len + 1);
    @memcpy(out[0..d.entries.len], d.entries);
    out[d.entries.len] = .{ .key = try a.dupe(u8, key), .value = value };
    return .{ .entries = out };
}

/// A copy of `d` without `key`.
pub fn dictWithout(a: Allocator, d: Dict, key: []const u8) Allocator.Error!Dict {
    var out: std.ArrayList(Entry) = .empty;
    errdefer out.deinit(a);
    for (d.entries) |e| {
        if (!std.mem.eql(u8, e.key, key)) try out.append(a, e);
    }
    return .{ .entries = try out.toOwnedSlice(a) };
}

/// A dictionary from `key, value` pairs, allocated from `a`.
pub fn makeDict(a: Allocator, pairs: []const struct { []const u8, Object }) Allocator.Error!Dict {
    const out = try a.alloc(Entry, pairs.len);
    for (pairs, 0..) |p, i| out[i] = .{ .key = try a.dupe(u8, p[0]), .value = p[1] };
    return .{ .entries = out };
}

/// An array of numbers, allocated from `a`.
pub fn numbers(a: Allocator, values: []const f64) Allocator.Error!Object {
    const out = try a.alloc(Object, values.len);
    for (values, 0..) |v, i| out[i] = .{ .real = v };
    return .{ .array = out };
}

// ---- incremental update ------------------------------------------------------------------

pub const Error = error{
    /// The file is encrypted; new strings and streams would have to be encrypted.
    Encrypted,
    /// The file's cross-reference data was damaged and rebuilt when it was opened.
    Repaired,
    /// No object number is left below `Options.max_objects`.
    TooManyObjects,
    /// An object number that is neither in the file nor handed out by `add`.
    InvalidObject,
    OutOfMemory,
    WriteFailed,
};

/// New and changed objects of one document, to be appended with `write`.
/// Everything the update allocates lives in its own arena.
pub const Update = struct {
    doc: *Document,
    arena: std.heap.ArenaAllocator,
    /// Object number to its new value, in the order they were set.
    changed: std.AutoArrayHashMapUnmanaged(u32, Object) = .empty,
    next: u32,
    /// `Document.oom_events` at `init`. If an object could not be read for
    /// want of memory since, the update may be built on a missing one.
    oom_at_init: u64,

    pub fn init(gpa: Allocator, doc: *Document) Error!Update {
        if (doc.crypt != null) return error.Encrypted;
        if (doc.repaired) return error.Repaired;
        var top: u32 = 0;
        // `/Size` may be above the highest number in use. It is not followed to
        // where new numbers would reach the limit on reading the file back.
        if (doc.trailer.get("Size")) |s| if (std.math.cast(u32, s.asInt() orelse 0)) |size| {
            if (size <= doc.options.max_objects -| 65536) top = size;
        };
        var it = doc.xref.keyIterator();
        while (it.next()) |k| top = @max(top, k.* + 1);
        return .{ .doc = doc, .arena = std.heap.ArenaAllocator.init(gpa), .next = top, .oom_at_init = doc.oom_events };
    }

    pub fn deinit(self: *Update) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// For building objects that go into the update.
    pub fn allocator(self: *Update) Allocator {
        return self.arena.allocator();
    }

    /// Adds a new indirect object and returns its reference.
    pub fn add(self: *Update, o: Object) (Allocator.Error || error{TooManyObjects})!Ref {
        const num = self.next;
        if (num >= self.doc.options.max_objects) return error.TooManyObjects;
        self.next += 1;
        try self.changed.put(self.allocator(), num, o);
        return .{ .num = num };
    }

    /// The generation object `num` has in the file. New objects and objects
    /// stored in object streams have generation 0.
    fn generation(self: *const Update, num: u32) u16 {
        const entry = self.doc.xref.get(num) orelse return 0;
        return switch (entry) {
            .in_use => |e| e.gen,
            .free, .compressed => 0,
        };
    }

    /// The reference to object `num`. Use this to refer to an existing object:
    /// a reference with the wrong generation means null (7.3.10).
    pub fn refTo(self: *const Update, num: u32) Ref {
        return .{ .num = num, .gen = self.generation(num) };
    }

    /// Replaces the value of existing object `num`.
    pub fn set(self: *Update, num: u32, o: Object) (Allocator.Error || error{InvalidObject})!void {
        if (num == 0 or num >= self.next) return error.InvalidObject;
        try self.changed.put(self.allocator(), num, o);
    }

    /// The newest value of object `num`: the one set in this update, else the document's.
    pub fn get(self: *Update, num: u32) Object {
        return self.changed.get(num) orelse self.doc.getObject(num);
    }

    /// Writes the original file followed by the update.
    pub fn write(self: *Update, gpa: Allocator, w: *Io.Writer) Error!void {
        const doc = self.doc;
        // A bad entry found since `init` rebuilds the document: the file's own
        // cross-reference data cannot be pointed at any more.
        if (doc.repaired) return error.Repaired;
        try doc.checkMemory(self.oom_at_init);
        if (self.changed.count() == 0) {
            w.writeAll(doc.data) catch return error.WriteFailed;
            return;
        }
        const prev = lastStartxref(doc.data) orelse return error.Repaired;
        // The same form as the file's last section. (The merged trailer mixes
        // the keys of all revisions, so it cannot say.)
        const last_section = std.mem.trimStart(u8, doc.data[@min(doc.data.len, doc.base +| prev)..], &std.ascii.whitespace);
        const use_stream = !std.mem.startsWith(u8, last_section, "xref");

        var sec: Io.Writer.Allocating = .init(gpa);
        defer sec.deinit();
        const sw = &sec.writer;

        // Offsets count from the file's `%PDF-` header; the section follows the original bytes.
        const file_len = doc.data.len - doc.base;
        if (doc.data.len > 0 and doc.data[doc.data.len - 1] != '\n') sw.writeByte('\n') catch return error.WriteFailed;

        const nums = try gpa.dupe(u32, self.changed.keys());
        defer gpa.free(nums);
        std.mem.sort(u32, nums, {}, std.sort.asc(u32));
        const offsets = try gpa.alloc(usize, nums.len);
        defer gpa.free(offsets);

        for (nums, 0..) |num, i| {
            offsets[i] = file_len + sw.end;
            sw.print("{d} {d} obj\n", .{ num, self.generation(num) }) catch return error.WriteFailed;
            writeObject(sw, self.changed.get(num).?) catch return error.WriteFailed;
            sw.writeAll("\nendobj\n") catch return error.WriteFailed;
        }

        // A cross-reference stream is an object itself.
        if (use_stream and self.next >= doc.options.max_objects) return error.TooManyObjects;
        const id = try self.updatedId(self.allocator(), sw.buffered());
        const size = self.next + @intFromBool(use_stream);
        const xref_pos = file_len + sw.end;
        if (use_stream) {
            try self.writeXrefStream(gpa, sw, nums, offsets, xref_pos, size, prev, id);
        } else {
            try self.writeXrefTable(sw, nums, offsets, size, prev, id);
        }
        sw.print("startxref\n{d}\n%%EOF\n", .{xref_pos}) catch return error.WriteFailed;

        w.writeAll(doc.data) catch return error.WriteFailed;
        w.writeAll(sec.written()) catch return error.WriteFailed;
    }

    /// The entries every trailer carries: Root, Info and ID of the previous one.
    fn trailerEntries(self: *Update, a: Allocator, out: *std.ArrayList(Entry)) Allocator.Error!void {
        for ([_][]const u8{ "Root", "Info" }) |key| {
            if (self.doc.trailer.get(key)) |v| try out.append(a, .{ .key = key, .value = v });
        }
    }

    /// `/ID` for the update (14.4): the first string identifies the document
    /// and is kept; the second identifies this version of it, and is derived
    /// from the previous one and the objects written. Absent if the file had
    /// none.
    fn updatedId(self: *Update, a: Allocator, section: []const u8) Allocator.Error!?Object {
        const old = self.doc.resolve(self.doc.trailer.get("ID") orelse return null).asArray() orelse return null;
        if (old.len < 2) return null;
        const first = self.doc.resolve(old[0]);
        const previous = self.doc.resolve(old[1]);
        if (first != .string or previous != .string) return null;
        var hash = std.crypto.hash.Md5.init(.{});
        hash.update(previous.string);
        hash.update(std.mem.asBytes(&std.mem.nativeToLittle(u64, self.doc.data.len)));
        hash.update(section);
        var digest: [16]u8 = undefined;
        hash.final(&digest);
        return .{ .array = try a.dupe(Object, &.{ first, .{ .string = try a.dupe(u8, &digest) } }) };
    }

    fn writeXrefTable(self: *Update, sw: *Io.Writer, nums: []const u32, offsets: []const usize, size: u32, prev: usize, id: ?Object) Error!void {
        sw.writeAll("xref\n") catch return error.WriteFailed;
        var i: usize = 0;
        while (i < nums.len) {
            var j = i + 1;
            while (j < nums.len and nums[j] == nums[j - 1] + 1) j += 1;
            sw.print("{d} {d}\n", .{ nums[i], j - i }) catch return error.WriteFailed;
            for (i..j) |k| sw.print("{d:0>10} {d:0>5} n \n", .{ offsets[k], self.generation(nums[k]) }) catch return error.WriteFailed;
            i = j;
        }
        var entries: std.ArrayList(Entry) = .empty;
        const a = self.allocator();
        try entries.append(a, .{ .key = "Size", .value = .{ .integer = size } });
        try self.trailerEntries(a, &entries);
        if (id) |v| try entries.append(a, .{ .key = "ID", .value = v });
        try entries.append(a, .{ .key = "Prev", .value = .{ .integer = @intCast(prev) } });
        sw.writeAll("trailer\n") catch return error.WriteFailed;
        writeObject(sw, .{ .dict = .{ .entries = entries.items } }) catch return error.WriteFailed;
        sw.writeByte('\n') catch return error.WriteFailed;
    }

    fn writeXrefStream(self: *Update, gpa: Allocator, sw: *Io.Writer, nums: []const u32, offsets: []const usize, xref_pos: usize, size: u32, prev: usize, id: ?Object) Error!void {
        const a = self.allocator();
        // The stream describes itself too: it is object `self.next`.
        const own = self.next;
        var all_nums: std.ArrayList(u32) = .empty;
        defer all_nums.deinit(gpa);
        var all_offsets: std.ArrayList(usize) = .empty;
        defer all_offsets.deinit(gpa);
        try all_nums.appendSlice(gpa, nums);
        try all_offsets.appendSlice(gpa, offsets);
        try all_nums.append(gpa, own);
        try all_offsets.append(gpa, xref_pos);

        // /W [1 4 2]: type, offset, generation.
        var data: std.ArrayList(u8) = .empty;
        var index: std.ArrayList(Object) = .empty;
        var i: usize = 0;
        while (i < all_nums.items.len) {
            var j = i + 1;
            while (j < all_nums.items.len and all_nums.items[j] == all_nums.items[j - 1] + 1) j += 1;
            try index.append(a, .{ .integer = all_nums.items[i] });
            try index.append(a, .{ .integer = @intCast(j - i) });
            for (i..j) |k| {
                const off: u32 = @intCast(all_offsets.items[k]);
                const gen = self.generation(all_nums.items[k]);
                try data.appendSlice(a, &.{ 1, @intCast(off >> 24), @intCast((off >> 16) & 0xFF), @intCast((off >> 8) & 0xFF), @intCast(off & 0xFF), @intCast(gen >> 8), @intCast(gen & 0xFF) });
            }
            i = j;
        }
        const widths = try a.dupe(Object, &.{ .{ .integer = 1 }, .{ .integer = 4 }, .{ .integer = 2 } });
        var entries: std.ArrayList(Entry) = .empty;
        try entries.append(a, .{ .key = "Type", .value = .{ .name = "XRef" } });
        try entries.append(a, .{ .key = "Size", .value = .{ .integer = size } });
        try entries.append(a, .{ .key = "W", .value = .{ .array = widths } });
        try entries.append(a, .{ .key = "Index", .value = .{ .array = index.items } });
        try self.trailerEntries(a, &entries);
        if (id) |v| try entries.append(a, .{ .key = "ID", .value = v });
        try entries.append(a, .{ .key = "Prev", .value = .{ .integer = @intCast(prev) } });
        sw.print("{d} 0 obj\n", .{own}) catch return error.WriteFailed;
        writeObject(sw, .{ .stream = .{ .dict = .{ .entries = entries.items }, .data = data.items } }) catch return error.WriteFailed;
        sw.writeAll("\nendobj\n") catch return error.WriteFailed;
    }
};

/// The number after the last `startxref` keyword of `data`.
fn lastStartxref(data: []const u8) ?usize {
    const at = std.mem.lastIndexOf(u8, data, "startxref") orelse return null;
    var i = at + "startxref".len;
    while (i < data.len and object.isWhite(data[i])) i += 1;
    var n: usize = 0;
    var digits: usize = 0;
    while (i < data.len and data[i] >= '0' and data[i] <= '9') : (i += 1) {
        n = std.math.mul(usize, n, 10) catch return null;
        n = std.math.add(usize, n, data[i] - '0') catch return null;
        digits += 1;
    }
    return if (digits > 0) n else null;
}

// ---- tests -----------------------------------------------------------------------------------

const testing = std.testing;
const tests = @import("interp_tests.zig");

test "objects are written in PDF syntax" {
    var aw: Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    const w = &aw.writer;
    const arr = [_]Object{ .{ .integer = 1 }, .{ .real = 2.5 }, .{ .real = 3.0 }, .{ .name = "A B#" }, .{ .string = "a(b)\\" }, .{ .string = "\xFE\xFF" }, .{ .ref = .{ .num = 7 } }, .null, .{ .boolean = true } };
    try writeObject(w, .{ .array = &arr });
    try testing.expectEqualStrings("[1 2.5 3 /A#20B#23 (a\\(b\\)\\\\) <feff> 7 0 R null true]", aw.written());
}

test "text strings round trip through UTF-16BE" {
    const a = testing.allocator;
    const plain = try textString(a, "hello");
    defer a.free(plain);
    try testing.expectEqualStrings("hello", plain);
    const wide = try textString(a, "caf\u{e9} \u{1F600}");
    defer a.free(wide);
    try testing.expectEqual(@as(u8, 0xFE), wide[0]);
    const back = try textToUtf8(a, wide);
    defer a.free(back);
    try testing.expectEqualStrings("caf\u{e9} \u{1F600}", back);
}

test "an update adds an object and changes another; the original bytes stay" {
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const bytes = try tests.page(arena.allocator(), "0 0 m", "", &.{}, "");

    var doc = try document.Document.open(a, bytes, .{});
    defer doc.deinit();
    var upd = try Update.init(a, &doc);
    defer upd.deinit();

    const ua = upd.allocator();
    const note = try upd.add(.{ .dict = try makeDict(ua, &.{ .{ "Type", .{ .name = "Test" } }, .{ "Title", .{ .string = "hi" } } }) });
    try testing.expectEqual(@as(u32, 5), note.num);
    const page_dict = upd.get(3).asDict().?;
    try upd.set(3, .{ .dict = try dictWith(ua, page_dict, "Extra", .{ .ref = note }) });

    var out: Io.Writer.Allocating = .init(a);
    defer out.deinit();
    try upd.write(a, &out.writer);
    try testing.expect(std.mem.startsWith(u8, out.written(), bytes));

    try @import("interp_tests.zig").expectSoundFile(out.written());
    var doc2 = try document.Document.open(a, out.written(), .{});
    defer doc2.deinit();
    try testing.expect(!doc2.repaired);
    const new_page = doc2.getObject(3).asDict().?;
    const extra = doc2.resolve(new_page.get("Extra").?).asDict().?;
    try testing.expectEqualStrings("hi", extra.get("Title").?.string);
    // The rest of the page is still there.
    try testing.expect(new_page.get("Contents") != null);
}

test "a file with a cross-reference stream gets a stream update" {
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    // A file whose only section is a cross-reference stream (W [1 4 2]).
    const bodies = [_][]const u8{
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] >>",
    };
    var file: std.ArrayList(u8) = .empty;
    try file.appendSlice(aa, "%PDF-1.5\n");
    var offs: [4]usize = undefined;
    for (bodies, 0..) |b, i| {
        offs[i] = file.items.len;
        try file.print(aa, "{d} 0 obj\n{s}\nendobj\n", .{ i + 1, b });
    }
    offs[3] = file.items.len; // the stream is object 4
    var rows: [5 * 7]u8 = @splat(0);
    for (offs, 0..) |o, i| rows[(i + 1) * 7 ..][0..7].* = .{ 1, 0, 0, @intCast(o >> 8), @intCast(o & 0xFF), 0, 0 };
    try file.print(aa, "4 0 obj\n<< /Type /XRef /Size 5 /W [1 4 2] /Root 1 0 R /Length {d} >>\nstream\n", .{rows.len});
    try file.appendSlice(aa, &rows);
    try file.print(aa, "\nendstream\nendobj\nstartxref\n{d}\n%%EOF\n", .{offs[3]});

    var doc = try document.Document.open(a, file.items, .{});
    defer doc.deinit();
    try testing.expect(!doc.repaired);
    var upd = try Update.init(a, &doc);
    defer upd.deinit();
    const ref = try upd.add(.{ .dict = try makeDict(upd.allocator(), &.{.{ "K", .{ .integer = 42 } }}) });
    var out: Io.Writer.Allocating = .init(a);
    defer out.deinit();
    try upd.write(a, &out.writer);

    try @import("interp_tests.zig").expectSoundFile(out.written());
    var doc2 = try document.Document.open(a, out.written(), .{});
    defer doc2.deinit();
    try testing.expect(!doc2.repaired);
    try testing.expectEqual(@as(?i64, 42), doc2.getObject(ref.num).asDict().?.get("K").?.asInt());
    // The old objects are still reachable through /Prev.
    try testing.expect(doc2.getObject(3).asDict() != null);
}

test "encrypted and repaired files are refused" {
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const bytes = try arena.allocator().dupe(u8, try tests.page(arena.allocator(), "0 0 m", "", &.{}, ""));
    // Damage the startxref pointer so the document is rebuilt on open.
    const at = std.mem.lastIndexOf(u8, bytes, "startxref\n").? + "startxref\n".len;
    @memset(bytes[at .. at + 2], '9');
    var doc = try document.Document.open(a, bytes, .{});
    defer doc.deinit();
    try testing.expect(doc.repaired);
    try testing.expectError(error.Repaired, Update.init(a, &doc));
}

test "rewritten objects keep their generation, in tables and in new references" {
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    // Catalog `1 2`, page `3 1`.
    var file: std.ArrayList(u8) = .empty;
    try file.appendSlice(aa, "%PDF-1.7\n");
    const bodies = [_][]const u8{
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 1 R] /Count 1 >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] >>",
    };
    const gens = [_]u16{ 2, 0, 1 };
    var offs: [bodies.len]usize = undefined;
    for (bodies, gens, 0..) |b, g, i| {
        offs[i] = file.items.len;
        try file.print(aa, "{d} {d} obj\n{s}\nendobj\n", .{ i + 1, g, b });
    }
    const at = file.items.len;
    try file.appendSlice(aa, "xref\n0 4\n0000000000 65535 f \n");
    for (offs, gens) |o, g| try file.print(aa, "{d:0>10} {d:0>5} n \n", .{ o, g });
    try file.print(aa, "trailer\n<< /Size 4 /Root 1 2 R >>\nstartxref\n{d}\n%%EOF\n", .{at});
    try tests.expectSoundFile(file.items);

    var doc = try document.Document.open(a, file.items, .{});
    defer doc.deinit();
    var upd = try Update.init(a, &doc);
    defer upd.deinit();
    // Rewrites the catalog (no outline yet) and refers to the page in a new destination.
    _ = try @import("outline.zig").add(&upd, 3, "here", null);
    try upd.set(3, upd.get(3));
    var out: Io.Writer.Allocating = .init(a);
    defer out.deinit();
    try upd.write(a, &out.writer);
    try tests.expectSoundFile(out.written());
    try testing.expect(std.mem.indexOf(u8, out.written()[file.items.len..], "[3 1 R /XYZ") != null);
}

test "set refuses object 0 and numbers that were never handed out" {
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var doc = try document.Document.open(a, try tests.page(arena.allocator(), "0 g", "", &.{}, ""), .{});
    defer doc.deinit();
    var upd = try Update.init(a, &doc);
    defer upd.deinit();
    try testing.expectError(error.InvalidObject, upd.set(0, .null));
    try testing.expectError(error.InvalidObject, upd.set(999, .null));
    const r = try upd.add(.null);
    try upd.set(r.num, .{ .integer = 1 });
}

test "a repair that happens during editing stops the write" {
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const bytes = try arena.allocator().dupe(u8, try tests.page(arena.allocator(), "0 0 m", "", &.{"<< /Extra true >>"}, ""));
    // Give object 5, which opening does not read, a wrong offset.
    const table = std.mem.lastIndexOf(u8, bytes, "xref\n0 6\n").? + "xref\n0 6\n".len;
    @memcpy(bytes[table + 5 * 20 ..][0..10], "0000000011");
    var doc = try document.Document.open(a, bytes, .{});
    defer doc.deinit();
    var upd = try Update.init(a, &doc);
    defer upd.deinit();
    try testing.expect(!doc.repaired);
    _ = upd.get(5);
    try testing.expect(doc.repaired);
    var out: Io.Writer.Allocating = .init(a);
    defer out.deinit();
    try testing.expectError(error.Repaired, upd.write(a, &out.writer));
    try testing.expectEqual(@as(usize, 0), out.written().len);
}

test "a trailer /Size beyond the object limit is not used to number new objects" {
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    const good = try tests.page(aa, "0 g", "", &.{}, "");
    for ([_][]const u8{ "4294967295", "9000000", "8000000", "-1" }) |size| {
        const bytes = try std.mem.replaceOwned(u8, aa, good, "/Size 5", try std.fmt.allocPrint(aa, "/Size {s}", .{size}));
        var doc = try document.Document.open(a, bytes, .{});
        defer doc.deinit();
        var upd = try Update.init(a, &doc);
        defer upd.deinit();
        const first = try upd.add(.{ .integer = 1 });
        const second = try upd.add(.{ .integer = 2 });
        try testing.expectEqual(@as(u32, 5), first.num);
        var out: Io.Writer.Allocating = .init(a);
        defer out.deinit();
        try upd.write(a, &out.writer);
        var doc2 = try document.Document.open(a, out.written(), .{});
        defer doc2.deinit();
        try testing.expectEqual(@as(?i64, 2), doc2.getObject(second.num).asInt());
    }
    // An honest /Size above the highest object number is still respected.
    const bytes = try std.mem.replaceOwned(u8, aa, good, "/Size 5", "/Size 40");
    var doc = try document.Document.open(a, bytes, .{});
    defer doc.deinit();
    var upd = try Update.init(a, &doc);
    defer upd.deinit();
    try testing.expectEqual(@as(u32, 40), (try upd.add(.null)).num);
}

test "adding past the object limit is an error" {
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var doc = try document.Document.open(a, try tests.page(arena.allocator(), "0 g", "", &.{}, ""), .{ .max_objects = 7 });
    defer doc.deinit();
    var upd = try Update.init(a, &doc);
    defer upd.deinit();
    _ = try upd.add(.null);
    _ = try upd.add(.null);
    try testing.expectError(error.TooManyObjects, upd.add(.null));
}

test "reals keep their value when written and read back" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]f64{ 0.000001, 1.23456e-5, -4e-6, 0.1, -2.5, 1e60, -1e60, 123456.789012, 9.999999999999999e-31, 1.2345678901234567e-30, 612.0001, 1e15, 3e18 }) |v| {
        var aw: Io.Writer.Allocating = .init(a);
        try writeObject(&aw.writer, .{ .real = v });
        const out = aw.written();
        try testing.expect(std.mem.indexOfAny(u8, out, "eE") == null);
        var p = object.Parser.init(a, out, 0);
        try testing.expectEqual(v, (try p.parseObject()).asNum().?);
    }
    // Smaller than anything PDF can mean, and not a number: zero.
    for ([_]f64{ 1e-60, -1e-310, std.math.nan(f64), std.math.inf(f64) }) |v| {
        var aw: Io.Writer.Allocating = .init(a);
        try writeObject(&aw.writer, .{ .real = v });
        try testing.expectEqualStrings("0", aw.written());
    }
}

test "text strings: PDFDocEncoding, UTF-8 and language escapes" {
    const a = testing.allocator;
    const cases = [_][2][]const u8{
        // Where PDFDocEncoding differs from Latin-1 (Annex D).
        .{ "\x18\x1f", "\u{2d8}\u{2dc}" },
        .{ "\x80\x85\x8d\x8e\x90\x92\x96\x9e\xa0", "\u{2022}\u{2013}\u{201c}\u{201d}\u{2019}\u{2122}\u{152}\u{17e}\u{20ac}" },
        .{ "tab\tcaf\xe9\n", "tab\tcaf\u{e9}\n" },
        // Undefined codes are replaced.
        .{ "a\x9f\x7f\xad", "a\u{fffd}\u{fffd}\u{fffd}" },
        // UTF-8 with its byte order mark (PDF 2.0).
        .{ "\xef\xbb\xbfcaf\xc3\xa9", "caf\u{e9}" },
        .{ "\xef\xbb\xbfbad\xff", "bad\u{fffd}" },
        // A language escape in UTF-16 is not text.
        .{ "\xfe\xff\x00A\x00\x1b\x00e\x00n\x00\x1b\x00B", "AB" },
    };
    for (cases) |c| {
        const got = try textToUtf8(a, c[0]);
        defer a.free(got);
        try testing.expectEqualStrings(c[1], got);
    }
}

test "the update's cross-reference form follows the file's last section" {
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    // A classic update on top of a file whose trailer says it was a stream.
    const base = try tests.page(aa, "0 g", "", &.{}, "");
    const bytes = try std.mem.replaceOwned(u8, aa, base, "/Root 1 0 R >>", "/Root 1 0 R /Type /XRef >>");
    var doc = try document.Document.open(a, bytes, .{});
    defer doc.deinit();
    var upd = try Update.init(a, &doc);
    defer upd.deinit();
    _ = try upd.add(.null);
    var out: Io.Writer.Allocating = .init(a);
    defer out.deinit();
    try upd.write(a, &out.writer);
    const added = out.written()[bytes.len..];
    try testing.expect(std.mem.indexOf(u8, added, "\nxref\n") != null);
    try testing.expect(std.mem.indexOf(u8, added, "/XRef") == null);
}

test "the file identifier keeps its first part and gets a new second one" {
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    const bytes = try std.mem.replaceOwned(u8, aa, try tests.page(aa, "0 g", "", &.{}, ""), "/Root 1 0 R >>", "/Root 1 0 R /ID [(first) (second)] >>");
    var seconds: [2][]const u8 = undefined;
    for (&seconds, 0..) |*second, k| {
        var doc = try document.Document.open(a, bytes, .{});
        defer doc.deinit();
        var upd = try Update.init(a, &doc);
        defer upd.deinit();
        _ = try upd.add(.{ .integer = @intCast(k) });
        var out: Io.Writer.Allocating = .init(a);
        defer out.deinit();
        try upd.write(a, &out.writer);
        var doc2 = try document.Document.open(a, out.written(), .{});
        defer doc2.deinit();
        const id = doc2.trailer.get("ID").?.array;
        try testing.expectEqualStrings("first", id[0].string);
        try testing.expect(!std.mem.eql(u8, id[1].string, "second"));
        second.* = try aa.dupe(u8, id[1].string);
    }
    // Different changes, different identifiers.
    try testing.expect(!std.mem.eql(u8, seconds[0], seconds[1]));
}

test "an update with nothing in it writes the file unchanged" {
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const bytes = try tests.page(arena.allocator(), "0 g", "", &.{}, "");
    var doc = try document.Document.open(a, bytes, .{});
    defer doc.deinit();
    var upd = try Update.init(a, &doc);
    defer upd.deinit();
    var out: Io.Writer.Allocating = .init(a);
    defer out.deinit();
    try upd.write(a, &out.writer);
    try testing.expectEqualStrings(bytes, out.written());
}
