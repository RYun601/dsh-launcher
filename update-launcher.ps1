param(
    [switch]$CheckOnly,
    [switch]$Upgrade
)

# —— 控制台编码修复 ——
# 与 update-check.ps1 相同：传统控制台下把控制台代码页与输出编码统一回系统 ANSI 代码页。
try {
    $__dsh_cp = [Globalization.CultureInfo]::CurrentCulture.TextInfo.ANSICodePage
    if ($__dsh_cp -ne 65001) {
        chcp $__dsh_cp | Out-Null
        $__dsh_enc = [Text.Encoding]::GetEncoding($__dsh_cp)
        [Console]::OutputEncoding = $__dsh_enc
        [Console]::InputEncoding  = $__dsh_enc
        $OutputEncoding = $__dsh_enc
    }
} catch { }

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$scriptDir = (Split-Path -Parent $MyInvocation.MyCommand.Path).TrimEnd('\')
. (Join-Path $scriptDir 'dsh-version.ps1')
. (Join-Path $scriptDir 'dsh-maintenance-lock.ps1')
$stateHelper = Join-Path $scriptDir 'dsh-launch-state.ps1'

# 退出码契约（设计文档 §3.2）：
#   0 = 检查成功 / 已是最新 / 本地较新 / 更新成功
#   1 = 参数、网络、包验证、安装边界、安装忙等失败；或更新失败但已恢复原版本
#   2 = 更新失败且自动恢复未完成（保留恢复副本与事务记录）
$script:exitCode = 1

function Get-UpdateTempRoot {
    return [IO.Path]::GetFullPath($env:TEMP)
}

function Get-LocalLauncherVersion {
    $versionFile = Join-Path $scriptDir 'VERSION'
    if (-not (Test-Path -LiteralPath $versionFile -PathType Leaf)) { return '' }
    try {
        return ([string](Get-Content -LiteralPath $versionFile -Raw)).Trim()
    } catch {
        return ''
    }
}

function ConvertTo-DshLauncherUpdateSemVer {
    param([string]$Version)
    if (-not $Version) { return $null }
    return ConvertTo-DshSemVer $Version
}

# 查询 GitHub 最新稳定发行版。测试通过 DSH_TEST_UPDATE_API 注入本地 JSON 文件。
function Get-LatestLauncherRelease {
    $api = 'https://api.github.com/repos/RYun601/dsh-launcher/releases/latest'
    $release = $null
    if ($env:DSH_TEST_UPDATE_API) {
        $apiFile = $env:DSH_TEST_UPDATE_API
        if (-not (Test-Path -LiteralPath $apiFile -PathType Leaf)) {
            throw "DSH_TEST_UPDATE_API 文件不存在：$apiFile"
        }
        $release = Get-Content -LiteralPath $apiFile -Raw -Encoding UTF8 | ConvertFrom-Json
    } else {
        try {
            $release = Invoke-RestMethod -Uri $api -Headers @{ 'User-Agent' = 'dsh-launcher-self-update' } -TimeoutSec 30
        } catch {
            $reason = $_.Exception.Message
            if ($_.Exception.Response) {
                $statusCode = [int]$_.Exception.Response.StatusCode
                if ($statusCode -eq 403) { $reason = 'GitHub API 限流（403），请稍后重试' }
                elseif ($statusCode -eq 404) { $reason = '仓库没有可用发行版（404）' }
                else { $reason = "HTTP $statusCode" }
            }
            throw "无法查询 GitHub 最新发行版：$reason"
        }
    }
    if (-not $release) { throw '无法查询 GitHub 最新发行版：响应为空' }

    $tag = ''
    if ($release.PSObject.Properties['tag_name']) { $tag = [string]$release.tag_name }
    $tagMatch = [regex]::Match($tag, '^v(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$')
    if (-not $tagMatch.Success) {
        throw "最新发行标签无效（应为 v<VERSION> 形式）：$tag"
    }
    $targetVersion = $tag.Substring(1)

    $asset = $null
    if ($release.PSObject.Properties['assets'] -and $release.assets) {
        $matching = @($release.assets | Where-Object { [string]$_.name -eq 'dsh-launcher.zip' })
        if ($matching.Count -eq 1) { $asset = $matching[0] }
        elseif ($matching.Count -gt 1) { throw '发行包资产异常：存在多个 dsh-launcher.zip' }
    }
    if (-not $asset) { throw '最新发行版缺少 dsh-launcher.zip 资产' }

    $digest = ''
    $digestSource = 'missing'
    if ($asset.PSObject.Properties['digest'] -and $asset.digest) {
        $apiDigest = [string]$asset.digest
        $digestMatch = [regex]::Match($apiDigest, '^sha256:([0-9a-fA-F]{64})$')
        if ($digestMatch.Success) {
            $digest = $digestMatch.Groups[1].Value.ToLowerInvariant()
            $digestSource = 'api'
        }
    }
    $sidecar = $null
    if ($release.PSObject.Properties['assets'] -and $release.assets) {
        $sidecars = @($release.assets | Where-Object { [string]$_.name -eq 'dsh-launcher.zip.sha256' })
        if ($sidecars.Count -eq 1) { $sidecar = $sidecars[0] }
    }
    if (-not $digest -and $sidecar) {
        $digestSource = 'sidecar-asset'
    }

    return [pscustomobject]@{
        Tag = $tag
        Version = $targetVersion
        AssetUrl = [string]$asset.browser_download_url
        AssetSize = [int64]$asset.size
        Digest = $digest
        DigestSource = $digestSource
        SidecarUrl = if ($sidecar) { [string]$sidecar.browser_download_url } else { '' }
    }
}

function Get-DshFileSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $stream = [IO.File]::OpenRead($Path)
        try {
            $hash = $sha256.ComputeHash($stream)
        } finally {
            $stream.Dispose()
        }
        return ((($hash | ForEach-Object { $_.ToString('x2') }) -join '').ToLowerInvariant())
    } finally {
        $sha256.Dispose()
    }
}

function Test-DshUpdateZipEntries {
    param([Parameter(Mandatory = $true)][string]$ZipPath)

    Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null
    $zip = [IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        if ($zip.Entries.Count -gt 2000) { throw '发行包条目数量异常' }
        $seen = @{}
        foreach ($entry in $zip.Entries) {
            $name = ([string]$entry.FullName).Replace('/', '\')
            if (-not $name) { throw '发行包含有空条目' }
            if ($name -match '^[A-Za-z]:') { throw "发行包含有盘符路径条目：$name" }
            if ($name.Contains(':')) { throw "发行包含有非法流路径条目：$name" }
            if ($name.StartsWith('\') -or $name.StartsWith('\\')) { throw "发行包含有绝对路径条目：$name" }
            if ($name -eq '..\' -or $name.StartsWith('..\') -or $name.Contains('\..\')) {
                throw "发行包含有路径穿越条目：$name"
            }
            $key = $name.ToLowerInvariant().TrimEnd('\')
            if ($seen.ContainsKey($key)) { throw "发行包含有大小写归一后的重名条目：$name" }
            $seen[$key] = $true
            if ($entry.Length -gt 512MB) { throw "发行包条目超出大小限制：$name" }
        }
    } finally {
        $zip.Dispose()
    }
}

function Assert-DshUpdatePackage {
    param(
        [Parameter(Mandatory = $true)][string]$PayloadRoot,
        [Parameter(Mandatory = $true)][string]$ExpectedVersion
    )

    $versionFile = Join-Path $PayloadRoot 'VERSION'
    if (-not (Test-Path -LiteralPath $versionFile -PathType Leaf)) {
        throw '发行包缺少 VERSION 文件'
    }
    $packageVersion = ([string](Get-Content -LiteralPath $versionFile -Raw)).Trim()
    if ($packageVersion -ne $ExpectedVersion) {
        throw "发行包内 VERSION（$packageVersion）与发行标签（$ExpectedVersion）不一致"
    }
    foreach ($requiredFile in @('deepseek.cmd', 'dsh-node-version.ps1', 'release-files.txt')) {
        if (-not (Test-Path -LiteralPath (Join-Path $PayloadRoot $requiredFile) -PathType Leaf)) {
            throw "发行包缺少必需文件：$requiredFile"
        }
    }
    foreach ($payloadScript in @(Get-ChildItem -LiteralPath $PayloadRoot -Filter '*.ps1' -File -Recurse)) {
        $tokens = $null
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile(
            $payloadScript.FullName, [ref]$tokens, [ref]$errors) | Out-Null
        if ($errors.Count -gt 0) {
            throw "发行包内脚本无法被 Windows PowerShell 5.1 解析：$($payloadScript.Name)"
        }
    }
    $payloadInstaller = Join-Path $PayloadRoot 'install.ps1'
    if (Test-Path -LiteralPath $payloadInstaller -PathType Leaf) {
        $bytes = [IO.File]::ReadAllBytes($payloadInstaller)
        if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
            throw '发行包内 install.ps1 带有 UTF-8 BOM'
        }
    }
    # 用包内自带清单核对完整文件集合（设计 §5.7）：多文件、少文件都拒绝。
    $manifestLines = @(Get-Content -LiteralPath (Join-Path $PayloadRoot 'release-files.txt') | ForEach-Object {
        ([string]$_).Trim()
    } | Where-Object { $_ -and -not $_.StartsWith('#') } | ForEach-Object { $_.Replace('/', '\').ToLowerInvariant() })
    $manifestSet = New-Object System.Collections.Generic.HashSet[string]([StringComparer]::OrdinalIgnoreCase)
    foreach ($line in $manifestLines) { $manifestSet.Add($line) | Out-Null }
    if ($manifestSet.Count -eq 0) { throw '发行包清单（release-files.txt）为空' }
    $actualSet = New-Object System.Collections.Generic.HashSet[string]([StringComparer]::OrdinalIgnoreCase)
    foreach ($item in @(Get-ChildItem -LiteralPath $PayloadRoot -Recurse -File)) {
        $relative = $item.FullName.Substring($PayloadRoot.Length + 1).Replace('/', '\').ToLowerInvariant()
        $actualSet.Add($relative) | Out-Null
    }
    foreach ($missing in @($manifestSet | Where-Object { -not $actualSet.Contains($_) })) {
        throw "发行包缺少清单声明的文件：$missing"
    }
    foreach ($extra in @($actualSet | Where-Object { -not $manifestSet.Contains($_) })) {
        throw "发行包存在清单之外的文件：$extra"
    }
    return $packageVersion
}

function Test-DshUpdateSourceTree {
    param([Parameter(Mandatory = $true)][string]$InstallDir)

    # 源码工作树绝不能被自动覆盖（设计 §4）。
    $current = $InstallDir
    while ($true) {
        if (Test-Path -LiteralPath (Join-Path $current '.git')) { return $true }
        $parent = Split-Path -Parent $current
        if (-not $parent -or [string]::Equals($parent, $current, [StringComparison]::OrdinalIgnoreCase)) {
            return $false
        }
        $current = $parent
    }
}

function Test-DshServiceBusy {
    $lockOutput = [string]((& $stateHelper -Action TestStartupLock) -join '')
    if ($lockOutput -match '^LOCKED\s+\d+') { return "已有 DeepSeek Harness 实例正在运行或启动（$lockOutput）" }
    $upgradeTransaction = Join-Path $env:USERPROFILE 'dsh-launch\runtime-upgrade.json'
    if (Test-Path -LiteralPath $upgradeTransaction -PathType Leaf) {
        return "DSH 升级事务尚未结束：$upgradeTransaction"
    }
    return ''
}

function Move-DshUpdateDirectory {
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

function Write-DshUpdateRecoverScript {
    param([string]$TransactionDir, [string]$InstallPath, [string]$BackupPath, [string]$TargetVersion)

    # 可直接运行的恢复执行器（设计 §6）：更新中断后原入口不可用时，
    # 用户按输出提示运行它即可把旧安装移回原位。
    $recoverScript = Join-Path $TransactionDir 'recover-launcher.ps1'
    $installLiteral = $InstallPath.Replace("'", "''")
    $backupLiteral = $BackupPath.Replace("'", "''")
    $targetLiteral = $TargetVersion.Replace("'", "''")
    $content = @"
param([switch]`$Force)
`$ErrorActionPreference = 'Stop'
`$installPath = '$installLiteral'
`$backupPath = '$backupPath'
`$targetVersion = '$targetLiteral'
if (-not (Test-Path -LiteralPath `$backupPath)) {
    Write-Host "[ERROR] 恢复副本不存在：`$backupPath"
    exit 1
}
`$currentVersion = ''
`$versionFile = Join-Path `$installPath 'VERSION'
if (Test-Path -LiteralPath `$versionFile -PathType Leaf) {
    try { `$currentVersion = ([string](Get-Content -LiteralPath `$versionFile -Raw)).Trim() } catch { }
}
# 需要恢复的两种情况：安装位置已损坏（缺少 deepseek.cmd），
# 或该位置放置的是本次更新失败的候选（VERSION 等于目标版本）。
`$installBroken = -not (Test-Path -LiteralPath (Join-Path `$installPath 'deepseek.cmd') -PathType Leaf)
`$looksLikeFailedCandidate = (`$currentVersion -eq `$targetVersion)
if (-not (`$installBroken -or `$looksLikeFailedCandidate) -and -not `$Force) {
    Write-Host '[INFO] 原安装位置仍然可用，未做任何更改。'
    exit 0
}
if (Test-Path -LiteralPath `$installPath) {
    Remove-Item -LiteralPath `$installPath -Recurse -Force
}
Move-Item -LiteralPath `$backupPath -Destination `$installPath
Write-Host "已把旧版启动器（恢复到 `$installPath）恢复完毕。"
exit 0
"@
    # 带签名写出：恢复脚本包含中文提示，必须带 BOM 让 Windows PowerShell 5.1
    # 按 UTF-8 读取（无 BOM 文件会按 ANSI 解码，多字节尾部会吞掉换行）。
    [IO.File]::WriteAllText($recoverScript, $content, [Text.UTF8Encoding]::new($true))
    return $recoverScript
}

# ============================== 主流程 ==============================

if ($CheckOnly -and $Upgrade) {
    Write-Host '[ERROR] --CheckOnly 与 -Upgrade 不能同时使用。'
    exit 1
}

$localVersion = Get-LocalLauncherVersion
$localVersionValid = $false
if ($localVersion -and (ConvertTo-DshLauncherUpdateSemVer $localVersion)) {
    $localVersionValid = $true
}
if (-not $localVersionValid) {
    Write-Host "[ERROR] 当前安装目录缺少有效的启动器版本号（VERSION = '$localVersion'）。"
    Write-Host '自动更新已拒绝执行；请重新运行官方安装脚本修复安装。'
    exit 1
}
Write-Host "启动器当前版本：$localVersion"

$release = $null
try {
    $release = Get-LatestLauncherRelease
} catch {
    Write-Host "[ERROR] $($_.Exception.Message)"
    exit 1
}
$targetVersion = $release.Version
Write-Host "GitHub 稳定发行版：$($release.Tag)"

$comparison = Compare-DshVersion $localVersion $targetVersion
if ($comparison -gt 0) {
    Write-Host "当前安装的启动器（$localVersion）比稳定发行版（$targetVersion）更新，无需更新。"
    exit 0
}
if ($comparison -eq 0) {
    Write-Host '启动器已是最新版本。'
    exit 0
}
Write-Host "发现新版本：$localVersion -> $targetVersion"
if (-not $Upgrade) {
    Write-Host '执行 deepseek --upgrade-launcher 开始更新启动器（更新前请先 deepseek --stop 停止服务）。'
    exit 0
}

# —— 以下为执行路径：任何失败都必须保持旧安装可用 ——

$installFull = $scriptDir
$profileFull = ''
try {
    $profileFull = [IO.Path]::GetFullPath($env:USERPROFILE).TrimEnd('\')
} catch {
    Write-Host '[ERROR] USERPROFILE 不可用，无法验证安装边界。'
    exit 1
}
$dshConfigRoot = [IO.Path]::GetFullPath((Join-Path $profileFull '.dsh')).TrimEnd('\')
$launchDataRoot = [IO.Path]::GetFullPath((Join-Path $profileFull 'dsh-launch')).TrimEnd('\')
foreach ($protectedRoot in @($dshConfigRoot, $launchDataRoot)) {
    if ([string]::Equals($installFull, $protectedRoot, [StringComparison]::OrdinalIgnoreCase) -or
            $installFull.StartsWith($protectedRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
        Write-Host "[ERROR] 安装目录位于受保护数据目录内，拒绝自动更新：$installFull"
        exit 1
    }
}
if ([string]::Equals($installFull, $profileFull, [StringComparison]::OrdinalIgnoreCase)) {
    Write-Host "[ERROR] 安装目录不能是用户主目录：$installFull"
    exit 1
}
if (Test-DshUpdateSourceTree -InstallDir $installFull) {
    Write-Host "[ERROR] 当前目录是源码工作树（发现 .git），拒绝自动覆盖；请使用 git pull 或官方安装包。"
    exit 1
}
$ownerMarkerPath = Join-Path $installFull '.dsh-launcher-owner.json'
if (-not (Test-Path -LiteralPath $ownerMarkerPath -PathType Leaf)) {
    Write-Host '[ERROR] 当前目录缺少启动器所有权标记（.dsh-launcher-owner.json），可能是手动解压或旧版安装。'
    Write-Host '第一版自更新仅支持受管安装；请使用官方安装脚本更新。'
    exit 1
}
try {
    $ownerMarker = Get-Content -LiteralPath $ownerMarkerPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $markedPath = [IO.Path]::GetFullPath([string]$ownerMarker.InstallPath).TrimEnd('\')
} catch {
    Write-Host '[ERROR] 所有权标记无法解析，拒绝自动更新。'
    exit 1
}
# 设计 §4：更新必须保留原 InstallationId 与最终安装路径。
$preservedInstallationId = ''
if ($ownerMarker.PSObject.Properties['InstallationId']) {
    $preservedInstallationId = [string]$ownerMarker.InstallationId
}
if (-not [string]::Equals($markedPath, $installFull, [StringComparison]::OrdinalIgnoreCase)) {
    Write-Host "[ERROR] 所有权标记与当前安装目录不一致（标记指向 $markedPath），拒绝自动更新。"
    exit 1
}

$busyReason = Test-DshServiceBusy
if ($busyReason) {
    Write-Host "[ERROR] 启动器忙，拒绝更新：$busyReason"
    Write-Host '请先执行 deepseek --stop，并等待 DSH 升级事务结束后重试。'
    exit 1
}

$transactionId = [guid]::NewGuid().ToString('N')
$transactionDir = Join-Path (Get-UpdateTempRoot) ('dsh-launcher-update-' + $transactionId)
Write-Host "更新事务目录：$transactionDir（中断恢复脚本将保存在此处）"
$zipPath = Join-Path $transactionDir 'dsh-launcher.zip'
$staging = $null
$prepareDir = $null
$oldInstallDir = $null
$maintenanceMutex = $null
$updateCommitted = $false
$updateSwapped = $false
$recoverScriptPath = ''
try {
    New-Item -ItemType Directory -Force -Path $transactionDir | Out-Null

    # 1) 下载与校验（锁外完成，减少维护锁持有时长）
    $expectedDigest = $release.Digest
    if ($release.DigestSource -eq 'sidecar-asset') {
        $sidecarPath = Join-Path $transactionDir 'dsh-launcher.zip.sha256'
        if ($env:DSH_TEST_UPDATE_FILES) {
            $testSidecar = Join-Path $env:DSH_TEST_UPDATE_FILES 'dsh-launcher.zip.sha256'
            if (-not (Test-Path -LiteralPath $testSidecar -PathType Leaf)) {
                throw '发行版缺少 SHA-256 校验材料，无法安全地自动更新；请手动下载官方安装包更新。'
            }
            Copy-Item -LiteralPath $testSidecar -Destination $sidecarPath -Force
        } else {
            Invoke-WebRequest -Uri $release.SidecarUrl -OutFile $sidecarPath `
                -Headers @{ 'User-Agent' = 'dsh-launcher-self-update' } -TimeoutSec 60
        }
        $sidecarText = ([string](Get-Content -LiteralPath $sidecarPath -Raw)).Trim()
        $digestMatch = [regex]::Match($sidecarText, '(?:^|\s)([0-9a-fA-F]{64})(?:\s|$)')
        if (-not $digestMatch.Success) { throw 'SHA-256 校验文件格式无效' }
        $expectedDigest = $digestMatch.Groups[1].Value.ToLowerInvariant()
    }
    if (-not $expectedDigest) {
        throw '发行版缺少 SHA-256 校验材料，无法安全地自动更新；请手动下载官方安装包更新。'
    }
    if ($env:DSH_TEST_UPDATE_FILES) {
        $sourceZip = Join-Path $env:DSH_TEST_UPDATE_FILES 'dsh-launcher.zip'
        if (-not (Test-Path -LiteralPath $sourceZip -PathType Leaf)) {
            throw "测试发行包不存在：$sourceZip"
        }
        Copy-Item -LiteralPath $sourceZip -Destination $zipPath -Force
    } else {
        Write-Host "正在下载 dsh-launcher.zip（$([Math]::Round($release.AssetSize / 1KB, 1)) KB）..."
        Invoke-WebRequest -Uri $release.AssetUrl -OutFile $zipPath `
            -Headers @{ 'User-Agent' = 'dsh-launcher-self-update' } -TimeoutSec 600
    }
    $actualSize = (Get-Item -LiteralPath $zipPath).Length
    if ($actualSize -le 0 -or $actualSize -gt 512MB) {
        throw "下载的发行包大小异常：$actualSize 字节"
    }
    $actualDigest = Get-DshFileSha256 -Path $zipPath
    if ($actualDigest -ne $expectedDigest) {
        throw "发行包 SHA-256 校验失败（期望 $expectedDigest，实际 $actualDigest）"
    }
    Write-Host '发行包校验通过（SHA-256）。'

    # 2) 解压与包验证
    Test-DshUpdateZipEntries -ZipPath $zipPath
    $staging = Join-Path $transactionDir 'staging'
    Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null
    [IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $staging)
    foreach ($extracted in @(Get-ChildItem -LiteralPath $staging -Recurse -File)) {
        $extractedFull = [IO.Path]::GetFullPath($extracted.FullName)
        if (-not $extractedFull.StartsWith($staging + '\', [StringComparison]::OrdinalIgnoreCase)) {
            throw "解压后出现暂存目录之外的文件：$($extracted.FullName)"
        }
    }
    $stageEntry = Join-Path $staging 'deepseek.cmd'
    $nestedRoot = Join-Path $staging 'dsh-launcher'
    $payloadRoot = ''
    if ((Test-Path -LiteralPath $stageEntry -PathType Leaf) -and (Test-Path -LiteralPath (Join-Path $nestedRoot 'deepseek.cmd') -PathType Leaf)) {
        throw '发行包结构异常：根目录与 dsh-launcher 子目录同时包含入口'
    }
    if (Test-Path -LiteralPath $stageEntry -PathType Leaf) {
        $payloadRoot = $staging
    } elseif (Test-Path -LiteralPath (Join-Path $nestedRoot 'deepseek.cmd') -PathType Leaf) {
        $payloadRoot = $nestedRoot
    } else {
        throw '发行包中未找到 deepseek.cmd'
    }
    Assert-DshUpdatePackage -PayloadRoot $payloadRoot -ExpectedVersion $targetVersion | Out-Null
    Write-Host "发行包验证完成：$targetVersion"

    # 3) 维护锁与复检（设计 §3.3：锁外只做下载，提交前必须复检）
    $maintenanceMutex = Enter-DshMaintenanceLock
    $currentLocalVersion = Get-LocalLauncherVersion
    if ($currentLocalVersion -ne $localVersion) {
        throw "等待维护锁期间安装被其他事务修改（$localVersion -> $currentLocalVersion），更新已取消。"
    }
    $busyReason = Test-DshServiceBusy
    if ($busyReason) {
        throw "维护锁复检发现启动器忙：$busyReason"
    }

    # 4) 同卷准备 payload（跨卷暂存目录不能直接作为重命名来源）
    $installParent = Split-Path -Parent $installFull
    $prepareDir = Join-Path $installParent ('.dsh-launcher-payload-' + $transactionId)
    New-Item -ItemType Directory -Force -Path $prepareDir | Out-Null
    foreach ($payloadItem in @(Get-ChildItem -LiteralPath $payloadRoot -Force)) {
        Copy-Item -LiteralPath $payloadItem.FullName -Destination $prepareDir -Recurse -Force
    }

    # 设计 §4：变更前核对当前安装目录的文件集合——发现发行清单之外的
    # 文件时拒绝自动更新并报告，绝不先移走再决定（否则用户文件会随旧
    # 安装备份一起在提交后被删除）。
    $updateManifest = New-Object System.Collections.Generic.HashSet[string]([StringComparer]::OrdinalIgnoreCase)
    foreach ($line in @(Get-Content -LiteralPath (Join-Path $payloadRoot 'release-files.txt') | ForEach-Object {
        ([string]$_).Trim()
    } | Where-Object { $_ -and -not $_.StartsWith('#') })) {
        $updateManifest.Add($line.Replace('/', '')) | Out-Null
    }
    $foreignEntries = @()
    foreach ($item in @(Get-ChildItem -LiteralPath $installFull -Recurse -File)) {
        $relative = $item.FullName.Substring($installFull.Length + 1).Replace('/', '')
        if ($relative -eq '.dsh-launcher-owner.json') { continue }
        if (-not $updateManifest.Contains($relative)) { $foreignEntries += $relative }
    }
    if ($foreignEntries.Count -gt 0) {
        throw ("当前安装目录存在发行清单之外的文件，拒绝自动更新（不会删除它们）：`n  " +
            ($foreignEntries -join "`n  ") +
            "`n请先手动处理这些文件（移动或删除），或重新运行官方安装脚本。")
    }

    # 5) 备份旧安装并放置新安装
    $oldInstallDir = Join-Path $installParent ('.dsh-launcher-old-' + $transactionId)
    # 移动前先写好恢复执行器，覆盖“旧目录已移走、新目录未就位”的中断窗口。
    $recoverScriptPath = Write-DshUpdateRecoverScript `
        -TransactionDir $transactionDir -InstallPath $installFull `
        -BackupPath $oldInstallDir -TargetVersion $targetVersion
    if (-not (Move-DshUpdateDirectory -Source $installFull -Destination $oldInstallDir)) {
        $oldInstallDir = $null
        throw '旧安装目录被占用，无法完成事务替换；请先 deepseek --stop 后重试。'
    }
    $updateSwapped = $true
    try {
        Move-Item -LiteralPath $prepareDir -Destination $installFull -ErrorAction Stop
        $prepareDir = $null
    } catch {
        if (Move-DshUpdateDirectory -Source $oldInstallDir -Destination $installFull) {
            $oldInstallDir = $null
            $updateSwapped = $false
        }
        throw
    }
    if ($env:DSH_TEST_UPDATE_FAIL_STAGE -eq 'swap') {
        throw '测试注入：目录交换后失败'
    }

    # 6) 恢复受管安装身份 + 离线烟雾验证
    $owner = [ordered]@{
        SchemaVersion = 1
        InstallPath = $installFull
        InstallationId = if ($preservedInstallationId) { $preservedInstallationId } else { [guid]::NewGuid().ToString('N') }
    }
    [IO.File]::WriteAllText(
        (Join-Path $installFull '.dsh-launcher-owner.json'),
        ($owner | ConvertTo-Json),
        [Text.UTF8Encoding]::new($false)
    )
    if ($env:DSH_TEST_UPDATE_FAIL_STAGE -eq 'marker') {
        throw '测试注入：所有权标记写入后失败'
    }
    $smokeOutput = & cmd.exe /c ('"' + (Join-Path $installFull 'deepseek.cmd') + '" --version') 2>&1
    $smokeExit = $LASTEXITCODE
    $smokeText = [string]($smokeOutput -join [Environment]::NewLine)
    if ($smokeExit -ne 0 -or $smokeText -notmatch [regex]::Escape($targetVersion)) {
        throw "更新后离线烟雾验证失败（exit $smokeExit）：$smokeText"
    }
    if ($env:DSH_TEST_UPDATE_FAIL_STAGE -eq 'smoke') {
        throw '测试注入：烟雾验证后失败'
    }

    # 7) 提交
    $updateCommitted = $true
    if (Test-Path -LiteralPath $oldInstallDir) {
        try {
            Remove-Item -LiteralPath $oldInstallDir -Recurse -Force -ErrorAction Stop
            $oldInstallDir = $null
        } catch {
            Write-Host "[WARN] 旧安装备份未能删除，已保留在：$oldInstallDir"
        }
    }
    $script:exitCode = 0
    Write-Host "启动器更新完成：$localVersion -> $targetVersion"
    Write-Host '已保留 DSH 运行时、用户配置与快捷方式设置。'
} catch {
    Write-Host "[ERROR] $($_.Exception.Message)"
    if (-not $updateSwapped -or $updateCommitted) {
        # 失败发生在事务替换之前或提交之后：原安装从未离开原位（或已提交完成）。
        $script:exitCode = 1
    } elseif ($env:DSH_TEST_UPDATE_FAIL_RESTORE -eq '1') {
        # 测试注入：模拟自动恢复失败，保留备份与事务记录。
        Write-Host "[ERROR] 自动恢复未完成。旧安装备份保留在：$oldInstallDir"
        if ($recoverScriptPath) { Write-Host "可运行恢复脚本：$recoverScriptPath" }
        $script:exitCode = 2
    } else {
        # 8) 失败恢复：移除失败候选，把旧安装原样移回并验证入口。
        if (Test-Path -LiteralPath $installFull) {
            try { Remove-Item -LiteralPath $installFull -Recurse -Force -ErrorAction Stop } catch { }
        }
        if ($oldInstallDir -and (Test-Path -LiteralPath $oldInstallDir)) {
            if (Move-DshUpdateDirectory -Source $oldInstallDir -Destination $installFull) {
                $oldInstallDir = $null
                Write-Host "已恢复原启动器（$localVersion）。"
                $script:exitCode = 1
            } else {
                Write-Host "[ERROR] 自动恢复未完成。旧安装备份保留在：$oldInstallDir"
                if ($recoverScriptPath) { Write-Host "可运行恢复脚本：$recoverScriptPath" }
                $script:exitCode = 2
            }
        } else {
            Write-Host "[ERROR] 自动恢复未完成（旧安装备份缺失）。"
            if ($recoverScriptPath) { Write-Host "可运行恢复脚本：$recoverScriptPath" }
            $script:exitCode = 2
        }
    }
} finally {
    Exit-DshMaintenanceLock -Mutex $maintenanceMutex
    if ($prepareDir -and (Test-Path -LiteralPath $prepareDir)) {
        Remove-Item -LiteralPath $prepareDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($script:exitCode -eq 0 -and (Test-Path -LiteralPath $transactionDir)) {
        Remove-Item -LiteralPath $transactionDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

exit $script:exitCode
