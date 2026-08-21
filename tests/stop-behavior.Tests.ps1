$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$stopScript = Join-Path $repoRoot 'stop-dsh.ps1'
$testRoot = Join-Path $env:TEMP ('dsh-stop-tests-' + [guid]::NewGuid().ToString('N'))
$profileRoot = Join-Path $testRoot 'profile'
$launchRoot = Join-Path $profileRoot 'dsh-launch'
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

function Invoke-Test {
    param([string]$Name, [scriptblock]$Body)
    & $Body
    $script:Passed++
    Write-Host "PASS: $Name"
}

New-Item -ItemType Directory -Force -Path $testRoot, $launchRoot | Out-Null
try {
    $harness = @'
$ErrorActionPreference = 'Stop'
$env:USERPROFILE = $env:DSH_STOP_TEST_PROFILE
$killLog = $env:DSH_STOP_TEST_KILL_LOG

function global:Get-NetTCPConnection {
    param([int]$LocalPort, [string]$State)
    return $null
}

function global:Get-CimInstance {
    param([string]$ClassName, [string]$Filter)
    if ($Filter -match 'ProcessId=(\d+)') {
        return [pscustomobject]@{
            ProcessId = [int]$Matches[1]
            Name = 'powershell.exe'
            CommandLine = 'powershell.exe -File background-run.ps1 -Version 0.1.0-rc.8'
        }
    }
}

function global:taskkill.exe {
    [IO.File]::AppendAllText($killLog, ($args -join ' ') + [Environment]::NewLine, [Text.Encoding]::ASCII)
}

$lockDirectory = Join-Path $env:USERPROFILE 'dsh-launch\dsh-startup.lock'
New-Item -ItemType Directory -Force -Path $lockDirectory | Out-Null
Set-Content -LiteralPath (Join-Path $lockDirectory 'pid.txt') -Value $PID -Encoding ASCII

& $env:DSH_STOP_SCRIPT
exit $LASTEXITCODE
'@
    $harnessPath = Join-Path $testRoot 'stop-harness.ps1'
    [IO.File]::WriteAllText($harnessPath, $harness, [Text.UTF8Encoding]::new($false))

    Invoke-Test 'stop recognizes the PowerShell background runner while it owns startup lock' {
        $previousProfile = $env:DSH_STOP_TEST_PROFILE
        $previousKillLog = $env:DSH_STOP_TEST_KILL_LOG
        $previousScript = $env:DSH_STOP_SCRIPT
        try {
            $env:DSH_STOP_TEST_PROFILE = $profileRoot
            $env:DSH_STOP_TEST_KILL_LOG = $killLog
            $env:DSH_STOP_SCRIPT = $stopScript
            $output = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $harnessPath 2>&1)
            Assert-Equal 0 $LASTEXITCODE "Stop harness should exit successfully. Output:`n$($output -join [Environment]::NewLine)"
            Assert-Match ([IO.File]::ReadAllText($killLog)) '/PID \d+ /T /F' 'Stop should taskkill the startup runner tree'
        } finally {
            $env:DSH_STOP_TEST_PROFILE = $previousProfile
            $env:DSH_STOP_TEST_KILL_LOG = $previousKillLog
            $env:DSH_STOP_SCRIPT = $previousScript
        }
    }

    Write-Host "All $script:Passed stop behavior tests passed."
} finally {
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}

exit 0
