# —— 控制台编码修复 ——
# 在代码页被切到 UTF-8(65001) 的传统控制台里，中文输出会出现“每个字重复”的重影 bug。
# 这里把控制台代码页与输出编码统一回系统 ANSI 代码页（中文系统为 936/GBK）。
try {
    $__dsh_cp = [Globalization.CultureInfo]::CurrentCulture.TextInfo.ANSICodePage
    if ($__dsh_cp -ne 65001) {
        chcp $__dsh_cp | Out-Null
        $__dsh_enc = [Text.Encoding]::GetEncoding($__dsh_cp)
        [Console]::OutputEncoding = $__dsh_enc
        [Console]::InputEncoding  = $__dsh_enc
        $OutputEncoding = $__dsh_enc
    }
} catch { }
$conns = Get-NetTCPConnection -LocalPort 3080 -State Listen -ErrorAction SilentlyContinue
if ($conns) {
    $pids = $conns | Select-Object -ExpandProperty OwningProcess -Unique
    $stopped = @()
    foreach ($p in $pids) {
        $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$p" -ErrorAction SilentlyContinue
        $cmdLine = if ($proc) { $proc.CommandLine } else { '' }
        if ($cmdLine -match 'dsh|@deepseek-ai') {
            Stop-Process -Id $p -Force -ErrorAction SilentlyContinue
            $stopped += $p
        } else {
            $name = if ($proc) { $proc.Name } else { '未知进程' }
            Write-Host "端口 3080 被其他程序占用（PID $p：$name），已跳过停止，请人工确认"
        }
    }
    if ($stopped) {
        Write-Host "已停止 DeepSeek Harness（PID：$($stopped -join '、')）"
        Write-Host "重新启动：deepseek -b（后台）或 deepseek（前台）"
    } else {
        Write-Host "端口 3080 无 DeepSeek Harness 进程，未执行停止"
    }
} else {
    Write-Host "未检测到运行中的 DeepSeek Harness（端口 3080 无监听）"
    Write-Host "启动：deepseek -b（后台）或 deepseek（前台）"
}