param(
    [ValidateSet('default', 'edge', 'chrome', 'firefox', 'brave')]
    [string]$Browser = 'default',

    [string]$LaunchRoot = (Join-Path $env:USERPROFILE 'dsh-launch'),

    [ValidateRange(1, 65535)]
    [int]$Port = 3080
)

$ErrorActionPreference = 'Stop'
if ($Port -ne 3080 -and $env:DSH_TEST_MODE -ne '1') {
    Write-Error '[ERROR] Production lifecycle commands only support port 3080.'
    exit 1
}

$useTestHooks = $env:DSH_TEST_MODE -eq '1' -and $env:DSH_TEST_OPEN_HOOK -eq '1'
if (-not $useTestHooks -and
    -not (Get-Command 'Get-DshServiceClassification' -CommandType Function -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'dsh-service-health.ps1')
}

function Get-DshOpenStartupState {
    param([Parameter(Mandatory = $true)][string]$Root)

    $statePath = Join-Path $Root 'dsh-startup.json'
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
        return $null
    }
    try {
        $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($state.State -eq 'RUNNING') { $state.State = 'READY' }
        return $state
    } catch {
        return $null
    }
}

function Get-DshBrowserExecutable {
    param([Parameter(Mandatory = $true)][string]$Alias)

    if ($Alias -eq 'default') { return '' }
    $specs = @{
        edge    = [pscustomobject]@{ Name = 'Microsoft Edge'; Executable = 'msedge.exe'; RelativePath = 'Microsoft\Edge\Application\msedge.exe' }
        chrome  = [pscustomobject]@{ Name = 'Google Chrome'; Executable = 'chrome.exe'; RelativePath = 'Google\Chrome\Application\chrome.exe' }
        firefox = [pscustomobject]@{ Name = 'Mozilla Firefox'; Executable = 'firefox.exe'; RelativePath = 'Mozilla Firefox\firefox.exe' }
        brave   = [pscustomobject]@{ Name = 'Brave'; Executable = 'brave.exe'; RelativePath = 'BraveSoftware\Brave-Browser\Application\brave.exe' }
    }
    $spec = $specs[$Alias]
    if (-not $spec) { throw "Unsupported browser alias: $Alias" }

    if ($env:DSH_TEST_MODE -eq '1' -and $env:DSH_TEST_BROWSER_ROOT) {
        $testPath = Join-Path $env:DSH_TEST_BROWSER_ROOT $spec.Executable
        if (Test-Path -LiteralPath $testPath -PathType Leaf) { return [IO.Path]::GetFullPath($testPath) }
        throw "$($spec.Name) was not found in the test browser directory"
    }

    $registryPaths = @(
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\App Paths\$($spec.Executable)",
        "HKLM:\Software\Microsoft\Windows\CurrentVersion\App Paths\$($spec.Executable)",
        "HKCU:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\$($spec.Executable)",
        "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\$($spec.Executable)"
    )
    foreach ($registryPath in $registryPaths) {
        try {
            $registeredPath = (Get-Item -LiteralPath $registryPath -ErrorAction Stop).GetValue('')
            if ($registeredPath) {
                $registeredPath = ([string]$registeredPath).Trim().Trim('"')
                if ([IO.Path]::GetFileName($registeredPath) -ieq $spec.Executable -and
                    (Test-Path -LiteralPath $registeredPath -PathType Leaf)) {
                    return [IO.Path]::GetFullPath($registeredPath)
                }
            }
        } catch { }
    }

    $candidatePaths = @()
    foreach ($root in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA)) {
        if ($root) { $candidatePaths += Join-Path $root $spec.RelativePath }
    }
    if ($Alias -eq 'firefox' -and $env:LOCALAPPDATA) {
        $candidatePaths += Join-Path $env:LOCALAPPDATA 'Programs\Mozilla Firefox\firefox.exe'
    }
    foreach ($candidatePath in $candidatePaths) {
        if (Test-Path -LiteralPath $candidatePath -PathType Leaf) {
            return [IO.Path]::GetFullPath($candidatePath)
        }
    }
    throw "$($spec.Name) is not installed or could not be located"
}

try {
    $state = Get-DshOpenStartupState -Root $LaunchRoot
    if (-not $state) { throw 'No DeepSeek Harness startup state is available' }
    if ($state.State -eq 'STARTING') { throw 'DeepSeek Harness is still starting; retry after it becomes READY' }
    if ($state.State -ne 'READY') { throw "DeepSeek Harness is not ready (state: $($state.State))" }

    $runnerPid = if ($state.RunnerPid) { [int]$state.RunnerPid } elseif ($state.Pid) { [int]$state.Pid } else { 0 }
    $entrypoint = [string]$state.Entrypoint
    $startupToken = [string]$state.StartupToken
    if ($runnerPid -le 0 -or [string]::IsNullOrWhiteSpace($entrypoint) -or
        [string]::IsNullOrWhiteSpace($startupToken)) {
        throw 'DeepSeek Harness startup identity is incomplete'
    }

    $classification = Get-DshServiceClassification -Port $Port -ExpectedEntrypoint $entrypoint `
        -ExpectedStartupToken $startupToken -RunnerPid $runnerPid -LaunchRoot $LaunchRoot
    if ($classification.State -ne 'READY') {
        throw "DeepSeek Harness is not ready ($($classification.State)): $($classification.Message)"
    }

    $url = Get-DshStartupUrl -LaunchRoot $LaunchRoot -Port $Port `
        -ExpectedStartupToken $startupToken -ExpectedOwnerPid $runnerPid
    if ([string]::IsNullOrWhiteSpace($url)) {
        throw 'No authenticated DSH Web URL is available; restart DeepSeek Harness with the current launcher'
    }

    $browserPath = Get-DshBrowserExecutable -Alias $Browser
    if ($Browser -eq 'default') {
        Start-Process -FilePath $url -ErrorAction Stop
        Write-Output 'Opened DeepSeek Harness in the default browser.'
    } else {
        Start-Process -FilePath $browserPath -ArgumentList @($url) -ErrorAction Stop
        Write-Output "Opened DeepSeek Harness in $Browser."
    }
    exit 0
} catch {
    Write-Error ('[ERROR] ' + $_.Exception.Message)
    exit 1
}
