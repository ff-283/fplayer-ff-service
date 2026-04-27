@echo off
setlocal
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\stop-all.ps1"
if errorlevel 1 (
  echo.
  echo Service stop failed.
  pause
)
endlocal
