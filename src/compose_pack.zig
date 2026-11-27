// SPDX-License-Identifier: LGPL-2.0-or-later
//! The compact form of a new file for `compose.Builder`: objects that are not
//! streams are gathered into compressed object streams (ISO 32000-1:2008,
//! 7.5.7), and the objects are found through a cross-reference stream (7.5.8).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const flate = std.compress.flate;
const object = @import("object.zig");
const serial = @import("write.zig");

const Object = object.Object;

/// Most objects in one object stream. Reading one object decodes its whole
/// stream, so streams stay small.
pub const max_objects = 200;
/// A stream is closed once it holds this much.
const full_bytes = 256 << 10;
/// An object this large is not packed: it would gain little.
pub const max_packed_object = 1 << 20;

/// Where an object is.
pub const Location = union(enum) {
    /// Not written yet.
    none,
    /// At this offset in a buffer or file.
    at: usize,
    /// Entry `index` of object stream `stream`.
    in: struct { stream: u32, index: u16 },
};

/// Locations by object number: `items[0]` is object `first`.
pub const Table = struct {
    items: []Location,
    first: u32 = 0,
};

/// The objects of the object stream being filled.
pub const Pack = struct {
    nums: std.ArrayList(u32) = .empty,
    /// Where each object starts in `data`.
    starts: std.ArrayList(usize) = .empty,
    data: std.ArrayList(u8) = .empty,

    pub fn deinit(self: *Pack, gpa: Allocator) void {
        self.nums.deinit(gpa);
        self.starts.deinit(gpa);
        self.data.deinit(gpa);
    }

    pub fn clear(self: *Pack) void {
        self.nums.clearRetainingCapacity();
        self.starts.clearRetainingCapacity();
        self.data.clearRetainingCapacity();
    }

    pub fn isFull(self: *const Pack) bool {
        return self.nums.items.len >= max_objects or self.data.items.len >= full_bytes;
    }

    /// Adds object `num`, whose serialized value is `value`.
    pub fn add(self: *Pack, gpa: Allocator, num: u32, value: []const u8) Allocator.Error!void {
        try self.nums.ensureUnusedCapacity(gpa, 1);
        try self.starts.ensureUnusedCapacity(gpa, 1);
        try self.data.ensureUnusedCapacity(gpa, value.len + 1);
        self.nums.appendAssumeCapacity(num);
        self.starts.appendAssumeCapacity(self.data.items.len);
        self.data.appendSliceAssumeCapacity(value);
        self.data.appendAssumeCapacity('\n');
    }

    /// Writes the pack to `w` as object stream `stream_num`, records in `table`
    /// where its objects now are, and empties the pack.
    pub fn close(self: *Pack, gpa: Allocator, w: *Io.Writer, stream_num: u32, table: Table) Allocator.Error!void {
        // The stream begins with each object's number and offset.
        var plain: std.ArrayList(u8) = .empty;
        defer plain.deinit(gpa);
        for (self.nums.items, self.starts.items) |num, start| try plain.print(gpa, "{d} {d} ", .{ num, start });
        const first = plain.items.len;
        try plain.appendSlice(gpa, self.data.items);
        const squeezed = try compress(gpa, plain.items);
        defer gpa.free(squeezed);

        w.print("{d} 0 obj\n<< /Type /ObjStm /N {d} /First {d} /Filter /FlateDecode /Length {d} >>\nstream\n", .{ stream_num, self.nums.items.len, first, squeezed.len }) catch return error.OutOfMemory;
        w.writeAll(squeezed) catch return error.OutOfMemory;
        w.writeAll("\nendstream\nendobj\n") catch return error.OutOfMemory;
        for (self.nums.items, 0..) |num, i| table.items[num - table.first] = .{ .in = .{ .stream = stream_num, .index = @intCast(i) } };
        self.clear();
    }
};

/// `data` in the zlib format that `/FlateDecode` reads. The caller frees it.
pub fn compress(gpa: Allocator, data: []const u8) Allocator.Error![]u8 {
    // The compressor's state is too large for the stack.
    const state = try gpa.create(flate.Compress);
    defer gpa.destroy(state);
    const window = try gpa.alloc(u8, flate.max_window_len);
    defer gpa.free(window);
    var out = try Io.Writer.Allocating.initCapacity(gpa, 4096);
    errdefer out.deinit();
    // It writes to memory, so it only fails for want of it.
    state.* = flate.Compress.init(&out.writer, window, .zlib, .default) catch return error.OutOfMemory;
    state.writer.writeAll(data) catch return error.OutOfMemory;
    state.finish() catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

/// Writes the cross-reference stream, itself object `own` at offset `own_at`,
/// and the end of the file. `locations` has every other object; entry 0 and any
/// beyond are not read.
pub fn writeXref(gpa: Allocator, w: *Io.Writer, locations: []const Location, own: u32, own_at: usize, root: u32, id: [16]u8) Allocator.Error!void {
    const size = own + 1;
    // Fields: the type, then an offset or a stream's number, then the index in
    // that stream (table 18). Eight bytes of offset only past 4 GiB.
    const width: usize = if (own_at > std.math.maxInt(u32)) 8 else 4;
    const row = 1 + width + 2;
    const entries = try gpa.alloc(u8, size * row);
    defer gpa.free(entries);
    for (0..size) |num| {
        var kind: u8 = 0;
        var second: u64 = 0;
        var third: u16 = 0;
        if (num == 0) {
            third = 65535;
        } else if (num == own) {
            kind = 1;
            second = own_at;
        } else switch (locations[num]) {
            .none => unreachable,
            .at => |offset| {
                kind = 1;
                second = offset;
            },
            .in => |packed_at| {
                kind = 2;
                second = packed_at.stream;
                third = packed_at.index;
            },
        }
        const bytes = entries[num * row ..][0..row];
        bytes[0] = kind;
        var wide: [8]u8 = undefined;
        std.mem.writeInt(u64, &wide, second, .big);
        @memcpy(bytes[1..][0..width], wide[8 - width ..]);
        std.mem.writeInt(u16, bytes[1 + width ..][0..2], third, .big);
    }
    const squeezed = try compress(gpa, entries);
    defer gpa.free(squeezed);

    const id_object: Object = .{ .string = &id };
    var dict_arena = std.heap.ArenaAllocator.init(gpa);
    defer dict_arena.deinit();
    const a = dict_arena.allocator();
    const dict = try serial.makeDict(a, &.{
        .{ "Type", .{ .name = "XRef" } },
        .{ "Size", .{ .integer = size } },
        .{ "W", .{ .array = try a.dupe(Object, &.{ .{ .integer = 1 }, .{ .integer = @intCast(width) }, .{ .integer = 2 } }) } },
        .{ "Root", .{ .ref = .{ .num = root } } },
        .{ "ID", .{ .array = try a.dupe(Object, &.{ id_object, id_object }) } },
        .{ "Filter", .{ .name = "FlateDecode" } },
    });
    w.print("{d} 0 obj\n", .{own}) catch return error.OutOfMemory;
    serial.writeObject(w, .{ .stream = .{ .dict = dict, .data = squeezed } }) catch return error.OutOfMemory;
    w.print("\nendobj\nstartxref\n{d}\n%%EOF\n", .{own_at}) catch return error.OutOfMemory;
}
