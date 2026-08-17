@echo off
chcp 65001 >nul
title DeepSeek Harness 后台启动
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-background.ps1" -WaitForReady -TimeoutSeconds 900
set "DSH_EXIT_CODE=%ERRORLEVEL%"
if not "%DSH_EXIT_CODE%"=="0" (
    echo.
    echo 启动失败，窗口将保留以便查看以上信息。
    echo 按任意键关闭...
    pause >nul
)
exit /b %DSH_EXIT_CODE%
