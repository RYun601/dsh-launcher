param(
    [string]$LauncherDir = $PSScriptRoot,
    [string]$LaunchRoot = ''
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'dsh-version.ps1')
. (Join-Path $PSScriptRoot 'dsh-runtime-layout.ps1')

# Single version source for `deepseek --version` (R7/R8). The launcher version
# comes from this script's own directory; the active DeepSeek Harness version
# comes from the managed runtime pointer (Current first, legacy fallback).
# Output stays ASCII because this file runs under the console code page.
if (-not $LaunchRoot) {
    $LaunchRoot = Join-Path $env:USERPROFILE 'dsh-launch'
}

$launcherVersion = 'unknown'
$versionFile = Join-Path $LauncherDir 'VERSION'
if (Test-Path -LiteralPath $versionFile -PathType Leaf) {
    try {
        $candidate = ([string](Get-Content -LiteralPath $versionFile -Raw)).Trim()
        if ($candidate) { $launcherVersion = $candidate }
    } catch { }
}

$layout = Get-DshRuntimeLayout -LaunchRoot $LaunchRoot
$report = Get-DshRuntimeVersionReport -Layout $layout

Write-Host "dsh-launcher $launcherVersion"
if ($report.ActiveSource -eq 'current') {
    $readySuffix = ''
    if (-not $report.CurrentValid) { $readySuffix = ' (ready check FAILED)' }
    Write-Host "DeepSeek Harness $($report.ActiveVersion)$readySuffix"
    Write-Host "Active runtime: $($report.ActivePath)"
} elseif ($report.ActiveSource -eq 'legacy') {
    Write-Host "DeepSeek Harness $($report.ActiveVersion)"
    Write-Host "Active runtime: $($report.ActivePath)"
} elseif ($report.ActiveSource -eq 'pointer-error') {
    Write-Host 'DeepSeek Harness unknown (runtime pointer unreadable)'
    Write-Host "Pointer error: $($report.PointerErrorMessage)"
} else {
    Write-Host 'DeepSeek Harness unknown (no managed runtime installed)'
}

$notes = @()
if ($report.Previous) {
    $notes += "previous pointer: $($report.Previous.Version)"
}
if ($report.LegacyInstalledVersion -and
        ($report.ActiveSource -ne 'legacy') -and
        ($report.LegacyInstalledVersion -ne $report.ActiveVersion)) {
    $notes += "legacy runtime: $($report.LegacyInstalledVersion)"
}
if ($notes.Count -gt 0) {
    Write-Host ("Other detected: " + ($notes -join '; '))
}
