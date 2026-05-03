const std = @import("std");
const ip = @import("protocol_ip");

test "coverage extracts ipv4 from trace and json bodies" {
    try std.testing.expectEqualStrings("203.0.113.8", ip.findIPv4("fl=1\nip=203.0.113.8\n") orelse "");
    try std.testing.expectEqualStrings("198.51.100.9", ip.findIPv4("{\"ip\":\"198.51.100.9\"}") orelse "");
}

test "coverage extracts ipv6 from json and plain bodies" {
    try std.testing.expectEqualStrings("2001:db8::1", ip.findIPv6("{\"ip\":\"2001:db8::1\"}") orelse "");
    try std.testing.expectEqualStrings("2400:3200::1", ip.findIPv6("addr=2400:3200::1\n") orelse "");
}

test "coverage returns null when no address is present" {
    try std.testing.expect(ip.findIPv4("status=ok\nno-address-here\n") == null);
    try std.testing.expect(ip.findIPv6("status=ok\nno-address-here\n") == null);
}
