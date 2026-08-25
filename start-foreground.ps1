param(
    [string]$Version,
    [string]$LaunchRoot = (Join-Path $env:USERPROFILE 'dsh-launch'),
    [ValidateRange(1, 65535)]
    [int]$Port = 3080,
    [ValidateRange(1, 86400)]
    [int]$TimeoutSeconds = 900
)

$ErrorActionPreference = 'Stop'
$stateHelper = Join-Path $PSScriptRoot 'dsh-launch-state.ps1'
$healthHelper = Join-Path $PSScriptRoot 'dsh-service-health.ps1'
$monitorScript = Join-Path $PSScriptRoot 'open-when-ready.ps1'
$runScript = Join-Path $PSScriptRoot 'run-dsh.ps1'
$runtimeRoot = Join-Path $LaunchRoot 'runtime'
$entrypoint = Join-Path $runtimeRoot 'node_modules\@deepseek-ai\dsh\lib\bin.js'
$url = "http://127.0.0.1:$Port"
$startupToken = [guid]::NewGuid().ToString('N')
$commandPath = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
$scriptPath = [IO.Path]::GetFullPath($MyInvocation.MyCommand.Path)
$systemPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$ownsStartupLock = $false
$dshStarted = $false
$dshExitCode = 1

. $healthHelper
New-Item -ItemType Directory -Force -Path $LaunchRoot | Out-Null

function Get-ForegroundStartupState {
    try {
        $json = [string](@(& $stateHelper -Action GetStartupState -LaunchRoot $LaunchRoot) -join '')
        if ($json) { return $json | ConvertFrom-Json }
    } catch { }
    return $null
}

$existingState = Get-ForegroundStartupState
$expectedEntrypoint = if ($existingState -and $existingState.Entrypoint) {
    [string]$existingState.Entrypoint
} else {
    $entrypoint
}
$expectedToken = if ($existingState -and $existingState.StartupToken) {
    [string]$existingState.StartupToken
} else {
    ''
}
$expectedRunnerPid = if ($existingState -and $existingState.RunnerPid) {
    [int]$existingState.RunnerPid
} else {
    0
}
$existing = Get-DshServiceClassification -Port $Port -ExpectedEntrypoint $expectedEntrypoint `
    -ExpectedStartupToken $expectedToken -RunnerPid $expectedRunnerPid
if ($existing.State -eq 'READY') {
    Write-Host "[REUSE] DeepSeek Harness is already ready (PID $($existing.ServicePid))."
    Start-Process $url
    exit 0
}
if ($existing.State -ne 'STOPPED') {
    Write-Host "[ERROR] $($existing.State) - $($existing.Message)"
    exit 1
}

if (-not $Version) {
    $Version = [string](@(& (Join-Path $PSScriptRoot 'resolve-dsh-version.ps1') `
        -PreferLocalRuntime -RuntimeRoot $runtimeRoot) -join '')
    if (-not $Version) { $Version = 'latest' }
}

try {
    $lockOutput = @(& $stateHelper -Action AcquireStartupLock -LaunchRoot $LaunchRoot `
        -OwnerPid $PID -StartupToken $startupToken -CommandPath $commandPath -ScriptPath $scriptPath 2>&1)
    $lockExitCode = $LASTEXITCODE
    $lockText = [string]($lockOutput -join [Environment]::NewLine)
    if ($lockExitCode -eq 2 -or $lockText -match '(?m)^LOCKED\s+\d+\s*$') {
        Write-Host '[INFO] DeepSeek Harness is already starting; this foreground request did not start another instance.'
        exit 0
    }
    if ($lockExitCode -ne 0 -or $lockText -notmatch '(?m)^(?:ACQUIRED|OWNED)\s+\d+\s*$') {
        throw "Unable to acquire the foreground startup lock: $lockText"
    }
    $ownsStartupLock = $true

    & $stateHelper -Action WriteStartupState -LaunchRoot $LaunchRoot -State STARTING `
        -OwnerPid $PID -StartupToken $startupToken -RuntimeRoot $runtimeRoot `
        -Entrypoint $entrypoint -Version $Version -Message 'Installing or starting DeepSeek Harness' | Out-Null

    $monitorArguments = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', "`"$monitorScript`"",
        '-TimeoutSeconds', [string]$TimeoutSeconds,
        '-ParentPid', [string]$PID,
        '-LaunchRoot', "`"$LaunchRoot`"",
        '-OwnerPid', [string]$PID,
        '-StartupToken', $startupToken,
        '-RuntimeRoot', "`"$runtimeRoot`"",
        '-Entrypoint', "`"$entrypoint`"",
        '-Port', [string]$Port,
        '-StableMilliseconds', '5000',
        '-PollIntervalMilliseconds', '200'
    )
    Start-Process -FilePath $systemPowerShell -ArgumentList $monitorArguments `
        -WindowStyle Hidden -ErrorAction Stop | Out-Null

    Write-Host 'Starting DeepSeek Harness (foreground)...'
    Write-Host "Browser will open automatically at $url"
    Write-Host 'Press Ctrl+C or close this window to stop.'
    Write-Host
    $dshStarted = $true
    $runArguments = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', $runScript,
        '-Version', $Version,
        '-RuntimeRoot', $runtimeRoot,
        '-DshArguments', 'web',
        '-NoOpen'
    )
    & $systemPowerShell @runArguments
    $dshExitCode = $LASTEXITCODE
} catch {
    $dshExitCode = 1
    Write-Host "[ERROR] $($_.Exception.Message)"
    if ($ownsStartupLock -and -not $dshStarted) {
        & $stateHelper -Action WriteStartupState -LaunchRoot $LaunchRoot -State FAILED `
            -OwnerPid $PID -StartupToken $startupToken -RuntimeRoot $runtimeRoot `
            -Entrypoint $entrypoint -Version $Version -ExitCode 1 -Message $_.Exception.Message | Out-Null
    }
} finally {
    if ($dshStarted) {
        & $stateHelper -Action RecordStartupExit -LaunchRoot $LaunchRoot -OwnerPid $PID `
            -StartupToken $startupToken -RuntimeRoot $runtimeRoot -Entrypoint $entrypoint `
            -Version $Version -ExitCode $dshExitCode -Message 'DSH exited before readiness' | Out-Null
    }
    if ($ownsStartupLock) {
        & $stateHelper -Action ReleaseStartupLock -LaunchRoot $LaunchRoot -OwnerPid $PID `
            -StartupToken $startupToken | Out-Null
    }
}

Write-Host
Write-Host 'Service stopped (or failed to start).'
exit $dshExitCode
