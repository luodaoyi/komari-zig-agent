const std = @import("std");
const config = @import("config.zig");
const autodiscovery = @import("protocol/autodiscovery.zig");
const basic_info = @import("protocol/basic_info.zig");
const common = @import("platform/common.zig");
const provider = @import("platform/provider.zig");
const ip = @import("protocol/ip.zig");
const report_ws = @import("protocol/report_ws.zig");
const update = @import("update.zig");
const version = @import("version.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

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

    if (!cfg.disable_auto_update) {
        try update.checkAndUpdate(allocator, cfg);
        update.startBackground(allocator, cfg);
    }

    var info = try provider.basicInfo(allocator);
    try applyIpConfig(allocator, cfg, &info);
    const info_json = try basic_info.allocBasicInfoJson(allocator, info, true);
    defer allocator.free(info_json);
    try stdout.print("Basic info ready: {d} bytes\n", .{info_json.len});
    basic_info.upload(allocator, cfg, info) catch |err| {
        try stdout.print("Basic info upload failed: {s}\n", .{@errorName(err)});
        return;
    };
    try stdout.writeAll("Basic info uploaded successfully\n");
    startBasicInfoLoop(allocator, cfg);

    const report_json = try report_ws.runOnce(allocator, cfg);
    defer allocator.free(report_json);
    try stdout.print("Report ready: {d} bytes\n", .{report_json.len});

    try report_ws.loop(allocator, cfg);
}

fn startBasicInfoLoop(allocator: std.mem.Allocator, cfg: config.Config) void {
    const thread = std.Thread.spawn(.{}, basicInfoLoop, .{ allocator, cfg }) catch return;
    thread.detach();
}

fn basicInfoLoop(allocator: std.mem.Allocator, cfg: config.Config) void {
    const mins: u64 = if (cfg.info_report_interval <= 0) 5 else @intCast(cfg.info_report_interval);
    while (true) {
        std.Thread.sleep(mins * 60 * std.time.ns_per_s);
        var info = provider.basicInfo(allocator) catch continue;
        applyIpConfig(allocator, cfg, &info) catch {};
        basic_info.upload(allocator, cfg, info) catch {};
    }
}

fn applyIpConfig(allocator: std.mem.Allocator, cfg: config.Config, info: *common.BasicInfo) !void {
    if (cfg.get_ip_addr_from_nic) {
        if (cfg.custom_ipv4.len != 0) info.ipv4 = cfg.custom_ipv4;
        if (cfg.custom_ipv6.len != 0) info.ipv6 = cfg.custom_ipv6;
        return;
    }

    info.ipv4 = if (cfg.custom_ipv4.len != 0) cfg.custom_ipv4 else try ip.getIPv4Address(allocator, cfg);
    info.ipv6 = if (cfg.custom_ipv6.len != 0) cfg.custom_ipv6 else try ip.getIPv6Address(allocator, cfg);
}
