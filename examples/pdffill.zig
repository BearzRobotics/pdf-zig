//! Lists the form fields of a PDF, or fills them:
//!     pdffill IN.pdf                       list the fields
//!     pdffill IN.pdf OUT.pdf name=value…   fill text fields; for a check box "on" or "off",
//!                                          for a radio group the number of the button (0, 1, …)

const std = @import("std");
const pdf = @import("pdf");

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) {
        std.debug.print("usage: pdffill IN.pdf [OUT.pdf name=value...]\n", .{});
        return 2;
    }
    var in_file = try std.Io.Dir.cwd().openFile(io, args[1], .{});
    defer in_file.close(io);
    var buf: [65536]u8 = undefined;
    var reader = in_file.reader(io, &buf);
    var doc = try pdf.Document.openReader(gpa, &reader.interface, .{});
    defer doc.deinit();
    const list = try pdf.pages.PageList.build(&doc);
    const all = try pdf.form.fields(arena, &doc, list);

    if (args.len < 4) {
        for (all) |f| std.debug.print("{s}\t{s}\t\"{s}\"\t{d} widget(s)\n", .{ f.name, @tagName(f.kind), f.value, f.widgets.len });
        return 0;
    }
    var upd = try pdf.write.Update.init(gpa, &doc);
    defer upd.deinit();
    for (args[3..]) |assign| {
        const eq = std.mem.indexOfScalar(u8, assign, '=') orelse continue;
        const name = assign[0..eq];
        const value = assign[eq + 1 ..];
        var field: ?pdf.form.Field = null;
        for (all) |f| if (std.mem.eql(u8, f.name, name)) {
            field = f;
        };
        const f = field orelse {
            std.debug.print("pdffill: no field \"{s}\"\n", .{name});
            return 1;
        };
        switch (f.kind) {
            .text, .combo => try pdf.form.setText(&upd, f, value),
            .list => try pdf.form.setChoice(&upd, f, value),
            .checkbox => try pdf.form.setChecked(&upd, f, 0, std.mem.eql(u8, value, "on")),
            .radio => try pdf.form.setChecked(&upd, f, try std.fmt.parseInt(usize, value, 10), true),
            else => {
                std.debug.print("pdffill: cannot fill a {s} field\n", .{@tagName(f.kind)});
                return 1;
            },
        }
    }
    var out_file = try std.Io.Dir.cwd().createFile(io, args[2], .{});
    defer out_file.close(io);
    var wbuf: [65536]u8 = undefined;
    var writer = out_file.writer(io, &wbuf);
    try upd.write(gpa, &writer.interface);
    try writer.interface.flush();
    return 0;
}
