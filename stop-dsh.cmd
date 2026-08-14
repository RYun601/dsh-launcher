@echo off
chcp 65001 >nul
title DeepSeek Harness 停止
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0stop-dsh.ps1"
echo.
pause
