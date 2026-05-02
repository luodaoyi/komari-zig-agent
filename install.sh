#!/bin/sh
set -eu

service_name="komari-agent"
target_dir="/opt/komari"
github_proxy=""
install_version=""
komari_args=""

os_name="$(uname -s | tr '[:upper:]' '[:lower:]')"
case "$os_name" in
  linux) os_name="linux" ;;
  freebsd) os_name="freebsd" ;;
  darwin) os_name="darwin"; target_dir="/usr/local/komari" ;;
  *) echo "[ERROR] unsupported os: $os_name" >&2; exit 1 ;;
esac

while [ "$#" -gt 0 ]; do
  case "$1" in
    --install-dir) target_dir="$2"; shift 2 ;;
    --install-service-name) service_name="$2"; shift 2 ;;
    --install-ghproxy) github_proxy="$2"; shift 2 ;;
    --install-version) install_version="$2"; shift 2 ;;
    --install*) echo "[WARNING] unknown install parameter: $1"; shift ;;
    *) komari_args="${komari_args} $1"; shift ;;
  esac
done
komari_args="$(printf '%s' "$komari_args" | sed 's/^ //')"

arch="$(uname -m)"
case "$arch" in
  x86_64|amd64) arch="amd64" ;;
  aarch64|arm64) arch="arm64" ;;
  i386|i686) arch="386" ;;
  armv6*|armv7*) arch="arm" ;;
  *) echo "[ERROR] unsupported arch: $arch" >&2; exit 1 ;;
esac

if [ "$os_name" = "darwin" ] && { [ "$arch" = "386" ] || [ "$arch" = "arm" ]; }; then
  echo "[ERROR] unsupported darwin arch: $arch" >&2
  exit 1
fi

if [ "$(id -u)" -ne 0 ] && [ "$os_name" != "darwin" ]; then
  echo "[ERROR] please run as root" >&2
  exit 1
fi

mkdir -p "$target_dir"
agent_path="$target_dir/agent"
asset="komari-agent-$os_name-$arch"
if [ -n "$install_version" ]; then
  release_path="download/$install_version"
else
  release_path="latest/download"
fi
url="https://github.com/luodaoyi/komari-zig-agent/releases/$release_path/$asset"
if [ -n "$github_proxy" ]; then
  url="$github_proxy/$url"
fi

echo "Downloading $url"
curl -L -o "$agent_path" "$url"
chmod +x "$agent_path"

if command -v systemctl >/dev/null 2>&1 && [ "$os_name" = "linux" ]; then
  cat > "/etc/systemd/system/$service_name.service" <<EOF
[Unit]
Description=Komari Agent Service
After=network.target

[Service]
Type=simple
ExecStart=$agent_path $komari_args
WorkingDirectory=$target_dir
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable "$service_name.service"
  systemctl restart "$service_name.service"
elif command -v rc-service >/dev/null 2>&1 && [ "$os_name" != "darwin" ]; then
  cat > "/etc/init.d/$service_name" <<EOF
#!/sbin/openrc-run
name="Komari Agent Service"
command="$agent_path"
command_args="$komari_args"
command_user="root"
directory="$target_dir"
pidfile="/run/$service_name.pid"
supervisor=supervise-daemon
depend() { need net; after network; }
EOF
  chmod +x "/etc/init.d/$service_name"
  rc-update add "$service_name" default
  rc-service "$service_name" restart
elif [ "$os_name" = "freebsd" ] && [ -d /usr/local/etc/rc.d ]; then
  rc_file="/usr/local/etc/rc.d/$service_name"
  rc_name="$(printf '%s' "$service_name" | tr -c 'A-Za-z0-9_' '_')"
  daemon_bin="/usr/sbin/daemon"
  cat > "$rc_file" <<EOF
#!/bin/sh

# PROVIDE: $rc_name
# REQUIRE: NETWORKING
# KEYWORD: shutdown

. /etc/rc.subr

name="$rc_name"
rcvar="${rc_name}_enable"
command="$daemon_bin"
pidfile="/var/run/$service_name.pid"
procname="$agent_path"
command_args="-f -p \$pidfile $agent_path $komari_args"

load_rc_config "\$name"
: \${${rc_name}_enable:="YES"}

run_rc_command "\$1"
EOF
  chmod +x "$rc_file"
  sysrc "${rc_name}_enable=YES" >/dev/null 2>&1 || true
  service "$service_name" restart
elif [ "$os_name" = "darwin" ] && command -v launchctl >/dev/null 2>&1; then
  plist="/Library/LaunchDaemons/com.komari.$service_name.plist"
  cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>com.komari.$service_name</string>
<key>ProgramArguments</key><array><string>$agent_path</string></array>
<key>WorkingDirectory</key><string>$target_dir</string>
<key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
</dict></plist>
EOF
  launchctl bootout system "$plist" 2>/dev/null || true
  launchctl bootstrap system "$plist"
else
  echo "[WARNING] no supported service manager found; binary installed at $agent_path"
fi

echo "Komari Agent installed: $agent_path"
