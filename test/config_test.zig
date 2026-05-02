const std = @import("std");
const config = @import("config");

test "defaults match Go agent" {
    const cfg = config.Config.default();
    try std.testing.expectEqual(@as(f64, 1.0), cfg.interval);
    try std.testing.expectEqual(@as(i32, 3), cfg.max_retries);
    try std.testing.expectEqual(@as(i32, 5), cfg.reconnect_interval);
    try std.testing.expectEqual(@as(i32, 5), cfg.info_report_interval);
    try std.testing.expect(!cfg.disable_auto_update);
    try std.testing.expect(!cfg.disable_web_ssh);
}

test "cli aliases parse" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const args = [_][]const u8{
        "komari-agent", "-t", "tok", "-e", "https://panel.example", "-i", "2.5",
        "-u", "-r", "7", "-c", "11",
    };
    const cfg = try config.parseArgs(arena.allocator(), &args);
    try std.testing.expectEqualStrings("tok", cfg.token);
    try std.testing.expectEqualStrings("https://panel.example", cfg.endpoint);
    try std.testing.expectEqual(@as(f64, 2.5), cfg.interval);
    try std.testing.expect(cfg.ignore_unsafe_cert);
    try std.testing.expectEqual(@as(i32, 7), cfg.max_retries);
    try std.testing.expectEqual(@as(i32, 11), cfg.reconnect_interval);
}

test "unknown flags are ignored" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const args = [_][]const u8{ "komari-agent", "--future-flag", "x", "--token", "tok" };
    const cfg = try config.parseArgs(arena.allocator(), &args);
    try std.testing.expectEqualStrings("tok", cfg.token);
}

test "deprecated flags are ignored" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const args = [_][]const u8{
        "komari-agent", "--autoUpdate", "--memory-mode-available", "--token", "tok",
    };
    const cfg = try config.parseArgs(arena.allocator(), &args);
    try std.testing.expectEqualStrings("tok", cfg.token);
}

test "json config keys parse" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const json =
        \\{
        \\  "token": "json-token",
        \\  "endpoint": "https://json.example",
        \\  "disable_auto_update": true,
        \\  "disable_web_ssh": true,
        \\  "interval": 3.5,
        \\  "max_retries": 9,
        \\  "reconnect_interval": 12,
        \\  "info_report_interval": 30,
        \\  "include_nics": "eth0",
        \\  "month_rotate": 15,
        \\  "cf_access_client_id": "id",
        \\  "cf_access_client_secret": "secret",
        \\  "memory_include_cache": true,
        \\  "memory_report_raw_used": true,
        \\  "custom_dns": "1.1.1.1",
        \\  "enable_gpu": true,
        \\  "custom_ipv4": "192.0.2.1",
        \\  "custom_ipv6": "2001:db8::1",
        \\  "get_ip_addr_from_nic": true,
        \\  "host_proc": "/host/proc"
        \\}
    ;

    var cfg = config.Config.default();
    try cfg.loadJson(arena.allocator(), json);
    try std.testing.expectEqualStrings("json-token", cfg.token);
    try std.testing.expectEqualStrings("https://json.example", cfg.endpoint);
    try std.testing.expect(cfg.disable_auto_update);
    try std.testing.expect(cfg.disable_web_ssh);
    try std.testing.expectEqual(@as(f64, 3.5), cfg.interval);
    try std.testing.expectEqual(@as(i32, 9), cfg.max_retries);
    try std.testing.expectEqual(@as(i32, 12), cfg.reconnect_interval);
    try std.testing.expectEqual(@as(i32, 30), cfg.info_report_interval);
    try std.testing.expectEqualStrings("eth0", cfg.include_nics);
    try std.testing.expectEqual(@as(i32, 15), cfg.month_rotate);
    try std.testing.expectEqualStrings("id", cfg.cf_access_client_id);
    try std.testing.expectEqualStrings("secret", cfg.cf_access_client_secret);
    try std.testing.expect(cfg.memory_include_cache);
    try std.testing.expect(cfg.memory_report_raw_used);
    try std.testing.expectEqualStrings("1.1.1.1", cfg.custom_dns);
    try std.testing.expect(cfg.enable_gpu);
    try std.testing.expectEqualStrings("192.0.2.1", cfg.custom_ipv4);
    try std.testing.expectEqualStrings("2001:db8::1", cfg.custom_ipv6);
    try std.testing.expect(cfg.get_ip_addr_from_nic);
    try std.testing.expectEqualStrings("/host/proc", cfg.host_proc);
}
