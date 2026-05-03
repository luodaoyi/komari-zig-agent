const std = @import("std");
const types = @import("types.zig");
const http = @import("http.zig");

pub const max_command_output_bytes: usize = 4 * 1024 * 1024;
const safe_command_path = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/opt/rocm/bin";

pub const CommandResult = struct {
    output: []const u8,
    exit_code: i32,

    pub fn deinit(self: CommandResult, allocator: std.mem.Allocator) void {
        allocator.free(self.output);
    }
};

pub fn allocTaskResultJson(allocator: std.mem.Allocator, task_id: []const u8, result: []const u8, exit_code: i32, finished_at: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try types.writeTaskResultJson(out.writer(allocator), .{
        .task_id = task_id,
        .result = result,
        .exit_code = exit_code,
        .finished_at = finished_at,
    });
    return out.toOwnedSlice(allocator);
}

pub fn runCommand(allocator: std.mem.Allocator, command: []const u8) ![]const u8 {
    const result = try runCommandDetailed(allocator, command);
    return result.output;
}

pub fn runCommandDetailed(allocator: std.mem.Allocator, command: []const u8) !CommandResult {
    if (command.len == 0) return .{ .output = try allocator.dupe(u8, "No command provided"), .exit_code = 0 };
    var env = try std.process.getEnvMap(allocator);
    defer env.deinit();
    try env.put("PATH", safe_command_path);
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "/bin/sh", "-c", command },
        .env_map = &env,
        .max_output_bytes = max_command_output_bytes,
    }) catch |err| switch (err) {
        error.StdoutStreamTooLong, error.StderrStreamTooLong => return .{
            .output = try std.fmt.allocPrint(allocator, "Command output exceeded {d} bytes", .{max_command_output_bytes}),
            .exit_code = -1,
        },
        else => return err,
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    const merged = try std.mem.concat(allocator, u8, &.{ result.stdout, if (result.stderr.len > 0) "\n" else "", result.stderr });
    defer allocator.free(merged);
    return .{
        .output = try normalizeCommandOutput(allocator, merged),
        .exit_code = exitCode(result.term),
    };
}

pub fn uploadExecResult(allocator: std.mem.Allocator, cfg: anytype, task_id: []const u8, command: []const u8) !void {
    if (task_id.len == 0) return;
    const result = if (cfg.disable_web_ssh)
        try disabledRemoteControlResult(allocator)
    else
        try runCommandDetailed(allocator, command);
    defer result.deinit(allocator);

    const finished = try utcNow(allocator);
    defer allocator.free(finished);
    const payload = try allocTaskResultJson(allocator, task_id, result.output, result.exit_code, finished);
    defer allocator.free(payload);
    const url = try http.taskResultUrl(allocator, cfg.endpoint, cfg.token);
    defer allocator.free(url);
    try http.postJson(allocator, url, payload, cfg);
}

pub fn disabledRemoteControlResult(allocator: std.mem.Allocator) !CommandResult {
    return .{
        .output = try allocator.dupe(u8, "Remote control is disabled."),
        .exit_code = -1,
    };
}

pub fn normalizeCommandOutput(allocator: std.mem.Allocator, output: []const u8) ![]const u8 {
    var normalized: std.ArrayList(u8) = .empty;
    defer normalized.deinit(allocator);
    var i: usize = 0;
    while (i < output.len) : (i += 1) {
        if (output[i] == '\r' and i + 1 < output.len and output[i + 1] == '\n') {
            try normalized.append(allocator, '\n');
            i += 1;
        } else {
            try normalized.append(allocator, output[i]);
        }
    }
    return normalized.toOwnedSlice(allocator);
}

fn exitCode(term: std.process.Child.Term) i32 {
    return switch (term) {
        .Exited => |code| @intCast(code),
        .Signal => |signal| 128 + @as(i32, @intCast(signal)),
        else => -1,
    };
}

pub fn utcNow(allocator: std.mem.Allocator) ![]const u8 {
    const timestamp = std.time.timestamp();
    const date = civilFromTimestamp(timestamp);
    const seconds_of_day = @mod(timestamp, std.time.s_per_day);
    const hour = @divFloor(seconds_of_day, 3600);
    const minute = @divFloor(@mod(seconds_of_day, 3600), 60);
    const second = @mod(seconds_of_day, 60);
    return std.fmt.allocPrint(
        allocator,
        "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z",
        .{ date.year, date.month, date.day, hour, minute, second },
    );
}

const CivilDate = struct { year: i32, month: i32, day: i32 };

fn civilFromTimestamp(timestamp: i64) CivilDate {
    const days = @divFloor(timestamp, std.time.s_per_day);
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe: i32 = @intCast(z - era * 146097);
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    var year: i32 = @intCast(yoe + era * 400);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const day = doy - @divFloor(153 * mp + 2, 5) + 1;
    const month = mp + @as(i32, if (mp < 10) 3 else -9);
    year += if (month <= 2) 1 else 0;
    return .{ .year = year, .month = month, .day = day };
}
