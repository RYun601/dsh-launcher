$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$stateHelper = Join-Path $repoRoot 'dsh-launch-state.ps1'
$upgradeScript = Join-Path $repoRoot 'upgrade-dsh.ps1'
$versionHelper = Join-Path $repoRoot 'dsh-version.ps1'
$testRoot = Join-Path $env:TEMP ('dsh-launcher-cache-tests-' + [guid]::NewGuid().ToString('N'))
$script:Passed = 0

function Read-NpmLog {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    return [IO.File]::ReadAllText($Path).Trim()
}

# Build an isolated upgrade fixture: upgrade-dsh.ps1 with stubbed dependency
# scripts, a fake npm that records its arguments, and an optional global dsh
# package under an isolated APPDATA. The test's real global npm install must
# never be touched, so APPDATA is always redirected into the fixture.
function New-UpgradeFixture {
    param(
        [string]$Root,
        [string]$NpmLog,
        [string]$GlobalDshVersion = '',
        [string]$ResolvedVersion = '0.1.0-rc.8'
    )

    $fakeBin = Join-Path $Root 'fake-bin'
    $appData = Join-Path $Root 'app-data'
    $localAppData = Join-Path $Root 'local-app-data'
    # upgrade-dsh.ps1 treats $env:USERPROFILE\dsh-launch as the launcher data
    # directory; the fixture must redirect USERPROFILE too, or the test would
    # pollute the real user environment.
    $userProfile = Join-Path $Root 'user-profile'
    $startLog = Join-Path $Root 'start.log'
    $attemptsLog = Join-Path $Root 'start-attempts.log'
    New-Item -ItemType Directory -Force -Path $fakeBin, $appData, $localAppData, $userProfile | Out-Null
    [IO.File]::WriteAllText($attemptsLog, '', [Text.Encoding]::ASCII)

    Copy-Item -LiteralPath $upgradeScript -Destination (Join-Path $Root 'upgrade-dsh.ps1')
    Copy-Item -LiteralPath $versionHelper -Destination (Join-Path $Root 'dsh-version.ps1')
    Copy-Item -LiteralPath (Join-Path $repoRoot 'dsh-node-version.ps1') -Destination (Join-Path $Root 'dsh-node-version.ps1')
    Copy-Item -LiteralPath (Join-Path $repoRoot 'dsh-runtime-layout.ps1') -Destination (Join-Path $Root 'dsh-runtime-layout.ps1')
    Copy-Item -LiteralPath (Join-Path $repoRoot 'dsh-maintenance-lock.ps1') -Destination (Join-Path $Root 'dsh-maintenance-lock.ps1')
    [IO.File]::WriteAllText(
        (Join-Path $Root 'resolve-dsh-version.ps1'),
        "Write-Output '$ResolvedVersion'`r`n",
        [Text.Encoding]::ASCII
    )
    [IO.File]::WriteAllText(
        (Join-Path $Root 'stop-dsh.ps1'),
        "[IO.File]::WriteAllText(`$env:DSH_TEST_STOP_MARKER, 'STOPPED', [Text.Encoding]::ASCII)`r`nexit 0`r`n",
        [Text.Encoding]::ASCII
    )
    [IO.File]::WriteAllText(
        (Join-Path $Root 'run-dsh.ps1'),
        @'
param([string]$Version, [string]$RuntimeRoot, [switch]$PrepareOnly)
$dshRoot = Join-Path $RuntimeRoot 'node_modules\@deepseek-ai\dsh'
New-Item -ItemType Directory -Force -Path (Join-Path $dshRoot 'lib') | Out-Null
[IO.File]::WriteAllText((Join-Path $dshRoot 'lib\bin.js'), ('#!/usr/bin/env node' + (';' * 2048)), [Text.Encoding]::ASCII)
[IO.File]::WriteAllText((Join-Path $dshRoot 'package.json'), (@{name='@deepseek-ai/dsh';version=$Version}|ConvertTo-Json), [Text.Encoding]::ASCII)
[IO.File]::WriteAllText((Join-Path $RuntimeRoot 'dsh-runtime-ready.json'), (@{SchemaVersion=2;Version=$Version;ValidatedBy='npm-ls-all'}|ConvertTo-Json), [Text.UTF8Encoding]::new($false))
exit 0
'@,
        [Text.UTF8Encoding]::new($false)
    )
    [IO.File]::WriteAllText(
        (Join-Path $Root 'dsh-launch-state.ps1'),
        "param([string]`$Action,[string]`$CacheRoot)`r`nexit 0`r`n",
        [Text.Encoding]::ASCII
    )
    [IO.File]::WriteAllText(
        (Join-Path $Root 'start-background.ps1'),
        @'
param(
    [switch]$WaitForReady,
    [int]$TimeoutSeconds,
     [string]$Version,
     [string]$RuntimeRoot
)
[IO.File]::WriteAllText(
    $env:DSH_TEST_UPGRADE_LOG,
    "VERSION=$Version;WAIT=$WaitForReady;TIMEOUT=$TimeoutSeconds",
    [Text.Encoding]::ASCII
)
[IO.File]::AppendAllText(
    $env:DSH_TEST_UPGRADE_ATTEMPTS_LOG,
    "VERSION=$Version;ROOT=$RuntimeRoot`r`n",
    [Text.Encoding]::ASCII
)
$launchLog = Join-Path $env:USERPROFILE 'dsh-launch\dsh-background.log'
New-Item -ItemType Directory -Force -Path (Split-Path $launchLog -Parent) | Out-Null
Add-Content -LiteralPath $launchLog -Encoding UTF8 -Value ('===== fake startup ' + $Version + ' =====')
Add-Content -LiteralPath $launchLog -Encoding UTF8 -Value "DSH version: $Version"
$exitCode = 0
if ($env:DSH_TEST_START_FAIL_VERSION -and $Version -eq $env:DSH_TEST_START_FAIL_VERSION -and -not (Test-Path -LiteralPath $env:DSH_TEST_PLUGIN_REMOVE_MARKER)) {
    Add-Content -LiteralPath $launchLog -Encoding UTF8 -Value "Error: dsh: plugin tree failed to load"
    Add-Content -LiteralPath $launchLog -Encoding UTF8 -Value "Error: failed to import loader entry vision-toolkit (@dsh-external/dsh-vision-toolkit): The requested module '@deepseek-ai/dsh-settings' does not provide an export named 'settingsNamespace'"
    Add-Content -LiteralPath $launchLog -Encoding UTF8 -Value "Error: failed to import loader entry better-sidebar (dsh-better-sidebar): The requested module '@deepseek-ai/dsh-settings' does not provide an export named 'settingsNamespace'"
    $exitCode = 1
}
exit $exitCode
'@,
        [Text.Encoding]::ASCII
    )
    [IO.File]::WriteAllText(
        (Join-Path $fakeBin 'npm.cmd'),
        "@echo off`r`necho %*>>`"%DSH_TEST_NPM_LOG%`"`r`nexit /b 0`r`n",
        [Text.Encoding]::ASCII
    )
    [IO.File]::WriteAllText(
        (Join-Path $fakeBin 'node.cmd'),
        "@echo off`r`nif defined DSH_TEST_NODE_LOG echo %*>>`"%DSH_TEST_NODE_LOG%`"`r`necho %*| findstr /i /c:`" plugin `" >nul`r`nif not errorlevel 1 if defined DSH_TEST_PLUGIN_REMOVE_MARKER echo removed>`"%DSH_TEST_PLUGIN_REMOVE_MARKER%`"`r`nif defined DSH_TEST_NODE_VERSION (echo %DSH_TEST_NODE_VERSION%) else (echo v22.19.0)`r`nexit /b 0`r`n",
        [Text.Encoding]::ASCII
    )

    if ($GlobalDshVersion) {
        $globalPkgDir = Join-Path $appData 'npm\node_modules\@deepseek-ai\dsh'
        New-Item -ItemType Directory -Force -Path $globalPkgDir | Out-Null
        [IO.File]::WriteAllText(
            (Join-Path $globalPkgDir 'package.json'),
            (@{ name = '@deepseek-ai/dsh'; version = $GlobalDshVersion } | ConvertTo-Json -Compress),
            [Text.Encoding]::ASCII
        )
    }

    return [pscustomobject]@{
        Root          = $Root
        FakeBin       = $fakeBin
        AppData       = $appData
        LocalAppData  = $localAppData
        UserProfile   = $userProfile
        StartLog      = $startLog
        AttemptsLog   = $attemptsLog
        NpmLog        = $NpmLog
        StopMarker    = Join-Path $Root 'stop.log'
    }
}

function Invoke-UpgradeFixture {
    param(
        [pscustomobject]$Fixture,
        [string]$NodeVersion = '',
        [string]$StartFailVersion = '',
        [string]$PromptAnswer = '',
        [string]$MaintenanceTimeout = '30000'
    )

    $previousPath = $env:PATH
    $previousAppData = $env:APPDATA
    $previousLocalAppData = $env:LOCALAPPDATA
    $previousUserProfile = $env:USERPROFILE
    $previousUpgradeLog = $env:DSH_TEST_UPGRADE_LOG
    $previousAttemptsLog = $env:DSH_TEST_UPGRADE_ATTEMPTS_LOG
    $previousStartFailVersion = $env:DSH_TEST_START_FAIL_VERSION
    $previousNpmLog = $env:DSH_TEST_NPM_LOG
    $previousStopMarker = $env:DSH_TEST_STOP_MARKER
    $previousNodeVersion = $env:DSH_TEST_NODE_VERSION
    $previousNodeLog = $env:DSH_TEST_NODE_LOG
    $previousPluginRemoveMarker = $env:DSH_TEST_PLUGIN_REMOVE_MARKER
    $previousMaintenanceTimeout = $env:DSH_TEST_MAINTENANCE_TIMEOUT_MS
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $env:PATH = "$($Fixture.FakeBin);$previousPath"
        $env:APPDATA = $Fixture.AppData
        $env:LOCALAPPDATA = $Fixture.LocalAppData
        $env:USERPROFILE = $Fixture.UserProfile
        $env:DSH_TEST_UPGRADE_LOG = $Fixture.StartLog
        $env:DSH_TEST_UPGRADE_ATTEMPTS_LOG = $Fixture.AttemptsLog
        $env:DSH_TEST_START_FAIL_VERSION = $StartFailVersion
        $env:DSH_TEST_NPM_LOG = $Fixture.NpmLog
        $env:DSH_TEST_STOP_MARKER = $Fixture.StopMarker
        $env:DSH_TEST_NODE_VERSION = $NodeVersion
        $env:DSH_TEST_MAINTENANCE_TIMEOUT_MS = $MaintenanceTimeout
        $nodeLog = Join-Path $Fixture.Root 'node.log'
        $pluginRemoveMarker = Join-Path $Fixture.Root 'plugin-removed.marker'
        $env:DSH_TEST_NODE_LOG = $nodeLog
        $env:DSH_TEST_PLUGIN_REMOVE_MARKER = $pluginRemoveMarker
        # 子进程的 stderr（如预期的互斥超时）不能以 NativeCommandError 终止父测试。
        $ErrorActionPreference = 'Continue'
        if ($PromptAnswer) {
            $output = @($PromptAnswer) | & powershell.exe -NoProfile -ExecutionPolicy Bypass `
                -File (Join-Path $Fixture.Root 'upgrade-dsh.ps1') 2>&1
        } else {
            $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass `
                -File (Join-Path $Fixture.Root 'upgrade-dsh.ps1') 2>&1
        }
        $ErrorActionPreference = $previousErrorActionPreference
        return [pscustomobject]@{
            ExitCode = $LASTEXITCODE
            Output   = [string]($output -join [Environment]::NewLine)
        }
    } finally {
        $env:PATH = $previousPath
        $env:APPDATA = $previousAppData
        $env:LOCALAPPDATA = $previousLocalAppData
        $env:USERPROFILE = $previousUserProfile
        $env:DSH_TEST_UPGRADE_LOG = $previousUpgradeLog
        $env:DSH_TEST_UPGRADE_ATTEMPTS_LOG = $previousAttemptsLog
        $env:DSH_TEST_START_FAIL_VERSION = $previousStartFailVersion
        $env:DSH_TEST_NPM_LOG = $previousNpmLog
        $env:DSH_TEST_STOP_MARKER = $previousStopMarker
        $env:DSH_TEST_NODE_VERSION = $previousNodeVersion
        $env:DSH_TEST_NODE_LOG = $previousNodeLog
        $env:DSH_TEST_PLUGIN_REMOVE_MARKER = $previousPluginRemoveMarker
        $env:DSH_TEST_MAINTENANCE_TIMEOUT_MS = $previousMaintenanceTimeout
        $ErrorActionPreference = $previousErrorActionPreference
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

function Assert-NotMatch {
    param([string]$Actual, [string]$Pattern, [string]$Message)

    if ($Actual -match $Pattern) {
        throw "$Message`nActual output:`n$Actual"
    }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)

    if ($Expected -ne $Actual) {
        throw "$Message (expected: $Expected, actual: $Actual)"
    }
}

function Invoke-Test {
    param([string]$Name, [scriptblock]$Body)

    & $Body
    $script:Passed++
    Write-Host "PASS: $Name"
}

function New-NpxWorkspace {
    param(
        [string]$Path,
        [string]$PackageName,
        [switch]$UseNpxMetadata
    )

    New-Item -ItemType Directory -Force -Path (Join-Path $Path 'node_modules\example') | Out-Null
    Set-Content -LiteralPath (Join-Path $Path 'node_modules\example\sentinel.txt') -Value $PackageName -Encoding UTF8

    $package = if ($UseNpxMetadata) {
        @{ dependencies = @{}; _npx = @{ packages = @($PackageName) } }
    } else {
        @{ dependencies = @{ $PackageName = '1.0.0' } }
    }
    $package | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $Path 'package.json') -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $Path 'package-lock.json') -Value '{}' -Encoding UTF8
}

function New-FakeReadyRuntimeAt {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Version
    )

    $dshRoot = Join-Path (Join-Path (Join-Path $Root 'node_modules') '@deepseek-ai') 'dsh'
    New-Item -ItemType Directory -Force -Path (Join-Path $dshRoot 'lib') | Out-Null
    $fakeEntry = "#!/usr/bin/env node`r`n" + (('// fake dsh entrypoint`r`n') * 80)
    [IO.File]::WriteAllText((Join-Path $dshRoot 'lib\bin.js'), $fakeEntry, [Text.Encoding]::ASCII)
    [IO.File]::WriteAllText(
        (Join-Path $dshRoot 'package.json'),
        (@{ name = '@deepseek-ai/dsh'; version = $Version } | ConvertTo-Json),
        [Text.Encoding]::ASCII
    )
    [IO.File]::WriteAllText(
        (Join-Path $Root 'dsh-runtime-ready.json'),
        (@{ SchemaVersion = 2; Version = $Version; ValidatedBy = 'npm-ls-all' } | ConvertTo-Json),
        [Text.UTF8Encoding]::new($false)
    )
}

function New-FakeStubRuntimeAt {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Version
    )

    $dshRoot = Join-Path (Join-Path (Join-Path $Root 'node_modules') '@deepseek-ai') 'dsh'
    New-Item -ItemType Directory -Force -Path (Join-Path $dshRoot 'lib') | Out-Null
    [IO.File]::WriteAllText((Join-Path $dshRoot 'lib\bin.js'), 'entry', [Text.Encoding]::ASCII)
    [IO.File]::WriteAllText(
        (Join-Path $dshRoot 'package.json'),
        (@{ name = '@deepseek-ai/dsh'; version = $Version } | ConvertTo-Json),
        [Text.Encoding]::ASCII
    )
    [IO.File]::WriteAllText(
        (Join-Path $Root 'dsh-runtime-ready.json'),
        (@{ SchemaVersion = 2; Version = $Version; ValidatedBy = 'npm-ls-all' } | ConvertTo-Json),
        [Text.UTF8Encoding]::new($false)
    )
}

New-Item -ItemType Directory -Force -Path $testRoot | Out-Null
try {
    Invoke-Test 'clears complete DSH npx workspaces and preserves unrelated workspaces' {
        $cacheRoot = Join-Path $testRoot 'npm-cache\_npx'
        $dshByMetadata = Join-Path $cacheRoot 'dsh-metadata'
        $dshByDependency = Join-Path $cacheRoot 'dsh-dependency'
        $otherWorkspace = Join-Path $cacheRoot 'other-package'

        New-NpxWorkspace -Path $dshByMetadata -PackageName '@deepseek-ai/dsh' -UseNpxMetadata
        New-NpxWorkspace -Path $dshByDependency -PackageName '@deepseek-ai/dsh'
        New-NpxWorkspace -Path $otherWorkspace -PackageName 'unrelated-tool' -UseNpxMetadata

        $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $stateHelper `
            -Action ClearDshNpxWorkspaces -CacheRoot $cacheRoot 2>&1
        Assert-True ($LASTEXITCODE -eq 0) "Cleanup helper should succeed. Output:`n$($output -join [Environment]::NewLine)"

        Assert-True (-not (Test-Path -LiteralPath $dshByMetadata)) 'A DSH workspace identified by _npx metadata must be fully removed'
        Assert-True (-not (Test-Path -LiteralPath $dshByDependency)) 'A DSH workspace identified by dependencies must be fully removed'
        Assert-True (Test-Path -LiteralPath (Join-Path $otherWorkspace 'node_modules\example\sentinel.txt')) 'An unrelated npx workspace must remain intact'

        $outputText = [string]($output -join [Environment]::NewLine)
        Assert-Match $outputText 'dsh-metadata' 'The metadata-identified workspace should be reported'
        Assert-Match $outputText 'dsh-dependency' 'The dependency-identified workspace should be reported'
    }

    Invoke-Test 'explicit upgrade passes the registry-selected version to startup and installs a missing global dsh' {
        $fixture = New-UpgradeFixture -Root (Join-Path $testRoot 'upgrade-fixture') `
            -NpmLog (Join-Path $testRoot 'upgrade-npm.log')

        $result = Invoke-UpgradeFixture -Fixture $fixture

        Assert-True ($result.ExitCode -eq 0) "Upgrade fixture should succeed. Output:`n$($result.Output)"
        $startCall = [IO.File]::ReadAllText($fixture.StartLog)
        Assert-Match $startCall '^VERSION=0\.1\.0-rc\.8;WAIT=True;TIMEOUT=900$' `
            'Upgrade must pass its registry-selected version to the synchronous startup coordinator'
        Assert-Match (Read-NpmLog $fixture.NpmLog) '^install -g @deepseek-ai/dsh@0\.1\.0-rc\.8$' `
            'Upgrade must install the missing global dsh command'
        Assert-True (Test-Path -LiteralPath (Join-Path $fixture.UserProfile 'dsh-launch\runtime-current.json')) `
            'Launcher state must stay inside the isolated fixture USERPROFILE'
        $fixtureRuntimes = @(Get-ChildItem -LiteralPath (Join-Path $fixture.UserProfile 'dsh-launch\runtime-versions') `
            -Directory -ErrorAction SilentlyContinue)
        Assert-True ($fixtureRuntimes.Count -ge 1) 'The fixture must create candidates only inside its isolated USERPROFILE'
    }

    Invoke-Test 'explicit upgrade refreshes an outdated global dsh command' {
        $fixture = New-UpgradeFixture -Root (Join-Path $testRoot 'upgrade-old-global') `
            -NpmLog (Join-Path $testRoot 'upgrade-old-global-npm.log') `
            -GlobalDshVersion '0.1.0-rc.7'

        $result = Invoke-UpgradeFixture -Fixture $fixture

        Assert-True ($result.ExitCode -eq 0) "Upgrade fixture should succeed. Output:`n$($result.Output)"
        Assert-Match (Read-NpmLog $fixture.NpmLog) '^install -g @deepseek-ai/dsh@0\.1\.0-rc\.8$' `
            'Upgrade must refresh an outdated global dsh command'
    }

    Invoke-Test 'explicit upgrade leaves a current global dsh command untouched' {
        $fixture = New-UpgradeFixture -Root (Join-Path $testRoot 'upgrade-current-global') `
            -NpmLog (Join-Path $testRoot 'upgrade-current-global-npm.log') `
            -GlobalDshVersion '0.1.0-rc.8'

        $result = Invoke-UpgradeFixture -Fixture $fixture

        Assert-True ($result.ExitCode -eq 0) "Upgrade fixture should succeed. Output:`n$($result.Output)"
        Assert-Equal '' (Read-NpmLog $fixture.NpmLog) 'A current global dsh must not trigger npm install'
    }

    Invoke-Test 'upgrade skips preparation and service restart when the current runtime is already latest' {
        $fixture = New-UpgradeFixture -Root (Join-Path $testRoot 'upgrade-already-latest') `
            -NpmLog (Join-Path $testRoot 'upgrade-already-latest-npm.log')
        $launchDir = Join-Path $fixture.UserProfile 'dsh-launch'
        $currentDir = Join-Path $launchDir 'runtime'
        New-FakeReadyRuntimeAt -Root $currentDir -Version '0.1.0-rc.8'
        $pointer = @{
            SchemaVersion = 1
            Current = @{ Path = 'runtime'; Version = '0.1.0-rc.8' }
            Previous = $null
        }
        [IO.File]::WriteAllText(
            (Join-Path $launchDir 'runtime-current.json'),
            ($pointer | ConvertTo-Json -Depth 5),
            [Text.UTF8Encoding]::new($false)
        )

        $result = Invoke-UpgradeFixture -Fixture $fixture

        Assert-Equal 0 $result.ExitCode "An already-latest runtime should make upgrade a no-op. Output:`n$($result.Output)"
        Assert-Match $result.Output 'already' 'The no-op result must be explicit'
        Assert-True (-not (Test-Path -LiteralPath $fixture.StopMarker)) 'A no-op upgrade must not stop the service'
        Assert-True (-not (Test-Path -LiteralPath $fixture.StartLog)) 'A no-op upgrade must not restart the service'
        Assert-Equal '' (Read-NpmLog $fixture.NpmLog) 'A no-op upgrade must not install or upgrade global dsh'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $launchDir 'runtime-versions'))) 'A no-op upgrade must not prepare a candidate runtime'
    }

    Invoke-Test 'candidate failure rolls back through the ready legacy runtime and clears the transaction' {
        $fixture = New-UpgradeFixture -Root (Join-Path $testRoot 'upgrade-rollback') `
            -NpmLog (Join-Path $testRoot 'upgrade-rollback-npm.log') `
            -ResolvedVersion '0.1.2-alpha.3'
        $launchDir = Join-Path $fixture.UserProfile 'dsh-launch'
        $versionsDir = Join-Path $launchDir 'runtime-versions'
        $legacyDir = Join-Path $launchDir 'runtime'
        $stubDir = Join-Path $versionsDir ('runtime-0.1.0-rc.6-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $legacyDir, $stubDir | Out-Null
        New-FakeStubRuntimeAt -Root $stubDir -Version '0.1.0-rc.6'
        New-FakeReadyRuntimeAt -Root $legacyDir -Version '0.1.0-rc.7'
        $pointer = @{
            SchemaVersion = 1
            Current   = @{ Path = (Join-Path 'runtime-versions' (Split-Path $stubDir -Leaf)); Version = '0.1.0-rc.6' }
            Previous = $null
        }
        [IO.File]::WriteAllText(
            (Join-Path $launchDir 'runtime-current.json'),
            ($pointer | ConvertTo-Json -Depth 5),
            [Text.UTF8Encoding]::new($false)
        )

        $result = Invoke-UpgradeFixture -Fixture $fixture -StartFailVersion '0.1.2-alpha.3'

        Assert-Equal 1 $result.ExitCode "A failed candidate must propagate the candidate exit code. Output:`n$($result.Output)"
        Assert-Match $result.Output '\[WARN\].*0\.1\.0-rc\.6' 'The upgrade must warn that the current runtime is not ready'
        Assert-Match $result.Output '0\.1\.0-rc\.7' 'The rollback must restore the ready legacy runtime'
        $attempts = [IO.File]::ReadAllText($fixture.AttemptsLog)
        Assert-Match $attempts '^VERSION=0\.1\.2-alpha\.3;' 'The candidate must be started once'
        Assert-Match $attempts '(?m)^VERSION=0\.1\.0-rc\.7;' 'The legacy runtime must be attempted for rollback'
        Assert-NotMatch $attempts 'VERSION=0\.1\.0-rc\.6' 'A stub current runtime must never be used for rollback'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $launchDir 'runtime-upgrade.json'))) `
            'A failed upgrade must clear its transaction'
        Assert-True (Test-Path -LiteralPath (Join-Path $launchDir 'runtime-current.json')) `
            'The pointer must remain intact after a failed upgrade'
        # 回退指针一致性：恢复成功后活动指针必须同步到恢复版本，
        # 否则下一次普通启动不会复用恢复出来的运行时。
        $syncedPointer = Get-Content -LiteralPath (Join-Path $launchDir 'runtime-current.json') -Raw | ConvertFrom-Json
        Assert-Equal '0.1.0-rc.7' ([string]$syncedPointer.Current.Version) `
            'The active pointer must be re-pointed at the restored legacy runtime'
        Assert-Equal 'runtime' ([string]$syncedPointer.Current.Path) `
            'The restored legacy runtime must be recorded as a relative pointer path'
    }

    Invoke-Test 'a second upgrade fails fast while the maintenance lock is held by another transaction' {
        # R9：两个升级（或升级与覆盖安装/自更新/卸载）必须互斥，不能交错提交。
        $fixture = New-UpgradeFixture -Root (Join-Path $testRoot 'upgrade-mutex') `
            -NpmLog (Join-Path $testRoot 'upgrade-mutex-npm.log')
        . (Join-Path $repoRoot 'dsh-maintenance-lock.ps1')
        $holderMutex = Enter-DshMaintenanceLock -LaunchRoot (Join-Path $fixture.UserProfile 'dsh-launch') `
            -TimeoutMilliseconds 200
        try {
            $result = Invoke-UpgradeFixture -Fixture $fixture -MaintenanceTimeout '500'
            Assert-Equal 1 $result.ExitCode 'A blocked upgrade must fail with a nonzero exit code'
            Assert-Match $result.Output 'maintenance lock' 'The failure must name the launcher maintenance lock'
            Assert-True (-not (Test-Path -LiteralPath $fixture.StopMarker)) `
                'A blocked upgrade must not stop the service'
            Assert-True (-not (Test-Path -LiteralPath $fixture.StartLog)) `
                'A blocked upgrade must not restart the service'
            Assert-True (-not (Test-Path -LiteralPath (Join-Path $fixture.UserProfile 'dsh-launch\runtime-upgrade.json'))) `
                'A blocked upgrade must not write its own transaction record'
        } finally {
            Exit-DshMaintenanceLock -Mutex $holderMutex
        }

        # 锁释放后，同一安装上的升级必须可以正常完成。
        $afterRelease = Invoke-UpgradeFixture -Fixture $fixture
        Assert-Equal 0 $afterRelease.ExitCode "An upgrade must succeed once the maintenance lock is free. Output:`n$($afterRelease.Output)"
    }

    Invoke-Test 'confirmed incompatible plugins are removed and the candidate startup is retried' {
        $fixture = New-UpgradeFixture -Root (Join-Path $testRoot 'upgrade-plugin-repair') `
            -NpmLog (Join-Path $testRoot 'upgrade-plugin-repair-npm.log') `
            -ResolvedVersion '0.1.2-alpha.3'

        $result = Invoke-UpgradeFixture -Fixture $fixture -StartFailVersion '0.1.2-alpha.3' -PromptAnswer 'Y'

        Assert-Equal 0 $result.ExitCode "A confirmed plugin repair should allow the upgrade to succeed. Output:`n$($result.Output)"
        Assert-Match $result.Output 'dsh-vision-toolkit' 'The prompt must identify the incompatible vision plugin'
        Assert-Match $result.Output 'dsh-better-sidebar' 'The prompt must identify the incompatible sidebar plugin'
        Assert-True (Test-Path -LiteralPath (Join-Path $fixture.Root 'plugin-removed.marker')) 'A confirmed repair must invoke the target runtime plugin removal command'
        $nodeLog = Read-NpmLog (Join-Path $fixture.Root 'node.log')
        Assert-Match $nodeLog 'plugin .*--profile web remove .*@dsh-external/dsh-vision-toolkit' 'The repair must remove the vision plugin from the web profile'
        Assert-Match $nodeLog 'plugin .*--profile web remove .*dsh-better-sidebar' 'The repair must remove the sidebar plugin from the web profile'
        $attempts = [IO.File]::ReadAllText($fixture.AttemptsLog)
        Assert-Match $attempts '(?ms)^VERSION=0\.1\.2-alpha\.3;.*\r?\nVERSION=0\.1\.2-alpha\.3;' 'The candidate must be retried after incompatible plugins are removed'
        Assert-Match $result.Output '0\.1\.2-alpha\.3' 'The repaired candidate must be committed after the retry'
    }

    Invoke-Test 'declining incompatible plugin removal preserves the plugins and rolls back' {
        $fixture = New-UpgradeFixture -Root (Join-Path $testRoot 'upgrade-plugin-decline') `
            -NpmLog (Join-Path $testRoot 'upgrade-plugin-decline-npm.log') `
            -ResolvedVersion '0.1.2-alpha.3'

        $result = Invoke-UpgradeFixture -Fixture $fixture `
            -StartFailVersion '0.1.2-alpha.3' -PromptAnswer 'N'

        Assert-Equal 1 $result.ExitCode "Declining plugin removal must retain the existing rollback behavior. Output:`n$($result.Output)"
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $fixture.Root 'plugin-removed.marker'))) 'Declining the prompt must not remove any plugin'
        $attempts = [IO.File]::ReadAllText($fixture.AttemptsLog)
        Assert-NotMatch $attempts '(?ms)^VERSION=0\.1\.2-alpha\.3;.*\r?\nVERSION=0\.1\.2-alpha\.3;' 'Declining the prompt must not retry the candidate'
    }

    Invoke-Test 'explicit upgrade aborts without stopping the service when the target version cannot be resolved' {
        $fixture = New-UpgradeFixture -Root (Join-Path $testRoot 'upgrade-unresolvable') `
            -NpmLog (Join-Path $testRoot 'upgrade-unresolvable-npm.log') `
            -ResolvedVersion ''

        $result = Invoke-UpgradeFixture -Fixture $fixture

        Assert-Equal 1 $result.ExitCode "An unresolvable target version must abort the upgrade. Output:`n$($result.Output)"
        Assert-Match $result.Output 'aborted' 'The abort message must be explicit'
        Assert-True (-not (Test-Path -LiteralPath $fixture.StopMarker)) 'The upgrade must not stop the service before resolving its target version'
        Assert-True (-not (Test-Path -LiteralPath $fixture.StartLog)) 'The upgrade must not restart startup when its target is unresolved'
    }

    Invoke-Test 'explicit upgrade aborts on a malformed resolved target version' {
        $fixture = New-UpgradeFixture -Root (Join-Path $testRoot 'upgrade-malformed') `
            -NpmLog (Join-Path $testRoot 'upgrade-malformed-npm.log') `
            -ResolvedVersion 'not-a-semver!!'

        $result = Invoke-UpgradeFixture -Fixture $fixture

        Assert-Equal 1 $result.ExitCode "A malformed target version must abort the upgrade. Output:`n$($result.Output)"
        Assert-Match $result.Output 'aborted' 'The abort message must be explicit'
        Assert-True (-not (Test-Path -LiteralPath $fixture.StopMarker)) 'The upgrade must not stop the service for an invalid target version'
    }

    Invoke-Test 'explicit upgrade fails fast when the local Node.js does not meet the requirement' {
        $fixture = New-UpgradeFixture -Root (Join-Path $testRoot 'upgrade-old-node') `
            -NpmLog (Join-Path $testRoot 'upgrade-old-node-npm.log')

        $result = Invoke-UpgradeFixture -Fixture $fixture -NodeVersion 'v18.19.0'

        Assert-Equal 1 $result.ExitCode "An unsupported Node.js must abort the upgrade. Output:`n$($result.Output)"
        Assert-Match $result.Output 'v18\.19\.0' 'The error must report the current Node.js version'
        Assert-Match $result.Output '\^22\.19\.0' 'The error must state the required version range'
        Assert-True (-not (Test-Path -LiteralPath $fixture.StopMarker)) 'The upgrade must not stop the service on an unsupported Node.js'
    }

    Write-Host "All $script:Passed upgrade cache behavior tests passed."
} finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}

exit 0
