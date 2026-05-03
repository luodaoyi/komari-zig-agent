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
            .unwind_tables = .none,
            .omit_frame_pointer = true,
        }),
    });
    exe.root_module.addOptions("build_options", opts);
    if (target.result.os.tag == .freebsd or target.result.os.tag == .macos) {
        exe.linkLibC();
    }
    if (target.result.os.tag == .freebsd) {
        exe.linkSystemLibrary("util");
    }
    const exe_idna = b.createModule(.{
        .root_source_file = b.path("src/idna.zig"),
        .target = target,
        .optimize = optimize,
        .unwind_tables = .none,
        .omit_frame_pointer = true,
    });
    const exe_dns = b.createModule(.{
        .root_source_file = b.path("src/dns.zig"),
        .target = target,
        .optimize = optimize,
        .unwind_tables = .none,
        .omit_frame_pointer = true,
    });
    exe.root_module.addImport("idna", exe_idna);
    exe.root_module.addImport("dns", exe_dns);
    exe.root_module.addImport("report_netstatic", b.createModule(.{
        .root_source_file = b.path("src/report/netstatic.zig"),
        .target = target,
        .optimize = optimize,
        .unwind_tables = .none,
        .omit_frame_pointer = true,
    }));
    b.installArtifact(exe);

    const version_module = b.createModule(.{
        .root_source_file = b.path("src/version.zig"),
        .target = target,
        .optimize = optimize,
    });
    version_module.addOptions("build_options", opts);

    const test_step = b.step("test", "Run unit tests");
    addTest(b, test_step, "test/bootstrap_test.zig", target, optimize, opts, version_module);
    addTest(b, test_step, "test/config_test.zig", target, optimize, opts, version_module);
    addTest(b, test_step, "test/protocol_json_test.zig", target, optimize, opts, version_module);
    addTest(b, test_step, "src/autodiscovery_test.zig", target, optimize, opts, version_module);
    addTest(b, test_step, "test/http_test.zig", target, optimize, opts, version_module);
    addTest(b, test_step, "test/dns_idna_test.zig", target, optimize, opts, version_module);
    addTest(b, test_step, "test/linux_basic_info_test.zig", target, optimize, opts, version_module);
    addTest(b, test_step, "test/disk_filter_test.zig", target, optimize, opts, version_module);
    addTest(b, test_step, "test/network_filter_test.zig", target, optimize, opts, version_module);
    addTest(b, test_step, "test/cpu_proc_test.zig", target, optimize, opts, version_module);
    addTest(b, test_step, "test/task_test.zig", target, optimize, opts, version_module);
    addTest(b, test_step, "test/ping_test.zig", target, optimize, opts, version_module);
    addTest(b, test_step, "test/ip_extract_test.zig", target, optimize, opts, version_module);
    addTest(b, test_step, "test/ws_message_test.zig", target, optimize, opts, version_module);
    addTest(b, test_step, "test/report_interval_test.zig", target, optimize, opts, version_module);
    addTest(b, test_step, "test/netstatic_test.zig", target, optimize, opts, version_module);
    addTest(b, test_step, "test/update_test.zig", target, optimize, opts, version_module);
}

fn addTest(
    b: *std.Build,
    test_step: *std.Build.Step,
    path: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    opts: *std.Build.Step.Options,
    version_module: *std.Build.Module,
) void {
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path(path),
            .target = target,
            .optimize = optimize,
        }),
    });
    tests.root_module.addOptions("build_options", opts);
    tests.root_module.addImport("version", version_module);
    tests.root_module.addImport("config", b.createModule(.{
        .root_source_file = b.path("src/config.zig"),
        .target = target,
        .optimize = optimize,
    }));
    tests.root_module.addImport("protocol_types", b.createModule(.{
        .root_source_file = b.path("src/protocol/types.zig"),
        .target = target,
        .optimize = optimize,
    }));
    const idna_module = b.createModule(.{
        .root_source_file = b.path("src/idna.zig"),
        .target = target,
        .optimize = optimize,
    });
    const dns_module = b.createModule(.{
        .root_source_file = b.path("src/dns.zig"),
        .target = target,
        .optimize = optimize,
    });
    const protocol_http = b.createModule(.{
        .root_source_file = b.path("src/protocol/http.zig"),
        .target = target,
        .optimize = optimize,
    });
    protocol_http.addImport("idna", idna_module);
    protocol_http.addImport("dns", dns_module);
    tests.root_module.addImport("protocol_http", protocol_http);
    const update_module = b.createModule(.{
        .root_source_file = b.path("src/update.zig"),
        .target = target,
        .optimize = optimize,
    });
    update_module.addOptions("build_options", opts);
    update_module.addImport("idna", idna_module);
    update_module.addImport("dns", dns_module);
    tests.root_module.addImport("update", update_module);
    tests.root_module.addImport("dns", dns_module);
    tests.root_module.addImport("idna", idna_module);
    const report_netstatic = b.createModule(.{
        .root_source_file = b.path("src/report/netstatic.zig"),
        .target = target,
        .optimize = optimize,
    });
    const platform_linux = b.createModule(.{
        .root_source_file = b.path("src/platform/linux.zig"),
        .target = target,
        .optimize = optimize,
    });
    platform_linux.addImport("report_netstatic", report_netstatic);
    tests.root_module.addImport("platform_linux", platform_linux);
    tests.root_module.addImport("protocol_task", b.createModule(.{
        .root_source_file = b.path("src/protocol/task.zig"),
        .target = target,
        .optimize = optimize,
    }));
    const protocol_ping = b.createModule(.{
        .root_source_file = b.path("src/protocol/ping.zig"),
        .target = target,
        .optimize = optimize,
    });
    protocol_ping.addImport("dns", dns_module);
    tests.root_module.addImport("protocol_ping", protocol_ping);
    const protocol_ip = b.createModule(.{
        .root_source_file = b.path("src/protocol/ip.zig"),
        .target = target,
        .optimize = optimize,
    });
    protocol_ip.addImport("idna", idna_module);
    protocol_ip.addImport("dns", dns_module);
    tests.root_module.addImport("protocol_ip", protocol_ip);
    tests.root_module.addImport("protocol_ws_message", b.createModule(.{
        .root_source_file = b.path("src/protocol/ws_message.zig"),
        .target = target,
        .optimize = optimize,
    }));
    tests.root_module.addImport("protocol_report_timing", b.createModule(.{
        .root_source_file = b.path("src/protocol/report_timing.zig"),
        .target = target,
        .optimize = optimize,
    }));
    tests.root_module.addImport("report_netstatic", report_netstatic);

    const run_tests = b.addRunArtifact(tests);
    test_step.dependOn(&run_tests.step);
}
