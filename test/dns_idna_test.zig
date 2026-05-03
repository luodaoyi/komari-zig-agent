const std = @import("std");
const dns = @import("dns");
const idna = @import("idna");

test "custom dns server normalization" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try std.testing.expectEqualStrings("8.8.8.8:53", try dns.normalizeDnsServer(allocator, "8.8.8.8"));
    try std.testing.expectEqualStrings("8.8.8.8:53", try dns.normalizeDnsServer(allocator, "8.8.8.8:53"));
    try std.testing.expectEqualStrings("[2606:4700:4700::1111]:53", try dns.normalizeDnsServer(allocator, "2606:4700:4700::1111"));
    try std.testing.expectEqualStrings("[2606:4700:4700::1111]:53", try dns.normalizeDnsServer(allocator, "[2606:4700:4700::1111]:53"));
    try std.testing.expectEqualStrings("", try dns.normalizeDnsServer(allocator, " \t\r\n"));
}

test "idn url converts unicode host labels to punycode" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const converted = try idna.convertUrlToAscii(arena.allocator(), "https://中文.域名.com:8443/api");
    try std.testing.expectEqualStrings("https://xn--fiq228c.xn--eqrt2g.com:8443/api", converted);
}
