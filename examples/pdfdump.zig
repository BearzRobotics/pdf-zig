//! Prints the display list of a page:  zig build && zig-out/bin/pdfdump FILE.pdf [PAGE]

const std = @import("std");
const pdf = @import("pdf");

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) {
        std.debug.print("usage: pdfdump FILE [PAGE]\n", .{});
        return 2;
    }
    const page_no = if (args.len > 2) (std.fmt.parseInt(usize, args[2], 10) catch 1) else 1;
    var file = try std.Io.Dir.cwd().openFile(io, args[1], .{});
    defer file.close(io);
    var buf: [65536]u8 = undefined;
    var reader = file.reader(io, &buf);
    var doc = try pdf.Document.openReader(gpa, &reader.interface, .{});
    defer doc.deinit();
    const list = try pdf.pages.PageList.build(&doc);
    const page = pdf.pages.page(&doc, list, page_no - 1) orelse {
        std.debug.print("pdfdump: no page {d} (the file has {d})\n", .{ page_no, list.entries.len });
        return 1;
    };
    var rend = pdf.Renderer.init(&doc, .{});
    defer rend.deinit();
    var dl = try rend.render(gpa, page);
    defer dl.deinit();
    std.debug.print("page {d}: {d:.0} x {d:.0} pt, rotate {d}, {d} commands\n", .{ page_no, dl.width, dl.height, page.rotate, dl.commands.len });
    for (dl.commands) |c| switch (c) {
        .save => std.debug.print("save\n", .{}),
        .restore => std.debug.print("restore\n", .{}),
        .clip => |x| std.debug.print("clip {d} segs\n", .{x.path.len}),
        .fill => |x| std.debug.print("fill {d} segs {s}\n", .{ x.path.len, @tagName(x.paint) }),
        .stroke => |x| std.debug.print("stroke {d} segs width {d:.2}\n", .{ x.path.len, x.style.width }),
        .shading => std.debug.print("shading\n", .{}),
        .image => |x| std.debug.print("image {d}x{d}{s}\n", .{ x.width, x.height, if (x.is_mask) " mask" else "" }),
        .text => |x| {
            std.debug.print("text font={s} size={d:.1} mode={d} glyphs={d}:", .{ x.font.base_font, x.size, x.mode, x.glyphs.len });
            for (x.glyphs[0..@min(x.glyphs.len, 24)]) |g| {
                if (g.text.len > 0) std.debug.print(" {s}", .{g.text}) else std.debug.print(" <{x}>", .{g.code});
            }
            std.debug.print("\n", .{});
        },
    };
    return 0;
}
