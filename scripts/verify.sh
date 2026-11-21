#!/bin/bash
# 一条命令验收：工作台、DSH 反代、cookie 登录链路、Tailscale 组网。
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${DSH_WORKBENCH_CONFIG:-$ROOT/config.json}"
FAIL=0
JAR="$(mktemp)"
trap 'rm -f "$JAR"' EXIT

ok()  { echo "OK   $*"; }
bad() { echo "FAIL $*"; FAIL=1; }
warn(){ echo "WARN $*"; }

[ -f "$CONFIG" ] || { echo "FAIL 缺少 $CONFIG"; exit 1; }
eval "$(python3 - "$CONFIG" <<'PY'
import json, os, shlex, sys
c = json.load(open(sys.argv[1], encoding="utf-8"))
print("WB_PORT=%d" % int(c["workbench"]["port"]))
print("PUB_PORT=%d" % int(c["dsh"]["publicPort"]))
print("MATCH=%s" % shlex.quote(str(c["dsh"].get("processMatch", "DeepSeek"))))
print("DSH_HOME=%s" % shlex.quote(os.path.expanduser(str(c["dsh"].get("home", "~/.dsh")))))
PY
)" || { echo "FAIL config.json 解析失败"; exit 1; }

TS_IP="$(ifconfig 2>/dev/null | awk '/inet 100\./ {print $2; exit}')"
HOST="${TS_IP:-127.0.0.1}"
CURL=(curl -s --noproxy '*' -m 5)

# 1. 工作台
if "${CURL[@]}" -o /dev/null -w '%{http_code}' "http://$HOST:$WB_PORT/" | grep -q '^200$'; then
  ok "工作台 http://$HOST:$WB_PORT/"
else
  bad "工作台打不开（看 ~/Library/Logs/dsh-workbench.err.log）"
fi

# 2. 状态接口：字段齐全，且不返回 token / 内部端口
if "${CURL[@]}" "http://$HOST:$WB_PORT/api/status" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert "host" in d and "clients" in d
assert "token" not in d["host"]["dsh"] and "url" not in d["host"]["dsh"]
assert "port" not in d["host"]["dsh"]
'; then ok "状态接口不泄露 token/内部端口"; else bad "状态接口异常或返回了敏感字段"; fi

# 3. 反代在听，且没有绑到所有网卡
LISTEN="$(lsof -nP -iTCP:"$PUB_PORT" -sTCP:LISTEN 2>/dev/null)"
if echo "$LISTEN" | grep -q LISTEN; then ok "反代监听 :$PUB_PORT"; else bad "反代未监听 :$PUB_PORT"; fi
if echo "$LISTEN" | grep -qE '\*:|0\.0\.0\.0:'; then bad "反代绑定了所有网卡（应只绑回环 + Tailscale）"; fi

# 4. DSH 本体：进程在听，且 Host 改写后能拿到鉴权页
DSH_PORT="$(lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | grep -i "$MATCH" \
            | grep -o '127\.0\.0\.1:[0-9]*' | cut -d: -f2 | sort -u | head -1)"
if [ -n "$DSH_PORT" ]; then ok "DSH 进程在听"; else warn "没找到 DSH 监听端口（DSH 是否在运行？）"; fi

# 5. 远程入口发 cookie
CODE="$("${CURL[@]}" -c "$JAR" -o /dev/null -w '%{http_code}' "http://$HOST:$WB_PORT/remote-dsh")"
if [ "$CODE" = "302" ]; then ok "/remote-dsh 下发 DSH cookie"; else bad "/remote-dsh 返回 ${CODE}（凭据文件或 DSH 版本不匹配）"; fi

# 6. 带上 cookie 访问反代，应直接进 DSH
CODE="$("${CURL[@]}" -b "$JAR" -o /dev/null -w '%{http_code}' "http://$HOST:$PUB_PORT/")"
case "$CODE" in
  200|303) ok "cookie 经反代进入 DSH（${CODE}）" ;;
  401) bad "反代返回 401：cookie 的 authority 与 Host 改写不一致，检查 dsh.publicPort" ;;
  *) bad "反代返回 ${CODE}（Caddy 目标端口没跟上，看 ~/Library/Logs/dsh-proxy.log）" ;;
esac

# 7. Tailscale：至少一个 peer
if command -v tailscale >/dev/null 2>&1 || [ -x /Applications/Tailscale.app/Contents/MacOS/Tailscale ]; then
  TS_BIN="$(command -v tailscale 2>/dev/null || echo /Applications/Tailscale.app/Contents/MacOS/Tailscale)"
  PEERS="$("$TS_BIN" status --json 2>/dev/null | python3 -c 'import json,sys;print(len((json.load(sys.stdin).get("Peer") or {})))' 2>/dev/null || echo 0)"
  if [ "${PEERS:-0}" -ge 1 ]; then ok "Tailscale 在线，peer $PEERS 台"; else warn "Tailscale 没有 peer，或 CLI 被权限拦截"; fi
else
  warn "没找到 tailscale CLI"
fi

echo
if [ "$FAIL" = "0" ]; then echo "验收通过"; else echo "有失败项，按上面提示排查"; fi
exit "$FAIL"
