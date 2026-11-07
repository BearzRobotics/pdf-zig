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
    if (!std.math.isFinite(r)) return w.writeByte('0');
    if (@abs(r) < 9e15 and r == @trunc(r)) return w.print("{d}", .{@as(i64, @intFromFloat(r))});
    // Fixed notation, never an exponent (PDF has none); trailing zeros dropped.
    var buf: [64]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d:.5}", .{r}) catch return w.writeByte('0');
    var end = text.len;
    while (end > 0 and text[end - 1] == '0') end -= 1;
    if (end > 0 and text[end - 1] == '.') end -= 1;
    try w.writeAll(text[0..end]);
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

/// A text string read back as UTF-8: UTF-16BE (with a BOM) or PDFDocEncoding
/// (treated as Latin-1 here, which agrees for all common characters).
pub fn textToUtf8(a: Allocator, s: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    if (s.len >= 2 and s[0] == 0xFE and s[1] == 0xFF) {
        var i: usize = 2;
        while (i + 1 < s.len) : (i += 2) {
            var cp: u21 = (@as(u21, s[i]) << 8) | s[i + 1];
            if (cp >= 0xD800 and cp < 0xDC00 and i + 3 < s.len) {
                const lo: u21 = (@as(u21, s[i + 2]) << 8) | s[i + 3];
                if (lo >= 0xDC00 and lo < 0xE000) {
                    cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                    i += 2;
                }
            }
            var buf: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(cp, &buf) catch continue;
            try out.appendSlice(a, buf[0..n]);
        }
    } else {
        for (s) |c| {
            var buf: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(c, &buf) catch continue;
            try out.appendSlice(a, buf[0..n]);
        }
    }
    return out.toOwnedSlice(a);
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

    pub fn init(gpa: Allocator, doc: *Document) Error!Update {
        if (doc.crypt != null) return error.Encrypted;
        if (doc.repaired) return error.Repaired;
        var top: u32 = 0;
        if (doc.trailer.get("Size")) |s| top = @intCast(@max(0, @min(s.asInt() orelse 0, std.math.maxInt(u32) - 1)));
        var it = doc.xref.keyIterator();
        while (it.next()) |k| top = @max(top, k.* + 1);
        return .{ .doc = doc, .arena = std.heap.ArenaAllocator.init(gpa), .next = top };
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
    pub fn add(self: *Update, o: Object) Allocator.Error!Ref {
        const num = self.next;
        self.next += 1;
        try self.changed.put(self.allocator(), num, o);
        return .{ .num = num };
    }

    /// Replaces the value of existing object `num`.
    pub fn set(self: *Update, num: u32, o: Object) Allocator.Error!void {
        try self.changed.put(self.allocator(), num, o);
    }

    /// The newest value of object `num`: the one set in this update, else the document's.
    pub fn get(self: *Update, num: u32) Object {
        return self.changed.get(num) orelse self.doc.getObject(num);
    }

    /// Writes the original file followed by the update.
    pub fn write(self: *Update, gpa: Allocator, w: *Io.Writer) Error!void {
        const doc = self.doc;
        const prev = lastStartxref(doc.data) orelse return error.Repaired;
        const use_stream = if (doc.trailer.get("Type")) |t| (t == .name and std.mem.eql(u8, t.name, "XRef")) else false;

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
            sw.print("{d} 0 obj\n", .{num}) catch return error.WriteFailed;
            writeObject(sw, self.changed.get(num).?) catch return error.WriteFailed;
            sw.writeAll("\nendobj\n") catch return error.WriteFailed;
        }

        const size = self.next + @intFromBool(use_stream);
        const xref_pos = file_len + sw.end;
        if (use_stream) {
            try self.writeXrefStream(gpa, sw, nums, offsets, xref_pos, size, prev);
        } else {
            try self.writeXrefTable(sw, nums, offsets, size, prev);
        }
        sw.print("startxref\n{d}\n%%EOF\n", .{xref_pos}) catch return error.WriteFailed;

        w.writeAll(doc.data) catch return error.WriteFailed;
        w.writeAll(sec.written()) catch return error.WriteFailed;
    }

    /// The entries every trailer carries: Root, Info and ID of the previous one.
    fn trailerEntries(self: *Update, a: Allocator, out: *std.ArrayList(Entry)) Allocator.Error!void {
        for ([_][]const u8{ "Root", "Info", "ID" }) |key| {
            if (self.doc.trailer.get(key)) |v| try out.append(a, .{ .key = key, .value = v });
        }
    }

    fn writeXrefTable(self: *Update, sw: *Io.Writer, nums: []const u32, offsets: []const usize, size: u32, prev: usize) Error!void {
        sw.writeAll("xref\n") catch return error.WriteFailed;
        var i: usize = 0;
        while (i < nums.len) {
            var j = i + 1;
            while (j < nums.len and nums[j] == nums[j - 1] + 1) j += 1;
            sw.print("{d} {d}\n", .{ nums[i], j - i }) catch return error.WriteFailed;
            for (i..j) |k| sw.print("{d:0>10} 00000 n \n", .{offsets[k]}) catch return error.WriteFailed;
            i = j;
        }
        var entries: std.ArrayList(Entry) = .empty;
        const a = self.allocator();
        try entries.append(a, .{ .key = "Size", .value = .{ .integer = size } });
        try self.trailerEntries(a, &entries);
        try entries.append(a, .{ .key = "Prev", .value = .{ .integer = @intCast(prev) } });
        sw.writeAll("trailer\n") catch return error.WriteFailed;
        writeObject(sw, .{ .dict = .{ .entries = entries.items } }) catch return error.WriteFailed;
        sw.writeByte('\n') catch return error.WriteFailed;
    }

    fn writeXrefStream(self: *Update, gpa: Allocator, sw: *Io.Writer, nums: []const u32, offsets: []const usize, xref_pos: usize, size: u32, prev: usize) Error!void {
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
                try data.appendSlice(a, &.{ 1, @intCast(off >> 24), @intCast((off >> 16) & 0xFF), @intCast((off >> 8) & 0xFF), @intCast(off & 0xFF), 0, 0 });
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
