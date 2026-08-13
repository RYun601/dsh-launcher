@echo off
title DeepSeek Harness
cd /d "%USERPROFILE%"

set "ARGS=%*"

echo %ARGS% | findstr /i /c:"--background" /c:"-b" /c:"--bg" >nul 2>&1
if not errorlevel 1 goto background

echo %ARGS% | findstr /i /c:"--stop" /c:"stop" >nul 2>&1
if not errorlevel 1 goto stop

echo %ARGS% | findstr /i /c:"--status" >nul 2>&1
if not errorlevel 1 goto status

echo %ARGS% | findstr /i /c:"--help" /c:"-h" /c:"/?" >nul 2>&1
if not errorlevel 1 goto help

echo %ARGS% | findstr /i /c:"--check" >nul 2>&1
if not errorlevel 1 goto check

goto foreground

:foreground
echo Starting DeepSeek Harness (foreground)...
echo Browser will open automatically at http://127.0.0.1:3080
echo Press Ctrl+C or close this window to stop.
echo.
start "" /b powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0open-when-ready.ps1"
npx --yes @deepseek-ai/dsh web
echo.
echo Service stopped (or failed to start).
exit /b 0

:background
echo Starting DeepSeek Harness (background)...
echo Close this window anytime - the service keeps running.
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-background.ps1"
exit /b 0

:stop
echo Stopping DeepSeek Harness...
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0stop-dsh.ps1"
exit /b 0

:status
powershell -NoProfile -ExecutionPolicy Bypass -Command "$c=Get-NetTCPConnection -LocalPort 3080 -State Listen -ErrorAction SilentlyContinue; if ($c) { Write-Host ('RUNNING - PID ' + $c.OwningProcess) } else { Write-Host 'NOT RUNNING' }"
exit /b 0

:help
echo Usage:
echo   deepseek                start in foreground mode (default)
echo   deepseek --background   start in background mode (keeps running)
echo   deepseek -b             same as --background
echo   deepseek --stop         stop the running service
echo   deepseek --status       check if the service is running
echo   deepseek --check        check environment and exit
echo   deepseek --help         show this help
exit /b 0

:check
echo deepseek.cmd: OK
echo Script dir: %~dp0
where npx >nul 2>&1 && echo npx: found || echo npx: NOT FOUND
echo GUI address: http://127.0.0.1:3080
exit /b 0