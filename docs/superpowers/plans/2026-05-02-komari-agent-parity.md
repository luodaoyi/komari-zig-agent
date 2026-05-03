# Komari Agent Protocol Parity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `komari-zig-agent` a drop-in Linux/FreeBSD/macOS replacement for the Go `komari-agent`, with all non-Windows features and wire protocols preserved.

**Architecture:** Keep the public JSON protocol in `src/protocol`, OS collectors in `src/platform`, and long-running agent orchestration in `src/main.zig`. Implement Linux first because it is the live deployment target, then FreeBSD/macOS, then replace temporary child-process HTTP/WebSocket plumbing with native Zig transport.

**Tech Stack:** Zig 0.16.0, stdlib JSON/HTTP/process/fs APIs, `/proc` and `/sys` on Linux, `sysctl`/`kstat`-style native files where available, shell-free CI builds for Linux/FreeBSD/macOS.

---

## Current Verdict

The agent is not 1:1 complete yet. It can build, start, upload basic info, and send report frames, but metrics and WS downlink protocols are incomplete. Treat current remote deployment as a live smoke-test bed, not a finished replacement.

## Protocol Compatibility Target

The Zig agent must preserve these Go agent endpoints and payloads:

- `POST /api/clients/uploadBasicInfo?token=...`
- `GET /api/clients/report?token=...` as WebSocket
- `GET /api/clients/terminal?token=...&id=...` as WebSocket
- `POST /api/clients/task/result?token=...`
- Report JSON fields: `cpu`, `ram`, `swap`, `load`, `disk`, `network`, `connections`, `uptime`, `process`, optional `gpu`, `message`
- BasicInfo JSON fields: `cpu_name`, `cpu_cores`, `arch`, `os`, `kernel_version`, `ipv4`, `ipv6`, `mem_total`, `swap_total`, `disk_total`, `gpu_name`, `virtualization`, `version`
- WS server messages:
  - terminal: `{"message":"terminal","request_id":"..."}`
  - exec: `{"message":"exec","task_id":"...","command":"..."}`
  - ping: `{"message":"ping","ping_task_id":1,"ping_type":"icmp|tcp|http","ping_target":"..."}`
- WS ping result message:
  - `{"type":"ping_result","task_id":1,"ping_type":"tcp","value":12,"finished_at":"..."}`
- Task result upload:
  - `{"task_id":"...","result":"...","exit_code":0,"finished_at":"..."}`

## Files And Responsibilities

- Modify `src/platform/common.zig`: shared metric structs, disk/network/GPU/virtualization structs, collector result shape.
- Modify `src/platform/linux.zig`: full Linux collectors for distro, CPU, disk, network, traffic, connections, IP, GPU, virtualization.
- Modify `src/platform/freebsd.zig`: FreeBSD collectors matching Linux fields.
- Modify `src/platform/darwin.zig`: macOS collectors matching Linux fields.
- Modify `src/platform/provider.zig`: stable OS dispatch and previous-snapshot state injection.
- Modify `src/report/report.zig`: serialize complete report JSON exactly like Go.
- Modify `src/report/netstatic.zig`: monthly traffic persistence and reset-day accounting.
- Modify `src/protocol/ws.zig`: native WebSocket client framing, read loop, ping/pong/close, masking, reconnect.
- Modify `src/protocol/report_ws.zig`: report loop plus WS message dispatch.
- Modify `src/protocol/task.zig`: exec task execution and task-result upload.
- Modify `src/protocol/ping.zig`: tcp/http/icmp ping semantics compatible with Go.
- Modify `src/terminal/terminal.zig`: PTY-backed terminal bridge on Unix.
- Modify `src/protocol/http.zig`: native HTTP POST, CF headers, IDN/DNS selection, retry behavior.
- Modify `src/protocol/basic_info.zig`: upload fallback without `kernel_version` for old servers.
- Modify `src/protocol/autodiscovery.zig`: registration/discovery flow.
- Modify `src/update.zig`: self-update/install replacement semantics.
- Modify `src/config.zig`: confirm every Go CLI/env/config flag is accepted.
- Modify `src/main.zig`: orchestrate basic-info ticker, report WS, netstatic, update, graceful shutdown.
- Modify `install.sh`, `build_all.sh`, `build_all.ps1`, `.github/workflows/*`: release assets and install behavior.
- Add tests under `test/` for every JSON shape and parser.

---

## Task 1: Freeze Go Protocol Goldens

**Files:**
- Modify: `test/golden/basic_info.json`
- Modify: `test/golden/report.json`
- Modify: `test/golden/ping_result.json`
- Modify: `test/golden/task_result.json`
- Modify: `test/protocol_json_test.zig`

- [x] Add representative non-zero golden values for every Go field: disk, network, connections, gpu, message, finished_at.
- [x] Add tests that fail if a field is renamed, omitted, or changes numeric type.
- [x] Run: `zig build test`
- [x] Expected: tests fail until serializers emit complete payloads.
- [x] Commit: `test: freeze komari protocol payload parity`

## Task 2: Complete Config/Flag Parity

**Files:**
- Modify: `src/config.zig`
- Modify: `test/config_test.zig`

- [x] Compare `D:\sources\repos-new\gh\komari-agent\cmd\flags\flag.go`, `cmd\root.go`, `cmd\autodiscovery.go`, `cmd\listDisk.go`.
- [x] Ensure Zig accepts: endpoint, token, interval, max retries, reconnect interval, info report interval, disable web ssh, ignore unsafe cert, include/exclude nics, include mountpoints, month rotate, enable gpu, custom dns, ipv4/ipv6 preference, CF Access headers, host proc.
- [x] Keep Windows-only warning behavior out of scope.
- [x] Add `listDisk` equivalent command for Unix.
- [x] Run: `zig build test`
- [x] Commit: `feat: complete config and cli parity`

## Task 3: Linux BasicInfo Collectors

**Files:**
- Modify: `src/platform/common.zig`
- Modify: `src/platform/linux.zig`
- Modify: `src/protocol/basic_info.zig`
- Add: `test/linux_basic_info_test.zig`

- [x] Implement distro name from `/etc/os-release` using `PRETTY_NAME`, fallback to `ID`, fallback `linux`.
- [ ] Implement kernel from `/proc/sys/kernel/osrelease` and `uname` fallback.
- [x] Implement arch mapping compatible with Go/runtime labels: `amd64`, `arm64`, `386`, `arm`.
- [ ] Implement IPv4/IPv6 public/local discovery with the same “return string or empty” behavior.
- [x] Implement virtualization detection from `/proc/1/environ`, `/proc/cpuinfo`, `/sys/class/dmi/id/product_name`, `systemd-detect-virt` only as last optional child process.
- [ ] Implement GPU name discovery from `nvidia-smi`, `rocm-smi`, `/sys/class/drm`, keeping failure silent.
- [x] Run: `zig build test`
- [ ] Run on `ccs2`: `/opt/komari/agent --list-disk` after redeploy when ready.
- [x] Commit: `feat: complete linux basic info collectors`

## Task 4: Linux Disk Collector

**Files:**
- Modify: `src/platform/linux.zig`
- Modify: `src/platform/common.zig`
- Add: `test/disk_filter_test.zig`

- [x] Parse `/proc/self/mountinfo` or `/proc/mounts`.
- [ ] Use `statvfs` for total/used bytes.
- [x] Include `/` even under containers.
- [x] Exclude Go-equivalent pseudo/network/tmp filesystems: `tmpfs`, `devtmpfs`, `nfs`, `cifs`, `smb`, `vboxsf`, `9p`, `fuse`, `overlay`, `proc`, `devpts`, `sysfs`, `cgroup`, `mqueue`, `hugetlbfs`, `debugfs`, `binfmt_misc`, `securityfs`.
- [x] Exclude mount prefixes: `/tmp`, `/var/tmp`, `/dev`, `/run`, `/var/lib/containers`, `/var/lib/docker`, `/proc`, `/sys`, `/sys/fs/cgroup`, `/etc/resolv.conf`, `/etc/host`, `/nix/store`.
- [x] Respect `--include-mountpoint` semicolon list.
- [x] Deduplicate ZFS by pool name.
- [ ] Add `listDisk` output matching Go style: `mountpoint (fstype)`.
- [x] Run: `zig build test`
- [x] Commit: `feat: add linux disk collector`

## Task 5: Linux Network Speed And Traffic

**Files:**
- Modify: `src/platform/linux.zig`
- Modify: `src/report/netstatic.zig`
- Modify: `src/config.zig`
- Add: `test/network_filter_test.zig`
- Add: `test/netstatic_test.zig`

- [x] Parse `/proc/net/dev`.
- [x] Exclude default virtual prefixes: `br`, `cni`, `docker`, `podman`, `flannel`, `lo`, `veth`, `virbr`, `vmbr`, `tap`, `fwbr`, `fwpr`.
- [x] Respect include-nics whitelist and exclude-nics blacklist.
- [x] Compute speed by delta over the report interval without sleeping inside collector.
- [ ] Persist total counters in `netstatic` when `month_rotate != 0`.
- [x] Implement reset day with same rule as Go `utils.GetLastResetDate`.
- [ ] Fall back to live total counters if persistence fails, and append message text.
- [x] Run: `zig build test`
- [x] Commit: `feat: add linux network traffic collector`

## Task 6: Linux CPU, Load, Process, Connections

**Files:**
- Modify: `src/platform/linux.zig`
- Modify: `src/platform/provider.zig`
- Add: `test/cpu_proc_test.zig`

- [x] Replace fixed CPU usage with `/proc/stat` delta calculation.
- [x] Keep minimum CPU usage at `0.001`, matching Go report behavior.
- [x] Keep load from `/proc/loadavg`.
- [x] Keep process count from numeric dirs in `/proc`.
- [x] Count TCP from `/proc/net/tcp` and `/proc/net/tcp6`.
- [x] Count UDP from `/proc/net/udp` and `/proc/net/udp6`.
- [x] Run: `zig build test`
- [x] Commit: `feat: add linux cpu and connection collectors`

## Task 7: Complete Report JSON

**Files:**
- Modify: `src/report/report.zig`
- Modify: `src/platform/common.zig`
- Modify: `test/protocol_json_test.zig`

- [ ] Serialize all Go report keys.
- [ ] Always include `message`.
- [ ] Include `gpu` only when GPU detailed collection is enabled and data exists, matching Go behavior.
- [ ] Ensure integer byte counters remain JSON numbers, not strings.
- [ ] Run: `zig build test`
- [ ] Commit: `feat: complete report json parity`

## Task 8: Native HTTP Client And BasicInfo Fallback

**Files:**
- Modify: `src/protocol/http.zig`
- Modify: `src/protocol/basic_info.zig`
- Modify: `src/dns.zig`
- Modify: `src/idna.zig`
- Modify: `test/http_test.zig`
- Modify: `test/dns_idna_test.zig`

- [ ] Replace `curl` child process with native Zig HTTP.
- [ ] Apply IDN-to-ASCII conversion before dial.
- [ ] Apply custom DNS and IPv4/IPv6 preference.
- [ ] Apply CF Access headers to all HTTP requests.
- [ ] Respect ignore-unsafe-cert where Zig TLS permits; otherwise document exact unsupported limitation before release.
- [ ] Retry task/basic uploads with max-retries and delay.
- [ ] For BasicInfo, retry once without `kernel_version` if server rejects full payload.
- [ ] Run: `zig build test`
- [ ] Commit: `feat: add native http protocol client`

## Task 9: Native WebSocket Transport

**Files:**
- Modify: `src/protocol/ws.zig`
- Modify: `src/protocol/report_ws.zig`
- Modify: `test/http_test.zig`

- [ ] Replace `openssl s_client` with native TCP/TLS WebSocket client.
- [ ] Implement HTTP upgrade with `Sec-WebSocket-Key`.
- [ ] Validate status `101`.
- [ ] Write masked text frames.
- [ ] Read text, ping, pong, close frames.
- [ ] Send heartbeat ping every 30 seconds.
- [ ] Reconnect using max retries and reconnect interval.
- [ ] Preserve CF headers and DNS behavior.
- [ ] Run: `zig build test`
- [ ] Commit: `feat: add native websocket client`

## Task 10: WS Message Dispatch

**Files:**
- Modify: `src/protocol/report_ws.zig`
- Modify: `src/protocol/task.zig`
- Modify: `src/protocol/ping.zig`
- Modify: `src/terminal/terminal.zig`
- Add: `test/ws_message_test.zig`

- [x] Parse unknown WS messages without crashing.
- [x] Dispatch terminal when `message == "terminal"` or `request_id != ""`.
- [x] Dispatch exec when `message == "exec"`.
- [x] Dispatch ping when `message == "ping"` or ping fields exist.
- [x] Ensure report sending continues while tasks run.
- [x] Run: `zig build test`
- [x] Commit: `feat: dispatch websocket tasks`

## Task 11: Exec Task Protocol

**Files:**
- Modify: `src/protocol/task.zig`
- Modify: `src/protocol/http.zig`
- Add: `test/task_test.zig`

- [x] On Unix run `sh -c <command>`.
- [x] If command empty, upload result `No command provided` with exit code `0`.
- [x] If remote control disabled, upload result `Remote control is disabled.` with exit code `-1`.
- [x] Merge stdout and stderr with `\n`, normalize CRLF to LF.
- [x] Detect exit code from child process.
- [x] Upload to `/api/clients/task/result?token=...`.
- [x] Run: `zig build test`
- [x] Commit: `feat: add exec task protocol`

## Task 12: Ping Task Protocol

**Files:**
- Modify: `src/protocol/ping.zig`
- Modify: `src/protocol/ws.zig`
- Add: `test/ping_test.zig`

- [x] TCP ping: resolve host before timing, default port 80.
- [x] HTTP ping: add `http://` when scheme absent, resolve host before timing, success for status 200-399.
- [ ] ICMP ping: implement raw socket where permitted; if permission denied, return `-1` and log message.
- [ ] Timeout is 3 seconds.
- [ ] Retry high latency over 1000 ms up to 3 times.
- [x] Send `ping_result` JSON over the report WS.
- [x] Run: `zig build test`
- [ ] Commit: `feat: add ping task protocol`

## Task 13: Terminal Protocol

**Files:**
- Modify: `src/terminal/terminal.zig`
- Modify: `src/protocol/report_ws.zig`
- Modify: `src/protocol/ws.zig`

- [ ] Connect `/api/clients/terminal?token=...&id=...`.
- [ ] Start `/bin/sh` or user shell from `SHELL`.
- [ ] Bridge PTY stdin/stdout/stderr to WebSocket binary/text messages compatible with Go terminal package.
- [ ] Handle resize messages if Go protocol sends them.
- [ ] Close process when WS closes.
- [ ] Run: `zig build test`
- [ ] Test manually from Komari panel terminal on `ccs2`.
- [ ] Commit: `feat: add unix terminal websocket`

## Task 14: Auto Discovery And Registration

**Files:**
- Modify: `src/protocol/autodiscovery.zig`
- Modify: `src/main.zig`
- Modify: `test/golden/autodiscovery_request.json`

- [ ] Match Go autodiscovery request shape.
- [ ] Respect config file creation and token persistence.
- [ ] Preserve user-provided endpoint/token precedence.
- [ ] Handle failed registration with clear logs and non-zero exit where Go exits.
- [ ] Run: `zig build test`
- [ ] Commit: `feat: add autodiscovery registration`

## Task 15: Self Update

**Files:**
- Modify: `src/update.zig`
- Modify: `src/main.zig`
- Modify: `install.sh`

- [ ] Match Go update channel/version check behavior.
- [ ] Download correct asset for linux/freebsd/darwin and amd64/arm64/386/arm where supported.
- [ ] Verify executable bit and replace current binary atomically.
- [ ] Restart through systemd when installed as service.
- [ ] Never update to Windows artifact.
- [ ] Run: `zig build test`
- [ ] Commit: `feat: add unix self update`

## Task 16: FreeBSD Collectors

**Files:**
- Modify: `src/platform/freebsd.zig`
- Add: `test/freebsd_compile_test.zig`

- [ ] Implement CPU, mem, swap, load, uptime, process, disk, network counters, connections, OS/kernel, arch.
- [ ] Use native `sysctl` and mount APIs where Zig exposes them; use procfs only when mounted.
- [ ] Keep unsupported GPU detailed data empty, not fatal.
- [ ] Cross-build: `zig build -Dtarget=x86_64-freebsd -Dversion=dev`
- [ ] Cross-build: `zig build -Dtarget=aarch64-freebsd -Dversion=dev`
- [ ] Commit: `feat: add freebsd collectors`

## Task 17: macOS Collectors

**Files:**
- Modify: `src/platform/darwin.zig`
- Add: `test/darwin_compile_test.zig`

- [ ] Implement CPU, mem, swap, load, uptime, process, disk, network counters, connections, OS/kernel, arch.
- [ ] Use `sysctl`, `getifaddrs`, and mount APIs.
- [ ] Keep unsupported detailed GPU data empty, not fatal.
- [ ] Cross-build: `zig build -Dtarget=x86_64-macos -Dversion=dev`
- [ ] Cross-build: `zig build -Dtarget=aarch64-macos -Dversion=dev`
- [ ] Commit: `feat: add macos collectors`

## Task 18: Install Scripts And CI

**Files:**
- Modify: `install.sh`
- Modify: `build_all.sh`
- Modify: `build_all.ps1`
- Modify: `.github/workflows/build.yml`
- Modify: `.github/workflows/release.yml`
- Modify: `README.md`

- [ ] Ensure install script detects Linux/FreeBSD/macOS and amd64/arm64/386/arm.
- [ ] Install to `/opt/komari/agent`.
- [ ] Create/replace `komari-agent.service` on systemd Linux.
- [ ] Preserve endpoint/token flags in service.
- [ ] Build all supported assets in CI.
- [ ] Upload release artifacts with Go-compatible names where possible.
- [ ] Run local `./build_all.ps1`.
- [ ] Commit: `ci: add release builds and install parity`

## Task 19: Remote Replacement Test On ccs2

**Files:**
- No source file expected unless bugs are found.

- [ ] Build linux amd64 release binary.
- [ ] Upload to `ccs2:/opt/komari/agent.zig-test`.
- [ ] Stop `komari-agent.service`.
- [ ] Backup current `/opt/komari/agent`.
- [ ] Move Zig binary into `/opt/komari/agent`.
- [ ] Start service.
- [ ] Verify `systemctl is-active komari-agent.service`.
- [ ] Verify RSS and CPU with `ps`.
- [ ] Verify panel receives non-zero disk/network/connection metrics.
- [ ] Trigger panel ping task and verify `ping_result`.
- [ ] Trigger panel exec task and verify task result.
- [ ] Trigger panel terminal and verify interactive shell.
- [ ] Roll back to previous binary if any protocol fails in production use.
- [ ] Commit bug fixes found during remote test.

## Task 20: Final Parity Gate

**Files:**
- Modify: `README.md`
- Add: `docs/protocol-parity.md`

- [ ] Run: `zig build test`
- [ ] Run: `./build_all.ps1`
- [ ] Run remote smoke test on `ccs2`.
- [ ] Document exact parity status: supported OS, unsupported Windows, GPU limits, ICMP permission note.
- [ ] Confirm no `curl` or `openssl` subprocess remains in runtime path.
- [ ] Confirm `git status --short` contains only intentional files.
- [ ] Commit: `docs: document komari agent protocol parity`

---

## Execution Order

1. Tasks 1-2: freeze contract, flags.
2. Tasks 3-7: Linux observability parity.
3. Tasks 8-13: native protocol and task parity.
4. Tasks 14-15: discovery/update.
5. Tasks 16-17: FreeBSD/macOS.
6. Tasks 18-20: packaging, remote deployment, final gate.

## Stop Conditions

- Stop and report if Komari server expects an undocumented field not present in Go source.
- Stop and report if Zig stdlib TLS cannot support required insecure-cert behavior without an external dependency.
- Stop and report if terminal protocol differs from Go after live panel testing.
- Stop and roll back `ccs2` if the service fails to stay active or panel stops receiving reports.
