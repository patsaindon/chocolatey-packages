[CmdletBinding()]
param(
    [string]
    $ReferencePath = (Join-Path $PSScriptRoot '..\prospecting\community-version-reference.csv'),

    # Evergreen's /apps index runs to several hundred entries -- checking
    # all of them every run would hammer both evergreen-api and the
    # Community Repository for no reason. Each run instead advances
    # through the index incrementally: whichever apps have gone longest
    # without a check (never-checked apps first) are this run's batch.
    # Re-running repeatedly eventually cycles through the whole index.
    [int]
    $BatchSize = 30,

    # How old a Community package's "Published" date has to be before
    # it's flagged as stale and worth a second look.
    [int]
    $StaleDays = 180
)

$ErrorActionPreference = 'Stop'

$CommunitySource = 'https://community.chocolatey.org/api/v2/'
$UserAgent = 'chocolatey-packages-mcp-server'

# Same build-metadata stripping already proven in production for AU's own
# au_GetLatest (see internal/*/update.ps1, mcp-server/tools/scaffold-
# internal-package.js) -- evergreen versions can carry a trailing '-LTS'
# and '+build' segment that a Community package's own version generally
# won't, so comparing the raw strings would flag a mismatch on every
# single evergreen-tracked app rather than only the ones that actually
# differ.
function ConvertTo-ComparableVersion {
    param([string]$Version)
    if (-not $Version) { return $Version }
    ($Version -replace '-LTS', '' -split '\+')[0]
}

Write-Verbose "Fetching evergreen-api's /apps index..."
$allApps = Invoke-RestMethod -Uri 'https://evergreen-api.stealthpuppy.com/apps' -UserAgent $UserAgent

$reference = if (Test-Path $ReferencePath) {
    @(Import-Csv -Path $ReferencePath)
} else {
    @()
}
$referenceByName = @{}
foreach ($row in $reference) { $referenceByName[$row.EvergreenName] = $row }

# Never-checked apps first (oldest possible LastChecked), then whichever
# checked apps have gone longest since their last check.
$ordered = $allApps | Sort-Object -Property @{
    Expression = { if ($referenceByName.ContainsKey($_.Name)) { [datetime]$referenceByName[$_.Name].LastChecked } else { [datetime]::MinValue } }
}
$batch = $ordered | Select-Object -First $BatchSize

Write-Host "Checking $($batch.Count) of $($allApps.Count) evergreen apps this run (batch size $BatchSize)."

$today = Get-Date
foreach ($app in $batch) {
    Write-Verbose "Checking '$($app.Name)' ('$($app.Application)')..."

    $evergreenVersion = $null
    try {
        $variants = Invoke-RestMethod -Uri "https://evergreen-api.stealthpuppy.com/app/$($app.Name)" -UserAgent $UserAgent
        $x64 = $variants | Where-Object { $_.Architecture -eq 'x64' } | Select-Object -First 1
        $evergreenVersion = if ($x64) { $x64.Version } else { ($variants | Select-Object -First 1).Version }
    } catch {
        Write-Warning "'$($app.Name)': couldn't fetch evergreen variant data ($($_.Exception.Message))."
    }

    # Matching an evergreen app to a Community package id is inherently a
    # guess -- evergreen's own Name (e.g. 'AdoptiumTemurin25') is a
    # vendor+product+version slug that rarely matches Chocolatey's own id
    # conventions. Tried in order, first exact match wins; found by
    # testing that a non-exact `choco search` on a real app name (e.g.
    # 'Firefox') returns dozens of loosely related packages
    # (adblockplusfirefox, allbrowsers, ...) before the real 'firefox'
    # package -- so only an --exact hit is trusted, never the first
    # substring result.
    $candidateTerms = @($app.Name, $app.Application, ($app.Application -replace '\s', ''))
    if ($app.Application) {
        $words = $app.Application -split '\s+' | Where-Object { $_.Length -gt 2 } | Sort-Object Length -Descending
        $candidateTerms += $words
    }

    $communityId = $null
    $communityVersion = $null
    $published = $null
    foreach ($term in ($candidateTerms | Select-Object -Unique)) {
        if (-not $term) { continue }
        $result = choco search $term --source=$CommunitySource --exact --limit-output 2>$null
        if ($LASTEXITCODE -eq 0 -and $result) {
            $lines = @($result -split "`n" | Where-Object { $_.Trim() })
            if ($lines.Count -eq 1) {
                $communityId, $communityVersion = $lines[0] -split '\|'
                break
            }
        }
    }

    $versionMismatch = $false
    if ($communityId) {
        $infoText = choco info $communityId --source=$CommunitySource 2>$null
        if ($LASTEXITCODE -eq 0) {
            $publishedLine = $infoText | Where-Object { $_ -match 'Published:\s*(\d{4}-\d{2}-\d{2})' } | Select-Object -First 1
            if ($publishedLine -and $publishedLine -match 'Published:\s*(\d{4}-\d{2}-\d{2})') {
                $published = $Matches[1]
            }
        }
        if ($evergreenVersion -and (ConvertTo-ComparableVersion $communityVersion) -ne (ConvertTo-ComparableVersion $evergreenVersion)) {
            $versionMismatch = $true
        }
    }

    $staleDaysActual = if ($published) { [int]((New-TimeSpan -Start ([datetime]$published) -End $today).Days) } else { $null }

    $referenceByName[$app.Name] = [pscustomobject]@{
        EvergreenName    = $app.Name
        Application      = $app.Application
        CommunityPackageId = $communityId
        CommunityVersion = $communityVersion
        EvergreenVersion = $evergreenVersion
        Published        = $published
        VersionMismatch  = $versionMismatch
        StaleDays        = $staleDaysActual
        LastChecked      = $today.ToString('yyyy-MM-dd')
    }
}

New-Item -Path (Split-Path $ReferencePath -Parent) -ItemType Directory -Force | Out-Null
$referenceByName.Values | Sort-Object EvergreenName | Export-Csv -Path $ReferencePath -NoTypeInformation -Encoding UTF8

$flagged = $referenceByName.Values | Where-Object {
    $_.VersionMismatch -eq $true -or ($_.StaleDays -ne $null -and [int]$_.StaleDays -gt $StaleDays)
}

Write-Host "`n$($flagged.Count) candidate(s) worth a look (version mismatch, or Published more than $StaleDays day(s) ago):"
$flagged | Sort-Object EvergreenName | Format-Table EvergreenName, Application, CommunityPackageId, CommunityVersion, EvergreenVersion, StaleDays, VersionMismatch -AutoSize

$noMatch = ($batch | ForEach-Object { $_.Name }) | Where-Object { -not $referenceByName[$_].CommunityPackageId }
if ($noMatch) {
    Write-Host "`n$($noMatch.Count) app(s) checked this run had no confident Community package match (not necessarily a problem -- just nothing to compare against):"
    $noMatch | ForEach-Object { Write-Host "  - $_" }
}
