$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$stateHelper = Join-Path $repoRoot 'dsh-launch-state.ps1'
$testRoot = Join-Path $env:TEMP ('dsh-launcher-state-tests-' + [guid]::NewGuid().ToString('N'))
$powerShellPath = (Get-Command powershell.exe -ErrorAction Stop).Source
$runtimeRoot = Join-Path $testRoot 'runtime'
$entrypoint = Join-Path $runtimeRoot 'node_modules\@deepseek-ai\dsh\lib\bin.js'
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
    param(
        [string[]]$Arguments,
        [string]$HelperPath = $stateHelper
    )

    $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $HelperPath @Arguments 2>&1
    return [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output   = [string]($output -join [Environment]::NewLine)
    }
}

function Start-TestScriptProcess {
    param([Parameter(Mandatory = $true)][string]$ScriptPath)

    [IO.File]::WriteAllText($ScriptPath, 'Start-Sleep -Seconds 30', [Text.Encoding]::ASCII)
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $powerShellPath
    $startInfo.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $ScriptPath + '"'
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    return [Diagnostics.Process]::Start($startInfo)
}

function New-ClassifierFixture {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$ClassificationState,
        [Parameter(Mandatory = $true)][int]$ServicePid
    )

    $fixtureRoot = Join-Path $testRoot $Name
    New-Item -ItemType Directory -Force -Path $fixtureRoot | Out-Null
    $helperPath = Join-Path $fixtureRoot 'dsh-launch-state.ps1'
    Copy-Item -LiteralPath $stateHelper -Destination $helperPath
    $tracePath = Join-Path $fixtureRoot 'classifier-trace.txt'
    $healthPath = Join-Path $fixtureRoot 'dsh-service-health.ps1'
    $healthScript = @'
function Write-TestClassifierTrace {
    param([string]$Kind, [int]$Port, [string]$Entrypoint, [string]$Token, [int]$RunnerPid, [int]$StableMilliseconds)

    $line = @($Kind, $Port, $Entrypoint, $Token, $RunnerPid, $StableMilliseconds) -join '|'
    Add-Content -LiteralPath $env:DSH_TEST_CLASSIFIER_TRACE -Value $line -Encoding UTF8
}

function New-TestClassification {
    return [pscustomobject]@{
        State = $env:DSH_TEST_CLASSIFIER_STATE
        ServicePid = [int]$env:DSH_TEST_CLASSIFIER_PID
        Message = 'fixture result'
        HttpStatus = 200
        Entrypoint = $env:DSH_TEST_CLASSIFIER_ENTRYPOINT
    }
}

function Get-DshServiceClassification {
    param([int]$Port, [string]$ExpectedEntrypoint, [string]$ExpectedStartupToken, [int]$RunnerPid)

    Write-TestClassifierTrace -Kind 'CLASSIFY' -Port $Port -Entrypoint $ExpectedEntrypoint `
        -Token $ExpectedStartupToken -RunnerPid $RunnerPid -StableMilliseconds 0
    return New-TestClassification
}

function Wait-DshServiceIdentity {
    param(
        [int]$Port,
        [string]$ExpectedEntrypoint,
        [string]$ExpectedStartupToken,
        [int]$RunnerPid,
        [int]$StableMilliseconds,
        [int]$PollMilliseconds
    )

    Write-TestClassifierTrace -Kind 'WAIT' -Port $Port -Entrypoint $ExpectedEntrypoint `
        -Token $ExpectedStartupToken -RunnerPid $RunnerPid -StableMilliseconds $StableMilliseconds
    return New-TestClassification
}
'@
    [IO.File]::WriteAllText($healthPath, $healthScript, [Text.UTF8Encoding]::new($false))
    return [pscustomobject]@{
        HelperPath = $helperPath
        TracePath = $tracePath
        State = $ClassificationState
        ServicePid = $ServicePid
    }
}

New-Item -ItemType Directory -Force -Path $testRoot | Out-Null
try {
    Invoke-Test 'reports STARTING while a live launcher owns the startup lock' {
        $launchRoot = Join-Path $testRoot 'starting'
        $startupToken = '11111111111111111111111111111111'
        $coordinatorScript = Join-Path $testRoot 'starting-start-background.ps1'
        $coordinator = Start-TestScriptProcess -ScriptPath $coordinatorScript

        try {
            $lock = Invoke-StateHelper -Arguments @(
                '-Action', 'AcquireStartupLock', '-LaunchRoot', $launchRoot,
                '-OwnerPid', $coordinator.Id, '-StartupToken', $startupToken,
                '-CommandPath', $powerShellPath, '-ScriptPath', $coordinatorScript
            )
            Assert-Equal 0 $lock.ExitCode "The live startup lock should be acquired. Output:`n$($lock.Output)"

            $write = Invoke-StateHelper -Arguments @(
                '-Action', 'WriteStartupState', '-LaunchRoot', $launchRoot,
                '-State', 'STARTING', '-OwnerPid', $coordinator.Id, '-Version', '0.1.0-rc.8',
                '-Message', 'Installing or starting DeepSeek Harness',
                '-StartupToken', $startupToken, '-RuntimeRoot', $runtimeRoot,
                '-Entrypoint', $entrypoint
            )
            Assert-Equal 0 $write.ExitCode "The STARTING state should be written. Output:`n$($write.Output)"

            $status = Invoke-StateHelper -Arguments @('-Action', 'GetStatus', '-LaunchRoot', $launchRoot, '-Port', 31990)
            Assert-Equal 0 $status.ExitCode "Status lookup should succeed. Output:`n$($status.Output)"
            Assert-Match $status.Output 'STARTING' 'A live startup must not be reported as NOT RUNNING'
            Assert-Match $status.Output ([regex]::Escape([string]$coordinator.Id)) 'STARTING status should identify its live owner'
        } finally {
            if ($coordinator -and -not $coordinator.HasExited) {
                Stop-Process -Id $coordinator.Id -Force -ErrorAction SilentlyContinue
                $coordinator.WaitForExit()
            }
        }
    }

    Invoke-Test 'preserves a live startup lock and removes a stale startup lock' {
        $launchRoot = Join-Path $testRoot 'locks'
        $startupToken = '22222222222222222222222222222222'
        $coordinatorScript = Join-Path $testRoot 'locks-start-background.ps1'
        $coordinator = Start-TestScriptProcess -ScriptPath $coordinatorScript

        try {
            $first = Invoke-StateHelper -Arguments @(
                '-Action', 'AcquireStartupLock', '-LaunchRoot', $launchRoot,
                '-OwnerPid', $coordinator.Id, '-StartupToken', $startupToken,
                '-CommandPath', $powerShellPath, '-ScriptPath', $coordinatorScript
            )
            Assert-Equal 0 $first.ExitCode "Initial lock acquisition should succeed. Output:`n$($first.Output)"

            $live = Invoke-StateHelper -Arguments @('-Action', 'TestStartupLock', '-LaunchRoot', $launchRoot)
            Assert-Equal 0 $live.ExitCode "Live lock inspection should succeed. Output:`n$($live.Output)"
            Assert-Match $live.Output 'LOCKED' 'A live lock must be retained'
            Assert-True (Test-Path -LiteralPath (Join-Path $launchRoot 'dsh-startup.lock')) 'A live lock directory must remain'
        } finally {
            if ($coordinator -and -not $coordinator.HasExited) {
                Stop-Process -Id $coordinator.Id -Force -ErrorAction SilentlyContinue
                $coordinator.WaitForExit()
            }
        }

        $staleRoot = Join-Path $testRoot 'stale-lock'
        $staleLock = Join-Path $staleRoot 'dsh-startup.lock'
        New-Item -ItemType Directory -Force -Path $staleLock | Out-Null
        Set-Content -LiteralPath (Join-Path $staleLock 'pid.txt') -Value '999999' -Encoding ASCII

        $stale = Invoke-StateHelper -Arguments @('-Action', 'TestStartupLock', '-LaunchRoot', $staleRoot)
        Assert-Equal 0 $stale.ExitCode "Stale lock inspection should succeed. Output:`n$($stale.Output)"
        Assert-Match $stale.Output 'UNLOCKED' 'A stale lock must be released for a future launch'
        Assert-True (-not (Test-Path -LiteralPath $staleLock)) 'The stale lock directory must be removed'
    }

    Invoke-Test 'a generic PowerShell PID cannot keep a background runner lock alive' {
        $launchRoot = Join-Path $testRoot 'reused-pid'
        $staleLock = Join-Path $launchRoot 'dsh-startup.lock'
        New-Item -ItemType Directory -Force -Path $staleLock | Out-Null
        $runnerScript = Join-Path $testRoot 'background-run.ps1'
        [IO.File]::WriteAllText($runnerScript, 'Start-Sleep -Seconds 30', [Text.Encoding]::ASCII)
        $intruder = Start-Process -FilePath $powerShellPath -ArgumentList @(
            '-NoProfile', '-Command', 'Start-Sleep -Seconds 30'
        ) -WindowStyle Hidden -PassThru
        try {
            Set-Content -LiteralPath (Join-Path $staleLock 'pid.txt') -Value ([string]$intruder.Id) -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $staleLock 'token.txt') -Value '33333333333333333333333333333333' -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $staleLock 'command-path.txt') -Value $powerShellPath -Encoding UTF8
            Set-Content -LiteralPath (Join-Path $staleLock 'script-path.txt') -Value $runnerScript -Encoding UTF8
            Set-Content -LiteralPath (Join-Path $staleLock 'created-at.txt') -Value ([DateTime]::UtcNow.ToString('o')) -Encoding ASCII

            $stale = Invoke-StateHelper -Arguments @('-Action', 'TestStartupLock', '-LaunchRoot', $launchRoot)
            Assert-Equal 0 $stale.ExitCode "Reused-PID inspection should succeed. Output:`n$($stale.Output)"
            Assert-Match $stale.Output 'UNLOCKED' 'A generic PowerShell process without the recorded runner script must not keep the lock live'
            Assert-True (-not (Test-Path -LiteralPath $staleLock)) 'The reused-PID lock directory must be removed'
        } finally {
            if ($intruder -and -not $intruder.HasExited) {
                Stop-Process -Id $intruder.Id -Force -ErrorAction SilentlyContinue
                $intruder.WaitForExit()
            }
        }
    }

    Invoke-Test 'reports STOPPED when status removes a stale startup lock' {
        $launchRoot = Join-Path $testRoot 'stale-status'
        $staleLock = Join-Path $launchRoot 'dsh-startup.lock'
        New-Item -ItemType Directory -Force -Path $staleLock | Out-Null
        Set-Content -LiteralPath (Join-Path $staleLock 'pid.txt') -Value '999999' -Encoding ASCII

        $status = Invoke-StateHelper -Arguments @('-Action', 'GetStatus', '-LaunchRoot', $launchRoot, '-Port', 31990)
        Assert-Equal 0 $status.ExitCode "Status lookup should succeed. Output:`n$($status.Output)"
        Assert-Equal 'STOPPED' $status.Output 'Stale lock cleanup must not leak helper return values into status output'
        Assert-True (-not (Test-Path -LiteralPath $staleLock)) 'Status should remove the stale lock directory'
    }

    Invoke-Test 'allows the same startup token to transfer a live lock to the runner PID' {
        $launchRoot = Join-Path $testRoot 'token-transfer'
        $startupToken = '11111111111111111111111111111111'
        $otherToken = '22222222222222222222222222222222'
        $coordinatorScript = Join-Path $testRoot 'transfer-start-background.ps1'
        $coordinator = Start-TestScriptProcess -ScriptPath $coordinatorScript
        $runnerScript = Join-Path $testRoot 'transfer-background-run.ps1'
        $runner = Start-TestScriptProcess -ScriptPath $runnerScript

        try {
            $reserved = Invoke-StateHelper -Arguments @(
                '-Action', 'AcquireStartupLock', '-LaunchRoot', $launchRoot,
                '-OwnerPid', $coordinator.Id, '-StartupToken', $startupToken,
                '-CommandPath', $powerShellPath, '-ScriptPath', $coordinatorScript
            )
            Assert-Equal 0 $reserved.ExitCode "The coordinator should reserve the lock. Output:`n$($reserved.Output)"

            $transferred = Invoke-StateHelper -Arguments @(
                '-Action', 'AcquireStartupLock', '-LaunchRoot', $launchRoot,
                '-OwnerPid', $runner.Id, '-StartupToken', $startupToken,
                '-CommandPath', $powerShellPath, '-ScriptPath', $runnerScript,
                '-TransferOwnership'
            )
            Assert-Equal 0 $transferred.ExitCode "The matching runner token should take over the lock. Output:`n$($transferred.Output)"
            $recordedPid = (Get-Content -LiteralPath (Join-Path $launchRoot 'dsh-startup.lock\pid.txt') -Raw).Trim()
            Assert-Equal ([string]$runner.Id) $recordedPid 'Token transfer must update the lock to the real runner PID'
            Assert-Equal ([IO.Path]::GetFullPath($powerShellPath)) `
                ((Get-Content -LiteralPath (Join-Path $launchRoot 'dsh-startup.lock\command-path.txt') -Raw).Trim()) `
                'Token transfer must persist the normalized runner command path'
            Assert-Equal ([IO.Path]::GetFullPath($runnerScript)) `
                ((Get-Content -LiteralPath (Join-Path $launchRoot 'dsh-startup.lock\script-path.txt') -Raw).Trim()) `
                'Token transfer must persist the normalized runner script path'
            Assert-True (Test-Path -LiteralPath (Join-Path $launchRoot 'dsh-startup.lock\created-at.txt')) `
                'The lock must persist its creation timestamp'

            $coordinatorRetry = Invoke-StateHelper -Arguments @(
                '-Action', 'AcquireStartupLock', '-LaunchRoot', $launchRoot,
                '-OwnerPid', $coordinator.Id, '-StartupToken', $startupToken,
                '-CommandPath', $powerShellPath, '-ScriptPath', $coordinatorScript
            )
            Assert-Equal 0 $coordinatorRetry.ExitCode "A matching coordinator retry should recognize the lock. Output:`n$($coordinatorRetry.Output)"
            $pidAfterRetry = (Get-Content -LiteralPath (Join-Path $launchRoot 'dsh-startup.lock\pid.txt') -Raw).Trim()
            Assert-Equal ([string]$runner.Id) $pidAfterRetry 'A coordinator retry must not overwrite the runner PID after ownership transfer'

            $contended = Invoke-StateHelper -Arguments @(
                '-Action', 'AcquireStartupLock', '-LaunchRoot', $launchRoot,
                '-OwnerPid', $coordinator.Id, '-StartupToken', $otherToken,
                '-CommandPath', $powerShellPath, '-ScriptPath', $coordinatorScript,
                '-TransferOwnership'
            )
            Assert-Equal 2 $contended.ExitCode "A different startup token must not take over a live lock. Output:`n$($contended.Output)"
            Assert-Match $contended.Output ([regex]::Escape("LOCKED $($runner.Id)")) 'Lock contention should identify the live runner PID'

            $wrongRelease = Invoke-StateHelper -Arguments @(
                '-Action', 'ReleaseStartupLock', '-LaunchRoot', $launchRoot,
                '-OwnerPid', $runner.Id, '-StartupToken', $otherToken,
                '-CommandPath', $powerShellPath, '-ScriptPath', $runnerScript
            )
            Assert-Equal 'UNCHANGED' $wrongRelease.Output 'A mismatched startup token must not release the runner lock'
            Assert-True (Test-Path -LiteralPath (Join-Path $launchRoot 'dsh-startup.lock')) `
                'A mismatched release must leave the lock intact'

            $missingTokenRelease = Invoke-StateHelper -Arguments @(
                '-Action', 'ReleaseStartupLock', '-LaunchRoot', $launchRoot,
                '-OwnerPid', $runner.Id,
                '-CommandPath', $powerShellPath, '-ScriptPath', $runnerScript
            )
            Assert-Equal 'UNCHANGED' $missingTokenRelease.Output `
                'A token-bound startup lock must not be released without its exact token'
            Assert-True (Test-Path -LiteralPath (Join-Path $launchRoot 'dsh-startup.lock')) `
                'A release without the recorded token must leave the lock intact'
        } finally {
            if ($coordinator -and -not $coordinator.HasExited) {
                Stop-Process -Id $coordinator.Id -Force -ErrorAction SilentlyContinue
                $coordinator.WaitForExit()
            }
            if ($runner -and -not $runner.HasExited) {
                Stop-Process -Id $runner.Id -Force -ErrorAction SilentlyContinue
                $runner.WaitForExit()
            }
        }
    }

    Invoke-Test 'READY state records immutable launch identity and never writes RUNNING' {
        $launchRoot = Join-Path $testRoot 'ready-state'
        $startupToken = '44444444444444444444444444444444'
        $starting = Invoke-StateHelper -Arguments @(
            '-Action', 'WriteStartupState', '-LaunchRoot', $launchRoot,
            '-State', 'STARTING', '-OwnerPid', $PID, '-Version', '0.1.0-rc.8',
            '-StartupToken', $startupToken, '-RuntimeRoot', $runtimeRoot,
            '-Entrypoint', $entrypoint
        )
        Assert-Equal 0 $starting.ExitCode "The STARTING identity should be written. Output:`n$($starting.Output)"

        $ready = Invoke-StateHelper -Arguments @(
            '-Action', 'WriteStartupState', '-LaunchRoot', $launchRoot,
            '-State', 'RUNNING', '-OwnerPid', 9999, '-ServicePid', 4321,
            '-Version', '9.9.9',
            '-StartupToken', 'ffffffffffffffffffffffffffffffff',
            '-RuntimeRoot', (Join-Path $testRoot 'wrong-runtime'),
            '-Entrypoint', (Join-Path $testRoot 'wrong-entrypoint.js')
        )
        Assert-Equal 0 $ready.ExitCode "The legacy RUNNING write should be normalized. Output:`n$($ready.Output)"
        $state = Get-Content -LiteralPath (Join-Path $launchRoot 'dsh-startup.json') -Raw | ConvertFrom-Json
        Assert-Equal 'READY' $state.State 'New state files must use READY rather than RUNNING'
        Assert-Equal $startupToken $state.StartupToken 'Stage updates must preserve the initial startup token'
        Assert-Equal $PID $state.RunnerPid 'Stage updates must preserve the initial runner PID'
        Assert-Equal 4321 $state.ServicePid 'READY must record the service PID'
        Assert-Equal $runtimeRoot $state.RuntimeRoot 'Stage updates must preserve the initial runtime root'
        Assert-Equal $entrypoint $state.Entrypoint 'Stage updates must preserve the exact initial entrypoint'
        Assert-Equal '0.1.0-rc.8' $state.Version 'Stage updates must preserve the initial selected version'

        $laterStage = Invoke-StateHelper -Arguments @(
            '-Action', 'WriteStartupState', '-LaunchRoot', $launchRoot,
            '-State', 'READY', '-OwnerPid', 1111, '-ServicePid', 9999,
            '-Message', 'later status refresh'
        )
        Assert-Equal 0 $laterStage.ExitCode "The later READY refresh should succeed. Output:`n$($laterStage.Output)"
        $refreshedState = Get-Content -LiteralPath (Join-Path $launchRoot 'dsh-startup.json') -Raw | ConvertFrom-Json
        Assert-Equal 4321 $refreshedState.ServicePid `
            'Once READY establishes the service PID, later stage refreshes must not replace it'
    }

    Invoke-Test 'legacy RUNNING state is read as READY without rewriting the state file' {
        $launchRoot = Join-Path $testRoot 'legacy-running'
        New-Item -ItemType Directory -Force -Path $launchRoot | Out-Null
        $legacyPath = Join-Path $launchRoot 'dsh-startup.json'
        [IO.File]::WriteAllText(
            $legacyPath,
            '{"State":"RUNNING","Pid":1234,"Version":"0.1.0-rc.8"}',
            [Text.UTF8Encoding]::new($false)
        )

        $read = Invoke-StateHelper -Arguments @('-Action', 'GetStartupState', '-LaunchRoot', $launchRoot)
        Assert-Equal 0 $read.ExitCode "Legacy state lookup should succeed. Output:`n$($read.Output)"
        Assert-Equal 'READY' (($read.Output | ConvertFrom-Json).State) 'Legacy RUNNING must be exposed as READY'
        Assert-Match ([IO.File]::ReadAllText($legacyPath)) '"State":"RUNNING"' `
            'Compatibility reads must not rewrite the legacy state file'
    }

    Invoke-Test 'READY status probes the stored identity exactly once' {
        $launchRoot = Join-Path $testRoot 'ready-status-state'
        $startupToken = '55555555555555555555555555555555'
        $servicePid = 5432
        $fixture = New-ClassifierFixture -Name 'ready-classifier' -ClassificationState 'READY' -ServicePid $servicePid
        $write = Invoke-StateHelper -HelperPath $fixture.HelperPath -Arguments @(
            '-Action', 'WriteStartupState', '-LaunchRoot', $launchRoot,
            '-State', 'READY', '-OwnerPid', $PID, '-ServicePid', $servicePid,
            '-StartupToken', $startupToken, '-RuntimeRoot', $runtimeRoot,
            '-Entrypoint', $entrypoint
        )
        Assert-Equal 0 $write.ExitCode "READY state setup should succeed. Output:`n$($write.Output)"

        $env:DSH_TEST_CLASSIFIER_TRACE = $fixture.TracePath
        $env:DSH_TEST_CLASSIFIER_STATE = $fixture.State
        $env:DSH_TEST_CLASSIFIER_PID = [string]$fixture.ServicePid
        $env:DSH_TEST_CLASSIFIER_ENTRYPOINT = $entrypoint
        try {
            $status = Invoke-StateHelper -HelperPath $fixture.HelperPath -Arguments @(
                '-Action', 'GetStatus', '-LaunchRoot', $launchRoot, '-Port', 31991
            )
        } finally {
            Remove-Item Env:\DSH_TEST_CLASSIFIER_TRACE, Env:\DSH_TEST_CLASSIFIER_STATE, `
                Env:\DSH_TEST_CLASSIFIER_PID, Env:\DSH_TEST_CLASSIFIER_ENTRYPOINT -ErrorAction SilentlyContinue
        }
        Assert-Equal 0 $status.ExitCode "READY status should succeed. Output:`n$($status.Output)"
        Assert-Match $status.Output "READY - PID $servicePid" 'The matching stored service identity must remain READY'
        $trace = @(Get-Content -LiteralPath $fixture.TracePath)
        Assert-Equal 1 $trace.Count 'An already READY matching identity must use one classifier probe'
        Assert-Equal "CLASSIFY|31991|$entrypoint|$startupToken|$PID|0" $trace[0] `
            'GetStatus must pass the stored entrypoint, token, and runner PID to the shared classifier'
    }

    Invoke-Test 'a new STARTING identity uses the stability wait before becoming READY' {
        $launchRoot = Join-Path $testRoot 'starting-status-state'
        $startupToken = '66666666666666666666666666666666'
        $servicePid = 6543
        $fixture = New-ClassifierFixture -Name 'starting-classifier' -ClassificationState 'READY' -ServicePid $servicePid
        $write = Invoke-StateHelper -HelperPath $fixture.HelperPath -Arguments @(
            '-Action', 'WriteStartupState', '-LaunchRoot', $launchRoot,
            '-State', 'STARTING', '-OwnerPid', $PID,
            '-StartupToken', $startupToken, '-RuntimeRoot', $runtimeRoot,
            '-Entrypoint', $entrypoint
        )
        Assert-Equal 0 $write.ExitCode "STARTING state setup should succeed. Output:`n$($write.Output)"

        $env:DSH_TEST_CLASSIFIER_TRACE = $fixture.TracePath
        $env:DSH_TEST_CLASSIFIER_STATE = $fixture.State
        $env:DSH_TEST_CLASSIFIER_PID = [string]$fixture.ServicePid
        $env:DSH_TEST_CLASSIFIER_ENTRYPOINT = $entrypoint
        try {
            $status = Invoke-StateHelper -HelperPath $fixture.HelperPath -Arguments @(
                '-Action', 'GetStatus', '-LaunchRoot', $launchRoot, '-Port', 31992
            )
        } finally {
            Remove-Item Env:\DSH_TEST_CLASSIFIER_TRACE, Env:\DSH_TEST_CLASSIFIER_STATE, `
                Env:\DSH_TEST_CLASSIFIER_PID, Env:\DSH_TEST_CLASSIFIER_ENTRYPOINT -ErrorAction SilentlyContinue
        }
        Assert-Equal 0 $status.ExitCode "STARTING status should succeed. Output:`n$($status.Output)"
        Assert-Match $status.Output "READY - PID $servicePid" 'A stable new identity may advance to READY'
        $trace = @(Get-Content -LiteralPath $fixture.TracePath)
        Assert-Equal 1 $trace.Count 'A STARTING identity should delegate stability to one wait operation'
        Assert-Match $trace[0] "^WAIT\|31992\|$([regex]::Escape($entrypoint))\|$startupToken\|$PID\|[1-9][0-9]*$" `
            'A STARTING identity must use a positive stability window with stored evidence'
        $state = Get-Content -LiteralPath (Join-Path $launchRoot 'dsh-startup.json') -Raw | ConvertFrom-Json
        Assert-Equal 'READY' $state.State 'Stable STARTING identity must be persisted as READY'
        Assert-Equal $servicePid $state.ServicePid 'The stable service PID must be persisted'
    }

    Invoke-Test 'reports FAILED with the launcher log location after early DSH exit' {
        $launchRoot = Join-Path $testRoot 'failed'

        $write = Invoke-StateHelper -Arguments @(
            '-Action', 'WriteStartupState', '-LaunchRoot', $launchRoot,
            '-State', 'FAILED', '-OwnerPid', 0, '-Version', '0.1.0-rc.8',
            '-ExitCode', 7, '-Message', 'DSH exited before readiness'
        )
        Assert-Equal 0 $write.ExitCode "The FAILED state should be written. Output:`n$($write.Output)"

        $status = Invoke-StateHelper -Arguments @('-Action', 'GetStatus', '-LaunchRoot', $launchRoot, '-Port', 31990)
        Assert-Equal 0 $status.ExitCode "Status lookup should succeed. Output:`n$($status.Output)"
        Assert-Match $status.Output 'FAILED' 'Early DSH exit must remain visible in status output'
        Assert-Match $status.Output 'DSH exited before readiness' 'Status should include the recorded failure reason'
        Assert-Match $status.Output ([regex]::Escape((Join-Path $launchRoot 'dsh-background.log'))) 'Status should identify the background log'
    }

    Invoke-Test 'records an early runner exit as FAILED but preserves a completed READY state' {
        $failedRoot = Join-Path $testRoot 'record-failed-exit'
        $starting = Invoke-StateHelper -Arguments @(
            '-Action', 'WriteStartupState', '-LaunchRoot', $failedRoot,
            '-State', 'STARTING', '-OwnerPid', $PID, '-Version', '0.1.0-rc.8',
            '-StartupToken', '77777777777777777777777777777777',
            '-RuntimeRoot', $runtimeRoot, '-Entrypoint', $entrypoint
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

        $readyRoot = Join-Path $testRoot 'record-ready-exit'
        $ready = Invoke-StateHelper -Arguments @(
            '-Action', 'WriteStartupState', '-LaunchRoot', $readyRoot,
            '-State', 'READY', '-OwnerPid', $PID, '-ServicePid', 7654,
            '-Version', '0.1.0-rc.8', '-StartupToken', '88888888888888888888888888888888',
            '-RuntimeRoot', $runtimeRoot, '-Entrypoint', $entrypoint
        )
        Assert-Equal 0 $ready.ExitCode "The READY state should be written. Output:`n$($ready.Output)"

        $normalExit = Invoke-StateHelper -Arguments @(
            '-Action', 'RecordStartupExit', '-LaunchRoot', $readyRoot,
            '-ExitCode', 0, '-Message', 'DSH exited before readiness'
        )
        Assert-Equal 0 $normalExit.ExitCode "A completed run should be recorded without error. Output:`n$($normalExit.Output)"
        $readyState = Get-Content -LiteralPath (Join-Path $readyRoot 'dsh-startup.json') -Raw | ConvertFrom-Json
        Assert-Equal 'READY' $readyState.State 'A process that had reached readiness must not be rewritten as a startup failure'
    }

    Write-Host "All $script:Passed launch state behavior tests passed."
} finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}

exit 0
