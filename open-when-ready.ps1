param(
    [int]$TimeoutSeconds = 900,
    [int]$ParentPid = 0,
    [Parameter(Mandatory = $true)]
    [string]$LaunchRoot,
    [Parameter(Mandatory = $true)]
    [int]$OwnerPid,
    [Parameter(Mandatory = $true)]
    [string]$StartupToken,
    [Parameter(Mandatory = $true)]
    [string]$RuntimeRoot,
    [Parameter(Mandatory = $true)]
    [string]$Entrypoint,
    [ValidateRange(1, 65535)]
    [int]$Port = 3080,
    [ValidateRange(0, 60000)]
    [int]$StableMilliseconds = 5000,
    [ValidateRange(50, 5000)]
    [int]$PollIntervalMilliseconds = 200
)

$ErrorActionPreference = 'Stop'
if ($Port -ne 3080 -and $env:DSH_TEST_MODE -ne '1') {
    Write-Host '[ERROR] Production lifecycle startup only supports port 3080. Set DSH_TEST_MODE=1 only for isolated tests.'
    exit 1
}
$url = "http://127.0.0.1:$Port"
$stateHelper = Join-Path $PSScriptRoot 'dsh-launch-state.ps1'
$healthHelper = Join-Path $PSScriptRoot 'dsh-service-health.ps1'
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
. $healthHelper

while ((Get-Date) -lt $deadline) {
    if ($ParentPid -gt 0 -and -not (Get-Process -Id $ParentPid -ErrorAction SilentlyContinue)) {
        exit 0
    }

    $classification = Wait-DshServiceIdentity -Port $Port -ExpectedEntrypoint $Entrypoint `
        -ExpectedStartupToken $StartupToken -RunnerPid $OwnerPid -LaunchRoot $LaunchRoot `
        -StableMilliseconds $StableMilliseconds -PollMilliseconds $PollIntervalMilliseconds
    if ($classification.State -eq 'READY') {
        & $stateHelper -Action WriteStartupState -LaunchRoot $LaunchRoot -State READY `
            -OwnerPid $OwnerPid -ServicePid ([int]$classification.ServicePid) `
            -StartupToken $StartupToken -RuntimeRoot $RuntimeRoot -Entrypoint $Entrypoint `
            -Message $classification.Message | Out-Null
        $openUrl = Get-DshStartupUrl -LaunchRoot $LaunchRoot -Port $Port `
            -ExpectedStartupToken $StartupToken -ExpectedOwnerPid $OwnerPid
        if ([string]::IsNullOrWhiteSpace($openUrl)) { $openUrl = $url }
        Start-Process $openUrl
        exit 0
    }

    Start-Sleep -Milliseconds $PollIntervalMilliseconds
}

exit 1
