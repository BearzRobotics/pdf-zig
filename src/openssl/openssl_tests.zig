// SPDX-License-Identifier: LGPL-2.0-or-later
//! The OpenSSL backend against what every backend must answer.

const std = @import("std");
const testing = std.testing;
const openssl = @import("pdf_openssl");
const conformance = @import("conformance");

test "pdf_openssl answers the shared signed files" {
    try conformance.run(openssl.verifier());
}

test "pdf_openssl never calls changed or damaged files intact by mistake" {
    try conformance.hostile(openssl.verifier());
}
