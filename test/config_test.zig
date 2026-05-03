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
        "-u",           "-r", "7",   "-c", "11",
    };
    const cfg = try config.parseArgs(arena.allocator(), &args);
    try std.testing.expectEqualStrings("tok", cfg.token);
    try std.testing.expectEqualStrings("https://panel.example", cfg.endpoint);
    try std.testing.expectEqual(@as(f64, 2.5), cfg.interval);
    try std.testing.expect(cfg.ignore_unsafe_cert);
    try std.testing.expectEqual(@as(i32, 7), cfg.max_retries);
    try std.testing.expectEqual(@as(i32, 11), cfg.reconnect_interval);
}

test "full go-compatible cli flags parse" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const args = [_][]const u8{
        "komari-agent",
        "--auto-discovery",
        "discover-key",
        "--disable-auto-update",
        "--disable-web-ssh",
        "--info-report-interval",
        "30",
        "--include-nics",
        "eth0,wlan0",
        "--exclude-nics",
        "docker0",
        "--include-mountpoint",
        "/;/data",
        "--month-rotate",
        "8",
        "--cf-access-client-id",
        "cf-id",
        "--cf-access-client-secret",
        "cf-secret",
        "--memory-include-cache",
        "--memory-exclude-bcf",
        "--custom-dns",
        "1.1.1.1",
        "--gpu",
        "--show-warning",
        "--custom-ipv4",
        "192.0.2.10",
        "--custom-ipv6",
        "2001:db8::10",
        "--get-ip-addr-from-nic",
        "--config",
        "agent.json",
    };
    const cfg = try config.parseArgs(arena.allocator(), &args);

    try std.testing.expectEqualStrings("discover-key", cfg.auto_discovery_key);
    try std.testing.expect(cfg.disable_auto_update);
    try std.testing.expect(cfg.disable_web_ssh);
    try std.testing.expectEqual(@as(i32, 30), cfg.info_report_interval);
    try std.testing.expectEqualStrings("eth0,wlan0", cfg.include_nics);
    try std.testing.expectEqualStrings("docker0", cfg.exclude_nics);
    try std.testing.expectEqualStrings("/;/data", cfg.include_mountpoints);
    try std.testing.expectEqual(@as(i32, 8), cfg.month_rotate);
    try std.testing.expectEqualStrings("cf-id", cfg.cf_access_client_id);
    try std.testing.expectEqualStrings("cf-secret", cfg.cf_access_client_secret);
    try std.testing.expect(cfg.memory_include_cache);
    try std.testing.expect(cfg.memory_report_raw_used);
    try std.testing.expectEqualStrings("1.1.1.1", cfg.custom_dns);
    try std.testing.expect(cfg.enable_gpu);
    try std.testing.expect(cfg.show_warning);
    try std.testing.expectEqualStrings("192.0.2.10", cfg.custom_ipv4);
    try std.testing.expectEqualStrings("2001:db8::10", cfg.custom_ipv6);
    try std.testing.expect(cfg.get_ip_addr_from_nic);
    try std.testing.expectEqualStrings("agent.json", cfg.config_file);
}

test "go-style equals cli flags parse" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const args = [_][]const u8{
        "komari-agent",
        "--token=tok",
        "--endpoint=https://panel.example",
        "--interval=2.5",
        "--max-retries=8",
        "--reconnect-interval=13",
        "--include-nics=eth*",
        "--exclude-nics=docker*",
        "--include-mountpoint=/;/data",
        "--month-rotate=9",
        "--custom-dns=8.8.8.8",
        "--config=agent.json",
    };
    const cfg = try config.parseArgs(arena.allocator(), &args);

    try std.testing.expectEqualStrings("tok", cfg.token);
    try std.testing.expectEqualStrings("https://panel.example", cfg.endpoint);
    try std.testing.expectEqual(@as(f64, 2.5), cfg.interval);
    try std.testing.expectEqual(@as(i32, 8), cfg.max_retries);
    try std.testing.expectEqual(@as(i32, 13), cfg.reconnect_interval);
    try std.testing.expectEqualStrings("eth*", cfg.include_nics);
    try std.testing.expectEqualStrings("docker*", cfg.exclude_nics);
    try std.testing.expectEqualStrings("/;/data", cfg.include_mountpoints);
    try std.testing.expectEqual(@as(i32, 9), cfg.month_rotate);
    try std.testing.expectEqualStrings("8.8.8.8", cfg.custom_dns);
    try std.testing.expectEqualStrings("agent.json", cfg.config_file);
}

test "go-style equals bool cli flags parse" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const args = [_][]const u8{
        "komari-agent",
        "--disable-auto-update=true",
        "--disable-web-ssh=true",
        "--ignore-unsafe-cert=true",
        "--memory-include-cache=true",
        "--memory-exclude-bcf=true",
        "--gpu=true",
        "--show-warning=true",
        "--get-ip-addr-from-nic=true",
    };
    const cfg = try config.parseArgs(arena.allocator(), &args);

    try std.testing.expect(cfg.disable_auto_update);
    try std.testing.expect(cfg.disable_web_ssh);
    try std.testing.expect(cfg.ignore_unsafe_cert);
    try std.testing.expect(cfg.memory_include_cache);
    try std.testing.expect(cfg.memory_report_raw_used);
    try std.testing.expect(cfg.enable_gpu);
    try std.testing.expect(cfg.show_warning);
    try std.testing.expect(cfg.get_ip_addr_from_nic);
}

test "go-style equals bool cli flags parse false values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const args = [_][]const u8{
        "komari-agent",
        "--disable-auto-update=false",
        "--disable-web-ssh=0",
        "--ignore-unsafe-cert=False",
        "--memory-include-cache=no",
        "--memory-exclude-bcf=off",
        "--gpu=false",
        "--show-warning=0",
        "--get-ip-addr-from-nic=FALSE",
    };
    const cfg = try config.parseArgs(arena.allocator(), &args);

    try std.testing.expect(!cfg.disable_auto_update);
    try std.testing.expect(!cfg.disable_web_ssh);
    try std.testing.expect(!cfg.ignore_unsafe_cert);
    try std.testing.expect(!cfg.memory_include_cache);
    try std.testing.expect(!cfg.memory_report_raw_used);
    try std.testing.expect(!cfg.enable_gpu);
    try std.testing.expect(!cfg.show_warning);
    try std.testing.expect(!cfg.get_ip_addr_from_nic);
}

test "list-disk subcommand is recognized" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const args = [_][]const u8{ "komari-agent", "list-disk" };
    const cfg = try config.parseArgs(arena.allocator(), &args);
    try std.testing.expectEqual(config.Command.list_disk, cfg.command);
}

test "check-mem subcommand is recognized" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const args = [_][]const u8{ "komari-agent", "check-mem" };
    const cfg = try config.parseArgs(arena.allocator(), &args);
    try std.testing.expectEqual(config.Command.check_mem, cfg.command);
}

test "unknown flags are ignored" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const args = [_][]const u8{ "komari-agent", "--future-flag", "x", "--token", "tok" };
    const cfg = try config.parseArgs(arena.allocator(), &args);
    try std.testing.expectEqualStrings("tok", cfg.token);
}

test "missing cli flag values keep following flags parseable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const args = [_][]const u8{ "komari-agent", "--token", "--endpoint", "https://panel.example", "--max-retries" };
    const cfg = try config.parseArgs(arena.allocator(), &args);
    try std.testing.expectEqualStrings("", cfg.token);
    try std.testing.expectEqualStrings("https://panel.example", cfg.endpoint);
    try std.testing.expectEqual(@as(i32, 3), cfg.max_retries);
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
