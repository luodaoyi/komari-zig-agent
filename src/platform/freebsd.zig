const common = @import("common.zig");
const std = @import("std");

pub fn basicInfo(_: std.mem.Allocator) !common.BasicInfo {
    return .{ .cpu = .{ .architecture = @tagName(@import("builtin").cpu.arch) }, .os_name = "freebsd" };
}

pub fn snapshot() !common.Snapshot {
    return .{ .cpu = .{ .architecture = @tagName(@import("builtin").cpu.arch), .usage = 0.001 } };
}
