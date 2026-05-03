const std = @import("std");

pub const net = std.Io.net;
pub const Address = net.IpAddress;
pub const Stream = net.Stream;

pub fn parseIp(text: []const u8, p: u16) !Address {
    return Address.parse(text, p);
}

pub fn parseIpAndPort(text: []const u8) !Address {
    return Address.parseLiteral(text);
}

pub fn initIp4(bytes: [4]u8, p: u16) Address {
    return .{ .ip4 = .{ .bytes = bytes, .port = p } };
}

pub fn initIp6(bytes: [16]u8, p: u16, flow: u32, scope_id: u32) Address {
    return .{ .ip6 = .{
        .bytes = bytes,
        .port = p,
        .flow = flow,
        .interface = .{ .index = scope_id },
    } };
}

pub fn resolveOne(host: []const u8, p: u16) !Address {
    return Address.resolve(std.Options.debug_io, host, p);
}

pub fn family(addr: Address) std.posix.sa_family_t {
    return switch (addr) {
        .ip4 => std.posix.AF.INET,
        .ip6 => std.posix.AF.INET6,
    };
}

pub fn isIpv4(addr: Address) bool {
    return switch (addr) {
        .ip4 => true,
        .ip6 => false,
    };
}

pub fn isIpv6(addr: Address) bool {
    return switch (addr) {
        .ip4 => false,
        .ip6 => true,
    };
}

pub fn getPort(addr: Address) u16 {
    return addr.getPort();
}

pub fn connect(addr: Address) !Stream {
    return addr.connect(std.Options.debug_io, .{ .mode = .stream });
}

pub fn close(stream: Stream) void {
    stream.close(std.Options.debug_io);
}

pub fn reader(stream: Stream, buffer: []u8) Stream.Reader {
    return stream.reader(std.Options.debug_io, buffer);
}

pub fn writer(stream: Stream, buffer: []u8) Stream.Writer {
    return stream.writer(std.Options.debug_io, buffer);
}

pub const SockAddr = struct {
    storage: std.posix.sockaddr.storage = undefined,
    len: std.posix.socklen_t,

    pub fn ptr(self: *const SockAddr) *const std.posix.sockaddr {
        return @ptrCast(@alignCast(&self.storage));
    }
};

pub fn sockAddr(addr: Address) SockAddr {
    var out: SockAddr = undefined;
    switch (addr) {
        .ip4 => |ip4| {
            const sa = std.posix.sockaddr.in{
                .port = std.mem.nativeToBig(u16, ip4.port),
                .addr = std.mem.readInt(u32, &ip4.bytes, .big),
            };
            out.storage = undefined;
            @memset(std.mem.asBytes(&out.storage), 0);
            @memcpy(std.mem.asBytes(&out.storage)[0..@sizeOf(@TypeOf(sa))], std.mem.asBytes(&sa));
            out.len = @sizeOf(@TypeOf(sa));
        },
        .ip6 => |ip6| {
            const sa = std.posix.sockaddr.in6{
                .port = std.mem.nativeToBig(u16, ip6.port),
                .flowinfo = ip6.flow,
                .addr = ip6.bytes,
                .scope_id = ip6.interface.index,
            };
            out.storage = undefined;
            @memset(std.mem.asBytes(&out.storage), 0);
            @memcpy(std.mem.asBytes(&out.storage)[0..@sizeOf(@TypeOf(sa))], std.mem.asBytes(&sa));
            out.len = @sizeOf(@TypeOf(sa));
        },
    }
    return out;
}
