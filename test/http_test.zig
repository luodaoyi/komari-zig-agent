const std = @import("std");
const config = @import("config");
const http = @import("protocol_http");

test "endpoint helpers trim slash and place token query" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try std.testing.expectEqualStrings(
        "https://panel.example/api/clients/uploadBasicInfo?token=tok",
        try http.basicInfoUrl(allocator, "https://panel.example/", "tok"),
    );
    try std.testing.expectEqualStrings(
        "https://panel.example/api/clients/task/result?token=tok",
        try http.taskResultUrl(allocator, "https://panel.example/", "tok"),
    );
    try std.testing.expectEqualStrings(
        "https://panel.example/api/clients/register?name=host%20one",
        try http.registerUrl(allocator, "https://panel.example/", "host one"),
    );
    try std.testing.expectEqualStrings(
        "https://panel.example/api/clients/register?name=a%2Fb%3Fc%3Dd",
        try http.registerUrl(allocator, "https://panel.example/", "a/b?c=d"),
    );
}

test "websocket helpers convert scheme" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try std.testing.expectEqualStrings(
        "wss://panel.example/api/clients/report?token=tok",
        try http.reportWsUrl(allocator, "https://panel.example/", "tok"),
    );
    try std.testing.expectEqualStrings(
        "ws://panel.example/api/clients/terminal?token=tok&id=req",
        try http.terminalWsUrl(allocator, "http://panel.example/", "tok", "req"),
    );
    try std.testing.expectEqualStrings(
        "wspanel.example/api/clients/report?token=tok",
        try http.reportWsUrl(allocator, "panel.example/", "tok"),
    );
}

test "cloudflare access headers are added when both values exist" {
    const cfg = config.Config{
        .cf_access_client_id = "id",
        .cf_access_client_secret = "secret",
    };
    var headers = http.Headers{};
    http.addCloudflareHeaders(&headers, cfg);

    try std.testing.expectEqualStrings("id", headers.cf_access_client_id.?);
    try std.testing.expectEqualStrings("secret", headers.cf_access_client_secret.?);

    var raw: [2]std.http.Header = undefined;
    const built = http.cloudflareHeaders(cfg, &raw);
    try std.testing.expectEqual(@as(usize, 2), built.len);
    try std.testing.expectEqualStrings("CF-Access-Client-Id", built[0].name);

    var missing = http.Headers{};
    http.addCloudflareHeaders(&missing, config.Config{ .cf_access_client_id = "id" });
    try std.testing.expect(missing.cf_access_client_id == null);
    try std.testing.expectEqual(@as(usize, 0), http.cloudflareHeaders(config.Config{ .cf_access_client_secret = "secret" }, &raw).len);
}

test "http client shell keeps timeout tls and retry settings" {
    const client = http.Client.init(.{
        .timeout_ms = 30000,
        .ignore_unsafe_cert = true,
        .max_retries = 3,
    });

    try std.testing.expectEqual(@as(u64, 30000), client.timeout_ms);
    try std.testing.expect(client.ignore_unsafe_cert);
    try std.testing.expectEqual(@as(u32, 3), client.max_retries);
    try std.testing.expect(client.shouldRetry(0, error.TemporaryNetworkFailure, null));
    try std.testing.expect(!client.shouldRetry(3, error.TemporaryNetworkFailure, null));
    try std.testing.expect(client.shouldRetry(0, null, 500));
    try std.testing.expect(client.shouldRetry(0, null, 204));
    try std.testing.expect(!client.shouldRetry(0, null, 200));
}

test "bounded response writer enforces limit while writing" {
    const exact = try http.collectBoundedResponseForTest(std.testing.allocator, 4, &.{ "ab", "cd" });
    defer std.testing.allocator.free(exact);
    try std.testing.expectEqualStrings("abcd", exact);

    try std.testing.expectError(
        error.HttpResponseTooLarge,
        http.collectBoundedResponseForTest(std.testing.allocator, 4, &.{ "ab", "cde" }),
    );
    try std.testing.expectError(
        error.HttpResponseTooLarge,
        http.collectBoundedResponseForTest(std.testing.allocator, 0, &.{"x"}),
    );
}

test "streaming response writer saves file and returns sha256" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const response =
        "HTTP/1.1 200 OK\r\n" ++
        "Transfer-Encoding: chunked\r\n" ++
        "\r\n" ++
        "5\r\nhello\r\n" ++
        "6\r\n world\r\n" ++
        "0\r\n\r\n";
    const digest = blk: {
        var file = try tmp.dir.createFile(std.testing.io, "body", .{ .read = true });
        defer file.close(std.testing.io);
        break :blk try http.writeResponseToFileSha256ForTest(std.testing.allocator, response, file);
    };

    var expected: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("hello world", &expected, .{});
    try std.testing.expectEqualSlices(u8, &expected, &digest);

    const body = try tmp.dir.readFileAlloc(std.testing.io, "body", std.testing.allocator, .limited(64));
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings("hello world", body);
}

test "proxy environment follows request scheme" {
    try std.testing.expectEqualStrings(
        "http://http-proxy.example:8080",
        http.proxyEnvForScheme("http", .{
            .http_proxy = "http://http-proxy.example:8080",
            .https_proxy = "http://https-proxy.example:8443",
        }).?,
    );
    try std.testing.expectEqualStrings(
        "http://https-proxy.example:8443",
        http.proxyEnvForScheme("https", .{
            .http_proxy = "http://http-proxy.example:8080",
            .https_proxy = "http://https-proxy.example:8443",
        }).?,
    );
}

test "proxy environment accepts lowercase and all proxy fallback" {
    try std.testing.expectEqualStrings(
        "http://lower-proxy.example:8080",
        http.proxyEnvForScheme("http", .{ .http_proxy_lower = "http://lower-proxy.example:8080" }).?,
    );
    try std.testing.expectEqualStrings(
        "http://all-proxy.example:8080",
        http.proxyEnvForScheme("https", .{ .all_proxy = "http://all-proxy.example:8080" }).?,
    );
    try std.testing.expectEqualStrings(
        "http://ws-proxy.example:8080",
        http.proxyEnvForScheme("ws", .{ .http_proxy = "http://ws-proxy.example:8080" }).?,
    );
    try std.testing.expectEqualStrings(
        "http://wss-proxy.example:8080",
        http.proxyEnvForScheme("wss", .{ .https_proxy = "http://wss-proxy.example:8080" }).?,
    );
    try std.testing.expectEqual(@as(?[]const u8, null), http.proxyEnvForScheme("https", .{}));
    try std.testing.expectEqual(@as(?[]const u8, null), http.proxyEnvForScheme("ftp", .{ .all_proxy = "http://all-proxy.example:8080" }));
}

test "proxy environment honors no proxy hosts" {
    const env = http.ProxyEnv{
        .http_proxy = "http://proxy.example:8080",
        .no_proxy = ".internal.example,api.example.com:8443,[2001:db8::1],10.0.0.0/8,fd00::/8",
    };

    try std.testing.expectEqual(@as(?[]const u8, null), http.proxyEnvForRequest("http", "localhost", 80, env));
    try std.testing.expectEqual(@as(?[]const u8, null), http.proxyEnvForRequest("http", "127.0.0.1", 80, env));
    try std.testing.expectEqual(@as(?[]const u8, null), http.proxyEnvForRequest("http", "::1", 80, env));
    try std.testing.expectEqual(@as(?[]const u8, null), http.proxyEnvForRequest("https", "node.internal.example", 443, env));
    try std.testing.expectEqual(@as(?[]const u8, null), http.proxyEnvForRequest("https", "api.example.com", 8443, env));
    try std.testing.expectEqual(@as(?[]const u8, null), http.proxyEnvForRequest("http", "2001:db8::1", 80, env));
    try std.testing.expectEqual(@as(?[]const u8, null), http.proxyEnvForRequest("http", "10.9.8.7", 80, env));
    try std.testing.expectEqual(@as(?[]const u8, null), http.proxyEnvForRequest("http", "fd00::1234", 80, env));
    try std.testing.expectEqualStrings(
        "http://proxy.example:8080",
        http.proxyEnvForRequest("http", "internal.example", 80, env).?,
    );
    try std.testing.expectEqualStrings(
        "http://proxy.example:8080",
        http.proxyEnvForRequest("http", "api.example.com", 443, env).?,
    );
}

test "proxy environment wildcard bypasses all proxy use" {
    try std.testing.expectEqual(@as(?[]const u8, null), http.proxyEnvForRequest("http", "example.com", 80, .{
        .http_proxy = "http://proxy.example:8080",
        .no_proxy_lower = "*",
    }));
}
