@echo off
setlocal
cd /d "%~dp0"
echo [Info] Starting fplayer-ff-service in kernel mode (no UI)...
echo.
cd /d ".\ui"
call npm run start:kernel
if errorlevel 1 (
  echo.
  echo Kernel mode start failed.
  pause
)
endlocal
