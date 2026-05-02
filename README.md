# komari-zig-agent

Zig implementation of `komari-agent`.

Status:

- Supported first: Linux, FreeBSD, macOS.
- Windows runtime is not included yet.
- Zig version: 0.15.2.
- Compatibility target: `komari-monitor/komari-agent`.

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

The release asset names stay compatible:

```text
komari-agent-linux-amd64
komari-agent-linux-arm64
komari-agent-freebsd-amd64
komari-agent-darwin-arm64
```
