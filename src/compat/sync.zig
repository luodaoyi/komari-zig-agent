const std = @import("std");

/// Blocking mutex facade backed by Zig 0.16 `std.Io.Mutex`.
pub const Mutex = struct {
    state: std.Io.Mutex = .init,

    pub fn lock(self: *Mutex) void {
        self.state.lockUncancelable(std.Options.debug_io);
    }

    pub fn unlock(self: *Mutex) void {
        self.state.unlock(std.Options.debug_io);
    }
};
