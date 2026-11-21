# 部署

按顺序做，每一步都有完成判据。命令里的 `<...>` 全部替换成你自己的值；不要把这些值提交回仓库。

## 0. 会装什么

| 位置 | 内容 |
|---|---|
| `~/Library/LaunchAgents/local.dsh-workbench.workbench.plist` | 工作台常驻 |
| `~/Library/LaunchAgents/local.dsh-workbench.proxy.plist` | DSH 端口跟随 + Caddy |
| `~/Library/Application Support/dsh-workbench/` | 运行时 Caddyfile、状态 |
| `~/Library/Logs/dsh-workbench*.log`、`dsh-proxy*.log` | 日志 |
| 仓库内 `config.json` | 本机配置（已 gitignore） |

## 1. Tailscale

Mac 和要接入的设备都安装 Tailscale，登录同一个 tailnet。

在 [Tailscale 管理台](https://login.tailscale.com/admin/machines) 做两件事：

1. 每台设备 `⋯ → Disable key expiry`，避免 180 天后集体掉线；
2. 如果要用 MagicDNS 名访问，打开 DNS → MagicDNS，并记下 Mac 的完整域名（形如 `mac.<tailnet>.ts.net`）。

**完成判据**

```bash
tailscale status
tailscale ip -4
```

能看到 Mac 自己和至少一台 peer；`tailscale ip -4` 返回 `100.` 开头的地址。

## 2. IPv6 与直连

不需要给 Mac 配固定 IPv6，也不需要端口映射。只需要确认「两端能拿到公网 IPv6，且能打洞」。

在 Mac 上：

```bash
tailscale netcheck
```

看 `IPv6: yes` 和 `UDP: true`。然后在 Mac 上 ping 一台接入设备：

```bash
tailscale ping -c 2 <peer 的 tailnet IP>
```

输出形如：

```
pong from ipad (100.x.y.z) via [2408:...]:41641 in 12ms
```

- `via [2408:...]`：IPv6 直连，最好；
- `via 1.2.3.4:...`：IPv4 直连，也可以；
- `via DERP(...)`：中继，能连但慢，检查路由器 IPv6 防火墙 / 运营商是否给公网 IPv6。

**完成判据**：至少一台设备是直连（`via` 后面是地址而不是 `DERP`）。全是 DERP 也能继续部署，工作台会显示 `Relay`，但不要期待低时延。

## 3. DSH 本体

确认 DSH 桌面版已经登录，并且 Web 界面在监听：

```bash
lsof -nP -iTCP -sTCP:LISTEN | grep -i DeepSeek
```

应该看到若干 `127.0.0.1:<port>`。工作台会自动识别「返回 DSH 鉴权页」的那个端口，不需要你填。

确认凭据文件存在：

```bash
ls -l ~/.dsh/.credentials.yaml
```

**完成判据**：DSH 进程在跑、凭据文件可读。`/remote-dsh` 的 cookie 就来自这个文件。

> 可选：如果你自己给 DSH 建过 launchd 任务，把它的 label 填进 `config.json` 的 `dsh.launchdLabel`，工作台会显示「launchd」；不确定就留空，显示「手动」不影响使用。

## 4. Caddy

```bash
brew install caddy
caddy version
```

**完成判据**：`caddy` 在 PATH 里，或你知道它的绝对路径（用 `CADDY_BIN` 传给 `install.sh`）。

## 5. 配置与安装

```bash
git clone https://github.com/AdarHZD/dsh-tailnet-workbench.git
cd dsh-tailnet-workbench
cp config.example.json config.json
```

按需修改：

| 字段 | 默认 | 什么时候改 |
|---|---|---|
| `workbench.port` | `8710` | 端口冲突 |
| `dsh.publicPort` | `8711` | 端口冲突；改了要重跑 `install.sh` |
| `dsh.launchdLabel` | `""` | DSH 由 launchd 托管时填 label |
| `devices` | `[]` | 只在 Tailscale CLI 被权限拦截时补兜底列表 |
| `workbench.hosts` | `[]` | 用自定义域名访问工作台时追加 |

安装：

```bash
./install.sh
```

第一次运行只生成 `config.json` 就退出；改完再跑一次。脚本会生成 launchd 任务、启动工作台和反代，并检查两个端口是否被占用。

**完成判据**：输出两条 `OK local.dsh-workbench.*`。

### Tailscale CLI 被权限拦截时

如果工作台设备卡只有本机、没有 peer，先看日志：

```bash
tail -20 ~/Library/Logs/dsh-workbench.err.log
```

确认是 CLI 拿不到结果后，在 `config.json` 里补兜底列表，再重跑 `./install.sh`：

```json
"devices": [
  { "name": "iPad", "kind": "ipad", "os": "iPadOS", "ip": "100.x.y.z" },
  { "name": "手机", "kind": "phone", "os": "Android", "ip": "100.x.y.z" }
]
```

`kind` 只接受 `mac` / `win` / `ipad` / `phone` / `other`，决定图标；`ip` 是 tailnet 地址。不要在仓库里填真实地址。

## 6. 验收

```bash
./scripts/verify.sh
```

它会检查：工作台 200、状态接口不泄露 token/内部端口、反代监听、DSH 在听、`/remote-dsh` 下发 cookie、带 cookie 进 DSH、Tailscale peer 数。

**完成判据**：最后一行「验收通过」。

手工再确认一次：

```bash
# 1) 应该 302，且响应头有 Set-Cookie
curl -si http://<mac 的 Tailscale 地址>:8710/remote-dsh | head -5

# 2) 带 cookie 访问反代，应该 200/303；401 说明 cookie authority 与 Host 改写不一致
curl -s -c /tmp/dsh.jar -o /dev/null http://<mac 的 Tailscale 地址>:8710/remote-dsh
curl -s -b /tmp/dsh.jar -o /dev/null -w '%{http_code}\n' http://<mac 的 Tailscale 地址>:8711/
rm -f /tmp/dsh.jar
```

## 7. 在接入设备上确认

用 iPad / 手机打开 `http://<mac 的 Tailscale 地址>:8710/`：

1. 设备卡里能看到本机和至少一台接入设备；
2. 在线设备有绿色点，时延是 `xx ms`，直连显示 `Direct`，中继显示 `Relay`；
3. 点顶部「DSH」进入 DSH，右上角出现时延数字；点 ↻ 只重载 DSH，不刷新工作台。

## 8. 升级与卸载

升级：

```bash
git pull
./install.sh
```

`config.json` 不入库，升级不会覆盖。

卸载：

```bash
./uninstall.sh
```

它会停掉两个 launchd 任务、清理可能残留的 Caddy 子进程、删除运行时状态；`config.json` 与日志保留。

只手工卸载时注意：`launchctl bootout` 只保证守护脚本退出，Caddy 子进程可能还在，需要按 `~/Library/Application Support/dsh-workbench/caddy.pid` 再 kill 一次。

```bash
launchctl bootout "gui/$(id -u)/local.dsh-workbench.workbench" 2>/dev/null || true
launchctl bootout "gui/$(id -u)/local.dsh-workbench.proxy" 2>/dev/null || true
rm -f ~/Library/LaunchAgents/local.dsh-workbench.*.plist
rm -rf "$HOME/Library/Application Support/dsh-workbench"
```

`config.json` 与日志按需保留。

## 9. 回滚

本方案不改 DSH 本体、不改 `~/.dsh`、不做端口转发，回滚就是停掉两个 launchd 任务并删掉 `config.json`。DSH 仍按原来的方式使用。

## 已知限制

- 只支持 macOS（工作台依赖 `launchctl`、`lsof`、`ifconfig`、`ping -t`）；
- DSH cookie 依赖桌面版内部凭据格式，换大版本后先跑 `./scripts/verify.sh`；
- 工作台没有账号密码，安全性完全依赖 Tailscale ACL。不要把 `:8710` / `:8711` 通过路由器或反向代理暴露到公网。
