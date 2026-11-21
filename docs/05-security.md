# 安全边界

## 信任边界只有一个：tailnet

工作台和反代都不做账号密码、不做公网监听。谁能进 tailnet，谁就能打开 `:8710` 和 `:8711`。所以：

- 只把自己的设备加入 tailnet；
- 不接受陌生设备的共享邀请；
- 设备丢失时，立刻在 Tailscale 管理台移除该设备并吊销 key；
- 需要更细的权限时，用 Tailscale ACL 限定只有指定设备能访问 Mac 的 `tcp:8710` 和 `tcp:8711`。

工作台不是公网服务。把它接到路由器端口映射、公网反向代理、`tailscale funnel`，都会破坏这个边界。

## 监听范围

| 服务 | 必须绑定 | 禁止 |
|---|---|---|
| 工作台 | `127.0.0.1` + Mac 的 Tailscale 地址 | `0.0.0.0`、局域网地址、公网 IPv6 |
| Caddy 反代 | `127.0.0.1` + Mac 的 Tailscale 地址 | 同上 |

验证：

```bash
lsof -nP -iTCP:8710 -sTCP:LISTEN
lsof -nP -iTCP:8711 -sTCP:LISTEN
```

不应出现 `*:` 或 `0.0.0.0:`。`scripts/verify.sh` 会检查这一条。

## 代码会碰什么数据

| 数据 | 用途 | 是否离开本机 |
|---|---|---|
| `~/.dsh/.credentials.yaml` 的 browser-session secret | 为 `127.0.0.1:<publicPort>` 签 cookie | 否，只在内存里参与 HMAC |
| `~/.dsh/sessions/` | 数会话总数、最近活动时间 | 只返回数字，不返回工作区名 |
| `~/.dsh/storages/workspace.json` | 数工作区 | 只返回数量 |
| `tailscale status --json` | 设备名、系统、tailnet IP、在线 | 返回给 tailnet 内的浏览器 |
| `lsof` | 找 DSH 实际监听端口 | 只在服务端用，不返回 |

## API 返回白名单

`/api/status` 只返回：

```
now, uiAt,
host: name, ip, managed, running, alive, dsh.instance,
      sessions.total, sessions.lastActivity, workspaces,
clients[]: name, kind, os, ip, online, note, via, rtt,
dsh_ping, issues[]
```

**不返回**：DSH 启动 token、带 token 的 URL、DSH 内部监听端口、工作区名字、凭据内容、设备 DNS 全名、tailnet 名、系统用户名、个人路径。

`scripts/verify.sh` 会断言 `host.dsh` 里没有 `token` / `url` / `port`。

## cookie 的边界

`/remote-dsh` 现场签的 cookie：

- 名字由 authority 哈希得到，值由本机 secret HMAC 签名；
- `HttpOnly`、`SameSite=Strict`、`Path=/`、30 天；
- 不设 `Secure`：工作台走 tailnet 内的 HTTP，设了 `Secure` 浏览器就不会回传；传输加密由 WireGuard 提供；
- cookie 的 authority 固定为 `127.0.0.1:<publicPort>`，与 Caddy 的 Host 改写一致。改 `dsh.publicPort` 会让旧 cookie 失效，重新进一次即可。

## 日志

- Caddy 访问日志被丢弃（`log { output discard }`），避免把设备 IP、URL、cookie 写进磁盘；
- 工作台与守护脚本的日志在 `~/Library/Logs/`，只记录启动、端口跟随、错误，不记录 token 和 cookie；
- launchd 的 stderr 可能包含异常栈，贴给别人前先扫一遍。

## 仓库卫生

入库前检查：

```bash
# 真实 tailnet 地址、局域网地址、tailnet 域名、常见密钥名、个人路径
grep -rnE '100\.[0-9]+\.[0-9]+\.[0-9]+|192\.168\.|10\.[0-9]+\.|\.ts\.net|tskey-|BEGIN (OPENSSH|RSA|PRIVATE)|/Users/[^/ ]+' .
```

- `config.json`、`*.log`、截图原图都在 `.gitignore`；
- 截图只使用示例数据（`100.64.0.x` 这类文档地址），不截真实设备名；
- 提交信息不含真实主机名、邮箱、内部项目名；
- 如果曾经提交过凭据：不要只删文件，重写历史，并轮换对应密钥（Tailscale node key、DSH 登录凭据、SSH key）。

## 泄漏后的处置

| 泄漏项 | 处置 |
|---|---|
| Tailscale 设备 key | 管理台移除设备 → 重新登录 |
| DSH 凭据文件 | 在 DSH 里退出登录/重置会话，重新登录 |
| SSH 私钥 | 从 `authorized_keys` 移除对应公钥，换新 key |
| tailnet 名/IP | 仅靠 ACL 限制访问；必要时重建 tailnet |

## 发布前最终检查

1. `scripts/verify.sh` 通过；
2. `lsof` 确认两个端口没有绑 `0.0.0.0`；
3. 全仓 grep 无真实 IP / tailnet 域名 / 密钥 / 个人路径；
4. 截图与 README 不含真实设备名；
5. `git log -p` 里没有历史泄漏；
6. `config.json` 没有被 `git add`。
