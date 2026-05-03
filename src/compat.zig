const std = @import("std");

/// Small blocking mutex used where the agent needs old `std.Thread.Mutex`
/// semantics on Zig 0.16.
pub const Mutex = struct {
    state: std.atomic.Mutex = .unlocked,

    pub fn lock(self: *Mutex) void {
        while (!self.state.tryLock()) {
            std.Thread.yield() catch {};
        }
    }

    pub fn unlock(self: *Mutex) void {
        self.state.unlock();
    }
};

pub fn currentEnvMap(allocator: std.mem.Allocator) !std.process.Environ.Map {
    if (std.Options.debug_threaded_io) |threaded_io| {
        return threaded_io.environ.process_environ.createMap(allocator);
    }
    return .init(allocator);
}

pub fn getEnvVarOwned(allocator: std.mem.Allocator, key: []const u8) ![]u8 {
    if (std.Options.debug_threaded_io) |threaded_io| {
        return threaded_io.environ.process_environ.getAlloc(allocator, key);
    }
    return error.EnvironmentVariableMissing;
}

pub fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, path, allocator, .limited(max_bytes));
}

pub fn selfExePathAlloc(allocator: std.mem.Allocator) ![]u8 {
    return std.process.executablePathAlloc(std.Options.debug_io, allocator);
}

pub fn statFile(path: []const u8) !std.Io.Dir.Stat {
    return std.Io.Dir.cwd().statFile(std.Options.debug_io, path, .{});
}

pub fn openFile(path: []const u8, options: std.Io.Dir.OpenFileOptions) !std.Io.File {
    return std.Io.Dir.cwd().openFile(std.Options.debug_io, path, options);
}

pub fn openFileAbsolute(path: []const u8, options: std.Io.Dir.OpenFileOptions) !std.Io.File {
    return std.Io.Dir.openFileAbsolute(std.Options.debug_io, path, options);
}

pub fn createFileAbsolute(path: []const u8, options: std.Io.Dir.CreateFileOptions) !std.Io.File {
    return std.Io.Dir.createFileAbsolute(std.Options.debug_io, path, options);
}

pub fn openDir(path: []const u8, options: std.Io.Dir.OpenOptions) !std.Io.Dir {
    return std.Io.Dir.cwd().openDir(std.Options.debug_io, path, options);
}

pub fn renameAbsolute(old_path: []const u8, new_path: []const u8) !void {
    return std.Io.Dir.renameAbsolute(old_path, new_path, std.Options.debug_io);
}

pub fn deleteFileAbsolute(path: []const u8) !void {
    return std.Io.Dir.deleteFileAbsolute(std.Options.debug_io, path);
}

pub fn copyFileAbsolute(src: []const u8, dst: []const u8, permissions: ?std.Io.File.Permissions) !void {
    return std.Io.Dir.copyFileAbsolute(src, dst, std.Options.debug_io, .{
        .permissions = permissions,
        .replace = true,
    });
}

pub fn readLinkAbsolute(path: []const u8, buffer: []u8) ![]u8 {
    const n = try std.Io.Dir.readLinkAbsolute(std.Options.debug_io, path, buffer);
    return buffer[0..n];
}

pub fn closeFd(fd: std.posix.fd_t) void {
    if (@import("builtin").os.tag == .linux) {
        _ = std.os.linux.close(fd);
    } else {
        _ = std.c.close(fd);
    }
}

pub fn socket(domain: std.posix.sa_family_t, socket_type: u32, protocol: u32) !std.posix.fd_t {
    if (@import("builtin").os.tag == .linux) {
        const rc = std.os.linux.socket(@intCast(domain), socket_type, protocol);
        return switch (std.posix.errno(rc)) {
            .SUCCESS => @intCast(rc),
            .ACCES, .PERM => error.AccessDenied,
            else => |err| std.posix.unexpectedErrno(err),
        };
    }
    const rc = std.c.socket(@intCast(domain), socket_type, protocol);
    return switch (std.posix.errno(rc)) {
        .SUCCESS => @intCast(rc),
        .ACCES, .PERM => error.AccessDenied,
        else => |err| std.posix.unexpectedErrno(err),
    };
}

pub fn sendTo(fd: std.posix.fd_t, bytes: []const u8, addr: *const std.posix.sockaddr, len: std.posix.socklen_t) !usize {
    if (@import("builtin").os.tag == .linux) {
        const rc = std.os.linux.sendto(fd, bytes.ptr, bytes.len, 0, addr, len);
        return switch (std.posix.errno(rc)) {
            .SUCCESS => rc,
            else => |err| std.posix.unexpectedErrno(err),
        };
    }
    const rc = std.c.sendto(fd, bytes.ptr, bytes.len, 0, addr, len);
    return switch (std.posix.errno(rc)) {
        .SUCCESS => @intCast(rc),
        else => |err| std.posix.unexpectedErrno(err),
    };
}

pub fn recvFrom(fd: std.posix.fd_t, buf: []u8) !usize {
    if (@import("builtin").os.tag == .linux) {
        const rc = std.os.linux.recvfrom(fd, buf.ptr, buf.len, 0, null, null);
        return switch (std.posix.errno(rc)) {
            .SUCCESS => rc,
            else => |err| std.posix.unexpectedErrno(err),
        };
    }
    const rc = std.c.recvfrom(fd, buf.ptr, buf.len, 0, null, null);
    return switch (std.posix.errno(rc)) {
        .SUCCESS => @intCast(rc),
        else => |err| std.posix.unexpectedErrno(err),
    };
}

pub fn fork() !std.posix.pid_t {
    if (@import("builtin").os.tag == .linux) {
        const rc = std.os.linux.fork();
        return switch (std.posix.errno(rc)) {
            .SUCCESS => @intCast(rc),
            else => |err| std.posix.unexpectedErrno(err),
        };
    }
    const rc = std.c.fork();
    return switch (std.posix.errno(rc)) {
        .SUCCESS => @intCast(rc),
        else => |err| std.posix.unexpectedErrno(err),
    };
}

pub fn dup2(old_fd: std.posix.fd_t, new_fd: std.posix.fd_t) !void {
    if (@import("builtin").os.tag == .linux) {
        const rc = std.os.linux.dup2(old_fd, new_fd);
        return switch (std.posix.errno(rc)) {
            .SUCCESS => {},
            else => |err| std.posix.unexpectedErrno(err),
        };
    }
    const rc = std.c.dup2(old_fd, new_fd);
    return switch (std.posix.errno(rc)) {
        .SUCCESS => {},
        else => |err| std.posix.unexpectedErrno(err),
    };
}

pub fn execveZ(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) !void {
    if (@import("builtin").os.tag == .linux) {
        const rc = std.os.linux.execve(path, argv, envp);
        return switch (std.posix.errno(rc)) {
            .SUCCESS => unreachable,
            else => |err| std.posix.unexpectedErrno(err),
        };
    }
    const rc = std.c.execve(path, argv, envp);
    return switch (std.posix.errno(rc)) {
        .SUCCESS => unreachable,
        else => |err| std.posix.unexpectedErrno(err),
    };
}

pub const WaitPidResult = struct {
    pid: std.posix.pid_t,
    status: u32,
};

pub fn waitPid(pid: std.posix.pid_t, flags: u32) !WaitPidResult {
    if (@import("builtin").os.tag == .linux) {
        var status: u32 = 0;
        const rc = std.os.linux.waitpid(pid, &status, flags);
        return switch (std.posix.errno(rc)) {
            .SUCCESS => .{ .pid = @intCast(rc), .status = status },
            else => |err| std.posix.unexpectedErrno(err),
        };
    }
    var status: c_int = 0;
    const rc = std.c.waitpid(pid, &status, @intCast(flags));
    return switch (std.posix.errno(rc)) {
        .SUCCESS => .{ .pid = @intCast(rc), .status = @intCast(status) },
        else => |err| std.posix.unexpectedErrno(err),
    };
}

pub fn setsid() !std.posix.pid_t {
    if (@import("builtin").os.tag == .linux) {
        const rc = std.os.linux.setsid();
        return switch (std.posix.errno(rc)) {
            .SUCCESS => @intCast(rc),
            else => |err| std.posix.unexpectedErrno(err),
        };
    }
    const rc = std.c.setsid();
    return switch (std.posix.errno(rc)) {
        .SUCCESS => @intCast(rc),
        else => |err| std.posix.unexpectedErrno(err),
    };
}

pub const RunOutputResult = struct {
    term: std.process.Child.Term,
    stdout: []u8,
};

pub fn runOutputIgnoreStderr(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    environ_map: ?*const std.process.Environ.Map,
    stdout_limit: usize,
) !RunOutputResult {
    var child = try std.process.spawn(std.Options.debug_io, .{
        .argv = argv,
        .environ_map = environ_map,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    });
    defer child.kill(std.Options.debug_io);

    const stdout_file = child.stdout orelse return error.CommandFailed;
    var reader_buf: [4096]u8 = undefined;
    var reader = stdout_file.reader(std.Options.debug_io, &reader_buf);
    var out = std.Io.Writer.Allocating.init(allocator);
    errdefer out.deinit();
    var total: usize = 0;
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = try reader.interface.readSliceShort(&buf);
        if (n == 0) break;
        if (total + n > stdout_limit) return error.StreamTooLong;
        try out.writer.writeAll(buf[0..n]);
        total += n;
    }

    return .{
        .term = try child.wait(std.Options.debug_io),
        .stdout = try out.toOwnedSlice(),
    };
}

pub fn runIgnoreOutput(argv: []const []const u8, environ_map: ?*const std.process.Environ.Map) !std.process.Child.Term {
    var child = try std.process.spawn(std.Options.debug_io, .{
        .argv = argv,
        .environ_map = environ_map,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    defer child.kill(std.Options.debug_io);
    return child.wait(std.Options.debug_io);
}

pub const FileWriter = struct {
    inner: std.Io.File.Writer,

    pub fn flush(self: *FileWriter) !void {
        try self.inner.interface.flush();
    }

    pub fn writeAll(self: *FileWriter, bytes: []const u8) !void {
        try self.inner.interface.writeAll(bytes);
    }

    pub fn print(self: *FileWriter, comptime fmt: []const u8, args: anytype) !void {
        try self.inner.interface.print(fmt, args);
    }
};

pub fn fileWriter(file: std.Io.File, buffer: []u8) FileWriter {
    return .{ .inner = file.writerStreaming(std.Options.debug_io, buffer) };
}

pub fn sleep(nanoseconds: u64) void {
    std.Io.sleep(std.Options.debug_io, .fromNanoseconds(@intCast(nanoseconds)), .awake) catch {};
}

pub fn unixTimestamp() i64 {
    return std.Io.Timestamp.now(std.Options.debug_io, .real).toSeconds();
}

pub fn milliTimestamp() i64 {
    return std.Io.Timestamp.now(std.Options.debug_io, .real).toMilliseconds();
}

pub fn nanoTimestamp() i128 {
    return std.Io.Timestamp.now(std.Options.debug_io, .real).toNanoseconds();
}

pub fn appendPrint(
    allocator: std.mem.Allocator,
    list: *std.ArrayList(u8),
    comptime fmt: []const u8,
    args: anytype,
) !void {
    var writer = std.Io.Writer.Allocating.fromArrayList(allocator, list);
    errdefer list.* = writer.toArrayList();
    try writer.writer.print(fmt, args);
    list.* = writer.toArrayList();
}
