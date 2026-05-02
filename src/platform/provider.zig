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
    return impl.snapshot(.{});
}

pub fn snapshotWithOptions(options: common.SnapshotOptions) !common.Snapshot {
    return impl.snapshot(options);
}

pub fn diskList(allocator: std.mem.Allocator) ![]common.DiskMount {
    return impl.diskList(allocator);
}

pub fn monitoringDiskList(allocator: std.mem.Allocator, include_mountpoints: []const u8) ![]const []const u8 {
    if (@hasDecl(impl, "monitoringDiskList")) return impl.monitoringDiskList(allocator, include_mountpoints);
    const disks = try impl.diskList(allocator);
    defer allocator.free(disks);
    var out: std.ArrayList([]const u8) = .empty;
    for (disks) |disk| {
        try out.append(allocator, try std.fmt.allocPrint(allocator, "{s} ({s})", .{ disk.mountpoint, disk.fstype }));
    }
    return out.toOwnedSlice(allocator);
}

pub fn interfaceList(allocator: std.mem.Allocator, include_nics: []const u8, exclude_nics: []const u8) ![]const []const u8 {
    if (@hasDecl(impl, "interfaceList")) return impl.interfaceList(allocator, include_nics, exclude_nics);
    return allocator.alloc([]const u8, 0);
}

pub fn localIpFromInterfaces(allocator: std.mem.Allocator, include_nics: []const u8, exclude_nics: []const u8) !common.LocalIpInfo {
    if (@hasDecl(impl, "localIpFromInterfaces")) return impl.localIpFromInterfaces(allocator, include_nics, exclude_nics);
    return .{ .ipv4 = "", .ipv6 = "" };
}
