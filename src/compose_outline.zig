// SPDX-License-Identifier: LGPL-2.0-or-later
//! The part of `compose.Builder` that carries bookmarks over (ISO 32000-1:2008,
//! 12.3.3). A bookmark is kept when it leads to an imported page, and so is a
//! heading above a kept one. Each call's bookmarks follow the earlier ones.

const std = @import("std");
const Allocator = std.mem.Allocator;
const object = @import("object.zig");
const outline = @import("outline.zig");
const serial = @import("write.zig");
const compose = @import("compose.zig");

const Object = object.Object;
const Dict = object.Dict;
const Entry = object.Entry;
const Builder = compose.Builder;
const Copy = compose.Copy;
const Error = compose.Error;

/// One bookmark of the new document. The list is in reading order: every item
/// comes after its parent.
pub const Item = struct {
    /// Index of the item above, or null at the top.
    parent: ?usize,
    /// The entries other than the links between items: `/Title`, and `/Dest`,
    /// `/C` and `/F` when it has them.
    entries: []const Entry,
    open: bool,
};

/// Appends the source's bookmarks to the builder.
pub fn collect(copy: *Copy, work: *outline.Work) Error!void {
    const doc = copy.doc;
    const cat = doc.catalog() orelse return;
    const root = doc.getDict(cat, "Outlines") orelse return;
    var walk: Walk = .{ .copy = copy, .work = work };
    try walk.children(root, null, 0);
}

const Walk = struct {
    copy: *Copy,
    work: *outline.Work,
    seen: std.AutoHashMapUnmanaged(u32, void) = .empty,
    visited: usize = 0,

    fn children(self: *Walk, parent: Dict, above: ?usize, depth: usize) Error!void {
        if (depth >= outline.max_depth) return;
        const copy = self.copy;
        const doc = copy.doc;
        const builder = copy.builder;
        var cursor = parent.get("First");
        while (cursor) |c| {
            if (self.visited >= outline.max_items) return;
            if (c == .ref) if ((try self.seen.getOrPut(copy.a, c.ref.num)).found_existing) return;
            const d = doc.resolve(c).asDict() orelse return;
            self.visited += 1;
            cursor = d.get("Next");

            var dest: ?Object = null;
            const arena = builder.arena.allocator();
            const target: ?Object = d.get("Dest") orelse blk: {
                const action = doc.getDict(d, "A") orelse break :blk null;
                const kind = doc.getName(action, "S") orelse break :blk null;
                break :blk if (std.mem.eql(u8, kind, "GoTo")) action.get("D") else null;
            };
            if (target) |t| dest = try copy.destination(copy.a, t, self.work);

            const at = builder.bookmarks.items.len;
            const held = builder.extra_bytes;
            // Whether it stays is known once its children have been seen.
            try builder.bookmarks.append(builder.gpa, .{ .parent = above, .entries = &.{}, .open = (doc.getInt(d, "Count") orelse 0) > 0 });
            if (d.get("First") != null) try self.children(d, at, depth + 1);
            if (dest == null and builder.bookmarks.items.len == at + 1) {
                builder.bookmarks.shrinkRetainingCapacity(at);
                builder.extra_bytes = held;
                continue;
            }

            var entries: std.ArrayList(Entry) = .empty;
            const title = if (doc.get(d, "Title")) |v| (if (v == .string) v.string else "") else "";
            // Any number of items can share one long title.
            try builder.charge(title.len + 64);
            try entries.append(arena, .{ .key = "Title", .value = .{ .string = try arena.dupe(u8, title) } });
            if (dest) |v| try entries.append(arena, .{ .key = "Dest", .value = try object.dupe(arena, v) });
            if (doc.getArray(d, "C")) |color| if (color.len == 3) {
                var values: [3]f64 = undefined;
                for (&values, color) |*out, v| out.* = doc.resolve(v).asNum() orelse 0;
                try entries.append(arena, .{ .key = "C", .value = try serial.numbers(arena, &values) });
            };
            if (doc.getInt(d, "F")) |v| try entries.append(arena, .{ .key = "F", .value = .{ .integer = v } });
            builder.bookmarks.items[at].entries = entries.items;
        }
    }
};

/// Adds the outline to the end of the file: its root, whose number is returned,
/// and then the bookmarks, numbered in order after it.
pub fn write(a: Allocator, items: []const Item, tail: *compose.Tail) Error!u32 {
    const first = try tail.newNumber();
    for (items) |_| _ = try tail.newNumber();
    // For each item, and in the last slot the root: its first and last child,
    // how many of its descendants show when it is open, and its neighbours.
    const Links = struct { first: ?usize = null, last: ?usize = null, prev: ?usize = null, next: ?usize = null, shown: i64 = 0 };
    const root = items.len;
    const links = try a.alloc(Links, items.len + 1);
    @memset(links, .{});
    for (items, 0..) |item, i| {
        const up = &links[item.parent orelse root];
        if (up.last) |previous| {
            links[previous].next = i;
            links[i].prev = previous;
        } else up.first = i;
        up.last = i;
    }
    var i = items.len;
    while (i > 0) {
        i -= 1;
        links[items[i].parent orelse root].shown += 1 + if (items[i].open) links[i].shown else 0;
    }

    const refOf = struct {
        fn get(start: u32, index: usize) Object {
            return .{ .ref = .{ .num = @intCast(start + 1 + index) } };
        }
    }.get;
    for (0..items.len + 1) |n| {
        // The root first, then the items.
        const index = if (n == 0) root else n - 1;
        var entries: std.ArrayList(Entry) = .empty;
        if (index == root) {
            try entries.append(a, .{ .key = "Type", .value = .{ .name = "Outlines" } });
        } else {
            try entries.appendSlice(a, items[index].entries);
            const parent: Object = if (items[index].parent) |p| refOf(first, p) else .{ .ref = .{ .num = first } };
            try entries.append(a, .{ .key = "Parent", .value = parent });
        }
        const l = links[index];
        for ([_]struct { []const u8, ?usize }{ .{ "First", l.first }, .{ "Last", l.last }, .{ "Prev", l.prev }, .{ "Next", l.next } }) |pair| {
            if (pair[1]) |target| try entries.append(a, .{ .key = pair[0], .value = refOf(first, target) });
        }
        if (l.shown > 0) {
            const open = index == root or items[index].open;
            try entries.append(a, .{ .key = "Count", .value = .{ .integer = if (open) l.shown else -l.shown } });
        }
        try tail.add(@intCast(first + n), .{ .dict = .{ .entries = entries.items } });
    }
    return first;
}
