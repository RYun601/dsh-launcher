$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$installer = Join-Path $repoRoot 'install.ps1'
$nodeHelper = Join-Path $repoRoot 'dsh-node-version.ps1'
$testRoot = Join-Path $env:TEMP ('dsh-installer-tests-' + [guid]::NewGuid().ToString('N'))
$profileRoot = Join-Path $testRoot 'profile'
$tempRoot = Join-Path $testRoot 'temp'
$payloadRoot = Join-Path $testRoot 'payload'
$archivePath = Join-Path $testRoot 'dsh-launcher.zip'
$fakeBin = Join-Path $testRoot 'fake-bin'
$nodeLog = Join-Path $testRoot 'node.log'
$script:Passed = 0

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    if ($Expected -ne $Actual) { throw "$Message (expected: $Expected, actual: $Actual)" }
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-PathEqual {
    param([string]$Expected, [string]$Actual, [string]$Message)
    $expectedFull = [IO.Path]::GetFullPath($Expected).TrimEnd('\')
    $actualFull = [IO.Path]::GetFullPath($Actual).TrimEnd('\')
    if (-not [string]::Equals($expectedFull, $actualFull, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Message (expected: $expectedFull, actual: $actualFull)"
    }
}

function Invoke-Ps51Parse {
    param([string]$Path)
    $tokens = $null
    $errors = $null
    [Management.Automation.Language.Parser]::ParseFile(
        [IO.Path]::GetFullPath($Path), [ref]$tokens, [ref]$errors
    ) | Out-Null
    return @($errors)
}

function Invoke-Test {
    param([string]$Name, [scriptblock]$Body)
    & $Body
    $script:Passed++
    Write-Host "PASS: $Name"
}

function Invoke-Installer {
    param([string]$InstallDir)

    $previousPath = $env:PATH
    $previousTestMode = $env:DSH_TEST_MODE
    $previousArchive = $env:DSH_TEST_INSTALL_ARCHIVE
    $previousProfile = $env:USERPROFILE
    $previousTemp = $env:TEMP
    $previousNodeLog = $env:DSH_TEST_NODE_LOG
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $env:PATH = "$fakeBin;$previousPath"
        $env:DSH_TEST_MODE = '1'
        $env:DSH_TEST_INSTALL_ARCHIVE = $archivePath
        $env:USERPROFILE = $profileRoot
        $env:TEMP = $tempRoot
        $env:DSH_TEST_NODE_LOG = $nodeLog
        $ErrorActionPreference = 'Continue'
        $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer `
            -InstallDir $InstallDir -SkipPath 2>&1
        $exitCode = $LASTEXITCODE
        return [pscustomobject]@{
            ExitCode = $exitCode
            Output = [string]($output -join [Environment]::NewLine)
        }
    } finally {
        $env:PATH = $previousPath
        $env:DSH_TEST_MODE = $previousTestMode
        $env:DSH_TEST_INSTALL_ARCHIVE = $previousArchive
        $env:USERPROFILE = $previousProfile
        $env:TEMP = $previousTemp
        $env:DSH_TEST_NODE_LOG = $previousNodeLog
        $ErrorActionPreference = $previousErrorActionPreference
    }
}

function Assert-RejectedInstallTarget {
    param([string]$Target, [string]$Name)

    New-Item -ItemType Directory -Force -Path $Target | Out-Null
    $sentinel = Join-Path $Target 'preserve.txt'
    [IO.File]::WriteAllText($sentinel, 'keep', [Text.Encoding]::ASCII)
    $result = Invoke-Installer -InstallDir $Target
    Assert-True ($result.ExitCode -ne 0) "$Name must be rejected. Output:`n$($result.Output)"
    Assert-True (Test-Path -LiteralPath $sentinel) "$Name must preserve the existing target"
    Assert-Equal 'keep' ([IO.File]::ReadAllText($sentinel)) "$Name sentinel must be unchanged"
}

function Assert-RejectedWithoutWrite {
    param([string]$Target, [string]$Name)

    $result = Invoke-Installer -InstallDir $Target
    Assert-True ($result.ExitCode -ne 0) "$Name must be rejected. Output:`n$($result.Output)"
}

New-Item -ItemType Directory -Force -Path $testRoot, $profileRoot, $tempRoot, $payloadRoot, $fakeBin | Out-Null
try {
    [IO.File]::WriteAllText((Join-Path $payloadRoot 'deepseek.cmd'), '@echo off' + "`r`n", [Text.Encoding]::ASCII)
    Copy-Item -LiteralPath $nodeHelper -Destination (Join-Path $payloadRoot 'dsh-node-version.ps1')
    [IO.File]::WriteAllText((Join-Path $payloadRoot 'sentinel.txt'), 'payload', [Text.Encoding]::ASCII)
    Compress-Archive -Path (Join-Path $payloadRoot '*') -DestinationPath $archivePath -CompressionLevel Optimal

    [IO.File]::WriteAllText(
        (Join-Path $fakeBin 'node.cmd'),
        "@echo off`r`necho %*>>%DSH_TEST_NODE_LOG%`r`necho v22.19.0`r`nexit /b 0`r`n",
        [Text.Encoding]::ASCII
    )
    [IO.File]::WriteAllText(
        (Join-Path $fakeBin 'npm.cmd'),
        "@echo off`r`nif `"%1`"==`"--version`" echo npm-test`r`nexit /b 0`r`n",
        [Text.Encoding]::ASCII
    )

    Invoke-Test 'installer source remains PowerShell 5.1 parseable and ASCII without a BOM' {
        $bytes = [IO.File]::ReadAllBytes($installer)
        Assert-Equal $false ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) 'Installer must not have a BOM'
        Assert-Equal 0 @($bytes | Where-Object { $_ -gt 0x7F }).Count 'Installer source must be ASCII-only'
        Assert-Equal 0 (Invoke-Ps51Parse -Path $installer).Count 'Windows PowerShell 5.1 must parse the installer'
    }

    Invoke-Test 'installer copies a staged archive and executes its shared Node helper' {
        $installDir = Join-Path $profileRoot 'dsh-launcher'
        $result = Invoke-Installer -InstallDir $installDir
        Assert-Equal 0 $result.ExitCode "Installer should copy the staged archive. Output:`n$($result.Output)"
        Assert-True (Test-Path -LiteralPath (Join-Path $installDir 'sentinel.txt')) 'Wildcard copy must include payload files'
        $owner = Get-Content -LiteralPath (Join-Path $installDir '.dsh-launcher-owner.json') -Raw | ConvertFrom-Json
        Assert-Equal 1 $owner.SchemaVersion 'Ownership marker schema must be stable'
        Assert-PathEqual $installDir $owner.InstallPath 'Ownership marker must bind the exact install path'
        Assert-True (-not [string]::IsNullOrWhiteSpace([string]$owner.InstallationId)) 'Ownership marker must include an installation id'
        Assert-True (Test-Path -LiteralPath $nodeLog) 'The archive Node helper must invoke node'
        Assert-True ((Get-Content -LiteralPath $nodeLog -Raw) -match '--version') 'The archive Node helper must perform its version check'
    }

    Invoke-Test 'installer rejects targets outside the isolated profile' {
        Assert-RejectedInstallTarget -Target (Join-Path $testRoot 'outside-profile') -Name 'Outside-profile target'
    }

    Invoke-Test 'installer rejects profile and drive roots before writing' {
        Assert-RejectedWithoutWrite -Target $profileRoot -Name 'Profile root target'
        Assert-RejectedWithoutWrite -Target ([IO.Path]::GetPathRoot($profileRoot)) -Name 'Drive root target'
    }

    Invoke-Test 'installer rejects protected DSH directory roots and children' {
        Assert-RejectedInstallTarget -Target (Join-Path $profileRoot '.dsh') -Name '.dsh root target'
        Assert-RejectedInstallTarget -Target (Join-Path $profileRoot 'dsh-launch') -Name 'dsh-launch root target'
        Assert-RejectedInstallTarget -Target (Join-Path $profileRoot '.dsh\blocked') -Name '.dsh target'
        Assert-RejectedInstallTarget -Target (Join-Path $profileRoot 'dsh-launch\blocked') -Name 'dsh-launch target'
    }

    Invoke-Test 'installer rejects a profile junction that leads into .dsh' {
        $configRoot = Join-Path $profileRoot '.dsh'
        $junction = Join-Path $profileRoot 'config-alias'
        New-Item -ItemType Directory -Force -Path $configRoot | Out-Null
        New-Item -ItemType Junction -Path $junction -Target $configRoot | Out-Null
        Assert-RejectedInstallTarget -Target (Join-Path $junction 'blocked') -Name '.dsh junction target'
    }

    Write-Host "All $script:Passed installer behavior tests passed."
} finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}

exit 0
