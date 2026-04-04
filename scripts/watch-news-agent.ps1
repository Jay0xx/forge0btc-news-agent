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
$watchLog = Join-Path $workspaceRoot 'daemon\news-watch.md'
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

function Get-StatusTakeaway {
    param(
        [Parameter(Mandatory = $true)]
        $StatusPayload
    )

    $waitMinutes = $StatusPayload.status.waitMinutes
    if ($waitMinutes -and $waitMinutes -gt 0) {
        return "Cooldown active. Wait $waitMinutes minutes before the next filing."
    }

    if ($StatusPayload.status.actions -and $StatusPayload.status.actions.Count -gt 0) {
        return ($StatusPayload.status.actions | Select-Object -First 1).description
    }

    return 'No immediate action returned. Check the beat and keep the next signal concrete.'
}

function Append-WatchLog {
    param(
        [Parameter(Mandatory = $true)]
        $StatusPayload
    )

    $stamp = Get-Date -Format 'yyyy-MM-ddTHH:mm:ssK'
    $beatSlug = $StatusPayload.status.beat.slug
    $beatName = $StatusPayload.status.beat.name
    $signalsToday = $StatusPayload.status.signalsToday
    $signalsFiled = $StatusPayload.status.totalSignals
    $cooldown = if ($StatusPayload.status.waitMinutes) { "$($StatusPayload.status.waitMinutes) minutes" } else { 'none' }
    $nextAction = ($StatusPayload.status.actions | Select-Object -First 1).description
    $takeaway = Get-StatusTakeaway -StatusPayload $StatusPayload

    $entry = @"
## $stamp
- Address: $($StatusPayload.address)
- Beat: $beatName ($beatSlug)
- Signals filed: $signalsFiled
- Signals today: $signalsToday
- Cooldown: $cooldown
- Next action: $nextAction
- Takeaway: $takeaway
- Display name: $($StatusPayload.status.display_name)
"@

    if (-not (Test-Path $watchLog)) {
        Set-Content -Path $watchLog -Value "# forge0btc - News Watch`r`n"
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
    Append-WatchLog -StatusPayload $status
    Write-Host ($status | ConvertTo-Json -Depth 8)

    if (-not $Continuous) {
        break
    }

    Start-Sleep -Seconds ($IntervalMinutes * 60)
}
