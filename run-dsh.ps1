param(
    [Parameter(Mandatory = $true)]
    [string]$Version,

    [string]$RuntimeRoot,

    [string[]]$DshArguments = @('web'),

    [switch]$NoOpen
)

$ErrorActionPreference = 'Stop'

$launchRoot = [IO.Path]::GetFullPath((Join-Path $env:USERPROFILE 'dsh-launch'))
if (-not $RuntimeRoot) {
    $RuntimeRoot = Join-Path $launchRoot 'runtime'
}
$RuntimeRoot = [IO.Path]::GetFullPath($RuntimeRoot)
$launchRootPrefix = $launchRoot.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
if (-not $RuntimeRoot.StartsWith($launchRootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "RuntimeRoot must be inside the launcher-owned directory: $launchRoot"
}

$nodeModules = Join-Path $RuntimeRoot 'node_modules'
$dshRoot = Join-Path (Join-Path $nodeModules '@deepseek-ai') 'dsh'
$dshEntrypoint = Join-Path $dshRoot 'lib\bin.js'
$readyMarker = Join-Path $RuntimeRoot 'dsh-runtime-ready.json'
$auditLog = Join-Path $RuntimeRoot 'dsh-dependency-audit.log'

function Test-RuntimeReady {
    if (-not (Test-Path -LiteralPath $readyMarker) -or -not (Test-Path -LiteralPath $dshEntrypoint)) {
        return $false
    }

    try {
        $ready = Get-Content -LiteralPath $readyMarker -Raw -Encoding UTF8 | ConvertFrom-Json
        return [string]$ready.Version -eq $Version -and
            [int]$ready.SchemaVersion -eq 2 -and
            [string]$ready.ValidatedBy -eq 'npm-ls-all'
    } catch {
        return $false
    }
}

function Test-RuntimeInstalledVersion {
    if (-not (Test-Path -LiteralPath $dshEntrypoint)) { return $false }
    $packageJson = Join-Path $dshRoot 'package.json'
    if (-not (Test-Path -LiteralPath $packageJson)) { return $false }
    try {
        $package = Get-Content -LiteralPath $packageJson -Raw -Encoding UTF8 | ConvertFrom-Json
        return [string]$package.name -eq '@deepseek-ai/dsh' -and [string]$package.version -eq $Version
    } catch {
        return $false
    }
}

function Invoke-NpmInstall {
    param([Parameter(Mandatory = $true)][string[]]$PackageSpecs)

    $npmArguments = @(
        'install',
        '--prefix', $RuntimeRoot,
        '--legacy-peer-deps',
        '--save-exact',
        '--no-audit',
        '--no-fund'
    ) + $PackageSpecs

    & npm.cmd @npmArguments
    if ($LASTEXITCODE -ne 0) {
        throw "npm install failed with exit code $LASTEXITCODE"
    }
}

function Get-MissingRequiredPeers {
    $missing = @{}
    if (-not (Test-Path -LiteralPath $nodeModules)) {
        return $missing
    }

    Get-ChildItem -LiteralPath $nodeModules -Filter 'package.json' -File -Recurse -ErrorAction Stop | ForEach-Object {
        try {
            $package = Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        } catch {
            return
        }

        if (-not $package.peerDependencies) {
            return
        }

        foreach ($peer in @($package.peerDependencies.PSObject.Properties)) {
            $isOptional = $false
            if ($package.peerDependenciesMeta) {
                $meta = @($package.peerDependenciesMeta.PSObject.Properties | Where-Object { $_.Name -eq $peer.Name })
                $isOptional = $meta.Count -gt 0 -and [bool]$meta[0].Value.optional
            }
            if ($isOptional) {
                continue
            }

            $relativePeerPath = $peer.Name.Replace('/', [IO.Path]::DirectorySeparatorChar)
            $peerPackageJson = Join-Path (Join-Path $nodeModules $relativePeerPath) 'package.json'
            if (-not (Test-Path -LiteralPath $peerPackageJson) -and -not $missing.ContainsKey($peer.Name)) {
                $missing[$peer.Name] = [string]$peer.Value
            }
        }
    }

    return $missing
}

function Invoke-NpmDependencyAudit {
    $npmCommand = @(Get-Command 'npm.cmd' -CommandType Application -ErrorAction Stop)[0]
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

function Repair-KnownPeerConflict {
    param([Parameter(Mandatory = $true)][pscustomobject]$Audit)

    if ($Audit.Output -notmatch '(?i)invalid:\s+react@') { return $false }

    $reactPackage = Join-Path $nodeModules 'react\package.json'
    $reactDomPackage = Join-Path $nodeModules 'react-dom\package.json'
    if (-not (Test-Path -LiteralPath $reactPackage) -or -not (Test-Path -LiteralPath $reactDomPackage)) {
        return $false
    }

    # rc.8 currently resolves React 19 next to use-sync-external-store@1.2.0,
    # whose required peer range ends at React 18. Keep the renderer pair aligned.
    Write-Output 'Repairing the incompatible React peer pair with React 18.3.1...'
    Invoke-NpmInstall -PackageSpecs @('react@18.3.1', 'react-dom@18.3.1')
    return $true
}

function Write-AuditFailure {
    param([Parameter(Mandatory = $true)][pscustomobject]$Audit)

    [IO.File]::WriteAllText($auditLog, $Audit.Output, [Text.UTF8Encoding]::new($false))
    $details = @($Audit.Output -split "`r?`n" | Where-Object { $_ } | Select-Object -First 12) -join [Environment]::NewLine
    throw "DSH runtime dependency validation failed (npm ls exit $($Audit.ExitCode)). Audit: $auditLog$([Environment]::NewLine)$details"
}

function Get-RuntimeMutexName {
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($RuntimeRoot.ToUpperInvariant())
        $hash = $sha256.ComputeHash($bytes)
        $suffix = -join @($hash[0..11] | ForEach-Object { $_.ToString('x2') })
        return "Local\DeepSeekHarnessRuntime-$suffix"
    } finally {
        $sha256.Dispose()
    }
}

$runtimeMutex = [Threading.Mutex]::new($false, (Get-RuntimeMutexName))
$ownsRuntimeMutex = $false
$nodeExitCode = 1
try {
    try {
        $ownsRuntimeMutex = $runtimeMutex.WaitOne(0)
        if (-not $ownsRuntimeMutex) {
            Write-Output 'Another DeepSeek Harness process is using the managed runtime; waiting...'
            $ownsRuntimeMutex = $runtimeMutex.WaitOne([TimeSpan]::FromMinutes(15))
        }
    } catch [Threading.AbandonedMutexException] {
        $ownsRuntimeMutex = $true
    }
    if (-not $ownsRuntimeMutex) {
        throw 'Timed out waiting for exclusive access to the managed DSH runtime'
    }

    if (-not (Test-RuntimeReady)) {
        if (-not (Test-RuntimeInstalledVersion)) {
            if (Test-Path -LiteralPath $RuntimeRoot) {
                Remove-Item -LiteralPath $RuntimeRoot -Recurse -Force
            }
            New-Item -ItemType Directory -Force -Path $RuntimeRoot | Out-Null

            Write-Output "Preparing DeepSeek Harness runtime $Version..."
            Invoke-NpmInstall -PackageSpecs @("@deepseek-ai/dsh@$Version")
        } else {
            Write-Output "Validating existing DeepSeek Harness runtime $Version..."
        }

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
        if ($remainingPeers.Count -gt 0) {
            throw "DSH runtime is missing $($remainingPeers.Count) required peer dependencies after preparation"
        }
        if (-not (Test-Path -LiteralPath $dshEntrypoint)) {
            throw "DSH entrypoint was not installed: $dshEntrypoint"
        }

        $audit = Invoke-NpmDependencyAudit
        if ($audit.ExitCode -ne 0 -and (Repair-KnownPeerConflict -Audit $audit)) {
            $audit = Invoke-NpmDependencyAudit
        }
        if ($audit.ExitCode -ne 0) { Write-AuditFailure -Audit $audit }
        if (Test-Path -LiteralPath $auditLog) { Remove-Item -LiteralPath $auditLog -Force }

        $marker = [ordered]@{
            SchemaVersion = 2
            Version = $Version
            PreparedAt = (Get-Date).ToString('o')
            ValidatedBy = 'npm-ls-all'
        }
        $temporaryMarker = Join-Path $RuntimeRoot ('dsh-runtime-ready-' + [guid]::NewGuid().ToString('N') + '.tmp')
        [IO.File]::WriteAllText(
            $temporaryMarker,
            ($marker | ConvertTo-Json),
            [Text.UTF8Encoding]::new($false)
        )
        Move-Item -LiteralPath $temporaryMarker -Destination $readyMarker -Force
    }

    if ($NoOpen -and $DshArguments -notcontains '--no-open') {
        $DshArguments = @($DshArguments) + '--no-open'
    }
    & node $dshEntrypoint @DshArguments
    $nodeExitCode = $LASTEXITCODE
} finally {
    if ($ownsRuntimeMutex) { $runtimeMutex.ReleaseMutex() }
    $runtimeMutex.Dispose()
}
exit $nodeExitCode
