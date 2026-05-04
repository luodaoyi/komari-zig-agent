#!/bin/sh
set -eu

version="$(git describe --tags --abbrev=0 2>/dev/null || printf dev)"
mkdir -p build

build_one() {
  os="$1"; arch="$2"; target="$3"
  ext="${4:-}"
  echo "Building $os/$arch"
  zig build -Doptimize=ReleaseSmall -Dversion="$version" -Dtarget="$target"
  cp "zig-out/bin/komari-agent$ext" "build/komari-agent-$os-$arch$ext"
}

build_one linux amd64 x86_64-linux-musl
build_one linux arm64 aarch64-linux-musl
build_one linux 386 x86-linux-musl
build_one linux arm arm-linux-musleabi
build_one linux mips mips-linux-musleabi
build_one linux mipsel mipsel-linux-musleabi
build_one linux mips64 mips64-linux-muslabi64
build_one linux mips64el mips64el-linux-muslabi64
build_one linux riscv64 riscv64-linux-musl
build_one linux s390x s390x-linux-musl
build_one linux loong64 loongarch64-linux-musl
build_one freebsd amd64 x86_64-freebsd
build_one freebsd arm64 aarch64-freebsd
build_one freebsd 386 x86-freebsd
build_one freebsd arm arm-freebsd
build_one darwin amd64 x86_64-macos
build_one darwin arm64 aarch64-macos
build_one windows amd64 x86_64-windows-gnu .exe
build_one windows arm64 aarch64-windows-gnu .exe
build_one windows 386 x86-windows-gnu .exe
