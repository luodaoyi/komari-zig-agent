const std = @import("std");
const config = @import("../config.zig");
const provider = @import("../platform/provider.zig");
const report = @import("../report/report.zig");

pub fn runOnce(allocator: std.mem.Allocator, cfg: config.Config) ![]const u8 {
    _ = cfg;
    return report.allocReportJson(allocator, try provider.snapshot());
}

pub fn loop(allocator: std.mem.Allocator, cfg: config.Config) !void {
    var stdout = std.fs.File.stdout().deprecatedWriter();
    const seconds: u64 = if (cfg.interval <= 1) 1 else @intFromFloat(cfg.interval - 1);
    while (true) {
        const payload = try runOnce(allocator, cfg);
        defer allocator.free(payload);
        try stdout.print("Report generated: {d} bytes\n", .{payload.len});
        std.Thread.sleep(seconds * std.time.ns_per_s);
    }
}
