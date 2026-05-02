const std = @import("std");

pub const Input = union(enum) {
    input: []const u8,
    resize: struct { cols: u16, rows: u16 },
    raw: []const u8,
};

pub fn parseInput(bytes: []const u8) Input {
    var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, bytes, .{}) catch return .{ .raw = bytes };
    defer parsed.deinit();
    const obj = parsed.value.object;
    const typ = obj.get("type") orelse return .{ .raw = bytes };
    if (typ != .string) return .{ .raw = bytes };
    if (std.mem.eql(u8, typ.string, "input")) {
        if (obj.get("input")) |v| if (v == .string) return .{ .input = v.string };
    }
    if (std.mem.eql(u8, typ.string, "resize")) {
        const cols = if (obj.get("cols")) |v| if (v == .integer) @as(u16, @intCast(v.integer)) else 0 else 0;
        const rows = if (obj.get("rows")) |v| if (v == .integer) @as(u16, @intCast(v.integer)) else 0 else 0;
        return .{ .resize = .{ .cols = cols, .rows = rows } };
    }
    return .{ .raw = bytes };
}

pub fn startDisabledMessage() []const u8 {
    return "\n\nWeb SSH is disabled. Enable it by running without the --disable-web-ssh flag.";
}
