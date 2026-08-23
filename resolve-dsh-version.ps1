param(
    [switch]$PreferLocalRuntime,
    [string]$RuntimeRoot
)

# Prints the highest published version across all npm dist-tags (latest, next, ...).
# Prints nothing when the registry cannot be queried; callers decide the fallback.
$ErrorActionPreference = 'SilentlyContinue'
. (Join-Path $PSScriptRoot 'dsh-version.ps1')

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
$best = Get-HighestDshVersion $publishedVersions
if ($best) { Write-Output $best }
