// SPDX-License-Identifier: LGPL-2.0-or-later
//! Adding drawing to a page of an existing file, in a `write.Update`: what
//! flattening a form and stamping a canvas share.

const std = @import("std");
const Allocator = std.mem.Allocator;
const object = @import("object.zig");
const pages = @import("pages.zig");
const content = @import("content.zig");
const write = @import("write.zig");

const Object = object.Object;
const Dict = object.Dict;
const Entry = object.Entry;
const Ref = object.Ref;
const Update = write.Update;

pub const Error = write.Error || error{
    /// More content or unmatched `q` than is handled.
    TooLarge,
    /// A content stream of the page cannot be decoded, so what it leaves behind
    /// is not known and nothing can safely be drawn after it.
    UnreadableContent,
};

/// Most unmatched `q` or `Q` of a page's content that are made up for.
const max_unmatched = 1000;

/// `v`, with references followed as the update has them.
pub fn resolve(upd: *Update, v: Object) Object {
    var cur = v;
    for (0..32) |_| {
        if (cur != .ref) return cur;
        cur = upd.get(cur.ref.num);
    }
    return .null;
}

/// The page's resources, to which form XObjects are added under names that are
/// not in use. The page gets a copy of its own: the old ones may be shared.
pub const Resources = struct {
    resources: Dict,
    xobjects: Dict,
    added: std.ArrayList(Entry) = .empty,
    next: usize = 0,

    /// `page_dict` is the page's dictionary as the update has it.
    pub fn of(upd: *Update, page: pages.Page, page_dict: Dict) Resources {
        const resources = if (page_dict.get("Resources")) |v| (resolve(upd, v).asDict() orelse page.resources) else page.resources;
        const xobjects: Dict = if (resources.get("XObject")) |v| (resolve(upd, v).asDict() orelse .{}) else .{};
        return .{ .resources = resources, .xobjects = xobjects };
    }

    /// The name under which `form` can now be drawn.
    pub fn add(self: *Resources, upd: *Update, form: Ref) Allocator.Error![]const u8 {
        const a = upd.allocator();
        var name: []const u8 = undefined;
        while (true) {
            name = try std.fmt.allocPrint(a, "PzF{d}", .{self.next});
            self.next += 1;
            if (!self.xobjects.has(name)) break;
        }
        try self.added.append(a, .{ .key = name, .value = .{ .ref = form } });
        return name;
    }

    /// `page_dict` with these resources.
    pub fn applyTo(self: *const Resources, upd: *Update, page_dict: Dict) Allocator.Error!Dict {
        const a = upd.allocator();
        var entries: std.ArrayList(Entry) = .empty;
        try entries.appendSlice(a, self.xobjects.entries);
        try entries.appendSlice(a, self.added.items);
        const own = try write.dictWith(a, self.resources, "XObject", .{ .dict = .{ .entries = entries.items } });
        return write.dictWith(a, page_dict, "Resources", .{ .dict = own });
    }
};

/// The content streams that `/Contents` leads to.
fn parts(upd: *Update, contents: ?Object) Allocator.Error![]const Object {
    const c = contents orelse return &.{};
    const target = resolve(upd, c);
    if (target == .array) return target.array;
    return if (target == .stream) try upd.allocator().dupe(Object, &.{c}) else &.{};
}

fn newStream(upd: *Update, data: []const u8) Error!Object {
    return .{ .ref = try upd.add(.{ .stream = .{ .dict = .{}, .data = data } }) };
}

/// How many `q` of their own the saved states of `old` need around them: one,
/// and one for each `Q` that has no `q`; and how many `Q` then close them all.
/// A single pair is not enough: content with an unmatched `q` or `Q` would
/// leave its transformation in force for what follows.
fn balance(upd: *Update, old: []const Object) Error!struct { open: usize, close: usize } {
    var memory = std.heap.ArenaAllocator.init(upd.arena.child_allocator);
    defer memory.deinit();
    const a = memory.allocator();
    var all: std.ArrayList(u8) = .empty;
    for (old) |part| {
        const o = resolve(upd, part);
        if (o != .stream) continue;
        const data = upd.doc.streamDataIn(a, o.stream) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.UnreadableContent,
        };
        if (data.len > upd.doc.options.max_stream_bytes -| all.items.len) return error.TooLarge;
        try all.appendSlice(a, data);
        try all.append(a, '\n');
    }
    var depth: usize = 0;
    var unmatched: usize = 0;
    var operands = std.heap.ArenaAllocator.init(upd.arena.child_allocator);
    defer operands.deinit();
    var scanner = content.Scanner.init(operands.allocator(), all.items);
    while (try scanner.next()) |op| {
        if (std.mem.eql(u8, op.name, "q")) {
            depth += 1;
        } else if (std.mem.eql(u8, op.name, "Q")) {
            if (depth > 0) depth -= 1 else unmatched += 1;
        }
        if (depth > max_unmatched or unmatched > max_unmatched) return error.TooLarge;
    }
    return .{ .open = 1 + unmatched, .close = 1 + depth };
}

/// `/Contents` with `drawing` after what was there, the old content inside
/// saved states of its own.
pub fn drawOver(upd: *Update, contents: ?Object, drawing: []const u8) Error!Object {
    const a = upd.allocator();
    const old = try parts(upd, contents);
    var out: std.ArrayList(Object) = .empty;
    var tail: []const u8 = drawing;
    if (old.len > 0) {
        const needed = try balance(upd, old);
        var head: std.ArrayList(u8) = .empty;
        for (0..needed.open) |_| try head.appendSlice(a, "q\n");
        var end: std.ArrayList(u8) = .empty;
        try end.appendSlice(a, "\n");
        for (0..needed.close) |_| try end.appendSlice(a, "Q\n");
        try end.appendSlice(a, drawing);
        try out.append(a, try newStream(upd, head.items));
        try out.appendSlice(a, old);
        tail = end.items;
    }
    try out.append(a, try newStream(upd, tail));
    return .{ .array = out.items };
}

/// `/Contents` with `drawing` before what was there. `drawing` must leave the
/// graphics state as it found it; the old content then starts as it did, and
/// needs not be read.
pub fn drawUnder(upd: *Update, contents: ?Object, drawing: []const u8) Error!Object {
    const a = upd.allocator();
    var out: std.ArrayList(Object) = .empty;
    try out.append(a, try newStream(upd, drawing));
    try out.appendSlice(a, try parts(upd, contents));
    return .{ .array = out.items };
}
