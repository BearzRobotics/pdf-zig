// SPDX-License-Identifier: LGPL-2.0-or-later
//! What every verification backend must answer, on signed files made by
//! `make_fixtures.py`. A backend's tests call `run` and `hostile`.
//!
//! The expected answers assume a backend with what `pdf_openssl` has. One that
//! lacks more would need its own expectations, never fewer cases.

const std = @import("std");
const pdf = @import("pdf");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const verify = pdf.verify;
const signature = pdf.signature;

const Expected = union(enum) {
    intact: struct {
        digest: verify.Digest = .sha256,
        key: @FieldType(verify.Key, "kind") = .rsa,
        bits: u32 = 2048,
        weak_digest: bool = false,
        weak_key: bool = false,
        timed: bool = true,
    },
    altered,
    not_checked: verify.CannotCheck,
};

const Case = struct { name: []const u8, bytes: []const u8, expected: Expected };

fn case(comptime name: []const u8, expected: Expected) Case {
    return .{ .name = name, .bytes = @embedFile(name ++ ".pdf"), .expected = expected };
}

const cases = [_]Case{
    case("rsa", .{ .intact = .{} }),
    case("ecdsa", .{ .intact = .{ .digest = .sha384, .key = .ecdsa, .bits = 256 } }),
    case("rsa_pss", .{ .intact = .{} }),
    case("sha1", .{ .intact = .{ .digest = .sha1, .weak_digest = true } }),
    case("short_key", .{ .intact = .{ .bits = 1024, .weak_key = true } }),
    case("ber", .{ .intact = .{} }),
    // Without signed attributes there is no signing time.
    case("no_attributes", .{ .intact = .{ .timed = false } }),
    case("pkcs7_sha1", .{ .intact = .{ .weak_digest = true } }),
    case("pkcs7_sha1_other", .altered),
    case("pkcs7_sha1_detached", .{ .not_checked = .malformed_value }),
    case("two_signers", .{ .not_checked = .not_one_signer }),
    case("no_certificate", .{ .not_checked = .no_signer_certificate }),
    case("attached", .{ .not_checked = .malformed_value }),
    case("attached_same", .{ .not_checked = .malformed_value }),
};

fn check(a: Allocator, bytes: []const u8, verifier: verify.Verifier) !verify.Report {
    const doc = try a.create(pdf.Document);
    doc.* = try pdf.Document.open(a, bytes, .{});
    const found = try signature.list(a, doc, try pdf.pages.PageList.build(doc), .{});
    try testing.expectEqual(@as(usize, 1), found.len);
    try testing.expect(found[0].coverage == .sound);
    return verify.check(a, doc, found[0], verifier);
}

/// Where the hexadecimal digits of the value are.
fn valueDigits(bytes: []const u8) []const u8 {
    const start = std.mem.indexOf(u8, bytes, "/Contents <").? + "/Contents <".len;
    return bytes[start..std.mem.indexOfScalarPos(u8, bytes, start, '>').?];
}

/// The answer for each file as it is.
pub fn run(verifier: verify.Verifier) !void {
    for (cases) |item| {
        errdefer std.debug.print("backend case {s}\n", .{item.name});
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const report = try check(arena.allocator(), item.bytes, verifier);
        switch (item.expected) {
            .altered => try testing.expectEqual(verify.Outcome.altered, report.integrity),
            .not_checked => |why| try testing.expectEqual(verify.Outcome{ .not_checked = why }, report.integrity),
            .intact => |want| {
                try testing.expectEqualStrings("intact", @tagName(report.integrity));
                const got = report.integrity.intact;
                try testing.expectEqual(want.digest, got.digest);
                try testing.expectEqual(want.key, got.key.kind);
                try testing.expectEqual(want.bits, got.key.bits);
                try testing.expectEqual(want.weak_digest, report.weak.digest);
                try testing.expectEqual(want.weak_key, report.weak.key);
                // A DER certificate that names the test signer.
                try testing.expectEqual(@as(u8, 0x30), got.certificate[0]);
                try testing.expect(std.mem.indexOf(u8, got.certificate, "pdf-zig test ") != null);
                // The files were made in 2020 or later.
                try testing.expectEqual(want.timed, got.claimed_time != null);
                if (got.claimed_time) |time| try testing.expect(time > 1_577_836_800 and time < 4_102_444_800);
            },
        }
    }
}

/// Files that were changed after signing must never come out intact, and no
/// damage to a value may crash.
pub fn hostile(verifier: verify.Verifier) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    for (cases) |item| {
        if (item.expected != .intact) continue;
        errdefer std.debug.print("backend case {s}\n", .{item.name});
        // A changed byte in either signed piece.
        for ([_][]const u8{ "/MediaBox [0 0 200", "trailer\n<< /Size 6" }) |near| {
            const changed = try a.dupe(u8, item.bytes);
            const at = std.mem.indexOf(u8, changed, near).? + near.len - 1;
            changed[at] = if (changed[at] == '7') '8' else '7';
            const report = try check(a, changed, verifier);
            try testing.expectEqual(verify.Outcome.altered, report.integrity);
        }
    }

    const good = cases[0].bytes;
    const digits = valueDigits(good);
    const at = @intFromPtr(digits.ptr) - @intFromPtr(good.ptr);
    var used = digits.len;
    while (digits[used - 1] == '0') used -= 1;
    used += used % 2;

    const changed = try a.dupe(u8, good);
    const value = changed[at..][0..digits.len];
    const expectNot = struct {
        fn intact(alloc: Allocator, bytes: []const u8, with: verify.Verifier) !verify.Outcome {
            const report = try check(alloc, bytes, with);
            try testing.expect(report.integrity != .intact);
            return report.integrity;
        }
    }.intact;

    // Something other than zeros after the structure.
    value[value.len - 1] = '1';
    try testing.expectEqual(verify.Outcome{ .not_checked = .malformed_value }, try expectNot(a, changed, verifier));
    // The signature itself changed: its last byte ends the structure.
    @memcpy(value, digits);
    value[used - 1] = if (value[used - 1] == '1') '2' else '1';
    try testing.expectEqual(verify.Outcome.altered, try expectNot(a, changed, verifier));
    // Cut short, and not a signature at all.
    for ([_]usize{ 2, 8, used / 4, used / 2, used - 2 }) |keep| {
        @memcpy(value, digits);
        @memset(value[keep..], '0');
        value[0] = '3';
        _ = try expectNot(a, changed, verifier);
    }
    @memset(value, 'F');
    try testing.expectEqual(verify.Outcome{ .not_checked = .malformed_value }, try expectNot(a, changed, verifier));

    // Seeded damage to the values. Some of a value is not signed (the
    // certificate, for one), so it may still be intact: the signed bytes are.
    var prng = std.Random.DefaultPrng.init(0x52);
    const random = prng.random();
    for ([_][]const u8{ good, cases[5].bytes, cases[7].bytes }) |source| {
        const length = valueDigits(source).len;
        const from = @intFromPtr(valueDigits(source).ptr) - @intFromPtr(source.ptr);
        var end = length;
        while (source[from + end - 1] == '0') end -= 1;
        const copy = try a.dupe(u8, source);
        for (0..1500) |_| {
            @memcpy(copy, source);
            for (0..random.intRangeAtMost(usize, 1, 4)) |_| {
                copy[from + random.uintLessThan(usize, end)] = "0123456789ABCDEF"[random.uintLessThan(usize, 16)];
            }
            var each = std.heap.ArenaAllocator.init(testing.allocator);
            defer each.deinit();
            _ = try check(each.allocator(), copy, verifier);
        }
    }
}
