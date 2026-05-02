const std = @import("std");
const ping = @import("protocol_ping");

test "tcp target parser defaults to port 80" {
    const parsed = try ping.parseTcpTarget("example.com");
    try std.testing.expectEqualStrings("example.com", parsed.host);
    try std.testing.expectEqualStrings("80", parsed.port);
}

test "http target parser adds http scheme" {
    const target = try ping.normalizeHttpTarget(std.testing.allocator, "example.com");
    defer std.testing.allocator.free(target);
    try std.testing.expectEqualStrings("http://example.com", target);
}
