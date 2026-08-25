@echo off
title DeepSeek Harness Web
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-foreground.ps1"
set "DSH_RC=%ERRORLEVEL%"
exit /b %DSH_RC%
