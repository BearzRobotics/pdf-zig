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
