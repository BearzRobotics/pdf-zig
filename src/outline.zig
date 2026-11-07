//! The document outline, the "bookmarks" of a PDF (ISO 32000-1:2008, 12.3.3),
//! and destinations (12.3.2).
//!
//! `read` returns the whole tree. Reading is bounded: a node is visited once
//! (so loops end), nesting stops at `max_depth` and the tree at `max_items`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const object = @import("object.zig");
const document = @import("document.zig");
const pages = @import("pages.zig");
const write = @import("write.zig");

const Object = object.Object;
const Dict = object.Dict;
const Document = document.Document;

pub const max_depth = 32;
pub const max_items = 100_000;

/// Where a bookmark or link goes.
pub const Destination = struct {
    /// Page index, 0-based.
    page: usize,
    /// Position on the page in user space, when the destination gives one.
    x: ?f64 = null,
    y: ?f64 = null,
};

pub const Item = struct {
    /// Object number of the outline item (what `remove` takes).
    num: u32,
    /// UTF-8.
    title: []const u8,
    dest: ?Destination,
    /// The file asks for the children to be shown at first.
    open: bool,
    children: []const Item,
};

/// The outline of `doc`, allocated from `a` (use an arena). Empty when there is none.
pub fn read(a: Allocator, doc: *Document, list: pages.PageList) Allocator.Error![]const Item {
    const cat = doc.catalog() orelse return &.{};
    const root = doc.getDict(cat, "Outlines") orelse return &.{};
    var budget: usize = max_items;
    var seen: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer seen.deinit(a);
    return children(a, doc, list, root, 0, &budget, &seen);
}

/// The items below `parent` (a dictionary with `/First`).
fn children(a: Allocator, doc: *Document, list: pages.PageList, parent: Dict, depth: usize, budget: *usize, seen: *std.AutoHashMapUnmanaged(u32, void)) Allocator.Error![]const Item {
    if (depth >= max_depth) return &.{};
    var out: std.ArrayList(Item) = .empty;
    errdefer out.deinit(a);
    var cursor = parent.get("First");
    while (cursor) |c| {
        if (budget.* == 0) break;
        // Each node once: a /Next or /First that leads back ends the walk.
        if (c == .ref) {
            const gop = try seen.getOrPut(a, c.ref.num);
            if (gop.found_existing) break;
        }
        const d = doc.resolve(c).asDict() orelse break;
        budget.* -= 1;

        const title_raw = if (doc.get(d, "Title")) |t| (if (t == .string) t.string else "") else "";
        const count = doc.getInt(d, "Count") orelse 0;
        try out.append(a, .{
            .num = if (c == .ref) c.ref.num else 0,
            .title = try write.textToUtf8(a, title_raw),
            .dest = destinationOf(a, doc, list, d),
            .open = count > 0,
            .children = if (d.get("First") != null) try children(a, doc, list, d, depth + 1, budget, seen) else &.{},
        });
        cursor = d.get("Next");
    }
    return out.toOwnedSlice(a);
}

/// The destination of an outline item or link: its `/Dest`, or the `/D` of a GoTo action `/A`.
pub fn destinationOf(a: Allocator, doc: *Document, list: pages.PageList, d: Dict) ?Destination {
    if (d.get("Dest")) |dest| return resolveDest(a, doc, list, dest, 0);
    const action = doc.getDict(d, "A") orelse return null;
    const kind = doc.getName(action, "S") orelse return null;
    if (!std.mem.eql(u8, kind, "GoTo")) return null;
    return resolveDest(a, doc, list, action.get("D") orelse return null, 0);
}

fn resolveDest(a: Allocator, doc: *Document, list: pages.PageList, dest: Object, depth: usize) ?Destination {
    if (depth > 4) return null;
    const o = doc.resolve(dest);
    switch (o) {
        .array => |arr| return fromArray(doc, list, arr),
        .dict => |d| return resolveDest(a, doc, list, d.get("D") orelse return null, depth + 1),
        .name, .string => |key| {
            // A named destination: the catalog's /Dests dictionary, then the /Names /Dests tree.
            const cat = doc.catalog() orelse return null;
            if (o == .name) if (doc.getDict(cat, "Dests")) |dests| if (dests.get(key)) |v| return resolveDest(a, doc, list, v, depth + 1);
            if (doc.getDict(cat, "Names")) |names| if (doc.getDict(names, "Dests")) |tree| {
                if (lookupTree(doc, tree, key, 0)) |v| return resolveDest(a, doc, list, v, depth + 1);
            };
            return null;
        },
        else => return null,
    }
}

fn fromArray(doc: *Document, list: pages.PageList, arr: []const Object) ?Destination {
    if (arr.len == 0) return null;
    const first = arr[0];
    var page_index: ?usize = null;
    if (first == .ref) {
        for (list.entries, 0..) |e, i| if (e.num == first.ref.num) {
            page_index = i;
            break;
        };
    }
    const idx = page_index orelse return null;
    var out: Destination = .{ .page = idx };
    // [page /XYZ left top zoom]: the only form that says where on the page.
    if (arr.len >= 4 and doc.resolve(arr[1]) == .name and std.mem.eql(u8, doc.resolve(arr[1]).name, "XYZ")) {
        out.x = doc.resolve(arr[2]).asNum();
        out.y = doc.resolve(arr[3]).asNum();
    } else if (arr.len >= 3 and doc.resolve(arr[1]) == .name and std.mem.eql(u8, doc.resolve(arr[1]).name, "FitH")) {
        out.y = doc.resolve(arr[2]).asNum();
    }
    return out;
}

/// Looks `key` up in a name tree (7.9.6).
fn lookupTree(doc: *Document, node: Dict, key: []const u8, depth: usize) ?Object {
    if (depth > 16) return null;
    if (doc.getArray(node, "Names")) |pairs| {
        var i: usize = 0;
        while (i + 1 < pairs.len) : (i += 2) {
            const k = doc.resolve(pairs[i]);
            if (k == .string and std.mem.eql(u8, k.string, key)) return pairs[i + 1];
        }
    }
    if (doc.getArray(node, "Kids")) |kids| for (kids) |kid| {
        const kd = doc.resolve(kid).asDict() orelse continue;
        // A kid with /Limits [low high] can be skipped when the key is outside it.
        if (doc.getArray(kd, "Limits")) |lim| if (lim.len == 2) {
            const lo = doc.resolve(lim[0]);
            const hi = doc.resolve(lim[1]);
            if (lo == .string and hi == .string and (std.mem.lessThan(u8, key, lo.string) or std.mem.lessThan(u8, hi.string, key))) continue;
        };
        if (lookupTree(doc, kd, key, depth + 1)) |v| return v;
    };
    return null;
}

// ---- editing -------------------------------------------------------------------------------------

pub const EditError = write.Error || error{ NoCatalog, NoSuchItem, DirectPage };

fn refOf(o: ?Object) ?object.Ref {
    const v = o orelse return null;
    return if (v == .ref) v.ref else null;
}

/// Appends a top-level bookmark that goes to page object `page_num` (`pages.Page.num`),
/// scrolled so that user-space height `top` is at the top of the window when given.
/// Creates the outline when the document has none.
pub fn add(upd: *write.Update, page_num: u32, title: []const u8, top: ?f64) EditError!object.Ref {
    if (page_num == 0) return error.DirectPage;
    const a = upd.allocator();
    const root_ref = refOf(upd.doc.trailer.get("Root")) orelse return error.NoCatalog;
    var cat = upd.get(root_ref.num).asDict() orelse return error.NoCatalog;

    const dest = try a.dupe(Object, &.{
        .{ .ref = .{ .num = page_num } },
        .{ .name = "XYZ" },
        .null,
        if (top) |t| Object{ .real = t } else .null,
        .null,
    });
    const title_obj: Object = .{ .string = try write.textString(a, title) };

    if (refOf(cat.get("Outlines"))) |outlines| {
        var root = upd.get(outlines.num).asDict() orelse return error.NoCatalog;
        const last = refOf(root.get("Last"));
        var entries: std.ArrayList(object.Entry) = .empty;
        try entries.append(a, .{ .key = "Title", .value = title_obj });
        try entries.append(a, .{ .key = "Parent", .value = .{ .ref = outlines } });
        if (last) |l| try entries.append(a, .{ .key = "Prev", .value = .{ .ref = l } });
        try entries.append(a, .{ .key = "Dest", .value = .{ .array = dest } });
        const item = try upd.add(.{ .dict = .{ .entries = entries.items } });
        if (last) |l| {
            const ld = upd.get(l.num).asDict() orelse return error.NoSuchItem;
            try upd.set(l.num, .{ .dict = try write.dictWith(a, ld, "Next", .{ .ref = item }) });
        }
        if (root.get("First") == null) root = try write.dictWith(a, root, "First", .{ .ref = item });
        root = try write.dictWith(a, root, "Last", .{ .ref = item });
        try upd.set(outlines.num, .{ .dict = try recount(upd, root) });
        return item;
    }

    // No outline yet: the root and the first item refer to each other, so number the root first.
    const root = try upd.add(.null);
    const item = try upd.add(.{ .dict = try write.makeDict(a, &.{
        .{ "Title", title_obj },
        .{ "Parent", .{ .ref = root } },
        .{ "Dest", .{ .array = dest } },
    }) });
    try upd.set(root.num, .{ .dict = try write.makeDict(a, &.{
        .{ "Type", .{ .name = "Outlines" } },
        .{ "First", .{ .ref = item } },
        .{ "Last", .{ .ref = item } },
        .{ "Count", .{ .integer = 1 } },
    }) });
    cat = try write.dictWith(a, cat, "Outlines", .{ .ref = root });
    try upd.set(root_ref.num, .{ .dict = cat });
    return item;
}

/// Removes outline item `num` and everything below it from the tree.
pub fn remove(upd: *write.Update, num: u32) EditError!void {
    const a = upd.allocator();
    const d = upd.get(num).asDict() orelse return error.NoSuchItem;
    const parent_ref = refOf(d.get("Parent")) orelse return error.NoSuchItem;
    const prev = refOf(d.get("Prev"));
    const next = refOf(d.get("Next"));

    if (prev) |p| {
        const pd = upd.get(p.num).asDict() orelse return error.NoSuchItem;
        try upd.set(p.num, .{ .dict = if (next) |n| try write.dictWith(a, pd, "Next", .{ .ref = n }) else try write.dictWithout(a, pd, "Next") });
    }
    if (next) |n| {
        const nd = upd.get(n.num).asDict() orelse return error.NoSuchItem;
        try upd.set(n.num, .{ .dict = if (prev) |p| try write.dictWith(a, nd, "Prev", .{ .ref = p }) else try write.dictWithout(a, nd, "Prev") });
    }
    var parent = upd.get(parent_ref.num).asDict() orelse return error.NoSuchItem;
    if (prev == null) parent = if (next) |n| try write.dictWith(a, parent, "First", .{ .ref = n }) else try write.dictWithout(a, parent, "First");
    if (next == null) parent = if (prev) |p| try write.dictWith(a, parent, "Last", .{ .ref = p }) else try write.dictWithout(a, parent, "Last");
    try upd.set(parent_ref.num, .{ .dict = try recount(upd, parent) });
}

/// `d` with `/Count` set from its children: the number of visible descendants
/// (open children count themselves and their own `/Count`). The sign of the old
/// count says whether `d` is open; no count means open for the root.
fn recount(upd: *write.Update, d: Dict) EditError!Dict {
    const a = upd.allocator();
    var n: i64 = 0;
    var cursor = refOf(d.get("First"));
    var steps: usize = 0;
    while (cursor) |c| : (steps += 1) {
        if (steps > max_items) break;
        n += 1;
        const cd = upd.get(c.num).asDict() orelse break;
        if (cd.get("Count")) |cnt| if (cnt.asInt()) |v| {
            if (v > 0) n += v;
        };
        cursor = refOf(cd.get("Next"));
    }
    if (n == 0) return write.dictWithout(a, d, "Count");
    const closed = if (d.get("Count")) |cnt| (cnt.asInt() orelse 1) < 0 else false;
    return write.dictWith(a, d, "Count", .{ .integer = if (closed) -n else n });
}

// ---- tests ---------------------------------------------------------------------------------------

const testing = std.testing;

test "outline: nesting, destinations, named destinations and loops" {
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    // Objects: 1 catalog, 2 pages, 3 and 4 pages, 5 outlines, 6 chapter, 7 section, 8 chapter two, 9 named.
    const bodies = [_][]const u8{
        "<< /Type /Catalog /Pages 2 0 R /Outlines 5 0 R /Names << /Dests << /Names [(intro) [4 0 R /XYZ 10 90 0]] >> >> >>",
        "<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] >>",
        "<< /Type /Outlines /First 6 0 R /Last 8 0 R /Count 3 >>",
        "<< /Title (Chapter 1) /Parent 5 0 R /First 7 0 R /Last 7 0 R /Next 8 0 R /Count 1 /Dest [3 0 R /Fit] >>",
        "<< /Title <FEFF00E900E9> /Parent 6 0 R /Dest [4 0 R /XYZ 5 60 null] >>",
        // Chapter two goes by a named destination and its /Next loops back to chapter one.
        "<< /Title (Intro) /Parent 5 0 R /A << /S /GoTo /D (intro) >> /Next 6 0 R >>",
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

    var doc = try Document.open(a, file.items, .{});
    defer doc.deinit();
    const pl = try pages.PageList.build(&doc);
    const items = try read(aa, &doc, pl);
    try testing.expectEqual(@as(usize, 2), items.len);
    try testing.expectEqualStrings("Chapter 1", items[0].title);
    try testing.expectEqual(@as(usize, 0), items[0].dest.?.page);
    try testing.expect(items[0].open);
    try testing.expectEqual(@as(usize, 1), items[0].children.len);
    try testing.expectEqualStrings("\u{e9}\u{e9}", items[0].children[0].title);
    try testing.expectEqual(@as(usize, 1), items[0].children[0].dest.?.page);
    try testing.expectEqual(@as(?f64, 5), items[0].children[0].dest.?.x);
    try testing.expectEqual(@as(?f64, 60), items[0].children[0].dest.?.y);
    // The named destination.
    try testing.expectEqualStrings("Intro", items[1].title);
    try testing.expectEqual(@as(usize, 1), items[1].dest.?.page);
    try testing.expectEqual(@as(?f64, 90), items[1].dest.?.y);
}

test "a document without an outline gives an empty list" {
    const tests = @import("interp_tests.zig");
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try Document.open(testing.allocator, try tests.page(arena.allocator(), "0 g", "", &.{}, ""), .{});
    defer doc.deinit();
    const pl = try pages.PageList.build(&doc);
    try testing.expectEqual(@as(usize, 0), (try read(arena.allocator(), &doc, pl)).len);
}

test "bookmarks can be added to a document without an outline, and removed" {
    const tests = @import("interp_tests.zig");
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    const bytes = try tests.page(aa, "0 g", "", &.{}, "");

    var doc = try Document.open(a, bytes, .{});
    defer doc.deinit();
    var upd = try write.Update.init(a, &doc);
    defer upd.deinit();
    _ = try add(&upd, 3, "caf\u{e9}", 80);
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    try upd.write(a, &out.writer);

    var doc2 = try Document.open(a, out.written(), .{});
    defer doc2.deinit();
    try testing.expect(!doc2.repaired);
    const pl2 = try pages.PageList.build(&doc2);
    var items = try read(aa, &doc2, pl2);
    try testing.expectEqual(@as(usize, 1), items.len);
    try testing.expectEqualStrings("caf\u{e9}", items[0].title);
    try testing.expectEqual(@as(usize, 0), items[0].dest.?.page);
    try testing.expectEqual(@as(?f64, 80), items[0].dest.?.y);

    // A second and third bookmark join the list in order.
    var upd2 = try write.Update.init(a, &doc2);
    defer upd2.deinit();
    _ = try add(&upd2, 3, "two", null);
    _ = try add(&upd2, 3, "three", null);
    var out2: std.Io.Writer.Allocating = .init(a);
    defer out2.deinit();
    try upd2.write(a, &out2.writer);
    var doc3 = try Document.open(a, out2.written(), .{});
    defer doc3.deinit();
    const pl3 = try pages.PageList.build(&doc3);
    items = try read(aa, &doc3, pl3);
    try testing.expectEqual(@as(usize, 3), items.len);
    try testing.expectEqualStrings("two", items[1].title);
    try testing.expectEqualStrings("three", items[2].title);

    // Remove the middle one, then the first.
    var upd3 = try write.Update.init(a, &doc3);
    defer upd3.deinit();
    try remove(&upd3, items[1].num);
    var out3: std.Io.Writer.Allocating = .init(a);
    defer out3.deinit();
    try upd3.write(a, &out3.writer);
    var doc4 = try Document.open(a, out3.written(), .{});
    defer doc4.deinit();
    const pl4 = try pages.PageList.build(&doc4);
    items = try read(aa, &doc4, pl4);
    try testing.expectEqual(@as(usize, 2), items.len);
    try testing.expectEqualStrings("three", items[1].title);

    var upd4 = try write.Update.init(a, &doc4);
    defer upd4.deinit();
    try remove(&upd4, items[0].num);
    var out4: std.Io.Writer.Allocating = .init(a);
    defer out4.deinit();
    try upd4.write(a, &out4.writer);
    var doc5 = try Document.open(a, out4.written(), .{});
    defer doc5.deinit();
    const pl5 = try pages.PageList.build(&doc5);
    items = try read(aa, &doc5, pl5);
    try testing.expectEqual(@as(usize, 1), items.len);
    try testing.expectEqualStrings("three", items[0].title);
}
