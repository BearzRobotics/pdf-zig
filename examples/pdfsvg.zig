//! Draws a page's display list as SVG (a way to look at the output):
//!
//!     zig build && zig-out/bin/pdfsvg FILE.pdf PAGE > page.svg
//!
//! Text is set in a generic font at the right positions; images are grey boxes.

const std = @import("std");
const pdf = @import("pdf");
const display = pdf.display;

fn m(w: *std.Io.Writer, mat: display.Matrix) !void {
    try w.print("matrix({d:.6} {d:.6} {d:.6} {d:.6} {d:.6} {d:.6})", .{ mat.a, mat.b, mat.c, mat.d, mat.e, mat.f });
}

fn pathData(w: *std.Io.Writer, p: display.Path) !void {
    for (p) |s| switch (s) {
        .move => |q| try w.print("M{d:.4} {d:.4} ", .{ q.x, q.y }),
        .line => |q| try w.print("L{d:.4} {d:.4} ", .{ q.x, q.y }),
        .curve => |c| try w.print("C{d:.4} {d:.4} {d:.4} {d:.4} {d:.4} {d:.4} ", .{ c.c1.x, c.c1.y, c.c2.x, c.c2.y, c.p.x, c.p.y }),
        .close => try w.writeAll("Z "),
    };
}

fn rgb(w: *std.Io.Writer, p: display.Paint) !void {
    switch (p) {
        .color => |c| try w.print("rgb({d},{d},{d})", .{ @as(u32, @intFromFloat(c.r * 255)), @as(u32, @intFromFloat(c.g * 255)), @as(u32, @intFromFloat(c.b * 255)) }),
        .shading => try w.writeAll("#8899cc"),
        .tiling => try w.writeAll("#cc9988"),
        .none => try w.writeAll("none"),
    }
}

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 3) {
        std.debug.print("usage: pdfsvg FILE PAGE > page.svg\n", .{});
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

    var out_buf: [65536]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &out_buf);
    const w = &stdout.interface;
    try w.print("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"{d:.2}\" height=\"{d:.2}\" viewBox=\"0 0 {d:.2} {d:.2}\">\n", .{ dl.width, dl.height, dl.width, dl.height });
    try w.print("<rect width=\"{d:.2}\" height=\"{d:.2}\" fill=\"white\"/>\n<g transform=\"", .{ dl.width, dl.height });
    try m(w, dl.base);
    try w.writeAll("\">\n");

    var levels: std.ArrayList(u32) = .empty; // groups opened per save level
    defer levels.deinit(gpa);
    var extra: u32 = 0; // groups opened by clips at the top level
    var clip_id: u32 = 0;
    for (dl.commands) |c| switch (c) {
        .save => {
            try levels.append(gpa, extra);
            extra = 0;
        },
        .restore => {
            var k: u32 = 0;
            while (k < extra) : (k += 1) try w.writeAll("</g>");
            extra = levels.pop() orelse 0;
        },
        .clip => |x| {
            clip_id += 1;
            try w.print("<clipPath id=\"c{d}\"><path clip-rule=\"{s}\" transform=\"", .{ clip_id, if (x.rule == .even_odd) "evenodd" else "nonzero" });
            try m(w, x.ctm);
            try w.writeAll("\" d=\"");
            try pathData(w, x.path);
            try w.print("\"/></clipPath><g clip-path=\"url(#c{d})\">", .{clip_id});
            extra += 1;
        },
        .fill => |x| {
            try w.print("<path fill-rule=\"{s}\" fill-opacity=\"{d:.3}\" fill=\"", .{ if (x.rule == .even_odd) "evenodd" else "nonzero", x.alpha });
            try rgb(w, x.paint);
            try w.writeAll("\" transform=\"");
            try m(w, x.ctm);
            try w.writeAll("\" d=\"");
            try pathData(w, x.path);
            try w.writeAll("\"/>\n");
        },
        .stroke => |x| {
            try w.print("<path fill=\"none\" stroke-width=\"{d:.4}\" stroke-opacity=\"{d:.3}\" stroke=\"", .{ x.style.width, x.alpha });
            try rgb(w, x.paint);
            try w.writeAll("\" transform=\"");
            try m(w, x.ctm);
            try w.writeAll("\" d=\"");
            try pathData(w, x.path);
            try w.writeAll("\"/>\n");
        },
        .image => |x| {
            try w.writeAll("<rect width=\"1\" height=\"1\" fill=\"#bbb\" fill-opacity=\"0.6\" transform=\"");
            try m(w, x.ctm);
            try w.writeAll("\"/>\n");
        },
        .shading => {},
        .text => |t| {
            if (t.mode == 3 or t.mode == 7) continue;
            for (t.glyphs) |g| {
                if (g.text.len == 0 or g.text[0] == ' ') continue;
                const glyph_m = display.Matrix.translate(g.x, 0).mul(.{ .a = t.size * t.h_scale, .d = t.size, .f = t.rise }).mul(t.tm).mul(t.ctm);
                try w.writeAll("<text font-family=\"DejaVu Sans, sans-serif\" font-size=\"1\" fill=\"");
                try rgb(w, t.fill);
                try w.writeAll("\" transform=\"");
                try m(w, glyph_m);
                try w.writeAll(" scale(1,-1)\">");
                for (g.text) |ch| switch (ch) {
                    '<' => try w.writeAll("&lt;"),
                    '>' => try w.writeAll("&gt;"),
                    '&' => try w.writeAll("&amp;"),
                    else => try w.writeByte(ch),
                };
                try w.writeAll("</text>\n");
            }
        },
    };
    while (extra > 0) : (extra -= 1) try w.writeAll("</g>");
    while (levels.pop()) |k| {
        var j: u32 = 0;
        while (j < k) : (j += 1) try w.writeAll("</g>");
    }
    try w.writeAll("</g>\n</svg>\n");
    try w.flush();
    return 0;
}
