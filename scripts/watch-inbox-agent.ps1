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

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$workspaceRoot = Join-Path $scriptRoot '..'
$skillsRoot = Join-Path $workspaceRoot 'aibtcdev-skills'
$watchLog = Join-Path $workspaceRoot 'daemon\inbox-watch.md'
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

function Get-InboxSnapshot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Address
    )

    return Invoke-RestMethod -Uri "https://aibtc.com/api/inbox/$Address" -Method Get
}

function Append-WatchLog {
    param(
        [Parameter(Mandatory = $true)]
        $InboxPayload
    )

    $stamp = Get-Date -Format 'yyyy-MM-ddTHH:mm:ssK'
    $inbox = $InboxPayload.inbox
    $messageCount = if ($inbox.unreadCount) { $inbox.unreadCount } else { 0 }
    $latest = $null
    if ($inbox.messages -and $inbox.messages.Count -gt 0) {
        $latest = $inbox.messages | Sort-Object sentAt -Descending | Select-Object -First 1
    }

    $entry = @"
## $stamp
- Address: $($InboxPayload.agent.stxAddress)
- Display name: $($InboxPayload.agent.displayName)
- Total messages: $($inbox.totalCount)
- Unread messages: $($inbox.unreadCount)
- Last received: $($latest.sentAt)
- Unread fetched: $messageCount
"@

    if (-not (Test-Path $watchLog)) {
        Set-Content -Path $watchLog -Value "# forge0btc - Inbox Watch`r`n"
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
    $snapshot = Get-InboxSnapshot -Address $BtcAddress
    Append-WatchLog -InboxPayload $snapshot
    Write-Host ($snapshot | ConvertTo-Json -Depth 8)

    if (-not $Continuous) {
        break
    }

    Start-Sleep -Seconds ($IntervalMinutes * 60)
}
