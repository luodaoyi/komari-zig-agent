const std = @import("std");
const ws_client = @import("protocol_ws_client");

test "websocket url parser handles defaults explicit ports and ipv6" {
    const plain = try ws_client.parseUrl("ws://panel.example/api/clients/report?token=tok");
    try std.testing.expectEqualStrings("panel.example", plain.host);
    try std.testing.expectEqual(@as(u16, 80), plain.port);
    try std.testing.expectEqualStrings("/api/clients/report?token=tok", plain.path);
    try std.testing.expect(!plain.tls);

    const tls = try ws_client.parseUrl("wss://panel.example:8443/ws");
    try std.testing.expectEqualStrings("panel.example", tls.host);
    try std.testing.expectEqual(@as(u16, 8443), tls.port);
    try std.testing.expect(tls.tls);

    const ipv6 = try ws_client.parseUrl("wss://[2001:db8::1]/terminal");
    try std.testing.expectEqualStrings("2001:db8::1", ipv6.host);
    try std.testing.expectEqual(@as(u16, 443), ipv6.port);
    try std.testing.expectEqualStrings("/terminal", ipv6.path);

    const raw_ipv6 = try ws_client.parseUrl("ws://2001:db8::2/path");
    try std.testing.expectEqualStrings("2001:db8::2", raw_ipv6.host);
    try std.testing.expectEqual(@as(u16, 80), raw_ipv6.port);
}

test "websocket url parser rejects invalid forms" {
    try std.testing.expectError(error.InvalidWebSocketUrl, ws_client.parseUrl("http://panel.example/ws"));
    try std.testing.expectError(error.InvalidWebSocketUrl, ws_client.parseUrl("ws://panel.example"));
    try std.testing.expectError(error.InvalidWebSocketUrl, ws_client.parseUrl("ws://[2001:db8::1/path"));
    try std.testing.expectError(error.InvalidCharacter, ws_client.parseUrl("ws://panel.example:not-a-port/path"));
}
