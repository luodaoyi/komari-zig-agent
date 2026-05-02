const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const version = b.option([]const u8, "version", "agent version") orelse "0.0.1";

    const opts = b.addOptions();
    opts.addOption([]const u8, "version", version);

    const exe = b.addExecutable(.{
        .name = "komari-agent",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addOptions("build_options", opts);
    b.installArtifact(exe);

    const version_module = b.createModule(.{
        .root_source_file = b.path("src/version.zig"),
        .target = target,
        .optimize = optimize,
    });
    version_module.addOptions("build_options", opts);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/bootstrap_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    tests.root_module.addOptions("build_options", opts);
    tests.root_module.addImport("version", version_module);

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
