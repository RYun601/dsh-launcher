param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Immediate', 'Ready', 'Failed')]
    [string]$Scenario,

    [Parameter(Mandatory = $true)]
    [string]$ScriptPath,

    [Parameter(Mandatory = $true)]
    [string]$ProfilePath,

    [Parameter(Mandatory = $true)]
    [string]$ProcessLogPath
)

$ErrorActionPreference = 'Stop'
$env:USERPROFILE = $ProfilePath
$global:DshTestScenario = $Scenario
$global:DshTestPortChecks = 0
$global:DshTestProcessLogPath = $ProcessLogPath

function global:Get-NetTCPConnection {
    param(
        [int]$LocalPort,
        [string]$State,
        [object]$ErrorAction
    )

    $global:DshTestPortChecks++
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
    [IO.File]::AppendAllText(
        $global:DshTestProcessLogPath,
        "$FilePath`t$argumentsText$([Environment]::NewLine)",
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

    if ($global:DshTestScenario -eq 'Ready') {
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
    [IO.File]::WriteAllText(
        (Join-Path $logDirectory 'dsh-background.log'),
        'simulated launch failure',
        [Text.Encoding]::UTF8
    )
}

if ($Scenario -eq 'Immediate') {
    & $ScriptPath -TimeoutSeconds 900
} else {
    & $ScriptPath -WaitForReady -TimeoutSeconds 900
}

$scriptExitCode = if ($LASTEXITCODE -is [int]) { $LASTEXITCODE } elseif ($?) { 0 } else { 1 }
exit $scriptExitCode
