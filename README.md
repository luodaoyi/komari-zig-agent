# komari-zig-agent

Zig 版 `komari-agent`，目标是直接替换原 Go agent，并保持 Komari 现有协议、上报字段、任务、Ping、Web SSH、自更新等行为兼容。

## 状态

- 支持：Linux、FreeBSD、macOS。
- 暂不支持：Windows runtime。
- Zig：0.15.2。
- 兼容目标：`komari-monitor/komari-agent` 协议。
- 发布仓库：`luodaoyi/komari-zig-agent`。
- 自更新：检查本仓库 GitHub Release，不再下载原 Go 仓库版本。

## 性能对比

测试环境：

- 系统：Debian Linux 6.1 x86_64。
- Go 版：官方 `komari-monitor/komari-agent` 1.1.93，linux-amd64。
- Zig 版：本仓库 ReleaseSmall，linux-amd64。
- 两者使用同一 Komari 配置。Go 版测试时关闭自更新，避免测试过程中切换版本。

| 指标 | 原 Go agent | Zig agent | 结果 |
| --- | ---: | ---: | --- |
| linux-amd64 二进制大小 | 8,585,378 B | 748,256 B | Zig 约小 11.5 倍 |
| 常驻 RSS | 17,828 KB | 约 1,284-1,436 KB | Zig 约低 92% |
| 线程数 | 9 | 4 | Zig 更少 |
| CPU | 约 0.6% | 约 0.1-0.2% | Zig 更低 |

结论：

- Zig 版常驻内存已低于 3 MB 目标。
- CPU 没有靠降低上报频率换取；采样等待、WebSocket 上报节奏和协议字段保持不变。
- 二进制体积明显小，适合 OpenWrt、小内存 VPS、低端 ARM/MIPS 设备。

## 安装 Zig 版

最常用：

```sh
curl -fsSL https://raw.githubusercontent.com/luodaoyi/komari-zig-agent/main/install.sh | sh -s -- \
  --endpoint https://panel.example \
  --token TOKEN
```

没有 `curl` 时：

```sh
wget -O- https://raw.githubusercontent.com/luodaoyi/komari-zig-agent/main/install.sh | sh -s -- \
  --endpoint https://panel.example \
  --token TOKEN
```

指定版本：

```sh
curl -fsSL https://raw.githubusercontent.com/luodaoyi/komari-zig-agent/main/install.sh | sh -s -- \
  --install-version v0.1.0 \
  --endpoint https://panel.example \
  --token TOKEN
```

常用安装参数：

```text
--install-dir <dir>            安装目录，默认 Linux/FreeBSD 为 /opt/komari
--install-service-name <name>  服务名，默认 komari-agent
--install-ghproxy <url>        GitHub 下载代理
--install-version <tag>        指定 Release tag；不填则用 latest
```

脚本会自动识别 Linux、OpenWrt/procd、OpenRC、systemd、FreeBSD rc.d、macOS launchd，并创建服务。

## 一键替换原 Go agent

在已安装 Go 版 `komari-agent` 的机器上运行：

```sh
curl -fsSL https://raw.githubusercontent.com/luodaoyi/komari-zig-agent/main/replace.sh | sh
```

无 `curl`：

```sh
wget -O- https://raw.githubusercontent.com/luodaoyi/komari-zig-agent/main/replace.sh | sh
```

指定版本替换：

```sh
curl -fsSL https://raw.githubusercontent.com/luodaoyi/komari-zig-agent/main/replace.sh | sh -s -- --version v0.1.0
```

OpenWrt 或非标准路径可显式指定：

```sh
curl -fsSL https://raw.githubusercontent.com/luodaoyi/komari-zig-agent/main/replace.sh | sh -s -- \
  --service komari-agent \
  --binary /opt/komari/agent
```

替换脚本参数：

```text
--repo <owner/repo>      Release 仓库，默认 luodaoyi/komari-zig-agent
--version <tag>          指定版本；不填则用 latest
--ghproxy <url>          GitHub 下载代理
--service <name>         服务名，默认 komari-agent
--binary <path>          直接指定原 agent 二进制路径
--install-dir <dir>      找不到服务路径时的默认目录，默认 /opt/komari
```

替换行为：

- 自动识别 CPU 架构并下载对应 Release 资产。
- 停止原服务，备份原二进制为 `*.go-backup.<timestamp>`。
- 替换二进制并重启原服务。
- 不改 endpoint、token、上报间隔等业务参数。

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
```

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
zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSmall -Dversion=v0.1.0
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
git tag -a v0.1.0 -m "Release v0.1.0"
git push origin v0.1.0
```

2. GitHub Actions 手动发布：

```text
Actions -> Release -> Run workflow -> 输入 v0.1.0 或 0.1.0
```

Action 会自动：

- 规范化 tag 为 `vX.Y.Z`。
- 手动触发时创建并推送 tag。
- 编译 Linux、FreeBSD、macOS 多架构二进制。
- 创建 GitHub Release。
- 上传所有 Release 资产。

## 验证

```sh
zig build test
zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSmall
zig build -Dtarget=x86_64-freebsd -Doptimize=ReleaseSmall
zig build -Dtarget=aarch64-macos -Doptimize=ReleaseSmall
```
