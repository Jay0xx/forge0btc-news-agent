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
    [string]$DraftOutputPath,

    [Parameter(Mandatory = $false)]
    [string]$DraftJsonPath,

    [Parameter(Mandatory = $false)]
    [string]$DraftInputPath,

    [Parameter(Mandatory = $false)]
    [int]$IntervalMinutes = 5,

    [Parameter(Mandatory = $false)]
    [switch]$DraftOnly,

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
$topicLog = Join-Path $workspaceRoot 'daemon\news-topic.md'
$errorLog = Join-Path $workspaceRoot 'daemon\news-signal-automation-error.log'
$draftLog = if ($DraftOutputPath) { $DraftOutputPath } else { Join-Path $workspaceRoot 'daemon\news-next-draft.md' }
$draftJsonLog = if ($DraftJsonPath) { $DraftJsonPath } else { [System.IO.Path]::ChangeExtension($draftLog, '.json') }
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

function Get-TodaySignalCount {
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
        100
    )

    $payload = Invoke-JsonCommand -Args $command
    $signals = @($payload.signals)
    $todayUtc = [datetime]::UtcNow.Date

    return @(
        $signals | Where-Object {
            if (-not $_.timestamp) {
                return $false
            }

            try {
                ([datetime]::Parse($_.timestamp)).ToUniversalTime().Date -eq $todayUtc
            } catch {
                $false
            }
        }
    ).Count
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

    $tokens = $normalized -split ' ' | Where-Object {
        $_ -and $_.Length -ge 3 -and -not $stopWords.ContainsKey($_)
    }

    return @($tokens)
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

        if ((Normalize-Text -Text $text) -eq (Normalize-Text -Text $candidateText)) {
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

    $headline = "AIBTC Infrastructure $($Candidate.tag): $($Candidate.featureLead)"

    if ($headline.Length -gt 120) {
        $headline = $headline.Substring(0, 117).Trim() + '...'
    }

    $content = @"
What changed: AIBTC $($Candidate.repository.Split('/')[1]) shipped $($Candidate.name) on $($Candidate.publishedAt.ToString('yyyy-MM-dd')), and the release changes the tooling layer agents depend on rather than just bumping version metadata.

What it means: the release notes highlight $($Candidate.featureLead), which is the specific feature-level change that alters how integrations route calls, validate capabilities, and stay aligned with the current tool surface.

Operational thesis: this is a workflow update, not a cosmetic release, because stale routing or outdated capability checks can miss the new path and leave automation pointed at the wrong interface. Correspondents should spell out which agent capability is now unlocked or safer to use.

What to do: use the new capability while it is still fresh, and verify the live release details again before filing if the source material changes.
"@

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

function Test-SignalDraft {
    param(
        [Parameter(Mandatory = $true)]
        $Draft,

        [Parameter(Mandatory = $true)]
        $Candidate
    )

    $contentSections = @(
        'What changed:'
        'What it means:'
        'Operational thesis:'
        'What to do:'
    )

    if (-not $Draft.headline -or $Draft.headline.Length -gt 120) {
        throw 'Draft headline must be present and 120 characters or fewer.'
    }

    if (-not $Draft.content -or $Draft.content.Length -gt 1000) {
        throw 'Draft content must be present and 1000 characters or fewer.'
    }

    foreach ($section in $contentSections) {
        if ($Draft.content -notmatch [regex]::Escape($section)) {
            throw "Draft content must include the section marker: $section"
        }
    }

    if (-not $Draft.sources -or @($Draft.sources).Count -lt 1 -or @($Draft.sources).Count -gt 5) {
        throw 'Draft sources must contain 1 to 5 primary URLs.'
    }

    foreach ($source in @($Draft.sources)) {
        if (-not $source.url -or -not ($source.url -match '^https://')) {
            throw 'Draft sources must use stable HTTPS URLs.'
        }
        if (-not $source.title) {
            throw 'Each draft source must include a title.'
        }
    }

    if (-not $Draft.tags -or @($Draft.tags).Count -lt 1 -or @($Draft.tags).Count -gt 10) {
        throw 'Draft tags must contain 1 to 10 entries.'
    }

    if (-not $Draft.disclosure -or -not $Draft.disclosure.notes) {
        throw 'Draft disclosure must include notes.'
    }

    if ($Candidate.sourceKind -eq 'release' -and ($Draft.headline -notmatch '\d')) {
        throw 'Release-based drafts must include a specific number in the headline.'
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

function Write-ErrorLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    Add-Content -Path $errorLog -Value "`r`n## $(Get-Date -Format 'yyyy-MM-ddTHH:mm:ssK')`r`n$Message`r`n"
}

function Read-DraftArtifact {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path $Path)) {
        throw "Draft artifact was not found: $Path"
    }

    $artifact = Get-Content $Path -Raw | ConvertFrom-Json
    if (-not $artifact.candidate -or -not $artifact.draft) {
        throw "Draft artifact is missing candidate or draft content: $Path"
    }

    return $artifact
}

function Write-DraftOutput {
    param(
        [Parameter(Mandatory = $true)]
        $Candidate,

        [Parameter(Mandatory = $true)]
        $Draft,

        [Parameter(Mandatory = $true)]
        [object]$Status
    )

    $artifact = [pscustomobject]@{
        generatedAt = (Get-Date).ToString('o')
        candidate = $Candidate
        draft = $Draft
        status = $Status
    }

    $statusJson = $Status | ConvertTo-Json -Depth 10
    $draftBody = @"
# forge0btc Next-Day News Draft

Generated: $(Get-Date -Format 'yyyy-MM-ddTHH:mm:ssK')
Mode: Draft only

## Candidate

- Repository: $($Candidate.repository)
- Release: $($Candidate.name)
- Tag: $($Candidate.tag)
- Published: $($Candidate.publishedAt.ToString('o'))
- URL: $($Candidate.htmlUrl)

## Headline

$($Draft.headline)

## Body

$($Draft.content)

## Sources

$(@($Draft.sources) | ForEach-Object { "- $($_.url)" } | Out-String)

## Tags

$(@($Draft.tags) | ForEach-Object { "- $_" } | Out-String)

## Disclosure

```json
$($Draft.disclosure | ConvertTo-Json -Depth 10)
```

## Live Status Snapshot

```json
$statusJson
```
"@

    Set-Content -Path $draftLog -Value $draftBody
    $artifact | ConvertTo-Json -Depth 10 | Set-Content -Path $draftJsonLog
}

try {
    $bun = Resolve-BunPath -ExplicitPath $BunPath
    if (-not $DraftOnly) {
        $script:WalletPassword = $WalletPassword
        Set-WalletEnvironment -Password $script:WalletPassword
    }
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

        $todaySignalCount = Get-TodaySignalCount -Address $BtcAddress

        if ($DraftOnly) {
            $recentSignals = @(Get-RecentSignals -Limit 50)
            $beatSignals = @(Get-RecentSignals -BeatSlug $beatSlug -Limit 20)
            $allSignals = @($recentSignals + $beatSignals | Select-Object -Unique)
            $candidates = Get-TopicCandidates
            $candidate = Select-TopicCandidate -Candidates $candidates -Signals $allSignals

            if (-not $candidate) {
                Write-TopicLog -Message "Draft mode: all candidate topics are already covered in recent signals."
                Write-Host "Draft mode: all candidate topics are already covered in recent signals; nothing drafted."
            } else {
                $draft = Build-SignalDraft -Candidate $candidate
                Test-SignalDraft -Draft $draft -Candidate $candidate
                Write-DraftOutput -Candidate $candidate -Draft $draft -Status $status
                Write-TopicLog -Message @"
Drafted for next day:
Repository: $($candidate.repository)
Tag: $($candidate.tag)
Headline: $($draft.headline)
Output: $draftLog
Artifact: $draftJsonLog
"@
                Write-Host "Draft written to $draftLog"
            }

            if (-not $Continuous) {
                break
            }

            Start-Sleep -Seconds ($IntervalMinutes * 60)
            continue
        }

        if ($todaySignalCount -ge 3) {
            Write-TopicLog -Message "Beat: $beatName ($beatSlug)`r`nSkipped: daily quality cap reached ($todaySignalCount/3). Try again tomorrow."
            Write-Host "Daily quality cap reached ($todaySignalCount/3); nothing filed."
            if (-not $Continuous) {
                break
            }

            Start-Sleep -Seconds ($IntervalMinutes * 60)
            continue
        }

        if (-not $newsStatus.canFileSignal) {
            Write-TopicLog -Message "Beat: $beatName ($beatSlug)`r`nSkipped: $($newsStatus.actions[0].description)"
            Write-Host ($status | ConvertTo-Json -Depth 10)
        } else {
            if ($DraftInputPath) {
                $artifact = Read-DraftArtifact -Path $DraftInputPath
                $candidate = $artifact.candidate
                $draft = $artifact.draft
                Test-SignalDraft -Draft $draft -Candidate $candidate
                Write-TopicLog -Message @"
Using draft artifact for filing:
Artifact: $DraftInputPath
Repository: $($candidate.repository)
Tag: $($candidate.tag)
Headline: $($draft.headline)
"@
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
                    Test-SignalDraft -Draft $draft -Candidate $candidate
                    Write-DraftOutput -Candidate $candidate -Draft $draft -Status $status
                }
            }

            if ($candidate) {
                $sourcesJson = @(
                    ($draft.sources | Select-Object -First 1).url
                ) | ConvertTo-Json -Compress
                $tagsJson = @($draft.tags) | ConvertTo-Json -Compress
                $disclosureJson = [pscustomobject]@{
                    notes = $draft.disclosure.notes
                } | ConvertTo-Json -Compress

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
                    $sourcesJson
                    '--tags'
                    $tagsJson
                    '--disclosure'
                    $disclosureJson
                )

                Write-TopicLog -Message @"
Attempting signal filing:
Artifact: $DraftInputPath
Repository: $($candidate.repository)
Tag: $($candidate.tag)
Headline: $($draft.headline)
Sources: $sourcesJson
Tags: $tagsJson
Disclosure: $disclosureJson
"@

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
}
catch {
    $errorRecord = $_
    $errorMessage = @(
        'Signal automation failed.'
        "Message: $($errorRecord.Exception.Message)"
        "Category: $($errorRecord.CategoryInfo.Category)"
        "TargetObject: $($errorRecord.TargetObject)"
        "FullyQualifiedErrorId: $($errorRecord.FullyQualifiedErrorId)"
        "ScriptStackTrace: $($errorRecord.ScriptStackTrace)"
        'ErrorRecord:'
        ($errorRecord | Out-String).Trim()
    ) -join "`r`n"

    Write-ErrorLog -Message $errorMessage
    Write-TopicLog -Message "Automation failed:`r`n$($errorRecord.Exception.Message)"
    throw
}