const std = @import("std");
const builtin = @import("builtin");
const types = @import("types.zig");
const config = @import("../config.zig");
const http = @import("http.zig");

pub const AutoDiscoveryConfig = struct {
    uuid: []const u8 = "",
    token: []const u8 = "",
};

pub fn configPath(allocator: std.mem.Allocator) ![]const u8 {
    const exe = try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(exe);
    const dir = std.fs.path.dirname(exe) orelse ".";
    return std.fs.path.join(allocator, &.{ dir, "auto-discovery.json" });
}

pub fn load(allocator: std.mem.Allocator) !?AutoDiscoveryConfig {
    const path = try configPath(allocator);
    defer allocator.free(path);
    const bytes = std.fs.cwd().readFileAlloc(allocator, path, 64 * 1024) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(bytes);
    return parseStoredConfig(allocator, bytes);
}

pub fn save(allocator: std.mem.Allocator, value: AutoDiscoveryConfig) !void {
    const path = try configPath(allocator);
    defer allocator.free(path);
    var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    var writer = file.deprecatedWriter();
    try writer.print("{f}", .{std.json.fmt(value, .{ .whitespace = .indent_2 })});
}

pub fn applyExistingToken(allocator: std.mem.Allocator, cfg: *config.Config) !void {
    if (cfg.auto_discovery_key.len == 0) return;
    if (load(allocator) catch null) |stored| {
        cfg.token = stored.token;
        return;
    }
    try register(allocator, cfg);
}

pub fn parseStoredConfig(allocator: std.mem.Allocator, bytes: []const u8) !?AutoDiscoveryConfig {
    const parsed = std.json.parseFromSliceLeaky(AutoDiscoveryConfig, allocator, bytes, .{ .ignore_unknown_fields = true }) catch return null;
    if (parsed.token.len == 0) return null;
    return parsed;
}

pub fn allocRegisterRequest(allocator: std.mem.Allocator, key: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try types.writeAutoDiscoveryRequestJson(out.writer(allocator), .{ .key = key });
    return out.toOwnedSlice(allocator);
}

pub fn register(allocator: std.mem.Allocator, cfg: *config.Config) !void {
    const hostname_owned = try systemHostname(allocator);
    defer allocator.free(hostname_owned);
    const hostname = hostname_owned;
    const url = try http.registerUrl(allocator, cfg.endpoint, hostname);
    defer allocator.free(url);
    const payload = try allocRegisterRequest(allocator, cfg.auto_discovery_key);
    defer allocator.free(payload);
    const response = try http.postJsonReadAuth(allocator, url, payload, cfg.*, cfg.auto_discovery_key);
    defer allocator.free(response);
    const parsed = try parseRegisterResponse(allocator, response);
    try save(allocator, parsed);
    cfg.token = parsed.token;
}

pub fn systemHostname(allocator: std.mem.Allocator) ![]u8 {
    if (try posixHostname(allocator)) |hostname| return hostname;
    if (std.process.getEnvVarOwned(allocator, "HOSTNAME")) |hostname| {
        if (std.mem.trim(u8, hostname, " \t\r\n").len != 0) return hostname;
        allocator.free(hostname);
    } else |_| {}
    if (readTrimmedFile(allocator, "/etc/hostname")) |hostname| return hostname else |_| {}
    return allocator.dupe(u8, "komari-agent");
}

fn posixHostname(allocator: std.mem.Allocator) !?[]u8 {
    switch (builtin.os.tag) {
        .linux => return posixHostnameImpl(allocator),
        .macos, .freebsd => {
            if (comptime builtin.link_libc) return posixHostnameImpl(allocator);
            return null;
        },
        else => return null,
    }
}

fn posixHostnameImpl(allocator: std.mem.Allocator) !?[]u8 {
    var buf: [std.posix.HOST_NAME_MAX]u8 = undefined;
    const raw = std.posix.gethostname(&buf) catch return null;
    const hostname = std.mem.trim(u8, raw, " \t\r\n");
    if (hostname.len == 0) return null;
    return try allocator.dupe(u8, hostname);
}

fn readTrimmedFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const bytes = try std.fs.cwd().readFileAlloc(allocator, path, 4096);
    errdefer allocator.free(bytes);
    const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
    if (trimmed.len == bytes.len) return bytes;
    const out = try allocator.dupe(u8, trimmed);
    allocator.free(bytes);
    return out;
}

pub fn parseRegisterResponse(allocator: std.mem.Allocator, bytes: []const u8) !AutoDiscoveryConfig {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    const object = parsed.value.object;
    if (object.get("status")) |status| {
        if (status == .string and !std.mem.eql(u8, status.string, "success")) return error.AutoDiscoveryFailed;
    }
    const data = object.get("data") orelse return error.AutoDiscoveryBadResponse;
    if (data != .object) return error.AutoDiscoveryBadResponse;
    return .{
        .uuid = try dupeString(allocator, data.object, "uuid"),
        .token = try dupeString(allocator, data.object, "token"),
    };
}

fn dupeString(allocator: std.mem.Allocator, object: std.json.ObjectMap, key: []const u8) ![]const u8 {
    const value = object.get(key) orelse return error.AutoDiscoveryBadResponse;
    if (value != .string) return error.AutoDiscoveryBadResponse;
    return allocator.dupe(u8, value.string);
}
