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

$portableDir = Join-Path $releaseDir "portable"
if (Test-Path $portableDir) {
  Remove-Item -Recurse -Force $portableDir
}
# 便携包必须先完整复制 win-unpacked（包含 Electron 运行时 DLL，如 ffmpeg.dll）
New-Item -ItemType Directory -Force -Path $portableDir | Out-Null
Get-ChildItem -LiteralPath $winUnpackedDir -Force | ForEach-Object {
  Copy-Item -Path $_.FullName -Destination $portableDir -Recurse -Force
}

$source3rd = Join-Path $root "3rd"
if (Test-Path $source3rd) {
  Copy-Item -Path $source3rd -Destination (Join-Path $portableDir "3rd") -Recurse -Force
}
# 兜底：若同级 3rd 缺失，则从 resources/3rd 回填到同级，保证 exe 同级可直接运行
$portable3rd = Join-Path $portableDir "3rd"
$resources3rd = Join-Path $portableDir "resources\3rd"
if (!(Test-Path $portable3rd) -and (Test-Path $resources3rd)) {
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
  if (!(Test-Path $requiredPath)) {
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
  $ok = Test-Path $requiredPath
  $mark = if ($ok) { "[OK]" } else { "[MISSING]" }
  Write-Host "  $mark $requiredPath"
}
