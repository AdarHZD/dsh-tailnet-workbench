# 部署（Windows）

> macOS 用 [02-deploy.md](02-deploy.md)。本页假设 DSH 桌面版已经安装、登录、API 可用。

Windows 和 macOS 的组件完全一样，只是托管方式从 launchd 换成计划任务，端口发现从 `lsof` 换成 PowerShell。工作台、反代、cookie 链路不变。

## 0. 会装什么

| 位置 | 内容 |
|---|---|
| 计划任务 `DSH Workbench` | 工作台常驻（用户登录后启动） |
| 计划任务 `DSH Proxy` | DSH 端口跟随 + Caddy |
| `%LOCALAPPDATA%\dsh-workbench\` | Caddyfile、Caddy PID、日志、`caddy.path` |
| 仓库内 `config.json` | 本机配置（已 gitignore） |
| 可选：计划任务 `DSH Desktop` | DSH 常驻（见 [07b](07b-windows-keep-running.md)） |

两个任务都以**当前用户**、`Interactive` 登录类型运行，只在用户登录后启动；锁屏不影响，注销或停在登录界面会停止。

## 1. 主执行端保持在线

先按 [07b-windows-keep-running.md](07b-windows-keep-running.md) 处理睡眠、自动登录和 DSH 常驻。最少做到：

```powershell
powercfg /change standby-timeout-ac 0
powercfg /change hibernate-timeout-ac 0
powercfg /change monitor-timeout-ac 10
```

**完成判据**：接电源时系统不待机；用户保持登录；Tailscale 随登录启动。

## 2. Tailscale

安装 Tailscale 并登录同一个 tailnet。CLI 通常在：

```powershell
$TS = "$env:ProgramFiles\Tailscale\tailscale.exe"
& $TS status
& $TS ip -4
& $TS netcheck
```

**完成判据**：`status` 至少有一个 peer；`ip -4` 返回 `100.` 开头的地址；`netcheck` 显示 `IPv6: yes`、`UDP: true`。

在 Tailscale 管理台给设备 `Disable key expiry`，避免 180 天后掉线。

## 3. DSH 本体

确认 DSH 已登录，并且 Web 端口在监听：

```powershell
Get-Process | Where-Object { $_.ProcessName -like "*DeepSeek*" }
Get-NetTCPConnection -State Listen |
  Where-Object { $_.LocalAddress -in @("127.0.0.1", "::1") } |
  Select-Object LocalAddress,LocalPort,OwningProcess
```

确认凭据文件：

```powershell
Test-Path "$env:USERPROFILE\.dsh\.credentials.yaml"
```

**完成判据**：DSH 进程在跑、凭据文件可读。工作台会自动识别「返回 DSH 鉴权页」的端口，不需要填端口。

> DSH 默认装在 `%LOCALAPPDATA%\Programs\DeepSeek Harness\`；数据目录默认 `%USERPROFILE%\.dsh`。不在默认位置时改 `config.json` 的 `dsh.home` / `dsh.credentials`。

## 4. Python

需要 Python 3.9+，且必须是 python.org 或 winget 安装的真实 Python；Microsoft Store 的 `python` 别名不可用。

```powershell
winget install --id Python.Python.3.12 -e
python --version
```

装完后新开一个 PowerShell 再试。`python` 不在 PATH 时，安装时用 `-PythonPath` 指定：

```powershell
.\install.ps1 -PythonPath "C:\Python312\python.exe"
```

## 5. Caddy

```powershell
winget install --id CaddyServer.Caddy -e
caddy version
```

没有 winget 时，从 [caddyserver.com/download](https://caddyserver.com/download) 下载 Windows amd64 的 `caddy.exe`，放到：

```
%LOCALAPPDATA%\dsh-workbench\bin\caddy.exe
```

或安装时指定：

```powershell
.\install.ps1 -CaddyPath "C:\Tools\caddy.exe"
```

## 6. 配置

```powershell
git clone https://github.com/AdarHZD/dsh-tailnet-workbench.git
cd dsh-tailnet-workbench
Copy-Item config.example.json config.json
notepad config.json
```

按需修改：

| 字段 | 默认 | 什么时候改 |
|---|---|---|
| `hostName` | `DSH 主机` | 设备列表里本机的显示名 |
| `workbench.port` | `8710` | 端口冲突 |
| `dsh.publicPort` | `8711` | 端口冲突；改了要重跑 `install.ps1` |
| `dsh.taskName` | `""` | 已创建 DSH 计划任务时填任务名，工作台才显示「计划任务」 |
| `dsh.processMatch` | `DeepSeek` | DSH 进程名不是 DeepSeek 时填实际进程名前 9 个字符 |
| `dsh.home` / `dsh.credentials` | `~/.dsh` | DSH 数据目录不在默认位置时改 |
| `devices` | `[]` | 只在 Tailscale CLI 被权限拦截时补兜底列表 |
| `ignoreDevices` | `[]` | 不想显示的 tailnet 设备名 |

`dsh.launchdLabel` 在 Windows 上不使用；保留为空即可。

**完成判据**：`Get-Content config.json -Raw | ConvertFrom-Json` 通过；两个端口没有被占用：

```powershell
Get-NetTCPConnection -State Listen | Where-Object { $_.LocalPort -in 8710,8711 }
```

## 7. 安装

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

脚本会：

1. 检查 Python / Caddy / Tailscale；
2. 生成 `config.json`（没有时先复制模板并退出）；
3. 停掉旧任务，清理本仓库状态目录里的 Caddy；
4. 检查两个端口；
5. 创建并启动 `DSH Workbench`、`DSH Proxy` 两个计划任务；
6. 打印工作台地址。

**完成判据**：输出两行 `OK  DSH Workbench` / `OK  DSH Proxy`。若显示 `WARN ... 未运行（Ready）`，说明当前没有交互登录会话；先登录 Windows，再运行：

```powershell
Start-ScheduledTask -TaskName "DSH Workbench"
Start-ScheduledTask -TaskName "DSH Proxy"
```

> 计划任务只在用户登录后运行，这是 Windows 的登录会话限制，不是故障。不要把工作台改成 Windows 服务：服务跑在 Session 0，拿不到 DSH 的图形会话。

## 8. 验收

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\verify.ps1
```

它会检查：

- 工作台 200；
- `/api/status` 是有效 JSON，且不泄露 token / 内部端口；
- Caddy 反代在监听；
- DSH 进程在跑；
- `/remote-dsh` 返回 302 + `Set-Cookie`；
- 带 cookie 访问 `:8711` 返回 200/303；
- Tailscale 至少一个 peer；
- 系统待机超时为 0；
- `dsh.taskName` 对应的计划任务在运行（未填时只警告）。

**完成判据**：最后一行「验收通过」。手工再确认一次：

```powershell
curl.exe -s -c "$env:TEMP\dsh.jar" -o NUL -w "%{http_code}\n" http://<主执行端 tailnet IP>:8710/remote-dsh
curl.exe -s -b "$env:TEMP\dsh.jar" -o NUL -w "%{http_code}\n" http://<主执行端 tailnet IP>:8711/
Remove-Item "$env:TEMP\dsh.jar"
```

期望 `302` → `200`。

## 9. 防火墙

首次启动 Python / Caddy 时，Windows 可能弹出「允许访问」。勾选**专用网络**；不要勾「公用网络」。

如果别的 tailnet 设备打不开，用管理员 PowerShell 只对 Tailscale 网卡放行：

```powershell
New-NetFirewallRule -DisplayName "DSH Workbench (Tailscale)" `
  -Direction Inbound -Protocol TCP -LocalPort 8710,8711 `
  -Action Allow -InterfaceAlias "Tailscale"
```

**完成判据**：另一台 tailnet 设备能打开 `http://<主执行端 tailnet IP>:8710/`；直接开 `:8711` 返回 401 是正常的（没有 cookie）。

## 10. 在接入设备上确认

用 iPad / 手机打开 `http://<主执行端 tailnet IP>:8710/`：

1. 设备卡里能看到本机与至少一台接入设备；
2. 在线设备有绿色点，时延是 `xx ms`，直连 `Direct`，中继 `Relay`；
3. 点顶部「DSH」能进入，右上角有时延。

## 11. 升级与卸载

升级：

```powershell
git pull
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

`config.json` 不入库，升级不会覆盖。

卸载：

```powershell
powershell -ExecutionPolicy Bypass -File .\uninstall.ps1
```

它会停掉并删除两个计划任务、按 PID 清理 Caddy、删除 `%LOCALAPPDATA%\dsh-workbench`；`config.json` 与仓库保留。

## 12. 已知限制

- 计划任务需要用户交互登录；停在登录界面不会启动；
- 工作台绑定 `127.0.0.1` + Tailscale IPv4 地址，不做 `0.0.0.0` 监听；
- Windows 防火墙、杀毒软件可能拦截 Python/Caddy 的入站连接；
- DSH 的 cookie 依赖桌面版内部凭据格式，换大版本后先跑 `verify.ps1`；
- 本次验证使用假 DSH 进程 + 真实 DSH 凭据签名；真实 DSH 登录后的端到端效果需在实际机器上再确认一次。
