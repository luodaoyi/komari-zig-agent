const std = @import("std");
const freebsd = @import("platform_freebsd");

test "freebsd ifconfig parser fills public NIC IPv4 like hostuno ixl0" {
    const text =
        \\lo0: flags=8049<UP,LOOPBACK,RUNNING,MULTICAST> metric 0 mtu 16384
        \\        inet 127.0.0.1 netmask 0xff000000
        \\        inet6 ::1 prefixlen 128
        \\ixl0: flags=8843<UP,BROADCAST,RUNNING,SIMPLEX,MULTICAST> metric 0 mtu 1500
        \\        inet 203.0.114.10 netmask 0xffffff00 broadcast 203.0.114.255
        \\        inet6 2001:db8::10 prefixlen 64
        \\        inet6 fe80::1%ixl0 prefixlen 64 scopeid 0x1
        \\ixl1: flags=8802<BROADCAST,SIMPLEX,MULTICAST> metric 0 mtu 1500
        \\        inet 198.51.100.20 netmask 0xffffff00 broadcast 198.51.100.255
    ;

    const parsed = freebsd.parseIfconfigLocalIp(text, "", "");
    try std.testing.expectEqualStrings("203.0.114.10", parsed.ipv4);
    try std.testing.expectEqualStrings("2001:db8::10", parsed.ipv6);
}

test "freebsd ifconfig parser skips loopback and honors include list" {
    const text =
        \\lo0: flags=8049<UP,LOOPBACK,RUNNING,MULTICAST> metric 0 mtu 16384
        \\        inet 127.0.0.1 netmask 0xff000000
        \\ixl0: flags=8843<UP,BROADCAST,RUNNING,SIMPLEX,MULTICAST> metric 0 mtu 1500
        \\        inet 203.0.114.10 netmask 0xffffff00 broadcast 203.0.114.255
        \\ixl1: flags=8802<BROADCAST,SIMPLEX,MULTICAST> metric 0 mtu 1500
        \\        inet 198.51.100.20 netmask 0xffffff00 broadcast 198.51.100.255
    ;

    const only_ixl1 = freebsd.parseIfconfigLocalIp(text, "ixl1", "");
    try std.testing.expectEqualStrings("198.51.100.20", only_ixl1.ipv4);

    const empty = freebsd.parseIfconfigLocalIp(text, "", "ixl0,ixl1");
    try std.testing.expectEqualStrings("", empty.ipv4);
}

test "freebsd netstat strips trailing asterisk from down interfaces" {
    try std.testing.expectEqualStrings("ixl1", freebsd.normalizeNetstatIfaceName("ixl1*"));
    try std.testing.expectEqualStrings("ixl0", freebsd.normalizeNetstatIfaceName("ixl0"));
    try std.testing.expectEqualStrings("", freebsd.normalizeNetstatIfaceName(""));

    const text =
        \\Name            Mtu Network       Address              Ipkts Ierrs Idrop     Ibytes    Opkts Oerrs      Obytes  Coll
        \\ixl0         1500 <Link#1>                            100     0     0      1000      200     0       3000     0
        \\ixl1*        1500 <Link#2>                              0     0     0         0        0     0          0     0
        \\lo0         16384 <Link#3>                            10     0     0       100       10     0        100     0
    ;

    const names = try freebsd.parseNetstatInterfaceNames(std.testing.allocator, text, "", "");
    defer {
        for (names) |name| std.testing.allocator.free(name);
        std.testing.allocator.free(names);
    }

    try std.testing.expectEqual(@as(usize, 2), names.len);
    try std.testing.expectEqualStrings("ixl0", names[0]);
    try std.testing.expectEqualStrings("ixl1", names[1]);
}
