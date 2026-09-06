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

function Assert-NotMatch {
    param([string]$Actual, [string]$Pattern, [string]$Message)
    if ($Actual -match $Pattern) { throw "$Message`nActual:`n$Actual" }
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
    # R7 更新后的不变量：版本比较必须经共享比较器（dsh-version.ps1），
    # 更新检查必须读取活动运行时指针（而非“各来源取最高”）。
    $resolver = Get-Content -LiteralPath (Join-Path $repoRoot 'resolve-dsh-version.ps1') -Raw
    $update = Get-Content -LiteralPath (Join-Path $repoRoot 'update-check.ps1') -Raw
    $command = Get-Content -LiteralPath (Join-Path $repoRoot 'deepseek.cmd') -Raw
    $versionInfo = Get-Content -LiteralPath (Join-Path $repoRoot 'version-info.ps1') -Raw
    Assert-Match $resolver 'dsh-version\.ps1' 'Published dist-tag selection must use the shared comparator'
    Assert-Match $update 'Compare-DshVersion' 'Update checks must compare via the shared comparator'
    Assert-Match $update 'Get-DshRuntimeVersionReport' 'Update checks must read the active runtime pointer'
    Assert-NotMatch $update 'Get-HighestDshVersion' 'Update checks must not approximate the local version with the highest of all sources'
    Assert-Match $command 'version-info\.ps1' 'deepseek --version must dispatch to the shared version source'
    Assert-Match $versionInfo 'dsh-version\.ps1' 'The version display must use the shared comparator'
}

Write-Host "All $script:Passed version ordering behavior tests passed."
exit 0
