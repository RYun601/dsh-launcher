@echo off
title 安装 deepseek 命令
echo ============================================
echo   安装 deepseek 命令到 PATH
echo ============================================
echo.
echo 正在把当前文件夹加入用户 PATH...
powershell -NoProfile -ExecutionPolicy Bypass -Command "$dir=(('%~dp0').TrimEnd('\')); $p=[Environment]::GetEnvironmentVariable('Path','User'); if ($p -split ';' -contains $dir) { Write-Host 'OK: 已在 PATH 中，无需重复添加' } else { [Environment]::SetEnvironmentVariable('Path', (($p.TrimEnd(';'))+';'+$dir), 'User'); Write-Host ('OK: 已添加 ' + $dir) }"
echo.
echo 完成！请新开一个终端窗口，然后输入 deepseek 测试。
echo 说明：当前已打开的终端不会立即生效，需新开窗口。
echo.
pause