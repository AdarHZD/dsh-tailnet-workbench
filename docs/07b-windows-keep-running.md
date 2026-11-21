# 主执行端常开与 DSH 常驻（Windows）

> macOS 见 [07-keep-running.md](07-keep-running.md)。

工作台、反代、DSH 都跑在 **Windows 的交互式用户会话**里。下面任何一条不成立，远程入口就会消失：

- 系统睡眠 / 休眠；
- 用户注销，或停在登录界面；
- DSH 退出；
- Tailscale 没有随登录启动。

锁屏不算注销，锁屏后进程仍在。需要管理员权限或图形界面的步骤，交给主执行端的所有者执行。

## 1. 系统不睡

设置 → 系统 → 电源和电池 → 屏幕和睡眠：

- 「接通电源时，使设备进入睡眠状态」设为「从不」；
- 「接通电源时，使设备进入休眠状态」设为「从不」；
- 屏幕可以 10 分钟后关闭，不影响进程。

或者用管理员 PowerShell：

```powershell
powercfg /change standby-timeout-ac 0
powercfg /change hibernate-timeout-ac 0
powercfg /change monitor-timeout-ac 10
powercfg /query
```

期望 `standby-timeout-ac` 为 `0`。笔记本合盖仍可能睡眠；要么接电源并设置「合盖不采取任何操作」，要么保持开盖。

## 2. 保持登录

注销会杀掉整个用户会话，计划任务随之停止。重启后如果要无人值守恢复，需要自动登录：

1. `Win + R` → `netplwiz`；
2. 取消勾选「要使用本计算机，用户必须输入用户名和密码」；
3. 输入一次密码确认。

- 自动登录会降低物理安全，只在可信环境使用；
- 开了 BitLocker 时，重启后仍可能需要先解锁磁盘；这不是 DSH 能绕过的；
- Windows 更新重启后会回到登录界面；没有自动登录时，需要人工登录一次；
- 不要设置「闲置后注销」。

## 3. DSH 常驻

先确认 DSH 可执行文件：

```powershell
$Exe = Join-Path $env:LOCALAPPDATA "Programs\DeepSeek Harness\DeepSeek Harness.exe"
Test-Path $Exe
```

路径不同就改 `$Exe`。如果 DSH 自己已经有「登录时启动」，二选一，不要同时开两个入口。

用计划任务在登录后拉起 DSH：

```powershell
$Exe = Join-Path $env:LOCALAPPDATA "Programs\DeepSeek Harness\DeepSeek Harness.exe"
$User = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$Action = New-ScheduledTaskAction -Execute $Exe
$Trigger = New-ScheduledTaskTrigger -AtLogOn
$Principal = New-ScheduledTaskPrincipal -UserId $User -LogonType Interactive -RunLevel Limited
$Settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
  -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) `
  -ExecutionTimeLimit ([TimeSpan]::Zero)

Register-ScheduledTask -TaskName "DSH Desktop" -Action $Action -Trigger $Trigger `
  -Settings $Settings -Principal $Principal -Force
Start-ScheduledTask -TaskName "DSH Desktop"
```

检查：

```powershell
Get-ScheduledTask -TaskName "DSH Desktop" | Select-Object TaskName,State
Get-Process | Where-Object { $_.ProcessName -like "*DeepSeek*" }
```

把任务名填进 `config.json`：

```json
"dsh": {
  "taskName": "DSH Desktop"
}
```

重跑 `install.ps1`，工作台「Windows DSH」行应显示「常驻托管 计划任务」。

- 不要用 Windows 服务跑 DSH：服务在 Session 0，没有桌面，DSH 的图形会话起不来；
- 不要把 DSH 的 `KeepAlive` 交给服务管理器；
- DSH 更新器重启自身后，计划任务的 `RestartCount` 会把它拉回来；
- 不用计划任务也可以：DSH 自带的登录启动 + 不退出，工作台会显示「手动」。

## 4. Tailscale 随登录启动

Tailscale 托盘 → Settings → 打开「Start Tailscale with Windows」。

```powershell
$TS = "$env:ProgramFiles\Tailscale\tailscale.exe"
& $TS status
```

期望能看到本机和至少一台 peer。

## 5. 验收

```powershell
powercfg /query
Get-ScheduledTask -TaskName "DSH Workbench","DSH Proxy","DSH Desktop" | Select-Object TaskName,State
Get-Process | Where-Object { $_.ProcessName -like "*DeepSeek*" }
powershell -ExecutionPolicy Bypass -File .\scripts\verify.ps1
```

工作台上应同时看到：

- 「DSH 界面」绿色「运行中」；
- 「常驻托管」绿色「计划任务」；
- 设备卡有时延与 Direct/Relay。

重启验证（需要用户同意，属于破坏性动作）：重启 Windows，等 60 秒，确认已自动登录、三个任务都在运行、工作台可打开。没有自动登录时，先手动登录，这是预期行为。

## 6. 取舍

- 长期不睡会增加功耗；台式机影响小，笔记本建议接电源；
- 自动登录降低物理安全，只在可信环境使用；
- Windows 更新会重启，重启后仍受自动登录与计划任务约束；
- 如果机器必须睡眠，远程访问不保证；Tailscale 不能把睡眠中的机器唤醒到可用状态。
