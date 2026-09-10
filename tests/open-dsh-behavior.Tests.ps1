$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$openScript = Join-Path $repoRoot 'open-dsh.ps1'
$testRoot = Join-Path $env:TEMP ('dsh-open-dsh-tests-' + [guid]::NewGuid().ToString('N'))
$launchRoot = Join-Path $testRoot 'profile\dsh-launch'
$browserRoot = Join-Path $testRoot 'browsers'
$eventsPath = Join-Path $testRoot 'browser-events.log'
$harnessPath = Join-Path $testRoot 'open-harness.ps1'
$script:Passed = 0

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    if ($Expected -ne $Actual) { throw "$Message (expected: $Expected, actual: $Actual)" }
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
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

function Invoke-OpenScenario {
    param(
        [string]$Browser = 'edge',
        [string]$State = 'READY',
        [string]$Url = 'http://127.0.0.1:3080/?token=test-token'
    )

    [IO.File]::WriteAllText($eventsPath, '', [Text.Encoding]::ASCII)
    $token = '11111111111111111111111111111111'
    $stateDocument = [ordered]@{
        State = $State
        Pid = $PID
        RunnerPid = $PID
        ServicePid = 4321
        StartupToken = $token
        RuntimeRoot = (Join-Path $launchRoot 'runtime')
        Entrypoint = (Join-Path $launchRoot 'runtime\node_modules\@deepseek-ai\dsh\lib\bin.js')
        Version = '0.1.2-rc.1'
        StartedAt = [DateTime]::UtcNow.ToString('o')
        UpdatedAt = [DateTime]::UtcNow.ToString('o')
        Message = 'test'
        ExitCode = 0
    }
    [IO.File]::WriteAllText(
        (Join-Path $launchRoot 'dsh-startup.json'),
        ($stateDocument | ConvertTo-Json),
        [Text.UTF8Encoding]::new($false)
    )

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $harnessPath `
            -OpenScript $openScript -LaunchRoot $launchRoot -EventsPath $eventsPath `
            -StartupToken $token -State $State -Url $Url -Browser $Browser 2>&1
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    return [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output = [string]($output -join [Environment]::NewLine)
        Events = [IO.File]::ReadAllText($eventsPath)
    }
}

New-Item -ItemType Directory -Force -Path $launchRoot, $browserRoot | Out-Null
try {
    foreach ($name in @('msedge.exe', 'chrome.exe', 'firefox.exe', 'brave.exe')) {
        [IO.File]::WriteAllText((Join-Path $browserRoot $name), '', [Text.Encoding]::ASCII)
    }

    $harness = @'
param(
    [Parameter(Mandatory = $true)][string]$OpenScript,
    [Parameter(Mandatory = $true)][string]$LaunchRoot,
    [Parameter(Mandatory = $true)][string]$EventsPath,
    [Parameter(Mandatory = $true)][string]$StartupToken,
    [Parameter(Mandatory = $true)][string]$State,
    [Parameter(Mandatory = $true)][string]$Url,
    [Parameter(Mandatory = $true)][string]$Browser
)

$env:DSH_TEST_MODE = '1'
$env:DSH_TEST_OPEN_HOOK = '1'
$env:DSH_TEST_OPEN_STATE = $State
$env:DSH_TEST_OPEN_URL = $Url
$env:DSH_TEST_OPEN_EVENTS = $EventsPath

function global:Get-DshServiceClassification {
    param([int]$Port, [string]$ExpectedEntrypoint, [string]$ExpectedStartupToken, [int]$RunnerPid, [string]$LaunchRoot)
    return [pscustomobject]@{
        State = 'READY'
        ServicePid = 4321
        Message = 'fixture result'
        HttpStatus = 200
        Entrypoint = $ExpectedEntrypoint
    }
}

function global:Get-DshStartupUrl {
    param([string]$LaunchRoot, [int]$Port, [string]$ExpectedStartupToken, [int]$ExpectedOwnerPid)
    return $env:DSH_TEST_OPEN_URL
}

function global:Start-Process {
    param(
        [string]$FilePath,
        [object[]]$ArgumentList,
        [string]$WorkingDirectory,
        [object]$ErrorAction
    )
    $arguments = if ($ArgumentList) { $ArgumentList -join ' ' } else { '' }
    [IO.File]::WriteAllText(
        $env:DSH_TEST_OPEN_EVENTS,
        "$FilePath|$arguments",
        [Text.Encoding]::UTF8
    )
}

& $OpenScript -LaunchRoot $LaunchRoot -Browser $Browser -Port 3080
exit $LASTEXITCODE
'@
    [IO.File]::WriteAllText($harnessPath, $harness, [Text.UTF8Encoding]::new($false))

    $browserRootVariable = $env:DSH_TEST_BROWSER_ROOT
    $env:DSH_TEST_BROWSER_ROOT = $browserRoot
    try {
        Invoke-Test 'opens the authenticated URL with the selected browser' {
            $result = Invoke-OpenScenario -Browser 'edge'
            Assert-Equal 0 $result.ExitCode "Edge open should succeed. Output:`n$($result.Output)"
            Assert-Match $result.Events ([regex]::Escape((Join-Path $browserRoot 'msedge.exe'))) `
                'The edge alias must resolve to msedge.exe'
            Assert-Match $result.Events 'http://127\.0\.0\.1:3080/\?token=test-token' `
                'The selected browser must receive the authenticated URL'
            Assert-NotMatch $result.Output 'test-token' 'The token must not be printed by the open command'
        }

        Invoke-Test 'all supported browser aliases resolve to their known executable' {
            $expectedExecutables = @{
                edge = 'msedge.exe'
                chrome = 'chrome.exe'
                firefox = 'firefox.exe'
                brave = 'brave.exe'
            }
            foreach ($alias in $expectedExecutables.Keys) {
                $result = Invoke-OpenScenario -Browser $alias
                Assert-Equal 0 $result.ExitCode "The $alias browser alias should succeed"
                Assert-Match $result.Events ([regex]::Escape((Join-Path $browserRoot $expectedExecutables[$alias]))) `
                    "The $alias alias must resolve to its known executable"
            }
        }

        Invoke-Test 'the default browser alias receives the authenticated URL directly' {
            $result = Invoke-OpenScenario -Browser 'default'
            Assert-Equal 0 $result.ExitCode 'The default browser alias should succeed'
            Assert-Match $result.Events '^http://127\.0\.0\.1:3080/\?token=test-token\|$' `
                'The default browser must receive the authenticated URL as the shell target'
        }

        Invoke-Test 'a missing selected browser fails without launching anything' {
            Remove-Item -LiteralPath (Join-Path $browserRoot 'msedge.exe') -Force
            $result = Invoke-OpenScenario -Browser 'edge'
            Assert-Equal 1 $result.ExitCode 'A missing browser must fail the open command'
            Assert-Equal '' $result.Events 'A missing browser must not be launched'
            Assert-Match $result.Output 'not found|not installed|test browser directory' `
                'The missing browser error must identify the resolution failure'
        }

        Invoke-Test 'does not open a browser while the service is still starting' {
        $result = Invoke-OpenScenario -Browser 'chrome' -State 'STARTING'
        Assert-Equal 1 $result.ExitCode 'An incomplete startup must fail the open command'
        Assert-Equal '' $result.Events 'An incomplete startup must not launch a browser'
    }

    Invoke-Test 'foreground and background coordinators clean only their own access record' {
        foreach ($scriptName in @('start-foreground.ps1', 'background-run.ps1')) {
            $source = Get-Content -LiteralPath (Join-Path $repoRoot $scriptName) -Raw
            Assert-Match $source 'Remove-DshWebAccessRecord' "$scriptName must clean the Web access record"
            Assert-Match $source 'ExpectedStartupToken' "$scriptName must bind cleanup to its startup token"
        }
    }
    } finally {
        $env:DSH_TEST_BROWSER_ROOT = $browserRootVariable
    }

    Write-Host "All $script:Passed open DSH behavior tests passed."
} finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}

exit 0
