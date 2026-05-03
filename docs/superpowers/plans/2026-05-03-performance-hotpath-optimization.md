# Komari Zig Agent Performance Hotpath Optimization Plan

> For agentic workers: implement one task at a time. Each task must pass local verification, deploy to `ccs2` by SSH, pass remote acceptance, then commit and push before moving to the next task. After all tasks are complete, stop and report status.

**Goal:** Remove avoidable report-loop latency and make HTTP response size limits enforce during reads, not after memory has already been consumed.

**Scope:**
- Fix the two sequential one-second sleeps in report snapshot collection.
- Fix report interval drift caused by compensating for those sleeps.
- Enforce HTTP response body limits while data is written.

**Non-goals:**
- Do not change Komari protocol fields.
- Do not change endpoint paths or token behavior.
- Do not refactor unrelated collectors.
- Do not alter install scripts in this plan.

**Baseline expectation:** before this plan, Linux report snapshot can spend about two seconds in sampling because `networkInfo()` and `cpuUsage()` both sleep for one second. With `--interval 1`, real report cadence is therefore longer than one second.

---

## Global Rules

- [ ] Work from a clean tree or record unrelated dirty files before starting.
- [ ] For every task, write or update tests before implementation where practical.
- [ ] Run `zig fmt` on touched Zig files.
- [ ] Run `zig build test` before every deployment.
- [ ] Deploy and verify on `ccs2` before every commit.
- [ ] Commit only the files touched by the current task.
- [ ] Push after each accepted commit.
- [ ] If deploy, service restart, or remote verification fails, stop and fix before committing.
- [ ] If merge conflict appears during Git operations, stop and ask the user.

Recommended per-task command shape:

```powershell
git status --short
zig fmt <touched-files>
zig build test
zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSmall -Dversion=dev
scp zig-out/bin/komari-agent ccs2:/tmp/komari-agent
ssh ccs2 'set -eu; sudo install -m 0755 /tmp/komari-agent /opt/komari/agent; sudo systemctl restart komari-agent.service; sleep 20; systemctl is-active komari-agent.service; journalctl -u komari-agent.service -n 80 --no-pager'
git add <task-files>
git commit -m "<message>"
git push
```

If the service binary path on `ccs2` differs, discover it first:

```powershell
ssh ccs2 'systemctl cat komari-agent.service | sed -n "s/^[[:space:]]*ExecStart=[[:space:]]*//p"'
```

---

## Task 1: Remove Blocking Sleep From Linux Network and CPU Sampling

**Files:**
- Modify: `src/platform/linux.zig`
- Test: `test/linux_basic_info_test.zig` or new focused test

**Intent:** report snapshot should read current counters and use the previous sample for rate/usage calculation. The report path must not sleep.

- [ ] Add pure helper tests for network rate calculation.
  - Current counters greater than previous counters produce per-second rates.
  - Counter reset or wrap produces zero rate.
  - Zero or invalid elapsed time produces zero rate.

- [ ] Add or keep tests for CPU usage delta using existing `cpuUsagePercent()`.

- [ ] Replace `networkInfo()` sleep behavior.
  - Read current `/proc/net/dev`.
  - Record current timestamp.
  - If no previous sample exists, store current and return zero `up/down` with current totals.
  - If previous sample exists, compute `up/down` from byte delta divided by elapsed time.
  - Preserve monthly totals behavior when `month_rotate != 0`.

- [ ] Replace `cpuUsage()` sleep behavior.
  - Read current `/proc/stat`.
  - If no previous sample exists, store current and return `0.001`.
  - If previous sample exists, compute usage from previous/current.

- [ ] Protect previous samples with a small mutex.
  - `report_ws` has reader/task threads; future calls should not race global samples.

- [ ] Local acceptance.

```powershell
zig fmt src/platform/linux.zig test/linux_basic_info_test.zig
zig build test
zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSmall -Dversion=dev
```

- [ ] Remote acceptance on `ccs2`.

```powershell
scp zig-out/bin/komari-agent ccs2:/tmp/komari-agent
ssh ccs2 'set -eu; sudo install -m 0755 /tmp/komari-agent /opt/komari/agent; sudo systemctl restart komari-agent.service; sleep 20; systemctl is-active komari-agent.service; journalctl -u komari-agent.service -n 80 --no-pager'
```

Expected:
- Service is `active`.
- No repeated `WebSocket write failed`.
- Report loop remains connected.
- Log cadence is visibly faster than the old two-second-plus snapshot path.

- [ ] Commit and push.

```powershell
git add src/platform/linux.zig test/linux_basic_info_test.zig
git commit -m "perf: remove blocking linux report sampling"
git push
```

---

## Task 2: Make Report Interval Deadline-Based

**Files:**
- Modify: `src/protocol/report_ws.zig`
- Test: `test/ws_message_test.zig` or new `test/report_interval_test.zig`
- Modify: `build.zig` if a new test file is added

**Intent:** `--interval 1` should mean roughly one report per second, not one second plus hidden sampling time.

- [ ] Add pure helper tests.
  - `interval <= 0` maps to `1000ms`.
  - `interval = 1` maps to `1000ms`.
  - `interval = 2.5` maps to `2500ms`.
  - Sleep budget clamps to zero when work takes longer than the interval.

- [ ] Replace `reportSleepSeconds()` with millisecond helpers.
  - Suggested helpers:
    - `reportIntervalMs(interval: f64) u64`
    - `remainingSleepMs(start_ms: i64, interval_ms: u64, now_ms: i64) u64`

- [ ] Update the report loop.
  - Capture loop start time before `writeReportOnce()`.
  - After write/update confirmation, sleep only the remaining interval budget.
  - Keep heartbeat calculation independent.

- [ ] Local acceptance.

```powershell
zig fmt src/protocol/report_ws.zig test/report_interval_test.zig build.zig
zig build test
zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSmall -Dversion=dev
```

- [ ] Remote acceptance on `ccs2`.

```powershell
scp zig-out/bin/komari-agent ccs2:/tmp/komari-agent
ssh ccs2 'set -eu; sudo install -m 0755 /tmp/komari-agent /opt/komari/agent; sudo systemctl restart komari-agent.service; sleep 30; systemctl is-active komari-agent.service; journalctl -u komari-agent.service -n 100 --no-pager'
```

Expected:
- Service is `active`.
- With default `--interval 1`, report cadence is near one second, allowing normal network jitter.
- Heartbeat still appears about every 30 seconds on long runs.

- [ ] Commit and push.

```powershell
git add src/protocol/report_ws.zig test/report_interval_test.zig build.zig
git commit -m "perf: make report interval deadline based"
git push
```

---

## Task 3: Enforce HTTP Response Limits While Reading

**Files:**
- Modify: `src/protocol/http.zig`
- Test: `test/http_test.zig`

**Intent:** a response larger than `max_response_body_bytes` must fail during body collection, before the allocator grows without bound.

- [ ] Add tests for bounded response writing.
  - Writing exactly the limit succeeds.
  - Writing more than the limit returns `error.HttpResponseTooLarge`.
  - Partial writes cannot leave an owned successful body above the limit.

- [ ] Add a bounded writer helper in `http.zig`.
  - It should wrap the allocating writer or owned buffer builder.
  - It should check `current_len + incoming_len` before accepting bytes.
  - It should return `error.HttpResponseTooLarge` immediately.

- [ ] Use the bounded writer in `postJsonReadAuth()`.
  - This covers normal POST response collection.

- [ ] Use the bounded writer in `getRead()`.
  - This covers release metadata and general GET response collection through `std.http.Client`.

- [ ] Keep raw HTTP parser checks.
  - `Content-Length` and chunked code already check limits.
  - Do not mix raw parser refactors into this task unless tests expose a real bug.

- [ ] Local acceptance.

```powershell
zig fmt src/protocol/http.zig test/http_test.zig
zig build test
zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSmall -Dversion=dev
```

- [ ] Remote acceptance on `ccs2`.

```powershell
scp zig-out/bin/komari-agent ccs2:/tmp/komari-agent
ssh ccs2 'set -eu; sudo install -m 0755 /tmp/komari-agent /opt/komari/agent; sudo systemctl restart komari-agent.service; sleep 20; systemctl is-active komari-agent.service; journalctl -u komari-agent.service -n 80 --no-pager'
```

Expected:
- Service is `active`.
- Basic info upload still succeeds.
- Report WebSocket still connects.
- Self-update check does not regress on ordinary GitHub API response sizes.

- [ ] Commit and push.

```powershell
git add src/protocol/http.zig test/http_test.zig
git commit -m "perf: bound http response allocation"
git push
```

---

## Final Verification

- [ ] Run full local verification.

```powershell
zig fmt --check build.zig src test
zig build test
zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSmall -Dversion=dev
```

- [ ] Run final `ccs2` soak.

```powershell
scp zig-out/bin/komari-agent ccs2:/tmp/komari-agent
ssh ccs2 'set -eu; sudo install -m 0755 /tmp/komari-agent /opt/komari/agent; sudo systemctl restart komari-agent.service; sleep 90; systemctl is-active komari-agent.service; journalctl -u komari-agent.service -n 160 --no-pager'
```

Expected:
- Service remains `active`.
- No crash, no fast reconnect loop.
- Basic info upload and report WebSocket remain normal.
- Report cadence reflects configured interval.

- [ ] Record final commit range and pushed branch.
- [ ] Stop. Do not start new optimization tasks without a new user instruction.
