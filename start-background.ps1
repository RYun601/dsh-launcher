param(
    [switch]$WaitForReady,
    [ValidateRange(1, 86400)]
    [int]$TimeoutSeconds = 900,
    [string]$Version,
    [ValidateRange(1, 65535)]
    [int]$Port = 3080
)

$ErrorActionPreference = 'Stop'
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

$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$launchRoot = Join-Path $env:USERPROFILE 'dsh-launch'
$log = Join-Path $launchRoot 'dsh-background.log'
$stateHelper = Join-Path $dir 'dsh-launch-state.ps1'
$url = "http://127.0.0.1:$Port"
New-Item -ItemType Directory -Force -Path (Split-Path $log -Parent) | Out-Null

function Write-StartupFailure {
    param([string]$Message)

    Write-Host $Message
    Write-Host "日志：$log"
    if (Test-Path $log) {
        Write-Host '最近日志：'
        Get-Content $log -Tail 8 -Encoding UTF8 | ForEach-Object { Write-Host $_ }
    }
}

function Test-DshReady {
    try {
        $response = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 2 -ErrorAction Stop
        return $response.StatusCode -ge 200 -and $response.StatusCode -lt 500
    } catch {
        return $false
    }
}

function Test-TcpPortOpen {
    param(
        [string]$HostName = '127.0.0.1',
        [Parameter(Mandatory = $true)][int]$TargetPort,
        [int]$TimeoutMilliseconds = 200
    )

    $client = [Net.Sockets.TcpClient]::new()
    try {
        $pending = $client.BeginConnect($HostName, $TargetPort, $null, $null)
        if (-not $pending.AsyncWaitHandle.WaitOne($TimeoutMilliseconds)) {
            return $false
        }
        $client.EndConnect($pending)
        return $true
    } catch {
        return $false
    } finally {
        $client.Dispose()
    }
}

function Get-DshStartupState {
    try {
        $stateJson = [string](@(& $stateHelper -Action GetStartupState -LaunchRoot $launchRoot) -join '')
        if ($stateJson) { return $stateJson | ConvertFrom-Json }
    } catch { }
    return $null
}

function Wait-DshStartup {
    param(
        [Parameter(Mandatory = $true)][int]$OwnerPid,
        [object]$SubmittedProcess
    )

    $startedAt = Get-Date
    $deadline = $startedAt.AddSeconds($TimeoutSeconds)
    $nextProgressSeconds = 5
    while ((Get-Date) -lt $deadline) {
        if (Test-DshReady) {
            Write-Host "DeepSeek Harness 服务已就绪（PID $OwnerPid）"
            Write-Host '查看状态：deepseek --status'
            Write-Host '查看日志：deepseek --logs'
            Write-Host '停止服务：deepseek --stop'
            return 0
        }

        $startupState = Get-DshStartupState
        if ($startupState -and $startupState.State -eq 'FAILED') {
            $reason = if ($startupState.Message) { [string]$startupState.Message } else { '后台启动失败' }
            Write-StartupFailure "启动失败：$reason"
            return 1
        }

        $ownerExited = if ($SubmittedProcess) {
            $SubmittedProcess.HasExited
        } else {
            $null -eq (Get-Process -Id $OwnerPid -ErrorAction SilentlyContinue)
        }
        if ($ownerExited) {
            Write-StartupFailure '启动失败：后台进程已退出。'
            return 1
        }

        $elapsedSeconds = [int]((Get-Date) - $startedAt).TotalSeconds
        if ($elapsedSeconds -ge $nextProgressSeconds) {
            Write-Host "仍在启动，已等待 $elapsedSeconds 秒..."
            $nextProgressSeconds += 5
        }
        Start-Sleep -Seconds 1
    }

    Write-StartupFailure "启动超时：等待 $TimeoutSeconds 秒后服务仍未就绪。"
    return 1
}

# A live launcher-owned lock means npx is already installing or starting DSH.
# Do not submit another process that would contend for the same npx workspace.
$lockStatus = @(& $stateHelper -Action TestStartupLock -LaunchRoot $launchRoot)
if ($LASTEXITCODE -ne 0) {
    Write-StartupFailure '启动失败：无法检查后台启动状态。'
    exit 1
}
$lockText = [string]($lockStatus -join [Environment]::NewLine)
if ($lockText -match '^LOCKED\s+(\d+)') {
    $existingOwnerPid = [int]$Matches[1]
    Write-Host "DeepSeek Harness 已在启动中（PID $existingOwnerPid），未重复提交启动任务"
    Write-Host "查看状态：deepseek --status"
    Write-Host "查看日志：deepseek --logs"
    if (-not $WaitForReady) { exit 0 }
    Write-Host '正在等待现有启动任务完成...'
    exit (Wait-DshStartup -OwnerPid $existingOwnerPid)
}

# 0) 端口预检：只有在确认没有正在进行的 launcher startup 后，才允许
# 直接复用一个已监听的服务并打开浏览器。这样不会和原 runner 的 monitor 重复打开。
$existing = if (Test-TcpPortOpen -TargetPort $Port) {
    Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
}
if ($existing) {
    Write-Host "端口 $Port 已有实例在运行（PID $($existing.OwningProcess)），无需重复启动"
    Write-Host '正在打开浏览器...'
    Start-Process $url
    exit 0
}

if (-not $Version) {
    $runtimeRoot = Join-Path $launchRoot 'runtime'
    $Version = [string](@(& (Join-Path $dir 'resolve-dsh-version.ps1') `
        -PreferLocalRuntime -RuntimeRoot $runtimeRoot) -join '')
    if (-not $Version) { $Version = 'latest' }
}

# 1) 日志轮转：超过 1MB 保留为 .old
if (Test-Path $log) {
    $size = (Get-Item $log).Length
    if ($size -gt 1MB) { Move-Item $log "$log.old" -Force }
}

# 2) Reserve before spawning. The child waits on a gate until ownership has
# been transferred to its real CMD process ID.
$startupToken = [guid]::NewGuid().ToString('N')
$gatePath = Join-Path $launchRoot ("startup-$startupToken.gate")
$initialReservation = @(& $stateHelper -Action AcquireStartupLock -LaunchRoot $launchRoot `
    -OwnerPid $PID -StartupToken $startupToken)
if ($LASTEXITCODE -eq 2) {
    $owner = ([string]($initialReservation -join [Environment]::NewLine) -replace '^LOCKED\s*', '').Trim()
    Write-Host "DeepSeek Harness 已在启动中（PID $owner），未重复提交启动任务"
    if ($WaitForReady -and $owner -match '^\d+$') {
        exit (Wait-DshStartup -OwnerPid ([int]$owner))
    }
    exit 0
}
if ($LASTEXITCODE -ne 0) {
    Write-StartupFailure '启动失败：无法预留后台启动状态。'
    exit 1
}

$hadStartupToken = Test-Path -LiteralPath 'Env:\DSH_STARTUP_TOKEN'
$previousStartupToken = [Environment]::GetEnvironmentVariable('DSH_STARTUP_TOKEN', 'Process')
$hadCoordinatorGate = Test-Path -LiteralPath 'Env:\DSH_COORDINATOR_GATE'
$previousCoordinatorGate = [Environment]::GetEnvironmentVariable('DSH_COORDINATOR_GATE', 'Process')
$env:DSH_STARTUP_TOKEN = $startupToken
$env:DSH_COORDINATOR_GATE = $gatePath
try {
    $runnerScript = Join-Path $dir 'background-run.ps1'
    $runnerArguments = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', "`"$runnerScript`"",
        '-Version', $Version,
        '-LaunchRoot', "`"$launchRoot`"",
        '-StartupToken', $startupToken,
        '-CoordinatorGate', "`"$gatePath`"",
        '-TimeoutSeconds', [string]$TimeoutSeconds
    )
    $systemPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $proc = Start-Process -FilePath $systemPowerShell -ArgumentList $runnerArguments `
        -WorkingDirectory $env:USERPROFILE -WindowStyle Hidden -PassThru
} catch {
    & $stateHelper -Action ReleaseStartupLock -LaunchRoot $launchRoot -OwnerPid $PID -StartupToken $startupToken | Out-Null
    throw
} finally {
    if ($hadStartupToken) {
        $env:DSH_STARTUP_TOKEN = $previousStartupToken
    } else {
        Remove-Item -LiteralPath 'Env:\DSH_STARTUP_TOKEN' -ErrorAction SilentlyContinue
    }
    if ($hadCoordinatorGate) {
        $env:DSH_COORDINATOR_GATE = $previousCoordinatorGate
    } else {
        Remove-Item -LiteralPath 'Env:\DSH_COORDINATOR_GATE' -ErrorAction SilentlyContinue
    }
}
$reservation = @(& $stateHelper -Action AcquireStartupLock -LaunchRoot $launchRoot -OwnerPid $proc.Id -StartupToken $startupToken -TransferOwnership)
if ($LASTEXITCODE -eq 2) {
    [IO.File]::WriteAllText($gatePath, 'CANCEL', [Text.Encoding]::ASCII)
    $owner = ([string]($reservation -join [Environment]::NewLine) -replace '^LOCKED\s*', '').Trim()
    Write-Host "DeepSeek Harness 已在启动中（PID $owner），未重复提交启动任务"
    Write-Host '查看状态：deepseek --status'
    Write-Host '查看日志：deepseek --logs'
    exit 0
}
if ($LASTEXITCODE -ne 0) {
    [IO.File]::WriteAllText($gatePath, 'CANCEL', [Text.Encoding]::ASCII)
    Write-StartupFailure '启动失败：无法登记后台启动状态。'
    exit 1
}
& $stateHelper -Action WriteStartupState -LaunchRoot $launchRoot -State STARTING `
    -OwnerPid $proc.Id -Version $Version -Message 'Installing or starting DeepSeek Harness' | Out-Null
[IO.File]::WriteAllText($gatePath, 'GO', [Text.Encoding]::ASCII)

# 3) 命令行后台模式：提交启动后立即返回，由独立监视器负责就绪后打开浏览器
if (-not $WaitForReady) {
    Write-Host "DeepSeek Harness 后台启动已提交（PID $($proc.Id)）"
    Write-Host "服务就绪后浏览器将自动打开 $url"
    Write-Host '查看状态：deepseek --status'
    Write-Host '查看日志：deepseek --logs'
    Write-Host '停止服务：deepseek --stop'
    exit 0
}

# 4) 快捷方式/升级模式：等待 HTTP 真正可用；runner monitor 负责打开浏览器
Write-Host "DeepSeek Harness 正在后台启动（PID $($proc.Id)）"
Write-Host '正在等待服务就绪；首次下载可能需要几分钟...'
exit (Wait-DshStartup -OwnerPid $proc.Id -SubmittedProcess $proc)
