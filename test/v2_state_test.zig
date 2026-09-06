const std = @import("std");
const v2_state = @import("protocol_v2_state");

test "requested protocol version normalizes to v1 or v2" {
    v2_state.initRequestedProtocolVersion(0);
    try std.testing.expectEqual(@as(i32, 1), v2_state.requestedProtocolVersion());

    v2_state.initRequestedProtocolVersion(1);
    try std.testing.expectEqual(@as(i32, 1), v2_state.requestedProtocolVersion());

    v2_state.initRequestedProtocolVersion(2);
    try std.testing.expectEqual(@as(i32, 2), v2_state.requestedProtocolVersion());
}

test "v2 protocol failures fall back after three attempts" {
    v2_state.initRequestedProtocolVersion(2);
    v2_state.resetConnectionProtocolVersion();

    const first = v2_state.noteV2AttemptResult(2, error.InvalidV2Response);
    try std.testing.expectEqual(@as(u32, 1), first.failures);
    try std.testing.expect(!first.fallback);

    const second = v2_state.noteV2AttemptResult(2, error.InvalidV2EventResult);
    try std.testing.expectEqual(@as(u32, 2), second.failures);
    try std.testing.expect(!second.fallback);

    const third = v2_state.noteV2AttemptResult(2, error.HttpStatusNotOk);
    try std.testing.expectEqual(@as(u32, 3), third.failures);
    try std.testing.expect(third.fallback);
}

test "non protocol errors do not count toward v2 fallback" {
    v2_state.initRequestedProtocolVersion(2);
    v2_state.resetConnectionProtocolVersion();

    const result = v2_state.noteV2AttemptResult(2, error.ConnectionRefused);
    try std.testing.expectEqual(@as(u32, 0), result.failures);
    try std.testing.expect(!result.fallback);

    const followup = v2_state.noteV2AttemptResult(2, error.InvalidV2Response);
    try std.testing.expectEqual(@as(u32, 1), followup.failures);
    try std.testing.expect(!followup.fallback);
}

test "successful v2 attempt resets failure count" {
    v2_state.initRequestedProtocolVersion(2);
    v2_state.resetConnectionProtocolVersion();

    _ = v2_state.noteV2AttemptResult(2, error.InvalidV2Response);
    _ = v2_state.noteV2AttemptResult(2, error.InvalidV2Response);

    const success = v2_state.noteV2AttemptResult(2, null);
    try std.testing.expectEqual(@as(u32, 0), success.failures);
    try std.testing.expect(!success.fallback);

    const next = v2_state.noteV2AttemptResult(2, error.InvalidV2Response);
    try std.testing.expectEqual(@as(u32, 1), next.failures);
    try std.testing.expect(!next.fallback);
}


test "sticky connection version clears back to requested v2" {
    v2_state.initRequestedProtocolVersion(2);
    v2_state.resetConnectionProtocolVersion();
    try std.testing.expectEqual(@as(i32, 2), v2_state.uploadProtocolVersion());

    v2_state.setConnectionProtocolVersion(1);
    try std.testing.expectEqual(@as(i32, 1), v2_state.uploadProtocolVersion());

    v2_state.resetConnectionProtocolVersion();
    try std.testing.expectEqual(@as(i32, 2), v2_state.uploadProtocolVersion());
}

test "v2 protocol handshake failures count toward fallback" {
    v2_state.initRequestedProtocolVersion(2);
    v2_state.resetConnectionProtocolVersion();

    try std.testing.expect(v2_state.isV2ProtocolFailure(error.HttpStatusNotOk));
    try std.testing.expect(v2_state.isV2ProtocolFailure(error.WebSocketHandshakeFailed));
    try std.testing.expect(!v2_state.isV2ProtocolFailure(error.ConnectFailed));

    const first = v2_state.noteV2AttemptResult(2, error.WebSocketHandshakeFailed);
    try std.testing.expectEqual(@as(u32, 1), first.failures);
    try std.testing.expect(!first.fallback);
}
