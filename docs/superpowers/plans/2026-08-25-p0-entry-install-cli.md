# P0 Entry, Installer, and CLI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the shared Node.js prerequisite, release installer, and public CMD dispatcher satisfy the P0 behavior and PowerShell 5.1 compatibility requirements.

**Architecture:** Keep Node version semantics in `dsh-node-version.ps1`, keep `deepseek.cmd` as a small explicit action dispatcher, and make `install.ps1` an ASCII-source bootstrap that can safely install a staged archive under the user profile. Tests execute the real CMD and installer paths with isolated executables and profiles.

**Tech Stack:** Windows PowerShell 5.1, CMD/BAT, self-contained PowerShell behavior tests, ZIP archives.

**Spec:** `docs/superpowers/specs/2026-08-25-p0-reliability-remediation-design.md`

## Global Constraints

- Production scripts must parse and run under `powershell.exe` 5.1.
- Node.js requirement is exactly `^22.19.0 || >=24.0.0`.
- `install.ps1` remains UTF-8 without BOM and contains ASCII source bytes only.
- Installation targets must remain inside `%USERPROFILE%`, outside `.dsh` and `dsh-launch`.
- Tests use isolated `USERPROFILE`, `TEMP`, `APPDATA`, `LOCALAPPDATA`, PATH, and fake executables.
- No test may read, move, or delete the real `%USERPROFILE%\.dsh`.
- Commit messages are Chinese.

---

### Task 1: Complete the shared Node.js prerequisite contract

**Files:**
- Create: `tests/node-version-behavior.Tests.ps1`
- Modify: `dsh-node-version.ps1:1-72`
- Modify: `tests/runtime-preparation-behavior.Tests.ps1:365-383`
- Modify: `tests/upgrade-cache-behavior.Tests.ps1:275-284`

**Interfaces:**
- Consumes: fake `node.cmd --version` output from an isolated PATH.
- Produces: `Test-DshNodeRequirement(Version, MinimumMajor, MinimumMinor, AlternateMajor) -> bool`, `Get-DshNodeVersion(NodeCommand) -> string`, and `Assert-DshNodeEnvironment(NodeCommand) -> bool`.

- [ ] **Step 1: Add a focused failing behavior test**

Create a test harness that dot-sources the helper after placing a fake `node.cmd` first on PATH. Cover these exact cases:

```powershell
$missing = Invoke-NodeAssertion -NodeVersion 'NONE'
Assert-Equal $false $missing.Result 'Missing Node must be rejected'
Assert-Match $missing.Output '当前版本：未检测到' 'Missing Node must state the current version'
Assert-Match $missing.Output '\^22\.19\.0 \|\| >=24\.0\.0' 'Missing Node must state the range'
Assert-Match $missing.Output '(?i)nodejs\.org|nvm-windows' 'Missing Node must state an upgrade method'

$old = Invoke-NodeAssertion -NodeVersion 'v22.18.9'
Assert-Equal $false $old.Result 'Node below the minimum must be rejected'
Assert-Match $old.Output '当前版本：v22\.18\.9' 'Old Node must report its version'

$minimum = Invoke-NodeAssertion -NodeVersion 'v22.19.0'
Assert-Equal $true $minimum.Result 'The exact minimum must pass'

$alternate = Invoke-NodeAssertion -NodeVersion 'v24.0.0'
Assert-Equal $true $alternate.Result 'The alternate supported major must pass'
```

Also read `install.ps1`, `run-dsh.ps1`, and `upgrade-dsh.ps1` as text and assert each dot-sources `dsh-node-version.ps1` and invokes `Assert-DshNodeEnvironment` instead of carrying a second comparison.

- [ ] **Step 2: Run the test and verify the missing-current-version assertion fails**

Run:

```powershell
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\node-version-behavior.Tests.ps1
if ($LASTEXITCODE -eq 0) { throw 'Expected the Node behavior test to fail before implementation' }
```

Expected: failure naming the absent `当前版本：未检测到` line.

- [ ] **Step 3: Make the minimal helper change**

In the missing-version branch, emit all three required facts before returning false:

```powershell
Write-Host '[ERROR] 未检测到 Node.js！'
Write-Host '当前版本：未检测到'
Write-Host "要求版本：$requiredRange（DeepSeek Harness 上游要求）"
Write-Host '升级方式：从 https://nodejs.org 下载安装 LTS 版本（自带 npm），或使用 nvm-windows。'
return $false
```

Keep the comparison logic centralized and leave accepted-version output unchanged.

- [ ] **Step 4: Run focused and consumer tests**

Run:

```powershell
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\node-version-behavior.Tests.ps1
if ($LASTEXITCODE -ne 0) { throw 'node-version behavior failed' }
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\runtime-preparation-behavior.Tests.ps1
if ($LASTEXITCODE -ne 0) { throw 'runtime preparation behavior failed' }
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\upgrade-cache-behavior.Tests.ps1
if ($LASTEXITCODE -ne 0) { throw 'upgrade cache behavior failed' }
```

Expected: all three commands exit 0.

- [ ] **Step 5: Commit the Node contract**

```powershell
git add dsh-node-version.ps1 tests/node-version-behavior.Tests.ps1 tests/runtime-preparation-behavior.Tests.ps1 tests/upgrade-cache-behavior.Tests.ps1
git commit -m '完善 Node.js 前置检查'
```

### Task 2: Make the release installer PowerShell 5.1-safe and behavior-tested

**Files:**
- Create: `tests/install-behavior.Tests.ps1`
- Modify: `install.ps1:1-114`
- Modify: `tests/release-package-behavior.Tests.ps1:13-129`

**Interfaces:**
- Consumes: a release ZIP selected by the normal GitHub download path or by `DSH_TEST_INSTALL_ARCHIVE` only when `DSH_TEST_MODE=1`.
- Produces: a normalized installation under `%USERPROFILE%`, plus `.dsh-launcher-owner.json` with `SchemaVersion`, `InstallPath`, and `InstallationId`.

- [ ] **Step 1: Add failing installer safety and copy tests**

The new test must create an isolated release ZIP containing `deepseek.cmd`, `dsh-node-version.ps1`, and a sentinel file. Invoke the real installer with fake Node/npm and these environment values:

Define the path and parser assertions at the top of the test. Because the test itself runs under `powershell.exe`, `Invoke-Ps51Parse` uses the Windows PowerShell 5.1 parser:

```powershell
function Assert-PathEqual {
    param([string]$Expected, [string]$Actual, [string]$Message)
    $expectedFull = [IO.Path]::GetFullPath($Expected).TrimEnd('\')
    $actualFull = [IO.Path]::GetFullPath($Actual).TrimEnd('\')
    if (-not [string]::Equals($expectedFull, $actualFull, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Message (expected: $expectedFull, actual: $actualFull)"
    }
}

function Invoke-Ps51Parse {
    param([string]$Path)
    $tokens = $null
    $errors = $null
    [Management.Automation.Language.Parser]::ParseFile(
        [IO.Path]::GetFullPath($Path), [ref]$tokens, [ref]$errors
    ) | Out-Null
    return @($errors)
}
```

```powershell
$env:DSH_TEST_MODE = '1'
$env:DSH_TEST_INSTALL_ARCHIVE = $archivePath
$env:USERPROFILE = $profileRoot
$env:TEMP = $tempRoot
$installDir = Join-Path $profileRoot 'dsh-launcher'
$output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer `
    -InstallDir $installDir -SkipPath 2>&1
```

Assert:

```powershell
Assert-Equal 0 $LASTEXITCODE "Installer should copy the staged archive. Output:`n$($output -join "`n")"
Assert-True (Test-Path -LiteralPath (Join-Path $installDir 'sentinel.txt')) 'Wildcard copy must include payload files'
$owner = Get-Content -LiteralPath (Join-Path $installDir '.dsh-launcher-owner.json') -Raw | ConvertFrom-Json
Assert-Equal 1 $owner.SchemaVersion 'Ownership marker schema must be stable'
Assert-PathEqual $installDir $owner.InstallPath 'Ownership marker must bind the exact install path'
```

Add three static/runtime assertions:

```powershell
$bytes = [IO.File]::ReadAllBytes($installer)
Assert-Equal $false ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) 'Installer must not have a BOM'
Assert-Equal 0 @($bytes | Where-Object { $_ -gt 0x7F }).Count 'Installer source must be ASCII-only'
Assert-Equal 0 (Invoke-Ps51Parse -Path $installer).Count 'Windows PowerShell 5.1 must parse the installer'
```

Invoke the installer with an install path outside the isolated profile and with paths under `.dsh` and `dsh-launch`; each must exit nonzero and preserve a sentinel in the rejected target.

- [ ] **Step 2: Run the installer test and verify the current implementation fails**

Run:

```powershell
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\install-behavior.Tests.ps1
if ($LASTEXITCODE -eq 0) { throw 'Expected installer behavior to fail before implementation' }
```

Expected: failure from PS 5.1 parsing, non-ASCII source, or `-LiteralPath` wildcard copying.

- [ ] **Step 3: Rewrite the installer bootstrap with ASCII source**

Keep the parameter block first and render localized text from ASCII JSON escapes:

```powershell
function ConvertFrom-DshUnicodeText {
    param([Parameter(Mandatory = $true)][string]$EscapedText)
    return ConvertFrom-Json ('"' + $EscapedText + '"')
}

function Test-DshChildPath {
    param([string]$Parent, [string]$Candidate)
    $parentFull = [IO.Path]::GetFullPath($Parent).TrimEnd('\')
    $candidateFull = [IO.Path]::GetFullPath($Candidate).TrimEnd('\')
    return $candidateFull.StartsWith($parentFull + '\', [StringComparison]::OrdinalIgnoreCase)
}
```

Validate the normalized target against profile, `.dsh`, `dsh-launch`, and drive roots before creating it. Select the test archive only behind both test environment variables; otherwise retain the GitHub release download.

Replace the wildcard copy with literal child copying:

```powershell
$payloadItems = @(Get-ChildItem -LiteralPath $payloadRoot -Force -ErrorAction Stop)
foreach ($payloadItem in $payloadItems) {
    Copy-Item -LiteralPath $payloadItem.FullName -Destination $installFull -Recurse -Force
}
```

Write the marker without BOM:

```powershell
$owner = [ordered]@{
    SchemaVersion = 1
    InstallPath = $installFull
    InstallationId = [guid]::NewGuid().ToString('N')
}
[IO.File]::WriteAllText(
    (Join-Path $installFull '.dsh-launcher-owner.json'),
    ($owner | ConvertTo-Json),
    [Text.UTF8Encoding]::new($false)
)
```

- [ ] **Step 4: Run installer and package tests**

Run:

```powershell
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\install-behavior.Tests.ps1
if ($LASTEXITCODE -ne 0) { throw 'installer behavior failed' }
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\release-package-behavior.Tests.ps1
if ($LASTEXITCODE -ne 0) { throw 'release package behavior failed' }
```

Expected: both commands exit 0, and the installer test never performs a network request.

- [ ] **Step 5: Commit the installer fix**

```powershell
git add install.ps1 tests/install-behavior.Tests.ps1 tests/release-package-behavior.Tests.ps1
git commit -m '修复安装器复制与 PowerShell 兼容性'
```

### Task 3: Correct CLI modifiers, numeric arguments, and exact exit propagation

**Files:**
- Modify: `deepseek.cmd:1-206`
- Modify: `tests/startup-behavior.Tests.ps1:690-773`
- Modify: `README.md:102-120`
- Modify: `README.en.md:104-122`

**Interfaces:**
- Consumes: CLI tokens accepted by `deepseek.cmd`.
- Produces: one canonical action, optional `FULL=1`, optional numeric `LOG_COUNT`, and the exact child PowerShell exit code.

- [ ] **Step 1: Strengthen the failing CMD behavior tests**

Change the full-uninstall test to inspect the fake process log rather than general output:

```powershell
$full = Invoke-DeepseekCommand -Argument '--uninstall --full'
Assert-Equal 0 $full.ExitCode '--uninstall --full should dispatch normally'
Assert-Match $full.ProcessLog 'uninstall\.ps1.*(?:^|\s)-Full(?:\s|$)' 'Full uninstall must pass -Full to PowerShell'
```

Add these rejection cases and assert no foreground or action script dispatch:

```powershell
foreach ($argument in @('20', '--status 20', '20 --logs', '--logs 20 30')) {
    $result = Invoke-DeepseekCommand -Argument $argument
    Assert-Equal 1 $result.ExitCode "Invalid numeric placement must fail: $argument"
    Assert-Match $result.Output 'Unknown argument|Invalid.*logs|Usage:' 'The error must be actionable'
    Assert-NotMatch $result.ProcessLog 'run-dsh\.ps1|dsh-launch-state\.ps1' 'Invalid input must not dispatch'
}
```

Add a success case for `--logs 50`, and a table covering nonzero child exits for the PowerShell-backed background, stop, status, logs, upgrade, update, version, uninstall, and foreground actions. Assert the internal `--check` action returns 0 when its checks complete.

- [ ] **Step 2: Run startup behavior and verify `-Full` or numeric tests fail**

Run:

```powershell
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\startup-behavior.Tests.ps1
if ($LASTEXITCODE -eq 0) { throw 'Expected strengthened startup behavior to fail before implementation' }
```

- [ ] **Step 3: Implement modifier-aware classification**

Keep `ACTION`, `FULL`, and `LOG_COUNT` separate. In the token classifier:

```bat
if /i "%CLASSIFY_TOKEN%"=="--full" (
    if defined FULL set "BADARG=duplicate --full"
    set "FULL=1"
    goto :eof
)

echo(%CLASSIFY_TOKEN%| findstr /r /c:"^[0-9][0-9]*$" >nul 2>&1
if not errorlevel 1 (
    if /i not "%ACTION%"=="logs" set "BADARG=%CLASSIFY_TOKEN%"
    if defined LOG_COUNT set "BADARG=%CLASSIFY_TOKEN%"
    set "LOG_COUNT=%CLASSIFY_TOKEN%"
    goto :eof
)
```

After classification, reject `FULL` unless `ACTION` is uninstall. Dispatch uninstall as:

```bat
:uninstall
echo Removing deepseek command from PATH...
if defined FULL (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0uninstall.ps1" -Full
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0uninstall.ps1"
)
set "DSH_RC=%ERRORLEVEL%"
exit /b %DSH_RC%
```

Capture every other PowerShell exit code into `DSH_RC` immediately before printing or branching.

- [ ] **Step 4: Run CLI, package, and whitespace checks**

Run:

```powershell
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\startup-behavior.Tests.ps1
if ($LASTEXITCODE -ne 0) { throw 'startup behavior failed' }
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\release-package-behavior.Tests.ps1
if ($LASTEXITCODE -ne 0) { throw 'release package behavior failed' }
git diff --check
if ($LASTEXITCODE -ne 0) { throw 'diff check failed' }
```

- [ ] **Step 5: Update the bilingual CLI contract and commit**

Document that `--full` reaches the transactional full uninstaller, numeric values are valid only after `--logs`, and nonzero exit codes propagate.

```powershell
git add deepseek.cmd tests/startup-behavior.Tests.ps1 README.md README.en.md
git commit -m '修复 CLI 修饰符与退出码传播'
```
