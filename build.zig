// SPDX-License-Identifier: LGPL-2.0-or-later
//! pdf-zig build script. `zig build test` runs the tests.

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
    for ([_][]const u8{ "fax_g3_1d.pdf", "fax_g3_2d.pdf", "fax_g4.pdf", "fax_ref.pbm", "lzw_libtiff.bin", "fax_runs.bin" }) |name| {
        mod.addAnonymousImport(name, .{ .root_source_file = b.path(b.fmt("test/fixtures/{s}", .{name})) });
    }

    const test_step = b.step("test", "Run unit tests and compile the example programs");
    // A change that breaks an example must fail the tests too.
    for ([_]*std.Build.Step.Compile{ pdfinfo, pdftext, pdfdump, pdfmark, pdffill, pdfsvg, pdfimg, pdfpages, pdfsurvey }) |example| {
        test_step.dependOn(&example.step);
    }
    const unit = b.addTest(.{ .root_module = mod });
    test_step.dependOn(&b.addRunArtifact(unit).step);
}
