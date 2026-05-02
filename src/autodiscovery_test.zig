const std = @import("std");
const autodiscovery = @import("protocol/autodiscovery.zig");

test "stored auto discovery config parses cached token" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const stored = (try autodiscovery.parseStoredConfig(arena.allocator(),
        \\{"uuid":"u1","token":"tok1"}
    )).?;
    try std.testing.expectEqualStrings("u1", stored.uuid);
    try std.testing.expectEqualStrings("tok1", stored.token);
}

test "corrupt stored auto discovery config is ignored" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectEqual(@as(?autodiscovery.AutoDiscoveryConfig, null), try autodiscovery.parseStoredConfig(arena.allocator(), "{not-json"));
}
