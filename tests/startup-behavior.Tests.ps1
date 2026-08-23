param([string]$TestFilter = $env:DSH_TEST_FILTER)

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
    if ($TestFilter -and $Name -notmatch $TestFilter) { return }
    & $Body
    $script:Passed++
    Write-Host "PASS: $Name"
}

function Remove-TestRoot {
    param([string]$Path)

    for ($attempt = 0; $attempt -lt 30 -and (Test-Path -LiteralPath $Path); $attempt++) {
        try {
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
        } catch [IO.IOException] {
            Start-Sleep -Milliseconds 100
        }
    }
    if (Test-Path -LiteralPath $Path) {
        throw "Test cleanup could not remove $Path"
    }
}

function Read-TestLog {
    param([string]$Path)

    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        try {
            if (Test-Path -LiteralPath $Path) {
                return [IO.File]::ReadAllText($Path)
            }
            return ''
        } catch [IO.IOException] {
            Start-Sleep -Milliseconds 100
        }
    }
    throw "Test log remained locked: $Path"
}

# The behavior test files are UTF-8 without BOM (Windows PowerShell 5.1 baseline).
# Chinese phase text is therefore built from UTF-16 code units at runtime instead
# of being written as literals, keeping the test files parseable by PS 5.1.
function Get-PhaseText {
    param([int[]]$CodeUnits)
    return (-join @($CodeUnits | ForEach-Object { [char]$_ }))
}

$script:PhasePrefix = Get-PhaseText @(0x542F, 0x52A8, 0x9636, 0x6BB5, 0xFF1A)                       # 启动阶段：
$script:HeartbeatPrefix = Get-PhaseText @(0x542F, 0x52A8, 0x4ECD, 0x5728, 0x8FDB, 0x884C, 0xFF1A)  # 启动仍在进行：
$script:OldCounterText = Get-PhaseText @(0x4ECD, 0x5728, 0x542F, 0x52A8, 0xFF0C, 0x5DF2, 0x7B49, 0x5F85)  # 仍在启动，已等待
$script:ElapsedPrefix = Get-PhaseText @(0xFF0C, 0x5DF2, 0x7B49, 0x5F85)                             # ，已等待
$script:SecondsEllipsis = Get-PhaseText @(0x79D2, 0x2E, 0x2E, 0x2E)                                  # 秒...
$script:PhaseDownload = Get-PhaseText @(0x6B63, 0x5728, 0x4E0B, 0x8F7D, 0x20, 0x44, 0x65, 0x65, 0x70, 0x53, 0x65, 0x65, 0x6B, 0x20, 0x48, 0x61, 0x72, 0x6E, 0x65, 0x73, 0x73, 0x20, 0x8FD0, 0x884C, 0x65F6, 0xFF0C, 0x9996, 0x6B21, 0x4E0B, 0x8F7D, 0x53EF, 0x80FD, 0x9700, 0x8981, 0x51E0, 0x5206, 0x949F, 0x2E, 0x2E, 0x2E)
$script:PhasePeers = Get-PhaseText @(0x6B63, 0x5728, 0x5B89, 0x88C5, 0x20, 0x44, 0x53, 0x48, 0x20, 0x70, 0x65, 0x65, 0x72, 0x20, 0x4F9D, 0x8D56, 0xFF08, 0x32, 0x31, 0x20, 0x4E2A, 0xFF09, 0x2E, 0x2E, 0x2E)
$script:PhaseValidate = Get-PhaseText @(0x6B63, 0x5728, 0x6821, 0x9A8C, 0x8FD0, 0x884C, 0x65F6, 0x4F9D, 0x8D56, 0x2E, 0x2E, 0x2E)
$script:PhaseWeb = Get-PhaseText @(0x6B63, 0x5728, 0x542F, 0x52A8, 0x20, 0x57, 0x65, 0x62, 0x20, 0x670D, 0x52A1, 0x2E, 0x2E, 0x2E)

function Invoke-StartScenario {
    param(
        [ValidateSet('Immediate', 'Ready', 'Failed', 'Duplicate', 'DuplicateReady', 'DuplicateFailed', 'OccupiedDuplicate', 'Staged')]
        [string]$Scenario,
        [string]$ScenarioName = $Scenario,
        [ValidateRange(1, 65535)]
        [int]$Port = 3080,
        [ValidateRange(1, 3600)]
        [int]$HeartbeatSeconds = 30
    )

    $scenarioRoot = Join-Path $testRoot $ScenarioName
    $profilePath = Join-Path $scenarioRoot 'profile'
    $processLogPath = Join-Path $scenarioRoot 'processes.log'
    New-Item -ItemType Directory -Force -Path $profilePath | Out-Null
    [IO.File]::WriteAllText($processLogPath, '', [Text.Encoding]::UTF8)

    $timer = [Diagnostics.Stopwatch]::StartNew()
    $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $harness `
        -Scenario $Scenario `
        -ScriptPath $startScript `
        -ProfilePath $profilePath `
        -ProcessLogPath $processLogPath `
        -Port $Port `
        -HeartbeatSeconds $HeartbeatSeconds 2>&1
    $exitCode = $LASTEXITCODE
    $timer.Stop()

    return [pscustomobject]@{
        ExitCode   = $exitCode
        Elapsed    = $timer.Elapsed
        Output     = [string]($output -join [Environment]::NewLine)
        ProcessLog = [IO.File]::ReadAllText($processLogPath)
        LogPath    = Join-Path $profilePath 'dsh-launch\dsh-background.log'
        FailureOutputPath = Join-Path $profilePath 'dsh-launch\failure-output.txt'
        StagedOutputPath = Join-Path $profilePath 'dsh-launch\staged-output.txt'
        StatePath  = Join-Path $profilePath 'dsh-launch\dsh-startup.json'
        LockPath   = Join-Path $profilePath 'dsh-launch\dsh-startup.lock'
        LockTokenPath = Join-Path $profilePath 'dsh-launch\dsh-startup.lock\token.txt'
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
    var argumentsText = string.Join(" ", args);
    var output = "POWERSHELL_ARGS:" + argumentsText;
    var processLog = Environment.GetEnvironmentVariable("DSH_TEST_PROCESS_LOG");
    if (!string.IsNullOrEmpty(processLog))
    {
        System.IO.File.AppendAllText(processLog, output + Environment.NewLine);
    }
    if (argumentsText.Contains("resolve-dsh-version.ps1"))
    {
        Console.WriteLine("0.1.0-rc.8");
    }
    else if (argumentsText.Contains("Get-CimInstance Win32_Process"))
    {
        Console.WriteLine("4242");
    }
    else
    {
        Console.WriteLine(output);
    }
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
    param([switch]$SuppressBrowserMonitor)

    $fakeBin = Get-FakePowerShellBin
    $scenarioName = if ($SuppressBrowserMonitor) { 'background-runner-suppressed' } else { 'background-runner-default' }
    $profilePath = Join-Path $testRoot $scenarioName
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
    if ($SuppressBrowserMonitor) {
        $startInfo.EnvironmentVariables['DSH_SUPPRESS_BROWSER_MONITOR'] = '1'
    }

    $process = [Diagnostics.Process]::Start($startInfo)
    Assert-True ($process.WaitForExit(3000)) 'background-run.cmd did not exit after the fake DSH command completed'

    $monitorLog = ''
    for ($i = 0; $i -lt 30; $i++) {
        try {
            if (Test-Path -LiteralPath $monitorLogPath) {
                $monitorLog = [IO.File]::ReadAllText($monitorLogPath)
                if ($monitorLog -match 'open-when-ready\.ps1') { break }
            }
        } catch [IO.IOException] { }
        Start-Sleep -Milliseconds 100
    }

    return [pscustomobject]@{
        ExitCode = $process.ExitCode
        Log      = Read-TestLog -Path $logPath
        MonitorLog = $monitorLog
        Output   = $process.StandardOutput.ReadToEnd() + $process.StandardError.ReadToEnd()
    }
}

function Invoke-ReservedRealBackgroundRunner {
    param(
        [string]$ScenarioName = 'reserved-real-runner',
        [int]$NodeDelaySeconds = 2,
        [switch]$NodeWritesStderr,
        [switch]$NodeWritesStages,
        [switch]$SkipMonitorInspection,
        [switch]$SuppressBrowserMonitor
    )

    $scenarioRoot = Join-Path $testRoot $ScenarioName
    $profilePath = Join-Path $scenarioRoot 'profile'
    $launchRoot = Join-Path $profilePath 'dsh-launch'
    $fakeBin = Join-Path $scenarioRoot 'fake-bin'
    $startupToken = [guid]::NewGuid().ToString('N')
    $gatePath = Join-Path $launchRoot ("startup-$startupToken.gate")
    New-Item -ItemType Directory -Force -Path $profilePath, $fakeBin | Out-Null

    $runtimeRoot = Join-Path $profilePath 'dsh-launch\runtime'
    $dshEntrypoint = Join-Path $runtimeRoot 'node_modules\@deepseek-ai\dsh\lib\bin.js'
    New-Item -ItemType Directory -Force -Path (Split-Path $dshEntrypoint -Parent) | Out-Null
    [IO.File]::WriteAllText($dshEntrypoint, '// fake dsh', [Text.Encoding]::ASCII)
    [IO.File]::WriteAllText(
        (Join-Path (Split-Path $dshEntrypoint -Parent | Split-Path -Parent) 'package.json'),
        '{"name":"@deepseek-ai/dsh","version":"0.1.0-rc.8"}',
        [Text.Encoding]::ASCII
    )
    [IO.File]::WriteAllText(
        (Join-Path $runtimeRoot 'dsh-runtime-ready.json'),
        '{"SchemaVersion":2,"Version":"0.1.0-rc.8","ValidatedBy":"npm-ls-all"}',
        [Text.Encoding]::ASCII
    )

    [IO.File]::WriteAllText(
        (Join-Path $fakeBin 'npm.cmd'),
        "@echo off`r`necho {`"latest`":`"0.1.0-rc.8`"}`r`nexit /b 0`r`n",
        [Text.Encoding]::ASCII
    )
    [IO.File]::WriteAllText(
        (Join-Path $fakeBin 'node.cmd'),
        "@echo off`r`necho REAL_NODE_ARGS:%*`r`nif defined DSH_TEST_NODE_STAGES echo Preparing DeepSeek Harness runtime`r`nif defined DSH_TEST_NODE_STAGES powershell.exe -NoProfile -Command `"Start-Sleep -Milliseconds 500`"`r`nif defined DSH_TEST_NODE_STAGES echo Installing 21 required DSH peer dependencies...`r`nif defined DSH_TEST_NODE_STAGES powershell.exe -NoProfile -Command `"Start-Sleep -Milliseconds 500`"`r`nif defined DSH_TEST_NODE_STAGES echo Validating DSH runtime dependencies...`r`nif defined DSH_TEST_NODE_STAGES powershell.exe -NoProfile -Command `"Start-Sleep -Milliseconds 500`"`r`nif defined DSH_TEST_NODE_STAGES echo Starting DeepSeek Harness web service...`r`nif defined DSH_TEST_NODE_STDERR >&2 echo BENIGN_NODE_STDERR`r`nif defined DSH_TEST_NODE_DELAY powershell.exe -NoProfile -Command `"Start-Sleep -Seconds %DSH_TEST_NODE_DELAY%`"`r`nexit /b 0`r`n",
        [Text.Encoding]::ASCII
    )

    $reservation = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot 'dsh-launch-state.ps1') `
        -Action AcquireStartupLock -LaunchRoot $launchRoot -OwnerPid $PID -StartupToken $startupToken 2>&1
    Assert-Equal 0 $LASTEXITCODE "The test coordinator should reserve the startup lock. Output:`n$($reservation -join [Environment]::NewLine)"

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $systemPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $runnerScript = Join-Path $repoRoot 'background-run.ps1'
    $runnerArguments = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', "`"$runnerScript`"",
        '-Version', '0.1.0-rc.8',
        '-LaunchRoot', "`"$launchRoot`"",
        '-StartupToken', $startupToken,
        '-CoordinatorGate', "`"$gatePath`"",
        '-TimeoutSeconds', '10'
    )
    if ($SuppressBrowserMonitor) { $runnerArguments += '-SuppressBrowserMonitor' }
    $startInfo.FileName = $systemPowerShell
    $startInfo.Arguments = $runnerArguments -join ' '
    $startInfo.WorkingDirectory = $repoRoot
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.EnvironmentVariables['PATH'] = "$fakeBin;$env:PATH"
    $startInfo.EnvironmentVariables['USERPROFILE'] = $profilePath
    if ($NodeDelaySeconds -gt 0) {
        $startInfo.EnvironmentVariables['DSH_TEST_NODE_DELAY'] = [string]$NodeDelaySeconds
    }
    if ($NodeWritesStderr) {
        $startInfo.EnvironmentVariables['DSH_TEST_NODE_STDERR'] = '1'
    }
    if ($NodeWritesStages) {
        $startInfo.EnvironmentVariables['DSH_TEST_NODE_STAGES'] = '1'
    }

    $process = [Diagnostics.Process]::Start($startInfo)
    $transfer = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot 'dsh-launch-state.ps1') `
        -Action AcquireStartupLock -LaunchRoot $launchRoot -OwnerPid $process.Id `
        -StartupToken $startupToken -TransferOwnership 2>&1
    Assert-Equal 0 $LASTEXITCODE "The coordinator should transfer ownership to the real runner. Output:`n$($transfer -join [Environment]::NewLine)"
    [IO.File]::WriteAllText($gatePath, 'GO', [Text.Encoding]::ASCII)

    $logPath = Join-Path $launchRoot 'dsh-background.log'
    $statePath = Join-Path $launchRoot 'dsh-startup.json'
    $runnerStarted = $false
    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        if (Test-Path -LiteralPath $statePath) {
            $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
            if ($state.State -eq 'STARTING') {
                $runnerStarted = $true
                break
            }
        }
        if ($process.HasExited) {
            break
        }
        Start-Sleep -Milliseconds 100
    }
    Assert-True $runnerStarted 'The real background runner should record STARTING before the fake npx command exits'
    $stateOwnerDuringRun = [string]$state.Pid
    $lockOwnerDuringRun = (Get-Content -LiteralPath (Join-Path $launchRoot 'dsh-startup.lock\pid.txt') -Raw).Trim()
    $startupMessages = [System.Collections.Generic.List[string]]::new()
    if ($state.Message) { $startupMessages.Add([string]$state.Message) }
    $monitorCommandLine = ''
    $monitorPid = 0
    if (-not $SkipMonitorInspection) {
        for ($attempt = 0; $attempt -lt 20; $attempt++) {
            $monitor = Get-CimInstance Win32_Process | Where-Object {
                $_.CommandLine -match 'open-when-ready\.ps1' -and $_.CommandLine -match [regex]::Escape($launchRoot)
            } | Select-Object -First 1
            if ($monitor) {
                $monitorCommandLine = [string]$monitor.CommandLine
                $monitorPid = [int]$monitor.ProcessId
                break
            }
            Start-Sleep -Milliseconds 100
        }
    }

    while (-not $process.HasExited) {
        if (Test-Path -LiteralPath $statePath) {
            $currentState = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
            if ($currentState.Message -and -not $startupMessages.Contains([string]$currentState.Message)) {
                $startupMessages.Add([string]$currentState.Message)
            }
        }
        Start-Sleep -Milliseconds 100
    }
    if (-not $process.WaitForExit(10000)) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        throw 'The real background runner did not exit after the fake DSH command completed'
    }
    if ($monitorPid -gt 0) {
        Stop-Process -Id $monitorPid -Force -ErrorAction SilentlyContinue
    }
    for ($attempt = 0; $attempt -lt 30 -and (Test-Path -LiteralPath (Join-Path $launchRoot 'dsh-startup.lock')); $attempt++) {
        Start-Sleep -Milliseconds 100
    }

    return [pscustomobject]@{
        ExitCode  = $process.ExitCode
        CoordinatorPid = $PID
        LockOwnerDuringRun = $lockOwnerDuringRun
        StateOwnerDuringRun = $stateOwnerDuringRun
        MonitorCommandLine = $monitorCommandLine
        RunnerPid = $process.Id
        StartupMessages = @($startupMessages)
        LockPath  = Join-Path $launchRoot 'dsh-startup.lock'
        Log       = Read-TestLog -Path $logPath
        Output    = $process.StandardOutput.ReadToEnd() + $process.StandardError.ReadToEnd()
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
    param(
        [string]$Argument = '-b',
        [int]$PowerShellExitCode = 0
    )
    $fakeBin = Get-FakePowerShellBin
    $profilePath = Join-Path $testRoot 'deepseek-profile'
    $processLogPath = Join-Path $profilePath 'powershell-processes.log'
    New-Item -ItemType Directory -Force -Path $profilePath | Out-Null
    [IO.File]::WriteAllText($processLogPath, '', [Text.Encoding]::UTF8)

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = 'cmd.exe'
    $startInfo.Arguments = '/d /c deepseek.cmd ' + $Argument
    $startInfo.WorkingDirectory = $repoRoot
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.EnvironmentVariables['PATH'] = "$fakeBin;$env:PATH"
    $startInfo.EnvironmentVariables['USERPROFILE'] = $profilePath
    $startInfo.EnvironmentVariables['DSH_TEST_POWERSHELL_EXIT'] = [string]$PowerShellExitCode
    $startInfo.EnvironmentVariables['DSH_TEST_PROCESS_LOG'] = $processLogPath

    $process = [Diagnostics.Process]::Start($startInfo)
    Assert-True ($process.WaitForExit(3000)) "deepseek $Argument did not return promptly"
    return [pscustomobject]@{
        ExitCode = $process.ExitCode
        Output   = $process.StandardOutput.ReadToEnd() + $process.StandardError.ReadToEnd()
        ProcessLog = [IO.File]::ReadAllText($processLogPath)
    }
}

function Invoke-AlternateForegroundCommand {
    $fakeBin = Get-FakePowerShellBin
    $profilePath = Join-Path $testRoot 'alternate-foreground-profile'
    $processLogPath = Join-Path $profilePath 'powershell-processes.log'
    New-Item -ItemType Directory -Force -Path $profilePath | Out-Null
    [IO.File]::WriteAllText($processLogPath, '', [Text.Encoding]::UTF8)

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = 'cmd.exe'
    $startInfo.Arguments = '/d /c start-deepseek-harness.bat'
    $startInfo.WorkingDirectory = $repoRoot
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.EnvironmentVariables['PATH'] = "$fakeBin;$env:PATH"
    $startInfo.EnvironmentVariables['USERPROFILE'] = $profilePath
    $startInfo.EnvironmentVariables['DSH_TEST_POWERSHELL_EXIT'] = '0'
    $startInfo.EnvironmentVariables['DSH_TEST_PROCESS_LOG'] = $processLogPath

    $process = [Diagnostics.Process]::Start($startInfo)
    $process.StandardInput.WriteLine('x')
    $process.StandardInput.Close()
    Assert-True ($process.WaitForExit(3000)) 'start-deepseek-harness.bat did not finish after test input'

    return [pscustomobject]@{
        ExitCode = $process.ExitCode
        Output = $process.StandardOutput.ReadToEnd() + $process.StandardError.ReadToEnd()
        ProcessLog = [IO.File]::ReadAllText($processLogPath)
    }
}

New-Item -ItemType Directory -Force -Path $testRoot | Out-Null
try {
    Invoke-Test 'closed-port startup skips Get-NetTCPConnection' {
        $reservation = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
        $reservation.Start()
        $closedPort = ([Net.IPEndPoint]$reservation.LocalEndpoint).Port
        $reservation.Stop()

        $closed = Invoke-StartScenario -Scenario Immediate -ScenarioName 'closed-port' -Port $closedPort
        Assert-Equal 0 $closed.ExitCode "Closed-port startup should be submitted. Output:`n$($closed.Output)"
        Assert-NotMatch $closed.ProcessLog 'GET_NET_TCP_CONNECTION' 'Closed-port startup must avoid the networking cmdlet'
    }

    Invoke-Test 'occupied-port startup resolves its owner after TCP connects' {
        $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
        $listener.Start()
        try {
            $occupiedPort = ([Net.IPEndPoint]$listener.LocalEndpoint).Port
            $occupied = Invoke-StartScenario -Scenario Immediate -ScenarioName 'occupied-port' -Port $occupiedPort
        } finally {
            $listener.Stop()
        }

        Assert-Equal 0 $occupied.ExitCode "Occupied-port startup should report the existing listener. Output:`n$($occupied.Output)"
        Assert-Match $occupied.ProcessLog "GET_NET_TCP_CONNECTION`t$occupiedPort" 'Occupied port must resolve its owner for diagnostics'
    }

    Invoke-Test 'a live startup lock owns browser opening when its port is already listening' {
        $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
        $listener.Start()
        $occupiedPort = ([Net.IPEndPoint]$listener.LocalEndpoint).Port
        $listener.Stop()
        $result = Invoke-StartScenario -Scenario OccupiedDuplicate -ScenarioName 'occupied-duplicate' -Port $occupiedPort

        Assert-Equal 0 $result.ExitCode 'An existing startup should return without submitting another process'
        Assert-NotMatch $result.ProcessLog '(?m)^http://127\.0\.0\.1:' 'A duplicate launch must not open a second browser window'
        Assert-NotMatch $result.ProcessLog 'background-run\.ps1' 'A duplicate launch must not submit a second runner'
    }

    Invoke-Test 'background CLI mode returns immediately with submitted status' {
        $result = Invoke-StartScenario -Scenario Immediate
        Assert-Equal 0 $result.ExitCode 'Immediate mode should exit successfully'
        Assert-True ($result.Elapsed.TotalSeconds -lt 3) 'Immediate mode should not wait for readiness'
        Assert-Match $result.Output 'deepseek --logs' 'Immediate mode should expose the log command'
        Assert-Match $result.ProcessLog 'powershell(?:\.exe)?.*background-run\.ps1.*-Version 0\.1\.0-rc\.8' 'Immediate mode should launch the direct PowerShell runner with the selected local version'
        Assert-NotMatch $result.ProcessLog 'background-run\.cmd' 'Normal startup must not retain the CMD runner on its critical path'
        Assert-True (Test-Path -LiteralPath $result.LockPath) 'Immediate mode should acquire the startup lock before returning'
        $coordinatorState = Get-Content -LiteralPath $result.StatePath -Raw | ConvertFrom-Json
        Assert-Equal 'STARTING' $coordinatorState.State 'The coordinator must replace any stale failure state before releasing the runner gate'
    }

    Invoke-Test 'background coordinator passes the same startup token to the runner and lock' {
        $result = Invoke-StartScenario -Scenario Immediate
        $tokenMatch = [regex]::Match($result.ProcessLog, 'STARTUP_TOKEN=([0-9a-f]{32})')
        Assert-True $tokenMatch.Success 'The background process must inherit a generated startup token'
        Assert-True (Test-Path -LiteralPath $result.LockTokenPath) 'The coordinator lock must record its startup token'
        $lockToken = (Get-Content -LiteralPath $result.LockTokenPath -Raw).Trim()
        Assert-Equal $tokenMatch.Groups[1].Value $lockToken 'The child environment and coordinator lock must identify the same startup task'
        Assert-Match $result.ProcessLog 'LOCK_PRESENT=True' 'The coordinator must initialize the lock before the runner can execute'
    }

    Invoke-Test 'deepseek -b no longer tells the user to close a waiting window' {
        $result = Invoke-DeepseekCommand
        Assert-Equal 0 $result.ExitCode 'deepseek -b should preserve a successful launch exit code'
        Assert-NotMatch $result.Output 'Close this window anytime' 'deepseek -b should not print the stale waiting-window message'
        Assert-Match $result.Output 'start-background\.ps1.*-TimeoutSeconds 900' 'deepseek -b should submit startup with the approved monitor timeout'
    }

    Invoke-Test 'compatibility CMD forwards to the PowerShell runner' {
        $result = Invoke-BackgroundRunner
        Assert-Equal 0 $result.ExitCode "Compatibility runner should preserve success. Output:`n$($result.Output)"
        Assert-Match $result.MonitorLog 'resolve-dsh-version\.ps1.*-PreferLocalRuntime' 'Compatibility wrapper should resolve a local-first version'
        Assert-Match $result.MonitorLog 'background-run\.ps1.*-Version 0\.1\.0-rc\.8' 'Compatibility wrapper should forward to the PowerShell runner'
    }

    Invoke-Test 'compatibility CMD forwards browser-monitor suppression' {
        $result = Invoke-BackgroundRunner -SuppressBrowserMonitor
        Assert-Equal 0 $result.ExitCode "Suppressed compatibility runner should succeed. Output:`n$($result.Output)"
        Assert-Match $result.MonitorLog 'background-run\.ps1.*-SuppressBrowserMonitor' 'Compatibility wrapper must preserve explicit monitor suppression'
    }

    Invoke-Test 'real PowerShell runner owns state, monitor, and lock cleanup' {
        $result = Invoke-ReservedRealBackgroundRunner
        Assert-Equal 0 $result.ExitCode "The PowerShell runner should exit successfully. Log:`n$($result.Log)`nOutput:`n$($result.Output)"
        Assert-Equal ([string]$result.RunnerPid) $result.LockOwnerDuringRun 'The runner must own the transferred lock'
        Assert-Equal ([string]$result.RunnerPid) $result.StateOwnerDuringRun 'STARTING state must identify the runner'
        Assert-Match $result.MonitorCommandLine ([regex]::Escape("-ParentPid $($result.RunnerPid)")) 'The readiness monitor must follow the runner process'
        Assert-Match $result.MonitorCommandLine ([regex]::Escape("-OwnerPid $($result.RunnerPid)")) 'The readiness monitor must write RUNNING with the runner PID'
        Assert-Match $result.MonitorCommandLine ([regex]::Escape('-PollIntervalMilliseconds 200')) 'The runner must use the 200 ms readiness interval'
        Assert-Match $result.Log '(?m)^Runner PID: \d+\s*$' 'The runner must log its identity before DSH work starts'
        Assert-Match $result.Log 'REAL_NODE_ARGS:.*@deepseek-ai\\dsh\\lib\\bin\.js web --no-open' 'The runner must leave browser ownership with the readiness monitor'
        Assert-Equal 1 ([regex]::Matches($result.Log, '--no-open').Count) 'The runner must pass --no-open exactly once'
        Assert-NotMatch $result.Log 'Get-CimInstance Win32_Process|resolve-dsh-version' 'The runner must not rediscover its PID or selected version'
        Assert-NotMatch $result.Log "`0" 'The UTF-8 startup log must not contain UTF-16 NUL bytes from helper output'
        Assert-Equal $false (Test-Path -LiteralPath $result.LockPath) 'A completed runner must release its startup lock'
    }

    Invoke-Test 'real runner reports runtime preparation phases through startup state' {
        $result = Invoke-ReservedRealBackgroundRunner -ScenarioName 'runner-stages' `
            -NodeDelaySeconds 2 -NodeWritesStages -SkipMonitorInspection -SuppressBrowserMonitor
        $messages = [string]($result.StartupMessages -join [Environment]::NewLine)
        Assert-Match $messages 'PREPARING_RUNTIME' `
            'The runner should report the runtime preparation phase'
        Assert-Match $messages 'INSTALLING_PEERS:21' `
            'The runner should report the peer dependency phase'
        Assert-Match $messages 'VALIDATING_RUNTIME' `
            'The runner should report the dependency validation phase'
        Assert-Match $messages 'STARTING_WEB' `
            'The runner should report the web service phase'
        Assert-Match $result.Log 'Preparing DeepSeek Harness runtime' `
            'The runner log should retain the original preparation marker'
    }

    Invoke-Test 'benign child stderr does not turn a successful DSH exit into runner failure' {
        $result = Invoke-ReservedRealBackgroundRunner -ScenarioName 'runner-benign-stderr' `
            -NodeDelaySeconds 0 -NodeWritesStderr -SuppressBrowserMonitor
        Assert-Equal 0 $result.ExitCode "A successful DSH child must preserve exit code 0. Log:`n$($result.Log)`nOutput:`n$($result.Output)"
        Assert-Match $result.Log 'BENIGN_NODE_STDERR' 'Child stderr diagnostics must still be written to the UTF-8 runner log'
        Assert-NotMatch $result.Log 'Runner failure:' 'Child stderr is output, not a terminating runner exception'
    }

    Invoke-Test 'ten rapid PowerShell runner cycles all log and release their locks' {
        foreach ($attempt in 1..10) {
            $result = Invoke-ReservedRealBackgroundRunner -ScenarioName "runner-stress-$attempt" -NodeDelaySeconds 0 -SuppressBrowserMonitor
            Assert-Equal 0 $result.ExitCode "Stress runner $attempt should exit successfully. Output:`n$($result.Output)"
            Assert-Match $result.Log '(?m)^Runner PID: \d+\s*$' "Stress runner $attempt must write its first log record"
            Assert-Equal $false (Test-Path -LiteralPath $result.LockPath) "Stress runner $attempt must release its lock"
        }
    }

    Invoke-Test 'deepseek CMD entrypoint is safe across Windows code pages' {
        $bytes = [IO.File]::ReadAllBytes((Join-Path $repoRoot 'deepseek.cmd'))
        $nonAscii = $bytes | Where-Object { $_ -gt 0x7F } | Select-Object -First 1
        Assert-True ($null -eq $nonAscii) 'deepseek.cmd must contain only ASCII bytes so CMD does not misinterpret UTF-8 comments under CP936'
    }

    Invoke-Test 'deepseek status delegates to launcher startup state reporting' {
        $result = Invoke-DeepseekCommand -Argument '--status'
        Assert-Equal 0 $result.ExitCode 'Status lookup should return successfully'
        Assert-Match $result.Output 'dsh-launch-state\.ps1.*-Action GetStatus' 'Status must delegate to the launcher state helper'
    }

    Invoke-Test 'deepseek upgrade preserves a nonzero upgrade script exit code' {
        $result = Invoke-DeepseekCommand -Argument '--upgrade' -PowerShellExitCode 7
        Assert-Equal 7 $result.ExitCode 'A failed or timed-out upgrade must return the PowerShell failure code to the caller'
        Assert-Match $result.Output 'upgrade-dsh\.ps1' 'The upgrade command should still dispatch to the upgrade script'
    }

    Invoke-Test 'foreground launch uses the prepared DSH runtime' {
        $result = Invoke-DeepseekCommand -Argument ''
        Assert-Equal 0 $result.ExitCode 'The fake foreground DSH command should exit successfully'
        Assert-Match $result.ProcessLog 'resolve-dsh-version\.ps1.*-PreferLocalRuntime' 'Foreground launch must reuse a prepared runtime without registry discovery'
        Assert-Match $result.ProcessLog 'open-when-ready\.ps1.*-PollIntervalMilliseconds 200' 'Foreground launch must use the 200 ms readiness interval'
        Assert-Match $result.ProcessLog 'run-dsh\.ps1.*-Version 0\.1\.0-rc\.8.*-DshArguments web.*-NoOpen' 'Foreground launch must leave browser ownership with the readiness monitor'
    }

    Invoke-Test 'alternate foreground launcher uses the managed runtime instead of npx' {
        $result = Invoke-AlternateForegroundCommand
        Assert-Equal 0 $result.ExitCode "The alternate foreground command should exit successfully. Output:`n$($result.Output)"
        Assert-Match $result.ProcessLog 'resolve-dsh-version\.ps1.*-PreferLocalRuntime' 'The alternate launcher must reuse a prepared runtime without registry discovery'
        Assert-Match $result.ProcessLog 'open-when-ready\.ps1.*-PollIntervalMilliseconds 200' 'The alternate launcher must use the 200 ms readiness interval'
        Assert-Match $result.ProcessLog 'run-dsh\.ps1.*-DshArguments web.*-NoOpen' 'The alternate launcher must leave browser ownership with the readiness monitor'
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

    Invoke-Test 'shortcut wait mode leaves browser opening to the runner monitor' {
        $result = Invoke-StartScenario -Scenario Ready
        Assert-Equal 0 $result.ExitCode 'Wait mode should exit successfully after HTTP readiness'
        Assert-Match $result.ProcessLog 'WEB_REQUEST' 'Wait mode must observe HTTP readiness before returning'
        Assert-NotMatch $result.ProcessLog '(?m)^http://127\.0\.0\.1:3080\s*$' 'The wait coordinator must not issue a duplicate browser launch'
        Assert-NotMatch $result.ProcessLog '-SuppressBrowserMonitor|SUPPRESS_MONITOR=1' 'Wait mode must leave the runner readiness monitor enabled'
    }

    Invoke-Test 'wait mode reports log details when the service exits early' {
        $result = Invoke-StartScenario -Scenario Failed
        $utf8LogText = [string]::Concat([char]0x5468, [char]0x56DB, ' simulated launch failure')
        $failureOutput = [IO.File]::ReadAllText($result.FailureOutputPath)
        Assert-Equal 1 $result.ExitCode 'Wait mode should fail when the background process exits'
        Assert-Match $result.Output ([regex]::Escape($result.LogPath)) 'Wait mode should print the full log path'
        Assert-Match $failureOutput ([regex]::Escape($utf8LogText)) 'Wait mode should decode UTF-8 log details without mojibake'
    }

    Invoke-Test 'wait mode prints mapped startup phases and a phase-aware heartbeat' {
        $result = Invoke-StartScenario -Scenario Staged -ScenarioName 'staged-phases' -HeartbeatSeconds 1
        Assert-Equal 0 $result.ExitCode "Staged startup should exit after HTTP readiness. Output:`n$($result.Output)"
        Assert-Match $result.ProcessLog 'WEB_REQUEST' 'The wait loop must poll HTTP readiness before the staged service becomes ready'
        $stagedOutput = [IO.File]::ReadAllText($result.StagedOutputPath)
        foreach ($phase in @($script:PhaseDownload, $script:PhasePeers, $script:PhaseValidate, $script:PhaseWeb)) {
            $phaseLinePattern = [regex]::Escape($script:PhasePrefix + $phase)
            Assert-Equal 1 ([regex]::Matches($stagedOutput, $phaseLinePattern).Count) 'Each mapped phase line should appear exactly once'
        }
        Assert-NotMatch $stagedOutput ([regex]::Escape($script:OldCounterText)) 'The old five-second counter must no longer be printed'
        $heartbeatPattern = [regex]::Escape($script:HeartbeatPrefix) + '.+' + [regex]::Escape($script:ElapsedPrefix) + ' \d+ ' + [regex]::Escape($script:SecondsEllipsis)
        Assert-Match $stagedOutput $heartbeatPattern 'A heartbeat should carry the current phase and the elapsed seconds'
    }

    Invoke-Test 'a live startup lock prevents another background runner from being submitted' {
        $result = Invoke-StartScenario -Scenario Duplicate
        Assert-Equal 0 $result.ExitCode 'A duplicate background command should return successfully'
        Assert-Match $result.Output 'deepseek --status' 'Duplicate launch should point to the current startup status'
        Assert-NotMatch $result.ProcessLog 'background-run\.(?:cmd|ps1)' 'Duplicate launch must not submit another background runner'
    }

    Invoke-Test 'wait mode attaches to an existing startup until it becomes ready' {
        $result = Invoke-StartScenario -Scenario DuplicateReady
        Assert-Equal 0 $result.ExitCode 'A synchronous duplicate should succeed only after observing readiness'
        Assert-Match $result.ProcessLog 'WEB_REQUEST' 'Synchronous duplicate startup must poll the existing service instead of returning immediately'
        Assert-NotMatch $result.ProcessLog 'background-run\.(?:cmd|ps1)' 'Attaching to an existing startup must not submit another runner'
        Assert-NotMatch $result.ProcessLog '(?m)^http://127\.0\.0\.1:3080\s*$' 'The attached waiter must leave browser ownership with the original startup'
    }

    Invoke-Test 'wait mode propagates failure from an existing startup' {
        $result = Invoke-StartScenario -Scenario DuplicateFailed
        Assert-Equal 1 $result.ExitCode 'A synchronous duplicate must fail when the startup it attached to has failed'
        Assert-Match $result.Output 'existing startup failed' 'The attached waiter should report the existing failure reason'
        Assert-NotMatch $result.ProcessLog 'background-run\.(?:cmd|ps1)' 'A failed existing startup must not trigger a second runner'
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
        Remove-TestRoot -Path $testRoot
    }
}

exit 0
