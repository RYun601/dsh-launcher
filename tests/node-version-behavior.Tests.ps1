$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$helperScript = Join-Path $repoRoot 'dsh-node-version.ps1'
$testRoot = Join-Path $env:TEMP ('dsh-node-version-tests-' + [guid]::NewGuid().ToString('N'))
$fakeBin = Join-Path $testRoot 'fake-bin'
$script:Passed = 0

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    if ($Expected -ne $Actual) { throw "$Message (expected: $Expected, actual: $Actual)" }
}

function Assert-Match {
    param([string]$Actual, [string]$Pattern, [string]$Message)
    if ($Actual -notmatch $Pattern) { throw "$Message`nActual:`n$Actual" }
}

function Invoke-Test {
    param([string]$Name, [scriptblock]$Body)
    & $Body
    $script:Passed++
    Write-Host "PASS: $Name"
}

function Invoke-NodeAssertion {
    param([Parameter(Mandatory = $true)][string]$NodeVersion)

    $previousPath = $env:PATH
    $previousNodeVersion = $env:DSH_TEST_NODE_VERSION
    try {
        $env:PATH = "$fakeBin;$previousPath"
        $env:DSH_TEST_NODE_VERSION = $NodeVersion
        $output = @(& {
            . $helperScript
            $result = Assert-DshNodeEnvironment
            Write-Output "RESULT:$result"
        } 6>&1)
        $resultLine = @($output | ForEach-Object { [string]$_ } | Where-Object { $_ -match '^RESULT:' } | Select-Object -Last 1)
        return [pscustomobject]@{
            Result = [bool]($resultLine -eq 'RESULT:True')
            Output = [string](($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine)
        }
    } finally {
        $env:PATH = $previousPath
        $env:DSH_TEST_NODE_VERSION = $previousNodeVersion
    }
}

New-Item -ItemType Directory -Force -Path $fakeBin | Out-Null
try {
    [IO.File]::WriteAllText(
        (Join-Path $fakeBin 'node.cmd'),
        "@echo off`r`nif `"%1`"==`"--version`" (`r`n  if `"%DSH_TEST_NODE_VERSION%`"==`"NONE`" exit /b 0`r`n  if not `"%DSH_TEST_NODE_VERSION%`"==`"`" echo %DSH_TEST_NODE_VERSION%`r`n)`r`nexit /b 0`r`n",
        [Text.Encoding]::ASCII
    )

    Invoke-Test 'reports the Node.js requirement for missing and unsupported versions' {
        $missingCurrentVersion = [string]::Concat([char[]]@(0x5f53, 0x524d, 0x7248, 0x672c, 0xff1a, 0x672a, 0x68c0, 0x6d4b, 0x5230))
        $missing = Invoke-NodeAssertion -NodeVersion 'NONE'
        Assert-Equal $false $missing.Result 'Missing Node must be rejected'
        Assert-Match $missing.Output $missingCurrentVersion 'Missing Node must state the current version'
        Assert-Match $missing.Output '\^22\.19\.0 \|\| >=24\.0\.0' 'Missing Node must state the range'
        Assert-Match $missing.Output '(?i)nodejs\.org|nvm-windows' 'Missing Node must state an upgrade method'

        $old = Invoke-NodeAssertion -NodeVersion 'v22.18.9'
        Assert-Equal $false $old.Result 'Node below the minimum must be rejected'
        Assert-Match $old.Output ($missingCurrentVersion.Substring(0, 5) + 'v22\.18\.9') 'Old Node must report its version'
    }

    Invoke-Test 'accepts the two supported Node.js version boundaries' {
        $minimum = Invoke-NodeAssertion -NodeVersion 'v22.19.0'
        Assert-Equal $true $minimum.Result 'The exact minimum must pass'

        $alternate = Invoke-NodeAssertion -NodeVersion 'v24.0.0'
        Assert-Equal $true $alternate.Result 'The alternate supported major must pass'
    }

    Invoke-Test 'all Node-aware entries use the shared prerequisite helper' {
        foreach ($entry in @('install.ps1', 'run-dsh.ps1', 'upgrade-dsh.ps1')) {
            $source = Get-Content -LiteralPath (Join-Path $repoRoot $entry) -Raw
            Assert-Match $source 'dsh-node-version\.ps1' "$entry must dot-source the shared Node helper"
            Assert-Match $source 'Assert-DshNodeEnvironment' "$entry must invoke the shared Node assertion"
        }
    }

    Write-Host "All $script:Passed Node version behavior tests passed."
} finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
