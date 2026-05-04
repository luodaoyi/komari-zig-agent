/// Linux-specific PTY helpers.
const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const linux = std.os.linux;
const lib = @import("lib.zig");

extern fn execvpe(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) c_int;
extern fn ptsname_r(fd: c_int, buf: [*]u8, buflen: usize) c_int;
extern fn tcgetpgrp(fd: c_int) c_int;

// musl dlopen flags (match glibc values)
const RTLD_LAZY = 0x00001;
const RTLD_GLOBAL = 0x00100;
extern fn dlopen(filename: ?[*:0]const u8, flags: c_int) ?*anyopaque;

/// Execute a child process, searching PATH if needed.
/// Uses musl's execvpe for PATH resolution, with a fallback that invokes
/// the ELF interpreter directly to bypass noexec mounts
/// (required on Android/Termux where /data/data is mounted noexec).
pub fn execChild(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) void {
    _ = execvpe(file, argv, envp);
    // Only attempt the linker fallback on EACCES from noexec mounts (Android/Termux).
    // Distinguish noexec EACCES from permission EACCES: if the file has +x but
    // execve still returned EACCES, the mount must be noexec.
    if (std.c._errno().* == @intFromEnum(std.c.E.ACCES)) {
        const file_slice = std.mem.sliceTo(file, 0);
        const resolved = if (std.mem.indexOfScalar(u8, file_slice, '/') != null)
            file
        else
            resolveInPath(file_slice, envp) orelse return;
        // If the file is executable (+x) but execve failed, it must be a noexec mount
        if (isExecutable(resolved)) {
            execveLinkerFallback(resolved, argv, envp);
        }
    }
}

/// Bypass noexec mount restrictions by invoking the dynamic linker directly.
/// On Android/Termux, /data/data is mounted noexec. termux-exec works around this
/// by calling execve("/system/bin/linker64", [argv0, "/path/to/binary", ...args], envp)
/// — the linker lives on /system (not noexec) and loads the target binary itself.
fn execveLinkerFallback(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) void {
    // Read ELF interpreter from the binary's PT_INTERP header
    var interp_buf: [256]u8 = undefined;
    const interp = readElfInterp(file, &interp_buf) orelse return;

    // Build new argv: [original_argv0, file, original_argv1..]
    // Stack-allocate space for the new argv (max 256 args)
    var new_argv: [258]?[*:0]const u8 = undefined;
    new_argv[0] = argv[0]; // preserve argv[0] (program name)
    new_argv[1] = file; // linker needs the binary path as first real arg

    var i: usize = 1;
    while (i < new_argv.len - 2) : (i += 1) {
        const arg = argv[i];
        new_argv[i + 1] = arg;
        if (arg == null) break;
    }
    if (i >= new_argv.len - 2) new_argv[new_argv.len - 1] = null;

    const new_argv_ptr: [*:null]const ?[*:0]const u8 = @ptrCast(&new_argv);
    _ = linux.execve(interp, new_argv_ptr, envp);
}

/// Seek within an ELF file without instantiating Zig 0.16's linux.lseek wrapper on
/// 32-bit targets, where its offset bitcast currently fails to compile.
fn seek(fd: i32, offset: u64) std.posix.E {
    if (@sizeOf(usize) == 4 and offset > std.math.maxInt(usize)) return .OVERFLOW;
    const rc = linux.syscall3(.lseek, @as(usize, @bitCast(@as(isize, fd))), @intCast(offset), linux.SEEK.SET);
    return std.posix.errno(rc);
}

/// Read the PT_INTERP (dynamic linker path) from an ELF binary.
fn readElfInterp(file: [*:0]const u8, buf: *[256]u8) ?[*:0]const u8 {
    const fd_rc = linux.open(file, .{ .ACCMODE = .RDONLY }, 0);
    if (std.posix.errno(fd_rc) != .SUCCESS) return null;
    defer _ = linux.close(@intCast(fd_rc));
    const fd: i32 = @intCast(fd_rc);

    // Read ELF header
    var ehdr: [64]u8 = undefined;
    const n = linux.read(fd, &ehdr, 64);
    if (std.posix.errno(n) != .SUCCESS or n < 64) return null;

    // Verify ELF magic
    if (ehdr[0] != 0x7f or ehdr[1] != 'E' or ehdr[2] != 'L' or ehdr[3] != 'F') return null;

    const is_64 = ehdr[4] == 2;
    if (!is_64) return null; // Only support 64-bit

    // Parse e_phoff, e_phentsize, e_phnum from ELF64 header
    const e_phoff: u64 = std.mem.readInt(u64, ehdr[32..40], .little);
    const e_phentsize: u16 = std.mem.readInt(u16, ehdr[54..56], .little);
    const e_phnum: u16 = std.mem.readInt(u16, ehdr[56..58], .little);

    // Scan program headers for PT_INTERP (type = 3)
    var ph_buf: [56]u8 = undefined; // ELF64 phdr is 56 bytes
    var idx: u16 = 0;
    while (idx < e_phnum) : (idx += 1) {
        const off = e_phoff + @as(u64, idx) * e_phentsize;
        if (seek(fd, off) != .SUCCESS) continue;
        const pn = linux.read(fd, &ph_buf, @min(e_phentsize, 56));
        if (std.posix.errno(pn) != .SUCCESS or pn < 56) continue;

        const p_type = std.mem.readInt(u32, ph_buf[0..4], .little);
        if (p_type != 3) continue; // PT_INTERP = 3

        const p_offset: u64 = std.mem.readInt(u64, ph_buf[8..16], .little);
        const p_filesz: u64 = std.mem.readInt(u64, ph_buf[32..40], .little);
        if (p_filesz == 0 or p_filesz > buf.len) return null;

        if (seek(fd, p_offset) != .SUCCESS) return null;
        const rn = linux.read(fd, buf, @intCast(p_filesz));
        if (std.posix.errno(rn) != .SUCCESS or rn < p_filesz) return null;

        // Ensure null-terminated
        const len: usize = @intCast(p_filesz);
        if (buf[len - 1] == 0) {
            return @ptrCast(buf[0 .. len - 1 :0]);
        }
        if (len < buf.len) {
            buf[len] = 0;
            return @ptrCast(buf[0..len :0]);
        }
        return null;
    }
    return null;
}

/// Check if a file has executable permission (but may be on a noexec mount).
fn isExecutable(path: [*:0]const u8) bool {
    return std.posix.errno(linux.faccessat(linux.AT.FDCWD, path, linux.X_OK, 0)) == .SUCCESS;
}

/// Resolve a command name to a full path by searching PATH from envp.
/// Uses a static buffer — returned pointer is valid until next call.
var resolve_buf: [std.fs.max_path_bytes]u8 = undefined;
fn resolveInPath(file: []const u8, envp: [*:null]const ?[*:0]const u8) ?[*:0]const u8 {
    const path_env = getEnvFromEnvp(envp, "PATH") orelse return null;
    var it = std.mem.splitScalar(u8, path_env, ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        if (dir.len + 1 + file.len + 1 > resolve_buf.len) continue;
        @memcpy(resolve_buf[0..dir.len], dir);
        resolve_buf[dir.len] = '/';
        @memcpy(resolve_buf[dir.len + 1 ..][0..file.len], file);
        resolve_buf[dir.len + 1 + file.len] = 0;
        const full: [*:0]const u8 = @ptrCast(resolve_buf[0 .. dir.len + 1 + file.len :0]);
        // Check if the file exists and is executable
        if (std.posix.errno(linux.faccessat(linux.AT.FDCWD, full, linux.X_OK, 0)) == .SUCCESS) {
            return full;
        }
    }
    return null;
}

/// Extract a value from a null-terminated envp array.
fn getEnvFromEnvp(envp: [*:null]const ?[*:0]const u8, key: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (envp[i]) |entry| : (i += 1) {
        const entry_slice = std.mem.sliceTo(entry, 0);
        if (entry_slice.len > key.len and
            entry_slice[key.len] == '=' and
            std.mem.eql(u8, entry_slice[0..key.len], key))
        {
            return entry_slice[key.len + 1 ..];
        }
    }
    return null;
}

pub fn getPtyName(fd: c_int, buf: *[256]u8) usize {
    if (ptsname_r(fd, buf, buf.len) == 0) {
        return std.mem.indexOfScalar(u8, buf, 0) orelse buf.len;
    }
    return 0;
}

/// Get the foreground process name via /proc/{pgrp}/cmdline.
pub fn getProcessName(fd: posix.fd_t, buf: []u8) ?[]const u8 {
    const pgrp = tcgetpgrp(@intCast(fd));
    if (pgrp < 0) return null;

    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/cmdline", .{pgrp}) catch return null;

    const file_handle = std.fs.openFileAbsolute(path, .{}) catch return null;
    defer file_handle.close();

    const bytes_read = file_handle.read(buf) catch return null;
    if (bytes_read == 0) return null;

    const cmd = std.mem.sliceTo(buf[0..bytes_read], 0);
    return if (std.mem.lastIndexOfScalar(u8, cmd, '/')) |p| cmd[p + 1 ..] else cmd;
}

/// Parsed fields from /proc/<pid>/stat. `comm` is copied into a fixed buffer
/// so the source read buffer can be reused for the next pid.
const ProcStat = struct {
    ppid: posix.pid_t,
    comm: [16]u8,
    comm_len: u8,
    utime_ticks: u64,
    stime_ticks: u64,
    rss_pages: u64,
};

/// Snapshot entry for the pid → ppid tree walk.
const ProcEntry = struct {
    pid: posix.pid_t,
    stat: ProcStat,
};

/// Get aggregated stats for the leader process and its descendant tree.
/// Walks /proc once, builds a pid/ppid index, BFS from `leader_pid`, and
/// sums rss + cpu across every transitive descendant (including the leader).
/// Catches background jobs, subshells, and anything else the leader spawned,
/// regardless of pgrp/session/job-control juggling. Double-fork daemons that
/// reparent to init fall out of the tree (expected — they detached).
pub fn getStats(leader_pid: posix.pid_t, allocator: std.mem.Allocator, cwd_buf: []u8) ?lib.Stats {
    if (leader_pid <= 0) return null;

    const clk_tck: u64 = 100;
    const page_size = getPageSize();

    // Leader cwd — readlink on /proc/<pid>/cwd. Used as a liveness gate too:
    // if this fails the process is probably gone, but we still try the walk
    // since the child could have reparented.
    var leader_cwd: ?[]const u8 = null;
    var path_buf: [64]u8 = undefined;
    if (std.fmt.bufPrint(&path_buf, "/proc/{d}/cwd", .{leader_pid})) |cwd_path| {
        if (std.posix.readlink(cwd_path, cwd_buf)) |link| {
            if (link.len > 0) leader_cwd = link;
        } else |_| {}
    } else |_| {}

    // Snapshot every pid + its stat row once, so the BFS can look up ppid
    // relationships without re-reading /proc.
    var entries = std.ArrayListUnmanaged(ProcEntry){};
    defer entries.deinit(allocator);

    var dir = std.fs.openDirAbsolute("/proc", .{ .iterate = true }) catch return null;
    defer dir.close();

    var it = dir.iterate();
    while (true) {
        const entry = (it.next() catch break) orelse break;
        // Don't filter by entry.kind — procfs can return .unknown depending on
        // the kernel/mount. parseInt on the name is enough to skip non-pid dirs.
        const pid = std.fmt.parseInt(posix.pid_t, entry.name, 10) catch continue;

        const stat_path = std.fmt.bufPrint(&path_buf, "/proc/{d}/stat", .{pid}) catch continue;
        const f = std.fs.openFileAbsolute(stat_path, .{}) catch continue;
        defer f.close();

        var stat_buf: [1024]u8 = undefined;
        const n = f.read(&stat_buf) catch continue;
        if (n == 0) continue;

        const ps = parseProcStat(stat_buf[0..n]) orelse continue;
        entries.append(allocator, .{ .pid = pid, .stat = ps }) catch break;
    }

    if (entries.items.len == 0) return null;

    // Find the leader in the snapshot. If it's gone, bail.
    var leader_idx: ?usize = null;
    for (entries.items, 0..) |e, i| {
        if (e.pid == leader_pid) {
            leader_idx = i;
            break;
        }
    }
    const li = leader_idx orelse return null;

    // BFS by ppid. `marked[i] == true` ⇒ entry i is the leader or a
    // transitive descendant.
    const marked = allocator.alloc(bool, entries.items.len) catch return null;
    defer allocator.free(marked);
    @memset(marked, false);

    var queue = std.ArrayListUnmanaged(usize){};
    defer queue.deinit(allocator);

    marked[li] = true;
    queue.append(allocator, li) catch return null;

    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const parent_pid = entries.items[queue.items[head]].pid;
        for (entries.items, 0..) |e, i| {
            if (marked[i]) continue;
            if (e.stat.ppid != parent_pid) continue;
            marked[i] = true;
            queue.append(allocator, i) catch break;
        }
    }

    var children = std.ArrayListUnmanaged(lib.ChildStats){};
    errdefer children.deinit(allocator);

    var total_rss: u64 = 0;
    var total_user: u64 = 0;
    var total_sys: u64 = 0;
    var count: u32 = 0;

    for (entries.items, 0..) |e, i| {
        if (!marked[i]) continue;
        const ps = e.stat;

        const rss_bytes = ps.rss_pages * page_size;
        const cpu_user_us = (ps.utime_ticks * 1_000_000) / clk_tck;
        const cpu_sys_us = (ps.stime_ticks * 1_000_000) / clk_tck;

        total_rss += rss_bytes;
        total_user += cpu_user_us;
        total_sys += cpu_sys_us;
        count += 1;

        if (e.pid == leader_pid) continue;

        var child = lib.ChildStats{
            .pid = e.pid,
            .name = undefined,
            .name_len = 0,
            .rss_bytes = rss_bytes,
            .cpu_user_us = cpu_user_us,
            .cpu_sys_us = cpu_sys_us,
        };
        const nl = @min(@as(usize, ps.comm_len), child.name.len);
        if (nl > 0) @memcpy(child.name[0..nl], ps.comm[0..nl]);
        child.name_len = @intCast(nl);
        children.append(allocator, child) catch continue;
    }

    if (count == 0) {
        children.deinit(allocator);
        return null;
    }

    const owned = children.toOwnedSlice(allocator) catch blk: {
        children.deinit(allocator);
        break :blk &[_]lib.ChildStats{};
    };
    return lib.Stats{
        .pid = leader_pid,
        .cwd = leader_cwd,
        .rss_bytes = total_rss,
        .cpu_user_us = total_user,
        .cpu_sys_us = total_sys,
        .count = count,
        .children = owned,
    };
}

/// Parse /proc/<pid>/stat. Format: `pid (comm) state ppid pgrp ...`
/// comm can contain spaces/parens, so we skip to the LAST ')' then count fields.
fn parseProcStat(buf: []const u8) ?ProcStat {
    const first_paren = std.mem.indexOfScalar(u8, buf, '(') orelse return null;
    const last_paren = std.mem.lastIndexOfScalar(u8, buf, ')') orelse return null;
    if (last_paren <= first_paren or last_paren + 2 >= buf.len) return null;

    const comm_src = buf[first_paren + 1 .. last_paren];

    var result = ProcStat{
        .ppid = -1,
        .comm = undefined,
        .comm_len = 0,
        .utime_ticks = 0,
        .stime_ticks = 0,
        .rss_pages = 0,
    };
    // Copy comm out of the source buffer so the caller can reuse it.
    const copy_len = @min(comm_src.len, result.comm.len);
    if (copy_len > 0) @memcpy(result.comm[0..copy_len], comm_src[0..copy_len]);
    result.comm_len = @intCast(copy_len);

    // Fields after last ')': state(0) ppid(1) pgrp(2) session(3) tty_nr(4)
    //   tpgid(5) flags(6) minflt(7) cminflt(8) majflt(9) cmajflt(10)
    //   utime(11) stime(12) cutime(13) cstime(14) priority(15) nice(16)
    //   num_threads(17) itrealvalue(18) starttime(19) vsize(20) rss(21)
    var it = std.mem.tokenizeScalar(u8, buf[last_paren + 2 ..], ' ');
    var idx: usize = 0;
    while (it.next()) |field| : (idx += 1) {
        switch (idx) {
            1 => result.ppid = std.fmt.parseInt(posix.pid_t, field, 10) catch return null,
            11 => result.utime_ticks = std.fmt.parseInt(u64, field, 10) catch 0,
            12 => result.stime_ticks = std.fmt.parseInt(u64, field, 10) catch 0,
            21 => {
                result.rss_pages = std.fmt.parseInt(u64, field, 10) catch return null;
                return result;
            },
            else => {},
        }
    }
    return null;
}

var cached_page_size: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

/// Resolve page size via AT_PAGESZ in /proc/self/auxv. Avoids sysconf's SC-constant
/// mismatch on Android and handles ARM64 16K pages correctly.
fn getPageSize() u64 {
    const cached = cached_page_size.load(.unordered);
    if (cached != 0) return cached;

    const size = parseAuxvPageSize() orelse 4096;
    cached_page_size.store(size, .unordered);
    return size;
}

fn parseAuxvPageSize() ?u64 {
    const AT_NULL: usize = 0;
    const AT_PAGESZ: usize = 6;

    const f = std.fs.openFileAbsolute("/proc/self/auxv", .{}) catch return null;
    defer f.close();

    var buf: [1024]u8 = undefined;
    const n = f.read(&buf) catch return null;

    // auxv entries are stored in the target's native endianness, not a fixed one.
    const endian = builtin.cpu.arch.endian();
    const entry_size = @sizeOf(usize) * 2;
    var i: usize = 0;
    while (i + entry_size <= n) : (i += entry_size) {
        const key = std.mem.readInt(usize, buf[i..][0..@sizeOf(usize)], endian);
        const val = std.mem.readInt(usize, buf[i + @sizeOf(usize) ..][0..@sizeOf(usize)], endian);
        if (key == AT_NULL) return null;
        if (key == AT_PAGESZ) return val;
    }
    return null;
}

/// Ensure libtermux-exec.so is loaded on Termux/Android.
/// This library installs a SIGSYS handler for seccomp softfail — without it,
/// syscalls like close_range (kernel <5.9) trigger SECCOMP_RET_TRAP which
/// kills the process with signal 31 (SIGSYS). Loading it in the parent
/// ensures forked children inherit the handler before exec.
/// Uses bare name so the dynamic linker resolves via LD_LIBRARY_PATH and
/// default search paths. On non-Termux Linux, fails silently.
var termux_exec_loaded = std.atomic.Value(bool).init(false);
pub fn ensureTermuxExec() void {
    if (termux_exec_loaded.cmpxchgStrong(false, true, .acq_rel, .acquire) != null) return;
    _ = dlopen("libtermux-exec.so", RTLD_LAZY | RTLD_GLOBAL);
}

/// Raw exit — bypasses musl's exit() and its atexit handlers.
/// After fork in a mixed musl/Bionic process (Android), musl's exit()
/// can hang because atexit handlers registered by Node.js/V8 expect
/// Bionic's libc state. Uses _exit() which bypasses atexit handlers
/// while going through the proper libc syscall path (required on
/// Android where seccomp blocks direct syscall instructions).
pub fn rawExit(status: u8) noreturn {
    std.c._exit(@intCast(status));
}

pub fn resetSignalHandlers() void {
    var sa = std.mem.zeroes(linux.Sigaction);
    sa.handler = .{ .handler = linux.SIG.DFL };
    var i: u8 = 1;
    while (i < linux.NSIG) : (i += 1) {
        const sig: linux.SIG = @enumFromInt(i);
        if (sig == linux.SIG.KILL or sig == linux.SIG.STOP) continue;
        // Keep SIGSYS handler for Android seccomp softfail.
        // ensureTermuxExec() loads libtermux-exec.so before fork, which
        // installs a SIGSYS handler that converts SECCOMP_RET_TRAP to
        // ENOSYS. We must preserve it so closeExcessFds() can safely
        // attempt close_range on older kernels.
        if (sig == linux.SIG.SYS) continue;
        _ = linux.sigaction(sig, &sa, null);
    }
}

pub fn closeExcessFds() void {
    // Try close_range syscall directly (Linux 5.9+, avoids libc dependency).
    // On Android, ensureTermuxExec() must be called before fork so the
    // child inherits libtermux-exec.so's SIGSYS handler — without it,
    // seccomp kills the process instead of returning ENOSYS.
    const rc = linux.syscall3(.close_range, 3, std.math.maxInt(c_uint), 0);
    if (std.posix.errno(rc) == .SUCCESS) return;

    // Fallback: raw getdents64 on /proc/self/fd (no allocator, async-signal-safe)
    const dir_fd = linux.open("/proc/self/fd", .{ .DIRECTORY = true, .CLOEXEC = true }, 0);
    if (std.posix.errno(dir_fd) != .SUCCESS) {
        // Last resort: brute-force close FDs 3..256
        var fd: c_int = 3;
        while (fd < 256) : (fd += 1) _ = linux.close(@intCast(fd));
        return;
    }
    defer _ = linux.close(@intCast(dir_fd));

    var buf: [1024]u8 = undefined;
    while (true) {
        const nread = linux.getdents64(@intCast(dir_fd), @ptrCast(&buf), buf.len);
        if (std.posix.errno(nread) != .SUCCESS or nread == 0) break;

        var offset: usize = 0;
        while (offset < nread) {
            const d: *align(1) const linux.dirent64 = @ptrCast(buf[offset..]);
            offset += d.reclen;

            // Parse fd number from name (null-terminated after fixed fields)
            const name_ptr: [*:0]const u8 = @ptrCast(&d.name);
            const fd_num = std.fmt.parseInt(posix.fd_t, std.mem.sliceTo(name_ptr, 0), 10) catch continue;
            if (fd_num > 2 and fd_num != @as(posix.fd_t, @intCast(dir_fd))) {
                _ = linux.close(@intCast(fd_num));
            }
        }
    }
}
