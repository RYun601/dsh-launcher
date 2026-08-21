@echo off
title DeepSeek Harness Web
cd /d "%USERPROFILE%"
echo Starting DeepSeek Harness Web...
echo The browser will open automatically when ready.
echo Closing this window stops the service.
echo.
start "" /b powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0open-when-ready.ps1" -PollIntervalMilliseconds 200
for /f "delims=" %%v in ('powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0resolve-dsh-version.ps1" -PreferLocalRuntime') do set "DSH_TARGET=%%v"
if not defined DSH_TARGET set "DSH_TARGET=latest"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0run-dsh.ps1" -Version "%DSH_TARGET%" -DshArguments web -NoOpen
echo.
echo Service stopped (or failed to start).
pause
