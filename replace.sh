#!/bin/sh
set -eu

repo="luodaoyi/komari-zig-agent"
service_name="komari-agent"
install_version=""
github_proxy=""
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
  riscv64) arch="riscv64" ;;
  *) die "unsupported architecture: $machine" ;;
esac

download() {
  url="$1"
  out="$2"
  attempt=1
  max_attempts=3
  if command -v curl >/dev/null 2>&1; then
    while [ "$attempt" -le "$max_attempts" ]; do
      curl -fL --connect-timeout 20 -o "$out" "$url" && return 0
      rm -f "$out"
      log "download failed, retry ${attempt}/${max_attempts}"
      attempt=$((attempt + 1))
      sleep 2
    done
    return 1
  elif command -v wget >/dev/null 2>&1; then
    while [ "$attempt" -le "$max_attempts" ]; do
      wget -O "$out" "$url" && return 0
      rm -f "$out"
      log "download failed, retry ${attempt}/${max_attempts}"
      attempt=$((attempt + 1))
      sleep 2
    done
    return 1
  else
    die "curl or wget is required"
  fi
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
[ -n "$github_proxy" ] && url="${github_proxy}/${url}"

target="$(find_binary)"
target_dir="$(dirname "$target")"
tmp="${target}.zig-new.$$"
backup="${target}.go-backup.$(date +%Y%m%d%H%M%S)"

log "repo: ${repo}"
log "asset: ${asset}"
log "target: ${target}"
log "download: ${url}"

mkdir -p "$target_dir"
download "$url" "$tmp" || die "failed to download release asset"
chmod 0755 "$tmp"
"$tmp" --show-warning >/dev/null 2>&1 || die "downloaded binary cannot run on this system"

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
