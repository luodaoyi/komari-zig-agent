const std = @import("std");

/// Shared foreground upload policy for startup and reconnect paths.
pub const UploadContext = enum {
    startup,
    websocket_reconnect,
};

pub const ForegroundUploadOutcome = union(enum) {
    success,
    failure: anyerror,
};

pub fn contextLabel(context: UploadContext) []const u8 {
    return switch (context) {
        .startup => "startup",
        .websocket_reconnect => "websocket reconnect",
    };
}

pub fn handleForegroundUploadResult(
    writer: anytype,
    context: UploadContext,
    result: anyerror!void,
) !ForegroundUploadOutcome {
    result catch |err| {
        try writer.print("Basic info upload failed during {s}: {s}\n", .{ contextLabel(context), @errorName(err) });
        return .{ .failure = err };
    };

    try writer.writeAll("Basic info uploaded successfully\n");
    return .success;
}
