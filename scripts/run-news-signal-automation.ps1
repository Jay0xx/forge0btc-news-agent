param(
    [Parameter(Mandatory = $false)]
    [int]$IntervalMinutes = 5,

    [Parameter(Mandatory = $false)]
    [string]$PasswordFile = $(Join-Path $env:USERPROFILE '.aibtc\news-signal.password')
)

$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$autoSignalScript = Join-Path $scriptRoot 'auto-topic-news-signal.ps1'

if (-not (Test-Path $PasswordFile)) {
    throw "Password file not found: $PasswordFile"
}

$securePassword = Get-Content $PasswordFile -Raw | ConvertTo-SecureString
$password = [System.Net.NetworkCredential]::new('', $securePassword).Password

$env:NETWORK = 'mainnet'
$env:AIBTC_WALLET_PASSWORD = $password
$env:WALLET_PASSWORD = $password

& powershell -NoProfile -ExecutionPolicy Bypass -File $autoSignalScript -WalletPassword $password -IntervalMinutes $IntervalMinutes -Continuous
