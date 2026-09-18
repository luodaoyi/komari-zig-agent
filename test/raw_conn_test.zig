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

fn absPathInTmp(tmp: *std.testing.TmpDir, name: []const u8, buf: []u8) ![]const u8 {
    const n = try tmp.dir.realPathFile(std.testing.io, name, buf);
    return buf[0..n];
}

fn absDirPath(tmp: *std.testing.TmpDir, buf: []u8) ![]const u8 {
    const n = try tmp.dir.realPath(std.testing.io, buf);
    return buf[0..n];
}

fn writePem(tmp: *std.testing.TmpDir, name: []const u8, pem_bytes: []const u8) !void {
    var file = try tmp.dir.createFile(std.testing.io, name, .{});
    defer file.close(std.testing.io);
    try file.writeStreamingAll(std.testing.io, pem_bytes);
}

test "ca bundle loader skips missing file and loads next path" {
    if (std.http.Client.disable_tls) return;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const pem_bytes = @embedFile("testdata_ca_root.pem");
    try writePem(&tmp, "good.pem", pem_bytes);

    var good_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const good_path = try absPathInTmp(&tmp, "good.pem", &good_buf);

    var dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_dir_path = try absDirPath(&tmp, &dir_buf);
    const missing_path = try std.fs.path.join(std.testing.allocator, &.{ tmp_dir_path, "missing-does-not-exist.pem" });
    defer std.testing.allocator.free(missing_path);

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

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_dir_path = try absDirPath(&tmp, &dir_buf);
    const missing_file = try std.fs.path.join(std.testing.allocator, &.{ tmp_dir_path, "missing-a.pem" });
    defer std.testing.allocator.free(missing_file);
    const missing_dir = try std.fs.path.join(std.testing.allocator, &.{ tmp_dir_path, "missing-dir" });
    defer std.testing.allocator.free(missing_dir);

    const file_paths = [_][]const u8{missing_file};
    const dir_paths = [_][]const u8{missing_dir};

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

test "ca bundle loader loads file and still scans dir with distinct CAs" {
    if (std.http.Client.disable_tls) return;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file_pem = @embedFile("testdata_ca_root.pem");
    const dir_pem = @embedFile("testdata_ca_dir.pem");
    try writePem(&tmp, "file-ca.pem", file_pem);
    try tmp.dir.createDirPath(std.testing.io, "certs");
    {
        var certs_dir = try tmp.dir.openDir(std.testing.io, "certs", .{});
        defer certs_dir.close(std.testing.io);
        var file = try certs_dir.createFile(std.testing.io, "dir-ca.pem", .{});
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, dir_pem);
    }

    var file_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const file_path = try absPathInTmp(&tmp, "file-ca.pem", &file_buf);

    var dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const parent_path = try absDirPath(&tmp, &dir_buf);
    const certs_dir_path = try std.fs.path.join(std.testing.allocator, &.{ parent_path, "certs" });
    defer std.testing.allocator.free(certs_dir_path);

    // File-only baseline: one CA from the file path.
    var file_only: std.crypto.Certificate.Bundle = .empty;
    defer file_only.deinit(std.testing.allocator);
    const file_paths_only = [_][]const u8{file_path};
    const empty_dirs = [_][]const u8{};
    try raw_conn.loadCaBundleFromCandidatePaths(
        &file_only,
        std.testing.allocator,
        std.testing.io,
        std.Io.Timestamp.now(std.testing.io, .real),
        &file_paths_only,
        &empty_dirs,
    );
    const file_only_count = file_only.map.count();
    try std.testing.expect(file_only_count >= 1);

    // File + dir: Go-aligned loader must still scan the directory after the file succeeds.
    var both: std.crypto.Certificate.Bundle = .empty;
    defer both.deinit(std.testing.allocator);
    const file_paths = [_][]const u8{file_path};
    const dir_paths = [_][]const u8{certs_dir_path};
    try raw_conn.loadCaBundleFromCandidatePaths(
        &both,
        std.testing.allocator,
        std.testing.io,
        std.Io.Timestamp.now(std.testing.io, .real),
        &file_paths,
        &dir_paths,
    );
    try std.testing.expect(both.map.count() > file_only_count);
}