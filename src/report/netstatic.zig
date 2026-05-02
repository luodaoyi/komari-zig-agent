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
