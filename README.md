# komari-zig-agent

Zig 版 `komari-agent`，目标是直接替换原 Go agent，并保持 Komari 现有协议、上报字段、任务、Ping、Web SSH、自更新等行为兼容。

## 项目看板

<p>
  <a href="https://github.com/luodaoyi/komari-zig-agent/actions/workflows/build.yml?query=branch%3Amain"><img alt="Build" src="https://img.shields.io/github/actions/workflow/status/luodaoyi/komari-zig-agent/build.yml?branch=main&label=build&logo=githubactions&logoColor=white" /></a>
  <a href="https://github.com/luodaoyi/komari-zig-agent/actions/workflows/build.yml?query=branch%3Amain"><img alt="Coverage Gate" src="https://img.shields.io/github/actions/workflow/status/luodaoyi/komari-zig-agent/build.yml?branch=main&label=coverage%20100%25%20gate&logo=codecov&logoColor=white" /></a>
  <a href="https://github.com/luodaoyi/komari-zig-agent/actions/workflows/release.yml"><img alt="Release Workflow" src="https://img.shields.io/github/actions/workflow/status/luodaoyi/komari-zig-agent/release.yml?label=release&logo=githubactions&logoColor=white" /></a>
  <a href="https://github.com/luodaoyi/komari-zig-agent/releases/latest"><img alt="Latest Release" src="https://img.shields.io/github/v/release/luodaoyi/komari-zig-agent?display_name=tag&sort=semver" /></a>
  <a href="https://github.com/luodaoyi/komari-zig-agent/releases"><img alt="Release Date" src="https://img.shields.io/github/release-date/luodaoyi/komari-zig-agent" /></a>
  <a href="https://github.com/luodaoyi/komari-zig-agent/releases"><img alt="Total Downloads" src="https://img.shields.io/github/downloads/luodaoyi/komari-zig-agent/total?label=release%20downloads" /></a>
  <a href="https://github.com/luodaoyi/komari-zig-agent/stargazers"><img alt="Stars" src="https://img.shields.io/github/stars/luodaoyi/komari-zig-agent?style=flat" /></a>
  <a href="https://github.com/luodaoyi/komari-zig-agent/issues"><img alt="Issues" src="https://img.shields.io/github/issues/luodaoyi/komari-zig-agent" /></a>
</p>

<p>
  <img alt="Systems" src="https://img.shields.io/badge/systems-Linux%20%7C%20FreeBSD%20%7C%20macOS%20%7C%20Windows-2ea043" />
  <img alt="Linux Architectures" src="https://img.shields.io/badge/Linux%20arch-11%20targets-0969da" />
  <img alt="Release Assets" src="https://img.shields.io/badge/release%20assets-20%20binaries-8250df" />
  <img alt="Distro Matrix" src="https://img.shields.io/badge/distro%20matrix-Debian%2FUbuntu%2FKali%2FRedHat%2FOpenWrt%2FRPiOS%2FSynology-1f883d" />
  <img alt="Security" src="https://img.shields.io/badge/security-SHA256SUMS%20%2B%20rollback-a371f7" />
  <img alt="Zig" src="https://img.shields.io/badge/Zig-0.16.0-f7a41d?logo=zig&logoColor=white" />
</p>

这些 SVG 徽章由 GitHub Actions 与 Shields.io 按仓库实时状态生成；构建、覆盖率门禁、Release、下载量、Star、Issue 会随仓库变化自动更新。

## 状态

- 功能兼容：官方 Go agent `1.2.60` 的启动参数、配置来源、BasicInfo、Report WebSocket、任务执行、Ping、Web SSH、自动发现、代理、自定义 DNS/IP、自更新、安装和替换脚本均已实现；继续保留可选 Cloudflare Access 凭据支持。
- 上游增量：已吸收 `Snapshot-2607270914` 的非 root systemd user 安装和 Windows NVIDIA 详细 GPU 指标，并继续支持更早加入的 Linux `loong64` 构建与安装。
- 支持系统：Linux、FreeBSD、macOS、Windows；Linux 覆盖 Debian/Ubuntu/Kali、Fedora/CentOS Stream/Rocky/Alma、OpenWrt、Raspberry Pi OS profile、Synology DSM profile。
- Release 资产：自动构建 20 个二进制，其中 Linux 11 架构：`amd64`、`arm64`、`386`、`arm`、`mips`、`mipsel`、`mips64`、`mips64el`、`riscv64`、`s390x`、`loong64`。
- 自动化测试：Ubuntu、macOS、Windows 原生单测；Debian/Ubuntu/Kali 和红帽系容器单测；FreeBSD VM 单测；OpenWrt、Raspberry Pi OS、Synology DSM profile 与主流 Linux 发行版 agent 启动烟测；Linux 多架构 QEMU agent 启动烟测。
- 测试覆盖率：GitHub Actions 使用 kcov 强制 `100.00%` 行覆盖率门槛。
- 安全情况：Release 产物生成 `SHA256SUMS`；安装、替换、纯二进制更新、自更新均校验下载内容；下载、校验或预检失败不会覆盖原二进制；CI 使用固定版本 Zig 与固定哈希下载，主要 GitHub actions 固定到提交 SHA。
- 功能兼容：100% 全部实现；旧 checklist 已移除，后续以 CI 与 Release 验收为准。
- Zig：0.16.0。
- 服务端原项目：`komari-monitor/komari`，仓库地址 <https://github.com/komari-monitor/komari>。
- Agent 兼容目标：`komari-monitor/komari-agent` 协议，原 Agent 仓库 <https://github.com/komari-monitor/komari-agent>。
- 发布仓库：`luodaoyi/komari-zig-agent`。
- 自更新：检查本仓库 GitHub Release，不再下载原 Go 仓库版本。

## 相较官方 Go Agent 的优势

- 更省资源：linux-amd64 二进制约小 12 倍；常驻 RSS 实测约 1.2 MB，适合小内存 VPS、OpenWrt、ARM/MIPS 设备。
- 更快上报：Linux 热路径主要读 `/proc` 与原生 syscall；FreeBSD/macOS 已去除采样中的固定 1 秒阻塞；上报间隔不再被采样等待拖长。
- 更稳运行：WebSocket 写入加锁并分块 mask；服务端任务设并发上限，避免 ping、exec、terminal 任务过多压垮 agent。
- 更安全更新：安装、替换、纯二进制更新、自更新均校验 SHA256；自更新流式落盘后校验，失败不覆盖原二进制；替换失败可回滚。
- 更适合国内网络：安装、替换、纯二进制更新、自更新支持 GitHub 代理池，可显式指定代理，减少国内机器拉取失败。
- 更广兼容：保持官方 Go agent 参数和 Komari 协议兼容，同时发布 Linux 11 架构及 Windows、FreeBSD、macOS 资产。
- 更严测试：CI 覆盖多发行版、多架构、FreeBSD、OpenWrt/RPiOS/Synology profile，单测覆盖率门禁为 `100.00%`。
- 更低运维风险：Release 产物有 `SHA256SUMS`，CI 固定 Zig 版本与下载哈希，脚本先预检二进制再替换服务。

## 性能对比

测试环境：

- 系统：Debian Linux 6.1 x86_64。
- Go 版：官方 `komari-monitor/komari-agent` 1.2.13，linux-amd64。
- Zig 版：本仓库 ReleaseSmall，linux-amd64。
- 两者使用同一 Komari 配置。Go 版测试时关闭自更新，避免测试过程中切换版本。

| 指标 | 原 Go agent | Zig agent | 结果 |
| --- | ---: | ---: | --- |
| linux-amd64 二进制大小 | 8,585,378 B | 702,488 B | Zig 约小 12.2 倍 |
| 常驻 RSS | 17,828 KB | 约 1,196 KB | Zig 约低 93% |
| systemd 当前内存记账 | 未记录 | 约 644 KB | 低于 1 MB |
| 私有脏页 | 未记录 | 约 504 KB | 堆与可写私有页很低 |
| 线程数 | 9 | 4 | Zig 更少 |
| CPU | 约 0.6% | 约 0.1% | Zig 更低 |

结论：

- Zig 版 `ps` RSS 已约 1.2 MB；systemd 当前内存记账低于 1 MB。
- CPU 没有靠降低上报频率换取；采样等待、WebSocket 上报节奏和协议字段保持不变。
- 上报 JSON、月流量采样、`/proc` 热路径已尽量改为栈缓冲，减少重复堆申请。
- 二进制体积明显小，适合 OpenWrt、小内存 VPS、低端 ARM/MIPS 设备。

## 一键替换原 Go Agent

已经装了官方 Go 版 `komari-agent`？直接执行下面一条命令即可替换为 Zig 版。原有的面板地址、Token、上报间隔和服务名都会保留，无需重新配置。

```sh
curl -fsSL https://raw.githubusercontent.com/luodaoyi/komari-zig-agent/main/replace.sh | sudo sh
```

国内网络无法访问 GitHub 时，使用 jsDelivr CDN：

```sh
curl -fsSL https://cdn.jsdelivr.net/gh/luodaoyi/komari-zig-agent@main/replace.sh | sudo sh
```

脚本会自动识别系统和 CPU 架构，下载匹配的 Release，校验 `SHA256SUMS`，备份原 Go Agent，替换后重启原服务。下载、校验或启动失败时不会覆盖正在使用的 Agent；systemd 启动失败会自动回滚。

> 适用于 Linux、OpenWrt、FreeBSD 和 macOS 的已有 Go Agent 安装。Windows、首次安装、指定版本或自定义路径等高级场景，请查看脚本参数或 GitHub Release。

## 自更新

Agent 启动后会检查：

```text
https://api.github.com/repos/luodaoyi/komari-zig-agent/releases/latest
```

若发现更高版本，会下载与当前平台匹配的资产，例如：

```text
komari-agent-linux-amd64
komari-agent-linux-arm64
komari-agent-linux-386
komari-agent-linux-arm
komari-agent-linux-mips
komari-agent-linux-mipsel
komari-agent-linux-mips64
komari-agent-linux-mips64el
komari-agent-linux-riscv64
komari-agent-linux-s390x
komari-agent-linux-loong64
komari-agent-freebsd-amd64
komari-agent-freebsd-arm64
komari-agent-freebsd-386
komari-agent-freebsd-arm
komari-agent-darwin-amd64
komari-agent-darwin-arm64
komari-agent-windows-amd64.exe
komari-agent-windows-arm64.exe
komari-agent-windows-386.exe
```

自更新同样优先直连 GitHub；Release API、二进制资产、`SHA256SUMS` 任一步直连失败，都会按内置代理池回退。可用 `KOMARI_GITHUB_PROXIES` 覆盖代理池，多个代理可用空格、逗号或分号分隔：

```sh
KOMARI_GITHUB_PROXIES="https://gh.llkk.cc https://gh-proxy.com https://ghproxy.net"
```

下载完成后会校验 GitHub Release API 的 `digest`；若 API 未返回 digest，则使用同 Release 的 `SHA256SUMS`。校验失败不会替换本机二进制。

可用参数关闭自更新：

```sh
--disable-auto-update
```

## 构建

本机构建：

```sh
zig build -Doptimize=ReleaseSmall -Dversion=dev
```

构建指定平台：

```sh
zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSmall -Dversion=v0.1.6
```

全平台构建：

```sh
./build_all.sh
```

Windows PowerShell：

```powershell
.\build_all.ps1
```

## 注释与文档

生产源码的注释覆盖率已纳入仓库门槛，统计范围为 `src/**/*.zig`，排除 `*_test.zig`，要求至少 `80%` 的源码文件带有 Zig 文档注释 `//!` 或 `///`。细则见 `docs/code-comments.md`。

本地可直接执行：

```sh
python3 scripts/check_comment_coverage.py src 80
```

## Release CI/CD

自动发布有两种方式：

1. 推送 tag：

```sh
git tag -a v0.1.6 -m "Release v0.1.6"
git push origin v0.1.6
```

2. GitHub Actions 手动发布：

```text
Actions -> Release -> Run workflow -> 输入 v0.1.6 或 0.1.6
```

Action 会自动：

- 规范化 tag 为 `vX.Y.Z`。
- 手动触发时创建并推送 tag。
- 编译 Linux 11 架构、FreeBSD、macOS、Windows 多平台二进制。
- 创建 GitHub Release。
- 上传所有 Release 资产。
- 生成并上传 `SHA256SUMS`，供安装脚本、替换脚本和 Agent 自更新校验下载内容。

## Star History

<a href="https://www.star-history.com/?repos=luodaoyi%2Fkomari-zig-agent&type=date&legend=top-left">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=luodaoyi/komari-zig-agent&type=date&theme=dark&legend=top-left" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=luodaoyi/komari-zig-agent&type=date&legend=top-left" />
   <img alt="Star History Chart" src="https://api.star-history.com/chart?repos=luodaoyi/komari-zig-agent&type=date&legend=top-left" />
 </picture>
</a>

## 验证

```sh
zig build test
zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSmall
zig build -Dtarget=s390x-linux-musl -Doptimize=ReleaseSmall
zig build -Dtarget=loongarch64-linux-musl -Doptimize=ReleaseSmall
zig build -Dtarget=x86_64-freebsd -Doptimize=ReleaseSmall
zig build -Dtarget=aarch64-macos -Doptimize=ReleaseSmall
```
