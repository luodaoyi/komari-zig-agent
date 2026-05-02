const std = @import("std");
const types = @import("types.zig");
const config = @import("../config.zig");

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
    const parsed = try std.json.parseFromSliceLeaky(AutoDiscoveryConfig, allocator, bytes, .{ .ignore_unknown_fields = true });
    return parsed;
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
    if (try load(allocator)) |stored| {
        cfg.token = stored.token;
    }
}

pub fn allocRegisterRequest(allocator: std.mem.Allocator, key: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try types.writeAutoDiscoveryRequestJson(out.writer(allocator), .{ .key = key });
    return out.toOwnedSlice(allocator);
}
