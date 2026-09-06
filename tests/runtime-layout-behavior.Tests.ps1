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
    # The entrypoint must look like a real packaged bundle (>1KB); a 5-byte
    # placeholder must never count as a ready runtime.
    $fakeEntry = "#!/usr/bin/env node`r`n" + (('// fake dsh entrypoint`r`n') * 80)
    [IO.File]::WriteAllText((Join-Path $dshRoot 'lib\bin.js'), $fakeEntry, [Text.Encoding]::ASCII)
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

    Invoke-Test 'rejects a junction alias pointing outside the owned root' {
        # R1 repro in review doc: a junction level inside the managed path points
        # outside the launcher-owned tree. Comments must stay ASCII here because
        # this file is UTF-8 without BOM and PS 5.1 decodes it as ANSI.
        . $helper
        $outside = Join-Path $testRoot 'outside-runtime-target'
        $outsideDshRoot = Join-Path $outside 'node_modules\@deepseek-ai\dsh'
        New-Item -ItemType Directory -Force -Path (Join-Path $outsideDshRoot 'lib') | Out-Null
        $outsideSentinel = Join-Path $outside 'sentinel.txt'
        [IO.File]::WriteAllText($outsideSentinel, 'keep', [Text.Encoding]::ASCII)
        $alias = Join-Path $launchRoot 'runtime-alias'
        if (Test-Path -LiteralPath $alias) { [IO.Directory]::Delete($alias) }
        New-Item -ItemType Junction -Path $alias -Target $outside | Out-Null
        New-FakeReadyRuntime -Root $alias -Version '0.2.0'

        Assert-Throws { Resolve-DshOwnedRuntimePath -LaunchRoot $launchRoot -RelativePath 'runtime-alias' } `
            'A junction alias must not satisfy the owned-root check'
        $layout = Get-DshRuntimeLayout -LaunchRoot $launchRoot
        $candidate = [pscustomobject]@{ Path = $alias; Version = '0.2.0' }
        Assert-Throws { Commit-DshRuntimePointer -Layout $layout -Candidate $candidate } `
            'A junction candidate must never be committed to the pointer'
        Assert-True (Test-Path -LiteralPath $outsideSentinel) 'The junction target must remain untouched'
        Assert-True (Test-Path -LiteralPath (Join-Path $alias 'dsh-runtime-ready.json')) 'The alias contents must remain untouched'
        [IO.Directory]::Delete($alias)
    }

    Invoke-Test 'rejects a junction alias pointing into the .dsh data tree' {
        # R2 验收补充：指向合成 .dsh（用户凭据边界）的 junction 同样必须拒绝。
        . $helper
        $dshData = Join-Path (Join-Path (Join-Path $testRoot 'profile') '.dsh') 'runtime-alias-target'
        New-Item -ItemType Directory -Force -Path $dshData | Out-Null
        $dshSentinel = Join-Path $dshData 'sentinel.txt'
        [IO.File]::WriteAllText($dshSentinel, 'keep', [Text.Encoding]::ASCII)
        $alias = Join-Path $launchRoot 'runtime-dsh-alias'
        New-Item -ItemType Junction -Path $alias -Target $dshData | Out-Null
        try {
            Assert-Throws { Resolve-DshOwnedRuntimePath -LaunchRoot $launchRoot -RelativePath 'runtime-dsh-alias' } `
                'A junction alias into .dsh must fail the owned-root check'
            Assert-True (Test-Path -LiteralPath $dshSentinel) 'The .dsh junction target must remain untouched'
        } finally {
            [IO.Directory]::Delete($alias)
        }
    }

    Invoke-Test 'rejects a junction parent above the runtime path' {
        . $helper
        $outside = Join-Path $testRoot 'outside-versions-target'
        New-Item -ItemType Directory -Force -Path $outside | Out-Null
        $outsideSentinel = Join-Path $outside 'sentinel.txt'
        [IO.File]::WriteAllText($outsideSentinel, 'keep', [Text.Encoding]::ASCII)
        $versionsRoot = Join-Path $launchRoot 'runtime-versions'
        $holdRoot = Join-Path $testRoot 'versions-hold'
        if (Test-Path -LiteralPath $versionsRoot) {
            $originalVersions = @(Get-ChildItem -LiteralPath $versionsRoot -Force)
            if ($originalVersions.Count -gt 0) {
                New-Item -ItemType Directory -Force -Path $holdRoot | Out-Null
                foreach ($entry in $originalVersions) {
                    Move-Item -LiteralPath $entry.FullName -Destination $holdRoot
                }
            }
            [IO.Directory]::Delete($versionsRoot)
        }
        New-Item -ItemType Junction -Path $versionsRoot -Target $outside | Out-Null
        try {
            $layout = Get-DshRuntimeLayout -LaunchRoot $launchRoot
            $candidate = New-DshRuntimeCandidate -Layout $layout -Version '0.2.1'
            New-FakeReadyRuntime -Root $candidate.Path -Version $candidate.Version
            Assert-Throws { Commit-DshRuntimePointer -Layout $layout -Candidate $candidate } `
                'A candidate below a junction parent must never be committed'
            Assert-True (Test-Path -LiteralPath $outsideSentinel) 'The junction parent target must remain untouched'
        } finally {
            [IO.Directory]::Delete($versionsRoot)
            New-Item -ItemType Directory -Force -Path $versionsRoot | Out-Null
            if (Test-Path -LiteralPath $holdRoot) {
                foreach ($entry in @(Get-ChildItem -LiteralPath $holdRoot -Force)) {
                    Move-Item -LiteralPath $entry.FullName -Destination $versionsRoot
                }
                Remove-Item -LiteralPath $holdRoot -Recurse -Force
            }
        }
    }

    Invoke-Test 'cleanup never deletes through a reparse point' {
        . $helper
        $outside = Join-Path $testRoot 'outside-cleanup-target'
        New-Item -ItemType Directory -Force -Path $outside | Out-Null
        $outsideSentinel = Join-Path $outside 'sentinel.txt'
        [IO.File]::WriteAllText($outsideSentinel, 'keep', [Text.Encoding]::ASCII)
        $junctionRuntime = Join-Path $launchRoot 'runtime-junction-unreferenced'
        New-Item -ItemType Junction -Path $junctionRuntime -Target $outside | Out-Null
        [IO.File]::WriteAllText(
            (Join-Path $junctionRuntime 'dsh-runtime-ready.json'),
            (@{ SchemaVersion = 2; Version = '0.0.1'; ValidatedBy = 'npm-ls-all' } | ConvertTo-Json -Compress),
            [Text.UTF8Encoding]::new($false)
        )
        $layout = Get-DshRuntimeLayout -LaunchRoot $launchRoot
        Remove-DshUnreferencedRuntimes -Layout $layout
        Assert-True (Test-Path -LiteralPath $junctionRuntime) 'A junction runtime directory must not be removed'
        Assert-True (Test-Path -LiteralPath $outsideSentinel) 'The junction target must remain untouched'
        [IO.Directory]::Delete($junctionRuntime)
    }

    Invoke-Test 'normalizes short path aliases before the boundary comparison' {
        . $helper
        $fso = New-Object -ComObject Scripting.FileSystemObject
        $shortLaunchRoot = $fso.GetFolder($launchRoot).ShortPath
        $runtimePath = Join-Path $launchRoot 'runtime'
        $shortRuntimePath = if (Test-Path -LiteralPath $runtimePath) {
            $fso.GetFolder($runtimePath).ShortPath
        } else {
            ''
        }
        if ($shortRuntimePath -and $shortRuntimePath -ne $runtimePath) {
            $result = Assert-DshRuntimePathWithinOwnedRoot -Root $shortLaunchRoot -Path $shortRuntimePath
            Assert-PathEqual $runtimePath $result 'A short path alias must normalize back to the physical path'
        }
        # On volumes without 8.3 aliases ShortPath equals the long path; the
        # basic owned-root behavior is still exercised in that case.
        $result = Assert-DshRuntimePathWithinOwnedRoot -Root $shortLaunchRoot -Path $runtimePath
        Assert-PathEqual $runtimePath $result 'A plain path must pass the owned-root check unchanged'
    }

    Invoke-Test 'a stub entrypoint is not considered ready' {
        . $helper
        $layout = Get-DshRuntimeLayout -LaunchRoot $launchRoot
        $stub = New-DshRuntimeCandidate -Layout $layout -Version '0.1.0-rc.6'
        $dshRoot = Join-Path (Join-Path $stub.Path 'node_modules\@deepseek-ai') 'dsh'
        New-Item -ItemType Directory -Force -Path (Join-Path $dshRoot 'lib') | Out-Null
        [IO.File]::WriteAllText((Join-Path $dshRoot 'lib\bin.js'), 'entry', [Text.Encoding]::ASCII)
        [IO.File]::WriteAllText(
            (Join-Path $dshRoot 'package.json'),
            (@{ name = '@deepseek-ai/dsh'; version = '0.1.0-rc.6' } | ConvertTo-Json -Compress),
            [Text.Encoding]::ASCII
        )
        [IO.File]::WriteAllText(
            (Join-Path $stub.Path 'dsh-runtime-ready.json'),
            (@{ SchemaVersion = 2; Version = '0.1.0-rc.6'; ValidatedBy = 'npm-ls-all' } | ConvertTo-Json -Compress),
            [Text.UTF8Encoding]::new($false)
        )
        Assert-True (-not (Test-DshRuntimeReady -Path $stub.Path -ExpectedVersion '0.1.0-rc.6')) `
            'A stub entrypoint (5 bytes) must never be considered ready'
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

    Invoke-Test 'upgrade transaction ownership is validated on read and clear' {
        # R9: transaction read/clear must verify the owning transaction id so a
        # foreign maintenance operation can never take over or delete the record.
        . $helper
        $layout = Get-DshRuntimeLayout -LaunchRoot $launchRoot
        $pointer = Read-DshRuntimePointer -Layout $layout
        $candidate = New-DshRuntimeCandidate -Layout $layout -Version '0.2.2'
        $ownId = [guid]::NewGuid().ToString('N')
        Write-DshUpgradeTransaction -Layout $layout -Phase 'PREPARED' `
            -Old $pointer.Current -Candidate $candidate -StartupToken 'token-2' `
            -TransactionId $ownId | Out-Null
        Assert-Throws { Read-DshUpgradeTransaction -Layout $layout -ExpectedTransactionId ([guid]::NewGuid().ToString('N')) } `
            'A foreign transaction id must not be able to read the record'
        Assert-Throws { Clear-DshUpgradeTransaction -Layout $layout -ExpectedTransactionId ([guid]::NewGuid().ToString('N')) } `
            'Clearing with a foreign transaction id must fail loudly'
        Assert-True (Test-Path -LiteralPath $layout.TransactionPath) `
            'A foreign transaction id must not be able to clear the record'
        $own = Read-DshUpgradeTransaction -Layout $layout -ExpectedTransactionId $ownId
        Assert-Equal $ownId $own.TransactionId 'The owning id must read its own transaction'
        Clear-DshUpgradeTransaction -Layout $layout -ExpectedTransactionId $ownId
        Assert-True (-not (Test-Path -LiteralPath $layout.TransactionPath)) 'The owning id must be able to clear its transaction'
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
