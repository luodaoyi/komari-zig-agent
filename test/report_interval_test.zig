const std = @import("std");
const timing = @import("protocol_report_timing");

test "report interval clamps to at least one second" {
    try std.testing.expectEqual(@as(u64, 1000), timing.reportIntervalMs(0));
    try std.testing.expectEqual(@as(u64, 1000), timing.reportIntervalMs(-1));
    try std.testing.expectEqual(@as(u64, 1000), timing.reportIntervalMs(0.5));
    try std.testing.expectEqual(@as(u64, 1000), timing.reportIntervalMs(1));
    try std.testing.expectEqual(@as(u64, 2500), timing.reportIntervalMs(2.5));
}

test "remaining report sleep uses elapsed work time" {
    try std.testing.expectEqual(@as(u64, 900), timing.remainingSleepMs(1000, 1000, 1100));
    try std.testing.expectEqual(@as(u64, 0), timing.remainingSleepMs(1000, 1000, 2000));
    try std.testing.expectEqual(@as(u64, 0), timing.remainingSleepMs(1000, 1000, 2500));
    try std.testing.expectEqual(@as(u64, 1000), timing.remainingSleepMs(1000, 1000, 900));
}
