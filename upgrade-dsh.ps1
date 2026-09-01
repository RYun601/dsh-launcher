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
. (Join-Path $dir 'dsh-node-version.ps1')
. (Join-Path $dir 'dsh-runtime-layout.ps1')

# 0) Node.js 版本前置检查：不满足要求时直接失败，不触碰正在运行的服务。
if (-not (Assert-DshNodeEnvironment)) { exit 1 }

# 1) 目标版本 = 各 dist-tag（latest/next/...）中的最高者（当前 next=0.1.0-rc.8）。
#    必须先成功解析并校验版本，才允许停止服务或清理任何东西。
$latest = & (Join-Path $dir 'resolve-dsh-version.ps1')
if (-not $latest) {
    Write-Host '[ERROR] 无法解析目标 DSH 版本，升级已取消（upgrade aborted）；当前安装未被更改。'
    exit 1
}
$targetVersion = [string]$latest
if (-not (ConvertTo-DshSemVer $targetVersion)) {
    Write-Host "[ERROR] 解析到的目标版本无效：$targetVersion，升级已取消（upgrade aborted）；当前安装未被更改。"
    exit 1
}
Write-Host "目标版本：$targetVersion"

$launchRoot = Join-Path $env:USERPROFILE 'dsh-launch'
$layout = Get-DshRuntimeLayout -LaunchRoot $launchRoot
$pointer = Initialize-DshRuntimePointer -Layout $layout
$oldRuntime = $pointer.Current
if ($oldRuntime -and -not (Test-DshRuntimeReady -Path $oldRuntime.Path -ExpectedVersion $oldRuntime.Version)) {
    Write-Host "[WARN] 当前运行时未通过就绪校验（$($oldRuntime.Version)），升级回退将尝试其他可用运行时。"
}
$candidate = New-DshRuntimeCandidate -Layout $layout -Version $targetVersion
$runScript = Join-Path $dir 'run-dsh.ps1'

# 先在独立候选目录完成 npm 安装、peer 修复和审计；此阶段不得触碰当前指针或旧运行时。
Write-Host "正在准备候选运行时：$($candidate.Path)"
& $runScript -Version $candidate.Version -RuntimeRoot $candidate.Path -PrepareOnly
if ($LASTEXITCODE -ne 0) {
    Write-Host '[ERROR] 候选运行时准备失败，升级已取消；当前运行时未被更改。'
    exit $LASTEXITCODE
}
Write-DshUpgradeTransaction -Layout $layout -Phase 'PREPARED' -Old $oldRuntime `
    -Candidate $candidate -StartupToken ([guid]::NewGuid().ToString('N')) | Out-Null

# 2) 停止服务（stop-dsh.ps1 内含误杀防护）
Write-Host '正在停止服务...'
& (Join-Path $dir 'stop-dsh.ps1')
if ($LASTEXITCODE -ne 0) {
    Write-Host '[ERROR] 停止服务失败，升级已中止；当前运行时未切换。'
    exit $LASTEXITCODE
}

$transaction = Read-DshUpgradeTransaction -Layout $layout
Write-DshUpgradeTransaction -Layout $layout -Phase 'STOPPED' -Old $transaction.Old `
    -Candidate $transaction.Candidate -StartupToken $transaction.StartupToken | Out-Null

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

# 4) 用候选运行时重新后台启动；只有候选真正就绪后才提交 Current 指针。
Write-Host '正在用候选运行时重新后台启动并等待就绪...'
& (Join-Path $dir 'start-background.ps1') -WaitForReady -TimeoutSeconds 900 `
    -Version $candidate.Version -RuntimeRoot $candidate.Path
if ($LASTEXITCODE -ne 0) {
    $candidateExit = $LASTEXITCODE
    Write-Host "[ERROR] 候选运行时启动失败（exit $candidateExit），正在尝试恢复可用旧运行时。"
    & (Join-Path $dir 'stop-dsh.ps1') | Out-Null

    # 回退候选链：当前指针 -> 上一版指针 -> 旧版单运行时目录（legacy）。
    # 只有通过就绪校验（含入口完整性）的运行时才会被尝试，避免用损坏的存根回退。
    $rollbackOptions = @()
    foreach ($selection in @($pointer.Current, $pointer.Previous)) {
        if ($selection -and (Test-DshRuntimeReady -Path $selection.Path -ExpectedVersion $selection.Version)) {
            $rollbackOptions += $selection
        }
    }
    if (Test-DshRuntimeReady -Path $layout.LegacyRoot) {
        $rollbackOptions += (Get-DshRuntimeSelection -Path $layout.LegacyRoot)
    }

    $restored = $false
    foreach ($option in $rollbackOptions) {
        if ($restored) { break }
        Write-Host "正在尝试恢复运行时：$($option.Version)（$($option.Path)）..."
        & (Join-Path $dir 'start-background.ps1') -WaitForReady -TimeoutSeconds 900 `
            -Version $option.Version -RuntimeRoot $option.Path
        $rollbackExit = $LASTEXITCODE
        if ($rollbackExit -eq 0) {
            Write-Host "旧运行时已恢复：$($option.Version)"
            $restored = $true
        } else {
            Write-Host "[WARN] 恢复失败（$($option.Version)，exit $rollbackExit），尝试下一个候选。"
        }
    }
    if (-not $restored) {
        Write-Host '[ERROR] 没有可恢复的可用运行时；服务当前未运行。可稍后重新执行 deepseek 启动。'
    }
    Clear-DshUpgradeTransaction -Layout $layout
    exit $candidateExit
}

$committed = Commit-DshRuntimePointer -Layout $layout -Candidate $candidate
Write-DshUpgradeTransaction -Layout $layout -Phase 'COMMITTED' -Old $committed.Previous `
    -Candidate $committed.Current -StartupToken $transaction.StartupToken | Out-Null
Remove-DshUnreferencedRuntimes -Layout $layout
Clear-DshUpgradeTransaction -Layout $layout
Write-Host "升级完成，当前运行时：$($committed.Current.Version)"
