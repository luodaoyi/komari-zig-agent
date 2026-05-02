const std = @import("std");
const http = @import("../protocol/http.zig");

pub const Input = union(enum) {
    input: []const u8,
    resize: struct { cols: u16, rows: u16 },
    raw: []const u8,
};

pub fn parseInput(bytes: []const u8) Input {
    var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, bytes, .{}) catch return .{ .raw = bytes };
    defer parsed.deinit();
    const obj = parsed.value.object;
    const typ = obj.get("type") orelse return .{ .raw = bytes };
    if (typ != .string) return .{ .raw = bytes };
    if (std.mem.eql(u8, typ.string, "input")) {
        if (obj.get("input")) |v| if (v == .string) return .{ .input = v.string };
    }
    if (std.mem.eql(u8, typ.string, "resize")) {
        const cols = if (obj.get("cols")) |v| if (v == .integer) @as(u16, @intCast(v.integer)) else 0 else 0;
        const rows = if (obj.get("rows")) |v| if (v == .integer) @as(u16, @intCast(v.integer)) else 0 else 0;
        return .{ .resize = .{ .cols = cols, .rows = rows } };
    }
    return .{ .raw = bytes };
}

pub fn startDisabledMessage() []const u8 {
    return "\n\nWeb SSH is disabled. Enable it by running without the --disable-web-ssh flag.";
}

pub fn startSession(allocator: std.mem.Allocator, cfg: anytype, request_id: []const u8) !void {
    if (cfg.disable_web_ssh) return;
    const url = try http.terminalWsUrl(allocator, cfg.endpoint, cfg.token, request_id);
    defer allocator.free(url);
    const target = try parseWsUrl(url);
    const connect = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ target.host, target.port });
    defer allocator.free(connect);

    var ws_child = std.process.Child.init(&.{ "openssl", "s_client", "-quiet", "-connect", connect, "-servername", target.host }, allocator);
    ws_child.stdin_behavior = .Pipe;
    ws_child.stdout_behavior = .Pipe;
    ws_child.stderr_behavior = .Ignore;
    try ws_child.spawn();
    defer {
        if (ws_child.stdin) |file| file.close();
        if (ws_child.stdout) |file| file.close();
        _ = ws_child.kill() catch {};
        _ = ws_child.wait() catch {};
    }

    var ws_writer = ws_child.stdin.?.deprecatedWriter();
    try ws_writer.print(
        "GET {s} HTTP/1.1\r\nHost: {s}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n",
        .{ target.path, target.host },
    );
    try readHandshake(ws_child.stdout.?);

    const shell = shellPath();
    var sh = std.process.Child.init(&.{ shell }, allocator);
    sh.stdin_behavior = .Pipe;
    sh.stdout_behavior = .Pipe;
    sh.stderr_behavior = .Pipe;
    try sh.spawn();
    defer {
        if (sh.stdin) |file| file.close();
        if (sh.stdout) |file| file.close();
        if (sh.stderr) |file| file.close();
        _ = sh.kill() catch {};
        _ = sh.wait() catch {};
    }

    const out_thread = try std.Thread.spawn(.{}, pipeShellOutputToWs, .{ sh.stdout.?, ws_child.stdin.? });
    out_thread.detach();
    const err_thread = try std.Thread.spawn(.{}, pipeShellOutputToWs, .{ sh.stderr.?, ws_child.stdin.? });
    err_thread.detach();

    while (true) {
        const frame = try readFrame(allocator, ws_child.stdout.?);
        defer allocator.free(frame.payload);
        if (frame.opcode == 0x8) return;
        if (frame.opcode != 0x1 and frame.opcode != 0x2) continue;
        const input = parseInput(frame.payload);
        switch (input) {
            .input => |bytes| try sh.stdin.?.writeAll(bytes),
            .raw => |bytes| try sh.stdin.?.writeAll(bytes),
            .resize => {},
        }
    }
}

fn shellPath() []const u8 {
    if (std.process.getEnvVarOwned(std.heap.page_allocator, "SHELL")) |value| {
        if (value.len != 0) return value;
    } else |_| {}
    return "/bin/sh";
}

fn pipeShellOutputToWs(from: std.fs.File, to: std.fs.File) void {
    var reader = from.deprecatedReader();
    var writer = to.deprecatedWriter();
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = reader.read(&buf) catch return;
        if (n == 0) return;
        writeMaskedFrame(&writer, 0x2, buf[0..n]) catch return;
    }
}

const WsTarget = struct {
    host: []const u8,
    port: []const u8,
    path: []const u8,
};

const Frame = struct {
    opcode: u8,
    payload: []u8,
};

fn parseWsUrl(url: []const u8) !WsTarget {
    const prefix = if (std.mem.startsWith(u8, url, "wss://")) "wss://" else if (std.mem.startsWith(u8, url, "ws://")) "ws://" else return error.InvalidWebSocketUrl;
    const rest = url[prefix.len..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return error.InvalidWebSocketUrl;
    const hostport = rest[0..slash];
    const path = rest[slash..];
    if (std.mem.lastIndexOfScalar(u8, hostport, ':')) |idx| return .{ .host = hostport[0..idx], .port = hostport[idx + 1 ..], .path = path };
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

fn readFrame(allocator: std.mem.Allocator, file: std.fs.File) !Frame {
    var reader = file.deprecatedReader();
    const b0 = try reader.readByte();
    const opcode = b0 & 0x0f;
    const b1 = try reader.readByte();
    const masked = (b1 & 0x80) != 0;
    var len: u64 = b1 & 0x7f;
    if (len == 126) {
        len = (@as(u64, try reader.readByte()) << 8) | try reader.readByte();
    } else if (len == 127) {
        return error.WebSocketPayloadTooLarge;
    }
    var mask: [4]u8 = .{ 0, 0, 0, 0 };
    if (masked) {
        for (&mask) |*m| m.* = try reader.readByte();
    }
    const payload = try allocator.alloc(u8, @intCast(len));
    errdefer allocator.free(payload);
    try reader.readNoEof(payload);
    if (masked) {
        for (payload, 0..) |*b, i| b.* ^= mask[i % 4];
    }
    return .{ .opcode = opcode, .payload = payload };
}

fn writeMaskedFrame(writer: anytype, opcode: u8, payload: []const u8) !void {
    try writer.writeByte(0x80 | opcode);
    if (payload.len < 126) {
        try writer.writeByte(0x80 | @as(u8, @intCast(payload.len)));
    } else if (payload.len <= 0xffff) {
        try writer.writeByte(0x80 | 126);
        try writer.writeByte(@intCast((payload.len >> 8) & 0xff));
        try writer.writeByte(@intCast(payload.len & 0xff));
    } else {
        return error.WebSocketPayloadTooLarge;
    }
    const mask = [_]u8{ 5, 6, 7, 8 };
    try writer.writeAll(&mask);
    for (payload, 0..) |b, i| try writer.writeByte(b ^ mask[i % 4]);
}
