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

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $HelperPath @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    return [pscustomobject]@{
        ExitCode = $exitCode
        Output   = [string]($output -join [Environment]::NewLine)
    }
}

function Assert-NotMatch {
    param([string]$Actual, [string]$Pattern, [string]$Message)

    if ($Actual -match $Pattern) {
        throw "$Message`nActual output:`n$Actual"
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

function Start-StateHelperProcess {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$OutputPath,
        [Parameter(Mandatory = $true)][string]$ErrorPath
    )

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $powerShellPath
    $startInfo.Arguments = (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $stateHelper) + $Arguments) -join ' '
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $false
    $startInfo.RedirectStandardError = $false
    $process = Start-Process -FilePath $powerShellPath -ArgumentList $startInfo.Arguments `
        -WindowStyle Hidden -RedirectStandardOutput $OutputPath -RedirectStandardError $ErrorPath -PassThru
    return $process
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
function Test-DshCommandLineArgument {
    param([string]$CommandLine, [string]$ExpectedPath)

    return [string]$CommandLine -match [regex]::Escape([IO.Path]::GetFullPath($ExpectedPath))
}

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
            $identityPath = Join-Path $launchRoot 'dsh-startup.lock\identity.json'
            Assert-True (Test-Path -LiteralPath $identityPath) `
                'A transferred lock must publish one authoritative atomic identity record'
            $atomicIdentity = Get-Content -LiteralPath $identityPath -Raw | ConvertFrom-Json
            Assert-Equal $runner.Id $atomicIdentity.OwnerPid 'The atomic identity must name the runner owner'
            Assert-Equal $startupToken $atomicIdentity.Token 'The atomic identity must preserve the exact token'
            Assert-Equal ([IO.Path]::GetFullPath($powerShellPath)) $atomicIdentity.CommandPath `
                'The atomic identity must contain the normalized command path'
            Assert-Equal ([IO.Path]::GetFullPath($runnerScript)) $atomicIdentity.ScriptPath `
                'The atomic identity must contain the normalized runner script path'
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

    Invoke-Test 'atomic lock identity survives a mixed legacy transfer window' {
        $launchRoot = Join-Path $testRoot 'mixed-transfer-window'
        $startupToken = '31313131313131313131313131313131'
        $coordinatorScript = Join-Path $testRoot 'mixed-start-background.ps1'
        $runnerScript = Join-Path $testRoot 'mixed-background-run.ps1'
        $coordinator = Start-TestScriptProcess -ScriptPath $coordinatorScript
        $runner = Start-TestScriptProcess -ScriptPath $runnerScript
        try {
            $acquired = Invoke-StateHelper -Arguments @(
                '-Action', 'AcquireStartupLock', '-LaunchRoot', $launchRoot,
                '-OwnerPid', $coordinator.Id, '-StartupToken', $startupToken,
                '-CommandPath', $powerShellPath, '-ScriptPath', $coordinatorScript
            )
            Assert-Equal 0 $acquired.ExitCode "The coordinator lock should be created. Output:`n$($acquired.Output)"

            $lockRoot = Join-Path $launchRoot 'dsh-startup.lock'
            Set-Content -LiteralPath (Join-Path $lockRoot 'pid.txt') -Value $runner.Id -Encoding ASCII
            [IO.File]::WriteAllText(
                (Join-Path $lockRoot 'script-path.txt'),
                [IO.Path]::GetFullPath($coordinatorScript),
                [Text.UTF8Encoding]::new($false)
            )

            $observed = Invoke-StateHelper -Arguments @('-Action', 'TestStartupLock', '-LaunchRoot', $launchRoot)
            Assert-Equal 0 $observed.ExitCode "Mixed-window observation should succeed. Output:`n$($observed.Output)"
            Assert-Match $observed.Output "LOCKED $($coordinator.Id)" `
                'Readers must use the complete atomic identity rather than combining legacy files from two owners'
            Assert-True (Test-Path -LiteralPath $lockRoot) `
                'A mixed legacy transfer window must not cause the authoritative live lock to be removed'
        } finally {
            foreach ($process in @($coordinator, $runner)) {
                if ($process -and -not $process.HasExited) {
                    Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
                    $process.WaitForExit()
                }
            }
        }
    }

    Invoke-Test 'release waits for an in-flight transfer and cannot delete the new owner' {
        $launchRoot = Join-Path $testRoot 'release-transfer-serialization'
        $startupToken = '32323232323232323232323232323232'
        $coordinatorScript = Join-Path $testRoot 'serialized-start-background.ps1'
        $runnerScript = Join-Path $testRoot 'serialized-background-run.ps1'
        $coordinator = Start-TestScriptProcess -ScriptPath $coordinatorScript
        $runner = Start-TestScriptProcess -ScriptPath $runnerScript
        $guard = $null
        $release = $null
        try {
            $acquired = Invoke-StateHelper -Arguments @(
                '-Action', 'AcquireStartupLock', '-LaunchRoot', $launchRoot,
                '-OwnerPid', $coordinator.Id, '-StartupToken', $startupToken,
                '-CommandPath', $powerShellPath, '-ScriptPath', $coordinatorScript
            )
            Assert-Equal 0 $acquired.ExitCode "The coordinator lock should be created. Output:`n$($acquired.Output)"

            $guardPath = Join-Path $launchRoot 'dsh-startup.lock.guard'
            $guard = [IO.File]::Open(
                $guardPath,
                [IO.FileMode]::OpenOrCreate,
                [IO.FileAccess]::ReadWrite,
                [IO.FileShare]::None
            )
            $releaseOutput = Join-Path $testRoot 'serialized-release.out'
            $releaseError = Join-Path $testRoot 'serialized-release.err'
            $release = Start-StateHelperProcess -Arguments @(
                '-Action', 'ReleaseStartupLock', '-LaunchRoot', $launchRoot,
                '-OwnerPid', [string]$coordinator.Id, '-StartupToken', $startupToken
            ) -OutputPath $releaseOutput -ErrorPath $releaseError
            [Threading.Thread]::Sleep(1500)
            Assert-True (-not $release.HasExited) `
                'Release must wait on the same serialization guard as ownership transfer'

            $lockRoot = Join-Path $launchRoot 'dsh-startup.lock'
            $identityPath = Join-Path $lockRoot 'identity.json'
            $newIdentity = [ordered]@{
                SchemaVersion = 1
                OwnerPid = $runner.Id
                Token = $startupToken
                CommandPath = [IO.Path]::GetFullPath($powerShellPath)
                ScriptPath = [IO.Path]::GetFullPath($runnerScript)
                CreatedAt = [DateTime]::UtcNow.ToString('o')
            }
            $temporaryIdentity = Join-Path $lockRoot 'test-transfer.tmp'
            [IO.File]::WriteAllText(
                $temporaryIdentity,
                ($newIdentity | ConvertTo-Json -Depth 3),
                [Text.UTF8Encoding]::new($false)
            )
            Move-Item -LiteralPath $temporaryIdentity -Destination $identityPath -Force
            $guard.Dispose()
            $guard = $null

            Assert-True $release.WaitForExit(10000) 'The serialized release should finish after the guard is released'
            $release.Refresh()
            Assert-Equal 'UNCHANGED' ([IO.File]::ReadAllText($releaseOutput).Trim()) `
                'Release must re-read ownership after transfer and leave the new owner intact'
            Assert-True (Test-Path -LiteralPath $lockRoot) `
                'A release racing with ownership transfer must not delete the new owner lock'
            $finalIdentity = Get-Content -LiteralPath $identityPath -Raw | ConvertFrom-Json
            Assert-Equal $runner.Id $finalIdentity.OwnerPid 'The transferred runner must remain the unique owner'
        } finally {
            if ($guard) { $guard.Dispose() }
            if ($release -and -not $release.HasExited) {
                Stop-Process -Id $release.Id -Force -ErrorAction SilentlyContinue
                $release.WaitForExit()
            }
            foreach ($process in @($coordinator, $runner)) {
                if ($process -and -not $process.HasExited) {
                    Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
                    $process.WaitForExit()
                }
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
            '-StartupToken', $startupToken,
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
            '-Message', 'later status refresh', '-StartupToken', $startupToken
        )
        Assert-Equal 0 $laterStage.ExitCode "The later READY refresh should succeed. Output:`n$($laterStage.Output)"
        $refreshedState = Get-Content -LiteralPath (Join-Path $launchRoot 'dsh-startup.json') -Raw | ConvertFrom-Json
        Assert-Equal 4321 $refreshedState.ServicePid `
            'Once READY establishes the service PID, later stage refreshes must not replace it'
    }

    Invoke-Test 'token-bound state rejects mismatched or missing identity updates' {
        $launchRoot = Join-Path $testRoot 'state-token-authorization'
        $tokenA = '91919191919191919191919191919191'
        $tokenB = '92929292929292929292929292929292'
        $starting = Invoke-StateHelper -Arguments @(
            '-Action', 'WriteStartupState', '-LaunchRoot', $launchRoot,
            '-State', 'STARTING', '-OwnerPid', $PID, '-Version', '0.1.0-rc.8',
            '-StartupToken', $tokenA, '-RuntimeRoot', $runtimeRoot,
            '-Entrypoint', $entrypoint
        )
        Assert-Equal 0 $starting.ExitCode "The token-A state should be created. Output:`n$($starting.Output)"
        $statePath = Join-Path $launchRoot 'dsh-startup.json'
        $originalJson = [IO.File]::ReadAllText($statePath)

        foreach ($arguments in @(
            @('-Action', 'WriteStartupState', '-LaunchRoot', $launchRoot,
                '-State', 'READY', '-OwnerPid', $PID, '-ServicePid', 1001,
                '-StartupToken', $tokenB),
            @('-Action', 'WriteStartupState', '-LaunchRoot', $launchRoot,
                '-State', 'STARTING', '-OwnerPid', $PID, '-Message', 'STARTING_WEB'),
            @('-Action', 'RecordStartupExit', '-LaunchRoot', $launchRoot,
                '-OwnerPid', $PID, '-ExitCode', 7, '-StartupToken', $tokenB),
            @('-Action', 'RecordStartupExit', '-LaunchRoot', $launchRoot,
                '-OwnerPid', $PID, '-ExitCode', 7)
        )) {
            $rejected = Invoke-StateHelper -Arguments $arguments
            Assert-True ($rejected.ExitCode -ne 0) `
                "A token-bound state update with wrong or missing token must fail. Output:`n$($rejected.Output)"
            Assert-Equal $originalJson ([IO.File]::ReadAllText($statePath)) `
                'A rejected state update must leave the state file byte-for-byte unchanged'
        }

        $matched = Invoke-StateHelper -Arguments @(
            '-Action', 'WriteStartupState', '-LaunchRoot', $launchRoot,
            '-State', 'READY', '-OwnerPid', $PID, '-ServicePid', 1001,
            '-StartupToken', $tokenA
        )
        Assert-Equal 0 $matched.ExitCode "The matching startup identity should establish READY. Output:`n$($matched.Output)"
        $readyState = [IO.File]::ReadAllText($statePath) | ConvertFrom-Json
        Assert-Equal 'READY' $readyState.State 'The matching token should be allowed to advance the state'
        Assert-Equal 1001 $readyState.ServicePid 'Only the matching token may establish ServicePid'
    }

    Invoke-Test 'a live new lock may replace old state but the old token cannot fail the new startup' {
        $launchRoot = Join-Path $testRoot 'state-token-replacement'
        $tokenA = '93939393939393939393939393939393'
        $tokenB = '94949494949494949494949494949494'
        $coordinatorScript = Join-Path $testRoot 'replacement-start-background.ps1'
        $coordinator = Start-TestScriptProcess -ScriptPath $coordinatorScript
        try {
            $oldState = Invoke-StateHelper -Arguments @(
                '-Action', 'WriteStartupState', '-LaunchRoot', $launchRoot,
                '-State', 'STARTING', '-OwnerPid', 1234, '-Version', '0.1.0-rc.7',
                '-StartupToken', $tokenA, '-RuntimeRoot', (Join-Path $testRoot 'old-runtime'),
                '-Entrypoint', (Join-Path $testRoot 'old-entrypoint.js')
            )
            Assert-Equal 0 $oldState.ExitCode "The old token-A state should be created. Output:`n$($oldState.Output)"
            $newLock = Invoke-StateHelper -Arguments @(
                '-Action', 'AcquireStartupLock', '-LaunchRoot', $launchRoot,
                '-OwnerPid', $coordinator.Id, '-StartupToken', $tokenB,
                '-CommandPath', $powerShellPath, '-ScriptPath', $coordinatorScript
            )
            Assert-Equal 0 $newLock.ExitCode "The new token-B lock should be created. Output:`n$($newLock.Output)"

            $replacement = Invoke-StateHelper -Arguments @(
                '-Action', 'WriteStartupState', '-LaunchRoot', $launchRoot,
                '-State', 'STARTING', '-OwnerPid', $coordinator.Id, '-Version', '0.1.0-rc.8',
                '-StartupToken', $tokenB, '-RuntimeRoot', $runtimeRoot,
                '-Entrypoint', $entrypoint
            )
            Assert-Equal 0 $replacement.ExitCode `
                "A live matching new lock should replace stale state identity. Output:`n$($replacement.Output)"
            $newStateJson = [IO.File]::ReadAllText((Join-Path $launchRoot 'dsh-startup.json'))
            $newState = $newStateJson | ConvertFrom-Json
            Assert-Equal $tokenB $newState.StartupToken 'The replacement state must bind to token B'
            Assert-Equal $coordinator.Id $newState.RunnerPid 'The replacement state must bind to the new owner'

            $oldExit = Invoke-StateHelper -Arguments @(
                '-Action', 'RecordStartupExit', '-LaunchRoot', $launchRoot,
                '-OwnerPid', 1234, '-StartupToken', $tokenA, '-ExitCode', 7
            )
            Assert-True ($oldExit.ExitCode -ne 0) 'The old token must not fail the new STARTING state'
            Assert-Equal $newStateJson ([IO.File]::ReadAllText((Join-Path $launchRoot 'dsh-startup.json'))) `
                'The rejected old-runner exit must leave the new startup state unchanged'
        } finally {
            if ($coordinator -and -not $coordinator.HasExited) {
                Stop-Process -Id $coordinator.Id -Force -ErrorAction SilentlyContinue
                $coordinator.WaitForExit()
            }
        }
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

    Invoke-Test 'READY status requires a stored positive matching service PID' {
        $startupToken = '56565656565656565656565656565656'
        foreach ($case in @(
            [pscustomobject]@{ Name = 'missing'; StoredPid = $null; ClassifiedPid = 7001; ExpectedProbes = 0 },
            [pscustomobject]@{ Name = 'zero'; StoredPid = 0; ClassifiedPid = 7002; ExpectedProbes = 0 },
            [pscustomobject]@{ Name = 'mismatch'; StoredPid = 7003; ClassifiedPid = 7004; ExpectedProbes = 1 }
        )) {
            $launchRoot = Join-Path $testRoot ("ready-service-pid-" + $case.Name)
            $fixture = New-ClassifierFixture -Name ("service-pid-classifier-" + $case.Name) `
                -ClassificationState 'READY' -ServicePid $case.ClassifiedPid
            New-Item -ItemType Directory -Force -Path $launchRoot | Out-Null
            $state = [ordered]@{
                State = 'READY'
                Pid = $PID
                RunnerPid = $PID
                StartupToken = $startupToken
                RuntimeRoot = $runtimeRoot
                Entrypoint = $entrypoint
                Version = '0.1.0-rc.8'
            }
            if ($null -ne $case.StoredPid) { $state.ServicePid = $case.StoredPid }
            [IO.File]::WriteAllText(
                (Join-Path $launchRoot 'dsh-startup.json'),
                ($state | ConvertTo-Json -Depth 3),
                [Text.UTF8Encoding]::new($false)
            )

            $env:DSH_TEST_CLASSIFIER_TRACE = $fixture.TracePath
            $env:DSH_TEST_CLASSIFIER_STATE = $fixture.State
            $env:DSH_TEST_CLASSIFIER_PID = [string]$fixture.ServicePid
            $env:DSH_TEST_CLASSIFIER_ENTRYPOINT = $entrypoint
            try {
                $status = Invoke-StateHelper -HelperPath $fixture.HelperPath -Arguments @(
                    '-Action', 'GetStatus', '-LaunchRoot', $launchRoot, '-Port', 31993
                )
            } finally {
                Remove-Item Env:\DSH_TEST_CLASSIFIER_TRACE, Env:\DSH_TEST_CLASSIFIER_STATE, `
                    Env:\DSH_TEST_CLASSIFIER_PID, Env:\DSH_TEST_CLASSIFIER_ENTRYPOINT -ErrorAction SilentlyContinue
            }
            Assert-Equal 0 $status.ExitCode "READY evidence check should succeed. Output:`n$($status.Output)"
            Assert-Match $status.Output '^UNHEALTHY' `
                "READY with $($case.Name) ServicePid evidence must not be accepted"
            Assert-NotMatch $status.Output '^READY' `
                "READY with $($case.Name) ServicePid evidence must fail closed"
            $probeCount = if (Test-Path -LiteralPath $fixture.TracePath) {
                @(Get-Content -LiteralPath $fixture.TracePath).Count
            } else {
                0
            }
            Assert-Equal $case.ExpectedProbes $probeCount `
                "ServicePid case $($case.Name) must use the expected classifier probe count"
        }
    }

    Invoke-Test 'a new STARTING identity uses the stability wait before becoming READY' {
        $launchRoot = Join-Path $testRoot 'starting-status-state'
        $startupToken = '66666666666666666666666666666666'
        $servicePid = 6543
        $fixture = New-ClassifierFixture -Name 'starting-classifier' -ClassificationState 'READY' -ServicePid $servicePid
        $runnerScript = Join-Path $testRoot 'stable-background-run.ps1'
        $runner = Start-TestScriptProcess -ScriptPath $runnerScript
        try {
            $lock = Invoke-StateHelper -HelperPath $fixture.HelperPath -Arguments @(
                '-Action', 'AcquireStartupLock', '-LaunchRoot', $launchRoot,
                '-OwnerPid', $runner.Id, '-StartupToken', $startupToken,
                '-CommandPath', $powerShellPath, '-ScriptPath', $runnerScript
            )
            Assert-Equal 0 $lock.ExitCode "STARTING lock setup should succeed. Output:`n$($lock.Output)"
            $write = Invoke-StateHelper -HelperPath $fixture.HelperPath -Arguments @(
                '-Action', 'WriteStartupState', '-LaunchRoot', $launchRoot,
                '-State', 'STARTING', '-OwnerPid', $runner.Id,
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
            Assert-Match $trace[0] "^WAIT\|31992\|$([regex]::Escape($entrypoint))\|$startupToken\|$($runner.Id)\|[1-9][0-9]*$" `
                'A STARTING identity must use a positive stability window with stored evidence'
            $state = Get-Content -LiteralPath (Join-Path $launchRoot 'dsh-startup.json') -Raw | ConvertFrom-Json
            Assert-Equal 'READY' $state.State 'Stable STARTING identity must be persisted as READY'
            Assert-Equal $servicePid $state.ServicePid 'The stable service PID must be persisted'
        } finally {
            Remove-Item Env:\DSH_TEST_CLASSIFIER_TRACE, Env:\DSH_TEST_CLASSIFIER_STATE, `
                Env:\DSH_TEST_CLASSIFIER_PID, Env:\DSH_TEST_CLASSIFIER_ENTRYPOINT -ErrorAction SilentlyContinue
            if ($runner -and -not $runner.HasExited) {
                Stop-Process -Id $runner.Id -Force -ErrorAction SilentlyContinue
                $runner.WaitForExit()
            }
        }
    }

    Invoke-Test 'STARTING state must match the live lock token and runner before probing' {
        $launchRoot = Join-Path $testRoot 'starting-lock-mismatch'
        $stateToken = '68686868686868686868686868686868'
        $lockToken = '69696969696969696969696969696969'
        $fixture = New-ClassifierFixture -Name 'starting-lock-mismatch-classifier' `
            -ClassificationState 'READY' -ServicePid 6789
        $runnerScript = Join-Path $testRoot 'mismatch-background-run.ps1'
        $runner = Start-TestScriptProcess -ScriptPath $runnerScript
        try {
            $lock = Invoke-StateHelper -HelperPath $fixture.HelperPath -Arguments @(
                '-Action', 'AcquireStartupLock', '-LaunchRoot', $launchRoot,
                '-OwnerPid', $runner.Id, '-StartupToken', $lockToken,
                '-CommandPath', $powerShellPath, '-ScriptPath', $runnerScript
            )
            Assert-Equal 0 $lock.ExitCode "The live lock should be created. Output:`n$($lock.Output)"
            New-Item -ItemType Directory -Force -Path $launchRoot | Out-Null
            $staleState = [ordered]@{
                State = 'STARTING'
                Pid = $PID
                RunnerPid = $PID
                ServicePid = 0
                StartupToken = $stateToken
                RuntimeRoot = $runtimeRoot
                Entrypoint = $entrypoint
                Version = '0.1.0-rc.8'
            }
            [IO.File]::WriteAllText(
                (Join-Path $launchRoot 'dsh-startup.json'),
                ($staleState | ConvertTo-Json -Depth 3),
                [Text.UTF8Encoding]::new($false)
            )

            $env:DSH_TEST_CLASSIFIER_TRACE = $fixture.TracePath
            $env:DSH_TEST_CLASSIFIER_STATE = $fixture.State
            $env:DSH_TEST_CLASSIFIER_PID = [string]$fixture.ServicePid
            $env:DSH_TEST_CLASSIFIER_ENTRYPOINT = $entrypoint
            try {
                $status = Invoke-StateHelper -HelperPath $fixture.HelperPath -Arguments @(
                    '-Action', 'GetStatus', '-LaunchRoot', $launchRoot, '-Port', 31995
                )
            } finally {
                Remove-Item Env:\DSH_TEST_CLASSIFIER_TRACE, Env:\DSH_TEST_CLASSIFIER_STATE, `
                    Env:\DSH_TEST_CLASSIFIER_PID, Env:\DSH_TEST_CLASSIFIER_ENTRYPOINT -ErrorAction SilentlyContinue
            }
            Assert-Equal 0 $status.ExitCode "Mismatched STARTING status should succeed. Output:`n$($status.Output)"
            Assert-Match $status.Output "^STARTING - PID $($runner.Id)" `
                'Status may report the verified live lock, but not the stale state identity'
            Assert-True (-not (Test-Path -LiteralPath $fixture.TracePath)) `
                'A STARTING state whose token or runner differs from the live lock must not invoke the classifier'
        } finally {
            if ($runner -and -not $runner.HasExited) {
                Stop-Process -Id $runner.Id -Force -ErrorAction SilentlyContinue
                $runner.WaitForExit()
            }
        }
    }

    Invoke-Test 'STARTING without a live identity lock cannot survive PID reuse' {
        $launchRoot = Join-Path $testRoot 'starting-reused-pid'
        $startupToken = '67676767676767676767676767676767'
        $fixture = New-ClassifierFixture -Name 'starting-reused-pid-classifier' `
            -ClassificationState 'STOPPED' -ServicePid 0
        $intruder = Start-Process -FilePath $powerShellPath -ArgumentList @(
            '-NoProfile', '-Command', 'Start-Sleep -Seconds 30'
        ) -WindowStyle Hidden -PassThru
        try {
            $write = Invoke-StateHelper -HelperPath $fixture.HelperPath -Arguments @(
                '-Action', 'WriteStartupState', '-LaunchRoot', $launchRoot,
                '-State', 'STARTING', '-OwnerPid', $intruder.Id,
                '-StartupToken', $startupToken, '-RuntimeRoot', $runtimeRoot,
                '-Entrypoint', $entrypoint
            )
            Assert-Equal 0 $write.ExitCode "The stale STARTING fixture should be written. Output:`n$($write.Output)"

            $env:DSH_TEST_CLASSIFIER_TRACE = $fixture.TracePath
            $env:DSH_TEST_CLASSIFIER_STATE = $fixture.State
            $env:DSH_TEST_CLASSIFIER_PID = '0'
            $env:DSH_TEST_CLASSIFIER_ENTRYPOINT = $entrypoint
            try {
                $status = Invoke-StateHelper -HelperPath $fixture.HelperPath -Arguments @(
                    '-Action', 'GetStatus', '-LaunchRoot', $launchRoot, '-Port', 31994
                )
            } finally {
                Remove-Item Env:\DSH_TEST_CLASSIFIER_TRACE, Env:\DSH_TEST_CLASSIFIER_STATE, `
                    Env:\DSH_TEST_CLASSIFIER_PID, Env:\DSH_TEST_CLASSIFIER_ENTRYPOINT -ErrorAction SilentlyContinue
            }
            Assert-Equal 0 $status.ExitCode "Stale STARTING status should succeed. Output:`n$($status.Output)"
            Assert-Equal 'STOPPED' $status.Output `
                'Without a live identity-bound lock, a generic reused PID must not keep STARTING alive'
        } finally {
            if ($intruder -and -not $intruder.HasExited) {
                Stop-Process -Id $intruder.Id -Force -ErrorAction SilentlyContinue
                $intruder.WaitForExit()
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
            '-ExitCode', 7, '-Message', 'DSH exited before readiness',
            '-StartupToken', '77777777777777777777777777777777'
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
