const std = @import("std");
pub const repo = "komari-monitor/komari-agent";

pub fn parseVersionPrefixless(version: []const u8) []const u8 {
    if (version.len > 0 and (version[0] == 'v' or version[0] == 'V')) return version[1..];
    return version;
}

pub fn checkAndUpdate(_: std.mem.Allocator) !void {}
pub fn startBackground(_: std.mem.Allocator) void {}
