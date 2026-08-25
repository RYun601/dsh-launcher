# P0 Service Identity and Uninstall Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Establish one token-, entrypoint-, process-, and response-aware service identity protocol, then use it for state, readiness, stopping, and transactional full uninstall.

**Architecture:** A new `dsh-service-health.ps1` owns all port/process/HTTP classification. Launch state records the evidence needed to bind a listener to one startup token, and lifecycle consumers call the shared functions rather than copying regexes or accepting any HTTP response.

**Tech Stack:** Windows PowerShell 5.1, Win32_Process/CIM, TCP/HTTP loopback probes, self-contained behavior tests.

**Spec:** `docs/superpowers/specs/2026-08-25-p0-reliability-remediation-design.md`

## Global Constraints

- Complete `2026-08-25-p0-entry-install-cli.md` first; this plan consumes `.dsh-launcher-owner.json` and exact `-Full` dispatch.
- Production remains on Windows PowerShell 5.1 and port 3080.
- Initial readiness requires the same PID to be valid for 5 seconds; tests may inject shorter millisecond windows.
- Service identity requires token, exact entrypoint path, Node process identity, and HTML body marker `id="root"`.
- Unknown port owners are never terminated.
- `%USERPROFILE%\.dsh` is never read, moved, or deleted.
- Lifecycle tests use isolated ports and fake processes only.
- Commit messages are Chinese.

---

### Task 1: Introduce the shared service classifier

**Files:**
- Create: `dsh-service-health.ps1`
- Create: `tests/service-health-behavior.Tests.ps1`
- Modify: `release-files.txt:1-25`
- Modify: `tests/release-package-behavior.Tests.ps1:13-22`

**Interfaces:**
- Produces: `Get-DshPortOwner(Port) -> object|null`, `Test-DshProcessIdentity(ProcessId, ExpectedEntrypoint) -> bool`, `Invoke-DshHttpProbe(Port) -> object`, `Get-DshServiceClassification(Port, ExpectedEntrypoint, ExpectedStartupToken, RunnerPid) -> object`, and `Wait-DshServiceIdentity(Port, ExpectedEntrypoint, ExpectedStartupToken, RunnerPid, StableMilliseconds, PollMilliseconds) -> object`.
- Result object properties: `State`, `ServicePid`, `Message`, `HttpStatus`, `Entrypoint`.

- [ ] **Step 1: Write classifier tests with real isolated listeners and controlled process metadata**

Test these states:

Define `Invoke-Classification` as the fixture boundary: it starts the existing fake HTTP listener with the supplied body/status, installs a scoped `Get-CimInstance` test double returning `Name`, `CommandLine`, and `ExecutablePath`, invokes `Wait-DshServiceIdentity`, and always stops the listener and removes the test double in `finally`. Its signature is:

```powershell
function Invoke-Classification {
    param(
        [string]$CommandLine,
        [string]$Body,
        [int]$StatusCode,
        [int]$StableMilliseconds = 0
    )
    $script:DshTestProcessInfo = [pscustomobject]@{
        Name = if ($CommandLine -match '^node(?:\.exe)?\s') { 'node.exe' } else { 'powershell.exe' }
        CommandLine = $CommandLine
        ExecutablePath = if ($CommandLine -match '^node(?:\.exe)?\s') { 'C:\node\node.exe' } else { 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' }
    }
    $fixture = Start-FakeHttpFixture -Body $Body -StatusCode $StatusCode
    try {
        return Wait-DshServiceIdentity -Port $fixture.Port -ExpectedEntrypoint $script:ExpectedEntrypoint `
            -ExpectedStartupToken $script:ExpectedStartupToken -RunnerPid $script:ExpectedRunnerPid `
            -StableMilliseconds $StableMilliseconds -PollMilliseconds 25
    } finally {
        Stop-FakeHttpFixture -Fixture $fixture
    }
}
```

The test harness's scoped `Get-CimInstance` function returns `$script:DshTestProcessInfo`; restore any prior function definition in the outer test `finally`.

```powershell
$foreign = Invoke-Classification -CommandLine 'node.exe C:\apps\other\server.js' -Body '<div id="root"></div>' -StatusCode 200
Assert-Equal 'FOREIGN_PORT' $foreign.State 'Wrong entrypoint must be foreign'

$spoof = Invoke-Classification -CommandLine 'powershell.exe -Command "# @deepseek-ai/dsh/lib/bin.js"' -Body '<div id="root"></div>' -StatusCode 200
Assert-Equal 'FOREIGN_PORT' $spoof.State 'A substring marker must not establish identity'

$dead = Invoke-Classification -CommandLine $expectedNodeCommand -Body 'error' -StatusCode 500
Assert-Equal 'UNHEALTHY' $dead.State 'An identified listener with dead HTTP is unhealthy'

$wrongBody = Invoke-Classification -CommandLine $expectedNodeCommand -Body '<html>other app</html>' -StatusCode 200
Assert-Equal 'UNHEALTHY' $wrongBody.State 'A generic success page is not DSH'

$ready = Invoke-Classification -CommandLine $expectedNodeCommand -Body '<div id="root"></div>' -StatusCode 200 -StableMilliseconds 200
Assert-Equal 'READY' $ready.State 'Exact identity and stable DSH page must be ready'
```

Add a process that exits inside the stability window and assert it never returns READY.

- [ ] **Step 2: Run the new test and verify the helper is missing**

```powershell
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\service-health-behavior.Tests.ps1
if ($LASTEXITCODE -eq 0) { throw 'Expected service-health behavior to fail before implementation' }
```

- [ ] **Step 3: Implement exact process and bounded HTTP checks**

Dot-source semantics must only define functions. Normalize the expected entrypoint and require it as a complete command-line argument:

```powershell
function Test-DshCommandLineArgument {
    param([string]$CommandLine, [string]$ExpectedPath)
    $escaped = [regex]::Escape([IO.Path]::GetFullPath($ExpectedPath))
    return $CommandLine -match ('(?i)(?:^|\s)"?' + $escaped + '"?(?:\s|$)')
}
```

Require Win32 process name `node` or `node.exe`, require the exact entrypoint, require the caller-supplied startup token and live runner evidence, read at most 256 KiB from the HTTP response stream, require 200-399 and `id=["'']root["'']`, and return structured states. `Wait-DshServiceIdentity` repeatedly calls `Get-DshServiceClassification`, pins the first valid listener PID, and resets stability if the PID changes.

- [ ] **Step 4: Run focused and package tests**

```powershell
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\service-health-behavior.Tests.ps1
if ($LASTEXITCODE -ne 0) { throw 'service health behavior failed' }
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\release-package-behavior.Tests.ps1
if ($LASTEXITCODE -ne 0) { throw 'release package behavior failed' }
```

- [ ] **Step 5: Commit the shared classifier**

```powershell
git add dsh-service-health.ps1 tests/service-health-behavior.Tests.ps1 release-files.txt tests/release-package-behavior.Tests.ps1
git commit -m '新增统一服务身份与健康检查'
```

### Task 2: Bind startup locks and state to command paths and tokens

**Files:**
- Modify: `dsh-launch-state.ps1:1-414`
- Modify: `tests/launch-state-behavior.Tests.ps1:113-310`

**Interfaces:**
- Consumes: service classifier functions and startup metadata arguments.
- Produces: lock files `pid.txt`, `token.txt`, `command-path.txt`, `script-path.txt`, `created-at.txt`; state schema with `StartupToken`, `RunnerPid`, `ServicePid`, `RuntimeRoot`, `Entrypoint`.

- [ ] **Step 1: Add failing lock and state identity tests**

Extend helper invocations to pass:

```powershell
'-StartupToken', $token,
'-CommandPath', $powerShellPath,
'-ScriptPath', $runnerScript,
'-RuntimeRoot', $runtimeRoot,
'-Entrypoint', $entrypoint
```

Assert a live generic PowerShell process cannot keep a lock whose recorded script path is `background-run.ps1`. Assert token mismatch cannot transfer or release. Assert READY state JSON records the service PID, token, runtime root, and exact entrypoint. Assert legacy `RUNNING` is read as READY but never newly written. Assert `GetStatus` uses the stored token/entrypoint and one `Get-DshServiceClassification` probe for an already READY matching PID, while a new STARTING identity still requires the stability wait.

- [ ] **Step 2: Run launch-state behavior and verify identity assertions fail**

```powershell
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\launch-state-behavior.Tests.ps1
if ($LASTEXITCODE -eq 0) { throw 'Expected launch-state behavior to fail before implementation' }
```

- [ ] **Step 3: Implement metadata-aware lock and state schemas**

Add parameters and persisted properties with exact names:

```powershell
[string]$CommandPath,
[string]$ScriptPath,
[int]$ServicePid = 0,
[string]$RuntimeRoot,
[string]$Entrypoint
```

`Test-StartupOwnerAlive` must query `Win32_Process`, compare the normalized executable and script argument to recorded metadata, and return false when it cannot prove a match. `WriteStartupStateFile` must preserve immutable startup metadata across stage updates. Map legacy `RUNNING` to READY when reading status.

- [ ] **Step 4: Run launch-state and startup regression tests**

```powershell
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\launch-state-behavior.Tests.ps1
if ($LASTEXITCODE -ne 0) { throw 'launch-state behavior failed' }
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\startup-behavior.Tests.ps1
if ($LASTEXITCODE -ne 0) { throw 'startup behavior failed' }
```

- [ ] **Step 5: Commit lock/state identity**

```powershell
git add dsh-launch-state.ps1 tests/launch-state-behavior.Tests.ps1 tests/startup-behavior.Tests.ps1
git commit -m '强化启动锁与状态身份校验'
```

### Task 3: Route foreground, background, status, and readiness through the classifier

**Files:**
- Create: `start-foreground.ps1`
- Modify: `deepseek.cmd:76-98`
- Modify: `start-deepseek-harness.bat:1-35`
- Modify: `start-background.ps1:27-312`
- Modify: `background-run.ps1:1-168`
- Modify: `open-when-ready.ps1:1-30`
- Modify: `tests/startup-behavior.Tests.ps1:94-843`
- Modify: `tests/open-when-ready-behavior.Tests.ps1:1-142`
- Modify: `release-files.txt:1-25`
- Modify: `tests/release-package-behavior.Tests.ps1:13-129`

**Interfaces:**
- Consumes: `Wait-DshServiceIdentity`, lock/state metadata, selected version/runtime/entrypoint.
- Produces: foreground and background startup with one token and one browser owner; `open-when-ready.ps1` writes READY only after stable identity.

- [ ] **Step 1: Add failing integration cases**

Add a foreground foreign-port scenario and assert exit 1, no browser, and no `run-dsh.ps1`. Add a readiness scenario where HTTP 200 contains a generic page and assert no browser. Add a stable DSH page scenario and assert exactly one browser call and READY state. Assert coordinator, runner, monitor, and state all receive the same startup token and expected entrypoint.

- [ ] **Step 2: Run startup and readiness tests to verify the broad checks fail**

```powershell
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\startup-behavior.Tests.ps1
$startupExit = $LASTEXITCODE
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\open-when-ready-behavior.Tests.ps1
$readyExit = $LASTEXITCODE
if ($startupExit -eq 0 -and $readyExit -eq 0) { throw 'Expected startup or readiness behavior to fail before implementation' }
```

- [ ] **Step 3: Implement the shared startup path**

`start-foreground.ps1` must acquire a tokenized lock for its own PID, write STARTING metadata, launch one `open-when-ready.ps1` monitor, invoke `run-dsh.ps1`, record early failure, release the lock, and exit with the runtime code.

Pass monitor evidence explicitly:

```powershell
& $monitorScript -LaunchRoot $launchRoot -OwnerPid $PID -StartupToken $startupToken `
    -RuntimeRoot $RuntimeRoot -Entrypoint $entrypoint -Port $Port `
    -StableMilliseconds 5000 -PollIntervalMilliseconds 200
```

Replace `Test-DshReady` and local process regexes in background startup with `Wait-DshServiceIdentity`/single-probe classifier calls. `deepseek.cmd` and `start-deepseek-harness.bat` delegate foreground behavior to `start-foreground.ps1` and immediately propagate its exit code.

- [ ] **Step 4: Run all startup-facing tests**

```powershell
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\service-health-behavior.Tests.ps1
if ($LASTEXITCODE -ne 0) { throw 'service health behavior failed' }
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\startup-behavior.Tests.ps1
if ($LASTEXITCODE -ne 0) { throw 'startup behavior failed' }
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\open-when-ready-behavior.Tests.ps1
if ($LASTEXITCODE -ne 0) { throw 'readiness behavior failed' }
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\release-package-behavior.Tests.ps1
if ($LASTEXITCODE -ne 0) { throw 'release package behavior failed' }
```

- [ ] **Step 5: Commit startup integration**

```powershell
git add start-foreground.ps1 deepseek.cmd start-deepseek-harness.bat start-background.ps1 background-run.ps1 open-when-ready.ps1 tests/startup-behavior.Tests.ps1 tests/open-when-ready-behavior.Tests.ps1 release-files.txt tests/release-package-behavior.Tests.ps1
git commit -m '统一前后台服务就绪判定'
```

### Task 4: Make stopping condition-based and failure-aware

**Files:**
- Modify: `stop-dsh.ps1:1-72`
- Modify: `tests/stop-behavior.Tests.ps1:1-88`

**Interfaces:**
- Consumes: shared service identity, tokenized startup lock, `taskkill.exe` exit code.
- Produces: exit 0 only after the identified DSH process, port listener, and startup lock disappear; exit 1 on kill failure or timeout.

- [ ] **Step 1: Add failing stop cases**

Add scenarios for taskkill exit 5, taskkill returning 0 while the fake PID/port remains for the whole timeout, successful disappearance, and a foreign listener. Assert the foreign listener never appears in the kill log.

```powershell
Assert-Equal 1 $killFailure.ExitCode 'taskkill failure must propagate'
Assert-Equal 1 $timeout.ExitCode 'A surviving PID or lock must fail after timeout'
Assert-NotMatch $foreign.KillLog ([regex]::Escape([string]$foreign.Pid)) 'Foreign process must not be killed'
```

- [ ] **Step 2: Run stop behavior and verify false-success cases fail**

```powershell
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\stop-behavior.Tests.ps1
if ($LASTEXITCODE -eq 0) { throw 'Expected stop behavior to fail before implementation' }
```

- [ ] **Step 3: Implement checked kill and condition wait**

Expose testable parameters while retaining defaults:

```powershell
param(
    [int]$Port = 3080,
    [string]$LaunchRoot = (Join-Path $env:USERPROFILE 'dsh-launch'),
    [int]$TimeoutMilliseconds = 5000
)
```

After `taskkill.exe`, capture `$LASTEXITCODE` immediately and fail on nonzero. Poll until the identified PID is gone, no identified DSH owns the port, and `TestStartupLock` is UNLOCKED. At the deadline emit an error with remaining evidence and exit 1.

- [ ] **Step 4: Run stop, health, and startup tests**

```powershell
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\stop-behavior.Tests.ps1
if ($LASTEXITCODE -ne 0) { throw 'stop behavior failed' }
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\service-health-behavior.Tests.ps1
if ($LASTEXITCODE -ne 0) { throw 'service health behavior failed' }
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\startup-behavior.Tests.ps1
if ($LASTEXITCODE -ne 0) { throw 'startup behavior failed' }
```

- [ ] **Step 5: Commit reliable stopping**

```powershell
git add stop-dsh.ps1 tests/stop-behavior.Tests.ps1
git commit -m '确保停止流程验证进程完全退出'
```

### Task 5: Make full uninstall ownership-bound and transactional

**Files:**
- Modify: `uninstall.ps1:1-154`
- Modify: `tests/uninstall-behavior.Tests.ps1:1-174`
- Modify: `README.md:102-157`
- Modify: `README.en.md:104-159`

**Interfaces:**
- Consumes: `.dsh-launcher-owner.json`, checked `stop-dsh.ps1`, profile-bounded paths, user PATH.
- Produces: either a complete uninstall or restored directories/PATH; a cleanup failure leaves one reported backup owned by this transaction.

- [ ] **Step 1: Add failing ownership, stop, and rollback tests**

Every valid fixture writes an owner marker matching its install path. Add tests for missing marker, mismatched path, install outside profile, install under `.dsh`, missing stop script, stop timeout/nonzero, user cancellation, PATH update failure, second move failure, and backup cleanup failure.

Capture user PATH before each subprocess and restore it in `finally`. Track backup paths returned by the fixture and clean only those exact paths. Delete the existing helper that enumerates every `dsh-launcher-backup-*` directory.

Key assertions:

```powershell
Assert-Equal $originalUserPath ([Environment]::GetEnvironmentVariable('Path', 'User')) 'Abort must preserve PATH'
Assert-True (Test-Path -LiteralPath $fixture.InstallDir) 'Abort must preserve install files'
Assert-True (Test-Path -LiteralPath $fixture.DshCredentialSentinel) '.dsh must never be touched'
Assert-Match $cleanupFailure.Output 'backup kept at' 'Retained backup location must be explicit'
```

- [ ] **Step 2: Run uninstall behavior and verify new cases fail**

```powershell
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\uninstall-behavior.Tests.ps1
if ($LASTEXITCODE -eq 0) { throw 'Expected uninstall behavior to fail before implementation' }
```

- [ ] **Step 3: Implement the uninstall transaction**

Move user PATH removal out of script startup. Validate the owner marker before stop or move:

```powershell
$ownerPath = Join-Path $installFull '.dsh-launcher-owner.json'
$owner = Get-Content -LiteralPath $ownerPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ([int]$owner.SchemaVersion -ne 1 -or -not [string]::Equals(
    [IO.Path]::GetFullPath([string]$owner.InstallPath).TrimEnd('\'),
    $installFull.TrimEnd('\'),
    [StringComparison]::OrdinalIgnoreCase
)) { throw 'Launcher ownership marker does not match the install directory' }
```

Use a unique backup root directly below the validated profile. Move the shortcut, `dsh-launch`, and install directory into it. Keep an ordered move journal in memory. On move or PATH failure, restore in reverse order and restore the exact original user PATH. If backup deletion fails after a committed uninstall, return success with the retained exact path.

- [ ] **Step 4: Run uninstall, stop, CLI, and diff checks**

```powershell
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\uninstall-behavior.Tests.ps1
if ($LASTEXITCODE -ne 0) { throw 'uninstall behavior failed' }
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\stop-behavior.Tests.ps1
if ($LASTEXITCODE -ne 0) { throw 'stop behavior failed' }
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\startup-behavior.Tests.ps1
if ($LASTEXITCODE -ne 0) { throw 'startup behavior failed' }
git diff --check
if ($LASTEXITCODE -ne 0) { throw 'diff check failed' }
```

- [ ] **Step 5: Update uninstall documentation and commit**

Document ownership-marker refusal, PATH preservation on abort, service-stop confirmation, `.dsh` exclusion, and retained backup diagnostics.

```powershell
git add uninstall.ps1 tests/uninstall-behavior.Tests.ps1 README.md README.en.md
git commit -m '实现可回滚的安全完整卸载'
```
