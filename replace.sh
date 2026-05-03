#!/bin/sh
set -eu

repo="luodaoyi/komari-zig-agent"
service_name="komari-agent"
install_version=""
github_proxy=""
github_proxy_list="${KOMARI_GITHUB_PROXIES:-https://gh.llkk.cc https://gh-proxy.com https://ghproxy.net https://ghfast.top https://ghproxy.cc}"
binary_path=""
install_dir="/opt/komari"
tmp=""
backup=""

log() { printf '%s\n' "$*"; }
err() { printf 'ERROR: %s\n' "$*" >&2; }
die() { err "$*"; exit 1; }

cleanup() {
  if [ -n "$tmp" ] && [ -f "$tmp" ]; then
    rm -f "$tmp"
  fi
  return 0
}
trap cleanup EXIT HUP INT TERM

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo) repo="$2"; shift 2 ;;
    --version) install_version="$2"; shift 2 ;;
    --ghproxy) github_proxy="$2"; shift 2 ;;
    --service|--install-service-name) service_name="$2"; shift 2 ;;
    --binary) binary_path="$2"; shift 2 ;;
    --install-dir) install_dir="$2"; shift 2 ;;
    *) err "unknown argument: $1"; exit 1 ;;
  esac
done

if [ "$(id -u)" != "0" ]; then
  die "please run as root"
fi

os_name="$(uname -s)"
case "$os_name" in
  Linux) os_name="linux" ;;
  *) die "this replacement script supports Linux/OpenWrt only" ;;
esac

machine="$(uname -m)"
case "$machine" in
  x86_64|amd64) arch="amd64" ;;
  i386|i486|i586|i686) arch="386" ;;
  aarch64|arm64) arch="arm64" ;;
  armv5*|armv6*|armv7*|arm*) arch="arm" ;;
  mips) arch="mips" ;;
  mipsel) arch="mipsel" ;;
  mips64) arch="mips64" ;;
  mips64el) arch="mips64el" ;;
  riscv64) arch="riscv64" ;;
  s390x) arch="s390x" ;;
  loongarch64|loong64) arch="loong64" ;;
  *) die "unsupported architecture: $machine" ;;
esac

download() {
  dl_url="$1"
  dl_out="$2"
  dl_attempt=1
  dl_max_attempts=3
  if command -v curl >/dev/null 2>&1; then
    while [ "$dl_attempt" -le "$dl_max_attempts" ]; do
      curl -fL --connect-timeout 20 -o "$dl_out" "$dl_url" && return 0
      rm -f "$dl_out"
      log "download failed, retry ${dl_attempt}/${dl_max_attempts}"
      dl_attempt=$((dl_attempt + 1))
      sleep 2
    done
    return 1
  elif command -v wget >/dev/null 2>&1; then
    while [ "$dl_attempt" -le "$dl_max_attempts" ]; do
      wget -O "$dl_out" "$dl_url" && return 0
      rm -f "$dl_out"
      log "download failed, retry ${dl_attempt}/${dl_max_attempts}"
      dl_attempt=$((dl_attempt + 1))
      sleep 2
    done
    return 1
  else
    die "curl or wget is required"
  fi
}

proxy_url() {
  proxy="$1"
  url="$2"
  printf '%s/%s\n' "${proxy%/}" "$url"
}

probe_url() {
  url="$1"
  command -v curl >/dev/null 2>&1 || return 1
  curl -fIL --connect-timeout 5 --max-time 12 -o /dev/null -w '%{time_total}' "$url" 2>/dev/null || return 1
}

time_less_than() {
  command -v awk >/dev/null 2>&1 || return 1
  awk "BEGIN { exit !($1 < $2) }"
}

github_proxy_items() {
  printf '%s\n' "$github_proxy_list" | tr ',;' '  '
}

select_fastest_proxy_url() {
  base_url="$1"
  best_proxy=""
  best_time=""
  for proxy in $(github_proxy_items); do
    candidate="$(proxy_url "$proxy" "$base_url")"
    elapsed="$(probe_url "$candidate" || true)"
    [ -n "$elapsed" ] || continue
    log "proxy probe: ${proxy} ${elapsed}s" >&2
    if [ -z "$best_time" ] || time_less_than "$elapsed" "$best_time"; then
      best_time="$elapsed"
      best_proxy="$proxy"
    fi
  done
  [ -n "$best_proxy" ] || return 1
  printf '%s\n' "$best_proxy"
}

try_download_binary() {
  tdb_url="$1"
  tdb_sums_url="$2"
  tdb_out="$3"
  tdb_sums_fallback_url="${4:-}"
  tdb_sums_out="${tdb_out}.sha256.$$"
  rm -f "$tdb_sums_out"
  log "download: ${tdb_url}"
  download "$tdb_url" "$tdb_out" || { rm -f "$tdb_sums_out"; return 1; }
  if ! download "$tdb_sums_url" "$tdb_sums_out"; then
    if [ -n "$tdb_sums_fallback_url" ]; then
      download "$tdb_sums_fallback_url" "$tdb_sums_out" || { rm -f "$tdb_out" "$tdb_sums_out"; return 1; }
    else
      rm -f "$tdb_out" "$tdb_sums_out"
      return 1
    fi
  fi
  verify_sha256sum "$tdb_out" "$tdb_sums_out" || {
    rm -f "$tdb_out" "$tdb_sums_out"
    log "downloaded file failed SHA256 verification"
    return 1
  }
  rm -f "$tdb_sums_out"
  chmod 0755 "$tdb_out"
  "$tdb_out" --show-warning >/dev/null 2>&1 && return 0
  rm -f "$tdb_out"
  log "downloaded file failed binary preflight"
  return 1
}

sha256_file() {
  file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" | awk '{print $1}'
  elif command -v sha256 >/dev/null 2>&1; then
    sha256 -q "$file"
  else
    err "sha256sum, shasum, or sha256 is required"
    return 1
  fi
}

verify_sha256sum() {
  file="$1"
  sums="$2"
  expected="$(awk -v name="$asset" '($2 == name || $2 == "*" name) { print $1; exit }' "$sums")"
  [ -n "$expected" ] || return 1
  actual="$(sha256_file "$file")" || return 1
  [ "$expected" = "$actual" ]
}

download_binary_with_fallback() {
  db_base_url="$1"
  db_sums_url="$2"
  db_out="$3"
  if [ -n "$github_proxy" ]; then
    try_download_binary "$(proxy_url "$github_proxy" "$db_base_url")" "$db_sums_url" "$db_out" "$(proxy_url "$github_proxy" "$db_sums_url")"
    return
  fi

  try_download_binary "$db_base_url" "$db_sums_url" "$db_out" && return 0
  log "direct GitHub download failed, probing GitHub proxy mirrors"

  db_fastest_proxy="$(select_fastest_proxy_url "$db_base_url" || true)"
  if [ -n "$db_fastest_proxy" ]; then
    try_download_binary "$(proxy_url "$db_fastest_proxy" "$db_base_url")" "$db_sums_url" "$db_out" "$(proxy_url "$db_fastest_proxy" "$db_sums_url")" && return 0
    log "fastest proxy failed, trying remaining proxy mirrors"
  fi

  for proxy in $(github_proxy_items); do
    [ "$proxy" = "$db_fastest_proxy" ] && continue
    try_download_binary "$(proxy_url "$proxy" "$db_base_url")" "$db_sums_url" "$db_out" "$(proxy_url "$proxy" "$db_sums_url")" && return 0
  done
  return 1
}

parse_exec_binary() {
  # shellcheck disable=SC2086
  set -- $1
  while [ "$#" -gt 0 ]; do
    word="$1"
    shift
    word="$(printf '%s' "$word" | sed 's/^[-+!@]*//')"
    case "$word" in
      ""|env|*/env|*=*) continue ;;
      *) printf '%s\n' "$word"; return 0 ;;
    esac
  done
  return 1
}

has_systemd_service() {
  command -v systemctl >/dev/null 2>&1 || return 1
  systemctl cat "${service_name}.service" >/dev/null 2>&1
}

find_systemd_binary() {
  has_systemd_service || return 1
  unit="${service_name}.service"
  line="$(systemctl cat "$unit" 2>/dev/null | sed -n 's/^[[:space:]]*ExecStart=[[:space:]]*//p' | sed '/^$/d' | tail -n 1)"
  [ -n "$line" ] || return 1
  parse_exec_binary "$line"
}

find_initd_binary() {
  script="/etc/init.d/${service_name}"
  [ -f "$script" ] || return 1
  value="$(sed -n 's/.*PROG="\([^"]*\)".*/\1/p; s/.*command="\([^"]*\)".*/\1/p; s/.*procname="\([^"]*\)".*/\1/p' "$script" | head -n 1)"
  if [ -z "$value" ]; then
    value="$(grep -Eo '/[^" ]*/(agent|komari-agent)' "$script" 2>/dev/null | head -n 1 || true)"
  fi
  [ -n "$value" ] || return 1
  printf '%s\n' "$value"
}

find_binary() {
  if [ -n "$binary_path" ]; then
    printf '%s\n' "$binary_path"
    return
  fi
  find_systemd_binary && return
  find_initd_binary && return
  if command -v komari-agent >/dev/null 2>&1; then command -v komari-agent; return; fi
  if command -v agent >/dev/null 2>&1; then command -v agent; return; fi
  printf '%s\n' "${install_dir}/agent"
}

stop_service() {
  if has_systemd_service; then
    systemctl stop "${service_name}.service" 2>/dev/null || true
    return
  fi
  if [ -x "/etc/init.d/${service_name}" ]; then
    "/etc/init.d/${service_name}" stop 2>/dev/null || true
    return
  fi
  if command -v service >/dev/null 2>&1; then
    service "$service_name" stop 2>/dev/null || true
  fi
}

start_service() {
  if has_systemd_service; then
    systemctl restart "${service_name}.service"
    return
  fi
  if [ -x "/etc/init.d/${service_name}" ]; then
    "/etc/init.d/${service_name}" enable 2>/dev/null || true
    "/etc/init.d/${service_name}" restart 2>/dev/null || "/etc/init.d/${service_name}" start
    return
  fi
  if command -v service >/dev/null 2>&1; then
    service "$service_name" start 2>/dev/null || return 1
  fi
}

service_healthy() {
  if has_systemd_service; then
    systemctl is-active --quiet "${service_name}.service"
    return
  fi
  if [ -x "/etc/init.d/${service_name}" ]; then
    "/etc/init.d/${service_name}" status >/dev/null 2>&1 || return 0
  fi
  return 0
}

rollback() {
  reason="$1"
  err "$reason"
  if [ -n "$backup" ] && [ -f "$backup" ]; then
    log "restoring backup: ${backup}"
    cp "$backup" "$target"
    chmod 0755 "$target"
    start_service >/dev/null 2>&1 || true
  fi
  exit 1
}

asset="komari-agent-${os_name}-${arch}"
if [ -n "$install_version" ]; then
  release_path="download/${install_version}"
else
  release_path="latest/download"
fi
url="https://github.com/${repo}/releases/${release_path}/${asset}"
checksums_url="https://github.com/${repo}/releases/${release_path}/SHA256SUMS"

target="$(find_binary)"
target_dir="$(dirname "$target")"
tmp="${target}.zig-new.$$"
backup="${target}.go-backup.$(date +%Y%m%d%H%M%S)"

log "repo: ${repo}"
log "asset: ${asset}"
log "target: ${target}"

mkdir -p "$target_dir"
download_binary_with_fallback "$url" "$checksums_url" "$tmp" || die "failed to download release asset"

stop_service
if [ -f "$target" ]; then
  cp "$target" "$backup"
  log "backup: ${backup}"
fi
mv "$tmp" "$target"
chmod 0755 "$target"
if ! start_service; then
  rollback "service failed to start after replacement"
fi
sleep 2
if ! service_healthy; then
  rollback "service is not healthy after replacement"
fi

log "replacement completed"
