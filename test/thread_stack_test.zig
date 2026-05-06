const std = @import("std");
const thread_stacks = @import("thread_stacks");

test "tls worker threads have enough stack for zig tls crypto" {
    try std.testing.expect(thread_stacks.tls_worker_stack_size >= 1024 * 1024);
    try std.testing.expect(thread_stacks.terminal_worker_stack_size >= 1024 * 1024);
    try std.testing.expect(thread_stacks.update_worker_stack_size >= 2 * 1024 * 1024);
}
