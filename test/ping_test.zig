const std = @import("std");
const ping = @import("protocol_ping");

test "tcp target parser defaults to port 80" {
    const parsed = try ping.parseTcpTarget("example.com");
    try std.testing.expectEqualStrings("example.com", parsed.host);
    try std.testing.expectEqualStrings("80", parsed.port);
}

test "tcp target parser accepts explicit port" {
    const parsed = try ping.parseTcpTarget("example.com:443");
    try std.testing.expectEqualStrings("example.com", parsed.host);
    try std.testing.expectEqualStrings("443", parsed.port);
}

test "http target parser adds http scheme" {
    const target = try ping.normalizeHttpTarget(std.testing.allocator, "example.com");
    defer std.testing.allocator.free(target);
    try std.testing.expectEqualStrings("http://example.com", target);
}

test "http target parser preserves existing scheme" {
    const target = try ping.normalizeHttpTarget(std.testing.allocator, "https://example.com");
    defer std.testing.allocator.free(target);
    try std.testing.expectEqualStrings("https://example.com", target);
}

test "ping type parser accepts server variants" {
    try std.testing.expectEqualStrings("tcp", ping.normalizePingTypeForTest("TCP") orelse "");
    try std.testing.expectEqualStrings("tcp", ping.normalizePingTypeForTest("tcp_ping") orelse "");
    try std.testing.expectEqualStrings("http", ping.normalizePingTypeForTest("httping") orelse "");
    try std.testing.expectEqualStrings("icmp", ping.normalizePingTypeForTest("ping") orelse "");
    try std.testing.expectEqual(@as(?[]const u8, null), ping.normalizePingTypeForTest("dns"));
}

test "icmp checksum is deterministic" {
    var packet = [_]u8{ 8, 0, 0, 0, 0x12, 0x34, 0, 1 };
    const sum = ping.icmpChecksum(&packet);
    try std.testing.expect(sum != 0);
    std.mem.writeInt(u16, packet[2..4], sum, .big);
    try std.testing.expectEqual(@as(u16, 0), ping.icmpChecksum(&packet));
}

test "icmp echo reply parser accepts linux datagram socket rewritten identifier" {
    var packet = [_]u8{0} ** 28;
    packet[0] = 0x45; // IPv4 header, 20 bytes.
    packet[20] = 0; // echo reply
    packet[21] = 0;
    packet[24] = 0x56; // Linux ping sockets may rewrite ICMP id.
    packet[25] = 0x78;
    packet[26] = 0;
    packet[27] = 1;
    try std.testing.expect(ping.isIcmpEchoReplyForTest(&packet, 0x1234, 1));
}

test "icmp6 echo reply parser accepts ipv6 payload" {
    var packet = [_]u8{0} ** 48;
    packet[0] = 0x60;
    packet[40] = 129;
    packet[41] = 0;
    packet[44] = 0x12;
    packet[45] = 0x34;
    packet[47] = 1;
    try std.testing.expect(ping.isIcmp6EchoReplyForTest(&packet, 0x1234, 1));
}
