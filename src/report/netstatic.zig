const std = @import("std");

pub const TrafficData = struct { timestamp: u64, tx: u64, rx: u64 };
pub const NetStaticConfig = struct {
    data_preserve_day: f64 = 31,
    detect_interval: f64 = 2,
    save_interval: f64 = 600,
    nics: []const []const u8 = &.{},
};

pub fn startOrContinue() !void {}
pub fn stop() !void {}

pub fn lastResetDate(reset_day: i32, now: i64) i64 {
    _ = reset_day;
    return now;
}

pub fn writeEmptyStore(allocator: std.mem.Allocator) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{{\"interfaces\":{{}},\"config\":{{\"data_preserve_day\":31,\"detect_interval\":2,\"save_interval\":600,\"nics\":[]}}}}", .{});
}
