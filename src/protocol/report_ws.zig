const std = @import("std");
const config = @import("../config.zig");
const debug = @import("debug");
const http = @import("http.zig");
const common = @import("../platform/common.zig");
const provider = @import("../platform/provider.zig");
const report = @import("../report/report.zig");
const ping = @import("ping.zig");
const task = @import("task.zig");
const terminal = @import("../terminal/terminal.zig");
const update = @import("../update.zig");
const v2 = @import("v2.zig");
const v2_state = @import("v2_state.zig");
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

var v2_ack_mutex: compat.Mutex = .{};
var v2_ack_event_ids: std.ArrayList([]const u8) = .empty;
var v2_seen_event_ids: std.ArrayList([]const u8) = .empty;

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

pub fn processV2ResponseBodyForTest(allocator: std.mem.Allocator, cfg: config.Config, body: []const u8) !void {
    return processV2ResponseBody(allocator, cfg, body);
}

pub fn postV2PullOnceForTest(allocator: std.mem.Allocator, cfg: config.Config) !void {
    return postV2PullOnce(allocator, cfg);
}

pub fn postV2ReportPayloadForTest(allocator: std.mem.Allocator, cfg: config.Config, report_json: []const u8) !void {
    const ack_ids = try snapshotV2AckEventIDs(allocator);
    defer allocator.free(ack_ids);
    const request_id = try std.fmt.allocPrint(allocator, "report-{d}", .{compat.nanoTimestamp()});
    defer allocator.free(request_id);
    const request = try v2.allocReportRequest(allocator, request_id, report_json, ack_ids);
    defer allocator.free(request);
    const body = try postV2Request(allocator, cfg, request);
    defer allocator.free(body);
    clearV2AckEventIDs(ack_ids);
    try processV2ResponseBody(allocator, cfg, body);
    v2_state.resetV2ProtocolFailures(2);
}

pub fn snapshotV2AckEventIDsForTest(allocator: std.mem.Allocator) ![]const []const u8 {
    return snapshotV2AckEventIDs(allocator);
}

pub fn resetV2ResponseTrackingForTest() void {
    resetV2ResponseTracking();
}

pub fn initRequestedProtocolVersionForTest(version: i32) void {
    v2_state.initRequestedProtocolVersion(version);
}

pub fn resetConnectionProtocolVersionForTest() void {
    v2_state.resetConnectionProtocolVersion();
}

pub fn uploadProtocolVersionForTest() i32 {
    return v2_state.uploadProtocolVersion();
}

fn applyV1FallbackConnectResult(connect_ok: bool) void {
    if (connect_ok) {
        v2_state.setConnectionProtocolVersion(1);
        v2_state.resetV2ProtocolFailures(1);
    } else {
        v2_state.resetConnectionProtocolVersion();
    }
}

/// Test wrapper around sticky-v1 rules without network I/O.
pub fn applyV1FallbackConnectResultForTest(connect_ok: bool) void {
    applyV1FallbackConnectResult(connect_ok);
}

pub fn prepareReconnectCycleForTest() void {
    v2_state.resetConnectionProtocolVersion();
}

fn writeReportOnce(allocator: std.mem.Allocator, ws: *ws_client.Client, cfg: config.Config) !void {
    const snap = try provider.snapshotWithOptions(snapshotOptions(cfg));
    var owns_gpu_json = true;
    defer if (owns_gpu_json and snap.gpu_json.len != 0) std.heap.page_allocator.free(snap.gpu_json);

    const protocol_version = v2_state.uploadProtocolVersion();
    var buf: [report_stack_buffer_size]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    report.writeReportJson(&writer, snap) catch |err| switch (err) {
        error.WriteFailed => {
            owns_gpu_json = false;
            const payload = try report.allocReportJson(allocator, snap);
            defer allocator.free(payload);
            if (protocol_version >= 2) {
                const rpc = try v2.allocReportNotification(allocator, payload);
                defer allocator.free(rpc);
                try ws.writeText(rpc);
            } else {
                try ws.writeText(payload);
            }
            return;
        },
    };
    if (protocol_version >= 2) {
        const rpc = try v2.allocReportNotification(allocator, writer.buffered());
        defer allocator.free(rpc);
        try ws.writeText(rpc);
    } else {
        try ws.writeText(writer.buffered());
    }
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
        var ws = connectReportWsWithRetries(allocator, cfg, stop_requested) catch |err| blk: {
            if (v2_state.requestedProtocolVersion() >= 2 and v2_state.uploadProtocolVersion() >= 2) {
                const fallback_ws = runPostFallback(allocator, cfg, stop_requested) catch |fallback_err| {
                    if (isStopRequested(stop_requested)) return;
                    try stdout.print("WebSocket POST fallback failed: {s}\n", .{@errorName(fallback_err)});
                    return fallback_err;
                };
                if (fallback_ws == null) {
                    return error.ShutdownRequested;
                }
                break :blk fallback_ws.?;
            }
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
                    v2_state.resetConnectionProtocolVersion();
                    closed = true;
                    break;
                };
                last_heartbeat = now;
            }
            writeReportOnce(allocator, ws, cfg) catch |err| {
                try stdout.print("WebSocket write failed: {s}\n", .{@errorName(err)});
                ws.close(allocator);
                v2_state.resetConnectionProtocolVersion();
                closed = true;
                break;
            };
            if (!update_confirmed) {
                // Pending update state is only confirmed after the replacement
                // binary survives long enough to send a regular report.
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
    const protocol_version = v2_state.uploadProtocolVersion();
    const url = try http.reportWsUrlForProtocol(allocator, cfg.endpoint, cfg.token, protocol_version);
    defer allocator.free(url);
    const ws = ws_client.connect(allocator, url, cfg) catch |err| {
        const attempt = v2_state.noteV2AttemptResult(protocol_version, err);
        if (attempt.fallback) {
            const fallback_url = try http.reportWsUrlForProtocol(allocator, cfg.endpoint, cfg.token, 1);
            defer allocator.free(fallback_url);
            const fallback_ws = ws_client.connect(allocator, fallback_url, cfg) catch |fallback_err| {
                // Failed v1 fallback must not stick; next reconnect cycle prefers requested v2 again.
                applyV1FallbackConnectResult(false);
                return fallback_err;
            };
            applyV1FallbackConnectResult(true);
            return fallback_ws;
        }
        return err;
    };
    v2_state.setConnectionProtocolVersion(protocol_version);
    v2_state.resetV2ProtocolFailures(protocol_version);
    return ws;
}

fn runPostFallback(allocator: std.mem.Allocator, cfg: config.Config, stop_requested: ?*const std.atomic.Value(bool)) !?*ws_client.Client {
    const report_interval_ms = reportIntervalMs(cfg.interval);
    const pull_interval_ms = std.time.ms_per_s;
    const reconnect_interval_ms = @as(u64, @intCast(reconnectSleepSeconds(cfg.reconnect_interval))) * std.time.ms_per_s;
    var last_report_ms = compat.milliTimestamp();
    var last_pull_ms = compat.milliTimestamp() - @as(i64, @intCast(pull_interval_ms));
    var last_reconnect_ms = compat.milliTimestamp() - @as(i64, @intCast(reconnect_interval_ms));

    while (!isStopRequested(stop_requested)) {
        const now_ms = compat.milliTimestamp();
        if (@as(u64, @intCast(@max(now_ms - last_report_ms, 0))) >= report_interval_ms) {
            last_report_ms = now_ms;
            postV2ReportOnce(allocator, cfg) catch |err| {
                if (v2_state.noteV2AttemptResult(2, err).fallback) {
                    v2_state.setConnectionProtocolVersion(1);
                    return err;
                }
            };
        }
        if (@as(u64, @intCast(@max(now_ms - last_pull_ms, 0))) >= pull_interval_ms) {
            last_pull_ms = now_ms;
            postV2PullOnce(allocator, cfg) catch |err| {
                if (v2_state.noteV2AttemptResult(2, err).fallback) {
                    v2_state.setConnectionProtocolVersion(1);
                    return err;
                }
            };
        }
        if (@as(u64, @intCast(@max(now_ms - last_reconnect_ms, 0))) >= reconnect_interval_ms) {
            last_reconnect_ms = now_ms;
            const ws = connectReportWs(allocator, cfg) catch continue;
            return ws;
        }
        compat.sleep(100 * std.time.ns_per_ms);
    }
    return null;
}

fn connectReportWsWithRetries(allocator: std.mem.Allocator, cfg: config.Config, stop_requested: ?*const std.atomic.Value(bool)) !*ws_client.Client {
    // Prefer requested protocol on each reconnect cycle (clears sticky v1 after a dropped session).
    v2_state.resetConnectionProtocolVersion();
    var retry: i32 = 0;
    while (retry <= cfg.max_retries) : (retry += 1) {
        if (isStopRequested(stop_requested)) return error.ShutdownRequested;
        debug.log("report websocket connect attempt {d} to {s}", .{ retry + 1, cfg.endpoint });
        const ws = connectReportWs(allocator, cfg) catch |err| {
            debug.log("report websocket connect attempt {d} failed: {s}", .{ retry + 1, @errorName(err) });
            if (retry >= cfg.max_retries) return err;
            if (sleepOrStop(reconnectSleepSeconds(cfg.reconnect_interval), stop_requested)) return error.ShutdownRequested;
            continue;
        };
        v2_state.resetV2ProtocolFailures(v2_state.uploadProtocolVersion());
        debug.log("report websocket connected on attempt {d}", .{retry + 1});
        return ws;
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
            const args = try PingTaskArgs.init(allocator, conn, cfg, v2_state.uploadProtocolVersion(), msg);
            errdefer args.deinit(allocator);
            const thread = try std.Thread.spawn(.{ .stack_size = thread_stacks.tls_worker_stack_size }, runPingTask, .{ allocator, args });
            thread.detach();
        },
        .exec => {
            const args = try ExecTaskArgs.init(allocator, cfg, msg);
            errdefer args.deinit(allocator);
            const thread = try std.Thread.spawn(.{}, runExecTask, .{ allocator, args });
            thread.detach();
        },
        .terminal => {
            const args = try TerminalTaskArgs.init(allocator, cfg, msg);
            errdefer args.deinit(allocator);
            const thread = try std.Thread.spawn(.{ .stack_size = thread_stacks.terminal_worker_stack_size }, runTerminalTask, .{ allocator, args });
            thread.detach();
        },
        .message, .event => {},
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
    defer args.deinit(allocator);
    terminal.startSession(allocator, args.cfg, args.request_id) catch |err| {
        var stdout_buf: [4096]u8 = undefined;
        var stdout = compat.fileWriter(std.Io.File.stdout(), &stdout_buf);
        defer stdout.flush() catch {};
        stdout.print("Terminal session failed: {s}\n", .{@errorName(err)}) catch {};
    };
}

const PingTaskArgs = struct {
    conn: ?*ws_client.Client,
    cfg: config.Config,
    protocol_version: i32,
    ping_task_id: u64,
    ping_type: []const u8,
    ping_target: []const u8,

    fn init(allocator: std.mem.Allocator, conn: ?*ws_client.Client, cfg: config.Config, protocol_version: i32, msg: ServerMessage) !PingTaskArgs {
        if (conn) |ws| ws.acquire();
        return .{
            .conn = conn,
            .cfg = cfg,
            .protocol_version = protocol_version,
            .ping_task_id = msg.ping_task_id,
            .ping_type = try allocator.dupe(u8, msg.ping_type),
            .ping_target = try allocator.dupe(u8, msg.ping_target),
        };
    }

    fn deinit(self: PingTaskArgs, allocator: std.mem.Allocator) void {
        allocator.free(self.ping_type);
        allocator.free(self.ping_target);
        if (self.conn) |conn| conn.release(allocator);
    }
};

fn runPingTask(allocator: std.mem.Allocator, args: PingTaskArgs) void {
    defer args.deinit(allocator);
    const value = ping.measure(allocator, args.ping_type, args.ping_target, args.cfg.custom_dns);
    const finished = task.utcNow(allocator) catch return;
    defer allocator.free(finished);
    const payload = if (args.protocol_version >= 2)
        v2.allocPingResultNotification(allocator, args.ping_task_id, args.ping_type, value, finished) catch return
    else
        ping.allocPingResultJson(allocator, args.ping_task_id, args.ping_type, value, finished) catch return;
    defer allocator.free(payload);
    if (args.conn) |conn| {
        conn.writeText(payload) catch {};
        return;
    }
    if (args.protocol_version >= 2) {
        postV2Payload(allocator, args.cfg, payload) catch {};
    }
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
    task.uploadExecResult(allocator, args.cfg, v2_state.uploadProtocolVersion(), args.task_id, args.command) catch {};
}

fn postV2ReportOnce(allocator: std.mem.Allocator, cfg: config.Config) !void {
    const snap = try provider.snapshotWithOptions(snapshotOptions(cfg));
    const payload = try report.allocReportJson(allocator, snap);
    defer allocator.free(payload);
    const ack_ids = try snapshotV2AckEventIDs(allocator);
    defer allocator.free(ack_ids);
    const request_id = try std.fmt.allocPrint(allocator, "report-{d}", .{compat.nanoTimestamp()});
    defer allocator.free(request_id);
    const request = try v2.allocReportRequest(allocator, request_id, payload, ack_ids);
    defer allocator.free(request);
    const body = try postV2Request(allocator, cfg, request);
    defer allocator.free(body);
    clearV2AckEventIDs(ack_ids);
    try processV2ResponseBody(allocator, cfg, body);
    v2_state.resetV2ProtocolFailures(2);
}

fn postV2PullOnce(allocator: std.mem.Allocator, cfg: config.Config) !void {
    const ack_ids = try snapshotV2AckEventIDs(allocator);
    defer allocator.free(ack_ids);
    const request_id = try std.fmt.allocPrint(allocator, "pull-{d}", .{compat.nanoTimestamp()});
    defer allocator.free(request_id);
    const request = try v2.allocPullRequest(allocator, request_id, .{
        .capabilities = &.{ "exec", "ping", "message", "event", "terminal" },
        .ack_event_ids = ack_ids,
    });
    defer allocator.free(request);
    const body = try postV2Request(allocator, cfg, request);
    defer allocator.free(body);
    clearV2AckEventIDs(ack_ids);
    try processV2ResponseBody(allocator, cfg, body);
    v2_state.resetV2ProtocolFailures(2);
}

fn postV2Payload(allocator: std.mem.Allocator, cfg: config.Config, payload: []const u8) !void {
    const body = try http.maybeGzip(allocator, payload, !cfg.disable_compression);
    defer allocator.free(body.body);
    var headers = http.Headers{};
    if (body.compressed) headers.content_encoding = "gzip";
    const url = try http.v2RpcUrl(allocator, cfg.endpoint, cfg.token);
    defer allocator.free(url);
    _ = try http.postJsonReadAuthHeaders(allocator, url, body.body, cfg, "", headers);
}

fn postV2Request(allocator: std.mem.Allocator, cfg: config.Config, payload: []const u8) ![]u8 {
    const body = try http.maybeGzip(allocator, payload, !cfg.disable_compression);
    defer allocator.free(body.body);
    var headers = http.Headers{};
    if (body.compressed) headers.content_encoding = "gzip";
    const url = try http.v2RpcUrl(allocator, cfg.endpoint, cfg.token);
    defer allocator.free(url);
    return http.postJsonReadAuthHeaders(allocator, url, body.body, cfg, "", headers);
}

fn processV2ResponseBody(allocator: std.mem.Allocator, cfg: config.Config, body: []const u8) !void {
    if (body.len == 0) return;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidV2Response;
    const object = parsed.value.object;
    const jsonrpc = object.get("jsonrpc") orelse return error.InvalidV2Response;
    if (jsonrpc != .string or !std.mem.eql(u8, jsonrpc.string, v2.Version)) return error.InvalidV2Response;
    if (object.get("error")) |err_value| {
        if (err_value != .object) return error.InvalidV2Response;
        return error.InvalidV2Response;
    }
    if (object.get("result")) |result_value| {
        if (result_value != .object) return error.InvalidV2EventResult;
        const result = result_value.object;
        if (result.get("events")) |events_value| {
            if (events_value != .array) return error.InvalidV2EventResult;
            for (events_value.array.items) |item| {
                if (item != .object) continue;
                const event = item.object;
                const event_id = if (event.get("id")) |id_value| if (id_value == .string) id_value.string else "" else "";
                const method = if (event.get("method")) |method_value| if (method_value == .string) method_value.string else "" else "";
                const params = event.get("params");
                if (processV2Event(allocator, null, cfg, method, params, event_id)) {
                    try addV2AckEventID(allocator, event_id);
                }
            }
        }
    }
    v2_state.resetV2ProtocolFailures(2);
}

fn processV2Event(allocator: std.mem.Allocator, conn: ?*ws_client.Client, cfg: config.Config, method: []const u8, params: ?std.json.Value, event_id: []const u8) bool {
    if (event_id.len != 0 and !markV2EventSeen(event_id)) return true;
    if (method.len == 0) return false;
    if (std.mem.eql(u8, method, v2.MethodAgentExec)) {
        const p = parseV2ExecParams(allocator, params) catch return false;
        const args = ExecTaskArgs{ .cfg = cfg, .task_id = p.task_id, .command = p.command };
        const thread = std.Thread.spawn(.{}, runExecTask, .{ allocator, args }) catch {
            args.deinit(allocator);
            return false;
        };
        thread.detach();
        return true;
    }
    if (std.mem.eql(u8, method, v2.MethodAgentPing)) {
        const p = parseV2PingParams(allocator, params) catch return false;
        if (conn) |ws| ws.acquire();
        const args = PingTaskArgs{
            .conn = conn,
            .cfg = cfg,
            .protocol_version = 2,
            .ping_task_id = p.ping_task_id,
            .ping_type = p.ping_type,
            .ping_target = p.ping_target,
        };
        const thread = std.Thread.spawn(.{ .stack_size = thread_stacks.tls_worker_stack_size }, runPingTask, .{ allocator, args }) catch {
            args.deinit(allocator);
            return false;
        };
        thread.detach();
        return true;
    }
    if (std.mem.eql(u8, method, v2.MethodAgentTerminal)) {
        const request_id = parseV2TerminalRequestId(allocator, params) catch return false;
        const args = TerminalTaskArgs{ .cfg = cfg, .request_id = request_id };
        const thread = std.Thread.spawn(.{ .stack_size = thread_stacks.terminal_worker_stack_size }, runTerminalTask, .{ allocator, args }) catch {
            args.deinit(allocator);
            return false;
        };
        thread.detach();
        return true;
    }
    if (std.mem.eql(u8, method, v2.MethodAgentMessage) or std.mem.eql(u8, method, v2.MethodAgentEvent)) {
        return true;
    }
    return false;
}

fn parseV2ExecParams(allocator: std.mem.Allocator, params: ?std.json.Value) !struct { task_id: []const u8, command: []const u8 } {
    const object = try expectV2Object(params);
    return .{
        .task_id = try dupJsonString(allocator, object, "task_id"),
        .command = try dupJsonString(allocator, object, "command"),
    };
}

fn parseV2PingParams(allocator: std.mem.Allocator, params: ?std.json.Value) !struct { ping_task_id: u64, ping_type: []const u8, ping_target: []const u8 } {
    const object = try expectV2Object(params);
    return .{
        .ping_task_id = jsonInt(object, "ping_task_id"),
        .ping_type = try dupJsonString(allocator, object, "ping_type"),
        .ping_target = try dupJsonString(allocator, object, "ping_target"),
    };
}

fn parseV2TerminalRequestId(allocator: std.mem.Allocator, params: ?std.json.Value) ![]const u8 {
    const object = try expectV2Object(params);
    return dupJsonString(allocator, object, "request_id");
}

fn expectV2Object(params: ?std.json.Value) !std.json.ObjectMap {
    const value = params orelse return error.InvalidV2EventResult;
    if (value != .object) return error.InvalidV2EventResult;
    return value.object;
}

fn dupJsonString(allocator: std.mem.Allocator, object: std.json.ObjectMap, key: []const u8) ![]const u8 {
    if (object.get(key)) |value| {
        if (value == .string) return allocator.dupe(u8, value.string);
    }
    return allocator.dupe(u8, "");
}

fn jsonInt(object: std.json.ObjectMap, key: []const u8) u64 {
    if (object.get(key)) |value| {
        return switch (value) {
            .integer => |n| @intCast(n),
            .string => |text| std.fmt.parseInt(u64, text, 10) catch 0,
            else => 0,
        };
    }
    return 0;
}

fn snapshotV2AckEventIDs(allocator: std.mem.Allocator) ![]const []const u8 {
    v2_ack_mutex.lock();
    defer v2_ack_mutex.unlock();
    var out: std.ArrayList([]const u8) = .empty;
    for (v2_ack_event_ids.items) |item| try out.append(allocator, item);
    return out.toOwnedSlice(allocator);
}

fn clearV2AckEventIDs(sent: []const []const u8) void {
    if (sent.len == 0) return;
    v2_ack_mutex.lock();
    defer v2_ack_mutex.unlock();
    var removed: std.ArrayList([]const u8) = .empty;
    defer {
        for (removed.items) |item| std.heap.page_allocator.free(item);
        removed.deinit(std.heap.page_allocator);
    }
    var i: usize = 0;
    while (i < v2_ack_event_ids.items.len) {
        const current = v2_ack_event_ids.items[i];
        var matched = false;
        for (sent) |value| {
            if (std.mem.eql(u8, current, value)) {
                matched = true;
                break;
            }
        }
        if (matched) {
            removed.append(std.heap.page_allocator, current) catch {};
            _ = v2_ack_event_ids.orderedRemove(i);
            continue;
        }
        i += 1;
    }
}

fn addV2AckEventID(allocator: std.mem.Allocator, id: []const u8) !void {
    _ = allocator;
    if (id.len == 0) return;
    v2_ack_mutex.lock();
    defer v2_ack_mutex.unlock();
    for (v2_ack_event_ids.items) |item| {
        if (std.mem.eql(u8, item, id)) return;
    }
    try v2_ack_event_ids.append(std.heap.page_allocator, try std.heap.page_allocator.dupe(u8, id));
}

fn markV2EventSeen(id: []const u8) bool {
    if (id.len == 0) return true;
    v2_ack_mutex.lock();
    defer v2_ack_mutex.unlock();
    for (v2_seen_event_ids.items) |item| {
        if (std.mem.eql(u8, item, id)) return false;
    }
    const dup = std.heap.page_allocator.dupe(u8, id) catch return true;
    v2_seen_event_ids.append(std.heap.page_allocator, dup) catch {
        std.heap.page_allocator.free(dup);
        return true;
    };
    return true;
}

fn resetV2ResponseTracking() void {
    v2_ack_mutex.lock();
    defer v2_ack_mutex.unlock();
    for (v2_ack_event_ids.items) |item| std.heap.page_allocator.free(item);
    v2_ack_event_ids.clearRetainingCapacity();
    for (v2_seen_event_ids.items) |item| std.heap.page_allocator.free(item);
    v2_seen_event_ids.clearRetainingCapacity();
}
