@echo off
title Install "deepseek" command
echo ============================================
echo   Install the "deepseek" command (add to PATH)
echo ============================================
echo.
echo Adding the current folder to the user PATH...
rem R8: path registration lives in register-path.ps1; -File quoting survives
rem install paths with spaces, single quotes, exclamation marks or non-ASCII.
rem A registration failure must propagate its exit code instead of printing Done.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0register-path.ps1" -InstallDir "%~dp0"
set "DSH_RC=%ERRORLEVEL%"
if not "%DSH_RC%"=="0" (
    echo.
    echo Failed to update the user PATH (exit code %DSH_RC%). Close this window and retry,
    echo or add the folder to the user PATH manually via System Properties.
    exit /b %DSH_RC%
)
echo.
echo Done! Open a NEW terminal window, then type: deepseek
echo Note: already-open terminals will not pick up the new PATH.
echo.
pause
exit /b 0
