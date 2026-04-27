@echo off
setlocal
cd /d "%~dp0"
echo [Info] start-service.bat is for local development only.
echo [Info] For release distribution, run release\portable\FPlayerFFService.exe directly.
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\start-all.ps1"
if errorlevel 1 (
  echo.
  echo Service start failed.
  pause
)
endlocal
