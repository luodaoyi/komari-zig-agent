const std = @import("std");
const common = @import("common.zig");

pub fn basicInfo(allocator: std.mem.Allocator) !common.BasicInfo {
    const info = common.BasicInfo{
        .cpu = .{
            .name = try cpuName(allocator),
            .architecture = @tagName(@import("builtin").cpu.arch),
            .cores = @intCast(try std.Thread.getCpuCount()),
            .usage = 0.001,
        },
        .os_name = "linux",
        .kernel_version = try readFirstLine(allocator, "/proc/sys/kernel/osrelease"),
        .mem_total = (try memInfo()).total,
        .swap_total = (try swapInfo()).total,
        .disk_total = 0,
    };
    return info;
}

pub fn snapshot() !common.Snapshot {
    const mem = try memInfo();
    const swap = try swapInfo();
    return .{
        .cpu = .{ .architecture = @tagName(@import("builtin").cpu.arch), .cores = @intCast(try std.Thread.getCpuCount()), .usage = 0.001 },
        .ram = mem,
        .swap = swap,
        .load = try loadInfo(),
        .uptime = try uptime(),
        .process = try processCount(),
    };
}

fn readFirstLine(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const bytes = std.fs.cwd().readFileAlloc(allocator, path, 4096) catch return allocator.dupe(u8, "");
    if (std.mem.indexOfScalar(u8, bytes, '\n')) |idx| return bytes[0..idx];
    return bytes;
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
