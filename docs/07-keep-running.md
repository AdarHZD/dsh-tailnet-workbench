# 主执行端常开与 DSH 常驻

工作台、反代、DSH 都跑在 **Mac 的图形登录会话**里。下面任何一条不成立，远程入口就会消失：

- Mac 睡眠 / 关机；
- 用户注销（锁屏不算）；
- DSH 退出；
- Tailscale 没有随登录启动。

这一页给的是最小可用做法。需要 `sudo` 或图形界面的步骤，交给 Mac 的所有者执行。

## 1. 系统不睡

系统设置 → 能源（笔记本是「电池」）→：

- 「显示器关闭时防止自动进入睡眠」打开；
- 「唤醒以供网络访问」打开；
- 「使硬盘进入睡眠」关闭。

或者用命令（需要密码）：

```bash
sudo pmset -a sleep 0 disksleep 0 displaysleep 10 womp 1
pmset -g
```

期望看到 `sleep 0`；`disksleep 0` 是建议值（磁盘睡眠不影响远程入口，但可能带来偶发延迟）。

- 显示器可以睡，系统不能睡；
- 笔记本合盖仍会睡眠。要么接电源并外接显示器使用合盖模式，要么保持开盖；
- `womp` 只在支持的网卡/网络下有效，不能替代「不睡」。

## 2. 保持登录

锁屏不影响进程；**注销会杀掉整个用户会话**，launchd 任务也随之停止。

重启后如果要无人值守恢复，需要自动登录：

系统设置 → 用户与群组 → 自动登录为 → 选择你的用户。

- 自动登录要求关闭 FileVault；这是安全取舍，由机器所有者决定；
- 开着 FileVault 时，重启后必须手动登录一次，工作台才会回来；
- 不要开启「闲置 X 分钟后注销」。

## 3. DSH 常驻

先确认应用路径：

```bash
APP="/Applications/DeepSeek Harness.app"
test -x "$APP/Contents/MacOS/DeepSeek Harness" && echo OK
```

`APP` 路径不同就改 `APP`；如果 `Contents/MacOS/` 下的可执行文件名不是 `DeepSeek Harness`，按实际文件名改下面的 `<string>`。

如果 DSH 正在手动运行，先退出（⌘Q），避免 launchd 拉起第二个实例；如果 DSH 自己也有「登录时启动」，先关掉，只留一个入口。然后创建任务：

```bash
APP="/Applications/DeepSeek Harness.app"
LABEL="local.dsh.desktop"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$APP/Contents/MacOS/DeepSeek Harness</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ThrottleInterval</key><integer>15</integer>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/dsh-launcher.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/dsh-launcher.err.log</string>
</dict>
</plist>
EOF

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
launchctl print "gui/$(id -u)/$LABEL" | grep -E 'state|pid'
```

然后把 label 填进 `config.json`：

```json
"dsh": {
  "launchdLabel": "local.dsh.desktop"
}
```

重跑 `./install.sh`，工作台 Mac DSH 行应显示「常驻托管 launchd」。

- 不用 launchd 也可以：在 DSH 自己的设置里打开「登录时启动」，并且不要退出；工作台会显示「手动」；
- 不要把 DSH 交给 LaunchDaemon（系统级）；它需要图形会话；
- DSH 更新器重启自身后，launchd 的 `KeepAlive` 会把它拉回来。

## 4. Tailscale 随登录启动

Tailscale 菜单里确认「登录时启动」是开的。重启后：

```bash
TS=/Applications/Tailscale.app/Contents/MacOS/Tailscale
[ -x "$TS" ] || TS="$(command -v tailscale)"
"$TS" status
```

期望能看到本机和至少一台 peer。

## 5. 验收

```bash
pmset -g | grep -E ' sleep| disksleep| womp'
launchctl print "gui/$(id -u)/local.dsh.desktop" | grep 'state ='
lsof -nP -iTCP -sTCP:LISTEN | grep -i DeepSeek
./scripts/verify.sh
```

工作台上应同时看到：

- 「DSH 界面」绿色「运行中」；
- 「常驻托管」绿色「launchd」；
- 设备卡有时延与 Direct/Relay。

重启验证（需要用户同意，属于破坏性动作）：重启 Mac，等 60 秒，打开工作台，确认 DSH 标签可用、设备时延出现。
没有自动登录时，重启后先手动登录，这是预期行为。

## 6. 取舍

- Mac 长期不睡会增加功耗与发热；Mac mini 影响小，笔记本建议接电源；
- 自动登录降低物理安全，只在可信环境使用；
- macOS 系统更新会重启，重启后仍受自动登录与 launchd 约束；
- 如果 Mac 必须睡眠，远程访问不保证；Tailscale 不能把睡眠中的 Mac 唤醒到可用状态。
