# Komari Zig Agent Gap Closure Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the remaining protocol and feature parity gaps against the Go `komari-agent` for Linux, FreeBSD, and macOS.

**Architecture:** Keep the current small Zig stdlib-first design. Add focused helpers for TLS policy, WebSocket headers/reconnect, DNS resolution, memory mode selection, and platform-specific collectors without broad rewrites.

**Tech Stack:** Zig 0.16.0, `std.http.Client`, POSIX sockets, `/proc`, sysctl/Unix command adapters, GitHub Actions, shell install scripts.

---

## Audit Baseline

Known pushed baseline:
- Commit: `538bf13 feat: close unix agent parity gaps`
- Remote deploy: `ccs2` active, reports sent
- Verified: `zig build test`, `x86_64-linux`, `x86_64-freebsd`, `x86_64-macos`

Remaining gaps to close:
- `ignore_unsafe_cert`
- Cloudflare headers on WebSocket upgrade
- reconnect loop
- periodic BasicInfo upload
- `custom_dns`
- memory mode flags
- NIC wildcard filters
- `HOST_PROC`
- IPv6 ICMP
- FreeBSD/macOS native/runtime validation
- terminal motd/shell parity
- self-update hardening

---

## File Map

- Modify `src/protocol/http.zig`: TLS policy, custom DNS hooks, shared header construction.
- Modify `src/protocol/ws_client.zig`: Cloudflare headers, reconnect-safe connection API, optional insecure TLS.
- Modify `src/protocol/report_ws.zig`: reconnect loop, periodic basic info upload handoff.
- Modify `src/main.zig`: basic info ticker orchestration and shutdown shape.
- Modify `src/config.zig`: wildcard parsing tests only if parser behavior changes.
- Modify `src/platform/linux.zig`: `HOST_PROC`, memory modes, wildcard NIC filtering.
- Modify `src/platform/freebsd.zig`: native-ish collectors and parser tests.
- Modify `src/platform/darwin.zig`: macOS-specific collectors and parser tests.
- Modify `src/protocol/ping.zig`: IPv6 ICMP support.
- Modify `src/terminal/terminal.zig`: motd shell wrapper and shell fallback order.
- Modify `src/update.zig`: asset validation, safer replacement, release channel behavior.
- Add tests under `test/*_test.zig` for each changed behavior.

---

### Task 1: TLS Policy and Cloudflare Headers for WebSocket

**Files:**
- Modify: `src/protocol/http.zig`
- Modify: `src/protocol/ws_client.zig`
- Modify: `src/protocol/report_ws.zig`
- Modify: `src/terminal/terminal.zig`
- Test: `test/http_test.zig`

- [ ] **Step 1: Add header builder tests**

Add tests that assert CF headers are produced only when both config strings are set.

Run: `zig build test`

Expected before implementation: FAIL if helper absent.

- [ ] **Step 2: Add shared header helper**

Expose a helper in `http.zig`:

```zig
pub fn cloudflareHeaders(cfg: anytype, out: *[2]std.http.Header) []const std.http.Header {
    if (cfg.cf_access_client_id.len == 0 or cfg.cf_access_client_secret.len == 0) return &.{};
    out[0] = .{ .name = "CF-Access-Client-Id", .value = cfg.cf_access_client_id };
    out[1] = .{ .name = "CF-Access-Client-Secret", .value = cfg.cf_access_client_secret };
    return out[0..2];
}
```

- [ ] **Step 3: Thread config into `ws_client.connect`**

Change signature:

```zig
pub fn connect(allocator: std.mem.Allocator, url: []const u8, cfg: anytype) !*Client
```

Merge WebSocket upgrade headers plus optional CF headers.

- [ ] **Step 4: Wire report and terminal callers**

Update:
- `report_ws.zig`: `ws_client.connect(allocator, url, cfg)`
- `terminal.zig`: `ws_client.connect(allocator, url, cfg)`

- [ ] **Step 5: Verify**

Run:

```powershell
zig build test
zig build -Dtarget=x86_64-linux -Doptimize=ReleaseSmall -Dversion=dev
```

- [ ] **Step 6: Commit**

```powershell
git add src/protocol/http.zig src/protocol/ws_client.zig src/protocol/report_ws.zig src/terminal/terminal.zig test/http_test.zig
git commit -m "fix: send cloudflare headers on websocket"
```

---

### Task 2: Reconnect Loop and Periodic BasicInfo

**Files:**
- Modify: `src/protocol/report_ws.zig`
- Modify: `src/main.zig`
- Test: `test/bootstrap_test.zig` or new `test/reconnect_policy_test.zig`

- [ ] **Step 1: Add reconnect policy tests**

Create pure helpers:

```zig
pub fn reportSleepSeconds(interval: f64) u64 {
    return if (interval <= 1) 1 else @intFromFloat(interval - 1);
}

pub fn reconnectSleepSeconds(value: i32) u64 {
    return if (value <= 0) 5 else @intCast(value);
}
```

Test values: `interval=1 -> 1`, `interval=2.5 -> 1`, `reconnect=10 -> 10`.

- [ ] **Step 2: Refactor report loop**

Make `loop` reconnect after connect/write/read failures:

```zig
while (true) {
    var ws = connectReportWs(...) catch null;
    while (ws != null) { send reports; }
    std.Thread.sleep(reconnectSleepSeconds(cfg.reconnect_interval) * std.time.ns_per_s);
}
```

- [ ] **Step 3: Add BasicInfo ticker**

In `main.zig`, spawn a detached thread after first successful upload:

```zig
fn basicInfoLoop(allocator: std.mem.Allocator, cfg: config.Config) void {
    const mins = if (cfg.info_report_interval <= 0) 5 else cfg.info_report_interval;
    while (true) {
        std.Thread.sleep(@as(u64, @intCast(mins)) * 60 * std.time.ns_per_s);
        var info = provider.basicInfo(allocator) catch continue;
        basic_info.upload(allocator, cfg, info) catch {};
    }
}
```

- [ ] **Step 4: Verify remote behavior**

Deploy to `ccs2`, then:

```powershell
ssh ccs2 'systemctl restart komari-agent.service; sleep 20; journalctl -u komari-agent.service -n 40 --no-pager'
```

Expected: active, report `sent`, no one-shot exit.

- [ ] **Step 5: Commit**

```powershell
git add src/protocol/report_ws.zig src/main.zig test/reconnect_policy_test.zig build.zig
git commit -m "fix: reconnect websocket and refresh basic info"
```

---

### Task 3: Custom DNS and IDN on All Network Paths

**Files:**
- Modify: `src/dns.zig`
- Modify: `src/protocol/http.zig`
- Modify: `src/protocol/ws_client.zig`
- Modify: `src/protocol/ping.zig`
- Test: `test/dns_idna_test.zig`

- [ ] **Step 1: Define resolver contract**

Add:

```zig
pub const ResolveOptions = struct {
    custom_dns: []const u8 = "",
};
```

Resolve host through custom DNS when set; otherwise system resolver.

- [ ] **Step 2: HTTP/WS host normalization**

Before dialing or parsing URL hosts, call existing IDNA conversion for non-ASCII hostnames.

- [ ] **Step 3: TCP/ICMP ping uses resolver**

Change `measure` to accept config or add `measureWithOptions`.

- [ ] **Step 4: Tests**

Verify:
- `https://例子.测试/path` becomes ASCII host before connect path
- `custom_dns = "8.8.8.8"` picks custom resolver branch

- [ ] **Step 5: Commit**

```powershell
git add src/dns.zig src/protocol/http.zig src/protocol/ws_client.zig src/protocol/ping.zig test/dns_idna_test.zig
git commit -m "fix: route network dialing through configured dns"
```

---

### Task 4: Linux Memory Modes and HOST_PROC

**Files:**
- Modify: `src/platform/linux.zig`
- Modify: `src/platform/common.zig`
- Modify: `src/protocol/report_ws.zig`
- Test: `test/linux_basic_info_test.zig`

- [ ] **Step 1: Add proc path helper**

Implement:

```zig
fn procPath(allocator: std.mem.Allocator, root: []const u8, suffix: []const u8) ![]const u8 {
    if (root.len == 0) return std.fmt.allocPrint(allocator, "/proc/{s}", .{suffix});
    return std.fs.path.join(allocator, &.{ root, suffix });
}
```

- [ ] **Step 2: Thread `host_proc` into `SnapshotOptions`**

Add:

```zig
host_proc: []const u8 = "",
memory_include_cache: bool = false,
memory_report_raw_used: bool = false,
```

- [ ] **Step 3: Implement RAM formulas**

Behaviors:
- default: `used = total - MemAvailable`
- `memory_include_cache`: `used = total - MemFree`
- `memory_report_raw_used`: `used = total - free - buffers - cached`

- [ ] **Step 4: Use procPath everywhere Linux reads `/proc`**

Targets:
- `meminfo`
- `stat`
- `loadavg`
- `uptime`
- `net/dev`
- `net/tcp*`
- `net/udp*`
- process count

- [ ] **Step 5: Commit**

```powershell
git add src/platform/common.zig src/platform/linux.zig src/protocol/report_ws.zig test/linux_basic_info_test.zig
git commit -m "fix: honor linux memory modes and host proc"
```

---

### Task 5: NIC Wildcards and Network Parity

**Files:**
- Modify: `src/platform/linux.zig`
- Modify: `src/platform/freebsd.zig`
- Test: `test/network_filter_test.zig`

- [ ] **Step 1: Add wildcard tests**

Cases:
- include `eth*` matches `eth0`
- exclude `docker*` rejects `docker0`
- exact still works

- [ ] **Step 2: Implement glob matcher**

Minimal `*` wildcard:

```zig
pub fn globMatch(pattern: []const u8, value: []const u8) bool
```

Support prefix/suffix/middle `*`; no regex.

- [ ] **Step 3: Use matcher in include/exclude**

Replace exact `csvContains` in Linux; port same helper to FreeBSD or move to shared platform utility.

- [ ] **Step 4: Commit**

```powershell
git add src/platform/linux.zig src/platform/freebsd.zig test/network_filter_test.zig
git commit -m "fix: support wildcard network filters"
```

---

### Task 6: IPv6 ICMP and Ping Accuracy

**Files:**
- Modify: `src/protocol/ping.zig`
- Test: `test/ping_test.zig`

- [ ] **Step 1: Add ICMPv6 checksum and packet tests**

Test that packet builder emits type `128` for echo request and parses type `129`.

- [ ] **Step 2: Implement IPv6 branch**

If resolved address is `AF.INET6`, open:

```zig
std.posix.socket(std.posix.AF.INET6, std.posix.SOCK.DGRAM | CLOEXEC, std.posix.IPPROTO.ICMPV6)
```

Send ICMPv6 echo and parse reply.

- [ ] **Step 3: Keep permission behavior**

If socket returns `AccessDenied`, return `-1` rather than failing the report loop.

- [ ] **Step 4: Commit**

```powershell
git add src/protocol/ping.zig test/ping_test.zig
git commit -m "fix: add icmpv6 ping"
```

---

### Task 7: Terminal UX Parity

**Files:**
- Modify: `src/terminal/terminal.zig`
- Test: `test/ws_message_test.zig` or new `test/terminal_test.zig`

- [ ] **Step 1: Shell fallback order**

Implement:

```zig
SHELL if non-empty and executable
/bin/zsh
/bin/bash
/bin/sh
```

- [ ] **Step 2: Linux motd wrapper**

Match Go Unix behavior:

```sh
for f in /etc/update-motd.d/*; do [ -x "$f" ] && "$f"; done; [ -r /etc/motd ] && cat /etc/motd; exec "$0"
```

Use shell `-lc` when PTY starts.

- [ ] **Step 3: Close sequence**

On terminal close, write:
- Ctrl-C three times
- Ctrl-D
- `exit\n`

Then terminate child if still alive.

- [ ] **Step 4: Commit**

```powershell
git add src/terminal/terminal.zig test/terminal_test.zig build.zig
git commit -m "fix: match unix terminal startup and shutdown"
```

---

### Task 8: Self-Update Hardening and Install Script Coverage

**Files:**
- Modify: `src/update.zig`
- Modify: `install.sh`
- Modify: `.github/workflows/build.yml`
- Modify: `.github/workflows/release.yml`
- Test: new `test/update_test.zig`

- [ ] **Step 1: Add update tests**

Cover:
- `v1.2.3` > `1.2.2`
- prerelease does not downgrade stable
- asset exact name required
- Windows asset rejected

- [ ] **Step 2: Safer replacement**

Flow:
- download to `agent.update`
- chmod `0755`
- keep `agent.bak`
- rename old to backup
- rename update to current
- if final rename fails, restore backup

- [ ] **Step 3: Install script service managers**

Add FreeBSD rc.d native branch if OpenRC absent:

```sh
/usr/local/etc/rc.d/$service_name
sysrc ${service_name}_enable=YES
service "$service_name" restart
```

- [ ] **Step 4: CI matrix final check**

Ensure release matrix includes:
- linux: amd64, arm64, 386, arm
- freebsd: amd64, arm64, 386
- darwin: amd64, arm64

- [ ] **Step 5: Commit**

```powershell
git add src/update.zig install.sh .github/workflows/build.yml .github/workflows/release.yml test/update_test.zig build.zig
git commit -m "fix: harden self update and install coverage"
```

---

## Final Verification

- [ ] Run unit tests:

```powershell
zig build test
```

- [ ] Run cross builds:

```powershell
zig build -Dtarget=x86_64-linux -Doptimize=ReleaseSmall -Dversion=dev
zig build -Dtarget=aarch64-linux -Doptimize=ReleaseSmall -Dversion=dev
zig build -Dtarget=x86_64-freebsd -Doptimize=ReleaseSmall -Dversion=dev
zig build -Dtarget=aarch64-freebsd -Doptimize=ReleaseSmall -Dversion=dev
zig build -Dtarget=x86_64-macos -Doptimize=ReleaseSmall -Dversion=dev
zig build -Dtarget=aarch64-macos -Doptimize=ReleaseSmall -Dversion=dev
```

- [ ] Deploy to `ccs2`:

```powershell
scp .\zig-out\bin\komari-agent ccs2:/opt/komari/agent.zig-new
ssh ccs2 'set -e; systemctl stop komari-agent.service; cp /opt/komari/agent /opt/komari/agent.prev-gapfix-$(date +%Y%m%d%H%M%S); install -m 0755 /opt/komari/agent.zig-new /opt/komari/agent; systemctl start komari-agent.service; sleep 20; systemctl is-active komari-agent.service; journalctl -u komari-agent.service -n 30 --no-pager'
```

Expected:
- service `active`
- repeated `Report generated: ... sent`
- no `WebSocket connect failed`

- [ ] Push:

```powershell
git push origin main
```

---

## Residual Non-Goals

- Windows agent remains out of scope.
- FreeBSD/macOS must be runtime-tested on real hosts before claiming production parity.
- GPU detail still depends on vendor tools being installed, same practical constraint as Go agent.
