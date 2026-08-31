$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$testRoot = Join-Path $env:TEMP ('dsh-runtime-layout-tests-' + [guid]::NewGuid().ToString('N'))
$launchRoot = Join-Path $testRoot 'profile\dsh-launch'
$helper = Join-Path $repoRoot 'dsh-runtime-layout.ps1'
$script:Passed = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    if ($Expected -ne $Actual) { throw "$Message (expected: $Expected, actual: $Actual)" }
}

function Assert-PathEqual {
    param([string]$Expected, [string]$Actual, [string]$Message)
    $expectedFull = [IO.Path]::GetFullPath($Expected).TrimEnd('\')
    $actualFull = [IO.Path]::GetFullPath($Actual).TrimEnd('\')
    if (-not [string]::Equals($expectedFull, $actualFull, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Message (expected: $expectedFull, actual: $actualFull)"
    }
}

function Assert-Throws {
    param([scriptblock]$Body, [string]$Message)
    try {
        & $Body
    } catch {
        return
    }
    throw $Message
}

function Invoke-Test {
    param([string]$Name, [scriptblock]$Body)
    & $Body
    $script:Passed++
    Write-Host "PASS: $Name"
}

function New-FakeReadyRuntime {
    param([string]$Root, [string]$Version)
    $dshRoot = Join-Path $Root 'node_modules\@deepseek-ai\dsh'
    New-Item -ItemType Directory -Force -Path (Join-Path $dshRoot 'lib') | Out-Null
    [IO.File]::WriteAllText((Join-Path $dshRoot 'lib\bin.js'), 'entry', [Text.Encoding]::ASCII)
    [IO.File]::WriteAllText(
        (Join-Path $dshRoot 'package.json'),
        (@{ name = '@deepseek-ai/dsh'; version = $Version } | ConvertTo-Json -Compress),
        [Text.Encoding]::ASCII
    )
    [IO.File]::WriteAllText(
        (Join-Path $Root 'dsh-runtime-ready.json'),
        (@{ SchemaVersion = 2; Version = $Version; ValidatedBy = 'npm-ls-all' } | ConvertTo-Json -Compress),
        [Text.UTF8Encoding]::new($false)
    )
}

New-Item -ItemType Directory -Force -Path $launchRoot | Out-Null
try {
    Invoke-Test 'registers the legacy runtime without moving it' {
        New-FakeReadyRuntime -Root (Join-Path $launchRoot 'runtime') -Version '0.1.0-rc.7'
        . $helper
        $layout = Get-DshRuntimeLayout -LaunchRoot $launchRoot
        $pointer = Initialize-DshRuntimePointer -Layout $layout
        Assert-PathEqual (Join-Path $launchRoot 'runtime') $pointer.Current.Path 'Legacy runtime must remain current'
        Assert-Equal '0.1.0-rc.7' $pointer.Current.Version 'Legacy runtime version must be recorded'
        Assert-True (Test-Path -LiteralPath $layout.PointerPath) 'Initialization must write the pointer file'
    }

    Invoke-Test 'commits a ready candidate and retains the previous runtime' {
        . $helper
        $layout = Get-DshRuntimeLayout -LaunchRoot $launchRoot
        $candidate = New-DshRuntimeCandidate -Layout $layout -Version '0.1.0-rc.8'
        New-FakeReadyRuntime -Root $candidate.Path -Version $candidate.Version
        $committed = Commit-DshRuntimePointer -Layout $layout -Candidate $candidate
        Assert-PathEqual $candidate.Path $committed.Current.Path 'Candidate must become current'
        Assert-PathEqual (Join-Path $launchRoot 'runtime') $committed.Previous.Path 'Old runtime must become previous'
    }

    Invoke-Test 'rejects invalid pointer and candidate paths without touching sentinels' {
        . $helper
        $layout = Get-DshRuntimeLayout -LaunchRoot $launchRoot
        $sentinel = Join-Path $launchRoot 'sentinel.txt'
        [IO.File]::WriteAllText($sentinel, 'keep', [Text.Encoding]::ASCII)
        Assert-Throws { Resolve-DshOwnedRuntimePath -LaunchRoot $launchRoot -RelativePath '..\outside' } 'Parent traversal must fail'
        Assert-Throws { Resolve-DshOwnedRuntimePath -LaunchRoot $launchRoot -RelativePath 'C:\outside' } 'Absolute pointer path must fail'
        Assert-Throws { Resolve-DshOwnedRuntimePath -LaunchRoot $launchRoot -RelativePath '..\.dsh\secret' } 'Credential path escape must fail'
        Assert-True (Test-Path -LiteralPath $sentinel) 'Rejected paths must not delete sentinels'
    }

    Invoke-Test 'writes and clears an upgrade transaction with relative selections' {
        . $helper
        $layout = Get-DshRuntimeLayout -LaunchRoot $launchRoot
        $pointer = Read-DshRuntimePointer -Layout $layout
        $candidate = New-DshRuntimeCandidate -Layout $layout -Version '0.1.0-rc.9'
        $written = Write-DshUpgradeTransaction -Layout $layout -Phase 'PREPARED' `
            -Old $pointer.Current -Candidate $candidate -StartupToken 'token-1'
        Assert-Equal 'PREPARED' $written.Phase 'Transaction phase must be recorded'
        Assert-Equal 'token-1' $written.StartupToken 'Transaction token must be recorded'
        Assert-Equal '0.1.0-rc.9' $written.Candidate.Version 'Candidate version must be recorded'
        Assert-True (Test-Path -LiteralPath $layout.TransactionPath) 'Transaction file must exist'
        Clear-DshUpgradeTransaction -Layout $layout
        Assert-True (-not (Test-Path -LiteralPath $layout.TransactionPath)) 'Clearing must remove the transaction'
    }

    Invoke-Test 'retains only current and previous versioned runtimes' {
        . $helper
        $layout = Get-DshRuntimeLayout -LaunchRoot $launchRoot
        $old = New-DshRuntimeCandidate -Layout $layout -Version '0.1.0-rc.6'
        New-FakeReadyRuntime -Root $old.Path -Version $old.Version
        $current = Read-DshRuntimePointer -Layout $layout
        Remove-DshUnreferencedRuntimes -Layout $layout
        Assert-True (-not (Test-Path -LiteralPath $old.Path)) 'An unreferenced ready runtime must be removed'
        Assert-True (Test-Path -LiteralPath $current.Current.Path) 'Current runtime must remain'
    }

    Write-Host "All $script:Passed runtime layout behavior tests passed."
} finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}

exit 0
