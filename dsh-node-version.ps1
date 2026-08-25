# 共享的 Node.js 环境前置检查。
# install.ps1、run-dsh.ps1 和 upgrade-dsh.ps1 必须共用这里的实现；
# 不要在调用方复制一份版本判断逻辑。

# 上游 DeepSeek Harness 的 engines 要求：^22.19.0 || >=24.0.0。
function Test-DshNodeRequirement {
    param(
        [Parameter(Mandatory = $true)][string]$Version,
        [int]$MinimumMajor = 22,
        [int]$MinimumMinor = 19,
        [int]$AlternateMajor = 24
    )

    if ($Version -notmatch '^v(\d+)\.(\d+)\.\d+') { return $false }
    $major = [int]$Matches[1]
    $minor = [int]$Matches[2]
    if ($major -eq $MinimumMajor -and $minor -ge $MinimumMinor) { return $true }
    if ($major -ge $AlternateMajor) { return $true }
    return $false
}

function Get-DshNodeVersion {
    param([string]$NodeCommand = 'node')

    # node 可能经由 .cmd 包装器输出诊断到 stderr；在 $ErrorActionPreference='Stop'
    # 下 PowerShell 5.1 会把这种原生 stderr 内容当成终止异常，因此探测期间先降级
    # 为 Continue，仅依据 stdout 与退出码判定版本。
    $output = @()
    $exitCode = 1
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& $NodeCommand '--version' 2>$null)
        $exitCode = $LASTEXITCODE
    } catch {
        return ''
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($exitCode -ne 0) { return '' }
    $line = @($output | Where-Object { $_ -match '^v\d' }) | Select-Object -First 1
    if ($line) { return [string]$line }
    return ''
}

# 返回 $true 表示环境满足要求；失败时输出可操作错误（当前版本、要求版本、升级方式）。
function Assert-DshNodeEnvironment {
    param(
        [string]$NodeCommand = 'node',
        [int]$MinimumMajor = 22,
        [int]$MinimumMinor = 19,
        [int]$AlternateMajor = 24
    )

    $requiredRange = "^$MinimumMajor.$MinimumMinor.0 || >=$AlternateMajor.0.0"
    $version = Get-DshNodeVersion -NodeCommand $NodeCommand
    if (-not $version) {
        Write-Host '[ERROR] 未检测到 Node.js！'
        Write-Host '当前版本：未检测到'
        Write-Host "要求版本：$requiredRange（DeepSeek Harness 上游要求）"
        Write-Host '升级方式：从 https://nodejs.org 下载安装 LTS 版本（自带 npm），或使用 nvm-windows。'
        return $false
    }
    if (-not (Test-DshNodeRequirement -Version $version -MinimumMajor $MinimumMajor -MinimumMinor $MinimumMinor -AlternateMajor $AlternateMajor)) {
        Write-Host "[ERROR] Node.js 版本不满足要求。"
        Write-Host "当前版本：$version"
        Write-Host "要求版本：$requiredRange（DeepSeek Harness 上游要求）"
        Write-Host '升级方式：从 https://nodejs.org 安装最新 LTS 版本，或使用 nvm-windows：nvm install 22 && nvm use 22'
        return $false
    }
    Write-Host "Node.js $version"
    return $true
}
