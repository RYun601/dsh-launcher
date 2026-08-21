$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$monitorScript = Join-Path $repoRoot 'open-when-ready.ps1'
$testRoot = Join-Path $env:TEMP ('dsh-open-when-ready-tests-' + [guid]::NewGuid().ToString('N'))
$launchRoot = Join-Path $testRoot 'launch'
$eventsPath = Join-Path $testRoot 'events.log'
$harnessPath = Join-Path $testRoot 'monitor-harness.ps1'
$script:Passed = 0

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    if ($Expected -ne $Actual) { throw "$Message (expected: $Expected, actual: $Actual)" }
}

function Assert-Match {
    param([string]$Actual, [string]$Pattern, [string]$Message)
    if ($Actual -notmatch $Pattern) { throw "$Message`nActual:`n$Actual" }
}

function Invoke-Test {
    param([string]$Name, [scriptblock]$Body)
    & $Body
    $script:Passed++
    Write-Host "PASS: $Name"
}

New-Item -ItemType Directory -Force -Path $testRoot, $launchRoot | Out-Null
try {
    $harness = @'
param(
    [Parameter(Mandatory = $true)][string]$MonitorScript,
    [Parameter(Mandatory = $true)][string]$LaunchRoot,
    [Parameter(Mandatory = $true)][string]$EventsPath
)

$script:RequestCount = 0

function global:Invoke-WebRequest {
    param([string]$Uri, [switch]$UseBasicParsing, [int]$TimeoutSec)

    $script:RequestCount++
    [IO.File]::AppendAllText($EventsPath, "REQUEST $($script:RequestCount) $Uri`r`n", [Text.Encoding]::ASCII)
    if ($script:RequestCount -eq 1) { throw 'not ready' }
    return [pscustomobject]@{ StatusCode = 200 }
}

function global:Start-Sleep {
    param([int]$Milliseconds)
    [IO.File]::AppendAllText($EventsPath, "SLEEP $Milliseconds`r`n", [Text.Encoding]::ASCII)
}

function global:Start-Process {
    param([Parameter(Position = 0)][string]$FilePath)
    [IO.File]::AppendAllText($EventsPath, "OPEN $FilePath`r`n", [Text.Encoding]::ASCII)
}

& $MonitorScript -TimeoutSeconds 10 -PollIntervalMilliseconds 200 `
    -LaunchRoot $LaunchRoot -OwnerPid $PID
exit $LASTEXITCODE
'@
    [IO.File]::WriteAllText($harnessPath, $harness, [Text.UTF8Encoding]::new($false))

    Invoke-Test 'readiness monitor retries at 200 ms and opens the browser once' {
        $output = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $harnessPath `
            -MonitorScript $monitorScript -LaunchRoot $launchRoot -EventsPath $eventsPath 2>&1)
        $exitCode = $LASTEXITCODE
        Assert-Equal 0 $exitCode "Readiness monitor should succeed on its second request. Output:`n$($output -join [Environment]::NewLine)"

        $events = [IO.File]::ReadAllText($eventsPath)
        Assert-Match $events '(?m)^SLEEP 200\r?$' 'Readiness retries must use the 200 ms interval'
        Assert-Equal 1 ([regex]::Matches($events, '(?m)^OPEN http://127\.0\.0\.1:3080\r?$').Count) `
            'Only one successful readiness transition may open the browser'

        $state = Get-Content -LiteralPath (Join-Path $launchRoot 'dsh-startup.json') -Raw | ConvertFrom-Json
        Assert-Equal 'RUNNING' $state.State 'HTTP success must record RUNNING before exit'
    }

    Write-Host "All $script:Passed readiness monitor behavior tests passed."
} finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}

exit 0
