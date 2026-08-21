param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Immediate', 'Ready', 'Failed', 'Duplicate', 'DuplicateReady', 'DuplicateFailed', 'OccupiedDuplicate')]
    [string]$Scenario,

    [Parameter(Mandatory = $true)]
    [string]$ScriptPath,

    [Parameter(Mandatory = $true)]
    [string]$ProfilePath,

    [Parameter(Mandatory = $true)]
    [string]$ProcessLogPath,

    [ValidateRange(1, 65535)]
    [int]$Port = 3080
)

$ErrorActionPreference = 'Stop'
$env:USERPROFILE = $ProfilePath
$global:DshTestScenario = $Scenario
$global:DshTestPortChecks = 0
$global:DshTestProcessLogPath = $ProcessLogPath

$runtimeRoot = Join-Path $ProfilePath 'dsh-launch\runtime'
$dshRoot = Join-Path $runtimeRoot 'node_modules\@deepseek-ai\dsh'
New-Item -ItemType Directory -Force -Path (Join-Path $dshRoot 'lib') | Out-Null
[IO.File]::WriteAllText((Join-Path $dshRoot 'lib\bin.js'), '// fake dsh', [Text.Encoding]::ASCII)
[IO.File]::WriteAllText(
    (Join-Path $dshRoot 'package.json'),
    '{"name":"@deepseek-ai/dsh","version":"0.1.0-rc.8"}',
    [Text.Encoding]::ASCII
)
[IO.File]::WriteAllText(
    (Join-Path $runtimeRoot 'dsh-runtime-ready.json'),
    '{"SchemaVersion":2,"Version":"0.1.0-rc.8","ValidatedBy":"npm-ls-all"}',
    [Text.Encoding]::ASCII
)

function global:Get-NetTCPConnection {
    param(
        [int]$LocalPort,
        [string]$State,
        [object]$ErrorAction
    )

    $global:DshTestPortChecks++
    [IO.File]::AppendAllText(
        $global:DshTestProcessLogPath,
        "GET_NET_TCP_CONNECTION`t$LocalPort$([Environment]::NewLine)",
        [Text.Encoding]::UTF8
    )
    if ($global:DshTestPortChecks -eq 1 -or $global:DshTestScenario -eq 'Failed') {
        return $null
    }

    return [pscustomobject]@{ OwningProcess = 4242 }
}

function global:Start-Process {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [string]$FilePath,
        [object[]]$ArgumentList,
        [string]$WorkingDirectory,
        [object]$WindowStyle,
        [switch]$PassThru
    )

    $argumentsText = if ($ArgumentList) { $ArgumentList -join ' ' } else { '' }
    $startupToken = [string]$env:DSH_STARTUP_TOKEN
    $tokenSuffix = if ($PassThru) {
        $lockPresent = Test-Path -LiteralPath (Join-Path $env:USERPROFILE 'dsh-launch\dsh-startup.lock\pid.txt')
        $suppressMonitor = [string]$env:DSH_SUPPRESS_BROWSER_MONITOR
        $coordinatorGate = [string]$env:DSH_COORDINATOR_GATE
        "`tSTARTUP_TOKEN=$startupToken`tLOCK_PRESENT=$lockPresent`tSUPPRESS_MONITOR=$suppressMonitor`tGATE=$coordinatorGate"
    } else { '' }
    [IO.File]::AppendAllText(
        $global:DshTestProcessLogPath,
        "$FilePath`t$argumentsText$tokenSuffix$([Environment]::NewLine)",
        [Text.Encoding]::UTF8
    )

    if ($PassThru) {
        return [pscustomobject]@{
            Id        = 4242
            HasExited = ($global:DshTestScenario -in @('Immediate', 'Failed'))
        }
    }
}

function global:Invoke-WebRequest {
    param(
        [string]$Uri,
        [switch]$UseBasicParsing,
        [int]$TimeoutSec,
        [object]$ErrorAction
    )

    [IO.File]::AppendAllText(
        $global:DshTestProcessLogPath,
        "WEB_REQUEST`t$Uri$([Environment]::NewLine)",
        [Text.Encoding]::UTF8
    )

    if ($global:DshTestScenario -in @('Ready', 'DuplicateReady')) {
        return [pscustomobject]@{ StatusCode = 200 }
    }

    throw 'HTTP endpoint is not ready'
}

function global:Start-Sleep {
    param(
        [int]$Seconds,
        [int]$Milliseconds
    )
}

if ($Scenario -eq 'Failed') {
    $logDirectory = Join-Path $ProfilePath 'dsh-launch'
    New-Item -ItemType Directory -Force -Path $logDirectory | Out-Null
    $utf8LogLine = [string]::Concat([char]0x5468, [char]0x56DB, ' simulated launch failure')
    [IO.File]::WriteAllText(
        (Join-Path $logDirectory 'dsh-background.log'),
        $utf8LogLine,
        [Text.UTF8Encoding]::new($false)
    )
    Start-Transcript -LiteralPath (Join-Path $logDirectory 'failure-output.txt') -Force | Out-Null
}

if ($Scenario -in @('Duplicate', 'DuplicateReady', 'DuplicateFailed')) {
    $lockDirectory = Join-Path $ProfilePath 'dsh-launch\dsh-startup.lock'
    New-Item -ItemType Directory -Force -Path $lockDirectory | Out-Null
    Set-Content -LiteralPath (Join-Path $lockDirectory 'pid.txt') -Value $PID -Encoding ASCII
}

$listener = $null
if ($Scenario -eq 'OccupiedDuplicate') {
    $lockDirectory = Join-Path $ProfilePath 'dsh-launch\dsh-startup.lock'
    New-Item -ItemType Directory -Force -Path $lockDirectory | Out-Null
    Set-Content -LiteralPath (Join-Path $lockDirectory 'pid.txt') -Value $PID -Encoding ASCII
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $Port)
    $listener.Start()
}

if ($Scenario -eq 'DuplicateFailed') {
    $statePath = Join-Path $ProfilePath 'dsh-launch\dsh-startup.json'
    [IO.File]::WriteAllText(
        $statePath,
        '{"State":"FAILED","Pid":0,"Version":"0.1.0-rc.8","Message":"existing startup failed","ExitCode":7}',
        [Text.Encoding]::ASCII
    )
}

try {
    if ($Scenario -in @('Immediate', 'Duplicate', 'OccupiedDuplicate')) {
        & $ScriptPath -TimeoutSeconds 900 -Port $Port
    } else {
        & $ScriptPath -WaitForReady -TimeoutSeconds 900 -Port $Port
    }
} finally {
    if ($listener) { $listener.Stop() }
}

$scriptExitCode = if ($LASTEXITCODE -is [int]) { $LASTEXITCODE } elseif ($?) { 0 } else { 1 }
exit $scriptExitCode
