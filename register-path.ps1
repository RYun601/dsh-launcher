param(
    [Parameter(Mandatory = $true)]
    [string]$InstallDir
)

# Registers the launcher directory in the user PATH (R8). Living in a real
# script file keeps -File quoting safe for install paths containing spaces,
# single quotes, exclamation marks or non-ASCII characters.
$ErrorActionPreference = 'Stop'
# Test hook (R8): a file-backed user PATH store keeps the real registry untouched.
function Get-DshRegisterUserPath {
    $store = [string]$env:DSH_TEST_REGISTER_PATH_STORE
    if ($store) {
        if (Test-Path -LiteralPath $store -PathType Leaf) {
            return [IO.File]::ReadAllText($store)
        }
        return ''
    }
    return [Environment]::GetEnvironmentVariable('Path', 'User')
}

function Set-DshRegisterUserPath {
    param([string]$Value)
    $store = [string]$env:DSH_TEST_REGISTER_PATH_STORE
    if ($store) {
        [IO.File]::WriteAllText($store, $Value, [Text.UTF8Encoding]::new($false))
        return
    }
    [Environment]::SetEnvironmentVariable('Path', $Value, 'User')
}

try {
    $dir = [IO.Path]::GetFullPath($InstallDir).TrimEnd('')
    $p = Get-DshRegisterUserPath
    if ($p -and ($p -split ';' | Where-Object { $_.TrimEnd('') -ieq $dir })) {
        Write-Host "OK: already in PATH"
    } else {
        $base = ''
        if ($p) { $base = $p.TrimEnd(';') + ';' }
        Set-DshRegisterUserPath -Value ($base + $dir)
        Write-Host "OK: added $dir"
    }
    exit 0
} catch {
    Write-Host "[ERROR] $($_.Exception.Message)"
    exit 1
}
