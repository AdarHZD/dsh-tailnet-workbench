#!/bin/bash
# 安装/更新：生成 launchd 任务并启动工作台与 DSH 反代。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
CONFIG="${DSH_WORKBENCH_CONFIG:-$ROOT/config.json}"
STATE="${DSH_WORKBENCH_STATE:-$HOME/Library/Application Support/dsh-workbench}"
AGENTS="$HOME/Library/LaunchAgents"
LOGS="$HOME/Library/Logs"
UID_NUM="$(id -u)"
LABEL_WB="local.dsh-workbench.workbench"
LABEL_PX="local.dsh-workbench.proxy"

if [ ! -f "$CONFIG" ]; then
  cp "$ROOT/config.example.json" "$CONFIG"
  chmod 600 "$CONFIG"
  echo "已生成 ${CONFIG}，先按需改端口/设备，再重跑本脚本。"
  exit 0
fi

PYTHON="/usr/bin/python3"
if [ ! -x "$PYTHON" ]; then PYTHON="$(command -v python3 || true)"; fi
if [ -z "$PYTHON" ]; then
  echo "找不到 python3。macOS 装一次 Xcode 命令行工具：xcode-select --install" >&2
  exit 1
fi
"$PYTHON" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)' || {
  echo "需要 Python 3.9 以上：$PYTHON" >&2; exit 1; }

CADDY="${CADDY_BIN:-$(command -v caddy 2>/dev/null || true)}"
if [ -z "$CADDY" ]; then
  for p in "$STATE/bin/caddy" /opt/homebrew/bin/caddy /usr/local/bin/caddy; do
    if [ -x "$p" ]; then CADDY="$p"; break; fi
  done
fi
if [ -z "$CADDY" ]; then
  echo "找不到 caddy。先执行：brew install caddy" >&2
  exit 1
fi

"$PYTHON" - "$CONFIG" <<'PY' || { echo "config.json 解析失败" >&2; exit 1; }
import json, sys
c = json.load(open(sys.argv[1], encoding="utf-8"))
assert int(c["workbench"]["port"]) > 0
assert int(c["dsh"]["publicPort"]) > 0
PY

mkdir -p "$STATE" "$LOGS" "$AGENTS"

WB_PORT="$("$PYTHON" -c 'import json,sys;print(int(json.load(open(sys.argv[1]))["workbench"]["port"]))' "$CONFIG")"
PUB_PORT="$("$PYTHON" -c 'import json,sys;print(int(json.load(open(sys.argv[1]))["dsh"]["publicPort"]))' "$CONFIG")"

unload_job() {
  local label="$1"
  launchctl bootout "gui/$UID_NUM/$label" 2>/dev/null || true
  for _ in $(seq 1 20); do
    launchctl print "gui/$UID_NUM/$label" >/dev/null 2>&1 || return 0
    sleep 0.25
  done
  echo "无法卸载 $label；先执行 launchctl bootout gui/$UID_NUM/$label" >&2
  return 1
}
for label in "$LABEL_WB" "$LABEL_PX"; do
  unload_job "$label"
done

# launchd 只收走守护脚本时，Caddy 子进程可能还在。只清理「本仓库状态目录里的 Caddy」。
cleanup_stale_caddy() {
  local pid=""
  if [ -f "$STATE/caddy.pid" ]; then
    pid="$(cat "$STATE/caddy.pid" 2>/dev/null || true)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null \
       && ps -p "$pid" -o command= 2>/dev/null | grep -q caddy; then
      kill "$pid" 2>/dev/null || true
      for _ in $(seq 1 20); do kill -0 "$pid" 2>/dev/null || break; sleep 0.2; done
    fi
    rm -f "$STATE/caddy.pid"
  fi
  for pid in $(lsof -nP -iTCP:"$PUB_PORT" -sTCP:LISTEN -t 2>/dev/null); do
    if ps -p "$pid" -o command= 2>/dev/null | grep -Fq "$STATE/Caddyfile"; then
      kill "$pid" 2>/dev/null || true
    fi
  done
}
cleanup_stale_caddy
sleep 0.5

TS_IP="$(ifconfig 2>/dev/null | awk '/inet 100\./ {print $2; exit}')"
if [ -z "$TS_IP" ]; then
  echo "提示：当前没有 Tailscale 地址，工作台只会监听 127.0.0.1。"
  echo "     装好并登录 Tailscale 后，重跑 ./install.sh。"
fi

# 端口被别的进程占用时直接停，避免 launchd 反复重启刷日志。
for port in "$WB_PORT" "$PUB_PORT"; do
  if lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | grep -q .; then
    echo "端口 $port 已被占用。改 config.json 里的端口，或先停掉占用者。" >&2
    exit 1
  fi
done

xml() { printf '%s' "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'; }
ROOT_X="$(xml "$ROOT")"
CONFIG_X="$(xml "$CONFIG")"
STATE_X="$(xml "$STATE")"
LOGS_X="$(xml "$LOGS")"
PY_X="$(xml "$PYTHON")"
CADDY_X="$(xml "$CADDY")"

cat > "$AGENTS/$LABEL_WB.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>$LABEL_WB</string>
	<key>ProgramArguments</key>
	<array>
		<string>$PY_X</string>
		<string>$ROOT_X/workbench/workbench.py</string>
	</array>
	<key>WorkingDirectory</key><string>$ROOT_X</string>
	<key>EnvironmentVariables</key>
	<dict>
		<key>DSH_WORKBENCH_CONFIG</key><string>$CONFIG_X</string>
		<key>DSH_WORKBENCH_STATE</key><string>$STATE_X</string>
	</dict>
	<key>RunAtLoad</key><true/>
	<key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
	<key>ThrottleInterval</key><integer>10</integer>
	<key>StandardOutPath</key><string>$LOGS_X/dsh-workbench.log</string>
	<key>StandardErrorPath</key><string>$LOGS_X/dsh-workbench.err.log</string>
	<key>ProcessType</key><string>Background</string>
</dict>
</plist>
PLIST

cat > "$AGENTS/$LABEL_PX.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>$LABEL_PX</string>
	<key>ProgramArguments</key>
	<array>
		<string>$PY_X</string>
		<string>$ROOT_X/scripts/dsh-proxy.py</string>
	</array>
	<key>EnvironmentVariables</key>
	<dict>
		<key>DSH_WORKBENCH_CONFIG</key><string>$CONFIG_X</string>
		<key>DSH_WORKBENCH_STATE</key><string>$STATE_X</string>
		<key>CADDY_BIN</key><string>$CADDY_X</string>
	</dict>
	<key>RunAtLoad</key><true/>
	<key>KeepAlive</key><true/>
	<key>ThrottleInterval</key><integer>15</integer>
	<key>StandardOutPath</key><string>$LOGS_X/dsh-proxy-watcher.log</string>
	<key>StandardErrorPath</key><string>$LOGS_X/dsh-proxy-watcher.err.log</string>
</dict>
</plist>
PLIST

for label in "$LABEL_WB" "$LABEL_PX"; do
  launchctl bootout "gui/$UID_NUM/$label" 2>/dev/null || true
done
launchctl bootstrap "gui/$UID_NUM" "$AGENTS/$LABEL_WB.plist"
launchctl bootstrap "gui/$UID_NUM" "$AGENTS/$LABEL_PX.plist"

sleep 2
for label in "$LABEL_WB" "$LABEL_PX"; do
  if launchctl print "gui/$UID_NUM/$label" 2>/dev/null | grep -q "state = running"; then
    echo "OK  $label"
  else
    echo "WARN $label 未运行，看 ~/Library/Logs/ 下的日志" >&2
  fi
done

echo
echo "工作台：http://${TS_IP:-127.0.0.1}:$WB_PORT/"
echo "DSH：工作台顶部「DSH」标签（经本机反代，不需要公网端口）"
echo "验收：$ROOT/scripts/verify.sh"
