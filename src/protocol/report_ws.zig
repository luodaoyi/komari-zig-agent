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
    }));
}

pub fn loop(allocator: std.mem.Allocator, cfg: config.Config) !void {
    var stdout = std.fs.File.stdout().deprecatedWriter();
    const seconds: u64 = if (cfg.interval <= 1) 1 else @intFromFloat(cfg.interval - 1);
    var ws = connectReportWs(allocator, cfg) catch |err| blk: {
        try stdout.print("WebSocket connect failed: {s}; generating reports locally\n", .{@errorName(err)});
        break :blk null;
    };
    if (ws) |conn| startReader(allocator, conn, cfg);
    defer if (ws) |conn| conn.close(allocator);

    while (true) {
        const payload = try runOnce(allocator, cfg);
        defer allocator.free(payload);
        if (ws) |conn| {
            conn.writeText(payload) catch |err| {
                try stdout.print("WebSocket write failed: {s}\n", .{@errorName(err)});
                conn.close(allocator);
                ws = null;
            };
        }
        try stdout.print("Report generated: {d} bytes{s}\n", .{ payload.len, if (ws != null) " sent" else "" });
        std.Thread.sleep(seconds * std.time.ns_per_s);
    }
}

fn connectReportWs(allocator: std.mem.Allocator, cfg: config.Config) !*ws_client.Client {
    const url = try http.reportWsUrl(allocator, cfg.endpoint, cfg.token);
    defer allocator.free(url);
    return ws_client.connect(allocator, url);
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
            const value = ping.measure(allocator, msg.ping_type, msg.ping_target);
            const finished = try task.utcNow(allocator);
            defer allocator.free(finished);
            const payload = try ping.allocPingResultJson(allocator, msg.ping_task_id, msg.ping_type, value, finished);
            defer allocator.free(payload);
            try conn.writeText(payload);
        },
        .exec => {
            try task.uploadExecResult(allocator, cfg, msg.task_id, msg.command);
        },
        .terminal => {
            const thread = try std.Thread.spawn(.{}, terminal.startSession, .{ allocator, cfg, msg.request_id });
            thread.detach();
        },
        .unknown => {},
    }
}
