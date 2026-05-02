const std = @import("std");
const version = @import("version");

test "default version and repository are compatible" {
    try std.testing.expectEqualStrings("0.0.1", version.current);
    try std.testing.expectEqualStrings("luodaoyi/komari-zig-agent", version.repo);
}
