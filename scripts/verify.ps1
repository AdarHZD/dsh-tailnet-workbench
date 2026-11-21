# 一条命令验收（Windows）：工作台、DSH 反代、cookie 登录链路、Tailscale、常驻。
#Requires -Version 5.1
$ErrorActionPreference = "Continue"

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$Config = Join-Path (Split-Path -Parent $Root) "config.json"
if ($env:DSH_WORKBENCH_CONFIG) { $Config = $env:DSH_WORKBENCH_CONFIG }
$Fail = $false

function Ok([string]$m) { Write-Host "OK   $m" }
function Bad([string]$m) { Write-Host "FAIL $m" -ForegroundColor Red; $script:Fail = $true }
function Warn([string]$m) { Write-Host "WARN $m" -ForegroundColor Yellow }

if (-not (Test-Path $Config)) { Bad "缺少 $Config"; exit 1 }
try { $cfg = Get-Content $Config -Raw -Encoding UTF8 | ConvertFrom-Json }
catch { Bad "config.json 解析失败"; exit 1 }
$WbPort = [int]$cfg.workbench.port
$PubPort = [int]$cfg.dsh.publicPort

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
$HostIp = if ($TsIp) { $TsIp } else { "127.0.0.1" }
$Tmp = Join-Path $env:TEMP ("dshwb-verify-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $Tmp | Out-Null
$Jar = Join-Path $Tmp "cookies.txt"
$Curl = "curl.exe"

function DoCurl {
  param([string[]]$CurlArgs)
  return (& $Curl -s --noproxy "*" @CurlArgs)
}

try {
  $code = ((DoCurl @("-o", "NUL", "-w", "%{http_code}", "http://${HostIp}:$WbPort/")) | Out-String).Trim()
  if ($code -eq "200") { Ok "工作台 http://${HostIp}:$WbPort/" } else { Bad "工作台打不开（$code）" }

  $apiFile = Join-Path $Tmp "status.json"
  DoCurl @("-o", $apiFile, "http://${HostIp}:$WbPort/api/status") | Out-Null
  try {
    $d = Get-Content $apiFile -Raw -Encoding UTF8 | ConvertFrom-Json
    $keys = $d.host.dsh.PSObject.Properties.Name
    if ($keys -contains "token" -or $keys -contains "url" -or $keys -contains "port") {
      Bad "状态接口返回了敏感字段"
    } else { Ok "状态接口不泄露 token/内部端口" }
  } catch { Bad "状态接口不是有效 JSON" }

  $wbListeners = Get-NetTCPConnection -LocalPort $WbPort -State Listen -ErrorAction SilentlyContinue
  if ($wbListeners | Where-Object { $_.LocalAddress -eq "0.0.0.0" -or $_.LocalAddress -eq "::" }) {
    Bad "工作台绑定了所有网卡（应只绑回环 + Tailscale）"
  }

  $listeners = Get-NetTCPConnection -LocalPort $PubPort -State Listen -ErrorAction SilentlyContinue
  if ($listeners) { Ok "反代监听 :$PubPort" } else { Bad "反代未监听 :$PubPort" }
  if ($listeners | Where-Object { $_.LocalAddress -eq "0.0.0.0" -or $_.LocalAddress -eq "::" }) {
    Bad "反代绑定了所有网卡（应只绑回环 + Tailscale）"
  }

  $dshProc = Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -like "*DeepSeek*" }
  if ($dshProc) { Ok "DSH 进程在跑" } else { Warn "没找到 DSH 进程（DSH 是否在运行？）" }

  $hdr = (DoCurl @("-D", "-", "-o", "NUL", "-c", $Jar, "http://${HostIp}:$WbPort/remote-dsh")) -join "`n"
  if ($hdr -match " 302" -and $hdr -match "Set-Cookie") { Ok "/remote-dsh 下发 DSH cookie" }
  else { Bad "/remote-dsh 没有返回 302 + Set-Cookie" }

  $code = ((DoCurl @("-b", $Jar, "-o", "NUL", "-w", "%{http_code}", "http://${HostIp}:$PubPort/")) | Out-String).Trim()
  if ($code -eq "200" -or $code -eq "303") { Ok "cookie 经反代进入 DSH（$code）" }
  elseif ($code -eq "401") { Bad "反代返回 401：cookie authority 与 Host 改写不一致，检查 dsh.publicPort" }
  else { Bad "反代返回 $code（看 %LOCALAPPDATA%\dsh-workbench\dsh-proxy.log）" }

  if ($Ts -and (Test-Path $Ts)) {
    $tsj = & $Ts status --json 2>$null | ConvertFrom-Json
    $peers = 0
    if ($tsj.Peer) { $peers = ($tsj.Peer.PSObject.Properties | Measure-Object).Count }
    if ($peers -ge 1) { Ok "Tailscale 在线，peer $peers 台" } else { Warn "Tailscale 没有 peer，或 CLI 被权限拦截" }
  } else { Warn "没找到 tailscale.exe" }

  $sleep = & powercfg /query SCHEME_CURRENT SUB_SLEEP STANDBYIDLE 2>$null
  $line = $sleep | Select-String -Pattern "0x([0-9A-Fa-f]{8})" | Select-Object -First 1
  $hex = if ($line) { $line.Matches.Groups[1].Value } else { "" }
  if ($hex -and [Convert]::ToInt32($hex, 16) -eq 0) { Ok "系统待机超时为 0" }
  else { Warn "待机超时可能不是 0：powercfg /change standby-timeout-ac 0" }

  if ($cfg.dsh.taskName) {
    $st = (Get-ScheduledTask -TaskName $cfg.dsh.taskName -ErrorAction SilentlyContinue).State
    if ($st -eq "Running") { Ok "DSH 由计划任务常驻（$($cfg.dsh.taskName)）" }
    else { Bad "DSH 计划任务未运行（$($cfg.dsh.taskName)：$st）" }
  } else {
    Warn "未配置 dsh.taskName：DSH 退出/重启后需要手动打开"
  }
}
finally {
  Remove-Item $Tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
if ($Fail) { Write-Host "有失败项，按上面提示排查" -ForegroundColor Red; exit 1 }
Write-Host "验收通过"
exit 0
