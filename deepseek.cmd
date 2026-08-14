@echo off
title DeepSeek Harness
cd /d "%USERPROFILE%"

set "ARGS=%*"

echo %ARGS% | findstr /i /c:"--background" /c:"-b" /c:"--bg" /c:"--daemon" /c:"-d" >nul 2>&1
if not errorlevel 1 goto background

echo %ARGS% | findstr /i /c:"--full" >nul 2>&1
if not errorlevel 1 goto uninstall-full

echo %ARGS% | findstr /i /c:"--stop" /c:"stop" >nul 2>&1
if not errorlevel 1 goto stop

echo %ARGS% | findstr /i /c:"--status" >nul 2>&1
if not errorlevel 1 goto status

echo %ARGS% | findstr /i /c:"--logs" >nul 2>&1
if not errorlevel 1 goto logs

echo %ARGS% | findstr /i /c:"--upgrade" >nul 2>&1
if not errorlevel 1 goto upgrade

echo %ARGS% | findstr /i /c:"--update" /c:"update" >nul 2>&1
if not errorlevel 1 goto update

echo %ARGS% | findstr /i /c:"--version" >nul 2>&1
if not errorlevel 1 goto version

echo %ARGS% | findstr /i /c:"--uninstall" /c:"uninstall" >nul 2>&1
if not errorlevel 1 goto uninstall

echo %ARGS% | findstr /i /c:"--help" /c:"-h" /c:"/?" >nul 2>&1
if not errorlevel 1 goto help

echo %ARGS% | findstr /i /c:"--check" >nul 2>&1
if not errorlevel 1 goto check

goto foreground

:foreground
powershell -NoProfile -ExecutionPolicy Bypass -Command "$c=Get-NetTCPConnection -LocalPort 3080 -State Listen -ErrorAction SilentlyContinue; if ($c) { Write-Host ('[INFO] Port 3080 is already in use (PID ' + $c.OwningProcess + ') - opening browser...'); Start-Process 'http://127.0.0.1:3080'; exit 2 }"
if errorlevel 2 exit /b 0
echo Starting DeepSeek Harness (foreground)...
echo Browser will open automatically at http://127.0.0.1:3080
echo Press Ctrl+C or close this window to stop.
echo.
for /f %%P in ('powershell -NoProfile -Command "(Get-CimInstance Win32_Process -Filter ('ProcessId=' + $PID)).ParentProcessId"') do set "DSH_PPID=%%P"
if defined DSH_PPID (
    start "" /b powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0open-when-ready.ps1" -ParentPid %DSH_PPID%
) else (
    start "" /b powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0open-when-ready.ps1"
)
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
powershell -NoProfile -ExecutionPolicy Bypass -Command "$c=Get-NetTCPConnection -LocalPort 3080 -State Listen -ErrorAction SilentlyContinue; if ($c) { try { $r=Invoke-WebRequest 'http://127.0.0.1:3080' -UseBasicParsing -TimeoutSec 2 -ErrorAction Stop; Write-Host ('RUNNING (ready) - PID ' + $c.OwningProcess) } catch { Write-Host ('RUNNING (starting) - PID ' + $c.OwningProcess) } } else { Write-Host 'NOT RUNNING' }"
exit /b 0

:logs
for /f "tokens=2" %%n in ("%ARGS%") do set "LOGN=%%n"
echo %LOGN% | findstr /r /c:"^[0-9][0-9]*$" >nul 2>&1
if not errorlevel 1 (set "COUNT=%LOGN%") else (set "COUNT=20")
powershell -NoProfile -ExecutionPolicy Bypass -Command "$log=Join-Path $env:USERPROFILE 'dsh-launch\dsh-background.log'; if (Test-Path $log) { Get-Content $log -Tail %COUNT% } else { Write-Host ('No log yet: ' + $log) }"
exit /b 0

:upgrade
echo Upgrading DeepSeek Harness (stop -> clear cache -> restart)...
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0upgrade-dsh.ps1"
exit /b 0

:update
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0update-check.ps1"
exit /b 0

:version
powershell -NoProfile -ExecutionPolicy Bypass -Command "$ver = if (Test-Path '%~dp0VERSION') { (Get-Content '%~dp0VERSION' -Raw).Trim() } else { 'unknown' }; $local = 'unknown'; Get-ChildItem (Join-Path $env:LOCALAPPDATA 'npm-cache\_npx') -Directory -ErrorAction SilentlyContinue | ForEach-Object { $pj = Join-Path $_.FullName 'node_modules\@deepseek-ai\dsh\package.json'; if (Test-Path $pj) { try { $local = (Get-Content $pj -Raw | ConvertFrom-Json).version } catch {} } }; Write-Host ('dsh-launcher ' + $ver); Write-Host ('DeepSeek Harness ' + $local)"
exit /b 0

:uninstall
echo Removing deepseek command from PATH...
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0uninstall.ps1"
exit /b 0

:uninstall-full
echo Full uninstall (PATH + install dir + logs + shortcut)...
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0uninstall.ps1" -Full
exit /b 0

:help
echo Usage:
echo   deepseek                start in foreground mode (default)
echo   deepseek -b / -d        start in background mode (keeps running)
echo   deepseek --status       check service state (ready/starting/not running)
echo   deepseek --stop         stop the running service
echo   deepseek --logs [N]     show last N lines of the background log (default 20)
echo   deepseek --version      show launcher and DeepSeek Harness versions
echo   deepseek --update       check for a newer DeepSeek Harness version
echo   deepseek --upgrade      stop, clear cache, restart with the latest version
echo   deepseek --uninstall    remove this command from PATH
echo   deepseek --uninstall --full   remove everything (PATH, install dir, logs, shortcut)
echo   deepseek --check        check environment and exit
echo   deepseek --help         show this help
exit /b 0

:check
echo deepseek.cmd: OK
echo Script dir: %~dp0
where npx >nul 2>&1 && echo npx: found || echo npx: NOT FOUND
echo GUI address: http://127.0.0.1:3080
exit /b 0
