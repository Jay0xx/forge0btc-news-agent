param(
    [Parameter(Mandatory = $false)]
    [string]$BunPath,

    [Parameter(Mandatory = $false)]
    [string]$WalletId,

    [Parameter(Mandatory = $false)]
    [string]$WalletPassword,

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
$topicLog = Join-Path $workspaceRoot 'daemon\news-topic.md'
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
        throw "Wallet password is required for signal filing. Set AIBTC_WALLET_PASSWORD or WALLET_PASSWORD, or pass -WalletPassword."
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

function Get-NewsStatus {
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

function Get-DailyReportCandidate {
    $headers = @{
        'Accept' = 'application/json'
        'User-Agent' = 'BTC-AI-AGENT'
    }

    $report = Invoke-RestMethod -Uri 'https://aibtc.news/api/report' -Headers $headers -Method Get
    $headline = "AIBTC report shows $($report.signalsToday) signals and $($report.activeCorrespondents) active correspondents"
    $content = @"
The daily AIBTC report shows $($report.signalsToday) signals today and $($report.activeCorrespondents) active correspondents across $($report.totalBeats) beats.

Latest brief: $($report.latestBrief.date)
Why it matters: the network is still producing at high throughput, which is useful context for Infrastructure coverage and operational planning.
"@

    if ($headline.Length -gt 120) {
        $headline = $headline.Substring(0, 117).Trim() + '...'
    }

    if ($content.Length -gt 1000) {
        $content = $content.Substring(0, 997).Trim() + '...'
    }

    return [pscustomobject]@{
        repository = 'aibtc.news/report'
        name = 'Daily Report'
        tag = $report.date
        publishedAt = [datetime]::ParseExact($report.date, 'yyyy-MM-dd', $null)
        htmlUrl = 'https://aibtc.news/api/report'
        body = $content
        featureLead = $headline
        dedupeKey = "report-$($report.date)"
        sourceKind = 'daily-report'
    }
}

function Get-RecentSignals {
    param(
        [Parameter(Mandatory = $false)]
        [string]$BeatSlug,

        [Parameter(Mandatory = $false)]
        [int]$Limit = 25
    )

    $command = @(
        'run'
        (Join-Path $skillsRoot 'aibtc-news\aibtc-news.ts')
        'list-signals'
        '--limit'
        $Limit
    )

    if ($BeatSlug) {
        $command += @(
            '--beat-id'
            $BeatSlug
        )
    }

    $payload = Invoke-JsonCommand -Args $command
    if ($payload.signals) {
        return @($payload.signals)
    }

    return @()
}

function Get-GitHubRelease {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Repository
    )

    $headers = @{
        'Accept' = 'application/vnd.github+json'
        'User-Agent' = 'BTC-AI-AGENT'
        'X-GitHub-Api-Version' = '2022-11-28'
    }

    return Invoke-RestMethod -Uri "https://api.github.com/repos/$Repository/releases/latest" -Headers $headers -Method Get
}

function Get-FeatureLead {
    param(
        [Parameter(Mandatory = $true)]
        $Release
    )

    $lines = @($Release.body -split "`r?`n") | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    $featureLine = $lines | Where-Object { $_ -match '^[•*-]\s+' } | Select-Object -First 1

    if (-not $featureLine) {
        $featureLine = $lines | Select-Object -First 1
    }

    if (-not $featureLine) {
        return $Release.name
    }

    $lead = $featureLine -replace '^[•*-]\s*', ''
    $lead = $lead -replace '\s+\(.*$', ''
    $lead = $lead -replace '\s+\[#\d+\].*$', ''
    $lead = $lead -replace '\s+', ' '

    if ($lead.Length -gt 60) {
        $lead = $lead.Substring(0, 57).Trim() + '...'
    }

    return $lead
}

function Normalize-Text {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text
    )

    $normalized = $Text.ToLowerInvariant()
    $normalized = $normalized -replace '[^a-z0-9]+', ' '
    $normalized = ($normalized -replace '\s+', ' ').Trim()
    return $normalized
}

function Get-TextTokens {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text
    )

    $stopWords = @{
        'a' = $true
        'an' = $true
        'and' = $true
        'are' = $true
        'as' = $true
        'at' = $true
        'for' = $true
        'from' = $true
        'in' = $true
        'into' = $true
        'is' = $true
        'it' = $true
        'of' = $true
        'on' = $true
        'or' = $true
        'that' = $true
        'the' = $true
        'to' = $true
        'with' = $true
        'via' = $true
        'v' = $true
    }

    $normalized = Normalize-Text -Text $Text
    if (-not $normalized) {
        return @()
    }

    return @(
        $normalized -split ' '
        | Where-Object { $_ -and $_.Length -ge 3 -and -not $stopWords.ContainsKey($_) }
    )
}

function Test-TextOverlap {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CandidateText,

        [Parameter(Mandatory = $true)]
        [string]$SignalText
    )

    $candidateTokens = @(Get-TextTokens -Text $CandidateText | Sort-Object -Unique)
    $signalTokens = @(Get-TextTokens -Text $SignalText | Sort-Object -Unique)

    if ($candidateTokens.Count -eq 0 -or $signalTokens.Count -eq 0) {
        return $false
    }

    $sharedTokens = @($candidateTokens | Where-Object { $signalTokens -contains $_ })
    if ($sharedTokens.Count -lt 3) {
        return $false
    }

    $overlap = $sharedTokens.Count / [math]::Min($candidateTokens.Count, $signalTokens.Count)
    return $overlap -ge 0.6
}

function Get-TopicCandidates {
    $candidates = @()

    try {
        $candidates += Get-DailyReportCandidate
    } catch {
        Write-Host "Skipping daily report: $($_.Exception.Message)"
    }

    $repositories = @(
        'aibtcdev/aibtc-mcp-server',
        'aibtcdev/skills'
    )

    foreach ($repository in $repositories) {
        try {
            $release = Get-GitHubRelease -Repository $repository
            $featureLead = Get-FeatureLead -Release $release

            $candidates += [pscustomobject]@{
                repository = $repository
                name = $release.name
                tag = $release.tag_name
                publishedAt = [datetime]$release.published_at
                htmlUrl = $release.html_url
                body = $release.body
                featureLead = $featureLead
                dedupeKey = $release.tag_name
                sourceKind = 'release'
            }
        } catch {
            Write-Host "Skipping ${repository}: $($_.Exception.Message)"
        }
    }

    if (-not $candidates) {
        throw 'Unable to load any release candidates.'
    }

    return @($candidates | Sort-Object publishedAt -Descending)
}

function Select-TopicCandidate {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Candidates,

        [Parameter(Mandatory = $true)]
        [object[]]$Signals
    )

    foreach ($candidate in $Candidates) {
        if (-not (Test-AlreadyCovered -Candidate $candidate -Signals $Signals)) {
            return $candidate
        }
    }

    return $null
}

function Test-AlreadyCovered {
    param(
        [Parameter(Mandatory = $true)]
        $Candidate,

        [Parameter(Mandatory = $true)]
        [object[]]$Signals
    )

    $candidateText = @(
        $Candidate.dedupeKey
        $Candidate.featureLead
        $Candidate.name
        $Candidate.body
        $Candidate.repository
    ) -join ' '

    if (-not $candidateText) {
        return $false
    }

    foreach ($signal in $Signals) {
        $text = @(
            $signal.headline
            $signal.content
        ) -join ' '

        if (-not $text) {
            continue
        }

        if (Normalize-Text -Text $text -eq Normalize-Text -Text $candidateText) {
            return $true
        }

        if (Test-TextOverlap -CandidateText $candidateText -SignalText $text) {
            return $true
        }
    }

    return $false
}

function Build-SignalDraft {
    param(
        [Parameter(Mandatory = $true)]
        $Candidate
    )

    function Format-ThreePartBody {
        param(
            [Parameter(Mandatory = $true)]
            [string]$Claim,

            [Parameter(Mandatory = $true)]
            [string]$Evidence,

            [Parameter(Mandatory = $true)]
            [string]$Implication
        )

        return @"
$Claim

$Evidence

$Implication
"@
    }

    if ($Candidate.sourceKind -eq 'daily-report') {
        $claim = "AIBTC's daily report shows $($Candidate.featureLead -replace '^AIBTC report shows ', '') today, which means the network is still producing at high throughput."
        $evidence = "Evidence: the live report lists $($Candidate.body -replace '^The daily AIBTC report shows ', '')"
        $implication = "Implication: agents should treat Infrastructure coverage as a high-activity feed and focus on operational changes, backlog reduction, and anything that changes how correspondents file, review, or route signals."

        return [pscustomobject]@{
            headline = "AIBTC report shows $($Candidate.featureLead -replace '^AIBTC report shows ', '')"
            content = Format-ThreePartBody -Claim $claim -Evidence $evidence -Implication $implication
            sources = @(
                @{ url = $Candidate.htmlUrl; title = 'AIBTC Daily Report' }
            )
            tags = @('infrastructure', 'aibtc-news', 'report', 'throughput')
            disclosure = [pscustomobject]@{
                models = @('GPT-5.4 mini')
                tools = @('PowerShell', 'AIBTC daily report API', 'aibtc-news CLI')
                skills = @('aibtc-news')
                notes = 'Auto-selected from the live daily report.'
            }
        }
    }

    $headline = "AIBTC Infrastructure: $($Candidate.featureLead)"

    if ($headline.Length -gt 120) {
        $headline = $headline.Substring(0, 117).Trim() + '...'
    }

    $claim = "AIBTC $($Candidate.repository.Split('/')[1]) shipped $($Candidate.name) on $($Candidate.publishedAt.ToString('yyyy-MM-dd')), and the release changes the tooling layer agents depend on."
    $evidence = "Evidence: the release notes highlight $($Candidate.featureLead)."
    $implication = "Implication: correspondents should flag this as an operational update, not a generic changelog item, by stating which agent workflow improves or which failure mode is reduced."

    $content = Format-ThreePartBody -Claim $claim -Evidence $evidence -Implication $implication

    if ($content.Length -gt 1000) {
        $content = $content.Substring(0, 997).Trim() + '...'
    }

    return [pscustomobject]@{
        headline = $headline
        content = $content
        sources = @(
            @{ url = $Candidate.htmlUrl; title = $Candidate.name }
        )
        tags = @('infrastructure', 'release', 'github', ($Candidate.repository.Split('/')[1]))
        disclosure = [pscustomobject]@{
            models = @('GPT-5.4 mini')
            tools = @('PowerShell', 'GitHub Releases API', 'aibtc-news CLI')
            skills = @('aibtc-news')
            notes = 'Auto-selected from the freshest Infrastructure release candidate.'
        }
    }
}

function Write-TopicLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    if (-not (Test-Path $topicLog)) {
        Set-Content -Path $topicLog -Value "# forge0btc - Auto Topic Picks`r`n"
    }

    Add-Content -Path $topicLog -Value "`r`n## $(Get-Date -Format 'yyyy-MM-ddTHH:mm:ssK')`r`n$Message`r`n"
}

$bun = Resolve-BunPath -ExplicitPath $BunPath
$script:WalletPassword = $WalletPassword
Set-WalletEnvironment -Password $script:WalletPassword
$context = Get-ActiveWalletContext
$script:WalletId = $context.WalletId
$script:BtcAddress = $context.BtcAddress
$WalletId = $script:WalletId
$BtcAddress = $script:BtcAddress

while ($true) {
    $status = Get-NewsStatus -Address $BtcAddress
    $newsStatus = $status.status
    $beat = $newsStatus.beat
    $beatSlug = $beat.slug
    $beatName = $beat.name

    if (-not $newsStatus.canFileSignal) {
        Write-TopicLog -Message "Beat: $beatName ($beatSlug)`r`nSkipped: $($newsStatus.actions[0].description)"
        Write-Host ($status | ConvertTo-Json -Depth 10)
    } else {
        $recentSignals = @(Get-RecentSignals -Limit 50)
        $beatSignals = @(Get-RecentSignals -BeatSlug $beatSlug -Limit 20)
        $allSignals = @($recentSignals + $beatSignals | Select-Object -Unique)
        $candidates = Get-TopicCandidates
        $candidate = Select-TopicCandidate -Candidates $candidates -Signals $allSignals

        if (-not $candidate) {
            Write-TopicLog -Message "Skipped: all candidate topics are already covered in recent signals."
            Write-Host "All candidate topics are already covered in recent signals; nothing filed."
        } else {
            $draft = Build-SignalDraft -Candidate $candidate
            $sourceValue = ($draft.sources | Select-Object -First 1).url
            $tagsValue = $draft.tags -join ','
            $disclosureValue = ($draft.disclosure.notes)

            $command = @(
                'run'
                (Join-Path $skillsRoot 'aibtc-news\aibtc-news.ts')
                'file-signal'
                '--beat-id'
                $beatSlug
                '--headline'
                $draft.headline
                '--content'
                $draft.content
                '--sources'
                $sourceValue
                '--tags'
                $tagsValue
                '--disclosure'
                $disclosureValue
            )

            $result = Invoke-JsonCommand -Args $command
            Write-TopicLog -Message @"
Picked: $($candidate.repository) $($candidate.tag)
Headline: $($draft.headline)
Result: $($result.message)
"@
            Write-Host ($result | ConvertTo-Json -Depth 10)
        }
    }

    if (-not $Continuous) {
        break
    }

    Start-Sleep -Seconds ($IntervalMinutes * 60)
}