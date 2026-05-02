const std = @import("std");
const types = @import("types.zig");
const builtin = @import("builtin");
const dns = @import("dns");

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

pub fn measure(allocator: std.mem.Allocator, ping_type: []const u8, target: []const u8, custom_dns: []const u8) i64 {
    var best: i64 = -1;
    var attempt: u8 = 0;
    while (attempt < 3) : (attempt += 1) {
        const value = blk: {
            if (std.mem.eql(u8, ping_type, "tcp")) break :blk tcpPing(allocator, target, custom_dns) catch -1;
            if (std.mem.eql(u8, ping_type, "http")) break :blk httpPing(allocator, target, custom_dns) catch -1;
            if (std.mem.eql(u8, ping_type, "icmp")) break :blk icmpPing(allocator, target, custom_dns) catch -1;
            break :blk -1;
        };
        if (value >= 0 and (best < 0 or value < best)) best = value;
        if (value >= 0 and value <= 1000) return value;
    }
    return best;
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

fn icmpPing(allocator: std.mem.Allocator, target: []const u8, custom_dns: []const u8) !i64 {
    if (builtin.os.tag == .windows) return error.Unsupported;
    const addrs = try dns.resolveHost(allocator, parseHostOnly(target), 0, custom_dns);
    defer allocator.free(addrs);
    for (addrs) |addr| {
        if (addr.any.family != std.posix.AF.INET and addr.any.family != std.posix.AF.INET6) continue;
        return icmpPingAddress(addr) catch |err| switch (err) {
            error.AccessDenied => continue,
            else => continue,
        };
    }
    return -1;
}

fn icmpPingAddress(addr: std.net.Address) !i64 {
    if (addr.any.family == std.posix.AF.INET6) return icmp6PingAddress(addr);
    const flags = std.posix.SOCK.DGRAM | if (builtin.os.tag == .linux) std.posix.SOCK.CLOEXEC else 0;
    const sock = std.posix.socket(std.posix.AF.INET, flags, std.posix.IPPROTO.ICMP) catch |err| switch (err) {
        error.AccessDenied => try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.RAW | if (builtin.os.tag == .linux) std.posix.SOCK.CLOEXEC else 0, std.posix.IPPROTO.ICMP),
        else => return err,
    };
    defer std.posix.close(sock);

    var packet: [16]u8 = .{0} ** 16;
    packet[0] = 8;
    packet[1] = 0;
    const ident: u16 = @truncate(@as(u64, @intCast(std.time.milliTimestamp())) & 0xffff);
    const seq: u16 = 1;
    std.mem.writeInt(u16, packet[4..6], ident, .big);
    std.mem.writeInt(u16, packet[6..8], seq, .big);
    std.mem.writeInt(u64, packet[8..16], @truncate(@as(u128, @bitCast(std.time.nanoTimestamp()))), .big);
    const csum = icmpChecksum(&packet);
    std.mem.writeInt(u16, packet[2..4], csum, .big);

    const start = std.time.milliTimestamp();
    _ = try std.posix.sendto(sock, &packet, 0, &addr.any, addr.getOsSockLen());
    var fds = [_]std.posix.pollfd{.{ .fd = sock, .events = std.posix.POLL.IN, .revents = 0 }};
    while (std.time.milliTimestamp() - start < 3000) {
        const left: i32 = @intCast(@max(1, 3000 - (std.time.milliTimestamp() - start)));
        const ready = try std.posix.poll(&fds, left);
        if (ready == 0) return error.Timeout;
        var buf: [1500]u8 = undefined;
        const n = try std.posix.recvfrom(sock, &buf, 0, null, null);
        if (isEchoReply(buf[0..n], ident, seq)) return std.time.milliTimestamp() - start;
    }
    return error.Timeout;
}

fn icmp6PingAddress(addr: std.net.Address) !i64 {
    const flags = std.posix.SOCK.DGRAM | if (builtin.os.tag == .linux) std.posix.SOCK.CLOEXEC else 0;
    const sock = std.posix.socket(std.posix.AF.INET6, flags, std.posix.IPPROTO.ICMPV6) catch |err| switch (err) {
        error.AccessDenied => try std.posix.socket(std.posix.AF.INET6, std.posix.SOCK.RAW | if (builtin.os.tag == .linux) std.posix.SOCK.CLOEXEC else 0, std.posix.IPPROTO.ICMPV6),
        else => return err,
    };
    defer std.posix.close(sock);

    var packet: [16]u8 = .{0} ** 16;
    packet[0] = 128;
    packet[1] = 0;
    const ident: u16 = @truncate(@as(u64, @intCast(std.time.milliTimestamp())) & 0xffff);
    const seq: u16 = 1;
    std.mem.writeInt(u16, packet[4..6], ident, .big);
    std.mem.writeInt(u16, packet[6..8], seq, .big);
    std.mem.writeInt(u64, packet[8..16], @truncate(@as(u128, @bitCast(std.time.nanoTimestamp()))), .big);

    const start = std.time.milliTimestamp();
    _ = try std.posix.sendto(sock, &packet, 0, &addr.any, addr.getOsSockLen());
    var fds = [_]std.posix.pollfd{.{ .fd = sock, .events = std.posix.POLL.IN, .revents = 0 }};
    while (std.time.milliTimestamp() - start < 3000) {
        const left: i32 = @intCast(@max(1, 3000 - (std.time.milliTimestamp() - start)));
        const ready = try std.posix.poll(&fds, left);
        if (ready == 0) return error.Timeout;
        var buf: [1500]u8 = undefined;
        const n = try std.posix.recvfrom(sock, &buf, 0, null, null);
        if (isEchoReply6(buf[0..n], ident, seq)) return std.time.milliTimestamp() - start;
    }
    return error.Timeout;
}

fn isEchoReply(bytes: []const u8, ident: u16, seq: u16) bool {
    var off: usize = 0;
    if (bytes.len >= 20 and (bytes[0] >> 4) == 4) off = (bytes[0] & 0x0f) * 4;
    if (bytes.len < off + 8) return false;
    if (bytes[off] != 0 or bytes[off + 1] != 0) return false;
    const got_ident = (@as(u16, bytes[off + 4]) << 8) | bytes[off + 5];
    const got_seq = (@as(u16, bytes[off + 6]) << 8) | bytes[off + 7];
    return (got_ident == ident or got_ident == 0) and got_seq == seq;
}

fn isEchoReply6(bytes: []const u8, ident: u16, seq: u16) bool {
    var off: usize = 0;
    if (bytes.len >= 40 and (bytes[0] >> 4) == 6) off = 40;
    if (bytes.len < off + 8) return false;
    if (bytes[off] != 129 or bytes[off + 1] != 0) return false;
    const got_ident = (@as(u16, bytes[off + 4]) << 8) | bytes[off + 5];
    const got_seq = (@as(u16, bytes[off + 6]) << 8) | bytes[off + 7];
    return (got_ident == ident or got_ident == 0) and got_seq == seq;
}

pub fn isIcmp6EchoReplyForTest(bytes: []const u8, ident: u16, seq: u16) bool {
    return isEchoReply6(bytes, ident, seq);
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
    const start = std.time.milliTimestamp();
    var last_err: ?anyerror = null;
    for (addrs) |addr| {
        const sock_flags = std.posix.SOCK.STREAM | if (builtin.os.tag == .linux) std.posix.SOCK.CLOEXEC else 0;
        const sock = std.posix.socket(addr.any.family, sock_flags, std.posix.IPPROTO.TCP) catch |err| {
            last_err = err;
            continue;
        };
        std.posix.connect(sock, &addr.any, addr.getOsSockLen()) catch |err| {
            std.posix.close(sock);
            last_err = err;
            continue;
        };
        std.posix.close(sock);
        return std.time.milliTimestamp() - start;
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
    if (custom_dns.len != 0 and (std.mem.startsWith(u8, target, "http://") or std.mem.indexOf(u8, target, "://") == null)) {
        return httpPingPlainWithDns(allocator, target, custom_dns);
    }
    return httpPingStd(allocator, target);
}

fn httpPingPlainWithDns(allocator: std.mem.Allocator, target: []const u8, custom_dns: []const u8) !i64 {
    const url = try normalizeHttpTarget(allocator, target);
    defer allocator.free(url);
    const uri = try std.Uri.parse(url);
    const host_component = uri.host orelse return error.InvalidUrl;
    const host = switch (host_component) {
        .raw => |raw| raw,
        .percent_encoded => |raw| raw,
    };
    const port = uri.port orelse 80;
    const addrs = try dns.resolveHost(allocator, host, port, custom_dns);
    defer allocator.free(addrs);
    const path = uri.path.percent_encoded;

    const start = std.time.milliTimestamp();
    for (addrs) |addr| {
        const sock_flags = std.posix.SOCK.STREAM | if (builtin.os.tag == .linux) std.posix.SOCK.CLOEXEC else 0;
        const sock = std.posix.socket(addr.any.family, sock_flags, std.posix.IPPROTO.TCP) catch continue;
        std.posix.connect(sock, &addr.any, addr.getOsSockLen()) catch {
            std.posix.close(sock);
            continue;
        };
        defer std.posix.close(sock);
        var stream = std.net.Stream{ .handle = sock };
        const request = try std.fmt.allocPrint(allocator, "GET {s} HTTP/1.1\r\nHost: {s}\r\nUser-Agent: komari-zig-agent\r\nConnection: close\r\n\r\n", .{ if (path.len == 0) "/" else path, host });
        defer allocator.free(request);
        try stream.writeAll(request);
        var buf: [64]u8 = undefined;
        const n = try stream.read(&buf);
        const elapsed = std.time.milliTimestamp() - start;
        if (n >= 12 and std.mem.startsWith(u8, buf[0..n], "HTTP/1.") and buf[9] >= '2' and buf[9] <= '3') return elapsed;
        return -1;
    }
    return error.ConnectFailed;
}

fn httpPingStd(allocator: std.mem.Allocator, target: []const u8) !i64 {
    const url = try normalizeHttpTarget(allocator, target);
    defer allocator.free(url);

    const start = std.time.milliTimestamp();
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();
    const result = try client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .keep_alive = false,
    });
    const code = @intFromEnum(result.status);
    const elapsed = std.time.milliTimestamp() - start;
    if (code >= 200 and code < 400) return elapsed;
    return -1;
}
