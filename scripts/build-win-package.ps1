$ErrorActionPreference = "Stop"

$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$gatewayDir = Join-Path $root "gateway"
$gatewayBinDir = Join-Path $gatewayDir "bin"
$uiDir = Join-Path $root "ui"

if (!(Get-Command go -ErrorAction SilentlyContinue)) {
  throw "go command not found. Please install Go and add it to PATH."
}
if (!(Get-Command npm -ErrorAction SilentlyContinue)) {
  throw "npm command not found. Please install Node.js."
}

New-Item -ItemType Directory -Force -Path $gatewayBinDir | Out-Null

Write-Host "Building gateway.exe ..."
Push-Location $gatewayDir
go build -o ".\bin\gateway.exe" .
Pop-Location

Write-Host "Installing UI dependencies ..."
Push-Location $uiDir
npm install

Write-Host "Building Windows installer ..."
$env:CSC_IDENTITY_AUTO_DISCOVERY = "false"
$env:WIN_CSC_LINK = ""
$env:WIN_CSC_KEY_PASSWORD = ""
npm run dist:win
Pop-Location

Write-Host ""
Write-Host "Build done. Installer output:"
Write-Host "  $uiDir\dist"
