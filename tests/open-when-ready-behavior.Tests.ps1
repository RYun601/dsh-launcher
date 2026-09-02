$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$monitorScript = Join-Path $repoRoot 'open-when-ready.ps1'
$testRoot = Join-Path $env:TEMP ('dsh-open-when-ready-tests-' + [guid]::NewGuid().ToString('N'))
$fixtureScript = Join-Path $testRoot 'fake-http-fixture.ps1'
$harnessPath = Join-Path $testRoot 'monitor-harness.ps1'
$script:Passed = 0

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    if ($Expected -ne $Actual) { throw "$Message (expected: $Expected, actual: $Actual)" }
}

function Assert-Match {
    param([string]$Actual, [string]$Pattern, [string]$Message)
    if ($Actual -notmatch $Pattern) { throw "$Message`nActual:`n$Actual" }
}

function Assert-NotMatch {
    param([string]$Actual, [string]$Pattern, [string]$Message)
    if ($Actual -match $Pattern) { throw "$Message`nActual:`n$Actual" }
}

function Invoke-Test {
    param([string]$Name, [scriptblock]$Body)
    & $Body
    $script:Passed++
    Write-Host "PASS: $Name"
}

function Get-FreeTcpPort {
    $reservation = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    try {
        $reservation.Start()
        return ([Net.IPEndPoint]$reservation.LocalEndpoint).Port
    } finally {
        $reservation.Stop()
    }
}

function Start-FakeHttpFixture {
    param(
        [Parameter(Mandatory = $true)][string]$Body,
        [switch]$RequireToken
    )

    $port = Get-FreeTcpPort
    $bodyPath = Join-Path $testRoot ('body-' + [guid]::NewGuid().ToString('N') + '.txt')
    [IO.File]::WriteAllText($bodyPath, $Body, [Text.UTF8Encoding]::new($false))
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = 'powershell.exe'
    $startInfo.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $fixtureScript +
        '" -Port ' + $port + ' -BodyPath "' + $bodyPath + '"' + $(if ($RequireToken) { ' -RequireToken' } else { '' })
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $process = [Diagnostics.Process]::Start($startInfo)
    for ($attempt = 0; $attempt -lt 50; $attempt++) {
        try {
            $probe = [Net.Sockets.TcpClient]::new()
            $pending = $probe.BeginConnect('127.0.0.1', $port, $null, $null)
            if ($pending.AsyncWaitHandle.WaitOne(100)) {
                $probe.EndConnect($pending)
                $probe.Close()
                return [pscustomobject]@{ Port = $port; Process = $process }
            }
            $probe.Close()
        } catch { }
        Start-Sleep -Milliseconds 100
    }
    if (-not $process.HasExited) { $process.Kill() }
    throw "Fake HTTP fixture on port $port did not start"
}

function Invoke-MonitorScenario {
    param(
        [Parameter(Mandatory = $true)][string]$ScenarioName,
        [Parameter(Mandatory = $true)][string]$Body,
        [int]$StableMilliseconds = 100,
        [switch]$RequireToken
    )

    $scenarioRoot = Join-Path $testRoot $ScenarioName
    $launchRoot = Join-Path $scenarioRoot 'launch'
    $runtimeRoot = Join-Path $launchRoot 'runtime'
    $entrypoint = Join-Path $runtimeRoot 'node_modules\@deepseek-ai\dsh\lib\bin.js'
    $eventsPath = Join-Path $scenarioRoot 'events.log'
    $startupToken = '11111111111111111111111111111111'
    New-Item -ItemType Directory -Force -Path $launchRoot, (Split-Path $entrypoint -Parent) | Out-Null
    [IO.File]::WriteAllText($entrypoint, '// fake dsh', [Text.Encoding]::ASCII)
    [IO.File]::WriteAllText($eventsPath, '', [Text.Encoding]::ASCII)

    $fixture = Start-FakeHttpFixture -Body $Body -RequireToken:$RequireToken.IsPresent
    try {
        if ($RequireToken) {
            [IO.File]::WriteAllText(
                (Join-Path $launchRoot 'dsh-background.log'),
                "dsh web: http://127.0.0.1:$($fixture.Port)/?token=test-token`r`n",
                [Text.UTF8Encoding]::new($false)
            )
        }
        $output = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $harnessPath `
            -MonitorScript $monitorScript -LaunchRoot $launchRoot -EventsPath $eventsPath `
            -Port $fixture.Port -Entrypoint $entrypoint -RuntimeRoot $runtimeRoot `
            -StartupToken $startupToken -StableMilliseconds $StableMilliseconds 2>&1)
        $exitCode = $LASTEXITCODE
    } finally {
        if ($fixture.Process -and -not $fixture.Process.HasExited) {
            Stop-Process -Id $fixture.Process.Id -Force -ErrorAction SilentlyContinue
            $fixture.Process.WaitForExit()
        }
    }

    $statePath = Join-Path $launchRoot 'dsh-startup.json'
    return [pscustomobject]@{
        ExitCode = $exitCode
        Output = [string]($output -join [Environment]::NewLine)
        Events = [IO.File]::ReadAllText($eventsPath)
        State = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
        Entrypoint = $entrypoint
        RuntimeRoot = $runtimeRoot
        StartupToken = $startupToken
    }
}

New-Item -ItemType Directory -Force -Path $testRoot | Out-Null
$fixtureSource = @'
param([int]$Port, [string]$BodyPath, [switch]$RequireToken)
$bodyBytes = [Text.Encoding]::UTF8.GetBytes([IO.File]::ReadAllText($BodyPath, [Text.Encoding]::UTF8))
$unauthorizedBytes = [Text.Encoding]::UTF8.GetBytes('unauthorized')
$listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $Port)
$listener.Start()
try {
    while ($true) {
        $client = $listener.AcceptTcpClient()
        try {
            $stream = $client.GetStream()
            $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::ASCII, $false, 1024, $true)
            $requestLine = $reader.ReadLine()
            $cookieHeader = ''
            while ($true) {
                $line = $reader.ReadLine()
                if ($null -eq $line -or $line -eq '') { break }
                if ($line -match '(?i)^Cookie:\s*(.*)$') { $cookieHeader = $Matches[1] }
            }
            $hasToken = $requestLine -match '/\?token=test-token(?:\s|$)'
            $hasAuthCookie = $cookieHeader -match '(?i)(?:^|;\s*)dsh-auth-test=ok(?:;|$)'
            $isAuthorized = -not $RequireToken -or $hasAuthCookie
            $isTokenHandshake = $RequireToken -and $hasToken
            $responseBody = if ($isAuthorized) { $bodyBytes } else { $unauthorizedBytes }
            $statusLine = if ($isTokenHandshake) { 'HTTP/1.1 303 See Other' } elseif ($isAuthorized) { 'HTTP/1.1 200 OK' } else { 'HTTP/1.1 401 Unauthorized' }
            $redirectHeaders = if ($isTokenHandshake) { "Location: /`r`nSet-Cookie: dsh-auth-test=ok; Path=/`r`n" } else { '' }
            $headerBytes = [Text.Encoding]::ASCII.GetBytes("$statusLine`r`n$redirectHeaders" + "Content-Type: text/html; charset=utf-8`r`nContent-Length: $($responseBody.Length)`r`nConnection: close`r`n`r`n")
            $stream.Write($headerBytes, 0, $headerBytes.Length)
            $stream.Write($responseBody, 0, $responseBody.Length)
            $stream.Flush()
        } catch { } finally { $client.Close() }
    }
} finally { $listener.Stop() }
'@
[IO.File]::WriteAllText($fixtureScript, $fixtureSource, [Text.UTF8Encoding]::new($false))

$harness = @'
param(
    [string]$MonitorScript,
    [string]$LaunchRoot,
    [string]$EventsPath,
    [int]$Port,
    [string]$RuntimeRoot,
    [string]$Entrypoint,
    [string]$StartupToken,
    [int]$StableMilliseconds
)

function global:Get-NetTCPConnection {
    param([int]$LocalPort, [string]$State, [object]$ErrorAction)
    return [pscustomobject]@{ LocalAddress = '127.0.0.1'; LocalPort = $LocalPort; OwningProcess = 4321 }
}

function global:Get-CimInstance {
    param([string]$ClassName, [string]$Filter, [object]$ErrorAction)
    return [pscustomobject]@{
        ProcessId = 4321
        ParentProcessId = $PID
        Name = 'node.exe'
        CommandLine = 'node.exe "' + $Entrypoint + '" web'
        ExecutablePath = 'C:\node\node.exe'
    }
}

$env:DSH_TEST_MODE = '1'
$lockRoot = Join-Path $LaunchRoot 'dsh-startup.lock'
New-Item -ItemType Directory -Force -Path $lockRoot | Out-Null
$identity = [ordered]@{
    OwnerPid = $PID
    Token = $StartupToken
    CommandPath = $PSHOME + '\\powershell.exe'
    ScriptPath = $MonitorScript
    CreatedAt = [DateTime]::UtcNow.ToString('o')
}
[IO.File]::WriteAllText((Join-Path $lockRoot 'identity.json'), ($identity | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))

function global:Start-Process {
    param([Parameter(Position = 0)][string]$FilePath)
    [IO.File]::AppendAllText($EventsPath, "OPEN $FilePath`r`n", [Text.Encoding]::ASCII)
}

$state = [ordered]@{
    State = 'STARTING'
    Pid = $PID
    RunnerPid = $PID
    ServicePid = 0
    StartupToken = $StartupToken
    RuntimeRoot = $RuntimeRoot
    Entrypoint = $Entrypoint
    Version = '0.1.0-rc.8'
    StartedAt = [DateTime]::UtcNow.ToString('o')
    UpdatedAt = [DateTime]::UtcNow.ToString('o')
    Message = 'test startup'
    ExitCode = 0
}
[IO.File]::WriteAllText(
    (Join-Path $LaunchRoot 'dsh-startup.json'),
    ($state | ConvertTo-Json),
    [Text.UTF8Encoding]::new($false)
)

& $MonitorScript -TimeoutSeconds 1 -PollIntervalMilliseconds 50 `
    -LaunchRoot $LaunchRoot -OwnerPid $PID -StartupToken $StartupToken `
    -RuntimeRoot $RuntimeRoot -Entrypoint $Entrypoint -Port $Port `
    -StableMilliseconds $StableMilliseconds
exit $LASTEXITCODE
'@
[IO.File]::WriteAllText($harnessPath, $harness, [Text.UTF8Encoding]::new($false))

try {
    Invoke-Test 'generic HTTP 200 page never opens the browser or records READY' {
        $result = Invoke-MonitorScenario -ScenarioName 'generic-page' -Body '<html>other app</html>'
        Assert-Equal 1 $result.ExitCode "Generic page should time out. Output:`n$($result.Output)"
        Assert-NotMatch $result.Events '(?m)^OPEN ' 'A generic success page must not open the browser'
        Assert-Equal 'STARTING' $result.State.State 'A generic success page must not record READY'
    }

    Invoke-Test 'stable DSH identity opens once and records complete READY evidence' {
        $result = Invoke-MonitorScenario -ScenarioName 'stable-dsh-page' -Body '<div id="root"></div>'
        Assert-Equal 0 $result.ExitCode "Stable DSH page should become ready. Output:`n$($result.Output)"
        Assert-Equal 1 ([regex]::Matches($result.Events, '(?m)^OPEN http://127\.0\.0\.1:\d+\r?$').Count) `
            'Only one stable readiness transition may open the browser'
        Assert-Equal 'READY' $result.State.State 'Stable service identity must record READY before exit'
        Assert-Equal 4321 $result.State.ServicePid 'READY state must pin the classified service PID'
        Assert-Equal $result.StartupToken $result.State.StartupToken 'READY state must retain the startup token'
        Assert-Equal $result.RuntimeRoot $result.State.RuntimeRoot 'READY state must retain the runtime root'
        Assert-Equal $result.Entrypoint $result.State.Entrypoint 'READY state must retain the exact entrypoint'
    }

    Invoke-Test 'token-protected DSH page becomes ready using the URL from the startup log' {
        $result = Invoke-MonitorScenario -ScenarioName 'token-protected-dsh-page' `
            -Body '<div id="root"></div>' -RequireToken
        Assert-Equal 0 $result.ExitCode "A token-protected DSH page should become ready. Output:`n$($result.Output)"
        Assert-Match $result.Events '(?m)^OPEN http://127\.0\.0\.1:\d+/\?token=test-token\r?\n$' `
            'The monitor must open the token-protected DSH URL after readiness'
        Assert-Equal 'READY' $result.State.State 'A token-protected DSH page must record READY'
    }

    Write-Host "All $script:Passed readiness monitor behavior tests passed."
} finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}

exit 0
