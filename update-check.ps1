$ErrorActionPreference = 'Stop'
$local = $null
$cacheRoot = Join-Path $env:LOCALAPPDATA 'npm-cache\_npx'
if (Test-Path $cacheRoot) {
    Get-ChildItem $cacheRoot -Recurse -Filter package.json -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -like '*@deepseek-ai\dsh*' } |
        ForEach-Object {
            try {
                $j = Get-Content $_.FullName -Raw | ConvertFrom-Json
                if ($j.name -eq '@deepseek-ai/dsh' -and $j.version) { $local = $j.version }
            } catch { }
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
        Write-Host "有新版本可用！更新方法："
        Write-Host "  1. 停止服务：deepseek --stop"
        Write-Host "  2. 删除 npx 缓存目录：$cacheRoot"
        Write-Host "  3. 重新运行 deepseek -b（会自动下载最新版）"
    } else {
        Write-Host "已是最新版本。"
    }
} else {
    Write-Host "无法获取最新版本（请检查网络后重试）"
}