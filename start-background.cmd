@echo off
chcp 65001 >nul
title DeepSeek Harness 后台启动
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-background.ps1"
echo.
pause