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

    const test_step = b.step("test", "Run unit tests");
    const unit = b.addTest(.{ .root_module = mod });
    test_step.dependOn(&b.addRunArtifact(unit).step);
}
