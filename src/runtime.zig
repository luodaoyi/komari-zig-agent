const std = @import("std");

var process_environ: std.process.Environ = .empty;

/// Captures process data supplied by Zig 0.16 startup when using
/// `std.process.Init.Minimal`.
pub fn init(minimal: std.process.Init.Minimal) void {
    process_environ = minimal.environ;
}

pub fn currentEnvMap(allocator: std.mem.Allocator) !std.process.Environ.Map {
    return process_environ.createMap(allocator);
}

pub fn getEnvVarOwned(allocator: std.mem.Allocator, key: []const u8) ![]u8 {
    return process_environ.getAlloc(allocator, key);
}
