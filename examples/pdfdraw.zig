// SPDX-License-Identifier: LGPL-2.0-or-later
//! Makes a sample document with the drawing functions:
//!     zig build && zig-out/bin/pdfdraw OUT.pdf [PICTURE.jpg]
//! Used to check the output against other PDF readers.

const std = @import("std");
const pdf = @import("pdf");
const draw = pdf.draw;

fn sample(c: *draw.Canvas, picture: ?*const draw.Image) !void {
    try c.setFill(.{ .rgb = .{ 0.88, 0.92, 0.98 } });
    try c.rect(36, 36, 523, 48);
    try c.fill(.nonzero);
    try c.setFill(.black);
    try c.text(.helvetica_bold, 22, 48, 68, "Quarterly report");

    var y: f64 = 120;
    for (std.enums.values(draw.Builtin)) |builtin| {
        const font: draw.Font = .{ .builtin = builtin };
        var line: [128]u8 = undefined;
        try c.text(font, 12, 48, y, try std.fmt.bufPrint(&line, "{s}: Caf\u{e9} \u{20ac}9 \u{201c}quoted\u{201d} (x\\y)", .{builtin.baseFont()}));
        y += 18;
    }
    // A line as long as it measures, with a rule drawn to the same width.
    const measured = "This rule is as wide as the text above it.";
    try c.text(.times_roman, 14, 48, 360, measured);
    try c.setStroke(.{ .rgb = .{ 0.8, 0, 0 } });
    try c.setLineWidth(1);
    try c.moveTo(48, 364);
    try c.lineTo(48 + try (draw.Font.times_roman).textWidth(14, measured), 364);
    try c.stroke();
    try c.textWith(.courier, 12, 48, 388, "stretched to 300 points", .{ .fit_width = 300 });
    try c.textWith(.helvetica, 12, 48, 410, "invisible searchable text", .{ .mode = .invisible });

    try c.setDash(&.{ 6, 3 }, 0);
    try c.moveTo(48, 450);
    try c.curveTo(150, 420, 250, 500, 360, 450);
    try c.stroke();
    try c.setDash(&.{}, 0);

    // Overlapping, half opaque.
    try c.save();
    try c.setAlpha(0.5, 1);
    for ([_][3]f64{ .{ 1, 0, 0 }, .{ 0, 0.7, 0 }, .{ 0, 0, 1 } }, 0..) |rgb, i| {
        try c.setFill(.{ .rgb = rgb });
        try c.rect(400 + 36 * @as(f64, @floatFromInt(i)), 420 + 20 * @as(f64, @floatFromInt(i)), 70, 60);
        try c.fill(.nonzero);
    }
    try c.restore();

    // Turned a quarter, reading downwards.
    try c.save();
    try c.transform(.{ .a = 0, .b = 1, .c = -1, .d = 0, .e = 540 + 120, .f = 120 - 540 });
    try c.text(.helvetica, 12, 540, 120, "Turned text reads down");
    try c.restore();

    if (picture) |image| {
        const w: f64 = 200;
        const h = w * @as(f64, @floatFromInt(image.height)) / @as(f64, @floatFromInt(image.width));
        try c.image(image, 48, 500, w, h);
        try c.text(.helvetica, 10, 48, 500 + h + 12, "A JPEG, stored as it is");
    }
    // A gradient made of raw pixels, fading out downwards.
    var samples: [64 * 64 * 3]u8 = undefined;
    var alpha: [64 * 64]u8 = undefined;
    for (0..64) |row| for (0..64) |col| {
        samples[(row * 64 + col) * 3 ..][0..3].* = .{ @intCast(col * 4), 80, @intCast(255 - col * 4) };
        alpha[row * 64 + col] = @intCast(255 - row * 4);
    };
    var gradient = try draw.Image.fromPixels(c.gpa, .{ .width = 64, .height = 64, .format = .rgb, .samples = &samples, .alpha = &alpha });
    defer gradient.deinit();
    try c.image(&gradient, 300, 500, 200, 120);
}

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2 or args.len > 3) {
        std.debug.print("usage: pdfdraw OUT.pdf [PICTURE.jpg]\n", .{});
        return 2;
    }
    var picture: ?draw.Image = null;
    defer if (picture) |*p| p.deinit();
    if (args.len == 3) {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, args[2], gpa, .limited(64 << 20));
        defer gpa.free(bytes);
        picture = draw.Image.fromJpeg(gpa, bytes) catch |err| {
            std.debug.print("pdfdraw: {s}: {t}\n", .{ args[2], err });
            return 1;
        };
    }
    var canvas = try draw.Canvas.init(gpa, 595, 842);
    defer canvas.deinit();
    try sample(&canvas, if (picture) |*p| p else null);

    var builder = pdf.compose.Builder.init(gpa, .{});
    defer builder.deinit();
    try builder.addPage(&canvas);
    try builder.setInfo(.{ .title = "pdf-zig drawing sample", .creator = "pdfdraw" });

    // Written beside the target and then renamed over it, so that a failure
    // leaves what was there.
    var out_file = try std.Io.Dir.cwd().createFileAtomic(io, args[1], .{ .replace = true });
    defer out_file.deinit(io);
    var buf: [65536]u8 = undefined;
    var writer = out_file.file.writer(io, &buf);
    try builder.write(&writer.interface);
    try writer.interface.flush();
    try out_file.replace(io);
    return 0;
}
