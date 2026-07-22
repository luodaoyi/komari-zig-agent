const std = @import("std");
const flow = @import("basic_info_flow");

test "foreground upload success keeps success log" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    const outcome = try flow.handleForegroundUploadResult(&out.writer, .startup, {});
    switch (outcome) {
        .success => {},
        .deferred, .failure => return error.TestUnexpectedResult,
    }

    try std.testing.expectEqualStrings("Basic info uploaded successfully\n", out.written());
}

test "foreground upload deferral is reported without failure" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    const outcome = try flow.handleForegroundUploadResult(&out.writer, .startup, error.BasicInfoDeferredUntilPublicIp);
    switch (outcome) {
        .deferred => {},
        .success, .failure => return error.TestUnexpectedResult,
    }

    try std.testing.expectEqualStrings("Basic info upload deferred during startup: waiting for public IP refresh\n", out.written());
}

test "foreground upload deferral is the only case that restarts background loop immediately" {
    try std.testing.expect(!flow.shouldStartBackgroundLoopImmediately(.success));
    try std.testing.expect(flow.shouldStartBackgroundLoopImmediately(.deferred));
    try std.testing.expect(!flow.shouldStartBackgroundLoopImmediately(.{ .failure = error.Timeout }));
}

test "automatic foreground upload defers non-public IPv4" {
    try std.testing.expect(flow.shouldDeferForPublicIPv4(false, false, "", false));
    try std.testing.expect(!flow.shouldDeferForPublicIPv4(false, false, "", true));
}

test "explicit IPv4 modes preserve user-selected addresses" {
    try std.testing.expect(!flow.shouldDeferForPublicIPv4(false, false, "10.0.0.5", false));
    try std.testing.expect(!flow.shouldDeferForPublicIPv4(false, true, "", false));
    try std.testing.expect(!flow.shouldDeferForPublicIPv4(true, false, "", false));
}

test "foreground upload failure during startup is tolerated and logged" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    const outcome = try flow.handleForegroundUploadResult(&out.writer, .startup, error.Timeout);
    switch (outcome) {
        .success, .deferred => return error.TestUnexpectedResult,
        .failure => |err| try std.testing.expectEqual(error.Timeout, err),
    }

    try std.testing.expectEqualStrings("Basic info upload failed during startup: Timeout\n", out.written());
}

test "foreground upload failure during websocket reconnect is tolerated and logged" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    const outcome = try flow.handleForegroundUploadResult(&out.writer, .websocket_reconnect, error.HttpStatusNotOk);
    switch (outcome) {
        .success, .deferred => return error.TestUnexpectedResult,
        .failure => |err| try std.testing.expectEqual(error.HttpStatusNotOk, err),
    }

    try std.testing.expectEqualStrings("Basic info upload failed during websocket reconnect: HttpStatusNotOk\n", out.written());
}

test "foreground upload failure during websocket reconnect keeps protocol failure semantics" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    const outcome = try flow.handleForegroundUploadResult(&out.writer, .websocket_reconnect, error.InvalidV2Response);
    switch (outcome) {
        .success, .deferred => return error.TestUnexpectedResult,
        .failure => |err| try std.testing.expectEqual(error.InvalidV2Response, err),
    }
}
