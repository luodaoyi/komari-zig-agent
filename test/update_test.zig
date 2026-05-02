const std = @import("std");
const update = @import("update");

test "release versions compare with or without v prefix" {
    try std.testing.expect(update.newerThan("v0.1.0", "v0.1.1"));
    try std.testing.expect(update.newerThan("0.1.0", "v0.2.0"));
    try std.testing.expect(!update.newerThan("v0.2.0", "0.2.0"));
    try std.testing.expect(!update.newerThan("v0.2.1", "v0.2.0"));
}

test "self update asset name matches release assets" {
    const name = try update.assetName(std.testing.allocator);
    defer std.testing.allocator.free(name);
    try std.testing.expect(std.mem.startsWith(u8, name, "komari-agent-"));
    try std.testing.expect(std.mem.count(u8, name, "-") >= 2);
}
