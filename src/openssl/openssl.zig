// SPDX-License-Identifier: LGPL-2.0-or-later
//! `pdf_openssl`: a `pdf.verify.Verifier` on OpenSSL's CMS functions (3.5 or
//! later). Optional: built with `-Dopenssl=true`. A program that includes
//! OpenSSL should be distributed under LGPL version 3 or later (decision 0006).
//!
//! **It checks integrity only.** No certificate chain, purpose, date or
//! revocation is looked at, so `intact` says nothing about who signed. **The
//! certificate itself may have been swapped or edited** for another with the same
//! key, since the signature need not cover it.
//!
//! The digest reported is the signature's `digestAlgorithm`. Inside RSA-PSS
//! parameters, another digest of the mask function is not looked at.
//!
//! Handled: `adbe.pkcs7.detached` and `adbe.pkcs7.sha1`. CAdES signatures and
//! time stamps are `unsupported_format`: they need checks that are not made yet.
//!
//! The signature value is hostile input to OpenSSL's parser. Calls clear the
//! calling thread's OpenSSL error queue. The verifier has no state, so threads
//! may share it as far as OpenSSL itself allows.

const std = @import("std");
const Allocator = std.mem.Allocator;
const pdf = @import("pdf");
const c = @import("c");

const verify = pdf.verify;
const Outcome = verify.Outcome;

/// Never read: the verifier has no state.
var no_state: u8 = 0;

const vtable: verify.Verifier.VTable = .{ .name = "pdf_openssl", .verify = run };

pub fn verifier() verify.Verifier {
    return .{ .ptr = &no_state, .vtable = &vtable };
}

fn cannot(why: verify.CannotCheck) Outcome {
    return .{ .not_checked = why };
}

fn run(_: *anyopaque, a: Allocator, request: verify.Request) Allocator.Error!Outcome {
    switch (request.format) {
        .pkcs7_detached, .pkcs7_sha1 => {},
        // CAdES requires the certificate to be checked against a signed
        // attribute, which `CMS_verify` only does along with the chain. A time
        // stamp signs a digest of the bytes inside its own structure.
        .cades_detached, .rfc3161 => return cannot(.unsupported_format),
    }
    // So that what is read from the queue afterwards is this call's.
    c.ERR_clear_error();
    defer c.ERR_clear_error();

    const length = std.math.cast(c_long, request.value.len) orelse return cannot(.malformed_value);
    var next: [*c]const u8 = request.value.ptr;
    const cms = c.d2i_CMS_ContentInfo(null, &next, length) orelse return cannot(.malformed_value);
    defer c.CMS_ContentInfo_free(cms);
    const used = @intFromPtr(next) - @intFromPtr(request.value.ptr);
    if (!std.mem.allEqual(u8, request.value[used..], 0)) return cannot(.malformed_value);
    if (c.OBJ_obj2nid(c.CMS_get0_type(cms)) != c.NID_pkcs7_signed) return cannot(.malformed_value);

    // The format says where the signed content is. It decides what is checked,
    // so a value that disagrees is refused.
    const detached = c.CMS_is_detached(cms) == 1;
    if (detached != (request.format == .pkcs7_detached)) return cannot(.malformed_value);

    const signers: ?*const c.OPENSSL_STACK = @ptrCast(c.CMS_get0_SignerInfos(cms));
    if (signers == null or c.OPENSSL_sk_num(signers) != 1) return cannot(.not_one_signer);
    const info: *c.CMS_SignerInfo = @ptrCast(@alignCast(c.OPENSSL_sk_value(signers, 0).?));

    // `CMS_BINARY`: the bytes as they are, without turning line ends into
    // CR LF. The chain is not checked. **Never add the flags that leave the
    // content or the signed attributes unchecked.**
    const flags: c_uint = c.CMS_BINARY | c.CMS_NO_SIGNER_CERT_VERIFY;
    if (request.format == .pkcs7_detached) {
        var pieces: Pieces = .{ .left = request.signed };
        const method = Pieces.method() orelse return cannot(.verifier_failed);
        defer c.BIO_meth_free(method);
        const content = c.BIO_new(method) orelse return cannot(.verifier_failed);
        defer _ = c.BIO_free(content);
        c.BIO_set_data(content, &pieces);
        c.BIO_set_init(content, 1);
        if (c.CMS_verify(cms, null, null, content, null, flags) != 1) return failure();
    } else {
        // This checks the content the value carries, which is a digest ...
        if (c.CMS_verify(cms, null, null, null, null, flags) != 1) return failure();
        // ... and this that it is the digest of the signed bytes.
        const holder = c.CMS_get0_content(cms);
        if (holder == null or holder.* == null) return cannot(.malformed_value);
        const stored = holder.*;
        if (c.ASN1_STRING_length(stored) != 20) return cannot(.malformed_value);
        var digest: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
        var sha1 = std.crypto.hash.Sha1.init(.{});
        for (request.signed) |piece| sha1.update(piece);
        sha1.final(&digest);
        if (!std.mem.eql(u8, &digest, c.ASN1_STRING_get0_data(stored)[0..20])) return .altered;
    }
    return evidence(a, info);
}

/// What a failed `CMS_verify` means. Only a comparison that was made and did not
/// match is `altered`; anything else, known or not, is not a verdict.
fn failure() Outcome {
    var mismatch = false;
    var no_certificate = false;
    var unknown_digest = false;
    while (true) {
        const code = c.ERR_get_error();
        if (code == 0) break;
        if (c.ERR_GET_LIB(code) != c.ERR_LIB_CMS) continue;
        switch (c.ERR_GET_REASON(code)) {
            c.CMS_R_VERIFICATION_FAILURE => mismatch = true,
            c.CMS_R_SIGNER_CERTIFICATE_NOT_FOUND => no_certificate = true,
            c.CMS_R_UNKNOWN_DIGEST_ALGORITHM => unknown_digest = true,
            else => {},
        }
    }
    if (no_certificate) return cannot(.no_signer_certificate);
    if (unknown_digest) return cannot(.unsupported_algorithm);
    if (mismatch) return .altered;
    // OpenSSL failed for a reason not told apart here.
    return cannot(.verifier_failed);
}

/// What `intact` has to show, read from the signer that was just verified.
fn evidence(a: Allocator, info: *c.CMS_SignerInfo) Allocator.Error!Outcome {
    var public_key: ?*c.EVP_PKEY = null;
    var certificate: ?*c.X509 = null;
    var digest_algorithm: ?*c.X509_ALGOR = null;
    c.CMS_SignerInfo_get0_algs(info, @ptrCast(&public_key), @ptrCast(&certificate), @ptrCast(&digest_algorithm), null);
    if (certificate == null or digest_algorithm == null) return cannot(.verifier_failed);
    const key = c.X509_get0_pubkey(certificate) orelse return cannot(.verifier_failed);

    const size = c.i2d_X509(certificate, null);
    if (size <= 0) return cannot(.verifier_failed);
    const der = try a.alloc(u8, @intCast(size));
    var end: [*c]u8 = der.ptr;
    if (c.i2d_X509(certificate, &end) != size) return cannot(.verifier_failed);

    var oid: ?*const c.ASN1_OBJECT = null;
    c.X509_ALGOR_get0(@ptrCast(&oid), null, null, digest_algorithm);
    const bits = c.EVP_PKEY_get_bits(key);
    if (bits <= 0) return cannot(.verifier_failed);
    return .{ .intact = .{
        .certificate = der,
        .digest = digestOf(c.OBJ_obj2nid(oid)),
        .key = .{
            .kind = switch (c.EVP_PKEY_get_base_id(key)) {
                c.EVP_PKEY_RSA => .rsa,
                c.EVP_PKEY_RSA_PSS => .rsa_pss,
                c.EVP_PKEY_DSA => .dsa,
                c.EVP_PKEY_EC => .ecdsa,
                c.EVP_PKEY_ED25519 => .ed25519,
                c.EVP_PKEY_ED448 => .ed448,
                else => .other,
            },
            .bits = @intCast(bits),
        },
        .claimed_time = signingTime(info),
    } };
}

fn digestOf(nid: c_int) verify.Digest {
    return switch (nid) {
        c.NID_md5 => .md5,
        c.NID_ripemd160 => .ripemd160,
        c.NID_sha1 => .sha1,
        c.NID_sha224 => .sha224,
        c.NID_sha256 => .sha256,
        c.NID_sha384 => .sha384,
        c.NID_sha512 => .sha512,
        c.NID_sha3_256 => .sha3_256,
        c.NID_sha3_384 => .sha3_384,
        c.NID_sha3_512 => .sha3_512,
        else => .other,
    };
}

/// The `signingTime` signed attribute, in seconds since 1970.
fn signingTime(info: *c.CMS_SignerInfo) ?i64 {
    const at = c.CMS_signed_get_attr_by_NID(info, c.NID_pkcs9_signingTime, -1);
    if (at < 0) return null;
    const attribute = c.CMS_signed_get_attr(info, at) orelse return null;
    const value = c.X509_ATTRIBUTE_get0_type(attribute, 0) orelse return null;
    const kind = c.ASN1_TYPE_get(value);
    if (kind != c.V_ASN1_UTCTIME and kind != c.V_ASN1_GENERALIZEDTIME) return null;
    const time: ?*c.ASN1_TIME = @ptrCast(value.*.value.asn1_string);
    const epoch = c.ASN1_TIME_set(null, 0) orelse return null;
    defer c.ASN1_STRING_free(@ptrCast(epoch));
    var days: c_int = 0;
    var seconds: c_int = 0;
    if (c.ASN1_TIME_diff(&days, &seconds, epoch, time) != 1) return null;
    return @as(i64, days) * std.time.s_per_day + seconds;
}

/// A source that gives OpenSSL the two signed pieces without joining them,
/// which would copy nearly the whole file.
const Pieces = struct {
    left: [2][]const u8,

    fn method() ?*c.BIO_METHOD {
        const made = c.BIO_meth_new(c.BIO_TYPE_SOURCE_SINK, "pdf signed bytes") orelse return null;
        if (c.BIO_meth_set_read_ex(made, read) != 1 or c.BIO_meth_set_ctrl(made, control) != 1) {
            c.BIO_meth_free(made);
            return null;
        }
        return made;
    }

    fn read(bio: ?*c.BIO, out: [*c]u8, len: usize, done: [*c]usize) callconv(.c) c_int {
        const self: *Pieces = @ptrCast(@alignCast(c.BIO_get_data(bio).?));
        for (&self.left) |*piece| {
            if (piece.len == 0) continue;
            const n = @min(len, piece.len);
            @memcpy(out[0..n], piece.*[0..n]);
            piece.* = piece.*[n..];
            done.* = n;
            return 1;
        }
        done.* = 0;
        return 0;
    }

    fn control(bio: ?*c.BIO, command: c_int, _: c_long, _: ?*anyopaque) callconv(.c) c_long {
        if (command != c.BIO_CTRL_EOF) return 0;
        const self: *Pieces = @ptrCast(@alignCast(c.BIO_get_data(bio).?));
        return @intFromBool(self.left[0].len == 0 and self.left[1].len == 0);
    }
};
