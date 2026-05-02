const common = @import("common.zig");
const std = @import("std");

pub fn basicInfo(allocator: std.mem.Allocator) !common.BasicInfo {
    return .{
        .cpu = .{
            .name = try commandFirstLine(allocator, &.{ "sysctl", "-n", "machdep.cpu.brand_string" }, "Unknown"),
            .architecture = normalizeArch(@tagName(@import("builtin").cpu.arch)),
            .cores = @intCast(std.Thread.getCpuCount() catch 1),
            .usage = 0.001,
        },
        .os_name = try commandFirstLine(allocator, &.{ "sw_vers", "-productName" }, "macOS"),
        .kernel_version = try commandFirstLine(allocator, &.{ "uname", "-r" }, ""),
        .mem_total = sysctlInt(allocator, "hw.memsize") catch 0,
        .swap_total = (swapInfo(allocator) catch common.MemInfo{}).total,
        .disk_total = (diskInfo(allocator) catch common.DiskInfo{}).total,
        .gpu_name = try gpuName(allocator),
        .virtualization = try virtualization(allocator),
    };
}

pub fn snapshot(options: common.SnapshotOptions) !common.Snapshot {
    _ = options;
    return .{
        .cpu = .{ .architecture = normalizeArch(@tagName(@import("builtin").cpu.arch)), .cores = @intCast(std.Thread.getCpuCount() catch 1), .usage = cpuUsage(std.heap.page_allocator) catch 0.001 },
        .ram = memInfo(std.heap.page_allocator) catch .{},
        .swap = swapInfo(std.heap.page_allocator) catch .{},
        .load = loadInfo(std.heap.page_allocator) catch .{},
        .disk = diskInfo(std.heap.page_allocator) catch .{},
        .network = networkInfo(std.heap.page_allocator) catch .{},
        .connections = connectionsInfo(std.heap.page_allocator) catch .{},
        .uptime = uptime(std.heap.page_allocator) catch 0,
        .process = processCount(std.heap.page_allocator) catch 0,
    };
}

pub fn diskList(allocator: std.mem.Allocator) ![]common.DiskMount {
    const out = commandOutput(allocator, &.{ "df", "-k", "-P" }) catch return &.{};
    defer allocator.free(out);
    var list: std.ArrayList(common.DiskMount) = .empty;
    var lines = std.mem.splitScalar(u8, out, '\n');
    _ = lines.next();
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        const fs = fields.next() orelse continue;
        if (!std.mem.startsWith(u8, fs, "/dev/")) continue;
        _ = fields.next();
        _ = fields.next();
        _ = fields.next();
        _ = fields.next();
        const mountpoint = fields.next() orelse continue;
        try list.append(allocator, .{ .mountpoint = try allocator.dupe(u8, mountpoint), .fstype = try allocator.dupe(u8, "apfs") });
    }
    return list.toOwnedSlice(allocator);
}

fn memInfo(allocator: std.mem.Allocator) !common.MemInfo {
    const total = try sysctlInt(allocator, "hw.memsize");
    const out = try commandOutput(allocator, &.{"vm_stat"});
    defer allocator.free(out);
    var page_size: u64 = 4096;
    var free_pages: u64 = 0;
    var inactive_pages: u64 = 0;
    var speculative_pages: u64 = 0;
    var lines = std.mem.splitScalar(u8, out, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "page size of ")) |idx| {
            const start = idx + "page size of ".len;
            var end = start;
            while (end < line.len and std.ascii.isDigit(line[end])) : (end += 1) {}
            page_size = std.fmt.parseInt(u64, line[start..end], 10) catch page_size;
        } else if (std.mem.startsWith(u8, line, "Pages free:")) {
            free_pages = parseVmStatNumber(line);
        } else if (std.mem.startsWith(u8, line, "Pages inactive:")) {
            inactive_pages = parseVmStatNumber(line);
        } else if (std.mem.startsWith(u8, line, "Pages speculative:")) {
            speculative_pages = parseVmStatNumber(line);
        }
    }
    const available = (free_pages + inactive_pages + speculative_pages) * page_size;
    return .{ .total = total, .used = if (total >= available) total - available else 0 };
}

fn parseVmStatNumber(line: []const u8) u64 {
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return 0;
    const raw = std.mem.trim(u8, line[colon + 1 ..], " .\t\r\n");
    return std.fmt.parseInt(u64, raw, 10) catch 0;
}

fn swapInfo(allocator: std.mem.Allocator) !common.MemInfo {
    const out = try commandOutput(allocator, &.{ "sysctl", "-n", "vm.swapusage" });
    defer allocator.free(out);
    return .{ .total = parseSizeAfter(out, "total = "), .used = parseSizeAfter(out, "used = ") };
}

fn parseSizeAfter(text: []const u8, needle: []const u8) u64 {
    const idx = std.mem.indexOf(u8, text, needle) orelse return 0;
    const start = idx + needle.len;
    var end = start;
    while (end < text.len and (std.ascii.isDigit(text[end]) or text[end] == '.')) : (end += 1) {}
    const value = std.fmt.parseFloat(f64, text[start..end]) catch 0;
    const rest = text[end..@min(text.len, end + 2)];
    const mult: f64 = if (std.mem.startsWith(u8, rest, "G")) 1024 * 1024 * 1024 else if (std.mem.startsWith(u8, rest, "M")) 1024 * 1024 else 1;
    return @intFromFloat(value * mult);
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
    var total = common.DiskInfo{};
    var lines = std.mem.splitScalar(u8, out, '\n');
    _ = lines.next();
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        const fs = fields.next() orelse continue;
        if (!std.mem.startsWith(u8, fs, "/dev/")) continue;
        total.total += (std.fmt.parseInt(u64, fields.next() orelse "0", 10) catch 0) * 1024;
        total.used += (std.fmt.parseInt(u64, fields.next() orelse "0", 10) catch 0) * 1024;
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
    return .{
        .tcp = countNetstatLines(allocator, &.{ "netstat", "-an", "-p", "tcp" }) catch 0,
        .udp = countNetstatLines(allocator, &.{ "netstat", "-an", "-p", "udp" }) catch 0,
    };
}

fn countNetstatLines(allocator: std.mem.Allocator, argv: []const []const u8) !u64 {
    const out = try commandOutput(allocator, argv);
    defer allocator.free(out);
    var count: u64 = 0;
    var lines = std.mem.splitScalar(u8, out, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trimmed, "tcp") or std.mem.startsWith(u8, trimmed, "udp")) count += 1;
    }
    return count;
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
    const out = try commandOutput(allocator, &.{ "ps", "-A" });
    defer allocator.free(out);
    var count: u64 = 0;
    var lines = std.mem.splitScalar(u8, out, '\n');
    _ = lines.next();
    while (lines.next()) |line| {
        if (std.mem.trim(u8, line, " \t\r").len != 0) count += 1;
    }
    return count;
}

fn cpuUsage(allocator: std.mem.Allocator) !f64 {
    const out = try commandOutput(allocator, &.{ "top", "-l", "2", "-n", "0" });
    defer allocator.free(out);
    var last_cpu: []const u8 = "";
    var lines = std.mem.splitScalar(u8, out, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "CPU usage:") != null) last_cpu = line;
    }
    const idle_idx = std.mem.indexOf(u8, last_cpu, " idle") orelse return 0.001;
    var start = idle_idx;
    while (start > 0 and (std.ascii.isDigit(last_cpu[start - 1]) or last_cpu[start - 1] == '.')) : (start -= 1) {}
    const idle = std.fmt.parseFloat(f64, last_cpu[start..idle_idx]) catch return 0.001;
    return @max(0.001, 100.0 - idle);
}

fn gpuName(allocator: std.mem.Allocator) ![]const u8 {
    const out = commandOutput(allocator, &.{ "system_profiler", "SPDisplaysDataType" }) catch return allocator.dupe(u8, "Unknown");
    defer allocator.free(out);
    var lines = std.mem.splitScalar(u8, out, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r\n");
        if (std.mem.startsWith(u8, line, "Chipset Model:")) {
            return allocator.dupe(u8, std.mem.trim(u8, line["Chipset Model:".len..], " \t\r\n"));
        }
    }
    return allocator.dupe(u8, "Unknown");
}

fn virtualization(allocator: std.mem.Allocator) ![]const u8 {
    const out = commandFirstLine(allocator, &.{ "sysctl", "-n", "kern.hv_vmm_present" }, "0") catch "0";
    if (std.mem.eql(u8, out, "1")) return allocator.dupe(u8, "virtualized");
    return allocator.dupe(u8, "none");
}

fn sysctlInt(allocator: std.mem.Allocator, name: []const u8) !u64 {
    const out = try commandOutput(allocator, &.{ "sysctl", "-n", name });
    defer allocator.free(out);
    return std.fmt.parseInt(u64, std.mem.trim(u8, out, " \t\r\n"), 10);
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
    const stdout = try child.stdout.?.readToEndAlloc(allocator, 512 * 1024);
    errdefer allocator.free(stdout);
    const term = try child.wait();
    if (term != .Exited or term.Exited != 0) return error.CommandFailed;
    return stdout;
}

fn normalizeArch(arch: []const u8) []const u8 {
    if (std.mem.eql(u8, arch, "x86_64")) return "amd64";
    if (std.mem.eql(u8, arch, "aarch64")) return "arm64";
    if (std.mem.eql(u8, arch, "x86")) return "386";
    return arch;
}
