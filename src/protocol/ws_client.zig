const std = @import("std");
const debug = @import("debug");
const http = @import("http.zig");
const idna = @import("idna");
const raw_conn = @import("raw_conn.zig");
const compat = @import("compat");

/// Websocket client, framing, and buffer-pool management for agent links.
pub const Target = struct {
    host: []const u8,
    port: u16,
    path: []const u8,
    tls: bool,
};

pub const Frame = struct {
    opcode: u8,
    payload: []u8,
    pooled: bool = false,

    pub fn deinit(self: Frame, client: *Client, allocator: std.mem.Allocator) void {
        if (self.pooled) {
            client.releaseReadBuffer(self.payload);
        } else {
            allocator.free(self.payload);
        }
    }
};

pub const Client = struct {
    http_client: ?std.http.Client = null,
    request: ?std.http.Client.Request = null,
    raw: ?*raw_conn.RawConn = null,
    proxy_arena: ?std.heap.ArenaAllocator = null,
    read_pool: FrameBufferPool = .{},
    write_mutex: compat.Mutex = .{},
    refs: std.atomic.Value(usize) = std.atomic.Value(usize).init(1),
    closed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    track_write: bool = false,
    write_started_tick: std.atomic.Value(u32) = .init(0),

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
        if (self.raw) |raw| {
            if (self.track_write) raw.interrupt() else raw.shutdown();
        }
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
        if (self.proxy_arena) |*arena| arena.deinit();
        self.read_pool.deinit(allocator);
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

    pub fn isClosed(self: *const Client) bool {
        return self.closed.load(.acquire);
    }

    pub fn writeStalled(self: *const Client, now: i64, limit_ms: i64) bool {
        const started = self.write_started_tick.load(.acquire);
        return started != 0 and @as(i32, @bitCast(writeTick(now) -% started)) >= limit_ms;
    }

    pub fn writeFrame(self: *Client, opcode: u8, payload: []const u8) !void {
        self.write_mutex.lock();
        defer self.write_mutex.unlock();
        if (self.closed.load(.acquire)) return error.WebSocketClosed;
        if (self.track_write) self.write_started_tick.store(writeTick(monotonicMs()), .release);
        defer if (self.track_write) self.write_started_tick.store(0, .release);
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
        if (self.raw) |raw| return readFrameFromReader(self, allocator, raw.reader());
        const req = self.request orelse return error.WebSocketClosed;
        const conn = req.connection orelse return error.WebSocketClosed;
        return readFrameFromReader(self, allocator, conn.reader());
    }

    pub fn readText(self: *Client, allocator: std.mem.Allocator) ![]const u8 {
        const frame = try self.readTextFrame(allocator);
        defer frame.deinit(self, allocator);
        return allocator.dupe(u8, frame.payload);
    }

    pub fn readTextFrame(self: *Client, allocator: std.mem.Allocator) !Frame {
        while (true) {
            const frame = try self.readFrame(allocator);
            if (frame.opcode == 0x8) {
                frame.deinit(self, allocator);
                return error.WebSocketClosed;
            }
            if (frame.opcode == 0x9) {
                defer frame.deinit(self, allocator);
                try self.writeFrame(0xA, frame.payload);
                continue;
            }
            if (frame.opcode == 0xA) {
                frame.deinit(self, allocator);
                continue;
            }
            if (frame.opcode != 0x1) {
                frame.deinit(self, allocator);
                return error.UnsupportedWebSocketFrame;
            }
            return frame;
        }
    }

    fn acquireReadBuffer(self: *Client, allocator: std.mem.Allocator, len: usize) !?[]u8 {
        return self.read_pool.acquire(allocator, len);
    }

    fn releaseReadBuffer(self: *Client, payload: []u8) void {
        self.read_pool.release(payload);
    }
};

const read_pool_capacity = 64 * 1024;

const FrameBufferPool = struct {
    buffer: ?[]u8 = null,
    in_use: bool = false,
    mutex: compat.Mutex = .{},

    fn deinit(self: *FrameBufferPool, allocator: std.mem.Allocator) void {
        if (self.buffer) |buffer| allocator.free(buffer);
        self.* = .{};
    }

    fn acquire(self: *FrameBufferPool, allocator: std.mem.Allocator, len: usize) !?[]u8 {
        if (len == 0 or len > read_pool_capacity) return null;
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.in_use) return null;
        if (self.buffer == null) self.buffer = try allocator.alloc(u8, read_pool_capacity);
        self.in_use = true;
        return self.buffer.?[0..len];
    }

    fn release(self: *FrameBufferPool, payload: []u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const buffer = self.buffer orelse return;
        if (payload.ptr == buffer.ptr and payload.len <= buffer.len) self.in_use = false;
    }
};

pub fn connect(allocator: std.mem.Allocator, url: []const u8, cfg: anytype) !*Client {
    const ascii_url = try idna.convertUrlToAscii(allocator, url);
    defer allocator.free(ascii_url);
    return connectRaw(allocator, ascii_url, cfg, null);
}

/// Race the entire terminal connection setup against one cancellable deadline.
pub fn connectTerminal(allocator: std.mem.Allocator, url: []const u8, cfg: anytype, deadline_ms: i64) !*Client {
    return connectTerminalWithIo(compat.io(), allocator, url, cfg, deadline_ms);
}

fn connectTerminalWithIo(io: std.Io, allocator: std.mem.Allocator, url: []const u8, cfg: anytype, deadline_ms: i64) !*Client {
    const Connect = struct {
        fn run(a: std.mem.Allocator, endpoint: []const u8, config: @TypeOf(cfg), deadline: i64) anyerror!*Client {
            const ascii_url = try idna.convertUrlToAscii(a, endpoint);
            defer a.free(ascii_url);
            return connectRaw(a, ascii_url, config, deadline);
        }
    };
    const Result = union(enum) { connection: anyerror!*Client, timeout: void };
    var results: [2]Result = undefined;
    var race = std.Io.Select(Result).init(io, &results);
    defer while (race.cancel()) |pending| switch (pending) {
        .connection => |outcome| if (outcome) |ws| ws.close(allocator) else |_| {},
        .timeout => {},
    };
    try checkConnectDeadline(deadline_ms);
    try race.concurrent(.timeout, sleepUntilConnectDeadline, .{deadline_ms});
    try race.concurrent(.connection, Connect.run, .{ allocator, url, cfg, deadline_ms });
    switch (try race.await()) {
        .timeout => return error.TerminalConnectDeadline,
        .connection => |outcome| {
            const ws = try outcome;
            errdefer ws.close(allocator);
            try checkConnectDeadline(deadline_ms);
            return ws;
        },
    }
}

fn sleepUntilConnectDeadline(deadline: i64) void {
    const remaining = @max(0, deadline - monotonicMs());
    std.Io.sleep(std.Options.debug_io, .fromMilliseconds(remaining), .awake) catch {};
}

fn writeTick(now: i64) u32 {
    // Reserve zero for idle; this loses at most a millisecond at wrap.
    return @truncate(@as(u64, @bitCast(now)) | 1);
}

fn monotonicMs() i64 {
    return std.Io.Timestamp.now(std.Options.debug_io, .awake).toMilliseconds();
}

fn checkConnectDeadline(deadline_ms: ?i64) !void {
    if (deadline_ms) |deadline| {
        try std.Options.debug_io.checkCancel();
        if (monotonicMs() >= deadline) return error.TerminalConnectDeadline;
    }
}

fn connectRaw(allocator: std.mem.Allocator, url: []const u8, cfg: anytype, deadline_ms: ?i64) !*Client {
    try checkConnectDeadline(deadline_ms);
    const terminal = deadline_ms != null;
    const target = try parseUrl(url);
    const scheme = if (target.tls) "wss" else "ws";
    const family = http.dashboardAddressFamily(cfg);
    // Terminal uses cancellable Zig I/O instead of platform socket timeouts.
    const timeout_ms = if (terminal) 0 else http.timeoutMsForConfig(cfg);
    debug.log("websocket transport connect start host={s} port={d} tls={}", .{ target.host, target.port, target.tls });

    const proxy_url = try http.processProxyUrl(allocator, scheme, target.host, target.port);
    defer if (proxy_url) |value| allocator.free(value);
    if (proxy_url != null) {
        const raw_http = try http.connectRawHttp(allocator, scheme, target.host, target.port, target.tls, cfg.ignore_unsafe_cert, cfg.custom_dns, family, timeout_ms);
        return finishConnectHandshake(allocator, url, target, cfg, raw_http, terminal);
    }

    const addrs = if (deadline_ms) |deadline|
        try raw_conn.resolveAddressesUntil(allocator, target.host, target.port, cfg.custom_dns, deadline)
    else
        try raw_conn.resolveAddresses(allocator, target.host, target.port, cfg.custom_dns);
    defer allocator.free(addrs);
    var last_err: ?anyerror = null;
    for (addrs) |addr| {
        try checkConnectDeadline(deadline_ms);
        if (!raw_conn.familyMatches(addr, family)) continue;
        var addr_buf: [96]u8 = undefined;
        const addr_text = raw_conn.formatAddress(&addr_buf, addr);
        const conn = raw_conn.RawConn.connectResolved(allocator, addr, target.host, target.tls, cfg.ignore_unsafe_cert, timeout_ms) catch |err| {
            if (err == error.Canceled) return err;
            last_err = err;
            debug.log("websocket tcp/tls failed via {s}: {s}", .{ addr_text, @errorName(err) });
            continue;
        };
        const raw_http = http.RawConnection{ .conn = conn };
        const client = finishConnectHandshake(allocator, url, target, cfg, raw_http, terminal) catch |err| {
            if (err == error.TerminalUpgradeRejected or err == error.Canceled) return err;
            last_err = err;
            debug.log("websocket skipping address {s} due to {s}", .{ addr_text, @errorName(err) });
            continue;
        };
        debug.log("websocket connected via {s}", .{addr_text});
        return client;
    }
    return last_err orelse error.ConnectFailed;
}

fn finishConnectHandshake(allocator: std.mem.Allocator, url: []const u8, target: Target, cfg: anytype, raw_http: http.RawConnection, terminal: bool) !*Client {
    errdefer raw_http.close(allocator);
    const raw = raw_http.conn;
    debug.log("websocket transport connected host={s} port={d}", .{ target.host, target.port });
    const nonce_bytes = try randomBytes(allocator, 16);
    defer allocator.free(nonce_bytes);
    const nonce = try encodeBase64(allocator, nonce_bytes);
    defer allocator.free(nonce);
    var req = std.Io.Writer.Allocating.init(allocator);
    defer req.deinit();
    const request_target = if (raw_http.proxied_plain) url else target.path;
    const host_header = try http.formatHostHeader(allocator, target.host, target.port, target.tls);
    defer allocator.free(host_header);
    try req.writer.print(
        "GET {s} HTTP/1.1\r\nHost: {s}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {s}\r\nSec-WebSocket-Version: 13\r\nUser-Agent: komari-zig-agent\r\n",
        .{ request_target, host_header, nonce },
    );
    if (raw_http.proxy_authorization) |authorization| try req.writer.print("Proxy-Authorization: {s}\r\n", .{authorization});
    var cf: [2]std.http.Header = undefined;
    for (http.cloudflareHeaders(cfg, &cf)) |header| try req.writer.print("{s}: {s}\r\n", .{ header.name, header.value });
    try req.writer.writeAll("\r\n");
    const request = try req.toOwnedSlice();
    defer allocator.free(request);
    try raw.writer().writeAll(request);
    try raw.flush();
    if (!terminal) debug.log("websocket upgrade request sent path={s}", .{request_target});
    try readHandshake(raw.reader(), nonce, allocator, terminal);
    if (!terminal) debug.log("websocket handshake accepted path={s}", .{request_target});
    const client = try allocator.create(Client);
    client.* = .{ .raw = raw, .track_write = terminal };
    if (raw_http.proxy_authorization) |authorization| allocator.free(authorization);
    return client;
}
pub fn parseUrl(url: []const u8) !Target {
    const prefix = if (std.mem.startsWith(u8, url, "wss://")) "wss://" else if (std.mem.startsWith(u8, url, "ws://")) "ws://" else return error.InvalidWebSocketUrl;
    const tls = std.mem.eql(u8, prefix, "wss://");
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
            return .{ .host = host, .port = port, .path = path, .tls = tls };
        }
        return .{ .host = host, .port = if (tls) 443 else 80, .path = path, .tls = tls };
    }
    if (std.mem.lastIndexOfScalar(u8, hostport, ':')) |idx| {
        if (std.mem.indexOfScalar(u8, hostport[0..idx], ':') != null) {
            return .{ .host = hostport, .port = if (tls) 443 else 80, .path = path, .tls = tls };
        }
        const port = try std.fmt.parseInt(u16, hostport[idx + 1 ..], 10);
        return .{ .host = hostport[0..idx], .port = port, .path = path, .tls = tls };
    }
    return .{ .host = hostport, .port = if (tls) 443 else 80, .path = path, .tls = tls };
}

fn readFrameFromReader(client: *Client, allocator: std.mem.Allocator, reader: anytype) !Frame {
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
    const payload_len: usize = @intCast(len);
    const pooled = try client.acquireReadBuffer(allocator, payload_len);
    const payload = pooled orelse try allocator.alloc(u8, payload_len);
    errdefer if (pooled == null) allocator.free(payload) else client.releaseReadBuffer(payload);
    try reader.readSliceAll(payload);
    if (masked) {
        for (payload, 0..) |*b, i| b.* ^= mask[i % 4];
    }
    return .{ .opcode = opcode, .payload = payload, .pooled = pooled != null };
}

fn readHandshake(reader: *std.Io.Reader, nonce: []const u8, allocator: std.mem.Allocator, terminal: bool) !void {
    var line: [1024]u8 = undefined;
    const n = try readLine(reader, &line);
    const first = line[0..n];
    if (first.len < 12 or !std.mem.startsWith(u8, first, "HTTP/1.")) return error.WebSocketHandshakeFailed;
    const code = try std.fmt.parseInt(u16, first[9..12], 10);
    if (terminal and (code == 401 or code == 403 or code == 404 or code == 410)) return error.TerminalUpgradeRejected;
    if (code != 101) return error.WebSocketHandshakeFailed;
    var accept: ?[]const u8 = null;
    defer if (accept) |value| allocator.free(value);
    while (true) {
        const len = try readLine(reader, &line);
        if (len == 0) break;
        const header = line[0..len];
        if (header.len >= "Sec-WebSocket-Accept:".len and std.ascii.startsWithIgnoreCase(header, "Sec-WebSocket-Accept:")) {
            if (accept != null) return error.WebSocketHandshakeFailed;
            accept = try allocator.dupe(u8, std.mem.trim(u8, header["Sec-WebSocket-Accept:".len..], " \t"));
        }
    }
    const expected = try expectedAccept(allocator, nonce);
    defer allocator.free(expected);
    if (accept == null or !std.mem.eql(u8, accept.?, expected)) return error.WebSocketHandshakeFailed;
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

fn randomBytes(allocator: std.mem.Allocator, len: usize) ![]u8 {
    const out = try allocator.alloc(u8, len);
    fillRandomBytes(out);
    return out;
}

fn fillRandomBytes(buf: []u8) void {
    std.Options.debug_io.randomSecure(buf) catch @panic("secure random source unavailable");
}

fn encodeBase64(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    const encoded_len = std.base64.standard.Encoder.calcSize(data.len);
    const out = try allocator.alloc(u8, encoded_len);
    _ = std.base64.standard.Encoder.encode(out, data);
    return out;
}

fn expectedAccept(allocator: std.mem.Allocator, nonce: []const u8) ![]u8 {
    const input = try std.fmt.allocPrint(allocator, "{s}258EAFA5-E914-47DA-95CA-C5AB0DC85B11", .{nonce});
    defer allocator.free(input);
    var digest: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(input, &digest, .{});
    const encoded_len = std.base64.standard.Encoder.calcSize(digest.len);
    const out = try allocator.alloc(u8, encoded_len);
    _ = std.base64.standard.Encoder.encode(out, &digest);
    return out;
}

pub fn writeMaskedFrameForTest(writer: anytype, opcode: u8, payload: []const u8) !void {
    try writeMaskedFrame(writer, opcode, payload);
}

pub fn expectedAcceptForTest(allocator: std.mem.Allocator, nonce: []const u8) ![]u8 {
    return expectedAccept(allocator, nonce);
}

pub fn readFrameFromBytesForTest(client: *Client, allocator: std.mem.Allocator, bytes: []const u8) !Frame {
    var reader: std.Io.Reader = .fixed(bytes);
    return readFrameFromReader(client, allocator, &reader);
}

fn writeMaskedFrame(writer: anytype, opcode: u8, payload: []const u8) !void {
    var header: [14]u8 = undefined;
    var header_len: usize = 0;
    header[header_len] = 0x80 | opcode;
    header_len += 1;
    if (payload.len < 126) {
        header[header_len] = 0x80 | @as(u8, @intCast(payload.len));
        header_len += 1;
    } else if (payload.len <= 0xffff) {
        header[header_len] = 0x80 | 126;
        header_len += 1;
        header[header_len] = @intCast((payload.len >> 8) & 0xff);
        header_len += 1;
        header[header_len] = @intCast(payload.len & 0xff);
        header_len += 1;
    } else {
        header[header_len] = 0x80 | 127;
        header_len += 1;
        std.mem.writeInt(u64, header[header_len..][0..8], payload.len, .big);
        header_len += 8;
    }
    var mask: [4]u8 = undefined;
    fillRandomBytes(&mask);
    @memcpy(header[header_len..][0..4], &mask);
    header_len += 4;

    if (payload.len <= 512) {
        var small: [14 + 512]u8 = undefined;
        @memcpy(small[0..header_len], header[0..header_len]);
        for (payload, 0..) |b, i| small[header_len + i] = b ^ mask[i & 3];
        try writer.writeAll(small[0 .. header_len + payload.len]);
        return;
    }

    try writer.writeAll(header[0..header_len]);

    var masked: [4096]u8 = undefined;
    var offset: usize = 0;
    while (offset < payload.len) {
        const n = @min(masked.len, payload.len - offset);
        for (payload[offset..][0..n], 0..) |b, i| {
            masked[i] = b ^ mask[(offset + i) & 3];
        }
        try writer.writeAll(masked[0..n]);
        offset += n;
    }
}

test "terminal setup deadline cancels a stalled WSS TLS handshake" {
    if (@import("builtin").os.tag != .linux or std.http.Client.disable_tls) return error.SkipZigTest;

    const io = std.testing.io;
    var addr = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var listener = try addr.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    var saw_hello = std.atomic.Value(bool).init(false);
    const Peer = struct {
        fn run(server: *std.Io.net.Server, hello: *std.atomic.Value(bool)) !void {
            const stream = try server.accept(std.testing.io);
            defer stream.close(std.testing.io);
            var buffer: [512]u8 = undefined;
            var reader = stream.reader(std.testing.io, &buffer);
            hello.store(try reader.interface.takeByte() == 0x16, .release);
            // Never complete TLS. A bounded setup must close the socket.
            while (reader.interface.takeByte()) |_| {} else |_| {}
        }
    };
    var peer = try io.concurrent(Peer.run, .{ &listener, &saw_hello });
    defer peer.cancel(io) catch {};
    const url = try std.fmt.allocPrint(std.testing.allocator, "wss://127.0.0.1:{d}/terminal", .{listener.socket.address.getPort()});
    defer std.testing.allocator.free(url);
    const started = monotonicMs();
    const cfg = .{
        .ignore_unsafe_cert = false,
        .custom_dns = "",
        .cf_access_client_id = "",
        .cf_access_client_secret = "",
    };
    try std.testing.expectError(error.TerminalConnectDeadline, connectTerminalWithIo(io, std.testing.allocator, url, cfg, started + 1_000));
    try std.testing.expect(saw_hello.load(.acquire));
    try std.testing.expect(monotonicMs() - started < 3_000);
}
