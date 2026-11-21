# 排障

先按症状定位，再看日志。**同一原因失败两次就停**：记下现象、已执行的命令、日志末尾，交给用户决定，不第三次盲试。

## 症状速查

| 现象 | 先查 | 再查 |
|---|---|---|
| 工作台打不开 | `launchctl print gui/$(id -u)/local.dsh-workbench.workbench \| grep state` | `tail -30 ~/Library/Logs/dsh-workbench.err.log` |
| 页面一直「刷新失败」 | `curl -s http://127.0.0.1:8710/api/status` | 工作台进程是否在、端口是否被改 |
| 设备卡只有本机 | `tailscale status` 是否有 peer | `~/Library/Logs/dsh-workbench.err.log` 里 Tailscale CLI 是否报错 |
| 某设备时延一直 `—` | `tailscale ping <ip>` 是否通 | 设备是否在线、CLI 是否被权限拦截 |
| 路径一直是 `Relay` | `tailscale netcheck` 的 IPv6 | 路由器 IPv6 防火墙、运营商是否给公网 IPv6 |
| 点 DSH 白屏 / 401 | `curl -si http://<mac>:8710/remote-dsh` 是否 302 + Set-Cookie | `dsh.publicPort` 与 Caddy Host 是否一致 |
| 点 DSH 502 | `lsof -nP -iTCP -sTCP:LISTEN \| grep -i DeepSeek` | `tail -30 ~/Library/Logs/dsh-proxy.log`、Caddyfile 里的目标端口 |
| `/remote-dsh` 503 | `ls -l ~/.dsh/.credentials.yaml` | DSH 版本是否改了凭据格式；可回退到启动日志 token |
| 反代没监听 | `lsof -nP -iTCP:8711 -sTCP:LISTEN` | `CADDY_BIN` 是否正确、Caddy 是否启动失败 |
| 安装时提示端口占用 | `lsof -nP -iTCP:<port> -sTCP:LISTEN` | 改 `config.json` 的端口，或停掉占用者 |
| launchd `WARN` 未运行 | `launchctl print` 详情 | 日志里的 Python/Caddy 路径、权限 |
| DSH 重启后 iframe 卡住 | 工作台是否在轮询 | 等 10 秒；点 DSH 视图右上角 ↻ |
| 改了 config 没变化 | 是否重跑 `./install.sh` | 工作台会按文件 mtime 重载，但 launchd 环境变量要重装才更新 |
| 远程设备打不开 `127.0.0.1` 链接 | 是否用了 `127.0.0.1` 地址 | 换成 `http://<mac 的 Tailscale 地址>:8710/` |

## 工作台

```bash
launchctl print "gui/$(id -u)/local.dsh-workbench.workbench" | grep -E 'state|pid|last exit'
tail -50 ~/Library/Logs/dsh-workbench.err.log
curl -s http://127.0.0.1:8710/api/status | python3 -m json.tool | head -40
```

- 端口被改：`config.json` 的 `workbench.port` 与 `lsof` 对照。
- Python 路径：launchd 不读 shell 的 PATH；`install.sh` 写的是绝对路径。手动改过 plist 后要 `launchctl bootout` + `bootstrap`。
- 页面一直旧版：`uiAt` 变化会触发前端自动刷新；强制刷新浏览器一次。

## 设备列表

```bash
tailscale status
tailscale status --json | python3 -c 'import json,sys;d=json.load(sys.stdin);print(len(d.get("Peer") or {}))'
```

- `tailscale status` 正常但页面没有：看工作台日志里 `tailscale status --json` 是否超时/被拦。CLI 被拦时，在 `config.json` 的 `devices` 里补兜底列表。
- 设备名重复/旧节点：把节点名加进 `ignoreDevices`，或在 Tailscale 管理台删除旧设备。
- 本机行一定在；它不参与 ping。

## 时延

```bash
tailscale ping -c 2 --timeout 2s <peer>
ping -c 1 -t 2 <peer>
```

- `tailscale ping` 有 `in Xms` 但页面 `—`：等 5 秒（缓存 TTL），或点工作台刷新。
- 系统 `ping` 通、`tailscale ping` 不通：手机/平板不回应 ICMP 是正常的，以 `tailscale ping` 为准。
- 全部 `—`：Tailscale CLI 不可用，工作台退到系统 ping 也失败；先恢复 CLI。
- `Relay`：见下节。

## 直连 / IPv6

```bash
tailscale netcheck
tailscale ping -c 2 <peer>
```

- `IPv6: no`：路由器没下发 IPv6，或 Mac 没拿到地址；先修网络。
- `IPv6: yes` 但 `via DERP`：检查路由器「IPv6 防火墙」是否拦截入站 UDP；Tailscale 需要双向 UDP 才能打洞。
- 手机热点：部分运营商热点只有 IPv4，会退回 DERP，这是网络条件，不是部署问题。

## DSH 视图

```bash
# 反代目标端口
lsof -nP -iTCP -sTCP:LISTEN | grep -i DeepSeek

# 反代本身
lsof -nP -iTCP:8711 -sTCP:LISTEN
curl -s -o /dev/null -w '%{http_code}\n' -H 'Host: 127.0.0.1:8711' http://127.0.0.1:8711/

# cookie 链路
curl -s -c /tmp/dsh.jar -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8710/remote-dsh
curl -s -b /tmp/dsh.jar -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8711/
rm -f /tmp/dsh.jar
```

期望：`401`（无 cookie）→ `302`（发 cookie）→ `200`（带 cookie）。

| 结果 | 判断 |
|---|---|
| `502` | Caddy 的目标端口不对，或 DSH 没在听 → 看 `~/Library/Logs/dsh-proxy.log` |
| `401`（带 cookie） | cookie 的 authority 与 Host 改写不一致 → 检查 `dsh.publicPort`，重跑 `install.sh` |
| `503` | 凭据文件读不到 / 格式变了 → 检查 `dsh.credentials`，或配置 `dsh.launchLog` 回退 token |
| 连接被拒 | 反代没起 → `launchctl print` + `CADDY_BIN` |

DSH 重启换端口后，守护脚本最多 10 秒跟上；iframe 会在实例变化后自动重走 `/remote-dsh`。仍然卡住就点 DSH 视图右上角 ↻。

## 安装 / launchd

```bash
launchctl print "gui/$(id -u)/local.dsh-workbench.proxy" | grep -E 'state|pid|last exit'
tail -50 ~/Library/Logs/dsh-proxy-watcher.err.log
tail -50 ~/Library/Logs/dsh-proxy.log
```

- `找不到 caddy`：`brew install caddy`，或 `CADDY_BIN=/绝对路径 ./install.sh`。
- `端口已被占用`：换 `config.json` 的端口；不要 kill 不认识的进程。
- `WARN ... 未运行`：看对应 err 日志；修好后 `./install.sh` 重装。
- 仓库移动过位置：launchd 里是绝对路径，重跑 `./install.sh`。

## 访问地址

- 只用 `http://<mac 的 Tailscale 地址>:8710/` 或 MagicDNS 名；
- `127.0.0.1` 只在这台 Mac 上有效，iPad 上指的是 iPad 自己；
- 不要在 iPad 上用 `localhost`。

## 仍然不行

收集这四样再停手：

1. `./scripts/verify.sh` 的完整输出；
2. `launchctl print` 两个任务的状态；
3. `~/Library/Logs/` 下四个日志的最后 30 行；
4. `tailscale status` 与 `tailscale netcheck` 的结果。

贴出来前把真实 IP、tailnet 域名、设备名替换成占位符。
