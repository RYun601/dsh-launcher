param(
    [ValidateRange(1, 10000)]
    [int]$Count = 20,

    [switch]$Follow
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

# `deepseek --logs [--follow] [N]`（阶段 D）。
# 跟随模式基于路径轮询而非文件句柄：日志被轮转（改名）后，只要新日志
# 出现在同一路径就会自动重连，从头输出新文件内容；Ctrl+C 正常退出。
$logPath = Join-Path $env:USERPROFILE 'dsh-launch\dsh-background.log'

if (-not (Test-Path -LiteralPath $logPath -PathType Leaf)) {
    Write-Host "No log yet: $logPath"
    exit 0
}

if (-not $Follow) {
    Get-Content -LiteralPath $logPath -Tail $Count -Encoding UTF8 | ForEach-Object { Write-Host $_ }
    exit 0
}

Write-Host "Following $logPath (Ctrl+C to stop)..."

# 初始输出最近 N 行；重定向时管道输出会缓冲，统一用 Write-Host 即时写出。
Get-Content -LiteralPath $logPath -Tail $Count -Encoding UTF8 | ForEach-Object { Write-Host $_ }

# 轮转检测：Windows 文件隧道会让同路径重建的新文件继承原 CreationTime，
# 因此不能用创建时间判断轮转。这里记录文件头部（前 64 字节）指纹：
# 追加写入不会改变头部，轮转重建几乎必然改变头部内容。
$script:followPosition = (Get-Item -LiteralPath $logPath).Length
$script:followHead = $null

function Get-DshLogHead {
    param([string]$Path)

    try {
        $stream = [IO.File]::Open(
            $Path,
            [IO.FileMode]::Open,
            [IO.FileAccess]::Read,
            [IO.FileShare]([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
        )
        try {
            $take = [int][Math]::Min(64, $stream.Length)
            if ($take -le 0) { return $null }
            $buffer = New-Object byte[] $take
            $null = $stream.Read($buffer, 0, $take)
            return [Convert]::ToBase64String($buffer)
        } finally {
            $stream.Dispose()
        }
    } catch {
        return $null
    }
}

while ($true) {
    Start-Sleep -Milliseconds 300
    if (-not (Test-Path -LiteralPath $logPath -PathType Leaf)) {
        # 日志刚被轮转：等待新文件出现后从头跟随。
        $script:followPosition = 0
        $script:followHead = $null
        continue
    }
    $head = Get-DshLogHead -Path $logPath
    if ($head -and $script:followHead -and ($head -cne $script:followHead)) {
        # 同一路径的文件头部内容变了：日志已被轮转重建，从头跟随。
        $script:followPosition = 0
    }
    $script:followHead = $head
    try {
        $stream = [IO.File]::Open(
            $logPath,
            [IO.FileMode]::Open,
            [IO.FileAccess]::Read,
            [IO.FileShare]([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
        )
        try {
            if ($stream.Length -lt $script:followPosition) {
                # 新日志文件比上次的读取位置短：同样视为轮转重建。
                $script:followPosition = 0
            }
            if ($stream.Length -gt $script:followPosition) {
                $stream.Position = $script:followPosition
                $pending = New-Object byte[] ($stream.Length - $script:followPosition)
                $read = $stream.Read($pending, 0, $pending.Length)
                $text = [Text.Encoding]::UTF8.GetString($pending, 0, $read)
                # 只输出完整行，末尾不完整的行留到下一轮读取。
                $lastNewline = $text.LastIndexOf("`n")
                if ($lastNewline -ge 0) {
                    $complete = $text.Substring(0, $lastNewline).TrimEnd("`r").TrimStart([char]0xFEFF)
                    if ($complete) { Write-Host $complete }
                    $script:followPosition += [Text.Encoding]::UTF8.GetByteCount($text.Substring(0, $lastNewline + 1))
                }
            }
        } finally {
            $stream.Dispose()
        }
    } catch {
        # 文件被短暂占用或替换：下一轮重试。
    }
}

Get-Content -LiteralPath $logPath -Tail $Count -Encoding UTF8