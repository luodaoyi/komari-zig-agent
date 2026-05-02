const std = @import("std");
const types = @import("types.zig");

pub fn allocTaskResultJson(allocator: std.mem.Allocator, task_id: []const u8, result: []const u8, exit_code: i32, finished_at: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try types.writeTaskResultJson(out.writer(allocator), .{
        .task_id = task_id,
        .result = result,
        .exit_code = exit_code,
        .finished_at = finished_at,
    });
    return out.toOwnedSlice(allocator);
}

pub fn runCommand(allocator: std.mem.Allocator, command: []const u8) ![]const u8 {
    if (command.len == 0) return allocator.dupe(u8, "No command provided");
    var child = std.process.Child.init(&.{ "sh", "-c", command }, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    const stdout = try child.stdout.?.readToEndAlloc(allocator, 1024 * 1024);
    const stderr = try child.stderr.?.readToEndAlloc(allocator, 1024 * 1024);
    _ = try child.wait();
    defer allocator.free(stdout);
    defer allocator.free(stderr);
    return std.mem.concat(allocator, u8, &.{ stdout, if (stderr.len > 0) "\n" else "", stderr });
}
