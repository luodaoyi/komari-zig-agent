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

test "websocket ping task accepts task id field variants" {
    const numeric = try report_ws.parseServerMessage(std.testing.allocator, "{\"message\":\"ping\",\"task_id\":8,\"ping_type\":\"icmp\",\"ping_target\":\"1.1.1.1\"}");
    defer numeric.deinit(std.testing.allocator);
    try std.testing.expectEqual(report_ws.ServerMessageKind.ping, numeric.kind);
    try std.testing.expectEqual(@as(u64, 8), numeric.ping_task_id);

    const text = try report_ws.parseServerMessage(std.testing.allocator, "{\"message\":\"ping\",\"task_id\":\"9\",\"ping_type\":\"http\",\"ping_target\":\"example.com\"}");
    defer text.deinit(std.testing.allocator);
    try std.testing.expectEqual(report_ws.ServerMessageKind.ping, text.kind);
    try std.testing.expectEqual(@as(u64, 9), text.ping_task_id);
}

test "websocket message parses into caller arena without owned field frees" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const bytes = "{\"message\":\"exec\",\"task_id\":\"t2\",\"command\":\"uname -a\"}";
    const msg = try report_ws.parseServerMessageLeaky(arena.allocator(), bytes);
    defer msg.deinit(std.testing.allocator);
    try std.testing.expect(!msg.owns_fields);
    try std.testing.expectEqual(report_ws.ServerMessageKind.exec, msg.kind);
    try std.testing.expectEqualStrings("t2", msg.task_id);
    try std.testing.expectEqualStrings("uname -a", msg.command);
    try std.testing.expect(sliceInside(bytes, msg.task_id));
    try std.testing.expect(sliceInside(bytes, msg.command));

    try std.testing.expect(arena.reset(.retain_capacity));
}

test "websocket leaky ping parser accepts numeric task id" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const bytes = "{\"message\":\"ping\",\"task_id\":10,\"ping_type\":\"tcp\",\"ping_target\":\"example.com:443\"}";
    const msg = try report_ws.parseServerMessageLeaky(arena.allocator(), bytes);
    defer msg.deinit(std.testing.allocator);
    try std.testing.expect(!msg.owns_fields);
    try std.testing.expectEqual(report_ws.ServerMessageKind.ping, msg.kind);
    try std.testing.expectEqual(@as(u64, 10), msg.ping_task_id);
    try std.testing.expectEqualStrings("tcp", msg.ping_type);
    try std.testing.expectEqualStrings("example.com:443", msg.ping_target);
}

fn sliceInside(container: []const u8, slice: []const u8) bool {
    const start = @intFromPtr(container.ptr);
    const end = start + container.len;
    const ptr = @intFromPtr(slice.ptr);
    return ptr >= start and ptr + slice.len <= end;
}
