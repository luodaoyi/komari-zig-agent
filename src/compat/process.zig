const std = @import("std");
const builtin = @import("builtin");
const runtime = @import("runtime");
const windows = std.os.windows;

/// Process spawning helpers with bounded stdout capture.
pub const RunOutputResult = struct {
    term: std.process.Child.Term,
    stdout: []u8,
};

pub const WindowsProcessHandles = struct {
    process: windows.HANDLE,
    thread: windows.HANDLE,
};

pub const WindowsPipedChild = struct {
    stdin: std.Io.File,
    stdout: std.Io.File,
    process: WindowsProcessHandles,
};

pub fn runOutputIgnoreStderr(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    environ_map: ?*const std.process.Environ.Map,
    stdout_limit: usize,
) !RunOutputResult {
    const io = runtime.io();
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .environ_map = environ_map,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    });
    defer child.kill(io);

    const stdout_file = child.stdout orelse return error.CommandFailed;
    var reader_buf: [4096]u8 = undefined;
    var reader = stdout_file.reader(io, &reader_buf);
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
        .term = try child.wait(io),
        .stdout = try out.toOwnedSlice(),
    };
}

pub fn runOutputWindows(allocator: std.mem.Allocator, argv: []const []const u8, stdout_limit: usize) !RunOutputResult {
    if (builtin.os.tag != .windows) return error.UnsupportedOs;
    return runOutputWindowsImpl(allocator, argv, stdout_limit);
}

pub fn spawnWindowsPiped(allocator: std.mem.Allocator, argv: []const []const u8, cwd: ?[]const u8) !WindowsPipedChild {
    if (builtin.os.tag != .windows) return error.UnsupportedOs;
    return spawnWindowsPipedImpl(allocator, argv, cwd);
}

pub fn runIgnoreOutput(argv: []const []const u8, environ_map: ?*const std.process.Environ.Map) !std.process.Child.Term {
    const io = runtime.io();
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .environ_map = environ_map,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    defer child.kill(io);
    return child.wait(io);
}

const HANDLE_FLAG_INHERIT: windows.DWORD = 0x00000001;
const INFINITE: windows.DWORD = 0xffffffff;
const WAIT_TIMEOUT: windows.DWORD = 0x00000102;
const WAIT_FAILED: windows.DWORD = 0xffffffff;
const STD_INPUT_HANDLE: windows.DWORD = @bitCast(@as(i32, -10));

extern "kernel32" fn CreatePipe(
    hReadPipe: *windows.HANDLE,
    hWritePipe: *windows.HANDLE,
    lpPipeAttributes: ?*windows.SECURITY_ATTRIBUTES,
    nSize: windows.DWORD,
) callconv(.winapi) windows.BOOL;

extern "kernel32" fn SetHandleInformation(
    hObject: windows.HANDLE,
    dwMask: windows.DWORD,
    dwFlags: windows.DWORD,
) callconv(.winapi) windows.BOOL;

extern "kernel32" fn ReadFile(
    hFile: windows.HANDLE,
    lpBuffer: [*]u8,
    nNumberOfBytesToRead: windows.DWORD,
    lpNumberOfBytesRead: *windows.DWORD,
    lpOverlapped: ?*anyopaque,
) callconv(.winapi) windows.BOOL;

extern "kernel32" fn WaitForSingleObject(
    hHandle: windows.HANDLE,
    dwMilliseconds: windows.DWORD,
) callconv(.winapi) windows.DWORD;

extern "kernel32" fn GetExitCodeProcess(
    hProcess: windows.HANDLE,
    lpExitCode: *windows.DWORD,
) callconv(.winapi) windows.BOOL;

extern "kernel32" fn TerminateProcess(
    hProcess: windows.HANDLE,
    uExitCode: windows.UINT,
) callconv(.winapi) windows.BOOL;

extern "kernel32" fn GetStdHandle(nStdHandle: windows.DWORD) callconv(.winapi) ?windows.HANDLE;

fn runOutputWindowsImpl(allocator: std.mem.Allocator, argv: []const []const u8, stdout_limit: usize) !RunOutputResult {
    if (argv.len == 0) return error.InvalidArgs;

    const command_line = try makeWindowsCommandLine(allocator, argv);
    defer allocator.free(command_line);

    var read_pipe_raw: windows.HANDLE = undefined;
    var write_pipe_raw: windows.HANDLE = undefined;
    var security = windows.SECURITY_ATTRIBUTES{
        .nLength = @sizeOf(windows.SECURITY_ATTRIBUTES),
        .lpSecurityDescriptor = null,
        .bInheritHandle = .TRUE,
    };
    if (CreatePipe(&read_pipe_raw, &write_pipe_raw, &security, 0) == .FALSE) return error.CommandFailed;

    var read_pipe: ?windows.HANDLE = read_pipe_raw;
    var write_pipe: ?windows.HANDLE = write_pipe_raw;
    errdefer if (read_pipe) |handle| windows.CloseHandle(handle);
    errdefer if (write_pipe) |handle| windows.CloseHandle(handle);

    if (SetHandleInformation(read_pipe.?, HANDLE_FLAG_INHERIT, 0) == .FALSE) return error.CommandFailed;

    var startup = std.mem.zeroes(windows.STARTUPINFOW);
    startup.cb = @sizeOf(windows.STARTUPINFOW);
    startup.dwFlags = windows.STARTF_USESTDHANDLES;
    startup.hStdInput = inheritedStdIn();
    startup.hStdOutput = write_pipe;
    startup.hStdError = write_pipe;

    var process_info = std.mem.zeroes(windows.PROCESS.INFORMATION);
    if (windows.kernel32.CreateProcessW(
        null,
        command_line.ptr,
        null,
        null,
        .TRUE,
        .{ .create_no_window = true },
        null,
        null,
        &startup,
        &process_info,
    ) == .FALSE) return error.CommandFailed;

    errdefer _ = TerminateProcess(process_info.hProcess, 1);
    defer windows.CloseHandle(process_info.hProcess);
    defer windows.CloseHandle(process_info.hThread);

    windows.CloseHandle(write_pipe.?);
    write_pipe = null;

    var out = std.Io.Writer.Allocating.init(allocator);
    errdefer out.deinit();
    var total: usize = 0;
    var buf: [8192]u8 = undefined;
    while (true) {
        var bytes_read: windows.DWORD = 0;
        if (ReadFile(read_pipe.?, &buf, buf.len, &bytes_read, null) == .FALSE) break;
        if (bytes_read == 0) break;
        const n: usize = @intCast(bytes_read);
        if (total + n > stdout_limit) return error.StreamTooLong;
        try out.writer.writeAll(buf[0..n]);
        total += n;
    }

    windows.CloseHandle(read_pipe.?);
    read_pipe = null;

    if (WaitForSingleObject(process_info.hProcess, INFINITE) == WAIT_FAILED) return error.CommandFailed;
    var exit_code: windows.DWORD = 1;
    if (GetExitCodeProcess(process_info.hProcess, &exit_code) == .FALSE) return error.CommandFailed;
    const child_exit: u8 = @intCast(@min(exit_code, 255));

    return .{
        .term = .{ .exited = child_exit },
        .stdout = try out.toOwnedSlice(),
    };
}

fn spawnWindowsPipedImpl(allocator: std.mem.Allocator, argv: []const []const u8, cwd: ?[]const u8) !WindowsPipedChild {
    if (argv.len == 0) return error.InvalidArgs;

    const command_line = try makeWindowsCommandLine(allocator, argv);
    defer allocator.free(command_line);
    const cwd_w = if (cwd) |path| try std.unicode.wtf8ToWtf16LeAllocZ(allocator, path) else null;
    defer if (cwd_w) |path| allocator.free(path);

    var stdin_read_raw: windows.HANDLE = undefined;
    var stdin_write_raw: windows.HANDLE = undefined;
    var stdout_read_raw: windows.HANDLE = undefined;
    var stdout_write_raw: windows.HANDLE = undefined;
    var security = windows.SECURITY_ATTRIBUTES{
        .nLength = @sizeOf(windows.SECURITY_ATTRIBUTES),
        .lpSecurityDescriptor = null,
        .bInheritHandle = .TRUE,
    };

    if (CreatePipe(&stdin_read_raw, &stdin_write_raw, &security, 0) == .FALSE) return error.CommandFailed;
    var stdin_read: ?windows.HANDLE = stdin_read_raw;
    const stdin_write = stdin_write_raw;
    errdefer if (stdin_read) |handle| windows.CloseHandle(handle);
    errdefer windows.CloseHandle(stdin_write);

    if (CreatePipe(&stdout_read_raw, &stdout_write_raw, &security, 0) == .FALSE) return error.CommandFailed;
    const stdout_read = stdout_read_raw;
    var stdout_write: ?windows.HANDLE = stdout_write_raw;
    errdefer windows.CloseHandle(stdout_read);
    errdefer if (stdout_write) |handle| windows.CloseHandle(handle);

    if (SetHandleInformation(stdin_write, HANDLE_FLAG_INHERIT, 0) == .FALSE) return error.CommandFailed;
    if (SetHandleInformation(stdout_read, HANDLE_FLAG_INHERIT, 0) == .FALSE) return error.CommandFailed;

    var startup = std.mem.zeroes(windows.STARTUPINFOW);
    startup.cb = @sizeOf(windows.STARTUPINFOW);
    startup.dwFlags = windows.STARTF_USESTDHANDLES;
    startup.hStdInput = stdin_read;
    startup.hStdOutput = stdout_write;
    startup.hStdError = stdout_write;

    var process_info = std.mem.zeroes(windows.PROCESS.INFORMATION);
    if (windows.kernel32.CreateProcessW(
        null,
        command_line.ptr,
        null,
        null,
        .TRUE,
        .{ .create_no_window = true },
        null,
        if (cwd_w) |path| path.ptr else null,
        &startup,
        &process_info,
    ) == .FALSE) return error.CommandFailed;

    windows.CloseHandle(stdin_read.?);
    stdin_read = null;
    windows.CloseHandle(stdout_write.?);
    stdout_write = null;

    return .{
        .stdin = .{ .handle = stdin_write, .flags = .{ .nonblocking = false } },
        .stdout = .{ .handle = stdout_read, .flags = .{ .nonblocking = false } },
        .process = .{ .process = process_info.hProcess, .thread = process_info.hThread },
    };
}

pub fn waitWindowsProcess(process: windows.HANDLE, timeout_ms: u32) bool {
    if (builtin.os.tag != .windows) return true;
    const result = WaitForSingleObject(process, timeout_ms);
    return result != WAIT_FAILED and result != WAIT_TIMEOUT;
}

pub fn terminateWindowsProcess(process: windows.HANDLE, exit_code: u32) void {
    if (builtin.os.tag != .windows) return;
    _ = TerminateProcess(process, exit_code);
}

pub fn closeWindowsProcessHandles(handles: *WindowsProcessHandles) void {
    if (builtin.os.tag != .windows) return;
    windows.CloseHandle(handles.thread);
    windows.CloseHandle(handles.process);
    handles.thread = windows.INVALID_HANDLE_VALUE;
    handles.process = windows.INVALID_HANDLE_VALUE;
}

fn inheritedStdIn() ?windows.HANDLE {
    const handle = GetStdHandle(STD_INPUT_HANDLE) orelse return null;
    if (handle == windows.INVALID_HANDLE_VALUE) return null;
    return handle;
}

fn makeWindowsCommandLine(allocator: std.mem.Allocator, argv: []const []const u8) ![:0]u16 {
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();

    for (argv, 0..) |arg, i| {
        if (i != 0) try out.writer.writeByte(' ');
        try writeWindowsQuotedArg(&out.writer, arg);
    }

    const utf8 = try out.toOwnedSlice();
    defer allocator.free(utf8);
    return std.unicode.wtf8ToWtf16LeAllocZ(allocator, utf8);
}

fn writeWindowsQuotedArg(writer: *std.Io.Writer, arg: []const u8) !void {
    if (!needsWindowsQuotes(arg)) {
        try writer.writeAll(arg);
        return;
    }

    try writer.writeByte('"');
    var backslashes: usize = 0;
    for (arg) |byte| {
        if (byte == '\\') {
            backslashes += 1;
            continue;
        }
        if (byte == '"') {
            try writeRepeatedByte(writer, '\\', backslashes * 2 + 1);
            try writer.writeByte('"');
            backslashes = 0;
            continue;
        }
        try writeRepeatedByte(writer, '\\', backslashes);
        backslashes = 0;
        try writer.writeByte(byte);
    }
    try writeRepeatedByte(writer, '\\', backslashes * 2);
    try writer.writeByte('"');
}

fn needsWindowsQuotes(arg: []const u8) bool {
    return arg.len == 0 or std.mem.indexOfAny(u8, arg, " \t\r\n\x0b\"") != null;
}

fn writeRepeatedByte(writer: *std.Io.Writer, byte: u8, count: usize) !void {
    var i: usize = 0;
    while (i < count) : (i += 1) try writer.writeByte(byte);
}
