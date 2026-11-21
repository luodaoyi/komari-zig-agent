const std = @import("std");
const terminal = @import("terminal/terminal.zig");

test "terminal input keeps raw non-json bytes" {
    const input = terminal.parseInput(std.testing.allocator, "hello\n");
    defer input.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 6), switch (input) {
        .raw => |bytes| bytes.len,
        else => 0,
    });
    try std.testing.expectEqualStrings("hello\n", switch (input) {
        .raw => |bytes| bytes,
        else => "",
    });
    try std.testing.expect(!terminal.isCloseInput(input));
}

test "terminal input ignores unknown json control messages" {
    const input = terminal.parseInput(std.testing.allocator, "{\"type\":\"future_control\",\"timestamp\":\"2026-06-17T00:00:00Z\"}");
    defer input.deinit(std.testing.allocator);

    try std.testing.expect(!terminal.isCloseInput(input));
    try std.testing.expect(switch (input) {
        .ignored => true,
        else => false,
    });
}

test "terminal input parses input and resize messages" {
    const typed = terminal.parseInput(std.testing.allocator, "{\"type\":\"input\",\"input\":\"ls\\n\"}");
    defer typed.deinit(std.testing.allocator);
    try std.testing.expect(switch (typed) {
        .input => |bytes| std.mem.eql(u8, bytes, "ls\n"),
        else => false,
    });

    const resized = terminal.parseInput(std.testing.allocator, "{\"type\":\"resize\",\"cols\":120,\"rows\":40}");
    defer resized.deinit(std.testing.allocator);
    try std.testing.expect(switch (resized) {
        .resize => |size| size.cols == 120 and size.rows == 40,
        else => false,
    });
}

test "terminal MOTD prelude always uses POSIX sh before the login shell" {
    // MOTD scripts must not be interpreted by zsh or another user-selected shell.
    try std.testing.expectEqualStrings("/bin/sh", terminal.posix_motd_shell);
    try std.testing.expect(std.mem.indexOf(u8, terminal.posix_motd_command, "exec \"$1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, terminal.posix_motd_command, "unsetopt") == null);
}

test "terminal protocol distinguishes abort, heartbeat and final termination" {
    const allocator = std.testing.allocator;
    const abort = terminal.parseInput(allocator, "{\"type\":\"abort\"}");
    defer abort.deinit(allocator);
    try std.testing.expect(abort == .abort);
    const heartbeat = terminal.parseInput(allocator, "{\"type\":\"heartbeat\",\"id\":\"probe\"}");
    defer heartbeat.deinit(allocator);
    try std.testing.expect(heartbeat == .heartbeat);
    try std.testing.expectEqualStrings("probe", heartbeat.heartbeat);
    const terminate = terminal.parseInput(allocator, "{\"type\":\"terminate\"}");
    defer terminate.deinit(allocator);
    try std.testing.expect(terminal.isCloseInput(terminate));
    const resize = terminal.parseInput(allocator, "{\"type\":\"resize\",\"cols\":-1,\"rows\":99999}");
    defer resize.deinit(allocator);
    try std.testing.expect(resize == .resize);
    try std.testing.expectEqual(@as(u16, 0), resize.resize.cols);
    try std.testing.expectEqual(@as(u16, 0), resize.resize.rows);
}
