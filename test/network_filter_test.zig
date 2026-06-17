const std = @import("std");
const linux = @import("platform_linux");

test "network interface filter matches go defaults" {
    try std.testing.expect(!linux.shouldIncludeNetworkInterface("lo", "", ""));
    try std.testing.expect(!linux.shouldIncludeNetworkInterface("docker0", "", ""));
    try std.testing.expect(!linux.shouldIncludeNetworkInterface("vethabc", "", ""));
    try std.testing.expect(linux.shouldIncludeNetworkInterface("eth0", "", ""));
    try std.testing.expect(linux.shouldIncludeNetworkInterface("eth0", "eth0,wlan0", ""));
    try std.testing.expect(linux.shouldIncludeNetworkInterface("eth0", "eth*", ""));
    try std.testing.expect(!linux.shouldIncludeNetworkInterface("eth1", "eth0,wlan0", ""));
    try std.testing.expect(!linux.shouldIncludeNetworkInterface("eth0", "", "eth0"));
    try std.testing.expect(!linux.shouldIncludeNetworkInterface("ens18", "", "ens*"));
}

test "glob matcher supports simple star patterns" {
    try std.testing.expect(linux.globMatch("*", "eth0"));
    try std.testing.expect(linux.globMatch("eth*", "eth0"));
    try std.testing.expect(linux.globMatch("*0", "eth0"));
    try std.testing.expect(!linux.globMatch("enp*", "eth0"));
}

test "proc net dev parser sums included interfaces" {
    const text =
        \\Inter-|   Receive                                                |  Transmit
        \\ face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
        \\    lo:     100       0    0    0    0     0          0         0      200       0    0    0    0     0       0          0
        \\  eth0:    1000       0    0    0    0     0          0         0     3000       0    0    0    0     0       0          0
        \\docker0:   500       0    0    0    0     0          0         0      600       0    0    0    0     0       0          0
    ;

    const totals = linux.parseProcNetDev(text, "", "");
    try std.testing.expectEqual(@as(u64, 3000), totals.totalUp);
    try std.testing.expectEqual(@as(u64, 1000), totals.totalDown);

    const included = linux.parseProcNetDev(text, "eth0", "");
    try std.testing.expectEqual(@as(u64, 3000), included.totalUp);
    try std.testing.expectEqual(@as(u64, 1000), included.totalDown);

    const excluded = linux.parseProcNetDev(text, "", "eth0");
    try std.testing.expectEqual(@as(u64, 0), excluded.totalUp);
    try std.testing.expectEqual(@as(u64, 0), excluded.totalDown);
}

test "ip addr parser handles aliased interface names and global addresses" {
    const text =
        \\2: eth0@if42    inet 198.51.100.10/24 brd 198.51.100.255 scope global eth0
        \\2: eth0@if42    inet6 2001:db8::10/64 scope global dynamic noprefixroute
        \\2: eth0@if42    inet6 fe80::1/64 scope link
    ;

    const parsed = linux.parseIpAddrOutput(text, "", "");
    try std.testing.expectEqualStrings("198.51.100.10", parsed.ipv4);
    try std.testing.expectEqualStrings("2001:db8::10", parsed.ipv6);
}

test "ip route parser extracts source address from allowed interface" {
    const ipv4 = linux.parseIpRouteGetSource(
        "1.1.1.1 via 198.51.100.1 dev eth0 src 198.51.100.10 uid 0",
        "",
        "",
        .ipv4,
    ) orelse "";
    try std.testing.expectEqualStrings("198.51.100.10", ipv4);

    const ipv6 = linux.parseIpRouteGetSource(
        "2001:4860:4860::8888 from :: via 2001:db8::1 dev eth0 src 2001:db8::10 metric 100 pref medium",
        "",
        "",
        .ipv6,
    ) orelse "";
    try std.testing.expectEqualStrings("2001:db8::10", ipv6);

    try std.testing.expect(
        linux.parseIpRouteGetSource(
            "2001:4860:4860::8888 from :: via 2001:db8::1 dev lo src fe80::1 metric 100 pref medium",
            "",
            "",
            .ipv6,
        ) == null,
    );
}

test "ip route parser extracts IPv6 source from multiline route output" {
    const ipv6 = linux.parseIpRouteGetSource(
        \\2001:4860:4860::8888 from :: via fe80::1 dev ens3 proto ra metric 100 pref medium
        \\    cache from :: src 2001:db8::10 metric 100 pref medium
        ,
        "",
        "",
        .ipv6,
    ) orelse "";
    try std.testing.expectEqualStrings("2001:db8::10", ipv6);
}

test "ipv6 probe route accepts allowed interface without explicit source" {
    try std.testing.expect(linux.canProbeRoute(
        "2001:4860:4860::8888 from :: via fe80::1 dev ens3 proto ra metric 100 pref medium",
        "",
        "",
        .ipv6,
    ));

    try std.testing.expect(!linux.canProbeRoute(
        "2001:4860:4860::8888 from :: via fe80::1 dev vmbr0 proto ra metric 100 pref medium",
        "",
        "",
        .ipv6,
    ));
}
