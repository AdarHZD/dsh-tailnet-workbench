# 停止并清理 Windows 计划任务、Caddy 子进程与运行时状态；不动 config.json 和仓库。
#Requires -Version 5.1
$ErrorActionPreference = "Continue"

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$State = Join-Path $env:LOCALAPPDATA "dsh-workbench"
$TaskWb = "DSH Workbench"
$TaskPx = "DSH Proxy"

foreach ($t in @($TaskWb, $TaskPx)) {
  Stop-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue
  Unregister-ScheduledTask -TaskName $t -Confirm:$false -ErrorAction SilentlyContinue
}
Start-Sleep -Seconds 1

$PidFile = Join-Path $State "caddy.pid"
if (Test-Path $PidFile) {
  $cpid = Get-Content $PidFile -ErrorAction SilentlyContinue
  if ($cpid) { Stop-Process -Id ([int]$cpid) -Force -ErrorAction SilentlyContinue }
}
Get-CimInstance Win32_Process -Filter "Name='caddy.exe'" -ErrorAction SilentlyContinue |
  Where-Object { $_.CommandLine -and $_.CommandLine.Contains("$State\Caddyfile") } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

if (Test-Path $State) { Remove-Item $State -Recurse -Force -ErrorAction SilentlyContinue }
Write-Host "已停止并清理 $(Split-Path -Leaf $Root) 的计划任务与运行时状态。"
Write-Host "config.json 与仓库保留；运行日志随上面的状态目录一起删除。"
