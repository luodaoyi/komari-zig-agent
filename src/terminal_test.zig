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
    const input = terminal.parseInput(std.testing.allocator, "{\"type\":\"heartbeat\",\"timestamp\":\"2026-06-17T00:00:00Z\"}");
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
