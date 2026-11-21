const std = @import("std");
const http = @import("../protocol/http.zig");
const ws_client = @import("../protocol/ws_client.zig");
const builtin = @import("builtin");
const compat = @import("compat");
const thread_stacks = @import("../thread_stacks.zig");
const zigpty = if (builtin.os.tag == .linux or builtin.os.tag == .macos) @import("zigpty") else struct {};

pub const posix_motd_shell = "/bin/sh";
pub const posix_motd_command =
    "for f in /etc/update-motd.d/*; do " ++
    "[ -e \"$f\" ] && [ -x \"$f\" ] && \"$f\"; done; " ++
    "[ -r /etc/motd ] && cat /etc/motd; exec \"$1\"";

extern "c" fn openpty(amaster: *c_int, aslave: *c_int, name: ?[*]u8, termp: ?*const anyopaque, winp: ?*const std.posix.winsize) c_int;
extern "c" fn ioctl(fd: std.posix.fd_t, request: c_ulong, ...) c_int;

/// Web terminal session bridge between PTY/process IO and websocket frames.
pub const Input = union(enum) {
    input: []const u8,
    resize: struct { cols: u16, rows: u16 },
    raw: []const u8,
    heartbeat: []const u8,
    ready: void,
    abort: void,
    terminate: void,
    ignored: void,

    pub fn deinit(self: Input, allocator: std.mem.Allocator) void {
        switch (self) {
            .input, .heartbeat => |bytes| allocator.free(bytes),
            .resize, .raw, .ready, .abort, .terminate, .ignored => {},
        }
    }
};

pub fn parseInput(allocator: std.mem.Allocator, bytes: []const u8) Input {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch return .{ .raw = bytes };
    defer parsed.deinit();
    if (parsed.value != .object) return .{ .raw = bytes };
    const obj = parsed.value.object;
    const typ = obj.get("type") orelse return .{ .ignored = {} };
    if (typ != .string) return .{ .ignored = {} };
    if (std.mem.eql(u8, typ.string, "ready")) return .{ .ready = {} };
    if (std.mem.eql(u8, typ.string, "abort")) return .{ .abort = {} };
    if (std.mem.eql(u8, typ.string, "terminate") or std.mem.eql(u8, typ.string, "close")) return .{ .terminate = {} };
    if (std.mem.eql(u8, typ.string, "heartbeat")) {
        if (obj.get("id")) |id| if (id == .string and id.string.len != 0)
            return .{ .heartbeat = allocator.dupe(u8, id.string) catch return .{ .ignored = {} } };
        return .{ .ready = {} };
    }
    if (std.mem.eql(u8, typ.string, "input")) {
        if (obj.get("input")) |v| if (v == .string) return .{ .input = allocator.dupe(u8, v.string) catch return .{ .raw = bytes } };
    }
    if (std.mem.eql(u8, typ.string, "resize")) {
        const cols = dimension(obj.get("cols"));
        const rows = dimension(obj.get("rows"));
        return .{ .resize = .{ .cols = cols, .rows = rows } };
    }
    return .{ .ignored = {} };
}

fn dimension(value: ?std.json.Value) u16 {
    const v = value orelse return 0;
    return if (v == .integer) std.math.cast(u16, v.integer) orelse 0 else 0;
}

pub fn isCloseInput(input: Input) bool {
    return switch (input) {
        .input => |bytes| isCloseBytes(bytes),
        .raw => |bytes| isCloseBytes(bytes),
        .terminate => true,
        .resize, .heartbeat, .ready, .abort, .ignored => false,
    };
}

fn isCloseBytes(bytes: []const u8) bool {
    const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
    return std.mem.eql(u8, trimmed, "exit") or
        std.mem.eql(u8, trimmed, "logout") or
        std.mem.eql(u8, bytes, "\x04");
}

pub fn startDisabledMessage() []const u8 {
    return "\n\nWeb SSH is disabled. Enable it by running without the --disable-web-ssh flag.";
}

const retention_ms: i64 = 5 * 60 * 1000;
const ping_ms: i64 = 30_000;
const read_wait_ms: i64 = 75_000;
const retry_ms: i64 = 2_000;
const failed_dial_retry_ms: i64 = 15_000;
const poll_ms: u64 = 100;
const connect_ms: i64 = 10_000;
const write_wait_ms: i64 = 10_000;
const input_wait_ms: i64 = 5_000;
const terminate_message = "{\"type\":\"terminate\"}";

var requests_mutex: compat.Mutex = .{};
var requests: std.StringHashMapUnmanaged(void) = .empty;

fn clockTick(now: i64) u32 {
    // Sessions use differences of seconds/minutes, not the absolute uptime.
    return @truncate(@as(u64, @bitCast(now)));
}

fn nowMs() i64 {
    return std.Io.Timestamp.now(std.Options.debug_io, .awake).toMilliseconds();
}

/// A duplicate dispatch must not start another shell or displace the owning socket.
fn claimRequest(id: []const u8) !bool {
    requests_mutex.lock();
    defer requests_mutex.unlock();
    const entry = try requests.getOrPut(std.heap.page_allocator, id);
    return !entry.found_existing;
}

fn releaseRequest(id: []const u8) void {
    requests_mutex.lock();
    defer requests_mutex.unlock();
    _ = requests.remove(id);
    if (requests.count() == 0) requests.clearAndFree(std.heap.page_allocator);
}

pub fn startSession(allocator: std.mem.Allocator, cfg: anytype, request_id: []const u8) !void {
    // Zig 0.16 only gives us a proven cancellable resolver on Linux. Other
    // platforms keep their existing one-socket terminal, with no retained PTY.
    if (builtin.os.tag != .linux) return startLegacySession(allocator, cfg, request_id);
    if (!try claimRequest(request_id)) return;
    defer releaseRequest(request_id);
    const url = try http.terminalWsUrl(allocator, cfg.endpoint, cfg.token, request_id);
    defer allocator.free(url);

    if (cfg.disable_web_ssh) {
        const ws = try ws_client.connectTerminal(allocator, url, cfg, nowMs() + connect_ms);
        defer ws.close(allocator);
        try ws.writeText(startDisabledMessage());
        return;
    }

    const initial_deadline = nowMs() + retention_ms;
    var state: SessionState = .{};
    var shell: ?ShellSession = null;
    var output_worker: ?std.Thread = null;
    defer {
        state.finished.store(true, .release);
        if (output_worker) |worker| worker.join();
        if (shell) |*session| session.closeForced();
    }

    while (!state.finished.load(.acquire)) {
        const deadline = if (shell == null) initial_deadline else state.deadline();
        if (deadline != 0 and nowMs() >= deadline) return;
        const attempt_deadline = @min(deadline, nowMs() + connect_ms);
        const ws = ws_client.connectTerminal(allocator, url, cfg, attempt_deadline) catch |err| {
            if (err == error.TerminalUpgradeRejected) return;
            sleepUntilRetry(&state, failed_dial_retry_ms, deadline);
            continue;
        };
        defer ws.close(allocator);
        if (state.finished.load(.acquire) or (deadline != 0 and nowMs() >= deadline)) {
            return;
        }
        if (shell == null) {
            shell = ShellSession.start(allocator) catch |err| {
                const message = try std.fmt.allocPrint(allocator, "Error: {s}\r\n", .{@errorName(err)});
                defer allocator.free(message);
                ws.writeText(message) catch {};
                ws.writeText(terminate_message) catch {};
                return err;
            };
            try setInputNonblocking(shell.?.input.handle);
        }
        state.attach(ws);
        defer state.detach();
        if (output_worker == null) {
            output_worker = try std.Thread.spawn(.{ .stack_size = thread_stacks.terminal_worker_stack_size }, pumpOutput, .{ allocator, shell.?.output, &state });
        }
        if (!try serveConnection(allocator, ws, &state, &shell.?)) return;
        // Loss of transport must not extend a browser-detach lease already in force.
        state.beginRetention();
        state.detach();
        ws.shutdown();
        sleepUntilRetry(&state, retry_ms, state.deadline());
    }
}

fn sleepUntilRetry(state: *const SessionState, delay: i64, deadline: i64) void {
    const until = @min(nowMs() + delay, deadline);
    while (!state.finished.load(.acquire) and nowMs() < until) {
        compat.sleep(poll_ms * std.time.ns_per_ms);
    }
}

const SessionState = struct {
    mutex: compat.Mutex = .{},
    ws: ?*ws_client.Client = null,
    finished: std.atomic.Value(bool) = .init(false),
    retention_deadline: i64 = 0,

    fn deadline(self: *SessionState) i64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.retention_deadline;
    }

    fn attach(self: *SessionState, ws: *ws_client.Client) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.ws = ws;
    }

    fn detach(self: *SessionState) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.ws = null;
    }

    fn socket(self: *SessionState) ?*ws_client.Client {
        self.mutex.lock();
        defer self.mutex.unlock();
        const ws = self.ws orelse return null;
        ws.acquire();
        return ws;
    }

    fn beginRetention(self: *SessionState) void {
        self.beginRetentionAt(nowMs());
    }

    fn beginRetentionAt(self: *SessionState, now: i64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.retention_deadline == 0) self.retention_deadline = now + retention_ms;
    }

    fn markActive(self: *SessionState) bool {
        return self.markActiveAt(nowMs());
    }

    fn markActiveAt(self: *SessionState, now: i64) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.retention_deadline != 0 and now >= self.retention_deadline) return false;
        self.retention_deadline = 0;
        return true;
    }

    fn expire(self: *SessionState, now: i64) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.retention_deadline <= 0 or now < self.retention_deadline) return false;
        self.retention_deadline = -1;
        return true;
    }
};

const Keepalive = struct {
    state: *SessionState,
    ws: *ws_client.Client,
    last_read: std.atomic.Value(u32),
    stopped: std.atomic.Value(bool) = .init(false),

    fn run(self: *Keepalive) void {
        while (!self.stopped.load(.acquire)) {
            const now = nowMs();
            if (self.state.expire(now)) {
                self.state.finished.store(true, .release);
                self.ws.shutdown();
                return;
            }
            // The watchdog must never wait for the writer lock or perform I/O.
            if (@as(i32, @bitCast(clockTick(now) -% self.last_read.load(.acquire))) >= read_wait_ms or self.ws.writeStalled(now, write_wait_ms)) {
                self.ws.shutdown();
                return;
            }
            compat.sleep(poll_ms * std.time.ns_per_ms);
        }
    }
};

// Only the owner reads from a socket. A writer failing on the old, ref-counted
// socket can wake that reader but cannot close or replace the new socket.
fn serveConnection(allocator: std.mem.Allocator, ws: *ws_client.Client, state: *SessionState, shell: *ShellSession) !bool {
    var keepalive: Keepalive = .{ .state = state, .ws = ws, .last_read = .init(clockTick(nowMs())) };
    const worker = try std.Thread.spawn(.{ .stack_size = thread_stacks.terminal_worker_stack_size }, Keepalive.run, .{&keepalive});
    defer {
        keepalive.stopped.store(true, .release);
        ws.shutdown();
        worker.join();
    }

    while (!state.finished.load(.acquire)) {
        const frame = ws.readFrame(allocator) catch return !state.finished.load(.acquire);
        defer frame.deinit(ws, allocator);
        keepalive.last_read.store(clockTick(nowMs()), .release);
        switch (frame.opcode) {
            // Old dashboards end a session with a normal WebSocket close.
            // New dashboards send JSON terminate; abnormal transport loss can recover.
            0x8 => return !isNormalWsClose(frame.payload),
            0x9 => ws.writeFrame(0xA, frame.payload) catch return true,
            0xA => {},
            0x2 => {
                if (!state.markActive()) break;
                writeInputBounded(shell.input.handle, frame.payload, ws) catch |err| {
                    if (err == error.TerminalTransportClosed) return true;
                    break;
                };
            },
            0x1 => {
                const input = parseInput(allocator, frame.payload);
                defer input.deinit(allocator);
                switch (input) {
                    .terminate => return false,
                    .abort => state.beginRetention(),
                    .ready => if (!state.markActive()) break,
                    .heartbeat => |id| {
                        if (!state.markActive()) break;
                        const payload = try std.json.Stringify.valueAlloc(allocator, .{ .type = "heartbeat", .id = id }, .{});
                        defer allocator.free(payload);
                        ws.writeText(payload) catch return true;
                    },
                    .input, .raw => |bytes| {
                        if (!state.markActive()) break;
                        if (isCloseInput(input)) {
                            ws.writeText(terminate_message) catch {};
                            return false;
                        }
                        writeInputBounded(shell.input.handle, bytes, ws) catch |err| {
                            if (err == error.TerminalTransportClosed) return true;
                            break;
                        };
                    },
                    .resize => |size| {
                        if (!state.markActive()) break;
                        shell.resize(size.cols, size.rows) catch {};
                    },
                    .ignored => {},
                }
            },
            else => {},
        }
    }
    if (!state.finished.load(.acquire)) ws.writeText(terminate_message) catch {};
    return false;
}

fn isNormalWsClose(payload: []const u8) bool {
    return payload.len == 0 or (payload.len >= 2 and std.mem.readInt(u16, payload[0..2], .big) == 1000);
}

fn startLegacySession(allocator: std.mem.Allocator, cfg: anytype, request_id: []const u8) !void {
    const url = try http.terminalWsUrl(allocator, cfg.endpoint, cfg.token, request_id);
    defer allocator.free(url);
    const ws = try ws_client.connect(allocator, url, cfg);
    defer ws.close(allocator);

    if (cfg.disable_web_ssh) {
        try ws.writeText(startDisabledMessage());
        return;
    }

    var session = ShellSession.start(allocator) catch |err| {
        const message = try std.fmt.allocPrint(allocator, "Error: {s}\r\n", .{@errorName(err)});
        defer allocator.free(message);
        try ws.writeText(message);
        return;
    };
    defer session.close();

    ws.acquire();
    const out_thread = std.Thread.spawn(.{ .stack_size = thread_stacks.terminal_worker_stack_size }, legacyPipeShellOutput, .{ allocator, session.output, ws }) catch |err| {
        ws.release(allocator);
        return err;
    };
    out_thread.detach();

    while (true) {
        const frame = try ws.readFrame(allocator);
        defer frame.deinit(ws, allocator);
        if (frame.opcode == 0x8) return;
        if (frame.opcode != 0x1 and frame.opcode != 0x2) continue;
        const input = parseInput(allocator, frame.payload);
        defer input.deinit(allocator);
        switch (input) {
            .input, .raw => |bytes| if (isCloseBytes(bytes)) return,
            else => {},
        }
        switch (input) {
            .input => |bytes| try session.writeInput(bytes),
            .raw => |bytes| try session.writeInput(bytes),
            else => {},
            .resize => |size| session.resize(size.cols, size.rows) catch {},
        }
    }
}

const ShellSession = struct {
    input: std.Io.File,
    output: std.Io.File,
    pid: if (builtin.os.tag == .windows) compat.WindowsProcessHandles else std.posix.pid_t,

    fn start(allocator: std.mem.Allocator) !ShellSession {
        if (builtin.os.tag == .linux or builtin.os.tag == .macos) return startZigPty(allocator);
        if (builtin.os.tag == .freebsd) return startBsdPty(allocator);
        return startPipeFallback(allocator);
    }

    fn close(self: *ShellSession) void {
        self.gracefulShutdown();
        self.closeForced();
    }

    /// Do not enqueue an exit command into a backpressured terminal before
    /// signalling the process; that can prevent cleanup from ever starting.
    fn closeForced(self: *ShellSession) void {
        if (builtin.os.tag == .windows) {
            if (!compat.waitWindowsProcess(self.pid.process, 2000)) {
                compat.terminateWindowsProcess(self.pid.process, 1);
                _ = compat.waitWindowsProcess(self.pid.process, 3000);
            }
            compat.closeWindowsProcessHandles(&self.pid);
        } else {
            _ = std.posix.kill(-self.pid, std.posix.SIG.TERM) catch {
                _ = std.posix.kill(self.pid, std.posix.SIG.TERM) catch {};
            };
            const deadline = compat.milliTimestamp() + 5000;
            while (compat.milliTimestamp() < deadline) {
                const result = compat.waitPid(self.pid, childNoHangFlag()) catch break;
                if (result.pid != 0) break;
                compat.sleep(50 * std.time.ns_per_ms);
            } else {
                _ = std.posix.kill(-self.pid, std.posix.SIG.KILL) catch {
                    _ = std.posix.kill(self.pid, std.posix.SIG.KILL) catch {};
                };
                _ = compat.waitPid(self.pid, 0) catch {};
            }
        }
        if (self.input.handle != self.output.handle) self.input.close(std.Options.debug_io);
        self.output.close(std.Options.debug_io);
    }

    fn gracefulShutdown(self: *ShellSession) void {
        var buf: [256]u8 = undefined;
        var writer = compat.fileWriter(self.input, &buf);
        defer writer.flush() catch {};
        var i: u8 = 0;
        while (i < 3) : (i += 1) {
            writer.writeAll(&.{3}) catch return;
            compat.sleep(50 * std.time.ns_per_ms);
        }
        compat.sleep(200 * std.time.ns_per_ms);
        writer.writeAll(&.{4}) catch {};
        compat.sleep(100 * std.time.ns_per_ms);
        writer.writeAll("exit\n") catch {};
        compat.sleep(100 * std.time.ns_per_ms);
    }

    fn writeInput(self: *ShellSession, bytes: []const u8) !void {
        if (builtin.os.tag != .windows and self.input.handle == self.output.handle) {
            try writeUnixFdAll(self.input.handle, bytes);
            return;
        }
        try self.input.writeStreamingAll(std.Options.debug_io, bytes);
    }

    fn resize(self: *ShellSession, cols: u16, rows: u16) !void {
        if (cols == 0 or rows == 0) return;
        if (builtin.os.tag == .linux or builtin.os.tag == .macos) {
            try zigpty.resize(self.output.handle, cols, rows, 0, 0);
            return;
        }
        if (builtin.os.tag == .freebsd) {
            var wsz = std.posix.winsize{ .row = rows, .col = cols, .xpixel = 0, .ypixel = 0 };
            const rc = ioctl(self.output.handle, tiocswinszRequest(), @intFromPtr(&wsz));
            if (std.posix.errno(rc) != .SUCCESS) return error.ResizeFailed;
            return;
        }
        if (builtin.os.tag == .windows) return;
        var buf: [64]u8 = undefined;
        const cmd = try std.fmt.bufPrint(&buf, "stty cols {d} rows {d}\n", .{ cols, rows });
        try self.writeInput(cmd);
    }
};

fn startZigPty(allocator: std.mem.Allocator) !ShellSession {
    const shell_path = try shellPathAlloc(allocator);
    defer allocator.free(shell_path);
    const shell = try allocator.dupeZ(u8, shell_path);
    defer allocator.free(shell);
    const prelude = try allocator.dupeZ(u8, posix_motd_command);
    defer allocator.free(prelude);
    const cwd = try terminalCwdAlloc(allocator);
    defer allocator.free(cwd);
    const cwd_z = try allocator.dupeZ(u8, cwd);
    defer allocator.free(cwd_z);
    var env_arena = std.heap.ArenaAllocator.init(allocator);
    defer env_arena.deinit();
    var env_map = try compat.currentEnvMap(env_arena.allocator());
    try env_map.put("TERM", "xterm-256color");
    try env_map.put("LANG", "C.UTF-8");
    try env_map.put("LC_ALL", "C.UTF-8");
    const envp = try env_map.createPosixBlock(env_arena.allocator(), .{});
    var argv = [_:null]?[*:0]const u8{
        "sh",
        "-c",
        prelude.ptr,
        "komari-motd",
        shell.ptr,
    };
    const result = try zigpty.forkPty(.{
        .file = posix_motd_shell,
        .argv = &argv,
        .envp = envp.slice.ptr,
        .cwd = cwd_z.ptr,
        .cols = 80,
        .rows = 24,
        .use_utf8 = true,
    });
    const pty_file = std.Io.File{ .handle = result.fd, .flags = .{ .nonblocking = false } };
    compat.sleep(50 * std.time.ns_per_ms);
    const wait_result = compat.waitPid(result.pid, childNoHangFlag()) catch return error.ShellExitedEarly;
    if (wait_result.pid != 0) {
        pty_file.close(std.Options.debug_io);
        return error.ShellExitedEarly;
    }
    return .{ .input = pty_file, .output = pty_file, .pid = result.pid };
}

fn startBsdPty(allocator: std.mem.Allocator) !ShellSession {
    const shell_path = try shellPathAlloc(allocator);
    defer allocator.free(shell_path);
    const shell = try allocator.dupeZ(u8, shell_path);
    defer allocator.free(shell);
    const prelude = try allocator.dupeZ(u8, posix_motd_command);
    defer allocator.free(prelude);
    var env_arena = std.heap.ArenaAllocator.init(allocator);
    defer env_arena.deinit();
    var env_map = try compat.currentEnvMap(env_arena.allocator());
    try env_map.put("TERM", "xterm-256color");
    try env_map.put("LANG", "C.UTF-8");
    try env_map.put("LC_ALL", "C.UTF-8");
    const env = try env_map.createPosixBlock(env_arena.allocator(), .{});

    var master_fd: c_int = -1;
    var slave_fd: c_int = -1;
    var initial_size = std.posix.winsize{ .row = 24, .col = 80, .xpixel = 0, .ypixel = 0 };
    if (openpty(&master_fd, &slave_fd, null, null, &initial_size) != 0) return error.PtyOpenFailed;
    const master: std.posix.fd_t = @intCast(master_fd);
    const slave: std.posix.fd_t = @intCast(slave_fd);
    errdefer compat.closeFd(master);
    errdefer compat.closeFd(slave);

    const pid = try compat.fork();
    if (pid == 0) {
        _ = compat.setsid() catch {};
        _ = ioctl(slave, tiocscttyRequest(), @as(c_int, 0));
        compat.dup2(slave, std.posix.STDIN_FILENO) catch std.process.exit(127);
        compat.dup2(slave, std.posix.STDOUT_FILENO) catch std.process.exit(127);
        compat.dup2(slave, std.posix.STDERR_FILENO) catch std.process.exit(127);
        if (slave > 2) compat.closeFd(slave);
        compat.closeFd(master);
        var argv = [_:null]?[*:0]const u8{
            "sh",
            "-c",
            prelude.ptr,
            "komari-motd",
            shell.ptr,
        };
        compat.execveZ(posix_motd_shell, &argv, env.slice.ptr) catch std.process.exit(127);
    }

    compat.closeFd(slave);
    const pty_file = std.Io.File{ .handle = master, .flags = .{ .nonblocking = false } };
    compat.sleep(50 * std.time.ns_per_ms);
    const result = compat.waitPid(pid, childNoHangFlag()) catch return error.ShellExitedEarly;
    if (result.pid != 0) {
        pty_file.close(std.Options.debug_io);
        return error.ShellExitedEarly;
    }
    return .{ .input = pty_file, .output = pty_file, .pid = pid };
}

fn childNoHangFlag() u32 {
    return if (builtin.os.tag == .linux) std.os.linux.W.NOHANG else std.c.W.NOHANG;
}

fn startPipeFallback(allocator: std.mem.Allocator) !ShellSession {
    if (builtin.os.tag == .windows) return startWindowsPipeFallback(allocator);

    const shell = shellPath();
    const env = try terminalEnv(allocator);
    defer {
        env.deinit();
        allocator.destroy(env);
    }
    const cwd = try terminalCwdAlloc(allocator);
    defer allocator.free(cwd);
    const argv = &.{ "script", "-q", "-c", shell, "/dev/null" };
    const io = compat.io();
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = .{ .path = cwd },
        .environ_map = env,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .ignore,
    });
    if (child.stdin == null or child.stdout == null) {
        child.kill(io);
        return error.ShellPipeFailed;
    }
    return .{
        .input = child.stdin.?,
        .output = child.stdout.?,
        .pid = child.id orelse return error.ShellPipeFailed,
    };
}

fn startWindowsPipeFallback(allocator: std.mem.Allocator) !ShellSession {
    const cwd = try terminalCwdAlloc(allocator);
    defer allocator.free(cwd);
    const child = try compat.spawnWindowsPiped(allocator, &.{ shellPath(), "-NoLogo" }, cwd);
    return .{
        .input = child.stdin,
        .output = child.stdout,
        .pid = child.process,
    };
}

fn tiocswinszRequest() c_ulong {
    return switch (builtin.os.tag) {
        .freebsd, .macos => 0x80087467,
        else => @intCast(std.posix.T.IOCSWINSZ),
    };
}

fn tiocscttyRequest() c_ulong {
    return switch (builtin.os.tag) {
        .freebsd, .macos => 0x20007461,
        else => @intCast(std.posix.T.IOCSCTTY),
    };
}

fn shellPath() []const u8 {
    if (builtin.os.tag == .windows) return "powershell.exe";
    if (compat.getEnvVarOwned(std.heap.page_allocator, "SHELL")) |value| {
        if (value.len != 0) return value;
    } else |_| {}
    return "/bin/sh";
}

fn shellPathAlloc(allocator: std.mem.Allocator) ![]const u8 {
    if (compat.getEnvVarOwned(allocator, "HOME")) |home| {
        defer allocator.free(home);
        if (passwdShellForHome(allocator, home)) |shell| {
            if (isExecutable(shell)) return shell;
            allocator.free(shell);
        } else |_| {}
    } else |_| {}

    const candidates = [_][]const u8{ "/bin/zsh", "/usr/bin/zsh", "/bin/bash", "/usr/bin/bash", "/bin/sh", "/usr/bin/sh" };
    for (&candidates) |candidate| {
        if (isExecutable(candidate)) return allocator.dupe(u8, candidate);
    }
    return error.NoSupportedShell;
}

fn passwdShellForHome(allocator: std.mem.Allocator, home: []const u8) ![]const u8 {
    const bytes = try compat.readFileAlloc(allocator, "/etc/passwd", 1024 * 1024);
    defer allocator.free(bytes);
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, home) == null) continue;
        var fields = std.mem.splitScalar(u8, line, ':');
        var idx: usize = 0;
        while (fields.next()) |field| : (idx += 1) {
            if (idx == 6 and field.len != 0) return allocator.dupe(u8, std.mem.trim(u8, field, " \t\r\n"));
        }
    }
    return error.NoSupportedShell;
}

fn isExecutable(path: []const u8) bool {
    const file = compat.openFile(path, .{}) catch return false;
    file.close(std.Options.debug_io);
    return true;
}

fn terminalEnv(allocator: std.mem.Allocator) !*std.process.Environ.Map {
    var env = try allocator.create(std.process.Environ.Map);
    env.* = if (builtin.os.tag == .windows) try compat.currentEnvMap(allocator) else compat.emptyEnvMap(allocator);
    if (builtin.os.tag != .windows) {
        try env.put("TERM", "xterm-256color");
        try env.put("LANG", "C.UTF-8");
        try env.put("LC_ALL", "C.UTF-8");
    }
    return env;
}

/// Poll first so cleanup can join the output worker before closing its PTY fd.
fn pumpOutput(allocator: std.mem.Allocator, from: std.Io.File, state: *SessionState) void {
    var buffer: [4096]u8 = undefined;
    var next_ping = nowMs() + ping_ms;
    while (!state.finished.load(.acquire)) {
        const n = readAvailableOutput(from, &buffer) catch break;
        if (state.socket()) |ws| {
            defer ws.release(allocator);
            if (n != 0) ws.writeBinary(buffer[0..n]) catch ws.shutdown();
            const now = nowMs();
            if (now >= next_ping) {
                ws.writePing() catch ws.shutdown();
                next_ping = now + ping_ms;
            }
        }
    }
    if (!state.finished.swap(true, .acq_rel)) {
        if (state.socket()) |ws| {
            defer ws.release(allocator);
            ws.writeText(terminate_message) catch {};
            ws.shutdown();
        }
    }
}

fn readAvailableOutput(from: std.Io.File, buffer: []u8) !usize {
    var fds = [_]std.posix.pollfd{.{ .fd = from.handle, .events = std.posix.POLL.IN, .revents = 0 }};
    if (try std.posix.poll(&fds, @intCast(poll_ms)) == 0) return 0;
    const rc = std.c.read(@intCast(from.handle), buffer.ptr, buffer.len);
    if (rc < 0) {
        const err = @as(std.posix.E, @enumFromInt(std.c._errno().*));
        if (err == .INTR or err == .AGAIN) return 0;
        return error.ShellOutputClosed;
    }
    return if (rc == 0) error.ShellOutputClosed else @intCast(rc);
}

fn setInputNonblocking(fd: std.posix.fd_t) !void {
    const flags = std.c.fcntl(fd, std.posix.F.GETFL);
    if (flags < 0) return error.ShellInputConfigurationFailed;
    var updated: std.posix.O = @bitCast(@as(u32, @bitCast(flags)));
    updated.NONBLOCK = true;
    if (std.c.fcntl(fd, std.posix.F.SETFL, @as(c_int, @bitCast(updated))) < 0)
        return error.ShellInputConfigurationFailed;
}

fn writeInputBounded(fd: std.posix.fd_t, bytes: []const u8, ws: *const ws_client.Client) !void {
    const deadline = nowMs() + input_wait_ms;
    var offset: usize = 0;
    while (offset < bytes.len) {
        if (ws.isClosed()) return error.TerminalTransportClosed;
        if (nowMs() >= deadline) return error.ShellInputBackpressure;
        const written = writeFdOnce(fd, bytes[offset..]) catch |err| switch (err) {
            error.Interrupted => continue,
            error.WouldBlock => {
                var fds = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.OUT, .revents = 0 }};
                _ = try std.posix.poll(&fds, @intCast(poll_ms));
                continue;
            },
            else => return err,
        };
        if (written == 0) return error.WriteFailed;
        offset += written;
    }
}

fn legacyPipeShellOutput(allocator: std.mem.Allocator, from: std.Io.File, ws: *ws_client.Client) void {
    defer ws.release(allocator);
    if (builtin.os.tag != .windows and from.handle >= 0) {
        var buf: [4096]u8 = undefined;
        while (true) {
            const n = readUnixFd(from.handle, &buf) catch return;
            if (n == 0) return;
            ws.writeBinary(buf[0..n]) catch return;
        }
    }
    var reader_buf: [4096]u8 = undefined;
    var reader = from.reader(std.Options.debug_io, &reader_buf);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = reader.interface.readSliceShort(&buf) catch return;
        if (n == 0) return;
        ws.writeBinary(buf[0..n]) catch return;
    }
}

fn terminalCwdAlloc(allocator: std.mem.Allocator) ![]u8 {
    if (builtin.os.tag == .windows) {
        const exe = compat.selfExePathAlloc(allocator) catch return allocator.dupe(u8, ".");
        defer allocator.free(exe);
        return allocator.dupe(u8, std.fs.path.dirname(exe) orelse ".");
    }
    if (compat.getEnvVarOwned(allocator, "HOME")) |home| {
        if (home.len != 0) return home;
        allocator.free(home);
    } else |_| {}
    return allocator.dupe(u8, "/");
}

fn writeUnixFdAll(fd: std.posix.fd_t, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const written = writeFdOnce(fd, bytes[offset..]) catch |err| switch (err) {
            error.Interrupted => continue,
            else => return err,
        };
        offset += written;
    }
}

fn writeFdOnce(fd: std.posix.fd_t, bytes: []const u8) !usize {
    if (comptime builtin.os.tag == .linux and !builtin.link_libc) {
        const rc = std.os.linux.write(@intCast(fd), bytes.ptr, bytes.len);
        return switch (std.os.linux.errno(rc)) {
            .SUCCESS => rc,
            .INTR => error.Interrupted,
            .AGAIN => error.WouldBlock,
            else => error.WriteFailed,
        };
    }
    const rc = std.c.write(@intCast(fd), bytes.ptr, bytes.len);
    if (rc < 0) {
        const err = @as(std.posix.E, @enumFromInt(std.c._errno().*));
        if (err == .INTR) return error.Interrupted;
        if (err == .AGAIN) return error.WouldBlock;
        return error.WriteFailed;
    }
    return @intCast(rc);
}

test "terminal recovery lease only resets on browser activity" {
    var state: SessionState = .{};
    state.beginRetentionAt(1_000);
    state.beginRetentionAt(3_000);
    try std.testing.expectEqual(@as(i64, 301_000), state.deadline());
    try std.testing.expect(state.markActiveAt(3_001));
    state.beginRetentionAt(4_000);
    try std.testing.expectEqual(@as(i64, 304_000), state.deadline());
    try std.testing.expect(!state.expire(303_999));
    try std.testing.expect(!state.markActiveAt(304_000));
    try std.testing.expect(state.expire(304_000));
    try std.testing.expect(!state.markActiveAt(304_001));
}

test "normal legacy websocket closure is final" {
    try std.testing.expect(isNormalWsClose(&.{}));
    try std.testing.expect(isNormalWsClose(&.{ 0x03, 0xe8 }));
    try std.testing.expect(!isNormalWsClose(&.{ 0x03, 0xe9 }));
}

fn readUnixFd(fd: std.posix.fd_t, buf: []u8) !usize {
    while (true) {
        const rc = std.c.read(@intCast(fd), buf.ptr, buf.len);
        if (rc < 0) {
            const err = @as(std.posix.E, @enumFromInt(std.c._errno().*));
            if (err == .INTR) continue;
            if (err == .IO or err == .AGAIN) {
                compat.sleep(20 * std.time.ns_per_ms);
                continue;
            }
            return error.ReadFailed;
        }
        return @intCast(rc);
    }
}
