#!/bin/sh
set -eu

version="$(git describe --tags --abbrev=0 2>/dev/null || printf dev)"
mkdir -p build

build_one() {
  os="$1"; arch="$2"; target="$3"
  echo "Building $os/$arch"
  zig build -Doptimize=ReleaseSmall -Dversion="$version" -Dtarget="$target"
  cp zig-out/bin/komari-agent "build/komari-agent-$os-$arch"
}

build_one linux amd64 x86_64-linux-musl
build_one linux arm64 aarch64-linux-musl
build_one linux 386 x86-linux-musl
build_one linux arm arm-linux-musleabihf
build_one freebsd amd64 x86_64-freebsd
build_one freebsd arm64 aarch64-freebsd
build_one freebsd 386 x86-freebsd
build_one freebsd arm arm-freebsd
build_one darwin amd64 x86_64-macos
build_one darwin arm64 aarch64-macos
