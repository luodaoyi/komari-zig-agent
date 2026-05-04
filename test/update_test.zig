const std = @import("std");
const local_http = @import("local_http.zig");
const update = @import("update");

test "release versions compare with or without v prefix" {
    try std.testing.expect(update.newerThan("v0.1.0", "v0.1.1"));
    try std.testing.expect(update.newerThan("0.1.0", "v0.2.0"));
    try std.testing.expect(!update.newerThan("v0.2.0", "0.2.0"));
    try std.testing.expect(!update.newerThan("v0.2.1", "v0.2.0"));
}

test "stable release updates same numeric prerelease" {
    try std.testing.expect(update.newerThan("v0.1.4-webssh2", "v0.1.4"));
    try std.testing.expect(update.newerThan("0.1.4-rc1", "0.1.4"));
    try std.testing.expect(!update.newerThan("0.1.4", "0.1.4-rc1"));
}

test "build metadata does not affect release ordering" {
    try std.testing.expect(!update.newerThan("v0.1.6+local", "v0.1.6"));
    try std.testing.expect(update.newerThan("v0.1.6+local", "v0.1.7"));
}

test "development builds update to stable releases" {
    try std.testing.expect(update.newerThan("dev", "v0.1.17"));
    try std.testing.expect(update.newerThan("v0.1.17-tlsstack-test", "v0.1.17"));
}

test "self update asset name matches release assets" {
    const name = try update.assetName(std.testing.allocator);
    defer std.testing.allocator.free(name);
    try std.testing.expect(std.mem.startsWith(u8, name, "komari-agent-"));
    try std.testing.expect(std.mem.count(u8, name, "-") >= 2);
}

test "self update github proxy urls do not include closed mirrors" {
    for (&update.default_github_proxies) |proxy| {
        try std.testing.expect(std.mem.indexOf(u8, proxy, "hub.gitmirror.com") == null);
    }

    const url = try update.githubProxyUrl(std.testing.allocator, "https://gh.example.com/", "https://github.com/o/r/releases/latest/download/a");
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("https://gh.example.com/https://github.com/o/r/releases/latest/download/a", url);

    const api_url = try update.githubProxyUrl(std.testing.allocator, "https://gh.example.com/", "https://api.github.com/repos/o/r/releases/latest");
    defer std.testing.allocator.free(api_url);
    try std.testing.expectEqualStrings("https://gh.example.com/https://api.github.com/repos/o/r/releases/latest", api_url);
}

test "self update release api override helper duplicates value" {
    const url = try update.releaseApiUrlFromEnvValueForTest(std.testing.allocator, "http://127.0.0.1/release/latest");
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("http://127.0.0.1/release/latest", url);
}

test "self update identifies github release asset urls" {
    try std.testing.expect(update.githubReleaseAssetUrlForTest("https://github.com/o/r/releases/download/v1/a"));
    try std.testing.expect(!update.githubReleaseAssetUrlForTest("https://api.github.com/repos/o/r/releases/latest"));
    try std.testing.expect(!update.githubReleaseAssetUrlForTest("https://example.com/o/r/releases/download/v1/a"));
}

test "self update downloads release assets through proxy using real http" {
    const responses = [_][]const u8{
        "HTTP/1.1 200 OK\r\nContent-Length: 11\r\nConnection: close\r\n\r\nhello world",
    };
    var server = try local_http.Server.start(std.testing.allocator, &responses);
    defer server.join() catch unreachable;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try tmp.dir.createFile(std.testing.io, "asset", .{ .read = true });
    defer file.close(std.testing.io);

    const proxy = try server.url(std.testing.allocator, "");
    defer std.testing.allocator.free(proxy);
    const digest = (try update.downloadGithubUrlToFileViaProxyListForTest(
        std.testing.allocator,
        "https://github.com/luodaoyi/komari-zig-agent/releases/download/v0.1.17/komari-agent-linux-amd64",
        file,
        &.{proxy},
    )).?;

    var expected: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("hello world", &expected, .{});
    try std.testing.expectEqualSlices(u8, &expected, &digest);

    const body = try tmp.dir.readFileAlloc(std.testing.io, "asset", std.testing.allocator, .limited(64));
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings("hello world", body);
}

test "self update checksum file parser accepts common formats" {
    const sums =
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa  komari-agent-linux-amd64\n" ++
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb *komari-agent-linux-arm64\n";

    try std.testing.expectEqualStrings(
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        update.checksumFromSums(sums, "komari-agent-linux-amd64").?,
    );
    try std.testing.expectEqualStrings(
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        update.checksumFromSums(sums, "komari-agent-linux-arm64").?,
    );
    try std.testing.expect(update.checksumFromSums(sums, "missing") == null);
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
