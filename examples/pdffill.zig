// SPDX-License-Identifier: LGPL-2.0-or-later
//! Lists the form fields of a PDF, or fills them:
//!     pdffill IN.pdf                       list the fields
//!     pdffill IN.pdf OUT.pdf name=value…   fill text fields; for a choice an option's value
//!                                          or text, for a check box "on" or "off", for a
//!                                          radio group the number of the button (0, 1, …)
//!     pdffill IN.pdf OUT.pdf --flatten     make the fields part of the pages (after any
//!                                          filling given before it)

const std = @import("std");
const pdf = @import("pdf");

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    // Checked before anything is read: a mistake must not produce a file.
    var well_formed = args.len == 2 or args.len >= 4;
    for (args[@min(3, args.len)..]) |assign| {
        if (std.mem.indexOfScalar(u8, assign, '=') == null and !std.mem.eql(u8, assign, "--flatten")) well_formed = false;
    }
    if (!well_formed) {
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
    var flatten = false;
    for (args[3..]) |assign| {
        if (std.mem.eql(u8, assign, "--flatten")) {
            flatten = true;
            continue;
        }
        const eq = std.mem.indexOfScalar(u8, assign, '=').?;
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
            .checkbox => {
                const on = std.mem.eql(u8, value, "on");
                if (!on and !std.mem.eql(u8, value, "off")) {
                    std.debug.print("pdffill: a check box takes \"on\" or \"off\", not \"{s}\"\n", .{value});
                    return 2;
                }
                try pdf.form.setChecked(&upd, f, 0, on);
            },
            .radio => try pdf.form.setChecked(&upd, f, try std.fmt.parseInt(usize, value, 10), true),
            else => {
                std.debug.print("pdffill: cannot fill a {s} field\n", .{@tagName(f.kind)});
                return 1;
            },
        }
    }
    if (flatten) {
        var total: pdf.flatten.Result = .{};
        for (0..list.entries.len) |i| {
            const result = try pdf.flatten.widgets(&upd, pdf.pages.page(&doc, list, i).?);
            total.flattened += result.flattened;
            total.kept += result.kept;
        }
        std.debug.print("pdffill: flattened {d} widget(s), left {d}\n", .{ total.flattened, total.kept });
    }
    // Written beside the target and then renamed over it, so that a failure
    // leaves what was there, the input included if it is the target.
    var out_file = try std.Io.Dir.cwd().createFileAtomic(io, args[2], .{ .replace = true });
    defer out_file.deinit(io);
    var wbuf: [65536]u8 = undefined;
    var writer = out_file.file.writer(io, &wbuf);
    try upd.write(gpa, &writer.interface);
    try writer.interface.flush();
    try out_file.replace(io);
    return 0;
}
