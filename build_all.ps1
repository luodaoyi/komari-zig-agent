$ErrorActionPreference = "Stop"
$version = (cmd /c "git describe --tags --abbrev=0 2>nul")
if ($LASTEXITCODE -ne 0 -or -not $version) { $version = "dev" }
New-Item -ItemType Directory -Force -Path build | Out-Null

function Build-One($os, $arch, $target, $ext = "") {
    Write-Host "Building $os/$arch"
    zig build -Doptimize=ReleaseSmall "-Dversion=$version" "-Dtarget=$target"
    Copy-Item "zig-out/bin/komari-agent$ext" "build/komari-agent-$os-$arch$ext" -Force
}

Build-One linux amd64 x86_64-linux-musl
Build-One linux arm64 aarch64-linux-musl
Build-One linux 386 x86-linux-musl
Build-One linux arm arm-linux-musleabi
Build-One linux mips mips-linux-musl
Build-One linux mipsel mipsel-linux-musl
Build-One linux mips64 mips64-linux-muslabi64
Build-One linux mips64el mips64el-linux-muslabi64
Build-One linux riscv64 riscv64-linux-musl
Build-One linux s390x s390x-linux-musl
Build-One linux loong64 loongarch64-linux-musl
Build-One freebsd amd64 x86_64-freebsd
Build-One freebsd arm64 aarch64-freebsd
Build-One freebsd 386 x86-freebsd
Build-One freebsd arm arm-freebsd
Build-One darwin amd64 x86_64-macos
Build-One darwin arm64 aarch64-macos
Build-One windows amd64 x86_64-windows-gnu .exe
Build-One windows arm64 aarch64-windows-gnu .exe
Build-One windows 386 x86-windows-gnu .exe
