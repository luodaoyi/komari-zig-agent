const std = @import("std");
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

test "command failure result is uploadable" {
    const result = try task.commandFailureResult(std.testing.allocator, error.OutOfMemory);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("Command failed: OutOfMemory", result.output);
    try std.testing.expectEqual(@as(i32, -1), result.exit_code);
}

test "runCommand returns command stdout" {
    const output = try task.runCommandWithRunner(std.testing.allocator, "stdout", stdoutRunner);
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("hello", output);
}

test "runCommandDetailed merges stderr and exit code" {
    const result = try task.runCommandDetailedWithRunner(std.testing.allocator, "stderr", stdoutStderrRunner);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("out\nerr", result.output);
    try std.testing.expectEqual(@as(i32, 7), result.exit_code);
}

test "runCommandDetailed maps signaled shell exit" {
    const result = try task.runCommandDetailedWithRunner(std.testing.allocator, "signal", signalRunner);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(i32, 143), result.exit_code);
}

test "runCommandDetailed reports oversized output" {
    const result = try task.runCommandDetailedWithRunner(std.testing.allocator, "long", streamTooLongRunner);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("Command output exceeded 4194304 bytes", result.output);
    try std.testing.expectEqual(@as(i32, -1), result.exit_code);
}

test "runCommandDetailed returns runner errors" {
    try std.testing.expectError(
        error.UnexpectedTestError,
        task.runCommandDetailedWithRunner(std.testing.allocator, "err", errorRunner),
    );
}

test "runCommandDetailed maps unknown term to failure" {
    const result = try task.runCommandDetailedWithRunner(std.testing.allocator, "unknown", unknownRunner);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(i32, -1), result.exit_code);
}

test "utc timestamp formats as unsigned rfc3339" {
    const text = try task.utcFromTimestamp(std.testing.allocator, 0);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("1970-01-01T00:00:00Z", text);
}

fn stdoutRunner(allocator: std.mem.Allocator, env: *std.process.Environ.Map, command: []const u8) !std.process.RunResult {
    _ = env;
    try std.testing.expectEqualStrings("stdout", command);
    return .{
        .stdout = try allocator.dupe(u8, "hello"),
        .stderr = try allocator.dupe(u8, ""),
        .term = .{ .exited = 0 },
    };
}

fn stdoutStderrRunner(allocator: std.mem.Allocator, env: *std.process.Environ.Map, command: []const u8) !std.process.RunResult {
    _ = env;
    try std.testing.expectEqualStrings("stderr", command);
    return .{
        .stdout = try allocator.dupe(u8, "out"),
        .stderr = try allocator.dupe(u8, "err"),
        .term = .{ .exited = 7 },
    };
}

fn signalRunner(allocator: std.mem.Allocator, env: *std.process.Environ.Map, command: []const u8) !std.process.RunResult {
    _ = env;
    _ = command;
    return .{
        .stdout = try allocator.dupe(u8, ""),
        .stderr = try allocator.dupe(u8, ""),
        .term = .{ .signal = @enumFromInt(15) },
    };
}

fn streamTooLongRunner(allocator: std.mem.Allocator, env: *std.process.Environ.Map, command: []const u8) !std.process.RunResult {
    _ = allocator;
    _ = env;
    _ = command;
    return error.StreamTooLong;
}

fn errorRunner(allocator: std.mem.Allocator, env: *std.process.Environ.Map, command: []const u8) !std.process.RunResult {
    _ = allocator;
    _ = env;
    _ = command;
    return error.UnexpectedTestError;
}

fn unknownRunner(allocator: std.mem.Allocator, env: *std.process.Environ.Map, command: []const u8) !std.process.RunResult {
    _ = env;
    _ = command;
    return .{
        .stdout = try allocator.dupe(u8, ""),
        .stderr = try allocator.dupe(u8, ""),
        .term = .{ .unknown = 1 },
    };
}
