//! Prints what pdf-zig sees in a PDF file, and decodes every stream:
//!
//!     zig build && zig-out/bin/pdfinfo FILE.pdf

const std = @import("std");
const pdf = @import("pdf");

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) {
        std.debug.print("usage: pdfinfo FILE\n", .{});
        return 2;
    }
    var file = std.Io.Dir.cwd().openFile(io, args[1], .{}) catch |err| {
        std.debug.print("pdfinfo: cannot open {s}: {s}\n", .{ args[1], @errorName(err) });
        return 1;
    };
    defer file.close(io);
    var buf: [65536]u8 = undefined;
    var reader = file.reader(io, &buf);
    var doc = pdf.Document.openReader(gpa, &reader.interface, .{}) catch |err| {
        std.debug.print("pdfinfo: {s}: {s}\n", .{ args[1], @errorName(err) });
        return 1;
    };
    defer doc.deinit();

    var streams: usize = 0;
    var failed: usize = 0;
    var image_codecs: usize = 0;
    var it = doc.xref.keyIterator();
    var nums: std.ArrayList(u32) = .empty;
    defer nums.deinit(gpa);
    while (it.next()) |k| try nums.append(gpa, k.*);
    for (nums.items) |n| {
        const o = doc.getObject(n);
        if (o != .stream) continue;
        streams += 1;
        const r = doc.decodeStream(o.stream) catch {
            failed += 1;
            continue;
        };
        if (r.rest.len > 0) image_codecs += 1;
    }
    const list = try pdf.pages.PageList.build(&doc);
    std.debug.print("{s}: pages={d} objects={d} streams={d} undecodable={d} image-codec-streams={d} repaired={}\n", .{
        args[1], list.entries.len, doc.xref.count(), streams, failed, image_codecs, doc.repaired,
    });
    return 0;
}
