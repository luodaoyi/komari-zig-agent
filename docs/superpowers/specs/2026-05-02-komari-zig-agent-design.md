# Komari Zig Agent Design

Date: 2026-05-02

## Goal

Build a Zig implementation of `komari-agent` that can replace the current Go agent for Linux, FreeBSD, and macOS while preserving all public protocols, command-line behavior, configuration keys, installation flow, release assets, and service behavior.

Windows support is explicitly out of scope for the first implementation. The project may keep compatible option names and script branches, but it must not publish or claim a working Windows Zig agent until Windows support is implemented.

## Source Compatibility Target

The compatibility target is the current Go repository at:

`D:\sources\repos-new\gh\komari-agent`

The new implementation lives at:

`D:\sources\repos-new\gh\komari-zig-agent`

The Zig agent must preserve the behavior that matters to the Komari panel and deployment automation:

- Binary asset names: `komari-agent-{os}-{arch}` for supported Unix-like targets.
- CLI flags, short flags, environment variables, and JSON config keys.
- HTTP endpoints, methods, query parameters, headers, payload fields, and retry behavior.
- WebSocket endpoints, message types, ping frames, JSON payloads, and terminal stream behavior.
- Service install defaults and install script arguments.
- Exit behavior for self-update, including exit code `42` after a successful update.

## Supported Platforms

First implementation:

- Linux: `amd64`, `arm64`, `386`, `arm`
- FreeBSD: `amd64`, `arm64`, `386`, `arm` where Zig can build and the platform APIs are available
- macOS: `amd64`, `arm64`

Not supported in first implementation:

- Windows binaries, Windows service installation, Windows ConPTY, Windows metrics

## Configuration Compatibility

The Zig agent must accept the same user-facing configuration surface as the Go agent:

- `--token`, `-t`
- `--endpoint`, `-e`
- `--auto-discovery`
- `--disable-auto-update`
- `--disable-web-ssh`
- `--interval`, `-i`
- `--ignore-unsafe-cert`, `-u`
- `--max-retries`, `-r`
- `--reconnect-interval`, `-c`
- `--info-report-interval`
- `--include-nics`
- `--exclude-nics`
- `--include-mountpoint`
- `--month-rotate`
- `--cf-access-client-id`
- `--cf-access-client-secret`
- `--memory-include-cache`
- `--memory-exclude-bcf`
- `--custom-dns`
- `--gpu`
- `--show-warning`
- `--custom-ipv4`
- `--custom-ipv6`
- `--get-ip-addr-from-nic`
- `--config`

The Zig agent must also load the existing JSON keys and environment variables from the Go `Config` struct, including deprecated keys where they still affect compatibility. Environment variables override parsed defaults, and JSON config loading must remain compatible with existing installed configs.

Unknown flags should not break startup, matching the Go agent's current permissive parsing behavior.

## Protocol Compatibility

### Basic Info Upload

The agent uploads basic information to:

`POST {endpoint}/api/clients/uploadBasicInfo?token={token}`

Payload fields:

- `cpu_name`
- `cpu_cores`
- `arch`
- `os`
- `kernel_version`
- `ipv4`
- `ipv6`
- `mem_total`
- `swap_total`
- `disk_total`
- `gpu_name`
- `virtualization`
- `version`

If the server rejects the full payload, the agent retries without `kernel_version` for compatibility with older panels.

### Report WebSocket

The agent connects to:

`{endpoint}/api/clients/report?token={token}`

with `http` converted to `ws` and `https` converted to `wss`. IDN hostnames must be converted to ASCII/Punycode before dialing.

The regular report payload must preserve these top-level fields:

- `cpu`
- `ram`
- `swap`
- `load`
- `disk`
- `network`
- `connections`
- `uptime`
- `process`
- `gpu` when detailed GPU monitoring is enabled and data is available
- `message`

The agent sends WebSocket ping frames every 30 seconds. It sends report JSON on the configured interval, with the Go-compatible minimum interval behavior.

### WebSocket Commands

The report WebSocket must handle these incoming messages:

- Terminal request: `message == "terminal"` or non-empty `request_id`
- Remote exec: `message == "exec"`
- Ping task: `message == "ping"` or ping task fields are present

Remote exec uploads results to:

`POST {endpoint}/api/clients/task/result?token={token}`

Payload fields:

- `task_id`
- `result`
- `exit_code`
- `finished_at`

Remote exec must run through the platform shell on supported Unix-like systems. If remote control is disabled, the result must report `"Remote control is disabled."` with exit code `-1`.

Ping tasks must support:

- `icmp`
- `tcp`
- `http`

Ping result messages must be written back to the report WebSocket with:

- `type: "ping_result"`
- `task_id`
- `ping_type`
- `value`
- `finished_at`

The value `-1` means failure or packet loss.

### Terminal WebSocket

The agent connects terminal sessions to:

`{endpoint}/api/clients/terminal?token={token}&id={request_id}`

The terminal protocol must preserve:

- Text input JSON: `{ "type": "input", "input": "..." }`
- Resize JSON: `{ "type": "resize", "cols": N, "rows": N }`
- Raw binary input to PTY
- PTY output as binary WebSocket messages
- Disabled web SSH message when `--disable-web-ssh` is set

Linux, FreeBSD, and macOS terminal support should use Unix PTY APIs. The shell selection should follow the Go behavior: user shell when possible, then `zsh`, `bash`, `sh`.

## Monitoring Design

The report implementation should favor direct platform APIs and system files to reduce CPU and memory overhead:

- Linux: prefer `/proc`, `/sys`, `sysinfo`, `statvfs`, and netlink or `/proc/net` where practical.
- FreeBSD/macOS: prefer `sysctl`, `getifaddrs`, `statfs/statvfs`, `kinfo_proc`, and native socket tables where practical.
- External commands are allowed only where there is no small reliable platform API, such as optional GPU helpers.

Required metrics:

- CPU name, architecture, cores, usage
- RAM and swap total/used
- Load averages
- Disk total/used and mount list filtering
- Network total up/down and current up/down speed
- TCP and UDP connection counts
- Uptime
- Process count
- OS name and kernel version
- IP address discovery, with custom IPv4/IPv6 overrides
- Virtualization detection
- GPU name and detailed GPU data where the platform and local tools expose it

Network interface filtering must preserve default virtual and loopback exclusions, include lists, and exclude lists.

Memory behavior must preserve:

- Default Linux htop-like calculation
- `--memory-include-cache`
- `--memory-exclude-bcf`

## Monthly Traffic Accounting

When `--month-rotate` is non-zero, the Zig agent must maintain `net_static.json` compatibility:

- Same top-level structure: `interfaces` and `config`
- Same traffic record fields: `timestamp`, `tx`, `rx`
- Same default preserve, detect, and save intervals
- Same reset-day calculation, including month-end overflow behavior
- Same low-I/O behavior: keep hot samples in memory and flush periodically

The implementation must tolerate corrupt `net_static.json` by backing it up and continuing with a fresh store.

## DNS, TLS, and HTTP Behavior

The agent must support:

- System DNS by default
- `--custom-dns` with normalization for IPv4, IPv6, and host:port forms
- Fallback DNS servers only when custom DNS is set and unavailable
- IPv4/IPv6 ordering based on local interface capability
- `--ignore-unsafe-cert`
- Proxy environment variables
- Cloudflare Access headers:
  - `CF-Access-Client-Id`
  - `CF-Access-Client-Secret`

## Auto Discovery

Auto discovery must preserve the current file and server contract:

- Config file path: `auto-discovery.json` next to the executable
- Register endpoint: `POST {endpoint}/api/clients/register?name={hostname}`
- Headers:
  - `Content-Type: application/json`
  - `Authorization: Bearer {auto_discovery_key}`
  - optional Cloudflare Access headers
- Request body: `{ "key": "..." }`
- Response data fields: `uuid`, `token`

If `auto-discovery.json` already exists, the agent must reuse its token.

## Self Update

Self-update must check GitHub releases for the configured repository and replace the current executable when a newer semver release exists.

Compatibility requirements:

- Current version defaults to `0.0.1` unless CI injects a version.
- Accept tags with optional `v` or `V` prefix.
- Run a startup check unless `--disable-auto-update` is set.
- Check periodically every 6 hours.
- Exit with code `42` after successful update.

If fully safe in-place replacement cannot be made portable in Zig in the first pass, the implementation plan must include a small, auditable updater path that preserves the same user-visible behavior.

## Install Scripts and CI/CD

The new repository must provide:

- `install.sh` compatible with the Go script arguments:
  - `--install-dir`
  - `--install-service-name`
  - `--install-ghproxy`
  - `--install-version`
- Init support for:
  - systemd
  - OpenRC
  - OpenWrt procd
  - Upstart
  - macOS launchd
  - NixOS guidance
- GitHub Actions build workflow for supported platform and architecture matrix.
- GitHub Actions release workflow attaching release binaries.
- GitHub Actions release-note workflow.
- Docker release workflow for Linux `amd64` and `arm64`.
- `Dockerfile` compatible with the release asset names.
- Local build script for cross builds.

The download asset names should stay `komari-agent-{os}-{arch}` so existing installation instructions continue to work.

## Repository Structure

Planned source layout:

- `build.zig`: Zig build configuration and version injection.
- `build.zig.zon`: dependency lock and package metadata.
- `src/main.zig`: entrypoint and lifecycle.
- `src/config.zig`: CLI, env, JSON config, defaults, deprecated flag handling.
- `src/version.zig`: version and repository constants.
- `src/log.zig`: small logging helpers.
- `src/protocol/http.zig`: HTTP client helpers, headers, retries.
- `src/protocol/ws.zig`: WebSocket client and synchronized writes.
- `src/protocol/basic_info.zig`: basic info upload.
- `src/protocol/report.zig`: report WebSocket lifecycle.
- `src/protocol/task.zig`: remote exec and task result upload.
- `src/protocol/ping.zig`: ICMP, TCP, and HTTP ping tasks.
- `src/protocol/autodiscovery.zig`: registration and token reuse.
- `src/report/report.zig`: report JSON generation.
- `src/report/netstatic.zig`: monthly traffic store.
- `src/terminal/terminal.zig`: Unix terminal session protocol.
- `src/platform/common.zig`: shared metric types.
- `src/platform/linux.zig`: Linux metrics and terminal helpers.
- `src/platform/freebsd.zig`: FreeBSD metrics and terminal helpers.
- `src/platform/darwin.zig`: macOS metrics and terminal helpers.
- `src/update.zig`: self-update.
- `src/idna.zig`: IDN to ASCII conversion.
- `src/dns.zig`: resolver and dialing behavior.
- `test/`: protocol, config, JSON compatibility, and platform-unit tests.
- `.github/workflows/`: build, release, release notes, Docker publish.

## Testing and Acceptance

Compatibility must be proven with tests before declaring replacement readiness:

- Config tests for CLI, env, JSON, deprecated flags, and unknown flags.
- JSON golden tests for basic info, report payload, ping result, task result, auto-discovery request, and `net_static.json`.
- WebSocket mock server tests for report connection, incoming command dispatch, ping frame behavior, reconnect behavior, and terminal session handoff.
- HTTP mock server tests for basic info fallback without `kernel_version`, task result retries, auto-discovery registration, and Cloudflare Access headers.
- Platform unit tests for parsing `/proc`, `sysctl` output adapters, network filters, reset-date calculation, and disk filtering.
- CI cross-build for all supported target names.
- Manual smoke test against a Komari panel or compatible local mock before release.

## Risks

- Zig ecosystem support for production-grade WebSocket, TLS, IDN, and self-update may require careful dependency choice or small custom implementations.
- ICMP ping may require privileges or platform-specific socket handling.
- GPU detail parity depends on local tools such as `nvidia-smi` or ROCm utilities.
- FreeBSD and macOS socket connection counts may differ from Go `gopsutil`; tests must define acceptable parity by protocol output rather than internal method.
- Automatic executable replacement is sensitive on Unix permissions and service managers.

## Non-Goals for First Implementation

- Windows runtime support.
- Changing Komari server protocols.
- Adding new agent features beyond Go-agent compatibility.
- Replacing the Komari panel.
- Changing release asset names.

## Approval

The user approved this design direction in chat on 2026-05-02.
