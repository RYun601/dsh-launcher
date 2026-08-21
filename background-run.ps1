param(
    [Parameter(Mandatory = $true)]
    [string]$Version,

    [string]$LaunchRoot = (Join-Path $env:USERPROFILE 'dsh-launch'),

    [string]$StartupToken = $env:DSH_STARTUP_TOKEN,

    [string]$CoordinatorGate = $env:DSH_COORDINATOR_GATE,

    [switch]$SuppressBrowserMonitor,

    [ValidateRange(1, 86400)]
    [int]$TimeoutSeconds = 900
)

$ErrorActionPreference = 'Stop'
$stateHelper = Join-Path $PSScriptRoot 'dsh-launch-state.ps1'
$runScript = Join-Path $PSScriptRoot 'run-dsh.ps1'
$monitorScript = Join-Path $PSScriptRoot 'open-when-ready.ps1'
$log = Join-Path $LaunchRoot 'dsh-background.log'
$systemPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$dshExitCode = 1
$dshStarted = $false
$ownsStartupLock = $false

if ($env:DSH_SUPPRESS_BROWSER_MONITOR -eq '1') {
    $SuppressBrowserMonitor = $true
}
if (-not $StartupToken) {
    $StartupToken = [guid]::NewGuid().ToString('N')
}

New-Item -ItemType Directory -Force -Path $LaunchRoot | Out-Null
Add-Content -LiteralPath $log -Encoding UTF8 -Value ('===== {0:yyyy-MM-dd HH:mm:ss.fff} =====' -f (Get-Date))
Add-Content -LiteralPath $log -Encoding UTF8 -Value "Runner PID: $PID"

function Add-RunnerLogLines {
    param([object[]]$Lines)

    foreach ($line in @($Lines)) {
        if ($null -ne $line) {
            Add-Content -LiteralPath $log -Encoding UTF8 -Value ([string]$line)
        }
    }
}

if ($CoordinatorGate) {
    $gateAction = ''
    $gateDeadline = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $gateDeadline -and -not $gateAction) {
        if (Test-Path -LiteralPath $CoordinatorGate) {
            try {
                $gateAction = ([IO.File]::ReadAllText($CoordinatorGate, [Text.Encoding]::ASCII)).Trim()
            } catch [IO.IOException] { }
        }
        if (-not $gateAction) {
            Start-Sleep -Milliseconds 100
        }
    }
    Remove-Item -LiteralPath $CoordinatorGate -Force -ErrorAction SilentlyContinue
    if ($gateAction -ne 'GO') {
        $message = if ($gateAction -eq 'CANCEL') { 'Coordinator cancelled startup.' } else { 'Coordinator gate timed out.' }
        Add-Content -LiteralPath $log -Encoding UTF8 -Value $message
        $releaseOutput = @(& $stateHelper -Action ReleaseStartupLock -LaunchRoot $LaunchRoot `
            -OwnerPid $PID -StartupToken $StartupToken 2>&1)
        Add-RunnerLogLines -Lines $releaseOutput
        if ($gateAction -eq 'CANCEL') { exit 0 }
        $failureOutput = @(& $stateHelper -Action RecordStartupExit -LaunchRoot $LaunchRoot -OwnerPid $PID `
            -Version $Version -ExitCode 1 -Message $message 2>&1)
        Add-RunnerLogLines -Lines $failureOutput
        exit 1
    }
}

try {
    $lockOutput = @(& $stateHelper -Action AcquireStartupLock -LaunchRoot $LaunchRoot `
        -OwnerPid $PID -StartupToken $StartupToken -TransferOwnership 2>&1)
    $lockExitCode = $LASTEXITCODE
    $lockText = [string]($lockOutput -join [Environment]::NewLine)
    Add-Content -LiteralPath $log -Encoding UTF8 -Value $lockText
    if ($lockExitCode -ne 0 -or $lockText -notmatch '(?m)^(?:ACQUIRED|OWNED)\s+\d+\s*$') {
        throw "Unable to own the startup lock: $lockText"
    }
    $ownsStartupLock = $true

    & $stateHelper -Action WriteStartupState -LaunchRoot $LaunchRoot -State STARTING `
        -OwnerPid $PID -Version $Version -Message 'Installing or starting DeepSeek Harness' | Out-Null
    Add-Content -LiteralPath $log -Encoding UTF8 -Value "DSH version: $Version"
    Add-Content -LiteralPath $log -Encoding UTF8 -Value "Command: run-dsh.ps1 -Version $Version web -NoOpen"

    if (-not $SuppressBrowserMonitor) {
        $monitorArguments = @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass',
            '-File', "`"$monitorScript`"",
            '-TimeoutSeconds', [string]$TimeoutSeconds,
            '-ParentPid', [string]$PID,
            '-LaunchRoot', "`"$LaunchRoot`"",
            '-OwnerPid', [string]$PID,
            '-PollIntervalMilliseconds', '200'
        )
        Start-Process -FilePath $systemPowerShell -ArgumentList $monitorArguments `
            -WindowStyle Hidden -ErrorAction Stop | Out-Null
    }

    $runArguments = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', $runScript,
        '-Version', $Version,
        '-DshArguments', 'web',
        '-NoOpen'
    )
    $dshStarted = $true
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & $systemPowerShell @runArguments 2>&1 | ForEach-Object {
            Add-Content -LiteralPath $log -Encoding UTF8 -Value ([string]$_)
        }
        $dshExitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
} catch {
    $dshExitCode = 1
    Add-Content -LiteralPath $log -Encoding UTF8 -Value ("Runner failure: " + $_.Exception.Message)
    if ($ownsStartupLock -and -not $dshStarted) {
        & $stateHelper -Action WriteStartupState -LaunchRoot $LaunchRoot -State FAILED `
            -OwnerPid $PID -Version $Version -ExitCode $dshExitCode -Message $_.Exception.Message | Out-Null
    }
} finally {
    if ($dshStarted) {
        $exitOutput = @(& $stateHelper -Action RecordStartupExit -LaunchRoot $LaunchRoot -OwnerPid $PID `
            -Version $Version -ExitCode $dshExitCode -Message 'DSH exited before readiness' 2>&1)
        Add-RunnerLogLines -Lines $exitOutput
    }
    if ($ownsStartupLock) {
        $releaseOutput = @(& $stateHelper -Action ReleaseStartupLock -LaunchRoot $LaunchRoot `
            -OwnerPid $PID -StartupToken $StartupToken 2>&1)
        Add-RunnerLogLines -Lines $releaseOutput
    }
}

exit $dshExitCode
