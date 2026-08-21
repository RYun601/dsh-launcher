param(
    [int]$TimeoutSeconds = 900,
    [int]$ParentPid = 0,
    [string]$LaunchRoot = '',
    [int]$OwnerPid = 0,
    [ValidateRange(50, 5000)]
    [int]$PollIntervalMilliseconds = 200
)
$url = 'http://127.0.0.1:3080'
$stateHelper = Join-Path $PSScriptRoot 'dsh-launch-state.ps1'
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
while ((Get-Date) -lt $deadline) {
    # Foreground mode: if the parent window (deepseek) is gone, this monitor has no reason to stay alive
    if ($ParentPid -gt 0 -and -not (Get-Process -Id $ParentPid -ErrorAction SilentlyContinue)) {
        exit 0
    }
    try {
        $r = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 2
        if ($r.StatusCode -ge 200 -and $r.StatusCode -lt 500) {
            if ($LaunchRoot) {
                & $stateHelper -Action WriteStartupState -LaunchRoot $LaunchRoot -State RUNNING `
                    -OwnerPid $OwnerPid -Message 'DeepSeek Harness is ready' 2>$null
            }
            Start-Process $url
            exit 0
        }
    } catch { }
    Start-Sleep -Milliseconds $PollIntervalMilliseconds
}
exit 1
