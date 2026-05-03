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

pub fn resolveAll(allocator: std.mem.Allocator, host: []const u8, p: u16) ![]Address {
    const host_name = try net.HostName.init(host);
    var lookup_buffer: [32]net.HostName.LookupResult = undefined;
    var lookup_queue: std.Io.Queue(net.HostName.LookupResult) = .init(&lookup_buffer);
    try net.HostName.lookup(host_name, std.Options.debug_io, &lookup_queue, .{ .port = p });
    var out: std.ArrayList(Address) = .empty;
    errdefer out.deinit(allocator);
    while (lookup_queue.getOne(std.Options.debug_io)) |result| {
        switch (result) {
            .address => |addr| try out.append(allocator, addr),
            .canonical_name => {},
        }
    } else |err| {
        switch (err) {
            error.Closed => {},
            error.Canceled => return err,
        }
    }
    if (out.items.len == 0) return error.UnknownHostName;
    return out.toOwnedSlice(allocator);
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

const PosixAddress = extern union {
    any: std.posix.sockaddr,
    in: std.posix.sockaddr.in,
    in6: std.posix.sockaddr.in6,
};

pub fn sockAddr(addr: Address) SockAddr {
    var out: SockAddr = undefined;
    var posix_addr: PosixAddress = undefined;
    out.len = addressToPosix(addr, &posix_addr);
    out.storage = undefined;
    @memset(std.mem.asBytes(&out.storage), 0);
    @memcpy(std.mem.asBytes(&out.storage)[0..out.len], std.mem.asBytes(&posix_addr)[0..out.len]);
    return out;
}

fn addressToPosix(addr: Address, storage: *PosixAddress) std.posix.socklen_t {
    return switch (addr) {
        .ip4 => |ip4| {
            storage.in = .{
                .port = std.mem.nativeToBig(u16, ip4.port),
                .addr = @bitCast(ip4.bytes),
            };
            return @sizeOf(std.posix.sockaddr.in);
        },
        .ip6 => |ip6| {
            storage.in6 = .{
                .port = std.mem.nativeToBig(u16, ip6.port),
                .flowinfo = ip6.flow,
                .addr = ip6.bytes,
                .scope_id = ip6.interface.index,
            };
            return @sizeOf(std.posix.sockaddr.in6);
        },
    };
}
