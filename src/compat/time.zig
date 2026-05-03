const std = @import("std");

/// Time helpers backed by Zig 0.16 `std.Io`.
pub fn sleep(nanoseconds: u64) void {
    std.Io.sleep(std.Options.debug_io, .fromNanoseconds(@intCast(nanoseconds)), .awake) catch {};
}

pub fn unixTimestamp() i64 {
    return std.Io.Timestamp.now(std.Options.debug_io, .real).toSeconds();
}

pub fn milliTimestamp() i64 {
    return std.Io.Timestamp.now(std.Options.debug_io, .real).toMilliseconds();
}

pub fn nanoTimestamp() i128 {
    return std.Io.Timestamp.now(std.Options.debug_io, .real).toNanoseconds();
}
