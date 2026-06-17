const impl = @import("protocol/debug.zig");

pub fn setEnabled(value: bool) void {
    impl.setEnabled(value);
}

pub fn isEnabled() bool {
    return impl.isEnabled();
}

pub fn log(comptime fmt: []const u8, args: anytype) void {
    impl.log(fmt, args);
}
