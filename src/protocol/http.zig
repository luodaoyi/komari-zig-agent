const std = @import("std");
const idna = @import("idna");
const raw_conn = @import("raw_conn.zig");

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
            .proxy_url = null,
        };
    }

    pub fn shouldRetry(self: Client, attempt: u32, err: ?anyerror, status: ?u16) bool {
        if (attempt >= self.max_retries) return false;
        if (err != null) return true;
        if (status) |code| return code < 200 or code >= 400;
        return false;
    }
};

pub const ProxyEnv = struct {
    http_proxy: ?[]const u8 = null,
    https_proxy: ?[]const u8 = null,
    all_proxy: ?[]const u8 = null,
    http_proxy_lower: ?[]const u8 = null,
    https_proxy_lower: ?[]const u8 = null,
    all_proxy_lower: ?[]const u8 = null,
};

pub const RawConnection = struct {
    conn: *raw_conn.RawConn,
    proxied_plain: bool = false,
    proxy_authorization: ?[]const u8 = null,

    pub fn close(self: RawConnection, allocator: std.mem.Allocator) void {
        if (self.proxy_authorization) |value| allocator.free(value);
        self.conn.close();
    }
};

pub fn postJson(allocator: std.mem.Allocator, url: []const u8, payload: []const u8, cfg: anytype) !void {
    const body = try postJsonRead(allocator, url, payload, cfg);
    allocator.free(body);
}

pub fn postJsonRead(allocator: std.mem.Allocator, url: []const u8, payload: []const u8, cfg: anytype) ![]u8 {
    return postJsonReadAuth(allocator, url, payload, cfg, "");
}

pub fn postJsonReadAuth(allocator: std.mem.Allocator, url: []const u8, payload: []const u8, cfg: anytype, bearer_token: []const u8) ![]u8 {
    const ascii_url = try idna.convertUrlToAscii(allocator, url);
    defer allocator.free(ascii_url);
    const authorization = if (bearer_token.len == 0) "" else try std.fmt.allocPrint(allocator, "Bearer {s}", .{bearer_token});
    defer if (bearer_token.len != 0) allocator.free(authorization);
    if (cfg.custom_dns.len != 0 or cfg.ignore_unsafe_cert) {
        return requestReadAuth(allocator, ascii_url, "POST", payload, "application/json", cfg, authorization);
    }

    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();
    var proxy_arena = std.heap.ArenaAllocator.init(allocator);
    defer proxy_arena.deinit();
    try client.initDefaultProxies(proxy_arena.allocator());

    var extra: [3]std.http.Header = undefined;
    const extra_headers = postHeaders(cfg, authorization, &extra);

    const max_retries: u32 = if (cfg.max_retries < 0) 0 else @intCast(cfg.max_retries);
    var attempt: u32 = 0;
    while (true) : (attempt += 1) {
        var response_writer = std.Io.Writer.Allocating.init(allocator);
        defer response_writer.deinit();
        const result = client.fetch(.{
            .location = .{ .url = ascii_url },
            .method = .POST,
            .payload = payload,
            .headers = .{ .content_type = .{ .override = "application/json" } },
            .extra_headers = extra_headers,
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
    const ascii_url = try idna.convertUrlToAscii(allocator, url);
    defer allocator.free(ascii_url);

    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();
    var proxy_arena = std.heap.ArenaAllocator.init(allocator);
    defer proxy_arena.deinit();
    try client.initDefaultProxies(proxy_arena.allocator());
    var response_writer = std.Io.Writer.Allocating.init(allocator);
    defer response_writer.deinit();
    const result = try client.fetch(.{
        .location = .{ .url = ascii_url },
        .method = .GET,
        .headers = .{ .user_agent = .{ .override = "komari-zig-agent" } },
        .response_writer = &response_writer.writer,
        .keep_alive = false,
    });
    const code = @intFromEnum(result.status);
    if (code < 200 or code >= 300) return error.HttpStatusNotOk;
    return response_writer.toOwnedSlice();
}

pub fn getReadCfg(allocator: std.mem.Allocator, url: []const u8, cfg: anytype) ![]u8 {
    const ascii_url = try idna.convertUrlToAscii(allocator, url);
    defer allocator.free(ascii_url);
    if (cfg.custom_dns.len != 0 or cfg.ignore_unsafe_cert) {
        return requestRead(allocator, ascii_url, "GET", "", "", cfg);
    }
    return getRead(allocator, ascii_url);
}

pub fn getReadCfgFamily(allocator: std.mem.Allocator, url: []const u8, cfg: anytype, family: raw_conn.AddressFamily, user_agent: []const u8) ![]u8 {
    const ascii_url = try idna.convertUrlToAscii(allocator, url);
    defer allocator.free(ascii_url);
    return requestReadWithFamily(allocator, ascii_url, "GET", "", "", cfg, family, user_agent);
}

pub fn trimEndpoint(endpoint: []const u8) []const u8 {
    return std.mem.trimRight(u8, endpoint, "/");
}

pub fn basicInfoUrl(allocator: std.mem.Allocator, endpoint: []const u8, token: []const u8) ![]const u8 {
    const raw = try std.fmt.allocPrint(allocator, "{s}/api/clients/uploadBasicInfo?token={s}", .{ trimEndpoint(endpoint), token });
    defer allocator.free(raw);
    return idna.convertUrlToAscii(allocator, raw);
}

pub fn taskResultUrl(allocator: std.mem.Allocator, endpoint: []const u8, token: []const u8) ![]const u8 {
    const raw = try std.fmt.allocPrint(allocator, "{s}/api/clients/task/result?token={s}", .{ trimEndpoint(endpoint), token });
    defer allocator.free(raw);
    return idna.convertUrlToAscii(allocator, raw);
}

pub fn registerUrl(allocator: std.mem.Allocator, endpoint: []const u8, hostname: []const u8) ![]const u8 {
    const escaped = try percentEncode(allocator, hostname);
    defer allocator.free(escaped);
    const raw = try std.fmt.allocPrint(allocator, "{s}/api/clients/register?name={s}", .{ trimEndpoint(endpoint), escaped });
    defer allocator.free(raw);
    return idna.convertUrlToAscii(allocator, raw);
}

pub fn reportWsUrl(allocator: std.mem.Allocator, endpoint: []const u8, token: []const u8) ![]const u8 {
    const base = try wsEndpoint(allocator, endpoint);
    defer allocator.free(base);
    const raw = try std.fmt.allocPrint(allocator, "{s}/api/clients/report?token={s}", .{ trimEndpoint(base), token });
    defer allocator.free(raw);
    return idna.convertUrlToAscii(allocator, raw);
}

pub fn terminalWsUrl(allocator: std.mem.Allocator, endpoint: []const u8, token: []const u8, id: []const u8) ![]const u8 {
    const base = try wsEndpoint(allocator, endpoint);
    defer allocator.free(base);
    const raw = try std.fmt.allocPrint(allocator, "{s}/api/clients/terminal?token={s}&id={s}", .{ trimEndpoint(base), token, id });
    defer allocator.free(raw);
    return idna.convertUrlToAscii(allocator, raw);
}

pub fn addCloudflareHeaders(headers: *Headers, cfg: anytype) void {
    if (cfg.cf_access_client_id.len != 0 and cfg.cf_access_client_secret.len != 0) {
        headers.cf_access_client_id = cfg.cf_access_client_id;
        headers.cf_access_client_secret = cfg.cf_access_client_secret;
    }
}

pub fn cloudflareHeaders(cfg: anytype, out: *[2]std.http.Header) []const std.http.Header {
    if (cfg.cf_access_client_id.len == 0 or cfg.cf_access_client_secret.len == 0) return &.{};
    out[0] = .{ .name = "CF-Access-Client-Id", .value = cfg.cf_access_client_id };
    out[1] = .{ .name = "CF-Access-Client-Secret", .value = cfg.cf_access_client_secret };
    return out[0..2];
}

fn postHeaders(cfg: anytype, authorization: []const u8, out: *[3]std.http.Header) []const std.http.Header {
    var len: usize = 0;
    if (authorization.len != 0) {
        out[len] = .{ .name = "Authorization", .value = authorization };
        len += 1;
    }
    if (cfg.cf_access_client_id.len != 0 and cfg.cf_access_client_secret.len != 0) {
        out[len] = .{ .name = "CF-Access-Client-Id", .value = cfg.cf_access_client_id };
        len += 1;
        out[len] = .{ .name = "CF-Access-Client-Secret", .value = cfg.cf_access_client_secret };
        len += 1;
    }
    return out[0..len];
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

pub fn proxyEnvForScheme(scheme: []const u8, env: ProxyEnv) ?[]const u8 {
    if (std.ascii.eqlIgnoreCase(scheme, "https") or std.ascii.eqlIgnoreCase(scheme, "wss")) {
        return firstNonEmpty(&.{ env.https_proxy, env.https_proxy_lower, env.all_proxy, env.all_proxy_lower });
    }
    if (std.ascii.eqlIgnoreCase(scheme, "http") or std.ascii.eqlIgnoreCase(scheme, "ws")) {
        return firstNonEmpty(&.{ env.http_proxy, env.http_proxy_lower, env.all_proxy, env.all_proxy_lower });
    }
    return null;
}

pub fn connectRawHttp(
    allocator: std.mem.Allocator,
    scheme: []const u8,
    host: []const u8,
    port: u16,
    use_tls: bool,
    ignore_unsafe_cert: bool,
    custom_dns: []const u8,
    family: raw_conn.AddressFamily,
) !RawConnection {
    const proxy_url = try proxyFromProcess(allocator, scheme);
    defer if (proxy_url) |value| allocator.free(value);
    if (proxy_url) |value| {
        const proxy = try parseProxyUrl(allocator, value);
        defer proxy.deinit(allocator);
        if (proxy.tls) return error.UnsupportedProxyScheme;
        var conn = try raw_conn.RawConn.connectWithFamily(allocator, proxy.host, proxy.port, false, false, "", .any);
        errdefer conn.close();
        if (use_tls) {
            try sendConnectTunnel(allocator, conn, host, port, proxy.authorization);
            try conn.startTls(host, ignore_unsafe_cert);
            return .{ .conn = conn };
        }
        const authorization = if (proxy.authorization) |auth| try allocator.dupe(u8, auth) else null;
        errdefer if (authorization) |auth| allocator.free(auth);
        return .{ .conn = conn, .proxied_plain = true, .proxy_authorization = authorization };
    }
    return .{
        .conn = try raw_conn.RawConn.connectWithFamily(allocator, host, port, use_tls, ignore_unsafe_cert, custom_dns, family),
    };
}

fn requestRead(allocator: std.mem.Allocator, url: []const u8, method: []const u8, payload: []const u8, content_type: []const u8, cfg: anytype) ![]u8 {
    return requestReadAuth(allocator, url, method, payload, content_type, cfg, "");
}

fn requestReadAuth(allocator: std.mem.Allocator, url: []const u8, method: []const u8, payload: []const u8, content_type: []const u8, cfg: anytype, authorization: []const u8) ![]u8 {
    return requestReadWithFamilyAuth(allocator, url, method, payload, content_type, cfg, .any, "komari-zig-agent", authorization);
}

fn requestReadWithFamily(allocator: std.mem.Allocator, url: []const u8, method: []const u8, payload: []const u8, content_type: []const u8, cfg: anytype, family: raw_conn.AddressFamily, user_agent: []const u8) ![]u8 {
    return requestReadWithFamilyAuth(allocator, url, method, payload, content_type, cfg, family, user_agent, "");
}

fn requestReadWithFamilyAuth(allocator: std.mem.Allocator, url: []const u8, method: []const u8, payload: []const u8, content_type: []const u8, cfg: anytype, family: raw_conn.AddressFamily, user_agent: []const u8, authorization: []const u8) ![]u8 {
    const uri = try std.Uri.parse(url);
    const host = try uriHost(allocator, uri);
    defer allocator.free(host);
    const use_tls = std.mem.eql(u8, uri.scheme, "https");
    const port: u16 = uri.port orelse if (use_tls) 443 else 80;
    const path = try uriPathQuery(allocator, uri);
    defer allocator.free(path);

    const max_retries: u32 = if (cfg.max_retries < 0) 0 else @intCast(cfg.max_retries);
    var attempt: u32 = 0;
    while (true) : (attempt += 1) {
        const raw = connectRawHttp(allocator, uri.scheme, host, port, use_tls, cfg.ignore_unsafe_cert, cfg.custom_dns, family) catch |err| {
            if (attempt < max_retries) {
                std.Thread.sleep(2 * std.time.ns_per_s);
                continue;
            }
            return err;
        };
        var conn = raw.conn;
        defer raw.close(allocator);
        var req = std.Io.Writer.Allocating.init(allocator);
        defer req.deinit();
        const request_target = if (raw.proxied_plain) url else path;
        try req.writer.print("{s} {s} HTTP/1.1\r\nHost: {s}\r\nUser-Agent: {s}\r\nConnection: close\r\n", .{ method, request_target, host, user_agent });
        if (raw.proxy_authorization) |authorization_value| try req.writer.print("Proxy-Authorization: {s}\r\n", .{authorization_value});
        if (payload.len != 0) {
            try req.writer.print("Content-Type: {s}\r\nContent-Length: {d}\r\n", .{ content_type, payload.len });
        }
        var cf: [2]std.http.Header = undefined;
        for (cloudflareHeaders(cfg, &cf)) |header| try req.writer.print("{s}: {s}\r\n", .{ header.name, header.value });
        if (authorization.len != 0) try req.writer.print("Authorization: {s}\r\n", .{authorization});
        try req.writer.writeAll("\r\n");
        if (payload.len != 0) try req.writer.writeAll(payload);
        const request = try req.toOwnedSlice();
        defer allocator.free(request);
        try conn.writer().writeAll(request);
        try conn.flush();
        const response = readHttpResponse(allocator, conn.reader()) catch |err| {
            if (attempt < max_retries) {
                std.Thread.sleep(2 * std.time.ns_per_s);
                continue;
            }
            return err;
        };
        errdefer allocator.free(response.body);
        if (response.status >= 200 and response.status < 300) {
            return response.body;
        }
        allocator.free(response.body);
        if (attempt < max_retries) {
            std.Thread.sleep(2 * std.time.ns_per_s);
            continue;
        }
        return error.HttpStatusNotOk;
    }
}

fn uriHost(allocator: std.mem.Allocator, uri: std.Uri) ![]const u8 {
    const h = uri.host orelse return error.InvalidUrl;
    const raw = switch (h) {
        .raw => |v| v,
        .percent_encoded => |v| v,
    };
    return allocator.dupe(u8, std.mem.trim(u8, raw, "[]"));
}

fn uriPathQuery(allocator: std.mem.Allocator, uri: std.Uri) ![]const u8 {
    const path = if (uri.path.percent_encoded.len == 0) "/" else uri.path.percent_encoded;
    if (uri.query) |query| {
        return std.fmt.allocPrint(allocator, "{s}?{s}", .{ path, query.percent_encoded });
    }
    return allocator.dupe(u8, path);
}

const HttpResponse = struct { status: u16, body: []u8 };

fn readHttpResponse(allocator: std.mem.Allocator, reader: *std.Io.Reader) !HttpResponse {
    const header = try readHeader(allocator, reader);
    defer allocator.free(header);
    const status = try parseStatus(header);
    if (headerValue(header, "Content-Length")) |value| {
        const len = try std.fmt.parseInt(usize, std.mem.trim(u8, value, " \t"), 10);
        const body = try allocator.alloc(u8, len);
        errdefer allocator.free(body);
        try reader.readSliceAll(body);
        return .{ .status = status, .body = body };
    }
    if (headerValue(header, "Transfer-Encoding")) |value| {
        if (std.ascii.indexOfIgnoreCase(value, "chunked") != null) {
            return .{ .status = status, .body = try readChunked(allocator, reader) };
        }
    }
    return .{ .status = status, .body = try allocator.dupe(u8, "") };
}

fn readHeader(allocator: std.mem.Allocator, reader: *std.Io.Reader) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    while (true) {
        const b = try reader.takeByte();
        try out.append(allocator, b);
        if (std.mem.endsWith(u8, out.items, "\r\n\r\n")) break;
        if (out.items.len > 1024 * 1024) return error.HttpResponseTooLarge;
    }
    return out.toOwnedSlice(allocator);
}

fn parseStatus(bytes: []const u8) !u16 {
    const first_line_end = std.mem.indexOf(u8, bytes, "\r\n") orelse return error.InvalidHttpResponse;
    const first = bytes[0..first_line_end];
    if (first.len < 12 or !std.mem.startsWith(u8, first, "HTTP/1.")) return error.InvalidHttpResponse;
    return std.fmt.parseInt(u16, first[9..12], 10);
}

fn headerValue(header: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, header, "\r\n");
    _ = lines.next();
    while (lines.next()) |line| {
        if (line.len == 0) break;
        const idx = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..idx], " \t"), name)) {
            return std.mem.trim(u8, line[idx + 1 ..], " \t");
        }
    }
    return null;
}

fn readChunked(allocator: std.mem.Allocator, reader: *std.Io.Reader) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    var line_buf: [128]u8 = undefined;
    while (true) {
        const n = try readLine(reader, &line_buf);
        const size_text = std.mem.sliceTo(line_buf[0..n], ';');
        const size = try std.fmt.parseInt(usize, std.mem.trim(u8, size_text, " \t"), 16);
        if (size == 0) {
            _ = try readLine(reader, &line_buf);
            break;
        }
        const old = out.items.len;
        try out.resize(allocator, old + size);
        try reader.readSliceAll(out.items[old..]);
        var crlf: [2]u8 = undefined;
        try reader.readSliceAll(&crlf);
        if (!std.mem.eql(u8, &crlf, "\r\n")) return error.InvalidHttpResponse;
        if (out.items.len > 64 * 1024 * 1024) return error.HttpResponseTooLarge;
    }
    return out.toOwnedSlice(allocator);
}

fn readLine(reader: *std.Io.Reader, buf: []u8) !usize {
    var i: usize = 0;
    while (i < buf.len) {
        const b = try reader.takeByte();
        if (b == '\n') {
            if (i > 0 and buf[i - 1] == '\r') i -= 1;
            return i;
        }
        buf[i] = b;
        i += 1;
    }
    return error.LineTooLong;
}

const ProxyTarget = struct {
    host: []const u8,
    port: u16,
    tls: bool,
    authorization: ?[]const u8 = null,

    fn deinit(self: ProxyTarget, allocator: std.mem.Allocator) void {
        allocator.free(self.host);
        if (self.authorization) |value| allocator.free(value);
    }
};

fn firstNonEmpty(values: []const ?[]const u8) ?[]const u8 {
    for (values) |value| {
        if (value) |v| if (v.len != 0) return v;
    }
    return null;
}

fn proxyFromProcess(allocator: std.mem.Allocator, scheme: []const u8) !?[]const u8 {
    const names: []const []const u8 = if (std.ascii.eqlIgnoreCase(scheme, "https") or std.ascii.eqlIgnoreCase(scheme, "wss"))
        &.{ "HTTPS_PROXY", "https_proxy", "ALL_PROXY", "all_proxy" }
    else if (std.ascii.eqlIgnoreCase(scheme, "http") or std.ascii.eqlIgnoreCase(scheme, "ws"))
        &.{ "HTTP_PROXY", "http_proxy", "ALL_PROXY", "all_proxy" }
    else
        return null;
    for (names) |name| {
        const value = std.process.getEnvVarOwned(allocator, name) catch |err| switch (err) {
            error.EnvironmentVariableNotFound => continue,
            else => |e| return e,
        };
        if (value.len != 0) return value;
        allocator.free(value);
    }
    return null;
}

fn parseProxyUrl(allocator: std.mem.Allocator, value: []const u8) !ProxyTarget {
    const with_scheme = if (std.mem.indexOf(u8, value, "://") == null)
        try std.fmt.allocPrint(allocator, "http://{s}", .{value})
    else
        try allocator.dupe(u8, value);
    defer allocator.free(with_scheme);
    const uri = try std.Uri.parse(with_scheme);
    const is_https = std.ascii.eqlIgnoreCase(uri.scheme, "https");
    if (!is_https and !std.ascii.eqlIgnoreCase(uri.scheme, "http")) return error.UnsupportedProxyScheme;
    const host = try uri.getHostAlloc(allocator);
    errdefer allocator.free(host);
    const authorization = try basicProxyAuthorization(allocator, uri);
    errdefer if (authorization) |auth| allocator.free(auth);
    return .{
        .host = host,
        .port = uri.port orelse if (is_https) 443 else 80,
        .tls = is_https,
        .authorization = authorization,
    };
}

fn basicProxyAuthorization(allocator: std.mem.Allocator, uri: std.Uri) !?[]const u8 {
    if (uri.user == null and uri.password == null) return null;
    const user = componentText(uri.user) orelse "";
    const password = componentText(uri.password) orelse "";
    const raw = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ user, password });
    defer allocator.free(raw);
    const encoded_len = std.base64.standard.Encoder.calcSize(raw.len);
    const out = try allocator.alloc(u8, "Basic ".len + encoded_len);
    @memcpy(out[0.."Basic ".len], "Basic ");
    _ = std.base64.standard.Encoder.encode(out["Basic ".len..], raw);
    return out;
}

fn componentText(component: ?std.Uri.Component) ?[]const u8 {
    const c = component orelse return null;
    return switch (c) {
        .raw => |value| value,
        .percent_encoded => |value| value,
    };
}

fn sendConnectTunnel(allocator: std.mem.Allocator, conn: *raw_conn.RawConn, host: []const u8, port: u16, authorization: ?[]const u8) !void {
    var req = std.Io.Writer.Allocating.init(allocator);
    defer req.deinit();
    try req.writer.print("CONNECT {s}:{d} HTTP/1.1\r\nHost: {s}:{d}\r\n", .{ host, port, host, port });
    if (authorization) |value| try req.writer.print("Proxy-Authorization: {s}\r\n", .{value});
    try req.writer.writeAll("\r\n");
    const bytes = try req.toOwnedSlice();
    defer allocator.free(bytes);
    try conn.writer().writeAll(bytes);
    try conn.flush();
    const response = try readHttpResponse(allocator, conn.reader());
    defer allocator.free(response.body);
    if (response.status < 200 or response.status >= 300) return error.ProxyConnectFailed;
}
