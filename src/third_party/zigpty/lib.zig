/// zigpty — Pure Zig PTY library.
/// No NAPI or Node.js dependency. Can be used as a standalone Zig package.
const std = @import("std");
const builtin = @import("builtin");

pub const is_windows = builtin.os.tag == .windows;

const platform = switch (builtin.os.tag) {
    .linux => @import("pty_linux.zig"),
    .macos => @import("pty_darwin.zig"),
    .windows => @import("pty_windows.zig"),
    else => @compileError("unsupported OS: " ++ @tagName(builtin.os.tag)),
};

/// Re-export Windows module for direct access from NAPI layer.
pub const win = platform;

/// Re-export termios config (Unix only).
pub const termconfig = if (!is_windows) @import("termios.zig") else struct {};

// --- Shared types ---

/// Exit information from a child process.
pub const ExitInfo = struct {
    exit_code: i32,
    signal_code: i32,
};

pub const Fd = if (is_windows) platform.Fd else std.posix.fd_t;
pub const Pid = if (is_windows) platform.Pid else std.posix.pid_t;

// ============================================================================
// Unix-specific (Linux + macOS)
// ============================================================================

/// Result from `forkPty`.
pub const ForkResult = if (!is_windows) struct {
    fd: std.posix.fd_t,
    pid: std.posix.pid_t,
    pty_name: [256]u8,
    pty_name_len: usize,

    pub fn ptyName(self: *const ForkResult) []const u8 {
        return self.pty_name[0..self.pty_name_len];
    }
} else void;

/// Result from `openPty`.
pub const OpenResult = if (!is_windows) struct {
    master: std.posix.fd_t,
    slave: std.posix.fd_t,
    pty_name: [256]u8,
    pty_name_len: usize,

    pub fn ptyName(self: *const OpenResult) []const u8 {
        return self.pty_name[0..self.pty_name_len];
    }
} else void;

/// Options for `forkPty`.
pub const ForkOptions = if (!is_windows) struct {
    file: [*:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
    cwd: [*:0]const u8,
    cols: u16 = 80,
    rows: u16 = 24,
    uid: ?u32 = null,
    gid: ?u32 = null,
    use_utf8: bool = true,
} else void;

pub const PtyError = error{
    ForkPtyFailed,
    OpenPtyFailed,
    IoctlFailed,
    ChdirFailed,
    PtsnameFailed,
    TtynameFailed,
};

/// Info for a single non-leader process aggregated into Stats.
/// `name` is a short executable/command name (truncated to 32 bytes).
pub const ChildStats = struct {
    pid: Pid,
    name: [32]u8,
    name_len: u8,
    rss_bytes: u64,
    cpu_user_us: u64,
    cpu_sys_us: u64,

    pub fn nameSlice(self: *const ChildStats) []const u8 {
        return self.name[0..self.name_len];
    }
};

/// Aggregated process stats for a PTY.
/// Aggregates the leader process and every transitive descendant (by ppid)
/// on all platforms. Catches background jobs, subshells, and anything else
/// the leader spawned, regardless of pgrp/session/job-control juggling.
/// Double-fork daemons that reparent away from the leader fall out of the
/// tree (expected — they detached on purpose).
///
/// Top-level `rss_bytes`/`cpu_user_us`/`cpu_sys_us` are totals across all
/// aggregated processes (leader + children). `pid`/`cwd` refer to the leader
/// process (the spawned shell). `children` lists all non-leader descendants
/// aggregated; `count` is the total number of processes (children.len + 1).
///
/// `cwd` is a slice into the caller-provided buffer — null on Windows.
/// `children` is owned by the caller's allocator — call `deinit` to free.
/// CPU times are in microseconds. `rss_bytes` is resident set size.
pub const Stats = struct {
    pid: Pid,
    cwd: ?[]const u8,
    rss_bytes: u64,
    cpu_user_us: u64,
    cpu_sys_us: u64,
    count: u32,
    children: []const ChildStats,

    pub fn deinit(self: *Stats, allocator: std.mem.Allocator) void {
        if (self.children.len > 0) allocator.free(self.children);
        self.children = &[_]ChildStats{};
    }
};

// Unix extern declarations and functions — only compiled on non-Windows
pub const forkPty = if (!is_windows) forkPtyUnix else void;
pub const openPty = if (!is_windows) openPtyUnix else void;
pub const resize = if (!is_windows) resizeUnix else void;
pub const getProcessName = if (!is_windows) getProcessNameUnix else void;
pub const getStats = if (!is_windows) getStatsUnix else void;
pub const waitForExit = if (!is_windows) waitForExitUnix else void;

// --- Unix implementation (behind comptime guard) ---

const unix = if (!is_windows) struct {
    extern fn forkpty(master: *c_int, name: ?[*]u8, termp: ?*const anyopaque, winp: ?*const anyopaque) c_int;
    extern fn openpty(master: *c_int, slave: *c_int, name: ?[*]u8, termp: ?*const anyopaque, winp: ?*const anyopaque) c_int;
    extern fn waitpid(pid: c_int, status: *c_int, options: c_int) c_int;
    extern fn ttyname_r(fd: c_int, buf: [*]u8, buflen: usize) c_int;
    extern fn ioctl(fd: c_int, request: c_ulong, ...) c_int;

    const TIOCSWINSZ: c_ulong = switch (builtin.os.tag) {
        .linux => @intCast(std.posix.T.IOCSWINSZ),
        .macos => 0x80087467,
        else => 0,
    };
} else struct {};

fn forkPtyUnix(opts: ForkOptions) PtyError!ForkResult {
    var term: std.c.termios = std.mem.zeroes(std.c.termios);
    termconfig.configure(&term, opts.use_utf8);

    var ws = std.mem.zeroes(std.posix.winsize);
    ws.col = opts.cols;
    ws.row = opts.rows;

    // Ensure libtermux-exec.so is loaded on Android/Termux so its SIGSYS
    // handler is inherited by the forked child (seccomp softfail).
    if (builtin.os.tag == .linux) platform.ensureTermuxExec();

    var sigset_all = std.posix.sigfillset();
    var sigset_old: std.posix.sigset_t = undefined;
    _ = std.c.sigprocmask(std.c.SIG.SETMASK, @ptrCast(&sigset_all), @ptrCast(&sigset_old));

    var master_fd: c_int = -1;
    const pid = unix.forkpty(&master_fd, null, @ptrCast(&term), @ptrCast(&ws));

    if (pid < 0) {
        _ = std.c.sigprocmask(std.c.SIG.SETMASK, @ptrCast(&sigset_old), null);
        return PtyError.ForkPtyFailed;
    }

    if (pid == 0) {
        _ = std.c.sigprocmask(std.c.SIG.SETMASK, @ptrCast(&sigset_old), null);
        platform.resetSignalHandlers();

        if (std.c.chdir(opts.cwd) != 0) {
            platform.rawExit(1);
        }

        if (opts.gid) |gid| {
            if (std.c.setgid(gid) != 0) platform.rawExit(1);
        }
        if (opts.uid) |uid| {
            if (std.c.setuid(uid) != 0) platform.rawExit(1);
        }

        platform.closeExcessFds();

        platform.execChild(opts.file, opts.argv, opts.envp);
        platform.rawExit(1);
    }

    _ = std.c.sigprocmask(std.c.SIG.SETMASK, @ptrCast(&sigset_old), null);

    var result = ForkResult{
        .fd = @intCast(master_fd),
        .pid = pid,
        .pty_name = undefined,
        .pty_name_len = 0,
    };

    result.pty_name_len = platform.getPtyName(master_fd, &result.pty_name);

    return result;
}

fn openPtyUnix(cols: u16, rows: u16) PtyError!OpenResult {
    var ws = std.mem.zeroes(std.posix.winsize);
    ws.col = cols;
    ws.row = rows;

    var master_fd: c_int = undefined;
    var slave_fd: c_int = undefined;
    if (unix.openpty(&master_fd, &slave_fd, null, null, @ptrCast(&ws)) != 0) {
        return PtyError.OpenPtyFailed;
    }

    var result = OpenResult{
        .master = @intCast(master_fd),
        .slave = @intCast(slave_fd),
        .pty_name = undefined,
        .pty_name_len = 0,
    };

    if (unix.ttyname_r(slave_fd, &result.pty_name, result.pty_name.len) == 0) {
        result.pty_name_len = std.mem.indexOfScalar(u8, &result.pty_name, 0) orelse result.pty_name.len;
    }

    return result;
}

fn resizeUnix(fd: std.posix.fd_t, cols: u16, rows: u16, x_pixel: u16, y_pixel: u16) PtyError!void {
    var ws = std.mem.zeroes(std.posix.winsize);
    ws.col = cols;
    ws.row = rows;
    ws.xpixel = x_pixel;
    ws.ypixel = y_pixel;

    const ret = unix.ioctl(@intCast(fd), unix.TIOCSWINSZ, @intFromPtr(&ws));
    if (ret != 0) return PtyError.IoctlFailed;
}

fn getProcessNameUnix(fd: std.posix.fd_t, buf: []u8) ?[]const u8 {
    return platform.getProcessName(fd, buf);
}

fn getStatsUnix(pid: std.posix.pid_t, allocator: std.mem.Allocator, cwd_buf: []u8) ?Stats {
    return platform.getStats(pid, allocator, cwd_buf);
}

fn waitForExitUnix(pid: std.posix.pid_t) ExitInfo {
    var status: c_int = 0;
    while (true) {
        const ret = unix.waitpid(pid, &status, 0);
        if (ret == pid) break;
        if (ret == -1) {
            if (@as(std.posix.E, @enumFromInt(std.c._errno().*)) == .INTR) continue;
            return .{ .exit_code = -1, .signal_code = 0 };
        }
    }

    return decodeWaitStatus(status);
}

fn decodeWaitStatus(status: c_int) ExitInfo {
    const s: u32 = @bitCast(status);
    const termsig: u32 = s & 0x7f;
    if (termsig == 0) {
        return .{ .exit_code = @intCast((s >> 8) & 0xff), .signal_code = 0 };
    } else if (termsig != 0x7f) {
        return .{ .exit_code = 0, .signal_code = @intCast(termsig) };
    }
    return .{ .exit_code = -1, .signal_code = 0 };
}
