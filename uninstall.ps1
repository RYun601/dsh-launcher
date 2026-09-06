param([switch]$Full)
# —— 控制台编码修复 ——
# 在代码页被切到 UTF-8(65001) 的传统控制台里，中文输出会出现“每个字重复”的重影 bug。
# 这里把控制台代码页与输出编码统一回系统 ANSI 代码页（中文系统为 936/GBK）。
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
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$target = $dir.TrimEnd('\')
$maintenanceLockHelper = Join-Path $dir 'dsh-maintenance-lock.ps1'
if (Test-Path -LiteralPath $maintenanceLockHelper -PathType Leaf) {
    . $maintenanceLockHelper
}

# —— 用户 PATH 存储访问 ——
# 测试通过 DSH_TEST_UNINSTALL_PATH_STORE 注入文件存储，避免触碰真实注册表。
function Get-DshUserPathValue {
    $store = [string]$env:DSH_TEST_UNINSTALL_PATH_STORE
    if ($store) {
        if (Test-Path -LiteralPath $store -PathType Leaf) {
            return [IO.File]::ReadAllText($store)
        }
        return ''
    }
    return [Environment]::GetEnvironmentVariable('Path', 'User')
}

function Set-DshUserPathValue {
    param([string]$Value)
    $store = [string]$env:DSH_TEST_UNINSTALL_PATH_STORE
    if ($store) {
        [IO.File]::WriteAllText($store, $Value, [Text.UTF8Encoding]::new($false))
        return
    }
    [Environment]::SetEnvironmentVariable('Path', $Value, 'User')
}

# 普通卸载只注销用户 PATH；完整卸载的事务在确认通过、目录全部备份成功后才改 PATH。
if (-not $Full) {
    $p = Get-DshUserPathValue
    if ($p) {
        $parts = @($p -split ';' | Where-Object { $_ -ne '' -and $_.TrimEnd('\') -ne $target })
        Set-DshUserPathValue -Value ($parts -join ';')
        Write-Host "已从用户 PATH 移除：$dir"
        Write-Host '新开的终端中 deepseek 命令将不再可用（当前已打开的终端不受影响）。'
    } else {
        Write-Host '用户 PATH 为空，无需清理。'
    }
    exit 0
}

Write-Host ''
Write-Host '即将执行完整卸载：'
Write-Host '  1. 移除用户 PATH 注册'
Write-Host '  2. 将桌面快捷方式、日志运行数据、安装目录先移入备份区，确认无误后删除'
Write-Host "     （日志运行数据：$env:USERPROFILE\dsh-launch）"
Write-Host "     （安装目录：$dir）"
$ans = Read-Host '确认执行？输入 y 继续，其他任意键取消（取消不会改动任何内容）'
if ($ans -ne 'y' -and $ans -ne 'Y') {
    Write-Host '已取消完整卸载，未做任何更改。'
    exit 0
}

# —— 停止服务：任何停止失败都中止卸载，禁止带病删除 ——
$stopScript = Join-Path $dir 'stop-dsh.ps1'
if (Test-Path -LiteralPath $stopScript) {
    Write-Host '正在停止 DeepSeek Harness 服务...'
    & $stopScript
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[ERROR] 停止服务失败，完整卸载已中止（uninstall aborted）。"
        exit 1
    }
    Write-Host '服务已停止。'
} else {
    Write-Host '[WARN] 未找到 stop-dsh.ps1，跳过停止服务步骤。'
}

# —— 路径边界校验：任何路径超出启动器边界即拒绝删除 ——
$profile = [string]$env:USERPROFILE
if ([string]::IsNullOrWhiteSpace($profile)) {
    Write-Host '[ERROR] %USERPROFILE% 为空，无法安全解析卸载目标；完整卸载已中止（uninstall aborted）。'
    exit 1
}
$profileFull = [IO.Path]::GetFullPath($profile).TrimEnd('\')
$profileRoot = [IO.Path]::GetPathRoot($profileFull)
if ($profileFull -eq $profileRoot.TrimEnd('\')) {
    Write-Host '[ERROR] %USERPROFILE% 指向驱动器根目录，已拒绝删除；完整卸载已中止（uninstall aborted）。'
    exit 1
}
$logDirFull = [IO.Path]::GetFullPath((Join-Path $profileFull 'dsh-launch'))
if (-not [string]::Equals($logDirFull, $profileFull + '\dsh-launch', [StringComparison]::OrdinalIgnoreCase)) {
    Write-Host "[ERROR] 日志目录超出启动器边界：$logDirFull；完整卸载已中止（uninstall aborted）。"
    exit 1
}
$dirFull = [IO.Path]::GetFullPath($dir)
$dirRoot = [IO.Path]::GetPathRoot($dirFull)
if ($dirRoot.TrimEnd('\') -eq $dirFull.TrimEnd('\') -or [string]::Equals($dirFull, $profileFull, [StringComparison]::OrdinalIgnoreCase)) {
    Write-Host "[ERROR] 安装目录不满足安全边界：$dirFull；完整卸载已中止（uninstall aborted）。"
    exit 1
}
# %USERPROFILE%\.dsh 是用户的凭据目录，任何情况下都不得移动或删除。
$dshDataFull = [IO.Path]::GetFullPath((Join-Path $profileFull '.dsh')).TrimEnd('\')
$dshComparable = $dirFull.TrimEnd('\')
if ([string]::Equals($dshComparable, $dshDataFull, [StringComparison]::OrdinalIgnoreCase) -or
        $dshComparable.StartsWith($dshDataFull + '\', [StringComparison]::OrdinalIgnoreCase)) {
    Write-Host "[ERROR] 安装目录位于 %USERPROFILE%\.dsh 内，该目录是用户凭据边界，拒绝删除；完整卸载已中止（uninstall aborted）：$dirFull"
    exit 1
}
if (-not (Test-Path -LiteralPath (Join-Path $dirFull 'deepseek.cmd'))) {
    Write-Host "[ERROR] 安装目录不是有效的启动器目录（未找到 deepseek.cmd）；完整卸载已中止（uninstall aborted）：$dirFull"
    exit 1
}

# —— 所有权标记：存在时必须与当前安装目录一致才允许继续 ——
$ownerMarkerPath = Join-Path $dirFull '.dsh-launcher-owner.json'
if (Test-Path -LiteralPath $ownerMarkerPath) {
    $ownerMarker = $null
    try {
        $ownerMarker = Get-Content -LiteralPath $ownerMarkerPath -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch { }
    $markedInstallPath = ''
    if ($ownerMarker) {
        try { $markedInstallPath = [IO.Path]::GetFullPath([string]$ownerMarker.InstallPath).TrimEnd('\') } catch { }
    }
    if (-not $markedInstallPath -or -not [string]::Equals(
            $markedInstallPath, $dirFull.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) {
        Write-Host "[ERROR] 启动器所有权标记（.dsh-launcher-owner.json）与当前安装目录不一致，疑似错误目标；完整卸载已中止（uninstall aborted）：$dirFull"
        exit 1
    }
}

# 桌面定位：GetFolderPath 不受 USERPROFILE 影响；测试通过
# DSH_TEST_UNINSTALL_DESKTOP 注入假桌面，且只接受位于用户目录边界内的注入值。
$desktop = $null
$desktopOverride = [string]$env:DSH_TEST_UNINSTALL_DESKTOP
if (-not [string]::IsNullOrWhiteSpace($desktopOverride)) {
    try {
        $desktopCandidate = [IO.Path]::GetFullPath($desktopOverride).TrimEnd('\')
        if ($desktopCandidate.StartsWith($profileFull + '\', [StringComparison]::OrdinalIgnoreCase) -and
                (Test-Path -LiteralPath $desktopCandidate -PathType Container)) {
            $desktop = $desktopCandidate
        }
    } catch { }
}
if (-not $desktop) {
    $desktop = [Environment]::GetFolderPath('Desktop')
}
if ([string]::IsNullOrWhiteSpace($desktop)) {
    $desktop = Join-Path $profileFull 'Desktop'
}
$lnkPath = Join-Path $desktop 'DeepSeek Harness.lnk'

# 快捷方式归属核对（R6）：只有指向本安装的受管快捷方式才允许进入删除事务；
# 同名但指向其他安装/程序的快捷方式、以及同名普通文件都必须保留。
$managedShortcutDescription = 'DeepSeek Harness (background mode)'
function Test-DshOwnedDesktopShortcut {
    param([string]$ShortcutPath, [string]$InstallDirFull)

    if (-not (Test-Path -LiteralPath $ShortcutPath -PathType Leaf)) { return $false }
    if (-not [string]::Equals([IO.Path]::GetExtension($ShortcutPath), '.lnk', [StringComparison]::OrdinalIgnoreCase)) {
        return $false
    }
    try {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($ShortcutPath)
        $targetPath = [string]$shortcut.TargetPath
        $arguments = [string]$shortcut.Arguments
        $workingDirectory = [string]$shortcut.WorkingDirectory
        $description = [string]$shortcut.Description
    } catch {
        return $false
    }
    $managedWrapper = Join-Path $InstallDirFull 'start-background.cmd'
    $pointsAtThisInstall = $false
    if ($targetPath) {
        try {
            $normalizedTarget = [IO.Path]::GetFullPath($targetPath).TrimEnd('\')
            if ([string]::Equals($normalizedTarget, $InstallDirFull, [StringComparison]::OrdinalIgnoreCase)) {
                $pointsAtThisInstall = $true
            }
        } catch { }
    }
    if (-not $pointsAtThisInstall -and $arguments -and $arguments.IndexOf($managedWrapper, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
        $pointsAtThisInstall = $true
    }
    if (-not $pointsAtThisInstall) { return $false }
    if ($description -eq $managedShortcutDescription) { return $true }
    if ($workingDirectory) {
        try {
            $normalizedWorkingDirectory = [IO.Path]::GetFullPath($workingDirectory).TrimEnd('\')
            if ([string]::Equals($normalizedWorkingDirectory, $InstallDirFull, [StringComparison]::OrdinalIgnoreCase)) {
                return $true
            }
        } catch { }
    }
    return $false
}
$shortcutIsOwned = Test-DshOwnedDesktopShortcut -ShortcutPath $lnkPath -InstallDirFull $dirFull

# —— 备份后删除：先移入唯一备份区，最后一步才真正删除；任一搬移失败整体回滚 ——
# 维护互斥（AGENTS 不变量 11）：完整卸载属于维护事务，必须与覆盖安装、
# DSH 升级、启动器自更新串行化，避免并发替换/删除同一安装目录。
$script:uninstallMaintenanceMutex = $null
if (Get-Command Enter-DshMaintenanceLock -ErrorAction SilentlyContinue) {
    $script:uninstallMaintenanceMutex = Enter-DshMaintenanceLock
}
$backupRoot = Join-Path $env:TEMP ('dsh-launcher-backup-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $backupRoot | Out-Null
try {

# 搬移日志：同时记录备份区实际路径与原始绝对路径（R3），
# 供失败时逐项逆序恢复并验证。
$movedOriginals = [ordered]@{}
$movedBackups = [ordered]@{}

# 移动目录或文件到备份区（带重试，等待文件锁释放）。
function Move-ToBackup {
    param([string]$Source, [string]$Destination)

    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        try {
            if (-not (Test-Path -LiteralPath $Source)) { return $true }
            Move-Item -LiteralPath $Source -Destination $Destination -ErrorAction Stop
            return $true
        } catch [IO.IOException] {
            Start-Sleep -Milliseconds 100
        }
    }
    return $false
}

function Move-IntoTransaction {
    param([string]$Key, [string]$Source, [string]$Destination, [string]$FailureMessage)

    if ($env:DSH_TEST_UNINSTALL_FAIL_MOVE -eq $Key) { throw $FailureMessage }
    if (Test-Path -LiteralPath $Source) {
        if (-not (Move-ToBackup $Source $Destination)) { throw $FailureMessage }
        $script:movedOriginals[$Key] = $Source
        $script:movedBackups[$Key] = $Destination
        Write-Host "已移入备份区：$Source"
    }
}

# 逐项恢复并验证（R3）：只有每个已搬移条目都回到原位才算回滚成功；
# 任何失败都保留剩余备份，绝不递归删除唯一恢复副本。
function Restore-TransactionMoves {
    $allRestored = $true
    $names = @($movedOriginals.Keys)
    [array]::Reverse($names)
    foreach ($name in $names) {
        $backupPath = [string]$movedBackups[$name]
        $originalPath = [string]$movedOriginals[$name]
        if ($env:DSH_TEST_UNINSTALL_FAIL_RESTORE -eq $name) {
            Write-Host "[WARN] 测试注入的恢复失败：$name"
            $allRestored = $false
            continue
        }
        if (Test-Path -LiteralPath $originalPath) {
            # 原位已存在内容：把备份移回去会嵌套覆盖，视为恢复冲突。
            Write-Host "[WARN] 恢复冲突，原位已存在：$originalPath"
            $allRestored = $false
            continue
        }
        if (-not (Test-Path -LiteralPath $backupPath)) {
            Write-Host "[WARN] 备份缺失，无法恢复：$originalPath"
            $allRestored = $false
            continue
        }
        if (-not (Move-ToBackup -Source $backupPath -Destination $originalPath)) {
            Write-Host "[WARN] 恢复失败（可能仍被占用）：$originalPath"
            $allRestored = $false
            continue
        }
        if (-not (Test-Path -LiteralPath $originalPath)) {
            Write-Host "[WARN] 恢复后未找到：$originalPath"
            $allRestored = $false
        }
    }
    return $allRestored
}

try {
    if ($shortcutIsOwned) {
        Move-IntoTransaction -Key 'shortcut' -Source $lnkPath `
            -Destination (Join-Path $backupRoot 'DeepSeek Harness.lnk') `
            -FailureMessage "快捷方式无法移入备份区：$lnkPath"
    } elseif (Test-Path -LiteralPath $lnkPath) {
        Write-Host "检测到非本安装管理的同名快捷方式，已保留：$lnkPath"
    }
    Move-IntoTransaction -Key 'dsh-launch' -Source $logDirFull `
        -Destination (Join-Path $backupRoot 'dsh-launch') `
        -FailureMessage "日志目录无法移入备份区（可能仍被占用）：$logDirFull"
    Move-IntoTransaction -Key 'install' -Source $dirFull `
        -Destination (Join-Path $backupRoot 'install') `
        -FailureMessage "安装目录无法移入备份区（可能仍被占用）：$dirFull"
} catch {
    if (Restore-TransactionMoves) {
        Remove-Item -LiteralPath $backupRoot -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "[ERROR] 完整卸载失败并已回滚（uninstall aborted）：$($_.Exception.Message)"
    } else {
        Write-Host "[ERROR] 完整卸载失败，且未能完全恢复原状：$($_.Exception.Message)"
        Write-Host "[WARN] 剩余备份已保留（backup kept at）：$backupRoot"
        Write-Host '请根据备份区内容手动恢复未还原的项目。'
    }
    exit 1
}

# 全部搬移成功后才提交：现在开始改动用户 PATH；写 PATH 失败则连目录一起恢复。
try {
    if ($env:DSH_TEST_UNINSTALL_FAIL_PATH -eq '1') { throw 'Injected PATH commit failure' }
    $userPath = Get-DshUserPathValue
    if ($userPath) {
        $parts = @($userPath -split ';' | Where-Object { $_ -ne '' -and $_.TrimEnd('\') -ne $target })
        Set-DshUserPathValue -Value ($parts -join ';')
        Write-Host "已从用户 PATH 移除：$dir"
    } else {
        Write-Host '用户 PATH 为空，无需清理。'
    }
} catch {
    if (Restore-TransactionMoves) {
        Remove-Item -LiteralPath $backupRoot -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "[ERROR] 更新用户 PATH 失败，完整卸载未提交并已回滚（uninstall aborted）：$($_.Exception.Message)"
    } else {
        Write-Host "[ERROR] 更新用户 PATH 失败，且未能完全恢复原状：$($_.Exception.Message)"
        Write-Host "[WARN] 剩余备份已保留（backup kept at）：$backupRoot"
        Write-Host '请根据备份区内容手动恢复未还原的项目。'
    }
    exit 1
}

if ($env:DSH_TEST_UNINSTALL_DELETE_BACKUP_FAIL -eq '1') {
    $deleteFailed = $true
} else {
    try {
        Remove-Item -LiteralPath $backupRoot -Recurse -Force -ErrorAction Stop
        $deleteFailed = $false
    } catch {
        $deleteFailed = $true
    }
}
    if ($deleteFailed) {
        Write-Host "[WARN] 备份区未能删除，数据保留在（backup kept at）：$backupRoot"
        Write-Host '确认服务已退出后，可手动删除该备份目录。'
    } else {
        Write-Host '备份区已清理，完整卸载完成。'
    }
} finally {
    Exit-DshMaintenanceLock -Mutex $script:uninstallMaintenanceMutex
}
