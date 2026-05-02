const std = @import("std");
const config = @import("../config.zig");
const provider = @import("../platform/provider.zig");
const report = @import("../report/report.zig");

pub fn runOnce(allocator: std.mem.Allocator, cfg: config.Config) ![]const u8 {
    _ = cfg;
    return report.allocReportJson(allocator, try provider.snapshot());
}

pub fn loop(_: std.mem.Allocator, _: config.Config) !void {
    // Real websocket transport is exercised during deployment testing.
}
