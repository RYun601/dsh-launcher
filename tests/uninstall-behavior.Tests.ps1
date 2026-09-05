$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$uninstallScript = Join-Path $repoRoot 'uninstall.ps1'
$testRoot = Join-Path $env:TEMP ('dsh-launcher-uninstall-tests-' + [guid]::NewGuid().ToString('N'))
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

function New-UninstallFixture {
    param(
        [string]$ScenarioName,
        [switch]$WithLauncherMarker,
        [switch]$WithLaunchDir,
        [string]$OwnerMarkerTarget
    )

    $fixtureRoot = Join-Path $testRoot $ScenarioName
    $installDir = Join-Path $fixtureRoot 'launcher'
    $profileRoot = Join-Path $fixtureRoot 'profile'
    $launchDir = Join-Path $profileRoot 'dsh-launch'
    New-Item -ItemType Directory -Force -Path $installDir, $profileRoot | Out-Null

    Copy-Item -LiteralPath $uninstallScript -Destination $installDir
    if ($WithLauncherMarker) {
        [IO.File]::WriteAllText((Join-Path $installDir 'deepseek.cmd'), '@echo off' + "`r`n", [Text.Encoding]::ASCII)
    }
    if ($PSBoundParameters.ContainsKey('OwnerMarkerTarget')) {
        $owner = [ordered]@{
            SchemaVersion = 1
            InstallPath   = $OwnerMarkerTarget
            InstallationId = [guid]::NewGuid().ToString('N')
        }
        [IO.File]::WriteAllText(
            (Join-Path $installDir '.dsh-launcher-owner.json'),
            ($owner | ConvertTo-Json),
            [Text.UTF8Encoding]::new($false)
        )
    }
    # Fake stop-dsh.ps1: records the call; DSH_TEST_UNINSTALL_STOP_FAIL=1 simulates a failing stop.
    [IO.File]::WriteAllText(
        (Join-Path $installDir 'stop-dsh.ps1'),
        "[IO.File]::WriteAllText(`$env:DSH_TEST_UNINSTALL_STOP_MARKER, 'STOPPED', [Text.Encoding]::ASCII)`r`nif (`$env:DSH_TEST_UNINSTALL_STOP_FAIL -eq '1') { exit 3 }`r`nexit 0`r`n",
        [Text.Encoding]::ASCII
    )
    if ($WithLaunchDir) {
        New-Item -ItemType Directory -Force -Path $launchDir | Out-Null
        [IO.File]::WriteAllText((Join-Path $launchDir 'sentinel.txt'), 'keep', [Text.Encoding]::ASCII)
    }

    return [pscustomobject]@{
        Root        = $fixtureRoot
        InstallDir  = $installDir
        ProfileRoot = $profileRoot
        LaunchDir   = $launchDir
        StopMarker  = Join-Path $fixtureRoot 'stop.log'
    }
}

function Invoke-Uninstall {
    param(
        [pscustomobject]$Fixture,
        [string]$UserProfile = $Fixture.ProfileRoot,
        [string]$StopFail = '0',
        [string]$DeleteBackupFail = '0',
        [string]$FailMove = '',
        [string]$Confirm = 'y'
    )

    $previousUserProfile = $env:USERPROFILE
    $previousStopMarker = $env:DSH_TEST_UNINSTALL_STOP_MARKER
    $previousStopFail = $env:DSH_TEST_UNINSTALL_STOP_FAIL
    $previousDeleteFail = $env:DSH_TEST_UNINSTALL_DELETE_BACKUP_FAIL
    $previousFailMove = $env:DSH_TEST_UNINSTALL_FAIL_MOVE
    $beforePath = [Environment]::GetEnvironmentVariable('Path', 'User')
    try {
        $env:USERPROFILE = $UserProfile
        $env:DSH_TEST_UNINSTALL_STOP_MARKER = $Fixture.StopMarker
        $env:DSH_TEST_UNINSTALL_STOP_FAIL = $StopFail
        $env:DSH_TEST_UNINSTALL_DELETE_BACKUP_FAIL = $DeleteBackupFail
        $env:DSH_TEST_UNINSTALL_FAIL_MOVE = $FailMove
        $output = $Confirm | & powershell.exe -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $Fixture.InstallDir 'uninstall.ps1') -Full 2>&1
        return [pscustomobject]@{
            ExitCode      = $LASTEXITCODE
            Output        = [string]($output -join [Environment]::NewLine)
            PathBefore    = $beforePath
            PathAfter     = [Environment]::GetEnvironmentVariable('Path', 'User')
            PathUnchanged = ($beforePath -eq [Environment]::GetEnvironmentVariable('Path', 'User'))
        }
    } finally {
        $env:USERPROFILE = $previousUserProfile
        $env:DSH_TEST_UNINSTALL_STOP_MARKER = $previousStopMarker
        $env:DSH_TEST_UNINSTALL_STOP_FAIL = $previousStopFail
        $env:DSH_TEST_UNINSTALL_DELETE_BACKUP_FAIL = $previousDeleteFail
        $env:DSH_TEST_UNINSTALL_FAIL_MOVE = $previousFailMove
    }
}

function Get-TestBackupDirs {
    return @(Get-ChildItem -LiteralPath $env:TEMP -Directory -Filter 'dsh-launcher-backup-*' -ErrorAction SilentlyContinue)
}

New-Item -ItemType Directory -Force -Path $testRoot | Out-Null
try {
    Invoke-Test 'full uninstall aborts when USERPROFILE is unavailable' {
        $fixture = New-UninstallFixture -ScenarioName 'no-profile' -WithLauncherMarker -WithLaunchDir
        $result = Invoke-Uninstall -Fixture $fixture -UserProfile ''

        Assert-Equal 1 $result.ExitCode 'An empty USERPROFILE must abort the full uninstall'
        Assert-Match $result.Output 'aborted' 'The abort must be explicit'
        Assert-True (Test-Path -LiteralPath (Join-Path $fixture.LaunchDir 'sentinel.txt')) 'The launch directory must remain untouched'
    }

    Invoke-Test 'full uninstall aborts when the install directory lacks the launcher marker' {
        $fixture = New-UninstallFixture -ScenarioName 'no-marker' -WithLaunchDir
        $result = Invoke-Uninstall -Fixture $fixture

        Assert-Equal 1 $result.ExitCode 'An install directory without deepseek.cmd must be rejected'
        Assert-Match $result.Output 'aborted' 'The abort must be explicit'
        Assert-True (Test-Path -LiteralPath $fixture.InstallDir) 'The unverified install directory must not be deleted'
        Assert-True (Test-Path -LiteralPath (Join-Path $fixture.LaunchDir 'sentinel.txt')) 'The launch directory must remain untouched'
    }

    Invoke-Test 'full uninstall stops the service first and aborts when the stop fails' {
        $fixture = New-UninstallFixture -ScenarioName 'stop-fails' -WithLauncherMarker -WithLaunchDir
        $result = Invoke-Uninstall -Fixture $fixture -StopFail '1'

        Assert-Equal 1 $result.ExitCode 'A failed stop must abort the full uninstall'
        Assert-Match $result.Output 'aborted' 'The abort must be explicit'
        Assert-Equal 'STOPPED' ([IO.File]::ReadAllText($fixture.StopMarker).Trim()) 'The stop step must be attempted before deletion'
        Assert-True (Test-Path -LiteralPath (Join-Path $fixture.LaunchDir 'sentinel.txt')) 'A failed stop must not delete the launch directory'
    }

    Invoke-Test 'full uninstall backs up directories first and reports the backup location when cleanup fails' {
        $fixture = New-UninstallFixture -ScenarioName 'keep-backup' -WithLauncherMarker -WithLaunchDir
        $before = @(Get-TestBackupDirs)
        $result = Invoke-Uninstall -Fixture $fixture -DeleteBackupFail '1'

        Assert-Equal 0 $result.ExitCode 'The uninstall itself must succeed when only the backup cleanup fails'
        Assert-Match $result.Output 'backup kept at' 'The backup location must be reported'
        Assert-True (-not (Test-Path -LiteralPath $fixture.LaunchDir)) 'The launch directory must no longer exist at its original path'
        Assert-True (-not (Test-Path -LiteralPath $fixture.InstallDir)) 'The install directory must no longer exist at its original path'
        $after = @(Get-TestBackupDirs)
        Assert-Equal 1 ($after.Count - $before.Count) 'Exactly one new backup directory must remain'
        $newBackups = @($after | Where-Object { $before.FullName -notcontains $_.FullName })
        if ($newBackups.Count -gt 0) {
            $backupSentinel = Join-Path $newBackups[0].FullName 'dsh-launch\sentinel.txt'
            Assert-True (Test-Path -LiteralPath $backupSentinel) 'The backup must retain the launch directory contents'
            $backupMarker = Join-Path $newBackups[0].FullName 'install\deepseek.cmd'
            Assert-True (Test-Path -LiteralPath $backupMarker) 'The backup must retain the install directory contents'
        }
    }

    Invoke-Test 'full uninstall completes normally and cleans up its backup' {
        $fixture = New-UninstallFixture -ScenarioName 'normal' -WithLauncherMarker -WithLaunchDir
        # 模拟安装器留下的所有权标记；用确定性字符串构造，避免管道编码变量干扰。
        $markerJsonPath = Join-Path $fixture.InstallDir '.dsh-launcher-owner.json'
        $installFullPath = (Get-Item -LiteralPath $fixture.InstallDir).FullName.Replace('\', '\\')
        $markerJson = '{"SchemaVersion": 1, "InstallPath": "' + $installFullPath + '"}'
        [IO.File]::WriteAllText(
            $markerJsonPath,
            $markerJson,
            [Text.UTF8Encoding]::new($false)
        )
        $before = @(Get-TestBackupDirs)
        $result = Invoke-Uninstall -Fixture $fixture

        Assert-Equal 0 $result.ExitCode "A normal full uninstall must succeed. Output:`n$($result.Output)"
        Assert-True $result.PathUnchanged 'A committed uninstall with an unrelated PATH must leave its value identical'
        Assert-True (-not (Test-Path -LiteralPath $fixture.LaunchDir)) 'The launch directory must be removed'
        Assert-True (-not (Test-Path -LiteralPath $fixture.InstallDir)) 'The install directory must be removed'
        Assert-Equal $before.Count @(Get-TestBackupDirs).Count 'A normal uninstall must not leave new backup directories behind'
    }

    Invoke-Test 'cancelling the full uninstall changes nothing including the user PATH' {
        $fixture = New-UninstallFixture -ScenarioName 'cancelled' -WithLauncherMarker -WithLaunchDir
        $result = Invoke-Uninstall -Fixture $fixture -Confirm 'n'

        Assert-Equal 0 $result.ExitCode 'Cancelling is a normal outcome, not an error'
        Assert-Match $result.Output 'cancel|nothing' 'The output must state that nothing was changed'
        Assert-True $result.PathUnchanged 'A cancel must preserve the user PATH'
        Assert-True (Test-Path -LiteralPath $fixture.LaunchDir) 'The launch directory must remain untouched'
        Assert-True (Test-Path -LiteralPath $fixture.InstallDir) 'The install directory must remain untouched'
    }

    Invoke-Test 'full uninstall refuses a mismatched launcher ownership marker' {
        $fixture = New-UninstallFixture -ScenarioName 'wrong-owner' -WithLauncherMarker -WithLaunchDir `
            -OwnerMarkerTarget 'C:\somewhere-else\launcher'
        $result = Invoke-Uninstall -Fixture $fixture

        Assert-Equal 1 $result.ExitCode 'An ownership mismatch must abort the full uninstall'
        Assert-Match $result.Output 'aborted' 'The abort must be explicit'
        Assert-True $result.PathUnchanged 'An aborted uninstall must preserve the user PATH'
        Assert-True (Test-Path -LiteralPath $fixture.LaunchDir) 'The launch directory must remain untouched'
        Assert-True (Test-Path -LiteralPath (Join-Path $fixture.InstallDir '.dsh-launcher-owner.json')) 'The marker itself stays for diagnosis'
    }

    Invoke-Test 'a failed second move restores the already moved items and keeps the PATH' {
        $fixture = New-UninstallFixture -ScenarioName 'move-fails' -WithLauncherMarker -WithLaunchDir
        $before = @(Get-TestBackupDirs)
        $result = Invoke-Uninstall -Fixture $fixture -FailMove 'install'

        Assert-Equal 1 $result.ExitCode 'A failed move must abort the full uninstall'
        Assert-Match $result.Output 'aborted' 'The rollback must be explicit'
        Assert-True $result.PathUnchanged 'An aborted uninstall must preserve the user PATH'
        Assert-True (Test-Path -LiteralPath (Join-Path $fixture.LaunchDir 'sentinel.txt')) 'The first moved item must be restored to its original path'
        Assert-True (Test-Path -LiteralPath (Join-Path $fixture.InstallDir 'deepseek.cmd')) 'The failing item must remain at its original path'
        Assert-Equal $before.Count @(Get-TestBackupDirs).Count 'No backup directories may be left behind after a rollback'
    }

    Write-Host "All $script:Passed uninstall behavior tests passed."
} finally {
    foreach ($backup in @(Get-TestBackupDirs)) {
        Remove-Item -LiteralPath $backup.FullName -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}

exit 0
