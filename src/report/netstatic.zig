const std = @import("std");
const builtin = @import("builtin");
const compat = @import("compat");

const safe_command_path = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin";

/// Monthly traffic accounting and persistence for network statistics.
pub const TrafficData = struct { timestamp: u64, tx: u64, rx: u64 };
pub const Counters = struct { tx: u64 = 0, rx: u64 = 0 };

pub const NetStaticConfig = struct {
    data_preserve_day: f64 = 31,
    detect_interval: f64 = 2,
    save_interval: f64 = 600,
    nics: []const []const u8 = &.{},
};

pub const Store = struct {
    reset: i64 = 0,
    up: u64 = 0,
    down: u64 = 0,
};

pub const Totals = struct {
    up: u64,
    down: u64,
};

const SampleList = std.ArrayList(TrafficData);
const SampleMap = std.StringArrayHashMapUnmanaged(SampleList);
const CounterMap = std.StringArrayHashMapUnmanaged(Counters);

const Runtime = struct {
    allocator: std.mem.Allocator,
    mutex: compat.Mutex = .{},
    running: bool = false,
    stop_requested: bool = false,
    interfaces: SampleMap,
    cache: SampleMap,
    last: CounterMap,
    config: NetStaticConfig = .{},
};

var runtime: ?*Runtime = null;

pub fn startOrContinue() !void {
    const allocator = std.heap.page_allocator;
    const rt = try getRuntime(allocator);
    rt.mutex.lock();
    if (rt.running) {
        rt.mutex.unlock();
        return;
    }
    try loadFromFileLocked(rt);
    rt.running = true;
    rt.stop_requested = false;
    rt.mutex.unlock();

    const sampler = try std.Thread.spawn(.{ .stack_size = 256 * 1024 }, sampleLoop, .{rt});
    sampler.detach();
    const saver = try std.Thread.spawn(.{ .stack_size = 256 * 1024 }, saveLoop, .{rt});
    saver.detach();
}

pub fn stop() !void {
    const rt = runtime orelse return;
    rt.mutex.lock();
    rt.stop_requested = true;
    flushCacheLocked(rt, nowUnix());
    purgeExpiredLocked(rt);
    try saveToFileLocked(rt);
    rt.running = false;
    rt.mutex.unlock();
}

pub fn setNewConfig(new_cfg: NetStaticConfig) !void {
    const rt = try getRuntime(std.heap.page_allocator);
    rt.mutex.lock();
    defer rt.mutex.unlock();
    if (new_cfg.data_preserve_day != 0) rt.config.data_preserve_day = new_cfg.data_preserve_day;
    if (new_cfg.detect_interval != 0) rt.config.detect_interval = new_cfg.detect_interval;
    if (new_cfg.save_interval != 0) rt.config.save_interval = new_cfg.save_interval;
    rt.config.nics = new_cfg.nics;
    pruneUnmonitoredLocked(rt);
    purgeExpiredLocked(rt);
    try saveToFileLocked(rt);
}

pub fn applyMonthlyTotals(allocator: std.mem.Allocator, total_up: u64, total_down: u64, reset_day: i32) Totals {
    _ = total_up;
    _ = total_down;
    return applyMonthlyTotalsFiltered(allocator, reset_day, "", "");
}

pub fn applyMonthlyTotalsFiltered(allocator: std.mem.Allocator, reset_day: i32, include_nics: []const u8, exclude_nics: []const u8) Totals {
    if (reset_day < 1 or reset_day > 31) return .{ .up = 0, .down = 0 };
    startOrContinue() catch {};
    const start: u64 = @intCast(lastResetDate(reset_day, compat.unixTimestamp()));
    const end: u64 = @intCast(compat.unixTimestamp());
    return totalTrafficBetween(allocator, start, end, include_nics, exclude_nics) catch .{ .up = 0, .down = 0 };
}

pub fn totalTrafficBetween(allocator: std.mem.Allocator, start: u64, end: u64, include_nics: []const u8, exclude_nics: []const u8) !Totals {
    _ = allocator;
    const rt = try getRuntime(std.heap.page_allocator);
    rt.mutex.lock();
    defer rt.mutex.unlock();
    var totals = Totals{ .up = 0, .down = 0 };
    sumMapBetween(&totals, rt.interfaces, start, end, include_nics, exclude_nics);
    sumMapBetween(&totals, rt.cache, start, end, include_nics, exclude_nics);
    return totals;
}

fn getRuntime(allocator: std.mem.Allocator) !*Runtime {
    if (runtime) |rt| return rt;
    const rt = try allocator.create(Runtime);
    rt.* = .{
        .allocator = allocator,
        .interfaces = .empty,
        .cache = .empty,
        .last = .empty,
    };
    runtime = rt;
    return rt;
}

fn sampleLoop(rt: *Runtime) void {
    while (true) {
        rt.mutex.lock();
        const stop_requested = rt.stop_requested;
        const interval_ms: u64 = @intFromFloat(@max(rt.config.detect_interval, 0.1) * 1000);
        rt.mutex.unlock();
        if (stop_requested) return;
        compat.sleep(interval_ms * std.time.ns_per_ms);
        rt.mutex.lock();
        sampleOnceLocked(rt) catch {};
        rt.mutex.unlock();
    }
}

fn saveLoop(rt: *Runtime) void {
    while (true) {
        rt.mutex.lock();
        const stop_requested = rt.stop_requested;
        const interval_ms: u64 = @intFromFloat(@max(rt.config.save_interval, 1) * 1000);
        rt.mutex.unlock();
        if (stop_requested) return;
        compat.sleep(interval_ms * std.time.ns_per_ms);
        rt.mutex.lock();
        flushCacheLocked(rt, nowUnix());
        purgeExpiredLocked(rt);
        saveToFileLocked(rt) catch {};
        rt.mutex.unlock();
    }
}

fn sampleOnceLocked(rt: *Runtime) !void {
    if (builtin.os.tag != .freebsd and builtin.os.tag != .macos) {
        return sampleProcNetDevOnceLocked(rt);
    }
    var counters = try readProcNetDev(rt.allocator);
    defer deinitCounterMap(&counters);
    try sampleCounterMapLocked(rt, &counters);
}

fn sampleCounterMapLocked(rt: *Runtime, counters: *CounterMap) !void {
    const ts = nowUnix();
    var it = counters.iterator();
    while (it.next()) |entry| {
        try sampleCounterLocked(rt, ts, entry.key_ptr.*, entry.value_ptr.*);
    }
}

fn sampleProcNetDevOnceLocked(rt: *Runtime) !void {
    var buf: [64 * 1024]u8 = undefined;
    const bytes = readSmallFile("/proc/net/dev", &buf) orelse return;
    if (bytes.len == buf.len) {
        var counters = try readProcNetDev(rt.allocator);
        defer deinitCounterMap(&counters);
        return sampleCounterMapLocked(rt, &counters);
    }
    const ts = nowUnix();
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        var fields = std.mem.tokenizeAny(u8, line[colon + 1 ..], " \t");
        const rx = std.fmt.parseInt(u64, fields.next() orelse "0", 10) catch 0;
        var idx: usize = 1;
        var tx: u64 = 0;
        while (fields.next()) |field| : (idx += 1) {
            if (idx == 8) {
                tx = std.fmt.parseInt(u64, field, 10) catch 0;
                break;
            }
        }
        try sampleCounterLocked(rt, ts, name, .{ .tx = tx, .rx = rx });
    }
}

fn sampleCounterLocked(rt: *Runtime, ts: u64, name: []const u8, current: Counters) !void {
    if (!isNicAllowed(rt.config, name)) return;
    if (rt.last.getIndex(name)) |idx| {
        const previous = rt.last.values()[idx];
        const dtx = safeDelta(current.tx, previous.tx);
        const drx = safeDelta(current.rx, previous.rx);
        if (dtx != 0 or drx != 0) try appendSample(&rt.cache, rt.allocator, name, .{ .timestamp = ts, .tx = dtx, .rx = drx });
        rt.last.values()[idx] = current;
    } else {
        try rt.last.put(rt.allocator, try rt.allocator.dupe(u8, name), current);
    }
}

fn readProcNetDev(allocator: std.mem.Allocator) !CounterMap {
    if (builtin.os.tag == .freebsd or builtin.os.tag == .macos) return readNetstatCounters(allocator);
    var result: CounterMap = .empty;
    const bytes = compat.readFileAlloc(allocator, "/proc/net/dev", 1024 * 1024) catch return result;
    defer allocator.free(bytes);
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        var fields = std.mem.tokenizeAny(u8, line[colon + 1 ..], " \t");
        const rx = std.fmt.parseInt(u64, fields.next() orelse "0", 10) catch 0;
        var idx: usize = 1;
        var tx: u64 = 0;
        while (fields.next()) |field| : (idx += 1) {
            if (idx == 8) {
                tx = std.fmt.parseInt(u64, field, 10) catch 0;
                break;
            }
        }
        try result.put(allocator, try allocator.dupe(u8, name), .{ .tx = tx, .rx = rx });
    }
    return result;
}

fn readNetstatCounters(allocator: std.mem.Allocator) !CounterMap {
    var result: CounterMap = .empty;
    const out = commandOutput(allocator, &.{ "netstat", "-ibn" }) catch return result;
    defer allocator.free(out);
    var lines = std.mem.splitScalar(u8, out, '\n');
    _ = lines.next();
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        const name = fields.next() orelse continue;
        if (std.mem.eql(u8, name, "lo0")) continue;
        var vals: [12][]const u8 = undefined;
        var n: usize = 0;
        while (fields.next()) |f| : (n += 1) {
            if (n < vals.len) vals[n] = f;
        }
        if (n < 10) continue;
        const rx = std.fmt.parseInt(u64, vals[5], 10) catch 0;
        const tx = std.fmt.parseInt(u64, vals[8], 10) catch 0;
        try result.put(allocator, try allocator.dupe(u8, name), .{ .tx = tx, .rx = rx });
    }
    return result;
}

fn commandOutput(allocator: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    var env = try compat.currentEnvMap(allocator);
    defer env.deinit();
    try env.put("PATH", safe_command_path);
    const result = try compat.runOutputIgnoreStderr(allocator, argv, &env, 1024 * 1024);
    errdefer allocator.free(result.stdout);
    if (result.term != .exited or result.term.exited != 0) return error.CommandFailed;
    return result.stdout;
}

fn appendSample(map: *SampleMap, allocator: std.mem.Allocator, name: []const u8, sample: TrafficData) !void {
    if (map.getPtr(name)) |list| {
        try list.append(allocator, sample);
        return;
    }
    var list = SampleList.empty;
    try list.append(allocator, sample);
    try map.put(allocator, try allocator.dupe(u8, name), list);
}

fn flushCacheLocked(rt: *Runtime, ts: u64) void {
    var it = rt.cache.iterator();
    while (it.next()) |entry| {
        var tx: u64 = 0;
        var rx: u64 = 0;
        for (entry.value_ptr.items) |sample| {
            tx += sample.tx;
            rx += sample.rx;
        }
        if (tx != 0 or rx != 0) appendSample(&rt.interfaces, rt.allocator, entry.key_ptr.*, .{ .timestamp = ts, .tx = tx, .rx = rx }) catch {};
        entry.value_ptr.clearRetainingCapacity();
    }
}

fn purgeExpiredLocked(rt: *Runtime) void {
    const ttl: i64 = @intFromFloat(@max(rt.config.data_preserve_day, 1) * 24 * 3600);
    const cutoff: u64 = @intCast(@max(compat.unixTimestamp() - ttl, 0));
    purgeMap(rt.interfaces, cutoff);
    purgeMap(rt.cache, cutoff);
}

fn pruneUnmonitoredLocked(rt: *Runtime) void {
    if (rt.config.nics.len == 0) return;
    pruneCounterMap(&rt.last, rt.allocator, rt.config);
    pruneSampleMap(&rt.cache, rt.allocator, rt.config);
}

fn pruneCounterMap(map: *CounterMap, allocator: std.mem.Allocator, cfg: NetStaticConfig) void {
    var i: usize = 0;
    while (i < map.count()) {
        const name = map.keys()[i];
        if (isNicAllowed(cfg, name)) {
            i += 1;
            continue;
        }
        allocator.free(name);
        _ = map.orderedRemoveAt(i);
    }
}

fn pruneSampleMap(map: *SampleMap, allocator: std.mem.Allocator, cfg: NetStaticConfig) void {
    var i: usize = 0;
    while (i < map.count()) {
        const name = map.keys()[i];
        if (isNicAllowed(cfg, name)) {
            i += 1;
            continue;
        }
        map.values()[i].deinit(allocator);
        allocator.free(name);
        _ = map.orderedRemoveAt(i);
    }
}

fn purgeMap(map: SampleMap, cutoff: u64) void {
    var it = map.iterator();
    while (it.next()) |entry| {
        var kept: usize = 0;
        for (entry.value_ptr.items) |sample| {
            if (sample.timestamp >= cutoff) {
                entry.value_ptr.items[kept] = sample;
                kept += 1;
            }
        }
        entry.value_ptr.shrinkRetainingCapacity(kept);
    }
}

fn sumMapBetween(out: *Totals, map: SampleMap, start: u64, end: u64, include_nics: []const u8, exclude_nics: []const u8) void {
    var it = map.iterator();
    while (it.next()) |entry| {
        if (!shouldInclude(entry.key_ptr.*, include_nics, exclude_nics)) continue;
        for (entry.value_ptr.items) |sample| {
            if ((start == 0 or sample.timestamp >= start) and (end == 0 or sample.timestamp <= end)) {
                out.up += sample.tx;
                out.down += sample.rx;
            }
        }
    }
}

fn loadFromFileLocked(rt: *Runtime) !void {
    const bytes = compat.readFileAlloc(rt.allocator, saveFilePath(), 64 * 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer rt.allocator.free(bytes);
    try parseNetStaticJsonInto(rt, bytes);
    purgeExpiredLocked(rt);
}

fn parseNetStaticJsonInto(rt: *Runtime, bytes: []const u8) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, rt.allocator, bytes, .{}) catch {
        std.Io.Dir.cwd().rename(saveFilePath(), std.Io.Dir.cwd(), "net_static.json.bak", std.Options.debug_io) catch {};
        return;
    };
    defer parsed.deinit();
    if (parsed.value != .object) return;
    if (parsed.value.object.get("config")) |cfg_value| {
        if (cfg_value == .object) {
            rt.config.data_preserve_day = jsonFloat(cfg_value.object.get("data_preserve_day")) orelse rt.config.data_preserve_day;
            rt.config.detect_interval = jsonFloat(cfg_value.object.get("detect_interval")) orelse rt.config.detect_interval;
            rt.config.save_interval = jsonFloat(cfg_value.object.get("save_interval")) orelse rt.config.save_interval;
        }
    }
    const interfaces = parsed.value.object.get("interfaces") orelse return;
    if (interfaces != .object) return;
    var it = interfaces.object.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* != .array) continue;
        var list = SampleList.empty;
        for (entry.value_ptr.array.items) |item| {
            if (item != .object) continue;
            try list.append(rt.allocator, .{
                .timestamp = @intCast(jsonInt(item.object.get("timestamp")) orelse 0),
                .tx = @intCast(jsonInt(item.object.get("tx")) orelse 0),
                .rx = @intCast(jsonInt(item.object.get("rx")) orelse 0),
            });
        }
        try rt.interfaces.put(rt.allocator, try rt.allocator.dupe(u8, entry.key_ptr.*), list);
    }
}

fn saveToFileLocked(rt: *Runtime) !void {
    var writer = std.Io.Writer.Allocating.init(rt.allocator);
    defer writer.deinit();
    try writer.writer.writeAll("{\"interfaces\":{");
    var first_iface = true;
    var it = rt.interfaces.iterator();
    while (it.next()) |entry| {
        if (!first_iface) try writer.writer.writeByte(',');
        first_iface = false;
        try writer.writer.print("{f}:[", .{std.json.fmt(entry.key_ptr.*, .{})});
        for (entry.value_ptr.items, 0..) |sample, i| {
            if (i != 0) try writer.writer.writeByte(',');
            try writer.writer.print("{{\"timestamp\":{d},\"tx\":{d},\"rx\":{d}}}", .{ sample.timestamp, sample.tx, sample.rx });
        }
        try writer.writer.writeByte(']');
    }
    try writer.writer.print("}},\"config\":{{\"data_preserve_day\":{d},\"detect_interval\":{d},\"save_interval\":{d},\"nics\":[", .{ rt.config.data_preserve_day, rt.config.detect_interval, rt.config.save_interval });
    for (rt.config.nics, 0..) |nic, i| {
        if (i != 0) try writer.writer.writeByte(',');
        try writer.writer.print("{f}", .{std.json.fmt(nic, .{})});
    }
    try writer.writer.writeAll("]}}}");
    const bytes = try writer.toOwnedSlice();
    defer rt.allocator.free(bytes);
    const tmp = "net_static.json.tmp";
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = tmp, .data = bytes });
    std.Io.Dir.cwd().rename(tmp, std.Io.Dir.cwd(), saveFilePath(), std.Options.debug_io) catch {
        try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = saveFilePath(), .data = bytes });
    };
}

pub fn parseStore(bytes: []const u8) !Store {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, bytes, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    return .{
        .reset = jsonInt(obj.get("reset")) orelse 0,
        .up = @intCast(jsonInt(obj.get("up")) orelse 0),
        .down = @intCast(jsonInt(obj.get("down")) orelse 0),
    };
}

pub fn allocStoreJson(allocator: std.mem.Allocator, store: Store) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{{\"reset\":{d},\"up\":{d},\"down\":{d}}}", .{ store.reset, store.up, store.down });
}

fn jsonInt(value: ?std.json.Value) ?i64 {
    const v = value orelse return null;
    return switch (v) {
        .integer => |n| n,
        .float => |n| @intFromFloat(n),
        else => null,
    };
}

fn jsonFloat(value: ?std.json.Value) ?f64 {
    const v = value orelse return null;
    return switch (v) {
        .float => |n| n,
        .integer => |n| @floatFromInt(n),
        else => null,
    };
}

fn isNicAllowed(config: NetStaticConfig, name: []const u8) bool {
    if (config.nics.len == 0) return true;
    for (config.nics) |nic| if (std.mem.eql(u8, nic, name)) return true;
    return false;
}

fn shouldInclude(name: []const u8, include_nics: []const u8, exclude_nics: []const u8) bool {
    const excluded_prefixes = [_][]const u8{ "br", "cni", "docker", "podman", "flannel", "lo", "veth", "virbr", "vmbr", "tap", "fwbr", "fwpr" };
    for (&excluded_prefixes) |prefix| {
        if (std.mem.startsWith(u8, name, prefix)) return false;
    }
    if (include_nics.len != 0) return csvMatches(include_nics, name);
    if (exclude_nics.len != 0 and csvMatches(exclude_nics, name)) return false;
    return true;
}

fn csvMatches(csv: []const u8, needle: []const u8) bool {
    var it = std.mem.splitScalar(u8, csv, ',');
    while (it.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t");
        if (std.mem.eql(u8, trimmed, needle)) return true;
        if (globMatch(trimmed, needle)) return true;
    }
    return false;
}

fn globMatch(pattern: []const u8, value: []const u8) bool {
    if (std.mem.eql(u8, pattern, "*")) return true;
    const star = std.mem.indexOfScalar(u8, pattern, '*') orelse return std.mem.eql(u8, pattern, value);
    return std.mem.startsWith(u8, value, pattern[0..star]) and std.mem.endsWith(u8, value, pattern[star + 1 ..]);
}

fn deinitCounterMap(map: *CounterMap) void {
    var it = map.iterator();
    while (it.next()) |entry| std.heap.page_allocator.free(entry.key_ptr.*);
    map.deinit(std.heap.page_allocator);
}

fn safeDelta(cur: u64, prev: u64) u64 {
    return if (cur >= prev) cur - prev else 0;
}

fn nowUnix() u64 {
    return @intCast(compat.unixTimestamp());
}

fn readSmallFile(path: []const u8, buf: []u8) ?[]const u8 {
    const file = compat.openFile(path, .{}) catch return null;
    defer file.close(std.Options.debug_io);
    const n = compat.readAll(file, buf) catch return null;
    return buf[0..n];
}

fn saveFilePath() []const u8 {
    return "./net_static.json";
}

pub fn lastResetDate(reset_day: i32, now: i64) i64 {
    if (reset_day < 1 or reset_day > 31) return now;
    const current = civilFromTimestamp(now);
    const this_reset_date = actualResetDate(current.year, current.month, reset_day);
    const this_reset = utcTimestamp(this_reset_date.year, this_reset_date.month, this_reset_date.day) catch return now;
    if (now >= this_reset) return this_reset;

    var prev_year = current.year;
    var prev_month = current.month - 1;
    if (prev_month < 1) {
        prev_month = 12;
        prev_year -= 1;
    }
    const prev_reset_date = actualResetDate(prev_year, prev_month, reset_day);
    return utcTimestamp(prev_reset_date.year, prev_reset_date.month, prev_reset_date.day) catch now;
}

pub fn writeEmptyStore(allocator: std.mem.Allocator) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{{\"interfaces\":{{}},\"config\":{{\"data_preserve_day\":31,\"detect_interval\":2,\"save_interval\":600,\"nics\":[]}}}}", .{});
}

pub const CivilDate = struct {
    year: i32,
    month: i32,
    day: i32,
};

pub fn utcTimestamp(year: i32, month: i32, day: i32) !i64 {
    const days = daysFromCivil(year, month, day);
    return days * std.time.s_per_day;
}

fn actualResetDate(year: i32, month: i32, reset_day: i32) CivilDate {
    const last = daysInMonth(year, month);
    if (reset_day <= last) return .{ .year = year, .month = month, .day = reset_day };
    var next_year = year;
    var next_month = month + 1;
    if (next_month > 12) {
        next_month = 1;
        next_year += 1;
    }
    return .{ .year = next_year, .month = next_month, .day = 1 };
}

fn daysInMonth(year: i32, month: i32) i32 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (isLeapYear(year)) 29 else 28,
        else => 30,
    };
}

fn isLeapYear(year: i32) bool {
    return @mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0);
}

pub fn civilFromTimestamp(timestamp: i64) CivilDate {
    return civilFromDays(@divFloor(timestamp, std.time.s_per_day));
}

fn daysFromCivil(year_raw: i32, month_raw: i32, day_raw: i32) i64 {
    var year = year_raw;
    const month = month_raw;
    const day = day_raw;
    year -= if (month <= 2) 1 else 0;
    const era = @divFloor(year, 400);
    const yoe = year - era * 400;
    const mp = month + @as(i32, if (month > 2) -3 else 9);
    const doy = @divFloor(153 * mp + 2, 5) + day - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return @as(i64, era) * 146097 + doe - 719468;
}

fn civilFromDays(days_raw: i64) CivilDate {
    const z = days_raw + 719468;
    const era = @divFloor(z, 146097);
    const doe: i32 = @intCast(z - era * 146097);
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    var year: i32 = @intCast(yoe + era * 400);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const day = doy - @divFloor(153 * mp + 2, 5) + 1;
    const month = mp + @as(i32, if (mp < 10) 3 else -9);
    year += if (month <= 2) 1 else 0;
    return .{ .year = year, .month = month, .day = day };
}
