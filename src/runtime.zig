const std = @import("std");

var process_environ: std.process.Environ = .empty;
var process_io: std.Io.Threaded = .init_single_threaded;
var process_io_initialized = std.atomic.Value(bool).init(false);

/// Captures process data supplied by Zig 0.16 startup when using
/// `std.process.Init.Minimal`.
pub fn init(minimal: std.process.Init.Minimal) void {
    process_environ = minimal.environ;
    process_io = .init(std.heap.page_allocator, .{
        .argv0 = .init(minimal.args),
        .environ = minimal.environ,
    });
    process_io_initialized.store(true, .release);
}

pub fn io() std.Io {
    if (process_io_initialized.load(.acquire)) return process_io.io();
    return std.Options.debug_io;
}

pub fn currentEnvMap(allocator: std.mem.Allocator) !std.process.Environ.Map {
    return process_environ.createMap(allocator);
}

pub fn getEnvVarOwned(allocator: std.mem.Allocator, key: []const u8) ![]u8 {
    return process_environ.getAlloc(allocator, key);
}
