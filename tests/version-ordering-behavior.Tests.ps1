$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$versionHelper = Join-Path $repoRoot 'dsh-version.ps1'
$script:Passed = 0
. $versionHelper

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    if ($Expected -ne $Actual) { throw "$Message (expected: $Expected, actual: $Actual)" }
}

function Assert-Match {
    param([string]$Actual, [string]$Pattern, [string]$Message)
    if ($Actual -notmatch $Pattern) { throw "$Message`nActual:`n$Actual" }
}

function Invoke-Test {
    param([string]$Name, [scriptblock]$Body)
    & $Body
    $script:Passed++
    Write-Host "PASS: $Name"
}

Invoke-Test 'orders numeric prerelease identifiers numerically' {
    Assert-Equal '0.1.0-rc.10' (Get-HighestDshVersion @('0.1.0-rc.9', '0.1.0-rc.10')) 'rc.10 must be newer than rc.9'
}

Invoke-Test 'compares the core version before prerelease stability' {
    Assert-Equal '1.0.0-rc.1' (Get-HighestDshVersion @('0.9.9', '1.0.0-rc.1')) 'A higher core prerelease must outrank an older stable release'
    Assert-Equal '1.0.0' (Get-HighestDshVersion @('1.0.0-rc.99', '1.0.0')) 'Stable must outrank prerelease only for the same core version'
}

Invoke-Test 'all version consumers use the shared comparison helper' {
    $resolver = Get-Content -LiteralPath (Join-Path $repoRoot 'resolve-dsh-version.ps1') -Raw
    $update = Get-Content -LiteralPath (Join-Path $repoRoot 'update-check.ps1') -Raw
    $command = Get-Content -LiteralPath (Join-Path $repoRoot 'deepseek.cmd') -Raw
    Assert-Match $resolver 'dsh-version\.ps1' 'Published dist-tag selection must use the shared comparator'
    Assert-Match $update 'Get-HighestDshVersion' 'Update checks must use the shared comparator for local versions'
    Assert-Match $command 'dsh-version\.ps1' 'deepseek --version must use the shared comparator'
}

Write-Host "All $script:Passed version ordering behavior tests passed."
exit 0
