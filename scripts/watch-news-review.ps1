param(
    [Parameter(Mandatory = $false)]
    [string]$BunPath,

    [Parameter(Mandatory = $false)]
    [string]$WalletId,

    [Parameter(Mandatory = $false)]
    [string]$BtcAddress,

    [Parameter(Mandatory = $false)]
    [int]$IntervalMinutes = 5,

    [Parameter(Mandatory = $false)]
    [switch]$Continuous
)

$ErrorActionPreference = 'Stop'

if (-not $env:NETWORK) {
    $env:NETWORK = 'mainnet'
}

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$workspaceRoot = Join-Path $scriptRoot '..'
$skillsRoot = Join-Path $workspaceRoot 'aibtcdev-skills'
$watchLog = Join-Path $workspaceRoot 'daemon\news-review-watch.md'
$configPath = Join-Path $env:USERPROFILE '.aibtc\config.json'
$walletsPath = Join-Path $env:USERPROFILE '.aibtc\wallets.json'

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
        "C:\Program Files\bun\bun.exe",
        "C:\Program Files (x86)\bun\bun.exe",
        "C:\Users\a\bun\bun-windows-x64\bun.exe"
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

    throw "Unable to resolve the active wallet context. Pass -WalletId and -BtcAddress."
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

function Get-AgentStatus {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Address
    )

    $command = @(
        'run'
        (Join-Path $skillsRoot 'aibtc-news\aibtc-news.ts')
        'status'
        '--address'
        $Address
    )

    return Invoke-JsonCommand -Args $command
}

function Get-LatestSignal {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Address
    )

    $command = @(
        'run'
        (Join-Path $skillsRoot 'aibtc-news\aibtc-news.ts')
        'list-signals'
        '--address'
        $Address
        '--limit'
        '1'
    )

    $payload = Invoke-JsonCommand -Args $command
    $signals = @($payload.signals)

    if ($signals.Count -gt 0) {
        return $signals[0]
    }

    return $null
}

function Get-SignalField {
    param(
        [Parameter(Mandatory = $true)]
        $Signal,

        [Parameter(Mandatory = $true)]
        [string[]]$Names,

        [Parameter(Mandatory = $false)]
        $DefaultValue = $null
    )

    foreach ($name in $Names) {
        $property = $Signal.PSObject.Properties[$name]
        if ($property -and $null -ne $property.Value -and $property.Value -ne '') {
            return $property.Value
        }
    }

    return $DefaultValue
}

function Get-ContentSnippet {
    param(
        [Parameter(Mandatory = $false)]
        [string]$Text,

        [Parameter(Mandatory = $false)]
        [int]$MaxLength = 140
    )

    if (-not $Text) {
        return 'none'
    }

    $collapsed = ($Text -replace '\s+', ' ').Trim()
    if ($collapsed.Length -le $MaxLength) {
        return $collapsed
    }

    return $collapsed.Substring(0, $MaxLength - 1) + '…'
}

function Get-ReviewTakeaway {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SignalStatus,

        [Parameter(Mandatory = $false)]
        [string]$PublisherFeedback
    )

    switch ($SignalStatus) {
        'approved' { return 'Approved signal. Watch for brief inclusion and reuse the same concrete structure.' }
        'brief_included' { return 'Signal made the brief. Use this angle as a template for future filings.' }
        'rejected' {
            if ($PublisherFeedback -and $PublisherFeedback -ne 'none') {
                return "Rejected signal. Rewrite around the feedback: $PublisherFeedback"
            }

            return 'Rejected signal. Rewrite with tighter claim, evidence, and implication before refiling.'
        }
        default { return 'Still under review. Keep the next filing aligned to the beat and wait for a result.' }
    }
}

function Append-WatchLog {
    param(
        [Parameter(Mandatory = $true)]
        $StatusPayload,

        [Parameter(Mandatory = $true)]
        $LatestSignal
    )

    $stamp = Get-Date -Format 'yyyy-MM-ddTHH:mm:ssK'
    $beatSlug = $StatusPayload.status.beat.slug
    $beatName = $StatusPayload.status.beat.name
    $signalsToday = $StatusPayload.status.signalsToday
    $waitMinutes = if ($StatusPayload.status.waitMinutes) { "$($StatusPayload.status.waitMinutes) minutes" } else { 'none' }
    $signalHeadline = if ($LatestSignal) { Get-SignalField -Signal $LatestSignal -Names @('headline') -DefaultValue 'none' } else { 'none' }
    $signalEvidence = if ($LatestSignal) { Get-ContentSnippet -Text (Get-SignalField -Signal $LatestSignal -Names @('content') -DefaultValue '') } else { 'none' }
    $signalStatus = if ($LatestSignal) { Get-SignalField -Signal $LatestSignal -Names @('status') -DefaultValue 'none' } else { 'none' }
    $reviewedAt = if ($LatestSignal) { Get-SignalField -Signal $LatestSignal -Names @('reviewedAt', 'reviewed_at', 'reviewed') -DefaultValue 'pending' } else { 'pending' }
    $publisherFeedback = if ($LatestSignal) { Get-SignalField -Signal $LatestSignal -Names @('publisherFeedback', 'publisher_feedback') -DefaultValue 'none' } else { 'none' }
    $takeaway = Get-ReviewTakeaway -SignalStatus $signalStatus -PublisherFeedback $publisherFeedback

    $entry = @"
## $stamp
- Address: $($StatusPayload.address)
- Beat: $beatName ($beatSlug)
- Claim: $signalHeadline
- Evidence: $signalEvidence
- Signal status: $signalStatus
- Reviewed at: $reviewedAt
- Publisher feedback: $publisherFeedback
- Takeaway: $takeaway
- Signals today: $signalsToday
- Wait: $waitMinutes
"@

    if (-not (Test-Path $watchLog)) {
        Set-Content -Path $watchLog -Value "# forge0btc - News Review Watch`r`n"
    }

    Add-Content -Path $watchLog -Value $entry
}

$bun = Resolve-BunPath -ExplicitPath $BunPath
$context = Get-ActiveWalletContext
$script:WalletId = $context.WalletId
$script:BtcAddress = $context.BtcAddress
$WalletId = $script:WalletId
$BtcAddress = $script:BtcAddress

while ($true) {
    $status = Get-AgentStatus -Address $BtcAddress
    $latestSignal = Get-LatestSignal -Address $BtcAddress
    Append-WatchLog -StatusPayload $status -LatestSignal $latestSignal
    $latestSignalSnapshot = if ($latestSignal) {
        [pscustomobject]@{
            id = Get-SignalField -Signal $latestSignal -Names @('id')
            headline = Get-SignalField -Signal $latestSignal -Names @('headline')
            status = Get-SignalField -Signal $latestSignal -Names @('status')
            reviewedAt = Get-SignalField -Signal $latestSignal -Names @('reviewedAt', 'reviewed_at', 'reviewed')
            publisherFeedback = Get-SignalField -Signal $latestSignal -Names @('publisherFeedback', 'publisher_feedback')
            timestamp = Get-SignalField -Signal $latestSignal -Names @('timestamp')
        }
    } else {
        $null
    }

    $snapshot = [pscustomobject]@{
        timestamp = (Get-Date).ToString('o')
        address = $BtcAddress
        beat = [pscustomobject]@{
            slug = $status.status.beat.slug
            name = $status.status.beat.name
        }
        signalsToday = $status.status.signalsToday
        waitMinutes = $status.status.waitMinutes
        latestSignal = $latestSignalSnapshot
        takeaway = Get-ReviewTakeaway -SignalStatus (if ($latestSignalSnapshot) { $latestSignalSnapshot.status } else { 'none' }) -PublisherFeedback (if ($latestSignalSnapshot) { $latestSignalSnapshot.publisherFeedback } else { 'none' })
    }

    Write-Host ($snapshot | ConvertTo-Json -Depth 10)

    if (-not $Continuous) {
        break
    }

    Start-Sleep -Seconds ($IntervalMinutes * 60)
}