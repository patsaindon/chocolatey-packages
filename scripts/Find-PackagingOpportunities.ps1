[CmdletBinding()]
param(
    [string]
    $ReferencePath = (Join-Path $PSScriptRoot '..\prospecting\packaging-opportunities-reference.csv'),

    [string]
    $CursorPath = (Join-Path $PSScriptRoot '..\prospecting\packaging-opportunities-cursor.txt'),

    # How many GitHub repos to check per run -- each costs up to two extra
    # API calls (releases, then a Community search if it ships a Windows
    # installer), on top of the one search call per week slice. Kept
    # modest by default since this is exploratory, not urgent, discovery.
    [int]
    $BatchSize = 20,

    # "Gaining popularity" as a concrete, reproducible query rather than a
    # vague notion: created within this many months, with at least
    # $MinStars stars. Confirmed by testing that GitHub's own /search/
    # repositories endpoint answers this directly and reliably -- no
    # scraping the (unofficial, API-less) Trending page needed.
    [int]
    $CreatedWithinMonths = 12,

    [int]
    $MinStars = 300,

    [string]
    $CommunitySource = 'https://community.chocolatey.org/api/v2/',

    # Needed for a reasonable rate limit -- GitHub's search endpoint is
    # capped at 10 req/min unauthenticated vs. 30 authenticated, and every
    # other REST call here at 60/hr vs. 5,000/hr. Falls back to
    # GH_TOKEN/GITHUB_TOKEN from the environment (already how every GitHub
    # Actions workflow in this repo makes it available) if not passed.
    [string]
    $GitHubToken = $(if ($env:GH_TOKEN) { $env:GH_TOKEN } else { $env:GITHUB_TOKEN })
)

# Finds real open-source candidates for a brand-new internal AU package
# (or a Community contribution) that this repo has never had any
# visibility into before: software gaining popularity that has no
# Chocolatey package at all. The opposite discovery direction from
# prospecting/'s other two scripts, which both start from packages that
# already exist and ask whether they're stale -- this one starts from
# GitHub's real activity and asks whether Chocolatey has ever heard of it.
#
# A repo having stars and a recent creation date doesn't mean it ships
# anything installable on Windows at all -- confirmed by testing that a
# naive "does an asset name contain 'win'" check is actively misleading
# (a Node-native-module repo's win32-x64-msvc.node file matched that, but
# isn't a standalone installer at all; a real desktop app's actual
# Windows installers, by contrast, end in exactly '.exe'/'.msi'). Only a
# release asset ending in '.exe' or '.msi' counts as "ships a real
# Windows installer" here.
#
# The whole window is swept by WEEK, not by paging through one giant
# query -- confirmed by real testing that GitHub's Search API hard-caps
# every query at 1000 reachable results regardless of its own reported
# total_count. At the default 300-star/12-month query, total_count was
# 10,900 -- meaning page-based cursoring (the original design) could
# only ever reach the same top ~1,000 highest-starred repos in the whole
# window, forever, no matter how many runs went by. Slicing by month was
# tried first and rejected: real testing found several individual
# months' own total_count still exceeded 1000 (older months have had
# more time to accumulate stars past the threshold -- one sampled month
# hit 2,571). Slicing by week was then tested the same way across the
# full year (samples: 103, 159, 447, 308, 175, 171) and stayed
# comfortably under the cap everywhere sampled, so each week's own
# search is small enough that its own total_count never needs paging --
# one call per week reaches every matching repo created in it.
$ErrorActionPreference = 'Stop'

$headers = @{ 'User-Agent' = 'chocolatey-packages-mcp-server' }
if ($GitHubToken) { $headers['Authorization'] = "Bearer $GitHubToken" }

$reference = if (Test-Path $ReferencePath) { @(Import-Csv -Path $ReferencePath) } else { @() }
$referenceByRepo = @{}
foreach ($row in $reference) { $referenceByRepo[$row.Repo] = $row }

# ~4.345 weeks/month on average -- rounded up so the last slice never
# falls short of the full $CreatedWithinMonths window.
$totalWeeks = [Math]::Max(1, [Math]::Ceiling($CreatedWithinMonths * 4.345))

$weekIndex = if (Test-Path $CursorPath) { [int](Get-Content -Path $CursorPath -Raw).Trim() } else { 0 }
if ($weekIndex -ge $totalWeeks -or $weekIndex -lt 0) { $weekIndex = 0 }

$weekEnd = (Get-Date).AddDays(-7 * $weekIndex)
$weekStart = $weekEnd.AddDays(-7)
$query = "created:$($weekStart.ToString('yyyy-MM-dd'))..$($weekEnd.ToString('yyyy-MM-dd')) stars:>$MinStars"

Write-Verbose "Searching GitHub for repos matching: $query (week $weekIndex of $totalWeeks)"
$searchUri = "https://api.github.com/search/repositories?q=$([uri]::EscapeDataString($query))&sort=stars&order=desc&per_page=$BatchSize&page=1"
$searchResult = Invoke-RestMethod -Uri $searchUri -Headers $headers

if ($searchResult.total_count -gt 1000) {
    Write-Warning "Week $weekIndex ($($weekStart.ToString('yyyy-MM-dd'))..$($weekEnd.ToString('yyyy-MM-dd'))) reports total_count=$($searchResult.total_count), above the 1000-result cap -- this slice alone would need finer-than-weekly splitting to see everything. Proceeding with just the top $BatchSize by stars for now."
}

$today = Get-Date
foreach ($repo in $searchResult.items) {
    Write-Verbose "Checking '$($repo.full_name)' ($($repo.stargazers_count) stars)..."

    $windowsAssets = @()
    try {
        $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$($repo.full_name)/releases/latest" -Headers $headers
        $windowsAssets = @($release.assets | Where-Object { $_.name -match '\.(exe|msi)$' } | ForEach-Object { $_.name })
    } catch {
        # No releases at all (common for libraries/services) -- not an
        # error, just means there's nothing installable to check further.
    }

    $hasChocolateyPackage = $false
    $chocolateyMatch = $null
    if ($windowsAssets.Count -gt 0) {
        # The repo's own short name is usually a reasonable guess at a
        # Chocolatey id -- same "only trust an exact match" principle
        # already used for evergreen/winget matching elsewhere in this
        # repo, since a substring search here would be just as misleading
        # as it was found to be for those.
        $shortName = ($repo.full_name -split '/')[-1]
        $searchOut = choco search $shortName --source=$CommunitySource --exact --limit-output 2>$null
        if ($LASTEXITCODE -eq 0 -and $searchOut) {
            $hasChocolateyPackage = $true
            $chocolateyMatch = ($searchOut -split '\|')[0]
        }
    }

    $referenceByRepo[$repo.full_name] = [pscustomobject]@{
        Repo                  = $repo.full_name
        Stars                 = $repo.stargazers_count
        CreatedAt             = ($repo.created_at -as [datetime]).ToString('yyyy-MM-dd')
        Language              = $repo.language
        WindowsInstallerAssets = ($windowsAssets -join '; ')
        HasChocolateyPackage  = $hasChocolateyPackage
        ChocolateyMatch       = $chocolateyMatch
        Url                   = $repo.html_url
        LastChecked           = $today.ToString('yyyy-MM-dd')
    }
}

$nextWeekIndex = ($weekIndex + 1) % $totalWeeks
Set-Content -Path $CursorPath -Value $nextWeekIndex -Encoding UTF8

New-Item -Path (Split-Path $ReferencePath -Parent) -ItemType Directory -Force | Out-Null
$referenceByRepo.Values | Sort-Object Stars -Descending | Export-Csv -Path $ReferencePath -NoTypeInformation -Encoding UTF8

$flagged = $referenceByRepo.Values | Where-Object { $_.WindowsInstallerAssets -and -not $_.HasChocolateyPackage }

Write-Host "`nChecked $($searchResult.items.Count) repo(s) this run from week $weekIndex ($($weekStart.ToString('yyyy-MM-dd'))..$($weekEnd.ToString('yyyy-MM-dd'))) of $totalWeeks (cursor now at week $nextWeekIndex)."
Write-Host "$($flagged.Count) real opportunit(y/ies) across the full reference: ships a real Windows installer, no existing Chocolatey package found."
$flagged | Sort-Object Stars -Descending | Select-Object -First 10 | Format-Table Repo, Stars, CreatedAt, WindowsInstallerAssets -AutoSize
