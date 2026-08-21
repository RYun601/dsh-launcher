function ConvertTo-DshSemVer {
    param([Parameter(Mandatory = $true)][string]$Version)

    $match = [regex]::Match(
        $Version,
        '^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$'
    )
    if (-not $match.Success) { return $null }
    return [pscustomobject]@{
        Original = $Version
        Major = [uint64]$match.Groups[1].Value
        Minor = [uint64]$match.Groups[2].Value
        Patch = [uint64]$match.Groups[3].Value
        Prerelease = if ($match.Groups[4].Success) { @($match.Groups[4].Value -split '\.') } else { @() }
    }
}

function Compare-DshVersion {
    param(
        [Parameter(Mandatory = $true)][string]$Left,
        [Parameter(Mandatory = $true)][string]$Right
    )

    $leftVersion = ConvertTo-DshSemVer $Left
    $rightVersion = ConvertTo-DshSemVer $Right
    if (-not $leftVersion -or -not $rightVersion) {
        return [StringComparer]::OrdinalIgnoreCase.Compare($Left, $Right)
    }

    foreach ($component in @('Major', 'Minor', 'Patch')) {
        if ($leftVersion.$component -lt $rightVersion.$component) { return -1 }
        if ($leftVersion.$component -gt $rightVersion.$component) { return 1 }
    }

    if ($leftVersion.Prerelease.Count -eq 0 -and $rightVersion.Prerelease.Count -eq 0) { return 0 }
    if ($leftVersion.Prerelease.Count -eq 0) { return 1 }
    if ($rightVersion.Prerelease.Count -eq 0) { return -1 }

    $identifierCount = [Math]::Max($leftVersion.Prerelease.Count, $rightVersion.Prerelease.Count)
    for ($index = 0; $index -lt $identifierCount; $index++) {
        if ($index -ge $leftVersion.Prerelease.Count) { return -1 }
        if ($index -ge $rightVersion.Prerelease.Count) { return 1 }
        $leftId = [string]$leftVersion.Prerelease[$index]
        $rightId = [string]$rightVersion.Prerelease[$index]
        $leftNumeric = $leftId -match '^\d+$'
        $rightNumeric = $rightId -match '^\d+$'
        if ($leftNumeric -and $rightNumeric) {
            $leftNumber = [uint64]$leftId
            $rightNumber = [uint64]$rightId
            if ($leftNumber -lt $rightNumber) { return -1 }
            if ($leftNumber -gt $rightNumber) { return 1 }
        } elseif ($leftNumeric) {
            return -1
        } elseif ($rightNumeric) {
            return 1
        } else {
            $comparison = [StringComparer]::Ordinal.Compare($leftId, $rightId)
            if ($comparison -lt 0) { return -1 }
            if ($comparison -gt 0) { return 1 }
        }
    }
    return 0
}

function Get-HighestDshVersion {
    param([Parameter(Mandatory = $true, Position = 0)][object[]]$Versions)

    $highest = $null
    foreach ($candidateObject in @($Versions)) {
        $candidate = [string]$candidateObject
        if (-not $candidate) { continue }
        if (-not $highest -or (Compare-DshVersion $candidate $highest) -gt 0) {
            $highest = $candidate
        }
    }
    return $highest
}
