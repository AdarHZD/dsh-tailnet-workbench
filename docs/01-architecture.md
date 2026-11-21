# 架构

> 一句话：主执行端（macOS 或 Windows）是唯一的 DSH 本体；Tailscale 把设备连成一个私有网；一个只读工作台把「设备时延」和「DSH 状态」放在一页，并从同一页进入 DSH。

每个部署都是独立的：工作台只读**本机**的 Tailscale 状态和 DSH，没有中心服务，也不需要接入作者的 tailnet。

## 组件

| 组件 | 位置 | 作用 | 托管 |
|---|---|---|---|
| DSH 桌面版 | 主执行端 | 唯一的大脑，所有会话在这里 | macOS launchd / Windows 计划任务（见 07 / 07b） |
| 工作台 | 主执行端 | 聚合状态、下发 DSH cookie | macOS launchd `local.dsh-workbench.workbench`；Windows 计划任务 `DSH Workbench` |
| Caddy | 主执行端 | `:8711 → 127.0.0.1:<DSH 端口>`，固定 Host/Origin | 由守护脚本拉起 |
| `dsh-proxy.py` | 主执行端 | 每 10 秒跟随 DSH 动态端口 | macOS launchd `local.dsh-workbench.proxy`；Windows 计划任务 `DSH Proxy` |
| Tailscale | 全部设备 | 组网、打洞、直连/中继 | 系统服务 |
| 接入设备 | iPad / 手机 / 笔记本 | 浏览器打开工作台 | — |

工作台、反代、DSH 都运行在主执行端的**图形登录会话**里（macOS 是 Aqua，Windows 是交互式用户会话）：主执行端睡眠、注销、关机，或 DSH 退出，整条链路就会消失。常开与常驻：macOS 见 [07-keep-running.md](07-keep-running.md)，Windows 见 [07b-windows-keep-running.md](07b-windows-keep-running.md)。

## 数据流

### 工作台状态

```
浏览器 ──GET /api/status──▶ workbench.py
                              ├─ tailscale status --json   → 设备名 / 系统 / tailnet IP / 在线
                              ├─ tailscale ping <ip>       → 往返时延 + Direct/Relay
                              ├─ lsof / PowerShell + Host 探测 → DSH 实际监听端口（不返回给前端）
                              ├─ ~/.dsh/sessions（Windows: %USERPROFILE%\.dsh） → 会话总数 / 最近活动
                              └─ ~/.dsh/storages/workspace.json → 工作区数
```

- `tailscale status` 与 `tailscale ping` 都可能被系统权限拦截（macOS GUI 权限 / Windows 服务会话），所以放在后台线程，请求路径只读上次结果；CLI 不可用时退到 `config.json` 的 `devices` + 系统 ping。
- 在线判定优先用 `tailscale status` 的 `Online`；另外「5 分钟内发过请求」也算在线——手机走中继时 ICMP 常常打不通，但人明明正在刷新页面。
- 前端 5 秒轮询一次；退出后台再回来会立即刷新。

### DSH 远程访问

```
工作台 iframe
   │  src="/remote-dsh"
   ▼
workbench.py
   ├─ 读 ~/.dsh/.credentials.yaml（Windows 在 %USERPROFILE%\.dsh）的 browser-session secret
   ├─ 为 authority 127.0.0.1:8711 签 v1 cookie（30 天）
   └─ 302 → http://<当前主机>:8711/   + Set-Cookie
                 │
                 ▼
              Caddy :8711
                 ├─ bind 127.0.0.1 + Tailscale IP
                 ├─ reverse_proxy 127.0.0.1:<DSH 动态端口>
                 └─ header_up Host/Origin 127.0.0.1:8711
                 │
                 ▼
              DSH Web
```

DSH 只在回环上监听，并且 cookie 按 Host 签名。Caddy 把 Host 固定成 `127.0.0.1:8711` 后：

1. cookie 的 authority 与 Host 永远一致，DSH 重启换端口也不会掉登录；
2. 浏览器看到的是 `http://<主执行端>:8711`，cookie 属于这个地址，iframe 同源；
3. DSH 不需要知道 tailnet 的存在。

## 为什么是这些选择

| 决策 | 选择 | 约束 |
|---|---|---|
| 组网 | Tailscale | 不买公网 IP、不做端口转发；WireGuard 端到端加密；IPv6 可直连 |
| 反代 | Caddy | 单二进制、Caddyfile 可读；`bind`/`header_up` 足够解决 Host 问题 |
| 登录 | 现场签 cookie | DSH 启动日志常被 stdout 缓冲，token 不可靠；cookie 与端口无关 |
| 端口跟随 | 10 秒守护 | DSH 每次重启换端口；Caddy 不支持动态 upstream |
| DSH 展示 | 同页 iframe | 与「顶部标签切换」的效果一致；不需要新窗口/新域名 |
| 工作台 | 单文件 Python + 单页 | 只读、零前端依赖；不引入数据库/框架 |
| IPv6 | 只给 Tailscale 用 | 公网 IPv6 地址不直接暴露任何服务 |

## IPv6 直连是怎么发生的

Tailscale 客户端会给每个节点收集本机可达的地址（含公网 IPv6），通过协调服务器交换候选地址，然后两端同时向对方发包打洞。

- 两端都有公网 IPv6 且防火墙允许回包：UDP 直连，路径里是 `[2408:...]:41641`，时延接近局域网；
- 只有一端有 IPv6 / 防火墙阻断 / 运营商 CGNAT：退回 DERP 中继，工作台显示 `Relay`；
- 不需要在路由器上给主执行端做端口映射，也不需要固定 IPv6 地址。

验证方法见 [04-latency.md](04-latency.md)。

## 刻意不做的部分

- 文件/存储面板、共享盘、跨机同步；
- 入口链接面板（DSH / 工作台 / 管理台按钮）；
- 重启、挂载、删除等写操作；
- 公网入口、域名、登录页、自建中继；
- 前端外部依赖（CDN、字体、图标库）——为了在 DSH 预览/iPad 上离线可用。
