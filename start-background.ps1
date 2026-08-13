$ErrorActionPreference = 'Stop'
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$logDir = Join-Path $env:USERPROFILE 'dsh-launch'
$log = Join-Path $logDir 'dsh-background.log'
$proc = Start-Process -FilePath 'cmd.exe' -ArgumentList '/c','npx --yes @deepseek-ai/dsh web' -WorkingDirectory $env:USERPROFILE -WindowStyle Hidden -RedirectStandardOutput $log -RedirectStandardError "$log.err" -PassThru
# 后台启动浏览器监视器（服务就绪后自动打开）
Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$dir\open-when-ready.ps1`"",'-TimeoutSeconds','900' -WindowStyle Hidden
Start-Sleep -Seconds 3
if ($proc.HasExited) {
    Write-Host "启动失败，请查看日志：$log"
    exit 1
}
Write-Host "DeepSeek Harness 已在后台启动（PID $($proc.Id)）"
Write-Host "服务就绪后浏览器将自动打开 http://127.0.0.1:3080"
Write-Host "查看状态：deepseek --status"
Write-Host "停止服务：deepseek --stop"