# AGENTS.md

这个仓库要由**另一台机器上的 DSH** 读完后独立部署。目标：在不暴露公网、不复制任何私有配置的前提下，把工作台和 DSH 远程入口跑起来，并达到与 README 截图一致的效果。

先读 [README.md](README.md) 和 [docs/02-deploy.md](docs/02-deploy.md)。安全边界见 [docs/05-security.md](docs/05-security.md)。

## 硬规则

1. 工作台和反代只绑 `127.0.0.1` 与 Tailscale 地址。监听 `0.0.0.0`、端口转发、把 `8710` / `8711` 暴露到公网 IPv6，都属于失败。
2. `config.json` 只留本机。真实 IP、tailnet 名、密钥、设备名、个人路径一律不写进仓库文件、提交信息或截图。
3. 只读 DSH：不修改 `~/.dsh` 里的会话与工作区数据，不改 DSH 本体。
4. 端口冲突时改 `config.json`，不 kill 无关进程。
5. 每个阶段用给出的命令验收；未通过不进入下一阶段。

## 部署顺序

### 1. 盘点环境

```bash
tailscale status
tailscale netcheck
lsof -nP -iTCP -sTCP:LISTEN | grep -i DeepSeek
command -v caddy && caddy version
python3 --version
```

**完成判据**：Tailscale 已登录且至少有一个 peer；`netcheck` 能看到 IPv6；能找到 DSH 的监听端口；Python ≥ 3.9；Caddy 可用（没有就 `brew install caddy`）。

没有 IPv6 时继续部署，但直连可能退回 Relay；在 `tailscale ping <peer>` 的输出里确认实际路径。

### 2. 生成配置

```bash
cp config.example.json config.json
```

按需只改两类值：

- `workbench.port`（默认 8710）与 `dsh.publicPort`（默认 8711），冲突时换成未占用端口；
- `dsh.launchdLabel`：只有把 DSH 交给 launchd 托管时才填，否则留空，工作台显示「手动」。

`devices` 留空即可，设备列表优先从 `tailscale status --json` 自动发现；只有 CLI 被系统权限拦截时，才在 `devices` 里补兜底列表（见 docs/02）。

**完成判据**：`python3 -m json.tool config.json` 通过；两个端口在本机都没被占用。

### 3. 安装

```bash
./install.sh
```

**完成判据**：输出两条 `OK local.dsh-workbench.*`。任何一条 `WARN` 都先看 `~/Library/Logs/dsh-workbench.err.log`、`dsh-proxy-watcher.err.log`，修好再继续。

### 4. 验收

```bash
./scripts/verify.sh
```

**完成判据**：最后一行是「验收通过」。重点确认两件事：

- `/remote-dsh` 返回 302 且下发 cookie；
- 带 cookie 访问 `:8711` 返回 200/303，而不是 401/502。

### 5. 在接入设备上确认

用 iPad / 手机打开 `http://<mac 的 Tailscale 地址>:8710/`：

- 设备卡里能看到本机与至少一台接入设备，在线点、时延、Direct/Relay 正常；
- 点顶部「DSH」能进 DSH 界面，页面右上角有时延数字；
- 断网重连或 DSH 重启后，DSH 视图能自己恢复，不需要手动贴 token。

## 失败时

按 [docs/06-troubleshooting.md](docs/06-troubleshooting.md) 的症状表排查。**同一原因失败两次就停**：记录现象、已试过的命令、日志末尾，交给用户决定，不第三次盲试。

## 改 UI 时

先读 [docs/03-ui-spec.md](docs/03-ui-spec.md)。颜色令牌、时延阈值、图标尺寸、文案规则都在里面；不要新增存储、入口、文件面板，也不要给状态卡加解释性文字。
