# Komari Zig Agent Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a Linux, FreeBSD, and macOS Zig replacement for the Go `komari-agent` with protocol, config, install, release, and runtime behavior compatibility.

**Architecture:** Implement the agent as small Zig modules with protocol compatibility tests first. Platform metrics live behind a common interface, while HTTP/WebSocket/report/task/terminal code owns the Komari wire contracts.

**Tech Stack:** Zig 0.15.2, Zig standard library, small vendored or dependency-backed WebSocket/TLS helpers if required, POSIX APIs, GitHub Actions, shell install scripts, Docker.

---

## File Map

- Create `build.zig`: build graph, test steps, release target matrix, version options.
- Create `build.zig.zon`: package metadata and dependency pins.
- Create `src/main.zig`: entrypoint, lifecycle, signal handling, startup sequence.
- Create `src/config.zig`: CLI/env/JSON config compatibility.
- Create `src/version.zig`: version and repo constants.
- Create `src/log.zig`: timestamped log helpers.
- Create `src/idna.zig`: IDN/Punycode conversion wrapper.
- Create `src/dns.zig`: DNS normalization and dial preference.
- Create `src/protocol/http.zig`: HTTP request helpers, headers, retries.
- Create `src/protocol/ws.zig`: WebSocket client facade and synchronized writes.
- Create `src/protocol/basic_info.zig`: basic info upload.
- Create `src/protocol/report_ws.zig`: report WebSocket loop and dispatch.
- Create `src/protocol/task.zig`: remote exec and result upload.
- Create `src/protocol/ping.zig`: ICMP/TCP/HTTP ping tasks.
- Create `src/protocol/autodiscovery.zig`: registration and token reuse.
- Create `src/report/report.zig`: report JSON generation.
- Create `src/report/netstatic.zig`: monthly traffic accounting.
- Create `src/terminal/terminal.zig`: Unix PTY terminal bridge.
- Create `src/platform/common.zig`: shared metric structs and interface.
- Create `src/platform/linux.zig`: Linux metrics.
- Create `src/platform/freebsd.zig`: FreeBSD metrics.
- Create `src/platform/darwin.zig`: macOS metrics.
- Create `src/update.zig`: release lookup and self replacement.
- Create `test/golden/*.json`: protocol golden payloads.
- Create `test/*.zig`: unit and compatibility tests.
- Create `.github/workflows/build.yml`: CI build and test.
- Create `.github/workflows/release.yml`: release binary upload.
- Create `.github/workflows/release-from-commits.yml`: release notes.
- Create `.github/workflows/release-docker.yml`: Docker publish.
- Create `install.sh`: Unix installer.
- Create `build_all.sh`: local cross-build helper.
- Create `build_all.ps1`: Windows host cross-build helper, no Windows target.
- Create `Dockerfile`: Linux container image.
- Create `README.md`: compatibility status and usage.
- Create `.gitignore`: Zig cache, build output, runtime state files.

## Task 1: Bootstrap Zig Project

**Files:**
- Create: `build.zig`
- Create: `build.zig.zon`
- Create: `src/main.zig`
- Create: `src/version.zig`
- Create: `src/log.zig`
- Create: `.gitignore`
- Test: `test/bootstrap_test.zig`

- [ ] **Step 1: Write bootstrap test**

Create `test/bootstrap_test.zig`:

```zig
const std = @import("std");
const version = @import("../src/version.zig");

test "default version and repository are compatible" {
    try std.testing.expectEqualStrings("0.0.1", version.current);
    try std.testing.expectEqualStrings("komari-monitor/komari-agent", version.repo);
}
```

- [ ] **Step 2: Add minimal source files**

Create `src/version.zig`:

```zig
pub const current = @import("build_options").version;
pub const repo = "komari-monitor/komari-agent";
```

Create `src/log.zig`:

```zig
const std = @import("std");

pub fn info(comptime fmt: []const u8, args: anytype) void {
    std.log.info(fmt, args);
}

pub fn warn(comptime fmt: []const u8, args: anytype) void {
    std.log.warn(fmt, args);
}

pub fn err(comptime fmt: []const u8, args: anytype) void {
    std.log.err(fmt, args);
}
```

Create `src/main.zig`:

```zig
const std = @import("std");
const version = @import("version.zig");

pub fn main() !void {
    var stdout = std.io.getStdOut().writer();
    try stdout.print("Komari Agent {s}\n", .{version.current});
}
```

- [ ] **Step 3: Add build graph**

Create `build.zig`:

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const version = b.option([]const u8, "version", "agent version") orelse "0.0.1";

    const opts = b.addOptions();
    opts.addOption([]const u8, "version", version);

    const exe = b.addExecutable(.{
        .name = "komari-agent",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addOptions("build_options", opts);
    b.installArtifact(exe);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/bootstrap_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    tests.root_module.addOptions("build_options", opts);
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
```

Create `build.zig.zon`:

```zig
.{
    .name = .komari_zig_agent,
    .version = "0.0.1",
    .minimum_zig_version = "0.15.2",
    .dependencies = .{},
    .paths = .{
        "build.zig",
        "build.zig.zon",
        "src",
        "test",
    },
}
```

Create `.gitignore`:

```gitignore
.zig-cache/
zig-out/
build/
auto-discovery.json
net_static.json
net_static.json.bak
```

- [ ] **Step 4: Verify bootstrap**

Run:

```bash
zig build test
zig build -Dversion=dev
```

Expected: both commands succeed.

- [ ] **Step 5: Commit**

```bash
git add build.zig build.zig.zon src/main.zig src/version.zig src/log.zig test/bootstrap_test.zig .gitignore
git commit -m "chore: bootstrap zig agent project"
```

## Task 2: Config Compatibility

**Files:**
- Create: `src/config.zig`
- Modify: `src/main.zig`
- Test: `test/config_test.zig`
- Modify: `build.zig`

- [ ] **Step 1: Write config tests**

Create `test/config_test.zig` with cases for defaults, CLI aliases, env override, JSON keys, deprecated flags, and unknown flags:

```zig
const std = @import("std");
const config = @import("../src/config.zig");

test "defaults match Go agent" {
    const cfg = config.Config.default();
    try std.testing.expectEqual(@as(f64, 1.0), cfg.interval);
    try std.testing.expectEqual(@as(i32, 3), cfg.max_retries);
    try std.testing.expectEqual(@as(i32, 5), cfg.reconnect_interval);
    try std.testing.expectEqual(@as(i32, 5), cfg.info_report_interval);
}

test "cli aliases parse" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const args = [_][]const u8{
        "komari-agent", "-t", "tok", "-e", "https://panel.example", "-i", "2.5",
        "-u", "-r", "7", "-c", "11",
    };
    const cfg = try config.parseArgs(arena.allocator(), &args);
    try std.testing.expectEqualStrings("tok", cfg.token);
    try std.testing.expectEqualStrings("https://panel.example", cfg.endpoint);
    try std.testing.expectEqual(@as(f64, 2.5), cfg.interval);
    try std.testing.expect(cfg.ignore_unsafe_cert);
    try std.testing.expectEqual(@as(i32, 7), cfg.max_retries);
    try std.testing.expectEqual(@as(i32, 11), cfg.reconnect_interval);
}

test "unknown flags are ignored" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const args = [_][]const u8{ "komari-agent", "--future-flag", "x", "--token", "tok" };
    const cfg = try config.parseArgs(arena.allocator(), &args);
    try std.testing.expectEqualStrings("tok", cfg.token);
}
```

- [ ] **Step 2: Implement config**

Create `src/config.zig` with `Config.default()`, `parseArgs()`, `loadEnv()`, and `loadJsonFile()` fields matching the approved spec. Use owned strings allocated from the caller allocator. Ignore `-autoUpdate`, `--autoUpdate`, `-memory-mode-available`, and `--memory-mode-available` after logging a warning.

- [ ] **Step 3: Wire tests into build**

Modify `build.zig` so the `test` step runs `test/bootstrap_test.zig` and `test/config_test.zig`.

- [ ] **Step 4: Verify**

Run:

```bash
zig build test
```

Expected: config tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/config.zig src/main.zig build.zig test/config_test.zig
git commit -m "feat: add compatible config parsing"
```

## Task 3: Protocol JSON Types and Golden Tests

**Files:**
- Create: `src/protocol/types.zig`
- Create: `test/golden/basic_info.json`
- Create: `test/golden/report.json`
- Create: `test/golden/task_result.json`
- Create: `test/golden/ping_result.json`
- Create: `test/golden/autodiscovery_request.json`
- Test: `test/protocol_json_test.zig`
- Modify: `build.zig`

- [ ] **Step 1: Add golden files**

Create compact JSON files preserving Go field names:

`test/golden/basic_info.json`:

```json
{"cpu_name":"CPU","cpu_cores":4,"arch":"amd64","os":"linux","kernel_version":"6.1.0","ipv4":"192.0.2.1","ipv6":"2001:db8::1","mem_total":1024,"swap_total":2048,"disk_total":4096,"gpu_name":"GPU","virtualization":"kvm","version":"0.0.1"}
```

`test/golden/task_result.json`:

```json
{"task_id":"t1","result":"ok","exit_code":0,"finished_at":"2026-05-02T00:00:00Z"}
```

`test/golden/ping_result.json`:

```json
{"type":"ping_result","task_id":9,"ping_type":"tcp","value":12,"finished_at":"2026-05-02T00:00:00Z"}
```

`test/golden/autodiscovery_request.json`:

```json
{"key":"secret"}
```

`test/golden/report.json`:

```json
{"cpu":{"usage":0.001},"ram":{"total":1024,"used":512},"swap":{"total":2048,"used":256},"load":{"load1":0.1,"load5":0.2,"load15":0.3},"disk":{"total":4096,"used":1024},"network":{"up":10,"down":20,"totalUp":100,"totalDown":200},"connections":{"tcp":3,"udp":4},"uptime":99,"process":8,"message":""}
```

- [ ] **Step 2: Write tests**

Create `test/protocol_json_test.zig` to serialize typed payloads and compare parsed JSON semantics against each golden file using `std.json.parseFromSlice`.

- [ ] **Step 3: Implement protocol types**

Create `src/protocol/types.zig` with structs for `BasicInfoPayload`, `TaskResultPayload`, `PingResultPayload`, `AutoDiscoveryRequest`, and `ReportPayload`. Provide deterministic `writeJson()` functions.

- [ ] **Step 4: Verify**

Run:

```bash
zig build test
```

Expected: golden JSON tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/protocol/types.zig test/golden test/protocol_json_test.zig build.zig
git commit -m "test: lock komari protocol json payloads"
```

## Task 4: HTTP, Headers, DNS, TLS, and IDN Foundation

**Files:**
- Create: `src/protocol/http.zig`
- Create: `src/dns.zig`
- Create: `src/idna.zig`
- Test: `test/http_test.zig`
- Test: `test/dns_idna_test.zig`
- Modify: `build.zig`

- [ ] **Step 1: Write tests**

Test:

- endpoint trimming
- query token placement
- Cloudflare Access headers
- custom DNS normalization: `8.8.8.8`, `8.8.8.8:53`, `2606:4700:4700::1111`, `[2606:4700:4700::1111]:53`
- `http` to `ws` and `https` to `wss`
- IDN conversion for a known Unicode hostname

- [ ] **Step 2: Implement URL and header helpers**

Implement pure helpers first:

- `trimEndpoint(endpoint: []const u8) []const u8`
- `basicInfoUrl(endpoint, token)`
- `taskResultUrl(endpoint, token)`
- `registerUrl(endpoint, hostname)`
- `reportWsUrl(endpoint, token)`
- `terminalWsUrl(endpoint, token, id)`
- `addCloudflareHeaders(headers, cfg)`

- [ ] **Step 3: Implement DNS and IDN**

Implement `normalizeDnsServer()` and `convertIdnUrlToAscii()`. If Zig stdlib lacks a complete IDNA implementation, vendor a small Punycode implementation and limit it to host labels.

- [ ] **Step 4: Add HTTP client shell**

Add `Client` with request timeout, proxy-from-env hook when supported, TLS insecure option, and retry helper. Keep network tests mockable by separating request building from transport.

- [ ] **Step 5: Verify and commit**

Run:

```bash
zig build test
```

Then:

```bash
git add src/protocol/http.zig src/dns.zig src/idna.zig test/http_test.zig test/dns_idna_test.zig build.zig
git commit -m "feat: add http dns and idn compatibility helpers"
```

## Task 5: Basic Info and Auto Discovery

**Files:**
- Create: `src/protocol/basic_info.zig`
- Create: `src/protocol/autodiscovery.zig`
- Modify: `src/main.zig`
- Test: `test/basic_info_test.zig`
- Test: `test/autodiscovery_test.zig`

- [ ] **Step 1: Write mock transport tests**

Test:

- full basic info upload uses `kernel_version`
- fallback removes `kernel_version` after non-200 response
- auto-discovery loads existing `auto-discovery.json`
- auto-discovery registers and saves `uuid` and `token`
- register request includes bearer token and CF headers

- [ ] **Step 2: Implement basic info upload**

Use `protocol/types.zig` and `protocol/http.zig`. On non-200 or request error from the full payload, retry once without `kernel_version`.

- [ ] **Step 3: Implement auto-discovery**

Read/write `auto-discovery.json` next to `std.fs.selfExePathAlloc()` directory. Marshal with two-space indentation to match Go readability.

- [ ] **Step 4: Wire startup ordering**

In `src/main.zig`, load config, then run auto-discovery before requiring `token` for other protocols.

- [ ] **Step 5: Verify and commit**

Run:

```bash
zig build test
```

Then:

```bash
git add src/protocol/basic_info.zig src/protocol/autodiscovery.zig src/main.zig test/basic_info_test.zig test/autodiscovery_test.zig
git commit -m "feat: add basic info upload and auto discovery"
```

## Task 6: Report Payload and Platform Interface

**Files:**
- Create: `src/platform/common.zig`
- Create: `src/report/report.zig`
- Test: `test/report_test.zig`
- Modify: `build.zig`

- [ ] **Step 1: Write fake platform test**

Create a fake metrics provider that returns fixed CPU, RAM, swap, load, disk, network, connections, uptime, and process values. Assert the generated report equals `test/golden/report.json`.

- [ ] **Step 2: Define common metrics**

Create structs:

- `CpuInfo`
- `MemInfo`
- `LoadInfo`
- `DiskInfo`
- `NetworkInfo`
- `ConnectionInfo`
- `GpuInfo`
- `BasicInfo`
- `MetricsProvider`

- [ ] **Step 3: Implement report generation**

Generate Go-compatible report JSON. Clamp CPU usage to `0.001` when usage is `<= 0.001`. Include `gpu` only when detailed GPU monitoring is enabled and data exists.

- [ ] **Step 4: Verify and commit**

Run:

```bash
zig build test
```

Then:

```bash
git add src/platform/common.zig src/report/report.zig test/report_test.zig build.zig
git commit -m "feat: add report payload generation"
```

## Task 7: Linux Metrics

**Files:**
- Create: `src/platform/linux.zig`
- Test: `test/linux_metrics_test.zig`
- Add fixtures under: `test/fixtures/linux/`

- [ ] **Step 1: Add parser fixtures**

Create fixtures for:

- `/proc/meminfo`
- `/proc/stat`
- `/proc/cpuinfo`
- `/proc/net/dev`
- `/proc/net/tcp`
- `/proc/net/udp`
- `/proc/uptime`
- `/proc/loadavg`
- `/proc/1/status`

- [ ] **Step 2: Write parser tests**

Test memory htop-like calculation, swap calculation, CPU name fallback, network virtual interface exclusion, TCP/UDP counts, uptime, load, process count, and reset behavior for network deltas.

- [ ] **Step 3: Implement Linux parsers**

Implement parser functions that accept byte slices. Keep runtime filesystem reads as thin wrappers around these parser functions.

- [ ] **Step 4: Implement Linux provider**

Implement the `MetricsProvider` interface using `/proc`, `/sys`, `statvfs`, and direct filesystem traversal. Use external commands only for optional GPU discovery.

- [ ] **Step 5: Verify and commit**

Run:

```bash
zig build test
zig build -Dtarget=x86_64-linux-musl
```

Then:

```bash
git add src/platform/linux.zig test/linux_metrics_test.zig test/fixtures/linux
git commit -m "feat: add linux metrics provider"
```

## Task 8: FreeBSD and macOS Metrics

**Files:**
- Create: `src/platform/freebsd.zig`
- Create: `src/platform/darwin.zig`
- Test: `test/bsd_darwin_metrics_test.zig`
- Add fixtures under: `test/fixtures/bsd/`

- [ ] **Step 1: Write sysctl adapter tests**

Write tests for parsing mocked `sysctl` values and adapter outputs for OS name, kernel version, memory, swap, load, uptime, process count, disk, and interface data.

- [ ] **Step 2: Implement FreeBSD provider**

Use `sysctl`, `getifaddrs`, `statfs/statvfs`, and socket table APIs. Match protocol output fields even where internal measurement differs from Linux.

- [ ] **Step 3: Implement macOS provider**

Use `sysctl`, `host_statistics64` where available, `getifaddrs`, `statfs/statvfs`, and process table APIs. Use `system_profiler` or `ioreg` only for GPU name fallback when no cheap API is available.

- [ ] **Step 4: Cross-build**

Run:

```bash
zig build -Dtarget=x86_64-freebsd
zig build -Dtarget=aarch64-freebsd
zig build -Dtarget=x86_64-macos
zig build -Dtarget=aarch64-macos
```

Expected: all compile. Platform runtime tests can be gated to native OS.

- [ ] **Step 5: Commit**

```bash
git add src/platform/freebsd.zig src/platform/darwin.zig test/bsd_darwin_metrics_test.zig test/fixtures/bsd
git commit -m "feat: add freebsd and macos metrics providers"
```

## Task 9: Monthly Traffic Store

**Files:**
- Create: `src/report/netstatic.zig`
- Test: `test/netstatic_test.zig`
- Golden: `test/golden/net_static.json`

- [ ] **Step 1: Write tests**

Test:

- default config values
- corrupt file backup
- cache flush merges deltas
- `GetLastResetDate` equivalent for normal day and month overflow
- `GetTotalTrafficBetween`
- config update with NIC whitelist

- [ ] **Step 2: Implement store**

Implement the Go-compatible schema:

```json
{"interfaces":{"eth0":[{"timestamp":1,"tx":2,"rx":3}]},"config":{"data_preserve_day":31,"detect_interval":2,"save_interval":600,"nics":["eth0"]}}
```

- [ ] **Step 3: Wire network totals**

When `month_rotate != 0`, report `totalUp` and `totalDown` from `net_static.json` between last reset date and now, while live speed still comes from current counters.

- [ ] **Step 4: Verify and commit**

Run:

```bash
zig build test
```

Then:

```bash
git add src/report/netstatic.zig test/netstatic_test.zig test/golden/net_static.json
git commit -m "feat: add monthly network accounting"
```

## Task 10: WebSocket Report Loop and Command Dispatch

**Files:**
- Create: `src/protocol/ws.zig`
- Create: `src/protocol/report_ws.zig`
- Modify: `src/main.zig`
- Test: `test/ws_dispatch_test.zig`

- [ ] **Step 1: Write mock WebSocket tests**

Test:

- report URL is correct
- ping frames are sent every 30 seconds through injectable clock
- terminal messages dispatch to terminal handler
- exec messages dispatch to task handler
- ping messages dispatch to ping handler
- write failure closes connection and reconnects until max retries

- [ ] **Step 2: Choose WebSocket implementation**

Prefer a small audited Zig dependency if it supports client handshake, TLS, ping frames, binary/text messages, and custom headers. If no dependency is fit, implement RFC 6455 client framing and use `std.http.Client` or TLS stream for the handshake.

- [ ] **Step 3: Implement synchronized writer**

Implement a `SafeConn` equivalent with a mutex around writes. Reads may proceed without the write lock.

- [ ] **Step 4: Implement report loop**

Match Go timing:

- if `interval <= 1`, send every 1 second
- else send every `interval - 1` seconds
- heartbeat every 30 seconds
- retry up to `max_retries`
- sleep `reconnect_interval` seconds between tries

- [ ] **Step 5: Verify and commit**

Run:

```bash
zig build test
```

Then:

```bash
git add src/protocol/ws.zig src/protocol/report_ws.zig src/main.zig test/ws_dispatch_test.zig
git commit -m "feat: add report websocket loop"
```

## Task 11: Remote Exec and Ping Tasks

**Files:**
- Create: `src/protocol/task.zig`
- Create: `src/protocol/ping.zig`
- Test: `test/task_ping_test.zig`

- [ ] **Step 1: Write tests**

Test:

- empty task id does nothing
- empty command uploads `"No command provided"` with exit code `0`
- disabled remote control uploads `"Remote control is disabled."` with exit code `-1`
- shell command combines stdout and stderr with `\r\n` normalized to `\n`
- TCP ping defaults to port 80
- HTTP ping adds `http://` when no scheme exists
- IPv6 HTTP host wrapping
- unsupported ping type returns `-1`

- [ ] **Step 2: Implement remote exec**

Use `/bin/sh -c` on Unix-like platforms. Capture stdout and stderr separately, then concatenate Go-compatible result text.

- [ ] **Step 3: Implement ping**

Implement TCP and HTTP ping with DNS time excluded where practical. Implement ICMP with raw sockets and document privilege behavior. Retry high latency values above 1000 ms up to three times.

- [ ] **Step 4: Verify and commit**

Run:

```bash
zig build test
```

Then:

```bash
git add src/protocol/task.zig src/protocol/ping.zig test/task_ping_test.zig
git commit -m "feat: add remote exec and ping tasks"
```

## Task 12: Unix Terminal Bridge

**Files:**
- Create: `src/terminal/terminal.zig`
- Test: `test/terminal_test.zig`

- [ ] **Step 1: Write parser tests**

Test terminal input JSON parsing:

- resize with cols and rows
- input with non-empty text
- invalid text falls back to raw write
- binary message writes raw bytes

- [ ] **Step 2: Implement PTY startup**

Use POSIX PTY APIs. Shell selection:

1. User shell from account data where available.
2. `zsh`
3. `bash`
4. `sh`

Set `TERM=xterm-256color`, `LANG=C.UTF-8`, and `LC_ALL=C.UTF-8`.

- [ ] **Step 3: Implement bridge**

Read WebSocket input and write PTY. Read PTY and write binary WebSocket messages. Implement resize. On shutdown, send Ctrl-C three times, Ctrl-D, then `exit\n`, matching Go behavior.

- [ ] **Step 4: Verify and commit**

Run:

```bash
zig build test
zig build -Dtarget=x86_64-linux-musl
```

Then:

```bash
git add src/terminal/terminal.zig test/terminal_test.zig
git commit -m "feat: add unix terminal websocket bridge"
```

## Task 13: Self Update

**Files:**
- Create: `src/update.zig`
- Modify: `src/main.zig`
- Test: `test/update_test.zig`

- [ ] **Step 1: Write semver tests**

Port Go tests:

- `1.0.0`
- `v1.0.0`
- `V1.0.0`
- pre-release and build metadata accepted when compatible
- latest greater than current means update needed
- equal or older means no update

- [ ] **Step 2: Implement GitHub release lookup**

Query GitHub release metadata through the shared HTTP client. Select the asset matching `komari-agent-{os}-{arch}`.

- [ ] **Step 3: Implement replacement**

Download to a temp file in the executable directory, chmod executable, atomically rename over current executable on Unix-like systems. On success, exit `42`.

- [ ] **Step 4: Wire periodic update**

At startup, run unless disabled. Spawn a periodic 6-hour check loop.

- [ ] **Step 5: Verify and commit**

Run:

```bash
zig build test
```

Then:

```bash
git add src/update.zig src/main.zig test/update_test.zig
git commit -m "feat: add self update workflow"
```

## Task 14: Main Lifecycle Integration

**Files:**
- Modify: `src/main.zig`
- Test: `test/lifecycle_test.zig`

- [ ] **Step 1: Write lifecycle test with fakes**

Use fake implementations for HTTP, WS, metrics, update, and netstatic. Verify ordering:

1. parse config
2. load env and JSON
3. auto discovery
4. netstatic start when `month_rotate != 0`
5. update check unless disabled
6. upload basic info
7. enter report WebSocket loop

- [ ] **Step 2: Implement signal handling**

Handle `SIGINT` and `SIGTERM`, stop netstatic, close sockets, and exit cleanly.

- [ ] **Step 3: Implement startup logs**

Log `Komari Agent {version}` and `Github Repo: komari-monitor/komari-agent`.

- [ ] **Step 4: Verify and commit**

Run:

```bash
zig build test
```

Then:

```bash
git add src/main.zig test/lifecycle_test.zig
git commit -m "feat: integrate agent lifecycle"
```

## Task 15: Install Scripts, Local Build Scripts, Docker

**Files:**
- Create: `install.sh`
- Create: `build_all.sh`
- Create: `build_all.ps1`
- Create: `Dockerfile`
- Create: `README.md`
- Test: shell syntax checks listed in Step 5

- [ ] **Step 1: Port Unix install script**

Use the Go `install.sh` behavior, but supported download targets are Linux, FreeBSD, and macOS only. Preserve install arguments, service templates, default paths, service name, GitHub proxy, version selection, and asset names.

- [ ] **Step 2: Add local build scripts**

`build_all.sh` and `build_all.ps1` must build:

- linux: `amd64`, `arm64`, `386`, `arm`
- freebsd: `amd64`, `arm64`, `386`, `arm`
- darwin: `amd64`, `arm64`

Use:

```bash
zig build -Doptimize=ReleaseSmall -Dversion="$version" -Dtarget="$target"
```

Copy outputs to `build/komari-agent-{os}-{arch}`.

- [ ] **Step 3: Add Dockerfile**

Use Alpine, copy `komari-agent-${TARGETOS}-${TARGETARCH}` to `/app/komari-agent`, set executable bit, touch `/.komari-agent-container`, and use the same entrypoint/CMD behavior as Go.

- [ ] **Step 4: Add README**

Document:

- Zig version
- supported platforms
- Windows status
- install command
- build command
- compatibility target

- [ ] **Step 5: Verify and commit**

Run:

```bash
sh -n install.sh
sh -n build_all.sh
powershell -NoProfile -Command "$null = [scriptblock]::Create((Get-Content -Raw build_all.ps1)); 'ok'"
```

Then:

```bash
git add install.sh build_all.sh build_all.ps1 Dockerfile README.md
git commit -m "chore: add install build and docker scripts"
```

## Task 16: GitHub Actions CI/CD

**Files:**
- Create: `.github/workflows/build.yml`
- Create: `.github/workflows/release.yml`
- Create: `.github/workflows/release-from-commits.yml`
- Create: `.github/workflows/release-docker.yml`

- [ ] **Step 1: Add build workflow**

Workflow behavior:

- checkout
- setup Zig 0.15.2
- run `zig build test`
- cross-build supported matrix
- upload artifacts named `komari-agent-{os}-{arch}`

- [ ] **Step 2: Add release workflow**

On published release, build matrix with `-Dversion=${{ github.event.release.tag_name }}` and upload each binary to the release.

- [ ] **Step 3: Add release notes workflow**

Port the Go repository workflow, preserving previous tag calculation and commit-subject notes.

- [ ] **Step 4: Add Docker publish workflow**

Build Linux `amd64` and `arm64` binaries, then build and push multi-arch images to GHCR with release tag and `latest`.

- [ ] **Step 5: Verify and commit**

Run:

```bash
git diff --check
```

Then:

```bash
git add .github/workflows
git commit -m "ci: add zig build release and docker workflows"
```

## Task 17: Compatibility Smoke Harness

**Files:**
- Create: `test/mock_panel.zig`
- Create: `test/smoke_test.zig`
- Modify: `build.zig`

- [ ] **Step 1: Implement mock panel**

Mock endpoints:

- `POST /api/clients/uploadBasicInfo`
- `GET /api/clients/report`
- `GET /api/clients/terminal`
- `POST /api/clients/task/result`
- `POST /api/clients/register`

Record requests and emit WS command messages.

- [ ] **Step 2: Add smoke test**

Start the agent against the mock panel with temporary state directory. Verify:

- basic info received
- report received
- exec task result received
- ping result received
- terminal request attempted
- CF headers appear when configured

- [ ] **Step 3: Wire to build**

Add a `smoke` build step separate from fast unit tests:

```bash
zig build smoke
```

- [ ] **Step 4: Verify and commit**

Run:

```bash
zig build test
zig build smoke
```

Then:

```bash
git add test/mock_panel.zig test/smoke_test.zig build.zig
git commit -m "test: add komari protocol smoke harness"
```

## Task 18: Size and Runtime Optimization Pass

**Files:**
- Modify: source modules as measured
- Create: `docs/performance.md`

- [ ] **Step 1: Build release binaries**

Run:

```bash
zig build -Doptimize=ReleaseSmall -Dtarget=x86_64-linux-musl -Dversion=dev
```

- [ ] **Step 2: Measure baseline**

Run the agent against mock panel for 5 minutes. Record:

- RSS
- CPU percentage
- report interval drift
- network bytes generated by reports
- binary size

- [ ] **Step 3: Optimize hot paths**

Focus on:

- report JSON allocation reuse
- network counter sampling without extra sleeps beyond compatibility needs
- avoiding repeated full directory scans where cached state is valid
- external command calls only on basic info upload or GPU-enabled mode

- [ ] **Step 4: Document results**

Create `docs/performance.md` with commands and observed numbers.

- [ ] **Step 5: Verify and commit**

Run:

```bash
zig build test
zig build smoke
```

Then:

```bash
git add docs/performance.md src test
git commit -m "perf: reduce agent runtime overhead"
```

## Task 19: Release Readiness

**Files:**
- Modify: `README.md`
- Modify: `docs/performance.md`

- [ ] **Step 1: Full verification**

Run:

```bash
zig fmt build.zig src test
zig build test
zig build smoke
./build_all.sh
sh -n install.sh
git diff --check
```

Expected: all pass.

- [ ] **Step 2: Manual panel smoke**

Run a Linux binary against a real Komari panel or local panel-compatible deployment:

```bash
./build/komari-agent-linux-amd64 --endpoint "$KOMARI_ENDPOINT" --token "$KOMARI_TOKEN" --disable-auto-update --interval 1
```

Verify the panel shows live metrics and that exec, ping, and terminal work when enabled.

- [ ] **Step 3: Update support matrix**

Mark Linux as smoke-tested. Mark FreeBSD/macOS as compile-tested until native smoke tests are run.

- [ ] **Step 4: Commit final docs**

```bash
git add README.md docs/performance.md
git commit -m "docs: add release readiness notes"
```

## Self-Review Checklist

- Spec coverage: config, HTTP, WebSocket, task, ping, terminal, monitoring, netstatic, DNS/TLS, auto-discovery, self-update, install scripts, CI/CD, Docker, and performance are covered.
- Placeholder scan: no task uses unspecified “fill later” work; each task has files, tests, commands, and expected outcomes.
- Type consistency: protocol payload names are introduced in Task 3 and reused afterward.
- Scope: Windows remains out of scope for first implementation, matching the approved spec.
