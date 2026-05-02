const std = @import("std");
const types = @import("types.zig");

pub fn allocPingResultJson(allocator: std.mem.Allocator, task_id: u64, ping_type: []const u8, value: i64, finished_at: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try types.writePingResultJson(out.writer(allocator), .{
        .task_id = task_id,
        .ping_type = ping_type,
        .value = value,
        .finished_at = finished_at,
    });
    return out.toOwnedSlice(allocator);
}

pub fn measure(_: []const u8, _: []const u8) i64 {
    return -1;
}
