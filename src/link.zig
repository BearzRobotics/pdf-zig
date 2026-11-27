// SPDX-License-Identifier: LGPL-2.0-or-later
//! The links of a page and where they go (ISO 32000-1:2008, 12.5.6.5), through
//! a destination (12.3.2) or an action (12.6).
//!
//! Nothing here follows a link. A URI is text from an untrusted file: it may
//! use any scheme (`file:`, say), so a viewer must decide what it will open.

const std = @import("std");
const Allocator = std.mem.Allocator;
const object = @import("object.zig");
const document = @import("document.zig");
const pages = @import("pages.zig");
const outline = @import("outline.zig");

const Dict = object.Dict;
const Document = document.Document;

pub const Target = union(enum) {
    /// A place in this document.
    page: outline.Destination,
    /// The URI of a URI action (12.6.4.7), as the file gives it: valid UTF-8
    /// without control characters. A relative one is not resolved.
    uri: []const u8,
    /// The name of a named action (12.6.4.11): `NextPage`, `PrevPage`,
    /// `FirstPage`, `LastPage`, or one that is the viewer's own.
    named: []const u8,
    /// A link that cannot be given: the action's type (`GoToR`, `Launch`,
    /// `JavaScript`, ...), or `GoTo` or `URI` when the target is unusable.
    unsupported: []const u8,
};

pub const Link = struct {
    /// The annotation's object number (0 for a direct dictionary), as in
    /// `annot.list`, which also gives its `/QuadPoints`.
    num: u32,
    /// The active area, in user space.
    rect: pages.Rect,
    target: Target,
};

/// The links of `page` in the order of its annotations, allocated from `a` (use
/// an arena). Hidden ones, and ones with neither destination nor action, are
/// left out. `page_list` is needed to turn a destination into a page index.
pub fn list(a: Allocator, doc: *Document, page_list: pages.PageList, page: pages.Page) Allocator.Error![]const Link {
    const oom_before = doc.oom_events;
    const items = doc.getArray(page.dict, "Annots") orelse {
        try doc.checkMemory(oom_before);
        return &.{};
    };
    var page_of: outline.PageIndex = .empty;
    defer page_of.deinit(a);
    var indexed = false;
    var work: outline.Work = .{ .lookups = outline.max_outline_lookup_nodes, .page_of = &page_of };
    var out: std.ArrayList(Link) = .empty;
    errdefer out.deinit(a);
    for (items) |item| {
        const d = doc.resolve(item).asDict() orelse continue;
        if (!std.mem.eql(u8, doc.getName(d, "Subtype") orelse continue, "Link")) continue;
        if ((doc.getInt(d, "F") orelse 0) & (2 | 32) != 0) continue; // Hidden, NoView
        const corners = doc.getArray(d, "Rect") orelse continue;
        const rect = pages.rectFrom(doc, corners) orelse continue;
        if (!d.has("Dest") and !d.has("A")) continue;
        // Built once, and only for a page that has links.
        if (!indexed) {
            for (page_list.entries, 0..) |e, i| {
                const gop = try page_of.getOrPut(a, e.num);
                if (!gop.found_existing) gop.value_ptr.* = i;
            }
            indexed = true;
        }
        try out.append(a, .{
            .num = if (item == .ref) item.ref.num else 0,
            .rect = rect,
            .target = try targetOf(a, doc, page_list, d, &work),
        });
    }
    try doc.checkMemory(oom_before);
    return out.toOwnedSlice(a);
}

fn targetOf(a: Allocator, doc: *Document, page_list: pages.PageList, d: Dict, work: *outline.Work) Allocator.Error!Target {
    if (outline.destinationWithin(doc, page_list, d, work)) |dest| return .{ .page = dest };
    // `/Dest` takes the place of an action (table 173).
    if (d.has("Dest")) return .{ .unsupported = "GoTo" };
    const action = doc.getDict(d, "A") orelse return .{ .unsupported = "" };
    const kind = doc.getName(action, "S") orelse return .{ .unsupported = "" };
    if (std.mem.eql(u8, kind, "URI")) {
        const v = doc.get(action, "URI") orelse return .{ .unsupported = "URI" };
        if (v != .string or !printable(v.string)) return .{ .unsupported = "URI" };
        const uri = try copy(a, v.string, work) orelse return .{ .unsupported = "URI" };
        return .{ .uri = uri };
    }
    if (std.mem.eql(u8, kind, "Named")) {
        const name = doc.getName(action, "N") orelse return .{ .unsupported = "Named" };
        const named = try copy(a, name, work) orelse return .{ .unsupported = "Named" };
        return .{ .named = named };
    }
    return .{ .unsupported = try copy(a, kind, work) orelse "" };
}

fn printable(s: []const u8) bool {
    if (s.len == 0 or !std.unicode.utf8ValidateSlice(s)) return false;
    for (s) |c| if (c < 0x20 or c == 0x7f) return false;
    return true;
}

/// A copy of `s`, or null when the listing has copied all it may: many links
/// can share one long string.
fn copy(a: Allocator, s: []const u8, work: *outline.Work) Allocator.Error!?[]const u8 {
    if (s.len > work.text_left) return null;
    work.text_left -= s.len;
    return try a.dupe(u8, s);
}

// ---- tests ---------------------------------------------------------------------------------------

const testing = std.testing;

test "links: destinations, URIs, named actions and what cannot be given" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const annots = [_][]const u8{
        "/Dest [4 0 R /XYZ 10 90 0]",
        "/A << /S /GoTo /D (intro) >>",
        "/A << /S /URI /URI (https://example.org/a?b=c) >>",
        "/A << /S /URI /URI (https://example.org/\\000evil) >>",
        "/A << /S /Named /N /NextPage >>",
        "/A << /S /Launch /F (tool) >>",
        "/Dest (nowhere)",
        "", // neither: left out
        "/F 2 /Dest [4 0 R /Fit]", // hidden: left out
    };
    var bytes: std.ArrayList(u8) = .empty;
    try bytes.appendSlice(a, "%PDF-1.7\n" ++
        "1 0 obj\n<< /Type /Catalog /Pages 2 0 R /Names << /Dests << /Names [(intro) [4 0 R /FitH 70]] >> >> >>\nendobj\n" ++
        "2 0 obj\n<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 /MediaBox [0 0 100 100] >>\nendobj\n" ++
        "4 0 obj\n<< /Type /Page /Parent 2 0 R >>\nendobj\n" ++
        "3 0 obj\n<< /Type /Page /Parent 2 0 R /Annots [");
    for (annots) |body| try bytes.print(a, " << /Subtype /Link /Rect [30 40 10 20] {s} >>", .{body});
    // Another kind of annotation is not a link.
    try bytes.appendSlice(a, " << /Subtype /Text /Rect [0 0 1 1] /A << /S /URI /URI (x) >> >>] >>\nendobj\n" ++
        "trailer\n<< /Root 1 0 R >>\n%%EOF\n");

    var doc = try Document.open(testing.allocator, bytes.items, .{});
    defer doc.deinit();
    const pl = try pages.PageList.build(&doc);
    const links = try list(a, &doc, pl, pages.page(&doc, pl, 0).?);
    try testing.expectEqual(@as(usize, 7), links.len);
    try testing.expectEqual(pages.Rect{ .x0 = 10, .y0 = 20, .x1 = 30, .y1 = 40 }, links[0].rect);
    try testing.expectEqual(outline.Destination{ .page = 1, .x = 10, .y = 90 }, links[0].target.page);
    try testing.expectEqual(outline.Destination{ .page = 1, .y = 70 }, links[1].target.page);
    try testing.expectEqualStrings("https://example.org/a?b=c", links[2].target.uri);
    try testing.expectEqualStrings("URI", links[3].target.unsupported);
    try testing.expectEqualStrings("NextPage", links[4].target.named);
    try testing.expectEqualStrings("Launch", links[5].target.unsupported);
    try testing.expectEqualStrings("GoTo", links[6].target.unsupported);
}
