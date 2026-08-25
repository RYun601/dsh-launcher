$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$healthHelper = Join-Path $repoRoot 'dsh-service-health.ps1'
$testRoot = Join-Path $env:TEMP ('dsh-service-health-tests-' + [guid]::NewGuid().ToString('N'))
$fixtureScript = Join-Path $testRoot 'fake-http-fixture.ps1'
$script:ExpectedEntrypoint = Join-Path $testRoot 'runtime\node_modules\@deepseek-ai\dsh\lib\bin.js'
$script:ExpectedStartupToken = '11111111111111111111111111111111'
$script:ExpectedRunnerPid = $PID
$script:DshTestProcessInfo = $null
$script:DshTestFixtureMaxRequests = 0
$script:Passed = 0

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)

    if ($Expected -ne $Actual) {
        throw "$Message (expected: $Expected, actual: $Actual)"
    }
}

function Assert-True {
    param([bool]$Condition, [string]$Message)

    if (-not $Condition) { throw $Message }
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
        [Parameter(Mandatory = $true)][int]$StatusCode
    )

    $port = Get-FreeTcpPort
    $bodyPath = Join-Path $testRoot ('body-' + [guid]::NewGuid().ToString('N') + '.txt')
    [IO.File]::WriteAllText($bodyPath, $Body, [Text.UTF8Encoding]::new($false))

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = 'powershell.exe'
    $startInfo.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $fixtureScript +
        '" -Port ' + $port + ' -BodyPath "' + $bodyPath + '" -StatusCode ' + $StatusCode +
        ' -MaxRequests ' + $script:DshTestFixtureMaxRequests
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = [Diagnostics.Process]::Start($startInfo)

    for ($attempt = 0; $attempt -lt 50; $attempt++) {
        try {
            $probe = [Net.Sockets.TcpClient]::new()
            $pending = $probe.BeginConnect('127.0.0.1', $port, $null, $null)
            if ($pending.AsyncWaitHandle.WaitOne(100)) {
                $probe.EndConnect($pending)
                $probe.Close()
                return [pscustomobject]@{ Port = $port; Process = $process; BodyPath = $bodyPath }
            }
            $probe.Close()
        } catch { }
        Start-Sleep -Milliseconds 100
    }

    if (-not $process.HasExited) { $process.Kill() }
    $diagnostic = $process.StandardError.ReadToEnd()
    throw "Fake HTTP fixture on port $port did not start. $diagnostic"
}

function Stop-FakeHttpFixture {
    param([Parameter(Mandatory = $true)]$Fixture)

    if ($Fixture.Process -and -not $Fixture.Process.HasExited) {
        Stop-Process -Id $Fixture.Process.Id -Force -ErrorAction SilentlyContinue
        $Fixture.Process.WaitForExit()
    }
}

function Invoke-Classification {
    param(
        [string]$CommandLine,
        [string]$Body,
        [int]$StatusCode,
        [int]$StableMilliseconds = 0
    )
    $script:DshTestProcessInfo = [pscustomobject]@{
        Name = if ($CommandLine -match '^node(?:\.exe)?\s') { 'node.exe' } else { 'powershell.exe' }
        CommandLine = $CommandLine
        ExecutablePath = if ($CommandLine -match '^node(?:\.exe)?\s') { 'C:\node\node.exe' } else { 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' }
    }
    $fixture = Start-FakeHttpFixture -Body $Body -StatusCode $StatusCode
    try {
        return Wait-DshServiceIdentity -Port $fixture.Port -ExpectedEntrypoint $script:ExpectedEntrypoint `
            -ExpectedStartupToken $script:ExpectedStartupToken -RunnerPid $script:ExpectedRunnerPid `
            -StableMilliseconds $StableMilliseconds -PollMilliseconds 25
    } finally {
        Stop-FakeHttpFixture -Fixture $fixture
    }
}

New-Item -ItemType Directory -Force -Path $testRoot | Out-Null
$fixtureSource = @'
param(
    [int]$Port,
    [string]$BodyPath,
    [int]$StatusCode,
    [int]$MaxRequests = 0
)

$body = [IO.File]::ReadAllText($BodyPath, [Text.Encoding]::UTF8)
$bodyBytes = [Text.Encoding]::UTF8.GetBytes($body)
$header = "HTTP/1.1 $StatusCode Test`r`nContent-Type: text/html; charset=utf-8`r`nContent-Length: $($bodyBytes.Length)`r`nConnection: close`r`n`r`n"
$headerBytes = [Text.Encoding]::ASCII.GetBytes($header)
$listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $Port)
$listener.Start()
$served = 0
try {
    while ($MaxRequests -le 0 -or $served -lt $MaxRequests) {
        $client = $listener.AcceptTcpClient()
        try {
            $stream = $client.GetStream()
            $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::ASCII, $false, 1024, $true)
            while ($true) {
                $line = $reader.ReadLine()
                if ($null -eq $line -or $line -eq '') { break }
            }
            $stream.Write($headerBytes, 0, $headerBytes.Length)
            $stream.Write($bodyBytes, 0, $bodyBytes.Length)
            $stream.Flush()
        } catch { } finally {
            $client.Close()
            $served++
        }
    }
} finally {
    $listener.Stop()
}
'@
[IO.File]::WriteAllText($fixtureScript, $fixtureSource, [Text.UTF8Encoding]::new($false))

$priorCimFunction = Get-Item -LiteralPath Function:\Get-CimInstance -ErrorAction SilentlyContinue
$priorCimScriptBlock = if ($priorCimFunction) { $priorCimFunction.ScriptBlock } else { $null }
function Get-CimInstance {
    param(
        [Parameter(Position = 0)][string]$ClassName,
        [string]$Filter
    )

    return $script:DshTestProcessInfo
}

try {
    . $healthHelper

    $expectedNodeCommand = 'node.exe "' + $script:ExpectedEntrypoint + '" --port 12345'

    Invoke-Test 'wrong entrypoint is foreign' {
        $foreign = Invoke-Classification -CommandLine 'node.exe C:\apps\other\server.js' -Body '<div id="root"></div>' -StatusCode 200
        Assert-Equal 'FOREIGN_PORT' $foreign.State 'Wrong entrypoint must be foreign'
    }

    Invoke-Test 'substring marker does not establish process identity' {
        $spoof = Invoke-Classification -CommandLine 'powershell.exe -Command "# @deepseek-ai/dsh/lib/bin.js"' -Body '<div id="root"></div>' -StatusCode 200
        Assert-Equal 'FOREIGN_PORT' $spoof.State 'A substring marker must not establish identity'
    }

    Invoke-Test 'identified listener with failed HTTP is unhealthy' {
        $dead = Invoke-Classification -CommandLine $expectedNodeCommand -Body 'error' -StatusCode 500
        Assert-Equal 'UNHEALTHY' $dead.State 'An identified listener with dead HTTP is unhealthy'
        Assert-Equal 500 $dead.HttpStatus 'The failed HTTP status must remain observable'
    }

    Invoke-Test 'generic success page is unhealthy' {
        $wrongBody = Invoke-Classification -CommandLine $expectedNodeCommand -Body '<html>other app</html>' -StatusCode 200
        Assert-Equal 'UNHEALTHY' $wrongBody.State 'A generic success page is not DSH'
    }

    Invoke-Test 'exact identity and stable DSH page are ready' {
        $ready = Invoke-Classification -CommandLine $expectedNodeCommand -Body '<div id="root"></div>' -StatusCode 200 -StableMilliseconds 200
        Assert-Equal 'READY' $ready.State 'Exact identity and stable DSH page must be ready'
        Assert-True ($ready.ServicePid -gt 0) 'READY must identify the listening process'
        Assert-Equal ([IO.Path]::GetFullPath($script:ExpectedEntrypoint)) $ready.Entrypoint 'READY must report the normalized entrypoint'
    }

    Invoke-Test 'startup evidence is mandatory' {
        $script:DshTestProcessInfo = [pscustomobject]@{
            Name = 'node.exe'
            CommandLine = $expectedNodeCommand
            ExecutablePath = 'C:\node\node.exe'
        }
        $fixture = Start-FakeHttpFixture -Body '<div id="root"></div>' -StatusCode 200
        try {
            $missingToken = Get-DshServiceClassification -Port $fixture.Port `
                -ExpectedEntrypoint $script:ExpectedEntrypoint -ExpectedStartupToken '' -RunnerPid $PID
            Assert-Equal 'UNHEALTHY' $missingToken.State 'An empty startup token must not establish a managed service'

            $deadRunner = Get-DshServiceClassification -Port $fixture.Port `
                -ExpectedEntrypoint $script:ExpectedEntrypoint -ExpectedStartupToken $script:ExpectedStartupToken `
                -RunnerPid 2147483647
            Assert-Equal 'UNHEALTHY' $deadRunner.State 'A dead runner must not establish a managed service'
        } finally {
            Stop-FakeHttpFixture -Fixture $fixture
        }
    }

    Invoke-Test 'HTTP probe does not accept a marker beyond 256 KiB' {
        $oversizedBody = ('x' * 262144) + '<div id="root"></div>'
        $bounded = Invoke-Classification -CommandLine $expectedNodeCommand -Body $oversizedBody -StatusCode 200
        Assert-Equal 'UNHEALTHY' $bounded.State 'The HTTP identity marker must be found within the bounded read'
    }

    Invoke-Test 'listener exit inside stability window never returns ready' {
        $script:DshTestProcessInfo = [pscustomobject]@{
            Name = 'node.exe'
            CommandLine = $expectedNodeCommand
            ExecutablePath = 'C:\node\node.exe'
        }
        $script:DshTestFixtureMaxRequests = 2
        $fixture = Start-FakeHttpFixture -Body '<div id="root"></div>' -StatusCode 200
        try {
            $result = Wait-DshServiceIdentity -Port $fixture.Port -ExpectedEntrypoint $script:ExpectedEntrypoint `
                -ExpectedStartupToken $script:ExpectedStartupToken -RunnerPid $PID `
                -StableMilliseconds 500 -PollMilliseconds 25
            Assert-True ($result.State -ne 'READY') 'A listener that exits during stabilization must never be READY'
        } finally {
            $script:DshTestFixtureMaxRequests = 0
            Stop-FakeHttpFixture -Fixture $fixture
        }
    }

    Write-Host "All $script:Passed service health behavior tests passed."
} finally {
    if ($priorCimScriptBlock) {
        Set-Item -LiteralPath Function:\Get-CimInstance -Value $priorCimScriptBlock
    } else {
        Remove-Item -LiteralPath Function:\Get-CimInstance -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}

exit 0
