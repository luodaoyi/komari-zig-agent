const std = @import("std");
const types = @import("../protocol/types.zig");
const common = @import("../platform/common.zig");

pub fn writeReportJson(writer: anytype, snap: common.Snapshot) !void {
    var usage = snap.cpu.usage;
    if (usage <= 0.001) usage = 0.001;
    try types.writeReportJson(writer, .{
        .cpu = .{ .usage = usage },
        .ram = .{ .total = snap.ram.total, .used = snap.ram.used },
        .swap = .{ .total = snap.swap.total, .used = snap.swap.used },
        .load = .{ .load1 = snap.load.load1, .load5 = snap.load.load5, .load15 = snap.load.load15 },
        .disk = .{ .total = snap.disk.total, .used = snap.disk.used },
        .network = .{ .up = snap.network.up, .down = snap.network.down, .totalUp = snap.network.totalUp, .totalDown = snap.network.totalDown },
        .connections = .{ .tcp = snap.connections.tcp, .udp = snap.connections.udp },
        .uptime = snap.uptime,
        .process = snap.process,
        .message = snap.message,
    });
}

pub fn allocReportJson(allocator: std.mem.Allocator, snap: common.Snapshot) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try writeReportJson(out.writer(allocator), snap);
    return out.toOwnedSlice(allocator);
}
