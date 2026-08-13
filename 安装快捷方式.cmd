@echo off
title DeepSeek Harness 快捷方式安装
echo ============================================
echo   DeepSeek Harness 快捷方式安装脚本
echo ============================================
echo.

rem 检查 Node.js
node --version >nul 2>&1
if errorlevel 1 (
    echo [错误] 未检测到 Node.js。
    echo 请先到 https://nodejs.org 下载安装 LTS 版本，然后重新运行本脚本。
    start https://nodejs.org
    pause
    exit /b 1
)
echo [OK] 已检测到 Node.js：
node --version
echo.

echo 正在创建桌面快捷方式（前台 + 后台）...
powershell -NoProfile -ExecutionPolicy Bypass -Command "$d=[Environment]::GetFolderPath('Desktop'); $w=New-Object -ComObject WScript.Shell; $a=$w.CreateShortcut($d+'\DeepSeek Harness.lnk'); $a.TargetPath='%~dp0start-deepseek-harness.bat'; $a.WorkingDirectory='%~dp0'; $a.IconLocation='%~dp0deepseek.ico,0'; $a.Save(); $b=$w.CreateShortcut($d+'\DeepSeek Harness（后台）.lnk'); $b.TargetPath='%~dp0start-background.cmd'; $b.WorkingDirectory='%~dp0'; $b.IconLocation='%~dp0deepseek.ico,0'; $b.Save()"
if errorlevel 1 (
    echo [错误] 快捷方式创建失败，请检查权限后重试。
) else (
    echo [OK] 已生成两个快捷方式：
    echo   「DeepSeek Harness」        - 前台启动（窗口+日志，关窗即停）
    echo   「DeepSeek Harness（后台）」- 后台启动（无窗口，关窗不影响）
    echo 浏览器打开 http://127.0.0.1:3080
)
echo.
pause