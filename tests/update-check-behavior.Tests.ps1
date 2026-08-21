$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$updateScript = Join-Path $repoRoot 'update-check.ps1'
$testRoot = Join-Path $env:TEMP ('dsh-update-tests-' + [guid]::NewGuid().ToString('N'))
$profileRoot = Join-Path $testRoot 'profile'
$fakeBin = Join-Path $testRoot 'fake-bin'
$runtimePackage = Join-Path $profileRoot 'dsh-launch\runtime\node_modules\@deepseek-ai\dsh\package.json'
$script:Passed = 0

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    if ($Expected -ne $Actual) { throw "$Message (expected: $Expected, actual: $Actual)" }
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

New-Item -ItemType Directory -Force -Path (Split-Path $runtimePackage -Parent), $fakeBin | Out-Null
try {
    [IO.File]::WriteAllText(
        $runtimePackage,
        '{"name":"@deepseek-ai/dsh","version":"0.1.0-rc.8"}',
        [Text.Encoding]::ASCII
    )
    [IO.File]::WriteAllText(
        (Join-Path $fakeBin 'npm.cmd'),
        "@echo off`r`necho {`"latest`":`"0.1.0-rc.8`"}`r`nexit /b 0`r`n",
        [Text.Encoding]::ASCII
    )

    Invoke-Test 'update check reports the managed runtime version' {
        $startInfo = [Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = 'powershell.exe'
        $startInfo.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$updateScript`""
        $startInfo.UseShellExecute = $false
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $startInfo.EnvironmentVariables['PATH'] = "$fakeBin;$env:PATH"
        $startInfo.EnvironmentVariables['USERPROFILE'] = $profileRoot
        $startInfo.EnvironmentVariables['LOCALAPPDATA'] = (Join-Path $testRoot 'local-app-data')
        $startInfo.EnvironmentVariables['APPDATA'] = (Join-Path $testRoot 'app-data')

        $process = [Diagnostics.Process]::Start($startInfo)
        if (-not $process.WaitForExit(10000)) {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
            throw 'update-check.ps1 did not finish promptly'
        }
        $output = $process.StandardOutput.ReadToEnd() + $process.StandardError.ReadToEnd()
        Assert-Equal 0 $process.ExitCode "Update check should succeed. Output:`n$output"
        $versionMentions = [regex]::Matches($output, '0\.1\.0-rc\.8').Count
        Assert-Equal 2 $versionMentions 'Managed runtime rc.8 should be reported once as local and once as latest'
    }

    Write-Host "All $script:Passed update check behavior tests passed."
} finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}

exit 0
