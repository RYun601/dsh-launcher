$ErrorActionPreference = 'Stop'

# Launcher maintenance mutex (Phase B of the 2026-09-05 roadmap).
# All maintenance transactions that replace launcher or runtime files on the
# same user profile share one named mutex: overwrite install, DSH upgrade,
# launcher self-update and full uninstall. Lock ordering is fixed and must be
# preserved by every caller: maintenance lock -> startup lock -> runtime mutex.
# The mutex scope is the resolved launch root, so two isolated fixtures with
# different USERPROFILE values never contend with each other.
#
# install.ps1 embeds a byte-equivalent copy of these three functions because it
# must also work as a self-contained `irm | iex` one-shot script with no sibling
# files. If you change the mutex name derivation here, change it there too.

function Get-DshMaintenanceMutexScope {
    param([string]$LaunchRoot)

    if (-not $LaunchRoot) {
        $LaunchRoot = Join-Path $env:USERPROFILE 'dsh-launch'
    }
    return [IO.Path]::GetFullPath($LaunchRoot)
}

function Get-DshMaintenanceMutexName {
    param([string]$LaunchRoot)

    $scope = Get-DshMaintenanceMutexScope -LaunchRoot $LaunchRoot
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($scope.ToUpperInvariant())
        $hash = $sha256.ComputeHash($bytes)
        $suffix = -join @($hash[0..11] | ForEach-Object { $_.ToString('x2') })
        return 'Local\DshLauncherMaintenance-' + $suffix
    } finally {
        $sha256.Dispose()
    }
}

function Enter-DshMaintenanceLock {
    param(
        [string]$LaunchRoot,
        [ValidateRange(0, 3600000)]
        [int]$TimeoutMilliseconds = 900000
    )

    if ($env:DSH_TEST_MAINTENANCE_TIMEOUT_MS) {
        $TimeoutMilliseconds = [int]$env:DSH_TEST_MAINTENANCE_TIMEOUT_MS
    }
    $mutex = [Threading.Mutex]::new($false, (Get-DshMaintenanceMutexName -LaunchRoot $LaunchRoot))
    $owned = $false
    try {
        $owned = $mutex.WaitOne([TimeSpan]::FromMilliseconds($TimeoutMilliseconds))
    } catch [Threading.AbandonedMutexException] {
        # A previous holder died while holding the lock; the mutex was acquired.
        $owned = $true
    }
    if (-not $owned) {
        $mutex.Dispose()
        throw 'Timed out waiting for the launcher maintenance lock; another install, upgrade or self-update appears to be running'
    }
    return $mutex
}

function Exit-DshMaintenanceLock {
    param($Mutex)

    if ($Mutex) {
        try { $Mutex.ReleaseMutex() } catch { }
        $Mutex.Dispose()
    }
}
