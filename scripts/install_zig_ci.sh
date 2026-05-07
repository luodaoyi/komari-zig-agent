#!/bin/sh
set -eu

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
  echo "usage: $0 <archive-name> <sha256> [source-name]" >&2
  exit 1
fi

archive_name="$1"
expected_sha="$2"
source_name="${3:-github-komari-zig-agent-ci}"
mirror_list_url="${ZIG_MIRROR_LIST_URL:-https://ziglang.org/download/community-mirrors.txt}"
download_connect_timeout="${ZIG_DOWNLOAD_CONNECT_TIMEOUT:-8}"
download_max_time="${ZIG_DOWNLOAD_MAX_TIME:-120}"
download_retry_count="${ZIG_DOWNLOAD_RETRY_COUNT:-2}"
official_url=""

if [ -n "${ZIG_VERSION:-}" ]; then
  official_url="https://ziglang.org/download/${ZIG_VERSION}/${archive_name}"
fi

fallback_mirrors='https://pkg.hexops.org/zig
https://zigmirror.hryx.net/zig
https://zig.linus.dev/zig
https://zig.squirl.dev
https://zig.mirror.mschae23.de/zig
https://ziglang.freetls.fastly.net
https://zig.tilok.dev
https://zig-mirror.tsimnet.eu/zig
https://zig.karearl.com/zig
https://pkg.earth/zig
https://fs.liujiacai.net/zigbuilds
https://zigmirror.com
https://zig.chainsafe.dev
https://zig.savalione.com'

log() {
  printf '%s\n' "$*" >&2
}

sha256_file() {
  file_path="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file_path" | awk '{print $1}'
    return
  fi
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file_path" | awk '{print $1}'
    return
  fi
  if command -v sha256 >/dev/null 2>&1; then
    sha256 -q "$file_path"
    return
  fi
  log "No SHA-256 tool is available"
  exit 1
}

shuffle_lines() {
  awk 'BEGIN { srand(); } { printf "%.17f\t%s\n", rand(), $0; }' | sort -n | cut -f2-
}

fetch_mirrors() {
  if mirrors="$(curl -fsSL --connect-timeout "$download_connect_timeout" --max-time 20 "$mirror_list_url" 2>/dev/null)"; then
    printf '%s\n' "$mirrors"
    return
  fi
  printf '%s\n' "$fallback_mirrors"
}

download_archive() {
  url="$1"
  out_path="$2"
  curl -fsSL \
    --retry "$download_retry_count" \
    --retry-delay 1 \
    --retry-all-errors \
    --connect-timeout "$download_connect_timeout" \
    --max-time "$download_max_time" \
    -o "$out_path" \
    "$url"
}

temp_archive="${archive_name}.part.$$"
rm -f "$temp_archive"
trap 'rm -f "$temp_archive"' EXIT HUP INT TERM

for mirror_url in $(fetch_mirrors | shuffle_lines); do
  candidate="${mirror_url%/}/${archive_name}?source=${source_name}"
  log "Trying Zig mirror: $candidate"
  if ! download_archive "$candidate" "$temp_archive"; then
    rm -f "$temp_archive"
    continue
  fi
  actual_sha="$(sha256_file "$temp_archive")"
  if [ "$actual_sha" != "$expected_sha" ]; then
    log "Checksum mismatch from mirror: $mirror_url"
    rm -f "$temp_archive"
    continue
  fi
  break
done

if [ ! -f "$temp_archive" ] && [ -n "$official_url" ]; then
  log "Mirror download failed, falling back to official Zig download"
  if download_archive "$official_url" "$temp_archive"; then
    actual_sha="$(sha256_file "$temp_archive")"
    if [ "$actual_sha" != "$expected_sha" ]; then
      log "Checksum mismatch from official Zig download"
      rm -f "$temp_archive"
    fi
  fi
fi

if [ ! -f "$temp_archive" ]; then
  log "Unable to download ${archive_name}"
  exit 1
fi

root_dir="$(tar -tf "$temp_archive" | awk -F/ 'NR == 1 { print $1; exit }')"
if [ -z "$root_dir" ]; then
  log "Unable to determine extracted Zig directory"
  exit 1
fi

tar -xf "$temp_archive"

if [ -n "${GITHUB_PATH:-}" ]; then
  printf '%s\n' "$PWD/$root_dir" >> "$GITHUB_PATH"
fi

printf '%s\n' "$PWD/$root_dir"
