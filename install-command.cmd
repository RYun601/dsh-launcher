@echo off
title Install "deepseek" command
echo ============================================
echo   Install the "deepseek" command (add to PATH)
echo ============================================
echo.
echo Adding the current folder to the user PATH...
powershell -NoProfile -ExecutionPolicy Bypass -Command "$dir=(('%~dp0').TrimEnd('\')); $p=[Environment]::GetEnvironmentVariable('Path','User'); if ($p -split ';' -contains $dir) { Write-Host 'OK: already in PATH' } else { [Environment]::SetEnvironmentVariable('Path', (($p.TrimEnd(';'))+';'+$dir), 'User'); Write-Host ('OK: added ' + $dir) }"
echo.
echo Done! Open a NEW terminal window, then type: deepseek
echo Note: already-open terminals will not pick up the new PATH.
echo.
pause