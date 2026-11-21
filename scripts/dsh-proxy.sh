#!/bin/bash
# 跟随 DSH 的动态 Web 端口，用 Caddy 把 tailnet 上的 publicPort 反代到它。
# DSH 只接受 Host 为回环的请求，所以 Host/Origin 固定改写成 127.0.0.1:<publicPort>。
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${DSH_WORKBENCH_CONFIG:-$ROOT/config.json}"
STATE="${DSH_WORKBENCH_STATE:-$HOME/Library/Application Support/dsh-workbench}"
LOG="${DSH_PROXY_LOG:-$HOME/Library/Logs/dsh-proxy.log}"
mkdir -p "$STATE" "$(dirname "$LOG")"

if [ ! -f "$CONFIG" ]; then
  echo "缺少配置：${CONFIG}（先把 config.example.json 复制成 config.json）" >&2
  exit 1
fi

read_cfg() {
  python3 - "$CONFIG" <<'PY'
import json, os, shlex, sys
with open(sys.argv[1], encoding="utf-8") as f:
    c = json.load(f)
d = c.get("dsh") or {}
print("PUBLIC_PORT=%d" % int(d.get("publicPort", 8711)))
print("PROCESS_MATCH=%s" % shlex.quote(str(d.get("processMatch", "DeepSeek"))))
print("LAUNCH_LOG=%s" % shlex.quote(os.path.expanduser(str(d.get("launchLog", "")))))
PY
}
eval "$(read_cfg)"

if [ -z "${PUBLIC_PORT:-}" ]; then
  echo "配置里缺少 dsh.publicPort" >&2
  exit 1
fi
AUTHORITY="127.0.0.1:$PUBLIC_PORT"
CFG="$STATE/Caddyfile"

CADDY="${CADDY_BIN:-}"
if [ -z "$CADDY" ]; then
  for p in "$(command -v caddy 2>/dev/null)" \
           "$HOME/Library/Application Support/dsh-workbench/bin/caddy" \
           /opt/homebrew/bin/caddy /usr/local/bin/caddy; do
    if [ -n "$p" ] && [ -x "$p" ]; then CADDY="$p"; break; fi
  done
fi
if [ -z "$CADDY" ]; then
  echo "找不到 caddy：先 brew install caddy，或用 CADDY_BIN 指定绝对路径" >&2
  exit 1
fi

ts_ip() {
  local ip
  ip=$(ifconfig 2>/dev/null | awk '/inet 100\./ {print $2; exit}')
  if [ -z "$ip" ] && command -v tailscale >/dev/null 2>&1; then
    ip=$(tailscale ip -4 2>/dev/null | head -1)
  fi
  printf '%s' "$ip"
}
TS_IP="$(ts_ip)"
if [ -n "$TS_IP" ]; then BINDS="127.0.0.1 $TS_IP"; else BINDS="127.0.0.1"; fi

probe_port() {
  local p code
  for p in $(lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null \
             | grep -i "$PROCESS_MATCH" \
             | grep -o '127\.0\.0\.1:[0-9]*' | cut -d: -f2 | sort -u); do
    code=$(curl -s -o /dev/null -m 2 --noproxy '*' -H "Host: $AUTHORITY" \
                -w '%{http_code}' "http://127.0.0.1:$p/" 2>/dev/null)
    case "$code" in 200|303|401|403) printf '%s' "$p"; return 0;; esac
  done
  return 1
}

log_port() {
  [ -n "$LAUNCH_LOG" ] && [ -f "$LAUNCH_LOG" ] || return 1
  grep -o 'dsh web: http://127\.0\.0\.1:[0-9]*/' "$LAUNCH_LOG" 2>/dev/null \
    | tail -1 | grep -o ':[0-9]*/' | tr -d ':/'
}

write_cfg() {
  cat > "$CFG" <<CFGEOF
{
	admin off
	auto_https off
}

http://:$PUBLIC_PORT {
	bind $BINDS
	log {
		output discard
	}
	reverse_proxy 127.0.0.1:$1 {
		header_up Host $AUTHORITY
		header_up Origin http://$AUTHORITY
	}
}
CFGEOF
}

CADDY_PID=""
CUR_PORT=""
stop_caddy() {
  if [ -n "$CADDY_PID" ] && kill -0 "$CADDY_PID" 2>/dev/null; then
    kill "$CADDY_PID" 2>/dev/null
    for _ in $(seq 1 20); do
      kill -0 "$CADDY_PID" 2>/dev/null || break
      sleep 0.2
    done
  fi
  rm -f "$STATE/caddy.pid"
  CADDY_PID=""
}
trap 'stop_caddy; exit 0' INT TERM EXIT

echo "dsh-proxy: ${BINDS} :$PUBLIC_PORT -> 127.0.0.1:<dsh>" >&2
while true; do
  P=$(probe_port) || P=$(log_port) || P=""
  if [ -n "$P" ]; then
    if [ "$P" != "$CUR_PORT" ] || ! kill -0 "$CADDY_PID" 2>/dev/null; then
      stop_caddy
      write_cfg "$P"
      "$CADDY" run --config "$CFG" --adapter caddyfile >>"$LOG" 2>&1 &
      CADDY_PID=$!
      echo "$CADDY_PID" > "$STATE/caddy.pid"
      CUR_PORT="$P"
      echo "dsh-proxy: DSH :$P -> :$PUBLIC_PORT" >&2
    fi
  fi
  sleep 10
done
