[CmdletBinding()]
param(
    [string]
    $ReferencePath = (Join-Path $PSScriptRoot '..\prospecting\community-staleness-reference.csv'),

    [string]
    $CursorPath = (Join-Path $PSScriptRoot '..\prospecting\community-staleness-cursor.txt'),

    # Approximate minimum packages checked per run -- an already-started
    # page is always finished, so the real count is $BatchSize rounded
    # up to a multiple of the page size (30). This sweeps the whole
    # Community Repository (~11,654 unique packages, confirmed via
    # community.chocolatey.org/stats' UniquePackages field -- a much
    # larger, slower-moving universe than
    # Update-CommunityVersionReference.ps1's evergreen-bounded ~565
    # apps, with no curated index to draw from) -- so this defaults to a
    # bigger batch than that script's.
    [int]
    $BatchSize = 100,

    # How old a package's "Published" date has to be before it's
    # flagged. This is a much weaker signal than
    # Update-CommunityVersionReference.ps1's VersionMismatch: an old
    # Published date alone doesn't confirm the package is actually
    # behind a real current vendor version -- some software genuinely
    # hasn't changed in years. Treat a flag here as "worth a look", not
    # "confirmed stale".
    [int]
    $StaleDays = 365
)

$ErrorActionPreference = 'Stop'

$CommunitySource = 'https://community.chocolatey.org/api/v2/'
# choco's own documented recommendation -- other page sizes are noted
# to have "known issues with some repositories".
$PageSize = 30

# `choco search --page` is 0-indexed and stable under the default (Id)
# ordering -- confirmed by testing: page 0/1/2 hand off cleanly with no
# overlap or gap (e.g. page 0 ends '...0install', page 1 starts
# '0install.install...'). That stability is what makes a simple
# advancing page cursor a reliable way to sweep the whole catalog over
# many small runs, without needing to track every individual package id
# already seen the way Update-CommunityVersionReference.ps1 does for
# evergreen's much smaller, static app list.
$nextPage = if (Test-Path $CursorPath) { [int](Get-Content -Path $CursorPath -Raw).Trim() } else { 0 }

$reference = if (Test-Path $ReferencePath) { @(Import-Csv -Path $ReferencePath) } else { @() }
$referenceById = @{}
foreach ($row in $reference) { $referenceById[$row.PackageId] = $row }

$checked = 0
$page = $nextPage
$wrappedOnce = $false
$today = Get-Date

while ($checked -lt $BatchSize) {
    $result = choco search --source=$CommunitySource --page=$page --page-size=$PageSize --order-by='Id' --limit-output 2>$null
    $ids = @($result -split "`r?`n" | Where-Object { $_.Trim() } | ForEach-Object { ($_ -split '\|')[0] })

    if ($ids.Count -eq 0) {
        if ($wrappedOnce) {
            Write-Warning "Reached the end of the catalog twice in one run -- stopping early rather than looping forever (the catalog may be smaller than expected, or something's wrong upstream)."
            break
        }
        Write-Host "Reached the end of the catalog at page $page -- wrapping back to page 0 to keep refreshing the whole thing over time."
        $page = 0
        $wrappedOnce = $true
        continue
    }

    # Always finish a page once started, even past $BatchSize -- found by
    # testing: breaking out mid-page and still advancing $page to the
    # next one silently and permanently skips whatever was left unread
    # on this page, since the cursor never returns to it. $BatchSize is
    # therefore an approximate floor (rounded up to a full page), not an
    # exact cap.
    foreach ($id in $ids) {
        $version = $null
        $published = $null
        $infoText = choco info $id --source=$CommunitySource 2>$null
        if ($LASTEXITCODE -eq 0 -and $infoText) {
            $headerLine = $infoText | Select-Object -Skip 1 -First 1
            if ($headerLine -match '^\S+\s+(\S+)\s+\[') { $version = $Matches[1] }
            $publishedLine = $infoText | Where-Object { $_ -match 'Published:\s*(\d{4}-\d{2}-\d{2})' } | Select-Object -First 1
            if ($publishedLine -and $publishedLine -match 'Published:\s*(\d{4}-\d{2}-\d{2})') { $published = $Matches[1] }
        }

        $staleDaysActual = if ($published) { [int]((New-TimeSpan -Start ([datetime]$published) -End $today).Days) } else { $null }

        $referenceById[$id] = [pscustomobject]@{
            PackageId   = $id
            Version     = $version
            Published   = $published
            StaleDays   = $staleDaysActual
            LastChecked = $today.ToString('yyyy-MM-dd')
        }
        $checked++
    }

    $page++
}

Set-Content -Path $CursorPath -Value $page -Encoding UTF8

New-Item -Path (Split-Path $ReferencePath -Parent) -ItemType Directory -Force | Out-Null
$referenceById.Values | Sort-Object PackageId | Export-Csv -Path $ReferencePath -NoTypeInformation -Encoding UTF8

$flagged = $referenceById.Values | Where-Object { $_.StaleDays -ne $null -and [int]$_.StaleDays -gt $StaleDays }

Write-Host "`nChecked $checked package(s) this run (page cursor now at $page)."
Write-Host "$($flagged.Count) package(s) in the full reference are currently Published more than $StaleDays day(s) ago."
Write-Host "This alone doesn't confirm a real vendor-version mismatch (see prospecting/README.md) -- cross-reference against prospecting/community-version-reference.csv where the same id/vendor is evergreen-tracked, otherwise treat as a lead worth a manual look, not a confirmed candidate."
