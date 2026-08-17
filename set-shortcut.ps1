param(
    [Parameter(Mandatory = $true)]
    [string]$InstallDir,

    [Parameter(Mandatory = $true)]
    [string]$ShortcutPath,

    [switch]$Create
)

$ErrorActionPreference = 'Stop'
$description = 'DeepSeek Harness (background mode)'
$normalizedInstallDir = [IO.Path]::GetFullPath($InstallDir).TrimEnd('\')
$normalizedShortcutPath = [IO.Path]::GetFullPath($ShortcutPath)
$wrapperPath = Join-Path $normalizedInstallDir 'start-background.cmd'
$iconPath = Join-Path $normalizedInstallDir 'deepseek.ico'

if (-not (Test-Path -LiteralPath $wrapperPath)) {
    throw "Startup wrapper not found: $wrapperPath"
}

$shell = New-Object -ComObject WScript.Shell
$shortcutExists = Test-Path -LiteralPath $normalizedShortcutPath
$action = 'CREATED'

if ($shortcutExists) {
    $existing = $shell.CreateShortcut($normalizedShortcutPath)
    $sameWorkingDirectory = [string]::Equals(
        $existing.WorkingDirectory.TrimEnd('\'),
        $normalizedInstallDir,
        [StringComparison]::OrdinalIgnoreCase
    )
    $recognized = $existing.Description -eq $description -and $sameWorkingDirectory

    if (-not $Create -and -not $recognized) {
        Write-Output "SKIPPED:$normalizedShortcutPath"
        return
    }

    $action = 'UPDATED'
} elseif (-not $Create) {
    Write-Output "SKIPPED:$normalizedShortcutPath"
    return
}

$commandProcessor = $env:ComSpec
if (-not $commandProcessor) {
    $commandProcessor = Join-Path $env:SystemRoot 'System32\cmd.exe'
}

$shortcut = $shell.CreateShortcut($normalizedShortcutPath)
$shortcut.TargetPath = $commandProcessor
$shortcut.Arguments = '/d /c ""{0}""' -f $wrapperPath
$shortcut.IconLocation = "$iconPath,0"
$shortcut.WorkingDirectory = $normalizedInstallDir
$shortcut.Description = $description
$shortcut.Save()

Write-Output "${action}:$normalizedShortcutPath"
