const std = @import("std");
const http = @import("../protocol/http.zig");
const ws_client = @import("../protocol/ws_client.zig");
const builtin = @import("builtin");
const compat = @import("compat");
const thread_stacks = @import("../thread_stacks.zig");
const zigpty = if (builtin.os.tag == .linux or builtin.os.tag == .macos) @import("zigpty") else struct {};

extern "c" fn openpty(amaster: *c_int, aslave: *c_int, name: ?[*]u8, termp: ?*const anyopaque, winp: ?*const std.posix.winsize) c_int;
extern "c" fn ioctl(fd: std.posix.fd_t, request: c_ulong, ...) c_int;

/// Web terminal session bridge between PTY/process IO and websocket frames.
pub const Input = union(enum) {
    input: []const u8,
    resize: struct { cols: u16, rows: u16 },
    raw: []const u8,

    pub fn deinit(self: Input, allocator: std.mem.Allocator) void {
        switch (self) {
            .input => |bytes| allocator.free(bytes),
            .resize, .raw => {},
        }
    }
};

pub fn parseInput(allocator: std.mem.Allocator, bytes: []const u8) Input {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch return .{ .raw = bytes };
    defer parsed.deinit();
    const obj = parsed.value.object;
    const typ = obj.get("type") orelse return .{ .raw = bytes };
    if (typ != .string) return .{ .raw = bytes };
    if (std.mem.eql(u8, typ.string, "input")) {
        if (obj.get("input")) |v| if (v == .string) return .{ .input = allocator.dupe(u8, v.string) catch return .{ .raw = bytes } };
    }
    if (std.mem.eql(u8, typ.string, "resize")) {
        const cols = if (obj.get("cols")) |v| if (v == .integer) @as(u16, @intCast(v.integer)) else 0 else 0;
        const rows = if (obj.get("rows")) |v| if (v == .integer) @as(u16, @intCast(v.integer)) else 0 else 0;
        return .{ .resize = .{ .cols = cols, .rows = rows } };
    }
    return .{ .raw = bytes };
}

pub fn isCloseInput(input: Input) bool {
    return switch (input) {
        .input => |bytes| isCloseBytes(bytes),
        .raw => |bytes| isCloseBytes(bytes),
        .resize => false,
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

pub fn startSession(allocator: std.mem.Allocator, cfg: anytype, request_id: []const u8) !void {
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
    const out_thread = std.Thread.spawn(.{ .stack_size = thread_stacks.terminal_worker_stack_size }, pipeShellOutputToWs, .{ allocator, session.output, ws }) catch |err| {
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
        if (isCloseInput(input)) return;
        switch (input) {
            .input => |bytes| try session.writeInput(bytes),
            .raw => |bytes| try session.writeInput(bytes),
            .resize => |size| session.resize(size.cols, size.rows) catch {},
        }
    }
}

const ShellSession = struct {
    input: std.Io.File,
    output: std.Io.File,
    pid: if (builtin.os.tag == .windows) void else std.posix.pid_t,

    fn start(allocator: std.mem.Allocator) !ShellSession {
        if (builtin.os.tag == .linux or builtin.os.tag == .macos) return startZigPty(allocator);
        if (builtin.os.tag == .freebsd) return startBsdPty(allocator);
        return startPipeFallback(allocator);
    }

    fn close(self: *ShellSession) void {
        self.gracefulShutdown();
        if (builtin.os.tag != .windows and @TypeOf(self.pid) != void) {
            _ = std.posix.kill(-self.pid, std.posix.SIG.TERM) catch {
                _ = std.posix.kill(self.pid, std.posix.SIG.TERM) catch {};
            };
            const deadline = compat.milliTimestamp() + 5000;
            while (compat.milliTimestamp() < deadline) {
                const result = compat.waitPid(self.pid, if (builtin.os.tag == .linux) std.os.linux.W.NOHANG else 0) catch break;
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
        var buf: [64]u8 = undefined;
        const cmd = try std.fmt.bufPrint(&buf, "stty cols {d} rows {d}\n", .{ cols, rows });
        try self.writeInput(cmd);
    }
};

fn startZigPty(allocator: std.mem.Allocator) !ShellSession {
    return startZigPtyWithPrelude(allocator, true) catch |err| switch (err) {
        error.ShellExitedEarly => startZigPtyWithPrelude(allocator, false),
        else => return err,
    };
}

fn startZigPtyWithPrelude(allocator: std.mem.Allocator, use_prelude: bool) !ShellSession {
    const shell_path = try shellPathAlloc(allocator);
    defer allocator.free(shell_path);
    const shell = try allocator.dupeZ(u8, shell_path);
    defer allocator.free(shell);
    const shell_base_raw = std.fs.path.basename(shell_path);
    const shell_base = try allocator.dupeZ(u8, shell_base_raw);
    defer allocator.free(shell_base);
    const prelude = if (use_prelude) try allocator.dupeZ(u8, "for f in /etc/update-motd.d/*; do [ -x \"$f\" ] && \"$f\"; done; [ -r /etc/motd ] && cat /etc/motd; exec \"$0\"") else null;
    defer if (prelude) |value| allocator.free(value);
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
    const result = if (prelude) |value| blk: {
        var argv = [_:null]?[*:0]const u8{ shell_base.ptr, "-c", value.ptr };
        break :blk try zigpty.forkPty(.{
            .file = shell.ptr,
            .argv = &argv,
            .envp = envp.slice.ptr,
            .cwd = cwd_z.ptr,
            .cols = 80,
            .rows = 24,
            .use_utf8 = true,
        });
    } else blk: {
        var argv = [_:null]?[*:0]const u8{ shell.ptr };
        break :blk try zigpty.forkPty(.{
            .file = shell.ptr,
            .argv = &argv,
            .envp = envp.slice.ptr,
            .cwd = cwd_z.ptr,
            .cols = 80,
            .rows = 24,
            .use_utf8 = true,
        });
    };
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
    return startBsdPtyWithPrelude(allocator, true) catch |err| switch (err) {
        error.ShellExitedEarly => startBsdPtyWithPrelude(allocator, false),
        else => return err,
    };
}

fn startBsdPtyWithPrelude(allocator: std.mem.Allocator, use_prelude: bool) !ShellSession {
    const shell_path = try shellPathAlloc(allocator);
    defer allocator.free(shell_path);
    const shell = try allocator.dupeZ(u8, shell_path);
    defer allocator.free(shell);
    const shell_base_raw = std.fs.path.basename(shell_path);
    const shell_base = try allocator.dupeZ(u8, shell_base_raw);
    defer allocator.free(shell_base);
    const prelude = if (use_prelude) try allocator.dupeZ(u8, "for f in /etc/update-motd.d/*; do [ -x \"$f\" ] && \"$f\"; done; [ -r /etc/motd ] && cat /etc/motd; exec \"$0\"") else null;
    defer if (prelude) |value| allocator.free(value);
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
        if (prelude) |value| {
            var argv = [_:null]?[*:0]const u8{ shell_base.ptr, "-c", value.ptr };
            compat.execveZ(shell.ptr, &argv, env.slice.ptr) catch std.process.exit(127);
        } else {
            var argv = [_:null]?[*:0]const u8{ shell_base.ptr };
            compat.execveZ(shell.ptr, &argv, env.slice.ptr) catch std.process.exit(127);
        }
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
    const shell = shellPath();
    const argv = if (builtin.os.tag == .windows)
        &.{shell}
    else
        &.{ "script", "-q", "-c", shell, "/dev/null" };
    var child = try std.process.spawn(std.Options.debug_io, .{
        .argv = argv,
        .environ_map = try terminalEnv(allocator),
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .ignore,
        .create_no_window = builtin.os.tag == .windows,
    });
    if (child.stdin == null or child.stdout == null) {
        child.kill(std.Options.debug_io);
        return error.ShellPipeFailed;
    }
    return .{
        .input = child.stdin.?,
        .output = child.stdout.?,
        .pid = if (builtin.os.tag == .windows) {} else child.id orelse return error.ShellPipeFailed,
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
    env.* = std.process.Environ.Map.init(allocator);
    try env.put("TERM", "xterm-256color");
    try env.put("LANG", "C.UTF-8");
    try env.put("LC_ALL", "C.UTF-8");
    return env;
}

fn pipeShellOutputToWs(allocator: std.mem.Allocator, from: std.Io.File, ws: *ws_client.Client) void {
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
    if (compat.getEnvVarOwned(allocator, "HOME")) |home| {
        if (home.len != 0) return home;
        allocator.free(home);
    } else |_| {}
    return allocator.dupe(u8, "/");
}

fn writeUnixFdAll(fd: std.posix.fd_t, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const rc = std.c.write(@intCast(fd), bytes.ptr + offset, bytes.len - offset);
        if (rc < 0) {
            const err = @as(std.posix.E, @enumFromInt(std.c._errno().*));
            if (err == .INTR) continue;
            return error.WriteFailed;
        }
        offset += @intCast(rc);
    }
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
