const std = @import("std");
const types = @import("types.zig");

pub const TcpTarget = struct {
    host: []const u8,
    port: []const u8,
};

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

pub fn measure(allocator: std.mem.Allocator, ping_type: []const u8, target: []const u8) i64 {
    if (std.mem.eql(u8, ping_type, "tcp")) return tcpPing(allocator, target) catch -1;
    if (std.mem.eql(u8, ping_type, "http")) return httpPing(allocator, target) catch -1;
    if (std.mem.eql(u8, ping_type, "icmp")) return -1;
    return -1;
}

pub fn parseTcpTarget(target: []const u8) !TcpTarget {
    if (std.mem.lastIndexOfScalar(u8, target, ':')) |idx| {
        if (idx != 0 and idx + 1 < target.len and std.mem.indexOfScalar(u8, target[0..idx], ':') == null) {
            return .{ .host = target[0..idx], .port = target[idx + 1 ..] };
        }
    }
    return .{ .host = target, .port = "80" };
}

pub fn normalizeHttpTarget(allocator: std.mem.Allocator, target: []const u8) ![]const u8 {
    if (std.mem.startsWith(u8, target, "http://") or std.mem.startsWith(u8, target, "https://")) {
        return allocator.dupe(u8, target);
    }
    return std.fmt.allocPrint(allocator, "http://{s}", .{target});
}

fn tcpPing(allocator: std.mem.Allocator, target: []const u8) !i64 {
    const parsed = try parseTcpTarget(target);
    const start = std.time.milliTimestamp();
    var stream = try std.net.tcpConnectToHost(allocator, parsed.host, try std.fmt.parseInt(u16, parsed.port, 10));
    defer stream.close();
    return std.time.milliTimestamp() - start;
}

fn httpPing(allocator: std.mem.Allocator, target: []const u8) !i64 {
    const url = try normalizeHttpTarget(allocator, target);
    defer allocator.free(url);

    var args = std.ArrayList([]const u8).empty;
    defer args.deinit(allocator);
    try args.appendSlice(allocator, &.{ "curl", "-o", "/dev/null", "-s", "-w", "%{http_code}", "--max-time", "3", url });
    const start = std.time.milliTimestamp();
    var child = std.process.Child.init(args.items, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    try child.spawn();
    const stdout = try child.stdout.?.readToEndAlloc(allocator, 4096);
    defer allocator.free(stdout);
    const term = try child.wait();
    if (term != .Exited or term.Exited != 0) return error.HttpPingFailed;
    const code = std.fmt.parseInt(u16, std.mem.trim(u8, stdout, " \t\r\n"), 10) catch return error.HttpPingFailed;
    const elapsed = std.time.milliTimestamp() - start;
    if (code >= 200 and code < 400) return elapsed;
    return -1;
}
