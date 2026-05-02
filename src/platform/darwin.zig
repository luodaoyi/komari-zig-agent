const common = @import("common.zig");
const freebsd = @import("freebsd.zig");
const std = @import("std");

pub fn basicInfo(allocator: std.mem.Allocator) !common.BasicInfo {
    var info = try freebsd.basicInfo(allocator);
    info.os_name = try commandFirstLine(allocator, &.{ "sw_vers", "-productName" }, "macOS");
    info.kernel_version = try commandFirstLine(allocator, &.{ "uname", "-r" }, "");
    info.cpu.name = try commandFirstLine(allocator, &.{ "sysctl", "-n", "machdep.cpu.brand_string" }, "Unknown");
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
