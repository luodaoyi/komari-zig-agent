const std = @import("std");
const debug = @import("debug");
const http = @import("http.zig");
const net = @import("net");
const raw_conn = @import("raw_conn.zig");

/// Public IP discovery helpers for IPv4 and IPv6 reporting.
pub const external_lookup_timeout_ms: u64 = 5_000;
pub const external_lookup_max_retries: i32 = 0;

const ipv4_apis = [_][]const u8{
    "https://www.visa.cn/cdn-cgi/trace",
    "https://www.qualcomm.cn/cdn-cgi/trace",
    "https://www.toutiao.com/stream/widget/local_weather/data/",
    "https://edge-ip.html.zone/geo",
    "https://vercel-ip.html.zone/geo",
    "http://ipv4.ip.sb",
    "https://api.ipify.org?format=json",
};

const ipv6_apis = [_][]const u8{
    "https://v6.ip.zxinc.org/info.php?type=json",
    "https://api6.ipify.org?format=json",
    "https://ipv6.icanhazip.com",
    "http://api-ipv6.ip.sb/geoip",
};

pub fn getIPv4Address(allocator: std.mem.Allocator, cfg: anytype) ![]const u8 {
    return getAddressFromApis(allocator, cfg, &ipv4_apis, .ipv4, findIPv4);
}

pub fn getIPv6Address(allocator: std.mem.Allocator, cfg: anytype) ![]const u8 {
    return getAddressFromApis(allocator, cfg, &ipv6_apis, .ipv6, findIPv6);
}

pub fn shouldLookupExternalAddress(existing: []const u8, custom: []const u8, allow_external_lookup: bool) bool {
    _ = existing;
    return allow_external_lookup and custom.len == 0;
}

/// Returns true only for IPv4 addresses suitable for public node identity.
pub fn isPubliclyRoutableIPv4(value: []const u8) bool {
    const octets = parseIPv4Octets(value) orelse return false;
    const a = octets[0];
    const b = octets[1];
    const c = octets[2];

    if (a == 0 or a == 10 or a == 127) return false;
    if (a == 100 and b >= 64 and b <= 127) return false;
    if (a == 169 and b == 254) return false;
    if (a == 172 and b >= 16 and b <= 31) return false;
    if (a == 192 and b == 0 and (c == 0 or c == 2)) return false;
    if (a == 192 and b == 88 and c == 99) return false;
    if (a == 192 and b == 168) return false;
    if (a == 198 and (b == 18 or b == 19)) return false;
    if (a == 198 and b == 51 and c == 100) return false;
    if (a == 203 and b == 0 and c == 113) return false;
    if (a >= 224) return false;
    return true;
}

fn parseIPv4Octets(value: []const u8) ?[4]u8 {
    var octets: [4]u8 = undefined;
    var parts = std.mem.splitScalar(u8, value, '.');
    var index: usize = 0;
    while (parts.next()) |part| {
        if (index >= octets.len or part.len == 0) return null;
        octets[index] = std.fmt.parseInt(u8, part, 10) catch return null;
        index += 1;
    }
    return if (index == octets.len) octets else null;
}

fn getAddressFromApis(
    allocator: std.mem.Allocator,
    cfg: anytype,
    apis: []const []const u8,
    family: raw_conn.AddressFamily,
    finder: fn ([]const u8) ?[]const u8,
) ![]const u8 {
    const probe_cfg = probeConfig(cfg);
    for (apis) |url| {
        debug.log("public IP lookup ({s}) probing {s}", .{ @tagName(family), url });
        const body = http.getReadCfgFamily(allocator, url, probe_cfg, family, "curl/8.0.1") catch |err| {
            debug.log("public IP lookup ({s}) failed via {s}: {s}", .{ @tagName(family), url, @errorName(err) });
            continue;
        };
        defer allocator.free(body);
        if (finder(body)) |addr| {
            debug.log("public IP lookup ({s}) resolved via {s}: {s}", .{ @tagName(family), url, addr });
            return allocator.dupe(u8, addr);
        }
        debug.log("public IP lookup ({s}) returned no parsable address via {s}", .{ @tagName(family), url });
    }
    debug.log("public IP lookup ({s}) exhausted all providers", .{@tagName(family)});
    return allocator.dupe(u8, "");
}

fn probeConfig(cfg: anytype) struct {
    timeout_ms: u64,
    max_retries: i32,
    ignore_unsafe_cert: bool,
    custom_dns: []const u8,
    cf_access_client_id: []const u8,
    cf_access_client_secret: []const u8,
} {
    return .{
        .timeout_ms = external_lookup_timeout_ms,
        .max_retries = external_lookup_max_retries,
        .ignore_unsafe_cert = cfg.ignore_unsafe_cert,
        .custom_dns = cfg.custom_dns,
        .cf_access_client_id = cfg.cf_access_client_id,
        .cf_access_client_secret = cfg.cf_access_client_secret,
    };
}

pub fn findIPv4(bytes: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < bytes.len) : (i += 1) {
        if (!std.ascii.isDigit(bytes[i])) continue;
        const start = i;
        while (i < bytes.len and (std.ascii.isDigit(bytes[i]) or bytes[i] == '.')) : (i += 1) {}
        const candidate = bytes[start..i];
        _ = net.net.IpAddress.parseIp4(candidate, 0) catch continue;
        return candidate;
    }
    return null;
}

pub fn findIPv6(bytes: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < bytes.len) : (i += 1) {
        if (!isIPv6Char(bytes[i])) continue;
        const start = i;
        var has_colon = false;
        while (i < bytes.len and isIPv6Char(bytes[i])) : (i += 1) {
            if (bytes[i] == ':') has_colon = true;
        }
        if (!has_colon) continue;
        const candidate = std.mem.trim(u8, bytes[start..i], "[](){}\",'\r\n\t ");
        if (candidate.len < 2) continue;
        _ = net.net.IpAddress.parseIp6(candidate, 0) catch continue;
        return candidate;
    }
    return null;
}

fn isIPv6Char(b: u8) bool {
    return std.ascii.isHex(b) or b == ':' or b == '.';
}
