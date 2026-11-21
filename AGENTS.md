# AGENTS.md

这个仓库要由**另一台机器上的 DSH** 读完后独立部署。目标：在不暴露公网、不复制任何私有配置的前提下，让工作台和 DSH 远程入口跑起来，并达到 README 截图的效果。

先读 [README.md](README.md)、[docs/02-deploy.md](docs/02-deploy.md)、[docs/07-keep-running.md](docs/07-keep-running.md)。安全边界见 [docs/05-security.md](docs/05-security.md)。

## 硬规则

1. 工作台和反代只绑 `127.0.0.1` 与 Tailscale 地址。监听 `0.0.0.0`、端口转发、把 `8710` / `8711` 暴露到公网 IPv6，都属于失败。
2. `config.json` 只留本机。真实 IP、tailnet 名、密钥、设备名、个人路径一律不写进仓库文件、提交信息或截图。
3. 只读 DSH：不修改 `~/.dsh` 里的会话与工作区数据，不改 DSH 本体。
4. 端口冲突时改 `config.json`，不 kill 无关进程。
5. 需要 `sudo` 或图形界面的动作（关睡眠、自动登录、装 launchd）先交给用户执行；一次说清「为什么、做什么、看到什么算成功」，不要猜密码。
6. 每个阶段用给出的命令验收；未通过不进入下一阶段。

## 部署顺序

### 0. 确认主执行端会一直在线

工作台、反代、DSH 都在 Mac 的图形登录会话里。Mac 睡眠、注销、关机，或 DSH 退出，远程入口就会消失。

```bash
pmset -g | grep -E ' sleep| disksleep| womp'
```

**完成判据**：`sleep 0`（`disksleep 0` 是建议值，不影响常驻）；用户确认「保持登录，重启后要么自动登录、要么手动登录一次」；Tailscale 设置为登录时启动。
不满足就先按 [docs/07-keep-running.md](docs/07-keep-running.md) 处理，不要直接进入安装。

### 1. 盘点环境

macOS 的 Tailscale CLI 不一定在 PATH 里：

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

**完成判据**：Tailscale 已登录且至少一个 peer；`netcheck` 能看到 IPv6；找到 DSH 监听端口；凭据文件可读；Python ≥ 3.9；Caddy 可用（没有就 `brew install caddy`；没有 Homebrew 时用 `CADDY_BIN` 指定官方二进制）。

没有 IPv6 时继续，但直连可能退回 Relay；用 `"$TS" ping <peer>` 确认实际路径。

### 2. DSH 常驻

工作台只显示状态，不负责把 DSH 拉起来。按 [docs/07-keep-running.md](docs/07-keep-running.md) 第 3 节创建 launchd 任务，得到 label（示例 `local.dsh.desktop`）。

**完成判据**：`launchctl print "gui/$(id -u)/<label>"` 的 `state = running`，且 DSH 界面可访问。
如果用户明确不用 launchd，就接受工作台显示「手动」，并在最终报告里写明「重启后需要手动打开 DSH」。

### 3. 生成配置

```bash
cp config.example.json config.json
```

按需只改三类值：

- `workbench.port`（默认 8710）与 `dsh.publicPort`（默认 8711），冲突时换；
- `dsh.launchdLabel`：上一步的 label；不用 launchd 就留空；
- `devices`：留空即可，优先从 Tailscale 自动发现；CLI 被权限拦截时才补兜底列表（见 docs/02）。

**完成判据**：`python3 -m json.tool config.json` 通过；两个端口在本机都没被占用。

### 4. 安装

```bash
./install.sh
```

**完成判据**：输出两条 `OK local.dsh-workbench.*`。任何一条 `WARN` 都先看 `~/Library/Logs/dsh-workbench.err.log`、`dsh-proxy-watcher.err.log`，修好再继续。

### 5. 验收

```bash
./scripts/verify.sh
```

**完成判据**：最后一行是「验收通过」。重点确认：

- `/remote-dsh` 返回 302 且下发 cookie；
- 带 cookie 访问 `:8711` 返回 200/303，而不是 401/502；
- 工作台 Mac DSH 行显示「运行中」+「launchd」（或用户接受的「手动」）。

### 6. 在接入设备上确认

用 iPad / 手机打开 `http://<mac 的 Tailscale 地址>:8710/`：

- 设备卡里能看到本机与至少一台接入设备，在线点、时延、Direct/Relay 正常；
- 点顶部「DSH」能进 DSH 界面，右上角有时延数字；
- 断网重连或 DSH 重启后，DSH 视图能自己恢复，不需要手动贴 token。

## 最终清单

- [ ] `pmset -g`：`sleep 0`；
- [ ] DSH 在 launchd 里 `state = running`（或用户书面接受手动启动）；
- [ ] `./scripts/verify.sh` 输出「验收通过」；
- [ ] 工作台「Mac DSH」行是「运行中」+「launchd」；
- [ ] 另一台设备能打开工作台并进入 DSH。

## 失败时

按 [docs/06-troubleshooting.md](docs/06-troubleshooting.md) 的症状表排查。**同一原因失败两次就停**：记录现象、已执行的命令、日志末尾，交给用户决定，不第三次盲试。

## 改 UI 时

先读 [docs/03-ui-spec.md](docs/03-ui-spec.md)。颜色令牌、时延阈值、图标尺寸、文案规则都在里面；不要新增存储、入口、文件面板，也不要给状态卡加解释性文字。
