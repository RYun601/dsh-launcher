param(
    [string]$InstallDir = (Join-Path $env:USERPROFILE 'dsh-launcher'),
    [switch]$SkipPath,
    [switch]$Shortcut
)

function ConvertFrom-DshUnicodeText {
    param([Parameter(Mandatory = $true)][string]$EscapedText)
    return ConvertFrom-Json ('"' + $EscapedText + '"')
}

function Test-DshChildPath {
    param([string]$Parent, [string]$Candidate)
    $parentFull = [IO.Path]::GetFullPath($Parent).TrimEnd('\')
    $candidateFull = [IO.Path]::GetFullPath($Candidate).TrimEnd('\')
    return $candidateFull.StartsWith($parentFull + '\', [StringComparison]::OrdinalIgnoreCase)
}

if (-not ('DshInstallerPathNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class DshInstallerPathNative
{
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern uint GetLongPathName(string path, StringBuilder buffer, uint capacity);
}
'@
}

function ConvertTo-DshLongPath {
    param([string]$Path)

    $buffer = New-Object Text.StringBuilder 32768
    $length = [DshInstallerPathNative]::GetLongPathName($Path, $buffer, [uint32]$buffer.Capacity)
    if ($length -eq 0 -or $length -ge $buffer.Capacity) {
        throw (ConvertFrom-DshUnicodeText '\u5b89\u88c5\u5931\u8d25\uff1a\u65e0\u6cd5\u89e3\u6790\u5b89\u88c5\u8def\u5f84')
    }
    return $buffer.ToString()
}

function Resolve-DshPathForComparison {
    param([string]$Path)

    $existing = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $missingParts = New-Object Collections.Generic.List[string]
    while (-not (Test-Path -LiteralPath $existing)) {
        $leaf = Split-Path -Leaf $existing
        $parent = Split-Path -Parent $existing
        if ([string]::IsNullOrWhiteSpace($leaf) -or [string]::IsNullOrWhiteSpace($parent) -or
            [string]::Equals($parent, $existing, [StringComparison]::OrdinalIgnoreCase)) {
            throw (ConvertFrom-DshUnicodeText '\u5b89\u88c5\u5931\u8d25\uff1a\u65e0\u6cd5\u89e3\u6790\u5b89\u88c5\u8def\u5f84')
        }
        $missingParts.Insert(0, $leaf)
        $existing = $parent
    }

    $resolved = ConvertTo-DshLongPath -Path $existing
    foreach ($missingPart in $missingParts) {
        $resolved = Join-Path $resolved $missingPart
    }
    return [IO.Path]::GetFullPath($resolved).TrimEnd('\')
}

function Test-DshPathHasReparsePoint {
    param([string]$Parent, [string]$Candidate)

    $parentFull = [IO.Path]::GetFullPath($Parent).TrimEnd('\')
    $current = [IO.Path]::GetFullPath($Candidate).TrimEnd('\')
    while ($true) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                return $true
            }
        }
        if ([string]::Equals($current, $parentFull, [StringComparison]::OrdinalIgnoreCase)) {
            return $false
        }
        $current = Split-Path -Parent $current
        if ([string]::IsNullOrWhiteSpace($current)) {
            return $true
        }
    }
}

# Keep this defense for BOM-prefixed irm | iex input in Windows PowerShell 5.1.
if ($InstallDir -isnot [string] -or $InstallDir -match '(False|\s)$') {
    $InstallDir = Join-Path $env:USERPROFILE 'dsh-launcher'
}
$SkipPath = [bool]$SkipPath

try {
    $__dsh_cp = [Globalization.CultureInfo]::CurrentCulture.TextInfo.ANSICodePage
    if ($__dsh_cp -ne 65001) {
        chcp $__dsh_cp | Out-Null
        $__dsh_enc = [Text.Encoding]::GetEncoding($__dsh_cp)
        [Console]::OutputEncoding = $__dsh_enc
        [Console]::InputEncoding = $__dsh_enc
        $OutputEncoding = $__dsh_enc
    }
} catch { }

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

if ($env:DSH_TEST_MODE -eq '1' -and -not [string]::IsNullOrWhiteSpace($env:DSH_TEST_RESOLVE_PATH)) {
    Write-Output (Resolve-DshPathForComparison -Path $env:DSH_TEST_RESOLVE_PATH)
    exit 0
}

if ([string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
    throw (ConvertFrom-DshUnicodeText '\u5b89\u88c5\u5931\u8d25\uff1aUSERPROFILE \u4e0d\u53ef\u7528')
}

$profileInput = [IO.Path]::GetFullPath($env:USERPROFILE).TrimEnd('\')
$installInput = [IO.Path]::GetFullPath($InstallDir).TrimEnd('\')
$installDriveRoot = [IO.Path]::GetPathRoot($installInput).TrimEnd('\')

if ($installInput -eq $installDriveRoot) {
    throw (ConvertFrom-DshUnicodeText '\u5b89\u88c5\u5931\u8d25\uff1a\u5b89\u88c5\u8def\u5f84\u4e0d\u80fd\u662f\u9a71\u52a8\u5668\u6839\u76ee\u5f55')
}
if (-not (Test-DshChildPath -Parent $profileInput -Candidate $installInput)) {
    throw (ConvertFrom-DshUnicodeText '\u5b89\u88c5\u5931\u8d25\uff1a\u5b89\u88c5\u8def\u5f84\u5fc5\u987b\u4f4d\u4e8e USERPROFILE \u4e4b\u4e0b')
}
if (Test-DshPathHasReparsePoint -Parent $profileInput -Candidate $installInput) {
    throw (ConvertFrom-DshUnicodeText '\u5b89\u88c5\u5931\u8d25\uff1a\u5b89\u88c5\u8def\u5f84\u4e0d\u80fd\u7ecf\u8fc7\u91cd\u89e3\u6790\u70b9')
}
$profileFull = Resolve-DshPathForComparison -Path $profileInput
$installFull = Resolve-DshPathForComparison -Path $installInput
if (-not (Test-DshChildPath -Parent $profileFull -Candidate $installFull)) {
    throw (ConvertFrom-DshUnicodeText '\u5b89\u88c5\u5931\u8d25\uff1a\u5b89\u88c5\u8def\u5f84\u5fc5\u987b\u4f4d\u4e8e USERPROFILE \u4e4b\u4e0b')
}
$dshConfigRoot = Join-Path $profileFull '.dsh'
$launchDataRoot = Join-Path $profileFull 'dsh-launch'
if ($installFull -eq $dshConfigRoot -or (Test-DshChildPath -Parent $dshConfigRoot -Candidate $installFull)) {
    throw (ConvertFrom-DshUnicodeText '\u5b89\u88c5\u5931\u8d25\uff1a\u4e0d\u80fd\u5199\u5165 .dsh \u914d\u7f6e\u76ee\u5f55')
}
if ($installFull -eq $launchDataRoot -or (Test-DshChildPath -Parent $launchDataRoot -Candidate $installFull)) {
    throw (ConvertFrom-DshUnicodeText '\u5b89\u88c5\u5931\u8d25\uff1a\u4e0d\u80fd\u5199\u5165 dsh-launch \u8fd0\u884c\u6570\u636e\u76ee\u5f55')
}
$InstallDir = $installFull

$tmp = Join-Path $env:TEMP ('dsh-launcher-' + [guid]::NewGuid().ToString('N') + '.zip')
if ($env:DSH_TEST_MODE -eq '1' -and -not [string]::IsNullOrWhiteSpace($env:DSH_TEST_INSTALL_ARCHIVE)) {
    if (-not (Test-Path -LiteralPath $env:DSH_TEST_INSTALL_ARCHIVE -PathType Leaf)) {
        throw "Test archive is missing: $env:DSH_TEST_INSTALL_ARCHIVE"
    }
    Copy-Item -LiteralPath $env:DSH_TEST_INSTALL_ARCHIVE -Destination $tmp -Force
} else {
    $api = 'https://api.github.com/repos/RYun601/dsh-launcher/releases/latest'
    Write-Host (ConvertFrom-DshUnicodeText '\u6b63\u5728\u83b7\u53d6\u6700\u65b0\u7248\u672c\u4fe1\u606f...')
    $rel = Invoke-RestMethod -Uri $api -Headers @{ 'User-Agent' = 'dsh-installer' }
    $asset = $rel.assets | Where-Object { $_.name -eq 'dsh-launcher.zip' } | Select-Object -First 1
    if (-not $asset) { throw (ConvertFrom-DshUnicodeText '\u672a\u627e\u5230 dsh-launcher.zip \u53d1\u5e03\u5305') }
    Write-Host ((ConvertFrom-DshUnicodeText '\u6700\u65b0\u7248\u672c\uff1a') + $rel.tag_name)
    Write-Host ((ConvertFrom-DshUnicodeText '\u6b63\u5728\u4e0b\u8f7d ') + $asset.name + ' ...')
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $tmp -Headers @{ 'User-Agent' = 'dsh-installer' }
}

$staging = Join-Path $env:TEMP ('dsh-launcher-staging-' + [guid]::NewGuid().ToString('N'))
try {
    Expand-Archive -LiteralPath $tmp -DestinationPath $staging -Force
    $stageEntry = Join-Path $staging 'deepseek.cmd'
    if (-not (Test-Path -LiteralPath $stageEntry)) {
        $nested = Join-Path $staging 'dsh-launcher'
        if (Test-Path -LiteralPath (Join-Path $nested 'deepseek.cmd')) {
            $stageEntry = Join-Path $nested 'deepseek.cmd'
        }
    }
    if (-not (Test-Path -LiteralPath $stageEntry)) {
        throw (ConvertFrom-DshUnicodeText '\u4e0b\u8f7d\u5305\u4e2d\u672a\u627e\u5230 deepseek.cmd')
    }
    $payloadRoot = Split-Path -Parent $stageEntry
    $nodeHelper = Join-Path $payloadRoot 'dsh-node-version.ps1'
    if (-not (Test-Path -LiteralPath $nodeHelper)) {
        throw (ConvertFrom-DshUnicodeText '\u4e0b\u8f7d\u5305\u4e2d\u672a\u627e\u5230 Node.js \u68c0\u67e5\u811a\u672c')
    }

    Write-Host (ConvertFrom-DshUnicodeText '\u6b63\u5728\u68c0\u67e5 Node.js \u73af\u5883...')
    . $nodeHelper
    if (-not (Assert-DshNodeEnvironment)) { exit 1 }
    $npmVer = $null
    try { $npmVer = & npm --version 2>$null } catch { }
    if (-not $npmVer) {
        Write-Host (ConvertFrom-DshUnicodeText '\u672a\u68c0\u6d4b\u5230 npm\uff01\u8bf7\u91cd\u65b0\u5b89\u88c5 Node.js\uff08\u901a\u5e38\u81ea\u5e26 npm\uff09\uff1ahttps://nodejs.org')
        exit 1
    }
    Write-Host "npm $npmVer"

    Write-Host ((ConvertFrom-DshUnicodeText '\u6b63\u5728\u5b89\u88c5\u5230 ') + $InstallDir + ' ...')
    if (Test-Path -LiteralPath $InstallDir) {
        Write-Host (ConvertFrom-DshUnicodeText '\u76ee\u5f55\u5df2\u5b58\u5728\uff0c\u5c06\u8986\u76d6\u66f4\u65b0\u5176\u4e2d\u7684\u6587\u4ef6')
    }
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    $payloadItems = @(Get-ChildItem -LiteralPath $payloadRoot -Force -ErrorAction Stop)
    foreach ($payloadItem in $payloadItems) {
        Copy-Item -LiteralPath $payloadItem.FullName -Destination $installFull -Recurse -Force
    }

    $installed = Test-Path -LiteralPath (Join-Path $InstallDir 'deepseek.cmd')
    if (-not $installed) {
        throw ((ConvertFrom-DshUnicodeText '\u5b89\u88c5\u5931\u8d25\uff1a\u672a\u627e\u5230 ') + $InstallDir + '\deepseek.cmd')
    }
    $owner = [ordered]@{
        SchemaVersion = 1
        InstallPath = $installFull
        InstallationId = [guid]::NewGuid().ToString('N')
    }
    [IO.File]::WriteAllText(
        (Join-Path $installFull '.dsh-launcher-owner.json'),
        ($owner | ConvertTo-Json),
        [Text.UTF8Encoding]::new($false)
    )
} finally {
    Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
}

if (-not $SkipPath) {
    $p = [Environment]::GetEnvironmentVariable('Path', 'User')
    $target = $InstallDir.TrimEnd('\')
    if ($p -split ';' -contains $target) {
        Write-Host ((ConvertFrom-DshUnicodeText 'PATH \u5df2\u5305\u542b ') + $target)
    } else {
        [Environment]::SetEnvironmentVariable('Path', (($p.TrimEnd(';')) + ';' + $target), 'User')
        Write-Host ((ConvertFrom-DshUnicodeText '\u5df2\u6dfb\u52a0\u5230\u7528\u6237 PATH\uff1a') + $target)
    }
}

$desktop = [Environment]::GetFolderPath('Desktop')
if (-not [string]::IsNullOrWhiteSpace($desktop)) {
    $lnkPath = Join-Path $desktop 'DeepSeek Harness.lnk'
    $shortcutExists = Test-Path -LiteralPath $lnkPath
    if ($Shortcut -or $shortcutExists) {
        $shortcutScript = Join-Path $InstallDir 'set-shortcut.ps1'
        if (-not (Test-Path -LiteralPath $shortcutScript)) {
            throw ((ConvertFrom-DshUnicodeText '\u5b89\u88c5\u5931\u8d25\uff1a\u672a\u627e\u5230\u5feb\u6377\u65b9\u5f0f\u914d\u7f6e\u811a\u672c ') + $shortcutScript)
        }

        $shortcutResult = [string](& $shortcutScript -InstallDir $InstallDir -ShortcutPath $lnkPath -Create:$Shortcut)
        if ($shortcutResult -like 'CREATED:*') {
            Write-Host ((ConvertFrom-DshUnicodeText '\u5df2\u521b\u5efa\u684c\u9762\u5feb\u6377\u65b9\u5f0f\uff1a') + $lnkPath)
        } elseif ($shortcutResult -like 'UPDATED:*') {
            Write-Host ((ConvertFrom-DshUnicodeText '\u5df2\u66f4\u65b0\u684c\u9762\u5feb\u6377\u65b9\u5f0f\uff1a') + $lnkPath)
        } elseif ($Shortcut) {
            throw ((ConvertFrom-DshUnicodeText '\u684c\u9762\u5feb\u6377\u65b9\u5f0f\u521b\u5efa\u5931\u8d25\uff1a') + $lnkPath)
        } else {
            Write-Host (ConvertFrom-DshUnicodeText '\u68c0\u6d4b\u5230\u975e\u672c\u542f\u52a8\u5668\u7ba1\u7406\u7684\u540c\u540d\u5feb\u6377\u65b9\u5f0f\uff0c\u5df2\u4fdd\u7559')
        }
    }
} elseif ($Shortcut) {
    throw (ConvertFrom-DshUnicodeText '\u684c\u9762\u5feb\u6377\u65b9\u5f0f\u76ee\u5f55\u4e0d\u53ef\u7528')
}

Write-Host ''
Write-Host (ConvertFrom-DshUnicodeText '\u5b89\u88c5\u5b8c\u6210\uff01\u8bf7\u65b0\u5f00\u4e00\u4e2a\u7ec8\u7aef\u7a97\u53e3\uff0c\u7136\u540e\u8f93\u5165 deepseek \u5f00\u59cb\u4f7f\u7528\u3002')
Write-Host (ConvertFrom-DshUnicodeText '  deepseek -b    \u540e\u53f0\u542f\u52a8\uff08\u63a8\u8350\uff09')
Write-Host (ConvertFrom-DshUnicodeText '  deepseek --help  \u67e5\u770b\u5168\u90e8\u547d\u4ee4')
