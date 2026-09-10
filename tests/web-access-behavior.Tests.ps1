$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$healthHelper = Join-Path $repoRoot 'dsh-service-health.ps1'
$testRoot = Join-Path $env:TEMP ('dsh-web-access-tests-' + [guid]::NewGuid().ToString('N'))
$launchRoot = Join-Path $testRoot 'dsh-launch'
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

function Assert-Null {
    param($Actual, [string]$Message)
    if ($null -ne $Actual) { throw "$Message (actual: $Actual)" }
}

function Invoke-Test {
    param([string]$Name, [scriptblock]$Body)
    & $Body
    $script:Passed++
    Write-Host "PASS: $Name"
}

New-Item -ItemType Directory -Force -Path $launchRoot | Out-Null
try {
    . $healthHelper

    Invoke-Test 'startup output parser extracts a loopback token URL' {
        $url = Get-DshStartupUrlFromLine -Line 'dsh web: http://127.0.0.1:3080/?token=test-token' -Port 3080
        Assert-Equal 'http://127.0.0.1:3080/?token=test-token' $url 'The parser must return the authenticated URL'
    }

    Invoke-Test 'startup output parser ignores the optional LAN display suffix' {
        $url = Get-DshStartupUrlFromLine `
            -Line 'dsh web: http://127.0.0.1:3080/?token=test-token (LAN: http://192.0.2.10:3080/?token=lan-token)' `
            -Port 3080
        Assert-Equal 'http://127.0.0.1:3080/?token=test-token' $url 'Only the loopback URL may be recorded'
    }

    Invoke-Test 'web access record round-trips and binds to the startup owner' {
        $token = '11111111111111111111111111111111'
        $url = 'http://127.0.0.1:3080/?token=test-token'
        Write-DshWebAccessRecord -LaunchRoot $launchRoot -StartupToken $token -OwnerPid $PID -Port 3080 -Url $url
        $record = Get-DshWebAccessRecord -LaunchRoot $launchRoot `
            -ExpectedStartupToken $token -ExpectedOwnerPid $PID -Port 3080
        Assert-True ($null -ne $record) 'A valid access record must be readable'
        Assert-Equal 1 $record.SchemaVersion 'The access record schema must be versioned'
        Assert-Equal $token $record.StartupToken 'The access record must retain the launcher startup token'
        Assert-Equal $PID ([int]$record.OwnerPid) 'The access record must retain the runner owner PID'
        Assert-Equal $url $record.AuthenticatedUrl 'The access record must retain the authenticated URL'
        Assert-True (Test-Path -LiteralPath (Join-Path $launchRoot 'dsh-web-access.json')) `
            'The access record must live below the launch root'
        Assert-Equal 0 @(Get-ChildItem -LiteralPath $launchRoot -Filter 'dsh-web-access-*.tmp' -File).Count `
            'Atomic access-record writes must not leave temporary files behind'
    }

    Invoke-Test 'startup URL lookup prefers the identity-bound access record' {
        $url = Get-DshStartupUrl -LaunchRoot $launchRoot -Port 3080 `
            -ExpectedStartupToken '11111111111111111111111111111111' -ExpectedOwnerPid $PID
        Assert-Equal 'http://127.0.0.1:3080/?token=test-token' $url `
            'Health probes must use the current authenticated URL record'
    }

    Invoke-Test 'mismatched access-record identity fails closed' {
        $record = Get-DshWebAccessRecord -LaunchRoot $launchRoot `
            -ExpectedStartupToken '22222222222222222222222222222222' -ExpectedOwnerPid $PID -Port 3080
        Assert-Null $record 'A record from another startup must not be usable'
        $record = Get-DshWebAccessRecord -LaunchRoot $launchRoot `
            -ExpectedStartupToken '11111111111111111111111111111111' -ExpectedOwnerPid 99999 -Port 3080
        Assert-Null $record 'A record from another owner must not be usable'
    }

    Invoke-Test 'record cleanup requires the matching startup token' {
        Remove-DshWebAccessRecord -LaunchRoot $launchRoot -ExpectedStartupToken '22222222222222222222222222222222'
        Assert-True (Test-Path -LiteralPath (Join-Path $launchRoot 'dsh-web-access.json')) `
            'A different startup must not remove the current access record'
        Remove-DshWebAccessRecord -LaunchRoot $launchRoot `
            -ExpectedStartupToken '11111111111111111111111111111111'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $launchRoot 'dsh-web-access.json'))) `
            'The owning startup must be able to remove its access record'
    }

    Invoke-Test 'unsafe startup output is not accepted as an access URL' {
        Assert-Equal '' (Get-DshStartupUrlFromLine -Line 'dsh web: http://localhost:3080/?token=test-token' -Port 3080) `
            'The access URL must use the fixed loopback authority'
        Assert-Equal '' (Get-DshStartupUrlFromLine -Line 'dsh web: http://127.0.0.1:3081/?token=test-token' -Port 3080) `
            'The access URL must use the selected port'
        Assert-Equal '' (Get-DshStartupUrlFromLine -Line 'dsh web: http://127.0.0.1:3080/?token=a&other=b' -Port 3080) `
            'The access URL must not carry extra query parameters'
    }

    Write-Host "All $script:Passed web access behavior tests passed."
} finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}

exit 0
