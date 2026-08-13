$ErrorActionPreference = 'Stop'
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$log = Join-Path $env:USERPROFILE 'dsh-launch\dsh-background.log'

# 0) 端口预检：已有实例则提示并直接打开浏览器
$existing = Get-NetTCPConnection -LocalPort 3080 -State Listen -ErrorAction SilentlyContinue
if ($existing) {
    Write-Host "端口 3080 已有实例在运行（PID $($existing.OwningProcess)），无需重复启动"
    Write-Host "正在打开浏览器..."
    Start-Process 'http://127.0.0.1:3080'
    exit 0
}

# 1) 日志轮转：超过 1MB 保留为 .old
if (Test-Path $log) {
    $size = (Get-Item $log).Length
    if ($size -gt 1MB) { Move-Item $log "$log.old" -Force }
}

# 2) 启动隐藏进程（实际执行 background-run.cmd，输出合并进日志）
$proc = Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', "`"$dir\background-run.cmd`"" -WorkingDirectory $env:USERPROFILE -WindowStyle Hidden -PassThru

# 3) 启动浏览器监视器（服务就绪后自动打开）
Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$dir\open-when-ready.ps1`"",'-TimeoutSeconds','900' -WindowStyle Hidden

# 4) 轮询等待真实结果（最多 120 秒）：进程退出=失败；端口就绪=成功
$deadline = (Get-Date).AddSeconds(120)
while ((Get-Date) -lt $deadline) {
    if ($proc.HasExited) {
        Write-Host "启动失败！最近日志："
        if (Test-Path $log) { Get-Content $log -Tail 8 }
        exit 1
    }
    if (Get-NetTCPConnection -LocalPort 3080 -State Listen -ErrorAction SilentlyContinue) {
        Write-Host "DeepSeek Harness 已在后台启动（PID $($proc.Id)）"
        Write-Host "服务就绪后浏览器将自动打开 http://127.0.0.1:3080"
        Write-Host "查看状态：deepseek --status"
        Write-Host "停止服务：deepseek --stop"
        exit 0
    }
    Start-Sleep -Seconds 1
}
Write-Host "等待超时（120 秒），进程仍在运行但端口未就绪，请查看日志：$log"
exit 1