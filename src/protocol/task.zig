const std = @import("std");
const builtin = @import("builtin");
const types = @import("types.zig");
const http = @import("http.zig");
const compat = @import("compat");

pub const max_command_output_bytes: usize = 4 * 1024 * 1024;
const safe_command_path = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/opt/rocm/bin";

/// Remote command execution and task result upload helpers.
pub const CommandResult = struct {
    output: []const u8,
    exit_code: i32,

    pub fn deinit(self: CommandResult, allocator: std.mem.Allocator) void {
        allocator.free(self.output);
    }
};

pub fn allocTaskResultJson(allocator: std.mem.Allocator, task_id: []const u8, result: []const u8, exit_code: i32, finished_at: []const u8) ![]const u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    try types.writeTaskResultJson(&out.writer, .{
        .task_id = task_id,
        .result = result,
        .exit_code = exit_code,
        .finished_at = finished_at,
    });
    return out.toOwnedSlice();
}

pub fn runCommand(allocator: std.mem.Allocator, command: []const u8) ![]const u8 {
    const result = try runCommandDetailed(allocator, command);
    return result.output;
}

pub fn runCommandWithRunner(allocator: std.mem.Allocator, command: []const u8, runner: CommandRunner) ![]const u8 {
    const result = try runCommandDetailedWithRunner(allocator, command, runner);
    return result.output;
}

pub fn runCommandDetailed(allocator: std.mem.Allocator, command: []const u8) !CommandResult {
    if (command.len == 0) return .{ .output = try allocator.dupe(u8, "No command provided"), .exit_code = 0 };
    if (builtin.os.tag == .windows) return error.UnsupportedOs;
    return runCommandDetailedPosix(allocator, command) catch |err| switch (err) {
        error.StreamTooLong => return .{
            .output = try std.fmt.allocPrint(allocator, "Command output exceeded {d} bytes", .{max_command_output_bytes}),
            .exit_code = -1,
        },
        else => return err,
    };
}

fn runCommandDetailedPosix(allocator: std.mem.Allocator, command: []const u8) !CommandResult {
    const shell_command_raw = try std.fmt.allocPrint(allocator, "PATH={s}; export PATH; exec 2>&1; {s}", .{ safe_command_path, command });
    defer allocator.free(shell_command_raw);
    const shell_command = try allocator.dupeZ(u8, shell_command_raw);
    defer allocator.free(shell_command);
    const fds = try compat.pipe();
    errdefer {
        compat.closeFd(fds[0]);
        compat.closeFd(fds[1]);
    }
    const pid = try compat.fork();
    if (pid == 0) {
        compat.closeFd(fds[0]);
        compat.dup2(fds[1], 1) catch std.process.exit(127);
        compat.dup2(fds[1], 2) catch std.process.exit(127);
        compat.closeFd(fds[1]);
        const shell: [:0]const u8 = "/bin/sh";
        const arg_c: [:0]const u8 = "-c";
        const env_path: [:0]const u8 = "PATH=" ++ safe_command_path;
        const argv = [_:null]?[*:0]const u8{ shell.ptr, arg_c.ptr, shell_command.ptr };
        const envp = [_:null]?[*:0]const u8{ env_path.ptr };
        compat.execveZ(shell.ptr, &argv, &envp) catch std.process.exit(127);
    }
    compat.closeFd(fds[1]);
    var out = std.Io.Writer.Allocating.init(allocator);
    errdefer out.deinit();
    var total: usize = 0;
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = try std.posix.read(fds[0], &buf);
        if (n == 0) break;
        if (total + n > max_command_output_bytes) return error.StreamTooLong;
        try out.writer.writeAll(buf[0..n]);
        total += n;
    }
    compat.closeFd(fds[0]);
    const waited = try compat.waitPid(pid, 0);
    const raw = try out.toOwnedSlice();
    defer allocator.free(raw);
    return .{
        .output = try normalizeCommandOutput(allocator, raw),
        .exit_code = exitCodeFromStatus(waited.status),
    };
}

pub const CommandRunner = *const fn (std.mem.Allocator, *std.process.Environ.Map, []const u8) anyerror!std.process.RunResult;

fn realCommandRunner(allocator: std.mem.Allocator, env: *std.process.Environ.Map, command: []const u8) !std.process.RunResult {
    const work_allocator = std.heap.smp_allocator;
    const merged_command = try std.fmt.allocPrint(work_allocator, "exec 2>&1; {s}", .{command});
    defer work_allocator.free(merged_command);
    const output = try compat.runOutputIgnoreStderr(work_allocator, &.{ "/bin/sh", "-c", merged_command }, env, max_command_output_bytes);
    defer work_allocator.free(output.stdout);
    return .{
        .stdout = try allocator.dupe(u8, output.stdout),
        .stderr = try allocator.dupe(u8, ""),
        .term = output.term,
    };
}

pub fn runCommandDetailedWithRunner(allocator: std.mem.Allocator, command: []const u8, runner: CommandRunner) !CommandResult {
    if (command.len == 0) return .{ .output = try allocator.dupe(u8, "No command provided"), .exit_code = 0 };
    var env = compat.emptyEnvMap(allocator);
    defer env.deinit();
    try env.put("PATH", safe_command_path);
    const result = runner(allocator, &env, command) catch |err| switch (err) {
        error.StreamTooLong => return .{
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
        runCommandDetailed(allocator, command) catch |err| try commandFailureResult(allocator, err);
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

pub fn commandFailureResult(allocator: std.mem.Allocator, err: anyerror) !CommandResult {
    return .{
        .output = try std.fmt.allocPrint(allocator, "Command failed: {s}", .{@errorName(err)}),
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
        .exited => |code| @intCast(code),
        .signal => |signal| 128 + @as(i32, @intCast(@intFromEnum(signal))),
        else => -1,
    };
}

fn exitCodeFromStatus(status: u32) i32 {
    const signal = status & 0x7f;
    if (signal == 0) return @intCast((status >> 8) & 0xff);
    if (signal != 0x7f) return 128 + @as(i32, @intCast(signal));
    return -1;
}

pub fn utcNow(allocator: std.mem.Allocator) ![]const u8 {
    return utcFromTimestamp(allocator, compat.unixTimestamp());
}

pub fn utcFromTimestamp(allocator: std.mem.Allocator, timestamp: i64) ![]const u8 {
    const date = civilFromTimestamp(timestamp);
    const seconds_of_day = @mod(timestamp, std.time.s_per_day);
    const hour = @divFloor(seconds_of_day, 3600);
    const minute = @divFloor(@mod(seconds_of_day, 3600), 60);
    const second = @mod(seconds_of_day, 60);
    return std.fmt.allocPrint(
        allocator,
        "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z",
        .{
            @as(u32, @intCast(date.year)),
            @as(u8, @intCast(date.month)),
            @as(u8, @intCast(date.day)),
            @as(u8, @intCast(hour)),
            @as(u8, @intCast(minute)),
            @as(u8, @intCast(second)),
        },
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
