const std = @import("std");

/// Formatting helper for appending into existing array lists.
pub fn appendPrint(
    allocator: std.mem.Allocator,
    list: *std.ArrayList(u8),
    comptime fmt: []const u8,
    args: anytype,
) !void {
    var writer = std.Io.Writer.Allocating.fromArrayList(allocator, list);
    errdefer list.* = writer.toArrayList();
    try writer.writer.print(fmt, args);
    list.* = writer.toArrayList();
}
