const std = @import("std");

/// Filesystem helpers over Zig 0.16 `std.Io` APIs.
pub fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    if (isVirtualKernelFile(path)) return readStreamingFileAlloc(allocator, path, max_bytes);
    if (!std.fs.path.isAbsolute(path)) {
        return std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, path, allocator, .limited(max_bytes));
    }

    var file = try openFile(path, .{});
    defer file.close(std.Options.debug_io);
    var reader = file.reader(std.Options.debug_io, &.{});
    return reader.interface.allocRemaining(allocator, .limited(max_bytes)) catch |err| switch (err) {
        error.ReadFailed => return reader.err.?,
        error.OutOfMemory, error.StreamTooLong => |e| return e,
    };
}

fn readStreamingFileAlloc(allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    var file = try openFile(path, .{});
    defer file.close(std.Options.debug_io);
    var reader_buf: [4096]u8 = undefined;
    var read_buf: [4096]u8 = undefined;
    var reader = file.reader(std.Options.debug_io, &reader_buf);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    while (true) {
        const n = try reader.interface.readSliceShort(&read_buf);
        if (n == 0) break;
        if (out.items.len + n > max_bytes) return error.StreamTooLong;
        try out.appendSlice(allocator, read_buf[0..n]);
    }
    return out.toOwnedSlice(allocator);
}

fn isVirtualKernelFile(path: []const u8) bool {
    return std.mem.startsWith(u8, path, "/proc/") or
        std.mem.eql(u8, path, "/proc") or
        std.mem.startsWith(u8, path, "/sys/") or
        std.mem.eql(u8, path, "/sys");
}

pub fn selfExePathAlloc(allocator: std.mem.Allocator) ![]u8 {
    return std.process.executablePathAlloc(std.Options.debug_io, allocator);
}

pub fn statFile(path: []const u8) !std.Io.Dir.Stat {
    if (std.fs.path.isAbsolute(path)) {
        const file = try openFileAbsolute(path, .{});
        defer file.close(std.Options.debug_io);
        return file.stat(std.Options.debug_io);
    }
    return std.Io.Dir.cwd().statFile(std.Options.debug_io, path, .{});
}

pub fn openFile(path: []const u8, options: std.Io.Dir.OpenFileOptions) !std.Io.File {
    if (std.fs.path.isAbsolute(path)) return openFileAbsolute(path, options);
    return std.Io.Dir.cwd().openFile(std.Options.debug_io, path, options);
}

pub fn openFileAbsolute(path: []const u8, options: std.Io.Dir.OpenFileOptions) !std.Io.File {
    return std.Io.Dir.openFileAbsolute(std.Options.debug_io, path, options);
}

pub fn createFileAbsolute(path: []const u8, options: std.Io.Dir.CreateFileOptions) !std.Io.File {
    return std.Io.Dir.createFileAbsolute(std.Options.debug_io, path, options);
}

pub fn openDir(path: []const u8, options: std.Io.Dir.OpenOptions) !std.Io.Dir {
    if (std.fs.path.isAbsolute(path)) return std.Io.Dir.openDirAbsolute(std.Options.debug_io, path, options);
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

pub const private_file_permissions: std.Io.File.Permissions =
    if (@hasDecl(std.Io.File.Permissions, "fromMode")) std.Io.File.Permissions.fromMode(0o600) else .default_file;

pub const executable_file_permissions: std.Io.File.Permissions =
    if (@hasDecl(std.Io.File.Permissions, "fromMode")) std.Io.File.Permissions.fromMode(0o755) else .executable_file;

pub fn readLinkAbsolute(path: []const u8, buffer: []u8) ![]u8 {
    const n = try std.Io.Dir.readLinkAbsolute(std.Options.debug_io, path, buffer);
    return buffer[0..n];
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

pub fn readAll(file: std.Io.File, buf: []u8) !usize {
    var reader_buf: [4096]u8 = undefined;
    var reader = file.reader(std.Options.debug_io, &reader_buf);
    var total: usize = 0;
    while (total < buf.len) {
        const n = try reader.interface.readSliceShort(buf[total..]);
        if (n == 0) break;
        total += n;
    }
    return total;
}
