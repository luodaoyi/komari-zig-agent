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

pub fn postJson(allocator: std.mem.Allocator, url: []const u8, payload: []const u8, cfg: anytype) !void {
    const body = try postJsonRead(allocator, url, payload, cfg);
    allocator.free(body);
}

pub fn postJsonRead(allocator: std.mem.Allocator, url: []const u8, payload: []const u8, cfg: anytype) ![]u8 {
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    var extra: [2]std.http.Header = undefined;
    var extra_len: usize = 0;
    if (cfg.cf_access_client_id.len != 0 and cfg.cf_access_client_secret.len != 0) {
        extra[0] = .{ .name = "CF-Access-Client-Id", .value = cfg.cf_access_client_id };
        extra[1] = .{ .name = "CF-Access-Client-Secret", .value = cfg.cf_access_client_secret };
        extra_len = 2;
    }

    const max_retries: u32 = if (cfg.max_retries < 0) 0 else @intCast(cfg.max_retries);
    var attempt: u32 = 0;
    while (true) : (attempt += 1) {
        var response_writer = std.Io.Writer.Allocating.init(allocator);
        defer response_writer.deinit();
        const result = client.fetch(.{
            .location = .{ .url = url },
            .method = .POST,
            .payload = payload,
            .headers = .{ .content_type = .{ .override = "application/json" } },
            .extra_headers = extra[0..extra_len],
            .response_writer = &response_writer.writer,
            .keep_alive = false,
        }) catch |err| {
            if (attempt < max_retries) {
                std.Thread.sleep(2 * std.time.ns_per_s);
                continue;
            }
            return err;
        };
        const code = @intFromEnum(result.status);
        if (code >= 200 and code < 300) return response_writer.toOwnedSlice();
        if (attempt < max_retries) {
            std.Thread.sleep(2 * std.time.ns_per_s);
            continue;
        }
        return error.HttpStatusNotOk;
    }
}

pub fn getRead(allocator: std.mem.Allocator, url: []const u8) ![]u8 {
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();
    var response_writer = std.Io.Writer.Allocating.init(allocator);
    defer response_writer.deinit();
    const result = try client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .headers = .{ .user_agent = .{ .override = "komari-zig-agent" } },
        .response_writer = &response_writer.writer,
        .keep_alive = false,
    });
    const code = @intFromEnum(result.status);
    if (code < 200 or code >= 300) return error.HttpStatusNotOk;
    return response_writer.toOwnedSlice();
}

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
