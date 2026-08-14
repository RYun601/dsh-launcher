# dsh-launcher 一键安装脚本
# 用法（PowerShell）：
#   irm https://raw.githubusercontent.com/RYun601/dsh-launcher/main/install.ps1 | iex
# 可选参数（先下载到本地再运行）：
#   .\install.ps1 -InstallDir <目标目录> -SkipPath
param(
    [string]$InstallDir = (Join-Path $env:USERPROFILE 'dsh-launcher'),
    [switch]$SkipPath
)
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
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$api = 'https://api.github.com/repos/RYun601/dsh-launcher/releases/latest'
Write-Host '正在获取最新版本信息...'
$rel = Invoke-RestMethod -Uri $api -Headers @{ 'User-Agent' = 'dsh-installer' }
$asset = $rel.assets | Where-Object { $_.name -eq 'dsh-launcher.zip' } | Select-Object -First 1
if (-not $asset) { throw '未找到 dsh-launcher.zip 发布包' }
Write-Host "最新版本：$($rel.tag_name)"

$tmp = Join-Path $env:TEMP 'dsh-launcher.zip'
Write-Host "正在下载 $($asset.name) ..."
Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $tmp -Headers @{ 'User-Agent' = 'dsh-installer' }

Write-Host "正在解压到 $InstallDir ..."
if (Test-Path $InstallDir) { Write-Host '目录已存在，将覆盖更新其中的文件' }
$parent = Split-Path $InstallDir -Parent
Expand-Archive -Path $tmp -DestinationPath $parent -Force
Remove-Item $tmp -Force

$installed = Test-Path (Join-Path $InstallDir 'deepseek.cmd')
if (-not $installed) { throw "安装失败：未找到 $InstallDir\deepseek.cmd" }

if (-not $SkipPath) {
    $p = [Environment]::GetEnvironmentVariable('Path', 'User')
    $target = $InstallDir.TrimEnd('\')
    if ($p -split ';' -contains $target) {
        Write-Host "PATH 已包含 $target"
    } else {
        [Environment]::SetEnvironmentVariable('Path', (($p.TrimEnd(';')) + ';' + $target), 'User')
        Write-Host "已添加到用户 PATH：$target"
    }
}

Write-Host ''
Write-Host '安装完成！请新开一个终端窗口，然后输入 deepseek 开始使用。'
Write-Host '  deepseek -b    后台启动（推荐）'
Write-Host '  deepseek --help  查看全部命令'
