const std = @import("std");
const linux = @import("platform_linux");

test "os release parser prefers PRETTY_NAME" {
    const text =
        \\ID=debian
        \\PRETTY_NAME="Debian GNU/Linux 12 (bookworm)"
        \\VERSION_CODENAME=bookworm
    ;

    const name = try linux.parseOsReleaseName(std.testing.allocator, text);
    defer std.testing.allocator.free(name);
    try std.testing.expectEqualStrings("Debian GNU/Linux 12 (bookworm)", name);
}

test "os release parser falls back to ID then Linux" {
    const id_name = try linux.parseOsReleaseName(std.testing.allocator, "ID=alpine\n");
    defer std.testing.allocator.free(id_name);
    try std.testing.expectEqualStrings("alpine", id_name);

    const fallback = try linux.parseOsReleaseName(std.testing.allocator, "NAME=");
    defer std.testing.allocator.free(fallback);
    try std.testing.expectEqualStrings("Linux", fallback);
}

test "arch names match Go runtime labels" {
    try std.testing.expectEqualStrings("amd64", linux.normalizeArch("x86_64"));
    try std.testing.expectEqualStrings("arm64", linux.normalizeArch("aarch64"));
    try std.testing.expectEqualStrings("386", linux.normalizeArch("x86"));
    try std.testing.expectEqualStrings("arm", linux.normalizeArch("arm"));
}

test "container virtualization parser recognizes common cgroup forms" {
    try std.testing.expectEqualStrings("docker", linux.detectContainerFromCgroup("0::/docker/0123456789abcdef\n"));
    try std.testing.expectEqualStrings("podman", linux.detectContainerFromCgroup("0::/libpod-0123456789abcdef.scope\n"));
    try std.testing.expectEqualStrings("kubernetes", linux.detectContainerFromCgroup("0::/kubepods.slice/pod123\n"));
    try std.testing.expectEqualStrings("", linux.detectContainerFromCgroup("0::/user.slice\n"));
}

test "meminfo parser honors memory modes" {
    const text =
        \\MemTotal:       1000 kB
        \\MemFree:         100 kB
        \\MemAvailable:    400 kB
        \\Buffers:          50 kB
        \\Cached:          150 kB
    ;
    const normal = linux.parseMemInfo(text, .{});
    try std.testing.expectEqual(@as(u64, 1000 * 1024), normal.total);
    try std.testing.expectEqual(@as(u64, 700 * 1024), normal.used);
    const include_cache = linux.parseMemInfo(text, .{ .include_cache = true });
    try std.testing.expectEqual(@as(u64, 900 * 1024), include_cache.used);
    const raw = linux.parseMemInfo(text, .{ .report_raw_used = true });
    try std.testing.expectEqual(@as(u64, 700 * 1024), raw.used);
}

test "proc meminfo parser keeps check-mem fields" {
    const text =
        \\MemTotal:       1000 kB
        \\MemFree:         100 kB
        \\MemAvailable:    400 kB
        \\Buffers:          50 kB
        \\Cached:          150 kB
        \\SwapTotal:       200 kB
        \\SwapFree:         80 kB
        \\SwapCached:       20 kB
        \\Shmem:            30 kB
        \\SReclaimable:     70 kB
        \\Zswap:             5 kB
        \\Zswapped:          6 kB
    ;
    const info = linux.parseProcMemInfo(text);
    try std.testing.expectEqual(@as(u64, 1000 * 1024), info.mem_total);
    try std.testing.expectEqual(@as(u64, 400 * 1024), info.mem_available);
    try std.testing.expectEqual(@as(u64, 70 * 1024), info.sreclaimable);
    try std.testing.expectEqual(@as(u64, 6 * 1024), info.zswapped);
}

test "swap parser matches meminfo semantics" {
    const text =
        \\SwapTotal:      1000 kB
        \\SwapFree:        200 kB
        \\SwapCached:      100 kB
    ;
    const swap = linux.parseSwapInfo(text);
    try std.testing.expectEqual(@as(u64, 1000 * 1024), swap.total);
    try std.testing.expectEqual(@as(u64, 700 * 1024), swap.used);
}

test "proc path uses host proc root when provided" {
    const path = try linux.procPath(std.testing.allocator, "/host/proc", "net/dev");
    defer std.testing.allocator.free(path);
    const normalized = try std.mem.replaceOwned(u8, std.testing.allocator, path, "\\", "/");
    defer std.testing.allocator.free(normalized);
    try std.testing.expect(std.mem.endsWith(u8, normalized, "host/proc/net/dev"));
}

test "per second rate handles deltas and resets" {
    try std.testing.expectEqual(@as(u64, 2000), linux.perSecond(3000, 1000, 1000));
    try std.testing.expectEqual(@as(u64, 1000), linux.perSecond(3000, 1000, 2000));
    try std.testing.expectEqual(@as(u64, 0), linux.perSecond(1000, 3000, 1000));
    try std.testing.expectEqual(@as(u64, 0), linux.perSecond(3000, 1000, 0));
}
