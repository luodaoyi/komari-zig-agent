const builtin = @import("builtin");
const std = @import("std");

pub const net = std.Io.net;
pub const Address = net.IpAddress;
pub const Stream = net.Stream;

const LinuxSocketTimeval = extern struct {
    sec: c_long,
    usec: c_long,
};

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

pub fn connectWithTimeout(addr: Address, timeout_ms: u64) !Stream {
    if (timeout_ms == 0) return connect(addr);
    const stream = switch (builtin.os.tag) {
        .linux => try connectWithTimeoutLinux(addr, timeout_ms),
        else => try connect(addr),
    };
    errdefer close(stream);
    try setStreamTimeouts(stream, timeout_ms);
    return stream;
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

fn connectWithTimeoutLinux(addr: Address, timeout_ms: u64) !Stream {
    const socket_type = std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC | std.posix.SOCK.NONBLOCK;
    const fd = try socketLinux(@intCast(family(addr)), socket_type, std.posix.IPPROTO.TCP);
    errdefer _ = std.os.linux.close(fd);

    const sa = sockAddr(addr);
    switch (std.posix.errno(std.os.linux.connect(fd, sa.ptr(), sa.len))) {
        .SUCCESS => {},
        .INPROGRESS, .ALREADY, .AGAIN => try waitForConnectLinux(fd, timeout_ms),
        else => |err| return std.posix.unexpectedErrno(err),
    }

    try clearNonblockingLinux(fd);
    return .{ .socket = .{ .handle = fd, .address = addr } };
}

fn setStreamTimeouts(stream: Stream, timeout_ms: u64) !void {
    switch (builtin.os.tag) {
        .windows => return,
        .linux => {
            // SO_{RCV,SND}TIMEO use the kernel's legacy long/long ABI on
            // 32-bit Linux. Zig 0.16's std.posix.timeval is time64 there and
            // is rejected with EDOM (TimeoutTooBig), notably on MIPS/OpenWrt.
            const tv = timeoutToLinuxSocketTimeval(timeout_ms);
            try std.posix.setsockopt(stream.socket.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&tv));
            try std.posix.setsockopt(stream.socket.handle, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, std.mem.asBytes(&tv));
        },
        else => {
            const tv = timeoutToTimeval(timeout_ms);
            try std.posix.setsockopt(stream.socket.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&tv));
            try std.posix.setsockopt(stream.socket.handle, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, std.mem.asBytes(&tv));
        },
    }
}

fn timeoutToLinuxSocketTimeval(timeout_ms: u64) LinuxSocketTimeval {
    const seconds = timeout_ms / 1000;
    const microseconds = (timeout_ms % 1000) * 1000;
    return .{
        .sec = std.math.cast(c_long, seconds) orelse std.math.maxInt(c_long),
        .usec = @intCast(microseconds),
    };
}

pub fn socketTimeoutSmoke(timeout_ms: u64) !void {
    if (builtin.os.tag != .linux) return;
    const fd = try socketLinux(std.posix.AF.INET, std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC, std.posix.IPPROTO.TCP);
    defer _ = std.os.linux.close(fd);
    const stream: Stream = .{ .socket = .{ .handle = fd, .address = initIp4(.{ 127, 0, 0, 1 }, 0) } };
    try setStreamTimeouts(stream, timeout_ms);
}

pub fn linuxSocketTimevalSize() usize {
    return @sizeOf(LinuxSocketTimeval);
}

fn timeoutToTimeval(timeout_ms: u64) std.posix.timeval {
    const Timeval = std.posix.timeval;
    const sec_type = @FieldType(Timeval, "sec");
    const usec_type = @FieldType(Timeval, "usec");
    const seconds = timeout_ms / 1000;
    const microseconds = (timeout_ms % 1000) * 1000;
    return .{
        .sec = std.math.cast(sec_type, seconds) orelse std.math.maxInt(sec_type),
        .usec = std.math.cast(usec_type, microseconds) orelse std.math.maxInt(usec_type),
    };
}

fn socketLinux(domain: u32, socket_type: u32, protocol: u32) !std.posix.fd_t {
    const rc = std.os.linux.socket(domain, socket_type, protocol);
    return switch (std.posix.errno(rc)) {
        .SUCCESS => @intCast(rc),
        .ACCES, .PERM => error.AccessDenied,
        .AFNOSUPPORT => error.AddressFamilyUnsupported,
        .PROTONOSUPPORT => error.ProtocolNotSupported,
        .NFILE => error.SystemFdQuotaExceeded,
        .MFILE => error.ProcessFdQuotaExceeded,
        .NOBUFS, .NOMEM => error.SystemResources,
        else => |err| std.posix.unexpectedErrno(err),
    };
}

fn waitForConnectLinux(fd: std.posix.fd_t, timeout_ms: u64) !void {
    var fds = [_]std.posix.pollfd{.{
        .fd = fd,
        .events = std.posix.POLL.OUT,
        .revents = 0,
    }};
    const ready = try std.posix.poll(&fds, pollTimeoutMs(timeout_ms));
    if (ready == 0) return error.Timeout;

    var err_code: c_int = 0;
    var err_len: std.posix.socklen_t = @sizeOf(c_int);
    const rc = std.os.linux.getsockopt(
        fd,
        std.posix.SOL.SOCKET,
        std.posix.SO.ERROR,
        std.mem.asBytes(&err_code).ptr,
        &err_len,
    );
    switch (std.posix.errno(rc)) {
        .SUCCESS => {},
        else => |err| return std.posix.unexpectedErrno(err),
    }
    if (err_code == 0) return;
    return switch (@as(std.posix.E, @enumFromInt(err_code))) {
        .CONNREFUSED => error.ConnectionRefused,
        .HOSTUNREACH => error.HostUnreachable,
        .NETUNREACH => error.NetworkUnreachable,
        .NETDOWN => error.NetworkDown,
        .TIMEDOUT => error.Timeout,
        .ACCES, .PERM => error.AccessDenied,
        else => |err| std.posix.unexpectedErrno(err),
    };
}

fn clearNonblockingLinux(fd: std.posix.fd_t) !void {
    const current_rc = std.os.linux.fcntl(fd, std.posix.F.GETFL, 0);
    const current_bits: u32 = switch (std.posix.errno(current_rc)) {
        .SUCCESS => @intCast(current_rc),
        else => |err| return std.posix.unexpectedErrno(err),
    };
    var next_flags: std.posix.O = @bitCast(current_bits);
    next_flags.NONBLOCK = false;
    const next_bits: u32 = @bitCast(next_flags);
    switch (std.posix.errno(std.os.linux.fcntl(fd, std.posix.F.SETFL, @as(usize, next_bits)))) {
        .SUCCESS => {},
        else => |err| return std.posix.unexpectedErrno(err),
    }
}

fn pollTimeoutMs(timeout_ms: u64) i32 {
    return std.math.cast(i32, timeout_ms) orelse std.math.maxInt(i32);
}
