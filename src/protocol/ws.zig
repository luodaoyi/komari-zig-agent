const std = @import("std");

pub const SafeConn = struct {
    mutex: std.Thread.Mutex = .{},

    pub fn writeText(self: *SafeConn, _: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
    }
};
