$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$uninstallScript = Join-Path $repoRoot 'uninstall.ps1'
$testRoot = Join-Path $env:TEMP ('dsh-launcher-uninstall-tests-' + [guid]::NewGuid().ToString('N'))
# 测试专用 TEMP：备份目录只允许出现在这里，绝不枚举或清理真实用户 TEMP。
$testTempRoot = Join-Path $testRoot 'temp'
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
    $desktopDir = Join-Path $profileRoot 'Desktop'
    New-Item -ItemType Directory -Force -Path $installDir, $profileRoot, $desktopDir | Out-Null

    Copy-Item -LiteralPath $uninstallScript -Destination $installDir
    Copy-Item -LiteralPath (Join-Path $repoRoot 'dsh-maintenance-lock.ps1') -Destination (Join-Path $installDir 'dsh-maintenance-lock.ps1')
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
        DesktopDir  = $desktopDir
        ShortcutPath = (Join-Path $desktopDir 'DeepSeek Harness.lnk')
        PathStore   = (Join-Path $fixtureRoot 'user-path.txt')
        StopMarker  = Join-Path $fixtureRoot 'stop.log'
    }
}

function New-ManagedShortcut {
    param([pscustomobject]$Fixture, [string]$TargetDir)

    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($Fixture.ShortcutPath)
    $commandProcessor = $env:ComSpec
    if (-not $commandProcessor) { $commandProcessor = Join-Path $env:SystemRoot 'System32\cmd.exe' }
    $shortcut.TargetPath = $commandProcessor
    $shortcut.Arguments = ('/d /c ""{0}""' -f (Join-Path $TargetDir 'start-background.cmd'))
    $shortcut.WorkingDirectory = $TargetDir
    $shortcut.Description = 'DeepSeek Harness (background mode)'
    $shortcut.Save()
}

function Invoke-Uninstall {
    param(
        [pscustomobject]$Fixture,
        [string]$UserProfile = $Fixture.ProfileRoot,
        [string]$StopFail = '0',
        [string]$DeleteBackupFail = '0',
        [string]$FailMove = '',
        [string]$FailRestore = '',
        [string]$FailPath = '0',
        [string]$Confirm = 'y'
    )

    $previousUserProfile = $env:USERPROFILE
    $previousStopMarker = $env:DSH_TEST_UNINSTALL_STOP_MARKER
    $previousStopFail = $env:DSH_TEST_UNINSTALL_STOP_FAIL
    $previousDeleteFail = $env:DSH_TEST_UNINSTALL_DELETE_BACKUP_FAIL
    $previousFailMove = $env:DSH_TEST_UNINSTALL_FAIL_MOVE
    $previousFailRestore = $env:DSH_TEST_UNINSTALL_FAIL_RESTORE
    $previousFailPath = $env:DSH_TEST_UNINSTALL_FAIL_PATH
    $previousDesktop = $env:DSH_TEST_UNINSTALL_DESKTOP
    $previousPathStore = $env:DSH_TEST_UNINSTALL_PATH_STORE
    $previousTemp = $env:TEMP
    $beforeRealPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    try {
        # R4 隔离：桌面、PATH 存储与 TEMP 全部注入测试作用域内的假资源，
        # 子进程继承这些环境变量，真实桌面、注册表与 TEMP 不被触碰。
        $env:USERPROFILE = $UserProfile
        $env:DSH_TEST_UNINSTALL_STOP_MARKER = $Fixture.StopMarker
        $env:DSH_TEST_UNINSTALL_STOP_FAIL = $StopFail
        $env:DSH_TEST_UNINSTALL_DELETE_BACKUP_FAIL = $DeleteBackupFail
        $env:DSH_TEST_UNINSTALL_FAIL_MOVE = $FailMove
        $env:DSH_TEST_UNINSTALL_FAIL_RESTORE = $FailRestore
        $env:DSH_TEST_UNINSTALL_FAIL_PATH = $FailPath
        $env:DSH_TEST_UNINSTALL_DESKTOP = $Fixture.DesktopDir
        $env:DSH_TEST_UNINSTALL_PATH_STORE = $Fixture.PathStore
        $env:TEMP = $testTempRoot
        # 子进程 stderr（如预期的互斥超时）不能以 NativeCommandError 终止父测试。
        $ErrorActionPreference = 'Continue'
        $output = $Confirm | & powershell.exe -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $Fixture.InstallDir 'uninstall.ps1') -Full 2>&1
        $ErrorActionPreference = $previousErrorActionPreference
        return [pscustomobject]@{
            ExitCode      = $LASTEXITCODE
            Output        = [string]($output -join [Environment]::NewLine)
            PathBefore    = $beforeRealPath
            PathAfter     = [Environment]::GetEnvironmentVariable('Path', 'User')
            PathUnchanged = ($beforeRealPath -eq [Environment]::GetEnvironmentVariable('Path', 'User'))
        }
    } finally {
        $env:USERPROFILE = $previousUserProfile
        $env:DSH_TEST_UNINSTALL_STOP_MARKER = $previousStopMarker
        $env:DSH_TEST_UNINSTALL_STOP_FAIL = $previousStopFail
        $env:DSH_TEST_UNINSTALL_DELETE_BACKUP_FAIL = $previousDeleteFail
        $env:DSH_TEST_UNINSTALL_FAIL_MOVE = $previousFailMove
        $env:DSH_TEST_UNINSTALL_FAIL_RESTORE = $previousFailRestore
        $env:DSH_TEST_UNINSTALL_FAIL_PATH = $previousFailPath
        $env:DSH_TEST_UNINSTALL_DESKTOP = $previousDesktop
        $env:DSH_TEST_UNINSTALL_PATH_STORE = $previousPathStore
        $env:TEMP = $previousTemp
    }
}

function Get-TestBackupDirs {
    if (-not (Test-Path -LiteralPath $testTempRoot)) { return @() }
    return @(Get-ChildItem -LiteralPath $testTempRoot -Directory -Filter 'dsh-launcher-backup-*' -ErrorAction SilentlyContinue)
}

function New-UserPathStore {
    param([pscustomobject]$Fixture, [string]$Content)
    [IO.File]::WriteAllText($Fixture.PathStore, $Content, [Text.UTF8Encoding]::new($false))
}

New-Item -ItemType Directory -Force -Path $testRoot, $testTempRoot | Out-Null
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
        New-ManagedShortcut -Fixture $fixture -TargetDir $fixture.InstallDir
        New-UserPathStore -Fixture $fixture -Content ('C:\other\tool;' + $fixture.InstallDir)
        $before = @(Get-TestBackupDirs)
        $result = Invoke-Uninstall -Fixture $fixture -FailMove 'install'

        Assert-Equal 1 $result.ExitCode 'A failed move must abort the full uninstall'
        Assert-Match $result.Output 'aborted' 'The rollback must be explicit'
        Assert-True $result.PathUnchanged 'An aborted uninstall must preserve the user PATH'
        Assert-True (Test-Path -LiteralPath (Join-Path $fixture.LaunchDir 'sentinel.txt')) 'The first moved item must be restored to its original path'
        Assert-True (Test-Path -LiteralPath (Join-Path $fixture.InstallDir 'deepseek.cmd')) 'The failing item must remain at its original path'
        # R3 核心断言：快捷方式也必须被恢复，且内容仍是本安装的受管快捷方式。
        Assert-True (Test-Path -LiteralPath $fixture.ShortcutPath) 'The backed-up shortcut must be restored, not lost'
        $shell = New-Object -ComObject WScript.Shell
        $restoredShortcut = $shell.CreateShortcut($fixture.ShortcutPath)
        Assert-Match $restoredShortcut.Arguments ([regex]::Escape($fixture.InstallDir)) `
            'The restored shortcut must still point at this installation'
        $pathAfter = [IO.File]::ReadAllText($fixture.PathStore)
        Assert-Match $pathAfter ([regex]::Escape($fixture.InstallDir)) 'An aborted uninstall must not rewrite the injected PATH store'
        Assert-Equal $before.Count @(Get-TestBackupDirs).Count 'No backup directories may be left behind after a rollback'
    }

    Invoke-Test 'a failed PATH commit restores every moved item including the shortcut' {
        $fixture = New-UninstallFixture -ScenarioName 'path-fails' -WithLauncherMarker -WithLaunchDir
        New-ManagedShortcut -Fixture $fixture -TargetDir $fixture.InstallDir
        $before = @(Get-TestBackupDirs)
        $result = Invoke-Uninstall -Fixture $fixture -FailPath '1'

        Assert-Equal 1 $result.ExitCode 'A failed PATH commit must abort the full uninstall'
        Assert-Match $result.Output 'aborted' 'The rollback must be explicit'
        Assert-True (Test-Path -LiteralPath (Join-Path $fixture.LaunchDir 'sentinel.txt')) 'The launch directory must be restored'
        Assert-True (Test-Path -LiteralPath (Join-Path $fixture.InstallDir 'deepseek.cmd')) 'The install directory must be restored'
        Assert-True (Test-Path -LiteralPath $fixture.ShortcutPath) 'The shortcut must be restored when the PATH commit fails'
        Assert-Equal $before.Count @(Get-TestBackupDirs).Count 'A completed rollback must remove its backup directory'
    }

    Invoke-Test 'a failed restore keeps the remaining backup and reports its location' {
        $fixture = New-UninstallFixture -ScenarioName 'restore-fails' -WithLauncherMarker -WithLaunchDir
        New-ManagedShortcut -Fixture $fixture -TargetDir $fixture.InstallDir
        New-UserPathStore -Fixture $fixture -Content 'C:\other\tool'
        $before = @(Get-TestBackupDirs)
        $result = Invoke-Uninstall -Fixture $fixture -FailPath '1' -FailRestore 'install'

        Assert-Equal 1 $result.ExitCode 'A failed restore must surface as a failure'
        Assert-Match $result.Output 'backup kept at' 'The surviving backup location must be reported'
        # install 恢复被注入失败：其余条目（快捷方式、dsh-launch）必须已恢复。
        Assert-True (Test-Path -LiteralPath $fixture.ShortcutPath) 'Items that were restorable must be restored'
        Assert-True (Test-Path -LiteralPath (Join-Path $fixture.LaunchDir 'sentinel.txt')) 'Restorable launch data must be restored'
        Assert-True (-not (Test-Path -LiteralPath $fixture.InstallDir)) 'The failed item must stay inside the surviving backup'
        $after = @(Get-TestBackupDirs)
        Assert-Equal 1 ($after.Count - $before.Count) 'Exactly one backup directory must survive a failed restore'
        Assert-True (Test-Path -LiteralPath (Join-Path $after[$after.Count - 1].FullName 'install\deepseek.cmd')) `
            'The surviving backup must contain the unrestored install directory'
    }

    Invoke-Test 'an unrelated file named like the shortcut is preserved' {
        # R6 场景一：同名但根本不是快捷方式的哨兵文件必须保留。
        $fixture = New-UninstallFixture -ScenarioName 'unrelated-sentinel-shortcut' -WithLauncherMarker -WithLaunchDir
        [IO.File]::WriteAllText($fixture.ShortcutPath, 'not a shortcut', [Text.Encoding]::ASCII)
        $result = Invoke-Uninstall -Fixture $fixture

        Assert-Equal 0 $result.ExitCode "The uninstall must succeed. Output:`n$($result.Output)"
        Assert-True (Test-Path -LiteralPath $fixture.ShortcutPath) 'An unrelated same-name file must be preserved'
        Assert-Equal 'not a shortcut' ([IO.File]::ReadAllText($fixture.ShortcutPath)) 'The preserved file content must be intact'
        Assert-Match $result.Output ([regex]::Escape('已保留')) 'The output must state that the same-name item was kept'
    }

    Invoke-Test 'a shortcut owned by another installation is preserved' {
        # R6 场景二：同名快捷方式指向另一个安装目录，必须保留。
        $fixture = New-UninstallFixture -ScenarioName 'foreign-owned-shortcut' -WithLauncherMarker -WithLaunchDir
        $otherInstall = Join-Path $fixture.Root 'other-install'
        New-Item -ItemType Directory -Force -Path $otherInstall | Out-Null
        New-ManagedShortcut -Fixture $fixture -TargetDir $otherInstall
        $result = Invoke-Uninstall -Fixture $fixture

        Assert-Equal 0 $result.ExitCode "The uninstall must succeed. Output:`n$($result.Output)"
        Assert-True (Test-Path -LiteralPath $fixture.ShortcutPath) 'A shortcut owned by another installation must be preserved'
        $shell = New-Object -ComObject WScript.Shell
        $keptShortcut = $shell.CreateShortcut($fixture.ShortcutPath)
        Assert-Match $keptShortcut.Arguments ([regex]::Escape($otherInstall)) `
            'The preserved shortcut must still point at the other installation'
    }

    Invoke-Test 'the managed shortcut of this installation is removed with the install' {
        # R6 场景三：本安装的受管快捷方式随卸载移除。
        $fixture = New-UninstallFixture -ScenarioName 'owned-shortcut' -WithLauncherMarker -WithLaunchDir
        New-ManagedShortcut -Fixture $fixture -TargetDir $fixture.InstallDir
        $result = Invoke-Uninstall -Fixture $fixture

        Assert-Equal 0 $result.ExitCode "The uninstall must succeed. Output:`n$($result.Output)"
        Assert-True (-not (Test-Path -LiteralPath $fixture.ShortcutPath)) 'The managed shortcut must be removed'
    }

    Invoke-Test 'a held maintenance mutex refuses the full uninstall' {
        # AGENTS 不变量 11：完整卸载必须与覆盖安装、DSH 升级、自更新串行化。
        $fixture = New-UninstallFixture -ScenarioName 'maintenance-busy' -WithLauncherMarker -WithLaunchDir
        New-ManagedShortcut -Fixture $fixture -TargetDir $fixture.InstallDir
        . (Join-Path $repoRoot 'dsh-maintenance-lock.ps1')
        $holderMutex = Enter-DshMaintenanceLock -LaunchRoot (Join-Path $fixture.ProfileRoot 'dsh-launch') `
            -TimeoutMilliseconds 200
        try {
            $previousTimeout = $env:DSH_TEST_MAINTENANCE_TIMEOUT_MS
            $env:DSH_TEST_MAINTENANCE_TIMEOUT_MS = '500'
            try {
                $result = Invoke-Uninstall -Fixture $fixture
            } finally {
                $env:DSH_TEST_MAINTENANCE_TIMEOUT_MS = $previousTimeout
            }
            Assert-Equal 1 $result.ExitCode 'A blocked uninstall must fail with a nonzero exit code'
            Assert-Match $result.Output ([regex]::Escape('maintenance lock')) 'The failure must name the launcher maintenance lock'
            Assert-True (Test-Path -LiteralPath (Join-Path $fixture.LaunchDir 'sentinel.txt')) 'A blocked uninstall must not delete the launch directory'
            Assert-True (Test-Path -LiteralPath $fixture.InstallDir) 'A blocked uninstall must not delete the install directory'
            Assert-True (Test-Path -LiteralPath $fixture.ShortcutPath) 'A blocked uninstall must not touch the shortcut'
        } finally {
            Exit-DshMaintenanceLock -Mutex $holderMutex
        }
    }

    Invoke-Test 'pre-existing backup directories from other tasks are preserved' {
        # R4 验收：TEMP 中先前存在的备份目录（可能是人工恢复用的历史备份）
        # 绝不能被测试或卸载流程删除。
        $fixture = New-UninstallFixture -ScenarioName 'historical-backup' -WithLauncherMarker -WithLaunchDir
        $historicalBackup = Join-Path $testTempRoot 'dsh-launcher-backup-preexisting-manual'
        New-Item -ItemType Directory -Force -Path $historicalBackup | Out-Null
        $historicalSentinel = Join-Path $historicalBackup 'manual-restore-me.txt'
        [IO.File]::WriteAllText($historicalSentinel, 'do not delete', [Text.Encoding]::ASCII)
        $result = Invoke-Uninstall -Fixture $fixture

        Assert-Equal 0 $result.ExitCode "The uninstall must succeed. Output:`n$($result.Output)"
        Assert-True (Test-Path -LiteralPath $historicalSentinel) 'A pre-existing backup directory must survive the uninstall'
    }

    Write-Host "All $script:Passed uninstall behavior tests passed."
} finally {
    # 只清理测试作用域内的资源：testRoot 包含隔离 TEMP 与全部夹具。
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}

exit 0
