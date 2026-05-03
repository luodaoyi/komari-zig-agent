const std = @import("std");
const compat = @import("compat");

/// CLI, environment, and JSON configuration loading for the agent.
pub const Command = enum {
    run,
    list_disk,
    check_mem,
};

pub const Config = struct {
    command: Command = .run,
    auto_discovery_key: []const u8 = "",
    disable_auto_update: bool = false,
    disable_web_ssh: bool = false,
    memory_mode_available: bool = false,
    token: []const u8 = "",
    endpoint: []const u8 = "",
    interval: f64 = 1.0,
    ignore_unsafe_cert: bool = false,
    max_retries: i32 = 3,
    reconnect_interval: i32 = 5,
    info_report_interval: i32 = 5,
    include_nics: []const u8 = "",
    exclude_nics: []const u8 = "",
    include_mountpoints: []const u8 = "",
    month_rotate: i32 = 0,
    cf_access_client_id: []const u8 = "",
    cf_access_client_secret: []const u8 = "",
    memory_include_cache: bool = false,
    memory_report_raw_used: bool = false,
    custom_dns: []const u8 = "",
    enable_gpu: bool = false,
    show_warning: bool = false,
    custom_ipv4: []const u8 = "",
    custom_ipv6: []const u8 = "",
    get_ip_addr_from_nic: bool = false,
    host_proc: []const u8 = "",
    config_file: []const u8 = "",

    pub fn default() Config {
        return .{};
    }

    pub fn loadJson(self: *Config, allocator: std.mem.Allocator, bytes: []const u8) !void {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
        defer parsed.deinit();

        const object = parsed.value.object;
        try setStringJson(allocator, object, "auto_discovery_key", &self.auto_discovery_key);
        try setBoolJson(object, "disable_auto_update", &self.disable_auto_update);
        try setBoolJson(object, "disable_web_ssh", &self.disable_web_ssh);
        try setBoolJson(object, "memory_mode_available", &self.memory_mode_available);
        try setStringJson(allocator, object, "token", &self.token);
        try setStringJson(allocator, object, "endpoint", &self.endpoint);
        try setFloatJson(object, "interval", &self.interval);
        try setBoolJson(object, "ignore_unsafe_cert", &self.ignore_unsafe_cert);
        try setIntJson(object, "max_retries", &self.max_retries);
        try setIntJson(object, "reconnect_interval", &self.reconnect_interval);
        try setIntJson(object, "info_report_interval", &self.info_report_interval);
        try setStringJson(allocator, object, "include_nics", &self.include_nics);
        try setStringJson(allocator, object, "exclude_nics", &self.exclude_nics);
        try setStringJson(allocator, object, "include_mountpoints", &self.include_mountpoints);
        try setIntJson(object, "month_rotate", &self.month_rotate);
        try setStringJson(allocator, object, "cf_access_client_id", &self.cf_access_client_id);
        try setStringJson(allocator, object, "cf_access_client_secret", &self.cf_access_client_secret);
        try setBoolJson(object, "memory_include_cache", &self.memory_include_cache);
        try setBoolJson(object, "memory_report_raw_used", &self.memory_report_raw_used);
        try setStringJson(allocator, object, "custom_dns", &self.custom_dns);
        try setBoolJson(object, "enable_gpu", &self.enable_gpu);
        try setBoolJson(object, "show_warning", &self.show_warning);
        try setStringJson(allocator, object, "custom_ipv4", &self.custom_ipv4);
        try setStringJson(allocator, object, "custom_ipv6", &self.custom_ipv6);
        try setBoolJson(object, "get_ip_addr_from_nic", &self.get_ip_addr_from_nic);
        try setStringJson(allocator, object, "host_proc", &self.host_proc);
        try setStringJson(allocator, object, "config_file", &self.config_file);
    }

    pub fn loadJsonFile(self: *Config, allocator: std.mem.Allocator, path: []const u8) !void {
        const bytes = try compat.readFileAlloc(allocator, path, 1024 * 1024);
        defer allocator.free(bytes);
        try self.loadJson(allocator, bytes);
    }

    pub fn loadEnv(self: *Config, allocator: std.mem.Allocator) !void {
        try setStringEnv(allocator, "AGENT_AUTO_DISCOVERY_KEY", &self.auto_discovery_key);
        setBoolEnv("AGENT_DISABLE_AUTO_UPDATE", &self.disable_auto_update);
        setBoolEnv("AGENT_DISABLE_WEB_SSH", &self.disable_web_ssh);
        setBoolEnv("AGENT_MEMORY_MODE_AVAILABLE", &self.memory_mode_available);
        try setStringEnv(allocator, "AGENT_TOKEN", &self.token);
        try setStringEnv(allocator, "AGENT_ENDPOINT", &self.endpoint);
        setFloatEnv("AGENT_INTERVAL", &self.interval);
        setBoolEnv("AGENT_IGNORE_UNSAFE_CERT", &self.ignore_unsafe_cert);
        setIntEnv("AGENT_MAX_RETRIES", &self.max_retries);
        setIntEnv("AGENT_RECONNECT_INTERVAL", &self.reconnect_interval);
        setIntEnv("AGENT_INFO_REPORT_INTERVAL", &self.info_report_interval);
        try setStringEnv(allocator, "AGENT_INCLUDE_NICS", &self.include_nics);
        try setStringEnv(allocator, "AGENT_EXCLUDE_NICS", &self.exclude_nics);
        try setStringEnv(allocator, "AGENT_INCLUDE_MOUNTPOINTS", &self.include_mountpoints);
        setIntEnv("AGENT_MONTH_ROTATE", &self.month_rotate);
        try setStringEnv(allocator, "AGENT_CF_ACCESS_CLIENT_ID", &self.cf_access_client_id);
        try setStringEnv(allocator, "AGENT_CF_ACCESS_CLIENT_SECRET", &self.cf_access_client_secret);
        setBoolEnv("AGENT_MEMORY_INCLUDE_CACHE", &self.memory_include_cache);
        setBoolEnv("AGENT_MEMORY_REPORT_RAW_USED", &self.memory_report_raw_used);
        try setStringEnv(allocator, "AGENT_CUSTOM_DNS", &self.custom_dns);
        setBoolEnv("AGENT_ENABLE_GPU", &self.enable_gpu);
        setBoolEnv("AGENT_SHOW_WARNING", &self.show_warning);
        try setStringEnv(allocator, "AGENT_CUSTOM_IPV4", &self.custom_ipv4);
        try setStringEnv(allocator, "AGENT_CUSTOM_IPV6", &self.custom_ipv6);
        setBoolEnv("AGENT_GET_IP_ADDR_FROM_NIC", &self.get_ip_addr_from_nic);
        try setStringEnv(allocator, "HOST_PROC", &self.host_proc);
        try setStringEnv(allocator, "AGENT_CONFIG_FILE", &self.config_file);
    }
};

pub fn parseArgs(allocator: std.mem.Allocator, args: []const []const u8) !Config {
    var cfg = Config.default();
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (isDeprecated(arg)) {
            continue;
        }

        if (std.mem.eql(u8, arg, "list-disk")) {
            cfg.command = .list_disk;
        } else if (std.mem.eql(u8, arg, "check-mem")) {
            cfg.command = .check_mem;
        } else if (optionValue(arg, "--token")) |v| {
            cfg.token = try allocator.dupe(u8, v);
        } else if (optionValue(arg, "--endpoint")) |v| {
            cfg.endpoint = try allocator.dupe(u8, v);
        } else if (optionValue(arg, "--auto-discovery")) |v| {
            cfg.auto_discovery_key = try allocator.dupe(u8, v);
        } else if (optionValue(arg, "--interval")) |v| {
            cfg.interval = try std.fmt.parseFloat(f64, v);
        } else if (optionValue(arg, "--max-retries")) |v| {
            cfg.max_retries = try std.fmt.parseInt(i32, v, 10);
        } else if (optionValue(arg, "--reconnect-interval")) |v| {
            cfg.reconnect_interval = try std.fmt.parseInt(i32, v, 10);
        } else if (optionValue(arg, "--info-report-interval")) |v| {
            cfg.info_report_interval = try std.fmt.parseInt(i32, v, 10);
        } else if (optionValue(arg, "--include-nics")) |v| {
            cfg.include_nics = try allocator.dupe(u8, v);
        } else if (optionValue(arg, "--exclude-nics")) |v| {
            cfg.exclude_nics = try allocator.dupe(u8, v);
        } else if (optionValue(arg, "--include-mountpoint")) |v| {
            cfg.include_mountpoints = try allocator.dupe(u8, v);
        } else if (optionValue(arg, "--month-rotate")) |v| {
            cfg.month_rotate = try std.fmt.parseInt(i32, v, 10);
        } else if (optionValue(arg, "--cf-access-client-id")) |v| {
            cfg.cf_access_client_id = try allocator.dupe(u8, v);
        } else if (optionValue(arg, "--cf-access-client-secret")) |v| {
            cfg.cf_access_client_secret = try allocator.dupe(u8, v);
        } else if (optionValue(arg, "--custom-dns")) |v| {
            cfg.custom_dns = try allocator.dupe(u8, v);
        } else if (optionValue(arg, "--custom-ipv4")) |v| {
            cfg.custom_ipv4 = try allocator.dupe(u8, v);
        } else if (optionValue(arg, "--custom-ipv6")) |v| {
            cfg.custom_ipv6 = try allocator.dupe(u8, v);
        } else if (optionValue(arg, "--config")) |v| {
            cfg.config_file = try allocator.dupe(u8, v);
        } else if (boolOptionValue(arg, "--disable-auto-update")) |v| {
            cfg.disable_auto_update = v;
        } else if (boolOptionValue(arg, "--disable-web-ssh")) |v| {
            cfg.disable_web_ssh = v;
        } else if (boolOptionValue(arg, "--ignore-unsafe-cert")) |v| {
            cfg.ignore_unsafe_cert = v;
        } else if (boolOptionValue(arg, "--memory-include-cache")) |v| {
            cfg.memory_include_cache = v;
        } else if (boolOptionValue(arg, "--memory-exclude-bcf")) |v| {
            cfg.memory_report_raw_used = v;
        } else if (boolOptionValue(arg, "--gpu")) |v| {
            cfg.enable_gpu = v;
        } else if (boolOptionValue(arg, "--show-warning")) |v| {
            cfg.show_warning = v;
        } else if (boolOptionValue(arg, "--get-ip-addr-from-nic")) |v| {
            cfg.get_ip_addr_from_nic = v;
        } else if (std.mem.eql(u8, arg, "-t") or std.mem.eql(u8, arg, "--token")) {
            if (nextValue(args, &i)) |v| cfg.token = try allocator.dupe(u8, v);
        } else if (std.mem.eql(u8, arg, "-e") or std.mem.eql(u8, arg, "--endpoint")) {
            if (nextValue(args, &i)) |v| cfg.endpoint = try allocator.dupe(u8, v);
        } else if (std.mem.eql(u8, arg, "--auto-discovery")) {
            if (nextValue(args, &i)) |v| cfg.auto_discovery_key = try allocator.dupe(u8, v);
        } else if (std.mem.eql(u8, arg, "--disable-auto-update")) {
            cfg.disable_auto_update = true;
        } else if (std.mem.eql(u8, arg, "--disable-web-ssh")) {
            cfg.disable_web_ssh = true;
        } else if (std.mem.eql(u8, arg, "-i") or std.mem.eql(u8, arg, "--interval")) {
            if (nextValue(args, &i)) |v| cfg.interval = try std.fmt.parseFloat(f64, v);
        } else if (std.mem.eql(u8, arg, "-u") or std.mem.eql(u8, arg, "--ignore-unsafe-cert")) {
            cfg.ignore_unsafe_cert = true;
        } else if (std.mem.eql(u8, arg, "-r") or std.mem.eql(u8, arg, "--max-retries")) {
            if (nextValue(args, &i)) |v| cfg.max_retries = try std.fmt.parseInt(i32, v, 10);
        } else if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--reconnect-interval")) {
            if (nextValue(args, &i)) |v| cfg.reconnect_interval = try std.fmt.parseInt(i32, v, 10);
        } else if (std.mem.eql(u8, arg, "--info-report-interval")) {
            if (nextValue(args, &i)) |v| cfg.info_report_interval = try std.fmt.parseInt(i32, v, 10);
        } else if (std.mem.eql(u8, arg, "--include-nics")) {
            if (nextValue(args, &i)) |v| cfg.include_nics = try allocator.dupe(u8, v);
        } else if (std.mem.eql(u8, arg, "--exclude-nics")) {
            if (nextValue(args, &i)) |v| cfg.exclude_nics = try allocator.dupe(u8, v);
        } else if (std.mem.eql(u8, arg, "--include-mountpoint")) {
            if (nextValue(args, &i)) |v| cfg.include_mountpoints = try allocator.dupe(u8, v);
        } else if (std.mem.eql(u8, arg, "--month-rotate")) {
            if (nextValue(args, &i)) |v| cfg.month_rotate = try std.fmt.parseInt(i32, v, 10);
        } else if (std.mem.eql(u8, arg, "--cf-access-client-id")) {
            if (nextValue(args, &i)) |v| cfg.cf_access_client_id = try allocator.dupe(u8, v);
        } else if (std.mem.eql(u8, arg, "--cf-access-client-secret")) {
            if (nextValue(args, &i)) |v| cfg.cf_access_client_secret = try allocator.dupe(u8, v);
        } else if (std.mem.eql(u8, arg, "--memory-include-cache")) {
            cfg.memory_include_cache = true;
        } else if (std.mem.eql(u8, arg, "--memory-exclude-bcf")) {
            cfg.memory_report_raw_used = true;
        } else if (std.mem.eql(u8, arg, "--custom-dns")) {
            if (nextValue(args, &i)) |v| cfg.custom_dns = try allocator.dupe(u8, v);
        } else if (std.mem.eql(u8, arg, "--gpu")) {
            cfg.enable_gpu = true;
        } else if (std.mem.eql(u8, arg, "--show-warning")) {
            cfg.show_warning = true;
        } else if (std.mem.eql(u8, arg, "--custom-ipv4")) {
            if (nextValue(args, &i)) |v| cfg.custom_ipv4 = try allocator.dupe(u8, v);
        } else if (std.mem.eql(u8, arg, "--custom-ipv6")) {
            if (nextValue(args, &i)) |v| cfg.custom_ipv6 = try allocator.dupe(u8, v);
        } else if (std.mem.eql(u8, arg, "--get-ip-addr-from-nic")) {
            cfg.get_ip_addr_from_nic = true;
        } else if (std.mem.eql(u8, arg, "--config")) {
            if (nextValue(args, &i)) |v| cfg.config_file = try allocator.dupe(u8, v);
        } else if (std.mem.startsWith(u8, arg, "-")) {
            _ = nextValue(args, &i);
        }
    }
    return cfg;
}

fn optionValue(arg: []const u8, name: []const u8) ?[]const u8 {
    if (arg.len <= name.len or !std.mem.startsWith(u8, arg, name) or arg[name.len] != '=') return null;
    return arg[name.len + 1 ..];
}

fn boolOptionValue(arg: []const u8, name: []const u8) ?bool {
    const value = optionValue(arg, name) orelse return null;
    return parseBool(value);
}

fn parseBool(value: []const u8) bool {
    return std.ascii.eqlIgnoreCase(value, "true") or std.mem.eql(u8, value, "1");
}

fn nextValue(args: []const []const u8, index: *usize) ?[]const u8 {
    if (index.* + 1 >= args.len) return null;
    const next = args[index.* + 1];
    if (std.mem.startsWith(u8, next, "-")) return null;
    index.* += 1;
    return next;
}

fn isDeprecated(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "-autoUpdate") or
        std.mem.eql(u8, arg, "--autoUpdate") or
        std.mem.eql(u8, arg, "-memory-mode-available") or
        std.mem.eql(u8, arg, "--memory-mode-available");
}

fn setStringJson(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    key: []const u8,
    out: *[]const u8,
) !void {
    if (object.get(key)) |value| {
        if (value == .string) out.* = try allocator.dupe(u8, value.string);
    }
}

fn setBoolJson(object: std.json.ObjectMap, key: []const u8, out: *bool) !void {
    if (object.get(key)) |value| {
        if (value == .bool) out.* = value.bool;
    }
}

fn setIntJson(object: std.json.ObjectMap, key: []const u8, out: *i32) !void {
    if (object.get(key)) |value| {
        switch (value) {
            .integer => |v| out.* = @intCast(v),
            else => {},
        }
    }
}

fn setFloatJson(object: std.json.ObjectMap, key: []const u8, out: *f64) !void {
    if (object.get(key)) |value| {
        switch (value) {
            .float => |v| out.* = v,
            .integer => |v| out.* = @floatFromInt(v),
            else => {},
        }
    }
}

fn setStringEnv(allocator: std.mem.Allocator, key: []const u8, out: *[]const u8) !void {
    if (compat.getEnvVarOwned(allocator, key)) |value| {
        out.* = value;
    } else |_| {}
}

fn setBoolEnv(key: []const u8, out: *bool) void {
    var buf: [16]u8 = undefined;
    if (compat.getEnvVarOwned(std.heap.page_allocator, key)) |value| {
        defer std.heap.page_allocator.free(value);
        const lowered = std.ascii.lowerString(&buf, value[0..@min(value.len, buf.len)]);
        out.* = std.mem.eql(u8, lowered, "true") or std.mem.eql(u8, value, "1");
    } else |_| {}
}

fn setIntEnv(key: []const u8, out: *i32) void {
    var buf: [64]u8 = undefined;
    if (compat.getEnvVarOwned(std.heap.page_allocator, key)) |value| {
        defer std.heap.page_allocator.free(value);
        if (value.len <= buf.len) {
            @memcpy(buf[0..value.len], value);
            out.* = std.fmt.parseInt(i32, buf[0..value.len], 10) catch out.*;
        }
    } else |_| {}
}

fn setFloatEnv(key: []const u8, out: *f64) void {
    if (compat.getEnvVarOwned(std.heap.page_allocator, key)) |value| {
        defer std.heap.page_allocator.free(value);
        out.* = std.fmt.parseFloat(f64, value) catch out.*;
    } else |_| {}
}
