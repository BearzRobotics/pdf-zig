// SPDX-License-Identifier: LGPL-2.0-or-later
//! pdf-zig build script. `zig build test` runs the tests; with `-Dopenssl=true`
//! also those of the `pdf_openssl` module, which needs OpenSSL 3.5 or later.
//! A change is only tested when both pass.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The library module, importable by consumers as @import("pdf").
    const mod = b.addModule("pdf", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // The optional signature verifier. A dependent asks for it with the same
    // option: `b.dependency("pdf", .{ .openssl = true })`.
    const with_openssl = b.option(bool, "openssl", "Build pdf_openssl, which verifies signatures with OpenSSL 3.5 or later") orelse false;
    const openssl_mod: ?*std.Build.Module = if (with_openssl) openssl: {
        const headers = b.addTranslateC(.{
            .root_source_file = b.path("src/openssl/c.h"),
            .target = target,
            .optimize = optimize,
        }).createModule();
        headers.linkSystemLibrary("crypto", .{});
        break :openssl b.addModule("pdf_openssl", .{
            .root_source_file = b.path("src/openssl/openssl.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{ .{ .name = "pdf", .module = mod }, .{ .name = "c", .module = headers } },
        });
    } else null;

    // A small program for trying the library out: `zig build` then `zig-out/bin/pdfinfo FILE`.
    const pdfinfo = b.addExecutable(.{
        .name = "pdfinfo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/pdfinfo.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "pdf", .module = mod }},
        }),
    });
    b.installArtifact(pdfinfo);

    const pdftext = b.addExecutable(.{
        .name = "pdftext",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/pdftext.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "pdf", .module = mod }},
        }),
    });
    b.installArtifact(pdftext);

    const pdfdump = b.addExecutable(.{
        .name = "pdfdump",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/pdfdump.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "pdf", .module = mod }},
        }),
    });
    b.installArtifact(pdfdump);

    const pdfmark = b.addExecutable(.{
        .name = "pdfmark",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/pdfmark.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "pdf", .module = mod }},
        }),
    });
    b.installArtifact(pdfmark);

    const pdffill = b.addExecutable(.{
        .name = "pdffill",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/pdffill.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "pdf", .module = mod }},
        }),
    });
    b.installArtifact(pdffill);

    const pdfsvg = b.addExecutable(.{
        .name = "pdfsvg",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/pdfsvg.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "pdf", .module = mod }},
        }),
    });
    b.installArtifact(pdfsvg);

    const pdfimg = b.addExecutable(.{
        .name = "pdfimg",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/pdfimg.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "pdf", .module = mod }},
        }),
    });
    b.installArtifact(pdfimg);

    const pdfpages = b.addExecutable(.{
        .name = "pdfpages",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/pdfpages.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "pdf", .module = mod }},
        }),
    });
    b.installArtifact(pdfpages);

    const pdfsurvey = b.addExecutable(.{
        .name = "pdfsurvey",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/pdfsurvey.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "pdf", .module = mod }},
        }),
    });
    b.installArtifact(pdfsurvey);

    const pdfdraw = b.addExecutable(.{
        .name = "pdfdraw",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/pdfdraw.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "pdf", .module = mod }},
        }),
    });
    b.installArtifact(pdfdraw);

    const pdfstamp = b.addExecutable(.{
        .name = "pdfstamp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/pdfstamp.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "pdf", .module = mod }},
        }),
    });
    b.installArtifact(pdfstamp);
    const pdfsigs = b.addExecutable(.{
        .name = "pdfsigs",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/pdfsigs.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "pdf", .module = mod }},
        }),
    });
    b.installArtifact(pdfsigs);
    // With OpenSSL, `pdfsigs` also says whether the signed bytes are unaltered.
    const sigs_options = b.addOptions();
    sigs_options.addOption(bool, "openssl", with_openssl);
    pdfsigs.root_module.addOptions("build_options", sigs_options);
    if (openssl_mod) |backend| pdfsigs.root_module.addImport("pdf_openssl", backend);

    // Encrypted sample files for the tests (made with qpdf; see test/fixtures/README.md).
    for ([_][]const u8{
        "plain",          "enc_rc4_40",         "enc_rc4_128",          "enc_aes_128",           "enc_aes_256",
        "enc_aes_256_pw", "enc_rc4_128_pw",     "enc_rc4_40_pw",        "enc_rc4_v4_clearmeta",  "enc_aes_128_clearmeta",
        "enc_aes_256_r5", "enc_aes_128_objstm", "enc_rc4_r3_pdfdoc_pw", "enc_aes_128_pdfdoc_pw", "enc_aes_256_mapped_pw",
    }) |name| {
        mod.addAnonymousImport(b.fmt("{s}.pdf", .{name}), .{ .root_source_file = b.path(b.fmt("test/fixtures/{s}.pdf", .{name})) });
    }

    // CCITT fax samples (Ghostscript tiffg3/tiffg32d/tiffg4 output wrapped in a PDF) and the
    // bitmap Ghostscript renders for the same page; see test/fixtures/README.md.
    for ([_][]const u8{ "jpeg_rgb.jpg", "jpeg_progressive.jpg", "jpeg_gray.jpg", "jpeg_cmyk.jpg", "fax_g3_1d.pdf", "fax_g3_2d.pdf", "fax_g4.pdf", "fax_ref.pbm", "lzw_libtiff.bin", "fax_runs.bin" }) |name| {
        mod.addAnonymousImport(name, .{ .root_source_file = b.path(b.fmt("test/fixtures/{s}", .{name})) });
    }

    const test_step = b.step("test", "Run unit tests and compile the example programs");
    // A change that breaks an example must fail the tests too.
    for ([_]*std.Build.Step.Compile{ pdfinfo, pdftext, pdfdump, pdfmark, pdffill, pdfsvg, pdfimg, pdfpages, pdfsurvey, pdfdraw, pdfstamp, pdfsigs }) |example| {
        test_step.dependOn(&example.step);
    }
    const unit = b.addTest(.{ .root_module = mod });
    test_step.dependOn(&b.addRunArtifact(unit).step);

    if (openssl_mod) |backend| {
        // The files and expected answers that every verification backend shares.
        const conformance = b.createModule(.{
            .root_source_file = b.path("test/backend/conformance.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "pdf", .module = mod }},
        });
        for ([_][]const u8{
            "rsa",           "ecdsa",               "rsa_pss",          "sha1",        "short_key",      "ber",
            "no_attributes", "pkcs7_sha1",          "pkcs7_sha1_other", "two_signers", "no_certificate", "attached",
            "attached_same", "pkcs7_sha1_detached",
        }) |name| {
            conformance.addAnonymousImport(b.fmt("{s}.pdf", .{name}), .{ .root_source_file = b.path(b.fmt("test/backend/{s}.pdf", .{name})) });
        }
        const backend_tests = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path("src/openssl/openssl_tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{ .{ .name = "pdf_openssl", .module = backend }, .{ .name = "conformance", .module = conformance } },
        }) });
        test_step.dependOn(&b.addRunArtifact(backend_tests).step);
    }
}
