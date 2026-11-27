// SPDX-License-Identifier: LGPL-2.0-or-later
//! Puts a watermark across every page, and numbers the pages:
//!     zig build && zig-out/bin/pdfstamp IN.pdf OUT.pdf TEXT [--under]
//! With `--under` the watermark goes behind what the page shows (a page that
//! paints its whole area, as a scan does, hides it). The numbers go on top.

const std = @import("std");
const pdf = @import("pdf");
const draw = pdf.draw;

/// A grey line from the lower left to the upper right, across a page of `w` by
/// `h` points.
fn watermark(c: *draw.Canvas, line: []const u8, w: f64, h: f64) !void {
    const font: draw.Font = .helvetica_bold;
    const diagonal = std.math.hypot(w, h);
    const natural = try font.textWidth(1, line);
    if (!(natural > 0)) return;
    const size = @min(diagonal * 0.7 / natural, @min(w, h) / 3);
    const angle = -std.math.atan2(h, w);
    // Turned about the middle of the page.
    const cos = @cos(angle);
    const sin = @sin(angle);
    try c.transform(.{ .a = cos, .b = sin, .c = -sin, .d = cos, .e = w / 2, .f = h / 2 });
    try c.setAlpha(0.25, 0.25);
    try c.setFill(.{ .gray = 0.3 });
    try c.text(font, size, -natural * size / 2, size * 0.35, line);
}

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const under = args.len == 5 and std.mem.eql(u8, args[4], "--under");
    if (args.len != 4 and !under) {
        std.debug.print("usage: pdfstamp IN.pdf OUT.pdf TEXT [--under]\n", .{});
        return 2;
    }
    if (!(draw.Font.helvetica_bold).covers(args[3])) {
        std.debug.print("pdfstamp: the built-in fonts cannot write all of \"{s}\"\n", .{args[3]});
        return 2;
    }
    var in_file = try std.Io.Dir.cwd().openFile(io, args[1], .{});
    defer in_file.close(io);
    var buf: [65536]u8 = undefined;
    var reader = in_file.reader(io, &buf);
    var doc = pdf.Document.openReader(gpa, &reader.interface, .{}) catch |err| {
        std.debug.print("pdfstamp: {s}: {t}\n", .{ args[1], err });
        return 1;
    };
    defer doc.deinit();
    const list = try pdf.pages.PageList.build(&doc);
    var upd = pdf.write.Update.init(gpa, &doc) catch |err| {
        std.debug.print("pdfstamp: {s}: cannot be changed ({t})\n", .{ args[1], err });
        return 1;
    };
    defer upd.deinit();
    var stamp: draw.Stamp = .init(&upd);
    for (0..list.entries.len) |i| {
        const page = pdf.pages.page(&doc, list, i).?;
        const size = page.displaySize();
        var mark = draw.Canvas.init(gpa, size.w, size.h) catch continue;
        defer mark.deinit();
        try watermark(&mark, args[3], size.w, size.h);
        var number = try draw.Canvas.init(gpa, size.w, size.h);
        defer number.deinit();
        var label: [64]u8 = undefined;
        const text = try std.fmt.bufPrint(&label, "{d} / {d}", .{ i + 1, list.entries.len });
        const width = try (draw.Font.helvetica).textWidth(9, text);
        try number.text(.helvetica, 9, (size.w - width) / 2, size.h - 12, text);
        for ([_]struct { *const draw.Canvas, draw.Layer }{ .{ &mark, if (under) .under else .over }, .{ &number, .over } }) |item| {
            stamp.place(page, item[0], item[1]) catch |err| {
                std.debug.print("pdfstamp: page {d}: {t}\n", .{ i + 1, err });
                return 1;
            };
        }
    }
    try stamp.finish();

    // Written beside the target and then renamed over it, so that a failure
    // leaves what was there, the input included if it is the target.
    var out_file = try std.Io.Dir.cwd().createFileAtomic(io, args[2], .{ .replace = true });
    defer out_file.deinit(io);
    var wbuf: [65536]u8 = undefined;
    var writer = out_file.file.writer(io, &wbuf);
    upd.write(gpa, &writer.interface) catch |err| {
        std.debug.print("pdfstamp: {t}\n", .{err});
        return 1;
    };
    try writer.interface.flush();
    try out_file.replace(io);
    return 0;
}
