param(
    [Parameter(Mandatory = $true)]
    [ValidateSet(
        'ClearDshNpxWorkspaces',
        'AcquireStartupLock',
        'TestStartupLock',
        'ReleaseStartupLock',
        'WriteStartupState',
        'RecordStartupExit',
        'GetStartupState',
        'GetStartupSnapshot',
        'GetStatus'
    )]
    [string]$Action,

    [string]$CacheRoot,

    [string]$LaunchRoot,

    [int]$OwnerPid = 0,

    [string]$StartupToken,

    [string]$CommandPath,

    [string]$ScriptPath,

    [switch]$TransferOwnership,

    [ValidateSet('STARTING', 'READY', 'RUNNING', 'UNHEALTHY', 'FAILED')]
    [string]$State,

    [string]$Version,

    [string]$Message,

    [int]$ExitCode = 0,

    [int]$ServicePid = 0,

    [string]$RuntimeRoot,

    [string]$Entrypoint,

    [int]$Port = 3080
)

$ErrorActionPreference = 'Stop'
$serviceHealthHelper = Join-Path $PSScriptRoot 'dsh-service-health.ps1'
. $serviceHealthHelper

function Test-DshNpxWorkspace {
    param([Parameter(Mandatory = $true)][string]$Path)

    $packageJson = Join-Path $Path 'package.json'
    if (-not (Test-Path -LiteralPath $packageJson)) {
        return $false
    }

    try {
        $package = Get-Content -LiteralPath $packageJson -Raw | ConvertFrom-Json
    } catch {
        return $false
    }

    $npxPackages = @($package._npx.packages | ForEach-Object { [string]$_ })
    if ($npxPackages -contains '@deepseek-ai/dsh') {
        return $true
    }

    return $null -ne $package.dependencies.'@deepseek-ai/dsh'
}

function Get-LaunchRoot {
    if ($LaunchRoot) {
        return $LaunchRoot
    }
    return Join-Path $env:USERPROFILE 'dsh-launch'
}

function Get-StartupPaths {
    param([Parameter(Mandatory = $true)][string]$Root)

    return [pscustomobject]@{
        Root      = $Root
        Lock      = Join-Path $Root 'dsh-startup.lock'
        LockGuard = Join-Path $Root 'dsh-startup.lock.guard'
        LockIdentity = Join-Path (Join-Path $Root 'dsh-startup.lock') 'identity.json'
        LockOwner = Join-Path (Join-Path $Root 'dsh-startup.lock') 'pid.txt'
        LockToken = Join-Path (Join-Path $Root 'dsh-startup.lock') 'token.txt'
        LockCommandPath = Join-Path (Join-Path $Root 'dsh-startup.lock') 'command-path.txt'
        LockScriptPath = Join-Path (Join-Path $Root 'dsh-startup.lock') 'script-path.txt'
        LockCreatedAt = Join-Path (Join-Path $Root 'dsh-startup.lock') 'created-at.txt'
        State     = Join-Path $Root 'dsh-startup.json'
        Log       = Join-Path $Root 'dsh-background.log'
    }
}

function Ensure-LaunchRoot {
    param([Parameter(Mandatory = $true)][string]$Root)

    New-Item -ItemType Directory -Force -Path $Root | Out-Null
}

function ConvertTo-NormalizedPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ''
    }
    try {
        return [IO.Path]::GetFullPath($Path)
    } catch {
        return ''
    }
}

function Enter-StartupLockGuard {
    param([Parameter(Mandatory = $true)][pscustomobject]$Paths)

    Ensure-LaunchRoot -Root $Paths.Root
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    while ($true) {
        try {
            return [IO.File]::Open(
                $Paths.LockGuard,
                [IO.FileMode]::OpenOrCreate,
                [IO.FileAccess]::ReadWrite,
                [IO.FileShare]::None
            )
        } catch [IO.IOException] {
            if ([DateTime]::UtcNow -ge $deadline) {
                throw 'Timed out waiting for the startup lock serialization guard'
            }
            Start-Sleep -Milliseconds 25
        }
    }
}

function Exit-StartupLockGuard {
    param($Guard)

    if ($Guard) {
        $Guard.Dispose()
    }
}

function Get-StartupOwnerStatus {
    param(
        [int]$ProcessId,
        [string]$ExpectedCommandPath,
        [string]$ExpectedScriptPath
    )

    $normalizedCommandPath = ConvertTo-NormalizedPath -Path $ExpectedCommandPath
    $normalizedScriptPath = ConvertTo-NormalizedPath -Path $ExpectedScriptPath
    if ($ProcessId -le 0 -or -not $normalizedCommandPath -or -not $normalizedScriptPath) {
        return 'STALE'
    }

    $process = $null
    $querySucceeded = $false
    for ($attempt = 0; $attempt -lt 3; $attempt++) {
        try {
            $process = Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction Stop
            $querySucceeded = $true
            break
        } catch {
            if ($attempt -lt 2) {
                Start-Sleep -Milliseconds 50
            }
        }
    }
    if (-not $querySucceeded) {
        return 'UNKNOWN'
    }
    if (-not $process) {
        return 'STALE'
    }

    $actualCommandPath = ConvertTo-NormalizedPath -Path ([string]$process.ExecutablePath)
    if (-not $actualCommandPath -or -not [string]::Equals(
            $actualCommandPath,
            $normalizedCommandPath,
            [StringComparison]::OrdinalIgnoreCase)) {
        return 'STALE'
    }

    $actualCommandLine = [string]$process.CommandLine
    if ([string]::IsNullOrWhiteSpace($actualCommandLine)) {
        return 'UNKNOWN'
    }
    if (Test-DshCommandLineArgument -CommandLine $actualCommandLine `
            -ExpectedPath $normalizedScriptPath) {
        return 'ALIVE'
    }
    return 'STALE'
}

function Test-StartupOwnerAlive {
    param(
        [int]$ProcessId,
        [string]$ExpectedCommandPath,
        [string]$ExpectedScriptPath
    )

    return (Get-StartupOwnerStatus -ProcessId $ProcessId `
            -ExpectedCommandPath $ExpectedCommandPath -ExpectedScriptPath $ExpectedScriptPath) -eq 'ALIVE'
}

function Get-StartupLockInfo {
    param([Parameter(Mandatory = $true)][pscustomobject]$Paths)

    if (-not (Test-Path -LiteralPath $Paths.Lock)) {
        return [pscustomobject]@{
            Exists = $false
            OwnerPid = 0
            Token = ''
            CommandPath = ''
            ScriptPath = ''
            CreatedAt = ''
        }
    }

    $ownerPid = 0
    if (Test-Path -LiteralPath $Paths.LockOwner) {
        try {
            $candidate = (Get-Content -LiteralPath $Paths.LockOwner -Raw).Trim()
            $ownerPid = [int]$candidate
        } catch { }
    }

    $token = ''
    if (Test-Path -LiteralPath $Paths.LockToken) {
        try {
            $token = (Get-Content -LiteralPath $Paths.LockToken -Raw).Trim()
        } catch { }
    }

    if (Test-Path -LiteralPath $Paths.LockIdentity) {
        try {
            $identity = Get-Content -LiteralPath $Paths.LockIdentity -Raw | ConvertFrom-Json
            return [pscustomobject]@{
                Exists = $true
                OwnerPid = [int]$identity.OwnerPid
                Token = [string]$identity.Token
                CommandPath = [string]$identity.CommandPath
                ScriptPath = [string]$identity.ScriptPath
                CreatedAt = [string]$identity.CreatedAt
            }
        } catch {
            return [pscustomobject]@{
                Exists = $true
                OwnerPid = 0
                Token = ''
                CommandPath = ''
                ScriptPath = ''
                CreatedAt = ''
            }
        }
    }

    $commandPath = ''
    if (Test-Path -LiteralPath $Paths.LockCommandPath) {
        try { $commandPath = (Get-Content -LiteralPath $Paths.LockCommandPath -Raw).Trim() } catch { }
    }
    $scriptPath = ''
    if (Test-Path -LiteralPath $Paths.LockScriptPath) {
        try { $scriptPath = (Get-Content -LiteralPath $Paths.LockScriptPath -Raw).Trim() } catch { }
    }
    $createdAt = ''
    if (Test-Path -LiteralPath $Paths.LockCreatedAt) {
        try { $createdAt = (Get-Content -LiteralPath $Paths.LockCreatedAt -Raw).Trim() } catch { }
    }

    return [pscustomobject]@{
        Exists = $true
        OwnerPid = $ownerPid
        Token = $token
        CommandPath = $commandPath
        ScriptPath = $scriptPath
        CreatedAt = $createdAt
    }
}

function Write-StartupLockMetadata {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Paths,
        [Parameter(Mandatory = $true)][int]$NewOwnerPid,
        [string]$NewToken,
        [string]$NewCommandPath,
        [string]$NewScriptPath,
        [switch]$PreserveCreatedAt
    )

    if ($NewToken) {
        Set-Content -LiteralPath $Paths.LockToken -Value $NewToken -Encoding ASCII
    }
    $currentLock = if ($PreserveCreatedAt) { Get-StartupLockInfo -Paths $Paths } else { $null }
    $normalizedCommandPath = ConvertTo-NormalizedPath -Path $NewCommandPath
    if (-not $normalizedCommandPath -and $currentLock) { $normalizedCommandPath = [string]$currentLock.CommandPath }
    $normalizedScriptPath = ConvertTo-NormalizedPath -Path $NewScriptPath
    if (-not $normalizedScriptPath -and $currentLock) { $normalizedScriptPath = [string]$currentLock.ScriptPath }
    $effectiveToken = if ($NewToken) { $NewToken } elseif ($currentLock) { [string]$currentLock.Token } else { '' }
    $createdAt = if ($PreserveCreatedAt) {
        if ($currentLock.CreatedAt) { [string]$currentLock.CreatedAt } else { [DateTime]::UtcNow.ToString('o') }
    } else {
        [DateTime]::UtcNow.ToString('o')
    }
    $identity = [ordered]@{
        SchemaVersion = 1
        OwnerPid = $NewOwnerPid
        Token = $effectiveToken
        CommandPath = $normalizedCommandPath
        ScriptPath = $normalizedScriptPath
        CreatedAt = $createdAt
    }
    $temporaryIdentityPath = Join-Path $Paths.Lock ('identity-' + [guid]::NewGuid().ToString('N') + '.tmp')
    $backupIdentityPath = Join-Path $Paths.Lock ('identity-backup-' + [guid]::NewGuid().ToString('N') + '.tmp')
    [IO.File]::WriteAllText(
        $temporaryIdentityPath,
        ($identity | ConvertTo-Json -Depth 3),
        [Text.UTF8Encoding]::new($false)
    )
    try {
        if (Test-Path -LiteralPath $Paths.LockIdentity) {
            if ($env:DSH_TEST_MODE -eq '1') {
                $signalPath = $env:DSH_TEST_IDENTITY_BEFORE_REPLACE_SIGNAL
                $continuePath = $env:DSH_TEST_IDENTITY_BEFORE_REPLACE_CONTINUE
                if ($signalPath -and $continuePath -and -not (Test-Path -LiteralPath $signalPath)) {
                    [IO.File]::WriteAllText($signalPath, 'ready', [Text.Encoding]::ASCII)
                    $deadline = [DateTime]::UtcNow.AddSeconds(15)
                    while (-not (Test-Path -LiteralPath $continuePath)) {
                        if ([DateTime]::UtcNow -ge $deadline) {
                            throw 'Timed out waiting for the identity replacement test hook'
                        }
                        Start-Sleep -Milliseconds 25
                    }
                }
                if ($env:DSH_TEST_IDENTITY_REPLACE_FAILURE -eq '1') {
                    throw 'Injected identity replacement failure'
                }
            }
            try {
                [IO.File]::Replace($temporaryIdentityPath, $Paths.LockIdentity, $backupIdentityPath)
            } catch {
                if (-not (Test-Path -LiteralPath $Paths.LockIdentity) -and
                        (Test-Path -LiteralPath $backupIdentityPath)) {
                    [IO.File]::Move($backupIdentityPath, $Paths.LockIdentity)
                }
                throw
            }
        } else {
            [IO.File]::Move($temporaryIdentityPath, $Paths.LockIdentity)
        }
    } finally {
        if (Test-Path -LiteralPath $temporaryIdentityPath) {
            Remove-Item -LiteralPath $temporaryIdentityPath -Force -ErrorAction SilentlyContinue
        }
        if ((Test-Path -LiteralPath $Paths.LockIdentity) -and
                (Test-Path -LiteralPath $backupIdentityPath)) {
            Remove-Item -LiteralPath $backupIdentityPath -Force -ErrorAction SilentlyContinue
        }
    }
    if ($normalizedCommandPath) {
        [IO.File]::WriteAllText($Paths.LockCommandPath, $normalizedCommandPath, [Text.UTF8Encoding]::new($false))
    }
    if ($normalizedScriptPath) {
        [IO.File]::WriteAllText($Paths.LockScriptPath, $normalizedScriptPath, [Text.UTF8Encoding]::new($false))
    }
    if (-not $PreserveCreatedAt -or -not (Test-Path -LiteralPath $Paths.LockCreatedAt)) {
        Set-Content -LiteralPath $Paths.LockCreatedAt -Value $createdAt -Encoding ASCII
    }
    Set-Content -LiteralPath $Paths.LockOwner -Value $NewOwnerPid -Encoding ASCII
}

function Test-StartupLockInitializing {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Paths,
        [Parameter(Mandatory = $true)][pscustomobject]$LockInfo
    )

    if (-not $LockInfo.Exists -or $LockInfo.OwnerPid -gt 0) {
        return $false
    }

    try {
        $age = [DateTime]::UtcNow - (Get-Item -LiteralPath $Paths.Lock).CreationTimeUtc
        return $age.TotalSeconds -lt 5
    } catch {
        return $false
    }
}

function Remove-StaleStartupLock {
    param([Parameter(Mandatory = $true)][pscustomobject]$Paths)

    $lock = Get-StartupLockInfo -Paths $Paths
    if (-not $lock.Exists) {
        return $false
    }
    $ownerStatus = Get-StartupOwnerStatus -ProcessId $lock.OwnerPid `
        -ExpectedCommandPath $lock.CommandPath -ExpectedScriptPath $lock.ScriptPath
    if ($ownerStatus -ne 'STALE') {
        return $false
    }
    if (Test-StartupLockInitializing -Paths $Paths -LockInfo $lock) {
        return $false
    }

    Remove-Item -LiteralPath $Paths.Lock -Recurse -Force -ErrorAction Stop
    return $true
}

function Test-NewStartupStateIdentityAuthorized {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Paths,
        [int]$NewOwnerPid,
        [string]$NewStartupToken
    )

    if ($NewOwnerPid -le 0 -or -not $NewStartupToken) {
        return $false
    }
    $lock = Get-StartupLockInfo -Paths $Paths
    if (-not $lock.Exists -or $lock.OwnerPid -ne $NewOwnerPid -or
            -not [string]::Equals($lock.Token, $NewStartupToken, [StringComparison]::Ordinal)) {
        return $false
    }
    return Test-StartupOwnerAlive -ProcessId $lock.OwnerPid `
        -ExpectedCommandPath $lock.CommandPath -ExpectedScriptPath $lock.ScriptPath
}

function Read-StartupState {
    param([Parameter(Mandatory = $true)][pscustomobject]$Paths)

    if (-not (Test-Path -LiteralPath $Paths.State)) {
        return $null
    }

    try {
        $state = Get-Content -LiteralPath $Paths.State -Raw | ConvertFrom-Json
        if ($state.State -eq 'RUNNING') {
            $state.State = 'READY'
        }
        return $state
    } catch {
        return $null
    }
}

function Write-StartupStateFile {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Paths,
        [Parameter(Mandatory = $true)][string]$NewState,
        [int]$NewOwnerPid,
        [int]$NewServicePid,
        [string]$NewVersion,
        [string]$NewMessage,
        [int]$NewExitCode,
        [string]$NewStartupToken,
        [string]$NewRuntimeRoot,
        [string]$NewEntrypoint
    )

    Ensure-LaunchRoot -Root $Paths.Root
    $existing = Read-StartupState -Paths $Paths
    $existingStartupToken = if ($existing -and $existing.StartupToken) {
        [string]$existing.StartupToken
    } else {
        ''
    }
    $matchesExistingIdentity = $existingStartupToken -and $NewStartupToken -and [string]::Equals(
        $existingStartupToken,
        $NewStartupToken,
        [StringComparison]::Ordinal)
    $replacesExistingIdentity = $NewState -eq 'STARTING' -and
        (Test-NewStartupStateIdentityAuthorized -Paths $Paths -NewOwnerPid $NewOwnerPid `
            -NewStartupToken $NewStartupToken)
    if ($existingStartupToken -and -not $matchesExistingIdentity -and -not $replacesExistingIdentity) {
        throw 'Startup state identity does not match the existing startup token'
    }
    if ($NewState -eq 'RUNNING') {
        $NewState = 'READY'
    }
    $newIdentity = $NewState -eq 'STARTING' -and $NewStartupToken -and
        (-not $existing -or -not [string]::Equals(
            [string]$existing.StartupToken,
            $NewStartupToken,
            [StringComparison]::Ordinal))
    $preserveExistingIdentity = $existing -and -not $newIdentity
    $startedAt = if ($preserveExistingIdentity -and $existing.StartedAt) {
        [string]$existing.StartedAt
    } else {
        (Get-Date).ToString('o')
    }
    $existingRunnerPid = if ($existing -and $existing.RunnerPid) {
        [int]$existing.RunnerPid
    } elseif ($existing -and $existing.Pid) {
        [int]$existing.Pid
    } else {
        0
    }
    $effectiveRunnerPid = if ($preserveExistingIdentity -and $existingRunnerPid -gt 0) {
        $existingRunnerPid
    } elseif ($NewOwnerPid -gt 0) {
        $NewOwnerPid
    } else {
        $existingRunnerPid
    }
    $effectiveServicePid = if ($preserveExistingIdentity -and $existing.ServicePid) {
        [int]$existing.ServicePid
    } elseif ($NewServicePid -gt 0) {
        $NewServicePid
    } else {
        0
    }
    $effectiveVersion = if ($preserveExistingIdentity -and $existing.Version) {
        [string]$existing.Version
    } elseif ($NewVersion) {
        $NewVersion
    } else {
        ''
    }
    $effectiveMessage = if ($NewMessage) { $NewMessage } else { '' }
    $effectiveExitCode = if ($NewState -eq 'FAILED') { $NewExitCode } else { 0 }
    $effectiveStartupToken = if ($preserveExistingIdentity -and $existing.StartupToken) {
        [string]$existing.StartupToken
    } else {
        [string]$NewStartupToken
    }
    $effectiveRuntimeRoot = if ($preserveExistingIdentity -and $existing.RuntimeRoot) {
        [string]$existing.RuntimeRoot
    } else {
        [string]$NewRuntimeRoot
    }
    $effectiveEntrypoint = if ($preserveExistingIdentity -and $existing.Entrypoint) {
        [string]$existing.Entrypoint
    } else {
        [string]$NewEntrypoint
    }
    $stateObject = [ordered]@{
        State        = $NewState
        Pid          = $effectiveRunnerPid
        RunnerPid    = $effectiveRunnerPid
        ServicePid   = $effectiveServicePid
        StartupToken = $effectiveStartupToken
        RuntimeRoot  = $effectiveRuntimeRoot
        Entrypoint   = $effectiveEntrypoint
        Version      = $effectiveVersion
        StartedAt    = $startedAt
        UpdatedAt    = (Get-Date).ToString('o')
        Message      = $effectiveMessage
        ExitCode     = $effectiveExitCode
    }
    $temporaryPath = Join-Path $Paths.Root ('dsh-startup-' + [guid]::NewGuid().ToString('N') + '.tmp')
    [IO.File]::WriteAllText(
        $temporaryPath,
        ($stateObject | ConvertTo-Json -Depth 3),
        [Text.UTF8Encoding]::new($false)
    )
    Move-Item -LiteralPath $temporaryPath -Destination $Paths.State -Force
}

function Get-StartupStatusSnapshot {
    param([Parameter(Mandatory = $true)][pscustomobject]$Paths)

    $lock = Get-StartupLockInfo -Paths $Paths
    $ownerStatus = if ($lock.Exists) {
        Get-StartupOwnerStatus -ProcessId $lock.OwnerPid `
            -ExpectedCommandPath $lock.CommandPath -ExpectedScriptPath $lock.ScriptPath
    } else {
        'MISSING'
    }
    $lockIsLive = $lock.Exists -and $ownerStatus -in @('ALIVE', 'UNKNOWN')
    if ($lock.Exists -and $ownerStatus -eq 'STALE') {
        Remove-StaleStartupLock -Paths $Paths | Out-Null
        $lock = Get-StartupLockInfo -Paths $Paths
        $ownerStatus = if ($lock.Exists) {
            Get-StartupOwnerStatus -ProcessId $lock.OwnerPid `
                -ExpectedCommandPath $lock.CommandPath -ExpectedScriptPath $lock.ScriptPath
        } else {
            'MISSING'
        }
        $lockIsLive = $lock.Exists -and $ownerStatus -in @('ALIVE', 'UNKNOWN')
    }
    $startupState = Read-StartupState -Paths $Paths
    $runnerPid = if ($startupState -and $startupState.RunnerPid) {
        [int]$startupState.RunnerPid
    } elseif ($startupState -and $startupState.Pid) {
        [int]$startupState.Pid
    } else {
        0
    }

    return [pscustomobject]@{
        Lock = $lock
        LockIsLive = $lockIsLive
        LockOwnerStatus = $ownerStatus
        StartupState = $startupState
        RunnerPid = $runnerPid
    }
}

function Test-StatusLockMatchesState {
    param([Parameter(Mandatory = $true)][pscustomobject]$Snapshot)

    $startupState = $Snapshot.StartupState
    return $startupState -and $startupState.State -eq 'STARTING' -and
        $Snapshot.LockIsLive -and $Snapshot.LockOwnerStatus -eq 'ALIVE' -and
        $Snapshot.Lock.OwnerPid -eq $Snapshot.RunnerPid -and
        [string]::Equals(
            [string]$Snapshot.Lock.Token,
            [string]$startupState.StartupToken,
            [StringComparison]::Ordinal)
}

function Test-StartupStatusSnapshotMatch {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Expected,
        [Parameter(Mandatory = $true)][pscustomobject]$Actual
    )

    if ($Expected.LockIsLive -ne $Actual.LockIsLive) {
        return $false
    }
    if ($Expected.LockOwnerStatus -ne $Actual.LockOwnerStatus) {
        return $false
    }
    foreach ($propertyName in @('Exists', 'OwnerPid', 'Token', 'CommandPath', 'ScriptPath', 'CreatedAt')) {
        if (-not (Test-StatusSnapshotPropertyMatch -Expected $Expected.Lock -Actual $Actual.Lock `
                -PropertyName $propertyName)) {
            return $false
        }
    }

    if (($null -eq $Expected.StartupState) -ne ($null -eq $Actual.StartupState)) {
        return $false
    }
    if (-not $Expected.StartupState) {
        return $true
    }

    if ($Expected.RunnerPid -ne $Actual.RunnerPid) {
        return $false
    }
    foreach ($propertyName in @(
            'State', 'Pid', 'RunnerPid', 'ServicePid', 'StartupToken', 'RuntimeRoot',
            'Entrypoint', 'Version', 'StartedAt', 'UpdatedAt', 'Message', 'ExitCode')) {
        if (-not (Test-StatusSnapshotPropertyMatch -Expected $Expected.StartupState `
                -Actual $Actual.StartupState -PropertyName $propertyName)) {
            return $false
        }
    }
    return $true
}

function Test-StatusSnapshotPropertyMatch {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Expected,
        [Parameter(Mandatory = $true)][pscustomobject]$Actual,
        [Parameter(Mandatory = $true)][string]$PropertyName
    )

    $expectedProperty = $Expected.PSObject.Properties[$PropertyName]
    $actualProperty = $Actual.PSObject.Properties[$PropertyName]
    if (($null -eq $expectedProperty) -ne ($null -eq $actualProperty)) {
        return $false
    }
    if ($null -eq $expectedProperty) {
        return $true
    }

    $expectedJson = ConvertTo-Json -InputObject $expectedProperty.Value -Compress -Depth 3
    $actualJson = ConvertTo-Json -InputObject $actualProperty.Value -Compress -Depth 3
    return [string]::Equals($expectedJson, $actualJson, [StringComparison]::Ordinal)
}

function Invoke-StatusAfterProbeTestHook {
    if ($env:DSH_TEST_MODE -ne '1') {
        return
    }
    $signalPath = $env:DSH_TEST_STATUS_AFTER_PROBE_SIGNAL
    $continuePath = $env:DSH_TEST_STATUS_AFTER_PROBE_CONTINUE
    if (-not $signalPath -or -not $continuePath -or (Test-Path -LiteralPath $signalPath)) {
        return
    }

    [IO.File]::WriteAllText($signalPath, 'ready', [Text.Encoding]::ASCII)
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    while (-not (Test-Path -LiteralPath $continuePath)) {
        if ([DateTime]::UtcNow -ge $deadline) {
            throw 'Timed out waiting for the status probe test hook'
        }
        Start-Sleep -Milliseconds 25
    }
}

function Write-StatusWithoutProbe {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Paths,
        [Parameter(Mandatory = $true)][pscustomobject]$Snapshot
    )

    $startupState = $Snapshot.StartupState
    if ($Snapshot.LockIsLive) {
        $owner = $Snapshot.Lock.OwnerPid
        $versionSuffix = if ((Test-StatusLockMatchesState -Snapshot $Snapshot) -and $startupState.Version) {
            " - version $($startupState.Version)"
        } else {
            ''
        }
        Write-Output "STARTING - PID $owner$versionSuffix"
        return
    }

    if ($startupState -and $startupState.State -eq 'FAILED') {
        $reason = if ($startupState.Message) { [string]$startupState.Message } else { 'DeepSeek Harness exited before readiness' }
        $exitSuffix = if ($null -ne $startupState.ExitCode) { " (exit code $($startupState.ExitCode))" } else { '' }
        Write-Output "FAILED$exitSuffix - $reason"
        Write-Output "Log: $($Paths.Log)"
        return
    }

    Write-Output 'STOPPED'
}

function Invoke-StatusProbe {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Snapshot,
        [AllowEmptyString()][string]$ProbeKind,
        [Parameter(Mandatory = $true)][int]$ServicePort,
        [Parameter(Mandatory = $true)][string]$LaunchRoot
    )

    if (-not $ProbeKind) { return $null }
    $state = $Snapshot.StartupState
    $runnerPid = $Snapshot.RunnerPid
    if (-not $state -or -not $state.Entrypoint -or -not $state.StartupToken -or $runnerPid -le 0) {
        return $null
    }
    if ($ProbeKind -eq 'classify') {
        return Get-DshServiceClassification -Port $ServicePort `
            -ExpectedEntrypoint ([string]$state.Entrypoint) `
            -ExpectedStartupToken ([string]$state.StartupToken) `
            -RunnerPid $runnerPid -LaunchRoot $LaunchRoot
    }
    if ($ProbeKind -eq 'wait') {
        return Wait-DshServiceIdentity -Port $ServicePort `
            -ExpectedEntrypoint ([string]$state.Entrypoint) `
            -ExpectedStartupToken ([string]$state.StartupToken) `
            -RunnerPid $runnerPid -LaunchRoot $LaunchRoot `
            -StableMilliseconds 250 -PollMilliseconds 50
    }
    return $null
}

function Write-Status {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Paths,
        [int]$ServicePort = 3080
    )

    # 会话探测策略：READY 状态走一次性分类（CLASSIFY）；带有缓存版本记录的
    # STARTING（与活锁身份一致）走等待式探测（WAIT），探测到 READY 时允许
    # 把该缓存启动推进为 READY。无版本记录的新 STARTING 不探测、不推进，
    # 首个 READY 由就绪监视器独占发布。探测期间身份如发生变化，沿用同一
    # 策略对最新快照重新确认，并用新结果完成本次输出（防 ABA）。
    $probeKind = ''
    for ($attempt = 0; $attempt -lt 3; $attempt++) {
        $guard = Enter-StartupLockGuard -Paths $Paths
        try {
            $snapshot = Get-StartupStatusSnapshot -Paths $Paths
        } finally {
            Exit-StartupLockGuard -Guard $guard
        }

        $startupState = $snapshot.StartupState
        $runnerPid = $snapshot.RunnerPid
        $classification = $null
        $hasStartupEvidence = $startupState -and $startupState.Entrypoint -and
            $startupState.StartupToken -and $runnerPid -gt 0
        $startingLockMatchesState = Test-StatusLockMatchesState -Snapshot $snapshot
        if (-not $probeKind -and $hasStartupEvidence) {
            if ($startupState.State -eq 'READY') {
                $probeKind = 'classify'
            } elseif ($startupState.State -eq 'STARTING' -and $startingLockMatchesState -and
                    $startupState.Version) {
                $probeKind = 'wait'
            }
        }
        if ($probeKind -eq 'classify' -and $hasStartupEvidence -and $startupState.State -eq 'READY') {
            $recordedServicePid = if ($startupState.ServicePid) { [int]$startupState.ServicePid } else { 0 }
            if ($recordedServicePid -gt 0) {
                $classification = Get-DshServiceClassification -Port $ServicePort `
                    -ExpectedEntrypoint ([string]$startupState.Entrypoint) `
                    -ExpectedStartupToken ([string]$startupState.StartupToken) `
                    -RunnerPid $runnerPid -LaunchRoot $Paths.Root
            }
        } elseif ($probeKind -eq 'wait' -and $hasStartupEvidence -and
                $startupState.State -eq 'STARTING' -and $startingLockMatchesState) {
            $classification = Wait-DshServiceIdentity -Port $ServicePort `
                -ExpectedEntrypoint ([string]$startupState.Entrypoint) `
                -ExpectedStartupToken ([string]$startupState.StartupToken) `
                -RunnerPid $runnerPid -LaunchRoot $Paths.Root `
                -StableMilliseconds 250 -PollMilliseconds 50
        }

        if ($classification) {
            Invoke-StatusAfterProbeTestHook
        }

        $guard = Enter-StartupLockGuard -Paths $Paths
        try {
            $currentSnapshot = Get-StartupStatusSnapshot -Paths $Paths
            $applySnapshot = $currentSnapshot
            $applyClassification = $classification
            if (-not (Test-StartupStatusSnapshotMatch -Expected $snapshot -Actual $currentSnapshot)) {
                # 探测期间启动身份已变化：不能采用旧快照的探测结论，改用本次
                # 探测策略对最新快照重新确认，并用新结果完成本次输出（防 ABA）。
                $revalidated = Invoke-StatusProbe -Snapshot $currentSnapshot `
                    -ProbeKind $probeKind -ServicePort $ServicePort -LaunchRoot $Paths.Root
                $applyClassification = $revalidated
            }

            $applyState = $applySnapshot.StartupState
            $applyRunnerPid = $applySnapshot.RunnerPid
            if ($applyState -and $applyState.State -eq 'READY' -and
                    (-not $applyState.ServicePid -or [int]$applyState.ServicePid -le 0)) {
                Write-Output 'UNHEALTHY (stored READY state has no service PID evidence)'
                return
            }
            if ($applyClassification -and $applyState -and $applyState.State -eq 'READY' -and
                    $applyClassification.State -eq 'READY' -and
                    [int]$applyClassification.ServicePid -ne [int]$applyState.ServicePid) {
                Write-Output "UNHEALTHY - PID $($applyClassification.ServicePid) (service identity changed)"
                return
            }
            if ($applyClassification -and $applyClassification.State -eq 'READY') {
                if ($applyState -and $applyState.State -eq 'STARTING') {
                    # 带缓存版本记录且与活锁身份一致的 STARTING，探测确认 READY
                    # 后才允许推进；无版本记录的新 STARTING 永不进入此分支。
                    Write-StartupStateFile -Paths $Paths -NewState 'READY' `
                        -NewOwnerPid $applyRunnerPid `
                        -NewServicePid ([int]$applyClassification.ServicePid) `
                        -NewVersion ([string]$applyState.Version) `
                        -NewMessage ([string]$applyClassification.Message) `
                        -NewExitCode 0 -NewStartupToken ([string]$applyState.StartupToken) `
                        -NewRuntimeRoot ([string]$applyState.RuntimeRoot) `
                        -NewEntrypoint ([string]$applyState.Entrypoint)
                }
                Write-Output "READY - PID $($applyClassification.ServicePid)"
                return
            }
            if ($applyClassification -and
                    ($applyState -and $applyState.State -eq 'READY' -or $applyClassification.State -in @('FOREIGN_PORT', 'UNHEALTHY'))) {
                $pidSuffix = if ($applyClassification.ServicePid) { " - PID $($applyClassification.ServicePid)" } else { '' }
                $messageSuffix = if ($applyClassification.Message) { " ($($applyClassification.Message))" } else { '' }
                Write-Output "$($applyClassification.State)$pidSuffix$messageSuffix"
                return
            }

            Write-StatusWithoutProbe -Paths $Paths -Snapshot $applySnapshot
            return
        } finally {
            Exit-StartupLockGuard -Guard $guard
        }
    }

    $guard = Enter-StartupLockGuard -Paths $Paths
    try {
        Write-StatusWithoutProbe -Paths $Paths -Snapshot (Get-StartupStatusSnapshot -Paths $Paths)
    } finally {
        Exit-StartupLockGuard -Guard $guard
    }
}

switch ($Action) {
    'ClearDshNpxWorkspaces' {
        if (-not $CacheRoot -or -not (Test-Path -LiteralPath $CacheRoot)) {
            exit 0
        }

        Get-ChildItem -LiteralPath $CacheRoot -Directory -ErrorAction Stop | ForEach-Object {
            if (Test-DshNpxWorkspace -Path $_.FullName) {
                $workspace = $_.FullName
                Remove-Item -LiteralPath $workspace -Recurse -Force
                [Console]::Out.WriteLine($workspace)
            }
        }
    }

    'AcquireStartupLock' {
        if ($OwnerPid -le 0) { throw 'AcquireStartupLock requires a live owner PID' }
        $paths = Get-StartupPaths -Root (Get-LaunchRoot)
        Ensure-LaunchRoot -Root $paths.Root
        $guard = Enter-StartupLockGuard -Paths $paths
        try {
            try {
                New-Item -ItemType Directory -Path $paths.Lock -ErrorAction Stop | Out-Null
            } catch [IO.IOException] {
                $existing = Get-StartupLockInfo -Paths $paths
                $matchingToken = $StartupToken -and $existing.Token -and
                    [string]::Equals($existing.Token, $StartupToken, [StringComparison]::Ordinal)
                $matchingLegacyOwner = -not $StartupToken -and -not $existing.Token -and
                    $existing.OwnerPid -eq $OwnerPid
                if ($matchingToken) {
                    if ($TransferOwnership) {
                        Write-StartupLockMetadata -Paths $paths -NewOwnerPid $OwnerPid -NewToken $StartupToken `
                            -NewCommandPath $CommandPath -NewScriptPath $ScriptPath -PreserveCreatedAt
                        Write-Output "OWNED $OwnerPid"
                    } else {
                        Write-Output "OWNED $($existing.OwnerPid)"
                    }
                    exit 0
                }
                if ($matchingLegacyOwner) {
                    Write-Output "OWNED $OwnerPid"
                    exit 0
                }
                Remove-StaleStartupLock -Paths $paths | Out-Null
                try {
                    New-Item -ItemType Directory -Path $paths.Lock -ErrorAction Stop | Out-Null
                } catch [IO.IOException] {
                    $existing = Get-StartupLockInfo -Paths $paths
                    Write-Output "LOCKED $($existing.OwnerPid)"
                    exit 2
                }
            }
            Write-StartupLockMetadata -Paths $paths -NewOwnerPid $OwnerPid -NewToken $StartupToken `
                -NewCommandPath $CommandPath -NewScriptPath $ScriptPath
            Write-Output "ACQUIRED $OwnerPid"
        } finally {
            Exit-StartupLockGuard -Guard $guard
        }
    }

    'TestStartupLock' {
        $paths = Get-StartupPaths -Root (Get-LaunchRoot)
        $guard = Enter-StartupLockGuard -Paths $paths
        try {
            $lock = Get-StartupLockInfo -Paths $paths
            $ownerStatus = if ($lock.Exists) {
                Get-StartupOwnerStatus -ProcessId $lock.OwnerPid `
                    -ExpectedCommandPath $lock.CommandPath -ExpectedScriptPath $lock.ScriptPath
            } else {
                'MISSING'
            }
            if ($lock.Exists -and $ownerStatus -in @('ALIVE', 'UNKNOWN')) {
                Write-Output "LOCKED $($lock.OwnerPid)"
            } else {
                if ($lock.Exists) {
                    Remove-StaleStartupLock -Paths $paths | Out-Null
                }
                Write-Output 'UNLOCKED'
            }
        } finally {
            Exit-StartupLockGuard -Guard $guard
        }
    }

    'ReleaseStartupLock' {
        $paths = Get-StartupPaths -Root (Get-LaunchRoot)
        $guard = Enter-StartupLockGuard -Paths $paths
        try {
            $lock = Get-StartupLockInfo -Paths $paths
            $ownsLock = if ($StartupToken) {
                $lock.Token -and [string]::Equals($lock.Token, $StartupToken, [StringComparison]::Ordinal) -and
                    ($OwnerPid -le 0 -or $lock.OwnerPid -eq $OwnerPid)
            } else {
                -not $lock.Token -and ($OwnerPid -le 0 -or $lock.OwnerPid -eq $OwnerPid)
            }
            if ($lock.Exists -and $ownsLock) {
                Remove-Item -LiteralPath $paths.Lock -Recurse -Force -ErrorAction Stop
                Write-Output 'RELEASED'
            } else {
                Write-Output 'UNCHANGED'
            }
        } finally {
            Exit-StartupLockGuard -Guard $guard
        }
    }

    'WriteStartupState' {
        if (-not $State) { throw 'WriteStartupState requires State' }
        $paths = Get-StartupPaths -Root (Get-LaunchRoot)
        $guard = Enter-StartupLockGuard -Paths $paths
        try {
            Write-StartupStateFile -Paths $paths -NewState $State -NewOwnerPid $OwnerPid `
                -NewServicePid $ServicePid -NewVersion $Version -NewMessage $Message `
                -NewExitCode $ExitCode -NewStartupToken $StartupToken -NewRuntimeRoot $RuntimeRoot `
                -NewEntrypoint $Entrypoint
        } finally {
            Exit-StartupLockGuard -Guard $guard
        }
    }

    'RecordStartupExit' {
        $paths = Get-StartupPaths -Root (Get-LaunchRoot)
        $guard = Enter-StartupLockGuard -Paths $paths
        try {
            $startupState = Read-StartupState -Paths $paths
            if (-not $startupState -or $startupState.State -eq 'STARTING') {
                $owner = if ($startupState -and $startupState.Pid) { [int]$startupState.Pid } else { $OwnerPid }
                $stateVersion = if ($startupState -and $startupState.Version) { [string]$startupState.Version } else { $Version }
                $failureMessage = if ($Message) { $Message } else { 'DSH exited before readiness' }
                Write-StartupStateFile -Paths $paths -NewState 'FAILED' -NewOwnerPid $owner `
                    -NewServicePid 0 -NewVersion $stateVersion -NewMessage $failureMessage `
                    -NewExitCode $ExitCode -NewStartupToken $StartupToken `
                    -NewRuntimeRoot $RuntimeRoot -NewEntrypoint $Entrypoint
            }
        } finally {
            Exit-StartupLockGuard -Guard $guard
        }
    }

    'GetStartupState' {
        $paths = Get-StartupPaths -Root (Get-LaunchRoot)
        $startupState = Read-StartupState -Paths $paths
        if ($startupState) {
            Write-Output ($startupState | ConvertTo-Json -Depth 3 -Compress)
        }
    }

    'GetStartupSnapshot' {
        $paths = Get-StartupPaths -Root (Get-LaunchRoot)
        $guard = Enter-StartupLockGuard -Paths $paths
        try {
            $snapshot = Get-StartupStatusSnapshot -Paths $paths
            Write-Output ($snapshot | ConvertTo-Json -Depth 4 -Compress)
        } finally {
            Exit-StartupLockGuard -Guard $guard
        }
    }

    'GetStatus' {
        $paths = Get-StartupPaths -Root (Get-LaunchRoot)
        Write-Status -Paths $paths -ServicePort $Port
    }
}
