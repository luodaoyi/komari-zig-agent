const std = @import("std");

/// Shared foreground upload policy for startup and reconnect paths.
pub const UploadContext = enum {
    startup,
    websocket_reconnect,
};

pub const ForegroundUploadOutcome = union(enum) {
    success,
    deferred,
    failure: anyerror,
};

pub fn shouldStartBackgroundLoopImmediately(outcome: ForegroundUploadOutcome) bool {
    return outcome == .deferred;
}

/// Decides whether a synchronous upload must wait for the public IPv4 refresh.
pub fn shouldDeferForPublicIPv4(
    allow_external_ip_lookup: bool,
    get_ip_addr_from_nic: bool,
    custom_ipv4: []const u8,
    current_is_public: bool,
) bool {
    if (allow_external_ip_lookup or get_ip_addr_from_nic or custom_ipv4.len != 0) return false;
    return !current_is_public;
}

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
        if (err == error.BasicInfoDeferredUntilPublicIp) {
            try writer.print("Basic info upload deferred during {s}: waiting for public IP refresh\n", .{contextLabel(context)});
            return .deferred;
        }
        try writer.print("Basic info upload failed during {s}: {s}\n", .{ contextLabel(context), @errorName(err) });
        return .{ .failure = err };
    };

    try writer.writeAll("Basic info uploaded successfully\n");
    return .success;
}
