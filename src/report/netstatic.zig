const std = @import("std");

pub const TrafficData = struct { timestamp: u64, tx: u64, rx: u64 };
pub const NetStaticConfig = struct {
    data_preserve_day: f64 = 31,
    detect_interval: f64 = 2,
    save_interval: f64 = 600,
    nics: []const []const u8 = &.{},
};

pub fn startOrContinue() !void {}
pub fn stop() !void {}

pub const Store = struct {
    reset: i64 = 0,
    up: u64 = 0,
    down: u64 = 0,
};

pub const Totals = struct {
    up: u64,
    down: u64,
};

pub fn applyMonthlyTotals(allocator: std.mem.Allocator, total_up: u64, total_down: u64, reset_day: i32) Totals {
    if (reset_day < 1 or reset_day > 31) return .{ .up = total_up, .down = total_down };
    const reset = lastResetDate(reset_day, std.time.timestamp());
    var store = readStore(allocator) catch Store{};
    if (store.reset != reset or total_up < store.up or total_down < store.down) {
        store = .{ .reset = reset, .up = total_up, .down = total_down };
        writeStore(allocator, store) catch {};
    }
    return .{
        .up = if (total_up >= store.up) total_up - store.up else 0,
        .down = if (total_down >= store.down) total_down - store.down else 0,
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

fn readStore(allocator: std.mem.Allocator) !Store {
    const path = storePath();
    const bytes = std.fs.cwd().readFileAlloc(allocator, path, 4096) catch |err| switch (err) {
        error.FileNotFound => return Store{},
        else => return err,
    };
    defer allocator.free(bytes);
    return parseStore(bytes);
}

fn writeStore(allocator: std.mem.Allocator, store: Store) !void {
    const path = storePath();
    if (std.fs.path.dirname(path)) |dir| std.fs.cwd().makePath(dir) catch {};
    const bytes = try allocStoreJson(allocator, store);
    defer allocator.free(bytes);
    var file = std.fs.cwd().createFile(path, .{ .truncate = true }) catch {
        var fallback = try std.fs.cwd().createFile(".komari-netstatic.json", .{ .truncate = true });
        defer fallback.close();
        try fallback.writeAll(bytes);
        return;
    };
    defer file.close();
    try file.writeAll(bytes);
}

fn storePath() []const u8 {
    return if (@import("builtin").os.tag == .windows) ".komari-netstatic.json" else "/var/lib/komari-agent/netstatic.json";
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
