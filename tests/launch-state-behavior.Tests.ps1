$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$stateHelper = Join-Path $repoRoot 'dsh-launch-state.ps1'
$testRoot = Join-Path $env:TEMP ('dsh-launcher-state-tests-' + [guid]::NewGuid().ToString('N'))
$script:Passed = 0

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)

    if ($Expected -ne $Actual) {
        throw "$Message (expected: $Expected, actual: $Actual)"
    }
}

function Assert-True {
    param([bool]$Condition, [string]$Message)

    if (-not $Condition) { throw $Message }
}

function Assert-Match {
    param([string]$Actual, [string]$Pattern, [string]$Message)

    if ($Actual -notmatch $Pattern) {
        throw "$Message`nActual output:`n$Actual"
    }
}

function Invoke-Test {
    param([string]$Name, [scriptblock]$Body)

    & $Body
    $script:Passed++
    Write-Host "PASS: $Name"
}

function Invoke-StateHelper {
    param([string[]]$Arguments)

    $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $stateHelper @Arguments 2>&1
    return [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output   = [string]($output -join [Environment]::NewLine)
    }
}

New-Item -ItemType Directory -Force -Path $testRoot | Out-Null
try {
    Invoke-Test 'reports STARTING while a live launcher owns the startup lock' {
        $launchRoot = Join-Path $testRoot 'starting'

        $lock = Invoke-StateHelper -Arguments @(
            '-Action', 'AcquireStartupLock', '-LaunchRoot', $launchRoot,
            '-OwnerPid', $PID, '-Version', '0.1.0-rc.8'
        )
        Assert-Equal 0 $lock.ExitCode "The live startup lock should be acquired. Output:`n$($lock.Output)"

        $write = Invoke-StateHelper -Arguments @(
            '-Action', 'WriteStartupState', '-LaunchRoot', $launchRoot,
            '-State', 'STARTING', '-OwnerPid', $PID, '-Version', '0.1.0-rc.8',
            '-Message', 'Installing or starting DeepSeek Harness'
        )
        Assert-Equal 0 $write.ExitCode "The STARTING state should be written. Output:`n$($write.Output)"

        $status = Invoke-StateHelper -Arguments @('-Action', 'GetStatus', '-LaunchRoot', $launchRoot)
        Assert-Equal 0 $status.ExitCode "Status lookup should succeed. Output:`n$($status.Output)"
        Assert-Match $status.Output 'STARTING' 'A live startup must not be reported as NOT RUNNING'
        Assert-Match $status.Output ([regex]::Escape([string]$PID)) 'STARTING status should identify its live owner'
    }

    Invoke-Test 'preserves a live startup lock and removes a stale startup lock' {
        $launchRoot = Join-Path $testRoot 'locks'

        $first = Invoke-StateHelper -Arguments @('-Action', 'AcquireStartupLock', '-LaunchRoot', $launchRoot, '-OwnerPid', $PID)
        Assert-Equal 0 $first.ExitCode "Initial lock acquisition should succeed. Output:`n$($first.Output)"

        $live = Invoke-StateHelper -Arguments @('-Action', 'TestStartupLock', '-LaunchRoot', $launchRoot)
        Assert-Equal 0 $live.ExitCode "Live lock inspection should succeed. Output:`n$($live.Output)"
        Assert-Match $live.Output 'LOCKED' 'A live lock must be retained'
        Assert-True (Test-Path -LiteralPath (Join-Path $launchRoot 'dsh-startup.lock')) 'A live lock directory must remain'

        $staleRoot = Join-Path $testRoot 'stale-lock'
        $staleLock = Join-Path $staleRoot 'dsh-startup.lock'
        New-Item -ItemType Directory -Force -Path $staleLock | Out-Null
        Set-Content -LiteralPath (Join-Path $staleLock 'pid.txt') -Value '999999' -Encoding ASCII

        $stale = Invoke-StateHelper -Arguments @('-Action', 'TestStartupLock', '-LaunchRoot', $staleRoot)
        Assert-Equal 0 $stale.ExitCode "Stale lock inspection should succeed. Output:`n$($stale.Output)"
        Assert-Match $stale.Output 'UNLOCKED' 'A stale lock must be released for a future launch'
        Assert-True (-not (Test-Path -LiteralPath $staleLock)) 'The stale lock directory must be removed'
    }

    Invoke-Test 'reports only NOT RUNNING when status removes a stale startup lock' {
        $launchRoot = Join-Path $testRoot 'stale-status'
        $staleLock = Join-Path $launchRoot 'dsh-startup.lock'
        New-Item -ItemType Directory -Force -Path $staleLock | Out-Null
        Set-Content -LiteralPath (Join-Path $staleLock 'pid.txt') -Value '999999' -Encoding ASCII

        $status = Invoke-StateHelper -Arguments @('-Action', 'GetStatus', '-LaunchRoot', $launchRoot)
        Assert-Equal 0 $status.ExitCode "Status lookup should succeed. Output:`n$($status.Output)"
        Assert-Equal 'NOT RUNNING' $status.Output 'Stale lock cleanup must not leak helper return values into status output'
        Assert-True (-not (Test-Path -LiteralPath $staleLock)) 'Status should remove the stale lock directory'
    }

    Invoke-Test 'allows the same startup token to transfer a live lock to the runner PID' {
        $launchRoot = Join-Path $testRoot 'token-transfer'
        $startupToken = '11111111111111111111111111111111'
        $otherToken = '22222222222222222222222222222222'
        $runner = Start-Process -FilePath 'powershell.exe' -ArgumentList @(
            '-NoProfile', '-Command', 'Start-Sleep -Seconds 30'
        ) -WindowStyle Hidden -PassThru

        try {
            $reserved = Invoke-StateHelper -Arguments @(
                '-Action', 'AcquireStartupLock', '-LaunchRoot', $launchRoot,
                '-OwnerPid', $PID, '-StartupToken', $startupToken
            )
            Assert-Equal 0 $reserved.ExitCode "The coordinator should reserve the lock. Output:`n$($reserved.Output)"

            $transferred = Invoke-StateHelper -Arguments @(
                '-Action', 'AcquireStartupLock', '-LaunchRoot', $launchRoot,
                '-OwnerPid', $runner.Id, '-StartupToken', $startupToken,
                '-TransferOwnership'
            )
            Assert-Equal 0 $transferred.ExitCode "The matching runner token should take over the lock. Output:`n$($transferred.Output)"
            $recordedPid = (Get-Content -LiteralPath (Join-Path $launchRoot 'dsh-startup.lock\pid.txt') -Raw).Trim()
            Assert-Equal ([string]$runner.Id) $recordedPid 'Token transfer must update the lock to the real runner PID'

            $coordinatorRetry = Invoke-StateHelper -Arguments @(
                '-Action', 'AcquireStartupLock', '-LaunchRoot', $launchRoot,
                '-OwnerPid', $PID, '-StartupToken', $startupToken
            )
            Assert-Equal 0 $coordinatorRetry.ExitCode "A matching coordinator retry should recognize the lock. Output:`n$($coordinatorRetry.Output)"
            $pidAfterRetry = (Get-Content -LiteralPath (Join-Path $launchRoot 'dsh-startup.lock\pid.txt') -Raw).Trim()
            Assert-Equal ([string]$runner.Id) $pidAfterRetry 'A coordinator retry must not overwrite the runner PID after ownership transfer'

            $contended = Invoke-StateHelper -Arguments @(
                '-Action', 'AcquireStartupLock', '-LaunchRoot', $launchRoot,
                '-OwnerPid', $PID, '-StartupToken', $otherToken
            )
            Assert-Equal 2 $contended.ExitCode "A different startup token must not take over a live lock. Output:`n$($contended.Output)"
            Assert-Match $contended.Output ([regex]::Escape("LOCKED $($runner.Id)")) 'Lock contention should identify the live runner PID'
        } finally {
            if ($runner -and -not $runner.HasExited) {
                Stop-Process -Id $runner.Id -Force -ErrorAction SilentlyContinue
                $runner.WaitForExit()
            }
        }
    }

    Invoke-Test 'reports FAILED with the launcher log location after early DSH exit' {
        $launchRoot = Join-Path $testRoot 'failed'

        $write = Invoke-StateHelper -Arguments @(
            '-Action', 'WriteStartupState', '-LaunchRoot', $launchRoot,
            '-State', 'FAILED', '-OwnerPid', 0, '-Version', '0.1.0-rc.8',
            '-ExitCode', 7, '-Message', 'DSH exited before readiness'
        )
        Assert-Equal 0 $write.ExitCode "The FAILED state should be written. Output:`n$($write.Output)"

        $status = Invoke-StateHelper -Arguments @('-Action', 'GetStatus', '-LaunchRoot', $launchRoot)
        Assert-Equal 0 $status.ExitCode "Status lookup should succeed. Output:`n$($status.Output)"
        Assert-Match $status.Output 'FAILED' 'Early DSH exit must remain visible in status output'
        Assert-Match $status.Output 'DSH exited before readiness' 'Status should include the recorded failure reason'
        Assert-Match $status.Output ([regex]::Escape((Join-Path $launchRoot 'dsh-background.log'))) 'Status should identify the background log'
    }

    Invoke-Test 'records an early runner exit as FAILED but preserves a completed RUNNING state' {
        $failedRoot = Join-Path $testRoot 'record-failed-exit'
        $starting = Invoke-StateHelper -Arguments @(
            '-Action', 'WriteStartupState', '-LaunchRoot', $failedRoot,
            '-State', 'STARTING', '-OwnerPid', $PID, '-Version', '0.1.0-rc.8'
        )
        Assert-Equal 0 $starting.ExitCode "The STARTING state should be written. Output:`n$($starting.Output)"

        $failed = Invoke-StateHelper -Arguments @(
            '-Action', 'RecordStartupExit', '-LaunchRoot', $failedRoot,
            '-ExitCode', 7, '-Message', 'DSH exited before readiness'
        )
        Assert-Equal 0 $failed.ExitCode "Early exit should be recorded. Output:`n$($failed.Output)"
        $failedState = Get-Content -LiteralPath (Join-Path $failedRoot 'dsh-startup.json') -Raw | ConvertFrom-Json
        Assert-Equal 'FAILED' $failedState.State 'An exit during STARTING must be recorded as FAILED'
        Assert-Equal 7 $failedState.ExitCode 'The early process exit code must be retained'

        $runningRoot = Join-Path $testRoot 'record-running-exit'
        $running = Invoke-StateHelper -Arguments @(
            '-Action', 'WriteStartupState', '-LaunchRoot', $runningRoot,
            '-State', 'RUNNING', '-OwnerPid', $PID, '-Version', '0.1.0-rc.8'
        )
        Assert-Equal 0 $running.ExitCode "The RUNNING state should be written. Output:`n$($running.Output)"

        $normalExit = Invoke-StateHelper -Arguments @(
            '-Action', 'RecordStartupExit', '-LaunchRoot', $runningRoot,
            '-ExitCode', 0, '-Message', 'DSH exited before readiness'
        )
        Assert-Equal 0 $normalExit.ExitCode "A completed run should be recorded without error. Output:`n$($normalExit.Output)"
        $runningState = Get-Content -LiteralPath (Join-Path $runningRoot 'dsh-startup.json') -Raw | ConvertFrom-Json
        Assert-Equal 'RUNNING' $runningState.State 'A process that had reached readiness must not be rewritten as a startup failure'
    }

    Write-Host "All $script:Passed launch state behavior tests passed."
} finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}

exit 0
