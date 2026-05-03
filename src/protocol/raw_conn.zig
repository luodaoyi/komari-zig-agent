const std = @import("std");
const builtin = @import("builtin");
const dns = @import("dns");
const compat = @import("compat");
const net_compat = @import("net_compat");

/// Raw TCP/TLS connection wrapper used by HTTP and websocket clients.
pub const AddressFamily = enum {
    any,
    ipv4,
    ipv6,
};

const CaBundleCache = if (std.http.Client.disable_tls) struct {} else struct {
    mutex: compat.Mutex = .{},
    rwlock: std.Io.RwLock = .init,
    loaded: bool = false,
    bundle: std.crypto.Certificate.Bundle = .empty,
};

var ca_bundle_cache: CaBundleCache = .{};

pub const RawConn = struct {
    allocator: std.mem.Allocator,
    stream: net_compat.Stream,
    stream_reader: net_compat.Stream.Reader,
    stream_writer: net_compat.Stream.Writer,
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
        addr: net_compat.Address,
        tls_host: []const u8,
        use_tls: bool,
        ignore_unsafe_cert: bool,
    ) !*RawConn {
        const stream = try connectStreamAddress(addr);
        errdefer net_compat.close(stream);
        return fromStream(allocator, stream, tls_host, use_tls, ignore_unsafe_cert);
    }

    pub fn fromStream(
        allocator: std.mem.Allocator,
        stream: net_compat.Stream,
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
        raw.stream_reader = net_compat.reader(raw.stream, raw.socket_read_buf[0..]);
        raw.stream_writer = net_compat.writer(raw.stream, raw.socket_write_buf[0..]);
        if (use_tls) try raw.startTls(tls_host, ignore_unsafe_cert);
        return raw;
    }

    pub fn startTls(self: *RawConn, tls_host: []const u8, ignore_unsafe_cert: bool) !void {
        if (self.tls_client != null) return error.TlsAlreadyStarted;
        if (std.http.Client.disable_tls) return error.TlsInitializationFailed;
        if (ignore_unsafe_cert) {
            var random_buffer: [std.crypto.tls.Client.Options.entropy_len]u8 = undefined;
            std.Options.debug_io.random(&random_buffer);
            self.tls_client = std.crypto.tls.Client.init(
                &self.stream_reader.interface,
                &self.stream_writer.interface,
                .{
                    .host = .{ .explicit = tls_host },
                    .ca = .{ .no_verification = {} },
                    .read_buffer = self.tls_read_buf[0..],
                    .write_buffer = self.tls_write_buf[0..],
                    .entropy = &random_buffer,
                    .realtime_now = std.Io.Timestamp.now(std.Options.debug_io, .real),
                    .allow_truncation_attacks = true,
                },
            ) catch return error.TlsInitializationFailed;
        } else {
            var random_buffer: [std.crypto.tls.Client.Options.entropy_len]u8 = undefined;
            std.Options.debug_io.random(&random_buffer);
            const ca_bundle = try cachedCaBundle();
            self.tls_client = std.crypto.tls.Client.init(
                &self.stream_reader.interface,
                &self.stream_writer.interface,
                .{
                    .host = .{ .explicit = tls_host },
                    .ca = .{ .bundle = .{
                        .gpa = std.heap.page_allocator,
                        .io = std.Options.debug_io,
                        .lock = &ca_bundle_cache.rwlock,
                        .bundle = ca_bundle,
                    } },
                    .read_buffer = self.tls_read_buf[0..],
                    .write_buffer = self.tls_write_buf[0..],
                    .entropy = &random_buffer,
                    .realtime_now = std.Io.Timestamp.now(std.Options.debug_io, .real),
                    .allow_truncation_attacks = true,
                },
            ) catch return error.TlsInitializationFailed;
        }
    }

    pub fn shutdown(self: *RawConn) void {
        if (self.closed.swap(true, .acq_rel)) return;
        net_compat.close(self.stream);
    }

    pub fn close(self: *RawConn) void {
        self.shutdown();
        self.allocator.destroy(self);
    }

    pub fn reader(self: *RawConn) *std.Io.Reader {
        if (self.tls_client) |*tls| return &tls.reader;
        return &self.stream_reader.interface;
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

fn cachedCaBundle() !*std.crypto.Certificate.Bundle {
    if (std.http.Client.disable_tls) return error.TlsInitializationFailed;
    ca_bundle_cache.mutex.lock();
    defer ca_bundle_cache.mutex.unlock();
    if (!ca_bundle_cache.loaded) {
        ca_bundle_cache.bundle = .empty;
        ca_bundle_cache.bundle.rescan(std.heap.page_allocator, std.Options.debug_io, std.Io.Timestamp.now(std.Options.debug_io, .real)) catch {};
        ca_bundle_cache.loaded = true;
    }
    return &ca_bundle_cache.bundle;
}

fn familyMatches(addr: net_compat.Address, family: AddressFamily) bool {
    return switch (family) {
        .any => true,
        .ipv4 => net_compat.isIpv4(addr),
        .ipv6 => net_compat.isIpv6(addr),
    };
}

fn connectStreamAddress(addr: net_compat.Address) !net_compat.Stream {
    _ = builtin;
    return net_compat.connect(addr);
}
