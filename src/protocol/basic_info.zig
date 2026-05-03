const std = @import("std");
const version = @import("../version.zig");
const types = @import("types.zig");
const http = @import("http.zig");
const common = @import("../platform/common.zig");

/// BasicInfo payload serialization and upload helpers.
pub fn allocBasicInfoJson(allocator: std.mem.Allocator, info: common.BasicInfo, include_kernel: bool) ![]const u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    try types.writeBasicInfoJson(&out.writer, .{
        .cpu_name = info.cpu.name,
        .cpu_cores = info.cpu.cores,
        .arch = info.cpu.architecture,
        .os = info.os_name,
        .kernel_version = info.kernel_version,
        .ipv4 = info.ipv4,
        .ipv6 = info.ipv6,
        .mem_total = info.mem_total,
        .swap_total = info.swap_total,
        .disk_total = info.disk_total,
        .gpu_name = info.gpu_name,
        .virtualization = info.virtualization,
        .version = version.current,
    }, include_kernel);
    return out.toOwnedSlice();
}

pub fn upload(allocator: std.mem.Allocator, cfg: anytype, info: common.BasicInfo) !void {
    const payload = try allocBasicInfoJson(allocator, info, true);
    defer allocator.free(payload);
    const url = try http.basicInfoUrl(allocator, cfg.endpoint, cfg.token);
    defer allocator.free(url);
    http.postJson(allocator, url, payload, cfg) catch |first_err| {
        const fallback = try allocBasicInfoJson(allocator, info, false);
        defer allocator.free(fallback);
        http.postJson(allocator, url, fallback, cfg) catch return first_err;
    };
}
