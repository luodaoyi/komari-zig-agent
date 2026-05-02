$ErrorActionPreference = "Stop"
$version = (cmd /c "git describe --tags --abbrev=0 2>nul")
if ($LASTEXITCODE -ne 0 -or -not $version) { $version = "dev" }
New-Item -ItemType Directory -Force -Path build | Out-Null

function Build-One($os, $arch, $target) {
    Write-Host "Building $os/$arch"
    zig build -Doptimize=ReleaseSmall "-Dversion=$version" "-Dtarget=$target"
    Copy-Item zig-out/bin/komari-agent "build/komari-agent-$os-$arch" -Force
}

Build-One linux amd64 x86_64-linux-musl
Build-One linux arm64 aarch64-linux-musl
Build-One linux 386 x86-linux-musl
Build-One linux arm arm-linux-musleabi
Build-One linux mips mips-linux-musl
Build-One linux mipsel mipsel-linux-musl
Build-One linux riscv64 riscv64-linux-musl
Build-One freebsd amd64 x86_64-freebsd
Build-One freebsd arm64 aarch64-freebsd
Build-One freebsd 386 x86-freebsd
Build-One freebsd arm arm-freebsd
Build-One darwin amd64 x86_64-macos
Build-One darwin arm64 aarch64-macos
