param([string]$ArchivePath)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$manifestPath = Join-Path $repoRoot 'release-files.txt'
$releaseWorkflowPath = Join-Path $repoRoot '.github\workflows\release.yml'
$testRoot = Join-Path $env:TEMP ('dsh-release-tests-' + [guid]::NewGuid().ToString('N'))
$packageRoot = if ($ArchivePath) { Join-Path $testRoot 'extracted\dsh-launcher' } else { Join-Path $testRoot 'dsh-launcher' }
$fakeBin = Join-Path $testRoot 'fake-bin'
$profileRoot = Join-Path $testRoot 'profile'
$processLog = Join-Path $testRoot 'process.log'
$requiredRuntimeFiles = @(
    'deepseek.cmd',
    'background-run.cmd',
    'background-run.ps1',
    'start-background.ps1',
    'dsh-launch-state.ps1',
    'run-dsh.ps1',
    'resolve-dsh-version.ps1',
    'dsh-version.ps1'
)

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    if ($Expected -ne $Actual) { throw "$Message (expected: $Expected, actual: $Actual)" }
}

function Assert-Match {
    param([string]$Actual, [string]$Pattern, [string]$Message)
    if ($Actual -notmatch $Pattern) { throw "$Message`nActual:`n$Actual" }
}

function Invoke-PackagedCommand {
    param(
        [string]$Arguments,
        [string]$PathValue
    )

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = 'cmd.exe'
    $startInfo.Arguments = "/d /c deepseek.cmd $Arguments"
    $startInfo.WorkingDirectory = $packageRoot
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.EnvironmentVariables['PATH'] = $PathValue
    $startInfo.EnvironmentVariables['USERPROFILE'] = $profileRoot
    $startInfo.EnvironmentVariables['LOCALAPPDATA'] = (Join-Path $testRoot 'local-app-data')
    $startInfo.EnvironmentVariables['APPDATA'] = (Join-Path $testRoot 'app-data')
    $startInfo.EnvironmentVariables['DSH_TEST_PROCESS_LOG'] = $processLog
    $process = [Diagnostics.Process]::Start($startInfo)
    if (-not $process.WaitForExit(10000)) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        throw "Packaged deepseek $Arguments did not exit"
    }
    return [pscustomobject]@{
        ExitCode = $process.ExitCode
        Output = $process.StandardOutput.ReadToEnd() + $process.StandardError.ReadToEnd()
    }
}

New-Item -ItemType Directory -Force -Path $fakeBin, $profileRoot | Out-Null
try {
    if (-not (Test-Path -LiteralPath $manifestPath)) { throw 'release-files.txt is missing' }
    $releaseWorkflow = Get-Content -LiteralPath $releaseWorkflowPath -Raw
    Assert-Match $releaseWorkflow 'github\.ref_name' 'Release workflow must inspect the pushed tag name'
    Assert-Match $releaseWorkflow 'VERSION' 'Release workflow must compare the tag with VERSION'
    $releaseFiles = @(Get-Content -LiteralPath $manifestPath | Where-Object { $_ -and -not $_.StartsWith('#') })
    if ($ArchivePath) {
        if (-not (Test-Path -LiteralPath $ArchivePath -PathType Leaf)) { throw "Release archive is missing: $ArchivePath" }
        Expand-Archive -LiteralPath $ArchivePath -DestinationPath (Join-Path $testRoot 'extracted') -Force
    } else {
        New-Item -ItemType Directory -Force -Path $packageRoot | Out-Null
        foreach ($file in $releaseFiles) {
            $source = Join-Path $repoRoot $file
            if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Release manifest source is missing: $file" }
            Copy-Item -LiteralPath $source -Destination $packageRoot
        }
    }
    foreach ($required in $requiredRuntimeFiles) {
        Assert-Equal $true ($releaseFiles -contains $required) "Release manifest omits required runtime file $required"
        Assert-Equal $true (Test-Path -LiteralPath (Join-Path $packageRoot $required)) "Assembled package omits $required"
    }

    [IO.File]::WriteAllText((Join-Path $fakeBin 'npm.cmd'), "@echo off`r`necho npm-test`r`n", [Text.Encoding]::ASCII)
    $check = Invoke-PackagedCommand -Arguments '--check' -PathValue "$fakeBin;$env:PATH"
    Assert-Equal 0 $check.ExitCode "Packaged --check failed. Output:`n$($check.Output)"
    Assert-Match $check.Output 'npm: found' 'Packaged --check must find npm'

    $status = Invoke-PackagedCommand -Arguments '--status' -PathValue $env:PATH
    Assert-Equal 0 $status.ExitCode "Packaged --status failed. Output:`n$($status.Output)"
    Assert-Match $status.Output 'NOT RUNNING' 'A clean extracted package should report NOT RUNNING'

    $fakeSource = @'
using System;
public static class FakePowerShell
{
    public static int Main(string[] args)
    {
        var text = string.Join(" ", args);
        var log = Environment.GetEnvironmentVariable("DSH_TEST_PROCESS_LOG");
        if (!string.IsNullOrEmpty(log)) System.IO.File.AppendAllText(log, text + Environment.NewLine);
        if (text.Contains("resolve-dsh-version.ps1")) Console.WriteLine("0.1.0-rc.8");
        return 0;
    }
}
'@
    $fakeSourcePath = Join-Path $fakeBin 'FakePowerShell.cs'
    $fakePowerShell = Join-Path $fakeBin 'powershell.exe'
    [IO.File]::WriteAllText($fakeSourcePath, $fakeSource, [Text.Encoding]::ASCII)
    $compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    if (-not (Test-Path -LiteralPath $compiler)) { $compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
    & $compiler /nologo /target:exe "/out:$fakePowerShell" $fakeSourcePath
    Assert-Equal 0 $LASTEXITCODE 'Could not compile the packaged-dispatch PowerShell test double'

    [IO.File]::WriteAllText($processLog, '', [Text.Encoding]::ASCII)
    $foreground = Invoke-PackagedCommand -Arguments '' -PathValue "$fakeBin;$env:PATH"
    $background = Invoke-PackagedCommand -Arguments '-b' -PathValue "$fakeBin;$env:PATH"
    Assert-Equal 0 $foreground.ExitCode "Packaged foreground dispatch failed. Output:`n$($foreground.Output)"
    Assert-Equal 0 $background.ExitCode "Packaged background dispatch failed. Output:`n$($background.Output)"
    $dispatches = [IO.File]::ReadAllText($processLog)
    Assert-Match $dispatches 'run-dsh\.ps1' 'Extracted foreground command must reach the packaged runtime script'
    Assert-Match $dispatches 'start-background\.ps1' 'Extracted background command must reach the packaged coordinator script'

    Write-Host 'PASS: assembled release package contains and dispatches every required runtime path'
} finally {
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}

exit 0
