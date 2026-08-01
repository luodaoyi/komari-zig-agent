const std = @import("std");
const builtin = @import("builtin");
const net = @import("net");
const raw_conn = @import("protocol_raw_conn");

test "tls ca bundle storage is per connection" {
    if (std.http.Client.disable_tls) {
        try std.testing.expectEqualStrings("disabled", raw_conn.tls_ca_bundle_storage);
    } else {
        try std.testing.expectEqualStrings("per_connection", raw_conn.tls_ca_bundle_storage);
    }
}

test "tls ca bundle can be rescanned without global cache" {
    try raw_conn.rescanCaBundleForTest();
}

test "linux socket timeout ABI follows kernel long width" {
    if (builtin.os.tag != .linux) return;
    try std.testing.expectEqual(@sizeOf(c_long) * 2, net.linuxSocketTimevalSize());
}
