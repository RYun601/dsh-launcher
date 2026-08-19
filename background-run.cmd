@echo off
if not exist "%USERPROFILE%\dsh-launch" mkdir "%USERPROFILE%\dsh-launch"
chcp 65001 >nul
echo ===== %date% %time% ===== >> "%USERPROFILE%\dsh-launch\dsh-background.log"
start "" /b powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0open-when-ready.ps1" -TimeoutSeconds 900 >nul 2>&1
npx --yes @deepseek-ai/dsh web >> "%USERPROFILE%\dsh-launch\dsh-background.log" 2>&1
