const std = @import("std");
const linux = @import("platform_linux");

test "cpu usage is calculated from proc stat delta" {
    const previous = linux.parseCpuStat("cpu  100 0 100 800 0 0 0 0 0 0\n").?;
    const current = linux.parseCpuStat("cpu  150 0 150 900 0 0 0 0 0 0\n").?;
    try std.testing.expectEqual(@as(f64, 50.0), linux.cpuUsagePercent(previous, current));
}

test "connection parser counts tcp and udp entries excluding headers" {
    const table =
        \\  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
        \\   0: 0100007F:0016 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 1 1 0000000000000000 100 0 0 10 0
        \\   1: 0100007F:9C4C 0100007F:0016 01 00000000:00000000 00:00000000 00000000  1000        0 2 1 0000000000000000 20 4 30 10 -1
    ;
    try std.testing.expectEqual(@as(u64, 2), linux.countProcNetConnections(table));
}
