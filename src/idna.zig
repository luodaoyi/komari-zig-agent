const std = @import("std");

const base = 36;
const tmin = 1;
const tmax = 26;
const skew = 38;
const damp = 700;
const initial_bias = 72;
const initial_n = 128;
const delimiter = '-';

/// IDNA and punycode helpers for normalizing outbound URLs and hosts.
pub fn convertUrlToAscii(allocator: std.mem.Allocator, url: []const u8) ![]const u8 {
    const scheme_end = std.mem.indexOf(u8, url, "://") orelse return convertHostToAscii(allocator, url);
    const authority_start = scheme_end + 3;
    const path_start = std.mem.indexOfScalarPos(u8, url, authority_start, '/') orelse url.len;
    const authority = url[authority_start..path_start];

    var userinfo_end: usize = 0;
    if (std.mem.lastIndexOfScalar(u8, authority, '@')) |idx| userinfo_end = idx + 1;
    const hostport = authority[userinfo_end..];

    const host_end = hostEnd(hostport);
    const host = hostport[0..host_end];
    const port = hostport[host_end..];
    const ascii_host = try convertHostToAscii(allocator, host);
    return std.fmt.allocPrint(allocator, "{s}://{s}{s}{s}{s}", .{
        url[0..scheme_end],
        authority[0..userinfo_end],
        ascii_host,
        port,
        url[path_start..],
    });
}

pub fn convertHostToAscii(allocator: std.mem.Allocator, host: []const u8) ![]const u8 {
    if (host.len == 0 or std.mem.indexOfScalar(u8, host, '[') != null) return allocator.dupe(u8, host);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var it = std.mem.splitScalar(u8, host, '.');
    var first = true;
    while (it.next()) |label| {
        if (!first) try out.append(allocator, '.');
        first = false;
        if (isAscii(label)) {
            try out.appendSlice(allocator, label);
        } else {
            try out.appendSlice(allocator, "xn--");
            try punycodeEncodeLabel(allocator, label, &out);
        }
    }
    return out.toOwnedSlice(allocator);
}

fn hostEnd(hostport: []const u8) usize {
    if (std.mem.startsWith(u8, hostport, "[")) {
        if (std.mem.indexOfScalar(u8, hostport, ']')) |idx| return idx + 1;
    }
    if (std.mem.lastIndexOfScalar(u8, hostport, ':')) |idx| {
        if (std.mem.count(u8, hostport, ":") == 1) return idx;
    }
    return hostport.len;
}

fn isAscii(bytes: []const u8) bool {
    for (bytes) |b| {
        if (b >= 0x80) return false;
    }
    return true;
}

fn punycodeEncodeLabel(allocator: std.mem.Allocator, label: []const u8, out: *std.ArrayList(u8)) !void {
    var codepoints: std.ArrayList(u21) = .empty;
    defer codepoints.deinit(allocator);

    var view = try std.unicode.Utf8View.init(label);
    var iter = view.iterator();
    while (iter.nextCodepoint()) |cp| try codepoints.append(allocator, cp);

    var basic_count: usize = 0;
    for (codepoints.items) |cp| {
        if (cp < 0x80) {
            try out.append(allocator, @intCast(cp));
            basic_count += 1;
        }
    }
    var handled = basic_count;
    if (basic_count > 0 and handled < codepoints.items.len) try out.append(allocator, delimiter);

    var n: u32 = initial_n;
    var delta: u32 = 0;
    var bias: u32 = initial_bias;

    while (handled < codepoints.items.len) {
        var m: u32 = std.math.maxInt(u32);
        for (codepoints.items) |cp| {
            if (cp >= n and cp < m) m = cp;
        }
        delta += (m - n) * (@as(u32, @intCast(handled)) + 1);
        n = m;

        for (codepoints.items) |cp| {
            if (cp < n) {
                delta += 1;
            } else if (cp == n) {
                var q = delta;
                var k: u32 = base;
                while (true) : (k += base) {
                    const t = threshold(k, bias);
                    if (q < t) break;
                    try out.append(allocator, encodeDigit(t + ((q - t) % (base - t))));
                    q = (q - t) / (base - t);
                }
                try out.append(allocator, encodeDigit(q));
                bias = adapt(delta, @intCast(handled + 1), handled == basic_count);
                delta = 0;
                handled += 1;
            }
        }
        delta += 1;
        n += 1;
    }
}

fn threshold(k: u32, bias: u32) u32 {
    if (k <= bias + tmin) return tmin;
    if (k >= bias + tmax) return tmax;
    return k - bias;
}

fn adapt(delta_in: u32, points: u32, first_time: bool) u32 {
    var delta = if (first_time) delta_in / damp else delta_in / 2;
    delta += delta / points;
    var k: u32 = 0;
    while (delta > ((base - tmin) * tmax) / 2) : (k += base) {
        delta /= base - tmin;
    }
    return k + (((base - tmin + 1) * delta) / (delta + skew));
}

fn encodeDigit(d: u32) u8 {
    return @intCast(if (d < 26) 'a' + d else '0' + (d - 26));
}
