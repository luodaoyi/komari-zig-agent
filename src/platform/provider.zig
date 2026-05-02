const builtin = @import("builtin");
const std = @import("std");

pub const common = @import("common.zig");
const impl = switch (builtin.os.tag) {
    .linux => @import("linux.zig"),
    .freebsd => @import("freebsd.zig"),
    .macos => @import("darwin.zig"),
    else => @import("linux.zig"),
};

pub fn basicInfo(allocator: std.mem.Allocator) !common.BasicInfo {
    return impl.basicInfo(allocator);
}

pub fn snapshot() !common.Snapshot {
    return impl.snapshot();
}
