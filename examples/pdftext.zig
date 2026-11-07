//! Prints the text of a PDF:  zig build && zig-out/bin/pdftext [-raw] FILE.pdf [PAGE]

const std = @import("std");
const pdf = @import("pdf");

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var raw = false;
    var path: ?[]const u8 = null;
    var only: ?usize = null;
    for (args[1..]) |a| {
        if (std.mem.eql(u8, a, "-raw")) {
            raw = true;
        } else if (path == null) {
            path = a;
        } else only = std.fmt.parseInt(usize, a, 10) catch null;
    }
    const file_path = path orelse {
        std.debug.print("usage: pdftext [-raw] FILE [PAGE]\n", .{});
        return 2;
    };
    var file = try std.Io.Dir.cwd().openFile(io, file_path, .{});
    defer file.close(io);
    var buf: [65536]u8 = undefined;
    var reader = file.reader(io, &buf);
    var doc = pdf.Document.openReader(gpa, &reader.interface, .{}) catch |err| {
        std.debug.print("pdftext: {s}: {s}\n", .{ file_path, @errorName(err) });
        return 1;
    };
    defer doc.deinit();
    const list = try pdf.pages.PageList.build(&doc);
    var rend = pdf.Renderer.init(&doc, .{});
    defer rend.deinit();

    var out_buf: [65536]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &out_buf);
    const w = &stdout.interface;
    var n: usize = 0;
    while (n < list.entries.len) : (n += 1) {
        if (only) |o| if (o != n + 1) continue;
        const page = pdf.pages.page(&doc, list, n) orelse continue;
        var dl = rend.render(gpa, page) catch |err| {
            std.debug.print("pdftext: page {d}: {s}\n", .{ n + 1, @errorName(err) });
            continue;
        };
        defer dl.deinit();
        const text = try pdf.text.extract(gpa, &dl, if (raw) .content else .reading);
        defer gpa.free(text);
        try w.writeAll(text);
        try w.writeAll("\x0c");
    }
    try w.flush();
    return 0;
}
