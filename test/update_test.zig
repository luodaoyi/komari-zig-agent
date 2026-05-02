const std = @import("std");
const update = @import("update");

test "release versions compare with or without v prefix" {
    try std.testing.expect(update.newerThan("v0.1.0", "v0.1.1"));
    try std.testing.expect(update.newerThan("0.1.0", "v0.2.0"));
    try std.testing.expect(!update.newerThan("v0.2.0", "0.2.0"));
    try std.testing.expect(!update.newerThan("v0.2.1", "v0.2.0"));
}

test "self update asset name matches release assets" {
    const name = try update.assetName(std.testing.allocator);
    defer std.testing.allocator.free(name);
    try std.testing.expect(std.mem.startsWith(u8, name, "komari-agent-"));
    try std.testing.expect(std.mem.count(u8, name, "-") >= 2);
}

test "pending update allows first start then rolls back next unconfirmed start" {
    var state = update.PendingUpdateState{
        .previous_version = "v0.1.2",
        .target_version = "v0.1.3",
        .backup_path = "/opt/komari/agent.bak",
        .attempts = 0,
    };

    try std.testing.expectEqual(update.PendingAction.allow_start, update.pendingAction(state));
    state.attempts += 1;
    try std.testing.expectEqual(update.PendingAction.rollback, update.pendingAction(state));
}

test "pending update state roundtrips json" {
    const state = update.PendingUpdateState{
        .previous_version = "v0.1.2",
        .target_version = "v0.1.3",
        .backup_path = "/opt/komari/agent.bak",
        .attempts = 1,
    };

    const json = try update.allocPendingStateJson(std.testing.allocator, state);
    defer std.testing.allocator.free(json);
    const parsed = try update.parsePendingState(std.testing.allocator, json);
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("v0.1.2", parsed.previous_version);
    try std.testing.expectEqualStrings("v0.1.3", parsed.target_version);
    try std.testing.expectEqualStrings("/opt/komari/agent.bak", parsed.backup_path);
    try std.testing.expectEqual(@as(u32, 1), parsed.attempts);
}
