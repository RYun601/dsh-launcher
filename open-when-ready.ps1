$url = 'http://127.0.0.1:3080'
while ($true) {
    try {
        $r = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 2
        if ($r.StatusCode -ge 200 -and $r.StatusCode -lt 500) {
            Start-Process $url
            exit 0
        }
    } catch { }
    Start-Sleep -Seconds 1
}