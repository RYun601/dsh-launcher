$ErrorActionPreference = 'Stop'

function ConvertTo-DshRuntimeFullPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    return [IO.Path]::GetFullPath($Path).TrimEnd('\')
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
    return $resolved
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
    param([Parameter(Mandatory = $true)][pscustomobject]$Layout)
    if (-not (Test-Path -LiteralPath $Layout.TransactionPath -PathType Leaf)) { return $null }
    $raw = Get-Content -LiteralPath $Layout.TransactionPath -Raw -Encoding UTF8 | ConvertFrom-Json
    return [pscustomobject]@{
        SchemaVersion = [int]$raw.SchemaVersion
        Phase = [string]$raw.Phase
        StartupToken = [string]$raw.StartupToken
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
        [Parameter(Mandatory = $true)][string]$StartupToken
    )

    $value = [pscustomobject]@{
        SchemaVersion = 1
        Phase = $Phase
        StartupToken = $StartupToken
        Old = ConvertTo-DshRuntimePointerValue -Layout $Layout -Selection $Old
        Candidate = ConvertTo-DshRuntimePointerValue -Layout $Layout -Selection $Candidate
    }
    $tempPath = Join-Path $Layout.LaunchRoot ('.runtime-upgrade-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        New-Item -ItemType Directory -Force -Path $Layout.LaunchRoot | Out-Null
        [IO.File]::WriteAllText($tempPath, ($value | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
        if (Test-Path -LiteralPath $Layout.TransactionPath -PathType Leaf) {
            Remove-Item -LiteralPath $Layout.TransactionPath -Force
        }
        [IO.File]::Move($tempPath, $Layout.TransactionPath)
    } finally {
        if (Test-Path -LiteralPath $tempPath) { Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue }
    }
    return Read-DshUpgradeTransaction -Layout $Layout
}

function Clear-DshUpgradeTransaction {
    param([Parameter(Mandatory = $true)][pscustomobject]$Layout)
    if (Test-Path -LiteralPath $Layout.TransactionPath -PathType Leaf) {
        Remove-Item -LiteralPath $Layout.TransactionPath -Force
    }
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
        if (Test-DshRuntimeReady -Path $full) {
            Remove-Item -LiteralPath $full -Recurse -Force
        }
    }
}
