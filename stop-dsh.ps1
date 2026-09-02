# —— 控制台编码修复 ——
# 在代码页被切到 UTF-8(65001) 的传统控制台里，中文输出会出现“每个字重复”的重影 bug。
# 这里把控制台代码页与输出编码统一回系统 ANSI 代码页（中文系统为 936/GBK）。
param(
    [ValidateRange(1, 65535)][int]$Port = 3080,
    [string]$LaunchRoot,
    [ValidateRange(100, 600000)][int]$WaitTimeoutMilliseconds = 5000
)
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
$ErrorActionPreference = 'Stop'
if (-not $LaunchRoot) { $LaunchRoot = Join-Path $env:USERPROFILE 'dsh-launch' }
$stateHelper = Join-Path $PSScriptRoot 'dsh-launch-state.ps1'
$stopped = @()
# 已尝试结束但未成功的 PID：既用于避免重复 taskkill，也用于最终失败诊断。
$killedFailures = @()

function Test-DshLauncherProcess {
    param([Parameter(Mandatory = $true)][int]$ProcessId)

    $process = Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction SilentlyContinue
    if (-not $process) { return $false }
    $commandLine = [string]$process.CommandLine
    return $commandLine -match '(?i)(background-run\.(?:cmd|ps1)|run-dsh\.ps1|@deepseek-ai[\\/]dsh|[\\/]dsh[\\/]lib[\\/]bin\.js)'
}

function Stop-DshProcessTree {
    param([Parameter(Mandatory = $true)][int]$ProcessId)

    if (-not (Test-DshLauncherProcess -ProcessId $ProcessId)) { return $false }
    & taskkill.exe /PID $ProcessId /T /F 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        # 进程可能在身份校验和 taskkill 之间自行退出；此时停止目标已经达成。
        # 端口与启动锁仍会在调用方的条件等待中再次确认，避免把子进程残留误判为成功。
        if (-not (Test-DshLauncherProcess -ProcessId $ProcessId)) {
            $global:LASTEXITCODE = 0
            return $true
        }
        Write-Host "[ERROR] 结束 DSH 进程失败：taskkill /PID $ProcessId 返回退出码 $LASTEXITCODE。"
        return 'failed'
    }
    return $true
}

$conns = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
if ($conns) {
    $pids = $conns | Select-Object -ExpandProperty OwningProcess -Unique
    foreach ($p in $pids) {
        $outcome = Stop-DshProcessTree -ProcessId $p
        if ($outcome -eq $true) {
            $stopped += $p
        } elseif ($outcome -ne 'failed') {
            $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$p" -ErrorAction SilentlyContinue
            $name = if ($proc) { $proc.Name } else { '未知进程' }
            Write-Host "端口 $Port 被其他程序占用（PID $p：$name），已跳过停止，请人工确认"
        } else {
            $killedFailures += $p
        }
    }
}

$lockStatus = @(& $stateHelper -Action TestStartupLock -LaunchRoot $launchRoot)
if ($LASTEXITCODE -eq 0 -and [string]($lockStatus -join '') -match '^LOCKED\s+(\d+)') {
    $startupOwner = [int]$Matches[1]
    if ($stopped -notcontains $startupOwner -and $killedFailures -notcontains $startupOwner) {
        if ((Stop-DshProcessTree -ProcessId $startupOwner) -eq $true) {
            $stopped += $startupOwner
        } else {
            $killedFailures += $startupOwner
        }
    }
}

if ($killedFailures) {
    Write-Host "[ERROR] 未能停止 DeepSeek Harness（PID：$($killedFailures -join '、')），停止命令失败（stop failed）；请根据上方 taskkill 错误人工处理。"
    exit 1
}

if ($stopped) {
    $deadline = [DateTime]::UtcNow.AddMilliseconds($WaitTimeoutMilliseconds)
    while ($true) {
        $remainingPort = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
        $remainingLock = [string](@(& $stateHelper -Action TestStartupLock -LaunchRoot $launchRoot) -join '')
        if (-not $remainingPort -and $remainingLock -eq 'UNLOCKED') { break }
        if ([DateTime]::UtcNow -ge $deadline) {
            Write-Host "[ERROR] 停止超时（stop timeout）：进程、端口或启动锁在 ${WaitTimeoutMilliseconds}ms 内未完全释放。"
            foreach ($leftOwner in @($remainingPort | Select-Object -ExpandProperty OwningProcess -Unique)) {
                Write-Host "残留监听：/PID $leftOwner /T /F 未生效，端口 $Port 仍被占用"
            }
            if ($remainingLock -ne 'UNLOCKED') {
                Write-Host "启动锁仍未释放（TestStartupLock -> $remainingLock）"
            }
            exit 1
        }
        Start-Sleep -Milliseconds 200
    }
    Write-Host "已停止 DeepSeek Harness（PID：$($stopped -join '、')）"
    Write-Host "重新启动：deepseek -b（后台）或 deepseek（前台）"
} elseif (-not $conns) {
    Write-Host "未检测到运行中的 DeepSeek Harness（端口 $Port 无监听）"
    Write-Host "启动：deepseek -b（后台）或 deepseek（前台）"
} else {
    Write-Host "端口 $Port 无 DeepSeek Harness 进程，未执行停止"
}
