//! Shared GPU name aggregation and NVIDIA detailed-metric parsing.

const std = @import("std");

pub const NameCount = struct {
    name: []const u8,
    count: u32,
};

pub const NameList = struct {
    items: std.ArrayList(NameCount) = .empty,

    pub fn deinit(self: *NameList, allocator: std.mem.Allocator) void {
        for (self.items.items) |item| allocator.free(item.name);
        self.items.deinit(allocator);
    }

    pub fn append(
        self: *NameList,
        allocator: std.mem.Allocator,
        name_raw: []const u8,
    ) !void {
        const name = std.mem.trim(u8, name_raw, " \t\r\n");
        if (name.len == 0 or std.mem.eql(u8, name, "None")) return;

        for (self.items.items) |*item| {
            if (std.mem.eql(u8, item.name, name)) {
                item.count = item.count +| 1;
                return;
            }
        }

        try self.items.append(allocator, .{
            .name = try allocator.dupe(u8, name),
            .count = 1,
        });
    }

    pub fn format(
        self: *const NameList,
        allocator: std.mem.Allocator,
        empty_name: []const u8,
    ) ![]const u8 {
        if (self.items.items.len == 0) return allocator.dupe(u8, empty_name);

        var out = std.Io.Writer.Allocating.init(allocator);
        defer out.deinit();
        for (self.items.items, 0..) |item, index| {
            if (index != 0) try out.writer.writeAll(", ");
            if (item.count > 1) {
                try out.writer.print("{s} × {d}", .{ item.name, item.count });
            } else {
                try out.writer.writeAll(item.name);
            }
        }
        return out.toOwnedSlice();
    }
};

pub const DetailedGpuInfo = struct {
    name: []const u8,
    memory_total: u64,
    memory_used: u64,
    utilization: f64,
    temperature: u64,
};

pub const DetailedGpuReport = struct {
    count: u64,
    average_usage: f64,
    detailed_info: []const DetailedGpuInfo,
};

pub fn allocOutputNames(
    allocator: std.mem.Allocator,
    options: struct {
        output: []const u8,
        empty_name: []const u8,
    },
) ![]const u8 {
    var names: NameList = .{};
    defer names.deinit(allocator);

    var lines = std.mem.splitScalar(u8, options.output, '\n');
    while (lines.next()) |line| try names.append(allocator, line);
    return names.format(allocator, options.empty_name);
}

pub fn allocDarwinNames(allocator: std.mem.Allocator, output: []const u8) ![]const u8 {
    var names: NameList = .{};
    defer names.deinit(allocator);

    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r\n");
        if (!std.mem.startsWith(u8, line, "Chipset Model:")) continue;
        try names.append(allocator, line["Chipset Model:".len..]);
    }
    return names.format(allocator, "None");
}

pub fn allocFreeBsdNames(allocator: std.mem.Allocator, output: []const u8) ![]const u8 {
    var names: NameList = .{};
    defer names.deinit(allocator);

    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r\n");
        if (std.mem.indexOf(u8, line, "VGA") == null and
            std.mem.indexOf(u8, line, "Display") == null)
        {
            continue;
        }
        try names.append(allocator, line);
    }
    return names.format(allocator, "None");
}

pub fn allocNvidiaDetailedJson(
    allocator: std.mem.Allocator,
    output: []const u8,
) ![]const u8 {
    var devices: std.ArrayList(DetailedGpuInfo) = .empty;
    defer devices.deinit(allocator);

    var usage_sum: f64 = 0;
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r\n");
        if (line.len == 0) continue;
        const device = parseNvidiaLine(line) orelse continue;
        try devices.append(allocator, device);
        usage_sum += device.utilization;
    }
    if (devices.items.len == 0) return error.NoGpuDetails;

    const count: u64 = @intCast(devices.items.len);
    const report = DetailedGpuReport{
        .count = count,
        .average_usage = usage_sum / @as(f64, @floatFromInt(count)),
        .detailed_info = devices.items,
    };
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    try out.writer.print("{f}", .{std.json.fmt(report, .{})});
    return out.toOwnedSlice();
}

fn parseNvidiaLine(line: []const u8) ?DetailedGpuInfo {
    var commas: [4]usize = undefined;
    var end = line.len;
    var remaining: u8 = commas.len;
    while (remaining > 0) {
        remaining -= 1;
        const comma = std.mem.lastIndexOfScalar(u8, line[0..end], ',') orelse return null;
        commas[remaining] = comma;
        end = comma;
    }

    const name = std.mem.trim(u8, line[0..commas[0]], " \t\"");
    if (name.len == 0) return null;
    return .{
        .name = name,
        .memory_total = parseMiB(line[commas[0] + 1 .. commas[1]]),
        .memory_used = parseMiB(line[commas[1] + 1 .. commas[2]]),
        .utilization = parseFloat(line[commas[2] + 1 .. commas[3]]),
        .temperature = parseInteger(line[commas[3] + 1 ..]),
    };
}

fn parseFloat(value: []const u8) f64 {
    return std.fmt.parseFloat(f64, std.mem.trim(u8, value, " \t\r\n")) catch 0;
}

fn parseInteger(value: []const u8) u64 {
    return std.fmt.parseInt(u64, std.mem.trim(u8, value, " \t\r\n"), 10) catch 0;
}

fn parseMiB(value: []const u8) u64 {
    const amount = parseInteger(value);
    return std.math.mul(u64, amount, 1024 * 1024) catch 0;
}

test "GPU names preserve order and group repeated models" {
    // The formatter must retain discovery order while compacting duplicates.
    const actual = try allocOutputNames(std.testing.allocator, .{
        .output = "NVIDIA RTX\nAMD Radeon\nNVIDIA RTX\n\nNone\n",
        .empty_name = "None",
    });
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings("NVIDIA RTX × 2, AMD Radeon", actual);
}

test "Darwin and FreeBSD GPU parsers collect every display adapter" {
    // Platform command output is parsed without executing platform-specific tools.
    const darwin = try allocDarwinNames(
        std.testing.allocator,
        "Chipset Model: Apple M4\nChipset Model: Apple M4\nChipset Model: eGPU\n",
    );
    defer std.testing.allocator.free(darwin);
    try std.testing.expectEqualStrings("Apple M4 × 2, eGPU", darwin);

    const freebsd = try allocFreeBsdNames(
        std.testing.allocator,
        "vgapci0: <VGA NVIDIA>\nvgapci1: <VGA NVIDIA>\nnone0: <Network>\n",
    );
    defer std.testing.allocator.free(freebsd);
    try std.testing.expectEqualStrings("vgapci0: <VGA NVIDIA>, vgapci1: <VGA NVIDIA>", freebsd);
}

test "NVIDIA CSV parser emits detailed multi-GPU JSON" {
    // The last four columns are metrics, so commas inside a quoted model remain valid.
    const json = try allocNvidiaDetailedJson(
        std.testing.allocator,
        "\"NVIDIA RTX, Test\", 1024, 256, 25, 50\r\nNVIDIA RTX 2, 2048, 512, 75, 60\n",
    );
    defer std.testing.allocator.free(json);

    const parsed = try std.json.parseFromSlice(DetailedGpuReport, std.testing.allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u64, 2), parsed.value.count);
    try std.testing.expectApproxEqAbs(@as(f64, 50), parsed.value.average_usage, 0.001);
    try std.testing.expectEqualStrings("NVIDIA RTX, Test", parsed.value.detailed_info[0].name);
    try std.testing.expectEqual(@as(u64, 1024 * 1024 * 1024), parsed.value.detailed_info[0].memory_total);
    try std.testing.expectEqual(@as(u64, 60), parsed.value.detailed_info[1].temperature);
}

test "NVIDIA CSV parser rejects output without complete devices" {
    // Partial command output must not create a zero-valued phantom GPU.
    try std.testing.expectError(
        error.NoGpuDetails,
        allocNvidiaDetailedJson(std.testing.allocator, "NVIDIA RTX, 1024, 256\n"),
    );
}
