$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$logsScript = Join-Path $repoRoot 'dsh-logs.ps1'
$testRoot = Join-Path $env:TEMP ('dsh-logs-tests-' + [guid]::NewGuid().ToString('N'))
$script:Passed = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    if ($Expected -ne $Actual) { throw "$Message (expected: $Expected, actual: $Actual)" }
}

function Assert-Match {
    param([string]$Actual, [string]$Pattern, [string]$Message)
    if ($Actual -notmatch $Pattern) { throw "$Message`nActual output:`n$Actual" }
}

function Invoke-Test {
    param([string]$Name, [scriptblock]$Body)
    & $Body
    $script:Passed++
    Write-Host "PASS: $Name"
}

function New-LogFixture {
    param([string]$Name)

    $root = Join-Path $testRoot $Name
    $profileRoot = Join-Path $root 'profile'
    $launchRoot = Join-Path $profileRoot 'dsh-launch'
    New-Item -ItemType Directory -Force -Path $launchRoot | Out-Null
    return [pscustomobject]@{
        Root = $root
        ProfileRoot = $profileRoot
        LogPath = (Join-Path $launchRoot 'dsh-background.log')
    }
}

function Invoke-Logs {
    param([pscustomobject]$Fixture, [switch]$Follow, [int]$Count = 0)

    $previousUserProfile = $env:USERPROFILE
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $env:USERPROFILE = $Fixture.ProfileRoot
        $ErrorActionPreference = 'Continue'
        $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $logsScript)
        if ($Count -gt 0) { $arguments += @('-Count', [string]$Count) }
        if ($Follow) { $arguments += '-Follow' }
        $output = & powershell.exe @arguments 2>&1
        return [pscustomobject]@{
            ExitCode = $LASTEXITCODE
            Output = [string]($output -join [Environment]::NewLine)
        }
    } finally {
        $env:USERPROFILE = $previousUserProfile
        $ErrorActionPreference = $previousErrorActionPreference
    }
}

New-Item -ItemType Directory -Force -Path $testRoot | Out-Null
try {
    Invoke-Test 'a missing log is reported without failing' {
        $fixture = New-LogFixture -Name 'missing-log'
        $result = Invoke-Logs -Fixture $fixture
        Assert-Equal 0 $result.ExitCode 'A missing log must not fail the command'
        Assert-Match $result.Output 'No log yet' 'The missing log must be explained'
    }

    Invoke-Test 'plain mode prints the requested tail of the log' {
        $fixture = New-LogFixture -Name 'tail'
        1..30 | ForEach-Object { Add-Content -LiteralPath $fixture.LogPath -Value "line-$_" -Encoding UTF8 }
        $result = Invoke-Logs -Fixture $fixture -Count 5
        Assert-Equal 0 $result.ExitCode 'The tail read must succeed'
        $lines = @($result.Output -split "`r?`n" | Where-Object { $_ })
        Assert-Equal 5 $lines.Count 'Exactly the requested number of lines must be returned'
        Assert-Equal 'line-30' $lines[-1] 'The tail must end at the newest line'
        Assert-Equal 'line-26' $lines[0] 'The tail must start at the requested offset'
    }

    Invoke-Test 'follow mode streams live lines and reconnects after rotation' {
        $fixture = New-LogFixture -Name 'follow'
        Add-Content -LiteralPath $fixture.LogPath -Value 'tail-marker' -Encoding UTF8
        $capturePath = Join-Path $fixture.Root 'follow-capture.txt'
        $errPath = Join-Path $fixture.Root 'follow-error.txt'

        # Isolation: the follow child inherits USERPROFILE; it must be pointed
        # at the fixture profile, never at the real user log.
        $previousUserProfile = $env:USERPROFILE
        $env:USERPROFILE = $fixture.ProfileRoot
        $env:DSH_TEST_LOG_DEBUG = (Join-Path $fixture.Root 'follow-debug.txt')
        $follow = Start-Process powershell.exe `
            -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$logsScript`"", '-Follow', '-Count', '10') `
            -WindowStyle Hidden -RedirectStandardOutput $capturePath -RedirectStandardError $errPath -PassThru
        $env:DSH_TEST_LOG_DEBUG = $null
        $env:USERPROFILE = $previousUserProfile
        try {
            $deadline = (Get-Date).AddSeconds(20)
            $captured = ''
            while ((Get-Date) -lt $deadline) {
                if (Test-Path -LiteralPath $capturePath) {
                    $captured = Get-Content -LiteralPath $capturePath -Raw -ErrorAction SilentlyContinue
                    if ($captured -and $captured -match 'tail-marker') { break }
                }
                if ($follow.HasExited) { throw "The follow process exited early: $([IO.File]::ReadAllText($errPath))" }
                Start-Sleep -Milliseconds 200
            }
            Assert-Match $captured 'tail-marker' 'Follow mode must start with the existing tail'

            Add-Content -LiteralPath $fixture.LogPath -Value 'LIVE-1' -Encoding UTF8
            $deadline = (Get-Date).AddSeconds(20)
            while ((Get-Date) -lt $deadline) {
                $captured = Get-Content -LiteralPath $capturePath -Raw -ErrorAction SilentlyContinue
                if ($captured -and $captured -match 'LIVE-1') { break }
                if ($follow.HasExited) { throw 'The follow process exited while streaming' }
                Start-Sleep -Milliseconds 200
            }
            Assert-Match $captured 'LIVE-1' 'Follow mode must stream newly appended lines'

            # Simulate the runner-side rotation: the log is renamed away and a
            # fresh file takes its place; follow mode must reconnect.
            Move-Item -LiteralPath $fixture.LogPath -Destination "$($fixture.LogPath).old" -Force
            Add-Content -LiteralPath $fixture.LogPath -Value 'LIVE-2-AFTER-ROTATION' -Encoding UTF8
            $deadline = (Get-Date).AddSeconds(20)
            $reconnected = $false
            while ((Get-Date) -lt $deadline) {
                if (Test-Path -LiteralPath $capturePath) {
                    $captured = Get-Content -LiteralPath $capturePath -Raw -ErrorAction SilentlyContinue
                    if ($captured -and $captured -match 'LIVE-2-AFTER-ROTATION') { $reconnected = $true; break }
                }
                if ($follow.HasExited) { throw 'The follow process exited across rotation' }
                Start-Sleep -Milliseconds 200
            }
            if (-not $reconnected) {
                $state = if ($follow.HasExited) { "exited $($follow.ExitCode)" } else { 'running' }
                $captureNow = if (Test-Path -LiteralPath $capturePath) { Get-Content -LiteralPath $capturePath -Raw } else { '<missing>' }
                $debugNow = if (Test-Path -LiteralPath (Join-Path $fixture.Root 'follow-debug.txt')) { Get-Content -LiteralPath (Join-Path $fixture.Root 'follow-debug.txt') -Raw } else { '<none>' }
                throw "Follow mode must reconnect to the log after rotation (child $state). Capture: $captureNow. Debug: $debugNow"
            }
        } finally {
            if ($follow -and -not $follow.HasExited) {
                Stop-Process -Id $follow.Id -Force -ErrorAction SilentlyContinue
                $follow.WaitForExit(5000) | Out-Null
            }
        }
    }

    Write-Host "All $script:Passed log behavior tests passed."
} finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}

exit 0
