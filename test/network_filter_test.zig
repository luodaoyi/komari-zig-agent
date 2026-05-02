const std = @import("std");
const linux = @import("platform_linux");

test "network interface filter matches go defaults" {
    try std.testing.expect(!linux.shouldIncludeNetworkInterface("lo", "", ""));
    try std.testing.expect(!linux.shouldIncludeNetworkInterface("docker0", "", ""));
    try std.testing.expect(!linux.shouldIncludeNetworkInterface("vethabc", "", ""));
    try std.testing.expect(linux.shouldIncludeNetworkInterface("eth0", "", ""));
    try std.testing.expect(linux.shouldIncludeNetworkInterface("eth0", "eth0,wlan0", ""));
    try std.testing.expect(!linux.shouldIncludeNetworkInterface("eth1", "eth0,wlan0", ""));
    try std.testing.expect(!linux.shouldIncludeNetworkInterface("eth0", "", "eth0"));
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
}
