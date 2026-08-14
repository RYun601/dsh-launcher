$ErrorActionPreference = 'Stop'
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
$local = $null
$cacheRoot = Join-Path $env:LOCALAPPDATA 'npm-cache\_npx'
if (Test-Path $cacheRoot) {
    # 定向扫描：只查 _npx\<hash>\node_modules\@deepseek-ai\dsh\package.json，避免全量递归
    Get-ChildItem $cacheRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $pj = Join-Path $_.FullName 'node_modules\@deepseek-ai\dsh\package.json'
        if (Test-Path $pj) {
            try {
                $j = Get-Content $pj -Raw | ConvertFrom-Json
                if ($j.name -eq '@deepseek-ai/dsh' -and $j.version) { $local = $j.version }
            } catch { }
        }
    }
}
if (-not $local) { $local = 'unknown' }
Write-Host "本地版本：$local"
try {
    $latest = npm view @deepseek-ai/dsh version 2>$null | Select-Object -First 1
} catch { $latest = $null }
if ($latest) {
    Write-Host "最新版本：$latest"
    if ($local -ne 'unknown' -and $local -ne $latest) {
        Write-Host ""
        Write-Host "有新版本可用！执行 deepseek --upgrade 一键升级，或手动操作："
        Write-Host "  1. 停止服务：deepseek --stop"
        Write-Host "  2. 删除 npx 缓存目录：$cacheRoot"
        Write-Host "  3. 重新运行 deepseek -b（会自动下载最新版）"
    } else {
        Write-Host "已是最新版本。"
    }
} else {
    Write-Host "无法获取最新版本（请检查网络后重试）"
}