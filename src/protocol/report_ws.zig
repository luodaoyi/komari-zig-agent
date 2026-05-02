const std = @import("std");
const config = @import("../config.zig");
const http = @import("http.zig");
const provider = @import("../platform/provider.zig");
const report = @import("../report/report.zig");

pub fn runOnce(allocator: std.mem.Allocator, cfg: config.Config) ![]const u8 {
    _ = cfg;
    return report.allocReportJson(allocator, try provider.snapshot());
}

pub fn loop(allocator: std.mem.Allocator, cfg: config.Config) !void {
    var stdout = std.fs.File.stdout().deprecatedWriter();
    const seconds: u64 = if (cfg.interval <= 1) 1 else @intFromFloat(cfg.interval - 1);
    var ws = connectReportWs(allocator, cfg) catch |err| blk: {
        try stdout.print("WebSocket connect failed: {s}; generating reports locally\n", .{@errorName(err)});
        break :blk null;
    };
    defer if (ws) |*conn| conn.close(allocator);

    while (true) {
        const payload = try runOnce(allocator, cfg);
        defer allocator.free(payload);
        if (ws) |*conn| {
            conn.writeText(payload) catch |err| {
                try stdout.print("WebSocket write failed: {s}\n", .{@errorName(err)});
                conn.close(allocator);
                ws = null;
            };
        }
        try stdout.print("Report generated: {d} bytes{s}\n", .{ payload.len, if (ws != null) " sent" else "" });
        std.Thread.sleep(seconds * std.time.ns_per_s);
    }
}

const WsTarget = struct {
    host: []const u8,
    port: []const u8,
    path: []const u8,
};

const OpenSslWs = struct {
    child: std.process.Child,

    fn close(self: *OpenSslWs, allocator: std.mem.Allocator) void {
        _ = allocator;
        if (self.child.stdin) |file| file.close();
        if (self.child.stdout) |file| file.close();
        _ = self.child.kill() catch {};
        _ = self.child.wait() catch {};
    }

    fn writeText(self: *OpenSslWs, payload: []const u8) !void {
        const stdin = self.child.stdin orelse return error.WebSocketClosed;
        var writer = stdin.deprecatedWriter();
        try writeMaskedTextFrame(&writer, payload);
    }
};

fn connectReportWs(allocator: std.mem.Allocator, cfg: config.Config) !OpenSslWs {
    const url = try http.reportWsUrl(allocator, cfg.endpoint, cfg.token);
    defer allocator.free(url);
    const target = try parseWssUrl(url);
    const connect = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ target.host, target.port });
    defer allocator.free(connect);

    var child = std.process.Child.init(&.{ "openssl", "s_client", "-quiet", "-connect", connect, "-servername", target.host }, allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    try child.spawn();

    var conn = OpenSslWs{ .child = child };
    errdefer conn.close(allocator);

    var writer = conn.child.stdin.?.deprecatedWriter();
    try writer.print(
        "GET {s} HTTP/1.1\r\nHost: {s}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n",
        .{ target.path, target.host },
    );

    try readHandshake(conn.child.stdout.?);
    return conn;
}

fn parseWssUrl(url: []const u8) !WsTarget {
    const prefix = if (std.mem.startsWith(u8, url, "wss://")) "wss://" else if (std.mem.startsWith(u8, url, "ws://")) "ws://" else return error.InvalidWebSocketUrl;
    const rest = url[prefix.len..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return error.InvalidWebSocketUrl;
    const hostport = rest[0..slash];
    const path = rest[slash..];
    if (std.mem.lastIndexOfScalar(u8, hostport, ':')) |idx| {
        return .{ .host = hostport[0..idx], .port = hostport[idx + 1 ..], .path = path };
    }
    return .{ .host = hostport, .port = if (prefix[1] == 's') "443" else "80", .path = path };
}

fn readHandshake(file: std.fs.File) !void {
    var reader = file.deprecatedReader();
    var window: [4]u8 = .{ 0, 0, 0, 0 };
    var seen: usize = 0;
    while (seen < 8192) : (seen += 1) {
        const b = try reader.readByte();
        window[0] = window[1];
        window[1] = window[2];
        window[2] = window[3];
        window[3] = b;
        if (std.mem.eql(u8, &window, "\r\n\r\n")) return;
    }
    return error.WebSocketHandshakeTooLarge;
}

fn writeMaskedTextFrame(writer: anytype, payload: []const u8) !void {
    try writer.writeByte(0x81);
    if (payload.len < 126) {
        try writer.writeByte(0x80 | @as(u8, @intCast(payload.len)));
    } else if (payload.len <= 0xffff) {
        try writer.writeByte(0x80 | 126);
        try writer.writeByte(@intCast((payload.len >> 8) & 0xff));
        try writer.writeByte(@intCast(payload.len & 0xff));
    } else {
        return error.WebSocketPayloadTooLarge;
    }
    const mask = [_]u8{ 1, 2, 3, 4 };
    try writer.writeAll(&mask);
    for (payload, 0..) |b, i| {
        try writer.writeByte(b ^ mask[i % 4]);
    }
}
