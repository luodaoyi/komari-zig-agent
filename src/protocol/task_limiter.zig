const std = @import("std");

/// Concurrency guard for server-triggered background tasks.
pub const max_concurrent_tasks: u32 = 8;

var active_tasks = std.atomic.Value(u32).init(0);

pub fn tryAcquire() bool {
    var current = active_tasks.load(.acquire);
    while (current < max_concurrent_tasks) {
        if (active_tasks.cmpxchgWeak(current, current + 1, .acq_rel, .acquire)) |actual| {
            current = actual;
            continue;
        }
        return true;
    }
    return false;
}

pub fn release() void {
    const previous = active_tasks.fetchSub(1, .acq_rel);
    std.debug.assert(previous > 0);
}

pub fn activeForTest() u32 {
    return active_tasks.load(.acquire);
}

pub fn resetForTest() void {
    active_tasks.store(0, .release);
}
