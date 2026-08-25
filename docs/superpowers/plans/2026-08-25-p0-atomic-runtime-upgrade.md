# P0 Atomic Runtime Upgrade Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prepare DSH versions side by side, switch an atomic current/previous pointer only after stable service health, and automatically restart the old runtime after candidate failure.

**Architecture:** `dsh-runtime-layout.ps1` owns validated relative pointers and upgrade transactions. `run-dsh.ps1` prepares or runs one explicit runtime directory but never switches global state; `upgrade-dsh.ps1` orchestrates prepare, stop, candidate health, commit, rollback, and retention.

**Tech Stack:** Windows PowerShell 5.1, JSON state files, same-volume `File.Replace`/`File.Move`, npm subprocesses, isolated behavior tests.

**Spec:** `docs/superpowers/specs/2026-08-25-p0-reliability-remediation-design.md`

## Global Constraints

- Complete `2026-08-25-p0-service-uninstall.md` first; candidate acceptance consumes its stable service-health protocol and reliable stop result.
- Runtime paths remain inside `%USERPROFILE%\dsh-launch` and never enter `%USERPROFILE%\.dsh`.
- Pointer paths are relative and validated after canonical resolution.
- The pointer is the commit fact; preparing or starting a candidate never changes Current.
- A successful pointer keeps exactly Current and the most recent Previous runtime.
- npm failure, candidate health failure, and orchestration interruption leave the old pointer startable.
- Tests use isolated runtime roots and fake node/npm/HTTP processes, never the real port 3080 instance.
- Commit messages are Chinese.

---

### Task 1: Add the validated runtime layout and atomic pointer helper

**Files:**
- Create: `dsh-runtime-layout.ps1`
- Create: `tests/runtime-layout-behavior.Tests.ps1`
- Modify: `release-files.txt:1-28`
- Modify: `tests/release-package-behavior.Tests.ps1:13-129`

**Interfaces:**
- Produces: `Get-DshRuntimeLayout(LaunchRoot)`, `Read-DshRuntimePointer(Layout)`, `Initialize-DshRuntimePointer(Layout)`, `New-DshRuntimeCandidate(Layout, Version)`, `Commit-DshRuntimePointer(Layout, Candidate)`, `Read-DshUpgradeTransaction(Layout)`, `Write-DshUpgradeTransaction(Layout, Phase, Old, Candidate, StartupToken)`, `Clear-DshUpgradeTransaction(Layout)`, and `Remove-DshUnreferencedRuntimes(Layout)`.
- Selection objects contain `Path` and `Version`; transaction objects contain `SchemaVersion`, `Phase`, `StartupToken`, `Old`, and `Candidate`.

- [ ] **Step 1: Write failing pointer, migration, retention, and boundary tests**

Cover:

Define the reusable path assertion in the test:

```powershell
function Assert-PathEqual {
    param([string]$Expected, [string]$Actual, [string]$Message)
    $expectedFull = [IO.Path]::GetFullPath($Expected).TrimEnd('\')
    $actualFull = [IO.Path]::GetFullPath($Actual).TrimEnd('\')
    if (-not [string]::Equals($expectedFull, $actualFull, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Message (expected: $expectedFull, actual: $actualFull)"
    }
}
```

```powershell
$initial = Initialize-DshRuntimePointer -Layout $layout
Assert-PathEqual $legacyRuntime $initial.Current.Path 'Legacy runtime must be registered without moving it'

$candidate = New-DshRuntimeCandidate -Layout $layout -Version '0.1.0-rc.8'
Assert-True $candidate.Path.StartsWith($layout.VersionsRoot + '\') 'Candidate must stay under runtime-versions'

$committed = Commit-DshRuntimePointer -Layout $layout -Candidate $candidate
Assert-PathEqual $candidate.Path $committed.Current.Path 'Candidate must become current'
Assert-PathEqual $legacyRuntime $committed.Previous.Path 'Old current must become previous'
```

Attempt pointer paths containing `..`, absolute paths, paths under `.dsh`, and reparse-point escapes; each must fail without deleting sentinels. Simulate a second commit and assert only the new Current and immediate Previous remain referenced. Interrupt pointer replacement before commit and assert the old JSON remains readable.

- [ ] **Step 2: Run the layout test and verify the helper is missing**

```powershell
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\runtime-layout-behavior.Tests.ps1
if ($LASTEXITCODE -eq 0) { throw 'Expected runtime-layout behavior to fail before implementation' }
```

- [ ] **Step 3: Implement layout validation and same-directory atomic writes**

Return a layout object with `LaunchRoot`, `LegacyRoot` (`runtime`), `VersionsRoot` (`runtime-versions`), `PointerPath` (`runtime-current.json`), and `TransactionPath` (`runtime-upgrade.json`). Centralize containment:

```powershell
function Resolve-DshOwnedRuntimePath {
    param([string]$LaunchRoot, [string]$RelativePath)
    if ([IO.Path]::IsPathRooted($RelativePath)) { throw 'Runtime pointer path must be relative' }
    $root = [IO.Path]::GetFullPath($LaunchRoot).TrimEnd('\')
    $resolved = [IO.Path]::GetFullPath((Join-Path $root $RelativePath)).TrimEnd('\')
    if (-not $resolved.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Runtime pointer escapes the launcher-owned root'
    }
    return $resolved
}
```

Write JSON without BOM to a temp file in the pointer directory. Use `[IO.File]::Replace($temp, $pointer, $backup, $true)` when the pointer exists, otherwise `[IO.File]::Move($temp, $pointer)`. Validate ready marker version before commit. Cleanup accepts an explicit keep set and deletes only child directories of `VersionsRoot` with valid launcher ready markers.

- [ ] **Step 4: Run layout and package tests**

```powershell
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\runtime-layout-behavior.Tests.ps1
if ($LASTEXITCODE -ne 0) { throw 'runtime layout behavior failed' }
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\release-package-behavior.Tests.ps1
if ($LASTEXITCODE -ne 0) { throw 'release package behavior failed' }
```

- [ ] **Step 5: Commit the runtime layout**

```powershell
git add dsh-runtime-layout.ps1 tests/runtime-layout-behavior.Tests.ps1 release-files.txt tests/release-package-behavior.Tests.ps1
git commit -m '新增版本化运行时原子指针'
```

### Task 2: Separate runtime preparation from execution

**Files:**
- Modify: `run-dsh.ps1:1-296`
- Modify: `tests/runtime-preparation-behavior.Tests.ps1:1-425`

**Interfaces:**
- Consumes: explicit `Version`, explicit owned `RuntimeRoot`, optional `PrepareOnly`.
- Produces: a ready marker after install/peer/audit success; with `PrepareOnly`, exit 0 without running Node; without it, execute the exact runtime entrypoint and propagate Node exit.

- [ ] **Step 1: Replace swap assumptions with failing explicit-candidate tests**

Add assertions that preparing a new candidate leaves an existing active runtime byte-for-byte unchanged, that npm failure leaves the old runtime and pointer untouched, and that PrepareOnly never writes to the node execution log:

Define deterministic test helpers:

```powershell
function Read-NodeLog {
    if (-not (Test-Path -LiteralPath $nodeLog)) { return '' }
    return [IO.File]::ReadAllText($nodeLog)
}

function Get-TreeHash {
    param([string]$Root)
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    return [string](@(Get-ChildItem -LiteralPath $rootFull -File -Recurse | Sort-Object FullName | ForEach-Object {
        $relative = $_.FullName.Substring($rootFull.Length + 1)
        $relative + '=' + (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
    }) -join "`n")
}
```

```powershell
$prepared = Invoke-Runtime -SelectedRuntimeRoot $candidateRoot -PrepareOnly
Assert-Equal 0 $prepared.ExitCode 'Candidate preparation must succeed'
Assert-Equal '' (Read-NodeLog) 'PrepareOnly must not start DSH'
Assert-Equal $oldHash (Get-TreeHash -Root $activeRoot) 'Preparation must not mutate active runtime'
```

Remove tests that expect `run-dsh.ps1` itself to rename active/retired directories; pointer switching belongs to the orchestrator.

- [ ] **Step 2: Run runtime preparation and verify PrepareOnly is unsupported**

```powershell
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\runtime-preparation-behavior.Tests.ps1
if ($LASTEXITCODE -eq 0) { throw 'Expected runtime preparation behavior to fail before implementation' }
```

- [ ] **Step 3: Implement one-root prepare/run semantics**

Add:

```powershell
[switch]$PrepareOnly
```

Retain runtime-root boundary validation, per-root mutex, install, peer repair, audit, and atomic ready marker. Remove retired-directory rename/delete logic. After releasing preparation logic:

```powershell
if ($PrepareOnly) {
    $nodeExitCode = 0
} else {
    Write-Output 'Starting DeepSeek Harness web service...'
    & node $dshEntrypoint @DshArguments
    $nodeExitCode = $LASTEXITCODE
}
```

Ensure the outer `finally` still releases the mutex and the final process exit is `$nodeExitCode`.

- [ ] **Step 4: Run runtime and Node tests**

```powershell
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\runtime-preparation-behavior.Tests.ps1
if ($LASTEXITCODE -ne 0) { throw 'runtime preparation behavior failed' }
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\node-version-behavior.Tests.ps1
if ($LASTEXITCODE -ne 0) { throw 'node behavior failed' }
```

- [ ] **Step 5: Commit preparation separation**

```powershell
git add run-dsh.ps1 tests/runtime-preparation-behavior.Tests.ps1
git commit -m '拆分运行时准备与启动阶段'
```

### Task 3: Make normal startup resolve the current pointer

**Files:**
- Modify: `resolve-dsh-version.ps1:1-122`
- Modify: `start-foreground.ps1`
- Modify: `start-background.ps1:1-312`
- Modify: `background-run.ps1:1-168`
- Modify: `tests/version-resolution-behavior.Tests.ps1:1-260`
- Modify: `tests/startup-behavior.Tests.ps1:94-843`

**Interfaces:**
- Consumes: `Initialize-DshRuntimePointer`/`Read-DshRuntimePointer` selection.
- Produces: normal foreground/background runner invocations carrying the same explicit `Version`, `RuntimeRoot`, `Entrypoint`, and token.

- [ ] **Step 1: Add failing pointer-selection tests**

Create old legacy and versioned runtimes with different versions, point Current at the versioned one, and assert local-first resolution/startup selects only Current. Assert Previous is ignored during normal start. Assert legacy runtime is registered when no pointer exists and registry discovery is not invoked.

- [ ] **Step 2: Run resolution and startup tests and verify fixed-root assumptions fail**

```powershell
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\version-resolution-behavior.Tests.ps1
$versionExit = $LASTEXITCODE
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\startup-behavior.Tests.ps1
$startupExit = $LASTEXITCODE
if ($versionExit -eq 0 -and $startupExit -eq 0) { throw 'Expected pointer selection tests to fail before implementation' }
```

- [ ] **Step 3: Thread explicit selection through startup**

Dot-source `dsh-runtime-layout.ps1` in coordinators. Resolve one selection object and pass:

```powershell
'-Version', $selection.Version,
'-RuntimeRoot', ('"' + $selection.Path + '"')
```

`background-run.ps1` accepts mandatory `RuntimeRoot`, derives the expected entrypoint from it, writes it to state, and calls `run-dsh.ps1 -RuntimeRoot $RuntimeRoot`. Preserve local-first behavior without npm access when Current is valid.

- [ ] **Step 4: Run resolution, startup, state, and package tests**

```powershell
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\version-resolution-behavior.Tests.ps1
if ($LASTEXITCODE -ne 0) { throw 'version resolution behavior failed' }
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\startup-behavior.Tests.ps1
if ($LASTEXITCODE -ne 0) { throw 'startup behavior failed' }
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\launch-state-behavior.Tests.ps1
if ($LASTEXITCODE -ne 0) { throw 'launch state behavior failed' }
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\release-package-behavior.Tests.ps1
if ($LASTEXITCODE -ne 0) { throw 'release package behavior failed' }
```

- [ ] **Step 5: Commit pointer-aware startup**

```powershell
git add resolve-dsh-version.ps1 start-foreground.ps1 start-background.ps1 background-run.ps1 tests/version-resolution-behavior.Tests.ps1 tests/startup-behavior.Tests.ps1
git commit -m '让启动链路使用当前运行时指针'
```

### Task 4: Implement transactional upgrade and automatic old-runtime restart

**Files:**
- Modify: `upgrade-dsh.ps1:1-86`
- Modify: `tests/upgrade-cache-behavior.Tests.ps1:1-291`
- Modify: `tests/start-background-harness.ps1:1-230`

**Interfaces:**
- Consumes: runtime layout helper, `run-dsh.ps1 -PrepareOnly`, reliable `stop-dsh.ps1`, `start-background.ps1 -RuntimeRoot -WaitForReady`, shared stable health.
- Produces: pointer commit only after candidate READY, automatic old-runtime restart on candidate failure, and one retained Previous.

- [ ] **Step 1: Build failing upgrade transaction fixtures**

Extend the fixture to create an old current runtime and pointer, record prepare/stop/start calls, and control candidate health. Cover:

Define selection equality in the fixture:

```powershell
function Assert-SelectionEqual {
    param([pscustomobject]$Expected, [pscustomobject]$Actual, [string]$Message)
    Assert-Equal ([string]$Expected.Version) ([string]$Actual.Version) "$Message (version)"
    Assert-PathEqual ([string]$Expected.Path) ([string]$Actual.Path) "$Message (path)"
}
```

```powershell
$resolveFailure = Invoke-UpgradeFixture -ResolvedVersion ''
Assert-SelectionEqual $old $resolveFailure.Pointer.Current 'Resolve failure must preserve current'

$prepareFailure = Invoke-UpgradeFixture -PrepareExitCode 17
Assert-SelectionEqual $old $prepareFailure.Pointer.Current 'Prepare failure must preserve current'
Assert-Equal $false $prepareFailure.StopCalled 'Prepare failure must not stop the old service'

$healthFailure = Invoke-UpgradeFixture -CandidateStartExitCode 1 -OldRestartExitCode 0
Assert-SelectionEqual $old $healthFailure.Pointer.Current 'Health failure must preserve old current'
Assert-Match $healthFailure.StartLog 'CANDIDATE.*OLD' 'Old runtime must restart after candidate failure'

$success = Invoke-UpgradeFixture -CandidateStartExitCode 0
Assert-SelectionEqual $candidate $success.Pointer.Current 'Healthy candidate must become current'
Assert-SelectionEqual $old $success.Pointer.Previous 'Old current must become previous'
```

Add interrupted transactions in PREPARED and STARTING phases and assert recovery never deletes the pointer-selected old runtime.

- [ ] **Step 2: Run upgrade behavior and verify transaction assertions fail**

```powershell
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\upgrade-cache-behavior.Tests.ps1
if ($LASTEXITCODE -eq 0) { throw 'Expected upgrade transaction behavior to fail before implementation' }
```

- [ ] **Step 3: Implement the ordered transaction**

The implementation order is mandatory:

```powershell
$targetVersion = [string](@(& (Join-Path $dir 'resolve-dsh-version.ps1')) -join '')
if (-not $targetVersion -or -not (ConvertTo-DshSemVer $targetVersion)) {
    Write-Host '[ERROR] Unable to resolve a valid DSH target version; upgrade aborted.'
    exit 1
}
$layout = Get-DshRuntimeLayout -LaunchRoot $launchRoot
$pointer = Initialize-DshRuntimePointer -Layout $layout
$candidate = New-DshRuntimeCandidate -Layout $layout -Version $targetVersion
& $runScript -Version $targetVersion -RuntimeRoot $candidate.Path -PrepareOnly
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
Write-DshUpgradeTransaction -Layout $layout -Phase 'PREPARED' -Old $pointer.Current -Candidate $candidate -StartupToken $startupToken
& $stopScript
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& $startScript -WaitForReady -Version $candidate.Version -RuntimeRoot $candidate.Path -StartupToken $startupToken
```

On candidate success, commit the pointer, mark COMMITTED, sync global CLI, retain Current/Previous, and clear the transaction. On candidate failure, stop the candidate using transaction identity, start `$pointer.Current` with a fresh startup token, report both candidate and rollback outcomes, leave the pointer unchanged, and exit nonzero.

- [ ] **Step 4: Run upgrade, runtime, startup, and stop tests**

```powershell
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\upgrade-cache-behavior.Tests.ps1
if ($LASTEXITCODE -ne 0) { throw 'upgrade behavior failed' }
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\runtime-layout-behavior.Tests.ps1
if ($LASTEXITCODE -ne 0) { throw 'runtime layout behavior failed' }
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\runtime-preparation-behavior.Tests.ps1
if ($LASTEXITCODE -ne 0) { throw 'runtime preparation behavior failed' }
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\startup-behavior.Tests.ps1
if ($LASTEXITCODE -ne 0) { throw 'startup behavior failed' }
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\stop-behavior.Tests.ps1
if ($LASTEXITCODE -ne 0) { throw 'stop behavior failed' }
```

- [ ] **Step 5: Commit transactional upgrade**

```powershell
git add upgrade-dsh.ps1 tests/upgrade-cache-behavior.Tests.ps1 tests/start-background-harness.ps1
git commit -m '实现运行时健康切换与自动回滚'
```

### Task 5: Synchronize documentation, release contents, and final verification

**Files:**
- Modify: `README.md:24-157`
- Modify: `README.en.md:25-159`
- Modify: `release-files.txt:1-28`
- Modify: `tests/release-package-behavior.Tests.ps1:1-133`
- Modify: `.github/workflows/check.yml:15-58`
- Modify: `.github/workflows/release.yml:18-90`

**Interfaces:**
- Consumes: all preceding P0 implementations.
- Produces: accurate bilingual user documentation, complete release payload, PS 5.1/ASCII CI guards, and fresh full-suite evidence.

- [ ] **Step 1: Add release and CI assertions before documentation edits**

Require `dsh-node-version.ps1`, `dsh-service-health.ps1`, `dsh-runtime-layout.ps1`, and `start-foreground.ps1` in assembled/extracted packages. CI must parse every release PowerShell file with `powershell.exe` 5.1 and assert `install.ps1` has no BOM and no byte greater than `0x7F`.

- [ ] **Step 2: Run package and static checks to expose missing synchronization**

```powershell
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\release-package-behavior.Tests.ps1
if ($LASTEXITCODE -eq 0) { throw 'Expected release synchronization assertions to fail before updates' }
```

- [ ] **Step 3: Update bilingual documentation and manifests**

Document:

- exact Node range and three-entry shared check;
- strict CLI modifiers and numeric log argument;
- token/entrypoint/page/stability service identity;
- READY/STARTING/UNHEALTHY/FOREIGN_PORT/FAILED/STOPPED meanings;
- ownership-marker uninstall boundary and PATH rollback;
- versioned runtime directories, Current/Previous pointer, candidate health gate, automatic old-runtime restart, and one-version retention.

Do not change `VERSION`.

- [ ] **Step 4: Run the complete verification gate**

```powershell
$ErrorActionPreference = 'Stop'
$parseCommand = @'
$ErrorActionPreference = 'Stop'
$files = @(Get-Content .\release-files.txt | Where-Object { $_ -like '*.ps1' })
foreach ($file in $files) {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PWD $file), [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors.Count -gt 0) { throw "PS 5.1 parse failed: $file -> $($errors[0].Message)" }
}
'@
& powershell.exe -NoProfile -ExecutionPolicy Bypass -Command $parseCommand
if ($LASTEXITCODE -ne 0) { throw 'Windows PowerShell 5.1 parse gate failed' }

$tests = @(Get-ChildItem .\tests -Filter '*.Tests.ps1' | Sort-Object Name)
foreach ($test in $tests) {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $test.FullName
    if ($LASTEXITCODE -ne 0) { throw "$($test.Name) failed with exit code $LASTEXITCODE" }
}

$installBytes = [IO.File]::ReadAllBytes((Join-Path $PWD 'install.ps1'))
if ($installBytes.Length -ge 3 -and $installBytes[0] -eq 0xEF -and $installBytes[1] -eq 0xBB -and $installBytes[2] -eq 0xBF) { throw 'install.ps1 has a BOM' }
if (@($installBytes | Where-Object { $_ -gt 0x7F }).Count -ne 0) { throw 'install.ps1 is not ASCII-safe' }

git diff --check
if ($LASTEXITCODE -ne 0) { throw 'git diff check failed' }
```

Assemble `dist/dsh-launcher.zip` from `release-files.txt`, then run:

```powershell
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\release-package-behavior.Tests.ps1 -ArchivePath .\dist\dsh-launcher.zip
if ($LASTEXITCODE -ne 0) { throw 'archive smoke test failed' }
```

- [ ] **Step 5: Review the final diff and commit synchronization**

Confirm only intended source, tests, workflows, manifests, and bilingual docs are changed; confirm no logs, runtime, cache, credentials, temporary directories, or generated archive are staged.

```powershell
git add README.md README.en.md release-files.txt tests/release-package-behavior.Tests.ps1 .github/workflows/check.yml .github/workflows/release.yml
git commit -m '同步 P0 可靠性文档与发布检查'
```
