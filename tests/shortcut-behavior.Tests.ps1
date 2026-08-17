$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$shortcutScript = Join-Path $repoRoot 'set-shortcut.ps1'
$testRoot = Join-Path $env:TEMP ('dsh-shortcut-tests-' + [guid]::NewGuid().ToString('N'))
$installDir = Join-Path $testRoot 'Install Folder'
$desktopDir = Join-Path $testRoot 'Desktop'
$script:Passed = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-PathEqual {
    param([string]$Expected, [string]$Actual, [string]$Message)
    $matches = [string]::Equals(
        (Get-Item -LiteralPath $Expected).FullName.TrimEnd('\'),
        (Get-Item -LiteralPath $Actual).FullName.TrimEnd('\'),
        [StringComparison]::OrdinalIgnoreCase
    )
    if (-not $matches) {
        throw "$Message`nExpected: $Expected`nActual:   $Actual"
    }
}

function Assert-ShortcutCommand {
    param([string]$ExpectedPath, [string]$Actual, [string]$Message)
    $commandMatch = [regex]::Match($Actual, '^/d /c ""(?<Path>[^"]+)""$')
    if (-not $commandMatch.Success) {
        throw "$Message`nUnexpected command arguments: $Actual"
    }
    Assert-PathEqual $ExpectedPath $commandMatch.Groups['Path'].Value $Message
}

function Invoke-Test {
    param([string]$Name, [scriptblock]$Body)
    & $Body
    $script:Passed++
    Write-Host "PASS: $Name"
}

function Read-Shortcut {
    param([string]$Path)
    $shell = New-Object -ComObject WScript.Shell
    return $shell.CreateShortcut($Path)
}

New-Item -ItemType Directory -Force -Path $installDir, $desktopDir | Out-Null
[IO.File]::WriteAllText((Join-Path $installDir 'start-background.cmd'), '@echo off', [Text.Encoding]::ASCII)
[IO.File]::WriteAllBytes((Join-Path $installDir 'deepseek.ico'), [byte[]](0))

try {
    Invoke-Test 'creates a visible CMD shortcut with the interactive startup wrapper' {
        Assert-True (Test-Path -LiteralPath $shortcutScript) 'set-shortcut.ps1 should exist'
        $shortcutPath = Join-Path $desktopDir 'DeepSeek Harness.lnk'
        $output = & $shortcutScript -InstallDir $installDir -ShortcutPath $shortcutPath -Create
        Assert-True (Test-Path -LiteralPath $shortcutPath) 'Shortcut file should be created'

        $shortcut = Read-Shortcut -Path $shortcutPath
        Assert-PathEqual $env:ComSpec $shortcut.TargetPath 'Shortcut should target the visible Windows command processor'
        Assert-ShortcutCommand (Join-Path $installDir 'start-background.cmd') $shortcut.Arguments 'Shortcut should launch start-background.cmd with safe quoting'
        Assert-PathEqual $installDir $shortcut.WorkingDirectory 'Shortcut should use the install directory'
        Assert-True ($output -match '^CREATED:') 'Shortcut creation should report CREATED'
    }

    Invoke-Test 'migrates a recognized hidden PowerShell shortcut' {
        $shortcutPath = Join-Path $desktopDir 'Legacy DeepSeek Harness.lnk'
        $shell = New-Object -ComObject WScript.Shell
        $legacy = $shell.CreateShortcut($shortcutPath)
        $legacy.TargetPath = 'powershell.exe'
        $legacy.Arguments = '-NoProfile -WindowStyle Hidden -Command "cmd /c deepseek.cmd -b"'
        $legacy.WorkingDirectory = $installDir
        $legacy.Description = 'DeepSeek Harness (background mode)'
        $legacy.Save()

        $output = & $shortcutScript -InstallDir $installDir -ShortcutPath $shortcutPath
        $shortcut = Read-Shortcut -Path $shortcutPath
        Assert-PathEqual $env:ComSpec $shortcut.TargetPath 'Recognized legacy shortcut should be migrated to cmd.exe'
        Assert-True ($output -match '^UPDATED:') 'Recognized legacy shortcut should report UPDATED'
    }

    Invoke-Test 'does not overwrite an unrelated existing shortcut during automatic migration' {
        $shortcutPath = Join-Path $desktopDir 'Custom DeepSeek Harness.lnk'
        $shell = New-Object -ComObject WScript.Shell
        $custom = $shell.CreateShortcut($shortcutPath)
        $custom.TargetPath = 'notepad.exe'
        $custom.WorkingDirectory = $env:WINDIR
        $custom.Description = 'Personal shortcut'
        $custom.Save()

        $output = & $shortcutScript -InstallDir $installDir -ShortcutPath $shortcutPath
        $shortcut = Read-Shortcut -Path $shortcutPath
        Assert-PathEqual (Join-Path $env:WINDIR 'System32\notepad.exe') $shortcut.TargetPath 'Unrelated shortcut target should be preserved'
        Assert-True ($output -match '^SKIPPED:') 'Unrelated shortcut should report SKIPPED'
    }

    Write-Host "All $script:Passed shortcut behavior tests passed."
} finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}

exit 0
