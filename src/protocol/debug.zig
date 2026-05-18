const std = @import("std");

/// Optional stderr debug logging for startup and connection diagnosis.
var enabled_flag = std.atomic.Value(bool).init(false);

pub fn setEnabled(value: bool) void {
    enabled_flag.store(value, .release);
}

pub fn isEnabled() bool {
    return enabled_flag.load(.acquire);
}

pub fn log(comptime fmt: []const u8, args: anytype) void {
    if (!isEnabled()) return;
    std.debug.print("[debug] " ++ fmt ++ "\n", args);
}
