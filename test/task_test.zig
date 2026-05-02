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
