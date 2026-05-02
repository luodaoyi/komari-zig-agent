const std = @import("std");
const builtin = @import("builtin");

const fallback_servers = [_][]const u8{
    "1.1.1.1:53",
    "8.8.8.8:53",
    "114.114.114.114:53",
    "[2606:4700:4700::1111]:53",
};

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

pub fn resolveHost(allocator: std.mem.Allocator, host: []const u8, port: u16, custom_dns: []const u8) ![]std.net.Address {
    const trimmed = std.mem.trim(u8, host, "[]");
    if (std.net.Address.parseIp(trimmed, port)) |addr| {
        const out = try allocator.alloc(std.net.Address, 1);
        out[0] = addr;
        return out;
    } else |_| {}

    if (custom_dns.len == 0 or builtin.os.tag == .windows) {
        var list = try std.net.getAddressList(allocator, trimmed, port);
        defer list.deinit();
        const out = try allocator.dupe(std.net.Address, list.addrs);
        sortAddresses(out);
        return out;
    }

    const normalized = try normalizeDnsServer(allocator, custom_dns);
    defer allocator.free(normalized);
    return resolveWithServers(allocator, trimmed, port, &.{ normalized }) catch
        resolveWithServers(allocator, trimmed, port, &fallback_servers);
}

fn resolveWithServers(allocator: std.mem.Allocator, host: []const u8, port: u16, servers: []const []const u8) ![]std.net.Address {
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

fn queryServer(allocator: std.mem.Allocator, server: []const u8, host: []const u8, port: u16) ![]std.net.Address {
    var server_addr = std.net.Address.parseIpAndPort(server) catch blk: {
        const parsed = parseHostPort(server);
        var list = try std.net.getAddressList(allocator, parsed.host, parsed.port);
        defer list.deinit();
        if (list.addrs.len == 0) return error.DnsServerResolveFailed;
        break :blk list.addrs[0];
    };
    const family = server_addr.any.family;
    const flags = std.posix.SOCK.DGRAM | if (builtin.os.tag == .linux) std.posix.SOCK.CLOEXEC else 0;
    const sock = try std.posix.socket(family, flags, std.posix.IPPROTO.UDP);
    defer std.posix.close(sock);

    const request = try buildQuery(allocator, host, 0x4b5a, 1);
    defer allocator.free(request);
    _ = try std.posix.sendto(sock, request, 0, &server_addr.any, server_addr.getOsSockLen());
    var fds = [_]std.posix.pollfd{.{ .fd = sock, .events = std.posix.POLL.IN, .revents = 0 }};
    const ready = try std.posix.poll(&fds, 3000);
    if (ready == 0) return error.Timeout;
    var buf: [1500]u8 = undefined;
    const n = try std.posix.recvfrom(sock, &buf, 0, null, null);

    var out: std.ArrayList(std.net.Address) = .empty;
    defer out.deinit(allocator);
    try parseResponse(allocator, buf[0..n], 0x4b5a, port, &out);
    if (out.items.len == 0) {
        const request6 = try buildQuery(allocator, host, 0x4b5b, 28);
        defer allocator.free(request6);
        _ = try std.posix.sendto(sock, request6, 0, &server_addr.any, server_addr.getOsSockLen());
        const ready6 = try std.posix.poll(&fds, 3000);
        if (ready6 != 0) {
            const n6 = try std.posix.recvfrom(sock, &buf, 0, null, null);
            try parseResponse(allocator, buf[0..n6], 0x4b5b, port, &out);
        }
    }
    return out.toOwnedSlice(allocator);
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

fn parseResponse(allocator: std.mem.Allocator, bytes: []const u8, id: u16, port: u16, out: *std.ArrayList(std.net.Address)) !void {
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
            try out.append(allocator, std.net.Address.initIp4(bytes[off..][0..4].*, port));
        } else if (class == 1 and typ == 28 and rdlen == 16) {
            try out.append(allocator, std.net.Address.initIp6(bytes[off..][0..16].*, port, 0, 0));
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

fn sortAddresses(addrs: []std.net.Address) void {
    std.mem.sort(std.net.Address, addrs, {}, struct {
        fn lessThan(_: void, a: std.net.Address, b: std.net.Address) bool {
            return a.any.family == std.posix.AF.INET and b.any.family != std.posix.AF.INET;
        }
    }.lessThan);
}
