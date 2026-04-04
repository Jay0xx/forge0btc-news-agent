param(
    [Parameter(Mandatory = $false)]
    [string]$BunPath,

    [Parameter(Mandatory = $false)]
    [string]$WalletPassword,

    [Parameter(Mandatory = $false)]
    [string]$BtcAddress,

    [Parameter(Mandatory = $false)]
    [switch]$AutoClaim,

    [Parameter(Mandatory = $false)]
    [double]$ClaimThreshold = 0.7,

    [Parameter(Mandatory = $false)]
    [int]$MinAmountSats = 1000,

    [Parameter(Mandatory = $false)]
    [int]$MaxClaims = 1
)

$ErrorActionPreference = 'Stop'

if (-not $env:NETWORK) {
    $env:NETWORK = 'mainnet'
}

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$workspaceRoot = Join-Path $scriptRoot '..'
$skillsRoot = Join-Path $workspaceRoot 'aibtcdev-skills'
$daemonRoot = Join-Path $workspaceRoot 'daemon'
$scanLog = Join-Path $daemonRoot 'bounty-scan.md'
$scanJsonLog = Join-Path $daemonRoot 'bounty-scan.json'
$errorLog = Join-Path $daemonRoot 'bounty-scan-error.log'
$claimLog = Join-Path $daemonRoot 'bounty-claim.log'
$configPath = Join-Path $env:USERPROFILE '.aibtc\config.json'
$walletsPath = Join-Path $env:USERPROFILE '.aibtc\wallets.json'

function Set-WalletEnvironment {
    param(
        [Parameter(Mandatory = $false)]
        [string]$Password
    )

    $effectivePassword = $Password
    if (-not $effectivePassword) {
        $effectivePassword = $env:AIBTC_WALLET_PASSWORD
    }
    if (-not $effectivePassword) {
        $effectivePassword = $env:WALLET_PASSWORD
    }

    if (-not $effectivePassword) {
        throw 'Wallet password is required. Set AIBTC_WALLET_PASSWORD or WALLET_PASSWORD, or pass -WalletPassword.'
    }

    $env:AIBTC_WALLET_PASSWORD = $effectivePassword
    $env:WALLET_PASSWORD = $effectivePassword
}

function Resolve-BunPath {
    param(
        [Parameter(Mandatory = $false)]
        [string]$ExplicitPath
    )

    if ($ExplicitPath) {
        if (Test-Path $ExplicitPath) {
            return (Resolve-Path $ExplicitPath).Path
        }

        throw "BunPath was provided but not found: $ExplicitPath"
    }

    $command = Get-Command bun -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    $candidatePaths = @(
        "$env:LOCALAPPDATA\bun\bin\bun.exe",
        "$env:USERPROFILE\AppData\Local\bun\bin\bun.exe",
        'C:\Program Files\bun\bun.exe',
        'C:\Program Files (x86)\bun\bun.exe',
        'C:\Users\a\bun\bun-windows-x64\bun.exe'
    )

    foreach ($candidate in $candidatePaths) {
        if ($candidate -and (Test-Path $candidate)) {
            return (Resolve-Path $candidate).Path
        }
    }

    throw "Unable to find bun.exe. Pass -BunPath 'C:\full\path\to\bun.exe'."
}

function Get-ActiveWalletContext {
    if ($script:WalletId -and $script:BtcAddress) {
        return @{ WalletId = $script:WalletId; BtcAddress = $script:BtcAddress }
    }

    if ((Test-Path $configPath) -and (Test-Path $walletsPath)) {
        $config = Get-Content $configPath -Raw | ConvertFrom-Json
        $wallets = Get-Content $walletsPath -Raw | ConvertFrom-Json
        $wallet = $wallets.wallets | Where-Object { $_.id -eq $config.activeWalletId } | Select-Object -First 1

        if ($wallet) {
            if (-not $script:WalletId) { $script:WalletId = $wallet.id }
            if (-not $script:BtcAddress) { $script:BtcAddress = $wallet.btcAddress }
            return @{ WalletId = $script:WalletId; BtcAddress = $script:BtcAddress }
        }
    }

    throw 'Unable to resolve the active wallet context. Pass -BtcAddress or unlock a wallet first.'
}

function Invoke-JsonCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Args
    )

    $output = & $bun @Args 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        throw $output.Trim()
    }

    return ($output | ConvertFrom-Json)
}

function Write-BountyLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    if (-not (Test-Path $scanLog)) {
        Set-Content -Path $scanLog -Value "# forge0btc - Bounty Scan`r`n"
    }

    Add-Content -Path $scanLog -Value "`r`n## $(Get-Date -Format 'yyyy-MM-ddTHH:mm:ssK')`r`n$Message`r`n"
}

function Write-BountyErrorLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    Add-Content -Path $errorLog -Value "`r`n## $(Get-Date -Format 'yyyy-MM-ddTHH:mm:ssK')`r`n$Message`r`n"
}

function New-ClaimMessage {
    param(
        [Parameter(Mandatory = $true)]
        $Match
    )

    return @"
Auto-claim via GitHub Actions
UUID: $($Match.uuid)
Title: $($Match.title)
Confidence: $($Match.confidence)
Approach: I can complete this bounty and will submit proof promptly.
"@.Trim()
}

function Select-ClaimableMatches {
    param(
        [Parameter(Mandatory = $true)]
        [array]$Matches
    )

    return @(
        $Matches | Where-Object {
            $_.confidence -ge $ClaimThreshold -and $_.amount_sats -ge $MinAmountSats
        } | Sort-Object -Property @{ Expression = 'confidence'; Descending = $true }, @{ Expression = 'amount_sats'; Descending = $true }
    )
}

try {
    $bun = Resolve-BunPath -ExplicitPath $BunPath
    $script:WalletPassword = $WalletPassword
    if ($AutoClaim) {
        Set-WalletEnvironment -Password $script:WalletPassword
    }

    $context = Get-ActiveWalletContext
    $script:WalletId = $context.WalletId
    $script:BtcAddress = $context.BtcAddress
    $WalletId = $script:WalletId
    $BtcAddress = $script:BtcAddress

    $status = Invoke-JsonCommand -Args @('run', (Join-Path $skillsRoot 'bounty-scanner\bounty-scanner.ts'), 'status')
    $match = Invoke-JsonCommand -Args @('run', (Join-Path $skillsRoot 'bounty-scanner\bounty-scanner.ts'), 'match')
    $claimable = Select-ClaimableMatches -Matches @($match.matches)

    $artifact = [pscustomobject]@{
        generatedAt = (Get-Date).ToString('o')
        wallet = [pscustomobject]@{
            btcAddress = $BtcAddress
            walletId = $WalletId
        }
        status = $status
        match = $match
        claimable = $claimable
    }

    $scanBody = @"
# forge0btc Bounty Scan

Generated: $(Get-Date -Format 'yyyy-MM-ddTHH:mm:ssK')

## Board Status

```json
$($status | ConvertTo-Json -Depth 10)
```

## Match Summary

```json
$($match | ConvertTo-Json -Depth 10)
```

## Claimable Matches

```json
$($claimable | ConvertTo-Json -Depth 10)
```
"@

    Set-Content -Path $scanLog -Value $scanBody
    $artifact | ConvertTo-Json -Depth 10 | Set-Content -Path $scanJsonLog

    if (-not $AutoClaim) {
        Write-BountyLog -Message "Scan completed without auto-claim. Claimable matches: $($claimable.Count)."
        Write-Host ($match | ConvertTo-Json -Depth 10)
        return
    }

    if (-not $claimable -or $claimable.Count -lt 1) {
        Write-BountyLog -Message "Auto-claim enabled but no match met the threshold ($ClaimThreshold) and minimum amount ($MinAmountSats sats)."
        Write-Host 'No bounty met the auto-claim threshold.'
        return
    }

    $claimsIssued = 0
    foreach ($candidate in $claimable) {
        if ($claimsIssued -ge $MaxClaims) {
            break
        }

        $detail = Invoke-JsonCommand -Args @('run', (Join-Path $skillsRoot 'bounty-scanner\bounty-scanner.ts'), 'detail', $candidate.uuid)
        if (-not $detail.bounty -or $detail.bounty.status -ne 'open') {
            Write-BountyLog -Message "Skipped $($candidate.uuid): bounty is no longer open."
            continue
        }

        $claimMessage = New-ClaimMessage -Match $candidate
        $claimInfo = Invoke-JsonCommand -Args @('run', (Join-Path $skillsRoot 'bounty-scanner\bounty-scanner.ts'), 'claim', $candidate.uuid, '--message', $claimMessage)

        $payload = [ordered]@{}
        foreach ($property in @($claimInfo.required_fields.psobject.Properties.Name)) {
            $payload[$property] = $claimInfo.required_fields.$property
        }

        if (-not $payload.Contains('message')) {
            $payload['message'] = $claimMessage
        }
        if (-not $payload.Contains('btc_address') -and -not $payload.Contains('btcAddress')) {
            $payload['btcAddress'] = $BtcAddress
        }
        if (-not $payload.Contains('timestamp')) {
            $payload['timestamp'] = (Get-Date).ToUniversalTime().ToString('o')
        }

        $btcSignArgs = @(
            'run'
            (Join-Path $skillsRoot 'signing\signing.ts')
            'btc-sign'
            '--message'
            $claimMessage
        )
        $signatureResult = Invoke-JsonCommand -Args $btcSignArgs
        $payload['signature'] = $signatureResult.signature

        $jsonBody = $payload | ConvertTo-Json -Depth 10 -Compress
        Write-BountyLog -Message @"
Attempting bounty claim:
UUID: $($candidate.uuid)
Title: $($candidate.title)
Endpoint: $($claimInfo.endpoint)
Signing format: $($claimInfo.signing_format)
Message: $claimMessage
Payload: $jsonBody
"@

        try {
            $submitResponse = Invoke-RestMethod -Method $claimInfo.method -Uri $claimInfo.endpoint -ContentType 'application/json' -Body $jsonBody
            $submitResponse | ConvertTo-Json -Depth 10 | Add-Content -Path $claimLog
            Write-BountyLog -Message @"
Claim submitted:
UUID: $($candidate.uuid)
Title: $($candidate.title)
Response: $($submitResponse | ConvertTo-Json -Depth 10)
"@
            $claimsIssued++
        } catch {
            $errorRecord = $_
            $errorMessage = @(
                'Bounty claim failed.'
                "UUID: $($candidate.uuid)"
                "Message: $($errorRecord.Exception.Message)"
                "Category: $($errorRecord.CategoryInfo.Category)"
                "FullyQualifiedErrorId: $($errorRecord.FullyQualifiedErrorId)"
                ($errorRecord | Out-String).Trim()
            ) -join "`r`n"

            Write-BountyErrorLog -Message $errorMessage
            Write-BountyLog -Message "Claim failed for $($candidate.uuid): $($errorRecord.Exception.Message)"
        }
    }

    if ($claimsIssued -eq 0) {
        Write-BountyLog -Message 'No claims were submitted this run.'
    }
}
catch {
    $errorRecord = $_
    $errorMessage = @(
        'Bounty automation failed.'
        "Message: $($errorRecord.Exception.Message)"
        "Category: $($errorRecord.CategoryInfo.Category)"
        "TargetObject: $($errorRecord.TargetObject)"
        "FullyQualifiedErrorId: $($errorRecord.FullyQualifiedErrorId)"
        "ScriptStackTrace: $($errorRecord.ScriptStackTrace)"
        'ErrorRecord:'
        ($errorRecord | Out-String).Trim()
    ) -join "`r`n"

    Write-BountyErrorLog -Message $errorMessage
    throw
}