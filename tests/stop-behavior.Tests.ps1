$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$stopScript = Join-Path $repoRoot 'stop-dsh.ps1'
$testRoot = Join-Path $env:TEMP ('dsh-stop-tests-' + [guid]::NewGuid().ToString('N'))
$profileRoot = Join-Path $testRoot 'profile'
$launchRoot = Join-Path $profileRoot 'dsh-launch'
$fakeScriptRoot = Join-Path $testRoot 'fakes'
$killLog = Join-Path $testRoot 'taskkill.log'
$script:Passed = 0

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    if ($Expected -ne $Actual) { throw "$Message (expected: $Expected, actual: $Actual)" }
}

function Assert-Match {
    param([string]$Actual, [string]$Pattern, [string]$Message)
    if ($Actual -notmatch $Pattern) { throw "$Message`nActual:`n$Actual" }
}

function Assert-NotMatch {
    param([string]$Actual, [string]$Pattern, [string]$Message)
    if ($Actual -match $Pattern) { throw "$Message`nActual:`n$Actual" }
}

function Invoke-Test {
    param([string]$Name, [scriptblock]$Body)
    & $Body
    $script:Passed++
    Write-Host "PASS: $Name"
}

# The harness runs stop-dsh.ps1 in a child Windows PowerShell with every external
# effect replaced by scenario-controlled fakes: TCP listeners, Win32_Process data,
# and taskkill.exe. The startup lock is written in the current identity schema so
# the lock branch has to pass the same ownership validation as production code.
$harness = @'
$ErrorActionPreference = 'Stop'
$env:USERPROFILE = $env:DSH_STOP_TEST_PROFILE
$scenario = $env:DSH_STOP_TEST_SCENARIO
$port = [int]$env:DSH_STOP_TEST_PORT
$ownerPid = [int]$env:DSH_STOP_OWNER_PID
$servicePid = [int]$env:DSH_STOP_SERVICE_PID
$foreignPid = 40000 + ($ownerPid % 10000)
$exePath = (Get-Process -Id $PID).Path
$fakeScriptPath = Join-Path $env:DSH_STOP_TEST_FAKES 'background-run.ps1'
$script:distinctServiceKillObserved = $false
$script:runnerRaceProbeCount = 0
$script:cimUnavailable = $false

function global:Get-NetTCPConnection {
    param([int]$LocalPort, [string]$State)
    if ($env:DSH_STOP_HAS_LISTENER -ne '1') { return $null }
    return @([pscustomobject]@{
        LocalAddress  = '127.0.0.1'
        LocalPort     = $LocalPort
        State         = $State
        OwningProcess = $(if ($scenario -eq 'foreign') { $foreignPid } elseif ($scenario -eq 'runner-service-distinct') { $servicePid } else { $ownerPid })
    })
}

function global:Get-CimInstance {
    param([string]$ClassName, [string]$Filter)
    if ($Filter -notmatch 'ProcessId=(\d+)') { return $null }
    $queriedPid = [int]$Matches[1]
    if ($script:cimUnavailable) {
        throw 'Injected CIM query failure'
    }
    if ($scenario -eq 'runner-service-distinct' -and
            $script:distinctServiceKillObserved -and $queriedPid -eq $ownerPid) {
        $script:runnerRaceProbeCount++
        if ($script:runnerRaceProbeCount -ge 4) {
            # Let the runner disappear shortly after taskkill reports its
            # race failure, matching the normal cleanup path after Node exits.
            $env:DSH_STOP_PROCESS_GONE = '1'
            Remove-Item -LiteralPath (Join-Path $env:USERPROFILE 'dsh-launch\dsh-startup.lock') -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    if ($env:DSH_STOP_PROCESS_GONE -eq '1' -and $queriedPid -eq $ownerPid) { return $null }
    if ($scenario -eq 'foreign') {
        return [pscustomobject]@{
            ProcessId     = $queriedPid
            Name          = 'svchost.exe'
            ExecutablePath = 'C:\Windows\System32\svchost.exe'
            CommandLine   = 'C:\Windows\System32\svchost.exe -k unrelated-local-service'
        }
    }
    if ($scenario -eq 'runner-service-distinct' -and $queriedPid -eq $servicePid) {
        return [pscustomobject]@{
            ProcessId       = $queriedPid
            ParentProcessId  = $ownerPid
            Name            = 'node.exe'
            ExecutablePath   = 'C:\Program Files\nodejs\node.exe'
            CommandLine     = 'C:\Program Files\nodejs\node.exe "C:\dsh\runtime\node_modules\@deepseek-ai\dsh\lib\bin.js" web --no-open'
        }
    }
    return [pscustomobject]@{
        ProcessId      = $queriedPid
        Name           = 'powershell.exe'
        ExecutablePath = $exePath
        CommandLine    = ($exePath + ' -File "' + $fakeScriptPath + '" -Version 0.1.0-rc.8')
    }
}

function global:taskkill.exe {
    [IO.File]::AppendAllText($env:DSH_STOP_TEST_KILL_LOG, ($args -join ' ') + [Environment]::NewLine, [Text.Encoding]::ASCII)
    $killedPid = [int]$args[1]
    if ($scenario -eq 'runner-service-distinct') {
        if ($killedPid -eq $servicePid) {
            # The real service is a descendant of the runner. Killing the
            # service PID alone makes the runner begin its normal cleanup, but
            # it does not release the lock synchronously.
            $env:DSH_STOP_HAS_LISTENER = '0'
            $script:distinctServiceKillObserved = $true
            $global:LASTEXITCODE = 0
            return
        }
        if ($killedPid -eq $ownerPid) {
            if ($script:distinctServiceKillObserved) {
                # Reproduce the observed race: after the service is killed,
                # taskkill can lose against the runner's normal exit. The
                # process disappears on a later identity probe above.
                $global:LASTEXITCODE = 5
                return
            }
            # A direct runner stop succeeds and releases the startup lock.
            $env:DSH_STOP_HAS_LISTENER = '0'
            $env:DSH_STOP_PROCESS_GONE = '1'
            Remove-Item -LiteralPath (Join-Path $env:USERPROFILE 'dsh-launch\dsh-startup.lock') -Recurse -Force -ErrorAction SilentlyContinue
            $global:LASTEXITCODE = 0
            return
        }
    }
    if ($env:DSH_STOP_TASKKILL_EXIT -eq '5') {
        $global:LASTEXITCODE = 5
        if ($scenario -eq 'cim-unavailable-after-kill') {
            $script:cimUnavailable = $true
        }
        if ($env:DSH_STOP_TASKKILL_FAILS_BUT_RELEASES -eq '1') {
            $env:DSH_STOP_PROCESS_GONE = '1'
            Remove-Item -LiteralPath (Join-Path $env:USERPROFILE 'dsh-launch\dsh-startup.lock') -Recurse -Force -ErrorAction SilentlyContinue
        }
        return
    }
    $global:LASTEXITCODE = 0
    if ($env:DSH_STOP_TASKKILL_RELEASES -eq '1') {
        $env:DSH_STOP_PROCESS_GONE = '1'
        Remove-Item -LiteralPath (Join-Path $env:USERPROFILE 'dsh-launch\dsh-startup.lock') -Recurse -Force -ErrorAction SilentlyContinue
    }
}

& $env:DSH_STOP_SCRIPT -Port $port -WaitTimeoutMilliseconds ([int]$env:DSH_STOP_TEST_TIMEOUT_MS)
exit $LASTEXITCODE
'@
$harnessPath = Join-Path $testRoot 'stop-harness.ps1'

function New-IdentityStartupLock {
    $lockDir = Join-Path $launchRoot 'dsh-startup.lock'
    New-Item -ItemType Directory -Force -Path $lockDir | Out-Null
    $harnessPid = $PID
    $exePath = (Get-Process -Id $harnessPid).Path
    $fakeScriptPath = Join-Path $fakeScriptRoot 'background-run.ps1'
    $identity = [ordered]@{
        SchemaVersion = 1
        OwnerPid      = $harnessPid
        Token         = 'a' * 32
        CommandPath   = $exePath
        ScriptPath    = $fakeScriptPath
        CreatedAt     = (Get-Date).ToUniversalTime().ToString('o')
    }
    [IO.File]::WriteAllText(
        (Join-Path $lockDir 'identity.json'),
        ($identity | ConvertTo-Json),
        [Text.UTF8Encoding]::new($false)
    )
}

function Invoke-StopScenario {
    param(
        [Parameter(Mandatory = $true)][string]$Scenario,
        [string]$HasListener = '0',
        [string]$TaskkillExit = '0',
        [string]$TaskkillReleases = '0',
        [string]$TaskkillFailsButReleases = '0'
    )

    $previousProfile = $env:DSH_STOP_TEST_PROFILE
    $previousKillLog = $env:DSH_STOP_TEST_KILL_LOG
    $previousFakes = $env:DSH_STOP_TEST_FAKES
    $previousScript = $env:DSH_STOP_SCRIPT
    $previousScenario = $env:DSH_STOP_TEST_SCENARIO
    $previousPort = $env:DSH_STOP_TEST_PORT
    $previousTimeout = $env:DSH_STOP_TEST_TIMEOUT_MS
    $previousListener = $env:DSH_STOP_HAS_LISTENER
    $previousKillExit = $env:DSH_STOP_TASKKILL_EXIT
    $previousRelease = $env:DSH_STOP_TASKKILL_RELEASES
    $previousFailButRelease = $env:DSH_STOP_TASKKILL_FAILS_BUT_RELEASES
    $previousGone = $env:DSH_STOP_PROCESS_GONE
    $previousServicePid = $env:DSH_STOP_SERVICE_PID
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        New-Item -ItemType Directory -Force -Path $launchRoot | Out-Null
        $env:DSH_STOP_TEST_PROFILE = $profileRoot
        $env:DSH_STOP_TEST_KILL_LOG = $killLog
        $env:DSH_STOP_TEST_FAKES = $fakeScriptRoot
        $env:DSH_STOP_SCRIPT = $stopScript
        $env:DSH_STOP_TEST_SCENARIO = $Scenario
        $env:DSH_STOP_TEST_PORT = '30880'
        $env:DSH_STOP_TEST_TIMEOUT_MS = '600'
        $env:DSH_STOP_HAS_LISTENER = $HasListener
        $env:DSH_STOP_TASKKILL_EXIT = $TaskkillExit
        $env:DSH_STOP_TASKKILL_RELEASES = $TaskkillReleases
        $env:DSH_STOP_TASKKILL_FAILS_BUT_RELEASES = $TaskkillFailsButReleases
        $env:DSH_STOP_PROCESS_GONE = '0'
        $env:DSH_STOP_OWNER_PID = [string]$PID
        $env:DSH_STOP_SERVICE_PID = [string]($PID + 1000)
        New-IdentityStartupLock
        $ErrorActionPreference = 'Continue'
        $output = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $harnessPath 2>&1)
        $exitCode = $LASTEXITCODE
        $killLogText = ''
        if (Test-Path -LiteralPath $killLog) { $killLogText = [IO.File]::ReadAllText($killLog) }
        return [pscustomobject]@{
            ExitCode = $exitCode
            Output   = [string]($output -join [Environment]::NewLine)
            KillLog  = $killLogText
        }
    } finally {
        $env:DSH_STOP_TEST_PROFILE = $previousProfile
        $env:DSH_STOP_TEST_KILL_LOG = $previousKillLog
        $env:DSH_STOP_TEST_FAKES = $previousFakes
        $env:DSH_STOP_SCRIPT = $previousScript
        $env:DSH_STOP_TEST_SCENARIO = $previousScenario
        $env:DSH_STOP_TEST_PORT = $previousPort
        $env:DSH_STOP_TEST_TIMEOUT_MS = $previousTimeout
        $env:DSH_STOP_HAS_LISTENER = $previousListener
        $env:DSH_STOP_TASKKILL_EXIT = $previousKillExit
        $env:DSH_STOP_TASKKILL_RELEASES = $previousRelease
        $env:DSH_STOP_TASKKILL_FAILS_BUT_RELEASES = $previousFailButRelease
        $env:DSH_STOP_PROCESS_GONE = $previousGone
        $env:DSH_STOP_SERVICE_PID = $previousServicePid
        $ErrorActionPreference = $previousErrorActionPreference
        if (Test-Path -LiteralPath (Join-Path $launchRoot 'dsh-startup.lock')) {
            Remove-Item -LiteralPath (Join-Path $launchRoot 'dsh-startup.lock') -Recurse -Force
        }
        if (Test-Path -LiteralPath $killLog) { Remove-Item -LiteralPath $killLog -Force }
    }
}

New-Item -ItemType Directory -Force -Path $testRoot, $launchRoot, $fakeScriptRoot | Out-Null
try {
    [IO.File]::WriteAllText($harnessPath, $harness, [Text.UTF8Encoding]::new($false))

    Invoke-Test 'stop kills an identified runner holding a live identity lock and reports success' {
        $result = Invoke-StopScenario -Scenario 'locked-runner' -TaskkillReleases '1'
        Assert-Equal 0 $result.ExitCode "A verified stop must succeed. Output:`n$($result.Output)"
        Assert-Match $result.KillLog '/PID \d+ /T /F' 'Stop must taskkill the verified runner tree'
        Assert-Match $result.Output 'PID' 'Success output must identify the stopped process'
    }

    Invoke-Test 'a failed taskkill propagates as a stop failure with a nonzero exit code' {
        $result = Invoke-StopScenario -Scenario 'locked-runner' -TaskkillExit '5'
        Assert-Equal 1 $result.ExitCode 'taskkill failure must propagate'
        Assert-Match $result.Output 'taskkill.*5|5.*taskkill' 'The failure must name taskkill and its exit code'
        Assert-Match $result.KillLog '/PID \d+ /T /F' 'The kill attempt itself must still be logged'
    }

    Invoke-Test 'a taskkill race succeeds when the verified process has already exited' {
        $result = Invoke-StopScenario -Scenario 'locked-runner' -TaskkillExit '5' -TaskkillFailsButReleases '1'
        Assert-Equal 0 $result.ExitCode 'A process that exits during taskkill must not make stop fail'
    }

    Invoke-Test 'a CIM query failure after taskkill is not reported as a successful stop' {
        $result = Invoke-StopScenario -Scenario 'cim-unavailable-after-kill' -TaskkillExit '5'
        Assert-Equal 1 $result.ExitCode 'An indeterminate process state must remain a stop failure'
        Assert-Match $result.Output 'taskkill.*5|5.*taskkill' `
            'The stop failure must preserve the taskkill exit code when CIM is unavailable'
    }

    Invoke-Test 'a distinct service PID is stopped through its verified runner tree' {
        $result = Invoke-StopScenario -Scenario 'runner-service-distinct' -HasListener '1'
        Assert-Equal 0 $result.ExitCode "A runner-owned service with a distinct listener PID must stop successfully. Output:`n$($result.Output)"
        Assert-Match $result.KillLog ([regex]::Escape("/PID $($PID + 1000) /T /F")) `
            'Stop must attempt to terminate the identified service PID'
        Assert-Match $result.KillLog ([regex]::Escape("/PID $PID /T /F")) `
            'Stop must also clean up the verified runner PID'
        Assert-Equal 2 ([regex]::Matches($result.KillLog, '/PID').Count) `
            'The service and runner should each be targeted once'
        Assert-NotMatch $result.Output 'stop failed|taskkill.*5' `
            'A runner that exits during taskkill must not be reported as a stop failure'
    }

    Invoke-Test 'a surviving process or lock fails the stop after the condition wait times out' {
        $result = Invoke-StopScenario -Scenario 'locked-runner' -HasListener '1' -TaskkillReleases '0'
        Assert-Equal 1 $result.ExitCode 'A surviving PID or lock must fail after timeout'
        Assert-Match $result.Output 'stop timeout' 'The timeout must be explicit'
        Assert-Match $result.Output "/PID $($PID) " 'The diagnostic must identify the surviving PID'
        Assert-Equal 1 ([regex]::Matches($result.KillLog, '/PID').Count) 'The stop must not kill repeatedly during the wait'
    }

    Invoke-Test 'a foreign port occupant is reported and never killed' {
        $result = Invoke-StopScenario -Scenario 'foreign' -HasListener '1'
        Assert-Equal 0 $result.ExitCode 'A foreign occupant must not fail the stop command itself'
        Assert-Equal '' $result.KillLog 'The foreign process must never appear in the kill log'
        Assert-Match $result.Output '30880.*PID|PID.*30880' 'The report must point at the occupied port and owner'
    }

    Write-Host "All $script:Passed stop behavior tests passed."
} finally {
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}

exit 0
