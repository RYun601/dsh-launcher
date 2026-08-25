function Test-DshCommandLineArgument {
    param(
        [string]$CommandLine,
        [string]$ExpectedPath
    )

    if ([string]::IsNullOrWhiteSpace($CommandLine) -or [string]::IsNullOrWhiteSpace($ExpectedPath)) {
        return $false
    }

    try {
        $escaped = [regex]::Escape([IO.Path]::GetFullPath($ExpectedPath))
    } catch {
        return $false
    }
    return $CommandLine -match ('(?i)(?:^|\s)"?' + $escaped + '"?(?:\s|$)')
}

function Get-DshPortOwner {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateRange(1, 65535)]
        [int]$Port
    )

    try {
        $connections = @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction Stop)
    } catch {
        return $null
    }
    if ($connections.Count -eq 0) {
        return $null
    }

    $connection = $connections | Sort-Object OwningProcess | Select-Object -First 1
    return [pscustomobject]@{
        ProcessId     = [int]$connection.OwningProcess
        OwningProcess = [int]$connection.OwningProcess
        LocalAddress  = [string]$connection.LocalAddress
        LocalPort     = [int]$connection.LocalPort
    }
}

function Test-DshProcessIdentity {
    param(
        [Parameter(Mandatory = $true)][int]$ProcessId,
        [Parameter(Mandatory = $true)][string]$ExpectedEntrypoint
    )

    if ($ProcessId -le 0) {
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

    $processName = [string]$process.Name
    if ($processName -notmatch '^(?i:node(?:\.exe)?)$') {
        return $false
    }

    return Test-DshCommandLineArgument -CommandLine ([string]$process.CommandLine) `
        -ExpectedPath $ExpectedEntrypoint
}

function Invoke-DshHttpProbe {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateRange(1, 65535)]
        [int]$Port
    )

    $response = $null
    $failureMessage = ''
    try {
        $request = [Net.HttpWebRequest]::Create("http://127.0.0.1:$Port/")
        $request.Method = 'GET'
        $request.AllowAutoRedirect = $false
        $request.Timeout = 2000
        $request.ReadWriteTimeout = 2000
        $response = $request.GetResponse()
    } catch [Net.WebException] {
        $failureMessage = $_.Exception.Message
        $response = $_.Exception.Response
    } catch {
        return [pscustomobject]@{
            IsReady   = $false
            StatusCode = $null
            BodyMatches = $false
            Message   = $_.Exception.Message
        }
    }

    if (-not $response) {
        return [pscustomobject]@{
            IsReady    = $false
            StatusCode = $null
            BodyMatches = $false
            Message    = $failureMessage
        }
    }

    try {
        $statusCode = [int]$response.StatusCode
        $stream = $response.GetResponseStream()
        $buffer = New-Object byte[] 8192
        $bodyBuffer = [IO.MemoryStream]::new()
        try {
            $maximumBytes = 256KB
            while ($bodyBuffer.Length -lt $maximumBytes) {
                $remaining = [int]($maximumBytes - $bodyBuffer.Length)
                $readLength = [Math]::Min($buffer.Length, $remaining)
                $read = $stream.Read($buffer, 0, $readLength)
                if ($read -le 0) { break }
                $bodyBuffer.Write($buffer, 0, $read)
            }
            $body = [Text.Encoding]::UTF8.GetString($bodyBuffer.ToArray())
        } finally {
            $bodyBuffer.Dispose()
            if ($stream) { $stream.Dispose() }
        }

        $bodyMatches = $body -match 'id=[\x22\x27]root[\x22\x27]'
        $successfulStatus = $statusCode -ge 200 -and $statusCode -lt 400
        $message = if (-not $successfulStatus) {
            "HTTP returned status $statusCode"
        } elseif (-not $bodyMatches) {
            'HTTP response is not a DeepSeek Harness page'
        } else {
            'DeepSeek Harness HTTP endpoint is ready'
        }
        return [pscustomobject]@{
            IsReady    = $successfulStatus -and $bodyMatches
            StatusCode = $statusCode
            BodyMatches = $bodyMatches
            Message    = $message
        }
    } catch {
        return [pscustomobject]@{
            IsReady    = $false
            StatusCode = $null
            BodyMatches = $false
            Message    = $_.Exception.Message
        }
    } finally {
        $response.Dispose()
    }
}

function New-DshServiceClassificationResult {
    param(
        [Parameter(Mandatory = $true)][string]$State,
        [int]$ServicePid,
        [Parameter(Mandatory = $true)][string]$Message,
        $HttpStatus,
        [Parameter(Mandatory = $true)][string]$Entrypoint
    )

    return [pscustomobject][ordered]@{
        State      = $State
        ServicePid = $ServicePid
        Message    = $Message
        HttpStatus = $HttpStatus
        Entrypoint = $Entrypoint
    }
}

function Get-DshServiceClassification {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateRange(1, 65535)]
        [int]$Port,
        [Parameter(Mandatory = $true)][string]$ExpectedEntrypoint,
        [string]$ExpectedStartupToken,
        [int]$RunnerPid
    )

    try {
        $entrypoint = [IO.Path]::GetFullPath($ExpectedEntrypoint)
    } catch {
        $entrypoint = $ExpectedEntrypoint
    }

    $owner = Get-DshPortOwner -Port $Port
    if (-not $owner) {
        return New-DshServiceClassificationResult -State 'STOPPED' -ServicePid 0 `
            -Message "Port $Port is not listening" -HttpStatus $null -Entrypoint $entrypoint
    }

    $servicePid = [int]$owner.ProcessId
    if (-not (Test-DshProcessIdentity -ProcessId $servicePid -ExpectedEntrypoint $entrypoint)) {
        return New-DshServiceClassificationResult -State 'FOREIGN_PORT' -ServicePid $servicePid `
            -Message "Port $Port is owned by a process that is not DeepSeek Harness" `
            -HttpStatus $null -Entrypoint $entrypoint
    }

    if ([string]::IsNullOrWhiteSpace($ExpectedStartupToken)) {
        return New-DshServiceClassificationResult -State 'UNHEALTHY' -ServicePid $servicePid `
            -Message 'The DeepSeek Harness listener has no startup token evidence' `
            -HttpStatus $null -Entrypoint $entrypoint
    }

    $runner = if ($RunnerPid -gt 0) {
        Get-Process -Id $RunnerPid -ErrorAction SilentlyContinue
    } else {
        $null
    }
    if (-not $runner) {
        return New-DshServiceClassificationResult -State 'UNHEALTHY' -ServicePid $servicePid `
            -Message 'The DeepSeek Harness listener has no live runner evidence' `
            -HttpStatus $null -Entrypoint $entrypoint
    }

    $probe = Invoke-DshHttpProbe -Port $Port
    if (-not $probe.IsReady) {
        return New-DshServiceClassificationResult -State 'UNHEALTHY' -ServicePid $servicePid `
            -Message $probe.Message -HttpStatus $probe.StatusCode -Entrypoint $entrypoint
    }

    return New-DshServiceClassificationResult -State 'READY' -ServicePid $servicePid `
        -Message 'DeepSeek Harness service identity and HTTP health are verified' `
        -HttpStatus $probe.StatusCode -Entrypoint $entrypoint
}

function Wait-DshServiceIdentity {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateRange(1, 65535)]
        [int]$Port,
        [Parameter(Mandatory = $true)][string]$ExpectedEntrypoint,
        [string]$ExpectedStartupToken,
        [int]$RunnerPid,
        [ValidateRange(0, 60000)]
        [int]$StableMilliseconds = 0,
        [ValidateRange(1, 60000)]
        [int]$PollMilliseconds = 100
    )

    $pinnedServicePid = 0
    $stableTimer = [Diagnostics.Stopwatch]::new()
    while ($true) {
        $classification = Get-DshServiceClassification -Port $Port `
            -ExpectedEntrypoint $ExpectedEntrypoint -ExpectedStartupToken $ExpectedStartupToken `
            -RunnerPid $RunnerPid
        if ($classification.State -ne 'READY') {
            return $classification
        }
        if ($StableMilliseconds -eq 0) {
            return $classification
        }

        if ($pinnedServicePid -ne $classification.ServicePid) {
            $pinnedServicePid = $classification.ServicePid
            $stableTimer.Restart()
        } elseif ($stableTimer.ElapsedMilliseconds -ge $StableMilliseconds) {
            return $classification
        }

        Start-Sleep -Milliseconds $PollMilliseconds
    }
}
