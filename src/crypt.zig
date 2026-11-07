//! The standard security handler (ISO 32000-1:2008, 7.6; AES-256 from ISO
//! 32000-2:2020, 7.6.4): RC4 with 40 to 128 bit keys (V1, V2), AES-128 (V4,
//! `AESV2`) and AES-256 (V5, revisions 5 and 6, `AESV3`).
//!
//! The user password is checked (the empty password by default); the owner
//! password is not used. Public-key security handlers are not supported.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Md5 = std.crypto.hash.Md5;
const Sha256 = std.crypto.hash.sha2.Sha256;
const Sha384 = std.crypto.hash.sha2.Sha384;
const Sha512 = std.crypto.hash.sha2.Sha512;
const Aes128 = std.crypto.core.aes.Aes128;
const Aes256 = std.crypto.core.aes.Aes256;
const object = @import("object.zig");
const Object = object.Object;
const Dict = object.Dict;

pub const Error = error{
    /// The handler or its version/revision is not one this library reads.
    UnsupportedEncryption,
    /// The password does not open the document.
    PasswordRequired,
    OutOfMemory,
};

pub const Method = enum { none, rc4, aes128, aes256 };

const padding = [32]u8{
    0x28, 0xBF, 0x4E, 0x5E, 0x4E, 0x75, 0x8A, 0x41, 0x64, 0x00, 0x4E, 0x56, 0xFF, 0xFA, 0x01, 0x08,
    0x2E, 0x2E, 0x00, 0xB6, 0xD0, 0x68, 0x3E, 0x80, 0x2F, 0x0C, 0xA9, 0xFE, 0x64, 0x53, 0x69, 0x7A,
};

pub const Crypt = struct {
    /// The file encryption key (5 to 16 bytes, or 32 for AES-256).
    key: [32]u8 = @splat(0),
    key_len: usize = 0,
    stream_method: Method = .rc4,
    string_method: Method = .rc4,
    encrypt_metadata: bool = true,
    /// The object that holds the encryption dictionary: never decrypted.
    encrypt_obj: u32 = 0,

    /// Reads the encryption dictionary `d` (values already resolved by the
    /// caller where they are references) and derives the file key. `id0` is
    /// the first element of the trailer's `/ID` (empty if there is none).
    pub fn init(d: Dict, resolve_ctx: anytype, id0: []const u8, password: []const u8) Error!Crypt {
        const filter = (resolve_ctx.name(d, "Filter") orelse "Standard");
        if (!std.mem.eql(u8, filter, "Standard")) return error.UnsupportedEncryption;
        const v = resolve_ctx.int(d, "V") orelse 0;
        const r = resolve_ctx.int(d, "R") orelse return error.UnsupportedEncryption;
        var c: Crypt = .{};
        c.encrypt_metadata = if (resolve_ctx.boolean(d, "EncryptMetadata")) |b| b else true;

        if (v == 5) {
            if (r != 5 and r != 6) return error.UnsupportedEncryption;
            const u = resolve_ctx.string(d, "U") orelse return error.UnsupportedEncryption;
            const ue = resolve_ctx.string(d, "UE") orelse return error.UnsupportedEncryption;
            if (u.len < 48 or ue.len < 32) return error.UnsupportedEncryption;
            const pw = password[0..@min(password.len, 127)];
            const vsalt = u[32..40];
            const ksalt = u[40..48];
            var check: [32]u8 = undefined;
            hashV5(&check, r, pw, vsalt, "");
            if (!std.mem.eql(u8, &check, u[0..32])) return error.PasswordRequired;
            var inter: [32]u8 = undefined;
            hashV5(&inter, r, pw, ksalt, "");
            // The file key: UE decrypted with the intermediate key, AES-256-CBC, zero IV, no padding.
            const dec = Aes256.initDec(inter);
            var prev: [16]u8 = @splat(0);
            for (0..2) |i| {
                var block: [16]u8 = undefined;
                dec.decrypt(&block, ue[i * 16 ..][0..16]);
                for (0..16) |k| block[k] ^= prev[k];
                @memcpy(c.key[i * 16 ..][0..16], &block);
                @memcpy(&prev, ue[i * 16 ..][0..16]);
            }
            c.key_len = 32;
            c.stream_method = .aes256;
            c.string_method = .aes256;
            return c;
        }
        if (v != 1 and v != 2 and v != 4) return error.UnsupportedEncryption;
        if (r < 2 or r > 4) return error.UnsupportedEncryption;
        const o = resolve_ctx.string(d, "O") orelse return error.UnsupportedEncryption;
        const u = resolve_ctx.string(d, "U") orelse return error.UnsupportedEncryption;
        if (o.len < 32 or u.len < 32) return error.UnsupportedEncryption;
        const p: i32 = @truncate(resolve_ctx.int(d, "P") orelse 0);

        var key_len: usize = 5;
        if (v == 2) key_len = @intCast(std.math.clamp(@divTrunc(resolve_ctx.int(d, "Length") orelse 40, 8), 5, 16));
        c.stream_method = .rc4;
        c.string_method = .rc4;
        if (v == 4) {
            key_len = 16;
            c.stream_method = resolve_ctx.cryptFilter(d, "StmF");
            c.string_method = resolve_ctx.cryptFilter(d, "StrF");
        } else if (v == 1) key_len = 5;

        // Algorithm 2: the file key from the password.
        var pw_padded: [32]u8 = undefined;
        const n = @min(password.len, 32);
        @memcpy(pw_padded[0..n], password[0..n]);
        @memcpy(pw_padded[n..], padding[0 .. 32 - n]);
        var h = Md5.init(.{});
        h.update(&pw_padded);
        h.update(o[0..32]);
        var pb: [4]u8 = undefined;
        std.mem.writeInt(i32, &pb, p, .little);
        h.update(&pb);
        h.update(id0);
        if (r >= 4 and !c.encrypt_metadata) h.update(&[4]u8{ 0xFF, 0xFF, 0xFF, 0xFF });
        var digest: [16]u8 = undefined;
        h.final(&digest);
        if (r >= 3) {
            for (0..50) |_| Md5.hash(digest[0..key_len], &digest, .{});
        }
        @memcpy(c.key[0..key_len], digest[0..key_len]);
        c.key_len = key_len;

        // Algorithms 4 to 6: check the password against /U.
        if (r == 2) {
            var enc: [32]u8 = padding;
            rc4(c.key[0..key_len], &enc);
            if (!std.mem.eql(u8, &enc, u[0..32])) return error.PasswordRequired;
        } else {
            var hh = Md5.init(.{});
            hh.update(&padding);
            hh.update(id0);
            var x: [16]u8 = undefined;
            hh.final(&x);
            var k2: [16]u8 = undefined;
            for (0..20) |i| {
                for (0..key_len) |j| k2[j] = c.key[j] ^ @as(u8, @intCast(i));
                rc4(k2[0..key_len], &x);
            }
            if (!std.mem.eql(u8, &x, u[0..16])) return error.PasswordRequired;
        }
        return c;
    }

    /// The key for object `num gen` (algorithm 1), or the file key for AES-256.
    fn objectKey(self: Crypt, num: u32, gen: u16, method: Method, out: *[32]u8) usize {
        if (method == .aes256) {
            @memcpy(out, &self.key);
            return 32;
        }
        var h = Md5.init(.{});
        h.update(self.key[0..self.key_len]);
        h.update(&[5]u8{ @truncate(num), @truncate(num >> 8), @truncate(num >> 16), @truncate(gen), @truncate(gen >> 8) });
        if (method == .aes128) h.update("sAlT");
        var digest: [16]u8 = undefined;
        h.final(&digest);
        const n = @min(self.key_len + 5, 16);
        @memcpy(out[0..n], digest[0..n]);
        return n;
    }

    pub fn decrypt(self: Crypt, a: Allocator, method: Method, num: u32, gen: u16, data: []const u8) Allocator.Error![]const u8 {
        if (method == .none) return data;
        var key: [32]u8 = undefined;
        const klen = self.objectKey(num, gen, method, &key);
        switch (method) {
            .none => return data,
            .rc4 => {
                const out = try a.dupe(u8, data);
                rc4(key[0..klen], out);
                return out;
            },
            .aes128, .aes256 => {
                if (data.len < 32 or data.len % 16 != 0) {
                    // Shorter than IV plus one block: nothing to decrypt.
                    if (data.len < 32) return "";
                }
                const body = data[16 .. 16 + (data.len - 16) / 16 * 16];
                const out = try a.alloc(u8, body.len);
                var prev: [16]u8 = data[0..16].*;
                if (method == .aes128) {
                    const dec = Aes128.initDec(key[0..16].*);
                    cbcDecrypt(Aes128, dec, &prev, body, out);
                } else {
                    const dec = Aes256.initDec(key[0..32].*);
                    cbcDecrypt(Aes256, dec, &prev, body, out);
                }
                // PKCS#5 padding: the last byte is the pad length.
                if (out.len == 0) return out;
                const pad = out[out.len - 1];
                if (pad >= 1 and pad <= 16 and pad <= out.len) return out[0 .. out.len - pad];
                return out;
            },
        }
    }
};

fn cbcDecrypt(comptime Aes: type, ctx: anytype, iv: *[16]u8, src: []const u8, dst: []u8) void {
    _ = Aes;
    var prev = iv.*;
    var i: usize = 0;
    while (i + 16 <= src.len) : (i += 16) {
        var block: [16]u8 = undefined;
        ctx.decrypt(&block, src[i..][0..16]);
        for (0..16) |k| dst[i + k] = block[k] ^ prev[k];
        @memcpy(&prev, src[i..][0..16]);
    }
}

fn rc4(key: []const u8, data: []u8) void {
    var s: [256]u8 = undefined;
    for (&s, 0..) |*b, i| b.* = @intCast(i);
    var j: u8 = 0;
    for (0..256) |i| {
        j +%= s[i] +% key[i % key.len];
        std.mem.swap(u8, &s[i], &s[j]);
    }
    var a: u8 = 0;
    var b: u8 = 0;
    for (data) |*byte| {
        a +%= 1;
        b +%= s[a];
        std.mem.swap(u8, &s[a], &s[b]);
        byte.* ^= s[s[a] +% s[b]];
    }
}

/// Algorithm 2.A/2.B hash of revisions 5 and 6: `out = H(password + salt + udata)`.
fn hashV5(out: *[32]u8, r: i64, pw: []const u8, salt: []const u8, udata: []const u8) void {
    var h = Sha256.init(.{});
    h.update(pw);
    h.update(salt);
    h.update(udata);
    var k: [64]u8 = undefined;
    h.final(k[0..32]);
    if (r == 5) {
        @memcpy(out, k[0..32]);
        return;
    }
    // Revision 6 (algorithm 2.B): 64 or more rounds of AES-128-CBC and a hash
    // chosen by the data itself.
    var klen: usize = 32;
    var e_last: u8 = 0;
    var i: usize = 0;
    var buf: [(127 + 64 + 48) * 64]u8 = undefined;
    while (i < 64 or @as(i32, e_last) > @as(i32, @intCast(i)) - 32) : (i += 1) {
        // K1 is (password + K + udata) repeated 64 times.
        const unit = pw.len + klen + udata.len;
        var pos: usize = 0;
        for (0..64) |_| {
            @memcpy(buf[pos..][0..pw.len], pw);
            pos += pw.len;
            @memcpy(buf[pos..][0..klen], k[0..klen]);
            pos += klen;
            @memcpy(buf[pos..][0..udata.len], udata);
            pos += udata.len;
        }
        std.debug.assert(pos == unit * 64);
        const enc = Aes128.initEnc(k[0..16].*);
        var prev: [16]u8 = k[16..32].*;
        var off: usize = 0;
        while (off < pos) : (off += 16) {
            var block: [16]u8 = undefined;
            for (0..16) |q| block[q] = buf[off + q] ^ prev[q];
            enc.encrypt(&prev, &block);
            @memcpy(buf[off..][0..16], &prev);
        }
        // The first 16 bytes of E as a big-endian number, mod 3, pick the hash.
        var sum: u32 = 0;
        for (buf[0..16]) |bb| sum += bb;
        switch (sum % 3) {
            0 => {
                Sha256.hash(buf[0..pos], k[0..32], .{});
                klen = 32;
            },
            1 => {
                Sha384.hash(buf[0..pos], k[0..48], .{});
                klen = 48;
            },
            else => {
                Sha512.hash(buf[0..pos], k[0..64], .{});
                klen = 64;
            },
        }
        e_last = buf[pos - 1];
    }
    @memcpy(out, k[0..32]);
}

test "RC4 test vector" {
    // RFC 6229: key 0102030405, first keystream bytes b2 39 63 05 f0 3d c0 27.
    var data: [8]u8 = @splat(0);
    rc4(&.{ 1, 2, 3, 4, 5 }, &data);
    try std.testing.expectEqualSlices(u8, &.{ 0xb2, 0x39, 0x63, 0x05, 0xf0, 0x3d, 0xc0, 0x27 }, &data);
}

test "AES-128 CBC decryption of a known message" {
    // NIST SP 800-38A F.2.2: CBC-AES128.Decrypt, first block.
    const key = [16]u8{ 0x2b, 0x7e, 0x15, 0x16, 0x28, 0xae, 0xd2, 0xa6, 0xab, 0xf7, 0x15, 0x88, 0x09, 0xcf, 0x4f, 0x3c };
    var iv = [16]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 };
    const ct = [16]u8{ 0x76, 0x49, 0xab, 0xac, 0x81, 0x19, 0xb2, 0x46, 0xce, 0xe9, 0x8e, 0x9b, 0x12, 0xe9, 0x19, 0x7d };
    var pt: [16]u8 = undefined;
    cbcDecrypt(Aes128, Aes128.initDec(key), &iv, &ct, &pt);
    const want = [16]u8{ 0x6b, 0xc1, 0xbe, 0xe2, 0x2e, 0x40, 0x9f, 0x96, 0xe9, 0x3d, 0x7e, 0x11, 0x73, 0x93, 0x17, 0x2a };
    try std.testing.expectEqualSlices(u8, &want, &pt);
}
