const std = @import("std");
const common = @import("common.zig");
const netstatic = @import("report_netstatic");

var previous_network: ?NetworkSample = null;
var previous_cpu: ?CpuStat = null;

const NetworkSample = struct {
    total_up: u64,
    total_down: u64,
    timestamp_ms: i64,
};

pub const CpuStat = struct {
    idle: u64,
    total: u64,
};

pub fn basicInfo(allocator: std.mem.Allocator) !common.BasicInfo {
    var info = common.BasicInfo{
        .cpu = .{
            .name = try cpuName(allocator),
            .architecture = normalizeArch(@tagName(@import("builtin").cpu.arch)),
            .cores = @intCast(try std.Thread.getCpuCount()),
            .usage = 0.001,
        },
        .os_name = try osName(allocator),
        .kernel_version = try readFirstLine(allocator, "/proc/sys/kernel/osrelease"),
        .mem_total = (try memInfo()).total,
        .swap_total = (try swapInfo()).total,
        .disk_total = (try diskInfo()).total,
        .gpu_name = try gpuName(allocator),
        .virtualization = try virtualization(allocator),
    };
    fillLocalIp(allocator, &info) catch {};
    return info;
}

pub fn snapshot(options: common.SnapshotOptions) !common.Snapshot {
    const mem = try memInfoWithOptions(options);
    const swap = try swapInfoWithRoot(options.host_proc);
    return .{
        .cpu = .{ .architecture = normalizeArch(@tagName(@import("builtin").cpu.arch)), .cores = @intCast(try std.Thread.getCpuCount()), .usage = try cpuUsage(options.host_proc) },
        .ram = mem,
        .swap = swap,
        .load = try loadInfo(options.host_proc),
        .disk = try diskInfoWithMountpoints(options.include_mountpoints),
        .network = try networkInfo(options),
        .connections = try connectionsInfo(options.host_proc),
        .uptime = try uptime(options.host_proc),
        .process = try processCount(options.host_proc),
        .gpu_json = if (options.enable_gpu) detailedGpuJson(std.heap.page_allocator) catch "" else "",
    };
}

pub fn normalizeArch(arch: []const u8) []const u8 {
    if (std.mem.eql(u8, arch, "x86_64")) return "amd64";
    if (std.mem.eql(u8, arch, "aarch64")) return "arm64";
    if (std.mem.eql(u8, arch, "x86")) return "386";
    if (std.mem.eql(u8, arch, "i386")) return "386";
    if (std.mem.eql(u8, arch, "arm")) return "arm";
    return arch;
}

pub fn parseOsReleaseName(allocator: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    var id_value: ?[]const u8 = null;
    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (std.mem.startsWith(u8, line, "PRETTY_NAME=")) {
            const value = trimOsReleaseValue(line["PRETTY_NAME=".len..]);
            if (value.len != 0) return allocator.dupe(u8, value);
        }
        if (std.mem.startsWith(u8, line, "ID=")) {
            const value = trimOsReleaseValue(line["ID=".len..]);
            if (value.len != 0) id_value = value;
        }
    }
    if (id_value) |value| return allocator.dupe(u8, value);
    return allocator.dupe(u8, "Linux");
}

fn trimOsReleaseValue(value: []const u8) []const u8 {
    return std.mem.trim(u8, value, " \t\r\"");
}

fn osName(allocator: std.mem.Allocator) ![]const u8 {
    const bytes = std.fs.cwd().readFileAlloc(allocator, "/etc/os-release", 64 * 1024) catch return allocator.dupe(u8, "Linux");
    defer allocator.free(bytes);
    return parseOsReleaseName(allocator, bytes);
}

pub fn detectContainerFromCgroup(bytes: []const u8) []const u8 {
    if (std.mem.indexOf(u8, bytes, "/docker/") != null or
        std.mem.indexOf(u8, bytes, "/docker-") != null or
        std.mem.indexOf(u8, bytes, "/cri-containerd/") != null)
    {
        return "docker";
    }
    if (std.mem.indexOf(u8, bytes, "/libpod-") != null or
        std.mem.indexOf(u8, bytes, "/podman-") != null)
    {
        return "podman";
    }
    if (std.mem.indexOf(u8, bytes, "/kubepods") != null) return "kubernetes";
    if (std.mem.indexOf(u8, bytes, "/lxc/") != null) return "lxc";
    return "";
}

fn virtualization(allocator: std.mem.Allocator) ![]const u8 {
    if (fileExists("/.dockerenv")) return allocator.dupe(u8, "docker");
    if (fileExists("/run/.containerenv")) return allocator.dupe(u8, "container");

    const cgroup = std.fs.cwd().readFileAlloc(allocator, "/proc/self/cgroup", 256 * 1024) catch "";
    if (cgroup.len != 0) {
        defer allocator.free(cgroup);
        const detected = detectContainerFromCgroup(cgroup);
        if (detected.len != 0) return allocator.dupe(u8, detected);
    }

    const product = try readFirstLine(allocator, "/sys/class/dmi/id/product_name");
    defer allocator.free(product);
    const lower = try std.ascii.allocLowerString(allocator, product);
    defer allocator.free(lower);
    if (std.mem.indexOf(u8, lower, "kvm") != null) return allocator.dupe(u8, "kvm");
    if (std.mem.indexOf(u8, lower, "vmware") != null) return allocator.dupe(u8, "vmware");
    if (std.mem.indexOf(u8, lower, "virtualbox") != null) return allocator.dupe(u8, "oracle");
    if (std.mem.indexOf(u8, lower, "hyper-v") != null) return allocator.dupe(u8, "microsoft");
    return allocator.dupe(u8, "none");
}

fn fileExists(path: []const u8) bool {
    const stat = std.fs.cwd().statFile(path) catch return false;
    return stat.kind == .file;
}

fn gpuName(allocator: std.mem.Allocator) ![]const u8 {
    if (commandOutputFirstLine(allocator, &.{ "nvidia-smi", "--query-gpu=name", "--format=csv,noheader" })) |line| {
        if (line.len != 0) return line;
        allocator.free(line);
    } else |_| {}
    if (commandOutputFirstLine(allocator, &.{ "rocm-smi", "--showproductname" })) |line| {
        if (line.len != 0) return line;
        allocator.free(line);
    } else |_| {}
    return allocator.dupe(u8, "");
}

fn detailedGpuJson(allocator: std.mem.Allocator) ![]const u8 {
    if (nvidiaDetailedGpuJson(allocator)) |json| return json else |_| {}
    if (amdDetailedGpuJson(allocator)) |json| return json else |_| {}
    return error.NoGpuDetails;
}

fn nvidiaDetailedGpuJson(allocator: std.mem.Allocator) ![]const u8 {
    const output = try commandOutput(allocator, &.{ "nvidia-smi", "--query-gpu=name,memory.total,memory.used,utilization.gpu,temperature.gpu", "--format=csv,noheader,nounits" });
    defer allocator.free(output);
    var detail: std.ArrayList(u8) = .empty;
    defer detail.deinit(allocator);
    var count: u64 = 0;
    var usage_sum: f64 = 0;
    try detail.append(allocator, '[');
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        var fields = std.mem.splitScalar(u8, line, ',');
        const name = std.mem.trim(u8, fields.next() orelse "", " \t");
        const mem_total = (std.fmt.parseInt(u64, std.mem.trim(u8, fields.next() orelse "0", " \t"), 10) catch 0) * 1024 * 1024;
        const mem_used = (std.fmt.parseInt(u64, std.mem.trim(u8, fields.next() orelse "0", " \t"), 10) catch 0) * 1024 * 1024;
        const util = std.fmt.parseFloat(f64, std.mem.trim(u8, fields.next() orelse "0", " \t")) catch 0;
        const temp = std.fmt.parseInt(u64, std.mem.trim(u8, fields.next() orelse "0", " \t"), 10) catch 0;
        if (count != 0) try detail.append(allocator, ',');
        try detail.writer(allocator).print("{{\"name\":{f},\"memory_total\":{d},\"memory_used\":{d},\"utilization\":{d},\"temperature\":{d}}}", .{ std.json.fmt(name, .{}), mem_total, mem_used, util, temp });
        usage_sum += util;
        count += 1;
    }
    try detail.append(allocator, ']');
    if (count == 0) return error.NoGpuDetails;
    return std.fmt.allocPrint(allocator, "{{\"count\":{d},\"average_usage\":{d},\"detailed_info\":{s}}}", .{ count, usage_sum / @as(f64, @floatFromInt(count)), detail.items });
}

fn amdDetailedGpuJson(allocator: std.mem.Allocator) ![]const u8 {
    const output = try commandOutput(allocator, &.{ "rocm-smi", "--showproductname", "--showuse", "--showmeminfo", "vram", "--showtemp", "--json" });
    defer allocator.free(output);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, output, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.NoGpuDetails;
    var detail: std.ArrayList(u8) = .empty;
    defer detail.deinit(allocator);
    var count: u64 = 0;
    var usage_sum: f64 = 0;
    try detail.append(allocator, '[');
    var it = parsed.value.object.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* != .object) continue;
        const obj = entry.value_ptr.object;
        const name = jsonString(obj.get("Card series")) orelse jsonString(obj.get("Card model")) orelse entry.key_ptr.*;
        const util = parsePercent(jsonString(obj.get("GPU use (%)")) orelse "0");
        const mem_total = parseMiB(jsonString(obj.get("VRAM Total Memory (B)")) orelse jsonString(obj.get("VRAM Total Used Memory (B)")) orelse "0");
        const mem_used = parseMiB(jsonString(obj.get("VRAM Total Used Memory (B)")) orelse "0");
        const temp = @as(u64, @intFromFloat(parsePercent(jsonString(obj.get("Temperature (Sensor edge) (C)")) orelse "0")));
        if (count != 0) try detail.append(allocator, ',');
        try detail.writer(allocator).print("{{\"name\":{f},\"memory_total\":{d},\"memory_used\":{d},\"utilization\":{d},\"temperature\":{d}}}", .{ std.json.fmt(name, .{}), mem_total, mem_used, util, temp });
        usage_sum += util;
        count += 1;
    }
    try detail.append(allocator, ']');
    if (count == 0) return error.NoGpuDetails;
    return std.fmt.allocPrint(allocator, "{{\"count\":{d},\"average_usage\":{d},\"detailed_info\":{s}}}", .{ count, usage_sum / @as(f64, @floatFromInt(count)), detail.items });
}

fn jsonString(value: ?std.json.Value) ?[]const u8 {
    const v = value orelse return null;
    return if (v == .string) v.string else null;
}

fn parsePercent(value: []const u8) f64 {
    const trimmed = std.mem.trim(u8, value, " %\t\r\nC");
    return std.fmt.parseFloat(f64, trimmed) catch 0;
}

fn parseMiB(value: []const u8) u64 {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    return std.fmt.parseInt(u64, trimmed, 10) catch 0;
}

fn commandOutputFirstLine(allocator: std.mem.Allocator, argv: []const []const u8) ![]const u8 {
    var child = std.process.Child.init(argv, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    try child.spawn();
    const stdout = try child.stdout.?.readToEndAlloc(allocator, 64 * 1024);
    defer allocator.free(stdout);
    const term = try child.wait();
    if (term != .Exited or term.Exited != 0) return error.CommandFailed;
    var it = std.mem.splitScalar(u8, stdout, '\n');
    const line = std.mem.trim(u8, it.next() orelse "", " \t\r");
    return allocator.dupe(u8, line);
}

fn fillLocalIp(allocator: std.mem.Allocator, info: *common.BasicInfo) !void {
    const output = commandOutput(allocator, &.{ "ip", "-o", "addr", "show", "scope", "global" }) catch return;
    defer allocator.free(output);

    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        while (fields.next()) |field| {
            if (std.mem.eql(u8, field, "inet")) {
                if (fields.next()) |cidr| {
                    if (info.ipv4.len == 0) info.ipv4 = try stripCidr(allocator, cidr);
                }
            } else if (std.mem.eql(u8, field, "inet6")) {
                if (fields.next()) |cidr| {
                    if (info.ipv6.len == 0 and std.mem.indexOf(u8, cidr, "fe80:") == null) info.ipv6 = try stripCidr(allocator, cidr);
                }
            }
            if (info.ipv4.len != 0 and info.ipv6.len != 0) return;
        }
    }
}

fn stripCidr(allocator: std.mem.Allocator, cidr: []const u8) ![]const u8 {
    const slash = std.mem.indexOfScalar(u8, cidr, '/') orelse cidr.len;
    return allocator.dupe(u8, cidr[0..slash]);
}

fn commandOutput(allocator: std.mem.Allocator, argv: []const []const u8) ![]const u8 {
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

pub fn diskList(allocator: std.mem.Allocator) ![]common.DiskMount {
    const bytes = std.fs.cwd().readFileAlloc(allocator, "/proc/mounts", 1024 * 1024) catch return &.{};
    defer allocator.free(bytes);

    var mounts: std.ArrayList(common.DiskMount) = .empty;
    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        _ = fields.next() orelse continue;
        const mountpoint = fields.next() orelse continue;
        const fstype = fields.next() orelse continue;
        try mounts.append(allocator, .{
            .mountpoint = try allocator.dupe(u8, mountpoint),
            .fstype = try allocator.dupe(u8, fstype),
        });
    }
    return mounts.toOwnedSlice(allocator);
}

fn readFirstLine(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const bytes = std.fs.cwd().readFileAlloc(allocator, path, 4096) catch return allocator.dupe(u8, "");
    if (std.mem.indexOfScalar(u8, bytes, '\n')) |idx| return bytes[0..idx];
    return bytes;
}

fn diskInfo() !common.DiskInfo {
    return diskInfoWithMountpoints("");
}

fn diskInfoWithMountpoints(include_mountpoints: []const u8) !common.DiskInfo {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

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

    const bytes = std.fs.cwd().readFileAlloc(allocator, "/proc/mounts", 1024 * 1024) catch return .{};
    var by_device = std.StringHashMap(common.DiskInfo).init(allocator);

    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        const device = fields.next() orelse continue;
        const mountpoint = fields.next() orelse continue;
        const fstype = fields.next() orelse continue;
        if (!isPhysicalMount(mountpoint, fstype, device)) continue;

        const usage = diskUsageFromDf(allocator, mountpoint) catch continue;
        const key = diskDeviceKey(device, fstype);
        const existing = by_device.get(key);
        if (existing == null or usage.total > existing.?.total) {
            try by_device.put(try allocator.dupe(u8, key), usage);
        }
    }

    var total = common.DiskInfo{};
    var values = by_device.valueIterator();
    while (values.next()) |value| {
        total.total += value.total;
        total.used += value.used;
    }
    return total;
}

pub fn diskDeviceKey(device: []const u8, fstype: []const u8) []const u8 {
    if (std.ascii.eqlIgnoreCase(fstype, "zfs")) {
        return device[0 .. std.mem.indexOfScalar(u8, device, '/') orelse device.len];
    }
    return device;
}

pub fn isPhysicalMount(mountpoint_raw: []const u8, fstype_raw: []const u8, device: []const u8) bool {
    if (std.mem.eql(u8, mountpoint_raw, "/")) return true;
    const mountpoint = mountpoint_raw;
    const excluded_mounts = [_][]const u8{
        "/tmp",
        "/var/tmp",
        "/dev",
        "/run",
        "/var/lib/containers",
        "/var/lib/docker",
        "/proc",
        "/sys",
        "/sys/fs/cgroup",
        "/etc/resolv.conf",
        "/etc/host",
        "/nix/store",
    };
    for (&excluded_mounts) |prefix| {
        if (std.mem.eql(u8, mountpoint, prefix) or std.mem.startsWith(u8, mountpoint, prefix)) return false;
    }

    const fstype = fstype_raw;
    if (std.ascii.eqlIgnoreCase(fstype, "fuseblk")) return true;
    if (std.ascii.eqlIgnoreCase(fstype, "autofs") and !std.mem.startsWith(u8, device, "/dev/")) return false;
    const excluded_fs = [_][]const u8{
        "tmpfs",
        "devtmpfs",
        "udev",
        "nfs",
        "cifs",
        "smb",
        "vboxsf",
        "9p",
        "fuse",
        "overlay",
        "proc",
        "devpts",
        "sysfs",
        "cgroup",
        "mqueue",
        "hugetlbfs",
        "debugfs",
        "binfmt_misc",
        "securityfs",
        "squashfs",
    };
    for (&excluded_fs) |excluded| {
        if (std.ascii.eqlIgnoreCase(fstype, excluded) or startsWithIgnoreCase(fstype, excluded)) return false;
    }
    if (std.mem.startsWith(u8, device, "/dev/loop")) return false;
    return true;
}

fn startsWithIgnoreCase(value: []const u8, prefix: []const u8) bool {
    return value.len >= prefix.len and std.ascii.eqlIgnoreCase(value[0..prefix.len], prefix);
}

fn diskUsageFromDf(allocator: std.mem.Allocator, mountpoint: []const u8) !common.DiskInfo {
    const output = try commandOutput(allocator, &.{ "df", "-P", "-B1", mountpoint });
    defer allocator.free(output);
    var lines = std.mem.splitScalar(u8, output, '\n');
    _ = lines.next();
    const data = lines.next() orelse return error.BadDfOutput;
    var fields = std.mem.tokenizeAny(u8, data, " \t");
    _ = fields.next() orelse return error.BadDfOutput;
    const total = try std.fmt.parseInt(u64, fields.next() orelse return error.BadDfOutput, 10);
    const used = try std.fmt.parseInt(u64, fields.next() orelse return error.BadDfOutput, 10);
    return .{ .total = total, .used = used };
}

fn networkInfo(options: common.SnapshotOptions) !common.NetworkInfo {
    const path = try procPath(std.heap.page_allocator, options.host_proc, "net/dev");
    defer std.heap.page_allocator.free(path);
    const bytes = std.fs.cwd().readFileAlloc(std.heap.page_allocator, path, 1024 * 1024) catch return .{};
    defer std.heap.page_allocator.free(bytes);
    var current = parseProcNetDev(bytes, options.include_nics, options.exclude_nics);
    const now = std.time.milliTimestamp();
    if (previous_network) |prev| {
        const elapsed_ms: u64 = @intCast(@max(now - prev.timestamp_ms, 1));
        current.up = perSecond(current.totalUp, prev.total_up, elapsed_ms);
        current.down = perSecond(current.totalDown, prev.total_down, elapsed_ms);
    }
    previous_network = .{
        .total_up = current.totalUp,
        .total_down = current.totalDown,
        .timestamp_ms = now,
    };
    if (options.month_rotate != 0) {
        const totals = netstatic.applyMonthlyTotals(std.heap.page_allocator, current.totalUp, current.totalDown, options.month_rotate);
        current.totalUp = totals.up;
        current.totalDown = totals.down;
    }
    return current;
}

fn cpuUsage(host_proc: []const u8) !f64 {
    const path = try procPath(std.heap.page_allocator, host_proc, "stat");
    defer std.heap.page_allocator.free(path);
    const bytes = std.fs.cwd().readFileAlloc(std.heap.page_allocator, path, 64 * 1024) catch return 0.001;
    defer std.heap.page_allocator.free(bytes);
    const current = parseCpuStat(bytes) orelse return 0.001;
    defer previous_cpu = current;
    if (previous_cpu) |previous| {
        const usage = cpuUsagePercent(previous, current);
        return if (usage <= 0.001) 0.001 else usage;
    }
    return 0.001;
}

pub fn parseCpuStat(bytes: []const u8) ?CpuStat {
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    const line = lines.next() orelse return null;
    var fields = std.mem.tokenizeAny(u8, line, " \t");
    const label = fields.next() orelse return null;
    if (!std.mem.eql(u8, label, "cpu")) return null;

    var values: [10]u64 = .{0} ** 10;
    var count: usize = 0;
    while (fields.next()) |field| {
        if (count >= values.len) break;
        values[count] = std.fmt.parseInt(u64, field, 10) catch 0;
        count += 1;
    }
    if (count < 4) return null;
    var total: u64 = 0;
    for (values[0..count]) |value| total += value;
    return .{ .idle = values[3] + if (count > 4) values[4] else 0, .total = total };
}

pub fn cpuUsagePercent(previous: CpuStat, current: CpuStat) f64 {
    if (current.total <= previous.total or current.idle < previous.idle) return 0.001;
    const total_delta = current.total - previous.total;
    const idle_delta = current.idle - previous.idle;
    if (total_delta == 0 or total_delta < idle_delta) return 0.001;
    return (@as(f64, @floatFromInt(total_delta - idle_delta)) / @as(f64, @floatFromInt(total_delta))) * 100.0;
}

fn connectionsInfo(host_proc: []const u8) !common.ConnectionInfo {
    return .{
        .tcp = countProcNetFile(host_proc, "net/tcp") + countProcNetFile(host_proc, "net/tcp6"),
        .udp = countProcNetFile(host_proc, "net/udp") + countProcNetFile(host_proc, "net/udp6"),
    };
}

fn countProcNetFile(host_proc: []const u8, suffix: []const u8) u64 {
    const path = procPath(std.heap.page_allocator, host_proc, suffix) catch return 0;
    defer std.heap.page_allocator.free(path);
    const bytes = std.fs.cwd().readFileAlloc(std.heap.page_allocator, path, 1024 * 1024) catch return 0;
    defer std.heap.page_allocator.free(bytes);
    return countProcNetConnections(bytes);
}

pub fn countProcNetConnections(bytes: []const u8) u64 {
    var count: u64 = 0;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    _ = lines.next();
    while (lines.next()) |line| {
        if (std.mem.trim(u8, line, " \t\r").len != 0) count += 1;
    }
    return count;
}

fn perSecond(current: u64, previous: u64, elapsed_ms: u64) u64 {
    if (current <= previous) return 0;
    return ((current - previous) * 1000) / elapsed_ms;
}

pub fn parseProcNetDev(bytes: []const u8, include_nics: []const u8, exclude_nics: []const u8) common.NetworkInfo {
    var total_up: u64 = 0;
    var total_down: u64 = 0;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        if (!shouldIncludeNetworkInterface(name, include_nics, exclude_nics)) continue;
        var fields = std.mem.tokenizeAny(u8, line[colon + 1 ..], " \t");
        const rx = std.fmt.parseInt(u64, fields.next() orelse "0", 10) catch 0;
        var idx: usize = 1;
        var tx: u64 = 0;
        while (fields.next()) |field| : (idx += 1) {
            if (idx == 8) {
                tx = std.fmt.parseInt(u64, field, 10) catch 0;
                break;
            }
        }
        total_down += rx;
        total_up += tx;
    }
    return .{ .totalUp = total_up, .totalDown = total_down };
}

pub fn shouldIncludeNetworkInterface(name: []const u8, include_nics: []const u8, exclude_nics: []const u8) bool {
    const excluded_prefixes = [_][]const u8{ "br", "cni", "docker", "podman", "flannel", "lo", "veth", "virbr", "vmbr", "tap", "fwbr", "fwpr" };
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
        if (globMatch(std.mem.trim(u8, part, " \t"), needle)) return true;
    }
    return false;
}

pub fn globMatch(pattern: []const u8, value: []const u8) bool {
    if (std.mem.eql(u8, pattern, "*")) return true;
    const star = std.mem.indexOfScalar(u8, pattern, '*') orelse return std.mem.eql(u8, pattern, value);
    const prefix = pattern[0..star];
    const suffix = pattern[star + 1 ..];
    if (!std.mem.startsWith(u8, value, prefix)) return false;
    if (suffix.len == 0) return true;
    return std.mem.endsWith(u8, value, suffix);
}

fn cpuName(allocator: std.mem.Allocator) ![]const u8 {
    const bytes = std.fs.cwd().readFileAlloc(allocator, "/proc/cpuinfo", 256 * 1024) catch return allocator.dupe(u8, "Unknown");
    defer allocator.free(bytes);
    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "model name") or std.mem.startsWith(u8, line, "Hardware") or std.mem.startsWith(u8, line, "Processor")) {
            if (std.mem.indexOfScalar(u8, line, ':')) |idx| return allocator.dupe(u8, std.mem.trim(u8, line[idx + 1 ..], " \t"));
        }
    }
    return allocator.dupe(u8, "Unknown");
}

fn memInfo() !common.MemInfo {
    return memInfoFromPath("/proc/meminfo", .{});
}

pub const MemMode = struct {
    include_cache: bool = false,
    report_raw_used: bool = false,
};

fn memInfoWithOptions(options: common.SnapshotOptions) !common.MemInfo {
    const path = try procPath(std.heap.page_allocator, options.host_proc, "meminfo");
    defer std.heap.page_allocator.free(path);
    return memInfoFromPath(path, .{ .include_cache = options.memory_include_cache, .report_raw_used = options.memory_report_raw_used });
}

pub fn parseMemInfo(bytes: []const u8, mode: MemMode) common.MemInfo {
    var total: u64 = 0;
    var free: u64 = 0;
    var available: u64 = 0;
    var buffers: u64 = 0;
    var cached: u64 = 0;
    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |line| {
        var fields = std.mem.tokenizeAny(u8, line, " \t:");
        const key = fields.next() orelse continue;
        const val = fields.next() orelse continue;
        const n = (std.fmt.parseInt(u64, val, 10) catch 0) * 1024;
        if (std.mem.eql(u8, key, "MemTotal")) total = n;
        if (std.mem.eql(u8, key, "MemFree")) free = n;
        if (std.mem.eql(u8, key, "MemAvailable")) available = n;
        if (std.mem.eql(u8, key, "Buffers")) buffers = n;
        if (std.mem.eql(u8, key, "Cached")) cached = n;
    }
    const used = if (mode.report_raw_used)
        if (total >= free + buffers + cached) total - free - buffers - cached else 0
    else if (mode.include_cache)
        if (total >= free) total - free else 0
    else if (available > 0 and total >= available)
        total - available
    else if (total >= free)
        total - free
    else
        0;
    return .{ .total = total, .used = used };
}

fn memInfoFromPath(path: []const u8, mode: MemMode) !common.MemInfo {
    const bytes = std.fs.cwd().readFileAlloc(std.heap.page_allocator, path, 64 * 1024) catch return .{};
    defer std.heap.page_allocator.free(bytes);
    return parseMemInfo(bytes, mode);
}

fn swapInfo() !common.MemInfo {
    return swapInfoWithRoot("");
}

fn swapInfoWithRoot(host_proc: []const u8) !common.MemInfo {
    var total: u64 = 0;
    var free: u64 = 0;
    const path = try procPath(std.heap.page_allocator, host_proc, "meminfo");
    defer std.heap.page_allocator.free(path);
    const bytes = std.fs.cwd().readFileAlloc(std.heap.page_allocator, path, 64 * 1024) catch return .{};
    defer std.heap.page_allocator.free(bytes);
    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |line| {
        var fields = std.mem.tokenizeAny(u8, line, " \t:");
        const key = fields.next() orelse continue;
        const val = fields.next() orelse continue;
        const n = (std.fmt.parseInt(u64, val, 10) catch 0) * 1024;
        if (std.mem.eql(u8, key, "SwapTotal")) total = n;
        if (std.mem.eql(u8, key, "SwapFree")) free = n;
    }
    return .{ .total = total, .used = if (total >= free) total - free else 0 };
}

fn loadInfo(host_proc: []const u8) !common.LoadInfo {
    const path = try procPath(std.heap.page_allocator, host_proc, "loadavg");
    defer std.heap.page_allocator.free(path);
    const bytes = std.fs.cwd().readFileAlloc(std.heap.page_allocator, path, 4096) catch return .{};
    defer std.heap.page_allocator.free(bytes);
    var fields = std.mem.tokenizeAny(u8, bytes, " \t\n");
    return .{
        .load1 = std.fmt.parseFloat(f64, fields.next() orelse "0") catch 0,
        .load5 = std.fmt.parseFloat(f64, fields.next() orelse "0") catch 0,
        .load15 = std.fmt.parseFloat(f64, fields.next() orelse "0") catch 0,
    };
}

fn uptime(host_proc: []const u8) !u64 {
    const path = try procPath(std.heap.page_allocator, host_proc, "uptime");
    defer std.heap.page_allocator.free(path);
    const bytes = std.fs.cwd().readFileAlloc(std.heap.page_allocator, path, 4096) catch return 0;
    defer std.heap.page_allocator.free(bytes);
    var fields = std.mem.tokenizeAny(u8, bytes, " \t\n");
    const first = fields.next() orelse return 0;
    return @intFromFloat(std.fmt.parseFloat(f64, first) catch 0);
}

fn processCount(host_proc: []const u8) !u64 {
    const path = if (host_proc.len == 0) "/proc" else host_proc;
    var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch return 0;
    defer dir.close();
    var count: u64 = 0;
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .directory) continue;
        _ = std.fmt.parseInt(u64, entry.name, 10) catch continue;
        count += 1;
    }
    return count;
}

pub fn procPath(allocator: std.mem.Allocator, root: []const u8, suffix: []const u8) ![]const u8 {
    if (root.len == 0) return std.fmt.allocPrint(allocator, "/proc/{s}", .{suffix});
    return std.fs.path.join(allocator, &.{ root, suffix });
}
