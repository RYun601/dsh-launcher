param(
    [switch]$WaitForReady,
    [ValidateRange(1, 86400)]
    [int]$TimeoutSeconds = 900
)

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

$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$log = Join-Path $env:USERPROFILE 'dsh-launch\dsh-background.log'
$url = 'http://127.0.0.1:3080'
New-Item -ItemType Directory -Force -Path (Split-Path $log -Parent) | Out-Null

function Write-StartupFailure {
    param([string]$Message)

    Write-Host $Message
    Write-Host "日志：$log"
    if (Test-Path $log) {
        Write-Host '最近日志：'
        Get-Content $log -Tail 8
    }
}

function Test-DshReady {
    try {
        $response = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 2 -ErrorAction Stop
        return $response.StatusCode -ge 200 -and $response.StatusCode -lt 500
    } catch {
        return $false
    }
}

# 0) 端口预检：已有实例则提示并直接打开浏览器
$existing = Get-NetTCPConnection -LocalPort 3080 -State Listen -ErrorAction SilentlyContinue
if ($existing) {
    Write-Host "端口 3080 已有实例在运行（PID $($existing.OwningProcess)），无需重复启动"
    Write-Host '正在打开浏览器...'
    Start-Process $url
    exit 0
}

# 1) 日志轮转：超过 1MB 保留为 .old
if (Test-Path $log) {
    $size = (Get-Item $log).Length
    if ($size -gt 1MB) { Move-Item $log "$log.old" -Force }
}

# 2) 启动隐藏进程（实际执行 background-run.cmd，输出合并进日志）
$proc = Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', "`"$dir\background-run.cmd`"" -WorkingDirectory $env:USERPROFILE -WindowStyle Hidden -PassThru

# 3) 命令行后台模式：提交启动后立即返回，由独立监视器负责就绪后打开浏览器
if (-not $WaitForReady) {
    Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$dir\open-when-ready.ps1`"",'-TimeoutSeconds',[string]$TimeoutSeconds -WindowStyle Hidden
    Write-Host "DeepSeek Harness 后台启动已提交（PID $($proc.Id)）"
    Write-Host "服务就绪后浏览器将自动打开 $url"
    Write-Host '查看状态：deepseek --status'
    Write-Host '查看日志：deepseek --logs'
    Write-Host '停止服务：deepseek --stop'
    exit 0
}

# 4) 快捷方式/升级模式：等待 HTTP 真正可用后打开浏览器
Write-Host "DeepSeek Harness 正在后台启动（PID $($proc.Id)）"
Write-Host '正在等待服务就绪；首次下载可能需要几分钟...'
$startedAt = Get-Date
$deadline = $startedAt.AddSeconds($TimeoutSeconds)
$nextProgressSeconds = 5
while ((Get-Date) -lt $deadline) {
    if ($proc.HasExited) {
        Write-StartupFailure '启动失败：后台进程已退出。'
        exit 1
    }

    if (Test-DshReady) {
        try {
            Start-Process $url
        } catch {
            Write-StartupFailure "服务已就绪，但浏览器打开失败：$($_.Exception.Message)"
            exit 1
        }
        Write-Host "DeepSeek Harness 服务已就绪（PID $($proc.Id)）"
        Write-Host "浏览器已打开 $url"
        Write-Host '查看状态：deepseek --status'
        Write-Host '查看日志：deepseek --logs'
        Write-Host '停止服务：deepseek --stop'
        exit 0
    }

    $elapsedSeconds = [int]((Get-Date) - $startedAt).TotalSeconds
    if ($elapsedSeconds -ge $nextProgressSeconds) {
        Write-Host "仍在启动，已等待 $elapsedSeconds 秒..."
        $nextProgressSeconds += 5
    }
    Start-Sleep -Seconds 1
}

Write-StartupFailure "启动超时：等待 $TimeoutSeconds 秒后服务仍未就绪。"
exit 1
