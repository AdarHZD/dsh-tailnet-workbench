#!/bin/bash
# 停止并清理 launchd 任务、Caddy 子进程与运行时状态；不动 config.json 和仓库。
set -uo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
CONFIG="${DSH_WORKBENCH_CONFIG:-$ROOT/config.json}"
STATE="${DSH_WORKBENCH_STATE:-$HOME/Library/Application Support/dsh-workbench}"
AGENTS="$HOME/Library/LaunchAgents"
UID_NUM="$(id -u)"
LABEL_WB="local.dsh-workbench.workbench"
LABEL_PX="local.dsh-workbench.proxy"

PUB_PORT=""
if [ -f "$CONFIG" ]; then
  PUB_PORT="$(python3 -c 'import json,sys;print(int(json.load(open(sys.argv[1]))["dsh"]["publicPort"]))' "$CONFIG" 2>/dev/null || true)"
fi

for label in "$LABEL_WB" "$LABEL_PX"; do
  launchctl bootout "gui/$UID_NUM/$label" 2>/dev/null || true
done
sleep 1

# bootout 只保证守护脚本退出；Caddy 可能还在，按 pid 文件 + Caddyfile 路径清理。
if [ -f "$STATE/caddy.pid" ]; then
  pid="$(cat "$STATE/caddy.pid" 2>/dev/null || true)"
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null \
     && ps -p "$pid" -o command= 2>/dev/null | grep -q caddy; then
    kill "$pid" 2>/dev/null || true
  fi
fi
if [ -n "$PUB_PORT" ]; then
  for pid in $(lsof -nP -iTCP:"$PUB_PORT" -sTCP:LISTEN -t 2>/dev/null); do
    if ps -p "$pid" -o command= 2>/dev/null | grep -Fq "$STATE/Caddyfile"; then
      kill "$pid" 2>/dev/null || true
    fi
  done
fi

rm -f "$AGENTS/$LABEL_WB.plist" "$AGENTS/$LABEL_PX.plist"
rm -rf "$STATE"
echo "已停止并清理 $(basename "$ROOT") 的 launchd 任务与运行时状态。"
echo "config.json 与日志保留；需要时手动删除。"
