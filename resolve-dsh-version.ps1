param(
    [switch]$PreferLocalRuntime,
    [string]$RuntimeRoot,
    # List mode: print every published @deepseek-ai/dsh version, newest first.
    [switch]$ListPublished
)

# Prints the highest published version across all npm dist-tags (latest, next, ...).
# Prints nothing when the registry cannot be queried; callers decide the fallback.
$ErrorActionPreference = 'SilentlyContinue'
. (Join-Path $PSScriptRoot 'dsh-version.ps1')
. (Join-Path $PSScriptRoot 'dsh-runtime-layout.ps1')

if ($ListPublished) {
    # Registry fast path: the abbreviated packument (corgi doc) carries the
    # full version table with minimal per-version metadata. The registry
    # defaults to the npm public registry; DSH_REGISTRY can point at a mirror.
    # `npm view` remains the fallback so custom registry config, proxies, and
    # auth keep working.
    $registry = if ($env:DSH_REGISTRY) { [string]$env:DSH_REGISTRY } else { 'https://registry.npmjs.org' }
    $registry = $registry.TrimEnd('/')
    $allVersions = @()
    if ($registry) {
        try {
            $document = Invoke-RestMethod -Uri "$registry/@deepseek-ai%2Fdsh" `
                -Headers @{ Accept = 'application/vnd.npm.install-v1+json' } `
                -TimeoutSec 8 -ErrorAction Stop
            $allVersions = @($document.versions.PSObject.Properties.Name)
        } catch {
            $allVersions = @()
        }
    }
    if (-not $allVersions) {
        try {
            $allVersions = @(npm view @deepseek-ai/dsh versions --json 2>$null | ConvertFrom-Json)
        } catch {
            $allVersions = @()
        }
    }
    # Sort newest first with the shared semver comparator (string sort would
    # misorder prerelease identifiers such as rc.2 vs rc.10).
    $sortedVersions = @()
    foreach ($candidate in @($allVersions | Where-Object { $_ })) {
        $insertedAt = -1
        for ($index = 0; $index -lt $sortedVersions.Count; $index++) {
            if ((Compare-DshVersion $candidate ([string]$sortedVersions[$index])) -gt 0) {
                $insertedAt = $index
                break
            }
        }
        if ($insertedAt -lt 0) {
            $sortedVersions = @($sortedVersions) + @($candidate)
        } else {
            $before = @()
            if ($insertedAt -gt 0) { $before = @($sortedVersions[0..($insertedAt - 1)]) }
            $after = @($sortedVersions[$insertedAt..($sortedVersions.Count - 1)])
            $sortedVersions = @($before + @($candidate) + $after)
        }
    }
    $sortedVersions | ForEach-Object { Write-Output $_ }
    exit 0
}

if (-not $RuntimeRoot) {
    $RuntimeRoot = Join-Path $env:USERPROFILE 'dsh-launch\runtime'
}

function Get-InstalledRuntimeVersion {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [switch]$RequireReadyMarker
    )

    $dshRoot = Join-Path $Root 'node_modules\@deepseek-ai\dsh'
    $packagePath = Join-Path $dshRoot 'package.json'
    $entrypoint = Join-Path $dshRoot 'lib\bin.js'
    if (-not (Test-Path -LiteralPath $packagePath) -or -not (Test-Path -LiteralPath $entrypoint)) {
        return ''
    }

    try {
        $package = Get-Content -LiteralPath $packagePath -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        return ''
    }
    $installedVersion = [string]$package.version
    if ([string]$package.name -ne '@deepseek-ai/dsh' -or [string]::IsNullOrWhiteSpace($installedVersion)) {
        return ''
    }
    if (-not $RequireReadyMarker) {
        return $installedVersion
    }

    $markerPath = Join-Path $Root 'dsh-runtime-ready.json'
    if (-not (Test-Path -LiteralPath $markerPath)) {
        return ''
    }
    try {
        $marker = Get-Content -LiteralPath $markerPath -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        return ''
    }
    if ([int]$marker.SchemaVersion -ne 2 -or [string]$marker.ValidatedBy -ne 'npm-ls-all') {
        return ''
    }
    if ([string]$marker.Version -ne $installedVersion) {
        return ''
    }
    return $installedVersion
}

if ($PreferLocalRuntime) {
    try {
        $layout = Get-DshRuntimeLayout -LaunchRoot (Split-Path -Parent $RuntimeRoot)
        $pointer = Read-DshRuntimePointer -Layout $layout
        if ($pointer.Current -and (Test-DshRuntimeReady -Path $pointer.Current.Path -ExpectedVersion $pointer.Current.Version)) {
            Write-Output $pointer.Current.Version
            exit 0
        }
    } catch { }
    $selectedVersion = Get-InstalledRuntimeVersion -Root $RuntimeRoot -RequireReadyMarker
    if (-not $selectedVersion) {
        $selectedVersion = Get-InstalledRuntimeVersion -Root $RuntimeRoot
    }
    if ($selectedVersion) {
        Write-Output $selectedVersion
        exit 0
    }
}

$publishedVersions = @()
# Fast path: query the registry's dist-tags endpoint directly so update and
# upgrade checks skip the ~2s `npm` CLI startup that `npm view` pays on every
# invocation. The registry defaults to the npm public registry; DSH_REGISTRY
# can point at a mirror (e.g. a local proxy). `npm view` remains the fallback
# so custom npm registry config, proxies, and auth keep working.
$registry = if ($env:DSH_REGISTRY) { [string]$env:DSH_REGISTRY } else { 'https://registry.npmjs.org' }
$registry = $registry.TrimEnd('/')
$tags = $null
if ($registry) {
    try {
        $tags = Invoke-RestMethod -Uri "$registry/-/package/@deepseek-ai%2Fdsh/dist-tags" -TimeoutSec 8 -ErrorAction Stop
    } catch {
        $tags = $null
    }
}
if (-not $tags) {
    try {
        $tags = npm view @deepseek-ai/dsh dist-tags --json 2>$null | ConvertFrom-Json
    } catch { $tags = $null }
}
if ($tags) {
    foreach ($prop in $tags.PSObject.Properties) {
        $publishedVersions += [string]$prop.Value
    }
}
$best = $null
if ($publishedVersions.Count -gt 0) {
    $best = Get-HighestDshVersion $publishedVersions
}
if ($best) { Write-Output $best }
