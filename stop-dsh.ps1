$conns = Get-NetTCPConnection -LocalPort 3080 -State Listen -ErrorAction SilentlyContinue
if ($conns) {
    $pids = $conns | Select-Object -ExpandProperty OwningProcess -Unique
    foreach ($p in $pids) {
        Stop-Process -Id $p -Force -ErrorAction SilentlyContinue
    }
    Write-Host "已停止 DeepSeek Harness（PID：$($pids -join '、')）"
    Write-Host "重新启动：deepseek -b（后台）或 deepseek（前台）"
} else {
    Write-Host "未检测到运行中的 DeepSeek Harness（端口 3080 无监听）"
    Write-Host "启动：deepseek -b（后台）或 deepseek（前台）"
}