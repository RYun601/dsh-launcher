$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$runtimeScript = Join-Path $repoRoot 'run-dsh.ps1'
$testRoot = Join-Path $env:TEMP ('dsh-runtime-tests-' + [guid]::NewGuid().ToString('N'))
$profileRoot = Join-Path $testRoot 'profile'
$runtimeRoot = Join-Path $profileRoot 'dsh-launch\runtime'
$fakeBin = Join-Path $testRoot 'fake-bin'
$npmLog = Join-Path $testRoot 'npm.log'
$nodeLog = Join-Path $testRoot 'node.log'
$peerScanLog = Join-Path $testRoot 'peer-scan.log'
$runtimeHarness = Join-Path $testRoot 'invoke-runtime-with-scan-log.ps1'
$script:Passed = 0

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    if ($Expected -ne $Actual) { throw "$Message (expected: $Expected, actual: $Actual)" }
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

function Invoke-Runtime {
    param(
        [string]$SelectedRuntimeRoot = $runtimeRoot,
        [string]$PeerMode = '',
        [switch]$TrackPeerScans,
        [switch]$NoOpen
    )

    $previousPath = $env:PATH
    $previousNpmLog = $env:DSH_TEST_NPM_LOG
    $previousNodeLog = $env:DSH_TEST_NODE_LOG
    $previousUserProfile = $env:USERPROFILE
    $previousPeerMode = $env:DSH_TEST_PEER_MODE
    $previousPeerScanLog = $env:DSH_TEST_PEER_SCAN_LOG
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $env:PATH = "$fakeBin;$previousPath"
        $env:DSH_TEST_NPM_LOG = $npmLog
        $env:DSH_TEST_NODE_LOG = $nodeLog
        $env:USERPROFILE = $profileRoot
        $env:DSH_TEST_PEER_MODE = $PeerMode
        $env:DSH_TEST_PEER_SCAN_LOG = $peerScanLog
        $ErrorActionPreference = 'Continue'
        $scriptPath = if ($TrackPeerScans) { $runtimeHarness } else { $runtimeScript }
        $scriptArguments = if ($TrackPeerScans) {
            @('-RuntimeScript', $runtimeScript, '-Version', '0.1.0-rc.8', '-RuntimeRoot', $SelectedRuntimeRoot, '-DshArguments', 'web')
        } else {
            @('-Version', '0.1.0-rc.8', '-RuntimeRoot', $SelectedRuntimeRoot, '-DshArguments', 'web')
        }
        if ($NoOpen) { $scriptArguments += '-NoOpen' }
        $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath @scriptArguments 2>&1
        return [pscustomobject]@{
            ExitCode = $LASTEXITCODE
            Output = [string]($output -join [Environment]::NewLine)
        }
    } finally {
        $env:PATH = $previousPath
        $env:DSH_TEST_NPM_LOG = $previousNpmLog
        $env:DSH_TEST_NODE_LOG = $previousNodeLog
        $env:USERPROFILE = $previousUserProfile
        $env:DSH_TEST_PEER_MODE = $previousPeerMode
        $env:DSH_TEST_PEER_SCAN_LOG = $previousPeerScanLog
        $ErrorActionPreference = $previousErrorActionPreference
    }
}

function Invoke-UnsafeRuntime {
    param([string]$UnsafeRoot)

    $previousPath = $env:PATH
    $previousNpmLog = $env:DSH_TEST_NPM_LOG
    $previousNodeLog = $env:DSH_TEST_NODE_LOG
    $previousUserProfile = $env:USERPROFILE
    try {
        $env:PATH = "$fakeBin;$previousPath"
        $env:DSH_TEST_NPM_LOG = $npmLog
        $env:DSH_TEST_NODE_LOG = $nodeLog
        $env:USERPROFILE = $profileRoot
        $previousErrorPreference = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $runtimeScript `
            -Version '0.1.0-rc.8' -RuntimeRoot $UnsafeRoot -DshArguments 'web' 2>&1
        $exitCode = $LASTEXITCODE
        $ErrorActionPreference = $previousErrorPreference
        return [pscustomobject]@{
            ExitCode = $exitCode
            Output = [string]($output -join [Environment]::NewLine)
        }
    } finally {
        $env:PATH = $previousPath
        $env:DSH_TEST_NPM_LOG = $previousNpmLog
        $env:DSH_TEST_NODE_LOG = $previousNodeLog
        $env:USERPROFILE = $previousUserProfile
    }
}

New-Item -ItemType Directory -Force -Path $testRoot, $fakeBin | Out-Null
try {
    $runtimeHarnessScript = @'
param(
    [Parameter(Mandatory = $true)][string]$RuntimeScript,
    [Parameter(Mandatory = $true)][string]$Version,
    [Parameter(Mandatory = $true)][string]$RuntimeRoot,
    [string[]]$DshArguments = @('web')
)

function global:Get-ChildItem {
    [IO.File]::AppendAllText($env:DSH_TEST_PEER_SCAN_LOG, "scan`r`n")
    Microsoft.PowerShell.Management\Get-ChildItem @args
}

& $RuntimeScript -Version $Version -RuntimeRoot $RuntimeRoot -DshArguments $DshArguments
exit $LASTEXITCODE
'@
    [IO.File]::WriteAllText($runtimeHarness, $runtimeHarnessScript, [Text.UTF8Encoding]::new($false))

    $fakeNpmScript = @'
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$NpmArguments)
$ErrorActionPreference = 'Stop'
[IO.File]::AppendAllText($env:DSH_TEST_NPM_LOG, ($NpmArguments -join ' ') + [Environment]::NewLine)
$prefixIndex = [Array]::IndexOf($NpmArguments, '--prefix')
    $runtimeRoot = $NpmArguments[$prefixIndex + 1]
    $modules = Join-Path $runtimeRoot 'node_modules\@deepseek-ai'
    $argumentText = $NpmArguments -join ' '

    if ($NpmArguments[0] -eq 'ls') {
        $repairMarker = Join-Path $runtimeRoot 'react-peer-repaired.txt'
        if ($env:DSH_TEST_PEER_MODE -eq 'incompatible-react' -and -not (Test-Path -LiteralPath $repairMarker)) {
            [Console]::Error.WriteLine('npm error code ELSPROBLEMS')
            Write-Output '{"name":"runtime","problems":["invalid: react@19.2.8 node_modules/react"]}'
            exit 1
        }
        if ($env:DSH_TEST_PEER_MODE -eq 'unknown-audit-error') {
            [Console]::Error.WriteLine('npm error code ELSPROBLEMS')
            Write-Output '{"name":"runtime","problems":["missing: unknown-package@1.0.0"]}'
            exit 1
        }
        Write-Output '{"name":"runtime","problems":[]}'
        exit 0
    }

    if ($argumentText -match '@deepseek-ai/dsh@0\.1\.0-rc\.8') {
    $dshRoot = Join-Path $modules 'dsh'
    $bootRoot = Join-Path $modules 'dsh-app-boot'
    New-Item -ItemType Directory -Force -Path (Join-Path $dshRoot 'lib'), $bootRoot | Out-Null
    [IO.File]::WriteAllText((Join-Path $dshRoot 'lib\bin.js'), '// fake dsh', [Text.Encoding]::ASCII)
    [IO.File]::WriteAllText(
        (Join-Path $dshRoot 'package.json'),
        (@{ name = '@deepseek-ai/dsh'; version = '0.1.0-rc.8' } | ConvertTo-Json),
        [Text.UTF8Encoding]::new($false)
    )
        [IO.File]::WriteAllText(
            (Join-Path $bootRoot 'package.json'),
        (@{
            name = '@deepseek-ai/dsh-app-boot'
            version = '0.1.0-rc.8'
            peerDependencies = @{
                '@deepseek-ai/cordis-plugin-group' = '^1.0.1'
                '@deepseek-ai/optional-monitor' = '^1.0.0'
            }
            peerDependenciesMeta = @{
                '@deepseek-ai/optional-monitor' = @{ optional = $true }
            }
        } | ConvertTo-Json -Depth 5),
            [Text.UTF8Encoding]::new($false)
        )
        if ($env:DSH_TEST_PEER_MODE -eq 'incompatible-react') {
            $reactRoot = Join-Path $runtimeRoot 'node_modules\react'
            $reactDomRoot = Join-Path $runtimeRoot 'node_modules\react-dom'
            New-Item -ItemType Directory -Force -Path $reactRoot, $reactDomRoot | Out-Null
            [IO.File]::WriteAllText((Join-Path $reactRoot 'package.json'), '{"name":"react","version":"19.2.8"}', [Text.Encoding]::ASCII)
            [IO.File]::WriteAllText((Join-Path $reactDomRoot 'package.json'), '{"name":"react-dom","version":"19.2.8"}', [Text.Encoding]::ASCII)
        }
    }

    if ($argumentText -match '@deepseek-ai/cordis-plugin-group@') {
    $peerRoot = Join-Path $modules 'cordis-plugin-group'
    New-Item -ItemType Directory -Force -Path $peerRoot | Out-Null
    [IO.File]::WriteAllText(
        (Join-Path $peerRoot 'package.json'),
        (@{ name = '@deepseek-ai/cordis-plugin-group'; version = '1.0.1' } | ConvertTo-Json),
        [Text.UTF8Encoding]::new($false)
    )
    }


    if ($argumentText -match 'react@18\.3\.1' -and $argumentText -match 'react-dom@18\.3\.1') {
        $reactRoot = Join-Path $runtimeRoot 'node_modules\react'
        $reactDomRoot = Join-Path $runtimeRoot 'node_modules\react-dom'
        New-Item -ItemType Directory -Force -Path $reactRoot, $reactDomRoot | Out-Null
        [IO.File]::WriteAllText((Join-Path $reactRoot 'package.json'), '{"name":"react","version":"18.3.1"}', [Text.Encoding]::ASCII)
        [IO.File]::WriteAllText((Join-Path $reactDomRoot 'package.json'), '{"name":"react-dom","version":"18.3.1"}', [Text.Encoding]::ASCII)
        Set-Content -LiteralPath (Join-Path $runtimeRoot 'react-peer-repaired.txt') -Value 'ok' -Encoding ASCII
    }
    exit 0
'@
    [IO.File]::WriteAllText((Join-Path $fakeBin 'fake-npm.ps1'), $fakeNpmScript, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText(
        (Join-Path $fakeBin 'npm.cmd'),
        "@echo off`r`npowershell.exe -NoProfile -ExecutionPolicy Bypass -File `"%~dp0fake-npm.ps1`" %*`r`nexit /b %ERRORLEVEL%`r`n",
        [Text.Encoding]::ASCII
    )
    [IO.File]::WriteAllText(
        (Join-Path $fakeBin 'node.cmd'),
        "@echo off`r`necho %*>>`"%DSH_TEST_NODE_LOG%`"`r`nif defined DSH_TEST_NODE_DELAY powershell.exe -NoProfile -Command `"Start-Sleep -Seconds %DSH_TEST_NODE_DELAY%`"`r`nexit /b 0`r`n",
        [Text.Encoding]::ASCII
    )

    Invoke-Test 'installs the DSH runtime, completes required peers, and reuses a ready version' {
        [IO.File]::WriteAllText($peerScanLog, '', [Text.Encoding]::ASCII)
        $first = Invoke-Runtime -TrackPeerScans
        Assert-Equal 0 $first.ExitCode "Runtime preparation should succeed. Output:`n$($first.Output)"
        Assert-Equal 2 @([IO.File]::ReadAllLines($peerScanLog)).Count 'One peer-install round should require two dependency scans'
        $npmCalls = [IO.File]::ReadAllText($npmLog)
        $nodeCalls = [IO.File]::ReadAllText($nodeLog)
        Assert-Match $npmCalls '(?m)^install .*--legacy-peer-deps .*@deepseek-ai/dsh@0\.1\.0-rc\.8' 'The primary runtime tree should use the proven npm resolution mode'
        Assert-Match $npmCalls '@deepseek-ai/cordis-plugin-group@(?:\^)?1\.0\.1' 'A missing required peer should be installed explicitly'
        Assert-NotMatch $npmCalls '@deepseek-ai/optional-monitor@' 'An optional peer must not be installed automatically'
        Assert-Match $nodeCalls '@deepseek-ai\\dsh\\lib\\bin\.js web' 'The prepared DSH entrypoint should receive the requested argument'
        $ready = Get-Content -LiteralPath (Join-Path $runtimeRoot 'dsh-runtime-ready.json') -Raw | ConvertFrom-Json
        Assert-Equal 2 $ready.SchemaVersion 'The ready marker must record the dependency-validation schema'
        Assert-Equal 'npm-ls-all' $ready.ValidatedBy 'The ready marker must identify the complete npm dependency audit'

        $callsBeforeReuse = @([IO.File]::ReadAllLines($npmLog)).Count
        $scansBeforeReuse = @([IO.File]::ReadAllLines($peerScanLog)).Count
        $second = Invoke-Runtime -TrackPeerScans
        Assert-Equal 0 $second.ExitCode "A ready runtime should be reusable. Output:`n$($second.Output)"
        $callsAfterReuse = @([IO.File]::ReadAllLines($npmLog)).Count
        Assert-Equal $callsBeforeReuse $callsAfterReuse 'A ready immutable version should not run npm again'
        $scansAfterReuse = @([IO.File]::ReadAllLines($peerScanLog)).Count
        Assert-Equal $scansBeforeReuse $scansAfterReuse 'A ready immutable runtime must not scan package metadata again'
    }

    Invoke-Test 'NoOpen appends the DSH browser flag exactly once' {
        [IO.File]::WriteAllText($nodeLog, '', [Text.Encoding]::ASCII)

        $result = Invoke-Runtime -NoOpen

        Assert-Equal 0 $result.ExitCode "NoOpen runtime should succeed. Output:`n$($result.Output)"
        $nodeCall = [IO.File]::ReadAllText($nodeLog)
        Assert-Match $nodeCall '@deepseek-ai\\dsh\\lib\\bin\.js web --no-open' 'DSH must receive --no-open'
        Assert-Equal 1 ([regex]::Matches($nodeCall, '--no-open').Count) 'DSH must receive --no-open exactly once'
    }

    Invoke-Test 'repairs the known React 19 peer conflict before marking the runtime ready' {
        $conflictRuntime = Join-Path $profileRoot 'dsh-launch\runtime-react-conflict'
        $logStart = if (Test-Path -LiteralPath $npmLog) { (Get-Item -LiteralPath $npmLog).Length } else { 0 }
        $result = Invoke-Runtime -SelectedRuntimeRoot $conflictRuntime -PeerMode 'incompatible-react'
        Assert-Equal 0 $result.ExitCode "A compatible React pair should repair the published rc.8 graph. Output:`n$($result.Output)"
        $newCalls = [IO.File]::ReadAllText($npmLog).Substring([int]$logStart)
        Assert-Match $newCalls 'react@18\.3\.1' 'The repair must downgrade React to the compatible supported major'
        Assert-Match $newCalls 'react-dom@18\.3\.1' 'React and ReactDOM must remain on the same compatible version'
        $lsCalls = [regex]::Matches($newCalls, '(?m)^ls ').Count
        Assert-Equal 2 $lsCalls 'The incompatible graph must be audited before and after repair'
        $ready = Get-Content -LiteralPath (Join-Path $conflictRuntime 'dsh-runtime-ready.json') -Raw | ConvertFrom-Json
        Assert-Equal 2 $ready.SchemaVersion 'An invalid graph must never receive a legacy existence-only ready marker'
    }

    Invoke-Test 'keeps unknown npm audit failures fatal and writes their diagnostics' {
        $unknownRuntime = Join-Path $profileRoot 'dsh-launch\runtime-unknown-audit'
        $result = Invoke-Runtime -SelectedRuntimeRoot $unknownRuntime -PeerMode 'unknown-audit-error'

        Assert-Equal 1 $result.ExitCode "An unknown dependency problem must fail. Output:`n$($result.Output)"
        $auditPath = Join-Path $unknownRuntime 'dsh-dependency-audit.log'
        Assert-Equal $true (Test-Path -LiteralPath $auditPath) 'An unknown audit failure must retain a diagnostic log'
        Assert-Match (Get-Content -LiteralPath $auditPath -Raw) 'missing: unknown-package@1\.0\.0' 'The audit log must retain npm details'
        Assert-Equal $false (Test-Path -LiteralPath (Join-Path $unknownRuntime 'dsh-runtime-ready.json')) 'A failed audit must not mark the runtime ready'
    }

    Invoke-Test 'serializes concurrent users of the shared runtime' {
        [IO.File]::WriteAllText($nodeLog, '', [Text.Encoding]::ASCII)
        $processes = @()
        try {
            foreach ($delay in @('2', '')) {
                $startInfo = [Diagnostics.ProcessStartInfo]::new()
                $startInfo.FileName = 'powershell.exe'
                $startInfo.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$runtimeScript`" -Version 0.1.0-rc.8 -RuntimeRoot `"$runtimeRoot`" -DshArguments web"
                $startInfo.UseShellExecute = $false
                $startInfo.RedirectStandardOutput = $true
                $startInfo.RedirectStandardError = $true
                $startInfo.EnvironmentVariables['PATH'] = "$fakeBin;$env:PATH"
                $startInfo.EnvironmentVariables['USERPROFILE'] = $profileRoot
                $startInfo.EnvironmentVariables['DSH_TEST_NPM_LOG'] = $npmLog
                $startInfo.EnvironmentVariables['DSH_TEST_NODE_LOG'] = $nodeLog
                $startInfo.EnvironmentVariables['DSH_TEST_NODE_DELAY'] = $delay
                $processes += [Diagnostics.Process]::Start($startInfo)
                if ($processes.Count -eq 1) {
                    for ($attempt = 0; $attempt -lt 30 -and @([IO.File]::ReadAllLines($nodeLog)).Count -eq 0; $attempt++) {
                        Start-Sleep -Milliseconds 100
                    }
                }
            }

            Start-Sleep -Milliseconds 300
            Assert-Equal 1 @([IO.File]::ReadAllLines($nodeLog)).Count 'Only one process may execute from the shared runtime at a time'
            foreach ($process in $processes) {
                Assert-Equal $true $process.WaitForExit(10000) 'Concurrent runtime test process did not finish'
                Assert-Equal 0 $process.ExitCode "Serialized runtime process failed: $($process.StandardError.ReadToEnd())"
            }
        } finally {
            foreach ($process in $processes) {
                if ($process -and -not $process.HasExited) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
            }
        }
    }

    Invoke-Test 'rejects a runtime root outside the launcher-owned profile directory' {
        $unsafeRoot = Join-Path $testRoot 'not-launcher-owned'
        $sentinel = Join-Path $unsafeRoot 'sentinel.txt'
        New-Item -ItemType Directory -Force -Path $unsafeRoot | Out-Null
        Set-Content -LiteralPath $sentinel -Value 'keep' -Encoding ASCII

        $result = Invoke-UnsafeRuntime -UnsafeRoot $unsafeRoot
        Assert-Equal 1 $result.ExitCode "An unsafe runtime root should be rejected. Output:`n$($result.Output)"
        Assert-Equal $true (Test-Path -LiteralPath $sentinel) 'Rejecting an unsafe root must not delete its existing files'
    }

    Write-Host "All $script:Passed runtime preparation behavior tests passed."
} finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}

exit 0
