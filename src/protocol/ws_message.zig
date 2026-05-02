const std = @import("std");

pub const ServerMessageKind = enum {
    unknown,
    terminal,
    exec,
    ping,
};

pub const ServerMessage = struct {
    kind: ServerMessageKind = .unknown,
    message: []const u8 = "",
    request_id: []const u8 = "",
    task_id: []const u8 = "",
    command: []const u8 = "",
    ping_task_id: u64 = 0,
    ping_type: []const u8 = "",
    ping_target: []const u8 = "",

    pub fn deinit(self: ServerMessage, allocator: std.mem.Allocator) void {
        if (self.message.len != 0) allocator.free(self.message);
        if (self.request_id.len != 0) allocator.free(self.request_id);
        if (self.task_id.len != 0) allocator.free(self.task_id);
        if (self.command.len != 0) allocator.free(self.command);
        if (self.ping_type.len != 0) allocator.free(self.ping_type);
        if (self.ping_target.len != 0) allocator.free(self.ping_target);
    }
};

pub fn parseServerMessage(allocator: std.mem.Allocator, bytes: []const u8) !ServerMessage {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return .{};
    const object = parsed.value.object;

    var msg = ServerMessage{
        .message = try dupeString(allocator, object, "message"),
        .request_id = try dupeString(allocator, object, "request_id"),
        .task_id = try dupeString(allocator, object, "task_id"),
        .command = try dupeString(allocator, object, "command"),
        .ping_task_id = intValue(object, "ping_task_id"),
        .ping_type = try dupeString(allocator, object, "ping_type"),
        .ping_target = try dupeString(allocator, object, "ping_target"),
    };

    if (std.mem.eql(u8, msg.message, "terminal") or msg.request_id.len != 0) {
        msg.kind = .terminal;
    } else if (std.mem.eql(u8, msg.message, "exec")) {
        msg.kind = .exec;
    } else if (std.mem.eql(u8, msg.message, "ping") or msg.ping_task_id != 0 or msg.ping_type.len != 0 or msg.ping_target.len != 0) {
        msg.kind = .ping;
    }
    return msg;
}

fn dupeString(allocator: std.mem.Allocator, object: std.json.ObjectMap, key: []const u8) ![]const u8 {
    if (object.get(key)) |value| {
        if (value == .string) return allocator.dupe(u8, value.string);
    }
    return "";
}

fn intValue(object: std.json.ObjectMap, key: []const u8) u64 {
    if (object.get(key)) |value| {
        return switch (value) {
            .integer => |n| @intCast(n),
            else => 0,
        };
    }
    return 0;
}
