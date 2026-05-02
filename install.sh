#!/bin/sh
set -eu

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'

log_info() { printf '%b\n' "${NC} $*"; }
log_success() { printf '%b\n' "${GREEN}${NC} $*"; }
log_warning() { printf '%b\n' "${YELLOW}[WARNING]${NC} $*"; }
log_error() { printf '%b\n' "${RED}[ERROR]${NC} $*" >&2; }
log_config() { printf '%b\n' "${CYAN}[CONFIG]${NC} $*"; }

repo="luodaoyi/komari-zig-agent"
service_name="komari-agent"
target_dir="/opt/komari"
github_proxy=""
github_proxy_list="${KOMARI_GITHUB_PROXIES:-https://gh.llkk.cc https://gh-proxy.com https://ghproxy.net https://ghfast.top https://ghproxy.cc}"
install_version=""
komari_args=""

os_type="$(uname -s)"
case "$os_type" in
  Linux) os_name="linux" ;;
  FreeBSD) os_name="freebsd" ;;
  Darwin)
    os_name="darwin"
    target_dir="/usr/local/komari"
    if [ ! -w "/usr/local" ] && [ "${EUID:-$(id -u)}" -ne 0 ]; then
      target_dir="$HOME/.komari"
    fi
    ;;
  *) log_error "Unsupported operating system: $os_type"; exit 1 ;;
esac

while [ "$#" -gt 0 ]; do
  case "$1" in
    --install-dir) target_dir="$2"; shift 2 ;;
    --install-service-name) service_name="$2"; shift 2 ;;
    --install-ghproxy) github_proxy="$2"; shift 2 ;;
    --install-version) install_version="$2"; shift 2 ;;
    --install*) log_warning "Unknown install parameter: $1"; shift ;;
    *) komari_args="${komari_args} $1"; shift ;;
  esac
done
komari_args="${komari_args# }"
agent_path="${target_dir}/agent"

require_root=true
if [ "$os_name" = "darwin" ] && command -v brew >/dev/null 2>&1; then
  require_root=false
fi
if [ "${EUID:-$(id -u)}" -ne 0 ] && [ "$require_root" = true ]; then
  log_error "Please run as root"
  exit 1
fi

arch="$(uname -m)"
case "$arch" in
  x86_64|amd64) arch="amd64" ;;
  aarch64|arm64) arch="arm64" ;;
  i386|i686)
    case "$os_name" in linux|freebsd) arch="386" ;; *) log_error "32-bit x86 not supported on $os_name"; exit 1 ;; esac
    ;;
  armv6*|armv7*)
    case "$os_name" in linux|freebsd) arch="arm" ;; *) log_error "32-bit ARM not supported on $os_name"; exit 1 ;; esac
    ;;
  mips)
    [ "$os_name" = "linux" ] && arch="mips" || { log_error "MIPS not supported on $os_name"; exit 1; }
    ;;
  mipsel)
    [ "$os_name" = "linux" ] && arch="mipsel" || { log_error "MIPS little-endian not supported on $os_name"; exit 1; }
    ;;
  riscv64)
    [ "$os_name" = "linux" ] && arch="riscv64" || { log_error "RISC-V not supported on $os_name"; exit 1; }
    ;;
  *) log_error "Unsupported architecture: $arch"; exit 1 ;;
esac

printf '%b\n' "${WHITE}===========================================${NC}"
printf '%b\n' "${WHITE}    Komari Agent Installation Script${NC}"
printf '%b\n' "${WHITE}===========================================${NC}"
log_config "Service name: ${GREEN}$service_name${NC}"
log_config "Install directory: ${GREEN}$target_dir${NC}"
log_config "GitHub proxy: ${GREEN}${github_proxy:-"(auto fallback)"}${NC}"
log_config "Binary arguments: ${GREEN}$komari_args${NC}"
log_config "Version: ${GREEN}${install_version:-Latest}${NC}"

install_dependencies() {
  command -v curl >/dev/null 2>&1 && return
  log_info "Installing dependency: curl"
  if command -v apt >/dev/null 2>&1; then
    apt update && apt install -y curl
  elif command -v yum >/dev/null 2>&1; then
    yum install -y curl
  elif command -v apk >/dev/null 2>&1; then
    apk add curl
  elif command -v opkg >/dev/null 2>&1; then
    opkg update && opkg install curl
  elif command -v pkg >/dev/null 2>&1; then
    pkg install -y curl
  elif command -v brew >/dev/null 2>&1; then
    brew install curl
  else
    log_error "No supported package manager found for curl"
    exit 1
  fi
}

uninstall_previous() {
  log_info "Checking for previous installation..."
  if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files 2>/dev/null | grep -q "^${service_name}.service"; then
    systemctl stop "${service_name}.service" 2>/dev/null || true
    systemctl disable "${service_name}.service" 2>/dev/null || true
    rm -f "/etc/systemd/system/${service_name}.service"
    systemctl daemon-reload || true
  fi
  if command -v rc-service >/dev/null 2>&1 && [ -f "/etc/init.d/${service_name}" ]; then
    rc-service "$service_name" stop 2>/dev/null || true
    rc-update del "$service_name" default 2>/dev/null || true
    rm -f "/etc/init.d/${service_name}"
  fi
  if command -v uci >/dev/null 2>&1 && [ -f "/etc/init.d/${service_name}" ]; then
    "/etc/init.d/${service_name}" stop 2>/dev/null || true
    "/etc/init.d/${service_name}" disable 2>/dev/null || true
    rm -f "/etc/init.d/${service_name}"
  fi
  if command -v initctl >/dev/null 2>&1 && [ -f "/etc/init/${service_name}.conf" ]; then
    initctl stop "$service_name" 2>/dev/null || true
    rm -f "/etc/init/${service_name}.conf"
  fi
  if [ "$os_name" = "freebsd" ] && [ -f "/usr/local/etc/rc.d/${service_name}" ]; then
    service "$service_name" stop 2>/dev/null || true
    rm -f "/usr/local/etc/rc.d/${service_name}"
  fi
  if [ "$os_name" = "darwin" ] && command -v launchctl >/dev/null 2>&1; then
    system_plist="/Library/LaunchDaemons/com.komari.${service_name}.plist"
    user_plist="$HOME/Library/LaunchAgents/com.komari.${service_name}.plist"
    [ -f "$system_plist" ] && launchctl bootout system "$system_plist" 2>/dev/null || true
    [ -f "$user_plist" ] && launchctl bootout "gui/$(id -u)" "$user_plist" 2>/dev/null || true
    rm -f "$system_plist" "$user_plist"
  fi
  rm -f "$agent_path"
}

detect_init_system() {
  [ -f /etc/NIXOS ] && { echo nixos; return; }
  [ "$os_name" = "freebsd" ] && { echo freebsd; return; }
  [ "$os_name" = "darwin" ] && command -v launchctl >/dev/null 2>&1 && { echo launchd; return; }
  [ -f /etc/alpine-release ] && command -v rc-service >/dev/null 2>&1 && { echo openrc; return; }
  if command -v uci >/dev/null 2>&1 && [ -f /etc/rc.common ]; then echo procd; return; fi
  pid1="$(ps -p 1 -o comm= 2>/dev/null | tr -d ' ' || true)"
  if { [ "$pid1" = systemd ] || [ -d /run/systemd/system ]; } && command -v systemctl >/dev/null 2>&1 && systemctl list-units >/dev/null 2>&1; then
    echo systemd; return
  fi
  if command -v rc-service >/dev/null 2>&1 && { [ -d /run/openrc ] || [ -f /sbin/openrc ] || [ "$pid1" = openrc-init ]; }; then
    echo openrc; return
  fi
  if command -v initctl >/dev/null 2>&1 && [ -d /etc/init ]; then echo upstart; return; fi
  echo unknown
}

install_dependencies
uninstall_previous
mkdir -p "$target_dir"

download_file() {
  url="$1"
  out="$2"
  attempt=1
  max_attempts=3
  while [ "$attempt" -le "$max_attempts" ]; do
    curl -fL -o "$out" "$url" && return 0
    rm -f "$out"
    log_warning "Download failed, retry ${attempt}/${max_attempts}"
    attempt=$((attempt + 1))
    sleep 2
  done
  return 1
}

proxy_url() {
  proxy="$1"
  url="$2"
  printf '%s/%s\n' "${proxy%/}" "$url"
}

probe_url() {
  url="$1"
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
  best_url=""
  best_time=""
  for proxy in $(github_proxy_items); do
    candidate="$(proxy_url "$proxy" "$base_url")"
    elapsed="$(probe_url "$candidate" || true)"
    [ -n "$elapsed" ] || continue
    log_info "Proxy probe: ${CYAN}$proxy${NC} ${elapsed}s" >&2
    if [ -z "$best_time" ] || time_less_than "$elapsed" "$best_time"; then
      best_time="$elapsed"
      best_url="$candidate"
    fi
  done
  [ -n "$best_url" ] || return 1
  printf '%s\n' "$best_url"
}

try_download_binary() {
  url="$1"
  out="$2"
  log_info "Downloading: ${CYAN}$url${NC}"
  download_file "$url" "$out" || return 1
  chmod +x "$out"
  "$out" --show-warning >/dev/null 2>&1 && return 0
  rm -f "$out"
  log_warning "Downloaded file failed binary preflight"
  return 1
}

download_binary_with_fallback() {
  base_url="$1"
  out="$2"
  if [ -n "$github_proxy" ]; then
    try_download_binary "$(proxy_url "$github_proxy" "$base_url")" "$out"
    return
  fi

  try_download_binary "$base_url" "$out" && return 0
  log_warning "Direct GitHub download failed, probing GitHub proxy mirrors"

  fastest="$(select_fastest_proxy_url "$base_url" || true)"
  if [ -n "$fastest" ]; then
    try_download_binary "$fastest" "$out" && return 0
    log_warning "Fastest proxy failed, trying remaining proxy mirrors"
  fi

  for proxy in $(github_proxy_items); do
    candidate="$(proxy_url "$proxy" "$base_url")"
    [ "$candidate" = "$fastest" ] && continue
    try_download_binary "$candidate" "$out" && return 0
  done
  return 1
}

asset="komari-agent-${os_name}-${arch}"
if [ -n "$install_version" ]; then
  release_path="download/${install_version}"
else
  release_path="latest/download"
fi
download_url="https://github.com/${repo}/releases/${release_path}/${asset}"

log_info "Detected OS: ${GREEN}$os_name${NC}, Architecture: ${GREEN}$arch${NC}"
download_binary_with_fallback "$download_url" "$agent_path" || {
  log_error "Failed to download release asset"
  exit 1
}
log_success "Installed binary: $agent_path"

init_system="$(detect_init_system)"
log_info "Detected init system: ${GREEN}$init_system${NC}"

case "$init_system" in
  nixos)
    log_warning "NixOS detected. Add this service declaratively:"
    cat <<EOF
systemd.services.${service_name} = {
  description = "Komari Agent Service";
  after = [ "network.target" ];
  wantedBy = [ "multi-user.target" ];
  serviceConfig = {
    Type = "simple";
    ExecStart = "${agent_path} ${komari_args}";
    WorkingDirectory = "${target_dir}";
    Restart = "always";
    User = "root";
  };
};
EOF
    ;;
  systemd)
    cat > "/etc/systemd/system/${service_name}.service" <<EOF
[Unit]
Description=Komari Agent Service
After=network.target

[Service]
Type=simple
ExecStart=${agent_path} ${komari_args}
WorkingDirectory=${target_dir}
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "${service_name}.service"
    systemctl restart "${service_name}.service"
    ;;
  openrc)
    cat > "/etc/init.d/${service_name}" <<EOF
#!/sbin/openrc-run
name="Komari Agent Service"
description="Komari monitoring agent"
command="${agent_path}"
command_args="${komari_args}"
command_user="root"
directory="${target_dir}"
pidfile="/run/${service_name}.pid"
retry="SIGTERM/30"
supervisor=supervise-daemon
depend() { need net; after network; }
EOF
    chmod +x "/etc/init.d/${service_name}"
    rc-update add "$service_name" default
    rc-service "$service_name" restart
    ;;
  procd)
    cat > "/etc/init.d/${service_name}" <<EOF
#!/bin/sh /etc/rc.common
START=99
STOP=10
USE_PROCD=1
PROG="${agent_path}"
ARGS="${komari_args}"
start_service() {
  procd_open_instance
  procd_set_param command \$PROG \$ARGS
  procd_set_param respawn
  procd_set_param stdout 1
  procd_set_param stderr 1
  procd_set_param user root
  procd_close_instance
}
stop_service() { killall \$(basename \$PROG); }
reload_service() { stop; start; }
EOF
    chmod +x "/etc/init.d/${service_name}"
    "/etc/init.d/${service_name}" enable
    "/etc/init.d/${service_name}" restart
    ;;
  upstart)
    cat > "/etc/init/${service_name}.conf" <<EOF
description "Komari Agent Service"
chdir ${target_dir}
start on filesystem or runlevel [2345]
stop on runlevel [!2345]
respawn
respawn limit 10 5
script
  exec ${agent_path} ${komari_args}
end script
EOF
    initctl reload-configuration
    initctl restart "$service_name" || initctl start "$service_name"
    ;;
  freebsd)
    rc_name="$(printf '%s' "$service_name" | tr -c 'A-Za-z0-9_' '_')"
    rc_file="/usr/local/etc/rc.d/${service_name}"
    cat > "$rc_file" <<EOF
#!/bin/sh
# PROVIDE: ${rc_name}
# REQUIRE: NETWORKING
# KEYWORD: shutdown
. /etc/rc.subr
name="${rc_name}"
rcvar="${rc_name}_enable"
command="/usr/sbin/daemon"
pidfile="/var/run/${service_name}.pid"
procname="${agent_path}"
command_args="-f -p \$pidfile ${agent_path} ${komari_args}"
load_rc_config "\$name"
: \${${rc_name}_enable:="YES"}
run_rc_command "\$1"
EOF
    chmod +x "$rc_file"
    sysrc "${rc_name}_enable=YES" >/dev/null 2>&1 || true
    service "$service_name" restart
    ;;
  launchd)
    case "$target_dir" in
      /Users/*) user_launchd=true ;;
      *) user_launchd=false ;;
    esac
    if [ "$user_launchd" = true ] || [ "${EUID:-$(id -u)}" -ne 0 ]; then
      plist_dir="$HOME/Library/LaunchAgents"
      plist_file="$plist_dir/com.komari.${service_name}.plist"
      domain="gui/$(id -u)"
      service_user="$(whoami)"
      log_dir="$HOME/Library/Logs"
    else
      plist_dir="/Library/LaunchDaemons"
      plist_file="$plist_dir/com.komari.${service_name}.plist"
      domain="system"
      service_user="root"
      log_dir="/var/log"
    fi
    mkdir -p "$plist_dir" "$log_dir"
    cat > "$plist_file" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>com.komari.${service_name}</string>
<key>ProgramArguments</key><array><string>${agent_path}</string>
EOF
    if [ -n "$komari_args" ]; then
      # shellcheck disable=SC2086
      for arg in $komari_args; do printf '<string>%s</string>\n' "$arg" >> "$plist_file"; done
    fi
    cat >> "$plist_file" <<EOF
</array>
<key>WorkingDirectory</key><string>${target_dir}</string>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><true/>
<key>UserName</key><string>${service_user}</string>
<key>StandardOutPath</key><string>${log_dir}/${service_name}.log</string>
<key>StandardErrorPath</key><string>${log_dir}/${service_name}.log</string>
</dict></plist>
EOF
    launchctl bootout "$domain" "$plist_file" 2>/dev/null || true
    launchctl bootstrap "$domain" "$plist_file"
    ;;
  *)
    log_error "Unsupported or unknown init system: $init_system"
    exit 1
    ;;
esac

log_success "Komari-agent installation completed"
log_config "Service: ${GREEN}$service_name${NC}"
log_config "Arguments: ${GREEN}$komari_args${NC}"
