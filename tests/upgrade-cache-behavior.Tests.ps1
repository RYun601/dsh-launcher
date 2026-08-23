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

# Chinese status text is built from UTF-16 code units at runtime instead of
# being written as literals, keeping the test file parseable by PS 5.1.
function Get-UpgradeText {
    param([int[]]$CodeUnits)
    return (-join @($CodeUnits | ForEach-Object { [char]$_ }))
}

$script:InstallText = Get-UpgradeText @(0x6B63, 0x5728, 0x5B89, 0x88C5, 0x5168, 0x5C40, 0x20, 0x64, 0x73, 0x68, 0x20, 0x547D, 0x4EE4)                 # installing global dsh command
$script:UpgradeText = Get-UpgradeText @(0x6B63, 0x5728, 0x5347, 0x7EA7, 0x5168, 0x5C40, 0x20, 0x64, 0x73, 0x68, 0x20, 0x547D, 0x4EE4)                 # upgrading global dsh command
$script:ReadyText    = Get-UpgradeText @(0x5168, 0x5C40, 0x20, 0x64, 0x73, 0x68, 0x20, 0x5DF2, 0x5C31, 0x7EEA)                                       # global dsh ready
$script:CurrentText  = Get-UpgradeText @(0x5168, 0x5C40, 0x20, 0x64, 0x73, 0x68, 0x20, 0x5DF2, 0x662F, 0x6700, 0x65B0)                             # global dsh already current

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
    $startLog = Join-Path $Root 'start.log'
    New-Item -ItemType Directory -Force -Path $fakeBin, $appData, $localAppData | Out-Null

    Copy-Item -LiteralPath $upgradeScript -Destination (Join-Path $Root 'upgrade-dsh.ps1')
    Copy-Item -LiteralPath $versionHelper -Destination (Join-Path $Root 'dsh-version.ps1')
    [IO.File]::WriteAllText(
        (Join-Path $Root 'resolve-dsh-version.ps1'),
        "Write-Output '$ResolvedVersion'`r`n",
        [Text.Encoding]::ASCII
    )
    [IO.File]::WriteAllText(
        (Join-Path $Root 'stop-dsh.ps1'),
        "exit 0`r`n",
        [Text.Encoding]::ASCII
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
    [string]$Version
)
[IO.File]::WriteAllText(
    $env:DSH_TEST_UPGRADE_LOG,
    "VERSION=$Version;WAIT=$WaitForReady;TIMEOUT=$TimeoutSeconds",
    [Text.Encoding]::ASCII
)
exit 0
'@,
        [Text.Encoding]::ASCII
    )
    [IO.File]::WriteAllText(
        (Join-Path $fakeBin 'npm.cmd'),
        "@echo off`r`necho %*>>`"%DSH_TEST_NPM_LOG%`"`r`nexit /b 0`r`n",
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
        StartLog      = $startLog
        NpmLog        = $NpmLog
    }
}

function Invoke-UpgradeFixture {
    param([pscustomobject]$Fixture)

    $previousPath = $env:PATH
    $previousAppData = $env:APPDATA
    $previousLocalAppData = $env:LOCALAPPDATA
    $previousUpgradeLog = $env:DSH_TEST_UPGRADE_LOG
    $previousNpmLog = $env:DSH_TEST_NPM_LOG
    try {
        $env:PATH = "$($Fixture.FakeBin);$previousPath"
        $env:APPDATA = $Fixture.AppData
        $env:LOCALAPPDATA = $Fixture.LocalAppData
        $env:DSH_TEST_UPGRADE_LOG = $Fixture.StartLog
        $env:DSH_TEST_NPM_LOG = $Fixture.NpmLog
        $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $Fixture.Root 'upgrade-dsh.ps1') 2>&1
        return [pscustomobject]@{
            ExitCode = $LASTEXITCODE
            Output   = [string]($output -join [Environment]::NewLine)
        }
    } finally {
        $env:PATH = $previousPath
        $env:APPDATA = $previousAppData
        $env:LOCALAPPDATA = $previousLocalAppData
        $env:DSH_TEST_UPGRADE_LOG = $previousUpgradeLog
        $env:DSH_TEST_NPM_LOG = $previousNpmLog
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
        Assert-Match $result.Output ([regex]::Escape($script:InstallText)) 'Upgrade should report installing the global dsh command'
    }

    Invoke-Test 'explicit upgrade refreshes an outdated global dsh command' {
        $fixture = New-UpgradeFixture -Root (Join-Path $testRoot 'upgrade-old-global') `
            -NpmLog (Join-Path $testRoot 'upgrade-old-global-npm.log') `
            -GlobalDshVersion '0.1.0-rc.7'

        $result = Invoke-UpgradeFixture -Fixture $fixture

        Assert-True ($result.ExitCode -eq 0) "Upgrade fixture should succeed. Output:`n$($result.Output)"
        Assert-Match (Read-NpmLog $fixture.NpmLog) '^install -g @deepseek-ai/dsh@0\.1\.0-rc\.8$' `
            'Upgrade must refresh an outdated global dsh command'
        Assert-Match $result.Output ([regex]::Escape($script:UpgradeText)) 'Upgrade should report upgrading the global dsh command'
        Assert-Match $result.Output ([regex]::Escape($script:ReadyText)) 'Upgrade should confirm the refreshed global dsh command'
    }

    Invoke-Test 'explicit upgrade leaves a current global dsh command untouched' {
        $fixture = New-UpgradeFixture -Root (Join-Path $testRoot 'upgrade-current-global') `
            -NpmLog (Join-Path $testRoot 'upgrade-current-global-npm.log') `
            -GlobalDshVersion '0.1.0-rc.8'

        $result = Invoke-UpgradeFixture -Fixture $fixture

        Assert-True ($result.ExitCode -eq 0) "Upgrade fixture should succeed. Output:`n$($result.Output)"
        Assert-Equal '' (Read-NpmLog $fixture.NpmLog) 'A current global dsh must not trigger npm install'
        Assert-Match $result.Output ([regex]::Escape($script:CurrentText)) 'Upgrade should report the global dsh command is already current'
    }

    Write-Host "All $script:Passed upgrade cache behavior tests passed."
} finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}

exit 0
