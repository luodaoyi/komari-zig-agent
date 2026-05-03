const std = @import("std");

/// Process spawning helpers with bounded stdout capture.
pub const RunOutputResult = struct {
    term: std.process.Child.Term,
    stdout: []u8,
};

pub fn runOutputIgnoreStderr(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    environ_map: ?*const std.process.Environ.Map,
    stdout_limit: usize,
) !RunOutputResult {
    var child = try std.process.spawn(std.Options.debug_io, .{
        .argv = argv,
        .environ_map = environ_map,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    });
    defer child.kill(std.Options.debug_io);

    const stdout_file = child.stdout orelse return error.CommandFailed;
    var reader_buf: [4096]u8 = undefined;
    var reader = stdout_file.reader(std.Options.debug_io, &reader_buf);
    var out = std.Io.Writer.Allocating.init(allocator);
    errdefer out.deinit();
    var total: usize = 0;
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = try reader.interface.readSliceShort(&buf);
        if (n == 0) break;
        if (total + n > stdout_limit) return error.StreamTooLong;
        try out.writer.writeAll(buf[0..n]);
        total += n;
    }

    return .{
        .term = try child.wait(std.Options.debug_io),
        .stdout = try out.toOwnedSlice(),
    };
}

pub fn runIgnoreOutput(argv: []const []const u8, environ_map: ?*const std.process.Environ.Map) !std.process.Child.Term {
    var child = try std.process.spawn(std.Options.debug_io, .{
        .argv = argv,
        .environ_map = environ_map,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    defer child.kill(std.Options.debug_io);
    return child.wait(std.Options.debug_io);
}
