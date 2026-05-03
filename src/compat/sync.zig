const std = @import("std");

/// Small blocking mutex used where the agent needs old `std.Thread.Mutex`
/// semantics on Zig 0.16.
pub const Mutex = struct {
    state: std.atomic.Mutex = .unlocked,

    pub fn lock(self: *Mutex) void {
        while (!self.state.tryLock()) {
            std.Thread.yield() catch {};
        }
    }

    pub fn unlock(self: *Mutex) void {
        self.state.unlock();
    }
};
