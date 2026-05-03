const std = @import("std");
const builtin = @import("builtin");

/// Low-level POSIX wrappers kept narrow for Zig 0.16 cross-target support.
pub fn closeFd(fd: std.posix.fd_t) void {
    if (builtin.os.tag == .linux) {
        _ = std.os.linux.close(fd);
    } else {
        _ = std.c.close(fd);
    }
}

pub fn socket(domain: std.posix.sa_family_t, socket_type: u32, protocol: u32) !std.posix.fd_t {
    if (builtin.os.tag == .linux) {
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
    if (builtin.os.tag == .linux) {
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
    if (builtin.os.tag == .linux) {
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
    if (builtin.os.tag == .linux) {
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
    if (builtin.os.tag == .linux) {
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
    if (builtin.os.tag == .linux) {
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
    if (builtin.os.tag == .linux) {
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
    if (builtin.os.tag == .linux) {
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
