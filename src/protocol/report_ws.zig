const std = @import("std");
const config = @import("../config.zig");
const http = @import("http.zig");
const provider = @import("../platform/provider.zig");
const report = @import("../report/report.zig");
const ping = @import("ping.zig");
const task = @import("task.zig");
const terminal = @import("../terminal/terminal.zig");
const ws_client = @import("ws_client.zig");
pub const ws_message = @import("ws_message.zig");

pub const ServerMessageKind = ws_message.ServerMessageKind;
pub const ServerMessage = ws_message.ServerMessage;
pub const parseServerMessage = ws_message.parseServerMessage;

pub fn runOnce(allocator: std.mem.Allocator, cfg: config.Config) ![]const u8 {
    return report.allocReportJson(allocator, try provider.snapshotWithOptions(.{
        .include_nics = cfg.include_nics,
        .exclude_nics = cfg.exclude_nics,
        .include_mountpoints = cfg.include_mountpoints,
        .month_rotate = cfg.month_rotate,
        .enable_gpu = cfg.enable_gpu,
        .host_proc = cfg.host_proc,
        .memory_include_cache = cfg.memory_include_cache,
        .memory_report_raw_used = cfg.memory_report_raw_used,
    }));
}

pub fn reportSleepSeconds(interval: f64) u64 {
    return if (interval <= 1) 1 else @intFromFloat(interval - 1);
}

pub fn reconnectSleepSeconds(value: i32) u64 {
    return if (value <= 0) 5 else @intCast(value);
}

pub fn loop(allocator: std.mem.Allocator, cfg: config.Config) !void {
    var stdout = std.fs.File.stdout().deprecatedWriter();
    while (true) {
        var ws = connectReportWsWithRetries(allocator, cfg) catch |err| blk: {
            try stdout.print("WebSocket connect failed: {s}; retrying later\n", .{@errorName(err)});
            break :blk null;
        };
        if (ws) |conn| startReader(allocator, conn, cfg);
        var last_heartbeat = std.time.timestamp();

        while (ws != null) {
            const now = std.time.timestamp();
            if (now - last_heartbeat >= 30) {
                ws.?.writePing() catch |err| {
                    try stdout.print("Failed to send heartbeat: {s}\n", .{@errorName(err)});
                    ws.?.close(allocator);
                    ws = null;
                    break;
                };
                last_heartbeat = now;
            }
            const payload = try runOnce(allocator, cfg);
            defer allocator.free(payload);
            ws.?.writeText(payload) catch |err| {
                try stdout.print("WebSocket write failed: {s}\n", .{@errorName(err)});
                ws.?.close(allocator);
                ws = null;
                break;
            };
            try stdout.print("Report generated: {d} bytes sent\n", .{payload.len});
            std.Thread.sleep(reportSleepSeconds(cfg.interval) * std.time.ns_per_s);
        }

        if (ws == null) {
            const payload = try runOnce(allocator, cfg);
            defer allocator.free(payload);
            try stdout.print("Report generated: {d} bytes\n", .{payload.len});
            std.Thread.sleep(reconnectSleepSeconds(cfg.reconnect_interval) * std.time.ns_per_s);
        }
    }
}

fn connectReportWs(allocator: std.mem.Allocator, cfg: config.Config) !*ws_client.Client {
    const url = try http.reportWsUrl(allocator, cfg.endpoint, cfg.token);
    defer allocator.free(url);
    return ws_client.connect(allocator, url, cfg);
}

fn connectReportWsWithRetries(allocator: std.mem.Allocator, cfg: config.Config) !*ws_client.Client {
    var retry: i32 = 0;
    while (retry <= cfg.max_retries) : (retry += 1) {
        return connectReportWs(allocator, cfg) catch |err| {
            if (retry >= cfg.max_retries) return err;
            std.Thread.sleep(reconnectSleepSeconds(cfg.reconnect_interval) * std.time.ns_per_s);
            continue;
        };
    }
    return error.WebSocketHandshakeFailed;
}

fn startReader(allocator: std.mem.Allocator, conn: *ws_client.Client, cfg: config.Config) void {
    const thread = std.Thread.spawn(.{}, readerLoop, .{ allocator, conn, cfg }) catch return;
    thread.detach();
}

fn readerLoop(allocator: std.mem.Allocator, conn: *ws_client.Client, cfg: config.Config) void {
    var stdout = std.fs.File.stdout().deprecatedWriter();
    while (true) {
        const payload = conn.readText(allocator) catch |err| {
            stdout.print("WebSocket read failed: {s}\n", .{@errorName(err)}) catch {};
            return;
        };
        defer allocator.free(payload);
        const msg = parseServerMessage(allocator, payload) catch |err| {
            stdout.print("Bad ws message: {s}\n", .{@errorName(err)}) catch {};
            continue;
        };
        defer msg.deinit(allocator);
        handleServerMessage(allocator, conn, cfg, msg) catch |err| {
            stdout.print("WS task failed: {s}\n", .{@errorName(err)}) catch {};
        };
    }
}

fn handleServerMessage(allocator: std.mem.Allocator, conn: *ws_client.Client, cfg: config.Config, msg: ServerMessage) !void {
    switch (msg.kind) {
        .ping => {
            const args = try PingTaskArgs.init(allocator, conn, cfg, msg);
            const thread = try std.Thread.spawn(.{}, runPingTask, .{ allocator, args });
            thread.detach();
        },
        .exec => {
            const args = try ExecTaskArgs.init(allocator, cfg, msg);
            const thread = try std.Thread.spawn(.{}, runExecTask, .{ allocator, args });
            thread.detach();
        },
        .terminal => {
            const thread = try std.Thread.spawn(.{}, terminal.startSession, .{ allocator, cfg, msg.request_id });
            thread.detach();
        },
        .unknown => {},
    }
}

const PingTaskArgs = struct {
    conn: *ws_client.Client,
    cfg: config.Config,
    ping_task_id: u64,
    ping_type: []const u8,
    ping_target: []const u8,

    fn init(allocator: std.mem.Allocator, conn: *ws_client.Client, cfg: config.Config, msg: ServerMessage) !PingTaskArgs {
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
    }
};

fn runPingTask(allocator: std.mem.Allocator, args: PingTaskArgs) void {
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
    defer args.deinit(allocator);
    task.uploadExecResult(allocator, args.cfg, args.task_id, args.command) catch {};
}
