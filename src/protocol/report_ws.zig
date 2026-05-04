const std = @import("std");
const config = @import("../config.zig");
const http = @import("http.zig");
const common = @import("../platform/common.zig");
const provider = @import("../platform/provider.zig");
const report = @import("../report/report.zig");
const ping = @import("ping.zig");
const task = @import("task.zig");
const task_limiter = @import("task_limiter.zig");
const terminal = @import("../terminal/terminal.zig");
const update = @import("../update.zig");
const ws_client = @import("ws_client.zig");
const compat = @import("compat");
const timing = @import("report_timing.zig");
const thread_stacks = @import("../thread_stacks.zig");
/// Report websocket loop and server task dispatch.
pub const ws_message = @import("ws_message.zig");

pub const ServerMessageKind = ws_message.ServerMessageKind;
pub const ServerMessage = ws_message.ServerMessage;
pub const parseServerMessage = ws_message.parseServerMessage;

const report_stack_buffer_size = 4096;

fn snapshotOptions(cfg: config.Config) common.SnapshotOptions {
    return .{
        .include_nics = cfg.include_nics,
        .exclude_nics = cfg.exclude_nics,
        .include_mountpoints = cfg.include_mountpoints,
        .month_rotate = cfg.month_rotate,
        .enable_gpu = cfg.enable_gpu,
        .host_proc = cfg.host_proc,
        .memory_include_cache = cfg.memory_include_cache,
        .memory_report_raw_used = cfg.memory_report_raw_used,
    };
}

pub fn runOnce(allocator: std.mem.Allocator, cfg: config.Config) ![]const u8 {
    return report.allocReportJson(allocator, try provider.snapshotWithOptions(snapshotOptions(cfg)));
}

fn writeReportOnce(allocator: std.mem.Allocator, ws: *ws_client.Client, cfg: config.Config) !void {
    const snap = try provider.snapshotWithOptions(snapshotOptions(cfg));
    var owns_gpu_json = true;
    defer if (owns_gpu_json and snap.gpu_json.len != 0) std.heap.page_allocator.free(snap.gpu_json);

    var buf: [report_stack_buffer_size]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    report.writeReportJson(&writer, snap) catch |err| switch (err) {
        error.WriteFailed => {
            owns_gpu_json = false;
            const payload = try report.allocReportJson(allocator, snap);
            defer allocator.free(payload);
            try ws.writeText(payload);
            return;
        },
    };
    try ws.writeText(writer.buffered());
}

pub const reportIntervalMs = timing.reportIntervalMs;
pub const remainingSleepMs = timing.remainingSleepMs;

pub fn reconnectSleepSeconds(value: i32) u64 {
    return if (value <= 0) 5 else @intCast(value);
}

pub fn loop(allocator: std.mem.Allocator, cfg: config.Config, stop_requested: ?*const std.atomic.Value(bool)) !void {
    var stdout_buf: [4096]u8 = undefined;
    var stdout = compat.fileWriter(std.Io.File.stdout(), &stdout_buf);
    defer stdout.flush() catch {};
    var update_confirmed = false;
    while (!isStopRequested(stop_requested)) {
        var ws = connectReportWsWithRetries(allocator, cfg, stop_requested) catch |err| {
            if (isStopRequested(stop_requested)) return;
            try stdout.print("WebSocket connect failed: {s}\n", .{@errorName(err)});
            return err;
        };
        startReader(allocator, ws, cfg);
        var last_heartbeat = compat.unixTimestamp();
        var closed = false;

        while (!isStopRequested(stop_requested)) {
            const report_start_ms = compat.milliTimestamp();
            const now = compat.unixTimestamp();
            if (now - last_heartbeat >= 30) {
                ws.writePing() catch |err| {
                    try stdout.print("Failed to send heartbeat: {s}\n", .{@errorName(err)});
                    ws.close(allocator);
                    closed = true;
                    break;
                };
                last_heartbeat = now;
            }
            writeReportOnce(allocator, ws, cfg) catch |err| {
                try stdout.print("WebSocket write failed: {s}\n", .{@errorName(err)});
                ws.close(allocator);
                closed = true;
                break;
            };
            if (!update_confirmed) {
                update_confirmed = update.confirmPendingUpdate(allocator) catch false;
            }
            const sleep_ms = remainingSleepMs(report_start_ms, reportIntervalMs(cfg.interval), compat.milliTimestamp());
            if (sleepOrStopMs(sleep_ms, stop_requested)) return;
        }
        if (!closed and isStopRequested(stop_requested)) return;
    }
}

fn isStopRequested(stop_requested: ?*const std.atomic.Value(bool)) bool {
    const ptr = stop_requested orelse return false;
    return ptr.load(.acquire);
}

fn sleepOrStop(seconds: u64, stop_requested: ?*const std.atomic.Value(bool)) bool {
    var slept: u64 = 0;
    while (slept < seconds) : (slept += 1) {
        if (isStopRequested(stop_requested)) return true;
        compat.sleep(std.time.ns_per_s);
    }
    return isStopRequested(stop_requested);
}

fn sleepOrStopMs(milliseconds: u64, stop_requested: ?*const std.atomic.Value(bool)) bool {
    var remaining = milliseconds;
    while (remaining > 0) {
        if (isStopRequested(stop_requested)) return true;
        const chunk: u64 = @min(remaining, @as(u64, 100));
        compat.sleep(chunk * @as(u64, std.time.ns_per_ms));
        remaining -= chunk;
    }
    return isStopRequested(stop_requested);
}

fn connectReportWs(allocator: std.mem.Allocator, cfg: config.Config) !*ws_client.Client {
    const url = try http.reportWsUrl(allocator, cfg.endpoint, cfg.token);
    defer allocator.free(url);
    return ws_client.connect(allocator, url, cfg);
}

fn connectReportWsWithRetries(allocator: std.mem.Allocator, cfg: config.Config, stop_requested: ?*const std.atomic.Value(bool)) !*ws_client.Client {
    var retry: i32 = 0;
    while (retry <= cfg.max_retries) : (retry += 1) {
        if (isStopRequested(stop_requested)) return error.ShutdownRequested;
        return connectReportWs(allocator, cfg) catch |err| {
            if (retry >= cfg.max_retries) return err;
            if (sleepOrStop(reconnectSleepSeconds(cfg.reconnect_interval), stop_requested)) return error.ShutdownRequested;
            continue;
        };
    }
    return error.WebSocketHandshakeFailed;
}

fn startReader(allocator: std.mem.Allocator, conn: *ws_client.Client, cfg: config.Config) void {
    conn.acquire();
    const thread = std.Thread.spawn(.{ .stack_size = thread_stacks.tls_worker_stack_size }, readerLoop, .{ allocator, conn, cfg }) catch {
        conn.release(allocator);
        return;
    };
    thread.detach();
}

fn readerLoop(allocator: std.mem.Allocator, conn: *ws_client.Client, cfg: config.Config) void {
    defer conn.release(allocator);
    var stdout_buf: [4096]u8 = undefined;
    var stdout = compat.fileWriter(std.Io.File.stdout(), &stdout_buf);
    defer stdout.flush() catch {};
    var msg_arena = std.heap.ArenaAllocator.init(allocator);
    defer msg_arena.deinit();
    while (true) {
        _ = msg_arena.reset(.retain_capacity);
        const frame = conn.readTextFrame(allocator) catch |err| {
            conn.shutdown();
            stdout.print("WebSocket read failed: {s}\n", .{@errorName(err)}) catch {};
            return;
        };
        defer frame.deinit(conn, allocator);
        const msg = ws_message.parseServerMessageLeaky(msg_arena.allocator(), frame.payload) catch |err| {
            stdout.print("Bad ws message: {s}\n", .{@errorName(err)}) catch {};
            continue;
        };
        handleServerMessage(allocator, conn, cfg, msg) catch |err| {
            stdout.print("WS task failed: {s}\n", .{@errorName(err)}) catch {};
        };
    }
}

fn handleServerMessage(allocator: std.mem.Allocator, conn: *ws_client.Client, cfg: config.Config, msg: ServerMessage) !void {
    switch (msg.kind) {
        .ping => {
            if (!task_limiter.tryAcquire()) return error.TooManyConcurrentTasks;
            errdefer task_limiter.release();
            const args = try PingTaskArgs.init(allocator, conn, cfg, msg);
            errdefer args.deinit(allocator);
            const thread = try std.Thread.spawn(.{ .stack_size = thread_stacks.tls_worker_stack_size }, runPingTask, .{ allocator, args });
            thread.detach();
        },
        .exec => {
            if (!task_limiter.tryAcquire()) return error.TooManyConcurrentTasks;
            errdefer task_limiter.release();
            const args = try ExecTaskArgs.init(allocator, cfg, msg);
            errdefer args.deinit(allocator);
            const thread = try std.Thread.spawn(.{}, runExecTask, .{ allocator, args });
            thread.detach();
        },
        .terminal => {
            if (!task_limiter.tryAcquire()) return error.TooManyConcurrentTasks;
            errdefer task_limiter.release();
            const args = try TerminalTaskArgs.init(allocator, cfg, msg);
            errdefer args.deinit(allocator);
            const thread = try std.Thread.spawn(.{ .stack_size = thread_stacks.terminal_worker_stack_size }, runTerminalTask, .{ allocator, args });
            thread.detach();
        },
        .unknown => {},
    }
}

const TerminalTaskArgs = struct {
    cfg: config.Config,
    request_id: []const u8,

    fn init(allocator: std.mem.Allocator, cfg: config.Config, msg: ServerMessage) !TerminalTaskArgs {
        return .{
            .cfg = cfg,
            .request_id = try allocator.dupe(u8, msg.request_id),
        };
    }

    fn deinit(self: TerminalTaskArgs, allocator: std.mem.Allocator) void {
        allocator.free(self.request_id);
    }
};

fn runTerminalTask(allocator: std.mem.Allocator, args: TerminalTaskArgs) void {
    defer task_limiter.release();
    defer args.deinit(allocator);
    terminal.startSession(allocator, args.cfg, args.request_id) catch |err| {
        var stdout_buf: [4096]u8 = undefined;
        var stdout = compat.fileWriter(std.Io.File.stdout(), &stdout_buf);
        defer stdout.flush() catch {};
        stdout.print("Terminal session failed: {s}\n", .{@errorName(err)}) catch {};
    };
}

const PingTaskArgs = struct {
    conn: *ws_client.Client,
    cfg: config.Config,
    ping_task_id: u64,
    ping_type: []const u8,
    ping_target: []const u8,

    fn init(allocator: std.mem.Allocator, conn: *ws_client.Client, cfg: config.Config, msg: ServerMessage) !PingTaskArgs {
        conn.acquire();
        return .{
            .conn = conn,
            .cfg = cfg,
            .ping_task_id = msg.ping_task_id,
            .ping_type = try allocator.dupe(u8, msg.ping_type),
            .ping_target = try allocator.dupe(u8, msg.ping_target),
        };
    }

    fn deinit(self: PingTaskArgs, allocator: std.mem.Allocator) void {
        allocator.free(self.ping_type);
        allocator.free(self.ping_target);
        self.conn.release(allocator);
    }
};

fn runPingTask(allocator: std.mem.Allocator, args: PingTaskArgs) void {
    defer task_limiter.release();
    defer args.deinit(allocator);
    const value = ping.measure(allocator, args.ping_type, args.ping_target, args.cfg.custom_dns);
    const finished = task.utcNow(allocator) catch return;
    defer allocator.free(finished);
    const payload = ping.allocPingResultJson(allocator, args.ping_task_id, args.ping_type, value, finished) catch return;
    defer allocator.free(payload);
    args.conn.writeText(payload) catch {};
}

const ExecTaskArgs = struct {
    cfg: config.Config,
    task_id: []const u8,
    command: []const u8,

    fn init(allocator: std.mem.Allocator, cfg: config.Config, msg: ServerMessage) !ExecTaskArgs {
        return .{
            .cfg = cfg,
            .task_id = try allocator.dupe(u8, msg.task_id),
            .command = try allocator.dupe(u8, msg.command),
        };
    }

    fn deinit(self: ExecTaskArgs, allocator: std.mem.Allocator) void {
        allocator.free(self.task_id);
        allocator.free(self.command);
    }
};

fn runExecTask(allocator: std.mem.Allocator, args: ExecTaskArgs) void {
    defer task_limiter.release();
    defer args.deinit(allocator);
    task.uploadExecResult(allocator, args.cfg, args.task_id, args.command) catch {};
}
