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
. (Join-Path $dir 'dsh-version.ps1')

# 0) 目标版本 = 各 dist-tag（latest/next/...）中的最高者（当前 next=0.1.0-rc.8）
$latest = & (Join-Path $dir 'resolve-dsh-version.ps1')
if ($latest) { Write-Host "目标版本：$latest" }

# 1) 停止服务（stop-dsh.ps1 内含误杀防护）
Write-Host '正在停止服务...'
& (Join-Path $dir 'stop-dsh.ps1')

# 2) 删除完整的 DSH npx 工作区（下次启动自动下载最新版）。
# 只删除 node_modules\@deepseek-ai\dsh 会留下 package-lock.json 和旧依赖树，
# 使 npx 工作区处于不完整状态，升级后的解析可能继续使用旧锁文件。
$cacheRoot = Join-Path $env:LOCALAPPDATA 'npm-cache\_npx'
$stateHelper = Join-Path $dir 'dsh-launch-state.ps1'
$removed = @(& $stateHelper -Action ClearDshNpxWorkspaces -CacheRoot $cacheRoot)
if ($removed) {
    Write-Host '已清理 npx 缓存中的 DSH 工作区：'
    $removed | ForEach-Object { Write-Host "  $_" }
} else {
    Write-Host '未发现 npx 缓存中的 DSH 工作区'
}

# 3) 同步 npm 全局安装的 `dsh` 命令：缺失时安装、旧于目标版本时升级，
# 保证直接使用 `dsh web` 等命令的版本与 launcher 运行时一致。
# 失败仅警告，不阻塞 launcher 运行时本身的升级。
if ($latest) {
    $globalPkg = Join-Path $env:APPDATA 'npm\node_modules\@deepseek-ai\dsh\package.json'
    $globalVersion = ''
    if (Test-Path -LiteralPath $globalPkg) {
        try {
            $globalVersion = [string](Get-Content -LiteralPath $globalPkg -Raw -Encoding UTF8 | ConvertFrom-Json).version
        } catch { }
    }
    if (-not $globalVersion -or (Compare-DshVersion $globalVersion $latest) -lt 0) {
        if ($globalVersion) {
            Write-Host "正在升级全局 dsh 命令（$globalVersion -> $latest）..."
        } else {
            Write-Host "正在安装全局 dsh 命令（$latest）..."
        }
        try {
            & npm.cmd install -g "@deepseek-ai/dsh@$latest"
            if ($LASTEXITCODE -ne 0) { throw "npm install -g 退出码 $LASTEXITCODE" }
            Write-Host "全局 dsh 已就绪（$latest），现在可直接使用 dsh 命令。"
        } catch {
            Write-Host "警告：全局 dsh 安装/升级失败：$($_.Exception.Message)"
            Write-Host "可手动执行：npm install -g @deepseek-ai/dsh@$latest"
        }
    } else {
        Write-Host "全局 dsh 已是最新（$globalVersion）。"
    }
}

# 4) 重新后台启动（自动下载最新版 DSH）
Write-Host '正在重新后台启动（会自动下载最新版 DSH）...'
$upgradeTarget = if ($latest) { [string]$latest } else { 'latest' }
& (Join-Path $dir 'start-background.ps1') -WaitForReady -TimeoutSeconds 900 -Version $upgradeTarget
