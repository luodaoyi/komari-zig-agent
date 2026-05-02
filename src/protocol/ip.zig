const std = @import("std");
const http = @import("http.zig");

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
    for (&ipv4_apis) |url| {
        const body = http.getReadCfgFamily(allocator, url, cfg, .ipv4, "curl/8.0.1") catch continue;
        defer allocator.free(body);
        if (findIPv4(body)) |ip| return allocator.dupe(u8, ip);
    }
    return allocator.dupe(u8, "");
}

pub fn getIPv6Address(allocator: std.mem.Allocator, cfg: anytype) ![]const u8 {
    for (&ipv6_apis) |url| {
        const body = http.getReadCfgFamily(allocator, url, cfg, .ipv6, "curl/8.0.1") catch continue;
        defer allocator.free(body);
        if (findIPv6(body)) |ip| return allocator.dupe(u8, ip);
    }
    return allocator.dupe(u8, "");
}

pub fn findIPv4(bytes: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < bytes.len) : (i += 1) {
        if (!std.ascii.isDigit(bytes[i])) continue;
        const start = i;
        while (i < bytes.len and (std.ascii.isDigit(bytes[i]) or bytes[i] == '.')) : (i += 1) {}
        const candidate = bytes[start..i];
        _ = std.net.Address.parseIp4(candidate, 0) catch continue;
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
        _ = std.net.Address.parseIp6(candidate, 0) catch continue;
        return candidate;
    }
    return null;
}

fn isIPv6Char(b: u8) bool {
    return std.ascii.isHex(b) or b == ':' or b == '.';
}
