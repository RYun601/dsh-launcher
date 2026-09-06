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
. (Join-Path $scriptDir 'dsh-runtime-layout.ps1')

# 本地版本（R7）：优先读取 runtime-current.json 指针中的活动运行时；
# 指针缺失时回退旧版单运行时目录。旧 npx 缓存与全局安装只作参考信息，
# 不再参与“取最高值”的判断——它们不代表当前正在使用的版本。
$launchRoot = Join-Path $env:USERPROFILE 'dsh-launch'
$layout = Get-DshRuntimeLayout -LaunchRoot $launchRoot
$report = Get-DshRuntimeVersionReport -Layout $layout
$local = [string]$report.ActiveVersion

$sourceText = switch ($report.ActiveSource) {
    'current' { 'runtime-current 指针' }
    'legacy' { '旧版运行时目录' }
    'pointer-error' { '指针不可读' }
    default { '未安装受管运行时' }
}
Write-Host "本地版本：$local（$sourceText）"

$referenceVersions = @()
if ($report.Previous) { $referenceVersions += "上一版指针 $($report.Previous.Version)" }
if ($report.LegacyInstalledVersion -and $report.LegacyInstalledVersion -ne $local) {
    $referenceVersions += "旧目录 $($report.LegacyInstalledVersion)"
}
$cacheRoot = Join-Path $env:LOCALAPPDATA 'npm-cache\_npx'
if (Test-Path -LiteralPath $cacheRoot -PathType Container) {
    $cacheHighest = $null
    Get-ChildItem -LiteralPath $cacheRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $pj = Join-Path $_.FullName 'node_modules\@deepseek-ai\dsh\package.json'
        if (Test-Path -LiteralPath $pj -PathType Leaf) {
            try {
                $j = Get-Content -LiteralPath $pj -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($j.name -eq '@deepseek-ai/dsh' -and $j.version) {
                    $candidate = [string]$j.version
                    if (-not $cacheHighest -or (Compare-DshVersion $candidate $cacheHighest) -gt 0) {
                        $cacheHighest = $candidate
                    }
                }
            } catch { }
        }
    }
    if ($cacheHighest -and $cacheHighest -ne $local) { $referenceVersions += "npx 缓存 $cacheHighest" }
}
$globalPj = Join-Path $env:APPDATA 'npm\node_modules\@deepseek-ai\dsh\package.json'
if (Test-Path -LiteralPath $globalPj -PathType Leaf) {
    try {
        $j = Get-Content -LiteralPath $globalPj -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($j.name -eq '@deepseek-ai/dsh' -and $j.version -and [string]$j.version -ne $local) {
            $referenceVersions += "全局安装 $([string]$j.version)"
        }
    } catch { }
}
if ($referenceVersions.Count -gt 0) {
    Write-Host "其他检测到（非活动）：$($referenceVersions -join '；')"
}

# 最新版本 = 各 dist-tag（latest/next/...）中的最高者。
# 远端解析失败必须以非零退出码结束（R7），不能当作“已是最新”。
$latest = & (Join-Path $scriptDir 'resolve-dsh-version.ps1')
if (-not $latest) {
    Write-Host "无法获取最新版本（请检查网络后重试）"
    exit 1
}
Write-Host "最新版本：$latest"

if ($local -eq 'unknown' -or $report.PointerError) {
    Write-Host "无法确认当前实际使用的 DSH 版本，不能判断是否最新；请先完成一次 deepseek -b 启动。"
    exit 1
}
if ((Compare-DshVersion $local $latest) -lt 0) {
    Write-Host ""
    Write-Host "有新版本可用！执行 deepseek --upgrade 一键升级。"
    exit 0
}
if ((Compare-DshVersion $local $latest) -gt 0) {
    Write-Host "当前运行的版本（$local）比发布版本（$latest）更新，无需升级。"
    exit 0
}
Write-Host "已是最新版本。"
exit 0
