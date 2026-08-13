$ErrorActionPreference = 'Stop'
$logDir = Join-Path $env:USERPROFILE 'dsh-launch'
$log = Join-Path $logDir 'dsh-background.log'
$proc = Start-Process -FilePath 'cmd.exe' -ArgumentList '/c','npx --yes @deepseek-ai/dsh web' -WorkingDirectory $env:USERPROFILE -WindowStyle Hidden -RedirectStandardOutput $log -RedirectStandardError "$log.err" -PassThru
Start-Sleep -Seconds 3
if ($proc.HasExited) {
    Write-Host "启动失败，请查看日志：$log"
    exit 1
}
Write-Host "DeepSeek Harness 已在后台启动（PID $($proc.Id)）"
Write-Host "浏览器打开：http://127.0.0.1:3080"
Write-Host "停止服务：双击 stop-dsh.cmd"