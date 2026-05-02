const std = @import("std");
const http = @import("../protocol/http.zig");
const ws_client = @import("../protocol/ws_client.zig");
const builtin = @import("builtin");

pub const Input = union(enum) {
    input: []const u8,
    resize: struct { cols: u16, rows: u16 },
    raw: []const u8,
};

pub fn parseInput(bytes: []const u8) Input {
    var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, bytes, .{}) catch return .{ .raw = bytes };
    defer parsed.deinit();
    const obj = parsed.value.object;
    const typ = obj.get("type") orelse return .{ .raw = bytes };
    if (typ != .string) return .{ .raw = bytes };
    if (std.mem.eql(u8, typ.string, "input")) {
        if (obj.get("input")) |v| if (v == .string) return .{ .input = v.string };
    }
    if (std.mem.eql(u8, typ.string, "resize")) {
        const cols = if (obj.get("cols")) |v| if (v == .integer) @as(u16, @intCast(v.integer)) else 0 else 0;
        const rows = if (obj.get("rows")) |v| if (v == .integer) @as(u16, @intCast(v.integer)) else 0 else 0;
        return .{ .resize = .{ .cols = cols, .rows = rows } };
    }
    return .{ .raw = bytes };
}

pub fn startDisabledMessage() []const u8 {
    return "\n\nWeb SSH is disabled. Enable it by running without the --disable-web-ssh flag.";
}

pub fn startSession(allocator: std.mem.Allocator, cfg: anytype, request_id: []const u8) !void {
    if (cfg.disable_web_ssh) return;
    const url = try http.terminalWsUrl(allocator, cfg.endpoint, cfg.token, request_id);
    defer allocator.free(url);
    const ws = try ws_client.connect(allocator, url);
    defer ws.close(allocator);

    var session = try ShellSession.start(allocator);
    defer session.close();

    const out_thread = try std.Thread.spawn(.{}, pipeShellOutputToWs, .{ session.output, ws });
    out_thread.detach();

    while (true) {
        const frame = try ws.readFrame(allocator);
        defer allocator.free(frame.payload);
        if (frame.opcode == 0x8) return;
        if (frame.opcode != 0x1 and frame.opcode != 0x2) continue;
        const input = parseInput(frame.payload);
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
        if (builtin.os.tag != .windows and @TypeOf(self.pid) != void) {
            _ = std.posix.kill(self.pid, std.posix.SIG.TERM) catch {};
            _ = std.posix.waitpid(self.pid, 0);
        }
        if (self.input.handle != self.output.handle) self.input.close();
        self.output.close();
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
    const shell = try allocator.dupeZ(u8, shellPath());
    defer allocator.free(shell);
    var argv = [_:null]?[*:0]const u8{ shell.ptr };
    const empty_env = [_:null]?[*:0]const u8{};

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
        std.posix.execveZ(shell.ptr, &argv, &empty_env) catch std.posix.exit(127);
    }

    const pty_file = std.fs.File{ .handle = master };
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

fn pipeShellOutputToWs(from: std.fs.File, ws: *ws_client.Client) void {
    var reader = from.deprecatedReader();
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = reader.read(&buf) catch return;
        if (n == 0) return;
        ws.writeBinary(buf[0..n]) catch return;
    }
}
