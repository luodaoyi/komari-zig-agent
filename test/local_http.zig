const std = @import("std");

pub const Server = struct {
    allocator: std.mem.Allocator,
    ctx: *Context,
    thread: std.Thread,

    const Context = struct {
        listener: std.Io.net.Server,
        responses: []const []const u8,
        err: ?anyerror = null,
    };

    pub fn start(allocator: std.mem.Allocator, responses: []const []const u8) !Server {
        var addr = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
        var listener = try addr.listen(std.Options.debug_io, .{ .reuse_address = true });
        errdefer listener.deinit(std.Options.debug_io);

        const ctx = try allocator.create(Context);
        errdefer allocator.destroy(ctx);
        ctx.* = .{
            .listener = listener,
            .responses = responses,
        };
        return .{
            .allocator = allocator,
            .ctx = ctx,
            .thread = try std.Thread.spawn(.{}, serve, .{ctx}),
        };
    }

    pub fn url(self: *const Server, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
        return std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}{s}", .{ self.ctx.listener.socket.address.getPort(), path });
    }

    pub fn join(self: *Server) !void {
        self.thread.join();
        self.ctx.listener.deinit(std.Options.debug_io);
        defer self.allocator.destroy(self.ctx);
        if (self.ctx.err) |err| return err;
    }

    fn serve(ctx: *Context) void {
        for (ctx.responses) |response| {
            var stream = ctx.listener.accept(std.Options.debug_io) catch |err| {
                ctx.err = err;
                return;
            };
            defer stream.close(std.Options.debug_io);

            readRequest(&stream) catch |err| {
                ctx.err = err;
                return;
            };
            writeResponse(&stream, response) catch |err| {
                ctx.err = err;
                return;
            };
        }
    }

    fn readRequest(stream: *std.Io.net.Stream) !void {
        var reader_buf: [4096]u8 = undefined;
        var reader = stream.reader(std.Options.debug_io, &reader_buf);
        var header: [4096]u8 = undefined;
        var len: usize = 0;
        while (len < header.len) {
            header[len] = try reader.interface.takeByte();
            len += 1;
            if (std.mem.endsWith(u8, header[0..len], "\r\n\r\n")) return;
        }
        return error.HttpRequestHeaderTooLarge;
    }

    fn writeResponse(stream: *std.Io.net.Stream, response: []const u8) !void {
        var writer_buf: [4096]u8 = undefined;
        var writer = stream.writer(std.Options.debug_io, &writer_buf);
        try writer.interface.writeAll(response);
        try writer.interface.flush();
    }
};
