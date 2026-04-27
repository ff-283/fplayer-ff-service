$ErrorActionPreference = "Stop"

$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$runDir = Join-Path $root "run"
$logDir = Join-Path $root "logs"
New-Item -ItemType Directory -Force -Path $runDir | Out-Null
New-Item -ItemType Directory -Force -Path $logDir | Out-Null

$zlmDir = Join-Path $root "3rd\zlm\windows"
$zlmExe = Join-Path $zlmDir "MediaServer.exe"
$zlmCfg = Join-Path $zlmDir "config.ini"
$zlmRuntimeCfg = Join-Path $runDir "zlm.runtime.ini"
$gatewayDir = Join-Path $root "gateway"
$gatewayExe = Join-Path $gatewayDir "bin\gateway.exe"
$skipUi = $env:SERVICE_SKIP_UI -eq "1"
if (!(Test-Path $zlmExe)) {
  throw "ZLM executable not found: $zlmExe"
}
if (!(Test-Path $zlmCfg)) {
  throw "ZLM config not found: $zlmCfg"
}

function Get-FreePort {
  param(
    [int]$preferred = 0
  )
  if ($preferred -gt 0) {
    try {
      $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Any, $preferred)
      $listener.Start()
      $listener.Stop()
      return $preferred
    } catch {
    }
  }
  $tmp = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Any, 0)
  $tmp.Start()
  $port = $tmp.LocalEndpoint.Port
  $tmp.Stop()
  return $port
}

function Set-IniKeyValue {
  param(
    [string[]]$lines,
    [string]$section,
    [string]$key,
    [string]$value
  )
  $inSection = $false
  for ($i = 0; $i -lt $lines.Count; $i++) {
    $line = $lines[$i]
    if ($line -match "^\s*\[(.+)\]\s*$") {
      $inSection = ($matches[1] -eq $section)
      continue
    }
    if ($inSection -and $line -match "^\s*$key\s*=") {
      $lines[$i] = "$key=$value"
      return $lines
    }
  }
  return $lines
}

function Test-GatewayHealth {
  param(
    [int]$port,
    [int]$timeoutMs = 2500
  )
  $deadline = (Get-Date).AddMilliseconds($timeoutMs)
  while ((Get-Date) -lt $deadline) {
    try {
      $resp = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$port/healthz" -TimeoutSec 1
      if ($resp.StatusCode -eq 200) {
        return $true
      }
    } catch {
    }
    Start-Sleep -Milliseconds 200
  }
  return $false
}

function Get-LanIpv4 {
  try {
    $all = [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()
    foreach ($nic in $all) {
      if ($nic.OperationalStatus -ne [System.Net.NetworkInformation.OperationalStatus]::Up) {
        continue
      }
      $props = $nic.GetIPProperties()
      foreach ($ua in $props.UnicastAddresses) {
        if ($ua.Address.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
          continue
        }
        $ip = $ua.Address.ToString()
        if ([string]::IsNullOrWhiteSpace($ip)) {
          continue
        }
        if ($ip -eq "127.0.0.1" -or $ip.StartsWith("169.254.")) {
          continue
        }
        return $ip
      }
    }
  } catch {
  }
  return "127.0.0.1"
}

$zlmRtmpPort = Get-FreePort -preferred 1935
$zlmHttpPort = Get-FreePort -preferred 8080
$zlmHttpsPort = Get-FreePort -preferred 8443
$gatewayPort = -1
$runtimeFile = Join-Path $runDir "runtime.json"

$cfgLines = Get-Content $zlmCfg
$cfgLines = Set-IniKeyValue -lines $cfgLines -section "http" -key "port" -value "$zlmHttpPort"
$cfgLines = Set-IniKeyValue -lines $cfgLines -section "http" -key "sslport" -value "$zlmHttpsPort"
$cfgLines = Set-IniKeyValue -lines $cfgLines -section "rtmp" -key "port" -value "$zlmRtmpPort"
Set-Content -Path $zlmRuntimeCfg -Value $cfgLines -Encoding UTF8

$zlmLog = Join-Path $logDir "zlm.log"
$zlmErr = Join-Path $logDir "zlm.err.log"
$zlmProc = Start-Process -FilePath $zlmExe `
  -ArgumentList "-c", $zlmRuntimeCfg `
  -WindowStyle Hidden `
  -WorkingDirectory $zlmDir `
  -PassThru `
  -RedirectStandardOutput $zlmLog `
  -RedirectStandardError $zlmErr
Set-Content -Path (Join-Path $runDir "zlm.pid") -Value $zlmProc.Id

$gwLog = Join-Path $logDir "gateway.log"
$gwErr = Join-Path $logDir "gateway.err.log"
if (!(Test-Path $gatewayExe) -and !(Get-Command go -ErrorAction SilentlyContinue)) {
  throw "go command not found and gateway.exe not found. Please install Go or build gateway/bin/gateway.exe."
}
$gwProc = $null
for ($attempt = 0; $attempt -lt 8; $attempt++) {
  $preferredGatewayPort = if ($attempt -eq 0) { 9000 } else { 0 }
  $candidateGatewayPort = Get-FreePort -preferred $preferredGatewayPort

  if (Test-Path $gatewayExe) {
    $gatewayEnv = "set ZLM_RTMP_PORT=$zlmRtmpPort&& set ZLM_HTTP_PORT=$zlmHttpPort&& set SERVICE_GATEWAY_PORT=$candidateGatewayPort&& set SERVICE_LOG_DIR=$logDir&& `"$gatewayExe`""
    $gwProc = Start-Process -FilePath "cmd.exe" `
      -ArgumentList "/c", $gatewayEnv `
      -WindowStyle Hidden `
      -WorkingDirectory $gatewayDir `
      -PassThru `
      -RedirectStandardOutput $gwLog `
      -RedirectStandardError $gwErr
  } else {
    $gatewayCmd = "`$env:ZLM_RTMP_PORT='$zlmRtmpPort'; `$env:ZLM_HTTP_PORT='$zlmHttpPort'; `$env:SERVICE_GATEWAY_PORT='$candidateGatewayPort'; `$env:SERVICE_LOG_DIR='$logDir'; Set-Location '$gatewayDir'; go run ."
    $gwProc = Start-Process -FilePath "powershell" `
      -ArgumentList "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", $gatewayCmd `
      -WindowStyle Hidden `
      -WorkingDirectory $gatewayDir `
      -PassThru `
      -RedirectStandardOutput $gwLog `
      -RedirectStandardError $gwErr
  }

  if (Test-GatewayHealth -port $candidateGatewayPort -timeoutMs 3000) {
    $gatewayPort = $candidateGatewayPort
    break
  }
  try {
    if ($gwProc -and !$gwProc.HasExited) {
      Stop-Process -Id $gwProc.Id -Force -ErrorAction SilentlyContinue
    }
  } catch {
  }
  $gwProc = $null
}
if ($gatewayPort -le 0 -or -not $gwProc) {
  throw "gateway failed to start on dynamic ports. See logs/gateway.err.log"
}
Set-Content -Path (Join-Path $runDir "gateway.pid") -Value $gwProc.Id

$lanIp = Get-LanIpv4
$uiGatewayUrl = "http://$lanIp:$gatewayPort"
if (-not $skipUi) {
  if (!(Get-Command npm -ErrorAction SilentlyContinue)) {
    throw "npm command not found. Please install Node.js."
  }
  $uiDir = Join-Path $root "ui"
  $uiCmd = "`$env:SERVICE_GATEWAY_URL='$uiGatewayUrl'; `$env:SERVICE_MANAGED_MODE='1'; Set-Location '$uiDir'; npm start"
  $uiLog = Join-Path $logDir "ui.log"
  $uiErr = Join-Path $logDir "ui.err.log"
  $uiProc = Start-Process -FilePath "powershell" `
    -ArgumentList "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", $uiCmd `
    -WindowStyle Hidden `
    -WorkingDirectory $uiDir `
    -PassThru `
    -RedirectStandardOutput $uiLog `
    -RedirectStandardError $uiErr
  Set-Content -Path (Join-Path $runDir "ui.pid") -Value $uiProc.Id
}

$runtimeObject = [ordered]@{
  startedAt = (Get-Date).ToString("s")
  gateway = @{
    host = $lanIp
    port = $gatewayPort
    url  = "http://$lanIp:$gatewayPort"
  }
  zlm = @{
    rtmpPort  = $zlmRtmpPort
    httpPort  = $zlmHttpPort
    httpsPort = $zlmHttpsPort
  }
  endpoints = @{
    publishRtmp = "rtmp://127.0.0.1:$zlmRtmpPort/live/stream001"
    playHttpFlv = "http://127.0.0.1:$zlmHttpPort/live/stream001.flv"
  }
}
$runtimeObject | ConvertTo-Json -Depth 6 | Set-Content -Path $runtimeFile -Encoding UTF8

Write-Host "Started:"
Write-Host "  ZLM:      PID=$($zlmProc.Id)"
Write-Host "  Gateway:  PID=$($gwProc.Id)"
if (-not $skipUi) {
  Write-Host "  UI:       PID=$($uiProc.Id)"
}
Write-Host ""
Write-Host "Service endpoints:"
Write-Host "  Gateway:  http://$lanIp:$gatewayPort"
Write-Host "  RTMP:     rtmp://$lanIp:$zlmRtmpPort/live/stream001"
Write-Host "  HTTP-FLV: http://$lanIp:$zlmHttpPort/live/stream001.flv"
Write-Host ""
Write-Host "Note: ZLM runs as internal service core with auto-selected ports."
Write-Host "Runtime file: $runtimeFile"
