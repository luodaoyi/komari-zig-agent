#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
BASE="${SCRIPT_TEST_BASE:-${HOME:-/tmp}/.komari-zig-script-tests.$$}"
PASS=0
FAIL=0

cleanup() {
  if [ -n "${TEST_SERVICES:-}" ]; then
    for svc in $TEST_SERVICES; do
      rm -f "/etc/systemd/system/${svc}.service"
    done
  fi
  if [ "${SCRIPT_TEST_KEEP:-0}" != 1 ]; then
    rm -rf "$BASE"
  fi
}
trap cleanup EXIT HUP INT TERM

ok() {
  PASS=$((PASS + 1))
  printf 'ok - %s\n' "$1"
}

not_ok() {
  FAIL=$((FAIL + 1))
  printf 'not ok - %s\n' "$1" >&2
}

assert_file_contains() {
  file="$1"
  text="$2"
  grep -F "$text" "$file" >/dev/null 2>&1
}

assert_file_not_contains() {
  file="$1"
  text="$2"
  ! grep -F "$text" "$file" >/dev/null 2>&1
}

setup_case() {
  CASE="$BASE/$1"
  FAKEBIN="$CASE/bin"
  INSTALL_DIR="$CASE/install"
  FIXTURES="$CASE/fixtures"
  LOG="$CASE/calls.log"
  SERVICE="komari-script-test-$1"
  ASSET="komari-agent-linux-amd64"
  mkdir -p "$FAKEBIN" "$INSTALL_DIR" "$FIXTURES"
  : > "$LOG"
  TEST_SERVICES="${TEST_SERVICES:-} $SERVICE"
  write_good_asset "$FIXTURES/$ASSET"
  sha256sum "$FIXTURES/$ASSET" | awk -v name="$ASSET" '{print $1 "  " name}' > "$FIXTURES/SHA256SUMS"
  write_fakes
}

write_good_asset() {
  file="$1"
  cat > "$file" <<'EOF'
#!/bin/sh
if [ "${1:-}" = "--show-warning" ]; then exit 0; fi
printf 'komari test agent\n'
exit 0
EOF
  chmod 0755 "$file"
}

write_bad_preflight_asset() {
  file="$1"
  cat > "$file" <<'EOF'
#!/bin/sh
if [ "${1:-}" = "--show-warning" ]; then exit 9; fi
exit 0
EOF
  chmod 0755 "$file"
  sha256sum "$file" | awk -v name="$ASSET" '{print $1 "  " name}' > "$FIXTURES/SHA256SUMS"
}

write_bad_checksum() {
  printf '%064d  %s\n' 0 "$ASSET" > "$FIXTURES/SHA256SUMS"
}

write_fakes() {
  cat > "$FAKEBIN/curl" <<'EOF'
#!/bin/sh
out=""
fmt=""
url=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -w) fmt="$2"; shift 2 ;;
    --connect-timeout|--max-time) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
printf 'curl %s\n' "$url" >> "$SCRIPT_TEST_LOG"
case "$out:$fmt" in
  /dev/null:*) printf '0.010'; exit 0 ;;
esac
case "$url" in
  *SHA256SUMS) is_sums=1 ;;
  *) is_sums=0 ;;
esac
case "$url" in
  https://github.com/*) is_direct=1 ;;
  *) is_direct=0 ;;
esac
if [ "${SCRIPT_TEST_DIRECT_BINARY_FAIL:-0}" = 1 ] && [ "$is_direct" = 1 ] && [ "$is_sums" = 0 ]; then
  exit 22
fi
if [ "${SCRIPT_TEST_DIRECT_SUMS_FAIL:-0}" = 1 ] && [ "$is_direct" = 1 ] && [ "$is_sums" = 1 ]; then
  exit 22
fi
if [ "$is_sums" = 1 ]; then
  cp "$SCRIPT_TEST_FIXTURES/SHA256SUMS" "$out"
else
  cp "$SCRIPT_TEST_FIXTURES/$SCRIPT_TEST_ASSET" "$out"
fi
exit 0
EOF
  chmod 0755 "$FAKEBIN/curl"

  cat > "$FAKEBIN/systemctl" <<'EOF'
#!/bin/sh
printf 'systemctl %s\n' "$*" >> "$SCRIPT_TEST_LOG"
case "${1:-}" in
  list-unit-files) exit 0 ;;
  list-units) exit 0 ;;
  cat)
    if [ "${SCRIPT_TEST_SYSTEMD_CAT:-0}" = 1 ]; then
      printf '[Service]\nExecStart=%s -e http://old -t old\n' "$SCRIPT_TEST_TARGET"
      exit 0
    fi
    exit 1
    ;;
  restart)
    [ "${SCRIPT_TEST_SYSTEMD_RESTART_FAIL:-0}" = 1 ] && exit 1
    exit 0
    ;;
  is-active)
    [ "${SCRIPT_TEST_HEALTH_FAIL:-0}" = 1 ] && exit 1
    exit 0
    ;;
  *) exit 0 ;;
esac
EOF
  chmod 0755 "$FAKEBIN/systemctl"

  cat > "$FAKEBIN/service" <<'EOF'
#!/bin/sh
printf 'service %s\n' "$*" >> "$SCRIPT_TEST_LOG"
case "${2:-}" in
  start|restart)
    [ "${SCRIPT_TEST_SERVICE_START_FAIL:-0}" = 1 ] && exit 1
    ;;
esac
exit 0
EOF
  chmod 0755 "$FAKEBIN/service"

  cat > "$FAKEBIN/ps" <<'EOF'
#!/bin/sh
if [ "$*" = "-p 1 -o comm=" ]; then
  printf 'systemd\n'
  exit 0
fi
exec /usr/bin/ps "$@"
EOF
  chmod 0755 "$FAKEBIN/ps"

  cat > "$FAKEBIN/uname" <<'EOF'
#!/bin/sh
case "${1:-}" in
  -s|"") printf 'Linux\n' ;;
  -m) printf 'x86_64\n' ;;
  *) exec /usr/bin/uname "$@" ;;
esac
EOF
  chmod 0755 "$FAKEBIN/uname"

  cat > "$FAKEBIN/id" <<'EOF'
#!/bin/sh
case "${1:-}" in
  -u) printf '0\n' ;;
  *) exec /usr/bin/id "$@" ;;
esac
EOF
  chmod 0755 "$FAKEBIN/id"

  cat > "$FAKEBIN/sleep" <<'EOF'
#!/bin/sh
exit 0
EOF
  chmod 0755 "$FAKEBIN/sleep"

  cat > "$FAKEBIN/date" <<'EOF'
#!/bin/sh
printf '20260502010101\n'
EOF
  chmod 0755 "$FAKEBIN/date"
}

run_env() {
  env -u EUID \
    SCRIPT_TEST_LOG="$LOG" \
    SCRIPT_TEST_FIXTURES="$FIXTURES" \
    SCRIPT_TEST_ASSET="$ASSET" \
    SCRIPT_TEST_DIRECT_BINARY_FAIL="${SCRIPT_TEST_DIRECT_BINARY_FAIL:-0}" \
    SCRIPT_TEST_DIRECT_SUMS_FAIL="${SCRIPT_TEST_DIRECT_SUMS_FAIL:-0}" \
    SCRIPT_TEST_SYSTEMD_CAT="${SCRIPT_TEST_SYSTEMD_CAT:-0}" \
    SCRIPT_TEST_TARGET="${SCRIPT_TEST_TARGET:-}" \
    SCRIPT_TEST_SYSTEMD_RESTART_FAIL="${SCRIPT_TEST_SYSTEMD_RESTART_FAIL:-0}" \
    SCRIPT_TEST_HEALTH_FAIL="${SCRIPT_TEST_HEALTH_FAIL:-0}" \
    SCRIPT_TEST_SERVICE_START_FAIL="${SCRIPT_TEST_SERVICE_START_FAIL:-0}" \
    PATH="$FAKEBIN:/usr/sbin:/usr/bin:/sbin:/bin" \
    "$@"
}

test_install_direct_success() {
  setup_case install_direct
  run_env sh "$ROOT/install.sh" --install-dir "$INSTALL_DIR" --install-service-name "$SERVICE" -e http://server -t token >/dev/null
  [ -x "$INSTALL_DIR/agent" ] &&
    assert_file_contains "/etc/systemd/system/${SERVICE}.service" "ExecStart=$INSTALL_DIR/agent -e http://server -t token" &&
    assert_file_contains "$LOG" "curl https://github.com/luodaoyi/komari-zig-agent/releases/latest/download/$ASSET" &&
    assert_file_not_contains "$LOG" "curl https://gh.llkk.cc/"
}

test_install_proxy_fallback_success() {
  setup_case install_proxy
  SCRIPT_TEST_DIRECT_BINARY_FAIL=1 run_env sh "$ROOT/install.sh" --install-dir "$INSTALL_DIR" --install-service-name "$SERVICE" -e http://server -t token >/dev/null
  [ -x "$INSTALL_DIR/agent" ] &&
    assert_file_contains "$LOG" "curl https://gh.llkk.cc/https://github.com/luodaoyi/komari-zig-agent/releases/latest/download/$ASSET"
}

test_install_explicit_proxy_success() {
  setup_case install_explicit_proxy
  run_env sh "$ROOT/install.sh" --install-dir "$INSTALL_DIR" --install-service-name "$SERVICE" --install-ghproxy https://proxy.local -e http://server -t token >/dev/null
  [ -x "$INSTALL_DIR/agent" ] &&
    assert_file_contains "$LOG" "curl https://proxy.local/https://github.com/luodaoyi/komari-zig-agent/releases/latest/download/$ASSET"
}

test_install_checksum_failure() {
  setup_case install_checksum_fail
  write_bad_checksum
  if run_env sh "$ROOT/install.sh" --install-dir "$INSTALL_DIR" --install-service-name "$SERVICE" -e http://server -t token >/dev/null 2>&1; then
    return 1
  fi
  [ ! -f "$INSTALL_DIR/agent" ]
}

test_install_preflight_failure() {
  setup_case install_preflight_fail
  write_bad_preflight_asset "$FIXTURES/$ASSET"
  if run_env sh "$ROOT/install.sh" --install-dir "$INSTALL_DIR" --install-service-name "$SERVICE" -e http://server -t token >/dev/null 2>&1; then
    return 1
  fi
  [ ! -f "$INSTALL_DIR/agent" ]
}

test_replace_direct_success() {
  setup_case replace_direct
  target="$INSTALL_DIR/agent"
  printf 'old-agent\n' > "$target"
  chmod 0755 "$target"
  run_env sh "$ROOT/replace.sh" --binary "$target" --service "$SERVICE" >/dev/null
  assert_file_contains "$target" "komari test agent" &&
    [ -f "$INSTALL_DIR/agent.go-backup.20260502010101" ]
}

test_replace_proxy_fallback_success() {
  setup_case replace_proxy
  target="$INSTALL_DIR/agent"
  printf 'old-agent\n' > "$target"
  chmod 0755 "$target"
  SCRIPT_TEST_DIRECT_BINARY_FAIL=1 run_env sh "$ROOT/replace.sh" --binary "$target" --service "$SERVICE" >/dev/null
  assert_file_contains "$target" "komari test agent" &&
    assert_file_contains "$LOG" "curl https://gh.llkk.cc/https://github.com/luodaoyi/komari-zig-agent/releases/latest/download/$ASSET"
}

test_replace_proxy_checksum_fallback_success() {
  setup_case replace_proxy_sums
  target="$INSTALL_DIR/agent"
  printf 'old-agent\n' > "$target"
  chmod 0755 "$target"
  SCRIPT_TEST_DIRECT_BINARY_FAIL=1 SCRIPT_TEST_DIRECT_SUMS_FAIL=1 run_env sh "$ROOT/replace.sh" --binary "$target" --service "$SERVICE" >/dev/null
  assert_file_contains "$target" "komari test agent" &&
    assert_file_contains "$LOG" "curl https://gh.llkk.cc/https://github.com/luodaoyi/komari-zig-agent/releases/latest/download/SHA256SUMS"
}

test_replace_checksum_failure_keeps_old() {
  setup_case replace_checksum_fail
  target="$INSTALL_DIR/agent"
  printf 'old-agent\n' > "$target"
  chmod 0755 "$target"
  write_bad_checksum
  if run_env sh "$ROOT/replace.sh" --binary "$target" --service "$SERVICE" >/dev/null 2>&1; then
    return 1
  fi
  assert_file_contains "$target" "old-agent" &&
    assert_file_not_contains "$target" "komari test agent"
}

test_replace_preflight_failure_keeps_old() {
  setup_case replace_preflight_fail
  target="$INSTALL_DIR/agent"
  printf 'old-agent\n' > "$target"
  chmod 0755 "$target"
  write_bad_preflight_asset "$FIXTURES/$ASSET"
  if run_env sh "$ROOT/replace.sh" --binary "$target" --service "$SERVICE" >/dev/null 2>&1; then
    return 1
  fi
  assert_file_contains "$target" "old-agent" &&
    assert_file_not_contains "$target" "komari test agent"
}

test_replace_start_failure_rolls_back() {
  setup_case replace_rollback
  target="$INSTALL_DIR/agent"
  printf 'old-agent\n' > "$target"
  chmod 0755 "$target"
  SCRIPT_TEST_SERVICE_START_FAIL=1 run_env sh "$ROOT/replace.sh" --binary "$target" --service "$SERVICE" >/dev/null 2>&1 || true
  assert_file_contains "$target" "old-agent" &&
    assert_file_not_contains "$target" "komari test agent"
}

test_replace_systemd_discovery() {
  setup_case replace_systemd_find
  target="$INSTALL_DIR/agent"
  printf 'old-agent\n' > "$target"
  chmod 0755 "$target"
  SCRIPT_TEST_TARGET="$target" SCRIPT_TEST_SYSTEMD_CAT=1 run_env sh "$ROOT/replace.sh" --service "$SERVICE" >/dev/null
  assert_file_contains "$target" "komari test agent" &&
    assert_file_contains "$LOG" "systemctl cat ${SERVICE}.service"
}

run_test() {
  name="$1"
  if "$name"; then
    ok "$name"
  else
    not_ok "$name"
  fi
}

mkdir -p "$BASE"

run_test test_install_direct_success
run_test test_install_proxy_fallback_success
run_test test_install_explicit_proxy_success
run_test test_install_checksum_failure
run_test test_install_preflight_failure
run_test test_replace_direct_success
run_test test_replace_proxy_fallback_success
run_test test_replace_proxy_checksum_fallback_success
run_test test_replace_checksum_failure_keeps_old
run_test test_replace_preflight_failure_keeps_old
run_test test_replace_start_failure_rolls_back
run_test test_replace_systemd_discovery

printf 'script tests: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
