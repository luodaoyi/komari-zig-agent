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
