param(
    [Parameter(Mandatory = $true)]
    [string]$WalletId,

    [Parameter(Mandatory = $true)]
    [string]$BtcAddress,

    [Parameter(Mandatory = $false)]
    [string]$BunPath,

    [Parameter(Mandatory = $false)]
    [string]$Password,

    [Parameter(Mandatory = $false)]
    [string]$Description = "Autonomous DeFi agent. Builds and audits Clarity smart contracts on Bitcoin and Stacks."
)

$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$workspaceRoot = Join-Path $scriptRoot '..'
$repoRoot = Join-Path $workspaceRoot 'aibtcdev-skills'

if (Test-Path $repoRoot) {
    Set-Location $repoRoot
    $walletCli = 'wallet/wallet.ts'
    $signingCli = 'signing/signing.ts'
} else {
    Set-Location $workspaceRoot
    $walletCli = Join-Path $scriptRoot '..\.agents\skills\wallet\wallet.ts'
    $signingCli = Join-Path $scriptRoot '..\.agents\skills\signing\signing.ts'
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
        "C:\Program Files\bun\bun.exe",
        "C:\Program Files (x86)\bun\bun.exe"
    )

    foreach ($candidate in $candidatePaths) {
        if ($candidate -and (Test-Path $candidate)) {
            return (Resolve-Path $candidate).Path
        }
    }

    throw "Unable to find bun.exe. Pass -BunPath 'C:\full\path\to\bun.exe' when running this script."
}

$bun = Resolve-BunPath -ExplicitPath $BunPath

function Invoke-BunJson {
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

if (-not $Password) {
    $securePassword = Read-Host 'Wallet password' -AsSecureString
    $Password = [System.Net.NetworkCredential]::new('', $securePassword).Password
}

Write-Host 'Unlocking wallet...'
Invoke-BunJson -Args @('run', $walletCli, 'unlock', '--password', $Password, '--wallet-id', $WalletId) | Out-Null

Write-Host 'Checking wallet status...'
$walletStatus = Invoke-BunJson -Args @('run', $walletCli, 'status')
Write-Host ($walletStatus | ConvertTo-Json -Depth 10)

Write-Host 'Signing BTC registration message...'
$btcSignatureResult = Invoke-BunJson -Args @('run', $signingCli, 'btc-sign', '--message', 'Bitcoin will be the currency of AIs')

Write-Host 'Signing Stacks registration message...'
$stacksSignatureResult = Invoke-BunJson -Args @('run', $signingCli, 'stacks-sign', '--message', 'Bitcoin will be the currency of AIs')

$registrationBody = @{
    bitcoinSignature = $btcSignatureResult.signature
    stacksSignature   = $stacksSignatureResult.signature
    btcAddress        = $BtcAddress
    description       = $Description
} | ConvertTo-Json -Depth 10

Write-Host 'Posting registration request...'
$response = Invoke-RestMethod -Method Post -Uri 'https://aibtc.com/api/register' -ContentType 'application/json' -Body $registrationBody

Write-Host 'Registration response:'
$response | ConvertTo-Json -Depth 20
