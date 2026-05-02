const common = @import("common.zig");
const freebsd = @import("freebsd.zig");
const std = @import("std");

pub fn basicInfo(allocator: std.mem.Allocator) !common.BasicInfo {
    var info = try freebsd.basicInfo(allocator);
    info.os_name = try commandFirstLine(allocator, &.{ "sw_vers", "-productName" }, "macOS");
    info.kernel_version = try commandFirstLine(allocator, &.{ "uname", "-r" }, "");
    info.cpu.name = try commandFirstLine(allocator, &.{ "sysctl", "-n", "machdep.cpu.brand_string" }, "Unknown");
    info.gpu_name = try gpuName(allocator);
    return info;
}

pub fn snapshot(options: common.SnapshotOptions) !common.Snapshot {
    return freebsd.snapshot(options);
}

pub fn diskList(allocator: std.mem.Allocator) ![]common.DiskMount {
    return freebsd.diskList(allocator);
}

fn commandFirstLine(allocator: std.mem.Allocator, argv: []const []const u8, fallback: []const u8) ![]const u8 {
    var child = std.process.Child.init(argv, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return allocator.dupe(u8, fallback);
    const stdout = child.stdout.?.readToEndAlloc(allocator, 64 * 1024) catch return allocator.dupe(u8, fallback);
    defer allocator.free(stdout);
    const term = child.wait() catch return allocator.dupe(u8, fallback);
    if (term != .Exited or term.Exited != 0) return allocator.dupe(u8, fallback);
    var it = std.mem.splitScalar(u8, stdout, '\n');
    return allocator.dupe(u8, std.mem.trim(u8, it.next() orelse fallback, " \t\r"));
}

fn gpuName(allocator: std.mem.Allocator) ![]const u8 {
    const out = commandOutput(allocator, &.{ "system_profiler", "SPDisplaysDataType" }) catch return allocator.dupe(u8, "Unknown");
    defer allocator.free(out);
    var lines = std.mem.splitScalar(u8, out, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r\n");
        if (std.mem.startsWith(u8, line, "Chipset Model:")) {
            return allocator.dupe(u8, std.mem.trim(u8, line["Chipset Model:".len..], " \t\r\n"));
        }
    }
    return allocator.dupe(u8, "Unknown");
}

fn commandOutput(allocator: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    var child = std.process.Child.init(argv, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    try child.spawn();
    const stdout = try child.stdout.?.readToEndAlloc(allocator, 256 * 1024);
    errdefer allocator.free(stdout);
    const term = try child.wait();
    if (term != .Exited or term.Exited != 0) return error.CommandFailed;
    return stdout;
}
