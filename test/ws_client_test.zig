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
    try std.testing.expect(frame[4] != 1 or frame[5] != 2 or frame[6] != 3 or frame[7] != 4);
    try std.testing.expectEqual(payload.len + 8, frame.len);

    for (payload, 0..) |b, i| {
        try std.testing.expectEqual(b, frame[8 + i] ^ frame[4 + (i & 3)]);
    }
}

test "websocket small incoming frames reuse client read pool" {
    const client = try std.testing.allocator.create(ws_client.Client);
    client.* = .{};
    defer client.close(std.testing.allocator);

    const first = try ws_client.readFrameFromBytesForTest(client, std.testing.allocator, &.{ 0x81, 0x05, 'h', 'e', 'l', 'l', 'o' });
    try std.testing.expect(first.pooled);
    try std.testing.expectEqualStrings("hello", first.payload);
    const first_ptr = first.payload.ptr;
    first.deinit(client, std.testing.allocator);

    const second = try ws_client.readFrameFromBytesForTest(client, std.testing.allocator, &.{ 0x81, 0x03, 'b', 'y', 'e' });
    defer second.deinit(client, std.testing.allocator);
    try std.testing.expect(second.pooled);
    try std.testing.expectEqual(first_ptr, second.payload.ptr);
    try std.testing.expectEqualStrings("bye", second.payload);
}


test "websocket accept digest is derived from nonce" {
    const accept = try ws_client.expectedAcceptForTest(std.testing.allocator, "dGhlIHNhbXBsZSBub25jZQ==");
    defer std.testing.allocator.free(accept);
    try std.testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", accept);
}

test "websocket writer masks payload with non-fixed frame mask" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    try ws_client.writeMaskedFrameForTest(&out.writer, 0x1, "hello");
    const frame = out.written();
    try std.testing.expectEqual(@as(u8, 0x81), frame[0]);
    try std.testing.expectEqual(@as(u8, 0x80 | 5), frame[1]);
    try std.testing.expect(frame[4] != 1 or frame[5] != 2 or frame[6] != 3 or frame[7] != 4);
}
