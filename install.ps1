# 安装/更新：创建 Windows 计划任务，启动工作台与 DSH 反代。
#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$PythonPath = $env:DSH_PYTHON,
  [string]$CaddyPath = $env:CADDY_BIN
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$Config = Join-Path $Root "config.json"
$State = Join-Path $env:LOCALAPPDATA "dsh-workbench"
$TaskWb = "DSH Workbench"
$TaskPx = "DSH Proxy"

function Fail([string]$Message) {
  Write-Host "错误：$Message" -ForegroundColor Red
  exit 1
}

if (-not (Test-Path $Config)) {
  Copy-Item (Join-Path $Root "config.example.json") $Config
  Write-Host "已生成 $Config，先按需改端口 / taskName，再重跑 install.ps1。"
  exit 0
}

function Test-Python([string]$Exe) {
  if (-not $Exe -or -not (Test-Path $Exe)) { return $false }
  $ver = & $Exe -c "import sys; print(sys.version_info[0]*100+sys.version_info[1])" 2>$null
  return ($LASTEXITCODE -eq 0 -and [int]$ver -ge 309)
}

if (-not (Test-Python $PythonPath)) {
  $PythonPath = $null
  foreach ($name in @("python", "python3")) {
    $cmd = Get-Command $name -ErrorAction SilentlyContinue
    if ($cmd -and (Test-Python $cmd.Source)) { $PythonPath = $cmd.Source; break }
  }
}
if (-not $PythonPath) {
  Fail "找不到 Python 3.9+。装：winget install --id Python.Python.3.12 -e；或用 -PythonPath 指定 python.exe"
}
$PythonW = Join-Path (Split-Path $PythonPath) "pythonw.exe"
if (-not (Test-Path $PythonW)) { $PythonW = $PythonPath }

if (-not $CaddyPath) {
  $cmd = Get-Command caddy -ErrorAction SilentlyContinue
  if ($cmd) { $CaddyPath = $cmd.Source }
}
if (-not $CaddyPath) {
  foreach ($p in @((Join-Path $State "bin\caddy.exe"), "$env:ProgramFiles\Caddy\caddy.exe")) {
    if (Test-Path $p) { $CaddyPath = $p; break }
  }
}
if (-not $CaddyPath -or -not (Test-Path $CaddyPath)) {
  Fail "找不到 caddy.exe。装：winget install --id CaddyServer.Caddy -e；或用 -CaddyPath 指定"
}

try {
  $cfg = Get-Content $Config -Raw -Encoding UTF8 | ConvertFrom-Json
} catch {
  Fail "config.json 解析失败"
}
$WbPort = [int]$cfg.workbench.port
$PubPort = [int]$cfg.dsh.publicPort
if ($WbPort -le 0 -or $PubPort -le 0) { Fail "config.json 里的端口无效" }

New-Item -ItemType Directory -Force -Path $State | Out-Null
[IO.File]::WriteAllText((Join-Path $State "caddy.path"), $CaddyPath,
  (New-Object System.Text.UTF8Encoding($false)))

$Ts = "$env:ProgramFiles\Tailscale\tailscale.exe"
if (-not (Test-Path $Ts)) {
  $cmd = Get-Command tailscale -ErrorAction SilentlyContinue
  if ($cmd) { $Ts = $cmd.Source }
}
$TsIp = ""
if ($Ts -and (Test-Path $Ts)) {
  $line = & $Ts ip -4 2>$null | Select-Object -First 1
  if ($line) { $TsIp = $line.Trim() }
}
if (-not $TsIp) {
  $TsIp = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -like "100.*" } |
    Select-Object -First 1 -ExpandProperty IPAddress
}
if (-not $TsIp) {
  Write-Host "提示：当前没有 Tailscale 地址，工作台只会监听 127.0.0.1。" -ForegroundColor Yellow
  Write-Host "     登录 Tailscale 后重跑 install.ps1。" -ForegroundColor Yellow
}

# 重复安装：先停掉旧任务，再只清理本仓库状态目录里的 Caddy。
foreach ($t in @($TaskWb, $TaskPx)) {
  Stop-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue
  Unregister-ScheduledTask -TaskName $t -Confirm:$false -ErrorAction SilentlyContinue
}
Start-Sleep -Seconds 1
$PidFile = Join-Path $State "caddy.pid"
if (Test-Path $PidFile) {
  $cpid = Get-Content $PidFile -ErrorAction SilentlyContinue
  if ($cpid) { Stop-Process -Id ([int]$cpid) -Force -ErrorAction SilentlyContinue }
  Remove-Item $PidFile -Force -ErrorAction SilentlyContinue
}
Get-CimInstance Win32_Process -Filter "Name='caddy.exe'" -ErrorAction SilentlyContinue |
  Where-Object { $_.CommandLine -and $_.CommandLine.Contains("$State\Caddyfile") } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Milliseconds 500

foreach ($port in @($WbPort, $PubPort)) {
  $listener = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
  if ($listener) { Fail "端口 $port 已被占用。改 config.json 里的端口，或先停掉占用者。" }
}

$User = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$Principal = New-ScheduledTaskPrincipal -UserId $User -LogonType Interactive -RunLevel Limited
$Trigger = New-ScheduledTaskTrigger -AtLogOn
$Settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
  -StartWhenAvailable -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) `
  -ExecutionTimeLimit ([TimeSpan]::Zero)

$ArgWb = '"{0}"' -f (Join-Path $Root "workbench\workbench.py")
$ArgPx = '"{0}"' -f (Join-Path $Root "scripts\dsh-proxy.py")
$ActionWb = New-ScheduledTaskAction -Execute $PythonW -Argument $ArgWb
$ActionPx = New-ScheduledTaskAction -Execute $PythonW -Argument $ArgPx
Register-ScheduledTask -TaskName $TaskWb -Action $ActionWb -Trigger $Trigger `
  -Settings $Settings -Principal $Principal -Force | Out-Null
Register-ScheduledTask -TaskName $TaskPx -Action $ActionPx -Trigger $Trigger `
  -Settings $Settings -Principal $Principal -Force | Out-Null
Start-ScheduledTask -TaskName $TaskWb -ErrorAction SilentlyContinue
Start-ScheduledTask -TaskName $TaskPx -ErrorAction SilentlyContinue
Start-Sleep -Seconds 3

foreach ($t in @($TaskWb, $TaskPx)) {
  $st = (Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue).State
  if ($st -eq "Running") { Write-Host "OK  $t" } else { Write-Host "WARN $t 未运行（$st）" -ForegroundColor Yellow }
}

$DshExe = Join-Path $env:LOCALAPPDATA "Programs\DeepSeek Harness\DeepSeek Harness.exe"
if (Test-Path $DshExe) {
  Write-Host ""
  Write-Host "DSH 常驻：DSH 自带的登录启动，或按 docs/07b 创建计划任务，任务名填进 dsh.taskName。" -ForegroundColor Yellow
}
Write-Host ""
$HostIp = if ($TsIp) { $TsIp } else { "127.0.0.1" }
Write-Host "工作台：http://${HostIp}:$WbPort/"
Write-Host "DSH：工作台顶部「DSH」标签（经本机反代，不需要公网端口）"
Write-Host "验收：$Root\scripts\verify.ps1"
