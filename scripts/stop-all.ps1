$ErrorActionPreference = "Continue"

$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$runDir = Join-Path $root "run"

function Stop-ByPidFile {
  param(
    [string]$name,
    [string]$pidFile
  )
  if (!(Test-Path $pidFile)) {
    Write-Host "${name}: pid file not found, skip."
    return
  }

  $pidText = Get-Content $pidFile -ErrorAction SilentlyContinue
  if ([string]::IsNullOrWhiteSpace($pidText)) {
    Write-Host "${name}: pid file is empty, skip."
    Remove-Item $pidFile -ErrorAction SilentlyContinue
    return
  }

  $targetPid = 0
  if (-not [int]::TryParse($pidText.Trim(), [ref]$targetPid)) {
    Write-Host "${name}: invalid pid ($pidText), skip."
    Remove-Item $pidFile -ErrorAction SilentlyContinue
    return
  }

  try {
    $proc = Get-Process -Id $targetPid -ErrorAction Stop
    Stop-Process -Id $proc.Id -Force -ErrorAction Stop
    Write-Host "${name}: stopped PID=$targetPid"
  } catch {
    Write-Host "${name}: process missing or stop failed (PID=$targetPid)"
  }

  Remove-Item $pidFile -ErrorAction SilentlyContinue
}

Stop-ByPidFile -name "UI" -pidFile (Join-Path $runDir "ui.pid")
Stop-ByPidFile -name "Gateway" -pidFile (Join-Path $runDir "gateway.pid")
Stop-ByPidFile -name "ZLM" -pidFile (Join-Path $runDir "zlm.pid")

$runtimeFile = Join-Path $runDir "runtime.json"
if (Test-Path $runtimeFile) {
  Remove-Item $runtimeFile -ErrorAction SilentlyContinue
  Write-Host "Runtime file removed: $runtimeFile"
}
