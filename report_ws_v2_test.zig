const std = @import("std");
const config = @import("src/config.zig");
const local_http = @import("test/local_http.zig");
const report_ws = @import("src/protocol/report_ws.zig");

test "v2 pull request sends ack ids and clears them after success" {
    const first_body = "{\"jsonrpc\":\"2.0\",\"result\":{\"events\":[{\"id\":\"ev-1\",\"method\":\"agent.message\",\"params\":{\"text\":\"hello\"}}]}}";
    const second_body = "{\"jsonrpc\":\"2.0\",\"result\":{\"events\":[{\"id\":\"ev-1\",\"method\":\"agent.message\",\"params\":{\"text\":\"hello\"}},{\"id\":\"ev-2\",\"method\":\"agent.event\",\"params\":{}}],\"status\":\"ok\"}}";
    const third_body = "{\"jsonrpc\":\"2.0\",\"result\":{\"events\":[],\"status\":\"ok\"}}";
    const responses = [_][]const u8{
        std.fmt.comptimePrint("HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ first_body.len, first_body }),
        std.fmt.comptimePrint("HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ second_body.len, second_body }),
        std.fmt.comptimePrint("HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ third_body.len, third_body }),
    };
    var server = try local_http.Server.start(std.testing.allocator, &responses);

    report_ws.initRequestedProtocolVersionForTest(2);
    report_ws.resetConnectionProtocolVersionForTest();
    defer report_ws.resetConnectionProtocolVersionForTest();
    report_ws.resetV2ResponseTrackingForTest();
    defer report_ws.resetV2ResponseTrackingForTest();
    const endpoint = try server.url(std.testing.allocator, "");
    defer std.testing.allocator.free(endpoint);
    const cfg = config.Config{
        .endpoint = endpoint,
        .token = "tok",
        .disable_compression = true,
        .max_retries = 0,
    };
    try report_ws.postV2PullOnceForTest(std.testing.allocator, cfg);
    try report_ws.postV2PullOnceForTest(std.testing.allocator, cfg);
    try report_ws.postV2PullOnceForTest(std.testing.allocator, cfg);

    var completed = try server.finish();
    defer completed.deinit();

    try std.testing.expectEqual(@as(usize, 3), completed.requests.len);
    try std.testing.expectEqualStrings("POST /api/clients/v2/rpc?token=tok HTTP/1.1", completed.requests[0].requestLine());
    var parsed_first = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, completed.requests[0].body, .{});
    defer parsed_first.deinit();
    const first_root = try expectObject(parsed_first.value);
    const first_params = try expectObjectValue(first_root, "params");
    const first_ack_ids = try expectArrayValue(first_params, "ack_event_ids");
    try std.testing.expectEqual(@as(usize, 0), first_ack_ids.items.len);

    try std.testing.expectEqualStrings("POST /api/clients/v2/rpc?token=tok HTTP/1.1", completed.requests[1].requestLine());
    try std.testing.expectEqualStrings("POST /api/clients/v2/rpc?token=tok HTTP/1.1", completed.requests[2].requestLine());
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, completed.requests[1].body, .{});
    defer parsed.deinit();
    const root = try expectObject(parsed.value);
    const params = try expectObjectValue(root, "params");
    const ack_ids = try expectArrayValue(params, "ack_event_ids");
    try std.testing.expectEqual(@as(usize, 1), ack_ids.items.len);
    try std.testing.expectEqualStrings("ev-1", ack_ids.items[0].string);

    var parsed_third = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, completed.requests[2].body, .{});
    defer parsed_third.deinit();
    const third_root = try expectObject(parsed_third.value);
    const third_params = try expectObjectValue(third_root, "params");
    const third_ack_ids = try expectArrayValue(third_params, "ack_event_ids");
    try std.testing.expectEqual(@as(usize, 2), third_ack_ids.items.len);
    try std.testing.expectEqualStrings("ev-1", third_ack_ids.items[0].string);
    try std.testing.expectEqualStrings("ev-2", third_ack_ids.items[1].string);

    const snapshot = try report_ws.snapshotV2AckEventIDsForTest(std.testing.allocator);
    defer std.testing.allocator.free(snapshot);
    try std.testing.expectEqual(@as(usize, 0), snapshot.len);
}

test "v2 response rejects invalid jsonrpc payloads" {
    report_ws.resetV2ResponseTrackingForTest();
    defer report_ws.resetV2ResponseTrackingForTest();
    report_ws.initRequestedProtocolVersionForTest(2);
    report_ws.resetConnectionProtocolVersionForTest();
    defer report_ws.resetConnectionProtocolVersionForTest();

    const cfg = config.Config{
        .endpoint = "http://127.0.0.1:1",
        .token = "tok",
        .disable_compression = true,
        .max_retries = 0,
    };
    try std.testing.expectError(error.InvalidV2Response, report_ws.processV2ResponseBodyForTest(std.testing.allocator, cfg, "{\"jsonrpc\":\"1.0\"}"));
}

test "v2 report helper includes ack ids and clears them after success" {
    const seed_cfg = config.Config{
        .endpoint = "http://127.0.0.1:1",
        .token = "tok",
        .disable_compression = true,
        .max_retries = 0,
    };
    const response_body = "{\"jsonrpc\":\"2.0\",\"result\":{\"status\":\"ok\"}}";
    const response = std.fmt.comptimePrint(
        "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
        .{ response_body.len, response_body },
    );
    const responses = [_][]const u8{response};
    var server = try local_http.Server.start(std.testing.allocator, &responses);
    errdefer server.join() catch unreachable;

    report_ws.resetV2ResponseTrackingForTest();
    defer report_ws.resetV2ResponseTrackingForTest();
    try report_ws.processV2ResponseBodyForTest(
        std.testing.allocator,
        seed_cfg,
        "{\"jsonrpc\":\"2.0\",\"result\":{\"events\":[{\"id\":\"ev-report-1\",\"method\":\"agent.message\",\"params\":{\"text\":\"hello\"}}],\"status\":\"ok\"}}",
    );

    const endpoint = try server.url(std.testing.allocator, "");
    defer std.testing.allocator.free(endpoint);
    const cfg = config.Config{
        .endpoint = endpoint,
        .token = "tok",
        .disable_compression = true,
        .max_retries = 0,
    };
    try report_ws.postV2ReportPayloadForTest(std.testing.allocator, cfg, "{\"counter\":1}");

    var completed = try server.finish();
    defer completed.deinit();

    try std.testing.expectEqual(@as(usize, 1), completed.requests.len);
    try std.testing.expectEqualStrings("POST /api/clients/v2/rpc?token=tok HTTP/1.1", completed.requests[0].requestLine());

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, completed.requests[0].body, .{});
    defer parsed.deinit();
    const root = try expectObject(parsed.value);
    try expectStringField(root, "jsonrpc", "2.0");
    try expectStringField(root, "method", "agent.report");
    const params = try expectObjectValue(root, "params");
    const report_value = try expectObjectValue(params, "report");
    const counter = report_value.get("counter") orelse return error.TestUnexpectedResult;
    if (counter != .integer) return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(i64, 1), counter.integer);
    const ack_ids = try expectArrayValue(params, "ack_event_ids");
    try std.testing.expectEqual(@as(usize, 1), ack_ids.items.len);
    try std.testing.expectEqualStrings("ev-report-1", ack_ids.items[0].string);

    const snapshot = try report_ws.snapshotV2AckEventIDsForTest(std.testing.allocator);
    defer std.testing.allocator.free(snapshot);
    try std.testing.expectEqual(@as(usize, 0), snapshot.len);
}

fn expectObject(value: std.json.Value) !std.json.ObjectMap {
    if (value != .object) return error.TestUnexpectedResult;
    return value.object;
}

fn expectStringField(object: std.json.ObjectMap, key: []const u8, expected: []const u8) !void {
    const value = object.get(key) orelse return error.TestUnexpectedResult;
    if (value != .string) return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(expected, value.string);
}

fn expectObjectValue(object: std.json.ObjectMap, key: []const u8) !std.json.ObjectMap {
    const value = object.get(key) orelse return error.TestUnexpectedResult;
    return expectObject(value);
}

fn expectArrayValue(object: std.json.ObjectMap, key: []const u8) !std.json.Array {
    const value = object.get(key) orelse return error.TestUnexpectedResult;
    if (value != .array) return error.TestUnexpectedResult;
    return value.array;
}


test "sticky v1 is set only after successful v1 fallback connect" {
    report_ws.initRequestedProtocolVersionForTest(2);
    report_ws.resetConnectionProtocolVersionForTest();
    defer report_ws.resetConnectionProtocolVersionForTest();

    report_ws.applyV1FallbackConnectResultForTest(false);
    try std.testing.expectEqual(@as(i32, 2), report_ws.uploadProtocolVersionForTest());

    report_ws.applyV1FallbackConnectResultForTest(true);
    try std.testing.expectEqual(@as(i32, 1), report_ws.uploadProtocolVersionForTest());

    report_ws.prepareReconnectCycleForTest();
    try std.testing.expectEqual(@as(i32, 2), report_ws.uploadProtocolVersionForTest());
}
