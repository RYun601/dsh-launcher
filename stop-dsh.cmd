@echo off
title DeepSeek Harness ֹͣ
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0stop-dsh.ps1"
echo.
pause