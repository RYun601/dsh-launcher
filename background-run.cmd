@echo off
setlocal
if not defined DSH_TARGET for /f "delims=" %%v in ('powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0resolve-dsh-version.ps1" -PreferLocalRuntime') do set "DSH_TARGET=%%v"
if not defined DSH_TARGET set "DSH_TARGET=latest"
if "%DSH_SUPPRESS_BROWSER_MONITOR%"=="1" (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0background-run.ps1" -Version "%DSH_TARGET%" -SuppressBrowserMonitor
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0background-run.ps1" -Version "%DSH_TARGET%"
)
exit /b %ERRORLEVEL%
