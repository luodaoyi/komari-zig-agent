/// macOS-specific PTY helpers.
const std = @import("std");
const posix = std.posix;
const lib = @import("lib.zig");

extern fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
extern fn tcgetpgrp(fd: c_int) c_int;
extern fn sysctl(name: [*]c_int, namelen: c_uint, oldp: ?*anyopaque, oldlenp: ?*usize, newp: ?*const anyopaque, newlen: usize) c_int;
extern fn proc_pidinfo(pid: c_int, flavor: c_int, arg: u64, buffer: *anyopaque, buffersize: c_int) c_int;
extern fn proc_listpids(type: u32, typeinfo: u32, buffer: ?*anyopaque, buffersize: c_int) c_int;

const MachTimebaseInfo = extern struct { numer: u32, denom: u32 };
extern fn mach_timebase_info(info: *MachTimebaseInfo) c_int;

/// Cached `mach_timebase_info`. On Apple Silicon `mach_absolute_time` runs at
/// 24 MHz (numer=125, denom=3 → 41.667 ns/tick); on Intel macs the timebase is
/// 1:1 ns/tick. Cached lazily — `mach_timebase_info` is a syscall on first call.
var cached_timebase: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

fn machTimebase() MachTimebaseInfo {
    const packed_val = cached_timebase.load(.unordered);
    if (packed_val != 0) {
        return .{
            .numer = @truncate(packed_val >> 32),
            .denom = @truncate(packed_val),
        };
    }
    var info: MachTimebaseInfo = .{ .numer = 1, .denom = 1 };
    _ = mach_timebase_info(&info);
    if (info.denom == 0) info = .{ .numer = 1, .denom = 1 };
    cached_timebase.store((@as(u64, info.numer) << 32) | @as(u64, info.denom), .unordered);
    return info;
}

/// Convert raw `pti_total_user`/`pti_total_system` (mach absolute time units)
/// to microseconds: µs = ticks * numer / (denom * 1000).
fn machTicksToMicros(ticks: u64) u64 {
    const tb = machTimebase();
    // Compute as u128 to avoid overflow on Intel (numer=denom=1, ticks already
    // ns) when ticks approach u64 max. Apple Silicon's numer=125 keeps the
    // intermediate well within u128 range for any realistic CPU time.
    const num: u128 = @as(u128, ticks) * @as(u128, tb.numer);
    const den: u128 = @as(u128, tb.denom) * 1000;
    return @intCast(num / den);
}

/// On macOS there is no execvpe — set environ pointer then execvp.
pub fn execChild(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) void {
    // environ is char**, we cast our const env pointer to match
    const environ: *[*:null]const ?[*:0]const u8 = @extern(*[*:null]const ?[*:0]const u8, .{ .name = "environ" });
    environ.* = envp;
    _ = execvp(file, argv);
}

/// Get PTY name — on macOS, ptsname_r is not available.
/// We return 0 (no name) and let the caller handle it.
pub fn getPtyName(_: c_int, _: *[256]u8) usize {
    return 0;
}

/// Get the foreground process name via sysctl KERN_PROC.
pub fn getProcessName(fd: posix.fd_t, buf: []u8) ?[]const u8 {
    const pgrp = tcgetpgrp(@intCast(fd));
    if (pgrp < 0) return null;

    // sysctl kern.proc.pid.<pgrp>
    const CTL_KERN = 1;
    const KERN_PROC = 14;
    const KERN_PROC_PID = 1;
    var mib = [4]c_int{ CTL_KERN, KERN_PROC, KERN_PROC_PID, pgrp };

    // kinfo_proc is large (~648 bytes on arm64 macOS)
    var info_buf: [720]u8 align(8) = undefined;
    var size: usize = info_buf.len;

    if (sysctl(&mib, 4, &info_buf, &size, null, 0) != 0) return null;
    if (size == 0) return null;

    // p_comm is at offset 243 in kinfo_proc.kp_proc on macOS (both arm64 and x86_64).
    const P_COMM_OFFSET = 243;
    if (size < P_COMM_OFFSET + MAXCOMLEN) return null;

    // Bounded scan — p_comm is at most MAXCOMLEN bytes, avoid reading past buffer
    const comm = info_buf[P_COMM_OFFSET..][0..MAXCOMLEN];
    const len = std.mem.indexOfScalar(u8, comm, 0) orelse MAXCOMLEN;
    if (len == 0 or len > buf.len) return null;

    @memcpy(buf[0..len], comm[0..len]);
    return buf[0..len];
}

// proc_pidinfo flavors (from <sys/proc_info.h>)
const PROC_PIDTASKINFO = 4;
const PROC_PIDVNODEPATHINFO = 9;
const PROC_PIDT_SHORTBSDINFO = 13;

// proc_bsdshortinfo layout — total size 64 bytes:
//   [ 0..  4) pbsi_pid         u32
//   [ 4..  8) pbsi_ppid        u32     ← used for parent walk
//   [ 8.. 12) pbsi_pgid        u32
//   [12.. 16) pbsi_status      u32
//   [16.. 32) pbsi_comm        char[MAXCOMLEN] (16)   ← truncated comm name
//   [32.. 36) pbsi_flags       u32
//   [36.. 40) pbsi_uid         u32
//   [40.. 44) pbsi_gid         u32
//   [44.. 64) {ruid,rgid,svuid,svgid,rfu}
const PROC_SHORTBSDINFO_SIZE = 64;
const PBSI_PPID_OFFSET = 4;
const PBSI_COMM_OFFSET = 16;
const MAXCOMLEN = 16;

// struct proc_taskinfo layout — total size 96 bytes:
//   [ 0..  8) pti_virtual_size       u64
//   [ 8.. 16) pti_resident_size      u64  ← used for rss
//   [16.. 24) pti_total_user         u64  (mach absolute time units)
//   [24.. 32) pti_total_system       u64  (mach absolute time units)
//   [32.. 96) thread/page/fault counters (unused)
//
// Note: pti_total_user/pti_total_system are in mach absolute time units, NOT
// nanoseconds. On Apple Silicon mach_absolute_time runs at 24 MHz (numer=125,
// denom=3 → ~41.667 ns/tick). On Intel macs the timebase is 1:1 ns/tick which
// is why this was easy to get wrong. Always convert via machTicksToMicros().
const PROC_TASKINFO_SIZE = 96;

// struct proc_vnodepathinfo = { pvi_cdir, pvi_rdir } — each a vnode_info_path.
// struct vnode_info_path = { vip_vi: vnode_info(152), vip_path: [MAXPATHLEN]u8 }.
// struct vnode_info      = { vi_stat: vinfo_stat(136), vi_type(4), vi_pad(4), vi_fsid: fsid_t(8) } = 152.
// vinfo_stat breakdown (136 bytes): dev(4) + mode(2) + nlink(2) + ino(8) + uid(4) + gid(4)
//   + 4×(atime/mtime/ctime/birthtime pair of i64) = 64 + size(8) + blocks(8) + blksize(4)
//   + flags(4) + gen(4) + rdev(4) + qspare[2] i64 (16) = 136.
// → Offset of pvi_cdir.vip_path within proc_vnodepathinfo = 152.
// → Total size = 2 × (152 + 1024) = 2352.
const PROC_VNODEPATHINFO_SIZE = 2352;
const VIP_PATH_OFFSET = 152;
const MAXPATHLEN = 1024;

// proc_listpids flavors (from <libproc.h>):
//   PROC_ALL_PIDS=1, PROC_PGRP_ONLY=2, PROC_TTY_ONLY=3, PROC_UID_ONLY=4, PROC_RUID_ONLY=5
const PROC_ALL_PIDS: u32 = 1;

/// Snapshot entry for the pid → ppid tree walk.
const ProcEntry = struct {
    pid: c_int,
    ppid: c_int,
    comm: [MAXCOMLEN]u8,
    comm_len: u8,
};

/// Fetch per-process rss + cpu via PROC_PIDTASKINFO. Returns null if the call
/// fails (process exited) or the layout check fails.
fn taskInfo(pid: c_int) ?struct { rss: u64, user_us: u64, sys_us: u64 } {
    var task_buf: [PROC_TASKINFO_SIZE]u8 align(8) = undefined;
    const rc = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task_buf, PROC_TASKINFO_SIZE);
    if (rc != PROC_TASKINFO_SIZE) return null;
    return .{
        .rss = std.mem.readInt(u64, task_buf[8..16], .little),
        .user_us = machTicksToMicros(std.mem.readInt(u64, task_buf[16..24], .little)),
        .sys_us = machTicksToMicros(std.mem.readInt(u64, task_buf[24..32], .little)),
    };
}

/// Fetch ppid + truncated comm via PROC_PIDT_SHORTBSDINFO. ~60% cheaper than
/// the full PROC_PIDTBSDINFO struct (~216 bytes), and we only need the first
/// 32 bytes here.
fn shortBsdInfo(pid: c_int) ?struct { ppid: c_int, comm: [MAXCOMLEN]u8, comm_len: u8 } {
    var buf: [PROC_SHORTBSDINFO_SIZE]u8 align(8) = undefined;
    const rc = proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &buf, PROC_SHORTBSDINFO_SIZE);
    if (rc != PROC_SHORTBSDINFO_SIZE) return null;

    const ppid = std.mem.readInt(u32, buf[PBSI_PPID_OFFSET..][0..4], .little);
    var comm: [MAXCOMLEN]u8 = undefined;
    @memcpy(&comm, buf[PBSI_COMM_OFFSET..][0..MAXCOMLEN]);
    const comm_len = std.mem.indexOfScalar(u8, &comm, 0) orelse MAXCOMLEN;
    return .{ .ppid = @intCast(ppid), .comm = comm, .comm_len = @intCast(comm_len) };
}

/// Enumerate every pid on the system via proc_listpids(PROC_ALL_PIDS) with
/// buffer-grow retry, then pull ppid + comm for each via SHORTBSDINFO.
fn snapshotProcesses(allocator: std.mem.Allocator) ?[]ProcEntry {
    // proc_listpids returns bytes written. When the result equals the buffer
    // size, the list was probably truncated — retry on the heap with a bigger
    // buffer until the kernel reports fewer bytes than we handed it.
    const stack_cap: usize = 1024;
    var stack_buf: [stack_cap]c_int = undefined;
    var pids: []c_int = stack_buf[0..];
    var heap_pids: ?[]c_int = null;
    defer if (heap_pids) |h| allocator.free(h);

    var got_bytes = proc_listpids(PROC_ALL_PIDS, 0, pids.ptr, @intCast(pids.len * @sizeOf(c_int)));
    if (got_bytes <= 0) return null;

    // proc_listpids only reports bytes written, so an exact-fill is
    // indistinguishable from truncation — retry on a perfectly-fitted buffer.
    // Cap at 65536 pids (256KB on the heap); beyond the cap we accept a
    // truncated view rather than returning null.
    var cap: usize = stack_cap;
    while (@as(usize, @intCast(got_bytes)) >= cap * @sizeOf(c_int) and cap < 65536) {
        const new_cap = cap * 4;
        // Allocate the NEW buffer before freeing the old one, so `pids` never
        // dangles on an OOM.
        const h = allocator.alloc(c_int, new_cap) catch break;
        if (heap_pids) |old| allocator.free(old);
        heap_pids = h;
        pids = h;
        cap = new_cap;
        got_bytes = proc_listpids(PROC_ALL_PIDS, 0, h.ptr, @intCast(h.len * @sizeOf(c_int)));
        if (got_bytes <= 0) return null;
    }

    const num_pids: usize = @intCast(@divTrunc(got_bytes, @sizeOf(c_int)));
    if (num_pids == 0) return null;

    var entries = std.ArrayListUnmanaged(ProcEntry){};
    errdefer entries.deinit(allocator);
    entries.ensureTotalCapacity(allocator, num_pids) catch {};

    for (pids[0..num_pids]) |pid| {
        if (pid <= 0) continue;
        const info = shortBsdInfo(pid) orelse continue;
        entries.append(allocator, .{
            .pid = pid,
            .ppid = info.ppid,
            .comm = info.comm,
            .comm_len = info.comm_len,
        }) catch break;
    }

    return entries.toOwnedSlice(allocator) catch null;
}

/// Get aggregated stats for the leader process and its descendant tree.
/// Snapshots every pid on the system, walks the ppid graph from `leader_pid`,
/// and sums rss + cpu across every transitive descendant (including the
/// leader). Catches background jobs, subshells, and anything else the leader
/// spawned, regardless of pgrp or session juggling. Double-fork daemons that
/// reparent to launchd fall out of the tree (expected — they detached).
pub fn getStats(leader_pid: posix.pid_t, allocator: std.mem.Allocator, cwd_buf: []u8) ?lib.Stats {
    if (leader_pid <= 0) return null;

    // Leader rss + cpu first — gates liveness and keeps the common case (no
    // descendants) cheap (just two proc_pidinfo calls).
    const leader_ti = taskInfo(@intCast(leader_pid)) orelse return null;

    var children = std.ArrayListUnmanaged(lib.ChildStats){};
    errdefer children.deinit(allocator);

    var total_rss: u64 = leader_ti.rss;
    var total_user: u64 = leader_ti.user_us;
    var total_sys: u64 = leader_ti.sys_us;
    var count: u32 = 1;

    // Best-effort descendant aggregation. Any failure along the way falls
    // through to the end of the block — leader-only stats still get returned.
    descendants: {
        const entries = snapshotProcesses(allocator) orelse break :descendants;
        defer allocator.free(entries);
        if (entries.len == 0) break :descendants;

        const marked = allocator.alloc(bool, entries.len) catch break :descendants;
        defer allocator.free(marked);
        @memset(marked, false);

        var leader_idx: ?usize = null;
        for (entries, 0..) |e, i| {
            if (e.pid == leader_pid) {
                leader_idx = i;
                break;
            }
        }
        const li = leader_idx orelse break :descendants;

        var queue = std.ArrayListUnmanaged(usize){};
        defer queue.deinit(allocator);

        marked[li] = true;
        queue.append(allocator, li) catch break :descendants;

        // BFS. For each parent pop, linear-scan for unmarked children. For
        // typical descendant trees (few dozen procs) this is fine.
        var head: usize = 0;
        while (head < queue.items.len) : (head += 1) {
            const parent_pid = entries[queue.items[head]].pid;
            for (entries, 0..) |e, i| {
                if (marked[i]) continue;
                if (e.ppid != parent_pid) continue;
                marked[i] = true;
                queue.append(allocator, i) catch break :descendants;
            }
        }

        for (entries, 0..) |e, i| {
            if (!marked[i]) continue;
            if (e.pid == leader_pid) continue;

            const ti = taskInfo(e.pid) orelse continue;

            var child = lib.ChildStats{
                .pid = e.pid,
                .name = undefined,
                .name_len = 0,
                .rss_bytes = ti.rss,
                .cpu_user_us = ti.user_us,
                .cpu_sys_us = ti.sys_us,
            };
            const nl = @min(e.comm_len, child.name.len);
            if (nl > 0) @memcpy(child.name[0..nl], e.comm[0..nl]);
            child.name_len = @intCast(nl);
            children.append(allocator, child) catch continue;

            total_rss += ti.rss;
            total_user += ti.user_us;
            total_sys += ti.sys_us;
            count += 1;
        }
    }

    // Resolve leader cwd via PROC_PIDVNODEPATHINFO.
    var leader_cwd: ?[]const u8 = null;
    var vpi_buf: [PROC_VNODEPATHINFO_SIZE]u8 align(8) = undefined;
    const vpi_rc = proc_pidinfo(@intCast(leader_pid), PROC_PIDVNODEPATHINFO, 0, &vpi_buf, PROC_VNODEPATHINFO_SIZE);
    if (vpi_rc == PROC_VNODEPATHINFO_SIZE) {
        const path_slice = vpi_buf[VIP_PATH_OFFSET..][0..MAXPATHLEN];
        const len = std.mem.indexOfScalar(u8, path_slice, 0) orelse MAXPATHLEN;
        if (len > 0 and len <= cwd_buf.len) {
            @memcpy(cwd_buf[0..len], path_slice[0..len]);
            leader_cwd = cwd_buf[0..len];
        }
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

/// Raw exit — bypasses libc's exit() and its atexit handlers.
/// After fork, atexit handlers from the parent (Node.js/V8) should not run.
pub fn rawExit(status: u8) noreturn {
    // _exit (not exit) is the POSIX-correct way to terminate a forked child
    std.c._exit(@intCast(status));
}

pub fn resetSignalHandlers() void {
    var sa = std.mem.zeroes(std.c.Sigaction);
    sa.handler = .{ .handler = std.c.SIG.DFL };
    var i: u8 = 1;
    while (i < std.c.NSIG) : (i += 1) {
        if (i == posix.SIG.KILL or i == posix.SIG.STOP) continue;
        _ = std.c.sigaction(i, &sa, null);
    }
}

pub fn closeExcessFds() void {
    // Enumerate /dev/fd to close only open FDs, avoids ~1M close() syscalls via sysconf.
    // TODO: Apple has deprecated getdirentries — zig std.c.getdirentries maps to
    // __getdirentries64 which still works, but may need a fallback if Apple removes it.
    const dir_fd = std.c.open("/dev/fd", .{
        .ACCMODE = .RDONLY,
        .DIRECTORY = true,
        .CLOEXEC = true,
    });
    if (dir_fd < 0) {
        // Last resort: brute-force close FDs 3..255
        var fd: c_int = 3;
        while (fd < 256) : (fd += 1) {
            _ = std.c.close(fd);
        }
        return;
    }
    defer _ = std.c.close(dir_fd);

    var base: i64 = 0;
    var buf: [1024]u8 align(@alignOf(std.c.dirent)) = undefined;
    while (true) {
        const nread = std.c.getdirentries(dir_fd, &buf, buf.len, &base);
        if (nread <= 0) break;

        var offset: usize = 0;
        const end: usize = @intCast(nread);
        while (offset < end) {
            const d: *align(1) const std.c.dirent = @ptrCast(buf[offset..]);
            const reclen: usize = d.reclen;
            if (reclen == 0 or offset + reclen > end) break;
            offset += reclen;

            const fd_num = std.fmt.parseInt(c_int, d.name[0..d.namlen], 10) catch continue;
            if (fd_num > 2 and fd_num != dir_fd) {
                _ = std.c.close(fd_num);
            }
        }
    }
}
