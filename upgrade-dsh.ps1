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

# 1) 停止服务（stop-dsh.ps1 内含误杀防护）
Write-Host '正在停止服务...'
& (Join-Path $dir 'stop-dsh.ps1')

# 2) 删除 npx 缓存中的 dsh 包（下次启动自动下载最新版）
$cacheRoot = Join-Path $env:LOCALAPPDATA 'npm-cache_npx'
$removed = @()
if (Test-Path $cacheRoot) {
    Get-ChildItem $cacheRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $pkgDir = Join-Path $_.FullName 'node_modules\@deepseek-ai\dsh'
        if (Test-Path $pkgDir) {
            Remove-Item $pkgDir -Recurse -Force
            $removed += $pkgDir
        }
    }
}
if ($removed) {
    Write-Host '已清理 npx 缓存中的 DSH 包：'
    $removed | ForEach-Object { Write-Host "  $_" }
} else {
    Write-Host '未发现 npx 缓存中的 DSH 包'
}

# 3) 重新后台启动（自动下载最新版 DSH）
Write-Host '正在重新后台启动（会自动下载最新版 DSH）...'
& (Join-Path $dir 'start-background.ps1')
