const std = @import("std");
const version = @import("../version.zig");
const types = @import("types.zig");
const http = @import("http.zig");
const common = @import("../platform/common.zig");

pub fn allocBasicInfoJson(allocator: std.mem.Allocator, info: common.BasicInfo, include_kernel: bool) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try types.writeBasicInfoJson(out.writer(allocator), .{
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
    return out.toOwnedSlice(allocator);
}

pub fn upload(allocator: std.mem.Allocator, cfg: anytype, info: common.BasicInfo) !void {
    const payload = try allocBasicInfoJson(allocator, info, true);
    defer allocator.free(payload);
    const url = try http.basicInfoUrl(allocator, cfg.endpoint, cfg.token);
    defer allocator.free(url);
    try postJsonWithCurl(allocator, url, payload, cfg);
}

fn postJsonWithCurl(allocator: std.mem.Allocator, url: []const u8, payload: []const u8, cfg: anytype) !void {
    const tmp_name = try std.fmt.allocPrint(allocator, "/tmp/komari-basic-{d}.json", .{std.time.timestamp()});
    defer allocator.free(tmp_name);
    {
        var file = try std.fs.createFileAbsolute(tmp_name, .{ .truncate = true });
        defer file.close();
        try file.writeAll(payload);
    }
    defer std.fs.deleteFileAbsolute(tmp_name) catch {};

    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(allocator);
    try args.appendSlice(allocator, &.{ "curl", "-fsS", "-X", "POST", "-H", "Content-Type: application/json" });
    if (cfg.ignore_unsafe_cert) try args.append(allocator, "-k");
    if (cfg.cf_access_client_id.len != 0 and cfg.cf_access_client_secret.len != 0) {
        try args.appendSlice(allocator, &.{ "-H", try std.fmt.allocPrint(allocator, "CF-Access-Client-Id: {s}", .{cfg.cf_access_client_id}) });
        try args.appendSlice(allocator, &.{ "-H", try std.fmt.allocPrint(allocator, "CF-Access-Client-Secret: {s}", .{cfg.cf_access_client_secret}) });
    }
    try args.appendSlice(allocator, &.{ "--data-binary", try std.fmt.allocPrint(allocator, "@{s}", .{tmp_name}), url });

    var child = std.process.Child.init(args.items, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    const stdout = try child.stdout.?.readToEndAlloc(allocator, 64 * 1024);
    defer allocator.free(stdout);
    const stderr = try child.stderr.?.readToEndAlloc(allocator, 64 * 1024);
    defer allocator.free(stderr);
    const term = try child.wait();
    if (term != .Exited or term.Exited != 0) {
        return error.BasicInfoUploadFailed;
    }
}
