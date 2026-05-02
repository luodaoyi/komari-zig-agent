const std = @import("std");

pub const Target = struct {
    host: []const u8,
    port: u16,
    path: []const u8,
    tls: bool,
};

pub const Frame = struct {
    opcode: u8,
    payload: []u8,
};

pub const Client = struct {
    http_client: std.http.Client,
    request: std.http.Client.Request,
    write_mutex: std.Thread.Mutex = .{},

    pub fn close(self: *Client, allocator: std.mem.Allocator) void {
        self.request.connection.?.closing = true;
        self.request.deinit();
        self.http_client.deinit();
        allocator.destroy(self);
    }

    pub fn writeText(self: *Client, payload: []const u8) !void {
        try self.writeFrame(0x1, payload);
    }

    pub fn writeBinary(self: *Client, payload: []const u8) !void {
        try self.writeFrame(0x2, payload);
    }

    pub fn writeFrame(self: *Client, opcode: u8, payload: []const u8) !void {
        self.write_mutex.lock();
        defer self.write_mutex.unlock();
        const conn = self.request.connection orelse return error.WebSocketClosed;
        try writeMaskedFrame(conn.writer(), opcode, payload);
        try conn.flush();
    }

    pub fn readFrame(self: *Client, allocator: std.mem.Allocator) !Frame {
        const conn = self.request.connection orelse return error.WebSocketClosed;
        return readFrameFromReader(allocator, conn.reader());
    }

    pub fn readText(self: *Client, allocator: std.mem.Allocator) ![]const u8 {
        while (true) {
            const frame = try self.readFrame(allocator);
            if (frame.opcode == 0x8) {
                allocator.free(frame.payload);
                return error.WebSocketClosed;
            }
            if (frame.opcode == 0x9) {
                defer allocator.free(frame.payload);
                try self.writeFrame(0xA, frame.payload);
                continue;
            }
            if (frame.opcode == 0xA) {
                allocator.free(frame.payload);
                continue;
            }
            if (frame.opcode != 0x1) {
                allocator.free(frame.payload);
                return error.UnsupportedWebSocketFrame;
            }
            return frame.payload;
        }
    }
};

pub fn connect(allocator: std.mem.Allocator, url: []const u8) !*Client {
    const uri = try std.Uri.parse(url);
    var http_client = std.http.Client{ .allocator = allocator };
    errdefer http_client.deinit();

    const nonce = "dGhlIHNhbXBsZSBub25jZQ==";
    const extra = [_]std.http.Header{
        .{ .name = "Upgrade", .value = "websocket" },
        .{ .name = "Connection", .value = "Upgrade" },
        .{ .name = "Sec-WebSocket-Key", .value = nonce },
        .{ .name = "Sec-WebSocket-Version", .value = "13" },
    };

    var req = try http_client.request(.GET, uri, .{
        .keep_alive = true,
        .redirect_behavior = .unhandled,
        .extra_headers = &extra,
    });
    errdefer req.deinit();
    try req.sendBodiless();
    var redirect_buffer: [1024]u8 = undefined;
    const response = try req.receiveHead(&redirect_buffer);
    if (@intFromEnum(response.head.status) != 101) return error.WebSocketHandshakeFailed;

    const client = try allocator.create(Client);
    client.* = .{
        .http_client = http_client,
        .request = req,
    };
    return client;
}

pub fn parseUrl(url: []const u8) !Target {
    const prefix = if (std.mem.startsWith(u8, url, "wss://")) "wss://" else if (std.mem.startsWith(u8, url, "ws://")) "ws://" else return error.InvalidWebSocketUrl;
    const rest = url[prefix.len..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return error.InvalidWebSocketUrl;
    const hostport = rest[0..slash];
    const path = rest[slash..];
    if (std.mem.lastIndexOfScalar(u8, hostport, ':')) |idx| {
        const port = try std.fmt.parseInt(u16, hostport[idx + 1 ..], 10);
        return .{ .host = hostport[0..idx], .port = port, .path = path, .tls = prefix[1] == 's' };
    }
    return .{ .host = hostport, .port = if (prefix[1] == 's') 443 else 80, .path = path, .tls = prefix[1] == 's' };
}

fn readFrameFromReader(allocator: std.mem.Allocator, reader: anytype) !Frame {
    const b0 = try reader.takeByte();
    const opcode = b0 & 0x0f;
    const b1 = try reader.takeByte();
    const masked = (b1 & 0x80) != 0;
    var len: u64 = b1 & 0x7f;
    if (len == 126) {
        len = (@as(u64, try reader.takeByte()) << 8) | try reader.takeByte();
    } else if (len == 127) {
        var tmp: [8]u8 = undefined;
        for (&tmp) |*b| b.* = try reader.takeByte();
        len = std.mem.readInt(u64, &tmp, .big);
        if (len > 16 * 1024 * 1024) return error.WebSocketPayloadTooLarge;
    }
    var mask: [4]u8 = .{ 0, 0, 0, 0 };
    if (masked) {
        for (&mask) |*m| m.* = try reader.takeByte();
    }
    const payload = try allocator.alloc(u8, @intCast(len));
    errdefer allocator.free(payload);
    try reader.readSliceAll(payload);
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
        try writer.writeByte(0x80 | 127);
        var buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &buf, payload.len, .big);
        try writer.writeAll(&buf);
    }
    const mask = [_]u8{ 1, 2, 3, 4 };
    try writer.writeAll(&mask);
    for (payload, 0..) |b, i| try writer.writeByte(b ^ mask[i % 4]);
}
