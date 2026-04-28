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

function Stop-ServiceReleaseProcesses {
  $names = @("FPlayerFFService", "FPlayerFFServiceKernel")
  foreach ($name in $names) {
    try {
      Get-Process -Name $name -ErrorAction SilentlyContinue | ForEach-Object {
        Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
      }
    } catch {
    }
  }
}

function Show-ReleaseLockedPopup {
  param(
    [Parameter(Mandatory = $true)][string]$ReleasePath
  )
  try {
    Add-Type -AssemblyName PresentationFramework -ErrorAction SilentlyContinue
    $msg = "Failed to clean release directory:`n$ReleasePath`n`nPlease close apps using the release folder (Explorer windows, FPlayerFFService processes) and retry."
    [System.Windows.MessageBox]::Show($msg, "Build failed: release is locked", "OK", "Warning") | Out-Null
  } catch {
  }
}

$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$uiDir = Join-Path $root "ui"
$distDir = Join-Path $uiDir "dist"
$releaseDir = Join-Path $root "release"
$winUnpackedDir = Join-Path $distDir "win-unpacked"
$gatewayExe = Join-Path $root "gateway\bin\gateway.exe"
$kernelConsoleExe = Join-Path $root "kernel-console\bin\FPlayerFFServiceKernel.exe"
Assert-PathString -Value $root -Name "root"
Assert-PathString -Value $uiDir -Name "uiDir"
Assert-PathString -Value $distDir -Name "distDir"
Assert-PathString -Value $releaseDir -Name "releaseDir"
Assert-PathString -Value $winUnpackedDir -Name "winUnpackedDir"
Assert-PathString -Value $gatewayExe -Name "gatewayExe"
Assert-PathString -Value $kernelConsoleExe -Name "kernelConsoleExe"

Write-Host "Step 1/3: build installer ..."
powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root "scripts\build-win-package.ps1")

Write-Host "Step 2/3: collect artifacts ..."
Stop-ServiceReleaseProcesses
try {
  Remove-DirectoryWithRetry -DirPath $releaseDir -DirName "releaseDir"
} catch {
  Show-ReleaseLockedPopup -ReleasePath $releaseDir
  throw
}
New-Item -ItemType Directory -Force -Path $releaseDir | Out-Null

$installer = Get-ChildItem -Path $distDir -File -Filter "*.exe" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $installer) {
  throw "No installer exe found in: $distDir"
}

$targetInstaller = Join-Path $releaseDir $installer.Name
try {
  Copy-Item -Path $installer.FullName -Destination $targetInstaller -Force -ErrorAction Stop
} catch {
  Write-Warning "Failed to copy installer to release (file may be locked): $targetInstaller"
  Write-Warning "Portable package will still be generated. Close file handles and retry if installer copy is required."
}

if (!(Test-PathSafe -PathValue $winUnpackedDir -PathName "winUnpackedDir")) {
  throw "win-unpacked directory not found: $winUnpackedDir"
}
if (!(Test-PathSafe -PathValue $kernelConsoleExe -PathName "kernelConsoleExe")) {
  throw "kernel console executable not found: $kernelConsoleExe"
}

$packagedPortableDir = Join-Path $releaseDir "win-unpacked"
Remove-DirectoryWithRetry -DirPath $packagedPortableDir -DirName "packagedPortableDir"
Copy-Item -Path $winUnpackedDir -Destination $packagedPortableDir -Recurse -Force

$portableBaseDir = Join-Path $releaseDir "_portable-base"
Remove-DirectoryWithRetry -DirPath $portableBaseDir -DirName "portableBaseDir"
# 先复制一份基础目录（包含 Electron 运行时 DLL，如 ffmpeg.dll），再拆分 UI/Kernel 包
New-Item -ItemType Directory -Force -Path $portableBaseDir | Out-Null
Get-ChildItem -LiteralPath $winUnpackedDir -Force | ForEach-Object {
  Copy-Item -Path $_.FullName -Destination $portableBaseDir -Recurse -Force
}

$portableUiDir = Join-Path $releaseDir "portable-ui"
$portableKernelDir = Join-Path $releaseDir "portable-kernel"
Remove-DirectoryWithRetry -DirPath $portableUiDir -DirName "portableUiDir"
Remove-DirectoryWithRetry -DirPath $portableKernelDir -DirName "portableKernelDir"

$source3rd = Join-Path $root "3rd"
if (Test-Path $source3rd) {
  Copy-Item -Path $source3rd -Destination (Join-Path $portableBaseDir "3rd") -Recurse -Force
}
# 兜底：若同级 3rd 缺失，则从 resources/3rd 回填到同级，保证 exe 同级可直接运行
$portable3rd = Join-Path $portableBaseDir "3rd"
$resources3rd = Join-Path $portableBaseDir "resources\3rd"
if (!(Test-Path $portable3rd) -and (Test-Path $resources3rd)) {
  Copy-Item -Path $resources3rd -Destination $portable3rd -Recurse -Force
}
New-Item -ItemType Directory -Force -Path (Join-Path $portableBaseDir "gateway\bin") | Out-Null
Copy-Item -Path $gatewayExe -Destination (Join-Path $portableBaseDir "gateway\bin\gateway.exe") -Force
Copy-Item -Path (Join-Path $root "scripts") -Destination (Join-Path $portableBaseDir "scripts") -Recurse -Force

New-Item -ItemType Directory -Force -Path $portableUiDir | Out-Null
Get-ChildItem -LiteralPath $portableBaseDir -Force | ForEach-Object {
  Copy-Item -Path $_.FullName -Destination $portableUiDir -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $portableKernelDir | Out-Null
Get-ChildItem -LiteralPath $portableBaseDir -Force | ForEach-Object {
  Copy-Item -Path $_.FullName -Destination $portableKernelDir -Recurse -Force
}

$portableUiKernelExe = Join-Path $portableUiDir "FPlayerFFServiceKernel.exe"
if (Test-Path $portableUiKernelExe) {
  Remove-Item -Force $portableUiKernelExe
}
$portableKernelUiExe = Join-Path $portableKernelDir "FPlayerFFService.exe"
if (Test-Path $portableKernelUiExe) {
  Remove-Item -Force $portableKernelUiExe
}
Copy-Item -Path $kernelConsoleExe -Destination (Join-Path $portableKernelDir "FPlayerFFServiceKernel.exe") -Force

$requiredBasePaths = @(
  (Join-Path $portableBaseDir "FPlayerFFService.exe"),
  (Join-Path $portableBaseDir "ffmpeg.dll"),
  (Join-Path $portableBaseDir "3rd"),
  (Join-Path $portableBaseDir "3rd\zlm\windows"),
  (Join-Path $portableBaseDir "3rd\zlm\windows\MediaServer.exe"),
  (Join-Path $portableBaseDir "3rd\zlm\windows\config.ini"),
  (Join-Path $portableBaseDir "gateway\bin\gateway.exe"),
  (Join-Path $portableBaseDir "scripts\start-all.ps1"),
  (Join-Path $portableBaseDir "scripts\stop-all.ps1"),
  (Join-Path $portableBaseDir "resources\app.asar")
)
foreach ($requiredBasePath in $requiredBasePaths) {
  if (!(Test-Path $requiredBasePath)) {
    throw "Release package missing required dependency: $requiredBasePath"
  }
}

$requiredSplitPaths = @(
  (Join-Path $portableUiDir "FPlayerFFService.exe"),
  (Join-Path $portableKernelDir "FPlayerFFServiceKernel.exe")
)
foreach ($requiredSplitPath in $requiredSplitPaths) {
  if (!(Test-Path $requiredSplitPath)) {
    throw "Release package missing split artifact: $requiredSplitPath"
  }
}

Write-Host "Step 3/3: done"
Write-Host "Release directory: $releaseDir"
Write-Host "Installer: $targetInstaller"
Write-Host "Portable UI directory: $portableUiDir"
Write-Host "Portable Kernel directory: $portableKernelDir"
Write-Host "Packaged directory: $packagedPortableDir"
Write-Host ""
Write-Host "Portable split checklist:"
foreach ($requiredSplitPath in $requiredSplitPaths) {
  $ok = Test-Path $requiredSplitPath
  $mark = if ($ok) { "[OK]" } else { "[MISSING]" }
  Write-Host "  $mark $requiredSplitPath"
}

Remove-DirectoryWithRetry -DirPath $portableBaseDir -DirName "portableBaseDir-finally"
