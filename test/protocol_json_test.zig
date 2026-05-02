const std = @import("std");
const types = @import("protocol_types");

test "basic info payload matches golden json" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);

    try types.writeBasicInfoJson(out.writer(std.testing.allocator), .{
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
    try expectJsonEqual(out.items, @embedFile("golden/basic_info.json"));
}

test "task result payload matches golden json" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);

    try types.writeTaskResultJson(out.writer(std.testing.allocator), .{
        .task_id = "t1",
        .result = "ok",
        .exit_code = 0,
        .finished_at = "2026-05-02T00:00:00Z",
    });
    try expectJsonEqual(out.items, @embedFile("golden/task_result.json"));
}

test "ping result payload matches golden json" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);

    try types.writePingResultJson(out.writer(std.testing.allocator), .{
        .task_id = 9,
        .ping_type = "tcp",
        .value = 12,
        .finished_at = "2026-05-02T00:00:00Z",
    });
    try expectJsonEqual(out.items, @embedFile("golden/ping_result.json"));
}

test "auto discovery request matches golden json" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);

    try types.writeAutoDiscoveryRequestJson(out.writer(std.testing.allocator), .{ .key = "secret" });
    try expectJsonEqual(out.items, @embedFile("golden/autodiscovery_request.json"));
}

test "report payload matches golden json" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);

    try types.writeReportJson(out.writer(std.testing.allocator), .{
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
    try expectJsonEqual(out.items, @embedFile("golden/report.json"));
}

fn expectJsonEqual(actual: []const u8, expected: []const u8) !void {
    try std.testing.expectEqualStrings(std.mem.trimRight(u8, expected, "\r\n"), actual);
}
