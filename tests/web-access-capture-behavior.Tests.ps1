$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$runtimeScript = Join-Path $repoRoot 'run-dsh.ps1'
$testRoot = Join-Path $env:TEMP ('dsh-web-access-capture-tests-' + [guid]::NewGuid().ToString('N'))
$profileRoot = Join-Path $testRoot 'profile'
$launchRoot = Join-Path $profileRoot 'dsh-launch'
$runtimeRoot = Join-Path $launchRoot 'runtime'
$fakeBin = Join-Path $testRoot 'fake-bin'
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

function Invoke-Test {
    param([string]$Name, [scriptblock]$Body)
    & $Body
    $script:Passed++
    Write-Host "PASS: $Name"
}

New-Item -ItemType Directory -Force -Path $fakeBin, (Join-Path $runtimeRoot 'node_modules\@deepseek-ai\dsh\lib') | Out-Null
[IO.File]::WriteAllText(
    (Join-Path $runtimeRoot 'node_modules\@deepseek-ai\dsh\lib\bin.js'),
    ('x' * 2048),
    [Text.Encoding]::ASCII
)
[IO.File]::WriteAllText(
    (Join-Path $runtimeRoot 'node_modules\@deepseek-ai\dsh\package.json'),
    (@{ name = '@deepseek-ai/dsh'; version = '0.1.2-rc.1' } | ConvertTo-Json),
    [Text.UTF8Encoding]::new($false)
)
[IO.File]::WriteAllText(
    (Join-Path $runtimeRoot 'dsh-runtime-ready.json'),
    (@{ SchemaVersion = 2; Version = '0.1.2-rc.1'; ValidatedBy = 'npm-ls-all' } | ConvertTo-Json),
    [Text.UTF8Encoding]::new($false)
)
[IO.File]::WriteAllText(
    (Join-Path $fakeBin 'node.cmd'),
    "@echo off`r`nif `"%1`"==`"--version`" (`r`n  echo v22.19.0`r`n  exit /b 0`r`n)`r`necho dsh web: http://127.0.0.1:3080/?token=test-token`r`necho benign stderr 1>&2`r`nexit /b 0`r`n",
    [Text.Encoding]::ASCII
)
[IO.File]::WriteAllText(
    (Join-Path $fakeBin 'npm.cmd'),
    "@echo off`r`nif `"%1`"==`"ls`" echo {`"name`":`"runtime`",`"problems`":[]}`r`nexit /b 0`r`n",
    [Text.Encoding]::ASCII
)

$startupToken = '11111111111111111111111111111111'
$process = $null
try {
    Invoke-Test 'run-dsh captures the upstream URL while preserving output' {
        $startInfo = [Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = 'powershell.exe'
        $startInfo.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $runtimeScript +
            '" -Version 0.1.2-rc.1 -RuntimeRoot "' + $runtimeRoot +
            '" -LaunchRoot "' + $launchRoot + '" -StartupToken ' + $startupToken +
            ' -OwnerPid ' + $PID + ' -Port 3080 -DshArguments web'
        $startInfo.WorkingDirectory = $repoRoot
        $startInfo.UseShellExecute = $false
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $startInfo.EnvironmentVariables['PATH'] = "$fakeBin;$env:PATH"
        $startInfo.EnvironmentVariables['USERPROFILE'] = $profileRoot
        $process = [Diagnostics.Process]::Start($startInfo)

        Assert-True $process.WaitForExit(15000) 'The runtime process did not exit'

        $recordPath = Join-Path $launchRoot 'dsh-web-access.json'
        Assert-True (Test-Path -LiteralPath $recordPath -PathType Leaf) `
            'The shared runtime launcher must persist the URL after capture'
        $record = Get-Content -LiteralPath $recordPath -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert-Equal $startupToken $record.StartupToken 'The captured URL must bind to the launcher startup token'
        Assert-Equal $PID ([int]$record.OwnerPid) 'The captured URL must bind to the launcher owner PID'
        Assert-Equal 'http://127.0.0.1:3080/?token=test-token' $record.AuthenticatedUrl `
            'The captured URL must preserve the upstream token URL'

        Assert-True $process.WaitForExit(15000) 'The runtime process did not exit after the Node fixture was released'
        Assert-Equal 0 $process.ExitCode 'The runtime process should preserve the Node exit code'
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        Assert-Match $stdout 'dsh web: http://127\.0\.0\.1:3080/\?token=test-token' `
            'The URL line must remain visible to the caller'
        Assert-Match $stderr 'benign stderr' 'Normal Node stderr must remain visible'
    }

    Write-Host "All $script:Passed web access capture behavior tests passed."
} finally {
    if ($process -and -not $process.HasExited) {
        if (-not $process.WaitForExit(3000)) {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        }
    }
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}

exit 0
