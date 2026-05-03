const std = @import("std");
const builtin = @import("builtin");
const task = @import("protocol_task");

test "empty exec task matches go result text" {
    const result = try task.runCommandDetailed(std.testing.allocator, "");
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("No command provided", result.output);
    try std.testing.expectEqual(@as(i32, 0), result.exit_code);
}

test "crlf output is normalized to lf" {
    const normalized = try task.normalizeCommandOutput(std.testing.allocator, "a\r\nb\r\n");
    defer std.testing.allocator.free(normalized);
    try std.testing.expectEqualStrings("a\nb\n", normalized);
}

test "disabled remote control result does not execute command" {
    const result = try task.disabledRemoteControlResult(std.testing.allocator);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("Remote control is disabled.", result.output);
    try std.testing.expectEqual(@as(i32, -1), result.exit_code);
}

test "runCommand returns command stdout" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    const output = try task.runCommand(std.testing.allocator, "printf 'hello'");
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("hello", output);
}

test "runCommandDetailed merges stderr and exit code" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    const result = try task.runCommandDetailed(std.testing.allocator, "printf 'out'; printf 'err' >&2; exit 7");
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("out\nerr", result.output);
    try std.testing.expectEqual(@as(i32, 7), result.exit_code);
}

test "runCommandDetailed maps signaled shell exit" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    const result = try task.runCommandDetailed(std.testing.allocator, "kill -TERM $$");
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(i32, 143), result.exit_code);
}

test "runCommandDetailed reports oversized output" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    const result = try task.runCommandDetailed(std.testing.allocator, "yes x");
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("Command output exceeded 4194304 bytes", result.output);
    try std.testing.expectEqual(@as(i32, -1), result.exit_code);
}
