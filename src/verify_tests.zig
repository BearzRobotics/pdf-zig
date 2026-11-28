// SPDX-License-Identifier: LGPL-2.0-or-later
//! What `verify.check` asks a verifier and which answers it takes. The verifier
//! here is a stand-in without cryptography: its "signature" is a bare SHA-256
//! of the signed bytes, which anyone could make.

const std = @import("std");
const pdf = @import("root.zig");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;
const signature = pdf.signature;
const verify = pdf.verify;
const files = @import("signature_tests.zig");

const Stub = struct {
    calls: usize = 0,
    /// Answered instead of looking at the request.
    fixed: ?verify.Outcome = null,
    format: ?verify.Format = null,
    seen: [2][]const u8 = .{ "", "" },

    fn verifier(self: *Stub) verify.Verifier {
        return .{ .ptr = self, .vtable = &.{ .name = "stub", .verify = run } };
    }

    fn run(ptr: *anyopaque, a: Allocator, request: verify.Request) Allocator.Error!verify.Outcome {
        const self: *Stub = @ptrCast(@alignCast(ptr));
        self.calls += 1;
        self.format = request.format;
        self.seen = request.signed;
        if (self.fixed) |answer| return answer;
        var expected: [Sha256.digest_length]u8 = undefined;
        var hash = Sha256.init(.{});
        for (request.signed) |piece| hash.update(piece);
        hash.final(&expected);
        if (request.value.len < expected.len or !std.mem.allEqual(u8, request.value[expected.len..], 0))
            return .{ .not_checked = .malformed_value };
        if (!std.mem.eql(u8, request.value[0..expected.len], &expected)) return .altered;
        return .{ .intact = .{
            .certificate = try a.dupe(u8, "a certificate"),
            .digest = .sha256,
            .key = .{ .kind = .rsa, .bits = 2048 },
        } };
    }
};

const strong: verify.Evidence = .{ .certificate = "c", .digest = .sha256, .key = .{ .kind = .rsa, .bits = 2048 } };

/// Room for the stand-in's value and some padding.
const digits = 96;

/// A file whose signature value is the stand-in's, with `sub_filter`.
fn signed(a: Allocator, comptime sub_filter: []const u8) ![]u8 {
    const zeros: [digits]u8 = @splat('1');
    const dict = "<< /Type /Sig " ++ sub_filter ++ " /ByteRange " ++ files.holder ++ " /Contents <" ++ zeros ++ "> >>";
    const bytes = try files.buildFile(a, &.{ files.catalog, files.tree, files.page, files.widget, dict });
    files.seal(bytes);
    const first = std.mem.indexOf(u8, bytes, "/Contents <").? + "/Contents <".len;
    var hash = Sha256.init(.{});
    hash.update(bytes[0 .. first - 1]);
    hash.update(bytes[first + digits + 1 ..]);
    var value: [digits / 2]u8 = @splat(0);
    hash.final(value[0..Sha256.digest_length]);
    @memcpy(bytes[first..][0..digits], &std.fmt.bytesToHex(value, .upper));
    return bytes;
}

const detached = "/SubFilter /adbe.pkcs7.detached";

const Opened = struct { doc: *pdf.Document, s: signature.Signature };

fn open(a: Allocator, bytes: []const u8) !Opened {
    const doc = try a.create(pdf.Document);
    doc.* = try pdf.Document.open(a, bytes, .{});
    const found = try signature.list(a, doc, try pdf.pages.PageList.build(doc), .{});
    try testing.expectEqual(@as(usize, 1), found.len);
    return .{ .doc = doc, .s = found[0] };
}

fn expectNotChecked(report: verify.Report, why: verify.CannotCheck) !void {
    try testing.expectEqual(verify.Outcome{ .not_checked = why }, report.integrity);
}

test "the verifier is handed every byte but the value, and its answer is reported" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bytes = try signed(a, detached);
    const o = try open(a, bytes);
    var stub: Stub = .{};
    const report = try verify.check(a, o.doc, o.s, stub.verifier());
    try testing.expectEqualStrings("a certificate", report.integrity.intact.certificate);
    try testing.expectEqualStrings("stub", report.verifier);
    try testing.expectEqual(signature.After.nothing, report.after);
    try testing.expect(!report.weak.any());
    try testing.expectEqual(verify.Format.pkcs7_detached, stub.format.?);
    const range = o.s.coverage.sound.byte_range;
    try testing.expectEqualSlices(u8, bytes[0..range[1]], stub.seen[0]);
    try testing.expectEqualSlices(u8, bytes[range[2]..], stub.seen[1]);
}

test "a signed byte that is changed, in either piece, is reported as altered" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bytes = try signed(a, detached);
    for ([_][]const u8{ "/MediaBox [0 0 200 200]", "trailer\n<< /Size " }) |near| {
        const changed = try a.dupe(u8, bytes);
        const at = std.mem.indexOf(u8, changed, near).? + near.len - 2;
        // A digit becomes another, so that the file still reads.
        changed[at] = if (changed[at] == '9') '8' else '9';
        const o = try open(a, changed);
        var stub: Stub = .{};
        const report = try verify.check(a, o.doc, o.s, stub.verifier());
        try testing.expectEqual(verify.Outcome.altered, report.integrity);
        try testing.expectEqual(@as(usize, 1), stub.calls);
    }
}

test "an intact earlier revision is still reported as changed afterwards" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bytes = try signed(a, detached);
    const later = try files.update(a, bytes, &.{.{ .num = 3, .body = files.page }}, "/Root 1 0 R");
    const o = try open(a, later);
    var stub: Stub = .{};
    const report = try verify.check(a, o.doc, o.s, stub.verifier());
    try testing.expect(report.integrity == .intact);
    try testing.expect(report.after == .changed);
    try testing.expectEqual(bytes.len, report.coverage.sound.end);
    try testing.expectEqual(bytes.len - o.s.coverage.sound.byte_range[2], stub.seen[1].len);
}

test "unsound coverage is never intact, and the verifier is not asked" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bytes = try signed(a, detached);
    const o = try open(a, bytes);
    var s = o.s;
    var stub: Stub = .{ .fixed = .{ .intact = strong } };
    for (std.enums.values(signature.Defect)) |defect| {
        s.coverage = .{ .unsound = defect };
        try expectNotChecked(try verify.check(a, o.doc, s, stub.verifier()), .unsound_coverage);
    }
    try testing.expectEqual(@as(usize, 0), stub.calls);
}

test "a signature of other bytes, or a made-up one, is not handed on" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const o = try open(a, try signed(a, detached));
    var stub: Stub = .{ .fixed = .{ .intact = strong } };
    const other = try open(a, try files.simple(a, comptime files.dictText("")));

    const good = o.s.coverage.sound;
    var cases: std.ArrayList(signature.Signature) = .empty;
    // Another file's signature.
    try cases.append(a, other.s);
    // Another value.
    var s = o.s;
    const value = try a.dupe(u8, s.value);
    value[0] ^= 1;
    s.value = value;
    try cases.append(a, s);
    s.value = o.s.value[0 .. o.s.value.len - 1];
    try cases.append(a, s);
    // Ranges that do not add up or leave the file.
    const huge = std.math.maxInt(usize);
    for ([_][4]usize{
        .{ 1, good.byte_range[1], good.byte_range[2], good.byte_range[3] },
        .{ 0, good.byte_range[2], good.byte_range[1], good.byte_range[3] },
        .{ 0, good.byte_range[1] - 1, good.byte_range[2], good.byte_range[3] },
        .{ 0, good.byte_range[1], good.byte_range[2], good.byte_range[3] - 1 },
        .{ 0, good.byte_range[1], huge, 2 },
    }) |range| {
        s = o.s;
        s.coverage = .{ .sound = .{ .end = good.end, .byte_range = range } };
        try cases.append(a, s);
    }
    s = o.s;
    s.coverage = .{ .sound = .{ .end = huge, .byte_range = good.byte_range } };
    try cases.append(a, s);

    for (cases.items, 0..) |case, i| {
        errdefer std.debug.print("case {d}\n", .{i});
        const report = try verify.check(a, o.doc, case, stub.verifier());
        try expectNotChecked(report, .not_from_this_document);
        try testing.expectEqual(signature.After.unknown, report.after);
    }
    try testing.expectEqual(@as(usize, 0), stub.calls);
}

test "formats: the known ones are named to the verifier, others are not asked about" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const o = try open(a, try signed(a, detached));
    for ([_]struct { ?[]const u8, ?verify.Format }{
        .{ "adbe.pkcs7.detached", .pkcs7_detached },
        .{ "adbe.pkcs7.sha1", .pkcs7_sha1 },
        .{ "ETSI.CAdES.detached", .cades_detached },
        .{ "ETSI.RFC3161", .rfc3161 },
        .{ "adbe.x509.rsa_sha1", null },
        .{ "adbe.pkcs7.detached ", null },
        .{ "", null },
        .{ null, null },
    }) |case| {
        var s = o.s;
        s.sub_filter = case[0];
        var stub: Stub = .{ .fixed = .altered };
        const report = try verify.check(a, o.doc, s, stub.verifier());
        if (case[1]) |format| {
            try testing.expectEqual(format, stub.format.?);
        } else {
            try expectNotChecked(report, .unsupported_format);
            try testing.expectEqual(@as(usize, 0), stub.calls);
        }
        // The old format needs SHA-1 whatever is inside it.
        try testing.expectEqual(case[1] == .pkcs7_sha1, report.weak.digest);
    }
}

test "weak digests and keys are marked, whatever the verifier thinks of them" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const o = try open(a, try signed(a, detached));
    for (std.enums.values(verify.Digest)) |digest| {
        var evidence = strong;
        evidence.digest = digest;
        var stub: Stub = .{ .fixed = .{ .intact = evidence } };
        const report = try verify.check(a, o.doc, o.s, stub.verifier());
        try testing.expectEqual(digest == .md5 or digest == .ripemd160 or digest == .sha1, report.weak.digest);
        try testing.expect(!report.weak.key);
    }
    const Case = struct { verify.Key, bool };
    for ([_]Case{
        .{ .{ .kind = .rsa, .bits = 2047 }, true },
        .{ .{ .kind = .rsa, .bits = 2048 }, false },
        .{ .{ .kind = .rsa_pss, .bits = 1024 }, true },
        .{ .{ .kind = .dsa, .bits = 1024 }, true },
        .{ .{ .kind = .ecdsa, .bits = 192 }, true },
        .{ .{ .kind = .ecdsa, .bits = 224 }, false },
        .{ .{ .kind = .ed25519, .bits = 253 }, false },
    }) |case| {
        var evidence = strong;
        evidence.key = case[0];
        var stub: Stub = .{ .fixed = .{ .intact = evidence } };
        try testing.expectEqual(case[1], (try verify.check(a, o.doc, o.s, stub.verifier())).weak.key);
    }
}

test "answers that cannot be right become a failure of the verifier" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const o = try open(a, try signed(a, detached));
    var no_certificate = strong;
    no_certificate.certificate = "";
    var no_key = strong;
    no_key.key.bits = 0;
    for ([_]verify.Outcome{
        .{ .intact = no_certificate },
        .{ .intact = no_key },
        .{ .not_checked = .unsound_coverage },
        .{ .not_checked = .not_from_this_document },
    }) |answer| {
        var stub: Stub = .{ .fixed = answer };
        try expectNotChecked(try verify.check(a, o.doc, o.s, stub.verifier()), .verifier_failed);
    }
    // The verifier's own reasons are passed on.
    for ([_]verify.CannotCheck{ .unsupported_format, .unsupported_algorithm, .malformed_value, .not_one_signer, .no_signer_certificate, .verifier_failed }) |why| {
        var stub: Stub = .{ .fixed = .{ .not_checked = why } };
        try expectNotChecked(try verify.check(a, o.doc, o.s, stub.verifier()), why);
    }
}

fn checkOnce(gpa: Allocator, doc: *const pdf.Document, s: signature.Signature) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var stub: Stub = .{};
    _ = try verify.check(arena.allocator(), doc, s, stub.verifier());
}

test "a verifier that runs out of memory is an error, not an answer" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const o = try open(a, try signed(a, detached));
    try testing.checkAllAllocationFailures(testing.allocator, checkOnce, .{ o.doc, o.s });
}
