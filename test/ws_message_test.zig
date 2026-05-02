const std = @import("std");
const report_ws = @import("protocol_ws_message");

test "websocket terminal message parses by request id" {
    const msg = try report_ws.parseServerMessage(std.testing.allocator, "{\"request_id\":\"term-1\"}");
    defer msg.deinit(std.testing.allocator);
    try std.testing.expectEqual(report_ws.ServerMessageKind.terminal, msg.kind);
    try std.testing.expectEqualStrings("term-1", msg.request_id);
}

test "websocket exec and ping messages parse" {
    const exec = try report_ws.parseServerMessage(std.testing.allocator, "{\"message\":\"exec\",\"task_id\":\"t1\",\"command\":\"id\"}");
    defer exec.deinit(std.testing.allocator);
    try std.testing.expectEqual(report_ws.ServerMessageKind.exec, exec.kind);
    try std.testing.expectEqualStrings("t1", exec.task_id);
    try std.testing.expectEqualStrings("id", exec.command);

    const ping = try report_ws.parseServerMessage(std.testing.allocator, "{\"message\":\"ping\",\"ping_task_id\":7,\"ping_type\":\"tcp\",\"ping_target\":\"example.com:443\"}");
    defer ping.deinit(std.testing.allocator);
    try std.testing.expectEqual(report_ws.ServerMessageKind.ping, ping.kind);
    try std.testing.expectEqual(@as(u64, 7), ping.ping_task_id);
    try std.testing.expectEqualStrings("tcp", ping.ping_type);
    try std.testing.expectEqualStrings("example.com:443", ping.ping_target);
}
