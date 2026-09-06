$ErrorActionPreference = 'Stop'

function ConvertTo-DshRuntimeFullPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    return [IO.Path]::GetFullPath($Path).TrimEnd('\')
}

# Physical path comparison must normalize 8.3 short names first: GetLongPathName
# only resolves existing components; missing tail parts are re-joined verbatim and
# normalized once more. ASCII-only comments: this file is UTF-8 without BOM and
# Windows PowerShell 5.1 decodes it with the ANSI code page.
if (-not ('DshRuntimeLayoutPathNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class DshRuntimeLayoutPathNative
{
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern uint GetLongPathName(string path, StringBuilder buffer, uint capacity);
}
'@
}

function ConvertTo-DshRuntimeComparisonPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $full = ConvertTo-DshRuntimeFullPath $Path
    $existing = $full
    $missingParts = New-Object Collections.Generic.List[string]
    while (-not (Test-Path -LiteralPath $existing)) {
        $leaf = Split-Path -Leaf $existing
        $parent = Split-Path -Parent $existing
        if ([string]::IsNullOrWhiteSpace($leaf) -or [string]::IsNullOrWhiteSpace($parent) -or
                [string]::Equals($parent, $existing, [StringComparison]::OrdinalIgnoreCase)) {
            return $full
        }
        $missingParts.Insert(0, $leaf)
        $existing = $parent
    }
    $buffer = New-Object Text.StringBuilder 32768
    $length = [DshRuntimeLayoutPathNative]::GetLongPathName($existing, $buffer, [uint32]$buffer.Capacity)
    if ($length -eq 0 -or $length -ge $buffer.Capacity) { return $full }
    $resolved = $buffer.ToString()
    foreach ($missingPart in $missingParts) {
        $resolved = Join-Path $resolved $missingPart
    }
    return [IO.Path]::GetFullPath($resolved).TrimEnd('\')
}

function Test-DshRuntimeReparsePointBetween {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Path
    )

    # Walk from the target up to and including the root; levels above the root
    # (user profile redirection) are intentionally not inspected.
    $rootFull = (ConvertTo-DshRuntimeFullPath $Root).TrimEnd('\')
    $current = (ConvertTo-DshRuntimeFullPath $Path).TrimEnd('\')
    while ($true) {
        try {
            if (Test-Path -LiteralPath $current) {
                $item = Get-Item -LiteralPath $current -Force
                if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                    return $true
                }
            }
        } catch {
            return $true
        }
        if ([string]::Equals($current, $rootFull, [StringComparison]::OrdinalIgnoreCase)) {
            return $false
        }
        $parent = Split-Path -Parent $current
        if (-not $parent -or [string]::Equals($parent, $current, [StringComparison]::OrdinalIgnoreCase)) {
            return $false
        }
        $current = $parent
    }
}

# Unified runtime physical boundary: string prefix (after short-path
# normalization) plus zero reparse points between the root and the target.
# junction/symlink levels pointing outside the managed tree are rejected so
# install, read and cleanup paths cannot pierce the boundary.
function Assert-DshRuntimePathWithinOwnedRoot {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $rootPhysical = ConvertTo-DshRuntimeComparisonPath -Path $Root
    $pathPhysical = ConvertTo-DshRuntimeComparisonPath -Path $Path
    if (-not $pathPhysical.StartsWith($rootPhysical + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw "Runtime path escapes the launcher-owned root: $Path (root: $rootPhysical)"
    }
    if (Test-DshRuntimeReparsePointBetween -Root $rootPhysical -Path $pathPhysical) {
        throw "Runtime path crosses a reparse point outside the launcher-owned root: $Path"
    }
    return $pathPhysical
}

function Resolve-DshOwnedRuntimePath {
    param(
        [Parameter(Mandatory = $true)][string]$LaunchRoot,
        [Parameter(Mandatory = $true)][string]$RelativePath
    )

    if ([IO.Path]::IsPathRooted($RelativePath)) {
        throw 'Runtime pointer path must be relative'
    }

    $root = ConvertTo-DshRuntimeFullPath $LaunchRoot
    $resolved = ConvertTo-DshRuntimeFullPath (Join-Path $root $RelativePath)
    if (-not $resolved.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Runtime pointer escapes the launcher-owned root'
    }
    return (Assert-DshRuntimePathWithinOwnedRoot -Root $root -Path $resolved)
}

function Get-DshRuntimeLayout {
    param([Parameter(Mandatory = $true)][string]$LaunchRoot)

    $root = ConvertTo-DshRuntimeFullPath $LaunchRoot
    [pscustomobject]@{
        LaunchRoot     = $root
        LegacyRoot     = Join-Path $root 'runtime'
        VersionsRoot   = Join-Path $root 'runtime-versions'
        PointerPath    = Join-Path $root 'runtime-current.json'
        TransactionPath = Join-Path $root 'runtime-upgrade.json'
    }
}

function Test-DshRuntimeReady {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$ExpectedVersion
    )

    $markerPath = Join-Path $Path 'dsh-runtime-ready.json'
    $entrypoint = Join-Path $Path 'node_modules\@deepseek-ai\dsh\lib\bin.js'
    if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $entrypoint -PathType Leaf)) {
        return $false
    }
    # A real published DSH entrypoint is a complete bundle (thousands of bytes);
    # placeholder/stub entrypoints (5-byte test fixtures or failed installs) are
    # never valid runtimes.
    try {
        if ((Get-Item -LiteralPath $entrypoint).Length -lt 1024) {
            return $false
        }
    } catch {
        return $false
    }
    try {
        $marker = Get-Content -LiteralPath $markerPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ([int]$marker.SchemaVersion -ne 2 -or [string]$marker.ValidatedBy -ne 'npm-ls-all') {
            return $false
        }
        if ($ExpectedVersion -and [string]$marker.Version -ne $ExpectedVersion) {
            return $false
        }
        return $true
    } catch {
        return $false
    }
}

function Get-DshRuntimeSelection {
    param([Parameter(Mandatory = $true)][string]$Path)

    $fullPath = ConvertTo-DshRuntimeFullPath $Path
    $marker = Get-Content -LiteralPath (Join-Path $fullPath 'dsh-runtime-ready.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    return [pscustomobject]@{ Path = $fullPath; Version = [string]$marker.Version }
}

function ConvertTo-DshRuntimeRelativePath {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Layout,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $fullPath = ConvertTo-DshRuntimeFullPath $Path
    $root = $Layout.LaunchRoot.TrimEnd('\')
    if (-not $fullPath.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Runtime path is outside the launcher-owned root'
    }
    return $fullPath.Substring($root.Length + 1)
}

function ConvertFrom-DshRuntimeSelection {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Layout,
        [AllowNull()]$Value
    )

    if (-not $Value) { return $null }
    $path = Resolve-DshOwnedRuntimePath -LaunchRoot $Layout.LaunchRoot -RelativePath ([string]$Value.Path)
    return [pscustomobject]@{ Path = $path; Version = [string]$Value.Version }
}

function Read-DshRuntimePointer {
    param([Parameter(Mandatory = $true)][pscustomobject]$Layout)

    if (-not (Test-Path -LiteralPath $Layout.PointerPath -PathType Leaf)) {
        return [pscustomobject]@{ SchemaVersion = 1; Current = $null; Previous = $null }
    }
    $raw = Get-Content -LiteralPath $Layout.PointerPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([int]$raw.SchemaVersion -ne 1) { throw 'Unsupported DSH runtime pointer schema' }
    return [pscustomobject]@{
        SchemaVersion = 1
        Current = ConvertFrom-DshRuntimeSelection -Layout $Layout -Value $raw.Current
        Previous = ConvertFrom-DshRuntimeSelection -Layout $Layout -Value $raw.Previous
    }
}

function ConvertTo-DshRuntimePointerValue {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Layout,
        $Selection
    )
    if (-not $Selection) { return $null }
    return [pscustomobject]@{
        Path = ConvertTo-DshRuntimeRelativePath -Layout $Layout -Path ([string]$Selection.Path)
        Version = [string]$Selection.Version
    }
}

function Write-DshRuntimePointer {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Layout,
        [Parameter(Mandatory = $true)][pscustomobject]$Pointer
    )

    New-Item -ItemType Directory -Force -Path $Layout.LaunchRoot | Out-Null
    $tempPath = Join-Path $Layout.LaunchRoot ('.runtime-current-' + [guid]::NewGuid().ToString('N') + '.tmp')
    $backupPath = Join-Path $Layout.LaunchRoot ('.runtime-current-' + [guid]::NewGuid().ToString('N') + '.bak')
    $value = [pscustomobject]@{
        SchemaVersion = 1
        Current = ConvertTo-DshRuntimePointerValue -Layout $Layout -Selection $Pointer.Current
        Previous = ConvertTo-DshRuntimePointerValue -Layout $Layout -Selection $Pointer.Previous
    }
    try {
        [IO.File]::WriteAllText($tempPath, ($value | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
        if (Test-Path -LiteralPath $Layout.PointerPath -PathType Leaf) {
            [IO.File]::Replace($tempPath, $Layout.PointerPath, $backupPath, $true)
            if (Test-Path -LiteralPath $backupPath) { Remove-Item -LiteralPath $backupPath -Force }
        } else {
            [IO.File]::Move($tempPath, $Layout.PointerPath)
        }
    } finally {
        if (Test-Path -LiteralPath $tempPath) { Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $backupPath) { Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue }
    }
}

function Initialize-DshRuntimePointer {
    param([Parameter(Mandatory = $true)][pscustomobject]$Layout)

    if (Test-Path -LiteralPath $Layout.PointerPath -PathType Leaf) {
        return Read-DshRuntimePointer -Layout $Layout
    }
    $current = $null
    if (Test-DshRuntimeReady -Path $Layout.LegacyRoot) {
        $current = Get-DshRuntimeSelection -Path $Layout.LegacyRoot
    }
    $pointer = [pscustomobject]@{ SchemaVersion = 1; Current = $current; Previous = $null }
    Write-DshRuntimePointer -Layout $Layout -Pointer $pointer
    return $pointer
}

function New-DshRuntimeCandidate {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Layout,
        [Parameter(Mandatory = $true)][string]$Version
    )

    if ($Version -notmatch '^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$') {
        throw "Invalid DSH runtime version: $Version"
    }
    New-Item -ItemType Directory -Force -Path $Layout.VersionsRoot | Out-Null
    $candidatePath = Join-Path $Layout.VersionsRoot ('runtime-' + $Version + '-' + [guid]::NewGuid().ToString('N'))
    return [pscustomobject]@{ Path = $candidatePath; Version = $Version }
}

function Commit-DshRuntimePointer {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Layout,
        [Parameter(Mandatory = $true)][pscustomobject]$Candidate
    )

    if (-not (Test-DshRuntimeReady -Path $Candidate.Path -ExpectedVersion $Candidate.Version)) {
        throw 'Cannot commit a runtime that has not passed preparation validation'
    }
    $candidatePath = ConvertTo-DshRuntimeFullPath $Candidate.Path
    if (-not $candidatePath.StartsWith((ConvertTo-DshRuntimeFullPath $Layout.VersionsRoot) + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Runtime candidate must be inside runtime-versions'
    }
    Assert-DshRuntimePathWithinOwnedRoot -Root (ConvertTo-DshRuntimeFullPath $Layout.VersionsRoot) -Path $candidatePath | Out-Null
    $pointer = Initialize-DshRuntimePointer -Layout $Layout
    $next = [pscustomobject]@{
        SchemaVersion = 1
        Current = [pscustomobject]@{ Path = $candidatePath; Version = $Candidate.Version }
        Previous = $pointer.Current
    }
    Write-DshRuntimePointer -Layout $Layout -Pointer $next
    return $next
}

function Read-DshUpgradeTransaction {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Layout,
        [string]$ExpectedTransactionId = ''
    )
    if (-not (Test-Path -LiteralPath $Layout.TransactionPath -PathType Leaf)) { return $null }
    $raw = Get-Content -LiteralPath $Layout.TransactionPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $transactionId = ''
    if ($raw.PSObject.Properties['TransactionId']) {
        $transactionId = [string]$raw.TransactionId
    }
    if ($ExpectedTransactionId -and $transactionId -ne $ExpectedTransactionId) {
        throw 'The DSH upgrade transaction belongs to another maintenance operation; refusing to touch it'
    }
    return [pscustomobject]@{
        SchemaVersion = [int]$raw.SchemaVersion
        Phase = [string]$raw.Phase
        StartupToken = [string]$raw.StartupToken
        TransactionId = $transactionId
        Old = ConvertFrom-DshRuntimeSelection -Layout $Layout -Value $raw.Old
        Candidate = ConvertFrom-DshRuntimeSelection -Layout $Layout -Value $raw.Candidate
    }
}

function Write-DshUpgradeTransaction {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Layout,
        [Parameter(Mandatory = $true)][string]$Phase,
        $Old,
        [Parameter(Mandatory = $true)]$Candidate,
        [Parameter(Mandatory = $true)][string]$StartupToken,
        [string]$TransactionId = ''
    )

    $value = [pscustomobject]@{
        SchemaVersion = 1
        Phase = $Phase
        StartupToken = $StartupToken
        TransactionId = $TransactionId
        Old = ConvertTo-DshRuntimePointerValue -Layout $Layout -Selection $Old
        Candidate = ConvertTo-DshRuntimePointerValue -Layout $Layout -Selection $Candidate
    }
    # 原子替换：不再“先删除旧记录再 Move”，避免事务文件短暂缺失窗口。
    $tempPath = Join-Path $Layout.LaunchRoot ('.runtime-upgrade-' + [guid]::NewGuid().ToString('N') + '.tmp')
    $backupPath = Join-Path $Layout.LaunchRoot ('.runtime-upgrade-' + [guid]::NewGuid().ToString('N') + '.bak')
    try {
        New-Item -ItemType Directory -Force -Path $Layout.LaunchRoot | Out-Null
        [IO.File]::WriteAllText($tempPath, ($value | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
        if (Test-Path -LiteralPath $Layout.TransactionPath -PathType Leaf) {
            [IO.File]::Replace($tempPath, $Layout.TransactionPath, $backupPath, $true)
        } else {
            [IO.File]::Move($tempPath, $Layout.TransactionPath)
        }
    } finally {
        if (Test-Path -LiteralPath $tempPath) { Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $backupPath) { Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue }
    }
    return Read-DshUpgradeTransaction -Layout $Layout
}

function Clear-DshUpgradeTransaction {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Layout,
        [string]$ExpectedTransactionId = ''
    )
    if (-not (Test-Path -LiteralPath $Layout.TransactionPath -PathType Leaf)) { return }
    if ($ExpectedTransactionId) {
        # 归属校验失败会抛出异常；绝不删除属于其他维护事务的记录。
        Read-DshUpgradeTransaction -Layout $Layout -ExpectedTransactionId $ExpectedTransactionId | Out-Null
    }
    Remove-Item -LiteralPath $Layout.TransactionPath -Force
}

# Unified version source report (R7): the active runtime is the pointer's
# Current when present, else the legacy root; unknown must never be reported as
# "already latest" by callers. Secondary sources are surfaced separately.
function Get-DshRuntimeVersionReport {
    param([Parameter(Mandatory = $true)][pscustomobject]$Layout)

    $report = [pscustomobject]@{
        ActiveVersion = 'unknown'
        ActiveSource = 'none'
        ActivePath = ''
        Current = $null
        CurrentValid = $false
        Previous = $null
        LegacyInstalledVersion = ''
        PointerError = $false
        PointerErrorMessage = ''
    }
    try {
        $report.PointerError = $false
        $pointer = Read-DshRuntimePointer -Layout $Layout
        $report.Current = $pointer.Current
        $report.Previous = $pointer.Previous
        if ($pointer.Current) {
            $report.ActiveVersion = [string]$pointer.Current.Version
            $report.ActiveSource = 'current'
            $report.ActivePath = [string]$pointer.Current.Path
            $report.CurrentValid = Test-DshRuntimeReady -Path $pointer.Current.Path `
                -ExpectedVersion $pointer.Current.Version
        } elseif (Test-DshRuntimeReady -Path $Layout.LegacyRoot) {
            $legacy = Get-DshRuntimeSelection -Path $Layout.LegacyRoot
            $report.ActiveVersion = [string]$legacy.Version
            $report.ActiveSource = 'legacy'
            $report.ActivePath = [string]$legacy.Path
        }
    } catch {
        $report.PointerError = $true
        $report.ActiveSource = 'pointer-error'
        $report.PointerErrorMessage = $_.Exception.Message
        $report.Current = $null
        $report.Previous = $null
    }
    $legacyPackage = Join-Path (Join-Path (Join-Path (Join-Path $Layout.LegacyRoot 'node_modules') '@deepseek-ai') 'dsh') 'package.json'
    if (Test-Path -LiteralPath $legacyPackage -PathType Leaf) {
        try {
            $package = Get-Content -LiteralPath $legacyPackage -Raw -Encoding UTF8 | ConvertFrom-Json
            if ([string]$package.name -eq '@deepseek-ai/dsh' -and $package.version) {
                $report.LegacyInstalledVersion = [string]$package.version
            }
        } catch { }
    }
    return $report
}

function Remove-DshUnreferencedRuntimes {
    param([Parameter(Mandatory = $true)][pscustomobject]$Layout)

    $pointer = Read-DshRuntimePointer -Layout $Layout
    $keep = @($pointer.Current, $pointer.Previous) | Where-Object { $_ } | ForEach-Object {
        ConvertTo-DshRuntimeFullPath $_.Path
    }
    if (-not (Test-Path -LiteralPath $Layout.VersionsRoot -PathType Container)) { return }
    foreach ($directory in @(Get-ChildItem -LiteralPath $Layout.VersionsRoot -Directory -ErrorAction SilentlyContinue)) {
        $full = ConvertTo-DshRuntimeFullPath $directory.FullName
        if ($keep -contains $full) { continue }
        # Never recurse-delete a reparse point directory: its physical target
        # may live outside the managed boundary.
        try {
            $item = Get-Item -LiteralPath $full -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
        } catch {
            continue
        }
        if (Test-DshRuntimeReady -Path $full) {
            Remove-Item -LiteralPath $full -Recurse -Force
        }
    }
}
