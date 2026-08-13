@echo off
chcp 65001 >nul
echo ===== %date% %time% ===== >> "%USERPROFILE%\dsh-launch\dsh-background.log"
npx --yes @deepseek-ai/dsh web >> "%USERPROFILE%\dsh-launch\dsh-background.log" 2>&1