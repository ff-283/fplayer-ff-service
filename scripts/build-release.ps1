$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Assert-PathString {
  param(
    [Parameter(Mandatory = $true)][string]$Value,
    [Parameter(Mandatory = $true)][string]$Name
  )
  if ([string]::IsNullOrWhiteSpace($Value)) {
    throw "Path variable '$Name' is empty."
  }
}

function Test-PathSafe {
  param(
    [Parameter(Mandatory = $true)][string]$PathValue,
    [Parameter(Mandatory = $true)][string]$PathName
  )
  Assert-PathString -Value $PathValue -Name $PathName
  return Test-Path -LiteralPath $PathValue
}

function Stop-ReleaseProcesses {
  param(
    [Parameter(Mandatory = $true)][string]$ReleaseRoot
  )
  Assert-PathString -Value $ReleaseRoot -Name "ReleaseRoot"
  $normalizedRoot = [System.IO.Path]::GetFullPath($ReleaseRoot)
  Get-Process -ErrorAction SilentlyContinue | ForEach-Object {
    try {
      $procPath = $_.Path
      if ([string]::IsNullOrWhiteSpace($procPath)) {
        return
      }
      $fullProcPath = [System.IO.Path]::GetFullPath($procPath)
      if ($fullProcPath.StartsWith($normalizedRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        Stop-Process -Id $_.Id -Force -ErrorAction Stop
      }
    } catch {
      # 忽略无权限/系统进程读取失败
    }
  }
}

function Remove-DirectoryWithRetry {
  param(
    [Parameter(Mandatory = $true)][string]$DirPath,
    [Parameter(Mandatory = $true)][string]$DirName
  )
  if (!(Test-PathSafe -PathValue $DirPath -PathName $DirName)) {
    return
  }
  $attempt = 0
  while ($attempt -lt 3) {
    try {
      Remove-Item -LiteralPath $DirPath -Recurse -Force -ErrorAction Stop
      return
    } catch {
      $attempt += 1
      if ($attempt -ge 3) {
        throw "Failed to remove '$DirPath'. It is likely locked by a running process. Please close apps using files under release and retry."
      }
      Stop-ReleaseProcesses -ReleaseRoot (Split-Path -Parent $DirPath)
      Start-Sleep -Milliseconds (500 * $attempt)
    }
  }
}

$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$uiDir = Join-Path $root "ui"
$distDir = Join-Path $uiDir "dist"
$releaseDir = Join-Path $root "release"
$winUnpackedDir = Join-Path $distDir "win-unpacked"
$gatewayExe = Join-Path $root "gateway\bin\gateway.exe"
Assert-PathString -Value $root -Name "root"
Assert-PathString -Value $uiDir -Name "uiDir"
Assert-PathString -Value $distDir -Name "distDir"
Assert-PathString -Value $releaseDir -Name "releaseDir"
Assert-PathString -Value $winUnpackedDir -Name "winUnpackedDir"
Assert-PathString -Value $gatewayExe -Name "gatewayExe"

Write-Host "Step 1/3: build installer ..."
powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root "scripts\build-win-package.ps1")

Write-Host "Step 2/3: collect artifacts ..."
New-Item -ItemType Directory -Force -Path $releaseDir | Out-Null

$installer = Get-ChildItem -Path $distDir -File -Filter "*.exe" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $installer) {
  throw "No installer exe found in: $distDir"
}

$targetInstaller = Join-Path $releaseDir $installer.Name
Copy-Item -Path $installer.FullName -Destination $targetInstaller -Force

if (!(Test-PathSafe -PathValue $winUnpackedDir -PathName "winUnpackedDir")) {
  throw "win-unpacked directory not found: $winUnpackedDir"
}

$packagedPortableDir = Join-Path $releaseDir "win-unpacked"
Remove-DirectoryWithRetry -DirPath $packagedPortableDir -DirName "packagedPortableDir"
Copy-Item -Path $winUnpackedDir -Destination $packagedPortableDir -Recurse -Force

$portableDir = Join-Path $releaseDir "portable"
Remove-DirectoryWithRetry -DirPath $portableDir -DirName "portableDir"
# 便携包必须先完整复制 win-unpacked（包含 Electron 运行时 DLL，如 ffmpeg.dll）
New-Item -ItemType Directory -Force -Path $portableDir | Out-Null
Get-ChildItem -LiteralPath $winUnpackedDir -Force | ForEach-Object {
  Copy-Item -Path $_.FullName -Destination $portableDir -Recurse -Force
}

$source3rd = Join-Path $root "3rd"
if (Test-PathSafe -PathValue $source3rd -PathName "source3rd") {
  Copy-Item -Path $source3rd -Destination (Join-Path $portableDir "3rd") -Recurse -Force
}
# 兜底：若同级 3rd 缺失，则从 resources/3rd 回填到同级，保证 exe 同级可直接运行
$portable3rd = Join-Path $portableDir "3rd"
$resources3rd = Join-Path $portableDir "resources\3rd"
Assert-PathString -Value $portable3rd -Name "portable3rd"
Assert-PathString -Value $resources3rd -Name "resources3rd"
if (!(Test-PathSafe -PathValue $portable3rd -PathName "portable3rd") -and (Test-PathSafe -PathValue $resources3rd -PathName "resources3rd")) {
  Copy-Item -Path $resources3rd -Destination $portable3rd -Recurse -Force
}
New-Item -ItemType Directory -Force -Path (Join-Path $portableDir "gateway\bin") | Out-Null
Copy-Item -Path $gatewayExe -Destination (Join-Path $portableDir "gateway\bin\gateway.exe") -Force
Copy-Item -Path (Join-Path $root "scripts") -Destination (Join-Path $portableDir "scripts") -Recurse -Force

$requiredPaths = @(
  (Join-Path $portableDir "FPlayerFFService.exe"),
  (Join-Path $portableDir "ffmpeg.dll"),
  (Join-Path $portableDir "3rd"),
  (Join-Path $portableDir "3rd\zlm\windows"),
  (Join-Path $portableDir "3rd\zlm\windows\MediaServer.exe"),
  (Join-Path $portableDir "3rd\zlm\windows\config.ini"),
  (Join-Path $portableDir "gateway\bin\gateway.exe"),
  (Join-Path $portableDir "scripts\start-all.ps1"),
  (Join-Path $portableDir "scripts\stop-all.ps1"),
  (Join-Path $portableDir "resources\app.asar")
)
foreach ($requiredPath in $requiredPaths) {
  if (!(Test-PathSafe -PathValue $requiredPath -PathName "requiredPath")) {
    throw "Release package missing required dependency: $requiredPath"
  }
}

$readme = @"
FPlayer FF Service Windows 发布包
================================

1. 双击安装程序:
   $($installer.Name)

2. 或直接运行便携版（推荐）:
   portable\FPlayerFFService.exe
   - 运行依赖按 exe 同级目录查找（3rd/gateway/scripts）
   - 无需手动执行 start-service.bat / start-all.ps1

3. 安装后首次运行:
   - 若系统弹出防火墙提示，请允许访问
   - 程序将自动拉起 service 内核

4. 与 desktop 对接:
   - desktop 服务地址填写:
     http://<service-ip>:<gateway-port>

5. 常见问题:
   - 若启动失败，请检查 logs 目录日志
   - 若端口冲突，程序会自动选择可用端口
"@

Set-Content -Path (Join-Path $releaseDir "README-发布说明.txt") -Value $readme -Encoding UTF8

Write-Host "Step 3/3: done"
Write-Host "Release directory: $releaseDir"
Write-Host "Installer: $targetInstaller"
Write-Host "Portable directory: $portableDir"
Write-Host "Packaged directory: $packagedPortableDir"
Write-Host ""
Write-Host "Portable checklist:"
foreach ($requiredPath in $requiredPaths) {
  $ok = Test-PathSafe -PathValue $requiredPath -PathName "requiredPath"
  $mark = if ($ok) { "[OK]" } else { "[MISSING]" }
  Write-Host "  $mark $requiredPath"
}
