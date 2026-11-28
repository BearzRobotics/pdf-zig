// SPDX-License-Identifier: LGPL-2.0-or-later
//! Checking that a signature's signed bytes are unaltered, through a verifier
//! that the program supplies (ISO 32000-1 12.8; decision 0006, step S2).
//! pdf-zig does no cryptography itself.
//!
//! **Experimental:** with no second implementation yet, this interface may
//! change.
//!
//! **`intact` does not mean valid, and says nothing about who signed.** It means
//! that the holder of the private key for the certificate in the report signed
//! these bytes. Anyone can make a certificate in any name. Whether to trust it
//! (its chain, revocation and the time) is not checked.
//!
//! **A verifier is trusted completely.** `check` decides what it is asked and
//! which answers it takes, but cannot tell whether an answer is true.

const std = @import("std");
const Allocator = std.mem.Allocator;
const document = @import("document.zig");
const signature = @import("signature.zig");
const object = @import("object.zig");

const Document = document.Document;
const Signature = signature.Signature;

/// The signature formats a verifier is asked about, from `/SubFilter`.
pub const Format = enum {
    /// `adbe.pkcs7.detached`: CMS over the signed bytes.
    pkcs7_detached,
    /// `adbe.pkcs7.sha1`: the CMS holds the SHA-1 digest of the signed bytes as
    /// its content.
    pkcs7_sha1,
    /// `ETSI.CAdES.detached`.
    cades_detached,
    /// `ETSI.RFC3161`: a time-stamp token over the signed bytes.
    rfc3161,

    // `adbe.x509.rsa_sha1` is left out: its certificate is in the dictionary's
    // `/Cert`, which is not read yet.

    pub fn fromSubFilter(name: []const u8) ?Format {
        for ([_]struct { []const u8, Format }{
            .{ "adbe.pkcs7.detached", .pkcs7_detached },
            .{ "adbe.pkcs7.sha1", .pkcs7_sha1 },
            .{ "ETSI.CAdES.detached", .cades_detached },
            .{ "ETSI.RFC3161", .rfc3161 },
        }) |known| {
            if (std.mem.eql(u8, name, known[0])) return known[1];
        }
        return null;
    }
};

/// What a verifier is handed. Both borrow from the document and the signature,
/// and last only for the call. **All of it comes from an untrusted file.**
pub const Request = struct {
    format: Format,
    /// The signature value as the file holds it. It is usually longer than the
    /// structure in it, padded with zeros. A verifier must accept zeros after
    /// the structure and nothing else. Real files encode it in BER, often with
    /// indefinite lengths, so a reader of strict DER is not enough.
    value: []const u8,
    /// The signed bytes: these two pieces, one after the other.
    signed: [2][]const u8,
};

pub const Digest = enum { md5, ripemd160, sha1, sha224, sha256, sha384, sha512, sha3_256, sha3_384, sha3_512, other };

pub const Key = struct {
    kind: enum { rsa, rsa_pss, dsa, ecdsa, ed25519, ed448, other },
    /// The size of the key: for RSA and DSA the modulus, for elliptic curves
    /// the order of the group.
    bits: u32,
};

/// What a verifier must show to say that a signature is intact.
pub const Evidence = struct {
    /// The signer's certificate, DER: the one whose key was used. **Nothing
    /// says it is genuine**, so the names in it are claims.
    certificate: []const u8,
    /// The weakest digest that the result depends on.
    digest: Digest,
    key: Key,
    /// The signing time among the signed attributes, in seconds since 1970 UTC.
    /// **The signer wrote it**; no time stamp is checked.
    claimed_time: ?i64 = null,
};

/// Why integrity was not checked. This says nothing against the signature, and
/// nothing for it.
pub const CannotCheck = enum {
    /// The coverage is unsound, so a result would say nothing about a known part
    /// of the file. Set by `check`: the verifier is not asked.
    unsound_coverage,
    /// The signature is not of these document bytes. Set by `check`.
    not_from_this_document,
    /// A format that `check` or the verifier does not handle.
    unsupported_format,
    /// A digest, key or signature algorithm the verifier does not handle, or
    /// that its library refuses.
    unsupported_algorithm,
    /// The value cannot be read as the format says.
    malformed_value,
    /// There is not exactly one signer.
    not_one_signer,
    /// The signer's certificate is not in the value.
    no_signer_certificate,
    /// The verifier failed, or gave an answer that cannot be right.
    verifier_failed,
};

/// What a verifier answers.
pub const Outcome = union(enum) {
    /// The signature over these bytes checks out with the key in the
    /// certificate. It must be the answer only if both the digest of the signed
    /// bytes and the signature itself were checked.
    intact: Evidence,
    /// The check was made and failed: the bytes are not the ones signed, or the
    /// signature is not that key's. **Never the answer when something could not
    /// be checked.**
    altered,
    not_checked: CannotCheck,
};

/// A signature verification backend.
pub const Verifier = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Names the backend in reports. It must outlive them.
        name: []const u8,
        /// Checks that `request.value` has exactly one signer and signs the
        /// bytes of `request.signed`. It does not judge the certificate.
        /// Whatever the answer holds is allocated from `a`, an arena, and does
        /// not borrow from the backend. It keeps nothing of `request`.
        verify: *const fn (ptr: *anyopaque, a: Allocator, request: Request) Allocator.Error!Outcome,
    };
};

/// Algorithms too weak to rely on, whatever the verifier says. pdf-zig decides
/// this, so that it does not differ between verifiers.
pub const Weaknesses = struct {
    /// MD5, RIPEMD-160 or SHA-1, in the signature or required by its format.
    digest: bool = false,
    /// RSA or DSA below 2048 bits, or an elliptic curve below 224.
    key: bool = false,

    pub fn any(self: Weaknesses) bool {
        return self.digest or self.key;
    }
};

/// Separate answers, on purpose: **there is no single "valid".** The signer's
/// chain and revocation are not checked at all.
pub const Report = struct {
    /// The verifier's name.
    verifier: []const u8,
    coverage: signature.Coverage,
    integrity: Outcome,
    /// What changed after signing. **An intact signature of an earlier revision
    /// says nothing about what follows it.**
    after: signature.After,
    /// Without an intact signature, only what the format itself requires.
    weak: Weaknesses,
};

fn weakDigest(digest: Digest) bool {
    return switch (digest) {
        .md5, .ripemd160, .sha1 => true,
        else => false,
    };
}

fn weakKey(key: Key) bool {
    return switch (key.kind) {
        .rsa, .rsa_pss, .dsa => key.bits < 2048,
        .ecdsa => key.bits < 224,
        .ed25519, .ed448, .other => false,
    };
}

/// The signed pieces of `s` in the bytes of `doc`, if `s` can be one of its
/// signatures: a `Signature` is plain data that could come from another file.
fn signedPieces(doc: *const Document, s: Signature) ?[2][]const u8 {
    const sound = switch (s.coverage) {
        .sound => |c| c,
        .unsound => return null,
    };
    const start, const first, const second, const rest = sound.byte_range;
    if (start != 0 or first >= second or second > sound.end or sound.end > doc.data.len) return null;
    if (sound.end - second != rest) return null;
    // What is left out must be this value, in hexadecimal.
    const gap = doc.data[first..second];
    if (gap.len < 2 or gap[0] != '<' or gap[gap.len - 1] != '>') return null;
    const digits = gap[1 .. gap.len - 1];
    if (digits.len % 2 != 0 or digits.len / 2 != s.value.len) return null;
    for (s.value, 0..) |byte, i| {
        const there = std.fmt.parseInt(u8, digits[2 * i ..][0..2], 16) catch return null;
        if (there != byte) return null;
    }
    return .{ doc.data[0..first], doc.data[second..sound.end] };
}

/// Asks `verifier` whether the signed bytes of `s`, one of `signature.list`'s
/// results for `doc`, are unaltered. Allocate from an arena; the report also
/// refers to what `s` refers to.
pub fn check(a: Allocator, doc: *const Document, s: Signature, verifier: Verifier) Allocator.Error!Report {
    var report: Report = .{
        .verifier = verifier.vtable.name,
        .coverage = s.coverage,
        .integrity = .{ .not_checked = .unsound_coverage },
        .after = s.after,
        .weak = .{},
    };
    const format: ?Format = if (s.sub_filter) |name| Format.fromSubFilter(name) else null;
    if (format == .pkcs7_sha1) report.weak.digest = true;
    if (s.coverage != .sound) return report;

    const pieces = signedPieces(doc, s) orelse {
        report.integrity = .{ .not_checked = .not_from_this_document };
        // Nothing the caller passed in describes this document.
        report.after = .unknown;
        return report;
    };
    const known = format orelse {
        report.integrity = .{ .not_checked = .unsupported_format };
        return report;
    };
    var answer = try verifier.vtable.verify(verifier.ptr, a, .{ .format = known, .value = s.value, .signed = pieces });
    switch (answer) {
        .intact => |evidence| {
            if (evidence.certificate.len == 0 or evidence.key.bits == 0) {
                answer = .{ .not_checked = .verifier_failed };
            } else {
                if (weakDigest(evidence.digest)) report.weak.digest = true;
                report.weak.key = weakKey(evidence.key);
            }
        },
        .altered => {},
        .not_checked => |why| switch (why) {
            // Only `check` can know these.
            .unsound_coverage, .not_from_this_document => answer = .{ .not_checked = .verifier_failed },
            else => {},
        },
    }
    report.integrity = answer;
    return report;
}
