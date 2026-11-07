//! Highlights the first match of a word on page 1 and puts a note next to it:
//!     zig build && zig-out/bin/pdfmark IN.pdf OUT.pdf WORD
//! Used to check the output against other PDF readers.

const std = @import("std");
const pdf = @import("pdf");

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 4) {
        std.debug.print("usage: pdfmark IN.pdf OUT.pdf WORD\n", .{});
        return 2;
    }
    var in_file = try std.Io.Dir.cwd().openFile(io, args[1], .{});
    defer in_file.close(io);
    var buf: [65536]u8 = undefined;
    var reader = in_file.reader(io, &buf);
    var doc = try pdf.Document.openReader(gpa, &reader.interface, .{});
    defer doc.deinit();

    const list = try pdf.pages.PageList.build(&doc);
    const page = pdf.pages.page(&doc, list, 0) orelse return 1;
    var rend = pdf.Renderer.init(&doc, .{ .graphics = false });
    defer rend.deinit();
    var dl = try rend.render(gpa, page);
    defer dl.deinit();
    var lay = try pdf.text.layout(gpa, &dl);
    defer lay.deinit(gpa);

    var found: std.ArrayList([2]u32) = .empty;
    defer found.deinit(gpa);
    try lay.find(gpa, args[3], &found);
    if (found.items.len == 0) {
        std.debug.print("pdfmark: \"{s}\" not found on page 1\n", .{args[3]});
        return 1;
    }
    var rects: std.ArrayList(pdf.text.Rect) = .empty;
    defer rects.deinit(gpa);
    try lay.rectsFor(gpa, found.items[0][0], found.items[0][1], &rects);

    var upd = try pdf.write.Update.init(gpa, &doc);
    defer upd.deinit();
    _ = try pdf.annot.addMarkup(&upd, page, .highlight, rects.items, .{ .contents = "marked by pdfmark", .author = "pdf-zig", .color = .{ 1, 0.9, 0 } });
    _ = try pdf.annot.addNote(&upd, page, rects.items[0].x1 + 4, rects.items[0].y0, .{ .contents = "a note", .author = "pdf-zig" });

    var out_file = try std.Io.Dir.cwd().createFile(io, args[2], .{});
    defer out_file.close(io);
    var wbuf: [65536]u8 = undefined;
    var writer = out_file.writer(io, &wbuf);
    try upd.write(gpa, &writer.interface);
    try writer.interface.flush();
    return 0;
}
