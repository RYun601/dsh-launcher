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

if ($Full) {
    Write-Host ''
    Write-Host '即将执行完整卸载：'
    Write-Host '  1. 删除桌面快捷方式：DeepSeek Harness.lnk'
    Write-Host "  2. 删除日志目录：$env:USERPROFILE\dsh-launch"
    Write-Host "  3. 删除安装目录：$dir"
    $ans = Read-Host '确认删除以上内容？输入 y 继续，其他任意键取消'
    if ($ans -eq 'y' -or $ans -eq 'Y') {
        $desktop = [Environment]::GetFolderPath('Desktop')
        $lnkPath = Join-Path $desktop 'DeepSeek Harness.lnk'
        if (Test-Path $lnkPath) { Remove-Item $lnkPath -Force; Write-Host "已删除快捷方式：$lnkPath" }
        $logDir = Join-Path $env:USERPROFILE 'dsh-launch'
        if (Test-Path $logDir) { Remove-Item $logDir -Recurse -Force; Write-Host "已删除日志目录：$logDir" }
        if (Test-Path $dir) {
            Remove-Item $dir -Recurse -Force
            Write-Host "已删除安装目录：$dir"
        }
        Write-Host '完整卸载完成。'
    } else {
        Write-Host '已取消完整卸载（PATH 移除仍然生效）。'
    }
}
