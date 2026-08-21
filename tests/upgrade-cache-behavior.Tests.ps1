$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$stateHelper = Join-Path $repoRoot 'dsh-launch-state.ps1'
$upgradeScript = Join-Path $repoRoot 'upgrade-dsh.ps1'
$testRoot = Join-Path $env:TEMP ('dsh-launcher-cache-tests-' + [guid]::NewGuid().ToString('N'))
$script:Passed = 0

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
        Assert-Match $outputText ([regex]::Escape($dshByMetadata)) 'The metadata-identified workspace should be reported'
        Assert-Match $outputText ([regex]::Escape($dshByDependency)) 'The dependency-identified workspace should be reported'
    }

    Invoke-Test 'explicit upgrade passes the registry-selected version to startup' {
        $fixtureRoot = Join-Path $testRoot 'upgrade-fixture'
        $fixtureLog = Join-Path $fixtureRoot 'start.log'
        $localAppData = Join-Path $fixtureRoot 'local-app-data'
        New-Item -ItemType Directory -Force -Path $fixtureRoot, $localAppData | Out-Null
        Copy-Item -LiteralPath $upgradeScript -Destination (Join-Path $fixtureRoot 'upgrade-dsh.ps1')
        [IO.File]::WriteAllText(
            (Join-Path $fixtureRoot 'resolve-dsh-version.ps1'),
            "Write-Output '0.1.0-rc.8'`r`n",
            [Text.Encoding]::ASCII
        )
        [IO.File]::WriteAllText(
            (Join-Path $fixtureRoot 'stop-dsh.ps1'),
            "exit 0`r`n",
            [Text.Encoding]::ASCII
        )
        [IO.File]::WriteAllText(
            (Join-Path $fixtureRoot 'dsh-launch-state.ps1'),
            "param([string]`$Action,[string]`$CacheRoot)`r`nexit 0`r`n",
            [Text.Encoding]::ASCII
        )
        [IO.File]::WriteAllText(
            (Join-Path $fixtureRoot 'start-background.ps1'),
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

        $previousLocalAppData = $env:LOCALAPPDATA
        $previousUpgradeLog = $env:DSH_TEST_UPGRADE_LOG
        try {
            $env:LOCALAPPDATA = $localAppData
            $env:DSH_TEST_UPGRADE_LOG = $fixtureLog
            $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass `
                -File (Join-Path $fixtureRoot 'upgrade-dsh.ps1') 2>&1
            Assert-True ($LASTEXITCODE -eq 0) "Upgrade fixture should succeed. Output:`n$($output -join [Environment]::NewLine)"
        } finally {
            $env:LOCALAPPDATA = $previousLocalAppData
            $env:DSH_TEST_UPGRADE_LOG = $previousUpgradeLog
        }

        $startCall = [IO.File]::ReadAllText($fixtureLog)
        Assert-Match $startCall '^VERSION=0\.1\.0-rc\.8;WAIT=True;TIMEOUT=900$' `
            'Upgrade must pass its registry-selected version to the synchronous startup coordinator'
    }

    Write-Host "All $script:Passed upgrade cache behavior tests passed."
} finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}

exit 0
