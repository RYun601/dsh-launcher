$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$resolver = Join-Path $repoRoot 'resolve-dsh-version.ps1'
$testRoot = Join-Path $env:TEMP ('dsh-version-resolution-tests-' + [guid]::NewGuid().ToString('N'))
$profileRoot = Join-Path $testRoot 'profile'
$runtimeRoot = Join-Path $profileRoot 'dsh-launch\runtime'
$fakeBin = Join-Path $testRoot 'fake-bin'
$npmLog = Join-Path $testRoot 'npm.log'
$script:Passed = 0

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    if ($Expected -ne $Actual) {
        throw "$Message (expected: $Expected, actual: $Actual)"
    }
}

function Assert-Match {
    param([string]$Actual, [string]$Pattern, [string]$Message)
    if ($Actual -notmatch $Pattern) {
        throw "$Message`nActual:`n$Actual"
    }
}

function Invoke-Test {
    param([string]$Name, [scriptblock]$Body)
    & $Body
    $script:Passed++
    Write-Host "PASS: $Name"
}

function Reset-TestRuntime {
    if (Test-Path -LiteralPath $runtimeRoot) {
        Remove-Item -LiteralPath $runtimeRoot -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $runtimeRoot | Out-Null
}

function Reset-NpmLog {
    [IO.File]::WriteAllText($npmLog, '', [Text.Encoding]::ASCII)
}

function Read-NpmLog {
    if (-not (Test-Path -LiteralPath $npmLog)) { return '' }
    return [IO.File]::ReadAllText($npmLog).Trim()
}

function New-TestRuntime {
    param(
        [Parameter(Mandatory = $true)][string]$Version,
        [switch]$Ready,
        [string]$ReadyVersion = '',
        [switch]$OmitEntrypoint
    )

    $dshRoot = Join-Path $runtimeRoot 'node_modules\@deepseek-ai\dsh'
    New-Item -ItemType Directory -Force -Path (Join-Path $dshRoot 'lib') | Out-Null
    [IO.File]::WriteAllText(
        (Join-Path $dshRoot 'package.json'),
        (@{ name = '@deepseek-ai/dsh'; version = $Version } | ConvertTo-Json -Compress),
        [Text.UTF8Encoding]::new($false)
    )
    if (-not $OmitEntrypoint) {
        [IO.File]::WriteAllText((Join-Path $dshRoot 'lib\bin.js'), '// fake dsh', [Text.Encoding]::ASCII)
    }
    if ($Ready -or $ReadyVersion) {
        $markerVersion = if ($ReadyVersion) { $ReadyVersion } else { $Version }
        [IO.File]::WriteAllText(
            (Join-Path $runtimeRoot 'dsh-runtime-ready.json'),
            (@{
                SchemaVersion = 2
                Version = $markerVersion
                ValidatedBy = 'npm-ls-all'
            } | ConvertTo-Json -Compress),
            [Text.UTF8Encoding]::new($false)
        )
    }
}

function Invoke-Resolver {
    param(
        [switch]$PreferLocalRuntime,
        # Registry the resolver's direct HTTP fast path should query. The
        # default points at an unreachable loopback port so tests never touch
        # the real registry and the resolver falls back to the fake npm.
        [string]$Registry = 'http://127.0.0.1:9'
    )

    $previousPath = $env:PATH
    $previousProfile = $env:USERPROFILE
    $previousLog = $env:DSH_TEST_NPM_LOG
    $previousRegistry = $env:DSH_REGISTRY
    try {
        $env:PATH = "$fakeBin;$previousPath"
        $env:USERPROFILE = $profileRoot
        $env:DSH_TEST_NPM_LOG = $npmLog
        $env:DSH_REGISTRY = $Registry
        $arguments = @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass',
            '-File', $resolver,
            '-RuntimeRoot', $runtimeRoot
        )
        if ($PreferLocalRuntime) { $arguments += '-PreferLocalRuntime' }
        $output = @(& powershell.exe @arguments 2>&1)
        return [pscustomobject]@{
            ExitCode = $LASTEXITCODE
            Output = [string]($output -join [Environment]::NewLine)
        }
    } finally {
        $env:PATH = $previousPath
        $env:USERPROFILE = $previousProfile
        $env:DSH_TEST_NPM_LOG = $previousLog
        $env:DSH_REGISTRY = $previousRegistry
    }
}

New-Item -ItemType Directory -Force -Path $testRoot, $profileRoot, $fakeBin | Out-Null
try {
    [IO.File]::WriteAllText(
        (Join-Path $fakeBin 'npm.cmd'),
        "@echo off`r`necho %*>>`"%DSH_TEST_NPM_LOG%`"`r`necho {`"latest`":`"0.1.0-rc.9`",`"next`":`"0.1.0-rc.10`"}`r`nexit /b 0`r`n",
        [Text.Encoding]::ASCII
    )

    Invoke-Test 'prepared runtime wins without invoking npm' {
        Reset-TestRuntime
        Reset-NpmLog
        New-TestRuntime -Version '0.1.0-rc.8' -Ready

        $result = Invoke-Resolver -PreferLocalRuntime

        Assert-Equal 0 $result.ExitCode "Prepared resolution should succeed. Output:`n$($result.Output)"
        Assert-Equal '0.1.0-rc.8' $result.Output.Trim() 'Prepared version should be selected'
        Assert-Equal '' (Read-NpmLog) 'Prepared startup must not contact npm'
    }

    Invoke-Test 'installed runtime without marker is reused without invoking npm' {
        Reset-TestRuntime
        Reset-NpmLog
        New-TestRuntime -Version '0.1.0-rc.7'

        $result = Invoke-Resolver -PreferLocalRuntime

        Assert-Equal 0 $result.ExitCode "Installed resolution should succeed. Output:`n$($result.Output)"
        Assert-Equal '0.1.0-rc.7' $result.Output.Trim() 'Installed version should be selected for revalidation'
        Assert-Equal '' (Read-NpmLog) 'Local repair must not require registry discovery'
    }

    Invoke-Test 'mismatched ready marker falls back to the valid installed package' {
        Reset-TestRuntime
        Reset-NpmLog
        New-TestRuntime -Version '0.1.0-rc.7' -ReadyVersion '0.1.0-rc.8'

        $result = Invoke-Resolver -PreferLocalRuntime

        Assert-Equal 0 $result.ExitCode "Marker fallback should succeed. Output:`n$($result.Output)"
        Assert-Equal '0.1.0-rc.7' $result.Output.Trim() 'Invalid marker must not hide a repairable local package'
        Assert-Equal '' (Read-NpmLog) 'Repairable local metadata must not contact npm'
    }

    Invoke-Test 'invalid local installation falls back to published tags' {
        Reset-TestRuntime
        Reset-NpmLog
        New-TestRuntime -Version '0.1.0-rc.7' -OmitEntrypoint

        $result = Invoke-Resolver -PreferLocalRuntime

        Assert-Equal 0 $result.ExitCode "Registry fallback should succeed. Output:`n$($result.Output)"
        Assert-Equal '0.1.0-rc.10' $result.Output.Trim() 'Invalid local installation must fall back to npm'
        Assert-Match (Read-NpmLog) '^view @deepseek-ai/dsh dist-tags --json$' 'Fallback must query dist-tags'
    }

    Invoke-Test 'registry mode ignores a prepared runtime' {
        Reset-TestRuntime
        Reset-NpmLog
        New-TestRuntime -Version '0.1.0-rc.8' -Ready

        $result = Invoke-Resolver

        Assert-Equal 0 $result.ExitCode "Registry resolution should succeed. Output:`n$($result.Output)"
        Assert-Equal '0.1.0-rc.10' $result.Output.Trim() 'Explicit release discovery must use npm'
        Assert-Match (Read-NpmLog) '^view @deepseek-ai/dsh dist-tags --json$' 'Registry mode must query dist-tags'
    }

    Invoke-Test 'direct registry query returns the highest dist-tag without invoking npm' {
        Reset-TestRuntime
        Reset-NpmLog
        # Serve dist-tags from a throwaway loopback endpoint so the resolver's
        # HTTP fast path is exercised without touching the real registry. The
        # listener lives in a background job and signals readiness through a
        # marker file; it speaks a minimal HTTP/1.1 response itself.
        $probe = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
        $probe.Start()
        $port = ([Net.IPEndPoint]$probe.LocalEndpoint).Port
        $probe.Stop()
        $baseUrl = "http://127.0.0.1:$port"
        $markerPath = Join-Path $testRoot ('http-ready-' + [guid]::NewGuid().ToString('N') + '.txt')

        $listenerJob = Start-Job -ScriptBlock {
            param($TargetPort, $Marker)
            $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $TargetPort)
            $listener.Start()
            [IO.File]::WriteAllText($Marker, 'ready', [Text.Encoding]::ASCII)
            $client = $listener.AcceptTcpClient()
            $stream = $client.GetStream()
            $buffer = New-Object byte[] 8192
            $null = $stream.Read($buffer, 0, $buffer.Length)
            $body = '{"latest":"0.1.0-rc.9","next":"0.1.0-rc.10"}'
            $payload = [Text.Encoding]::UTF8.GetBytes($body)
            $head = "HTTP/1.1 200 OK`r`nContent-Type: application/json`r`nContent-Length: $($payload.Length)`r`nConnection: close`r`n`r`n"
            $headBytes = [Text.Encoding]::ASCII.GetBytes($head)
            $stream.Write($headBytes, 0, $headBytes.Length)
            $stream.Write($payload, 0, $payload.Length)
            $stream.Flush()
            $client.Close()
            $listener.Stop()
        } -ArgumentList @($port, $markerPath)

        try {
            $readyDeadline = (Get-Date).AddSeconds(10)
            while (-not (Test-Path -LiteralPath $markerPath) -and (Get-Date) -lt $readyDeadline) {
                Start-Sleep -Milliseconds 50
            }
            if (-not (Test-Path -LiteralPath $markerPath)) {
                throw 'Test HTTP endpoint did not become ready'
            }

            $result = Invoke-Resolver -Registry $baseUrl

            Assert-Equal 0 $result.ExitCode "HTTP resolution should succeed. Output:`n$($result.Output)"
            Assert-Equal '0.1.0-rc.10' $result.Output.Trim() 'The highest dist-tag must be selected'
            Assert-Equal '' (Read-NpmLog) 'A reachable registry fast path must not invoke npm'
        } finally {
            Stop-Job -Job $listenerJob -ErrorAction SilentlyContinue
            Remove-Job -Job $listenerJob -Force -ErrorAction SilentlyContinue
        }
    }

    Write-Host "All $script:Passed version resolution behavior tests passed."
} finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}

exit 0
