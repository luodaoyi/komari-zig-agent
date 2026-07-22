const std = @import("std");
const netstatic = @import("report_netstatic");

test "last reset date returns current timestamp for invalid reset day" {
    const now = try netstatic.utcTimestamp(2026, 5, 2);
    try std.testing.expectEqual(now, netstatic.lastResetDate(0, now));
    try std.testing.expectEqual(now, netstatic.lastResetDate(32, now));
}

test "last reset date uses this month when current day passed reset day" {
    const now = try netstatic.utcTimestamp(2026, 5, 20);
    const expected = try netstatic.utcTimestamp(2026, 5, 8);
    try std.testing.expectEqual(expected, netstatic.lastResetDate(8, now));
}

test "last reset date uses previous month when current day before reset day" {
    const now = try netstatic.utcTimestamp(2026, 5, 2);
    const expected = try netstatic.utcTimestamp(2026, 4, 8);
    try std.testing.expectEqual(expected, netstatic.lastResetDate(8, now));
}

test "last reset date rolls impossible day to next month first day" {
    const now = try netstatic.utcTimestamp(2026, 3, 30);
    const expected = try netstatic.utcTimestamp(2026, 3, 1);
    try std.testing.expectEqual(expected, netstatic.lastResetDate(31, now));
}

test "store json round trips baseline counters" {
    const json = try netstatic.allocStoreJson(std.testing.allocator, .{ .reset = 123, .up = 456, .down = 789 });
    defer std.testing.allocator.free(json);
    const parsed = try netstatic.parseStore(json);
    try std.testing.expectEqual(@as(i64, 123), parsed.reset);
    try std.testing.expectEqual(@as(u64, 456), parsed.up);
    try std.testing.expectEqual(@as(u64, 789), parsed.down);
}

test "invalid persisted traffic data is rejected" {
    try std.testing.expectError(error.InvalidNetStaticState, netstatic.validatePersistedState(std.testing.allocator, "{\"interfaces\":"));
}

test "legacy persisted traffic with one extra closing brace remains readable" {
    const legacy = "{\"interfaces\":{},\"config\":{\"data_preserve_day\":31}}}";
    try netstatic.validatePersistedState(std.testing.allocator, legacy);
}

test "valid persisted traffic remains readable" {
    const valid = "{\"interfaces\":{},\"config\":{\"data_preserve_day\":31}}";
    try netstatic.validatePersistedState(std.testing.allocator, valid);
}
