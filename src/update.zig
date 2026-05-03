const std = @import("std");
const builtin = @import("builtin");
const config = @import("config.zig");
const http = @import("protocol/http.zig");
const version = @import("version.zig");
const compat = @import("compat");

/// Self-update flow with release lookup, checksum validation, and rollback.
pub const repo = version.repo;
pub const default_github_proxies = [_][]const u8{
    "https://gh.llkk.cc",
    "https://gh-proxy.com",
    "https://ghproxy.net",
    "https://ghfast.top",
    "https://ghproxy.cc",
};

pub const PendingAction = enum {
    allow_start,
    rollback,
};

pub const PendingUpdateState = struct {
    previous_version: []const u8,
    target_version: []const u8,
    backup_path: []const u8,
    attempts: u32,

    pub fn deinit(self: PendingUpdateState, allocator: std.mem.Allocator) void {
        allocator.free(self.previous_version);
        allocator.free(self.target_version);
        allocator.free(self.backup_path);
    }
};

const ReleaseAsset = struct {
    url: []const u8,
    digest: ?[]const u8 = null,
};

pub fn parseVersionPrefixless(value: []const u8) []const u8 {
    if (value.len > 0 and (value[0] == 'v' or value[0] == 'V')) return value[1..];
    return value;
}

pub fn assetName(allocator: std.mem.Allocator) ![]const u8 {
    const os = switch (builtin.os.tag) {
        .linux => "linux",
        .freebsd => "freebsd",
        .macos => "darwin",
        .windows => "windows",
        else => "linux",
    };
    const arch = switch (builtin.cpu.arch) {
        .x86_64 => "amd64",
        .aarch64 => "arm64",
        .x86 => "386",
        .arm => "arm",
        .loongarch64 => "loong64",
        else => @tagName(builtin.cpu.arch),
    };
    const ext = if (builtin.os.tag == .windows) ".exe" else "";
    return std.fmt.allocPrint(allocator, "komari-agent-{s}-{s}{s}", .{ os, arch, ext });
}

pub fn newerThan(current_raw: []const u8, latest_raw: []const u8) bool {
    const current = parseVersionPrefixless(current_raw);
    const latest = parseVersionPrefixless(latest_raw);
    return compareVersion(latest, current) > 0;
}

pub fn pendingAction(state: PendingUpdateState) PendingAction {
    return if (state.attempts == 0) .allow_start else .rollback;
}

pub fn allocPendingStateJson(allocator: std.mem.Allocator, state: PendingUpdateState) ![]const u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    try out.writer.print("{f}", .{std.json.fmt(.{
        .previous_version = state.previous_version,
        .target_version = state.target_version,
        .backup_path = state.backup_path,
        .attempts = state.attempts,
    }, .{})});
    return out.toOwnedSlice();
}

pub fn parsePendingState(allocator: std.mem.Allocator, body: []const u8) !PendingUpdateState {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidPendingUpdateState;
    const object = parsed.value.object;
    const previous_version = try allocator.dupe(u8, stringField(object, "previous_version") orelse return error.InvalidPendingUpdateState);
    errdefer allocator.free(previous_version);
    const target_version = try allocator.dupe(u8, stringField(object, "target_version") orelse return error.InvalidPendingUpdateState);
    errdefer allocator.free(target_version);
    const backup_path = try allocator.dupe(u8, stringField(object, "backup_path") orelse return error.InvalidPendingUpdateState);
    errdefer allocator.free(backup_path);
    return .{
        .previous_version = previous_version,
        .target_version = target_version,
        .backup_path = backup_path,
        .attempts = intField(object, "attempts") orelse return error.InvalidPendingUpdateState,
    };
}

pub fn recoverPendingUpdate(allocator: std.mem.Allocator) !void {
    const exe = try compat.selfExePathAlloc(allocator);
    defer allocator.free(exe);
    const state_path = try pendingStatePath(allocator, exe);
    defer allocator.free(state_path);

    const state_body = readSmallFile(allocator, state_path) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer allocator.free(state_body);

    var state = parsePendingState(allocator, state_body) catch {
        deleteFileIgnoreMissing(state_path);
        return;
    };
    defer state.deinit(allocator);

    if (!std.mem.eql(u8, state.target_version, version.current)) {
        deleteFileIgnoreMissing(state_path);
        return;
    }

    switch (pendingAction(state)) {
        .allow_start => {
            state.attempts += 1;
            try writePendingStateFile(allocator, state_path, state);
        },
        .rollback => {
            compat.renameAbsolute(state.backup_path, exe) catch |err| switch (err) {
                error.FileNotFound => {
                    deleteFileIgnoreMissing(state_path);
                    return;
                },
                else => return err,
            };
            deleteFileIgnoreMissing(state_path);
            std.process.exit(42);
        },
    }
}

pub fn hasPendingUpdate(allocator: std.mem.Allocator) bool {
    const exe = compat.selfExePathAlloc(allocator) catch return false;
    defer allocator.free(exe);
    const state_path = pendingStatePath(allocator, exe) catch return false;
    defer allocator.free(state_path);
    var file = compat.openFileAbsolute(state_path, .{}) catch return false;
    file.close(std.Options.debug_io);
    return true;
}

pub fn confirmPendingUpdate(allocator: std.mem.Allocator) !bool {
    const exe = try compat.selfExePathAlloc(allocator);
    defer allocator.free(exe);
    const state_path = try pendingStatePath(allocator, exe);
    defer allocator.free(state_path);
    const state_body = readSmallFile(allocator, state_path) catch |err| switch (err) {
        error.FileNotFound => return true,
        else => return err,
    };
    defer allocator.free(state_body);

    var state = parsePendingState(allocator, state_body) catch {
        deleteFileIgnoreMissing(state_path);
        return true;
    };
    defer state.deinit(allocator);
    if (!std.mem.eql(u8, state.target_version, version.current)) return false;
    deleteFileIgnoreMissing(state.backup_path);
    deleteFileIgnoreMissing(state_path);
    return true;
}

pub fn checkAndUpdate(allocator: std.mem.Allocator, cfg: config.Config) !void {
    if (!isNumericVersion(version.current)) return;
    const release_url = "https://api.github.com/repos/" ++ repo ++ "/releases/latest";
    const release = downloadGithubUrlUnchecked(allocator, release_url, cfg) catch return;
    defer allocator.free(release);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, release, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return;
    const tag = stringField(parsed.value.object, "tag_name") orelse return;
    if (!newerThan(version.current, tag)) return;

    const wanted = try assetName(allocator);
    defer allocator.free(wanted);
    const asset = findAsset(parsed.value.object, wanted) orelse return;
    const sums_url = findAssetUrl(parsed.value.object, "SHA256SUMS");
    try downloadAndReplace(allocator, asset.url, cfg, tag, wanted, asset.digest, sums_url);
}

pub fn startBackground(allocator: std.mem.Allocator, cfg: config.Config) void {
    const thread = std.Thread.spawn(.{ .stack_size = 256 * 1024 }, updateLoop, .{ allocator, cfg }) catch return;
    thread.detach();
}

fn updateLoop(allocator: std.mem.Allocator, cfg: config.Config) void {
    while (true) {
        compat.sleep(6 * 60 * 60 * std.time.ns_per_s);
        checkAndUpdate(allocator, cfg) catch {};
    }
}

fn downloadAndReplace(
    allocator: std.mem.Allocator,
    url: []const u8,
    cfg: config.Config,
    target_version: []const u8,
    asset_name: []const u8,
    digest: ?[]const u8,
    sums_url: ?[]const u8,
) !void {
    const expected = try expectedSha256(allocator, cfg, asset_name, digest, sums_url);
    defer if (expected) |value| allocator.free(value);
    const exe = try compat.selfExePathAlloc(allocator);
    defer allocator.free(exe);
    const tmp = try std.fmt.allocPrint(allocator, "{s}.update", .{exe});
    defer allocator.free(tmp);
    errdefer deleteFileIgnoreMissing(tmp);
    const backup = try backupPath(allocator, exe);
    defer allocator.free(backup);
    const state_path = try pendingStatePath(allocator, exe);
    defer allocator.free(state_path);
    {
        var file = try compat.createFileAbsolute(tmp, .{ .truncate = true, .permissions = .executable_file });
        defer file.close(std.Options.debug_io);
        try downloadReleaseAssetToFile(allocator, url, cfg, expected, file);
    }
    try runBinaryPreflight(allocator, tmp);
    try copyFileAbsolute(exe, backup);
    errdefer deleteFileIgnoreMissing(backup);
    try writePendingStateFile(allocator, state_path, .{
        .previous_version = version.current,
        .target_version = target_version,
        .backup_path = backup,
        .attempts = 0,
    });
    errdefer deleteFileIgnoreMissing(state_path);
    try compat.renameAbsolute(tmp, exe);
    std.process.exit(42);
}

fn expectedSha256(allocator: std.mem.Allocator, cfg: config.Config, asset_name: []const u8, digest: ?[]const u8, sums_url: ?[]const u8) !?[]const u8 {
    if (digest) |value| {
        if (sha256DigestHex(value)) |hex| {
            const copy = try allocator.dupe(u8, hex);
            return copy;
        }
    }
    const url = sums_url orelse return null;
    const sums = try downloadGithubUrlUnchecked(allocator, url, cfg);
    defer allocator.free(sums);
    const hex = checksumFromSums(sums, asset_name) orelse return error.ReleaseChecksumMissing;
    const copy = try allocator.dupe(u8, hex);
    return copy;
}

fn downloadReleaseAssetToFile(allocator: std.mem.Allocator, url: []const u8, cfg: config.Config, expected_sha256: ?[]const u8, file: std.Io.File) !void {
    const expected = expected_sha256 orelse return error.ReleaseChecksumMissing;
    const digest = try downloadGithubUrlToFileUnchecked(allocator, url, cfg, file);
    if (!sha256DigestMatches(&digest, expected)) return error.ReleaseChecksumMismatch;
}

fn downloadGithubUrlUnchecked(allocator: std.mem.Allocator, url: []const u8, cfg: config.Config) ![]u8 {
    if (http.getReadCfg(allocator, url, cfg)) |body| return body else |err| {
        var last_err = err;
        if (compat.getEnvVarOwned(allocator, "KOMARI_GITHUB_PROXIES")) |env_value| {
            defer allocator.free(env_value);
            var it = std.mem.tokenizeAny(u8, env_value, " ,;\t\r\n");
            while (it.next()) |proxy| {
                const proxied = try githubProxyUrl(allocator, proxy, url);
                defer allocator.free(proxied);
                if (http.getReadCfg(allocator, proxied, cfg)) |body| return body else |proxy_err| last_err = proxy_err;
            }
        } else |env_err| switch (env_err) {
            error.EnvironmentVariableMissing => {
                for (&default_github_proxies) |proxy| {
                    const proxied = try githubProxyUrl(allocator, proxy, url);
                    defer allocator.free(proxied);
                    if (http.getReadCfg(allocator, proxied, cfg)) |body| return body else |proxy_err| last_err = proxy_err;
                }
            },
            else => return env_err,
        }
        return last_err;
    }
}

fn downloadGithubUrlToFileUnchecked(allocator: std.mem.Allocator, url: []const u8, cfg: config.Config, file: std.Io.File) ![32]u8 {
    if (http.getToFileSha256Cfg(allocator, url, cfg, file)) |digest| return digest else |err| {
        var last_err = err;
        if (compat.getEnvVarOwned(allocator, "KOMARI_GITHUB_PROXIES")) |env_value| {
            defer allocator.free(env_value);
            var it = std.mem.tokenizeAny(u8, env_value, " ,;\t\r\n");
            while (it.next()) |proxy| {
                const proxied = try githubProxyUrl(allocator, proxy, url);
                defer allocator.free(proxied);
                if (http.getToFileSha256Cfg(allocator, proxied, cfg, file)) |digest| return digest else |proxy_err| last_err = proxy_err;
            }
        } else |env_err| switch (env_err) {
            error.EnvironmentVariableMissing => {
                for (&default_github_proxies) |proxy| {
                    const proxied = try githubProxyUrl(allocator, proxy, url);
                    defer allocator.free(proxied);
                    if (http.getToFileSha256Cfg(allocator, proxied, cfg, file)) |digest| return digest else |proxy_err| last_err = proxy_err;
                }
            },
            else => return env_err,
        }
        return last_err;
    }
}

pub fn githubProxyUrl(allocator: std.mem.Allocator, proxy: []const u8, url: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ std.mem.trimEnd(u8, proxy, "/"), url });
}

fn sha256DigestHex(value: []const u8) ?[]const u8 {
    const prefix = "sha256:";
    if (!std.ascii.startsWithIgnoreCase(value, prefix)) return null;
    const hex = value[prefix.len..];
    if (!isHexSha256(hex)) return null;
    return hex;
}

pub fn checksumFromSums(sums: []const u8, asset_name: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, sums, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        const hex = fields.next() orelse continue;
        const name_raw = fields.next() orelse continue;
        const name = if (name_raw.len > 0 and name_raw[0] == '*') name_raw[1..] else name_raw;
        if (std.mem.eql(u8, name, asset_name) and isHexSha256(hex)) return hex;
    }
    return null;
}

fn sha256Matches(bytes: []const u8, expected: []const u8) bool {
    if (!isHexSha256(expected)) return false;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return sha256DigestMatches(&digest, expected);
}

fn sha256DigestMatches(digest: *const [32]u8, expected: []const u8) bool {
    if (!isHexSha256(expected)) return false;
    var actual: [64]u8 = undefined;
    toHexLower(&actual, digest);
    return std.ascii.eqlIgnoreCase(&actual, expected);
}

fn toHexLower(out: *[64]u8, bytes: *const [32]u8) void {
    const table = "0123456789abcdef";
    for (bytes, 0..) |b, i| {
        out[i * 2] = table[b >> 4];
        out[i * 2 + 1] = table[b & 0x0f];
    }
}

fn isHexSha256(value: []const u8) bool {
    if (value.len != 64) return false;
    for (value) |c| {
        if (!std.ascii.isHex(c)) return false;
    }
    return true;
}

fn stringField(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    if (object.get(name)) |value| {
        if (value == .string) return value.string;
    }
    return null;
}

fn intField(object: std.json.ObjectMap, name: []const u8) ?u32 {
    if (object.get(name)) |value| {
        if (value == .integer and value.integer >= 0 and value.integer <= std.math.maxInt(u32)) return @intCast(value.integer);
    }
    return null;
}

fn findAssetUrl(object: std.json.ObjectMap, wanted: []const u8) ?[]const u8 {
    const asset = findAsset(object, wanted) orelse return null;
    return asset.url;
}

fn findAsset(object: std.json.ObjectMap, wanted: []const u8) ?ReleaseAsset {
    const assets = object.get("assets") orelse return null;
    if (assets != .array) return null;
    for (assets.array.items) |asset| {
        if (asset != .object) continue;
        const name = stringField(asset.object, "name") orelse continue;
        if (!std.mem.eql(u8, name, wanted)) continue;
        const url = stringField(asset.object, "browser_download_url") orelse return null;
        return .{
            .url = url,
            .digest = stringField(asset.object, "digest"),
        };
    }
    return null;
}

fn compareVersion(a_raw: []const u8, b_raw: []const u8) i32 {
    const a_no_build = stripBuildMetadata(a_raw);
    const b_no_build = stripBuildMetadata(b_raw);
    var ait = std.mem.splitScalar(u8, a_no_build, '.');
    var bit = std.mem.splitScalar(u8, b_no_build, '.');
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        const av = parseVersionPart(ait.next() orelse "0");
        const bv = parseVersionPart(bit.next() orelse "0");
        if (av > bv) return 1;
        if (av < bv) return -1;
    }
    return comparePrerelease(prereleasePart(a_no_build), prereleasePart(b_no_build));
}

fn stripBuildMetadata(value: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, value, '+') orelse value.len;
    return value[0..end];
}

fn prereleasePart(value: []const u8) []const u8 {
    const idx = std.mem.indexOfScalar(u8, value, '-') orelse return "";
    return value[idx + 1 ..];
}

fn comparePrerelease(a: []const u8, b: []const u8) i32 {
    if (a.len == 0 and b.len == 0) return 0;
    if (a.len == 0) return 1;
    if (b.len == 0) return -1;
    var ait = std.mem.splitScalar(u8, a, '.');
    var bit = std.mem.splitScalar(u8, b, '.');
    while (true) {
        const av = ait.next();
        const bv = bit.next();
        if (av == null and bv == null) return 0;
        if (av == null) return -1;
        if (bv == null) return 1;
        const cmp = comparePrereleaseIdentifier(av.?, bv.?);
        if (cmp != 0) return cmp;
    }
}

fn comparePrereleaseIdentifier(a: []const u8, b: []const u8) i32 {
    const ai = parseNumericIdentifier(a);
    const bi = parseNumericIdentifier(b);
    if (ai) |an| {
        if (bi) |bn| {
            if (an > bn) return 1;
            if (an < bn) return -1;
            return 0;
        }
        return -1;
    }
    if (bi != null) return 1;
    const order = std.mem.order(u8, a, b);
    return switch (order) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    };
}

fn parseNumericIdentifier(value: []const u8) ?u64 {
    if (value.len == 0) return null;
    for (value) |c| if (c < '0' or c > '9') return null;
    return std.fmt.parseInt(u64, value, 10) catch null;
}

fn isNumericVersion(value_raw: []const u8) bool {
    const value = parseVersionPrefixless(value_raw);
    if (value.len == 0) return false;
    return value[0] >= '0' and value[0] <= '9';
}

fn parseVersionPart(part: []const u8) u64 {
    const end = std.mem.indexOfAny(u8, part, "-+") orelse part.len;
    return std.fmt.parseInt(u64, part[0..end], 10) catch 0;
}

fn pendingStatePath(allocator: std.mem.Allocator, exe: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}.update-state.json", .{exe});
}

fn backupPath(allocator: std.mem.Allocator, exe: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}.bak", .{exe});
}

fn writePendingStateFile(allocator: std.mem.Allocator, path: []const u8, state: PendingUpdateState) !void {
    const body = try allocPendingStateJson(allocator, state);
    defer allocator.free(body);
    var file = try compat.createFileAbsolute(path, .{ .truncate = true });
    defer file.close(std.Options.debug_io);
    try file.writeStreamingAll(std.Options.debug_io, body);
}

fn readSmallFile(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    return compat.readFileAlloc(allocator, path, 64 * 1024);
}

fn copyFileAbsolute(src: []const u8, dst: []const u8) !void {
    try compat.copyFileAbsolute(src, dst, .executable_file);
}

fn runBinaryPreflight(allocator: std.mem.Allocator, path: []const u8) !void {
    const result = try std.process.run(allocator, std.Options.debug_io, .{
        .argv = &.{ path, "--show-warning" },
        .stdout_limit = .limited(0),
        .stderr_limit = .limited(0),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.UpdatePreflightFailed,
        else => return error.UpdatePreflightFailed,
    }
}

fn deleteFileIgnoreMissing(path: []const u8) void {
    compat.deleteFileAbsolute(path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => {},
    };
}
