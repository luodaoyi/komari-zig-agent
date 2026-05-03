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

test "websocket masked writer handles extended payload in chunks" {
    const payload = try std.testing.allocator.alloc(u8, 9000);
    defer std.testing.allocator.free(payload);
    for (payload, 0..) |*b, i| b.* = @intCast(i & 0xff);

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try ws_client.writeMaskedFrameForTest(&out.writer, 0x2, payload);
    const frame = out.written();

    try std.testing.expectEqual(@as(u8, 0x82), frame[0]);
    try std.testing.expectEqual(@as(u8, 0x80 | 126), frame[1]);
    const len = (@as(usize, frame[2]) << 8) | frame[3];
    try std.testing.expectEqual(payload.len, len);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, frame[4..8]);
    try std.testing.expectEqual(payload.len + 8, frame.len);

    for (payload, 0..) |b, i| {
        try std.testing.expectEqual(b, frame[8 + i] ^ frame[4 + (i & 3)]);
    }
}
