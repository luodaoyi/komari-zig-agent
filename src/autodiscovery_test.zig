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

test "register response requires success status" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const parsed = try autodiscovery.parseRegisterResponse(arena.allocator(),
        \\{"status":"success","data":{"uuid":"u1","token":"tok1"}}
    );
    try std.testing.expectEqualStrings("u1", parsed.uuid);
    try std.testing.expectEqualStrings("tok1", parsed.token);

    try std.testing.expectError(error.AutoDiscoveryBadResponse, autodiscovery.parseRegisterResponse(arena.allocator(),
        \\{"data":{"uuid":"u1","token":"tok1"}}
    ));
    try std.testing.expectError(error.AutoDiscoveryFailed, autodiscovery.parseRegisterResponse(arena.allocator(),
        \\{"status":"error","data":{"uuid":"u1","token":"tok1"}}
    ));
}
