param(
    [Parameter(Mandatory = $false)]
    [string]$TaskName = 'forge0btc-news-auto-topic',

    [Parameter(Mandatory = $false)]
    [int]$IntervalMinutes = 5,

    [Parameter(Mandatory = $false)]
    [string]$PasswordFile = $(Join-Path $env:USERPROFILE '.aibtc\news-signal.password'),

    [Parameter(Mandatory = $false)]
    [string]$WalletPassword
)

$ErrorActionPreference = 'Stop'

function Resolve-WalletPassword {
    param(
        [Parameter(Mandatory = $false)]
        [string]$ExplicitPassword
    )

    if ($ExplicitPassword) {
        return $ExplicitPassword
    }

    if ($env:AIBTC_WALLET_PASSWORD) {
        return $env:AIBTC_WALLET_PASSWORD
    }

    if ($env:WALLET_PASSWORD) {
        return $env:WALLET_PASSWORD
    }

    $securePassword = Read-Host 'Wallet password' -AsSecureString
    return [System.Net.NetworkCredential]::new('', $securePassword).Password
}

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$wrapperScript = Join-Path $scriptRoot 'run-news-signal-automation.ps1'

$effectivePassword = Resolve-WalletPassword -ExplicitPassword $WalletPassword
$secretDirectory = Split-Path -Parent $PasswordFile
if (-not (Test-Path $secretDirectory)) {
    New-Item -ItemType Directory -Path $secretDirectory | Out-Null
}

$securePassword = ConvertTo-SecureString -String $effectivePassword -AsPlainText -Force
$securePassword | ConvertFrom-SecureString | Set-Content -Path $PasswordFile -Encoding ASCII

 $startupFolder = [Environment]::GetFolderPath('Startup')
 if (-not $startupFolder) {
     throw 'Unable to resolve the Windows Startup folder.'
 }

 $launcherPath = Join-Path $startupFolder "$TaskName.vbs"
 $shellCommand = "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$wrapperScript`" -IntervalMinutes $IntervalMinutes -PasswordFile `"$PasswordFile`""
 $shellCommand = $shellCommand.Replace('"', '""')
 $launcherContent = @"
Set shell = CreateObject("WScript.Shell")
shell.Run "$shellCommand", 0, False
"@

 Set-Content -Path $launcherPath -Value $launcherContent -Encoding ASCII

[pscustomobject]@{
    success = $true
    launcherPath = $launcherPath
    passwordFile = $PasswordFile
    intervalMinutes = $IntervalMinutes
    wrapperScript = $wrapperScript
    trigger = 'Windows logon Startup folder'
    network = 'mainnet'
    message = 'Startup launcher installed. It will run the news auto-filer at logon and keep it looping every interval.'
}
