const std = @import("std");
const builtin = @import("builtin");
const dns = @import("dns");

pub const AddressFamily = enum {
    any,
    ipv4,
    ipv6,
};

const CaBundleCache = if (std.http.Client.disable_tls) struct {} else struct {
    mutex: std.Thread.Mutex = .{},
    loaded: bool = false,
    bundle: std.crypto.Certificate.Bundle = .{},
};

var ca_bundle_cache: CaBundleCache = .{};

pub const RawConn = struct {
    allocator: std.mem.Allocator,
    stream: std.net.Stream,
    stream_reader: std.net.Stream.Reader,
    stream_writer: std.net.Stream.Writer,
    tls_client: ?std.crypto.tls.Client = null,
    socket_read_buf: [std.crypto.tls.Client.min_buffer_len]u8 = undefined,
    socket_write_buf: [std.crypto.tls.Client.min_buffer_len]u8 = undefined,
    tls_read_buf: [std.crypto.tls.Client.min_buffer_len]u8 = undefined,
    tls_write_buf: [std.crypto.tls.Client.min_buffer_len]u8 = undefined,
    closed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn connect(
        allocator: std.mem.Allocator,
        host: []const u8,
        port: u16,
        use_tls: bool,
        ignore_unsafe_cert: bool,
        custom_dns: []const u8,
    ) !*RawConn {
        return connectWithFamily(allocator, host, port, use_tls, ignore_unsafe_cert, custom_dns, .any);
    }

    pub fn connectWithFamily(
        allocator: std.mem.Allocator,
        host: []const u8,
        port: u16,
        use_tls: bool,
        ignore_unsafe_cert: bool,
        custom_dns: []const u8,
        family: AddressFamily,
    ) !*RawConn {
        const addrs = try dns.resolveHost(allocator, host, port, custom_dns);
        defer allocator.free(addrs);
        var last_err: ?anyerror = null;
        for (addrs) |addr| {
            if (!familyMatches(addr, family)) continue;
            return connectResolved(allocator, addr, host, use_tls, ignore_unsafe_cert) catch |err| {
                last_err = err;
                continue;
            };
        }
        return last_err orelse error.ConnectFailed;
    }

    pub fn connectResolved(
        allocator: std.mem.Allocator,
        addr: std.net.Address,
        tls_host: []const u8,
        use_tls: bool,
        ignore_unsafe_cert: bool,
    ) !*RawConn {
        const stream = try connectStreamAddress(addr);
        errdefer stream.close();
        return fromStream(allocator, stream, tls_host, use_tls, ignore_unsafe_cert);
    }

    pub fn fromStream(
        allocator: std.mem.Allocator,
        stream: std.net.Stream,
        tls_host: []const u8,
        use_tls: bool,
        ignore_unsafe_cert: bool,
    ) !*RawConn {
        const raw = try allocator.create(RawConn);
        errdefer allocator.destroy(raw);
        raw.* = .{
            .allocator = allocator,
            .stream = stream,
            .stream_reader = undefined,
            .stream_writer = undefined,
        };
        raw.stream_reader = raw.stream.reader(raw.socket_read_buf[0..]);
        raw.stream_writer = raw.stream.writer(raw.socket_write_buf[0..]);
        if (use_tls) try raw.startTls(tls_host, ignore_unsafe_cert);
        return raw;
    }

    pub fn startTls(self: *RawConn, tls_host: []const u8, ignore_unsafe_cert: bool) !void {
        if (self.tls_client != null) return error.TlsAlreadyStarted;
        if (std.http.Client.disable_tls) return error.TlsInitializationFailed;
        if (ignore_unsafe_cert) {
            self.tls_client = std.crypto.tls.Client.init(
                self.stream_reader.interface(),
                &self.stream_writer.interface,
                .{
                    .host = .{ .explicit = tls_host },
                    .ca = .{ .no_verification = {} },
                    .read_buffer = self.tls_read_buf[0..],
                    .write_buffer = self.tls_write_buf[0..],
                    .allow_truncation_attacks = true,
                },
            ) catch return error.TlsInitializationFailed;
        } else {
            const ca_bundle = try cachedCaBundle(self.allocator);
            self.tls_client = std.crypto.tls.Client.init(
                self.stream_reader.interface(),
                &self.stream_writer.interface,
                .{
                    .host = .{ .explicit = tls_host },
                    .ca = .{ .bundle = ca_bundle },
                    .read_buffer = self.tls_read_buf[0..],
                    .write_buffer = self.tls_write_buf[0..],
                    .allow_truncation_attacks = true,
                },
            ) catch return error.TlsInitializationFailed;
        }
    }

    pub fn shutdown(self: *RawConn) void {
        if (self.closed.swap(true, .acq_rel)) return;
        self.stream.close();
    }

    pub fn close(self: *RawConn) void {
        self.shutdown();
        self.allocator.destroy(self);
    }

    pub fn reader(self: *RawConn) *std.Io.Reader {
        if (self.tls_client) |*tls| return &tls.reader;
        return self.stream_reader.interface();
    }

    pub fn writer(self: *RawConn) *std.Io.Writer {
        if (self.tls_client) |*tls| return &tls.writer;
        return &self.stream_writer.interface;
    }

    pub fn flush(self: *RawConn) !void {
        try self.writer().flush();
        try self.stream_writer.interface.flush();
    }
};

fn cachedCaBundle(allocator: std.mem.Allocator) !std.crypto.Certificate.Bundle {
    if (std.http.Client.disable_tls) return error.TlsInitializationFailed;
    ca_bundle_cache.mutex.lock();
    defer ca_bundle_cache.mutex.unlock();
    if (!ca_bundle_cache.loaded) {
        ca_bundle_cache.bundle = .{};
        try ca_bundle_cache.bundle.rescan(allocator);
        ca_bundle_cache.loaded = true;
    }
    return ca_bundle_cache.bundle;
}

fn familyMatches(addr: std.net.Address, family: AddressFamily) bool {
    return switch (family) {
        .any => true,
        .ipv4 => addr.any.family == std.posix.AF.INET,
        .ipv6 => addr.any.family == std.posix.AF.INET6,
    };
}

fn connectStreamAddress(addr: std.net.Address) !std.net.Stream {
    const flags = std.posix.SOCK.STREAM | if (builtin.os.tag == .linux) std.posix.SOCK.CLOEXEC else 0;
    const sock = try std.posix.socket(addr.any.family, flags, std.posix.IPPROTO.TCP);
    errdefer std.posix.close(sock);
    try std.posix.connect(sock, &addr.any, addr.getOsSockLen());
    return .{ .handle = sock };
}
