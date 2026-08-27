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
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$target = $dir.TrimEnd('\')
$p = [Environment]::GetEnvironmentVariable('Path', 'User')
if ($p) {
    $parts = @($p -split ';' | Where-Object { $_ -ne '' -and $_.TrimEnd('\') -ne $target })
    [Environment]::SetEnvironmentVariable('Path', ($parts -join ';'), 'User')
    Write-Host "已从用户 PATH 移除：$dir"
} else {
    Write-Host '用户 PATH 为空，无需清理。'
}
Write-Host '新开的终端中 deepseek 命令将不再可用（当前已打开的终端不受影响）。'

# 移动目录到备份区（带重试，等待文件锁释放）。
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

if ($Full) {
    Write-Host ''
    Write-Host '即将执行完整卸载：'
    Write-Host '  1. 删除桌面快捷方式：DeepSeek Harness.lnk'
    Write-Host "  2. 删除日志、运行时和启动状态：$env:USERPROFILE\dsh-launch"
    Write-Host "  3. 删除安装目录：$dir"
    $ans = Read-Host '确认删除以上内容？输入 y 继续，其他任意键取消'
    if ($ans -eq 'y' -or $ans -eq 'Y') {
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
        if (-not (Test-Path -LiteralPath (Join-Path $dirFull 'deepseek.cmd'))) {
            Write-Host "[ERROR] 安装目录不是有效的启动器目录（未找到 deepseek.cmd）；完整卸载已中止（uninstall aborted）：$dirFull"
            exit 1
        }

        $desktop = [Environment]::GetFolderPath('Desktop')
        if ([string]::IsNullOrWhiteSpace($desktop)) {
            $desktop = Join-Path $profileFull 'Desktop'
        }
        $lnkPath = Join-Path $desktop 'DeepSeek Harness.lnk'
        if (Test-Path -LiteralPath $lnkPath) {
            Remove-Item -LiteralPath $lnkPath -Force
            Write-Host "已删除快捷方式：$lnkPath"
        }

        # —— 备份后删除：先移入同边界外的唯一备份区，最后一步才真正删除 ——
        $backupRoot = Join-Path $env:TEMP ('dsh-launcher-backup-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $backupRoot | Out-Null
        $moved = @()
        try {
            if (Test-Path -LiteralPath $logDirFull) {
                if (-not (Move-ToBackup $logDirFull (Join-Path $backupRoot 'dsh-launch'))) {
                    throw "日志目录无法移入备份区（可能仍被占用）：$logDirFull"
                }
                $moved += 'dsh-launch'
                Write-Host "已移入备份区：$logDirFull"
            }
            if (Test-Path -LiteralPath $dirFull) {
                if (-not (Move-ToBackup $dirFull (Join-Path $backupRoot 'install'))) {
                    throw "安装目录无法移入备份区（可能仍被占用）：$dirFull"
                }
                $moved += 'install'
                Write-Host "已移入备份区：$dirFull"
            }
        } catch {
            foreach ($name in @($moved)) {
                $dest = Join-Path $backupRoot $name
                if (Test-Path -LiteralPath $dest) {
                    $original = if ($name -eq 'install') { $dirFull } else { $logDirFull }
                    Move-ToBackup $dest $original | Out-Null
                }
            }
            Remove-Item -LiteralPath $backupRoot -Recurse -Force -ErrorAction SilentlyContinue
            Write-Host "[ERROR] 完整卸载失败并已回滚（uninstall aborted）：$($_.Exception.Message)"
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
    } else {
        Write-Host '已取消完整卸载（PATH 移除仍然生效）。'
    }
}
