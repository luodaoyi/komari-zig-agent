const common = @import("common.zig");
const std = @import("std");

pub fn basicInfo(allocator: std.mem.Allocator) !common.BasicInfo {
    const mem = sysctlInt("hw.physmem") catch 0;
    return .{
        .cpu = .{
            .name = try commandFirstLine(allocator, &.{ "sysctl", "-n", "hw.model" }, "Unknown"),
            .architecture = normalizeArch(@tagName(@import("builtin").cpu.arch)),
            .cores = @intCast(std.Thread.getCpuCount() catch 1),
            .usage = 0.001,
        },
        .os_name = try commandJoin(allocator, &.{ "uname", "-sr" }, "FreeBSD"),
        .kernel_version = try commandFirstLine(allocator, &.{ "uname", "-r" }, ""),
        .mem_total = mem,
        .swap_total = swapTotal(allocator) catch 0,
        .disk_total = (diskInfo(allocator) catch common.DiskInfo{}).total,
        .gpu_name = try gpuName(allocator),
        .virtualization = try commandFirstLine(allocator, &.{ "kenv", "smbios.system.product" }, ""),
    };
}

pub fn snapshot(options: common.SnapshotOptions) !common.Snapshot {
    _ = options;
    return .{
        .cpu = .{ .architecture = normalizeArch(@tagName(@import("builtin").cpu.arch)), .cores = @intCast(std.Thread.getCpuCount() catch 1), .usage = cpuUsage(std.heap.page_allocator) catch 0.001 },
        .ram = memInfo() catch .{},
        .swap = .{ .total = swapTotal(std.heap.page_allocator) catch 0 },
        .load = loadInfo(std.heap.page_allocator) catch .{},
        .disk = diskInfo(std.heap.page_allocator) catch .{},
        .network = networkInfo(std.heap.page_allocator) catch .{},
        .connections = connectionsInfo(std.heap.page_allocator) catch .{},
        .uptime = uptime(std.heap.page_allocator) catch 0,
        .process = processCount(std.heap.page_allocator) catch 0,
    };
}

pub fn diskList(allocator: std.mem.Allocator) ![]common.DiskMount {
    const out = commandOutput(allocator, &.{ "mount", "-p" }) catch return &.{};
    defer allocator.free(out);
    var list: std.ArrayList(common.DiskMount) = .empty;
    var lines = std.mem.splitScalar(u8, out, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        _ = fields.next() orelse continue;
        const mountpoint = fields.next() orelse continue;
        const fstype = fields.next() orelse "";
        try list.append(allocator, .{ .mountpoint = try allocator.dupe(u8, mountpoint), .fstype = try allocator.dupe(u8, fstype) });
    }
    return list.toOwnedSlice(allocator);
}

fn memInfo() !common.MemInfo {
    const total = try sysctlInt("hw.physmem");
    const free = (sysctlInt("vm.stats.vm.v_free_count") catch 0) * (sysctlInt("hw.pagesize") catch 4096);
    return .{ .total = total, .used = if (total >= free) total - free else 0 };
}

fn loadInfo(allocator: std.mem.Allocator) !common.LoadInfo {
    const out = try commandOutput(allocator, &.{ "sysctl", "-n", "vm.loadavg" });
    defer allocator.free(out);
    var fields = std.mem.tokenizeAny(u8, out, " {}\t\n");
    return .{
        .load1 = std.fmt.parseFloat(f64, fields.next() orelse "0") catch 0,
        .load5 = std.fmt.parseFloat(f64, fields.next() orelse "0") catch 0,
        .load15 = std.fmt.parseFloat(f64, fields.next() orelse "0") catch 0,
    };
}

fn diskInfo(allocator: std.mem.Allocator) !common.DiskInfo {
    const out = try commandOutput(allocator, &.{ "df", "-k", "-P" });
    defer allocator.free(out);
    return parseDf(out);
}

fn parseDf(out: []const u8) common.DiskInfo {
    var total = common.DiskInfo{};
    var lines = std.mem.splitScalar(u8, out, '\n');
    _ = lines.next();
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        const fs = fields.next() orelse continue;
        if (!std.mem.startsWith(u8, fs, "/dev/")) continue;
        const blocks = std.fmt.parseInt(u64, fields.next() orelse "0", 10) catch 0;
        const used = std.fmt.parseInt(u64, fields.next() orelse "0", 10) catch 0;
        total.total += blocks * 1024;
        total.used += used * 1024;
    }
    return total;
}

fn networkInfo(allocator: std.mem.Allocator) !common.NetworkInfo {
    const first_out = try commandOutput(allocator, &.{ "netstat", "-ibn" });
    defer allocator.free(first_out);
    const first = parseNetstat(first_out);
    std.Thread.sleep(std.time.ns_per_s);
    const out = try commandOutput(allocator, &.{ "netstat", "-ibn" });
    defer allocator.free(out);
    var current = parseNetstat(out);
    current.up = if (current.totalUp >= first.totalUp) current.totalUp - first.totalUp else 0;
    current.down = if (current.totalDown >= first.totalDown) current.totalDown - first.totalDown else 0;
    return current;
}

fn cpuUsage(allocator: std.mem.Allocator) !f64 {
    const first = try cpuTimes(allocator);
    std.Thread.sleep(std.time.ns_per_s);
    const second = try cpuTimes(allocator);
    if (second.total <= first.total or second.idle < first.idle) return 0.001;
    const total_delta = second.total - first.total;
    const idle_delta = second.idle - first.idle;
    if (total_delta == 0 or idle_delta > total_delta) return 0.001;
    return (@as(f64, @floatFromInt(total_delta - idle_delta)) / @as(f64, @floatFromInt(total_delta))) * 100.0;
}

const CpuTimes = struct { total: u64, idle: u64 };

fn cpuTimes(allocator: std.mem.Allocator) !CpuTimes {
    const out = try commandOutput(allocator, &.{ "sysctl", "-n", "kern.cp_time" });
    defer allocator.free(out);
    var fields = std.mem.tokenizeAny(u8, out, " \t\r\n");
    var vals: [5]u64 = .{0} ** 5;
    var i: usize = 0;
    while (fields.next()) |field| : (i += 1) {
        if (i >= vals.len) break;
        vals[i] = std.fmt.parseInt(u64, field, 10) catch 0;
    }
    var total: u64 = 0;
    for (vals) |v| total += v;
    return .{ .total = total, .idle = vals[4] };
}

fn parseNetstat(out: []const u8) common.NetworkInfo {
    var up: u64 = 0;
    var down: u64 = 0;
    var lines = std.mem.splitScalar(u8, out, '\n');
    _ = lines.next();
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        const name = fields.next() orelse continue;
        if (std.mem.eql(u8, name, "lo0")) continue;
        var vals: [12][]const u8 = undefined;
        var n: usize = 0;
        while (fields.next()) |f| : (n += 1) {
            if (n < vals.len) vals[n] = f;
        }
        if (n < 10) continue;
        down += std.fmt.parseInt(u64, vals[5], 10) catch 0;
        up += std.fmt.parseInt(u64, vals[8], 10) catch 0;
    }
    return .{ .totalUp = up, .totalDown = down };
}

fn connectionsInfo(allocator: std.mem.Allocator) !common.ConnectionInfo {
    const tcp = countLines(allocator, &.{ "sockstat", "-4", "-6", "-P", "tcp" }) catch 0;
    const udp = countLines(allocator, &.{ "sockstat", "-4", "-6", "-P", "udp" }) catch 0;
    return .{ .tcp = tcp, .udp = udp };
}

fn uptime(allocator: std.mem.Allocator) !u64 {
    const out = try commandOutput(allocator, &.{ "sysctl", "-n", "kern.boottime" });
    defer allocator.free(out);
    const sec_pos = std.mem.indexOf(u8, out, "sec = ") orelse return 0;
    var fields = std.mem.tokenizeAny(u8, out[sec_pos + 6 ..], ", ");
    const boot = try std.fmt.parseInt(i64, fields.next() orelse "0", 10);
    const now = std.time.timestamp();
    return if (now > boot) @intCast(now - boot) else 0;
}

fn processCount(allocator: std.mem.Allocator) !u64 {
    return countLines(allocator, &.{ "ps", "-ax", "-o", "pid=" });
}

fn swapTotal(allocator: std.mem.Allocator) !u64 {
    const out = try commandOutput(allocator, &.{ "swapinfo", "-k" });
    defer allocator.free(out);
    var total: u64 = 0;
    var lines = std.mem.splitScalar(u8, out, '\n');
    _ = lines.next();
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        _ = fields.next() orelse continue;
        total += (std.fmt.parseInt(u64, fields.next() orelse "0", 10) catch 0) * 1024;
    }
    return total;
}

fn sysctlInt(name: []const u8) !u64 {
    var buf: [64]u8 = undefined;
    var child = std.process.Child.init(&.{ "sysctl", "-n", name }, std.heap.page_allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    try child.spawn();
    const n = try child.stdout.?.readAll(&buf);
    _ = try child.wait();
    return std.fmt.parseInt(u64, std.mem.trim(u8, buf[0..n], " \t\r\n"), 10);
}

fn gpuName(allocator: std.mem.Allocator) ![]const u8 {
    const out = commandOutput(allocator, &.{ "pciconf", "-lv" }) catch return allocator.dupe(u8, "Unknown");
    defer allocator.free(out);
    var lines = std.mem.splitScalar(u8, out, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r\n");
        if (std.mem.indexOf(u8, line, "VGA") != null or std.mem.indexOf(u8, line, "Display") != null) {
            return allocator.dupe(u8, line);
        }
    }
    return allocator.dupe(u8, "Unknown");
}

fn commandJoin(allocator: std.mem.Allocator, argv: []const []const u8, fallback: []const u8) ![]const u8 {
    return commandFirstLine(allocator, argv, fallback);
}

fn commandFirstLine(allocator: std.mem.Allocator, argv: []const []const u8, fallback: []const u8) ![]const u8 {
    const out = commandOutput(allocator, argv) catch return allocator.dupe(u8, fallback);
    defer allocator.free(out);
    var it = std.mem.splitScalar(u8, out, '\n');
    return allocator.dupe(u8, std.mem.trim(u8, it.next() orelse fallback, " \t\r"));
}

fn commandOutput(allocator: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    var child = std.process.Child.init(argv, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    try child.spawn();
    const stdout = try child.stdout.?.readToEndAlloc(allocator, 256 * 1024);
    errdefer allocator.free(stdout);
    const term = try child.wait();
    if (term != .Exited or term.Exited != 0) return error.CommandFailed;
    return stdout;
}

fn countLines(allocator: std.mem.Allocator, argv: []const []const u8) !u64 {
    const out = try commandOutput(allocator, argv);
    defer allocator.free(out);
    var count: u64 = 0;
    var lines = std.mem.splitScalar(u8, out, '\n');
    while (lines.next()) |line| {
        if (std.mem.trim(u8, line, " \t\r").len != 0) count += 1;
    }
    return count;
}

fn normalizeArch(arch: []const u8) []const u8 {
    if (std.mem.eql(u8, arch, "x86_64")) return "amd64";
    if (std.mem.eql(u8, arch, "aarch64")) return "arm64";
    if (std.mem.eql(u8, arch, "x86")) return "386";
    return arch;
}
