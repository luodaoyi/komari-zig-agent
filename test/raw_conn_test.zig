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

test "freebsd ca cert file paths match Go root_bsd order" {
    try std.testing.expectEqualStrings("/usr/local/etc/ssl/cert.pem", raw_conn.freebsd_ca_cert_file_paths[0]);
    try std.testing.expectEqualStrings("/etc/ssl/cert.pem", raw_conn.freebsd_ca_cert_file_paths[1]);
    try std.testing.expectEqualStrings("/usr/local/share/certs/ca-root-nss.crt", raw_conn.freebsd_ca_cert_file_paths[2]);
    try std.testing.expectEqualStrings("/etc/ssl/certs", raw_conn.freebsd_ca_cert_dir_paths[0]);
    try std.testing.expectEqualStrings("/usr/local/share/certs", raw_conn.freebsd_ca_cert_dir_paths[1]);
}

test "ca bundle loader skips missing file and loads next path" {
    if (std.http.Client.disable_tls) return;

    const good_path = "/tmp/komari-zig-agent-ca-good-test.pem";
    const missing_path = "/tmp/komari-zig-agent-ca-missing-does-not-exist.pem";
    const pem_bytes = @embedFile("testdata_ca_root.pem");

    var file = try std.Io.Dir.createFileAbsolute(std.testing.io, good_path, .{});
    defer {
        file.close(std.testing.io);
        std.Io.Dir.deleteFileAbsolute(std.testing.io, good_path) catch {};
    }
    try file.writeStreamingAll(std.testing.io, pem_bytes);

    const file_paths = [_][]const u8{ missing_path, good_path };
    const dir_paths = [_][]const u8{};

    var bundle: std.crypto.Certificate.Bundle = .empty;
    defer bundle.deinit(std.testing.allocator);

    try raw_conn.loadCaBundleFromCandidatePaths(
        &bundle,
        std.testing.allocator,
        std.testing.io,
        std.Io.Timestamp.now(std.testing.io, .real),
        &file_paths,
        &dir_paths,
    );
    try std.testing.expect(bundle.map.count() >= 1);
}

test "ca bundle loader returns FileNotFound when all candidates missing" {
    if (std.http.Client.disable_tls) return;

    const file_paths = [_][]const u8{"/tmp/komari-zig-agent-ca-missing-a.pem"};
    const dir_paths = [_][]const u8{"/tmp/komari-zig-agent-ca-missing-dir"};

    var bundle: std.crypto.Certificate.Bundle = .empty;
    defer bundle.deinit(std.testing.allocator);

    const result = raw_conn.loadCaBundleFromCandidatePaths(
        &bundle,
        std.testing.allocator,
        std.testing.io,
        std.Io.Timestamp.now(std.testing.io, .real),
        &file_paths,
        &dir_paths,
    );
    try std.testing.expectError(error.FileNotFound, result);
}
