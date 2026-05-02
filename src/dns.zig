const std = @import("std");

pub fn normalizeDnsServer(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    const s = std.mem.trim(u8, input, " \t\r\n");
    if (s.len == 0) return allocator.dupe(u8, "");
    if (std.mem.startsWith(u8, s, "[") and std.mem.indexOf(u8, s, "]:") != null) {
        return allocator.dupe(u8, s);
    }
    if (std.mem.count(u8, s, ":") == 1) {
        return allocator.dupe(u8, s);
    }
    if (std.mem.count(u8, s, ":") >= 2) {
        return std.fmt.allocPrint(allocator, "[{s}]:53", .{s});
    }
    return std.fmt.allocPrint(allocator, "{s}:53", .{s});
}
