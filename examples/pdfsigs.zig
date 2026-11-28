// SPDX-License-Identifier: LGPL-2.0-or-later
//! Lists the signatures of a PDF, what each claims and covers, and what changed
//! afterwards. **Nothing is verified.**
//!     pdfsigs [-p PASSWORD] IN.pdf
//!     pdfsigs [-p PASSWORD] IN.pdf N OUT.pdf    save what signature N covers

const std = @import("std");
const pdf = @import("pdf");

/// Text from a file, with control characters, which could redraw a terminal,
/// shown as `?`.
fn printable(a: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var view = std.unicode.Utf8View.init(s) catch return "(not text)";
    var it = view.iterator();
    while (it.nextCodepointSlice()) |slice| {
        const c = std.unicode.utf8Decode(slice) catch 0;
        // C0, delete, C1, and the controls that reorder text.
        const control = c < 0x20 or (c >= 0x7f and c < 0xa0) or (c >= 0x200b and c <= 0x200f) or
            (c >= 0x202a and c <= 0x202e) or (c >= 0x2066 and c <= 0x2069);
        try out.appendSlice(a, if (control) "?" else slice);
    }
    return out.items;
}

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    const a = init.arena.allocator();
    var args: []const [:0]const u8 = try init.minimal.args.toSlice(a);
    var password: []const u8 = "";
    if (args.len > 2 and std.mem.eql(u8, args[1], "-p")) {
        password = args[2];
        args = args[2..];
    } else args = args[0..];
    if (args.len != 2 and args.len != 4) {
        std.debug.print("usage: pdfsigs [-p PASSWORD] IN.pdf [N OUT.pdf]\n", .{});
        return 2;
    }
    var file = try std.Io.Dir.cwd().openFile(io, args[1], .{});
    defer file.close(io);
    var buf: [65536]u8 = undefined;
    var reader = file.reader(io, &buf);
    var doc = try pdf.Document.openReader(gpa, &reader.interface, .{ .password = password });
    defer doc.deinit();
    const list = try pdf.pages.PageList.build(&doc);
    const found = try pdf.signature.list(a, &doc, list, .{ .password = password });

    if (args.len == 4) {
        const n = std.fmt.parseInt(usize, args[2], 10) catch 0;
        if (n == 0 or n > found.len) {
            std.debug.print("pdfsigs: no signature {s}\n", .{args[2]});
            return 1;
        }
        const bytes = pdf.signature.signedRevision(&doc, found[n - 1]) orelse {
            std.debug.print("pdfsigs: the coverage of signature {d} is not sound\n", .{n});
            return 1;
        };
        var out = try std.Io.Dir.cwd().createFile(io, args[3], .{ .exclusive = true });
        defer out.close(io);
        try out.writeStreamingAll(io, bytes);
        return 0;
    }

    var out_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &out_buf);
    const w = &stdout.interface;
    try w.print("{d} signature(s). Nothing here is verified.\n", .{found.len});
    for (found, 1..) |s, n| {
        try w.print("\n{d}. {t}", .{ n, s.kind });
        if (s.field_name.len > 0) try w.print(" in field \"{s}\"", .{try printable(a, s.field_name)});
        if (s.in_permissions) try w.writeAll(", named by the document's permissions");
        try w.writeByte('\n');
        if (s.kind == .certification) try w.print("   allows: {s}\n", .{if (s.allowed) |allowed| @tagName(allowed) else "(unknown level)"});
        if (s.lock) |lock| try w.print("   locks fields: {t}, {d} named{s}\n", .{ lock.action, lock.fields.len, if (lock.complete) "" else " (more left out)" });
        inline for (.{ "name", "date", "reason", "location", "contact" }) |key| {
            if (@field(s.claims, key)) |v| try w.print("   claimed {s}: {s}\n", .{ key, try printable(a, v) });
        }
        if (s.sub_filter) |v| try w.print("   format: {s}\n", .{try printable(a, v)});
        switch (s.coverage) {
            .sound => |c| {
                try w.print("   covers the first {d} of {d} bytes, all but its own value\n", .{ c.end, doc.data.len });
                const r = c.byte_range;
                try w.print("   byte range: {d} {d} {d} {d}\n", .{ r[0], r[1], r[2], r[3] });
            },
            .unsound => |defect| try w.print("   COVERAGE NOT SOUND: {t}\n", .{defect}),
        }
        switch (s.after) {
            .unknown => {},
            .nothing => try w.writeAll("   nothing follows the signed bytes\n"),
            .changed => |c| {
                try w.print("   CHANGED AFTER SIGNING: {d} bytes follow", .{c.bytes});
                if (c.trailer) try w.writeAll("; the trailer points elsewhere");
                try w.writeByte('\n');
                for (c.objects[0..@min(c.objects.len, 20)]) |change| try w.print("     object {d} {t}\n", .{ change.num, change.kind });
                const more = c.objects.len -| 20 + c.omitted;
                if (more > 0) try w.print("     and {d} more\n", .{more});
                if (c.objects.len == 0) try w.writeAll("     no object entry differs; some readers may still show the added bytes\n");
            },
        }
    }
    try w.flush();
    return 0;
}
