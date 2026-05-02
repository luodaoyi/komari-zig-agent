# komari-zig-agent

Zig implementation of `komari-agent`.

Status:

- Supported first: Linux, FreeBSD, macOS.
- Windows runtime is not included yet.
- Zig version: 0.15.2.
- Compatibility target: `komari-monitor/komari-agent` protocols, released from `luodaoyi/komari-zig-agent`.

Build:

```sh
zig build -Doptimize=ReleaseSmall -Dversion=dev
```

Cross build release assets:

```sh
./build_all.sh
```

Install:

```sh
sh install.sh --endpoint https://panel.example --token TOKEN
```

One-command replacement for an existing Go komari-agent on Linux/OpenWrt:

```sh
curl -fsSL https://raw.githubusercontent.com/luodaoyi/komari-zig-agent/main/replace.sh | sh
```

If `curl` is missing:

```sh
wget -O- https://raw.githubusercontent.com/luodaoyi/komari-zig-agent/main/replace.sh | sh
```

The release asset names stay compatible:

```text
komari-agent-linux-amd64
komari-agent-linux-arm64
komari-agent-linux-386
komari-agent-linux-arm
komari-agent-linux-mips
komari-agent-linux-mipsel
komari-agent-linux-riscv64
komari-agent-freebsd-amd64
komari-agent-freebsd-arm64
komari-agent-freebsd-386
komari-agent-freebsd-arm
komari-agent-darwin-amd64
komari-agent-darwin-arm64
```

Release:

- Pushing tag `v*` builds all assets and publishes a GitHub Release.
- Or open GitHub Actions -> `Release` -> `Run workflow`, input `v0.1.0` or `0.1.0`; the workflow creates the tag, builds all binaries, and publishes the Release.
- The agent self-update checks `https://api.github.com/repos/luodaoyi/komari-zig-agent/releases/latest`.
