@echo off
title DeepSeek Harness Web
cd /d "%USERPROFILE%"
echo Starting DeepSeek Harness Web...
echo The browser will open automatically when ready.
echo Closing this window stops the service.
echo.
start "" /b powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0open-when-ready.ps1"
npx --yes @deepseek-ai/dsh web
echo.
echo Service stopped (or failed to start).
pause