const std = @import("std");
const builtin = @import("builtin");
const net = @import("net");
const compat = @import("compat");

const fallback_servers = [_][]const u8{
    "[2606:4700:4700::1111]:53",
    "[2606:4700:4700::1001]:53",
    "[2001:4860:4860::8888]:53",
    "[2001:4860:4860::8844]:53",
    "114.114.114.114:53",
    "1.1.1.1:53",
    "8.8.8.8:53",
    "8.8.4.4:53",
    "223.5.5.5:53",
    "119.29.29.29:53",
};

/// DNS resolution helpers with custom resolver fallback and address ordering.
pub fn normalizeDnsServer(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    const s = std.mem.trim(u8, input, " \t\r\n");
    if (s.len == 0) return allocator.dupe(u8, "");
    if (std.mem.startsWith(u8, s, "[") and std.mem.indexOf(u8, s, "]:") != null) {
        return allocator.dupe(u8, s);
    }
    if (std.mem.count(u8, s, ":") == 1) {
        return allocator.dupe(u8, s);
    }
    if (std.mem.count(u8, s, ":") >= 2) {
        return std.fmt.allocPrint(allocator, "[{s}]:53", .{s});
    }
    return std.fmt.allocPrint(allocator, "{s}:53", .{s});
}

pub fn resolveHost(allocator: std.mem.Allocator, host: []const u8, port: u16, custom_dns: []const u8) ![]net.Address {
    const trimmed = std.mem.trim(u8, host, "[]");
    if (net.parseIp(trimmed, port)) |addr| {
        const out = try allocator.alloc(net.Address, 1);
        out[0] = addr;
        return out;
    } else |_| {}

    if (custom_dns.len == 0 or builtin.os.tag == .windows) {
        const out = try net.resolveAll(allocator, trimmed, port);
        sortAddresses(out);
        return out;
    }

    const normalized = try normalizeDnsServer(allocator, custom_dns);
    defer allocator.free(normalized);
    return resolveWithServers(allocator, trimmed, port, &.{normalized}) catch
        resolveWithServers(allocator, trimmed, port, &fallback_servers);
}

fn resolveWithServers(allocator: std.mem.Allocator, host: []const u8, port: u16, servers: []const []const u8) ![]net.Address {
    for (servers) |server| {
        if (queryServer(allocator, server, host, port)) |addrs| {
            if (addrs.len != 0) {
                sortAddresses(addrs);
                return addrs;
            }
            allocator.free(addrs);
        } else |_| {}
    }
    return error.DnsResolveFailed;
}

fn queryServer(allocator: std.mem.Allocator, server: []const u8, host: []const u8, port: u16) ![]net.Address {
    var server_addr = net.parseIpAndPort(server) catch blk: {
        const parsed = parseHostPort(server);
        break :blk net.resolveOne(parsed.host, parsed.port) catch return error.DnsServerResolveFailed;
    };
    const addr_family = net.family(server_addr);
    const sock = try udpSocket(addr_family);
    defer compat.closeFd(sock);

    var fds = [_]std.posix.pollfd{.{ .fd = sock, .events = std.posix.POLL.IN, .revents = 0 }};
    var out: std.ArrayList(net.Address) = .empty;
    defer out.deinit(allocator);
    try queryType(allocator, sock, &server_addr, &fds, host, port, 0x4b5a, 1, &out);
    try queryType(allocator, sock, &server_addr, &fds, host, port, 0x4b5b, 28, &out);
    return out.toOwnedSlice(allocator);
}

fn udpSocket(addr_family: std.posix.sa_family_t) !std.posix.fd_t {
    const flags = std.posix.SOCK.DGRAM | if (builtin.os.tag == .linux) std.posix.SOCK.CLOEXEC else 0;
    if (builtin.os.tag == .linux) {
        const rc = std.os.linux.socket(@intCast(addr_family), @intCast(flags), @intCast(std.posix.IPPROTO.UDP));
        return switch (std.posix.errno(rc)) {
            .SUCCESS => @intCast(rc),
            else => |err| std.posix.unexpectedErrno(err),
        };
    }
    const rc = std.c.socket(@intCast(addr_family), @intCast(flags), @intCast(std.posix.IPPROTO.UDP));
    return switch (std.posix.errno(rc)) {
        .SUCCESS => @intCast(rc),
        else => |err| std.posix.unexpectedErrno(err),
    };
}

fn queryType(
    allocator: std.mem.Allocator,
    sock: std.posix.socket_t,
    server_addr: *const net.Address,
    fds: []std.posix.pollfd,
    host: []const u8,
    port: u16,
    id: u16,
    qtype: u16,
    out: *std.ArrayList(net.Address),
) !void {
    const request = try buildQuery(allocator, host, id, qtype);
    defer allocator.free(request);
    const sa = net.sockAddr(server_addr.*);
    _ = try sendTo(sock, request, sa.ptr(), sa.len);
    if (fds.len != 0) fds[0].revents = 0;
    const ready = try std.posix.poll(fds, 3000);
    if (ready == 0) return;
    var buf: [1500]u8 = undefined;
    const n = try recvFrom(sock, &buf);
    parseResponse(allocator, buf[0..n], id, port, out) catch {};
}

fn sendTo(sock: std.posix.fd_t, bytes: []const u8, addr: *const std.posix.sockaddr, len: std.posix.socklen_t) !usize {
    if (builtin.os.tag == .linux) {
        const rc = std.os.linux.sendto(sock, bytes.ptr, bytes.len, 0, addr, len);
        return switch (std.posix.errno(rc)) {
            .SUCCESS => rc,
            else => |err| std.posix.unexpectedErrno(err),
        };
    }
    const rc = std.c.sendto(sock, bytes.ptr, bytes.len, 0, addr, len);
    return switch (std.posix.errno(rc)) {
        .SUCCESS => @intCast(rc),
        else => |err| std.posix.unexpectedErrno(err),
    };
}

fn recvFrom(sock: std.posix.fd_t, buf: []u8) !usize {
    if (builtin.os.tag == .linux) {
        const rc = std.os.linux.recvfrom(sock, buf.ptr, buf.len, 0, null, null);
        return switch (std.posix.errno(rc)) {
            .SUCCESS => rc,
            else => |err| std.posix.unexpectedErrno(err),
        };
    }
    const rc = std.c.recvfrom(sock, buf.ptr, buf.len, 0, null, null);
    return switch (std.posix.errno(rc)) {
        .SUCCESS => @intCast(rc),
        else => |err| std.posix.unexpectedErrno(err),
    };
}

const HostPort = struct { host: []const u8, port: u16 };

fn parseHostPort(value: []const u8) HostPort {
    if (std.mem.startsWith(u8, value, "[")) {
        if (std.mem.indexOfScalar(u8, value, ']')) |idx| {
            const port = if (idx + 2 < value.len and value[idx + 1] == ':') std.fmt.parseInt(u16, value[idx + 2 ..], 10) catch 53 else 53;
            return .{ .host = value[1..idx], .port = port };
        }
    }
    if (std.mem.lastIndexOfScalar(u8, value, ':')) |idx| {
        if (std.mem.indexOfScalar(u8, value[0..idx], ':') == null) {
            return .{ .host = value[0..idx], .port = std.fmt.parseInt(u16, value[idx + 1 ..], 10) catch 53 };
        }
    }
    return .{ .host = value, .port = 53 };
}

fn buildQuery(allocator: std.mem.Allocator, host: []const u8, id: u16, qtype: u16) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try out.appendNTimes(allocator, 0, 12);
    std.mem.writeInt(u16, out.items[0..2], id, .big);
    std.mem.writeInt(u16, out.items[2..4], 0x0100, .big);
    std.mem.writeInt(u16, out.items[4..6], 1, .big);
    var labels = std.mem.splitScalar(u8, host, '.');
    while (labels.next()) |label| {
        if (label.len == 0 or label.len > 63) return error.InvalidDnsName;
        try out.append(allocator, @intCast(label.len));
        try out.appendSlice(allocator, label);
    }
    try out.append(allocator, 0);
    try writeU16(&out, allocator, qtype);
    try writeU16(&out, allocator, 1);
    return out.toOwnedSlice(allocator);
}

fn parseResponse(allocator: std.mem.Allocator, bytes: []const u8, id: u16, port: u16, out: *std.ArrayList(net.Address)) !void {
    if (bytes.len < 12 or std.mem.readInt(u16, bytes[0..2], .big) != id) return error.InvalidDnsResponse;
    const qd = std.mem.readInt(u16, bytes[4..6], .big);
    const an = std.mem.readInt(u16, bytes[6..8], .big);
    var off: usize = 12;
    var i: u16 = 0;
    while (i < qd) : (i += 1) {
        off = try skipName(bytes, off);
        if (off + 4 > bytes.len) return error.InvalidDnsResponse;
        off += 4;
    }
    i = 0;
    while (i < an) : (i += 1) {
        off = try skipName(bytes, off);
        if (off + 10 > bytes.len) return error.InvalidDnsResponse;
        const typ = std.mem.readInt(u16, bytes[off..][0..2], .big);
        const class = std.mem.readInt(u16, bytes[off + 2 ..][0..2], .big);
        const rdlen = std.mem.readInt(u16, bytes[off + 8 ..][0..2], .big);
        off += 10;
        if (off + rdlen > bytes.len) return error.InvalidDnsResponse;
        if (class == 1 and typ == 1 and rdlen == 4) {
            try out.append(allocator, net.initIp4(bytes[off..][0..4].*, port));
        } else if (class == 1 and typ == 28 and rdlen == 16) {
            try out.append(allocator, net.initIp6(bytes[off..][0..16].*, port, 0, 0));
        }
        off += rdlen;
    }
}

fn skipName(bytes: []const u8, start: usize) !usize {
    var off = start;
    while (true) {
        if (off >= bytes.len) return error.InvalidDnsResponse;
        const len = bytes[off];
        if ((len & 0xc0) == 0xc0) {
            if (off + 2 > bytes.len) return error.InvalidDnsResponse;
            return off + 2;
        }
        off += 1;
        if (len == 0) return off;
        off += len;
        if (off > bytes.len) return error.InvalidDnsResponse;
    }
}

fn writeU16(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u16) !void {
    var buf: [2]u8 = undefined;
    std.mem.writeInt(u16, &buf, value, .big);
    try out.appendSlice(allocator, &buf);
}

fn sortAddresses(addrs: []net.Address) void {
    const prefer_v4 = preferIPv4First();
    std.mem.sort(net.Address, addrs, prefer_v4, struct {
        fn lessThan(prefer: bool, a: net.Address, b: net.Address) bool {
            const a_v4 = net.isIpv4(a);
            const b_v4 = net.isIpv4(b);
            if (a_v4 == b_v4) return false;
            return if (prefer) a_v4 else !a_v4;
        }
    }.lessThan);
}

fn preferIPv4First() bool {
    return switch (builtin.os.tag) {
        .linux => hasLinuxIPv4Route(),
        else => true,
    };
}

fn hasLinuxIPv4Route() bool {
    const file = compat.openFile("/proc/net/route", .{}) catch return true;
    defer file.close(std.Options.debug_io);
    var buf: [8192]u8 = undefined;
    const n = compat.readAll(file, &buf) catch return true;
    var lines = std.mem.splitScalar(u8, buf[0..n], '\n');
    _ = lines.next();
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeAny(u8, line, " \t\r\n");
        const iface = fields.next() orelse continue;
        if (std.mem.eql(u8, iface, "lo")) continue;
        _ = fields.next() orelse continue;
        _ = fields.next() orelse continue;
        const flags_hex = fields.next() orelse continue;
        const flags = std.fmt.parseInt(u32, flags_hex, 16) catch continue;
        if ((flags & 0x1) != 0) return true;
    }
    return false;
}
