# 排障

本页命令以 macOS 为例；Windows 的差异集中在文末 [Windows 差异](#windows-差异)。

先按症状定位，再看日志。**同一原因失败两次就停**：记下现象、已执行的命令、日志末尾，交给用户决定，不第三次盲试。

本页命令里的 `"$TS"` 先取一次（macOS 的 CLI 不一定在 PATH）：

```bash
TS=/Applications/Tailscale.app/Contents/MacOS/Tailscale
[ -x "$TS" ] || TS="$(command -v tailscale)"
```

## 症状速查

| 现象 | 先查 | 再查 |
|---|---|---|
| 工作台打不开 | `launchctl print gui/$(id -u)/local.dsh-workbench.workbench \| grep state` | `tail -30 ~/Library/Logs/dsh-workbench.err.log` |
| 页面一直「刷新失败」 | `curl -s http://127.0.0.1:8710/api/status` | 工作台进程是否在、端口是否被改 |
| 设备卡只有本机 | `"$TS" status` 是否有 peer | `~/Library/Logs/dsh-workbench.err.log` 里 Tailscale CLI 是否报错 |
| 某设备时延一直 `—` | `"$TS" ping <ip>` 是否通 | 设备是否在线、CLI 是否被权限拦截 |
| 路径一直是 `Relay` | `"$TS" netcheck` 的 IPv6 | 路由器 IPv6 防火墙、运营商是否给公网 IPv6 |
| 点 DSH 白屏 / 401 | `curl -si http://<mac>:8710/remote-dsh` 是否 302 + Set-Cookie | `dsh.publicPort` 与 Caddy Host 是否一致 |
| 点 DSH 502 | `lsof -nP -iTCP -sTCP:LISTEN \| grep -i DeepSeek` | `tail -30 ~/Library/Logs/dsh-proxy.log`、Caddyfile 里的目标端口 |
| `/remote-dsh` 503 | `ls -l ~/.dsh/.credentials.yaml` | DSH 版本是否改了凭据格式；可回退到启动日志 token |
| DSH 进程在跑，但工作台显示「未运行」 | `lsof` 的 COMMAND 列是否匹配 `dsh.processMatch` | 改 `config.json` 的 `processMatch` 后重跑 `./install.sh` |
| 工作区/会话一直是 0 | `config.json` 的 `dsh.home` 是否指向真实 `~/.dsh` | 权限是否可读 |
| 反代没监听 | `lsof -nP -iTCP:8711 -sTCP:LISTEN` | `CADDY_BIN` 是否正确、Caddy 是否启动失败 |
| 安装时提示端口占用 | `lsof -nP -iTCP:<port> -sTCP:LISTEN` | 改 `config.json` 的端口，或停掉占用者 |
| launchd `WARN` 未运行 | `launchctl print` 详情 | 日志里的 Python/Caddy 路径、权限 |
| DSH 重启后 iframe 卡住 | 工作台是否在轮询 | 等 10 秒；点 DSH 视图右上角 ↻ |
| 改了 config 没变化 | 是否重跑 `./install.sh` | 工作台会按文件 mtime 重载，但 launchd 环境变量要重装才更新 |
| 远程设备打不开 `127.0.0.1` 链接 | 是否用了 `127.0.0.1` 地址 | 换成 `http://<mac 的 Tailscale 地址>:8710/` |
| 睡一会儿/合盖后打不开 | `pmset -g` 的 `sleep` 是否为 0 | 见 [07-keep-running.md](07-keep-running.md) |
| 重启 Mac 后打不开 | 是否自动登录、Tailscale 是否登录 | `launchctl print` 两个任务；手动登录后重试 |
| DSH 退出后不回来 | DSH 是否在 launchd 里 | 见 07 第 3 节；或手动打开 DSH |

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
"$TS" status
"$TS" status --json | python3 -c 'import json,sys;d=json.load(sys.stdin);print(len(d.get("Peer") or {}))'
```

- `tailscale status` 正常但页面没有：看工作台日志里 `tailscale status --json` 是否超时/被拦。CLI 被拦时，在 `config.json` 的 `devices` 里补兜底列表。
- 设备名重复/旧节点：把节点名加进 `ignoreDevices`，或在 Tailscale 管理台删除旧设备。
- 本机行一定在；它不参与 ping。

## 时延

```bash
"$TS" ping -c 2 --timeout 2s <peer>
ping -c 1 -t 2 <peer>
```

- `tailscale ping` 有 `in Xms` 但页面 `—`：等 5 秒（缓存 TTL），或点工作台刷新。
- 系统 `ping` 通、`tailscale ping` 不通：手机/平板不回应 ICMP 是正常的，以 `tailscale ping` 为准。
- 全部 `—`：Tailscale CLI 不可用，工作台退到系统 ping 也失败；先恢复 CLI。
- `Relay`：见下节。

## 直连 / IPv6

```bash
"$TS" netcheck
"$TS" ping -c 2 <peer>
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

## 常驻

```bash
pmset -g | grep -E ' sleep| disksleep| womp'
launchctl print "gui/$(id -u)/local.dsh.desktop" 2>/dev/null | grep -E 'state|pid'
```

- `sleep` 不是 0：按 [07-keep-running.md](07-keep-running.md) 关睡眠；
- 工作台/反代在跑，但 Mac 睡醒后打不开：先确认 Tailscale 是否恢复，再看 launchd；
- 重启后两个任务都不在：用户会话没有自动登录，launchd GUI 任务不会启动；先手动登录；
- DSH 退出后不回来：检查 DSH 的 label 是否在 `config.json` 的 `dsh.launchdLabel`，以及 `KeepAlive` 是否生效；
- 不要用 LaunchDaemon 跑 DSH，它需要图形会话。

## Windows 差异

Windows 没有 launchd / `lsof` / `pmset`，对应关系：

| macOS | Windows |
|---|---|
| `launchctl print gui/$(id -u)/local.dsh-workbench.workbench` | `Get-ScheduledTask -TaskName "DSH Workbench"` |
| `launchctl print gui/$(id -u)/local.dsh-workbench.proxy` | `Get-ScheduledTask -TaskName "DSH Proxy"` |
| `lsof -nP -iTCP:8710 -sTCP:LISTEN` | `Get-NetTCPConnection -State Listen \| Where-Object LocalPort -eq 8710` |
| `tail -50 ~/Library/Logs/dsh-workbench.err.log` | `Get-Content "$env:LOCALAPPDATA\dsh-workbench\workbench.err.log" -Tail 50` |
| `tail -50 ~/Library/Logs/dsh-proxy.log` | `Get-Content "$env:LOCALAPPDATA\dsh-workbench\dsh-proxy.log" -Tail 50` |
| `pmset -g` | `powercfg /query`、`powercfg /change` |

### 任务状态

```powershell
Get-ScheduledTask -TaskName "DSH Workbench","DSH Proxy" |
  Select-Object TaskName,State
Get-ScheduledTask -TaskName "DSH Workbench","DSH Proxy" |
  Get-ScheduledTaskInfo | Select-Object TaskName,LastRunTime,LastTaskResult
```

- `State = Ready` 且 `LastTaskResult = 267011`（尚未运行）：当前没有交互登录会话。Windows 的 `AtLogOn` + `Interactive` 任务只在用户登录后跑；锁屏可以，注销/停在登录界面不行。
- 登录后仍不跑：`Start-ScheduledTask -TaskName "DSH Workbench"` 手动拉起，再看 `LastTaskResult`。
- 任务里的 Python 路径是绝对路径；换 Python 或移动仓库后重跑 `install.ps1`。

### 日志与 API

```powershell
Get-Content "$env:LOCALAPPDATA\dsh-workbench\workbench.err.log" -Tail 50
Get-Content "$env:LOCALAPPDATA\dsh-workbench\dsh-proxy.log" -Tail 50
Invoke-RestMethod http://127.0.0.1:8710/api/status | ConvertTo-Json -Depth 3
```

`workbench.err.log` 不存在时，看任务是否用了 `pythonw.exe`（无控制台，错误可能只在事件查看器）；也可临时用 `python.exe` 手动跑一次看栈。

### 端口与防火墙

```powershell
Get-NetTCPConnection -State Listen |
  Where-Object { $_.LocalPort -in 8710,8711 } |
  Select-Object LocalAddress,LocalPort,OwningProcess
```

- 应只有 `127.0.0.1` 和 `100.x` 的 Tailscale 地址，不能有 `0.0.0.0`；
- 别的 tailnet 设备打不开：Windows 防火墙可能只允许了专用网络。首次启动 Python/Caddy 时弹出的「允许访问」要勾选；漏掉时用管理员 PowerShell：
  `New-NetFirewallRule -DisplayName "DSH Workbench" -Direction Inbound -Protocol TCP -LocalPort 8710,8711 -Action Allow -Profile Private`
  只对 Tailscale 网卡放行更稳妥；不要放行「公用网络」。
- 端口被占用：改 `config.json` 的两个端口，重跑 `install.ps1`；不要 kill 不认识的进程。

### DSH 识别

```powershell
Get-Process | Where-Object { $_.ProcessName -like "*DeepSeek*" }
Get-NetTCPConnection -State Listen | Where-Object LocalPort -gt 0 |
  Select-Object LocalAddress,LocalPort,OwningProcess
```

工作台通过 `dsh.processMatch` 匹配进程名（默认 `DeepSeek`），并用 Host 探测确认端口。找不到就把实际进程名前 9 个字符填进 `config.json` 的 `dsh.processMatch`，重跑 `install.ps1`。

### 常见现象

| 现象 | 判断 |
|---|---|
| `install.ps1` 说找不到 Python | Microsoft Store 的 `python` 别名不算；装 python.org 版或用 `-PythonPath` 指定 |
| `install.ps1` 说找不到 Caddy | `winget install --id CaddyServer.Caddy -e`，或 `-CaddyPath` 指定 `caddy.exe` |
| 任务 `Ready` 不跑 | 没有交互登录；先登录，再 `Start-ScheduledTask` |
| 工作台显示「手动」 | `dsh.taskName` 没填，或 DSH 计划任务没创建；按 [07b](07b-windows-keep-running.md) 处理 |
| 另一台设备 401 | 先访问 `:8710/remote-dsh` 拿 cookie；直接开 `:8711` 一定 401 |
| 另一台设备超时 | Windows 防火墙入站规则；确认 `Get-NetTCPConnection` 绑了 `100.x` |
| `verify.ps1` 的 JSON 检查失败 | 确认脚本是 UTF-8 BOM 保存；API 响应先落盘再按 UTF-8 读，不要直接管道 `ConvertFrom-Json` |

## 仍然不行

收集这四样再停手：

1. `./scripts/verify.sh`（macOS）或 `.\scripts\verify.ps1`（Windows）的完整输出；
2. macOS `launchctl print` 两个任务 / Windows `Get-ScheduledTask` 的状态；
3. macOS `~/Library/Logs/` / Windows `%LOCALAPPDATA%\dsh-workbench\` 下日志的最后 30 行；
4. `tailscale status` 与 `tailscale netcheck` 的结果。

贴出来前把真实 IP、tailnet 域名、设备名替换成占位符。
