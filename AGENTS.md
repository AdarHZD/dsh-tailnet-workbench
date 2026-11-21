# AGENTS.md

这个仓库要由**另一台机器上的 DSH** 读完后独立部署。目标：在**当前机器**上从零部署属于当前用户的**一套独立工作台和 DSH 远程入口**，不是接入作者的工作台。工作台只读当前机器的 Tailscale 状态，不连接作者的 tailnet、地址或凭据。在不暴露公网、不复制任何私有配置的前提下，达到 README 截图的效果。

先读 [README.md](README.md)、部署文档（macOS [docs/02-deploy.md](docs/02-deploy.md)，Windows [docs/02b-windows.md](docs/02b-windows.md)）、常开文档（macOS [docs/07-keep-running.md](docs/07-keep-running.md)，Windows [docs/07b-windows-keep-running.md](docs/07b-windows-keep-running.md)）。安全边界见 [docs/05-security.md](docs/05-security.md)。

## 硬规则

1. 工作台和反代只绑 `127.0.0.1` 与 Tailscale 地址。监听 `0.0.0.0`、端口转发、把 `8710` / `8711` 暴露到公网 IPv6，都属于失败。
2. `config.json` 只留本机。真实 IP、tailnet 名、密钥、设备名、个人路径一律不写进仓库文件、提交信息或截图。
3. 只读 DSH：不修改 DSH 数据目录里的会话与工作区数据，不改 DSH 本体。
4. 端口冲突时改 `config.json`，不 kill 无关进程。
5. 需要 `sudo`、管理员权限或图形界面的动作（关睡眠、自动登录、装 launchd/计划任务）先交给用户执行；一次说清「为什么、做什么、看到什么算成功」，不要猜密码。
6. 每个阶段用给出的命令验收；未通过不进入下一阶段。

## 0. 判断系统，确认主执行端会一直在线

```bash
uname -s          # Darwin = macOS
```

```powershell
$PSVersionTable.PSVersion   # Windows
```

工作台、反代、DSH 都跑在主执行端的**图形登录会话**里。睡眠、注销、关机，或 DSH 退出，远程入口就会消失。

- macOS：`pmset -g` 的 `sleep` 必须为 0；按 [docs/07-keep-running.md](docs/07-keep-running.md) 处理。
- Windows：`powercfg /change standby-timeout-ac 0`；必须保持用户登录（锁屏可以，注销不行）；按 [docs/07b-windows-keep-running.md](docs/07b-windows-keep-running.md) 处理。

**完成判据**：系统不睡；用户确认「保持登录，重启后要么自动登录、要么手动登录一次」；Tailscale 设置为登录时启动。

## 1. 盘点环境

### macOS

```bash
TS=/Applications/Tailscale.app/Contents/MacOS/Tailscale
[ -x "$TS" ] || TS="$(command -v tailscale)"
"$TS" status
"$TS" netcheck
"$TS" ip -4

lsof -nP -iTCP -sTCP:LISTEN | grep -i DeepSeek
ls -l ~/.dsh/.credentials.yaml
command -v caddy && caddy version
python3 --version
```

### Windows

```powershell
$TS = "$env:ProgramFiles\Tailscale\tailscale.exe"
& $TS status
& $TS ip -4
& $TS netcheck

Get-Process | Where-Object { $_.ProcessName -like "*DeepSeek*" }
Test-Path "$env:USERPROFILE\.dsh\.credentials.yaml"
Get-Command caddy -ErrorAction SilentlyContinue
python --version
```

**完成判据**：Tailscale 已登录且至少一个 peer；找到 DSH 监听端口；凭据文件可读；Python ≥ 3.9；Caddy 可用。

- macOS 没 Caddy：`brew install caddy`；没有 Homebrew 时用 `CADDY_BIN` 指定官方二进制。
- Windows 没 Caddy：`winget install --id CaddyServer.Caddy -e`；或用 `install.ps1 -CaddyPath` 指定。
- 没有 IPv6 时继续，但直连可能退回 Relay；用 `tailscale ping <peer>` 确认实际路径。

## 2. DSH 常驻

工作台只显示状态，不负责把 DSH 拉起来。

- macOS：按 [docs/07-keep-running.md](docs/07-keep-running.md) 第 3 节创建 launchd 任务，得到 label（示例 `local.dsh.desktop`）。
- Windows：按 [docs/07b-windows-keep-running.md](docs/07b-windows-keep-running.md) 第 3 节创建计划任务（示例 `DSH Desktop`）。

**完成判据**：macOS `launchctl print "gui/$(id -u)/<label>"` 的 `state = running`；Windows `Get-ScheduledTask -TaskName "DSH Desktop"` 的 `State = Running`；DSH 界面可访问。
用户明确不用常驻时，接受工作台显示「手动」，并在最终报告里写明「重启后需要手动打开 DSH」。

## 3. 生成配置

```bash
cp config.example.json config.json
```

```powershell
Copy-Item config.example.json config.json
```

按需只改：

- `workbench.port`（默认 8710）与 `dsh.publicPort`（默认 8711），冲突时换；
- macOS：`dsh.launchdLabel` 填上一步的 label；
- Windows：`dsh.taskName` 填上一步的任务名；
- `devices` 留空即可，优先从 Tailscale 自动发现；CLI 被权限拦截时才补兜底列表（见 02 / 02b）。

**完成判据**：`python3 -m json.tool config.json`（Windows 用 `Get-Content config.json -Raw | ConvertFrom-Json`）通过；两个端口在本机都没被占用。

## 4. 安装

macOS：

```bash
./install.sh
```

Windows：

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

**完成判据**：macOS 输出两条 `OK local.dsh-workbench.*`；Windows 输出 `OK  DSH Workbench` / `OK  DSH Proxy`。任何 `WARN` 先看日志（macOS `~/Library/Logs/`，Windows `%LOCALAPPDATA%\dsh-workbench\`），修好再继续。

Windows 任务显示 `Ready` 且没有交互登录会话时，先登录 Windows 再 `Start-ScheduledTask`；这是登录会话限制，不是脚本故障。

## 5. 验收

macOS：

```bash
./scripts/verify.sh
```

Windows：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\verify.ps1
```

**完成判据**：最后一行「验收通过」。重点确认：

- `/remote-dsh` 返回 302 且下发 cookie；
- 带 cookie 访问 `:8711` 返回 200/303，而不是 401/502；
- 工作台 DSH 主机行显示「运行中」+「launchd」/「计划任务」（或用户接受的「手动」）。

## 6. 在接入设备上确认

用 iPad / 手机打开 `http://<主执行端的 Tailscale 地址>:8710/`：

- 设备卡里能看到本机与至少一台接入设备，在线点、时延、Direct/Relay 正常；
- 点顶部「DSH」能进 DSH 界面，右上角有时延数字；
- 断网重连或 DSH 重启后，DSH 视图能自己恢复，不需要手动贴 token。

## 最终清单

- [ ] 主执行端不睡（macOS `sleep 0`；Windows `standby-timeout-ac 0`）；
- [ ] 用户保持登录，重启后能恢复（自动登录或手动登录）；
- [ ] DSH 在 launchd / 计划任务里运行（或用户书面接受手动启动）；
- [ ] `verify.sh` / `verify.ps1` 输出「验收通过」；
- [ ] 工作台 DSH 主机行是「运行中」+「launchd」/「计划任务」；
- [ ] 另一台设备能打开工作台并进入 DSH。

## 失败时

按 [docs/06-troubleshooting.md](docs/06-troubleshooting.md) 的症状表排查；Windows 先看文末「Windows 差异」。**同一原因失败两次就停**：记录现象、已执行的命令、日志末尾，交给用户决定，不第三次盲试。

## 改 UI 时

先读 [docs/03-ui-spec.md](docs/03-ui-spec.md)。颜色令牌、时延阈值、图标尺寸、文案规则都在里面；不要新增存储、入口、文件面板，也不要给状态卡加解释性文字。
