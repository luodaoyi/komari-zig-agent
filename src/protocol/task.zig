const std = @import("std");
const types = @import("types.zig");
const http = @import("http.zig");

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
    var child = std.process.Child.init(&.{ "sh", "-c", command }, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    const stdout = try child.stdout.?.readToEndAlloc(allocator, 1024 * 1024);
    const stderr = try child.stderr.?.readToEndAlloc(allocator, 1024 * 1024);
    const term = try child.wait();
    defer allocator.free(stdout);
    defer allocator.free(stderr);
    const merged = try std.mem.concat(allocator, u8, &.{ stdout, if (stderr.len > 0) "\n" else "", stderr });
    defer allocator.free(merged);
    return .{
        .output = try normalizeCommandOutput(allocator, merged),
        .exit_code = exitCode(term),
    };
}

pub fn uploadExecResult(allocator: std.mem.Allocator, cfg: anytype, task_id: []const u8, command: []const u8) !void {
    const result = if (cfg.disable_web_ssh)
        CommandResult{ .output = try allocator.dupe(u8, "Remote control is disabled."), .exit_code = -1 }
    else
        try runCommandDetailed(allocator, command);
    defer result.deinit(allocator);

    const finished = try utcNow(allocator);
    defer allocator.free(finished);
    const payload = try allocTaskResultJson(allocator, task_id, result.output, result.exit_code, finished);
    defer allocator.free(payload);
    const url = try http.taskResultUrl(allocator, cfg.endpoint, cfg.token);
    defer allocator.free(url);
    try postJsonWithCurl(allocator, url, payload, cfg);
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
    var child = std.process.Child.init(&.{ "date", "-u", "+%Y-%m-%dT%H:%M:%SZ" }, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    try child.spawn();
    const stdout = try child.stdout.?.readToEndAlloc(allocator, 128);
    defer allocator.free(stdout);
    const term = try child.wait();
    if (term != .Exited or term.Exited != 0) {
        return std.fmt.allocPrint(allocator, "{d}", .{std.time.timestamp()});
    }
    return allocator.dupe(u8, std.mem.trim(u8, stdout, " \t\r\n"));
}

fn postJsonWithCurl(allocator: std.mem.Allocator, url: []const u8, payload: []const u8, cfg: anytype) !void {
    const tmp_name = try std.fmt.allocPrint(allocator, "/tmp/komari-task-{d}.json", .{std.time.nanoTimestamp()});
    defer allocator.free(tmp_name);
    {
        var file = try std.fs.createFileAbsolute(tmp_name, .{ .truncate = true });
        defer file.close();
        try file.writeAll(payload);
    }
    defer std.fs.deleteFileAbsolute(tmp_name) catch {};

    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(allocator);
    try args.appendSlice(allocator, &.{ "curl", "-fsS", "-X", "POST", "-H", "Content-Type: application/json" });
    if (cfg.ignore_unsafe_cert) try args.append(allocator, "-k");
    if (cfg.cf_access_client_id.len != 0 and cfg.cf_access_client_secret.len != 0) {
        try args.appendSlice(allocator, &.{ "-H", try std.fmt.allocPrint(allocator, "CF-Access-Client-Id: {s}", .{cfg.cf_access_client_id}) });
        try args.appendSlice(allocator, &.{ "-H", try std.fmt.allocPrint(allocator, "CF-Access-Client-Secret: {s}", .{cfg.cf_access_client_secret}) });
    }
    try args.appendSlice(allocator, &.{ "--data-binary", try std.fmt.allocPrint(allocator, "@{s}", .{tmp_name}), url });

    var child = std.process.Child.init(args.items, allocator);
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    try child.spawn();
    const term = try child.wait();
    if (term != .Exited or term.Exited != 0) return error.TaskResultUploadFailed;
}
