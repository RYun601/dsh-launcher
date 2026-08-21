# DSH Startup Performance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reduce prepared-runtime background startup from the measured 11.4-second median to no more than 8 seconds while preserving startup locking, status, failure logs, update behavior, and browser opening.

**Architecture:** Normal startup selects a validated launcher-owned runtime without contacting npm, then a single PowerShell runner owns the token, gate, state, monitor, DSH child, and cleanup lifecycle. DSH receives `--no-open`; the readiness monitor becomes the sole browser owner and polls every 200 milliseconds. Explicit update and upgrade operations retain registry-backed version discovery.

**Tech Stack:** Windows PowerShell 5.1, CMD, .NET `TcpClient`, npm/node, existing standalone PowerShell behavior-test harnesses.

## Global Constraints

- Preserve all public `deepseek` commands, aliases, port `3080`, log path, startup state, lock semantics, update flow, and stop-process ownership checks.
- Do not modify `%USERPROFILE%\.dsh`, DSH profiles, MCP configuration, credentials, global npm packages, or the installed DSH package source.
- Normal startup may use the network only when no usable launcher-owned runtime exists.
- `deepseek --update` and `deepseek --upgrade` must continue to query npm dist-tags.
- All PowerShell production scripts must parse and run under Windows PowerShell 5.1.
- Functional tests must use isolated profile/runtime directories and must not touch the user's real npm cache or DSH profile.
- Wall-clock performance thresholds belong only to the explicit local benchmark, not the CI behavior suite.
- The worktree already contains user-owned changes in implementation files. Do not create implementation commits that would absorb unrelated edits; use diff checkpoints after each task. New plan/spec documents may be committed independently.

---

## File Structure

- Create `background-run.ps1`: authoritative long-lived background lifecycle and cleanup owner.
- Create `tests/version-resolution-behavior.Tests.ps1`: isolated local-first versus registry-backed version-resolution contract.
- Create `tests/open-when-ready-behavior.Tests.ps1`: isolated readiness polling and single browser-open contract.
- Modify `resolve-dsh-version.ps1`: validated local-first mode plus injectable runtime root.
- Modify `start-background.ps1`: optional explicit target version, local-first fallback, lightweight port probe, and direct PowerShell runner creation.
- Modify `background-run.cmd`: compatibility wrapper that forwards to `background-run.ps1`.
- Modify `run-dsh.ps1`: explicit `-NoOpen` switch that appends `--no-open` exactly once.
- Modify `open-when-ready.ps1`: configurable 200 millisecond poll interval.
- Modify `deepseek.cmd` and `start-deepseek-harness.bat`: local-first foreground resolution and `-NoOpen`.
- Modify `upgrade-dsh.ps1`: pass the registry-resolved target version into `start-background.ps1`.
- Modify `tests/start-background-harness.ps1` and `tests/startup-behavior.Tests.ps1`: direct runner, token/gate, early-exit, and repeated-start behavior.
- Modify `tests/runtime-preparation-behavior.Tests.ps1`: no-browser argument behavior.
- Modify `release-files.txt`, `tests/release-package-behavior.Tests.ps1`, and `.github/workflows/check.yml`: package and validate the new runner.
- Modify `README.md` and `README.en.md`: document prepared-version startup and explicit release discovery.

### Task 1: Add Local-First Version Resolution

**Files:**
- Create: `tests/version-resolution-behavior.Tests.ps1`
- Modify: `resolve-dsh-version.ps1`

**Interfaces:**
- Produces: `resolve-dsh-version.ps1 [-PreferLocalRuntime] [-RuntimeRoot <absolute path>]`.
- Returns: exactly one selected version on stdout, or no output when neither local metadata nor npm can provide one.
- Local selection order: valid ready marker and matching package, then valid installed package, then npm dist-tags.
- Existing no-switch invocation remains registry-backed for `update-check.ps1` and `upgrade-dsh.ps1`.

- [ ] **Step 1: Write the isolated resolver behavior test**

Create a fake `npm.cmd` that appends its arguments to `$env:DSH_TEST_NPM_LOG` and returns `{"latest":"0.1.0-rc.9","next":"0.1.0-rc.10"}`. Add helpers that create `node_modules\@deepseek-ai\dsh\lib\bin.js`, package metadata, and an optional ready marker beneath an isolated runtime.

The required assertions are:

```powershell
Invoke-Test 'prepared runtime wins without invoking npm' {
    New-TestRuntime -Version '0.1.0-rc.8' -Ready
    $result = Invoke-Resolver -PreferLocalRuntime
    Assert-Equal '0.1.0-rc.8' $result.Output.Trim() 'Prepared version should be selected'
    Assert-Equal '' (Read-NpmLog) 'Prepared startup must not contact npm'
}

Invoke-Test 'installed runtime without marker is reused without invoking npm' {
    Reset-TestRuntime
    New-TestRuntime -Version '0.1.0-rc.7'
    $result = Invoke-Resolver -PreferLocalRuntime
    Assert-Equal '0.1.0-rc.7' $result.Output.Trim() 'Installed version should be revalidated locally'
    Assert-Equal '' (Read-NpmLog) 'Local repair must not require registry discovery'
}

Invoke-Test 'invalid local installation falls back to published tags' {
    Reset-TestRuntime
    New-TestRuntime -Version '0.1.0-rc.7' -OmitEntrypoint
    $result = Invoke-Resolver -PreferLocalRuntime
    Assert-Equal '0.1.0-rc.10' $result.Output.Trim() 'Invalid local metadata must fall back to npm'
    Assert-Match (Read-NpmLog) '^view @deepseek-ai/dsh dist-tags --json' 'Fallback must query dist-tags'
}

Invoke-Test 'registry mode ignores a prepared runtime' {
    Reset-NpmLog
    $result = Invoke-Resolver
    Assert-Equal '0.1.0-rc.10' $result.Output.Trim() 'Explicit release discovery must use npm'
    Assert-Match (Read-NpmLog) '^view @deepseek-ai/dsh dist-tags --json' 'Registry mode must query dist-tags'
}
```

- [ ] **Step 2: Run the resolver test and verify RED**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\version-resolution-behavior.Tests.ps1
```

Expected: FAIL because `resolve-dsh-version.ps1` does not accept `-PreferLocalRuntime` or `-RuntimeRoot`, and the fake npm log shows a registry query for prepared runtime cases.

- [ ] **Step 3: Implement validated local runtime discovery**

Add parameters and a local metadata helper before the existing npm lookup:

```powershell
param(
    [switch]$PreferLocalRuntime,
    [string]$RuntimeRoot
)

if (-not $RuntimeRoot) {
    $RuntimeRoot = Join-Path $env:USERPROFILE 'dsh-launch\runtime'
}

function Get-InstalledRuntimeVersion {
    param([string]$Root, [switch]$RequireReadyMarker)

    $dshRoot = Join-Path $Root 'node_modules\@deepseek-ai\dsh'
    $packagePath = Join-Path $dshRoot 'package.json'
    $entrypoint = Join-Path $dshRoot 'lib\bin.js'
    if (-not (Test-Path -LiteralPath $packagePath) -or -not (Test-Path -LiteralPath $entrypoint)) { return '' }
    try { $package = Get-Content -LiteralPath $packagePath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return '' }
    if ([string]$package.name -ne '@deepseek-ai/dsh' -or -not [string]$package.version) { return '' }
    if (-not $RequireReadyMarker) { return [string]$package.version }

    $markerPath = Join-Path $Root 'dsh-runtime-ready.json'
    if (-not (Test-Path -LiteralPath $markerPath)) { return '' }
    try { $marker = Get-Content -LiteralPath $markerPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return '' }
    if ([int]$marker.SchemaVersion -ne 2 -or [string]$marker.ValidatedBy -ne 'npm-ls-all') { return '' }
    if ([string]$marker.Version -ne [string]$package.version) { return '' }
    return [string]$package.version
}

if ($PreferLocalRuntime) {
    $selected = Get-InstalledRuntimeVersion -Root $RuntimeRoot -RequireReadyMarker
    if (-not $selected) { $selected = Get-InstalledRuntimeVersion -Root $RuntimeRoot }
    if ($selected) { Write-Output $selected; exit 0 }
}
```

Retain the current `dsh-version.ps1` comparator and npm dist-tag lookup unchanged after this block.

- [ ] **Step 4: Run resolver and version-ordering tests and verify GREEN**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\version-resolution-behavior.Tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\version-ordering-behavior.Tests.ps1
```

Expected: both exit `0`; prepared and installed cases leave the npm log empty, while registry cases select `0.1.0-rc.10`.

- [ ] **Step 5: Review the Task 1 diff checkpoint**

Run:

```powershell
git diff --check -- resolve-dsh-version.ps1 tests/version-resolution-behavior.Tests.ps1
git diff -- resolve-dsh-version.ps1 tests/version-resolution-behavior.Tests.ps1
```

Expected: no whitespace errors and no changes outside resolver behavior and its isolated test. Do not commit because `resolve-dsh-version.ps1` is part of the shared dirty worktree.

### Task 2: Replace The CMD Critical Path With A PowerShell Runner

**Files:**
- Create: `background-run.ps1`
- Modify: `background-run.cmd`
- Modify: `start-background.ps1`
- Modify: `upgrade-dsh.ps1`
- Modify: `tests/start-background-harness.ps1`
- Modify: `tests/startup-behavior.Tests.ps1`

**Interfaces:**
- Produces: `start-background.ps1 [-WaitForReady] [-TimeoutSeconds <int>] [-Version <semver>] [-Port <int>]`.
- Produces: `background-run.ps1 -Version <semver> [-LaunchRoot <path>] [-StartupToken <token>] [-CoordinatorGate <path>] [-SuppressBrowserMonitor]`.
- The coordinator resolves `-Version` locally only when the caller did not supply it.
- `upgrade-dsh.ps1` supplies the registry-resolved `-Version`, so an explicit upgrade cannot fall back to an older prepared runtime.
- The runner PID is the lock owner, state owner, and readiness monitor parent.

- [ ] **Step 1: Change coordinator tests to demand the direct PowerShell runner**

Update the isolated profile fixture in `tests/start-background-harness.ps1` to contain a valid prepared runtime for `0.1.0-rc.8`, then replace the existing CMD-runner assertions with:

```powershell
Assert-Match $result.ProcessLog 'powershell(?:\.exe)?.*background-run\.ps1.*-Version 0\.1\.0-rc\.8' `
    'Immediate mode must launch the direct PowerShell runner with the selected local version'
Assert-NotMatch $result.ProcessLog 'background-run\.cmd' `
    'Normal startup must not retain the CMD runner on its critical path'
Assert-Match $result.ProcessLog 'STARTUP_TOKEN=([0-9a-f]{32})' `
    'The direct runner must inherit the coordinator token'
```

Extend the fake `Start-Process` log with `GATE=<path>` and preserve the existing `LOCK_PRESENT=True` assertion. Update the expected immediate submission budget only after measuring the fake harness; keep it deterministic and no higher than the existing three-second limit.

- [ ] **Step 2: Add real runner lifecycle and stress tests**

Adapt `Invoke-ReservedRealBackgroundRunner` to launch the system Windows PowerShell executable directly with `-File background-run.ps1`. Reserve a token with the test coordinator PID, start the runner with a gate path, transfer ownership to `$process.Id`, write `GO`, then assert:

```powershell
Assert-Equal ([string]$result.RunnerPid) $result.LockOwnerDuringRun 'Runner must own the transferred lock'
Assert-Equal ([string]$result.RunnerPid) $result.StateOwnerDuringRun 'Runner must own STARTING state'
Assert-Match $result.MonitorCommandLine "-ParentPid $($result.RunnerPid)" 'Monitor must follow the runner'
Assert-Match $result.Log '(?m)^Runner PID: \d+\s*$' 'Runner must log before DSH work starts'
Assert-NotMatch $result.Log 'Get-CimInstance Win32_Process|resolve-dsh-version' 'Runner must not rediscover PID or version'
Assert-Equal $false (Test-Path -LiteralPath $result.LockPath) 'Completed child must release the startup lock'
```

Add a ten-iteration synthetic loop using an immediate fake node child. Each iteration must observe the runner's first log record, process exit, and absent lock before starting the next iteration. This reproduces the previously observed submitted-runner disappearance without touching the real service.

- [ ] **Step 3: Run startup tests and verify RED**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\startup-behavior.Tests.ps1
```

Expected: FAIL because `background-run.ps1` is missing and `start-background.ps1` still launches `background-run.cmd` without a preselected local version.

- [ ] **Step 4: Implement `background-run.ps1` lifecycle ownership**

Implement these parameters and lifecycle stages:

```powershell
param(
    [Parameter(Mandatory = $true)][string]$Version,
    [string]$LaunchRoot = (Join-Path $env:USERPROFILE 'dsh-launch'),
    [string]$StartupToken = $env:DSH_STARTUP_TOKEN,
    [string]$CoordinatorGate = $env:DSH_COORDINATOR_GATE,
    [switch]$SuppressBrowserMonitor,
    [ValidateRange(1, 86400)][int]$TimeoutSeconds = 900
)
```

The implementation must:

```powershell
$log = Join-Path $LaunchRoot 'dsh-background.log'
$stateHelper = Join-Path $PSScriptRoot 'dsh-launch-state.ps1'
New-Item -ItemType Directory -Force -Path $LaunchRoot | Out-Null
Add-Content -LiteralPath $log -Encoding UTF8 -Value ('===== {0:yyyy-MM-dd HH:mm:ss.fff} =====' -f (Get-Date))
Add-Content -LiteralPath $log -Encoding UTF8 -Value "Runner PID: $PID"
```

Wait up to 60 seconds for a coordinator gate when one is supplied. Accept only exact ASCII `GO`; delete the gate after reading it; exit without DSH on `CANCEL`. When no startup token exists, generate one and acquire the lock directly for compatibility-wrapper invocation. When a token exists, call `AcquireStartupLock` with `$PID`, the same token, and `-TransferOwnership`; accept only `ACQUIRED` or `OWNED` output.

Write `STARTING`, launch the monitor with `$PID` as both `ParentPid` and `OwnerPid`, then invoke the DSH child:

```powershell
$runArguments = @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass',
    '-File', (Join-Path $PSScriptRoot 'run-dsh.ps1'),
    '-Version', $Version,
    '-DshArguments', 'web'
)
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" @runArguments *>> $log
$dshExitCode = $LASTEXITCODE
```

Track `$ownsStartupLock` and `$dshStarted` separately. Set the first only after
the runner receives `ACQUIRED` or `OWNED`, and set the second immediately
before invoking the DSH child. In `finally`, call `RecordStartupExit` only
when `$dshStarted` is true, and call `ReleaseStartupLock` only when
`$ownsStartupLock` is true. Both calls use the same token.
`RecordStartupExit` already preserves a `RUNNING` state and converts only
`STARTING` into `FAILED`. A cancelled gate therefore cannot manufacture a DSH
failure state or release a lock the runner never owned.

- [ ] **Step 5: Convert `background-run.cmd` into the compatibility wrapper**

Keep the file ASCII-only. Resolve a local-first version only when `DSH_TARGET` is absent, then forward existing environment variables:

```bat
@echo off
setlocal
if not defined DSH_TARGET for /f "delims=" %%v in ('powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0resolve-dsh-version.ps1" -PreferLocalRuntime') do set "DSH_TARGET=%%v"
if not defined DSH_TARGET set "DSH_TARGET=latest"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0background-run.ps1" -Version "%DSH_TARGET%"
exit /b %ERRORLEVEL%
```

- [ ] **Step 6: Make the coordinator select once and launch the direct runner**

Add `[string]$Version` and `[ValidateRange(1, 65535)][int]$Port = 3080` parameters. When `-Version` is absent, call:

```powershell
$runtimeRoot = Join-Path $launchRoot 'runtime'
$Version = [string](@(& (Join-Path $dir 'resolve-dsh-version.ps1') `
    -PreferLocalRuntime -RuntimeRoot $runtimeRoot) -join '')
if (-not $Version) { $Version = 'latest' }
```

Start `background-run.ps1` directly, passing `-Version`, `-LaunchRoot`, `-StartupToken`, `-CoordinatorGate`, and `-TimeoutSeconds`. Preserve the existing environment restoration, reservation transfer, `STARTING` write, `GO`/`CANCEL` gate protocol, immediate-return output, and `WaitForReady` behavior.

- [ ] **Step 7: Preserve explicit upgrade version selection**

Change the final upgrade call to preserve the existing `latest` fallback while
preventing local-first selection from reusing an older runtime:

```powershell
$upgradeTarget = if ($latest) { [string]$latest } else { 'latest' }
& (Join-Path $dir 'start-background.ps1') -WaitForReady -TimeoutSeconds 900 -Version $upgradeTarget
```

Add an assertion to `tests/startup-behavior.Tests.ps1` that the upgrade fake receives `start-background.ps1 ... -Version 0.1.0-rc.8` after its registry resolver output. This guards against local-first startup silently undoing an explicit upgrade.

- [ ] **Step 8: Run startup and upgrade tests and verify GREEN**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\startup-behavior.Tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\upgrade-cache-behavior.Tests.ps1
```

Expected: both exit `0`; direct runner, token transfer, first-log, ten-cycle stress, early failure, duplicate startup, and explicit upgrade version assertions all pass.

- [ ] **Step 9: Review the Task 2 diff checkpoint**

Run:

```powershell
git diff --check -- background-run.ps1 background-run.cmd start-background.ps1 upgrade-dsh.ps1 tests/start-background-harness.ps1 tests/startup-behavior.Tests.ps1
git diff --stat -- background-run.ps1 background-run.cmd start-background.ps1 upgrade-dsh.ps1 tests/start-background-harness.ps1 tests/startup-behavior.Tests.ps1
```

Expected: no whitespace errors; changes remain limited to runner/coordinator behavior and tests. Do not commit shared dirty files.

### Task 3: Establish One Browser Owner And A Lightweight Port Probe

**Files:**
- Create: `tests/open-when-ready-behavior.Tests.ps1`
- Modify: `run-dsh.ps1`
- Modify: `open-when-ready.ps1`
- Modify: `start-background.ps1`
- Modify: `deepseek.cmd`
- Modify: `start-deepseek-harness.bat`
- Modify: `tests/runtime-preparation-behavior.Tests.ps1`
- Modify: `tests/start-background-harness.ps1`
- Modify: `tests/startup-behavior.Tests.ps1`

**Interfaces:**
- Produces: `run-dsh.ps1 ... [-NoOpen]`; when present, Node receives one trailing `--no-open` unless already supplied.
- Produces: `open-when-ready.ps1 ... [-PollIntervalMilliseconds 200]` with range `50..5000`.
- Produces: `start-background.ps1 -Port <int>` for isolated port-probe tests; public default remains `3080`.

- [ ] **Step 1: Add failing no-browser runtime assertions**

Extend `Invoke-Runtime` in `tests/runtime-preparation-behavior.Tests.ps1` with `[switch]$NoOpen` and append `-NoOpen` to the external script arguments only when selected. Add:

```powershell
Invoke-Test 'NoOpen appends the DSH browser flag exactly once' {
    [IO.File]::WriteAllText($nodeLog, '', [Text.Encoding]::ASCII)
    $result = Invoke-Runtime -NoOpen
    Assert-Equal 0 $result.ExitCode "NoOpen runtime failed: $($result.Output)"
    $nodeCall = [IO.File]::ReadAllText($nodeLog)
    Assert-Match $nodeCall '@deepseek-ai\\dsh\\lib\\bin\.js web --no-open' 'DSH must receive --no-open'
    Assert-Equal 1 ([regex]::Matches($nodeCall, '--no-open').Count) 'DSH must receive --no-open once'
}
```

- [ ] **Step 2: Add a failing readiness-monitor behavior test**

Create an isolated child harness inside `tests/open-when-ready-behavior.Tests.ps1`. Its first fake `Invoke-WebRequest` throws, its second returns status `200`; fake `Start-Sleep` and `Start-Process` append to a log. Invoke the real script with `-PollIntervalMilliseconds 200` and assert:

```powershell
Assert-Match $events '(?m)^SLEEP 200$' 'Readiness retries must use the 200 ms interval'
Assert-Equal 1 ([regex]::Matches($events, '(?m)^OPEN http://127\.0\.0\.1:3080$').Count) `
    'Only one successful readiness transition may open the browser'
$state = Get-Content -LiteralPath (Join-Path $launchRoot 'dsh-startup.json') -Raw | ConvertFrom-Json
Assert-Equal 'RUNNING' $state.State 'HTTP success must record RUNNING before exit'
```

- [ ] **Step 3: Add failing lightweight-port tests**

Run `start-background.ps1` against an automatically allocated closed local port using its new `-Port` parameter. The harness logs `Get-NetTCPConnection`; assert it is absent when `.NET TcpClient` cannot connect. Add a second scenario with a temporary `TcpListener` on an allocated port and assert `Get-NetTCPConnection` is called only after TCP connects.

```powershell
Assert-NotMatch $closed.ProcessLog 'GET_NET_TCP_CONNECTION' 'Closed-port startup must avoid the networking cmdlet'
Assert-Match $occupied.ProcessLog 'GET_NET_TCP_CONNECTION' 'Occupied port must resolve its owner for diagnostics'
```

- [ ] **Step 4: Run the focused tests and verify RED**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\runtime-preparation-behavior.Tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\open-when-ready-behavior.Tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\startup-behavior.Tests.ps1
```

Expected: FAIL because `run-dsh.ps1` lacks `-NoOpen`, the monitor lacks a millisecond interval, and the coordinator always invokes `Get-NetTCPConnection` during preflight.

- [ ] **Step 5: Implement `run-dsh.ps1 -NoOpen`**

Add a switch parameter and normalize arguments immediately before Node:

```powershell
if ($NoOpen -and $DshArguments -notcontains '--no-open') {
    $DshArguments = @($DshArguments) + '--no-open'
}
& node $dshEntrypoint @DshArguments
```

Do not change runtime preparation, dependency audit, mutex, or exit-code behavior.

- [ ] **Step 6: Implement the 200 millisecond readiness loop**

Add:

```powershell
[ValidateRange(50, 5000)]
[int]$PollIntervalMilliseconds = 200
```

Replace `Start-Sleep -Seconds 1` with `Start-Sleep -Milliseconds $PollIntervalMilliseconds`. Preserve the request timeout, parent-process exit check, state write before browser launch, and one successful `Start-Process` call.

- [ ] **Step 7: Implement the lightweight TCP preflight**

Build URLs from the coordinator's `-Port`. Add a bounded `TcpClient` helper:

```powershell
function Test-TcpPortOpen {
    param([string]$HostName = '127.0.0.1', [int]$TargetPort, [int]$TimeoutMilliseconds = 200)
    $client = [Net.Sockets.TcpClient]::new()
    try {
        $pending = $client.BeginConnect($HostName, $TargetPort, $null, $null)
        if (-not $pending.AsyncWaitHandle.WaitOne($TimeoutMilliseconds)) { return $false }
        $client.EndConnect($pending)
        return $true
    } catch {
        return $false
    } finally {
        $client.Dispose()
    }
}
```

Call `Get-NetTCPConnection` only after `Test-TcpPortOpen` returns true. Preserve the existing already-running output and browser behavior.

- [ ] **Step 8: Update all launcher-controlled Web invocations**

Add `-NoOpen` to the `background-run.ps1` child arguments introduced in Task
2, and pass it from `deepseek.cmd` and
`start-deepseek-harness.bat`. Use
`resolve-dsh-version.ps1 -PreferLocalRuntime` for both foreground entrypoints.
Pass `-PollIntervalMilliseconds 200` explicitly from runner/foreground monitor
invocations so process logs expose the contract.

For a newly submitted `-WaitForReady` launch, stop setting
`DSH_SUPPRESS_BROWSER_MONITOR`; let the runner start the same readiness monitor
as immediate mode. Change the coordinator's `Wait-DshStartup` call so it waits
and reports readiness without `-OpenBrowser`. Existing-ready-port handling may
still open the browser directly because no new monitor exists in that path.

Update startup tests to assert one monitor and
`run-dsh.ps1 ... -NoOpen`, reject a DSH invocation that omits `-NoOpen`, and
verify that synchronous wait mode leaves browser opening to its runner monitor
instead of issuing a second URL launch from the coordinator.

- [ ] **Step 9: Run focused and full startup tests and verify GREEN**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\runtime-preparation-behavior.Tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\open-when-ready-behavior.Tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\startup-behavior.Tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\shortcut-behavior.Tests.ps1
```

Expected: all exit `0`; Node receives `web --no-open` once, monitor opens once after HTTP, and closed-port startup avoids `Get-NetTCPConnection`.

- [ ] **Step 10: Review the Task 3 diff checkpoint**

Run:

```powershell
git diff --check -- run-dsh.ps1 open-when-ready.ps1 start-background.ps1 deepseek.cmd start-deepseek-harness.bat tests/runtime-preparation-behavior.Tests.ps1 tests/open-when-ready-behavior.Tests.ps1 tests/start-background-harness.ps1 tests/startup-behavior.Tests.ps1
```

Expected: no whitespace errors and no DSH profile or user configuration changes.

### Task 4: Package, Document, Regress, And Benchmark

**Files:**
- Modify: `release-files.txt`
- Modify: `tests/release-package-behavior.Tests.ps1`
- Modify: `.github/workflows/check.yml`
- Modify: `README.md`
- Modify: `README.en.md`

**Interfaces:**
- Produces: release archives containing both `background-run.ps1` and compatibility `background-run.cmd`.
- Documents: normal start uses the prepared version; `--update` and `--upgrade` perform npm release discovery.
- Verifies: complete Windows behavior suite and explicit three-cycle prepared-runtime benchmark.

- [ ] **Step 1: Write the failing release-package assertion**

Add `background-run.ps1` to `$requiredRuntimeFiles` in `tests/release-package-behavior.Tests.ps1` before changing the manifest:

```powershell
$requiredRuntimeFiles = @(
    'background-run.cmd',
    'background-run.ps1',
    'deepseek.cmd',
    'dsh-launch-state.ps1',
    'resolve-dsh-version.ps1',
    'run-dsh.ps1'
)
```

- [ ] **Step 2: Run release test and verify RED**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\release-package-behavior.Tests.ps1
```

Expected: FAIL because `release-files.txt` omits `background-run.ps1`.

- [ ] **Step 3: Add the runner to packaging and CI syntax validation**

Add `background-run.ps1` adjacent to `background-run.cmd` in `release-files.txt`. Update `.github/workflows/check.yml` so the CMD/log-directory check targets the PowerShell runner instead of requiring `mkdir` in the compatibility wrapper:

```bash
grep -q 'New-Item -ItemType Directory' background-run.ps1 || { echo "::error::background-run.ps1 missing log dir creation"; exit 1; }
```

The existing manifest-driven PowerShell parser will then include the new file automatically.

- [ ] **Step 4: Update Chinese and English documentation**

Document these exact behaviors in the command/script sections:

```markdown
- 普通启动优先复用已经准备并校验过的本地 DSH 版本，不访问 npm；使用 `deepseek --update` 检查新版本，使用 `deepseek --upgrade` 安装并切换到新版本。
- `background-run.ps1`：持有后台启动锁、记录状态与日志、启动就绪监视器和 DSH 子进程；`background-run.cmd` 仅保留为兼容入口。
```

```markdown
- Normal startup reuses the prepared and validated local DSH version without contacting npm. Use `deepseek --update` to discover releases and `deepseek --upgrade` to install and switch versions.
- `background-run.ps1`: owns the background startup lock, lifecycle state, log, readiness monitor, and DSH child; `background-run.cmd` remains only as a compatibility entrypoint.
```

- [ ] **Step 5: Run every Windows behavior test**

Run:

```powershell
$tests = @(Get-ChildItem .\tests -Filter '*.Tests.ps1' | Sort-Object Name)
foreach ($test in $tests) {
    Write-Host "Running $($test.Name)..."
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $test.FullName
    if ($LASTEXITCODE -ne 0) { throw "$($test.Name) failed with exit code $LASTEXITCODE" }
}
```

Expected: every discovered behavior test exits `0`, including resolver, runner, monitor, runtime preparation, launch state, release package, shortcut, update, upgrade, and version ordering.

- [ ] **Step 6: Parse every release PowerShell script with Windows PowerShell 5.1**

Run:

```powershell
$files = @(Get-Content .\release-files.txt | Where-Object { $_ -like '*.ps1' })
foreach ($file in $files) {
    $tokens = $null
    $errors = $null
    [Management.Automation.Language.Parser]::ParseFile((Join-Path $PWD $file), [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors.Count) { throw "$file parse failed: $($errors[0].Message)" }
}
```

Expected: zero parser errors.

- [ ] **Step 7: Run the real prepared-runtime benchmark**

Use the diagnostic timing loop established during investigation. For each of three cycles:

1. Run `deepseek --stop` and wait for port 3080 and the startup lock to clear.
2. Record the start timestamp.
3. Run `deepseek -b` and record command-return time.
4. Observe the direct runner, `run-dsh.ps1`, Node, and HTTP readiness timestamps.
5. Stop before the next cycle; after cycle three, leave the service running and ready.

Report a table containing `SubmitMs`, `RunnerStartMs`, `RunDshStartMs`, `NodeStartMs`, and `HttpReadyMs`. Compute the median `HttpReadyMs`:

```powershell
$medianReadyMs = @($rows.HttpReadyMs | Sort-Object)[1]
if ($medianReadyMs -gt 8000) {
    Write-Warning "Prepared-runtime median missed the 8000 ms target: $medianReadyMs ms"
}
```

Expected acceptance: all three starts reach HTTP; median `HttpReadyMs <= 8000`; no runner disappears before its first log; final `deepseek --status` reports `RUNNING (ready)`.

- [ ] **Step 8: Inspect final logs, process ownership, and repository diff**

Run:

```powershell
deepseek --status
deepseek --logs 40
git diff --check
git status --short --branch
git diff --stat
```

Expected: one ready DSH process tree, no duplicate browser-monitor process, no startup error in the final log tail, no whitespace errors, and only scoped implementation/test/documentation files changed in addition to the user's pre-existing worktree changes.

- [ ] **Step 9: Do not commit shared implementation files**

Because implementation files already contained user-owned uncommitted changes before this task, leave the verified implementation in the worktree and report the exact changed files and verification evidence. Do not stage or commit those files without separate user authorization.
