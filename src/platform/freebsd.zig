const common = @import("common.zig");
const std = @import("std");
const netstatic = @import("report_netstatic");
const compat = @import("compat");

const safe_command_path = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin";

var sample_mutex: compat.Mutex = .{};
var previous_network: ?NetworkSample = null;
var previous_cpu: ?CpuTimes = null;

const NetworkSample = struct {
    total_up: u64,
    total_down: u64,
    timestamp_ms: i64,
    include_nics: []const u8,
    exclude_nics: []const u8,
};

/// FreeBSD collectors for system info, disks, and interfaces.
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
    return .{
        .cpu = .{ .architecture = normalizeArch(@tagName(@import("builtin").cpu.arch)), .cores = @intCast(std.Thread.getCpuCount() catch 1), .usage = cpuUsage(std.heap.page_allocator) catch 0.001 },
        .ram = memInfo() catch .{},
        .swap = .{ .total = swapTotal(std.heap.page_allocator) catch 0 },
        .load = loadInfo(std.heap.page_allocator) catch .{},
        .disk = diskInfoWithMountpoints(std.heap.page_allocator, options.include_mountpoints) catch .{},
        .network = networkInfoWithOptions(std.heap.page_allocator, options) catch .{},
        .connections = connectionsInfo(std.heap.page_allocator) catch .{},
        .uptime = uptime(std.heap.page_allocator) catch 0,
        .process = processCount(std.heap.page_allocator) catch 0,
    };
}

pub fn diskList(allocator: std.mem.Allocator) ![]common.DiskMount {
    const out = commandOutput(allocator, &.{ "mount", "-p" }) catch return allocator.alloc(common.DiskMount, 0);
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

pub fn monitoringDiskList(allocator: std.mem.Allocator, include_mountpoints: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    if (include_mountpoints.len != 0) {
        var mounts = std.mem.splitScalar(u8, include_mountpoints, ';');
        while (mounts.next()) |raw| {
            const mountpoint = std.mem.trim(u8, raw, " \t\r\n");
            if (mountpoint.len != 0) try out.append(allocator, try allocator.dupe(u8, mountpoint));
        }
        return out.toOwnedSlice(allocator);
    }
    const disks = try diskList(allocator);
    defer allocator.free(disks);
    for (disks) |disk| {
        try out.append(allocator, try std.fmt.allocPrint(allocator, "{s} ({s})", .{ disk.mountpoint, disk.fstype }));
    }
    return out.toOwnedSlice(allocator);
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
    return diskInfoWithMountpoints(allocator, "");
}

fn diskInfoWithMountpoints(allocator: std.mem.Allocator, include_mountpoints: []const u8) !common.DiskInfo {
    if (include_mountpoints.len != 0) {
        var total = common.DiskInfo{};
        var mounts = std.mem.splitScalar(u8, include_mountpoints, ';');
        while (mounts.next()) |raw_mount| {
            const mountpoint = std.mem.trim(u8, raw_mount, " \t\r\n");
            if (mountpoint.len == 0) continue;
            const usage = diskUsageFromDf(allocator, mountpoint) catch continue;
            total.total += usage.total;
            total.used += usage.used;
        }
        return total;
    }
    const out = try commandOutput(allocator, &.{ "df", "-k", "-P" });
    defer allocator.free(out);
    return parseDf(out);
}

fn diskUsageFromDf(allocator: std.mem.Allocator, mountpoint: []const u8) !common.DiskInfo {
    const out = try commandOutput(allocator, &.{ "df", "-k", "-P", mountpoint });
    defer allocator.free(out);
    var lines = std.mem.splitScalar(u8, out, '\n');
    _ = lines.next();
    const data = lines.next() orelse return error.BadDfOutput;
    var fields = std.mem.tokenizeAny(u8, data, " \t");
    _ = fields.next() orelse return error.BadDfOutput;
    const blocks = try std.fmt.parseInt(u64, fields.next() orelse return error.BadDfOutput, 10);
    const used = try std.fmt.parseInt(u64, fields.next() orelse return error.BadDfOutput, 10);
    return .{ .total = blocks * 1024, .used = used * 1024 };
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
    return networkInfoWithOptions(allocator, .{});
}

fn networkInfoWithOptions(allocator: std.mem.Allocator, options: common.SnapshotOptions) !common.NetworkInfo {
    const out = try commandOutput(allocator, &.{ "netstat", "-ibn" });
    defer allocator.free(out);
    var current = parseNetstatFiltered(out, options.include_nics, options.exclude_nics);
    const now_ms = compat.milliTimestamp();

    sample_mutex.lock();
    defer sample_mutex.unlock();

    if (previous_network) |previous| {
        if (networkSampleMatches(previous, options)) {
            const elapsed_ms: u64 = @intCast(@max(now_ms - previous.timestamp_ms, 0));
            current.up = perSecond(current.totalUp, previous.total_up, elapsed_ms);
            current.down = perSecond(current.totalDown, previous.total_down, elapsed_ms);
        }
    }
    previous_network = .{
        .total_up = current.totalUp,
        .total_down = current.totalDown,
        .timestamp_ms = now_ms,
        .include_nics = options.include_nics,
        .exclude_nics = options.exclude_nics,
    };

    if (options.month_rotate != 0) {
        const totals = netstatic.applyMonthlyTotalsFiltered(std.heap.page_allocator, options.month_rotate, options.include_nics, options.exclude_nics);
        current.totalUp = totals.up;
        current.totalDown = totals.down;
    }
    return current;
}

fn cpuUsage(allocator: std.mem.Allocator) !f64 {
    const current = try cpuTimes(allocator);
    sample_mutex.lock();
    defer sample_mutex.unlock();
    const usage = if (previous_cpu) |previous| cpuUsagePercent(previous, current) else 0.001;
    previous_cpu = current;
    return if (usage <= 0.001) 0.001 else usage;
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

fn cpuUsagePercent(previous: CpuTimes, current: CpuTimes) f64 {
    if (current.total <= previous.total or current.idle < previous.idle) return 0.001;
    const total_delta = current.total - previous.total;
    const idle_delta = current.idle - previous.idle;
    if (total_delta == 0 or idle_delta > total_delta) return 0.001;
    return (@as(f64, @floatFromInt(total_delta - idle_delta)) / @as(f64, @floatFromInt(total_delta))) * 100.0;
}

fn networkSampleMatches(previous: NetworkSample, options: common.SnapshotOptions) bool {
    return std.mem.eql(u8, previous.include_nics, options.include_nics) and
        std.mem.eql(u8, previous.exclude_nics, options.exclude_nics);
}

fn perSecond(current: u64, previous: u64, elapsed_ms: u64) u64 {
    if (current <= previous or elapsed_ms == 0) return 0;
    return ((current - previous) * 1000) / elapsed_ms;
}

fn parseNetstat(out: []const u8) common.NetworkInfo {
    return parseNetstatFiltered(out, "", "");
}

fn parseNetstatFiltered(out: []const u8, include_nics: []const u8, exclude_nics: []const u8) common.NetworkInfo {
    var up: u64 = 0;
    var down: u64 = 0;
    var lines = std.mem.splitScalar(u8, out, '\n');
    _ = lines.next();
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        const name = fields.next() orelse continue;
        if (!shouldIncludeNetworkInterface(name, include_nics, exclude_nics)) continue;
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

pub fn interfaceList(allocator: std.mem.Allocator, include_nics: []const u8, exclude_nics: []const u8) ![]const []const u8 {
    const out_bytes = commandOutput(allocator, &.{ "netstat", "-ibn" }) catch return allocator.alloc([]const u8, 0);
    defer allocator.free(out_bytes);
    var out: std.ArrayList([]const u8) = .empty;
    var seen = std.StringHashMap(void).init(allocator);
    var lines = std.mem.splitScalar(u8, out_bytes, '\n');
    _ = lines.next();
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        const name = fields.next() orelse continue;
        if (!shouldIncludeNetworkInterface(name, include_nics, exclude_nics)) continue;
        if (seen.contains(name)) continue;
        try seen.put(try allocator.dupe(u8, name), {});
        try out.append(allocator, try allocator.dupe(u8, name));
    }
    return out.toOwnedSlice(allocator);
}

pub fn localIpFromInterfaces(allocator: std.mem.Allocator, include_nics: []const u8, exclude_nics: []const u8) !common.LocalIpInfo {
    return localIpFromIfconfig(allocator, include_nics, exclude_nics);
}

fn shouldIncludeNetworkInterface(name: []const u8, include_nics: []const u8, exclude_nics: []const u8) bool {
    const excluded_prefixes = [_][]const u8{ "lo", "br", "cni", "docker", "podman", "flannel", "veth", "virbr", "vmbr", "tap", "fwbr", "fwpr" };
    for (&excluded_prefixes) |prefix| {
        if (std.mem.startsWith(u8, name, prefix)) return false;
    }
    if (include_nics.len != 0) return csvMatches(include_nics, name);
    if (exclude_nics.len != 0 and csvMatches(exclude_nics, name)) return false;
    return true;
}

fn csvMatches(csv: []const u8, needle: []const u8) bool {
    var it = std.mem.splitScalar(u8, csv, ',');
    while (it.next()) |part| {
        if (std.mem.eql(u8, std.mem.trim(u8, part, " \t\r\n"), needle)) return true;
    }
    return false;
}

fn localIpFromIfconfig(allocator: std.mem.Allocator, include_nics: []const u8, exclude_nics: []const u8) !common.LocalIpInfo {
    const out = commandOutput(allocator, &.{"ifconfig"}) catch return .{};
    defer allocator.free(out);
    var ipv4: []const u8 = "";
    var ipv6: []const u8 = "";
    var current: []const u8 = "";
    var allowed = false;
    var lines = std.mem.splitScalar(u8, out, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trimEnd(u8, line_raw, " \t\r");
        if (line.len == 0) continue;
        if (line[0] != ' ' and line[0] != '\t') {
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            current = line[0..colon];
            allowed = shouldIncludeNetworkInterface(current, include_nics, exclude_nics);
            continue;
        }
        if (!allowed) continue;
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        const kind = fields.next() orelse continue;
        if (std.mem.eql(u8, kind, "inet")) {
            const addr = fields.next() orelse continue;
            if (ipv4.len == 0) ipv4 = try allocator.dupe(u8, addr);
        } else if (std.mem.eql(u8, kind, "inet6")) {
            const addr = fields.next() orelse continue;
            if (ipv6.len == 0 and !std.mem.startsWith(u8, addr, "fe80:")) ipv6 = try allocator.dupe(u8, addr);
        }
        if (ipv4.len != 0 and ipv6.len != 0) break;
    }
    return .{ .ipv4 = ipv4, .ipv6 = ipv6 };
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
    const now = compat.unixTimestamp();
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
    const allocator = std.heap.page_allocator;
    const result = try compat.runOutputIgnoreStderr(allocator, &.{ "sysctl", "-n", name }, null, 64);
    defer allocator.free(result.stdout);
    return std.fmt.parseInt(u64, std.mem.trim(u8, result.stdout, " \t\r\n"), 10);
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
    var env = compat.emptyEnvMap(allocator);
    defer env.deinit();
    try env.put("PATH", safe_command_path);
    const result = try compat.runOutputIgnoreStderr(allocator, argv, &env, 256 * 1024);
    errdefer allocator.free(result.stdout);
    if (result.term != .exited or result.term.exited != 0) return error.CommandFailed;
    return result.stdout;
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
