param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Immediate', 'Ready', 'Failed', 'Duplicate', 'DuplicateReady', 'DuplicateFailed', 'OccupiedDuplicate', 'OccupiedForeign', 'OccupiedReady', 'OccupiedUnhealthy', 'Staged')]
    [string]$Scenario,

    [Parameter(Mandatory = $true)]
    [string]$ScriptPath,

    [Parameter(Mandatory = $true)]
    [string]$ProfilePath,

    [Parameter(Mandatory = $true)]
    [string]$ProcessLogPath,

    [ValidateRange(1, 65535)]
    [int]$Port = 3080,

    [ValidateRange(1, 86400)]
    [int]$TimeoutSeconds = 900,

    [ValidateRange(1, 3600)]
    [int]$HeartbeatSeconds = 30
)

$ErrorActionPreference = 'Stop'
$env:USERPROFILE = $ProfilePath
$env:DSH_TEST_MODE = '1'
$global:DshTestScenario = $Scenario
$global:DshTestPortChecks = 0
$global:DshTestProcessLogPath = $ProcessLogPath
$global:DshTestWebRequestCount = 0
$global:DshTestRunnerPid = 4242
$global:DshTestServicePid = 4343

$runtimeRoot = Join-Path $ProfilePath 'dsh-launch\runtime'
$dshRoot = Join-Path $runtimeRoot 'node_modules\@deepseek-ai\dsh'
New-Item -ItemType Directory -Force -Path (Join-Path $dshRoot 'lib') | Out-Null
[IO.File]::WriteAllText((Join-Path $dshRoot 'lib\bin.js'), ('#!/usr/bin/env node' + (';' * 2048)), [Text.Encoding]::ASCII)
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
    if ($global:DshTestScenario -eq 'Staged' -and $global:DshTestPortChecks -gt 1) {
        $statePath = Join-Path $env:USERPROFILE 'dsh-launch\dsh-startup.json'
        $stagedPhases = @('PREPARING_RUNTIME', 'INSTALLING_PEERS:21', 'VALIDATING_RUNTIME', 'STARTING_WEB')
        $phaseIndex = $global:DshTestPortChecks - 2
        if ($phaseIndex -lt $stagedPhases.Count -and (Test-Path -LiteralPath $statePath)) {
            $stagedState = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
            $stagedState.Message = $stagedPhases[$phaseIndex]
            [IO.File]::WriteAllText($statePath, ($stagedState | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
        }
        if ($global:DshTestPortChecks -lt ($stagedPhases.Count + 3)) { return $null }
    }

    if ($global:DshTestScenario -in @('OccupiedForeign', 'OccupiedReady', 'OccupiedUnhealthy')) {
        return [pscustomobject]@{
            LocalAddress = '127.0.0.1'
            LocalPort = $LocalPort
            OwningProcess = $global:DshTestServicePid
        }
    }
    if ($global:DshTestPortChecks -eq 1 -or $global:DshTestScenario -eq 'Failed') {
        return $null
    }

    return [pscustomobject]@{
        LocalAddress = '127.0.0.1'
        LocalPort = $LocalPort
        OwningProcess = $global:DshTestServicePid
    }
}

function global:Get-CimInstance {
    param(
        [string]$ClassName,
        [string]$Filter
    )

    $processId = if ($Filter -match 'ProcessId=(\d+)') { [int]$Matches[1] } else { 0 }
    if ($processId -eq $global:DshTestRunnerPid) {
        return [pscustomobject]@{
            Name = 'powershell.exe'
            CommandLine = 'powershell.exe -File "' + (Join-Path (Split-Path $ScriptPath -Parent) 'background-run.ps1') + '"'
            ExecutablePath = Join-Path $PSHOME 'powershell.exe'
        }
    }
    if ($processId -ne $global:DshTestServicePid) {
        return CimCmdlets\Get-CimInstance -ClassName $ClassName -Filter $Filter
    }
    if ($global:DshTestScenario -eq 'OccupiedForeign') {
        return [pscustomobject]@{
            Name = 'other-server.exe'
            CommandLine = 'C:\apps\other-server.exe --serve'
            ExecutablePath = 'C:\apps\other-server.exe'
        }
    }
    $serviceParentPid = if ($global:DshTestScenario -in @('Duplicate', 'DuplicateReady', 'DuplicateFailed', 'OccupiedReady')) {
        $PID
    } else {
        $global:DshTestRunnerPid
    }
    return [pscustomobject]@{
        ProcessId = $processId
        ParentProcessId = $serviceParentPid
        Name = 'node.exe'
        CommandLine = 'node.exe "' + (Join-Path $dshRoot 'lib\bin.js') + '" web'
        ExecutablePath = 'C:\node\node.exe'
    }
}

function global:Get-Process {
    param([int]$Id, [object]$ErrorAction)

    if ($Id -eq $global:DshTestRunnerPid) {
        return [pscustomobject]@{ Id = $Id; HasExited = $false }
    }
    return Microsoft.PowerShell.Management\Get-Process -Id $Id -ErrorAction $ErrorAction
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
            Id        = $global:DshTestRunnerPid
            HasExited = ($global:DshTestScenario -in @('Immediate', 'Failed'))
        }
    }
}

function global:Start-Sleep {
    param(
        [int]$Seconds,
        [int]$Milliseconds
    )

    if ($global:DshTestScenario -eq 'Staged') {
        if ($Milliseconds) { [Threading.Thread]::Sleep($Milliseconds) }
        elseif ($Seconds) { [Threading.Thread]::Sleep($Seconds * 1000) }
    }
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

if ($Scenario -eq 'Staged') {
    $logDirectory = Join-Path $ProfilePath 'dsh-launch'
    New-Item -ItemType Directory -Force -Path $logDirectory | Out-Null
    Start-Transcript -LiteralPath (Join-Path $logDirectory 'staged-output.txt') -Force | Out-Null
}

$testStartupToken = '22222222222222222222222222222222'
if ($Scenario -in @('Duplicate', 'DuplicateReady', 'DuplicateFailed', 'OccupiedReady')) {
    $lockDirectory = Join-Path $ProfilePath 'dsh-launch\dsh-startup.lock'
    New-Item -ItemType Directory -Force -Path $lockDirectory | Out-Null
    Set-Content -LiteralPath (Join-Path $lockDirectory 'pid.txt') -Value $PID -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $lockDirectory 'token.txt') -Value $testStartupToken -Encoding ASCII
    [IO.File]::WriteAllText(
        (Join-Path $lockDirectory 'command-path.txt'),
        (Join-Path $PSHOME 'powershell.exe'),
        [Text.UTF8Encoding]::new($false)
    )
    [IO.File]::WriteAllText(
        (Join-Path $lockDirectory 'script-path.txt'),
        [IO.Path]::GetFullPath($MyInvocation.MyCommand.Path),
        [Text.UTF8Encoding]::new($false)
    )
    Set-Content -LiteralPath (Join-Path $lockDirectory 'created-at.txt') `
        -Value ([DateTime]::UtcNow.ToString('o')) -Encoding ASCII
    [IO.File]::WriteAllText(
        (Join-Path $lockDirectory 'identity.json'),
        (@{ OwnerPid = $PID; Token = $testStartupToken; CommandPath = (Join-Path $PSHOME 'powershell.exe'); ScriptPath = [IO.Path]::GetFullPath($MyInvocation.MyCommand.Path); CreatedAt = [DateTime]::UtcNow.ToString('o') } | ConvertTo-Json -Compress),
        [Text.UTF8Encoding]::new($false)
    )
}

if ($Scenario -in @('Duplicate', 'DuplicateReady', 'OccupiedReady', 'OccupiedUnhealthy')) {
    $statePath = Join-Path $ProfilePath 'dsh-launch\dsh-startup.json'
    $state = [ordered]@{
        State = if ($Scenario -eq 'OccupiedReady') { 'READY' } else { 'STARTING' }
        Pid = $PID
        RunnerPid = $PID
        ServicePid = if ($Scenario -eq 'OccupiedReady') { $global:DshTestServicePid } else { 0 }
        StartupToken = $testStartupToken
        RuntimeRoot = $runtimeRoot
        Entrypoint = Join-Path $dshRoot 'lib\bin.js'
        Version = '0.1.0-rc.8'
        StartedAt = [DateTime]::UtcNow.ToString('o')
        UpdatedAt = [DateTime]::UtcNow.ToString('o')
        Message = 'test startup'
        ExitCode = 0
    }
    [IO.File]::WriteAllText($statePath, ($state | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
}

$listener = $null
if ($Scenario -eq 'OccupiedDuplicate') {
    $lockDirectory = Join-Path $ProfilePath 'dsh-launch\dsh-startup.lock'
    New-Item -ItemType Directory -Force -Path $lockDirectory | Out-Null
    Set-Content -LiteralPath (Join-Path $lockDirectory 'pid.txt') -Value $PID -Encoding ASCII
    [IO.File]::WriteAllText(
        (Join-Path $lockDirectory 'command-path.txt'),
        (Join-Path $PSHOME 'powershell.exe'),
        [Text.UTF8Encoding]::new($false)
    )
    [IO.File]::WriteAllText(
        (Join-Path $lockDirectory 'script-path.txt'),
        [IO.Path]::GetFullPath($MyInvocation.MyCommand.Path),
        [Text.UTF8Encoding]::new($false)
    )
    Set-Content -LiteralPath (Join-Path $lockDirectory 'created-at.txt') `
        -Value ([DateTime]::UtcNow.ToString('o')) -Encoding ASCII
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $Port)
    $listener.Start()
}

if ($Scenario -eq 'DuplicateFailed') {
    $statePath = Join-Path $ProfilePath 'dsh-launch\dsh-startup.json'
    $failedState = [ordered]@{
        State = 'FAILED'; Pid = $PID; RunnerPid = $PID; ServicePid = 0
        StartupToken = $testStartupToken; RuntimeRoot = $runtimeRoot
        Entrypoint = Join-Path $dshRoot 'lib\bin.js'; Version = '0.1.0-rc.8'
        Message = 'existing startup failed'; ExitCode = 7
    }
    [IO.File]::WriteAllText($statePath, ($failedState | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
}

try {
    if ($Scenario -in @('Immediate', 'Duplicate', 'OccupiedDuplicate', 'OccupiedForeign', 'OccupiedReady', 'OccupiedUnhealthy')) {
        & $ScriptPath -TimeoutSeconds $TimeoutSeconds -Port $Port
    } else {
        & $ScriptPath -WaitForReady -TimeoutSeconds $TimeoutSeconds -Port $Port -HeartbeatSeconds $HeartbeatSeconds
    }
} finally {
    if ($listener) { $listener.Stop() }
}

$scriptExitCode = if ($LASTEXITCODE -is [int]) { $LASTEXITCODE } elseif ($?) { 0 } else { 1 }
exit $scriptExitCode
