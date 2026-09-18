const std = @import("std");
const builtin = @import("builtin");
const dns = @import("dns");
const compat = @import("compat");
const debug = @import("debug");
const net = @import("net");

/// Raw TCP/TLS connection wrapper used by HTTP and websocket clients.
pub const AddressFamily = enum {
    any,
    ipv4,
    ipv6,
};

pub const tls_ca_bundle_storage = if (std.http.Client.disable_tls) "disabled" else "per_connection";

/// FreeBSD CA bundle files, ordered like Go crypto/x509 root_bsd.go.
/// Zig std only tries `/etc/ssl/cert.pem` (ziglang/zig#20516), which misses
/// ca_root_nss installs that Go finds first under `/usr/local/...`.
pub const freebsd_ca_cert_file_paths = [_][]const u8{
    "/usr/local/etc/ssl/cert.pem",
    "/etc/ssl/cert.pem",
    "/usr/local/share/certs/ca-root-nss.crt",
};

/// FreeBSD CA directories, matching Go crypto/x509 root_bsd.go.
pub const freebsd_ca_cert_dir_paths = [_][]const u8{
    "/etc/ssl/certs",
    "/usr/local/share/certs",
};

pub const RawConn = struct {
    allocator: std.mem.Allocator,
    stream: net.Stream,
    stream_reader: net.Stream.Reader,
    stream_writer: net.Stream.Writer,
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
        timeout_ms: u64,
    ) !*RawConn {
        return connectWithFamily(allocator, host, port, use_tls, ignore_unsafe_cert, custom_dns, .any, timeout_ms);
    }

    pub fn connectWithFamily(
        allocator: std.mem.Allocator,
        host: []const u8,
        port: u16,
        use_tls: bool,
        ignore_unsafe_cert: bool,
        custom_dns: []const u8,
        family: AddressFamily,
        timeout_ms: u64,
    ) !*RawConn {
        const addrs = try dns.resolveHost(allocator, host, port, custom_dns);
        defer allocator.free(addrs);
        var last_err: ?anyerror = null;
        for (addrs) |addr| {
            if (!familyMatches(addr, family)) continue;
            var addr_buf: [96]u8 = undefined;
            debug.log("tcp connect start {s}:{d} via {s} tls={}", .{ host, port, formatAddress(&addr_buf, addr), use_tls });
            return connectResolved(allocator, addr, host, use_tls, ignore_unsafe_cert, timeout_ms) catch |err| {
                last_err = err;
                debug.log("tcp connect failed via {s}: {s}", .{ formatAddress(&addr_buf, addr), @errorName(err) });
                continue;
            };
        }
        return last_err orelse error.ConnectFailed;
    }

    pub fn connectResolved(
        allocator: std.mem.Allocator,
        addr: net.Address,
        tls_host: []const u8,
        use_tls: bool,
        ignore_unsafe_cert: bool,
        timeout_ms: u64,
    ) !*RawConn {
        const stream = try connectStreamAddress(addr, timeout_ms);
        errdefer net.close(stream);
        var addr_buf: [96]u8 = undefined;
        debug.log("tcp connect established via {s}", .{formatAddress(&addr_buf, addr)});
        return fromStream(allocator, stream, tls_host, use_tls, ignore_unsafe_cert);
    }

    pub fn fromStream(
        allocator: std.mem.Allocator,
        stream: net.Stream,
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
        raw.stream_reader = net.reader(raw.stream, raw.socket_read_buf[0..]);
        raw.stream_writer = net.writer(raw.stream, raw.socket_write_buf[0..]);
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
            ) catch |err| {
                debug.log("tls handshake failed host={s} verify=off: {s}", .{ tls_host, @errorName(err) });
                return err;
            };
        } else {
            var random_buffer: [std.crypto.tls.Client.Options.entropy_len]u8 = undefined;
            std.Options.debug_io.random(&random_buffer);
            var ca_bundle = loadCaBundle() catch |err| {
                debug.log("tls ca bundle load failed host={s}: {s}", .{ tls_host, @errorName(err) });
                return err;
            };
            defer ca_bundle.deinit(std.heap.page_allocator);
            var ca_bundle_lock: std.Io.RwLock = .init;
            self.tls_client = std.crypto.tls.Client.init(
                &self.stream_reader.interface,
                &self.stream_writer.interface,
                .{
                    .host = .{ .explicit = tls_host },
                    .ca = .{ .bundle = .{
                        .gpa = std.heap.page_allocator,
                        .io = std.Options.debug_io,
                        .lock = &ca_bundle_lock,
                        .bundle = &ca_bundle,
                    } },
                    .read_buffer = self.tls_read_buf[0..],
                    .write_buffer = self.tls_write_buf[0..],
                    .entropy = &random_buffer,
                    .realtime_now = std.Io.Timestamp.now(std.Options.debug_io, .real),
                    .allow_truncation_attacks = true,
                },
            ) catch |err| {
                debug.log("tls handshake failed host={s} verify=on: {s}", .{ tls_host, @errorName(err) });
                return err;
            };
        }
    }

    pub fn shutdown(self: *RawConn) void {
        if (self.closed.swap(true, .acq_rel)) return;
        net.close(self.stream);
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

fn loadCaBundle() !std.crypto.Certificate.Bundle {
    if (std.http.Client.disable_tls) return error.TlsInitializationFailed;
    var bundle: std.crypto.Certificate.Bundle = .empty;
    errdefer bundle.deinit(std.heap.page_allocator);
    if (builtin.os.tag == .freebsd) {
        try loadCaBundleFreeBsd(&bundle);
    } else {
        try bundle.rescan(std.heap.page_allocator, std.Options.debug_io, std.Io.Timestamp.now(std.Options.debug_io, .real));
    }
    return bundle;
}

fn loadCaBundleFreeBsd(bundle: *std.crypto.Certificate.Bundle) !void {
    try loadCaBundleFromCandidatePaths(
        bundle,
        std.heap.page_allocator,
        std.Options.debug_io,
        std.Io.Timestamp.now(std.Options.debug_io, .real),
        &freebsd_ca_cert_file_paths,
        &freebsd_ca_cert_dir_paths,
    );
}

/// Load CA certs by trying file paths then directories (Go/Linux-style).
/// Continues on FileNotFound/AccessDenied for individual candidates so a
/// locked `/etc/ssl/cert.pem` does not block ca_root_nss under `/usr/local`.
pub fn loadCaBundleFromCandidatePaths(
    bundle: *std.crypto.Certificate.Bundle,
    gpa: std.mem.Allocator,
    io: std.Io,
    now: std.Io.Timestamp,
    file_paths: []const []const u8,
    dir_paths: []const []const u8,
) !void {
    bundle.bytes.clearRetainingCapacity();
    bundle.map.clearRetainingCapacity();

    var last_err: ?anyerror = null;
    scan_files: {
        for (file_paths) |cert_file_path| {
            if (bundle.addCertsFromFilePathAbsolute(gpa, io, now, cert_file_path)) |_| {
                debug.log("tls ca bundle loaded from file {s}", .{cert_file_path});
                break :scan_files;
            } else |err| switch (err) {
                error.FileNotFound, error.AccessDenied => {
                    last_err = err;
                    continue;
                },
                else => |e| return e,
            }
        }

        var loaded_dir = false;
        for (dir_paths) |cert_dir_path| {
            if (bundle.addCertsFromDirPathAbsolute(gpa, io, now, cert_dir_path)) |_| {
                loaded_dir = true;
                debug.log("tls ca bundle loaded from dir {s}", .{cert_dir_path});
            } else |err| switch (err) {
                error.FileNotFound, error.AccessDenied => {
                    last_err = err;
                    continue;
                },
                else => |e| return e,
            }
        }
        if (!loaded_dir) return last_err orelse error.FileNotFound;
    }

    bundle.bytes.shrinkAndFree(gpa, bundle.bytes.items.len);
}

pub fn rescanCaBundleForTest() !void {
    if (std.http.Client.disable_tls) return;
    var bundle = try loadCaBundle();
    defer bundle.deinit(std.heap.page_allocator);
}

pub fn resolveAddresses(
    allocator: std.mem.Allocator,
    host: []const u8,
    port: u16,
    custom_dns: []const u8,
) ![]net.Address {
    return dns.resolveHost(allocator, host, port, custom_dns);
}

pub fn familyMatches(addr: net.Address, family: AddressFamily) bool {
    return switch (family) {
        .any => true,
        .ipv4 => net.isIpv4(addr),
        .ipv6 => net.isIpv6(addr),
    };
}

fn connectStreamAddress(addr: net.Address, timeout_ms: u64) !net.Stream {
    _ = builtin;
    return net.connectWithTimeout(addr, timeout_ms);
}

pub fn formatAddress(buf: *[96]u8, addr: net.Address) []const u8 {
    var writer: std.Io.Writer = .fixed(buf);
    addr.format(&writer) catch return "<invalid-address>";
    return writer.buffered();
}
