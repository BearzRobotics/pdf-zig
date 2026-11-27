// SPDX-License-Identifier: LGPL-2.0-or-later
//! Encrypted files made with qpdf (see test/fixtures/README.md).

const std = @import("std");
const pdf = @import("root.zig");
const testing = std.testing;

fn textOf(doc: *pdf.Document) ![]u8 {
    var rend = pdf.Renderer.init(doc, .{ .graphics = false });
    defer rend.deinit();
    const list = try pdf.pages.PageList.build(doc);
    var dl = try rend.render(testing.allocator, pdf.pages.page(doc, list, 0) orelse return error.NoPage);
    defer dl.deinit();
    return pdf.text.extract(testing.allocator, &dl, .reading);
}

fn title(doc: *pdf.Document) ?[]const u8 {
    const info = doc.getDict(doc.trailer, "Info") orelse return null;
    const t = doc.get(info, "Title") orelse return null;
    return if (t == .string) t.string else null;
}

fn check(bytes: []const u8, password: []const u8) !void {
    var doc = try pdf.Document.open(testing.allocator, bytes, .{ .password = password });
    defer doc.deinit();
    const text = try textOf(&doc);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("Hello encrypted world\n", text);
    // Strings are decrypted too, not only streams.
    try testing.expectEqualStrings("Secret Title", title(&doc).?);
}

test "the unencrypted file" {
    try check(@embedFile("plain.pdf"), "");
}

test "RC4 40 and 128 bit, the empty password" {
    try check(@embedFile("enc_rc4_40.pdf"), "");
    try check(@embedFile("enc_rc4_128.pdf"), "");
}

test "AES-128 and AES-256, the empty password" {
    try check(@embedFile("enc_aes_128.pdf"), "");
    try check(@embedFile("enc_aes_256.pdf"), "");
}

test "a user password is required and checked" {
    for ([_][]const u8{ @embedFile("enc_aes_256_pw.pdf"), @embedFile("enc_rc4_128_pw.pdf") }) |bytes| {
        try testing.expectError(error.PasswordRequired, pdf.Document.open(testing.allocator, bytes, .{}));
        try testing.expectError(error.PasswordRequired, pdf.Document.open(testing.allocator, bytes, .{ .password = "wrong" }));
        try check(bytes, "pw");
    }
}

test "encrypted files that are damaged do not crash (seeded mutation)" {
    var prng = std.Random.DefaultPrng.init(0xc0de);
    const rnd = prng.random();
    const sources = [_][]const u8{ @embedFile("enc_rc4_128.pdf"), @embedFile("enc_aes_128.pdf"), @embedFile("enc_aes_256.pdf") };
    for (0..300) |i| {
        const src = sources[i % sources.len];
        const copy = try testing.allocator.dupe(u8, src);
        defer testing.allocator.free(copy);
        for (0..rnd.intRangeAtMost(usize, 1, 6)) |_| copy[rnd.uintLessThan(usize, copy.len)] = rnd.int(u8);
        const len = if (rnd.boolean()) copy.len else rnd.uintLessThan(usize, copy.len) + 1;
        var doc = pdf.Document.open(testing.allocator, copy[0..len], .{}) catch continue;
        defer doc.deinit();
        const text = textOf(&doc) catch continue;
        testing.allocator.free(text);
    }
}

/// `bytes` with `old` replaced by `new` of the same length, so offsets hold.
fn patched(a: std.mem.Allocator, bytes: []const u8, old: []const u8, new: []const u8) ![]u8 {
    try testing.expectEqual(old.len, new.len);
    try testing.expect(std.mem.indexOf(u8, bytes, old) != null);
    return std.mem.replaceOwned(u8, a, bytes, old, new);
}

test "an unknown crypt method is refused, not read as plain text" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const aes128 = @embedFile("enc_aes_128.pdf");
    const aes256 = @embedFile("enc_aes_256.pdf");
    for ([_][]const u8{
        try patched(a, aes128, "/CFM /AESV2", "/CFM /ZZZV9"),
        try patched(a, aes128, "/CFM /AESV2", "/CFX /AESV2"),
        try patched(a, aes128, "/StmF /StdCF", "/StmF /NoSuc"),
        try patched(a, aes256, "/CFM /AESV3", "/CFM /ZZZV9"),
        try patched(a, aes256, "/StrF /StdCF", "/StrF /NoSuc"),
    }) |bytes| {
        try testing.expectError(error.UnsupportedEncryption, pdf.Document.open(testing.allocator, bytes, .{}));
    }
}

test "AES-256 files follow /StmF and /StrF" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const bytes = try std.mem.replaceOwned(u8, arena.allocator(), @embedFile("enc_aes_256.pdf"), "/StrF /StdCF", "/StrF /Identity");
    var doc = try pdf.Document.open(testing.allocator, bytes, .{});
    defer doc.deinit();
    try testing.expectEqual(pdf.crypt.Method.none, doc.crypt.?.string_method);
    try testing.expectEqual(pdf.crypt.Method.aes256, doc.crypt.?.stream_method);
}

test "R2 with a password, R5, V4 RC4 and clear metadata, and object streams" {
    const r2 = @embedFile("enc_rc4_40_pw.pdf");
    // A wrong password must not open an R2 file.
    try testing.expectError(error.PasswordRequired, pdf.Document.open(testing.allocator, r2, .{}));
    try testing.expectError(error.PasswordRequired, pdf.Document.open(testing.allocator, r2, .{ .password = "wrong" }));
    try check(r2, "pw");
    try check(@embedFile("enc_aes_256_r5.pdf"), "");
    try check(@embedFile("enc_aes_128_objstm.pdf"), "");
    for ([_][]const u8{ @embedFile("enc_rc4_v4_clearmeta.pdf"), @embedFile("enc_aes_128_clearmeta.pdf") }) |bytes| {
        try check(bytes, "");
        // With /EncryptMetadata false the metadata stream is left as it is.
        var doc = try pdf.Document.open(testing.allocator, bytes, .{});
        defer doc.deinit();
        try testing.expect(!doc.crypt.?.encrypt_metadata);
        const metadata = doc.get(doc.catalog().?, "Metadata").?.stream;
        try testing.expectEqualStrings("<x:xmpmeta>clear metadata</x:xmpmeta>", try doc.streamData(metadata));
    }
}

test "a non-ASCII password given as UTF-8 opens R3 and R4 files" {
    // The files' password is "päss€•" in PDFDocEncoding (7.6.3.3).
    for ([_][]const u8{ @embedFile("enc_rc4_r3_pdfdoc_pw.pdf"), @embedFile("enc_aes_128_pdfdoc_pw.pdf") }) |bytes| {
        try check(bytes, "p\u{e4}ss\u{20ac}\u{2022}");
        // Bytes already in the file's encoding keep working.
        try check(bytes, "p\xe4ss\xa0\x80");
        try testing.expectError(error.PasswordRequired, pdf.Document.open(testing.allocator, bytes, .{ .password = "p\u{e4}ss\u{20ac}" }));
        // A character PDFDocEncoding lacks cannot be part of the password.
        try testing.expectError(error.PasswordRequired, pdf.Document.open(testing.allocator, bytes, .{ .password = "p\u{e4}ss\u{20ac}\u{2022}\u{4e00}" }));
    }
}

test "R6 passwords get SASLprep's character mapping" {
    // The file's password is "open sesame". A no-break space becomes a space
    // and a soft hyphen is dropped (RFC 4013, 2.1).
    const bytes = @embedFile("enc_aes_256_mapped_pw.pdf");
    try check(bytes, "open sesame");
    try check(bytes, "open\u{a0}ses\u{ad}ame");
    try testing.expectError(error.PasswordRequired, pdf.Document.open(testing.allocator, bytes, .{ .password = "opensesame" }));
}
