$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$target = $dir.TrimEnd('\')
$p = [Environment]::GetEnvironmentVariable('Path', 'User')
if (-not $p) {
    Write-Host "用户 PATH 为空，无需清理。"
    exit 0
}
$parts = @($p -split ';' | Where-Object { $_ -ne '' -and $_.TrimEnd('\') -ne $target })
[Environment]::SetEnvironmentVariable('Path', ($parts -join ';'), 'User')
Write-Host "已从用户 PATH 移除：$dir"
Write-Host "新开的终端中 deepseek 命令将不再可用（当前已打开的终端不受影响）。"