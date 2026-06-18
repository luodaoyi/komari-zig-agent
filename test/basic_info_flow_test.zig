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
