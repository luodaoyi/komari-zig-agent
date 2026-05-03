const std = @import("std");
const limiter = @import("protocol_task_limiter");

test "task limiter caps active task slots" {
    limiter.resetForTest();
    defer limiter.resetForTest();

    var acquired: u32 = 0;
    while (acquired < limiter.max_concurrent_tasks) : (acquired += 1) {
        try std.testing.expect(limiter.tryAcquire());
    }
    try std.testing.expectEqual(limiter.max_concurrent_tasks, limiter.activeForTest());
    try std.testing.expect(!limiter.tryAcquire());

    limiter.release();
    try std.testing.expectEqual(limiter.max_concurrent_tasks - 1, limiter.activeForTest());
    try std.testing.expect(limiter.tryAcquire());
    try std.testing.expectEqual(limiter.max_concurrent_tasks, limiter.activeForTest());
}
