$ErrorActionPreference = "Stop"

$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)

$targets = @(
  (Join-Path $root "ui\dist"),
  (Join-Path $root "release"),
  (Join-Path $root "run"),
  (Join-Path $root "logs"),
  (Join-Path $root "gateway\bin\gateway.exe")
)

Write-Host "Cleaning generated artifacts..."
foreach ($target in $targets) {
  if (Test-Path $target) {
    Remove-Item -Recurse -Force $target
    Write-Host "  [Removed] $target"
  } else {
    Write-Host "  [Skip]    $target"
  }
}

Write-Host ""
Write-Host "Done."
Write-Host "Note:"
Write-Host "  - This script does NOT remove 3rd/, source files, or docs."
Write-Host "  - If you also want to clean ui/node_modules, remove it manually."
