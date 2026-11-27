// SPDX-License-Identifier: LGPL-2.0-or-later
//! Makes a new PDF from pages of others, so as to extract, reorder or merge:
//!     zig build && zig-out/bin/pdfpages OUT.pdf IN.pdf[:PAGES] ...
//! PAGES is a list such as `3,1,5-9` or `9-1`; without it, every page. A PDF
//! name that itself contains a colon needs a PAGES list.

const std = @import("std");
const pdf = @import("pdf");

const usage = "usage: pdfpages OUT.pdf IN.pdf[:PAGES] ...  (pages are numbered from 1, as in 3,1,5-9)\n";

/// Appends the 0-based indices that `spec` names in a document of `count` pages.
fn parsePages(a: std.mem.Allocator, spec: []const u8, count: usize, out: *std.ArrayList(usize)) !void {
    var parts = std.mem.splitScalar(u8, spec, ',');
    while (parts.next()) |part| {
        const dash = std.mem.indexOfScalar(u8, part, '-');
        const first = try std.fmt.parseInt(usize, part[0 .. dash orelse part.len], 10);
        const last = if (dash) |d| try std.fmt.parseInt(usize, part[d + 1 ..], 10) else first;
        if (first == 0 or last == 0 or first > count or last > count) return error.NoSuchPage;
        var n = first;
        while (true) {
            try out.append(a, n - 1);
            if (n == last) break;
            n = if (last > first) n + 1 else n - 1;
        }
    }
}

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 3) {
        std.debug.print(usage, .{});
        return 2;
    }
    var builder = pdf.compose.Builder.init(gpa, .{});
    defer builder.deinit();
    for (args[2..]) |arg| {
        const colon = std.mem.lastIndexOfScalar(u8, arg, ':');
        const path = arg[0 .. colon orelse arg.len];
        var file = try std.Io.Dir.cwd().openFile(io, path, .{});
        defer file.close(io);
        var buf: [65536]u8 = undefined;
        var reader = file.reader(io, &buf);
        var doc = try pdf.Document.openReader(gpa, &reader.interface, .{});
        defer doc.deinit();
        const count = (try pdf.pages.PageList.build(&doc)).entries.len;
        var indices: std.ArrayList(usize) = .empty;
        defer indices.deinit(gpa);
        if (colon) |c| {
            parsePages(gpa, arg[c + 1 ..], count, &indices) catch |err| {
                std.debug.print("pdfpages: {s}: bad page list ({t}); the file has {d} pages\n", .{ arg, err, count });
                return 1;
            };
        } else for (0..count) |i| try indices.append(gpa, i);
        builder.importPages(&doc, indices.items, .{}) catch |err| {
            std.debug.print("pdfpages: {s}: {t}\n", .{ path, err });
            return 1;
        };
    }

    // Written beside the target and then renamed over it, so that a failure
    // leaves what was there.
    var out_file = try std.Io.Dir.cwd().createFileAtomic(io, args[1], .{ .replace = true });
    defer out_file.deinit(io);
    var wbuf: [65536]u8 = undefined;
    var writer = out_file.file.writer(io, &wbuf);
    builder.write(&writer.interface) catch |err| {
        std.debug.print("pdfpages: {t}\n", .{err});
        return 1;
    };
    try writer.interface.flush();
    try out_file.replace(io);
    return 0;
}
