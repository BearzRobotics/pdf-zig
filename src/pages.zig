// SPDX-License-Identifier: LGPL-2.0-or-later
//! The page tree (ISO 32000-1:2008, 7.7.3) and page attributes with
//! inheritance (7.7.3.4).

const std = @import("std");
const Allocator = std.mem.Allocator;
const object = @import("object.zig");
const doc_mod = @import("document.zig");
const Document = doc_mod.Document;
const Object = object.Object;
const Dict = object.Dict;

/// A rectangle with `x0 <= x1` and `y0 <= y1` (7.9.5 normalises corners).
pub const Rect = struct {
    x0: f64,
    y0: f64,
    x1: f64,
    y1: f64,

    pub fn width(self: Rect) f64 {
        return self.x1 - self.x0;
    }

    pub fn height(self: Rect) f64 {
        return self.y1 - self.y0;
    }

    pub const letter: Rect = .{ .x0 = 0, .y0 = 0, .x1 = 612, .y1 = 792 };
};

pub const Page = struct {
    /// The page object's number (0 if it is a direct object).
    num: u32,
    dict: Dict,
    media_box: Rect,
    /// `/CropBox`, or the media box.
    crop_box: Rect,
    /// Clockwise rotation in degrees when displayed: 0, 90, 180 or 270.
    rotate: u16,
    resources: Dict,

    /// Width and height of the page as displayed (crop box, rotation applied).
    pub fn displaySize(self: Page) struct { w: f64, h: f64 } {
        const w = self.crop_box.width();
        const h = self.crop_box.height();
        return if (self.rotate == 90 or self.rotate == 270) .{ .w = h, .h = w } else .{ .w = w, .h = h };
    }
};

const Inherited = struct {
    resources: ?Object = null,
    media_box: ?Object = null,
    crop_box: ?Object = null,
    rotate: ?Object = null,
};

const Entry = struct {
    num: u32,
    dict: Dict,
    inh: Inherited,
};

/// Every page of the document in order, found by walking the whole tree once.
/// The walk is bounded: a node or `/Kids` array that is an object of its own is
/// visited once (cycles end), and at most
/// `max_pages` pages are collected.
pub const PageList = struct {
    entries: []const Entry,
    /// Some pages are missing: the tree has a branch nested deeper than
    /// `max_depth`, or more than `max_pages` pages.
    truncated: bool = false,

    pub const max_depth = 256;

    pub const max_pages = 1 << 20;

    pub fn build(doc: *Document) Allocator.Error!PageList {
        const oom_before = doc.oom_events;
        const list = try walk(doc);
        // A node that could not be read would silently drop its pages.
        try doc.checkMemory(oom_before);
        return list;
    }

    fn walk(doc: *Document) Allocator.Error!PageList {
        const a = doc.arena.allocator();
        var out: std.ArrayList(Entry) = .empty;
        const root = doc.get(doc.catalog() orelse return .{ .entries = &.{} }, "Pages") orelse return .{ .entries = &.{} };
        const root_num: u32 = if (doc.catalog().?.get("Pages")) |p| (if (p == .ref) p.ref.num else 0) else 0;

        const Frame = struct { node: Dict, num: u32, inh: Inherited, next_kid: usize };
        var stack: std.ArrayList(Frame) = .empty;
        var visited: std.AutoHashMapUnmanaged(u32, void) = .empty;
        const root_dict = root.asDict() orelse return .{ .entries = &.{} };
        if (root_num != 0) try visited.put(a, root_num, {});
        try stack.append(a, .{ .node = root_dict, .num = root_num, .inh = inheritFrom(.{}, root_dict), .next_kid = 0 });

        var truncated = false;
        while (stack.items.len > 0) {
            if (out.items.len >= max_pages) {
                truncated = true;
                break;
            }
            var top = &stack.items[stack.items.len - 1];
            const kids = doc.getArray(top.node, "Kids") orelse {
                // A root without /Kids: it is the only page, unless it says it
                // is a node of the tree.
                if (!isTreeNode(doc, top.node)) try out.append(a, .{ .num = top.num, .dict = top.node, .inh = top.inh });
                _ = stack.pop();
                continue;
            };
            // An array that is an object of its own is expanded once. Without
            // this, direct kid dictionaries naming the same arrays make the
            // walk exponential.
            if (top.next_kid == 0) if (top.node.get("Kids").? == .ref) {
                if ((try visited.getOrPut(a, top.node.get("Kids").?.ref.num)).found_existing) {
                    _ = stack.pop();
                    continue;
                }
            };
            if (top.next_kid >= kids.len) {
                _ = stack.pop();
                continue;
            }
            const kid = kids[top.next_kid];
            top.next_kid += 1;
            const kid_num: u32 = if (kid == .ref) kid.ref.num else 0;
            if (kid_num != 0) {
                if (visited.contains(kid_num)) continue;
                try visited.put(a, kid_num, {});
            }
            const kd = doc.resolve(kid).asDict() orelse continue;
            if (kd.has("Kids")) {
                // Only this branch is left out; the walk goes on with the rest.
                if (stack.items.len >= max_depth - 1) {
                    truncated = true;
                    continue;
                }
                const inh = inheritFrom(top.inh, kd);
                try stack.append(a, .{ .node = kd, .num = kid_num, .inh = inh, .next_kid = 0 });
            } else if (!isTreeNode(doc, kd)) {
                try out.append(a, .{ .num = kid_num, .dict = kd, .inh = inheritFrom(top.inh, kd) });
            }
        }
        return .{ .entries = out.items, .truncated = truncated };
    }

    /// Whether `d` calls itself an inner node: without kids it has no pages.
    fn isTreeNode(doc: *Document, d: Dict) bool {
        return std.mem.eql(u8, doc.getName(d, "Type") orelse "", "Pages");
    }

    fn inheritFrom(parent: Inherited, d: Dict) Inherited {
        return .{
            .resources = d.get("Resources") orelse parent.resources,
            .media_box = d.get("MediaBox") orelse parent.media_box,
            .crop_box = d.get("CropBox") orelse parent.crop_box,
            .rotate = d.get("Rotate") orelse parent.rotate,
        };
    }
};

fn rectOf(doc: *Document, o: ?Object) ?Rect {
    const arr = (doc.resolve(o orelse return null)).asArray() orelse return null;
    if (arr.len < 4) return null;
    var v: [4]f64 = undefined;
    for (0..4) |i| v[i] = doc.resolve(arr[i]).asNum() orelse return null;
    return .{ .x0 = @min(v[0], v[2]), .y0 = @min(v[1], v[3]), .x1 = @max(v[0], v[2]), .y1 = @max(v[1], v[3]) };
}

/// Resolved attributes of the page at `index`.
pub fn page(doc: *Document, list: PageList, index: usize) ?Page {
    if (index >= list.entries.len) return null;
    const e = list.entries[index];
    // A box without area, or without a finite size, cannot be a page.
    var media = rectOf(doc, e.inh.media_box) orelse Rect.letter;
    if (!(media.width() > 0 and media.height() > 0 and std.math.isFinite(media.width()) and std.math.isFinite(media.height()))) media = Rect.letter;
    const crop_raw = rectOf(doc, e.inh.crop_box);
    // The crop box is clipped to the media box (14.11.2).
    const crop = if (crop_raw) |c| Rect{
        .x0 = @max(c.x0, media.x0),
        .y0 = @max(c.y0, media.y0),
        .x1 = @min(c.x1, media.x1),
        .y1 = @min(c.y1, media.y1),
    } else media;
    const rot_raw: i64 = if (e.inh.rotate) |r| (doc.resolve(r).asInt() orelse 0) else 0;
    // Reduced first: rounding down to a multiple of 90 overflows near minInt(i64).
    const rot: u16 = @intCast(@divTrunc(@mod(rot_raw, 360), 90) * 90);
    return .{
        .num = e.num,
        .dict = e.dict,
        .media_box = media,
        .crop_box = if (crop.width() > 0 and crop.height() > 0) crop else media,
        .rotate = rot,
        .resources = if (e.inh.resources) |r| (doc.resolve(r).asDict() orelse .{}) else .{},
    };
}

/// Content streams of a page joined into one buffer, separated by a newline
/// (7.8.2: the split between streams may fall between any two tokens).
/// The buffer is allocated from `a`; pass a scratch arena to avoid keeping it
/// for the life of the document.
pub fn contents(doc: *Document, a: Allocator, p: Page) (Allocator.Error || doc_mod.Error)![]const u8 {
    const oom_before = doc.oom_events;
    const c = doc.get(p.dict, "Contents") orelse {
        try doc.checkMemory(oom_before);
        return "";
    };
    var out: std.ArrayList(u8) = .empty;
    switch (c) {
        .stream => |s| try out.appendSlice(a, try doc.streamDataIn(a, s)),
        .array => |arr| {
            // Each part is decoded into memory of its own and freed once it has
            // been appended. The limit counts all that decoding produces, so
            // repeating a part that decodes to little is not free.
            var part = std.heap.ArenaAllocator.init(doc.arena.child_allocator);
            defer part.deinit();
            var work: usize = 0;
            for (arr) |item| {
                const r = doc.resolve(item);
                if (r != .stream) continue;
                _ = part.reset(.retain_capacity);
                const decoded = try doc.decodeStreamIn(part.allocator(), r.stream);
                try out.appendSlice(a, decoded.data);
                try out.append(a, '\n');
                work +|= @max(decoded.work, decoded.data.len);
                if (work > doc.options.max_stream_bytes or out.items.len > doc.options.max_stream_bytes) return error.TooLarge;
            }
        },
        else => {},
    }
    try doc.checkMemory(oom_before);
    return out.items;
}
