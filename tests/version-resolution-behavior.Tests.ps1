$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$resolver = Join-Path $repoRoot 'resolve-dsh-version.ps1'
$testRoot = Join-Path $env:TEMP ('dsh-version-resolution-tests-' + [guid]::NewGuid().ToString('N'))
$profileRoot = Join-Path $testRoot 'profile'
$runtimeRoot = Join-Path $profileRoot 'dsh-launch\runtime'
$fakeBin = Join-Path $testRoot 'fake-bin'
$npmLog = Join-Path $testRoot 'npm.log'
$script:Passed = 0

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    if ($Expected -ne $Actual) {
        throw "$Message (expected: $Expected, actual: $Actual)"
    }
}

function Assert-Match {
    param([string]$Actual, [string]$Pattern, [string]$Message)
    if ($Actual -notmatch $Pattern) {
        throw "$Message`nActual:`n$Actual"
    }
}

function Invoke-Test {
    param([string]$Name, [scriptblock]$Body)
    & $Body
    $script:Passed++
    Write-Host "PASS: $Name"
}

function Reset-TestRuntime {
    if (Test-Path -LiteralPath $runtimeRoot) {
        Remove-Item -LiteralPath $runtimeRoot -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $runtimeRoot | Out-Null
}

function Reset-NpmLog {
    [IO.File]::WriteAllText($npmLog, '', [Text.Encoding]::ASCII)
}

function Read-NpmLog {
    if (-not (Test-Path -LiteralPath $npmLog)) { return '' }
    return [IO.File]::ReadAllText($npmLog).Trim()
}

function New-TestRuntime {
    param(
        [Parameter(Mandatory = $true)][string]$Version,
        [switch]$Ready,
        [string]$ReadyVersion = '',
        [switch]$OmitEntrypoint
    )

    $dshRoot = Join-Path $runtimeRoot 'node_modules\@deepseek-ai\dsh'
    New-Item -ItemType Directory -Force -Path (Join-Path $dshRoot 'lib') | Out-Null
    [IO.File]::WriteAllText(
        (Join-Path $dshRoot 'package.json'),
        (@{ name = '@deepseek-ai/dsh'; version = $Version } | ConvertTo-Json -Compress),
        [Text.UTF8Encoding]::new($false)
    )
    if (-not $OmitEntrypoint) {
        [IO.File]::WriteAllText((Join-Path $dshRoot 'lib\bin.js'), '// fake dsh', [Text.Encoding]::ASCII)
    }
    if ($Ready -or $ReadyVersion) {
        $markerVersion = if ($ReadyVersion) { $ReadyVersion } else { $Version }
        [IO.File]::WriteAllText(
            (Join-Path $runtimeRoot 'dsh-runtime-ready.json'),
            (@{
                SchemaVersion = 2
                Version = $markerVersion
                ValidatedBy = 'npm-ls-all'
            } | ConvertTo-Json -Compress),
            [Text.UTF8Encoding]::new($false)
        )
    }
}

function Invoke-Resolver {
    param([switch]$PreferLocalRuntime)

    $previousPath = $env:PATH
    $previousProfile = $env:USERPROFILE
    $previousLog = $env:DSH_TEST_NPM_LOG
    try {
        $env:PATH = "$fakeBin;$previousPath"
        $env:USERPROFILE = $profileRoot
        $env:DSH_TEST_NPM_LOG = $npmLog
        $arguments = @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass',
            '-File', $resolver,
            '-RuntimeRoot', $runtimeRoot
        )
        if ($PreferLocalRuntime) { $arguments += '-PreferLocalRuntime' }
        $output = @(& powershell.exe @arguments 2>&1)
        return [pscustomobject]@{
            ExitCode = $LASTEXITCODE
            Output = [string]($output -join [Environment]::NewLine)
        }
    } finally {
        $env:PATH = $previousPath
        $env:USERPROFILE = $previousProfile
        $env:DSH_TEST_NPM_LOG = $previousLog
    }
}

New-Item -ItemType Directory -Force -Path $testRoot, $profileRoot, $fakeBin | Out-Null
try {
    [IO.File]::WriteAllText(
        (Join-Path $fakeBin 'npm.cmd'),
        "@echo off`r`necho %*>>`"%DSH_TEST_NPM_LOG%`"`r`necho {`"latest`":`"0.1.0-rc.9`",`"next`":`"0.1.0-rc.10`"}`r`nexit /b 0`r`n",
        [Text.Encoding]::ASCII
    )

    Invoke-Test 'prepared runtime wins without invoking npm' {
        Reset-TestRuntime
        Reset-NpmLog
        New-TestRuntime -Version '0.1.0-rc.8' -Ready

        $result = Invoke-Resolver -PreferLocalRuntime

        Assert-Equal 0 $result.ExitCode "Prepared resolution should succeed. Output:`n$($result.Output)"
        Assert-Equal '0.1.0-rc.8' $result.Output.Trim() 'Prepared version should be selected'
        Assert-Equal '' (Read-NpmLog) 'Prepared startup must not contact npm'
    }

    Invoke-Test 'installed runtime without marker is reused without invoking npm' {
        Reset-TestRuntime
        Reset-NpmLog
        New-TestRuntime -Version '0.1.0-rc.7'

        $result = Invoke-Resolver -PreferLocalRuntime

        Assert-Equal 0 $result.ExitCode "Installed resolution should succeed. Output:`n$($result.Output)"
        Assert-Equal '0.1.0-rc.7' $result.Output.Trim() 'Installed version should be selected for revalidation'
        Assert-Equal '' (Read-NpmLog) 'Local repair must not require registry discovery'
    }

    Invoke-Test 'mismatched ready marker falls back to the valid installed package' {
        Reset-TestRuntime
        Reset-NpmLog
        New-TestRuntime -Version '0.1.0-rc.7' -ReadyVersion '0.1.0-rc.8'

        $result = Invoke-Resolver -PreferLocalRuntime

        Assert-Equal 0 $result.ExitCode "Marker fallback should succeed. Output:`n$($result.Output)"
        Assert-Equal '0.1.0-rc.7' $result.Output.Trim() 'Invalid marker must not hide a repairable local package'
        Assert-Equal '' (Read-NpmLog) 'Repairable local metadata must not contact npm'
    }

    Invoke-Test 'invalid local installation falls back to published tags' {
        Reset-TestRuntime
        Reset-NpmLog
        New-TestRuntime -Version '0.1.0-rc.7' -OmitEntrypoint

        $result = Invoke-Resolver -PreferLocalRuntime

        Assert-Equal 0 $result.ExitCode "Registry fallback should succeed. Output:`n$($result.Output)"
        Assert-Equal '0.1.0-rc.10' $result.Output.Trim() 'Invalid local installation must fall back to npm'
        Assert-Match (Read-NpmLog) '^view @deepseek-ai/dsh dist-tags --json$' 'Fallback must query dist-tags'
    }

    Invoke-Test 'registry mode ignores a prepared runtime' {
        Reset-TestRuntime
        Reset-NpmLog
        New-TestRuntime -Version '0.1.0-rc.8' -Ready

        $result = Invoke-Resolver

        Assert-Equal 0 $result.ExitCode "Registry resolution should succeed. Output:`n$($result.Output)"
        Assert-Equal '0.1.0-rc.10' $result.Output.Trim() 'Explicit release discovery must use npm'
        Assert-Match (Read-NpmLog) '^view @deepseek-ai/dsh dist-tags --json$' 'Registry mode must query dist-tags'
    }

    Write-Host "All $script:Passed version resolution behavior tests passed."
} finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}

exit 0
