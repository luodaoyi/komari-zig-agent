const std = @import("std");
const common = @import("common.zig");

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

pub fn snapshot() !common.Snapshot {
    const mem = try memInfo();
    const swap = try swapInfo();
    return .{
        .cpu = .{ .architecture = normalizeArch(@tagName(@import("builtin").cpu.arch)), .cores = @intCast(try std.Thread.getCpuCount()), .usage = 0.001 },
        .ram = mem,
        .swap = swap,
        .load = try loadInfo(),
        .disk = try diskInfo(),
        .uptime = try uptime(),
        .process = try processCount(),
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
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

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
    var total: u64 = 0;
    var free: u64 = 0;
    var available: u64 = 0;
    const bytes = std.fs.cwd().readFileAlloc(std.heap.page_allocator, "/proc/meminfo", 64 * 1024) catch return .{};
    defer std.heap.page_allocator.free(bytes);
    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |line| {
        var fields = std.mem.tokenizeAny(u8, line, " \t:");
        const key = fields.next() orelse continue;
        const val = fields.next() orelse continue;
        const n = (std.fmt.parseInt(u64, val, 10) catch 0) * 1024;
        if (std.mem.eql(u8, key, "MemTotal")) total = n;
        if (std.mem.eql(u8, key, "MemFree")) free = n;
        if (std.mem.eql(u8, key, "MemAvailable")) available = n;
    }
    const used = if (available > 0 and total >= available) total - available else if (total >= free) total - free else 0;
    return .{ .total = total, .used = used };
}

fn swapInfo() !common.MemInfo {
    var total: u64 = 0;
    var free: u64 = 0;
    const bytes = std.fs.cwd().readFileAlloc(std.heap.page_allocator, "/proc/meminfo", 64 * 1024) catch return .{};
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

fn loadInfo() !common.LoadInfo {
    const bytes = std.fs.cwd().readFileAlloc(std.heap.page_allocator, "/proc/loadavg", 4096) catch return .{};
    defer std.heap.page_allocator.free(bytes);
    var fields = std.mem.tokenizeAny(u8, bytes, " \t\n");
    return .{
        .load1 = std.fmt.parseFloat(f64, fields.next() orelse "0") catch 0,
        .load5 = std.fmt.parseFloat(f64, fields.next() orelse "0") catch 0,
        .load15 = std.fmt.parseFloat(f64, fields.next() orelse "0") catch 0,
    };
}

fn uptime() !u64 {
    const bytes = std.fs.cwd().readFileAlloc(std.heap.page_allocator, "/proc/uptime", 4096) catch return 0;
    defer std.heap.page_allocator.free(bytes);
    var fields = std.mem.tokenizeAny(u8, bytes, " \t\n");
    const first = fields.next() orelse return 0;
    return @intFromFloat(std.fmt.parseFloat(f64, first) catch 0);
}

fn processCount() !u64 {
    var dir = std.fs.cwd().openDir("/proc", .{ .iterate = true }) catch return 0;
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
