#!/bin/sh
set -eu

repo="luodaoyi/komari-zig-agent"
service_name="komari-agent"
install_version=""
github_proxy=""
binary_path=""
install_dir="/opt/komari"

log() { printf '%s\n' "$*"; }
err() { printf 'ERROR: %s\n' "$*" >&2; }

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
  err "please run as root"
  exit 1
fi

os_name="$(uname -s)"
case "$os_name" in
  Linux) os_name="linux" ;;
  *) err "this replacement script supports Linux/OpenWrt only"; exit 1 ;;
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
  *) err "unsupported architecture: $machine"; exit 1 ;;
esac

download() {
  url="$1"
  out="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fL --connect-timeout 20 -o "$out" "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget -O "$out" "$url"
  else
    err "curl or wget is required"
    exit 1
  fi
}

first_word() {
  printf '%s\n' "$1" | sed 's/^[[:space:]]*//;s/[[:space:]].*$//'
}

find_systemd_binary() {
  command -v systemctl >/dev/null 2>&1 || return 1
  unit="${service_name}.service"
  fragment="$(systemctl show -p FragmentPath --value "$unit" 2>/dev/null || true)"
  [ -n "$fragment" ] && [ -f "$fragment" ] || return 1
  line="$(sed -n 's/^[[:space:]]*ExecStart=[[:space:]]*//p' "$fragment" | head -n 1)"
  [ -n "$line" ] || return 1
  first_word "$line"
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
  if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files 2>/dev/null | grep -q "^${service_name}.service"; then
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
  if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files 2>/dev/null | grep -q "^${service_name}.service"; then
    systemctl restart "${service_name}.service"
    return
  fi
  if [ -x "/etc/init.d/${service_name}" ]; then
    "/etc/init.d/${service_name}" enable 2>/dev/null || true
    "/etc/init.d/${service_name}" restart 2>/dev/null || {
      "/etc/init.d/${service_name}" start 2>/dev/null || true
    }
    return
  fi
  if command -v service >/dev/null 2>&1; then
    service "$service_name" start 2>/dev/null || true
  fi
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
download "$url" "$tmp"
chmod 0755 "$tmp"

stop_service
if [ -f "$target" ]; then
  cp "$target" "$backup"
  log "backup: ${backup}"
fi
mv "$tmp" "$target"
chmod 0755 "$target"
start_service

log "replacement completed"
