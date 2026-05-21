# Issue #9 分析与回复草稿

Issue: [ImmortalWrt 24.10.6系统中agent经常崩溃 #9](https://github.com/luodaoyi/komari-zig-agent/issues/9)

## 结论

这个问题的直接原因不是 ARM、x86 或 ImmortalWrt 某个平台专属崩溃，而是 `basic info` 前台上报失败后，主流程把错误继续向上返回，导致进程退出并被 `procd` 反复拉起。

日志里的 `http.zig` 栈只是说明失败发生在基础信息上报的 HTTP POST 链路上，并不代表 `http.zig` 第 419 行本身有内存释放或平台相关崩溃。

## 根因

触发链路如下：

1. agent 启动后同步执行一次 `uploadBasicInfoOnce`
2. 如果 POST `/api/clients/uploadBasicInfo` 失败，错误会从 `basic_info.upload` 返回
3. 主流程对这次失败使用了致命 `try`
4. 进程退出后被 OpenWrt `procd` 判定为 crash loop 并持续重启

同样的问题也存在于 report websocket 退出后的前台回补上报路径。

## 为什么日志里会看到相同 HTTP 栈重复两遍

`basic_info.upload` 会先发送一次带 `kernel_version` 的完整 JSON；如果失败，会再发送一次 fallback JSON。两次都失败时，会在日志里看到非常接近的两段 HTTP 调用栈，这是当前代码行为，不是两个独立故障点。

## 修复内容

- 启动阶段的基础信息前台上报失败不再导致进程退出
- report websocket 退出后的前台回补上报失败不再导致进程退出
- 失败时保留明确日志，便于继续定位底层失败原因
- 增加回归测试，覆盖 `startup` 和 `websocket reconnect` 两条前台上报路径的容错策略

## 建议回复草稿

可以直接在 issue 里回复下面这段：

```text
看了你给的日志，这个问题已经基本定位了。

根因不是 ImmortalWrt / ARM / x86 某个平台专属崩溃，而是 agent 在前台上传 basic info 时如果 HTTP 请求失败，主流程会直接退出；OpenWrt 的 procd 又会把它立即拉起，所以就表现成“经常崩溃”和 crash loop。

日志里反复出现的 http.zig/basic_info.zig/main.zig 调用栈，说明失败点在基础信息上传链路。这里还有一个细节：basic info 上传本身会先发一次完整 JSON，失败后再发一次 fallback JSON，所以你看到的相似栈重复两次是符合当前实现的。

我这边已经按这个方向修复：
1. 启动阶段 basic info 上传失败不再带死 agent
2. websocket 断开后的前台回补上传失败也不再带死 agent
3. 补了回归测试，防止以后再把普通上传失败变成致命退出

后续如果还想继续追根因，建议再补一段不过滤的完整日志，因为你现在贴的是 `logread | grep -i komari`，很可能把真正的 HTTP/DNS/TLS/超时错误行过滤掉了。
```
