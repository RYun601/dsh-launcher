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

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptDir 'dsh-version.ps1')

# 本地版本：launcher 运行时 + 旧 npx 缓存 + npm 全局安装都扫描，取最高
$versions = @()
$runtimePj = Join-Path $env:USERPROFILE 'dsh-launch\runtime\node_modules\@deepseek-ai\dsh\package.json'
if (Test-Path $runtimePj) {
    try {
        $j = Get-Content $runtimePj -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($j.name -eq '@deepseek-ai/dsh' -and $j.version) { $versions += $j.version }
    } catch { }
}
$cacheRoot = Join-Path $env:LOCALAPPDATA 'npm-cache\_npx'
if (Test-Path $cacheRoot) {
    Get-ChildItem $cacheRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $pj = Join-Path $_.FullName 'node_modules\@deepseek-ai\dsh\package.json'
        if (Test-Path $pj) {
            try {
                $j = Get-Content $pj -Raw | ConvertFrom-Json
                if ($j.name -eq '@deepseek-ai/dsh' -and $j.version) { $versions += $j.version }
            } catch { }
        }
    }
}
$globalPj = Join-Path $env:APPDATA 'npm\node_modules\@deepseek-ai\dsh\package.json'
if (Test-Path $globalPj) {
    try {
        $j = Get-Content $globalPj -Raw | ConvertFrom-Json
        if ($j.name -eq '@deepseek-ai/dsh' -and $j.version) { $versions += $j.version }
    } catch { }
}
$local = if ($versions.Count) { Get-HighestDshVersion $versions } else { 'unknown' }
Write-Host "本地版本：$local"

# 最新版本 = 各 dist-tag（latest/next/...）中的最高者
$latest = & (Join-Path $scriptDir 'resolve-dsh-version.ps1')
if ($latest) {
    Write-Host "最新版本：$latest"
    if ($local -ne 'unknown' -and (Compare-DshVersion $local $latest) -lt 0) {
        Write-Host ""
        Write-Host "有新版本可用！执行 deepseek --upgrade 一键升级。"
    } else {
        Write-Host "已是最新版本。"
    }
} else {
    Write-Host "无法获取最新版本（请检查网络后重试）"
}
