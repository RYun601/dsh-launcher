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

function Test-StartupOwnerAlive {
    param(
        [int]$ProcessId,
        [string]$ExpectedCommandPath,
        [string]$ExpectedScriptPath
    )

    $normalizedCommandPath = ConvertTo-NormalizedPath -Path $ExpectedCommandPath
    $normalizedScriptPath = ConvertTo-NormalizedPath -Path $ExpectedScriptPath
    if ($ProcessId -le 0 -or -not $normalizedCommandPath -or -not $normalizedScriptPath) {
        return $false
    }

    try {
        $process = Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction Stop
    } catch {
        return $false
    }
    if (-not $process) {
        return $false
    }

    $actualCommandPath = ConvertTo-NormalizedPath -Path ([string]$process.ExecutablePath)
    if (-not $actualCommandPath -or -not [string]::Equals(
            $actualCommandPath,
            $normalizedCommandPath,
            [StringComparison]::OrdinalIgnoreCase)) {
        return $false
    }

    return Test-DshCommandLineArgument -CommandLine ([string]$process.CommandLine) `
        -ExpectedPath $normalizedScriptPath
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
    $normalizedCommandPath = ConvertTo-NormalizedPath -Path $NewCommandPath
    $normalizedScriptPath = ConvertTo-NormalizedPath -Path $NewScriptPath
    if ($normalizedCommandPath) {
        [IO.File]::WriteAllText($Paths.LockCommandPath, $normalizedCommandPath, [Text.UTF8Encoding]::new($false))
    }
    if ($normalizedScriptPath) {
        [IO.File]::WriteAllText($Paths.LockScriptPath, $normalizedScriptPath, [Text.UTF8Encoding]::new($false))
    }
    if (-not $PreserveCreatedAt -or -not (Test-Path -LiteralPath $Paths.LockCreatedAt)) {
        Set-Content -LiteralPath $Paths.LockCreatedAt -Value ([DateTime]::UtcNow.ToString('o')) -Encoding ASCII
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
    if (Test-StartupOwnerAlive -ProcessId $lock.OwnerPid `
            -ExpectedCommandPath $lock.CommandPath -ExpectedScriptPath $lock.ScriptPath) {
        return $false
    }
    if (Test-StartupLockInitializing -Paths $Paths -LockInfo $lock) {
        return $false
    }

    Remove-Item -LiteralPath $Paths.Lock -Recurse -Force -ErrorAction Stop
    return $true
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
    if ($NewState -eq 'RUNNING') {
        $NewState = 'READY'
    }
    $existing = Read-StartupState -Paths $Paths
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

function Write-Status {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Paths,
        [int]$ServicePort = 3080
    )

    $lock = Get-StartupLockInfo -Paths $Paths
    $lockIsLive = $lock.Exists -and (Test-StartupOwnerAlive -ProcessId $lock.OwnerPid `
        -ExpectedCommandPath $lock.CommandPath -ExpectedScriptPath $lock.ScriptPath)
    if ($lock.Exists -and -not $lockIsLive) {
        Remove-StaleStartupLock -Paths $Paths | Out-Null
    }

    $startupState = Read-StartupState -Paths $Paths
    $runnerPid = if ($startupState -and $startupState.RunnerPid) {
        [int]$startupState.RunnerPid
    } elseif ($startupState -and $startupState.Pid) {
        [int]$startupState.Pid
    } else {
        0
    }
    $hasStartupEvidence = $startupState -and $startupState.Entrypoint -and
        $startupState.StartupToken -and $runnerPid -gt 0
    if ($hasStartupEvidence -and $startupState.State -in @('STARTING', 'READY')) {
        if ($startupState.State -eq 'READY') {
            $classification = Get-DshServiceClassification -Port $ServicePort `
                -ExpectedEntrypoint ([string]$startupState.Entrypoint) `
                -ExpectedStartupToken ([string]$startupState.StartupToken) `
                -RunnerPid $runnerPid
            $recordedServicePid = if ($startupState.ServicePid) { [int]$startupState.ServicePid } else { 0 }
            if ($classification.State -eq 'READY' -and $recordedServicePid -gt 0 -and
                    [int]$classification.ServicePid -ne $recordedServicePid) {
                Write-Output "UNHEALTHY - PID $($classification.ServicePid) (service identity changed)"
                return
            }
        } else {
            $classification = Wait-DshServiceIdentity -Port $ServicePort `
                -ExpectedEntrypoint ([string]$startupState.Entrypoint) `
                -ExpectedStartupToken ([string]$startupState.StartupToken) `
                -RunnerPid $runnerPid -StableMilliseconds 250 -PollMilliseconds 50
        }

        if ($classification.State -eq 'READY') {
            if ($startupState.State -eq 'STARTING') {
                Write-StartupStateFile -Paths $Paths -NewState 'READY' `
                    -NewOwnerPid $runnerPid -NewServicePid ([int]$classification.ServicePid) `
                    -NewVersion ([string]$startupState.Version) -NewMessage ([string]$classification.Message) `
                    -NewExitCode 0 -NewStartupToken ([string]$startupState.StartupToken) `
                    -NewRuntimeRoot ([string]$startupState.RuntimeRoot) `
                    -NewEntrypoint ([string]$startupState.Entrypoint)
            }
            Write-Output "READY - PID $($classification.ServicePid)"
            return
        }

        if ($startupState.State -eq 'READY' -or $classification.State -in @('FOREIGN_PORT', 'UNHEALTHY')) {
            $pidSuffix = if ($classification.ServicePid) { " - PID $($classification.ServicePid)" } else { '' }
            $messageSuffix = if ($classification.Message) { " ($($classification.Message))" } else { '' }
            Write-Output "$($classification.State)$pidSuffix$messageSuffix"
            return
        }
    }

    if ($lockIsLive -or ($startupState -and $startupState.State -eq 'STARTING' -and $runnerPid -gt 0 -and
            (Get-Process -Id $runnerPid -ErrorAction SilentlyContinue))) {
        $owner = if ($lockIsLive) { $lock.OwnerPid } else { $startupState.Pid }
        $versionSuffix = if ($startupState -and $startupState.Version) { " - version $($startupState.Version)" } else { '' }
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
    }

    'TestStartupLock' {
        $paths = Get-StartupPaths -Root (Get-LaunchRoot)
        $lock = Get-StartupLockInfo -Paths $paths
        if ($lock.Exists -and (Test-StartupOwnerAlive -ProcessId $lock.OwnerPid `
                -ExpectedCommandPath $lock.CommandPath -ExpectedScriptPath $lock.ScriptPath)) {
            Write-Output "LOCKED $($lock.OwnerPid)"
        } else {
            if ($lock.Exists) {
                Remove-StaleStartupLock -Paths $paths | Out-Null
            }
            Write-Output 'UNLOCKED'
        }
    }

    'ReleaseStartupLock' {
        $paths = Get-StartupPaths -Root (Get-LaunchRoot)
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
    }

    'WriteStartupState' {
        if (-not $State) { throw 'WriteStartupState requires State' }
        $paths = Get-StartupPaths -Root (Get-LaunchRoot)
        Write-StartupStateFile -Paths $paths -NewState $State -NewOwnerPid $OwnerPid `
            -NewServicePid $ServicePid -NewVersion $Version -NewMessage $Message `
            -NewExitCode $ExitCode -NewStartupToken $StartupToken -NewRuntimeRoot $RuntimeRoot `
            -NewEntrypoint $Entrypoint
    }

    'RecordStartupExit' {
        $paths = Get-StartupPaths -Root (Get-LaunchRoot)
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
    }

    'GetStartupState' {
        $paths = Get-StartupPaths -Root (Get-LaunchRoot)
        $startupState = Read-StartupState -Paths $paths
        if ($startupState) {
            Write-Output ($startupState | ConvertTo-Json -Depth 3 -Compress)
        }
    }

    'GetStatus' {
        $paths = Get-StartupPaths -Root (Get-LaunchRoot)
        Write-Status -Paths $paths -ServicePort $Port
    }
}
