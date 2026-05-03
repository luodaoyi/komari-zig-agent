const std = @import("std");
const compat = @import("compat");

/// Minimal websocket abstraction used when a safe stub is enough.
pub const SafeConn = struct {
    mutex: compat.Mutex = .{},

    pub fn writeText(self: *SafeConn, _: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
    }
};
