# DSH Runtime Startup Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the managed DSH runtime recover from npm 11's known React peer conflict under Windows PowerShell 5.1, reduce redundant peer scans, and prove real background startup reaches HTTP readiness.

**Architecture:** Keep runtime preparation in `run-dsh.ps1`. Narrowly capture an expected nonzero native npm audit without weakening script-wide error handling, then reuse only a still-valid peer scan result. Extend the existing process-level PowerShell tests so production code is exercised through Windows PowerShell 5.1 with realistic npm stdout, stderr, and exit behavior.

**Tech Stack:** Windows PowerShell 5.1, Windows CMD, Node.js 24, npm 11, standalone PowerShell behavior tests.

## Global Constraints

- Preserve DSH version selection, `%USERPROFILE%\dsh-launch\runtime`, port `3080`, browser opening, startup locks, and launch-state behavior.
- Keep unknown npm dependency failures fatal and write `dsh-dependency-audit.log`.
- Keep at most five explicit peer-install rounds and perform a final scan when the fifth install makes the previous scan stale.
- Do not move npm installation into install/upgrade, prebundle runtime packages, or change npm `allow-scripts` policy.
- Run production and regression behavior under `powershell.exe`, not only PowerShell 7.
- Preserve unrelated changes already present in the dirty worktree.

## File Structure

- Modify `run-dsh.ps1`: capture npm audit stderr safely and reuse valid peer scan results.
- Modify `tests/runtime-preparation-behavior.Tests.ps1`: model real npm 11 stderr, cover unknown audit failures, and count real peer scans through a test-only wrapper.
- Create `docs/superpowers/plans/2026-08-21-dsh-runtime-startup-fix.md`: record this implementation and verification sequence.

---

### Task 1: Capture Expected npm Audit Failures Under Windows PowerShell 5.1

**Files:**

- Modify: `tests/runtime-preparation-behavior.Tests.ps1:108`
- Modify: `tests/runtime-preparation-behavior.Tests.ps1:205`
- Modify: `run-dsh.ps1:111`

**Interfaces:**

- Consumes: `npm.cmd ls --prefix <runtime> --all --json` stdout, stderr, and process exit code.
- Produces: `Invoke-NpmDependencyAudit` object with `ExitCode: int` and `Output: string`.
- Preserves: `Repair-KnownPeerConflict([pscustomobject]$Audit)` and `Write-AuditFailure([pscustomobject]$Audit)` contracts.

- [ ] **Step 1: Make the fake incompatible audit reproduce npm 11 stderr**

Change the fake npm `ls` branch to emit both streams before returning `1`:

```powershell
if ($env:DSH_TEST_PEER_MODE -eq 'incompatible-react' -and -not (Test-Path -LiteralPath $repairMarker)) {
    [Console]::Error.WriteLine('npm error code ELSPROBLEMS')
    Write-Output '{"name":"runtime","problems":["invalid: react@19.2.8 node_modules/react"]}'
    exit 1
}
```

- [ ] **Step 2: Add an unknown-audit fixture and fatal-error assertion**

Add this fake npm branch before the successful audit response:

```powershell
if ($env:DSH_TEST_PEER_MODE -eq 'unknown-audit-error') {
    [Console]::Error.WriteLine('npm error code ELSPROBLEMS')
    Write-Output '{"name":"runtime","problems":["missing: unknown-package@1.0.0"]}'
    exit 1
}
```

Add a focused behavior test:

```powershell
Invoke-Test 'keeps unknown npm audit failures fatal and writes their diagnostics' {
    $unknownRuntime = Join-Path $profileRoot 'dsh-launch\runtime-unknown-audit'
    $result = Invoke-Runtime -SelectedRuntimeRoot $unknownRuntime -PeerMode 'unknown-audit-error'

    Assert-Equal 1 $result.ExitCode "An unknown dependency problem must fail. Output:`n$($result.Output)"
    $auditPath = Join-Path $unknownRuntime 'dsh-dependency-audit.log'
    Assert-Equal $true (Test-Path -LiteralPath $auditPath) 'An unknown audit failure must retain a diagnostic log'
    Assert-Match (Get-Content -LiteralPath $auditPath -Raw) 'missing: unknown-package@1\.0\.0' 'The audit log must retain npm details'
    Assert-Equal $false (Test-Path -LiteralPath (Join-Path $unknownRuntime 'dsh-runtime-ready.json')) 'A failed audit must not mark the runtime ready'
}
```

- [ ] **Step 3: Run the focused tests and verify RED**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\runtime-preparation-behavior.Tests.ps1
```

Expected: FAIL in the incompatible-React or unknown-audit case because real stderr becomes `NativeCommandError` before repair or audit-log handling runs.

- [ ] **Step 4: Implement scoped audit error handling**

Replace `Invoke-NpmDependencyAudit` with:

```powershell
function Invoke-NpmDependencyAudit {
    $npmCommand = Get-Command 'npm.cmd' -CommandType Application -ErrorAction Stop
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $auditOutput = @(& $npmCommand.Source ls --prefix $RuntimeRoot --all --json 2>&1)
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        Output = [string]($auditOutput -join [Environment]::NewLine)
    }
}
```

- [ ] **Step 5: Run the focused tests and verify GREEN**

Run the same focused test command.

Expected: all runtime preparation tests pass; the incompatible graph performs two `ls` calls and installs React 18.3.1, while the unknown graph exits `1`, writes an audit log, and writes no ready marker.

- [ ] **Step 6: Review and commit the correctness change**

Run:

```powershell
git diff --check -- run-dsh.ps1 tests/runtime-preparation-behavior.Tests.ps1
git diff -- run-dsh.ps1 tests/runtime-preparation-behavior.Tests.ps1
```

Confirm only approved runtime and test behavior changed, then commit those exact paths:

```powershell
git add -- run-dsh.ps1 tests/runtime-preparation-behavior.Tests.ps1
git commit -m "fix: handle npm audit errors during DSH startup"
```

### Task 2: Reuse Valid Peer Scan Results

**Files:**

- Modify: `tests/runtime-preparation-behavior.Tests.ps1:5`
- Modify: `tests/runtime-preparation-behavior.Tests.ps1:35`
- Modify: `tests/runtime-preparation-behavior.Tests.ps1:185`
- Modify: `run-dsh.ps1:187`

**Interfaces:**

- Consumes: the real `Get-MissingRequiredPeers` call path and its hashtable result.
- Produces: two scans for cold preparation with one install round, one scan for an existing unmarked runtime with no missing peers, and zero scans for ready-runtime reuse.
- Preserves: a final scan after loop exhaustion when the fifth peer installation invalidates the previous result.

- [ ] **Step 1: Add a test-only scan-count wrapper**

Add paths near the existing test fixtures:

```powershell
$peerScanLog = Join-Path $testRoot 'peer-scan.log'
$runtimeHarness = Join-Path $testRoot 'invoke-runtime-with-scan-log.ps1'
```

Create this wrapper in the test setup using the existing UTF-8 file-writing pattern:

```powershell
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
```

Extend `Invoke-Runtime` with `[switch]$TrackPeerScans`. Save and restore `DSH_TEST_PEER_SCAN_LOG` with the other environment values. When tracking is enabled, invoke the wrapper instead of invoking `run-dsh.ps1` directly:

```powershell
$scriptPath = if ($TrackPeerScans) { $runtimeHarness } else { $runtimeScript }
$scriptArguments = if ($TrackPeerScans) {
    @('-RuntimeScript', $runtimeScript, '-Version', '0.1.0-rc.8', '-RuntimeRoot', $SelectedRuntimeRoot, '-DshArguments', 'web')
} else {
    @('-Version', '0.1.0-rc.8', '-RuntimeRoot', $SelectedRuntimeRoot, '-DshArguments', 'web')
}
$output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath @scriptArguments 2>&1
```

- [ ] **Step 2: Add cold and ready-runtime scan assertions**

Update the first runtime behavior test:

```powershell
[IO.File]::WriteAllText($peerScanLog, '', [Text.Encoding]::ASCII)
$first = Invoke-Runtime -TrackPeerScans
Assert-Equal 0 $first.ExitCode "Runtime preparation should succeed. Output:`n$($first.Output)"
Assert-Equal 2 @([IO.File]::ReadAllLines($peerScanLog)).Count 'One peer-install round should require two dependency scans'

$scansBeforeReuse = @([IO.File]::ReadAllLines($peerScanLog)).Count
$second = Invoke-Runtime -TrackPeerScans
Assert-Equal 0 $second.ExitCode "A ready runtime should be reusable. Output:`n$($second.Output)"
$scansAfterReuse = @([IO.File]::ReadAllLines($peerScanLog)).Count
Assert-Equal $scansBeforeReuse $scansAfterReuse 'A ready immutable runtime must not scan package metadata again'
```

- [ ] **Step 3: Run the focused tests and verify RED**

Run the runtime preparation test.

Expected: FAIL with an actual scan count of `3` instead of `2`; ready reuse should already add zero scans.

- [ ] **Step 4: Retain only a valid final scan result**

Replace the peer loop with:

```powershell
$remainingPeers = $null
for ($round = 0; $round -lt 5; $round++) {
    $remainingPeers = Get-MissingRequiredPeers
    if ($remainingPeers.Count -eq 0) { break }

    $peerSpecs = @($remainingPeers.GetEnumerator() | Sort-Object Key | ForEach-Object {
        $_.Key + '@' + $_.Value
    })
    Write-Output "Installing $($peerSpecs.Count) required DSH peer dependencies..."
    Invoke-NpmInstall -PackageSpecs $peerSpecs

    # Installation invalidates the scan that selected these peers.
    $remainingPeers = $null
}

if ($null -eq $remainingPeers) {
    $remainingPeers = Get-MissingRequiredPeers
}
```

Keep the existing `$remainingPeers.Count -gt 0` failure immediately after this block.

- [ ] **Step 5: Run the focused tests and verify GREEN**

Run the runtime preparation test.

Expected: all tests pass; cold preparation reports exactly two scans and ready reuse reports no additional scan.

- [ ] **Step 6: Review and commit the scan optimization**

Run `git diff --check` and inspect the exact two files, then commit:

```powershell
git add -- run-dsh.ps1 tests/runtime-preparation-behavior.Tests.ps1
git commit -m "perf: avoid redundant DSH peer scans"
```

### Task 3: Full Regression And Real Startup Verification

**Files:**

- Verify: `run-dsh.ps1`
- Verify: `tests/*.Tests.ps1`
- Verify: `%USERPROFILE%\dsh-launch\runtime\dsh-runtime-ready.json`
- Verify: `%USERPROFILE%\dsh-launch\dsh-background.log`

**Interfaces:**

- Consumes: the complete repository test set and the real installed Node/npm environment.
- Produces: evidence that `deepseek -b` reaches `RUNNING`, serves HTTP on port 3080, reuses the ready marker, and cleans up after verification.

- [ ] **Step 1: Run every standalone behavior test**

Run the same loop used by CI:

```powershell
$tests = @(Get-ChildItem .\tests -Filter '*.Tests.ps1' | Sort-Object Name)
foreach ($test in $tests) {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $test.FullName
    if ($LASTEXITCODE -ne 0) { throw "Test failed: $($test.Name)" }
}
```

Expected: every test file exits `0`; the runtime suite reports all focused cases, including the new unknown-audit case.

- [ ] **Step 2: Run repository hygiene checks**

```powershell
git diff --check
Get-CimInstance Win32_Process | Where-Object {
    $_.CommandLine -match 'dsh-runtime-tests-|invoke-runtime-with-scan-log'
}
```

Expected: no whitespace errors and no test runtime processes remain.

- [ ] **Step 3: Start the real runtime and wait for a terminal state**

First ensure an old instance is not listening, then submit startup and poll for at most 180 seconds:

```powershell
deepseek --stop
$firstStart = [Diagnostics.Stopwatch]::StartNew()
deepseek -b
do {
    Start-Sleep -Seconds 1
    $status = [string](@(deepseek --status) -join [Environment]::NewLine)
} while ($firstStart.Elapsed.TotalSeconds -lt 180 -and $status -match '^STARTING')
$firstStart.Stop()
Write-Host "FIRST_READY_SECONDS=$([math]::Round($firstStart.Elapsed.TotalSeconds, 3))"
Write-Host $status
if ($status -notmatch '^RUNNING') { throw 'Real DSH startup did not reach RUNNING' }
```

Expected: the known React conflict is repaired, startup reaches `RUNNING`, and the log no longer ends at `NativeCommandError`.

- [ ] **Step 4: Verify HTTP readiness, marker contents, and dependency graph**

```powershell
$response = Invoke-WebRequest -Uri 'http://127.0.0.1:3080' -UseBasicParsing -TimeoutSec 5
if ($response.StatusCode -lt 200 -or $response.StatusCode -ge 500) { throw "Unexpected HTTP status $($response.StatusCode)" }

$markerPath = Join-Path $env:USERPROFILE 'dsh-launch\runtime\dsh-runtime-ready.json'
$marker = Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json
if ($marker.SchemaVersion -ne 2 -or $marker.ValidatedBy -ne 'npm-ls-all') { throw 'Invalid runtime ready marker' }

& npm.cmd ls --prefix (Split-Path -Parent $markerPath) --all --json | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'The repaired real dependency graph is still invalid' }
```

- [ ] **Step 5: Stop, restart from the ready runtime, and measure warm startup**

```powershell
deepseek --stop
$backgroundLog = Join-Path $env:USERPROFILE 'dsh-launch\dsh-background.log'
$warmLogStart = if (Test-Path -LiteralPath $backgroundLog) {
    @(Get-Content -LiteralPath $backgroundLog -Encoding UTF8).Count
} else {
    0
}
$warmStart = [Diagnostics.Stopwatch]::StartNew()
deepseek -b
do {
    Start-Sleep -Milliseconds 500
    $warmStatus = [string](@(deepseek --status) -join [Environment]::NewLine)
} while ($warmStart.Elapsed.TotalSeconds -lt 30 -and $warmStatus -match '^STARTING')
$warmStart.Stop()
Write-Host "WARM_READY_SECONDS=$([math]::Round($warmStart.Elapsed.TotalSeconds, 3))"
Write-Host $warmStatus
if ($warmStatus -notmatch '^RUNNING') { throw 'Warm DSH startup did not reach RUNNING within 30 seconds' }

$warmLog = [string](@(Get-Content -LiteralPath $backgroundLog -Encoding UTF8 | Select-Object -Skip $warmLogStart) -join [Environment]::NewLine)
if ($warmLog -match 'Preparing DeepSeek Harness runtime|Validating existing DeepSeek Harness runtime|Installing \d+ required DSH peer dependencies|npm (?:warn|error)') {
    throw "Warm startup unexpectedly ran npm preparation:`n$warmLog"
}
```

Expected: warm startup reaches `RUNNING` within 30 seconds and the background log does not contain new npm installation or audit output for that launch.

- [ ] **Step 6: Clean up and perform the final verification gate**

```powershell
deepseek --stop
$listener = Get-NetTCPConnection -LocalPort 3080 -State Listen -ErrorAction SilentlyContinue
if ($listener) { throw "Port 3080 is still listening on PID $($listener.OwningProcess)" }

$leftovers = @(Get-CimInstance Win32_Process | Where-Object {
    $_.CommandLine -match 'background-run|run-dsh|open-when-ready|dsh-runtime-tests-'
})
if ($leftovers.Count -gt 0) { throw "Launcher processes remain: $($leftovers.ProcessId -join ', ')" }

git diff --check
git status --short
```

Expected: port 3080 is closed, no launcher/test processes remain, changed files are limited to the approved implementation and pre-existing user work, and all previous verification evidence remains current.

## Review Checklist

- A realistic npm stderr regression was observed failing before production code changed.
- `Invoke-NpmDependencyAudit` restores its caller's error preference on every path.
- Missing npm is still a command-resolution failure; only a real npm process exit is classified as audit data.
- Known React conflict repair passes; unknown audit problems remain fatal and retain logs.
- Scan count is proven through the real production function call, not a source-text assertion.
- The fifth peer-install round still receives a final validation scan.
- Full tests, first real startup, HTTP readiness, warm reuse, and cleanup all have fresh command output.
