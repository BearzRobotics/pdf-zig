// SPDX-License-Identifier: LGPL-2.0-or-later
//! Listing signatures: claims, coverage and later changes. The attack cases
//! follow the structures described at pdf-insecurity.org and in the CCS 2019
//! paper on spoofing PDF signatures.
//!
//! The signature values are stand-ins: nothing here is verified.

const std = @import("std");
const pdf = @import("root.zig");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const signature = pdf.signature;
const buildFile = @import("interp_tests.zig").buildFile;

/// Ten digits each, so that filling them in moves nothing.
const holder = "[0 AAAAAAAAAA BBBBBBBBBB CCCCCCCCCC]";
const value_hex = "<3003020101000000000000000000000000000000>";

fn dictText(comptime extra: []const u8) []const u8 {
    return "<< /Type /Sig /Filter /Adobe.PPKLite /SubFilter /adbe.pkcs7.detached /ByteRange " ++
        holder ++ " /Contents " ++ value_hex ++ extra ++ " >>";
}

const catalog = "<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [4 0 R] /SigFlags 3 >> >>";
const tree = "<< /Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 200 200] >>";
const page = "<< /Type /Page /Parent 2 0 R /Annots [4 0 R] >>";
const widget = "<< /Type /Annot /Subtype /Widget /FT /Sig /T (signed) /Rect [0 0 0 0] /V 5 0 R >>";

/// Fills in the byte range of the dictionary at the first placeholder, so that
/// it leaves out the `/Contents` value that follows it and covers the whole of
/// `bytes`.
fn seal(bytes: []u8) void {
    const at = std.mem.indexOf(u8, bytes, holder).?;
    const open = std.mem.indexOfPos(u8, bytes, at, "/Contents <").? + "/Contents ".len;
    const close = std.mem.indexOfScalarPos(u8, bytes, open, '>').? + 1;
    var text: [holder.len]u8 = undefined;
    _ = std.fmt.bufPrint(&text, "[0 {d:0>10} {d:0>10} {d:0>10}]", .{ open, close, bytes.len - close }) catch unreachable;
    @memcpy(bytes[at..][0..holder.len], &text);
}

fn simple(a: Allocator, dict: []const u8) ![]u8 {
    const bytes = try buildFile(a, &.{ catalog, tree, page, widget, dict });
    seal(bytes);
    return bytes;
}

const New = struct { num: u32, body: []const u8 };

fn lastStartxref(bytes: []const u8) usize {
    const at = std.mem.lastIndexOf(u8, bytes, "startxref\n").? + "startxref\n".len;
    const end = std.mem.indexOfScalarPos(u8, bytes, at, '\n').?;
    return std.fmt.parseInt(usize, bytes[at..end], 10) catch unreachable;
}

/// `base` with a further revision that writes `objects`.
fn update(a: Allocator, base: []const u8, objects: []const New, trailer: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, base);
    const offsets = try a.alloc(usize, objects.len);
    for (objects, offsets) |item, *offset| {
        offset.* = out.items.len;
        try out.print(a, "{d} 0 obj\n{s}\nendobj\n", .{ item.num, item.body });
    }
    const xref_at = out.items.len;
    try out.appendSlice(a, "xref\n");
    for (objects, offsets) |item, offset| try out.print(a, "{d} 1\n{d:0>10} 00000 n \n", .{ item.num, offset });
    if (objects.len == 0) try out.appendSlice(a, "0 1\n0000000000 65535 f \n");
    try out.print(a, "trailer\n<< /Size 20 {s} /Prev {d} >>\nstartxref\n{d}\n%%EOF\n", .{ trailer, lastStartxref(base), xref_at });
    return out.items;
}

fn listed(a: Allocator, bytes: []const u8) !struct { doc: *pdf.Document, found: []signature.Signature } {
    const doc = try a.create(pdf.Document);
    doc.* = try pdf.Document.open(a, bytes, .{});
    const found = try signature.list(a, doc, try pdf.pages.PageList.build(doc), .{});
    return .{ .doc = doc, .found = found };
}

fn only(a: Allocator, bytes: []const u8) !signature.Signature {
    const r = try listed(a, bytes);
    try testing.expectEqual(@as(usize, 1), r.found.len);
    return r.found[0];
}

fn expectDefect(a: Allocator, bytes: []const u8, defect: signature.Defect) !void {
    const s = try only(a, bytes);
    try testing.expectEqual(signature.Coverage{ .unsound = defect }, s.coverage);
    try testing.expectEqual(signature.After.unknown, s.after);
    try testing.expectEqual(@as(usize, 0), s.value.len);
}

test "a signature that covers the whole file, with its claims" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bytes = try simple(a, comptime dictText(" /Name (Alice) /M (D:20260101120000Z) /Reason <FEFF006F006B> /Location (Here) /ContactInfo (mail)"));
    const r = try listed(a, bytes);
    const s = r.found[0];
    try testing.expectEqual(signature.Kind.approval, s.kind);
    try testing.expectEqual(@as(u32, 4), s.field_num);
    try testing.expectEqualStrings("signed", s.field_name);
    try testing.expectEqualStrings("Alice", s.claims.name.?);
    try testing.expectEqualStrings("D:20260101120000Z", s.claims.date.?);
    try testing.expectEqualStrings("ok", s.claims.reason.?);
    try testing.expectEqualStrings("Here", s.claims.location.?);
    try testing.expectEqualStrings("mail", s.claims.contact.?);
    try testing.expectEqualStrings("Adobe.PPKLite", s.filter.?);
    try testing.expectEqualStrings("adbe.pkcs7.detached", s.sub_filter.?);
    try testing.expectEqual(bytes.len, s.coverage.sound.end);
    const range = s.coverage.sound.byte_range;
    try testing.expectEqualStrings(value_hex, bytes[range[1]..range[2]]);
    try testing.expectEqual(@as(usize, 20), s.value.len);
    try testing.expectEqualSlices(u8, &.{ 0x30, 3, 2, 1, 1 }, s.value[0..5]);
    try testing.expectEqual(signature.After.nothing, s.after);
    try testing.expectEqual(bytes.len, signature.signedRevision(r.doc, s).?.len);

    // White space after the revision changes nothing.
    const padded = try std.mem.concat(a, u8, &.{ bytes, "\r\n\n  " });
    try testing.expectEqual(signature.After.nothing, (try only(a, padded)).after);
}

test "a field without a value is not signed, and a value that is no dictionary is shown" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const unsigned = try buildFile(a, &.{ catalog, tree, page, "<< /Type /Annot /Subtype /Widget /FT /Sig /T (empty) /Rect [0 0 0 0] >>" });
    try testing.expectEqual(@as(usize, 0), (try listed(a, unsigned)).found.len);
    // As the sneaky signature attack writes one (S&P 2021).
    const broken = try buildFile(a, &.{ catalog, tree, page, widget, "(not a signature)" });
    try expectDefect(a, broken, .not_a_signature);
    const nowhere = try buildFile(a, &.{ catalog, tree, page, widget });
    try expectDefect(a, nowhere, .not_a_signature);
}

test "later revisions are reported with what they replace and add" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const signed = try simple(a, comptime dictText(""));

    // A new page object and a new annotation (incremental saving).
    const changed = try update(a, signed, &.{
        .{ .num = 3, .body = "<< /Type /Page /Parent 2 0 R /Annots [4 0 R 6 0 R] >>" },
        .{ .num = 6, .body = "<< /Type /Annot /Subtype /FreeText /Rect [0 0 100 100] /Contents (new) >>" },
    }, "/Root 1 0 R");
    const r = try listed(a, changed);
    const s = r.found[0];
    try testing.expectEqual(signed.len, s.coverage.sound.end);
    const after = s.after.changed;
    try testing.expectEqual(changed.len - signed.len, after.bytes);
    try testing.expectEqualSlices(signature.Change, &.{ .{ .num = 3, .kind = .replaced }, .{ .num = 6, .kind = .added } }, after.objects);
    try testing.expect(!after.trailer);
    // The signed revision opens on its own, as it was.
    try testing.expectEqualSlices(u8, signed, signature.signedRevision(r.doc, s).?);

    // An object freed.
    var removed: std.ArrayList(u8) = .empty;
    try removed.appendSlice(a, signed);
    const at = removed.items.len;
    try removed.print(a, "xref\n5 1\n0000000000 65535 f \n3 1\n0000000000 00001 f \ntrailer\n<< /Size 20 /Root 1 0 R /Prev {d} >>\nstartxref\n{d}\n%%EOF\n", .{ lastStartxref(signed), at });
    const gone = (try listed(a, removed.items)).found;
    for (gone) |item| try testing.expect(item.after != .nothing);
}

test "content appended without a cross-reference table still counts as a change" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const signed = try simple(a, comptime dictText(""));
    const changed = try std.mem.concat(a, u8, &.{ signed, "3 0 obj\n<< /Type /Page /Parent 2 0 R >>\nendobj\n" });
    const s = try only(a, changed);
    // Either it still reads without repair, and the change has no listed
    // object, or the file needs repair and the coverage is not relied on.
    switch (s.coverage) {
        .sound => try testing.expect(s.after == .changed and s.after.changed.bytes > 0),
        .unsound => |defect| try testing.expectEqual(signature.Defect.damaged_file, defect),
    }
}

test "a table or trailer that points elsewhere in the signed bytes is a change" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The signed bytes hold a second object 3 that nothing points to yet, and
    // a second catalog: the "hide and replace" shadow attack.
    var base: std.ArrayList(u8) = .empty;
    const whole = try buildFile(a, &.{ catalog, tree, page, widget, comptime dictText(""), "<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [4 0 R] >> >>" });
    const table = std.mem.indexOf(u8, whole, "xref\n").?;
    try base.appendSlice(a, whole[0..table]);
    const shadow_at = base.items.len;
    try base.appendSlice(a, "3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 9 9] /Annots [4 0 R] >>\nendobj\n");
    const moved = base.items.len;
    try base.appendSlice(a, whole[table..std.mem.indexOf(u8, whole, "startxref").?]);
    try base.print(a, "startxref\n{d}\n%%EOF\n", .{moved});
    seal(base.items);

    var repoint: std.ArrayList(u8) = .empty;
    try repoint.appendSlice(a, base.items);
    const at = repoint.items.len;
    try repoint.print(a, "xref\n3 1\n{d:0>10} 00000 n \ntrailer\n<< /Size 20 /Root 1 0 R /Prev {d} >>\nstartxref\n{d}\n%%EOF\n", .{ shadow_at, moved, at });
    const s = try only(a, repoint.items);
    try testing.expectEqualSlices(signature.Change, &.{.{ .num = 3, .kind = .replaced }}, s.after.changed.objects);

    const other_root = try update(a, base.items, &.{}, "/Root 6 0 R");
    const t = try only(a, other_root);
    try testing.expect(t.after.changed.trailer);
    try testing.expectEqual(@as(usize, 0), t.after.changed.objects.len);
}

test "replacing an object stream changes the objects in it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Object 3, the page, is in object stream 6. The table is a stream, 7.
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, "%PDF-1.7\n");
    var offsets: [8]usize = @splat(0);
    for ([_]New{
        .{ .num = 1, .body = catalog },
        .{ .num = 2, .body = tree },
        .{ .num = 4, .body = widget },
        .{ .num = 5, .body = comptime dictText("") },
        .{ .num = 6, .body = try std.fmt.allocPrint(a, "<< /Type /ObjStm /N 1 /First 4 /Length {d} >>\nstream\n3 0 {s}\nendstream", .{ page.len + 4, page }) },
    }) |item| {
        offsets[item.num] = out.items.len;
        try out.print(a, "{d} 0 obj\n{s}\nendobj\n", .{ item.num, item.body });
    }
    offsets[7] = out.items.len;
    var rows: [8 * 6]u8 = undefined;
    for (0..8) |num| {
        const row = rows[num * 6 ..][0..6];
        row.* = @splat(0);
        if (num == 3) {
            row[0] = 2;
            std.mem.writeInt(u32, row[1..5], 6, .big);
        } else if (num != 0) {
            row[0] = 1;
            std.mem.writeInt(u32, row[1..5], @intCast(offsets[num]), .big);
        }
    }
    try out.print(a, "7 0 obj\n<< /Type /XRef /Size 8 /W [1 4 1] /Root 1 0 R /Length {d} >>\nstream\n", .{rows.len});
    try out.appendSlice(a, &rows);
    try out.print(a, "\nendstream\nendobj\nstartxref\n{d}\n%%EOF\n", .{offsets[7]});
    seal(out.items);
    try testing.expectEqual(signature.After.nothing, (try only(a, out.items)).after);

    const other = "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 9 9] /Annots [4 0 R] >>";
    const changed = try update(a, out.items, &.{.{ .num = 6, .body = try std.fmt.allocPrint(a, "<< /Type /ObjStm /N 1 /First 4 /Length {d} >>\nstream\n3 0 {s}\nendstream", .{ other.len + 4, other }) }}, "/Root 1 0 R");
    const s = try only(a, changed);
    try testing.expectEqualSlices(signature.Change, &.{ .{ .num = 3, .kind = .replaced }, .{ .num = 6, .kind = .replaced } }, s.after.changed.objects);
}

fn withRange(a: Allocator, base: []const u8, range: []const u8) ![]u8 {
    const bytes = try a.dupe(u8, base);
    const at = std.mem.indexOf(u8, bytes, "/ByteRange [").? + "/ByteRange ".len;
    @memset(bytes[at..][0..holder.len], ' ');
    @memcpy(bytes[at..][0..range.len], range);
    return bytes;
}

test "byte ranges that leave something out are refused (universal forgery)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const good = try simple(a, comptime dictText(""));
    const range = (try only(a, good)).coverage.sound.byte_range;
    const first = range[1];
    const second = range[2];
    const rest = range[3];

    const Case = struct { []const u8, signature.Defect };
    const print = std.fmt.allocPrint;
    for ([_]Case{
        .{ "[]", .no_byte_range },
        .{ "null", .no_byte_range },
        .{ "[0 1 2]", .no_byte_range },
        .{ "[0 -1 5 5]", .no_byte_range },
        .{ "[0 1.5 5 5]", .no_byte_range },
        .{ "[0 9 0 R 5 5]", .no_byte_range },
        .{ try print(a, "[1 {d} {d} {d}]", .{ first - 1, second, rest }), .byte_range_shape },
        .{ try print(a, "[0 0 {d} {d}]", .{ second, rest }), .byte_range_shape },
        .{ try print(a, "[0 {d} {d} {d}]", .{ first, first, rest }), .byte_range_shape },
        .{ try print(a, "[0 {d} {d} 0]", .{ first, second }), .byte_range_shape },
        .{ try print(a, "[0 {d} {d} {d}]", .{ first, second, rest + 1 }), .out_of_file },
        .{ "[0 1 2 999999999999999999]", .out_of_file },
        .{ try print(a, "[0 {d} {d} {d}]", .{ first - 1, second, rest }), .gap_is_not_value },
        .{ try print(a, "[0 {d} {d} {d}]", .{ first, second + 1, rest - 1 }), .gap_is_not_value },
        // Short of the end of the revision.
        .{ try print(a, "[0 {d} {d} {d}]", .{ first, second, rest - 10 }), .not_end_of_revision },
    }) |case| {
        errdefer std.debug.print("byte range {s}\n", .{case[0]});
        try expectDefect(a, try withRange(a, good, case[0]), case[1]);
    }
}

test "removed, null and invalid entries are refused (USF, figure 7)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const head = "<< /Type /Sig /ByteRange [0 1 2 3]";
    for ([_]struct { []const u8, signature.Defect }{
        .{ "<< /Type /Sig /Contents " ++ value_hex ++ " >>", .no_byte_range },
        .{ "<< /Type /Sig >>", .no_byte_range },
        .{ "<< /Type /Sig /ByteRange [0 9 5 5] /Contents " ++ value_hex ++ " >>", .byte_range_shape },
        .{ head ++ " /Contents null >>", .no_value },
        .{ head ++ " /Contents 0 >>", .no_value },
    }) |case| {
        errdefer std.debug.print("dictionary {s}\n", .{case[0]});
        try expectDefect(a, try buildFile(a, &.{ catalog, tree, page, widget, case[0] }), case[1]);
    }
    // A key with nothing after it leaves no dictionary at all.
    const empty = try buildFile(a, &.{ catalog, tree, page, widget, "<< /Type /Sig /ByteRange /Contents >>" });
    const r = try listed(a, empty);
    for (r.found) |s| try testing.expect(s.coverage == .unsound);
}

test "appended content never passes as nothing (ISA, variants 1 to 4)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const signed = try simple(a, comptime dictText(""));
    const body = "3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 9 9] >>\nendobj\n";
    const start = std.mem.indexOf(u8, signed, "5 0 obj\n").?;
    const stop = std.mem.indexOfPos(u8, signed, start, "endobj\n").? + "endobj\n".len;
    const copied = signed[start..stop];
    const prev = lastStartxref(signed);
    for ([_][]const u8{
        // 1: an empty table.
        try std.fmt.allocPrint(a, "{s}xref\n0 0\ntrailer\n<< /Size 20 /Root 1 0 R /Prev {d} >>\nstartxref\n{d}\n%%EOF\n", .{ body, prev, signed.len + body.len }),
        // 2: no table and no trailer.
        body,
        // 3: a trailer alone, pointing back at the signed table.
        try std.fmt.allocPrint(a, "{s}trailer\n<< /Size 20 /Root 1 0 R >>\nstartxref\n{d}\n%%EOF\n", .{ body, prev }),
        // 4: the signature copied, without a table.
        try std.mem.concat(a, u8, &.{ body, copied }),
    }, 1..) |tail, variant| {
        errdefer std.debug.print("variant {d}\n", .{variant});
        const r = try listed(a, try std.mem.concat(a, u8, &.{ signed, tail }));
        try testing.expect(r.found.len >= 1);
        for (r.found) |s| try testing.expect(s.after != .nothing);
    }
}

test "a byte range that signs no first part, or only the header, is refused (SWA 2 and 2*)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const good = try simple(a, comptime dictText(""));
    const range = (try only(a, good)).coverage.sound.byte_range;
    for ([_]struct { usize, signature.Defect }{ .{ 0, .byte_range_shape }, .{ 5, .gap_is_not_value } }) |case| {
        // Both signed parts, joined, moved to the end of the file.
        const parts = try std.mem.concat(a, u8, &.{ good[0..range[1]], good[range[2]..] });
        const text = try std.fmt.allocPrint(a, "[0 {d} {d} {d}]", .{ case[0], good.len, parts.len });
        const moved = try std.mem.concat(a, u8, &.{ try withRange(a, good, text), parts });
        try expectDefect(a, moved, case[1]);
    }
}

test "empty and misplaced signature values are refused" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const head = "<< /Type /Sig /ByteRange " ++ holder;
    const zeros = try simple(a, head ++ " /Contents <00000000> >>");
    try expectDefect(a, zeros, .empty_value);
    const nothing = try simple(a, head ++ " /Contents <> >>");
    try expectDefect(a, nothing, .empty_value);
    const spaced = try simple(a, head ++ " /Contents <30 03> >>");
    try expectDefect(a, spaced, .gap_is_not_value);
    const literal = try buildFile(a, &.{ catalog, tree, page, widget, "<< /Type /Sig /ByteRange [0 1 2 3] /Contents 6 0 R >>", "<3003>" });
    try expectDefect(a, literal, .no_value);
    const none = try buildFile(a, &.{ catalog, tree, page, widget, "<< /Type /Sig /ByteRange [0 1 2 3] >>" });
    try expectDefect(a, none, .no_value);

    // The gap holds the same string, but not this dictionary's: the second
    // `/Contents` counts, and the byte range leaves out the first.
    const twice = try simple(a, head ++ " /Contents " ++ value_hex ++ " /Contents " ++ value_hex ++ " >>");
    try expectDefect(a, twice, .gap_is_not_value);
}

test "a gap widened to hold unsigned content is refused (signature wrapping)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // A long reason after the value leaves room before the table.
    const roomy = try std.fmt.allocPrint(a, "<< /Type /Sig /ByteRange {s} /Contents {s} /Reason ({s:x>200}) >>", .{ holder, value_hex, "" });
    const signed = try simple(a, roomy);
    const range = (try only(a, signed)).coverage.sound.byte_range;
    // As the attack does it: the second signed part moves further on, and the
    // gap this opens after the value takes unsigned objects. The bytes the
    // range covers are the same as before, apart from the range itself.
    // The gap closes the dictionary, brings its own page, and holds a table at
    // the offset that the signed `startxref` names.
    const table_at = lastStartxref(signed);
    var forged: std.ArrayList(u8) = .empty;
    try forged.appendSlice(a, signed[0..range[2]]);
    try forged.appendSlice(a, " >>\nendobj\n");
    const object_at = forged.items.len;
    try forged.appendSlice(a, "3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 9 9] >>\nendobj\n");
    const new_table = @max(table_at, forged.items.len);
    try forged.appendNTimes(a, ' ', new_table - forged.items.len);
    // The signed table, with object 3 pointed at the injected one.
    const original = signed[table_at..std.mem.indexOfPos(u8, signed, table_at, "startxref").?];
    const copy = try a.dupe(u8, original);
    var line: usize = 0;
    for (0..4) |_| line = std.mem.indexOfScalarPos(u8, copy, line, '\n').? + 1;
    line = std.mem.indexOfScalarPos(u8, copy, line, '\n').? + 1;
    _ = try std.fmt.bufPrint(copy[line..][0..10], "{d:0>10}", .{object_at});
    try testing.expect(new_table == table_at);
    try forged.appendSlice(a, copy);
    try forged.appendSlice(a, "%");
    const moved_to = forged.items.len;
    try forged.appendSlice(a, signed[range[2]..]);
    const wrapped = forged.items;
    var numbers: [holder.len]u8 = undefined;
    _ = try std.fmt.bufPrint(&numbers, "[0 {d:0>10} {d:0>10} {d:0>10}]", .{ range[1], moved_to, range[3] });
    const at = std.mem.indexOf(u8, wrapped, "/ByteRange ").? + "/ByteRange ".len;
    @memcpy(wrapped[at..][0..holder.len], &numbers);
    // The forged file reads without repair and shows the injected page.
    const r = try listed(a, wrapped);
    try testing.expect(!r.doc.repaired);
    try testing.expectEqual(@as(f64, 9), r.doc.getObject(3).dict.get("MediaBox").?.array[2].asNum().?);
    try testing.expectEqual(@as(usize, 1), r.found.len);
    try testing.expectEqual(signature.Coverage{ .unsound = .gap_is_not_value }, r.found[0].coverage);
}

test "a signature written again by a later revision is judged where it now is" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const signed = try simple(a, comptime dictText(""));
    // The same dictionary, byte range and all, after the signed bytes.
    const start = std.mem.indexOf(u8, signed, "5 0 obj\n").? + "5 0 obj\n".len;
    const stop = std.mem.indexOfPos(u8, signed, start, "\nendobj").?;
    const moved = try update(a, signed, &.{.{ .num = 5, .body = signed[start..stop] }}, "/Root 1 0 R");
    try expectDefect(a, moved, .gap_is_not_value);
}

test "a signature the signed revision did not have in that place is refused" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The signed bytes hold the dictionary, but no field leads to it until a
    // later revision does.
    const hidden = try buildFile(a, &.{ "<< /Type /Catalog /Pages 2 0 R >>", tree, page, "<< >>", comptime dictText("") });
    seal(hidden);
    const pointed = try update(a, hidden, &.{ .{ .num = 1, .body = catalog }, .{ .num = 4, .body = widget } }, "/Root 1 0 R");
    try expectDefect(a, pointed, .revision_differs);

    // The field was there, but the form did not list it.
    const unlisted = try buildFile(a, &.{ "<< /Type /Catalog /Pages 2 0 R >>", tree, page, widget, comptime dictText("") });
    seal(unlisted);
    const listed_later = try update(a, unlisted, &.{.{ .num = 1, .body = catalog }}, "/Root 1 0 R");
    try expectDefect(a, listed_later, .revision_differs);
}

test "a signature inside an object stream cannot be left out of a byte range" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const body = "<< /Type /Sig /ByteRange [0 9 99 9] /Contents " ++ value_hex ++ " >>";
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, "%PDF-1.7\n");
    var offsets: [7]usize = @splat(0);
    for ([_]New{
        .{ .num = 1, .body = catalog },
        .{ .num = 2, .body = tree },
        .{ .num = 3, .body = page },
        .{ .num = 4, .body = widget },
        .{ .num = 6, .body = try std.fmt.allocPrint(a, "<< /Type /ObjStm /N 1 /First 4 /Length {d} >>\nstream\n5 0 {s}\nendstream", .{ body.len + 4, body }) },
    }) |item| {
        offsets[item.num] = out.items.len;
        try out.print(a, "{d} 0 obj\n{s}\nendobj\n", .{ item.num, item.body });
    }
    const xref_at = out.items.len;
    var rows: [7 * 6]u8 = @splat(0);
    for (1..7) |num| {
        rows[num * 6] = if (num == 5) 2 else 1;
        std.mem.writeInt(u32, rows[num * 6 + 1 ..][0..4], @intCast(if (num == 5) 6 else offsets[num]), .big);
    }
    // Object 0 is not used, and the table itself is not listed in itself.
    try out.print(a, "7 0 obj\n<< /Type /XRef /Size 7 /W [1 4 1] /Root 1 0 R /Length {d} >>\nstream\n", .{rows.len});
    try out.appendSlice(a, &rows);
    try out.print(a, "\nendstream\nendobj\nstartxref\n{d}\n%%EOF\n", .{xref_at});
    try expectDefect(a, out.items, .not_in_file);
}

test "a signature in a damaged file is not relied on" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const good = try simple(a, comptime dictText(""));
    const damaged = try a.dupe(u8, good);
    const at = std.mem.lastIndexOf(u8, damaged, "startxref\n").? + "startxref\n".len;
    damaged[at] = '9';
    try expectDefect(a, damaged, .damaged_file);
}

test "a dictionary written inside the field is found" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bytes = try buildFile(a, &.{ catalog, tree, page, "<< /Type /Annot /Subtype /Widget /FT /Sig /T (inside) /Rect [0 0 0 0] /V " ++ comptime dictText("") ++ " >>" });
    seal(bytes);
    const s = try only(a, bytes);
    try testing.expectEqual(signature.After.nothing, s.after);

    // And one a field inherits from its parent.
    const inherited = try buildFile(a, &.{
        catalog,
        tree,
        "<< /Type /Page /Parent 2 0 R >>",
        "<< /FT /Sig /T (parent) /V 6 0 R /Kids [5 0 R] >>",
        "<< /T (child) /Parent 4 0 R /Type /Annot /Subtype /Widget /Rect [0 0 0 0] >>",
        comptime dictText(""),
    });
    seal(inherited);
    const found = (try listed(a, inherited)).found;
    try testing.expect(found.len >= 1);
    try testing.expectEqual(signature.After.nothing, found[0].after);
}

test "certification, locks, permissions and time stamps" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const certified = try buildFile(a, &.{
        "<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [4 0 R] >> /Perms << /DocMDP 5 0 R >> >>",
        tree,
        page,
        widget,
        comptime dictText(" /Reference [<< /Type /SigRef /TransformMethod /DocMDP /TransformParams << /P 1 >> >> << /TransformMethod /FieldMDP /Data 1 0 R /TransformParams << /Action /Include /Fields [(a) (b)] >> >>]"),
    });
    seal(certified);
    const s = try only(a, certified);
    try testing.expectEqual(signature.Kind.certification, s.kind);
    try testing.expectEqual(signature.Allowed.nothing, s.allowed.?);
    try testing.expect(s.in_permissions);
    try testing.expectEqualStrings("b", s.lock.?.fields[1]);
    try testing.expect(s.lock.?.action == .include);
    try testing.expectEqual(signature.After.nothing, s.after);

    for ([_]struct { []const u8, ?signature.Allowed }{
        .{ "", .forms_and_signing },
        .{ "/P 3", .forms_signing_and_annotations },
        .{ "/P 9", null },
    }) |case| {
        const bytes = try simple(a, try std.mem.concat(a, u8, &.{ "<< /Type /Sig /ByteRange ", holder, " /Contents ", value_hex, " /Reference [<< /TransformMethod /DocMDP /TransformParams << ", case[0], " >> >>] >>" }));
        const c = try only(a, bytes);
        try testing.expectEqual(case[1], c.allowed);
        try testing.expect(!c.in_permissions);
    }

    // Usage rights are only in the permissions, which here are a direct
    // dictionary holding a direct signature.
    const rights = try buildFile(a, &.{ "<< /Type /Catalog /Pages 2 0 R /Perms << /UR3 " ++ comptime dictText("") ++ " >> >>", tree, "<< /Type /Page /Parent 2 0 R >>" });
    seal(rights);
    const u = try only(a, rights);
    try testing.expectEqual(signature.Kind.usage_rights, u.kind);
    try testing.expectEqual(@as(u32, 0), u.field_num);
    try testing.expect(u.in_permissions);
    try testing.expectEqual(signature.After.nothing, u.after);

    const stamp = try simple(a, "<< /Type /DocTimeStamp /SubFilter /ETSI.RFC3161 /ByteRange " ++ holder ++ " /Contents " ++ value_hex ++ " >>");
    try testing.expectEqual(signature.Kind.timestamp, (try only(a, stamp)).kind);
}

test "two signatures cover two revisions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const first = try simple(a, comptime dictText(" /Name (first)"));
    const second = try update(a, first, &.{
        .{ .num = 1, .body = "<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [4 0 R 6 0 R] >> >>" },
        .{ .num = 6, .body = "<< /Type /Annot /Subtype /Widget /FT /Sig /T (again) /Rect [0 0 0 0] /V 7 0 R >>" },
        .{ .num = 7, .body = comptime dictText(" /Name (second)") },
    }, "/Root 1 0 R");
    seal(second);
    const found = (try listed(a, second)).found;
    try testing.expectEqual(@as(usize, 2), found.len);
    try testing.expectEqual(first.len, found[0].coverage.sound.end);
    try testing.expect(found[0].after == .changed);
    try testing.expectEqual(second.len, found[1].coverage.sound.end);
    try testing.expectEqual(signature.After.nothing, found[1].after);
}

test "a filled form after signing is a change, whether or not it is allowed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bytes = try buildFile(a, &.{
        "<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [4 0 R 6 0 R] >> >>",
        tree,
        "<< /Type /Page /Parent 2 0 R /Annots [4 0 R 6 0 R] >>",
        widget,
        comptime dictText(""),
        "<< /Type /Annot /Subtype /Widget /FT /Tx /T (name) /Rect [10 10 90 30] >>",
    });
    seal(bytes);
    var doc = try pdf.Document.open(a, bytes, .{});
    const fields = try pdf.form.fields(a, &doc, try pdf.pages.PageList.build(&doc));
    var upd = try pdf.write.Update.init(testing.allocator, &doc);
    defer upd.deinit();
    for (fields) |f| if (f.kind == .text) try pdf.form.setText(&upd, f, "later");
    var out: std.Io.Writer.Allocating = .init(a);
    try upd.write(testing.allocator, &out.writer);
    const s = try only(a, out.written());
    try testing.expectEqual(bytes.len, s.coverage.sound.end);
    var saw_field = false;
    for (s.after.changed.objects) |change| {
        if (change.num == 6) saw_field = true;
        try testing.expect(change.num != 5);
    }
    try testing.expect(saw_field);
}

fn listAll(gpa: Allocator, bytes: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var doc = try pdf.Document.open(gpa, bytes, .{});
    defer doc.deinit();
    const page_list = try pdf.pages.PageList.build(&doc);
    _ = try signature.list(arena.allocator(), &doc, page_list, .{});
}

/// A form of `count` signature fields that all name one dictionary.
fn shared(a: Allocator, count: usize, dict: []const u8) ![]u8 {
    var bodies: std.ArrayList([]const u8) = .empty;
    var refs: std.ArrayList(u8) = .empty;
    for (0..count) |i| try refs.print(a, "{d} 0 R ", .{i + 5});
    try bodies.appendSlice(a, &.{
        try std.fmt.allocPrint(a, "<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [{s}] >> >>", .{refs.items}),
        tree,
        "<< /Type /Page /Parent 2 0 R >>",
        dict,
    });
    for (0..count) |i| try bodies.append(a, try std.fmt.allocPrint(a, "<< /FT /Sig /T (f{d}) /V 4 0 R >>", .{i}));
    return buildFile(a, bodies.items);
}

test "many fields naming one large signature do bounded work" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const long = try a.alloc(u8, signature.max_listed_bytes / 3);
    @memset(long, 'n');
    const dict = try std.fmt.allocPrint(a, "<< /Type /Sig /ByteRange {s} /Contents {s} /Name ({s}) >>", .{ holder, value_hex, long });
    const bytes = try shared(a, signature.max_examined + 40, dict);
    seal(bytes);
    const found = (try listed(a, bytes)).found;
    try testing.expectEqual(signature.max_examined + 40, found.len);
    var named: usize = 0;
    for (found, 0..) |s, i| {
        if (s.claims.name != null) named += 1;
        if (i < signature.max_examined) continue;
        try testing.expectEqual(signature.Coverage{ .unsound = .not_examined }, s.coverage);
        try testing.expect(s.sub_filter == null and s.value.len == 0);
    }
    // Only as many claims as the budget holds.
    try testing.expectEqual(@as(usize, 3), named);
}

test "a signature value or a lock too large to keep says so" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const digits = try a.alloc(u8, 2 * (signature.max_value_bytes + 1));
    @memset(digits, '1');
    const big = try simple(a, try std.fmt.allocPrint(a, "<< /Type /Sig /ByteRange {s} /Contents <{s}> >>", .{ holder, digits }));
    try expectDefect(a, big, .value_too_large);

    var names: std.ArrayList(u8) = .empty;
    for (0..signature.max_lock_fields + 1) |_| try names.appendSlice(a, "(f)");
    const locked = try simple(a, try std.fmt.allocPrint(a, "<< /Type /Sig /ByteRange {s} /Contents {s} /Reference [<< /TransformMethod /FieldMDP /TransformParams << /Action /Include /Fields [{s}] >> >>] >>", .{ holder, value_hex, names.items }));
    const lock = (try only(a, locked)).lock.?;
    try testing.expectEqual(signature.max_lock_fields, lock.fields.len);
    try testing.expect(!lock.complete);
}

test "a long list of changed objects is cut off and counted" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const signed = try simple(a, comptime dictText(""));
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, signed);
    const added = signature.max_changes + 7;
    const object_at = out.items.len;
    try out.appendSlice(a, "100 0 obj\nnull\nendobj\n");
    const table = out.items.len;
    try out.print(a, "xref\n100 {d}\n", .{added});
    for (0..added) |_| try out.print(a, "{d:0>10} 00000 n \n", .{object_at});
    try out.print(a, "trailer\n<< /Size {d} /Root 1 0 R /Prev {d} >>\nstartxref\n{d}\n%%EOF\n", .{ 100 + added, lastStartxref(signed), table });
    const changes = (try only(a, out.items)).after.changed;
    try testing.expectEqual(signature.max_changes, changes.objects.len);
    try testing.expectEqual(@as(usize, 7), changes.omitted);
    try testing.expectEqual(@as(u32, 100), changes.objects[0].num);
}

test "signature listing survives every allocation failing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const signed = try simple(a, comptime dictText(" /Name (A) /Reference [<< /TransformMethod /FieldMDP /TransformParams << /Action /All >> >>]"));
    const changed = try update(a, signed, &.{.{ .num = 3, .body = page }}, "/Root 1 0 R");
    try testing.checkAllAllocationFailures(testing.allocator, listAll, .{changed});
}

test "damaged signed files are listed or refused, never a crash (seeded mutation)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const signed = try simple(a, comptime dictText(" /Name (A) /Reference [<< /TransformMethod /DocMDP >>]"));
    const base = try update(a, signed, &.{.{ .num = 3, .body = page }}, "/Root 1 0 R");
    var prng = std.Random.DefaultPrng.init(0x51);
    const random = prng.random();
    const copy = try a.dupe(u8, base);
    var found_any: usize = 0;
    for (0..4000) |_| {
        @memcpy(copy, base);
        for (0..random.intRangeAtMost(usize, 1, 4)) |_| {
            copy[random.uintLessThan(usize, copy.len)] = "0123456789()<>[]/ .-RVx\n"[random.uintLessThan(usize, 24)];
        }
        var each = std.heap.ArenaAllocator.init(testing.allocator);
        defer each.deinit();
        var doc = pdf.Document.open(each.allocator(), copy, .{}) catch continue;
        const page_list = pdf.pages.PageList.build(&doc) catch continue;
        for (try signature.list(each.allocator(), &doc, page_list, .{})) |s| {
            found_any += 1;
            if (s.coverage != .sound) continue;
            // What sound coverage promises.
            const range = s.coverage.sound.byte_range;
            try testing.expect(range[0] == 0 and range[1] < range[2]);
            try testing.expect(s.coverage.sound.end <= copy.len);
            try testing.expect(copy[range[1]] == '<' and copy[range[2] - 1] == '>');
        }
    }
    try testing.expect(found_any > 200);
}
