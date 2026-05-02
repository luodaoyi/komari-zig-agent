const std = @import("std");
const http = @import("../protocol/http.zig");
const ws_client = @import("../protocol/ws_client.zig");
const builtin = @import("builtin");

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

    const out_thread = try std.Thread.spawn(.{}, pipeShellOutputToWs, .{ session.output, ws });
    out_thread.detach();

    while (true) {
        const frame = try ws.readFrame(allocator);
        defer allocator.free(frame.payload);
        if (frame.opcode == 0x8) return;
        if (frame.opcode != 0x1 and frame.opcode != 0x2) continue;
        const input = parseInput(allocator, frame.payload);
        defer input.deinit(allocator);
        if (isCloseInput(input)) return;
        switch (input) {
            .input => |bytes| try session.input.writeAll(bytes),
            .raw => |bytes| try session.input.writeAll(bytes),
            .resize => |size| session.resize(size.cols, size.rows) catch {},
        }
    }
}

const ShellSession = struct {
    input: std.fs.File,
    output: std.fs.File,
    pid: if (builtin.os.tag == .windows) void else std.posix.pid_t,

    fn start(allocator: std.mem.Allocator) !ShellSession {
        if (builtin.os.tag == .linux) return startLinuxPty(allocator);
        return startPipeFallback(allocator);
    }

    fn close(self: *ShellSession) void {
        self.gracefulShutdown();
        if (builtin.os.tag != .windows and @TypeOf(self.pid) != void) {
            _ = std.posix.kill(-self.pid, std.posix.SIG.TERM) catch {
                _ = std.posix.kill(self.pid, std.posix.SIG.TERM) catch {};
            };
            _ = std.posix.waitpid(self.pid, 0);
        }
        if (self.input.handle != self.output.handle) self.input.close();
        self.output.close();
    }

    fn gracefulShutdown(self: *ShellSession) void {
        var writer = self.input.deprecatedWriter();
        var i: u8 = 0;
        while (i < 3) : (i += 1) {
            writer.writeAll(&.{3}) catch return;
            std.Thread.sleep(50 * std.time.ns_per_ms);
        }
        std.Thread.sleep(200 * std.time.ns_per_ms);
        writer.writeAll(&.{4}) catch {};
        std.Thread.sleep(100 * std.time.ns_per_ms);
        writer.writeAll("exit\n") catch {};
        std.Thread.sleep(100 * std.time.ns_per_ms);
    }

    fn resize(self: *ShellSession, cols: u16, rows: u16) !void {
        if (builtin.os.tag != .linux or cols == 0 or rows == 0) return;
        var wsz = std.posix.winsize{ .row = rows, .col = cols, .xpixel = 0, .ypixel = 0 };
        const rc = std.posix.system.ioctl(self.output.handle, std.posix.T.IOCSWINSZ, @intFromPtr(&wsz));
        if (std.posix.errno(rc) != .SUCCESS) return error.ResizeFailed;
    }
};

fn startLinuxPty(allocator: std.mem.Allocator) !ShellSession {
    const master = try std.posix.open("/dev/ptmx", .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0);
    errdefer std.posix.close(master);

    var unlock: c_int = 0;
    if (std.posix.errno(std.posix.system.ioctl(master, std.posix.T.IOCSPTLCK, @intFromPtr(&unlock))) != .SUCCESS) return error.PtyUnlockFailed;
    var pty_num: c_uint = 0;
    if (std.posix.errno(std.posix.system.ioctl(master, std.posix.T.IOCGPTN, @intFromPtr(&pty_num))) != .SUCCESS) return error.PtyNameFailed;

    const slave_path_raw = try std.fmt.allocPrint(allocator, "/dev/pts/{d}", .{pty_num});
    defer allocator.free(slave_path_raw);
    const slave_path = try allocator.dupeZ(u8, slave_path_raw);
    defer allocator.free(slave_path);
    const shell_path = try shellPathAlloc(allocator);
    defer allocator.free(shell_path);
    const shell = try allocator.dupeZ(u8, shell_path);
    defer allocator.free(shell);
    const shell_base_raw = std.fs.path.basename(shell_path);
    const shell_base = try allocator.dupeZ(u8, shell_base_raw);
    defer allocator.free(shell_base);
    const prelude = try allocator.dupeZ(u8, "for f in /etc/update-motd.d/*; do [ -x \"$f\" ] && \"$f\"; done; [ -r /etc/motd ] && cat /etc/motd; exec \"$0\"");
    defer allocator.free(prelude);
    var argv = [_:null]?[*:0]const u8{ shell_base.ptr, "-c", prelude.ptr, shell_base.ptr };
    const path_env = std.process.getEnvVarOwned(allocator, "PATH") catch try allocator.dupe(u8, "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin");
    defer allocator.free(path_env);
    const path_kv_raw = try std.fmt.allocPrint(allocator, "PATH={s}", .{path_env});
    defer allocator.free(path_kv_raw);
    const path_kv = try allocator.dupeZ(u8, path_kv_raw);
    defer allocator.free(path_kv);
    const env = [_:null]?[*:0]const u8{
        "TERM=xterm-256color",
        "LANG=C.UTF-8",
        "LC_ALL=C.UTF-8",
        path_kv.ptr,
    };

    const pid = try std.posix.fork();
    if (pid == 0) {
        _ = std.os.linux.setsid();
        const slave = std.posix.openZ(slave_path.ptr, .{ .ACCMODE = .RDWR }, 0) catch std.posix.exit(127);
        _ = std.posix.system.ioctl(slave, std.posix.T.IOCSCTTY, 0);
        std.posix.dup2(slave, std.posix.STDIN_FILENO) catch std.posix.exit(127);
        std.posix.dup2(slave, std.posix.STDOUT_FILENO) catch std.posix.exit(127);
        std.posix.dup2(slave, std.posix.STDERR_FILENO) catch std.posix.exit(127);
        if (slave > 2) std.posix.close(slave);
        std.posix.close(master);
        std.posix.execveZ(shell.ptr, &argv, &env) catch std.posix.exit(127);
    }

    const pty_file = std.fs.File{ .handle = master };
    var initial_size = std.posix.winsize{ .row = 24, .col = 80, .xpixel = 0, .ypixel = 0 };
    _ = std.posix.system.ioctl(master, std.posix.T.IOCSWINSZ, @intFromPtr(&initial_size));
    return .{ .input = pty_file, .output = pty_file, .pid = pid };
}

fn startPipeFallback(allocator: std.mem.Allocator) !ShellSession {
    const shell = shellPath();
    const argv = if (builtin.os.tag == .windows)
        &.{ shell }
    else
        &.{ "script", "-q", "/dev/null", shell };
    var sh = std.process.Child.init(argv, allocator);
    sh.stdin_behavior = .Pipe;
    sh.stdout_behavior = .Pipe;
    sh.stderr_behavior = .Ignore;
    sh.env_map = try terminalEnv(allocator);
    try sh.spawn();
    if (sh.stdin == null or sh.stdout == null) return error.ShellPipeFailed;
    return .{ .input = sh.stdin.?, .output = sh.stdout.?, .pid = if (builtin.os.tag == .windows) {} else sh.id };
}

fn shellPath() []const u8 {
    if (std.process.getEnvVarOwned(std.heap.page_allocator, "SHELL")) |value| {
        if (value.len != 0) return value;
    } else |_| {}
    return "/bin/sh";
}

fn shellPathAlloc(allocator: std.mem.Allocator) ![]const u8 {
    if (std.process.getEnvVarOwned(allocator, "HOME")) |home| {
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
    const bytes = try std.fs.cwd().readFileAlloc(allocator, "/etc/passwd", 1024 * 1024);
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
    const file = std.fs.cwd().openFile(path, .{}) catch return false;
    file.close();
    return true;
}

fn terminalEnv(allocator: std.mem.Allocator) !*std.process.EnvMap {
    var env = try allocator.create(std.process.EnvMap);
    env.* = std.process.EnvMap.init(allocator);
    try env.put("TERM", "xterm-256color");
    try env.put("LANG", "C.UTF-8");
    try env.put("LC_ALL", "C.UTF-8");
    return env;
}

fn pipeShellOutputToWs(from: std.fs.File, ws: *ws_client.Client) void {
    var reader = from.deprecatedReader();
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = reader.read(&buf) catch return;
        if (n == 0) return;
        ws.writeBinary(buf[0..n]) catch return;
    }
}
