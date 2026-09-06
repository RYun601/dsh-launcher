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

# Embedded copy of dsh-maintenance-lock.ps1 (identical mutex name derivation) so
# the one-shot irm|iex installer participates in the same launcher maintenance
# mutex as upgrades, self-updates and uninstalls. Keep in sync with that file.
function Get-DshInstallMaintenanceMutexName {
    param([string]$ProfileRoot)

    $launchRoot = [IO.Path]::GetFullPath((Join-Path $ProfileRoot 'dsh-launch'))
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($launchRoot.ToUpperInvariant())
        $hash = $sha256.ComputeHash($bytes)
        $suffix = -join @($hash[0..11] | ForEach-Object { $_.ToString('x2') })
        return 'Local\DshLauncherMaintenance-' + $suffix
    } finally {
        $sha256.Dispose()
    }
}

function Enter-DshInstallMaintenanceLock {
    param([string]$ProfileRoot)

    $timeoutMilliseconds = 900000
    if ($env:DSH_TEST_MAINTENANCE_TIMEOUT_MS) {
        $timeoutMilliseconds = [int]$env:DSH_TEST_MAINTENANCE_TIMEOUT_MS
    }
    $mutex = [Threading.Mutex]::new($false, (Get-DshInstallMaintenanceMutexName -ProfileRoot $ProfileRoot))
    $owned = $false
    try {
        $owned = $mutex.WaitOne([TimeSpan]::FromMilliseconds($timeoutMilliseconds))
    } catch [Threading.AbandonedMutexException] {
        $owned = $true
    }
    if (-not $owned) {
        $mutex.Dispose()
        throw (ConvertFrom-DshUnicodeText '\u5b89\u88c5\u5931\u8d25\uff1a\u7b49\u5f85\u542f\u52a8\u5668\u7ef4\u62a4\u9501\u8d85\u65f6\uff0c\u53ef\u80fd\u6709\u5b89\u88c5\u3001\u5347\u7ea7\u6216\u81ea\u66f4\u65b0\u6b63\u5728\u8fdb\u884c')
    }
    return $mutex
}

function Exit-DshInstallMaintenanceLock {
    param($Mutex)

    if ($Mutex) {
        try { $Mutex.ReleaseMutex() } catch { }
        $Mutex.Dispose()
    }
}

function Move-DshDirectoryWithRetry {
    param([string]$Source, [string]$Destination)

    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        try {
            Move-Item -LiteralPath $Source -Destination $Destination -ErrorAction Stop
            return $true
        } catch [IO.IOException] {
            Start-Sleep -Milliseconds 100
        }
    }
    return $false
}

function Assert-DshPayloadPackage {
    param([string]$PayloadRoot)

    # Package validation must complete before any payload script is executed
    # (R5): manifest entry files, launcher version, PS 5.1 parseability and the
    # installer BOM guard are all checked against the extracted payload.
    $versionFile = Join-Path $PayloadRoot 'VERSION'
    if (-not (Test-Path -LiteralPath $versionFile -PathType Leaf)) {
        throw (ConvertFrom-DshUnicodeText '\u5b89\u88c5\u5931\u8d25\uff1a\u53d1\u884c\u5305\u7f3a\u5c11 VERSION \u6587\u4ef6')
    }
    $packageVersion = ([string](Get-Content -LiteralPath $versionFile -Raw)).Trim()
    if ($packageVersion -notmatch '^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$') {
        throw (ConvertFrom-DshUnicodeText '\u5b89\u88c5\u5931\u8d25\uff1a\u53d1\u884c\u5305 VERSION \u4e0d\u662f\u6709\u6548\u7248\u672c\u53f7')
    }
    foreach ($requiredFile in @('deepseek.cmd', 'dsh-node-version.ps1')) {
        if (-not (Test-Path -LiteralPath (Join-Path $PayloadRoot $requiredFile) -PathType Leaf)) {
            $message = '\u5b89\u88c5\u5931\u8d25\uff1a\u53d1\u884c\u5305\u7f3a\u5c11\u5fc5\u9700\u6587\u4ef6 ' + $requiredFile
            throw (ConvertFrom-DshUnicodeText $message)
        }
    }
    foreach ($payloadScript in @(Get-ChildItem -LiteralPath $PayloadRoot -Filter '*.ps1' -File -Recurse)) {
        $tokens = $null
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile(
            $payloadScript.FullName, [ref]$tokens, [ref]$errors) | Out-Null
        if ($errors.Count -gt 0) {
            throw (ConvertFrom-DshUnicodeText '\u5b89\u88c5\u5931\u8d25\uff1a\u53d1\u884c\u5305\u5185\u811a\u672c\u65e0\u6cd5\u88ab Windows PowerShell 5.1 \u89e3\u6790') + ': ' + $payloadScript.Name
        }
    }
    $payloadInstaller = Join-Path $PayloadRoot 'install.ps1'
    if (Test-Path -LiteralPath $payloadInstaller -PathType Leaf) {
        $bytes = [IO.File]::ReadAllBytes($payloadInstaller)
        if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
            throw (ConvertFrom-DshUnicodeText '\u5b89\u88c5\u5931\u8d25\uff1a\u53d1\u884c\u5305\u5185 install.ps1 \u5e26\u6709 UTF-8 BOM')
        }
    }
    return $packageVersion
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
$maintenanceMutex = $null
$prepareDir = $null
$oldInstallDir = $null
$installSwapped = $false
$installCommitted = $false
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

    $packageVersion = Assert-DshPayloadPackage -PayloadRoot $payloadRoot

    Write-Host (ConvertFrom-DshUnicodeText '\u6b63\u5728\u68c0\u67e5 Node.js \u73af\u5883...')
    $nodeHelper = Join-Path $payloadRoot 'dsh-node-version.ps1'
    . $nodeHelper
    if (-not (Assert-DshNodeEnvironment)) { exit 1 }
    $npmVer = $null
    try { $npmVer = & npm --version 2>$null } catch { }
    if (-not $npmVer) {
        Write-Host (ConvertFrom-DshUnicodeText '\u672a\u68c0\u6d4b\u5230 npm\uff01\u8bf7\u91cd\u65b0\u5b89\u88c5 Node.js\uff08\u901a\u5e38\u81ea\u5e26 npm\uff09\uff1ahttps://nodejs.org')
        exit 1
    }
    Write-Host "npm $npmVer"

    # R5: the commit phase is transactional. The payload is prepared on the same
    # volume as the install directory, the old installation moves to an adjacent
    # backup, the new payload renames into place, and only after the offline
    # smoke check does the old backup get removed. Any failure restores the old
    # installation; a failed restore keeps the backup and reports its location.
    Write-Host ((ConvertFrom-DshUnicodeText '\u6b63\u5728\u5b89\u88c5\u5230 ') + $InstallDir + ' ...')
    $maintenanceMutex = Enter-DshInstallMaintenanceLock -ProfileRoot $profileFull
    if ($env:DSH_TEST_INSTALL_FAIL_STAGE -eq 'lock') {
        throw 'Injected lock-stage failure'
    }
    $installParent = Split-Path -Parent $installFull
    $prepareDir = Join-Path $installParent ('.dsh-launcher-payload-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $prepareDir | Out-Null
    $payloadItems = @(Get-ChildItem -LiteralPath $payloadRoot -Force -ErrorAction Stop)
    foreach ($payloadItem in $payloadItems) {
        Copy-Item -LiteralPath $payloadItem.FullName -Destination $prepareDir -Recurse -Force
    }
    if ($env:DSH_TEST_INSTALL_FAIL_STAGE -eq 'copy') {
        throw (ConvertFrom-DshUnicodeText '\u6d4b\u8bd5\u6ce8\u5165\uff1a\u53d1\u884c\u5305\u590d\u5236\u5931\u8d25')
    }

    if (Test-Path -LiteralPath $installFull) {
        $oldInstallDir = Join-Path $installParent ('.dsh-launcher-old-' + [guid]::NewGuid().ToString('N'))
        if (-not (Move-DshDirectoryWithRetry -Source $installFull -Destination $oldInstallDir)) {
            $oldInstallDir = $null
            throw (ConvertFrom-DshUnicodeText '\u5b89\u88c5\u5931\u8d25\uff1a\u65e7\u5b89\u88c5\u76ee\u5f55\u88ab\u5360\u7528\uff0c\u65e0\u6cd5\u5b8c\u6210\u4e8b\u52a1\u66ff\u6362\uff1b\u8bf7\u5148\u6267\u884c deepseek --stop \u540e\u91cd\u8bd5')
        }
    }
    $installSwapped = $true
    try {
        Move-Item -LiteralPath $prepareDir -Destination $installFull -ErrorAction Stop
        $prepareDir = $null
    } catch {
        if ($oldInstallDir -and (Test-Path -LiteralPath $oldInstallDir)) {
            if (Move-DshDirectoryWithRetry -Source $oldInstallDir -Destination $installFull) {
                $oldInstallDir = $null
            }
        }
        $installSwapped = $false
        throw
    }
    if ($env:DSH_TEST_INSTALL_FAIL_STAGE -eq 'swap') {
        throw (ConvertFrom-DshUnicodeText '\u6d4b\u8bd5\u6ce8\u5165\uff1a\u76ee\u5f55\u4ea4\u6362\u540e\u5931\u8d25')
    }

    $installed = Test-Path -LiteralPath (Join-Path $installFull 'deepseek.cmd')
    if (-not $installed) {
        throw ((ConvertFrom-DshUnicodeText '\u5b89\u88c5\u5931\u8d25\uff1a\u672a\u627e\u5230 ') + $installFull + '\deepseek.cmd')
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
    if ($env:DSH_TEST_INSTALL_FAIL_STAGE -eq 'marker') {
        throw (ConvertFrom-DshUnicodeText '\u6d4b\u8bd5\u6ce8\u5165\uff1a\u6240\u6709\u6743\u6807\u8bb0\u5199\u5165\u540e\u5931\u8d25')
    }

    # Offline smoke check: the committed file set must carry the exact package
    # version; no Node service, npm access or shortcut work happens here.
    $installedVersion = ([string](Get-Content -LiteralPath (Join-Path $installFull 'VERSION') -Raw)).Trim()
    if ($installedVersion -ne $packageVersion) {
        throw (ConvertFrom-DshUnicodeText '\u5b89\u88c5\u5931\u8d25\uff1a\u5b89\u88c5\u540e VERSION \u4e0e\u53d1\u884c\u5305\u4e0d\u4e00\u81f4')
    }
    if ($env:DSH_TEST_INSTALL_FAIL_STAGE -eq 'smoke') {
        throw (ConvertFrom-DshUnicodeText '\u6d4b\u8bd5\u6ce8\u5165\uff1a\u79bb\u7ebf\u70df\u9727\u9a8c\u8bc1\u5931\u8d25')
    }

    $installCommitted = $true
    if ($oldInstallDir -and (Test-Path -LiteralPath $oldInstallDir)) {
        try {
            Remove-Item -LiteralPath $oldInstallDir -Recurse -Force -ErrorAction Stop
            $oldInstallDir = $null
        } catch {
            Write-Host ((ConvertFrom-DshUnicodeText '\u65e7\u5b89\u88c5\u5907\u4efd\u672a\u80fd\u5220\u9664\uff0c\u5df2\u4fdd\u7559\u5728\uff1a') + $oldInstallDir)
        }
    }
} catch {
    if ($installSwapped -and -not $installCommitted) {
        # R5 recovery: put the previous installation back exactly as it was.
        if (Test-Path -LiteralPath $installFull) {
            try { Remove-Item -LiteralPath $installFull -Recurse -Force -ErrorAction Stop } catch { }
        }
        if ($oldInstallDir -and (Test-Path -LiteralPath $oldInstallDir)) {
            if (Move-DshDirectoryWithRetry -Source $oldInstallDir -Destination $installFull) {
                $oldInstallDir = $null
                Write-Host (ConvertFrom-DshUnicodeText '\u5b89\u88c5\u5931\u8d25\uff0c\u5df2\u6062\u590d\u539f\u6709\u5b89\u88c5')
            } else {
                Write-Host ((ConvertFrom-DshUnicodeText '\u5b89\u88c5\u5931\u8d25\u4e14\u6062\u590d\u672a\u5b8c\u6210\uff0c\u65e7\u5b89\u88c5\u5907\u4efd\u4fdd\u7559\u5728\uff1a') + $oldInstallDir)
            }
        }
    }
    throw
} finally {
    if ($prepareDir -and (Test-Path -LiteralPath $prepareDir)) {
        Remove-Item -LiteralPath $prepareDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    Exit-DshInstallMaintenanceLock -Mutex $maintenanceMutex
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

$desktop = $null
$desktopOverride = [string]$env:DSH_TEST_DESKTOP_DIR
if (-not [string]::IsNullOrWhiteSpace($desktopOverride)) {
    # Test isolation hook (R4): only honored when the injected desktop lies
    # inside the resolved user profile boundary.
    try {
        $desktopCandidate = [IO.Path]::GetFullPath($desktopOverride).TrimEnd('\')
        if ($desktopCandidate.StartsWith($profileFull + '\', [StringComparison]::OrdinalIgnoreCase)) {
            $desktop = $desktopCandidate
        }
    } catch { }
}
if (-not $desktop) {
    $desktop = [Environment]::GetFolderPath('Desktop')
}
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
