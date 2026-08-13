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

echo 正在创建桌面快捷方式...
powershell -NoProfile -ExecutionPolicy Bypass -Command "$d=[Environment]::GetFolderPath('Desktop'); $s=(New-Object -ComObject WScript.Shell).CreateShortcut($d+'\DeepSeek Harness.lnk'); $s.TargetPath='%~dp0start-deepseek-harness.bat'; $s.WorkingDirectory='%~dp0'; $s.IconLocation='%~dp0deepseek.ico,0'; $s.Save()"
if errorlevel 1 (
    echo [错误] 快捷方式创建失败，请检查权限后重试。
) else (
    echo [OK] 桌面快捷方式创建成功！
    echo 现在双击桌面的「DeepSeek Harness」即可启动，浏览器打开 http://127.0.0.1:3080
)
echo.
pause