const std = @import("std");

/// Parsing for websocket messages delivered by the Komari server.
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
    owns_fields: bool = true,

    pub fn deinit(self: ServerMessage, allocator: std.mem.Allocator) void {
        if (!self.owns_fields) return;
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

    classify(&msg);
    return msg;
}

pub fn parseServerMessageLeaky(allocator: std.mem.Allocator, bytes: []const u8) !ServerMessage {
    var scanner = std.json.Scanner.initCompleteInput(allocator, bytes);
    defer scanner.deinit();
    const first = try scanner.next();
    if (first != .object_begin) return .{ .owns_fields = false };

    var msg = ServerMessage{ .owns_fields = false };
    while (true) {
        const key_token = try scanner.nextAlloc(allocator, .alloc_if_needed);
        const key = switch (key_token) {
            .object_end => break,
            .string => |value| value,
            .allocated_string => |value| value,
            else => return error.InvalidJson,
        };
        if (std.mem.eql(u8, key, "message")) {
            msg.message = try readStringValueLeaky(allocator, &scanner);
        } else if (std.mem.eql(u8, key, "request_id")) {
            msg.request_id = try readStringValueLeaky(allocator, &scanner);
        } else if (std.mem.eql(u8, key, "task_id")) {
            msg.task_id = try readStringValueLeaky(allocator, &scanner);
        } else if (std.mem.eql(u8, key, "command")) {
            msg.command = try readStringValueLeaky(allocator, &scanner);
        } else if (std.mem.eql(u8, key, "ping_task_id")) {
            msg.ping_task_id = try readU64Value(allocator, &scanner);
        } else if (std.mem.eql(u8, key, "ping_type")) {
            msg.ping_type = try readStringValueLeaky(allocator, &scanner);
        } else if (std.mem.eql(u8, key, "ping_target")) {
            msg.ping_target = try readStringValueLeaky(allocator, &scanner);
        } else {
            try scanner.skipValue();
        }
    }
    classify(&msg);
    return msg;
}

fn dupeString(allocator: std.mem.Allocator, object: std.json.ObjectMap, key: []const u8) ![]const u8 {
    if (object.get(key)) |value| {
        if (value == .string) return allocator.dupe(u8, value.string);
    }
    return "";
}

fn readStringValueLeaky(allocator: std.mem.Allocator, scanner: *std.json.Scanner) ![]const u8 {
    if (try scanner.peekNextTokenType() != .string) {
        try scanner.skipValue();
        return "";
    }
    const token = try scanner.nextAlloc(allocator, .alloc_if_needed);
    return switch (token) {
        .string => |value| value,
        .allocated_string => |value| value,
        else => "",
    };
}

fn readU64Value(allocator: std.mem.Allocator, scanner: *std.json.Scanner) !u64 {
    if (try scanner.peekNextTokenType() != .number) {
        try scanner.skipValue();
        return 0;
    }
    const token = try scanner.nextAlloc(allocator, .alloc_if_needed);
    const text = switch (token) {
        .number => |value| value,
        .allocated_number => |value| value,
        else => return 0,
    };
    return std.fmt.parseInt(u64, text, 10) catch 0;
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

fn classify(msg: *ServerMessage) void {
    if (std.mem.eql(u8, msg.message, "terminal") or msg.request_id.len != 0) {
        msg.kind = .terminal;
    } else if (std.mem.eql(u8, msg.message, "exec")) {
        msg.kind = .exec;
    } else if (std.mem.eql(u8, msg.message, "ping") or msg.ping_task_id != 0 or msg.ping_type.len != 0 or msg.ping_target.len != 0) {
        msg.kind = .ping;
    }
}
