$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$testRoot = Join-Path $env:TEMP ('dsh-launcher-update-tests-' + [guid]::NewGuid().ToString('N'))
$script:Passed = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    if ($Expected -ne $Actual) { throw "$Message (expected: $Expected, actual: $Actual)" }
}

function Assert-Match {
    param([string]$Actual, [string]$Pattern, [string]$Message)
    if ($Actual -notmatch $Pattern) { throw "$Message`nActual output:`n$Actual" }
}

function Assert-NotMatch {
    param([string]$Actual, [string]$Pattern, [string]$Message)
    if ($Actual -match $Pattern) { throw "$Message`nActual output:`n$Actual" }
}

function Invoke-Test {
    param([string]$Name, [scriptblock]$Body)
    & $Body
    $script:Passed++
    Write-Host "PASS: $Name"
}

# Files a working installed launcher needs for self-update: the updater itself,
# its dot-sourced helpers, the CLI entry (which smoke validation exercises) and
# the state helper used for the busy check.
$fixtureFiles = @(
    'deepseek.cmd', 'update-launcher.ps1', 'version-info.ps1',
    'dsh-version.ps1', 'dsh-runtime-layout.ps1', 'dsh-maintenance-lock.ps1',
    'dsh-launch-state.ps1', 'dsh-service-health.ps1', 'dsh-node-version.ps1'
)

function New-LauncherFixture {
    param(
        [string]$Name,
        [string]$LocalVersion = '0.1.0',
        [switch]$NoOwnerMarker,
        [switch]$InstallInsideDsh
    )

    $root = Join-Path $testRoot $Name
    if ($InstallInsideDsh) {
        # .dsh 是用户凭据边界：自更新必须拒绝其中的安装目录。
        $installDir = Join-Path $root 'profile\.dsh\launcher'
    } else {
        $installDir = Join-Path $root 'install'
    }
    $profileRoot = Join-Path $root 'profile'
    $tempDir = Join-Path $root 'temp'
    New-Item -ItemType Directory -Force -Path $installDir, $profileRoot, $tempDir | Out-Null
    foreach ($fileName in $fixtureFiles) {
        Copy-Item -LiteralPath (Join-Path $repoRoot $fileName) -Destination (Join-Path $installDir $fileName)
    }
    [IO.File]::WriteAllText((Join-Path $installDir 'VERSION'), "$LocalVersion`r`n", [Text.Encoding]::ASCII)
    if (-not $NoOwnerMarker) {
        $installFullPath = (Get-Item -LiteralPath $installDir).FullName
        $owner = [ordered]@{
            SchemaVersion = 1
            InstallPath = $installFullPath
            InstallationId = [guid]::NewGuid().ToString('N')
        }
        [IO.File]::WriteAllText(
            (Join-Path $installDir '.dsh-launcher-owner.json'),
            ($owner | ConvertTo-Json),
            [Text.UTF8Encoding]::new($false)
        )
    }
    # Data protection sentinels: the updater must never touch these trees.
    New-Item -ItemType Directory -Force -Path (Join-Path $profileRoot 'dsh-launch') | Out-Null
    [IO.File]::WriteAllText((Join-Path $profileRoot 'dsh-launch\sentinel.txt'), 'keep', [Text.Encoding]::ASCII)
    New-Item -ItemType Directory -Force -Path (Join-Path $profileRoot '.dsh') | Out-Null
    [IO.File]::WriteAllText((Join-Path $profileRoot '.dsh\sentinel.txt'), 'keep', [Text.Encoding]::ASCII)

    return [pscustomobject]@{
        Root = $root
        InstallDir = $installDir
        ProfileRoot = $profileRoot
        TempDir = $tempDir
        VersionFile = (Join-Path $installDir 'VERSION')
    }
}

# Builds a release payload directory and its dsh-launcher.zip. The zip carries
# the nested dsh-launcher/ top-level directory exactly like the real release
# workflow. Returns the SHA-256 digest for the API fixture.
function New-ReleaseFiles {
    param(
        [string]$FilesDir,
        [string]$Version,
        [string[]]$ExtraCmdLine = @()
    )

    $nested = Join-Path $FilesDir 'dsh-launcher'
    New-Item -ItemType Directory -Force -Path $nested | Out-Null
    foreach ($fileName in $fixtureFiles) {
        Copy-Item -LiteralPath (Join-Path $repoRoot $fileName) -Destination (Join-Path $nested $fileName)
    }
    foreach ($extraLine in $ExtraCmdLine) {
        Add-Content -LiteralPath (Join-Path $nested 'deepseek.cmd') -Value $extraLine -Encoding ASCII
    }
    [IO.File]::WriteAllText((Join-Path $nested 'VERSION'), "$Version`r`n", [Text.Encoding]::ASCII)
    $manifestNames = @((Get-ChildItem -LiteralPath $nested -File | ForEach-Object { $_.Name }) + 'release-files.txt') | Sort-Object -Unique
    [IO.File]::WriteAllLines((Join-Path $nested 'release-files.txt'), $manifestNames, [Text.UTF8Encoding]::new($false))
    return $nested
}

function New-ReleasePackage {
    param(
        [string]$FilesDir,
        [string]$Version,
        [string[]]$ExtraCmdLine = @(),
        [string]$PackageVersion = ''
    )

    $effectivePackageVersion = if ($PackageVersion) { $PackageVersion } else { $Version }
    $nested = New-ReleaseFiles -FilesDir $FilesDir -Version $effectivePackageVersion -ExtraCmdLine $ExtraCmdLine
    $zipPath = Join-Path $FilesDir 'dsh-launcher.zip'
    Compress-Archive -LiteralPath $nested -DestinationPath $zipPath -CompressionLevel Optimal -Force
    $sha256 = (Get-FileHash $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText(
        (Join-Path $FilesDir 'dsh-launcher.zip.sha256'),
        "$sha256  dsh-launcher.zip`n",
        [Text.UTF8Encoding]::new($false)
    )
    return [pscustomobject]@{ ZipPath = $zipPath; Sha256 = $sha256; Nested = $nested }
}

function New-UpdateEnvironment {
    param(
        [pscustomobject]$Fixture,
        [string]$ReleaseVersion,
        [string]$PackageVersion = '',
        [string]$DigestOverride = '',
        [switch]$NoDigest,
        [string[]]$ExtraCmdLine = @()
    )

    $filesDir = Join-Path $Fixture.Root 'release-files'
    New-Item -ItemType Directory -Force -Path $filesDir | Out-Null
    $package = New-ReleasePackage -FilesDir $filesDir -Version $ReleaseVersion `
        -ExtraCmdLine $ExtraCmdLine -PackageVersion $PackageVersion

    $zipAsset = [ordered]@{ name = 'dsh-launcher.zip'; size = (Get-Item $package.ZipPath).Length; browser_download_url = 'https://example.invalid/dsh-launcher.zip' }
    if (-not $NoDigest) {
        $digestValue = if ($DigestOverride) { $DigestOverride } else { $package.Sha256 }
        $zipAsset['digest'] = "sha256:$digestValue"
    }
    $assets = @($zipAsset)
    $api = [ordered]@{
        tag_name = "v$ReleaseVersion"
        assets = $assets
    }
    $apiPath = Join-Path $Fixture.Root 'api.json'
    [IO.File]::WriteAllText($apiPath, ($api | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))

    return [pscustomobject]@{
        ApiPath = $apiPath
        FilesDir = $filesDir
        ZipPath = $package.ZipPath
        ZipSha256 = $package.Sha256
    }
}

function Invoke-LauncherUpdate {
    param(
        [pscustomobject]$Fixture,
        [pscustomobject]$Environment,
        [switch]$Upgrade,
        [switch]$ViaCli,
        [string]$FailStage = '',
        [string]$FailRestore = '',
        [string]$MaintenanceTimeout = '30000'
    )

    $previousUserProfile = $env:USERPROFILE
    $previousTemp = $env:TEMP
    $previousApi = $env:DSH_TEST_UPDATE_API
    $previousFiles = $env:DSH_TEST_UPDATE_FILES
    $previousFailStage = $env:DSH_TEST_UPDATE_FAIL_STAGE
    $previousFailRestore = $env:DSH_TEST_UPDATE_FAIL_RESTORE
    $previousMaintenanceTimeout = $env:DSH_TEST_MAINTENANCE_TIMEOUT_MS
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $env:USERPROFILE = $Fixture.ProfileRoot
        $env:TEMP = $Fixture.TempDir
        $env:DSH_TEST_UPDATE_API = $Environment.ApiPath
        $env:DSH_TEST_UPDATE_FILES = $Environment.FilesDir
        $env:DSH_TEST_UPDATE_FAIL_STAGE = $FailStage
        $env:DSH_TEST_UPDATE_FAIL_RESTORE = $FailRestore
        $env:DSH_TEST_MAINTENANCE_TIMEOUT_MS = $MaintenanceTimeout
        $ErrorActionPreference = 'Continue'
        if ($ViaCli) {
            $output = & cmd.exe /c ('"' + (Join-Path $Fixture.InstallDir 'deepseek.cmd') + '" --upgrade-launcher') 2>&1
        } elseif ($Upgrade) {
            $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass `
                -File (Join-Path $Fixture.InstallDir 'update-launcher.ps1') -Upgrade 2>&1
        } else {
            $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass `
                -File (Join-Path $Fixture.InstallDir 'update-launcher.ps1') 2>&1
        }
        return [pscustomobject]@{
            ExitCode = $LASTEXITCODE
            Output = [string]($output -join [Environment]::NewLine)
        }
    } finally {
        $env:USERPROFILE = $previousUserProfile
        $env:TEMP = $previousTemp
        $env:DSH_TEST_UPDATE_API = $previousApi
        $env:DSH_TEST_UPDATE_FILES = $previousFiles
        $env:DSH_TEST_UPDATE_FAIL_STAGE = $previousFailStage
        $env:DSH_TEST_UPDATE_FAIL_RESTORE = $previousFailRestore
        $env:DSH_TEST_MAINTENANCE_TIMEOUT_MS = $previousMaintenanceTimeout
        $ErrorActionPreference = $previousErrorActionPreference
    }
}

function Get-FixtureLeftovers {
    param([pscustomobject]$Fixture)
    $parent = Split-Path -Parent $Fixture.InstallDir
    return @(Get-ChildItem -LiteralPath $parent -Directory -Force -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -like '.dsh-launcher-old-*' -or $_.Name -like '.dsh-launcher-payload-*'
    })
}

New-Item -ItemType Directory -Force -Path $testRoot | Out-Null
try {
    Invoke-Test 'update check reports a newer launcher release and refuses nothing' {
        $fixture = New-LauncherFixture -Name 'check-new' -LocalVersion '0.1.0'
        $environment = New-UpdateEnvironment -Fixture $fixture -ReleaseVersion '0.2.0'
        $result = Invoke-LauncherUpdate -Fixture $fixture -Environment $environment
        Assert-Equal 0 $result.ExitCode "Check must succeed. Output:`n$($result.Output)"
        Assert-Match $result.Output ([regex]::Escape('0.1.0 -> 0.2.0')) 'The version transition must be displayed'
        Assert-Match $result.Output '--upgrade-launcher' 'The check must point at the upgrade command'
        Assert-Equal '0.1.0' ([IO.File]::ReadAllText($fixture.VersionFile).Trim()) 'A check must not modify the install'
        Assert-Equal 0 @(Get-FixtureLeftovers -Fixture $fixture).Count 'A check must not create transaction directories in the install parent'
    }

    Invoke-Test 'update check reports already-latest and locally-newer installs' {
        $fixture = New-LauncherFixture -Name 'check-same' -LocalVersion '1.2.3'
        $environment = New-UpdateEnvironment -Fixture $fixture -ReleaseVersion '1.2.3'
        $result = Invoke-LauncherUpdate -Fixture $fixture -Environment $environment
        Assert-Equal 0 $result.ExitCode "Already-latest check must succeed. Output:`n$($result.Output)"
        Assert-Match $result.Output ([regex]::Escape('已是最新版本'))

        $newerFixture = New-LauncherFixture -Name 'check-newer' -LocalVersion '2.0.0'
        $newerEnvironment = New-UpdateEnvironment -Fixture $newerFixture -ReleaseVersion '1.2.3'
        $newerResult = Invoke-LauncherUpdate -Fixture $newerFixture -Environment $newerEnvironment
        Assert-Equal 0 $newerResult.ExitCode "Locally-newer check must succeed. Output:`n$($newerResult.Output)"
        Assert-Match $newerResult.Output ([regex]::Escape('更新')) 'The locally-newer report must be explicit'
        Assert-NotMatch $newerResult.Output '--upgrade-launcher' 'A locally-newer install must not be sent to the upgrade command'
    }

    Invoke-Test 'update check refuses an invalid release tag' {
        $fixture = New-LauncherFixture -Name 'check-badtag' -LocalVersion '0.1.0'
        $environment = New-UpdateEnvironment -Fixture $fixture -ReleaseVersion '1.0.0'
        # Corrupt the tag after the environment was built.
        $apiText = [IO.File]::ReadAllText($environment.ApiPath) -replace '"tag_name":\s*"v1\.0\.0"', '"tag_name": "v1.0"'
        [IO.File]::WriteAllText($environment.ApiPath, $apiText, [Text.UTF8Encoding]::new($false))
        $result = Invoke-LauncherUpdate -Fixture $fixture -Environment $environment
        Assert-Equal 1 $result.ExitCode 'An invalid tag must fail the check'
        Assert-Match $result.Output ([regex]::Escape('无效')) 'The failure must name the invalid tag'
    }

    Invoke-Test 'upgrade refuses when the release offers no digest material' {
        $fixture = New-LauncherFixture -Name 'upgrade-nodigest' -LocalVersion '0.1.0'
        $environment = New-UpdateEnvironment -Fixture $fixture -ReleaseVersion '0.2.0' -NoDigest
        $result = Invoke-LauncherUpdate -Fixture $fixture -Environment $environment -Upgrade
        Assert-Equal 1 $result.ExitCode "A missing digest must refuse the upgrade. Output:`n$($result.Output)"
        Assert-Match $result.Output ([regex]::Escape('SHA-256')) 'The refusal must name the missing digest'
        Assert-Equal '0.1.0' ([IO.File]::ReadAllText($fixture.VersionFile).Trim()) 'The refused upgrade must leave the install untouched'
    }

    Invoke-Test 'upgrade refuses a digest mismatch' {
        $fixture = New-LauncherFixture -Name 'upgrade-baddigest' -LocalVersion '0.1.0'
        $wrongDigest = ('ab' * 32)
        $environment = New-UpdateEnvironment -Fixture $fixture -ReleaseVersion '0.2.0' -DigestOverride $wrongDigest
        $result = Invoke-LauncherUpdate -Fixture $fixture -Environment $environment -Upgrade
        Assert-Equal 1 $result.ExitCode "A digest mismatch must refuse the upgrade. Output:`n$($result.Output)"
        Assert-Match $result.Output ([regex]::Escape('SHA-256 校验失败')) 'The failure must identify the digest verification'
        Assert-Equal '0.1.0' ([IO.File]::ReadAllText($fixture.VersionFile).Trim()) 'The refused upgrade must leave the install untouched'
    }

    Invoke-Test 'upgrade refuses when the package VERSION does not match the release tag' {
        $fixture = New-LauncherFixture -Name 'upgrade-versionmismatch' -LocalVersion '0.1.0'
        $environment = New-UpdateEnvironment -Fixture $fixture -ReleaseVersion '0.2.0' -PackageVersion '0.9.9'
        $result = Invoke-LauncherUpdate -Fixture $fixture -Environment $environment -Upgrade
        Assert-Equal 1 $result.ExitCode "A package/tag mismatch must refuse. Output:`n$($result.Output)"
        Assert-Match $result.Output ([regex]::Escape('不一致')) 'The failure must explain the version mismatch'
        Assert-Equal '0.1.0' ([IO.File]::ReadAllText($fixture.VersionFile).Trim()) 'The refused upgrade must leave the install untouched'
    }

    Invoke-Test 'upgrade refuses a package with a path traversal entry' {
        $fixture = New-LauncherFixture -Name 'upgrade-traversal' -LocalVersion '0.1.0'
        $environment = New-UpdateEnvironment -Fixture $fixture -ReleaseVersion '0.2.0'
        # Inject a traversal entry into the shipped zip, then re-sign the digest
        # so the ONLY failure is the entry validation.
        Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null
        $zip = [IO.Compression.ZipFile]::Open($environment.ZipPath, 'Update')
        try {
            $evil = $zip.CreateEntry('../evil.txt')
            $writer = New-Object IO.StreamWriter($evil.Open())
            $writer.Write('evil')
            $writer.Dispose()
        } finally {
            $zip.Dispose()
        }
        $sha256 = (Get-FileHash $environment.ZipPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $apiText = [IO.File]::ReadAllText($environment.ApiPath) -replace ([regex]::Escape($environment.ZipSha256)), $sha256
        [IO.File]::WriteAllText($environment.ApiPath, $apiText, [Text.UTF8Encoding]::new($false))

        $result = Invoke-LauncherUpdate -Fixture $fixture -Environment $environment -Upgrade
        Assert-Equal 1 $result.ExitCode "A traversal entry must refuse the upgrade. Output:`n$($result.Output)"
        Assert-Match $result.Output ([regex]::Escape('路径穿越')) 'The failure must name the traversal entry'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $fixture.Root 'evil.txt'))) 'The traversal entry must not extract outside the staging dir'
        Assert-Equal '0.1.0' ([IO.File]::ReadAllText($fixture.VersionFile).Trim()) 'The refused upgrade must leave the install untouched'
    }

    Invoke-Test 'upgrade via the CLI replaces the install, survives self-overwrite and cleans up' {
        $fixture = New-LauncherFixture -Name 'upgrade-cli' -LocalVersion '0.1.0'
        $originalInstallationId = [string]((Get-Content -LiteralPath (Join-Path $fixture.InstallDir '.dsh-launcher-owner.json') -Raw | ConvertFrom-Json).InstallationId)
        $oldCmd = [IO.File]::ReadAllBytes((Join-Path $fixture.InstallDir 'deepseek.cmd'))
        $environment = New-UpdateEnvironment -Fixture $fixture -ReleaseVersion '0.2.0' `
            -ExtraCmdLine @('rem release 0.2.0 layout marker line that changes the file length')

        $result = Invoke-LauncherUpdate -Fixture $fixture -Environment $environment -Upgrade -ViaCli

        Assert-Equal 0 $result.ExitCode "The CLI self-update must succeed end to end. Output:`n$($result.Output)"
        Assert-Equal '0.2.0' ([IO.File]::ReadAllText($fixture.VersionFile).Trim()) 'The committed VERSION must match the release tag'
        $newCmd = [IO.File]::ReadAllBytes((Join-Path $fixture.InstallDir 'deepseek.cmd'))
        Assert-True ($oldCmd.Length -ne $newCmd.Length) 'The rewritten deepseek.cmd must have a different length'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $fixture.InstallDir '.dsh-launcher-old-*'))) 'The old-install backup must be removed after commit'
        Assert-Equal 0 @(Get-FixtureLeftovers -Fixture $fixture).Count 'A committed update must not leave transaction directories'
        $owner = Get-Content -LiteralPath (Join-Path $fixture.InstallDir '.dsh-launcher-owner.json') -Raw | ConvertFrom-Json
        Assert-Equal (Get-Item -LiteralPath $fixture.InstallDir).FullName ([IO.Path]::GetFullPath($owner.InstallPath)) 'The ownership marker must be regenerated for the same path'
        Assert-Equal $originalInstallationId ([string]$owner.InstallationId) 'The update must preserve the original InstallationId (design §4)'
        # Sentinels: runtimes and user data are never touched by a launcher update.
        Assert-True (Test-Path -LiteralPath (Join-Path $fixture.ProfileRoot 'dsh-launch\sentinel.txt')) 'The launch data sentinel must survive'
        Assert-True (Test-Path -LiteralPath (Join-Path $fixture.ProfileRoot '.dsh\sentinel.txt')) 'The .dsh sentinel must survive'
    }

    Invoke-Test 'a failed CLI self-update restores the old file set and still exits with a real code' {
        $fixture = New-LauncherFixture -Name 'upgrade-cli-fail' -LocalVersion '0.1.0'
        $oldCmd = [IO.File]::ReadAllBytes((Join-Path $fixture.InstallDir 'deepseek.cmd'))
        $environment = New-UpdateEnvironment -Fixture $fixture -ReleaseVersion '0.2.0' `
            -ExtraCmdLine @('rem release 0.2.0 layout marker line that changes the file length')

        $result = Invoke-LauncherUpdate -Fixture $fixture -Environment $environment -Upgrade -ViaCli -FailStage 'smoke'

        Assert-Equal 1 $result.ExitCode "A failed update must exit 1 through the rewritten CMD chain. Output:`n$($result.Output)"
        Assert-Equal '0.1.0' ([IO.File]::ReadAllText($fixture.VersionFile).Trim()) 'The old version must be restored'
        $restoredCmd = [IO.File]::ReadAllBytes((Join-Path $fixture.InstallDir 'deepseek.cmd'))
        Assert-True (($oldCmd.Length -eq $restoredCmd.Length)) 'The old deepseek.cmd layout must be restored byte-for-byte in length'
        Assert-Equal 0 @(Get-FixtureLeftovers -Fixture $fixture).Count 'A restored update must clean its transaction directories'
    }

    Invoke-Test 'a failed restore keeps the backup and the recover script and exits 2' {
        $fixture = New-LauncherFixture -Name 'upgrade-restore-fail' -LocalVersion '0.1.0'
        $environment = New-UpdateEnvironment -Fixture $fixture -ReleaseVersion '0.2.0'

        $result = Invoke-LauncherUpdate -Fixture $fixture -Environment $environment -Upgrade `
            -FailStage 'marker' -FailRestore '1'

        Assert-Equal 2 $result.ExitCode "A failed restore must exit 2. Output:`n$($result.Output)"
        Assert-Match $result.Output ([regex]::Escape('自动恢复未完成')) 'The output must state the restore did not finish'
        Assert-Match $result.Output ([regex]::Escape('recover-launcher.ps1')) 'The recover script location must be printed'
        $parent = Split-Path -Parent $fixture.InstallDir
        $oldBackups = @(Get-ChildItem -LiteralPath $parent -Directory -Force | Where-Object { $_.Name -like '.dsh-launcher-old-*' })
        Assert-Equal 1 $oldBackups.Count 'The old-install backup must survive a failed restore'
        Assert-True (Test-Path -LiteralPath (Join-Path $oldBackups[0].FullName 'deepseek.cmd')) 'The backup must contain the old install'
        Assert-Equal '0.2.0' ([IO.File]::ReadAllText($fixture.VersionFile).Trim()) 'The failed candidate stays in place until recovery'
        # 恢复脚本必须能独立工作：运行后旧安装回到原位。
        $txDir = (Get-ChildItem -LiteralPath $fixture.TempDir -Directory -Filter 'dsh-launcher-update-*' | Select-Object -First 1).FullName
        $recoverPath = Join-Path $txDir 'recover-launcher.ps1'
        Assert-True (Test-Path -LiteralPath $recoverPath) 'The recover script must exist inside the transaction dir'
        $previousRecoverEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $recoverOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $recoverPath 2>&1
            $recoverExit = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $previousRecoverEap
        }
        Assert-Equal 0 $recoverExit "The recover script must succeed. Output:`n$($recoverOutput -join [Environment]::NewLine)"
        Assert-Equal '0.1.0' ([IO.File]::ReadAllText($fixture.VersionFile).Trim()) 'After recovery the old VERSION must be back'
    }

    Invoke-Test 'upgrade refuses while a live startup lock is held' {
        $fixture = New-LauncherFixture -Name 'upgrade-busy' -LocalVersion '0.1.0'
        $environment = New-UpdateEnvironment -Fixture $fixture -ReleaseVersion '0.2.0'
        $stateHelper = Join-Path $fixture.InstallDir 'dsh-launch-state.ps1'
        $token = [guid]::NewGuid().ToString('N')
        # The lock owner must be a live process whose command line carries a
        # ROOTED -File script path; the identity check skips relative tokens.
        $holderScript = Join-Path $fixture.Root 'lock-holder.ps1'
        [IO.File]::WriteAllText($holderScript, "Start-Sleep -Seconds 180`r`n", [Text.Encoding]::ASCII)
        $holder = Start-Process powershell.exe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$holderScript`"") -WindowStyle Hidden -PassThru
        $lockOutput = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $stateHelper `
            -Action AcquireStartupLock -LaunchRoot (Join-Path $fixture.ProfileRoot 'dsh-launch') `
            -OwnerPid $holder.Id -StartupToken $token -CommandPath $holder.Path `
            -ScriptPath $holderScript)
        $lockText = [string]($lockOutput -join '')
        Assert-Match $lockText 'ACQUIRED|OWNED' "Fixture must hold a live startup lock. Output:`n$lockText"
        try {
            $result = Invoke-LauncherUpdate -Fixture $fixture -Environment $environment -Upgrade
            Assert-Equal 1 $result.ExitCode "A busy install must refuse the upgrade. Output:`n$($result.Output)"
            Assert-Match $result.Output ([regex]::Escape('启动器忙')) 'The refusal must name the busy state'
            Assert-Equal '0.1.0' ([IO.File]::ReadAllText($fixture.VersionFile).Trim()) 'A refused upgrade must leave the install untouched'
        } finally {
            $null = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $stateHelper `
                -Action ReleaseStartupLock -LaunchRoot (Join-Path $fixture.ProfileRoot 'dsh-launch') `
                -OwnerPid $holder.Id -StartupToken $token
            if ($holder -and -not $holder.HasExited) { Stop-Process -Id $holder.Id -Force -ErrorAction SilentlyContinue }
        }
    }

    Invoke-Test 'upgrade refuses a source worktree and an unmanaged directory' {
        $gitFixture = New-LauncherFixture -Name 'upgrade-git' -LocalVersion '0.1.0'
        New-Item -ItemType Directory -Force -Path (Join-Path $gitFixture.InstallDir '.git') | Out-Null
        $gitEnvironment = New-UpdateEnvironment -Fixture $gitFixture -ReleaseVersion '0.2.0'
        $gitResult = Invoke-LauncherUpdate -Fixture $gitFixture -Environment $gitEnvironment -Upgrade
        Assert-Equal 1 $gitResult.ExitCode 'A source worktree must refuse the upgrade'
        Assert-Match $gitResult.Output ([regex]::Escape('.git')) 'The refusal must name the source tree detection'

        $unmanagedFixture = New-LauncherFixture -Name 'upgrade-unmanaged' -LocalVersion '0.1.0' -NoOwnerMarker
        $unmanagedEnvironment = New-UpdateEnvironment -Fixture $unmanagedFixture -ReleaseVersion '0.2.0'
        $unmanagedResult = Invoke-LauncherUpdate -Fixture $unmanagedFixture -Environment $unmanagedEnvironment -Upgrade
        Assert-Equal 1 $unmanagedResult.ExitCode 'An unmanaged install must refuse the upgrade'
        Assert-Match $unmanagedResult.Output ([regex]::Escape('所有权标记')) 'The refusal must name the missing ownership marker'
    }

    Invoke-Test 'upgrade refuses while a DSH upgrade transaction is open' {
        # 设计 §3.3：更新与 DSH 升级互斥——未结束的升级事务必须阻止自更新。
        $fixture = New-LauncherFixture -Name 'upgrade-dsh-tx' -LocalVersion '0.1.0'
        $environment = New-UpdateEnvironment -Fixture $fixture -ReleaseVersion '0.2.0'
        $launchDir = Join-Path $fixture.ProfileRoot 'dsh-launch'
        New-Item -ItemType Directory -Force -Path $launchDir | Out-Null
        [IO.File]::WriteAllText((Join-Path $launchDir 'runtime-upgrade.json'), '{"SchemaVersion":1}', [Text.UTF8Encoding]::new($false))
        $result = Invoke-LauncherUpdate -Fixture $fixture -Environment $environment -Upgrade
        Assert-Equal 1 $result.ExitCode 'An open DSH upgrade transaction must refuse the self-update'
        Assert-Match $result.Output ([regex]::Escape('启动器忙')) 'The refusal must name the busy state'
        Assert-Equal '0.1.0' ([IO.File]::ReadAllText($fixture.VersionFile).Trim()) 'A refused upgrade must leave the install untouched'
    }

    Invoke-Test 'upgrade refuses to replace an install directory inside the .dsh boundary' {
        $fixture = New-LauncherFixture -Name 'upgrade-dsh-dir' -LocalVersion '0.1.0' -InstallInsideDsh
        $environment = New-UpdateEnvironment -Fixture $fixture -ReleaseVersion '0.2.0'
        $result = Invoke-LauncherUpdate -Fixture $fixture -Environment $environment -Upgrade
        Assert-Equal 1 $result.ExitCode 'An install inside .dsh must refuse the self-update'
        Assert-Match $result.Output ([regex]::Escape('受保护数据目录')) 'The refusal must name the protected data boundary'
    }

    Invoke-Test 'upgrade refuses when the install directory carries files outside the release manifest' {
        # 设计 §4：无关文件必须在变更前拒绝，否则会随旧安装备份一起被删除。
        $fixture = New-LauncherFixture -Name 'upgrade-foreign-file' -LocalVersion '0.1.0'
        [IO.File]::WriteAllText((Join-Path $fixture.InstallDir 'my-notes.txt'), 'keep me', [Text.Encoding]::ASCII)
        $environment = New-UpdateEnvironment -Fixture $fixture -ReleaseVersion '0.2.0'
        $result = Invoke-LauncherUpdate -Fixture $fixture -Environment $environment -Upgrade
        Assert-Equal 1 $result.ExitCode 'An unrelated file must refuse the self-update'
        Assert-Match $result.Output ([regex]::Escape('my-notes.txt')) 'The refusal must list the offending file'
        Assert-Equal 'keep me' ([IO.File]::ReadAllText((Join-Path $fixture.InstallDir 'my-notes.txt'))) 'The unrelated file must remain untouched'
        Assert-Equal '0.1.0' ([IO.File]::ReadAllText($fixture.VersionFile).Trim()) 'A refused upgrade must leave the install untouched'
    }

    Write-Host "All $script:Passed launcher update behavior tests passed."
} finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}

exit 0
