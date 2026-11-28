// SPDX-License-Identifier: LGPL-2.0-or-later
//! Says which features a PDF uses, as a line of words, to measure what matters:
//!     zig build && zig-out/bin/pdfsurvey FILE.pdf
//! `test/tools/survey.py` runs it over many files and adds up. It prints no
//! text, names or other content of the file. Long files are sampled: the first
//! pages and others spread over the rest.

const std = @import("std");
const pdf = @import("pdf");
const display = pdf.display;

/// Most pages of one file that are interpreted.
const first_pages = 10;
const spread_pages = 20;

const Found = std.StringArrayHashMapUnmanaged(void);

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) {
        std.debug.print("usage: pdfsurvey FILE.pdf\n", .{});
        return 2;
    }
    var found: Found = .empty;
    const a = init.arena.allocator();
    var file = try std.Io.Dir.cwd().openFile(io, args[1], .{});
    defer file.close(io);
    var buf: [65536]u8 = undefined;
    var reader = file.reader(io, &buf);
    var out_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &out_buf);
    const w = &stdout.interface;

    if (pdf.Document.openReader(gpa, &reader.interface, .{})) |opened| {
        var doc = opened;
        defer doc.deinit();
        try found.put(a, "opens", {});
        survey(gpa, a, &doc, &found) catch |err| try found.put(a, try std.fmt.allocPrint(a, "survey-error:{t}", .{err}), {});
    } else |err| try found.put(a, try std.fmt.allocPrint(a, "open-error:{t}", .{err}), {});

    for (found.keys()) |key| try w.print("{s} ", .{key});
    try w.writeByte('\n');
    try w.flush();
    return 0;
}

fn survey(gpa: std.mem.Allocator, a: std.mem.Allocator, doc: *pdf.Document, found: *Found) !void {
    if (doc.crypt != null) try found.put(a, "encrypted", {});
    const list = try pdf.pages.PageList.build(doc);
    try forms(a, doc, list, found);
    try signatures(a, doc, list, found);
    if (doc.catalog()) |catalog| {
        for ([_]struct { []const u8, []const u8 }{
            .{ "Outlines", "bookmarks" },
            .{ "OCProperties", "layers" },
            .{ "PageLabels", "page-labels" },
            .{ "StructTreeRoot", "tagged" },
            .{ "Metadata", "xmp-metadata" },
        }) |entry| if (doc.get(catalog, entry[0]) != null) try found.put(a, entry[1], {});
        if (doc.getDict(catalog, "Names")) |names| if (doc.get(names, "EmbeddedFiles") != null) try found.put(a, "attachments", {});
    }

    var renderer = pdf.Renderer.init(doc, .{});
    defer renderer.deinit();
    const count = list.entries.len;
    var chosen: usize = 0;
    var index: usize = 0;
    while (index < count and chosen < first_pages + spread_pages) : (chosen += 1) {
        const page = pdf.pages.page(doc, list, index).?;
        if (page.user_unit != 1) try found.put(a, "user-unit", {});
        if (renderer.render(gpa, page)) |rendered| {
            var dl = rendered;
            defer dl.deinit();
            try onPage(a, &dl, found);
        } else |err| try found.put(a, try std.fmt.allocPrint(a, "page-error:{t}", .{err}), {});
        var links_arena = std.heap.ArenaAllocator.init(gpa);
        defer links_arena.deinit();
        if ((try pdf.link.list(links_arena.allocator(), doc, list, page)).len > 0) try found.put(a, "links", {});
        index += if (chosen + 1 < first_pages) 1 else @max(1, (count -| first_pages) / spread_pages);
    }
    if (doc.repaired) try found.put(a, "repaired", {});
}

fn forms(a: std.mem.Allocator, doc: *pdf.Document, list: pdf.pages.PageList, found: *Found) !void {
    const catalog = doc.catalog() orelse return;
    const form = doc.getDict(catalog, "AcroForm") orelse return;
    if (doc.get(form, "XFA") != null) try found.put(a, "xfa", {});
    if (doc.get(form, "NeedAppearances")) |v| if (v == .boolean and v.boolean) try found.put(a, "need-appearances", {});
    var arena = std.heap.ArenaAllocator.init(doc.arena.child_allocator);
    defer arena.deinit();
    for (try pdf.form.fields(arena.allocator(), doc, list)) |field| {
        try found.put(a, "form", {});
        const kind = try std.fmt.allocPrint(a, "field:{t}", .{field.kind});
        try found.put(a, kind, {});
    }
}

/// Signatures: their formats, and what the coverage rules make of real ones.
fn signatures(a: std.mem.Allocator, doc: *pdf.Document, list: pdf.pages.PageList, found: *Found) !void {
    var arena = std.heap.ArenaAllocator.init(doc.arena.child_allocator);
    defer arena.deinit();
    for (try pdf.signature.list(arena.allocator(), doc, list, .{})) |s| {
        try found.put(a, "signed", {});
        try found.put(a, try std.fmt.allocPrint(a, "signature-kind:{t}", .{s.kind}), {});
        if (s.sub_filter) |sub| {
            for ([_][]const u8{ "adbe.pkcs7.detached", "adbe.pkcs7.sha1", "adbe.x509.rsa_sha1", "ETSI.CAdES.detached", "ETSI.RFC3161" }) |known| {
                if (std.mem.eql(u8, sub, known)) try found.put(a, try std.fmt.allocPrint(a, "signature:{s}", .{known}), {});
            }
        }
        switch (s.coverage) {
            .sound => try found.put(a, try std.fmt.allocPrint(a, "signature-coverage:sound-after-{t}", .{s.after}), {}),
            .unsound => |defect| try found.put(a, try std.fmt.allocPrint(a, "signature-coverage:{t}", .{defect}), {}),
        }
        // How the value is encoded, which a verifier will have to read.
        if (s.value.len >= 2) try found.put(a, if (s.value[0] == 0x30 and s.value[1] == 0x80) "signature-value:indefinite-length" else if (s.value[0] == 0x30) "signature-value:definite-length" else "signature-value:other", {});
    }
}

fn onPage(a: std.mem.Allocator, dl: *const display.DisplayList, found: *Found) !void {
    inline for (@typeInfo(display.Omissions).@"struct".field_names) |name| {
        if (name[0] != '_') {
            if (@field(dl.omissions, name)) try found.put(a, "omits:" ++ name, {});
        }
    }
    var visible = false;
    var invisible = false;
    var covered = false;
    for (dl.commands) |command| switch (command) {
        .text => |t| if (t.glyphs.len > 2) {
            if (t.mode == 3 or t.mode == 7) invisible = true else visible = true;
        },
        .image => |image| {
            const filter = image.stream.dict.get("Filter");
            const last: ?pdf.Object = if (filter) |f| switch (f) {
                .array => |arr| if (arr.len > 0) arr[arr.len - 1] else null,
                else => f,
            } else null;
            const name = if (last) |l| l.asName() orelse "" else "";
            for ([_]struct { []const u8, []const u8 }{
                .{ "DCTDecode", "image:jpeg" },
                .{ "JPXDecode", "image:jpx" },
                .{ "JBIG2Decode", "image:jbig2" },
                .{ "CCITTFaxDecode", "image:ccitt" },
            }) |codec| if (std.mem.eql(u8, name, codec[0])) try found.put(a, codec[1], {});
            // The area the image's unit square covers on the page.
            const m = image.ctm.mul(dl.base);
            if (@abs(m.a * m.d - m.b * m.c) > 0.8 * dl.width * dl.height) covered = true;
        },
        else => {},
    };
    // A page that is one big picture, with or without recognised text under it.
    if (covered and !visible) try found.put(a, if (invisible) "scan-page-with-text" else "scan-page", {});
}
