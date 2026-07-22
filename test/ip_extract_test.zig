const std = @import("std");
const ip = @import("protocol_ip");

test "extracts ipv4 from trace and json bodies" {
    try std.testing.expectEqualStrings("203.0.113.8", ip.findIPv4("fl=1\nip=203.0.113.8\n") orelse "");
    try std.testing.expectEqualStrings("198.51.100.9", ip.findIPv4("{\"ip\":\"198.51.100.9\"}") orelse "");
}

test "extracts ipv6 from json and plain bodies" {
    try std.testing.expectEqualStrings("2001:db8::1", ip.findIPv6("{\"ip\":\"2001:db8::1\"}") orelse "");
    try std.testing.expectEqualStrings("2400:3200::1", ip.findIPv6("addr=2400:3200::1\n") orelse "");
}

test "returns null when no address is present" {
    try std.testing.expect(ip.findIPv4("status=ok\nno-address-here\n") == null);
    try std.testing.expect(ip.findIPv6("status=ok\nno-address-here\n") == null);
}

test "external lookup runs in automatic mode unless explicitly overridden" {
    try std.testing.expect(ip.shouldLookupExternalAddress("", "", true));
    try std.testing.expect(ip.shouldLookupExternalAddress("192.0.2.10", "", true));
    try std.testing.expect(ip.shouldLookupExternalAddress("203.0.113.9", "", true));
    try std.testing.expect(!ip.shouldLookupExternalAddress("", "198.51.100.8", true));
    try std.testing.expect(!ip.shouldLookupExternalAddress("", "", false));
}

test "classifies publicly routable IPv4 addresses" {
    try std.testing.expect(ip.isPubliclyRoutableIPv4("1.1.1.1"));
    try std.testing.expect(ip.isPubliclyRoutableIPv4("8.8.8.8"));
    try std.testing.expect(ip.isPubliclyRoutableIPv4("192.1.1.1"));
    try std.testing.expect(ip.isPubliclyRoutableIPv4("198.20.0.1"));
    try std.testing.expect(ip.isPubliclyRoutableIPv4("203.0.114.1"));
}

test "rejects private shared and special-use IPv4 addresses" {
    const rejected = [_][]const u8{
        "",           "not-an-ip",       "1.2.3",        "1.2.3.4.5",
        "0.0.0.0",    "10.91.0.28",      "100.64.0.1",   "100.127.255.254",
        "127.0.0.1",  "169.254.1.1",     "172.16.0.1",   "172.31.255.254",
        "192.0.0.1",  "192.0.2.1",       "192.88.99.1",  "192.168.1.1",
        "198.18.0.1", "198.19.255.254",  "198.51.100.1", "203.0.113.1",
        "224.0.0.1",  "239.255.255.255", "240.0.0.1",    "255.255.255.255",
    };
    for (rejected) |value| try std.testing.expect(!ip.isPubliclyRoutableIPv4(value));
}
