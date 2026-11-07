//! Decodes the images of a page and writes one as a PPM (alpha over white):
//!
//!     pdfimg FILE PAGE            lists the images of the page
//!     pdfimg FILE PAGE N OUT.ppm  writes image N (from 1)

const std = @import("std");
const pdf = @import("pdf");

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 3) {
        std.debug.print("usage: pdfimg FILE PAGE [N OUT.ppm]\n", .{});
        return 2;
    }
    const page_no = try std.fmt.parseInt(usize, args[2], 10);
    var file = try std.Io.Dir.cwd().openFile(io, args[1], .{});
    defer file.close(io);
    var buf: [65536]u8 = undefined;
    var reader = file.reader(io, &buf);
    var doc = try pdf.Document.openReader(gpa, &reader.interface, .{});
    defer doc.deinit();
    const list = try pdf.pages.PageList.build(&doc);
    const page = pdf.pages.page(&doc, list, page_no - 1) orelse return 1;
    var rend = pdf.Renderer.init(&doc, .{});
    defer rend.deinit();
    var dl = try rend.render(gpa, page);
    defer dl.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const want: ?usize = if (args.len > 3) try std.fmt.parseInt(usize, args[3], 10) else null;
    var n: usize = 0;
    for (dl.commands) |c| {
        if (c != .image) continue;
        n += 1;
        const res = pdf.image.decode(&doc, arena.allocator(), c.image) catch |err| {
            std.debug.print("image {d}: {d}x{d} error {s}\n", .{ n, c.image.width, c.image.height, @errorName(err) });
            continue;
        };
        switch (res) {
            .codec => |k| std.debug.print("image {d}: {d}x{d} needs {s} ({d} bytes)\n", .{ n, c.image.width, c.image.height, k.name, k.data.len }),
            .pixels => |p| {
                std.debug.print("image {d}: {d}x{d} decoded{s}\n", .{ n, p.width, p.height, if (c.image.is_mask) " (mask)" else "" });
                if (want == n and args.len > 4) {
                    var out = try std.Io.Dir.cwd().createFile(io, args[4], .{});
                    defer out.close(io);
                    var obuf: [65536]u8 = undefined;
                    var w = out.writer(io, &obuf);
                    try w.interface.print("P6\n{d} {d}\n255\n", .{ p.width, p.height });
                    var i: usize = 0;
                    while (i < p.rgba.len) : (i += 4) {
                        const al: u32 = p.rgba[i + 3];
                        for (0..3) |k| try w.interface.writeByte(@intCast((@as(u32, p.rgba[i + k]) * al + 255 * (255 - al)) / 255));
                    }
                    try w.interface.flush();
                }
            },
        }
        _ = arena.reset(.retain_capacity);
    }
    return 0;
}
