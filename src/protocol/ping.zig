const std = @import("std");
const types = @import("types.zig");
const builtin = @import("builtin");
const dns = @import("dns");
const raw_conn = @import("raw_conn.zig");
const net = @import("net");
const compat = @import("compat");

/// Ping task implementations for ICMP, TCP, and HTTP probes.
pub const TcpTarget = struct {
    host: []const u8,
    port: []const u8,
};

const PingKind = enum {
    tcp,
    http,
    icmp,
};

const IcmpMode = enum {
    auto,
    raw,
    datagram,
};

// Concurrent ICMP tasks need unique request markers so replies are not
// accidentally consumed by a sibling socket on the same host. Keep the atomic
// counter 32-bit so cross-compiles to 32-bit targets can still use fetchAdd.
var icmp_probe_counter = std.atomic.Value(u32).init(1);

const IcmpProbeIdentity = struct {
    ident: u16,
    seq: u16,
    payload: [8]u8,
};

pub fn allocPingResultJson(allocator: std.mem.Allocator, task_id: u64, ping_type: []const u8, value: i64, finished_at: []const u8) ![]const u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    try types.writePingResultJson(&out.writer, .{
        .task_id = task_id,
        .ping_type = ping_type,
        .value = value,
        .finished_at = finished_at,
    });
    return out.toOwnedSlice();
}

pub fn measure(allocator: std.mem.Allocator, ping_type: []const u8, target: []const u8, custom_dns: []const u8) i64 {
    return measureWithIcmpMode(allocator, ping_type, target, custom_dns, .auto);
}

pub fn measureDiagnostic(allocator: std.mem.Allocator, ping_type: []const u8, target: []const u8, custom_dns: []const u8, icmp_mode: []const u8) i64 {
    return measureWithIcmpMode(allocator, ping_type, target, custom_dns, parseIcmpMode(icmp_mode) orelse .auto);
}

fn measureWithIcmpMode(allocator: std.mem.Allocator, ping_type: []const u8, target: []const u8, custom_dns: []const u8, icmp_mode: IcmpMode) i64 {
    const kind = normalizePingType(ping_type) orelse return -1;
    const attempts = 3;
    var best: ?i64 = null;

    var attempt: usize = 0;
    while (attempt < attempts) : (attempt += 1) {
        const value = measureOnce(allocator, kind, target, custom_dns, icmp_mode);
        if (value >= 0) {
            best = if (best) |current| @min(current, value) else value;
        }
    }

    return best orelse -1;
}

pub fn bestLatencyFromSamplesForTest(samples: []const i64) i64 {
    var best: ?i64 = null;
    for (samples) |value| {
        if (value >= 0) {
            best = if (best) |current| @min(current, value) else value;
        }
    }
    return best orelse -1;
}

fn measureOnce(allocator: std.mem.Allocator, kind: PingKind, target: []const u8, custom_dns: []const u8, icmp_mode: IcmpMode) i64 {
    return switch (kind) {
        .tcp => tcpPing(allocator, target, custom_dns) catch -1,
        .http => httpPing(allocator, target, custom_dns) catch -1,
        .icmp => icmpPing(allocator, target, custom_dns, icmp_mode) catch -1,
    };
}

fn parseIcmpMode(value: []const u8) ?IcmpMode {
    if (value.len == 0 or std.ascii.eqlIgnoreCase(value, "auto")) return .auto;
    if (std.ascii.eqlIgnoreCase(value, "raw") or std.ascii.eqlIgnoreCase(value, "privileged")) return .raw;
    if (std.ascii.eqlIgnoreCase(value, "datagram") or std.ascii.eqlIgnoreCase(value, "dgram") or std.ascii.eqlIgnoreCase(value, "ping_socket")) return .datagram;
    return null;
}

fn normalizePingType(ping_type: []const u8) ?PingKind {
    if (std.ascii.eqlIgnoreCase(ping_type, "tcp") or
        std.ascii.eqlIgnoreCase(ping_type, "tcp_ping") or
        std.ascii.eqlIgnoreCase(ping_type, "tcping"))
    {
        return .tcp;
    }
    if (std.ascii.eqlIgnoreCase(ping_type, "http") or
        std.ascii.eqlIgnoreCase(ping_type, "http_ping") or
        std.ascii.eqlIgnoreCase(ping_type, "httping"))
    {
        return .http;
    }
    if (std.ascii.eqlIgnoreCase(ping_type, "icmp") or
        std.ascii.eqlIgnoreCase(ping_type, "icmp_ping") or
        std.ascii.eqlIgnoreCase(ping_type, "ping"))
    {
        return .icmp;
    }
    return null;
}

pub fn normalizePingTypeForTest(ping_type: []const u8) ?[]const u8 {
    return switch (normalizePingType(ping_type) orelse return null) {
        .tcp => "tcp",
        .http => "http",
        .icmp => "icmp",
    };
}

pub fn icmpChecksum(bytes: []const u8) u16 {
    var sum: u32 = 0;
    var i: usize = 0;
    while (i + 1 < bytes.len) : (i += 2) {
        sum += (@as(u32, bytes[i]) << 8) | bytes[i + 1];
    }
    if (i < bytes.len) sum += @as(u32, bytes[i]) << 8;
    while ((sum >> 16) != 0) sum = (sum & 0xffff) + (sum >> 16);
    return @as(u16, @intCast(~sum & 0xffff));
}

fn icmpProbeIdentityFromNonce(nonce: u64) IcmpProbeIdentity {
    const value = if (nonce == 0) 1 else nonce;
    var payload: [8]u8 = undefined;
    std.mem.writeInt(u64, payload[0..], value, .big);
    return .{
        .ident = @truncate(value >> 16),
        .seq = @truncate(value),
        .payload = payload,
    };
}

fn nextIcmpProbeIdentity() IcmpProbeIdentity {
    return icmpProbeIdentityFromNonce(@as(u64, icmp_probe_counter.fetchAdd(1, .monotonic)));
}

pub fn icmpProbeIdentityForTest(nonce: u64) IcmpProbeIdentity {
    return icmpProbeIdentityFromNonce(nonce);
}

fn icmpPing(allocator: std.mem.Allocator, target: []const u8, custom_dns: []const u8, icmp_mode: IcmpMode) !i64 {
    if (builtin.os.tag == .windows) return error.Unsupported;
    const addrs = try dns.resolveHost(allocator, parseHostOnly(target), 0, custom_dns);
    defer allocator.free(addrs);
    for (addrs) |addr| {
        if (!net.isIpv4(addr) and !net.isIpv6(addr)) continue;
        return icmpPingAddress(addr, icmp_mode) catch |err| switch (err) {
            error.AccessDenied => continue,
            else => continue,
        };
    }
    return -1;
}

fn icmpPingAddress(addr: net.Address, icmp_mode: IcmpMode) !i64 {
    if (net.isIpv6(addr)) return icmp6PingAddress(addr, icmp_mode);
    const opened = try openIcmp4Socket(icmp_mode);
    const sock = opened.fd;
    const privileged = opened.privileged;
    defer compat.closeFd(sock);

    var packet: [16]u8 = .{0} ** 16;
    const probe = nextIcmpProbeIdentity();
    packet[0] = 8;
    packet[1] = 0;
    std.mem.writeInt(u16, packet[4..6], probe.ident, .big);
    std.mem.writeInt(u16, packet[6..8], probe.seq, .big);
    @memcpy(packet[8..16], probe.payload[0..]);
    const payload = packet[8..16];
    const csum = icmpChecksum(&packet);
    std.mem.writeInt(u16, packet[2..4], csum, .big);

    const start = compat.milliTimestamp();
    const sa = net.sockAddr(addr);
    _ = try compat.sendTo(sock, &packet, sa.ptr(), sa.len);
    var fds = [_]std.posix.pollfd{.{ .fd = sock, .events = std.posix.POLL.IN, .revents = 0 }};
    while (compat.milliTimestamp() - start < 3000) {
        const left: i32 = @intCast(@max(1, 3000 - (compat.milliTimestamp() - start)));
        const ready = try std.posix.poll(&fds, left);
        if (ready == 0) return error.Timeout;
        var buf: [1500]u8 = undefined;
        const n = try compat.recvFrom(sock, &buf);
        if (isEchoReply(buf[0..n], probe.ident, probe.seq, payload, privileged)) return compat.milliTimestamp() - start;
    }
    return error.Timeout;
}

const IcmpSocket = struct {
    fd: std.posix.fd_t,
    privileged: bool,
};

fn openIcmp4Socket(icmp_mode: IcmpMode) !IcmpSocket {
    const dgram_flags = std.posix.SOCK.DGRAM | if (builtin.os.tag == .linux) std.posix.SOCK.CLOEXEC else 0;
    const raw_flags = std.posix.SOCK.RAW | if (builtin.os.tag == .linux) std.posix.SOCK.CLOEXEC else 0;
    return switch (icmp_mode) {
        .raw => .{ .fd = try compat.socket(std.posix.AF.INET, raw_flags, std.posix.IPPROTO.ICMP), .privileged = true },
        .datagram => .{ .fd = try compat.socket(std.posix.AF.INET, dgram_flags, std.posix.IPPROTO.ICMP), .privileged = false },
        .auto => blk: {
            const raw = compat.socket(std.posix.AF.INET, raw_flags, std.posix.IPPROTO.ICMP) catch |err| switch (err) {
                error.AccessDenied => break :blk .{ .fd = try compat.socket(std.posix.AF.INET, dgram_flags, std.posix.IPPROTO.ICMP), .privileged = false },
                else => return err,
            };
            break :blk .{ .fd = raw, .privileged = true };
        },
    };
}

fn icmp6PingAddress(addr: net.Address, icmp_mode: IcmpMode) !i64 {
    const opened = try openIcmp6Socket(icmp_mode);
    const sock = opened.fd;
    const privileged = opened.privileged;
    defer compat.closeFd(sock);

    var packet: [16]u8 = .{0} ** 16;
    const probe = nextIcmpProbeIdentity();
    packet[0] = 128;
    packet[1] = 0;
    std.mem.writeInt(u16, packet[4..6], probe.ident, .big);
    std.mem.writeInt(u16, packet[6..8], probe.seq, .big);
    @memcpy(packet[8..16], probe.payload[0..]);
    const payload = packet[8..16];

    const start = compat.milliTimestamp();
    const sa = net.sockAddr(addr);
    _ = try compat.sendTo(sock, &packet, sa.ptr(), sa.len);
    var fds = [_]std.posix.pollfd{.{ .fd = sock, .events = std.posix.POLL.IN, .revents = 0 }};
    while (compat.milliTimestamp() - start < 3000) {
        const left: i32 = @intCast(@max(1, 3000 - (compat.milliTimestamp() - start)));
        const ready = try std.posix.poll(&fds, left);
        if (ready == 0) return error.Timeout;
        var buf: [1500]u8 = undefined;
        const n = try compat.recvFrom(sock, &buf);
        if (isEchoReply6(buf[0..n], probe.ident, probe.seq, payload, privileged)) return compat.milliTimestamp() - start;
    }
    return error.Timeout;
}

fn openIcmp6Socket(icmp_mode: IcmpMode) !IcmpSocket {
    const dgram_flags = std.posix.SOCK.DGRAM | if (builtin.os.tag == .linux) std.posix.SOCK.CLOEXEC else 0;
    const raw_flags = std.posix.SOCK.RAW | if (builtin.os.tag == .linux) std.posix.SOCK.CLOEXEC else 0;
    return switch (icmp_mode) {
        .raw => .{ .fd = try compat.socket(std.posix.AF.INET6, raw_flags, std.posix.IPPROTO.ICMPV6), .privileged = true },
        .datagram => .{ .fd = try compat.socket(std.posix.AF.INET6, dgram_flags, std.posix.IPPROTO.ICMPV6), .privileged = false },
        .auto => blk: {
            const raw = compat.socket(std.posix.AF.INET6, raw_flags, std.posix.IPPROTO.ICMPV6) catch |err| switch (err) {
                error.AccessDenied => break :blk .{ .fd = try compat.socket(std.posix.AF.INET6, dgram_flags, std.posix.IPPROTO.ICMPV6), .privileged = false },
                else => return err,
            };
            break :blk .{ .fd = raw, .privileged = true };
        },
    };
}

fn isEchoReply(bytes: []const u8, ident: u16, seq: u16, payload: []const u8, privileged: bool) bool {
    var off: usize = 0;
    if (bytes.len >= 20 and (bytes[0] >> 4) == 4) off = (bytes[0] & 0x0f) * 4;
    if (bytes.len < off + 8) return false;
    if (bytes[off] != 0 or bytes[off + 1] != 0) return false;
    if (privileged) {
        const got_ident = (@as(u16, bytes[off + 4]) << 8) | bytes[off + 5];
        if (got_ident != ident) return false;
    }
    const got_seq = (@as(u16, bytes[off + 6]) << 8) | bytes[off + 7];
    if (got_seq != seq) return false;
    const body = bytes[off + 8 ..];
    return body.len == payload.len and std.mem.eql(u8, body, payload);
}

fn isEchoReply6(bytes: []const u8, ident: u16, seq: u16, payload: []const u8, privileged: bool) bool {
    var off: usize = 0;
    if (bytes.len >= 40 and (bytes[0] >> 4) == 6) off = 40;
    if (bytes.len < off + 8) return false;
    if (bytes[off] != 129 or bytes[off + 1] != 0) return false;
    if (privileged) {
        const got_ident = (@as(u16, bytes[off + 4]) << 8) | bytes[off + 5];
        if (got_ident != ident) return false;
    }
    const got_seq = (@as(u16, bytes[off + 6]) << 8) | bytes[off + 7];
    if (got_seq != seq) return false;
    const body = bytes[off + 8 ..];
    return body.len == payload.len and std.mem.eql(u8, body, payload);
}

pub fn isIcmpEchoReplyForTest(bytes: []const u8, ident: u16, seq: u16, payload: []const u8, privileged: bool) bool {
    return isEchoReply(bytes, ident, seq, payload, privileged);
}

pub fn isIcmp6EchoReplyForTest(bytes: []const u8, ident: u16, seq: u16, payload: []const u8, privileged: bool) bool {
    return isEchoReply6(bytes, ident, seq, payload, privileged);
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

fn tcpPing(allocator: std.mem.Allocator, target: []const u8, custom_dns: []const u8) !i64 {
    const parsed = try parseTcpTarget(target);
    const port = try std.fmt.parseInt(u16, parsed.port, 10);
    const addrs = try dns.resolveHost(allocator, parsed.host, port, custom_dns);
    defer allocator.free(addrs);
    const start = compat.milliTimestamp();
    var last_err: ?anyerror = null;
    for (addrs) |addr| {
        const stream = net.connect(addr) catch |err| {
            last_err = err;
            continue;
        };
        net.close(stream);
        return compat.milliTimestamp() - start;
    }
    return last_err orelse error.ConnectFailed;
}

fn parseHostOnly(target: []const u8) []const u8 {
    if (std.mem.startsWith(u8, target, "[")) {
        if (std.mem.indexOfScalar(u8, target, ']')) |idx| return target[1..idx];
    }
    if (std.mem.lastIndexOfScalar(u8, target, ':')) |idx| {
        if (std.mem.indexOfScalar(u8, target[0..idx], ':') == null) return target[0..idx];
    }
    return target;
}

fn httpPing(allocator: std.mem.Allocator, target: []const u8, custom_dns: []const u8) !i64 {
    const url = try normalizeHttpTarget(allocator, target);
    defer allocator.free(url);
    const uri = try std.Uri.parse(url);
    const host_component = uri.host orelse return error.InvalidUrl;
    const host_raw = switch (host_component) {
        .raw => |raw| raw,
        .percent_encoded => |raw| raw,
    };
    const host = std.mem.trim(u8, host_raw, "[]");
    const use_tls = std.mem.eql(u8, uri.scheme, "https");
    const port: u16 = uri.port orelse if (use_tls) @as(u16, 443) else @as(u16, 80);
    const addrs = try dns.resolveHost(allocator, host, port, custom_dns);
    defer allocator.free(addrs);
    const path = try uriPathQuery(allocator, uri);
    defer allocator.free(path);

    const start = compat.milliTimestamp();
    for (addrs) |addr| {
        var conn = raw_conn.RawConn.connectResolved(allocator, addr, host, use_tls, false) catch continue;
        defer conn.close();
        const request = try std.fmt.allocPrint(allocator, "GET {s} HTTP/1.1\r\nHost: {s}\r\nUser-Agent: komari-zig-agent\r\nConnection: close\r\n\r\n", .{ path, host_raw });
        defer allocator.free(request);
        try conn.writer().writeAll(request);
        try conn.flush();
        var buf: [64]u8 = undefined;
        const n = try conn.reader().readSliceShort(&buf);
        const elapsed = compat.milliTimestamp() - start;
        if (n >= 12 and std.mem.startsWith(u8, buf[0..n], "HTTP/1.")) return elapsed;
        return -1;
    }
    return error.ConnectFailed;
}

fn uriPathQuery(allocator: std.mem.Allocator, uri: std.Uri) ![]const u8 {
    const path = if (uri.path.percent_encoded.len == 0) "/" else uri.path.percent_encoded;
    if (uri.query) |query| return std.fmt.allocPrint(allocator, "{s}?{s}", .{ path, query.percent_encoded });
    return allocator.dupe(u8, path);
}
