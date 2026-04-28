$ErrorActionPreference = "Stop"

$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$uiDir = Join-Path $root "ui"
$distDir = Join-Path $uiDir "dist"
$releaseDir = Join-Path $root "release"
$winUnpackedDir = Join-Path $distDir "win-unpacked"
$gatewayExe = Join-Path $root "gateway\bin\gateway.exe"

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

if (!(Test-Path $winUnpackedDir)) {
  throw "win-unpacked directory not found: $winUnpackedDir"
}

$packagedPortableDir = Join-Path $releaseDir "win-unpacked"
if (Test-Path $packagedPortableDir) {
  Remove-Item -Recurse -Force $packagedPortableDir
}
Copy-Item -Path $winUnpackedDir -Destination $packagedPortableDir -Recurse -Force

$portableBaseDir = Join-Path $releaseDir "_portable-base"
if (Test-Path $portableBaseDir) {
  Remove-Item -Recurse -Force $portableBaseDir
}
# 先复制一份基础目录（包含 Electron 运行时 DLL，如 ffmpeg.dll），再拆分 UI/Kernel 包
New-Item -ItemType Directory -Force -Path $portableBaseDir | Out-Null
Get-ChildItem -LiteralPath $winUnpackedDir -Force | ForEach-Object {
  Copy-Item -Path $_.FullName -Destination $portableBaseDir -Recurse -Force
}

$uiExePath = Join-Path $portableBaseDir "FPlayerFFService.exe"
$kernelExePath = Join-Path $portableBaseDir "FPlayerFFServiceKernel.exe"
if (Test-Path $uiExePath) {
  Copy-Item -Path $uiExePath -Destination $kernelExePath -Force
}

$portableUiDir = Join-Path $releaseDir "portable-ui"
$portableKernelDir = Join-Path $releaseDir "portable-kernel"
if (Test-Path $portableUiDir) {
  Remove-Item -Recurse -Force $portableUiDir
}
if (Test-Path $portableKernelDir) {
  Remove-Item -Recurse -Force $portableKernelDir
}

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

Copy-Item -Path $portableBaseDir -Destination $portableUiDir -Recurse -Force
Copy-Item -Path $portableBaseDir -Destination $portableKernelDir -Recurse -Force

$portableUiKernelExe = Join-Path $portableUiDir "FPlayerFFServiceKernel.exe"
if (Test-Path $portableUiKernelExe) {
  Remove-Item -Force $portableUiKernelExe
}
$portableKernelUiExe = Join-Path $portableKernelDir "FPlayerFFService.exe"
if (Test-Path $portableKernelUiExe) {
  Remove-Item -Force $portableKernelUiExe
}

$requiredBasePaths = @(
  (Join-Path $portableBaseDir "FPlayerFFService.exe"),
  (Join-Path $portableBaseDir "FPlayerFFServiceKernel.exe"),
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

if (Test-Path $portableBaseDir) {
  Remove-Item -Recurse -Force $portableBaseDir
}
