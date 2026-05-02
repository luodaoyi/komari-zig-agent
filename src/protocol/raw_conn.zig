const std = @import("std");
const builtin = @import("builtin");
const dns = @import("dns");

pub const RawConn = struct {
    allocator: std.mem.Allocator,
    stream: std.net.Stream,
    stream_reader: std.net.Stream.Reader,
    stream_writer: std.net.Stream.Writer,
    tls_client: ?std.crypto.tls.Client = null,
    ca_bundle: if (std.http.Client.disable_tls) void else std.crypto.Certificate.Bundle = if (std.http.Client.disable_tls) {} else .{},
    verify_ca: bool = false,
    socket_read_buf: [std.crypto.tls.Client.min_buffer_len]u8 = undefined,
    socket_write_buf: [std.crypto.tls.Client.min_buffer_len]u8 = undefined,
    tls_read_buf: [std.crypto.tls.Client.min_buffer_len]u8 = undefined,
    tls_write_buf: [std.crypto.tls.Client.min_buffer_len]u8 = undefined,

    pub fn connect(
        allocator: std.mem.Allocator,
        host: []const u8,
        port: u16,
        use_tls: bool,
        ignore_unsafe_cert: bool,
        custom_dns: []const u8,
    ) !*RawConn {
        const addrs = try dns.resolveHost(allocator, host, port, custom_dns);
        defer allocator.free(addrs);
        var last_err: ?anyerror = null;
        for (addrs) |addr| {
            const stream = connectAddress(addr) catch |err| {
                last_err = err;
                continue;
            };
            errdefer stream.close();
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
            if (use_tls) {
                if (std.http.Client.disable_tls) return error.TlsInitializationFailed;
                if (ignore_unsafe_cert) {
                    raw.tls_client = std.crypto.tls.Client.init(
                        raw.stream_reader.interface(),
                        &raw.stream_writer.interface,
                        .{
                            .host = .{ .explicit = host },
                            .ca = .{ .no_verification = {} },
                            .read_buffer = raw.tls_read_buf[0..],
                            .write_buffer = raw.tls_write_buf[0..],
                            .allow_truncation_attacks = true,
                        },
                    ) catch return error.TlsInitializationFailed;
                } else {
                    raw.ca_bundle = .{};
                    try raw.ca_bundle.rescan(allocator);
                    raw.verify_ca = true;
                    raw.tls_client = std.crypto.tls.Client.init(
                        raw.stream_reader.interface(),
                        &raw.stream_writer.interface,
                        .{
                            .host = .{ .explicit = host },
                            .ca = .{ .bundle = raw.ca_bundle },
                            .read_buffer = raw.tls_read_buf[0..],
                            .write_buffer = raw.tls_write_buf[0..],
                            .allow_truncation_attacks = true,
                        },
                    ) catch return error.TlsInitializationFailed;
                }
            }
            return raw;
        }
        return last_err orelse error.ConnectFailed;
    }

    pub fn close(self: *RawConn) void {
        if (self.tls_client) |*tls| tls.end() catch {};
        self.stream.close();
        if (!std.http.Client.disable_tls and self.verify_ca) self.ca_bundle.deinit(self.allocator);
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

fn connectAddress(addr: std.net.Address) !std.net.Stream {
    const flags = std.posix.SOCK.STREAM | if (builtin.os.tag == .linux) std.posix.SOCK.CLOEXEC else 0;
    const sock = try std.posix.socket(addr.any.family, flags, std.posix.IPPROTO.TCP);
    errdefer std.posix.close(sock);
    try std.posix.connect(sock, &addr.any, addr.getOsSockLen());
    return .{ .handle = sock };
}
