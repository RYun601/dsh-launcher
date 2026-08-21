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
$ErrorActionPreference = 'Stop'
$launchRoot = Join-Path $env:USERPROFILE 'dsh-launch'
$stateHelper = Join-Path $PSScriptRoot 'dsh-launch-state.ps1'
$stopped = @()

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
    return $true
}

$conns = Get-NetTCPConnection -LocalPort 3080 -State Listen -ErrorAction SilentlyContinue
if ($conns) {
    $pids = $conns | Select-Object -ExpandProperty OwningProcess -Unique
    foreach ($p in $pids) {
        if (Stop-DshProcessTree -ProcessId $p) {
            $stopped += $p
        } else {
            $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$p" -ErrorAction SilentlyContinue
            $name = if ($proc) { $proc.Name } else { '未知进程' }
            Write-Host "端口 3080 被其他程序占用（PID $p：$name），已跳过停止，请人工确认"
        }
    }
}

$lockStatus = @(& $stateHelper -Action TestStartupLock -LaunchRoot $launchRoot)
if ($LASTEXITCODE -eq 0 -and [string]($lockStatus -join '') -match '^LOCKED\s+(\d+)') {
    $startupOwner = [int]$Matches[1]
    if ($stopped -notcontains $startupOwner -and (Stop-DshProcessTree -ProcessId $startupOwner)) {
        $stopped += $startupOwner
    }
}

if ($stopped) {
    for ($attempt = 0; $attempt -lt 50; $attempt++) {
        $remainingPort = Get-NetTCPConnection -LocalPort 3080 -State Listen -ErrorAction SilentlyContinue
        $remainingLock = [string](@(& $stateHelper -Action TestStartupLock -LaunchRoot $launchRoot) -join '')
        if (-not $remainingPort -and $remainingLock -eq 'UNLOCKED') { break }
        Start-Sleep -Milliseconds 100
    }
    Write-Host "已停止 DeepSeek Harness（PID：$($stopped -join '、')）"
    Write-Host "重新启动：deepseek -b（后台）或 deepseek（前台）"
} elseif (-not $conns) {
    Write-Host "未检测到运行中的 DeepSeek Harness（端口 3080 无监听）"
    Write-Host "启动：deepseek -b（后台）或 deepseek（前台）"
} else {
    Write-Host "端口 3080 无 DeepSeek Harness 进程，未执行停止"
}
