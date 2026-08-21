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

    [switch]$TransferOwnership,

    [ValidateSet('STARTING', 'RUNNING', 'FAILED')]
    [string]$State,

    [string]$Version,

    [string]$Message,

    [int]$ExitCode = 0
)

$ErrorActionPreference = 'Stop'

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
        State     = Join-Path $Root 'dsh-startup.json'
        Log       = Join-Path $Root 'dsh-background.log'
    }
}

function Ensure-LaunchRoot {
    param([Parameter(Mandatory = $true)][string]$Root)

    New-Item -ItemType Directory -Force -Path $Root | Out-Null
}

function Test-StartupOwnerAlive {
    param([int]$ProcessId)

    if ($ProcessId -le 0) {
        return $false
    }
    return $null -ne (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)
}

function Get-StartupLockInfo {
    param([Parameter(Mandatory = $true)][pscustomobject]$Paths)

    if (-not (Test-Path -LiteralPath $Paths.Lock)) {
        return [pscustomobject]@{ Exists = $false; OwnerPid = 0; Token = '' }
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

    return [pscustomobject]@{ Exists = $true; OwnerPid = $ownerPid; Token = $token }
}

function Write-StartupLockMetadata {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Paths,
        [Parameter(Mandatory = $true)][int]$NewOwnerPid,
        [string]$NewToken
    )

    if ($NewToken) {
        Set-Content -LiteralPath $Paths.LockToken -Value $NewToken -Encoding ASCII
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
    if (Test-StartupOwnerAlive -ProcessId $lock.OwnerPid) {
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
        return Get-Content -LiteralPath $Paths.State -Raw | ConvertFrom-Json
    } catch {
        return $null
    }
}

function Write-StartupStateFile {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Paths,
        [Parameter(Mandatory = $true)][string]$NewState,
        [int]$NewOwnerPid,
        [string]$NewVersion,
        [string]$NewMessage,
        [int]$NewExitCode
    )

    Ensure-LaunchRoot -Root $Paths.Root
    $existing = Read-StartupState -Paths $Paths
    $startedAt = if ($existing -and $existing.StartedAt) { [string]$existing.StartedAt } else { (Get-Date).ToString('o') }
    $effectivePid = if ($NewOwnerPid -gt 0) { $NewOwnerPid } elseif ($existing -and $existing.Pid) { [int]$existing.Pid } else { 0 }
    $effectiveVersion = if ($NewVersion) { $NewVersion } elseif ($existing -and $existing.Version) { [string]$existing.Version } else { '' }
    $effectiveMessage = if ($NewMessage) { $NewMessage } else { '' }
    $effectiveExitCode = if ($NewState -eq 'FAILED') { $NewExitCode } else { 0 }
    $stateObject = [ordered]@{
        State     = $NewState
        Pid       = $effectivePid
        Version   = $effectiveVersion
        StartedAt = $startedAt
        UpdatedAt = (Get-Date).ToString('o')
        Message   = $effectiveMessage
        ExitCode  = $effectiveExitCode
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
    param([Parameter(Mandatory = $true)][pscustomobject]$Paths)

    $connections = @(Get-NetTCPConnection -LocalPort 3080 -State Listen -ErrorAction SilentlyContinue)
    if ($connections.Count -gt 0) {
        $servicePid = $connections[0].OwningProcess
        try {
            $response = Invoke-WebRequest 'http://127.0.0.1:3080' -UseBasicParsing -TimeoutSec 2 -ErrorAction Stop
            if ($response.StatusCode -ge 200 -and $response.StatusCode -lt 500) {
                Write-Output "RUNNING (ready) - PID $servicePid"
                return
            }
        } catch { }
        Write-Output "RUNNING (starting) - PID $servicePid"
        return
    }

    $lock = Get-StartupLockInfo -Paths $Paths
    $lockIsLive = $lock.Exists -and (Test-StartupOwnerAlive -ProcessId $lock.OwnerPid)
    if ($lock.Exists -and -not $lockIsLive) {
        Remove-StaleStartupLock -Paths $Paths | Out-Null
    }

    $startupState = Read-StartupState -Paths $Paths
    $stateOwnerIsLive = $startupState -and (Test-StartupOwnerAlive -ProcessId ([int]$startupState.Pid))
    if ($lockIsLive -or ($startupState -and $startupState.State -eq 'STARTING' -and $stateOwnerIsLive)) {
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

    Write-Output 'NOT RUNNING'
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
                    Write-StartupLockMetadata -Paths $paths -NewOwnerPid $OwnerPid -NewToken $StartupToken
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
        Write-StartupLockMetadata -Paths $paths -NewOwnerPid $OwnerPid -NewToken $StartupToken
        Write-Output "ACQUIRED $OwnerPid"
    }

    'TestStartupLock' {
        $paths = Get-StartupPaths -Root (Get-LaunchRoot)
        $lock = Get-StartupLockInfo -Paths $paths
        if ($lock.Exists -and (Test-StartupOwnerAlive -ProcessId $lock.OwnerPid)) {
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
            $lock.Token -and [string]::Equals($lock.Token, $StartupToken, [StringComparison]::Ordinal)
        } else {
            $OwnerPid -le 0 -or $lock.OwnerPid -eq $OwnerPid
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
        Write-StartupStateFile -Paths $paths -NewState $State -NewOwnerPid $OwnerPid -NewVersion $Version -NewMessage $Message -NewExitCode $ExitCode
    }

    'RecordStartupExit' {
        $paths = Get-StartupPaths -Root (Get-LaunchRoot)
        $startupState = Read-StartupState -Paths $paths
        if (-not $startupState -or $startupState.State -eq 'STARTING') {
            $owner = if ($startupState -and $startupState.Pid) { [int]$startupState.Pid } else { $OwnerPid }
            $stateVersion = if ($startupState -and $startupState.Version) { [string]$startupState.Version } else { $Version }
            $failureMessage = if ($Message) { $Message } else { 'DSH exited before readiness' }
            Write-StartupStateFile -Paths $paths -NewState 'FAILED' -NewOwnerPid $owner -NewVersion $stateVersion -NewMessage $failureMessage -NewExitCode $ExitCode
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
        Write-Status -Paths $paths
    }
}
