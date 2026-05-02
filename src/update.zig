const std = @import("std");
const builtin = @import("builtin");
const config = @import("config.zig");
const http = @import("protocol/http.zig");
const version = @import("version.zig");

pub const repo = version.repo;

pub fn parseVersionPrefixless(value: []const u8) []const u8 {
    if (value.len > 0 and (value[0] == 'v' or value[0] == 'V')) return value[1..];
    return value;
}

pub fn assetName(allocator: std.mem.Allocator) ![]const u8 {
    const os = switch (builtin.os.tag) {
        .linux => "linux",
        .freebsd => "freebsd",
        .macos => "darwin",
        .windows => "windows",
        else => "linux",
    };
    const arch = switch (builtin.cpu.arch) {
        .x86_64 => "amd64",
        .aarch64 => "arm64",
        .x86 => "386",
        .arm => "arm",
        else => @tagName(builtin.cpu.arch),
    };
    const ext = if (builtin.os.tag == .windows) ".exe" else "";
    return std.fmt.allocPrint(allocator, "komari-agent-{s}-{s}{s}", .{ os, arch, ext });
}

pub fn newerThan(current_raw: []const u8, latest_raw: []const u8) bool {
    const current = parseVersionPrefixless(current_raw);
    const latest = parseVersionPrefixless(latest_raw);
    return compareVersion(latest, current) > 0;
}

pub fn checkAndUpdate(allocator: std.mem.Allocator, cfg: config.Config) !void {
    if (!isNumericVersion(version.current)) return;
    const release_url = "https://api.github.com/repos/" ++ repo ++ "/releases/latest";
    const release = http.getReadCfg(allocator, release_url, cfg) catch return;
    defer allocator.free(release);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, release, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return;
    const tag = stringField(parsed.value.object, "tag_name") orelse return;
    if (!newerThan(version.current, tag)) return;

    const wanted = try assetName(allocator);
    defer allocator.free(wanted);
    const url = findAssetUrl(parsed.value.object, wanted) orelse return;
    try downloadAndReplace(allocator, url, cfg);
}

pub fn startBackground(allocator: std.mem.Allocator, cfg: config.Config) void {
    const thread = std.Thread.spawn(.{ .stack_size = 256 * 1024 }, updateLoop, .{ allocator, cfg }) catch return;
    thread.detach();
}

fn updateLoop(allocator: std.mem.Allocator, cfg: config.Config) void {
    while (true) {
        std.Thread.sleep(6 * 60 * 60 * std.time.ns_per_s);
        checkAndUpdate(allocator, cfg) catch {};
    }
}

fn downloadAndReplace(allocator: std.mem.Allocator, url: []const u8, cfg: config.Config) !void {
    const body = try http.getReadCfg(allocator, url, cfg);
    defer allocator.free(body);
    const exe = try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(exe);
    const tmp = try std.fmt.allocPrint(allocator, "{s}.update", .{exe});
    defer allocator.free(tmp);
    {
        var file = try std.fs.createFileAbsolute(tmp, .{ .truncate = true, .mode = 0o755 });
        defer file.close();
        try file.writeAll(body);
    }
    try std.fs.renameAbsolute(tmp, exe);
    std.process.exit(42);
}

fn stringField(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    if (object.get(name)) |value| {
        if (value == .string) return value.string;
    }
    return null;
}

fn findAssetUrl(object: std.json.ObjectMap, wanted: []const u8) ?[]const u8 {
    const assets = object.get("assets") orelse return null;
    if (assets != .array) return null;
    for (assets.array.items) |asset| {
        if (asset != .object) continue;
        const name = stringField(asset.object, "name") orelse continue;
        if (std.mem.eql(u8, name, wanted)) return stringField(asset.object, "browser_download_url");
    }
    return null;
}

fn compareVersion(a_raw: []const u8, b_raw: []const u8) i32 {
    var ait = std.mem.splitScalar(u8, a_raw, '.');
    var bit = std.mem.splitScalar(u8, b_raw, '.');
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        const av = parseVersionPart(ait.next() orelse "0");
        const bv = parseVersionPart(bit.next() orelse "0");
        if (av > bv) return 1;
        if (av < bv) return -1;
    }
    return 0;
}

fn isNumericVersion(value_raw: []const u8) bool {
    const value = parseVersionPrefixless(value_raw);
    if (value.len == 0) return false;
    return value[0] >= '0' and value[0] <= '9';
}

fn parseVersionPart(part: []const u8) u64 {
    const end = std.mem.indexOfAny(u8, part, "-+") orelse part.len;
    return std.fmt.parseInt(u64, part[0..end], 10) catch 0;
}
