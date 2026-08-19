$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$startScript = Join-Path $repoRoot 'start-background.ps1'
$startCommand = Join-Path $repoRoot 'start-background.cmd'
$harness = Join-Path $PSScriptRoot 'start-background-harness.ps1'
$testRoot = Join-Path $env:TEMP ('dsh-launcher-tests-' + [guid]::NewGuid().ToString('N'))
$script:Passed = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    if ($Expected -ne $Actual) {
        throw "$Message (expected: $Expected, actual: $Actual)"
    }
}

function Assert-Match {
    param([string]$Actual, [string]$Pattern, [string]$Message)
    if ($Actual -notmatch $Pattern) {
        throw "$Message`nActual output:`n$Actual"
    }
}

function Assert-NotMatch {
    param([string]$Actual, [string]$Pattern, [string]$Message)
    if ($Actual -match $Pattern) {
        throw "$Message`nActual output:`n$Actual"
    }
}

function Invoke-Test {
    param([string]$Name, [scriptblock]$Body)
    & $Body
    $script:Passed++
    Write-Host "PASS: $Name"
}

function Invoke-StartScenario {
    param([ValidateSet('Immediate', 'Ready', 'Failed')][string]$Scenario)

    $scenarioRoot = Join-Path $testRoot $Scenario
    $profilePath = Join-Path $scenarioRoot 'profile'
    $processLogPath = Join-Path $scenarioRoot 'processes.log'
    New-Item -ItemType Directory -Force -Path $profilePath | Out-Null
    [IO.File]::WriteAllText($processLogPath, '', [Text.Encoding]::UTF8)

    $timer = [Diagnostics.Stopwatch]::StartNew()
    $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $harness `
        -Scenario $Scenario `
        -ScriptPath $startScript `
        -ProfilePath $profilePath `
        -ProcessLogPath $processLogPath 2>&1
    $exitCode = $LASTEXITCODE
    $timer.Stop()

    return [pscustomobject]@{
        ExitCode   = $exitCode
        Elapsed    = $timer.Elapsed
        Output     = [string]($output -join [Environment]::NewLine)
        ProcessLog = [IO.File]::ReadAllText($processLogPath)
        LogPath    = Join-Path $profilePath 'dsh-launch\dsh-background.log'
    }
}

function Get-FakePowerShellBin {
    $fakeBin = Join-Path $testRoot 'fake-bin'
    New-Item -ItemType Directory -Force -Path $fakeBin | Out-Null
    $fakePowerShell = Join-Path $fakeBin 'powershell.exe'
    if (-not (Test-Path -LiteralPath $fakePowerShell)) {
        $fakeSource = @'
using System;

public static class FakePowerShell
{
public static int Main(string[] args)
{
    var output = "POWERSHELL_ARGS:" + string.Join(" ", args);
    var processLog = Environment.GetEnvironmentVariable("DSH_TEST_PROCESS_LOG");
    if (!string.IsNullOrEmpty(processLog))
    {
        System.IO.File.AppendAllText(processLog, output + Environment.NewLine);
    }
    Console.WriteLine(output);
        int exitCode;
        return int.TryParse(Environment.GetEnvironmentVariable("DSH_TEST_POWERSHELL_EXIT"), out exitCode)
            ? exitCode
            : 0;
    }
}
'@
        $fakeSourcePath = Join-Path $fakeBin 'FakePowerShell.cs'
        [IO.File]::WriteAllText($fakeSourcePath, $fakeSource, [Text.UTF8Encoding]::new($false))
        $compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
        if (-not (Test-Path -LiteralPath $compiler)) {
            $compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe'
        }
        Assert-True (Test-Path -LiteralPath $compiler) 'The .NET Framework C# compiler is required for the CMD behavior test'
        & $compiler /nologo /target:exe "/out:$fakePowerShell" $fakeSourcePath
        Assert-Equal 0 $LASTEXITCODE 'Failed to build the test powershell.exe replacement'
    }

    $fakeNpx = Join-Path $fakeBin 'npx.cmd'
    if (-not (Test-Path -LiteralPath $fakeNpx)) {
        [IO.File]::WriteAllText(
            $fakeNpx,
            "@echo off`r`necho NPX_ARGS:%*`r`nexit /b 0`r`n",
            [Text.Encoding]::ASCII
        )
    }

    return $fakeBin
}

function Invoke-BackgroundRunner {
    $fakeBin = Get-FakePowerShellBin
    $profilePath = Join-Path $testRoot 'background-runner-profile'
    $logPath = Join-Path $profilePath 'dsh-launch\dsh-background.log'
    $monitorLogPath = Join-Path $profilePath 'monitor-processes.log'
    New-Item -ItemType Directory -Force -Path $profilePath | Out-Null

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = 'cmd.exe'
    $startInfo.Arguments = '/d /c background-run.cmd'
    $startInfo.WorkingDirectory = $repoRoot
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.EnvironmentVariables['PATH'] = "$fakeBin;$env:PATH"
    $startInfo.EnvironmentVariables['USERPROFILE'] = $profilePath
    $startInfo.EnvironmentVariables['DSH_TEST_POWERSHELL_EXIT'] = '0'
    $startInfo.EnvironmentVariables['DSH_TEST_PROCESS_LOG'] = $monitorLogPath

    $process = [Diagnostics.Process]::Start($startInfo)
    Assert-True ($process.WaitForExit(3000)) 'background-run.cmd did not exit after the fake DSH command completed'

    $monitorLog = ''
    for ($i = 0; $i -lt 30; $i++) {
        try {
            if (Test-Path -LiteralPath $monitorLogPath) {
                $monitorLog = [IO.File]::ReadAllText($monitorLogPath)
                if ($monitorLog -match 'POWERSHELL_ARGS:') { break }
            }
        } catch [IO.IOException] { }
        Start-Sleep -Milliseconds 100
    }

    return [pscustomobject]@{
        ExitCode = $process.ExitCode
        Log      = if (Test-Path -LiteralPath $logPath) { [IO.File]::ReadAllText($logPath) } else { '' }
        MonitorLog = $monitorLog
        Output   = $process.StandardOutput.ReadToEnd() + $process.StandardError.ReadToEnd()
    }
}

function Invoke-BackgroundCommand {
    param([int]$PowerShellExitCode)

    $fakeBin = Get-FakePowerShellBin

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = 'cmd.exe'
    $startInfo.Arguments = '/d /c start-background.cmd'
    $startInfo.WorkingDirectory = $repoRoot
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.EnvironmentVariables['PATH'] = "$fakeBin;$env:PATH"
    $startInfo.EnvironmentVariables['DSH_TEST_POWERSHELL_EXIT'] = [string]$PowerShellExitCode

    $process = [Diagnostics.Process]::Start($startInfo)
    $exitedBeforeInput = $process.WaitForExit(3000)
    if (-not $exitedBeforeInput) {
        $process.StandardInput.WriteLine('x')
        $process.StandardInput.Close()
        Assert-True ($process.WaitForExit(3000)) 'start-background.cmd did not exit after test input'
    }

    return [pscustomobject]@{
        ExitCode          = $process.ExitCode
        ExitedBeforeInput = $exitedBeforeInput
        Output            = $process.StandardOutput.ReadToEnd() + $process.StandardError.ReadToEnd()
    }
}

function Invoke-DeepseekCommand {
    param([string]$Argument = '-b')
    $fakeBin = Get-FakePowerShellBin
    $profilePath = Join-Path $testRoot 'deepseek-profile'
    New-Item -ItemType Directory -Force -Path $profilePath | Out-Null

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = 'cmd.exe'
    $startInfo.Arguments = '/d /c deepseek.cmd ' + $Argument
    $startInfo.WorkingDirectory = $repoRoot
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.EnvironmentVariables['PATH'] = "$fakeBin;$env:PATH"
    $startInfo.EnvironmentVariables['USERPROFILE'] = $profilePath
    $startInfo.EnvironmentVariables['DSH_TEST_POWERSHELL_EXIT'] = '0'

    $process = [Diagnostics.Process]::Start($startInfo)
    Assert-True ($process.WaitForExit(3000)) "deepseek $Argument did not return promptly"
    return [pscustomobject]@{
        ExitCode = $process.ExitCode
        Output   = $process.StandardOutput.ReadToEnd() + $process.StandardError.ReadToEnd()
    }
}

New-Item -ItemType Directory -Force -Path $testRoot | Out-Null
try {
    Invoke-Test 'background CLI mode returns immediately with submitted status' {
        $result = Invoke-StartScenario -Scenario Immediate
        Assert-Equal 0 $result.ExitCode 'Immediate mode should exit successfully'
        Assert-True ($result.Elapsed.TotalSeconds -lt 3) 'Immediate mode should not wait for readiness'
        Assert-Match $result.Output 'deepseek --logs' 'Immediate mode should expose the log command'
        Assert-Match $result.ProcessLog 'background-run\.cmd' 'Immediate mode should launch the long-lived background runner'
    }

    Invoke-Test 'deepseek -b no longer tells the user to close a waiting window' {
        $result = Invoke-DeepseekCommand
        Assert-Equal 0 $result.ExitCode 'deepseek -b should preserve a successful launch exit code'
        Assert-NotMatch $result.Output 'Close this window anytime' 'deepseek -b should not print the stale waiting-window message'
        Assert-Match $result.Output 'start-background\.ps1.*-TimeoutSeconds 900' 'deepseek -b should submit startup with the approved monitor timeout'
    }

    Invoke-Test 'background runner starts the readiness monitor for DSH' {
        $result = Invoke-BackgroundRunner
        Assert-True ($result.ExitCode -eq 0) "background runner should preserve the fake DSH exit code (actual: $($result.ExitCode))`nLog:`n$($result.Log)`nOutput:`n$($result.Output)"
        Assert-Match $result.MonitorLog 'POWERSHELL_ARGS:.*open-when-ready\.ps1.*-TimeoutSeconds 900' 'the long-lived background runner should start the browser readiness monitor'
        Assert-Match $result.Log 'NPX_ARGS:--yes @deepseek-ai/dsh web' 'background runner should still start DeepSeek Harness'
    }

    Invoke-Test 'deepseek CMD entrypoint is safe across Windows code pages' {
        $bytes = [IO.File]::ReadAllBytes((Join-Path $repoRoot 'deepseek.cmd'))
        $nonAscii = $bytes | Where-Object { $_ -gt 0x7F } | Select-Object -First 1
        Assert-True ($null -eq $nonAscii) 'deepseek.cmd must contain only ASCII bytes so CMD does not misinterpret UTF-8 comments under CP936'
    }

    Invoke-Test 'unknown arguments are rejected with an error, never silently launched' {
        $result = Invoke-DeepseekCommand -Argument '--totally-unknown-flag'
        Assert-Equal 1 $result.ExitCode 'unknown argument should exit with code 1'
        Assert-Match $result.Output 'Unknown argument' 'should name the bad token'
        Assert-Match $result.Output 'Usage:' 'should print the help block'
        Assert-NotMatch $result.Output 'start-background\.ps1' 'must not dispatch to background start'
        Assert-NotMatch $result.Output 'Starting DeepSeek Harness' 'must not fall through to foreground launch'
    }

    Invoke-Test 'bare --full is rejected (only valid together with --uninstall)' {
        $result = Invoke-DeepseekCommand -Argument '--full'
        Assert-Equal 1 $result.ExitCode 'bare --full should exit with code 1'
        Assert-Match $result.Output '--uninstall' 'error should point at the correct usage'
        Assert-NotMatch $result.Output 'uninstall\.ps1' 'must not dispatch to the uninstaller'
    }

    Invoke-Test '--full with --uninstall still dispatches to the uninstaller' {
        $result = Invoke-DeepseekCommand -Argument '--uninstall --full'
        Assert-Equal 0 $result.ExitCode '--uninstall --full should dispatch normally'
        Assert-Match $result.Output 'uninstall\.ps1' 'should invoke the full uninstaller'
    }

    Invoke-Test 'shortcut wait mode opens the browser before returning success' {
        $result = Invoke-StartScenario -Scenario Ready
        Assert-Equal 0 $result.ExitCode 'Wait mode should exit successfully after HTTP readiness'
        Assert-Match $result.Output 'http://127\.0\.0\.1:3080' 'Wait mode should report the ready URL'
        Assert-Match $result.ProcessLog '(?m)^http://127\.0\.0\.1:3080\s*$' 'Wait mode should issue the browser launch itself'
        Assert-NotMatch $result.ProcessLog 'open-when-ready\.ps1' 'Wait mode should not launch a duplicate browser monitor'
    }

    Invoke-Test 'wait mode reports log details when the service exits early' {
        $result = Invoke-StartScenario -Scenario Failed
        Assert-Equal 1 $result.ExitCode 'Wait mode should fail when the background process exits'
        Assert-Match $result.Output ([regex]::Escape($result.LogPath)) 'Wait mode should print the full log path'
        Assert-Match $result.Output 'simulated launch failure' 'Wait mode should print the latest log detail'
    }

    Invoke-Test 'shortcut command closes automatically after successful startup' {
        $result = Invoke-BackgroundCommand -PowerShellExitCode 0
        Assert-True $result.ExitedBeforeInput 'Successful shortcut launch should close without keyboard input'
        Assert-Equal 0 $result.ExitCode 'Successful shortcut launch should preserve exit code 0'
        Assert-Match $result.Output '-WaitForReady' 'Shortcut should call the synchronous readiness mode'
        Assert-Match $result.Output '-TimeoutSeconds 900' 'Shortcut should use the approved 15-minute timeout'
    }

    Invoke-Test 'shortcut command stays open after failed startup' {
        $result = Invoke-BackgroundCommand -PowerShellExitCode 1
        Assert-True (-not $result.ExitedBeforeInput) 'Failed shortcut launch should wait for keyboard input'
        Assert-Equal 1 $result.ExitCode 'Failed shortcut launch should preserve the failure exit code'
        Assert-Match $result.Output '-WaitForReady' 'Failed shortcut launch should use the synchronous readiness mode'
    }

    Write-Host "All $script:Passed startup behavior tests passed."
} finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}

exit 0
