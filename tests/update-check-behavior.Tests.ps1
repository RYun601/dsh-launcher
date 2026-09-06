$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$updateScript = Join-Path $repoRoot 'update-check.ps1'
$testRoot = Join-Path $env:TEMP ('dsh-update-tests-' + [guid]::NewGuid().ToString('N'))
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

# R7 acceptance: the update check must read the active runtime pointer instead
# of scanning caches and global installs, must label secondary sources, must
# never treat an unknown local version as "already latest", and must exit
# nonzero when the remote resolution fails.
function New-UpdateFixture {
    param(
        [string]$Name,
        [string]$PointerVersion = '',
        [switch]$CorruptPointer,
        [string]$LegacyVersion = '',
        [switch]$LegacyReady,
        [string]$GlobalVersion = '',
        [string]$CacheVersion = '',
        [switch]$NpmFails
    )

    $root = Join-Path $testRoot $Name
    $profileRoot = Join-Path $root 'profile'
    $fakeBin = Join-Path $root 'fake-bin'
    $launchDir = Join-Path $profileRoot 'dsh-launch'
    New-Item -ItemType Directory -Force -Path $launchDir, $fakeBin | Out-Null

    if ($CorruptPointer) {
        [IO.File]::WriteAllText((Join-Path $launchDir 'runtime-current.json'), '{not json', [Text.Encoding]::ASCII)
    } elseif ($PointerVersion) {
        $runtimeDir = Join-Path $launchDir ("runtime-versions\runtime-$PointerVersion")
        $dshRoot = Join-Path $runtimeDir 'node_modules\@deepseek-ai\dsh'
        New-Item -ItemType Directory -Force -Path (Join-Path $dshRoot 'lib') | Out-Null
        $fakeEntry = "#!/usr/bin/env node`r`n" + (('// fake dsh entrypoint' + "`r`n") * 80)
        [IO.File]::WriteAllText((Join-Path $dshRoot 'lib\bin.js'), $fakeEntry, [Text.Encoding]::ASCII)
        [IO.File]::WriteAllText(
            (Join-Path $dshRoot 'package.json'),
            ('{"name":"@deepseek-ai/dsh","version":"' + $PointerVersion + '"}'),
            [Text.Encoding]::ASCII
        )
        [IO.File]::WriteAllText(
            (Join-Path $runtimeDir 'dsh-runtime-ready.json'),
            ('{"SchemaVersion": 2, "Version": "' + $PointerVersion + '", "ValidatedBy": "npm-ls-all"}'),
            [Text.UTF8Encoding]::new($false)
        )
        $pointer = [ordered]@{
            SchemaVersion = 1
            Current = [ordered]@{ Path = ('runtime-versions\runtime-' + $PointerVersion); Version = $PointerVersion }
            Previous = $null
        }
        [IO.File]::WriteAllText(
            (Join-Path $launchDir 'runtime-current.json'),
            ($pointer | ConvertTo-Json -Depth 5),
            [Text.UTF8Encoding]::new($false)
        )
    }

    if ($LegacyVersion) {
        $legacyDshRoot = Join-Path $launchDir 'runtime\node_modules\@deepseek-ai\dsh'
        New-Item -ItemType Directory -Force -Path $legacyDshRoot | Out-Null
        [IO.File]::WriteAllText(
            (Join-Path $legacyDshRoot 'package.json'),
            ('{"name":"@deepseek-ai/dsh","version":"' + $LegacyVersion + '"}'),
            [Text.Encoding]::ASCII
        )
        if ($LegacyReady) {
            $fakeEntry = "#!/usr/bin/env node`r`n" + (('// fake dsh entrypoint' + "`r`n") * 80)
            New-Item -ItemType Directory -Force -Path (Join-Path $legacyDshRoot 'lib') | Out-Null
            [IO.File]::WriteAllText((Join-Path $legacyDshRoot 'lib\bin.js'), $fakeEntry, [Text.Encoding]::ASCII)
            [IO.File]::WriteAllText(
                (Join-Path $launchDir 'runtime\dsh-runtime-ready.json'),
                ('{"SchemaVersion": 2, "Version": "' + $LegacyVersion + '", "ValidatedBy": "npm-ls-all"}'),
                [Text.UTF8Encoding]::new($false)
            )
        }
    }

    if ($GlobalVersion) {
        $globalDshRoot = Join-Path $root 'app-data\npm\node_modules\@deepseek-ai\dsh'
        New-Item -ItemType Directory -Force -Path $globalDshRoot | Out-Null
        [IO.File]::WriteAllText(
            (Join-Path $globalDshRoot 'package.json'),
            ('{"name":"@deepseek-ai/dsh","version":"' + $GlobalVersion + '"}'),
            [Text.Encoding]::ASCII
        )
    }

    if ($CacheVersion) {
        $cacheDshRoot = Join-Path $root 'local-app-data\npm-cache\_npx\ws-1\node_modules\@deepseek-ai\dsh'
        New-Item -ItemType Directory -Force -Path $cacheDshRoot | Out-Null
        [IO.File]::WriteAllText(
            (Join-Path $cacheDshRoot 'package.json'),
            ('{"name":"@deepseek-ai/dsh","version":"' + $CacheVersion + '"}'),
            [Text.Encoding]::ASCII
        )
    }

    if ($NpmFails) {
        [IO.File]::WriteAllText((Join-Path $fakeBin 'npm.cmd'), "@echo off`r`nexit /b 1`r`n", [Text.Encoding]::ASCII)
    } else {
        [IO.File]::WriteAllText(
            (Join-Path $fakeBin 'npm.cmd'),
            "@echo off`r`necho {`"latest`":`"0.1.0-rc.8`"}`r`nexit /b 0`r`n",
            [Text.Encoding]::ASCII
        )
    }

    return [pscustomobject]@{
        Root          = $root
        ProfileRoot   = $profileRoot
        FakeBin       = $fakeBin
        AppData       = (Join-Path $root 'app-data')
        LocalAppData  = (Join-Path $root 'local-app-data')
    }
}

function Invoke-UpdateCheck {
    param([pscustomobject]$Fixture)

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = 'powershell.exe'
    $startInfo.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$updateScript`""
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.EnvironmentVariables['PATH'] = "$($Fixture.FakeBin);$env:PATH"
    $startInfo.EnvironmentVariables['USERPROFILE'] = $Fixture.ProfileRoot
    $startInfo.EnvironmentVariables['LOCALAPPDATA'] = $Fixture.LocalAppData
    $startInfo.EnvironmentVariables['APPDATA'] = $Fixture.AppData
    # Keep the registry fast path off the real network; the unreachable
    # endpoint makes the resolver fall back to the fake npm command.
    $startInfo.EnvironmentVariables['DSH_REGISTRY'] = 'http://127.0.0.1:9'
    $startInfo.EnvironmentVariables['DSH_TEST_MODE'] = '1'

    $process = [Diagnostics.Process]::Start($startInfo)
    if (-not $process.WaitForExit(20000)) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        throw 'update-check.ps1 did not finish promptly'
    }
    return [pscustomobject]@{
        ExitCode = $process.ExitCode
        Output = $process.StandardOutput.ReadToEnd() + $process.StandardError.ReadToEnd()
    }
}

try {
    Invoke-Test 'update check reports the active pointer runtime version' {
        $fixture = New-UpdateFixture -Name 'pointer-active' -PointerVersion '0.1.0-rc.8'
        $result = Invoke-UpdateCheck -Fixture $fixture
        Assert-Equal 0 $result.ExitCode "Update check should succeed. Output:`n$($result.Output)"
        Assert-Match $result.Output ([regex]::Escape('runtime-current')) 'The active source must be labeled as the runtime-current pointer'
        $versionMentions = [regex]::Matches($result.Output, '0\.1\.0-rc\.8').Count
        Assert-Equal 2 $versionMentions 'The active version should appear as local and latest'
        Assert-Match $result.Output ([regex]::Escape('已是最新版本')) 'A current install must be reported as up to date'
    }

    Invoke-Test 'update check labels a legacy runtime that differs from the active pointer' {
        $fixture = New-UpdateFixture -Name 'pointer-vs-legacy' -PointerVersion '0.1.0-rc.7' -LegacyVersion '0.1.0-rc.6'
        $result = Invoke-UpdateCheck -Fixture $fixture
        Assert-Equal 0 $result.ExitCode "Update check should succeed. Output:`n$($result.Output)"
        Assert-Match $result.Output ([regex]::Escape('0.1.0-rc.7')) 'The active pointer version must be the local version'
        Assert-Match $result.Output ([regex]::Escape('旧目录 0.1.0-rc.6')) 'The differing legacy runtime must be labeled as inactive'
        Assert-Match $result.Output ([regex]::Escape('有新版本可用')) 'rc.7 vs rc.8 latest must report an upgrade path'
    }

    Invoke-Test 'update check keeps a higher global install informational only' {
        $fixture = New-UpdateFixture -Name 'global-higher' -PointerVersion '0.1.0-rc.8' -GlobalVersion '9.9.9' -CacheVersion '9.8.9'
        $result = Invoke-UpdateCheck -Fixture $fixture
        Assert-Equal 0 $result.ExitCode "Update check should succeed. Output:`n$($result.Output)"
        Assert-Match $result.Output ([regex]::Escape('全局安装 9.9.9')) 'The higher global install must be reported'
        Assert-Match $result.Output ([regex]::Escape('npx 缓存 9.8.9')) 'The cache version must be reported'
        Assert-Match $result.Output ([regex]::Escape('已是最新版本')) 'A higher global install must not flip the comparison target'
    }

    Invoke-Test 'update check never reports already-latest when the active version is unknown' {
        $fixture = New-UpdateFixture -Name 'no-runtime'
        $result = Invoke-UpdateCheck -Fixture $fixture
        Assert-Equal 1 $result.ExitCode 'An unknown active version must fail the check'
        Assert-Match $result.Output ([regex]::Escape('无法确认')) 'The output must state the version could not be confirmed'
        Assert-NotMatch $result.Output ([regex]::Escape('已是最新版本')) 'Unknown must never mean already latest'
    }

    Invoke-Test 'update check reports a corrupted runtime pointer as a failure' {
        $fixture = New-UpdateFixture -Name 'corrupt-pointer' -CorruptPointer
        $result = Invoke-UpdateCheck -Fixture $fixture
        Assert-Equal 1 $result.ExitCode 'A corrupted pointer must fail the check'
        Assert-Match $result.Output ([regex]::Escape('指针不可读')) 'The output must name the unreadable pointer'
    }

    Invoke-Test 'update check exits nonzero when the remote version cannot be resolved' {
        $fixture = New-UpdateFixture -Name 'remote-fails' -PointerVersion '0.1.0-rc.8' -NpmFails
        $result = Invoke-UpdateCheck -Fixture $fixture
        Assert-Equal 1 $result.ExitCode 'A failed remote resolution must exit nonzero'
        Assert-Match $result.Output ([regex]::Escape('无法获取最新版本')) 'The output must state the remote resolution failed'
    }

    Write-Host "All $script:Passed update check behavior tests passed."
} finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}

exit 0
