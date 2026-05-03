const std = @import("std");
const types = @import("protocol_types");

test "basic info payload matches golden json" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    try types.writeBasicInfoJson(&out.writer, .{
        .cpu_name = "CPU",
        .cpu_cores = 4,
        .arch = "amd64",
        .os = "linux",
        .kernel_version = "6.1.0",
        .ipv4 = "192.0.2.1",
        .ipv6 = "2001:db8::1",
        .mem_total = 1024,
        .swap_total = 2048,
        .disk_total = 4096,
        .gpu_name = "GPU",
        .virtualization = "kvm",
        .version = "0.0.1",
    }, true);
    try expectJsonEqual(out.written(), @embedFile("golden/basic_info.json"));
}

test "task result payload matches golden json" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    try types.writeTaskResultJson(&out.writer, .{
        .task_id = "t1",
        .result = "ok",
        .exit_code = 0,
        .finished_at = "2026-05-02T00:00:00Z",
    });
    try expectJsonEqual(out.written(), @embedFile("golden/task_result.json"));
}

test "ping result payload matches golden json" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    try types.writePingResultJson(&out.writer, .{
        .task_id = 9,
        .ping_type = "tcp",
        .value = 12,
        .finished_at = "2026-05-02T00:00:00Z",
    });
    try expectJsonEqual(out.written(), @embedFile("golden/ping_result.json"));
}

test "auto discovery request matches golden json" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    try types.writeAutoDiscoveryRequestJson(&out.writer, .{ .key = "secret" });
    try expectJsonEqual(out.written(), @embedFile("golden/autodiscovery_request.json"));
}

test "report payload matches golden json" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    try types.writeReportJson(&out.writer, .{
        .cpu = .{ .usage = 0.001 },
        .ram = .{ .total = 1024, .used = 512 },
        .swap = .{ .total = 2048, .used = 256 },
        .load = .{ .load1 = 0.1, .load5 = 0.2, .load15 = 0.3 },
        .disk = .{ .total = 4096, .used = 1024 },
        .network = .{ .up = 10, .down = 20, .totalUp = 100, .totalDown = 200 },
        .connections = .{ .tcp = 3, .udp = 4 },
        .uptime = 99,
        .process = 8,
        .message = "",
    });
    try expectJsonEqual(out.written(), @embedFile("golden/report.json"));
}

fn expectJsonEqual(actual: []const u8, expected: []const u8) !void {
    try std.testing.expectEqualStrings(std.mem.trimEnd(u8, expected, "\r\n"), actual);
}
