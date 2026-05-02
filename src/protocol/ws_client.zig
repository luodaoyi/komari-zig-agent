const std = @import("std");
const http = @import("http.zig");
const idna = @import("idna");
const raw_conn = @import("raw_conn.zig");

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
    http_client: ?std.http.Client = null,
    request: ?std.http.Client.Request = null,
    raw: ?*raw_conn.RawConn = null,
    write_mutex: std.Thread.Mutex = .{},
    refs: std.atomic.Value(usize) = std.atomic.Value(usize).init(1),
    closed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn close(self: *Client, allocator: std.mem.Allocator) void {
        self.shutdown();
        self.release(allocator);
    }

    pub fn acquire(self: *Client) void {
        _ = self.refs.fetchAdd(1, .monotonic);
    }

    pub fn release(self: *Client, allocator: std.mem.Allocator) void {
        if (self.refs.fetchSub(1, .acq_rel) == 1) self.deinit(allocator);
    }

    pub fn shutdown(self: *Client) void {
        if (self.closed.swap(true, .acq_rel)) return;
        if (self.raw) |raw| raw.shutdown();
        if (self.request) |*request| {
            if (request.connection) |conn| conn.closing = true;
        }
    }

    fn deinit(self: *Client, allocator: std.mem.Allocator) void {
        if (self.request) |*request| {
            if (request.connection) |conn| conn.closing = true;
            request.deinit();
        }
        if (self.http_client) |*client| client.deinit();
        if (self.raw) |raw| raw.close();
        allocator.destroy(self);
    }

    pub fn writeText(self: *Client, payload: []const u8) !void {
        try self.writeFrame(0x1, payload);
    }

    pub fn writeBinary(self: *Client, payload: []const u8) !void {
        try self.writeFrame(0x2, payload);
    }

    pub fn writePing(self: *Client) !void {
        try self.writeFrame(0x9, "");
    }

    pub fn writeFrame(self: *Client, opcode: u8, payload: []const u8) !void {
        self.write_mutex.lock();
        defer self.write_mutex.unlock();
        if (self.closed.load(.acquire)) return error.WebSocketClosed;
        if (self.raw) |raw| {
            try writeMaskedFrame(raw.writer(), opcode, payload);
            try raw.flush();
            return;
        }
        const req = self.request orelse return error.WebSocketClosed;
        const conn = req.connection orelse return error.WebSocketClosed;
        try writeMaskedFrame(conn.writer(), opcode, payload);
        try conn.flush();
    }

    pub fn readFrame(self: *Client, allocator: std.mem.Allocator) !Frame {
        if (self.closed.load(.acquire)) return error.WebSocketClosed;
        if (self.raw) |raw| return readFrameFromReader(allocator, raw.reader());
        const req = self.request orelse return error.WebSocketClosed;
        const conn = req.connection orelse return error.WebSocketClosed;
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

pub fn connect(allocator: std.mem.Allocator, url: []const u8, cfg: anytype) !*Client {
    const ascii_url = try idna.convertUrlToAscii(allocator, url);
    defer allocator.free(ascii_url);
    if (cfg.custom_dns.len != 0 or cfg.ignore_unsafe_cert) {
        return connectRaw(allocator, ascii_url, cfg);
    }
    const uri = try std.Uri.parse(ascii_url);
    var http_client = std.http.Client{ .allocator = allocator };
    errdefer http_client.deinit();

    const nonce = "dGhlIHNhbXBsZSBub25jZQ==";
    var extra: [6]std.http.Header = undefined;
    extra[0] = .{ .name = "Upgrade", .value = "websocket" };
    extra[1] = .{ .name = "Connection", .value = "Upgrade" };
    extra[2] = .{ .name = "Sec-WebSocket-Key", .value = nonce };
    extra[3] = .{ .name = "Sec-WebSocket-Version", .value = "13" };
    var cf: [2]std.http.Header = undefined;
    const cf_headers = http.cloudflareHeaders(cfg, &cf);
    var extra_len: usize = 4;
    for (cf_headers) |header| {
        extra[extra_len] = header;
        extra_len += 1;
    }

    var req = try http_client.request(.GET, uri, .{
        .keep_alive = true,
        .redirect_behavior = .unhandled,
        .extra_headers = extra[0..extra_len],
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

fn connectRaw(allocator: std.mem.Allocator, url: []const u8, cfg: anytype) !*Client {
    const target = try parseUrl(url);
    const raw = try raw_conn.RawConn.connect(allocator, target.host, target.port, target.tls, cfg.ignore_unsafe_cert, cfg.custom_dns);
    errdefer raw.close();
    const nonce = "dGhlIHNhbXBsZSBub25jZQ==";
    var req = std.Io.Writer.Allocating.init(allocator);
    defer req.deinit();
    try req.writer.print(
        "GET {s} HTTP/1.1\r\nHost: {s}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {s}\r\nSec-WebSocket-Version: 13\r\nUser-Agent: komari-zig-agent\r\n",
        .{ target.path, target.host, nonce },
    );
    var cf: [2]std.http.Header = undefined;
    for (http.cloudflareHeaders(cfg, &cf)) |header| try req.writer.print("{s}: {s}\r\n", .{ header.name, header.value });
    try req.writer.writeAll("\r\n");
    const request = try req.toOwnedSlice();
    defer allocator.free(request);
    try raw.writer().writeAll(request);
    try raw.flush();
    const code = try readHandshake(raw.reader());
    if (code != 101) return error.WebSocketHandshakeFailed;
    const client = try allocator.create(Client);
    client.* = .{ .raw = raw };
    return client;
}

pub fn parseUrl(url: []const u8) !Target {
    const prefix = if (std.mem.startsWith(u8, url, "wss://")) "wss://" else if (std.mem.startsWith(u8, url, "ws://")) "ws://" else return error.InvalidWebSocketUrl;
    const rest = url[prefix.len..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return error.InvalidWebSocketUrl;
    const hostport = rest[0..slash];
    const path = rest[slash..];
    if (std.mem.startsWith(u8, hostport, "[")) {
        const close = std.mem.indexOfScalar(u8, hostport, ']') orelse return error.InvalidWebSocketUrl;
        const host = hostport[1..close];
        if (close + 1 < hostport.len) {
            if (hostport[close + 1] != ':') return error.InvalidWebSocketUrl;
            const port = try std.fmt.parseInt(u16, hostport[close + 2 ..], 10);
            return .{ .host = host, .port = port, .path = path, .tls = prefix[1] == 's' };
        }
        return .{ .host = host, .port = if (prefix[1] == 's') 443 else 80, .path = path, .tls = prefix[1] == 's' };
    }
    if (std.mem.lastIndexOfScalar(u8, hostport, ':')) |idx| {
        if (std.mem.indexOfScalar(u8, hostport[0..idx], ':') != null) {
            return .{ .host = hostport, .port = if (prefix[1] == 's') 443 else 80, .path = path, .tls = prefix[1] == 's' };
        }
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

fn readHandshake(reader: *std.Io.Reader) !u16 {
    var line: [1024]u8 = undefined;
    const n = try readLine(reader, &line);
    const first = line[0..n];
    if (first.len < 12 or !std.mem.startsWith(u8, first, "HTTP/1.")) return error.WebSocketHandshakeFailed;
    const code = try std.fmt.parseInt(u16, first[9..12], 10);
    while (true) {
        const len = try readLine(reader, &line);
        if (len == 0) break;
    }
    return code;
}

fn readLine(reader: *std.Io.Reader, buf: []u8) !usize {
    var i: usize = 0;
    while (i < buf.len) {
        const b = try reader.takeByte();
        if (b == '\n') {
            if (i > 0 and buf[i - 1] == '\r') i -= 1;
            return i;
        }
        buf[i] = b;
        i += 1;
    }
    return error.LineTooLong;
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
