const std = @import("std");

pub const Headers = struct {
    cf_access_client_id: ?[]const u8 = null,
    cf_access_client_secret: ?[]const u8 = null,
};

pub const ClientOptions = struct {
    timeout_ms: u64 = 30000,
    ignore_unsafe_cert: bool = false,
    max_retries: u32 = 3,
};

pub const Client = struct {
    timeout_ms: u64,
    ignore_unsafe_cert: bool,
    max_retries: u32,
    proxy_url: ?[]const u8,

    pub fn init(options: ClientOptions) Client {
        return .{
            .timeout_ms = options.timeout_ms,
            .ignore_unsafe_cert = options.ignore_unsafe_cert,
            .max_retries = options.max_retries,
            .proxy_url = proxyFromEnv(),
        };
    }

    pub fn shouldRetry(self: Client, attempt: u32, err: ?anyerror, status: ?u16) bool {
        if (attempt >= self.max_retries) return false;
        if (err != null) return true;
        if (status) |code| return code < 200 or code >= 400;
        return false;
    }
};

pub fn trimEndpoint(endpoint: []const u8) []const u8 {
    return std.mem.trimRight(u8, endpoint, "/");
}

pub fn basicInfoUrl(allocator: std.mem.Allocator, endpoint: []const u8, token: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}/api/clients/uploadBasicInfo?token={s}", .{ trimEndpoint(endpoint), token });
}

pub fn taskResultUrl(allocator: std.mem.Allocator, endpoint: []const u8, token: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}/api/clients/task/result?token={s}", .{ trimEndpoint(endpoint), token });
}

pub fn registerUrl(allocator: std.mem.Allocator, endpoint: []const u8, hostname: []const u8) ![]const u8 {
    const escaped = try percentEncode(allocator, hostname);
    defer allocator.free(escaped);
    return std.fmt.allocPrint(allocator, "{s}/api/clients/register?name={s}", .{ trimEndpoint(endpoint), escaped });
}

pub fn reportWsUrl(allocator: std.mem.Allocator, endpoint: []const u8, token: []const u8) ![]const u8 {
    const base = try wsEndpoint(allocator, endpoint);
    defer allocator.free(base);
    return std.fmt.allocPrint(allocator, "{s}/api/clients/report?token={s}", .{ trimEndpoint(base), token });
}

pub fn terminalWsUrl(allocator: std.mem.Allocator, endpoint: []const u8, token: []const u8, id: []const u8) ![]const u8 {
    const base = try wsEndpoint(allocator, endpoint);
    defer allocator.free(base);
    return std.fmt.allocPrint(allocator, "{s}/api/clients/terminal?token={s}&id={s}", .{ trimEndpoint(base), token, id });
}

pub fn addCloudflareHeaders(headers: *Headers, cfg: anytype) void {
    if (cfg.cf_access_client_id.len != 0 and cfg.cf_access_client_secret.len != 0) {
        headers.cf_access_client_id = cfg.cf_access_client_id;
        headers.cf_access_client_secret = cfg.cf_access_client_secret;
    }
}

fn wsEndpoint(allocator: std.mem.Allocator, endpoint: []const u8) ![]const u8 {
    if (std.mem.startsWith(u8, endpoint, "https://")) {
        return std.fmt.allocPrint(allocator, "wss://{s}", .{endpoint["https://".len..]});
    }
    if (std.mem.startsWith(u8, endpoint, "http://")) {
        return std.fmt.allocPrint(allocator, "ws://{s}", .{endpoint["http://".len..]});
    }
    return std.fmt.allocPrint(allocator, "ws{s}", .{endpoint});
}

fn percentEncode(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    for (value) |b| {
        if (isUnreserved(b)) {
            try out.append(allocator, b);
        } else {
            try out.writer(allocator).print("%{X:0>2}", .{b});
        }
    }
    return out.toOwnedSlice(allocator);
}

fn isUnreserved(b: u8) bool {
    return (b >= 'a' and b <= 'z') or
        (b >= 'A' and b <= 'Z') or
        (b >= '0' and b <= '9') or
        b == '-' or b == '_' or b == '.' or b == '~';
}

fn proxyFromEnv() ?[]const u8 {
    if (std.process.getEnvVarOwned(std.heap.page_allocator, "HTTPS_PROXY")) |value| {
        return value;
    } else |_| {}
    if (std.process.getEnvVarOwned(std.heap.page_allocator, "HTTP_PROXY")) |value| {
        return value;
    } else |_| {}
    return null;
}
