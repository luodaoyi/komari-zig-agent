const std = @import("std");
const version = @import("version.zig");

pub fn main() !void {
    var stdout = std.fs.File.stdout().deprecatedWriter();
    try stdout.print("Komari Agent {s}\n", .{version.current});
}
