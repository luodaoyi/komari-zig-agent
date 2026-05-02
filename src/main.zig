const std = @import("std");
const config = @import("config.zig");
const autodiscovery = @import("protocol/autodiscovery.zig");
const basic_info = @import("protocol/basic_info.zig");
const common = @import("platform/common.zig");
const provider = @import("platform/provider.zig");
const ip = @import("protocol/ip.zig");
const netstatic = @import("report_netstatic");
const report_ws = @import("protocol/report_ws.zig");
const update = @import("update.zig");
const version = @import("version.zig");
const builtin = @import("builtin");

var shutdown_requested = std.atomic.Value(bool).init(false);
var netstatic_active = std.atomic.Value(bool).init(false);

pub fn main() !void {
    const allocator = std.heap.smp_allocator;
    installSignalHandlers();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var cfg = try config.parseArgs(allocator, args);
    try cfg.loadEnv(allocator);
    if (cfg.config_file.len != 0) try cfg.loadJsonFile(allocator, cfg.config_file);

    if (cfg.command == .list_disk) {
        const disks = try provider.diskList(allocator);
        defer allocator.free(disks);
        var stdout = std.fs.File.stdout().deprecatedWriter();
        try stdout.writeAll("Mountpoint\tFstype\n");
        for (disks) |disk| {
            defer allocator.free(disk.mountpoint);
            defer allocator.free(disk.fstype);
            try stdout.print("{s}\t{s}\n", .{ disk.mountpoint, disk.fstype });
        }
        return;
    }

    try autodiscovery.applyExistingToken(allocator, &cfg);

    var stdout = std.fs.File.stdout().deprecatedWriter();
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

    if (!cfg.disable_auto_update) {
        try update.checkAndUpdate(allocator, cfg);
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

fn handleSignal(_: i32) callconv(.c) void {
    shutdown_requested.store(true, .release);
    if (!netstatic_active.load(.acquire)) std.posix.exit(0);
}

fn printMonitoringLists(allocator: std.mem.Allocator, cfg: config.Config) !void {
    var stdout = std.fs.File.stdout().deprecatedWriter();
    const disks = try provider.monitoringDiskList(allocator, cfg.include_mountpoints);
    defer allocator.free(disks);
    try stdout.writeAll("Monitoring Mountpoints: [");
    for (disks, 0..) |disk, i| {
        if (i != 0) try stdout.writeAll(" ");
        try stdout.print("{s}", .{disk});
    }
    try stdout.writeAll("]\n");
    const nics = try provider.interfaceList(allocator, cfg.include_nics, cfg.exclude_nics);
    defer allocator.free(nics);
    try stdout.writeAll("Monitoring Interfaces: [");
    for (nics, 0..) |nic, i| {
        if (i != 0) try stdout.writeAll(" ");
        try stdout.print("{s}", .{nic});
    }
    try stdout.writeAll("]\n");
}

fn uploadBasicInfoOnce(allocator: std.mem.Allocator, cfg: config.Config) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    var stdout = std.fs.File.stdout().deprecatedWriter();
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
    const thread = std.Thread.spawn(.{}, basicInfoLoop, .{ allocator, cfg }) catch return;
    thread.detach();
}

fn basicInfoLoop(allocator: std.mem.Allocator, cfg: config.Config) void {
    const mins: u64 = if (cfg.info_report_interval <= 0) 5 else @intCast(cfg.info_report_interval);
    while (true) {
        std.Thread.sleep(mins * 60 * std.time.ns_per_s);
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
