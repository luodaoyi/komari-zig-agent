const std = @import("std");
const linux = @import("platform_linux");

test "physical disk filter keeps root and excludes pseudo filesystems" {
    try std.testing.expect(linux.isPhysicalMount("/", "overlay", "/dev/root"));
    try std.testing.expect(!linux.isPhysicalMount("/proc", "proc", "proc"));
    try std.testing.expect(!linux.isPhysicalMount("/sys/fs/cgroup", "cgroup2", "cgroup2"));
    try std.testing.expect(!linux.isPhysicalMount("/var/lib/docker/overlay2/x", "ext4", "/dev/sda1"));
    try std.testing.expect(!linux.isPhysicalMount("/mnt/share", "nfs", "server:/share"));
    try std.testing.expect(!linux.isPhysicalMount("/snap/core", "squashfs", "/dev/loop0"));
    try std.testing.expect(linux.isPhysicalMount("/data", "ext4", "/dev/sdb1"));
    try std.testing.expect(linux.isPhysicalMount("/mnt/windows", "fuseblk", "/dev/sdc1"));
}

test "zfs device key deduplicates datasets by pool" {
    try std.testing.expectEqualStrings("tank", linux.diskDeviceKey("tank/data", "zfs"));
    try std.testing.expectEqualStrings("/dev/sda1", linux.diskDeviceKey("/dev/sda1", "ext4"));
}

test "df output parser indexes mountpoint usage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const map = try linux.parseDfOutput(arena.allocator(),
        \\Filesystem     1B-blocks    Used Available Use% Mounted on
        \\/dev/sda1      1000         400  600       40% /
        \\/dev/sdb1      9000         1000 8000      12% /data
    );

    try std.testing.expectEqual(@as(u64, 1000), map.get("/").?.total);
    try std.testing.expectEqual(@as(u64, 400), map.get("/").?.used);
    try std.testing.expectEqual(@as(u64, 9000), map.get("/data").?.total);
    try std.testing.expectEqual(@as(u64, 1000), map.get("/data").?.used);
}
