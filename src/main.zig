const std = @import("std");
const config = @import("config.zig");
const autodiscovery = @import("protocol/autodiscovery.zig");
const basic_info = @import("protocol/basic_info.zig");
const common = @import("platform/common.zig");
const provider = @import("platform/provider.zig");
const ip = @import("protocol/ip.zig");
const netstatic = @import("report_netstatic");
const ping = @import("protocol/ping.zig");
const report_ws = @import("protocol/report_ws.zig");
const update = @import("update.zig");
const version = @import("version.zig");
const builtin = @import("builtin");
const compat = @import("compat");
const runtime = @import("runtime");

/// Agent entrypoint that wires config, reporting, updates, and shutdown.
pub const std_options: std.Options = .{
    .enable_segfault_handler = !(builtin.os.tag == .freebsd and builtin.cpu.arch == .x86),
};

var shutdown_requested = std.atomic.Value(bool).init(false);
var netstatic_active = std.atomic.Value(bool).init(false);

pub fn main(init: std.process.Init.Minimal) !void {
    runtime.init(init);
    const allocator = std.heap.page_allocator;
    var config_arena = std.heap.ArenaAllocator.init(allocator);
    defer config_arena.deinit();
    const config_allocator = config_arena.allocator();
    installSignalHandlers();

    var args_iter = try std.process.Args.Iterator.initAllocator(init.args, config_allocator);
    defer args_iter.deinit();
    var args_list: std.ArrayList([]const u8) = .empty;
    while (args_iter.next()) |arg| try args_list.append(config_allocator, arg);
    const args = try args_list.toOwnedSlice(config_allocator);

    if (try runPingDiagnostic(allocator, args)) return;

    var cfg = try config.parseArgs(config_allocator, args);
    try cfg.loadEnv(config_allocator);
    if (cfg.config_file.len != 0) try cfg.loadJsonFile(config_allocator, cfg.config_file);

    if (cfg.command == .list_disk) {
        const disks = try provider.diskList(allocator);
        defer freeDiskMounts(allocator, disks);
        var stdout_buf: [4096]u8 = undefined;
        var stdout = compat.fileWriter(std.Io.File.stdout(), &stdout_buf);
        defer stdout.flush() catch {};
        try stdout.writeAll("All Disk Partitions:\n");
        try stdout.writeAll("Mountpoint\tFstype\n");
        for (disks) |disk| {
            try stdout.print("{s}\t{s}\n", .{ disk.mountpoint, disk.fstype });
        }
        const monitoring = try provider.monitoringDiskList(allocator, cfg.include_mountpoints);
        defer freeStringSlice(allocator, monitoring);
        try printStringList(&stdout, "Monitoring Mountpoints", monitoring);
        return;
    }

    if (cfg.command == .check_mem) {
        var stdout_buf: [4096]u8 = undefined;
        var stdout = compat.fileWriter(std.Io.File.stdout(), &stdout_buf);
        defer stdout.flush() catch {};
        try provider.printMemoryCheck(allocator, &stdout, cfg.memory_include_cache, cfg.memory_report_raw_used);
        return;
    }

    if (cfg.show_warning) return;

    try update.recoverPendingUpdate(allocator);
    try autodiscovery.applyExistingToken(config_allocator, &cfg);

    var stdout_buf: [4096]u8 = undefined;
    var stdout = compat.fileWriter(std.Io.File.stdout(), &stdout_buf);
    defer stdout.flush() catch {};
    try stdout.print("Komari Agent {s}\nGithub Repo: {s}\n", .{ version.current, update.repo });

    if (cfg.endpoint.len == 0 or cfg.token.len == 0) {
        try stdout.writeAll("Usage: komari-agent --endpoint <url> --token <token>\n");
        return;
    }

    if (cfg.month_rotate != 0) {
        netstatic.startOrContinue() catch |err| try stdout.print("Failed to start netstatic monitoring: {s}\n", .{@errorName(err)});
        const nics = provider.interfaceList(allocator, cfg.include_nics, cfg.exclude_nics) catch &.{};
        netstatic.setNewConfig(.{ .nics = nics }) catch |err| try stdout.print("Failed to set netstatic config: {s}\n", .{@errorName(err)});
        netstatic_active.store(true, .release);
    }
    defer if (cfg.month_rotate != 0) netstatic.stop() catch {};

    if (!cfg.disable_auto_update and !update.hasPendingUpdate(allocator)) {
        update.checkAndUpdate(allocator, cfg) catch |err| {
            try stdout.print("Auto update check failed: {s}\n", .{@errorName(err)});
        };
        update.startBackground(allocator, cfg);
    }

    printMonitoringLists(allocator, cfg) catch {};

    if (shutdown_requested.load(.acquire)) return;
    try uploadBasicInfoOnce(allocator, cfg);
    if (shutdown_requested.load(.acquire)) return;
    startBasicInfoLoop(allocator, cfg);

    if (shutdown_requested.load(.acquire)) return;

    while (!shutdown_requested.load(.acquire)) {
        report_ws.loop(allocator, cfg, &shutdown_requested) catch |err| {
            try stdout.print("Report websocket exited: {s}\n", .{@errorName(err)});
        };
        if (shutdown_requested.load(.acquire)) break;
        try uploadBasicInfoOnce(allocator, cfg);
    }
    try stdout.writeAll("shutting down gracefully...\n");
}

fn runPingDiagnostic(allocator: std.mem.Allocator, args: []const []const u8) !bool {
    if (args.len < 4 or !std.mem.eql(u8, args[1], "ping-test")) return false;
    const custom_dns = if (args.len >= 5) args[4] else "";
    const value = ping.measure(allocator, args[2], args[3], custom_dns);
    var stdout_buf: [256]u8 = undefined;
    var stdout = compat.fileWriter(std.Io.File.stdout(), &stdout_buf);
    defer stdout.flush() catch {};
    try stdout.print("{d}\n", .{value});
    return true;
}

fn installSignalHandlers() void {
    if (builtin.os.tag == .windows) return;
    const action = std.posix.Sigaction{
        .handler = .{ .handler = handleSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &action, null);
    std.posix.sigaction(std.posix.SIG.TERM, &action, null);
}

fn handleSignal(_: std.posix.SIG) callconv(.c) void {
    shutdown_requested.store(true, .release);
    if (!netstatic_active.load(.acquire)) std.process.exit(0);
}

fn printMonitoringLists(allocator: std.mem.Allocator, cfg: config.Config) !void {
    var stdout_buf: [4096]u8 = undefined;
    var stdout = compat.fileWriter(std.Io.File.stdout(), &stdout_buf);
    defer stdout.flush() catch {};
    const disks = try provider.monitoringDiskList(allocator, cfg.include_mountpoints);
    defer freeStringSlice(allocator, disks);
    try printStringList(&stdout, "Monitoring Mountpoints", disks);
    const nics = try provider.interfaceList(allocator, cfg.include_nics, cfg.exclude_nics);
    defer freeStringSlice(allocator, nics);
    try printStringList(&stdout, "Monitoring Interfaces", nics);
}

fn printStringList(writer: anytype, label: []const u8, values: []const []const u8) !void {
    try writer.print("{s}: [", .{label});
    for (values, 0..) |value, i| {
        if (i != 0) try writer.writeAll(" ");
        try writer.print("{s}", .{value});
    }
    try writer.writeAll("]\n");
}

fn freeDiskMounts(allocator: std.mem.Allocator, disks: []common.DiskMount) void {
    for (disks) |disk| {
        allocator.free(disk.mountpoint);
        allocator.free(disk.fstype);
    }
    allocator.free(disks);
}

fn freeStringSlice(allocator: std.mem.Allocator, values: []const []const u8) void {
    for (values) |value| allocator.free(value);
    allocator.free(values);
}

fn uploadBasicInfoOnce(allocator: std.mem.Allocator, cfg: config.Config) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    var stdout_buf: [4096]u8 = undefined;
    var stdout = compat.fileWriter(std.Io.File.stdout(), &stdout_buf);
    defer stdout.flush() catch {};
    var info = try provider.basicInfo(scratch);
    try applyIpConfig(scratch, cfg, &info);
    const info_json = try basic_info.allocBasicInfoJson(scratch, info, true);
    try stdout.print("Basic info ready: {d} bytes\n", .{info_json.len});
    basic_info.upload(scratch, cfg, info) catch |err| {
        try stdout.print("Basic info upload failed: {s}\n", .{@errorName(err)});
        return err;
    };
    try stdout.writeAll("Basic info uploaded successfully\n");
}

fn startBasicInfoLoop(allocator: std.mem.Allocator, cfg: config.Config) void {
    const thread = std.Thread.spawn(.{ .stack_size = 256 * 1024 }, basicInfoLoop, .{ allocator, cfg }) catch return;
    thread.detach();
}

fn basicInfoLoop(allocator: std.mem.Allocator, cfg: config.Config) void {
    const mins: u64 = if (cfg.info_report_interval <= 0) 5 else @intCast(cfg.info_report_interval);
    while (true) {
        compat.sleep(mins * 60 * std.time.ns_per_s);
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const scratch = arena.allocator();
        var info = provider.basicInfo(scratch) catch continue;
        applyIpConfig(scratch, cfg, &info) catch {};
        basic_info.upload(scratch, cfg, info) catch {};
    }
}

fn applyIpConfig(allocator: std.mem.Allocator, cfg: config.Config, info: *common.BasicInfo) !void {
    if (cfg.get_ip_addr_from_nic) {
        const local = try provider.localIpFromInterfaces(allocator, cfg.include_nics, cfg.exclude_nics);
        if (local.ipv4.len != 0 or local.ipv6.len != 0) {
            info.ipv4 = local.ipv4;
            info.ipv6 = local.ipv6;
            return;
        }
    }

    info.ipv4 = if (cfg.custom_ipv4.len != 0) cfg.custom_ipv4 else try ip.getIPv4Address(allocator, cfg);
    info.ipv6 = if (cfg.custom_ipv6.len != 0) cfg.custom_ipv6 else try ip.getIPv6Address(allocator, cfg);
}
