param(
    [string]$LaunchRoot = ''
)

# —— 控制台编码修复 ——
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
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptDir 'dsh-version.ps1')
. (Join-Path $scriptDir 'dsh-runtime-layout.ps1')
. (Join-Path $scriptDir 'dsh-node-version.ps1')
. (Join-Path $scriptDir 'dsh-service-health.ps1')
$stateHelper = Join-Path $scriptDir 'dsh-launch-state.ps1'

# --check 的诊断契约（阶段 D）：
#   一次看清“为什么不能启动、当前运行哪个版本”。只读诊断：不读取用户配置
#   内容、不导出完整环境变量、不访问 .dsh、不启动服务、不打开浏览器。
#   退出码：0 = 未发现阻断性问题；1 = 发现至少一项需要处理的问题。

if (-not $LaunchRoot) { $LaunchRoot = Join-Path $env:USERPROFILE 'dsh-launch' }
$script:problems = 0

function Write-DshDoctorSection {
    param([string]$Title)
    Write-Host ''
    Write-Host "== $Title =="
}

function Assert-DshDoctorProblem {
    param([bool]$IsProblem, [string]$ProblemText, [string]$OkText)
    if ($IsProblem) {
        $script:problems++
        Write-Host "[问题] $ProblemText"
    } else {
        Write-Host "[正常] $OkText"
    }
}

Write-Host 'DeepSeek Harness 启动器诊断（deepseek --check）'

# —— 1. 启动器安装 ——
Write-DshDoctorSection '启动器安装'
$installDir = $scriptDir
$launcherVersion = 'unknown'
$versionFile = Join-Path $installDir 'VERSION'
if (Test-Path -LiteralPath $versionFile -PathType Leaf) {
    try { $launcherVersion = ([string](Get-Content -LiteralPath $versionFile -Raw)).Trim() } catch { }
}
Write-Host "安装目录：$installDir"
Write-Host "启动器版本：$launcherVersion"
$ownerMarkerPath = Join-Path $installDir '.dsh-launcher-owner.json'
$ownerMarked = Test-Path -LiteralPath $ownerMarkerPath -PathType Leaf
Write-Host "所有权标记：$(if ($ownerMarked) { '存在（受管安装）' } else { '缺失（手动解压或旧版安装；自更新不可用）' })"

# —— 2. Node.js / npm ——
Write-DshDoctorSection 'Node.js 环境'
if (Assert-DshNodeEnvironment) {
    Write-Host '[正常] Node.js 满足运行要求'
} else {
    $script:problems++
}
$npmCommand = $null
try {
    $npmCommand = @(Get-Command 'npm.cmd' -CommandType Application -ErrorAction Stop)[0]
} catch { }
if ($npmCommand) {
    Write-Host "[正常] npm: found（$($npmCommand.Source)）"
} else {
    $script:problems++
    Write-Host '[问题] npm: NOT FOUND；请重新安装 Node.js（通常自带 npm）：https://nodejs.org'
}

# —— 3. 运行时与版本来源 ——
Write-DshDoctorSection 'DSH 运行时'
$layout = Get-DshRuntimeLayout -LaunchRoot $LaunchRoot
$report = Get-DshRuntimeVersionReport -Layout $layout
Write-Host "活动版本：$($report.ActiveVersion)（来源：$($report.ActiveSource)）"
if ($report.ActivePath) { Write-Host "活动运行时目录：$($report.ActivePath)" }
if ($report.PointerError) {
    Write-Host "指针读取失败：$($report.PointerErrorMessage)"
    $script:problems++
}
if ($report.Current -and -not $report.CurrentValid) {
    Write-Host "[问题] Current 指针指向的运行时未通过就绪校验（可能下载中断或文件损坏）"
    $script:problems++
}
if ($report.ActiveSource -eq 'none') {
    Write-Host '尚未安装受管运行时；首次 deepseek -b 启动时会自动下载。'
}
if ($report.Previous) { Write-Host "上一版指针：$($report.Previous.Version)（$($report.Previous.Path)）" }

# —— 4. 服务状态与端口 ——
Write-DshDoctorSection '服务与端口'
$stateText = [string]((& $stateHelper -Action GetStatus -LaunchRoot $LaunchRoot) -join '')
Write-Host "启动状态：$stateText"
$owner = Get-DshPortOwner -Port 3080
if (-not $owner) {
    Write-Host '端口 3080：无监听（服务未运行时这是正常状态）'
} else {
    $process = $null
    try {
        $process = Get-CimInstance Win32_Process -Filter "ProcessId=$($owner.ProcessId)" -ErrorAction Stop
    } catch { }
    $name = if ($process) { $process.Name } else { '未知进程' }
    Write-Host "端口 3080：被 PID $($owner.ProcessId)（$name）占用"
}

# —— 5. 最近一次失败 ——
Write-DshDoctorSection '最近一次失败'
$stateJsonPath = Join-Path $LaunchRoot 'dsh-startup.json'
$lastState = $null
if (Test-Path -LiteralPath $stateJsonPath -PathType Leaf) {
    try { $lastState = Get-Content -LiteralPath $stateJsonPath -Raw | ConvertFrom-Json } catch { }
}
if ($lastState -and $lastState.State -eq 'FAILED') {
    $exitSuffix = if ($null -ne $lastState.ExitCode) { "（退出码 $($lastState.ExitCode)）" } else { '' }
    $message = if ($lastState.Message) { [string]$lastState.Message } else { '未知原因' }
    Write-Host "最近一次启动失败$exitSuffix：$message"
    Write-Host "日志：$(Join-Path $LaunchRoot 'dsh-background.log')"
} else {
    Write-Host '没有记录到启动失败。'
}

Write-Host ''
if ($script:problems -gt 0) {
    Write-Host "诊断完成：发现 $script:problems 项需要处理的问题。"
    exit 1
}
Write-Host '诊断完成：未发现需要处理的问题。'
exit 0
