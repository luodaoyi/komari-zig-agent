# komari-zig-agent

Zig 版 `komari-agent`，目标是直接替换原 Go agent，并保持 Komari 现有协议、上报字段、任务、Ping、Web SSH、自更新等行为兼容。

## 状态

- 支持：Linux、FreeBSD、macOS。
- Windows：Release 资产与 Go 版对齐构建；运行兼容仍需实机验证。
- Zig：0.15.2。
- 兼容目标：`komari-monitor/komari-agent` 协议。
- 发布仓库：`luodaoyi/komari-zig-agent`。
- 自更新：检查本仓库 GitHub Release，不再下载原 Go 仓库版本。

## 功能兼容 Checklist

对比基准：官方 Go agent `1.1.93`。目标是协议与功能 1:1 兼容；连接重试节奏不要求逐字一致，只要求业务行为、字段与接口兼容。

| 模块 | Go agent | Zig agent | 状态 |
| --- | --- | --- | --- |
| 启动参数 | `--endpoint`、`--token`、`--interval`、`--disable-auto-update`、`--disable-web-ssh` 等 | 同名参数、短参数、`--flag=value`、bool `--flag=true` 均支持 | [x] 已对齐 |
| 配置来源 | CLI、环境变量、JSON 配置 | CLI、环境变量、JSON 配置 | [x] 已对齐 |
| BasicInfo 协议 | `/api/clients/uploadBasicInfo?token=` | 相同接口、相同 JSON 字段 | [x] 已对齐 |
| BasicInfo 字段 | CPU 名称、核心数、架构、系统、内核、IPv4、IPv6、内存、Swap、硬盘、GPU、虚拟化、版本 | 字段名与类型保持一致，含缺省兼容 | [x] 已对齐 |
| 架构识别 | amd64、arm64、386、arm、mips、mipsel、riscv64 等 | Release 资产与自更新命名同 Go 版风格 | [x] 已对齐 |
| Linux 发行版识别 | `/etc/os-release`、OpenWrt、Android、Proxmox 等 | 已实现对应识别与回退 | [x] 已对齐 |
| CPU 采集 | 使用率、核心数、名称、负载 | `/proc`/系统接口采集，上报字段一致 | [x] 已对齐 |
| 内存采集 | RAM、Swap、可用内存模式 | RAM/Swap 与 Go 版 htop-like 口径对齐 | [x] 已对齐 |
| 硬盘采集 | 总量、已用量、挂载点过滤 | `df`/系统命令口径，支持 include mountpoint | [x] 已对齐 |
| 网卡采集 | 实时上下行、累计上下行 | 支持 include/exclude NIC 与累计流量 | [x] 已对齐 |
| 月流量统计 | netstatic、month rotate | 支持月流量采样、轮转、重置 | [x] 已对齐 |
| 连接数 | TCP、UDP 连接数 | Linux `/proc/net/*`，BSD/macOS 用系统命令 | [x] 已对齐 |
| 运行状态 | uptime、process、load1/load5/load15 | 字段与类型一致 | [x] 已对齐 |
| Report WebSocket | `/api/clients/report?token=` | 相同 WebSocket 路径与上报 JSON | [x] 已对齐 |
| 服务端消息分发 | terminal、exec、ping、request_id | 支持同类消息分发与回包 | [x] 已对齐 |
| Exec 任务 | shell 执行、退出码、结果上报 | `sh -c` 执行，结果接口一致 | [x] 已对齐 |
| Ping 任务 | ICMP、TCP、HTTP，含 IPv4/IPv6 | 三类 ping 均支持，失败返回兼容值 | [x] 已对齐 |
| Web SSH | PTY、resize、禁用提示 | Linux PTY，FreeBSD/macOS openpty，禁用提示兼容 | [x] 已对齐 |
| 自动发现 | register、保存 `auto-discovery.json`、复用 token | 注册请求/响应兼容，缓存损坏时自动重新注册 | [x] 已对齐 |
| Cloudflare Access | `CF-Access-Client-Id`、`CF-Access-Client-Secret` | HTTP/WS 请求均带同名头 | [x] 已对齐 |
| 代理环境变量 | `HTTP_PROXY`、`HTTPS_PROXY`、`ALL_PROXY`、`NO_PROXY` | HTTP/WS 均支持，HTTPS/WSS 支持 CONNECT，按 `NO_PROXY` 绕过代理 | [x] 已对齐 |
| 自定义 DNS | 解析 HTTP、WS、Ping 目标 | raw HTTP/WS 与 Ping 路径支持 custom DNS | [x] 已对齐 |
| 自定义 IP | custom IPv4/IPv6、从网卡取 IP | 上报 IP 覆盖与网卡取 IP 均支持 | [x] 已对齐 |
| 自更新 | 检查 GitHub Release，下载对应资产 | 检查本仓库 Release，支持 prerelease 到 stable，失败保留原二进制 | [x] 已对齐 |
| 更新回滚 | 更新失败可恢复 | pending state、backup、recover 逻辑已实现 | [x] 已对齐 |
| 安装脚本 | Linux 服务安装 | 支持 systemd、OpenRC、OpenWrt/procd、FreeBSD rc.d、macOS launchd | [x] 已对齐并扩展 |
| 替换脚本 | 替换原 agent | 自动探测服务和二进制，备份、试运行、失败回滚 | [x] 已对齐并扩展 |
| CI/CD | 多平台 Release 资产 | GitHub Actions 手动/Tag 发布，自动上传 Release | [x] 已对齐并扩展 |

实机验证状态：

- Linux amd64、Linux arm64：已部署测试。
- FreeBSD/macOS：已通过交叉编译；运行路径已实现，仍建议在实机继续观察 PTY、网卡、磁盘采集细节。
- Windows：Release 资产保留；不作为当前优先运行目标。

## 性能对比

测试环境：

- 系统：Debian Linux 6.1 x86_64。
- Go 版：官方 `komari-monitor/komari-agent` 1.1.93，linux-amd64。
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

## 安装 Zig 版

最常用：

```sh
curl -fsSL https://raw.githubusercontent.com/luodaoyi/komari-zig-agent/main/install.sh | sudo sh -s -- \
  --endpoint https://panel.example \
  --token TOKEN
```

没有 `curl` 时：

```sh
wget -O- https://raw.githubusercontent.com/luodaoyi/komari-zig-agent/main/install.sh | sudo sh -s -- \
  --endpoint https://panel.example \
  --token TOKEN
```

指定版本：

```sh
curl -fsSL https://raw.githubusercontent.com/luodaoyi/komari-zig-agent/main/install.sh | sudo sh -s -- \
  --install-version v0.1.6 \
  --endpoint https://panel.example \
  --token TOKEN
```

常用安装参数：

```text
--install-dir <dir>            安装目录，默认 Linux/FreeBSD 为 /opt/komari
--install-service-name <name>  服务名，默认 komari-agent
--install-ghproxy <url>        指定 GitHub 下载代理；不指定时直连失败会自动测速代理池
--install-version <tag>        指定 Release tag；不填则用 latest
```

脚本会自动识别 Linux、OpenWrt/procd、OpenRC、systemd、FreeBSD rc.d、macOS launchd，并创建服务。

## 一键替换原 Go agent

在已安装 Go 版 `komari-agent` 的机器上运行：

```sh
curl -fsSL https://raw.githubusercontent.com/luodaoyi/komari-zig-agent/main/replace.sh | sudo sh
```

无 `curl`：

```sh
wget -O- https://raw.githubusercontent.com/luodaoyi/komari-zig-agent/main/replace.sh | sudo sh
```

指定版本替换：

```sh
curl -fsSL https://raw.githubusercontent.com/luodaoyi/komari-zig-agent/main/replace.sh | sudo sh -s -- --version v0.1.6
```

OpenWrt 或非标准路径可显式指定：

```sh
curl -fsSL https://raw.githubusercontent.com/luodaoyi/komari-zig-agent/main/replace.sh | sudo sh -s -- \
  --service komari-agent \
  --binary /opt/komari/agent
```

替换脚本参数：

```text
--repo <owner/repo>      Release 仓库，默认 luodaoyi/komari-zig-agent
--version <tag>          指定版本；不填则用 latest
--ghproxy <url>          指定 GitHub 下载代理；不指定时直连失败会自动测速代理池
--service <name>         服务名，默认 komari-agent
--binary <path>          直接指定原 agent 二进制路径
--install-dir <dir>      找不到服务路径时的默认目录，默认 /opt/komari
```

替换行为：

- 自动识别 CPU 架构并下载对应 Release 资产。
- 下载优先直连 GitHub；直连失败后自动测速多个 GitHub 代理并选择可用源。
- 下载失败会重试；下载后会先试运行二进制，避免把错误架构或错误页面写入服务。
- 停止原服务，备份原二进制为 `*.go-backup.<timestamp>`。
- 替换二进制并重启原服务；systemd 服务启动失败会自动回滚到备份。
- 不改 endpoint、token、上报间隔等业务参数。

自动代理池可通过环境变量覆盖：

```sh
curl -fsSL https://raw.githubusercontent.com/luodaoyi/komari-zig-agent/main/replace.sh | \
  sudo env KOMARI_GITHUB_PROXIES="https://gh.llkk.cc https://gh-proxy.com https://ghproxy.net" sh
```

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
komari-agent-linux-riscv64
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

自更新同样优先直连 GitHub；直连失败后按内置代理池回退。可用 `KOMARI_GITHUB_PROXIES` 覆盖代理池。

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
- 编译 Linux、FreeBSD、macOS 多架构二进制。
- 创建 GitHub Release。
- 上传所有 Release 资产。

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
zig build -Dtarget=x86_64-freebsd -Doptimize=ReleaseSmall
zig build -Dtarget=aarch64-macos -Doptimize=ReleaseSmall
```
