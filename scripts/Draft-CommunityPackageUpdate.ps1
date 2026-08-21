[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]
    $CommunityPackageId,

    [string]
    $ReferencePath = (Join-Path $PSScriptRoot '..\prospecting\community-version-reference.csv'),

    [string]
    $OutputDir
)

# Drafts everything a human needs to submit a version-bump update to a
# stale Community package's own maintainer -- fetches the maintainer's
# real current files and the real target version/URL/checksum (from
# evergreen-api), and writes UPDATE-NOTES.md summarizing what to change
# and where to submit it. Deliberately never auto-edits the maintainer's
# chocolateyInstall.ps1 or opens a PR: unlike this repo's own templates,
# an arbitrary Community package's script structure is unknown, and a
# wrong auto-edit wastes the maintainer's review time worse than no PR
# at all. Every external contribution from this tooling is reviewed and
# submitted by a human -- see docs/architecture.md section 6.9.

$ErrorActionPreference = 'Stop'
$CommunitySource = 'https://community.chocolatey.org/api/v2/'
$UserAgent = 'chocolatey-packages-mcp-server'
$ghHeaders = @{ 'User-Agent' = $UserAgent }

if (-not $OutputDir) {
    $OutputDir = Join-Path $PSScriptRoot "..\prospecting\drafts\$CommunityPackageId"
}

if (-not (Test-Path $ReferencePath)) {
    throw "No reference file at '$ReferencePath' -- run Update-CommunityVersionReference.ps1 first."
}
$row = Import-Csv $ReferencePath | Where-Object { $_.CommunityPackageId -eq $CommunityPackageId } | Select-Object -First 1
if (-not $row) {
    throw "'$CommunityPackageId' isn't in the reference file. Run Update-CommunityVersionReference.ps1 first (it may not have checked this app yet), or pass the id exactly as it appears in that CSV."
}

# The 'Chocolatey Package Source' line isn't cached in the reference CSV
# (Update-CommunityVersionReference.ps1's own job is the version/date
# diff, not this) -- fetched fresh here, only needed at draft time.
Write-Verbose "Looking up '$CommunityPackageId's Chocolatey Package Source..."
$infoText = choco info $CommunityPackageId --source=$CommunitySource
if ($LASTEXITCODE -ne 0) { throw "choco info failed for '$CommunityPackageId'." }
$sourceLine = $infoText | Where-Object { $_ -match 'Chocolatey Package Source:\s*(\S+)' } | Select-Object -First 1
if (-not $sourceLine -or $sourceLine -notmatch 'Chocolatey Package Source:\s*(\S+)') {
    throw "'$CommunityPackageId' has no 'Chocolatey Package Source' listed -- can't find where to draft an update automatically. This needs manual research on community.chocolatey.org/packages/$CommunityPackageId."
}
$sourceUrl = $Matches[1]

if ($sourceUrl -notmatch '^https://github\.com/(?<owner>[^/]+)/(?<repo>[^/]+)/tree/(?<branch>[^/]+)/(?<path>.+)$') {
    throw "'$CommunityPackageId''s source ('$sourceUrl') isn't a recognized GitHub tree URL -- can't draft an update automatically for this host."
}
$owner = $Matches.owner
$repo = $Matches.repo
$branch = $Matches.branch
$path = $Matches.path
Write-Host "Source: github.com/$owner/$repo, branch '$branch', path '$path'"

# Real target version/URL/checksum, from the same source
# Update-CommunityVersionReference.ps1 already trusted for this app.
$evergreenUrl = $null
$evergreenChecksum = $null
if ($row.EvergreenName) {
    try {
        $variants = Invoke-RestMethod -Uri "https://evergreen-api.stealthpuppy.com/app/$($row.EvergreenName)" -UserAgent $UserAgent
        $preferred = ($variants | Where-Object { $_.Architecture -eq 'x64' } | Select-Object -First 1)
        if (-not $preferred) { $preferred = $variants | Select-Object -First 1 }
        if ($preferred) {
            $evergreenUrl = $preferred.URI
            $evergreenChecksum = if ($preferred.Sha256) { $preferred.Sha256 } else { $preferred.Checksum }
        }
    } catch {
        Write-Warning "Couldn't re-fetch evergreen variant data for '$($row.EvergreenName)': $($_.Exception.Message)"
    }
}

# Don't guess the nuspec's exact filename (it isn't always <id>.nuspec) --
# list what's actually there.
$listing = Invoke-RestMethod -Uri "https://api.github.com/repos/$owner/$repo/contents/$path`?ref=$branch" -Headers $ghHeaders
$nuspecEntry = $listing | Where-Object { $_.type -eq 'file' -and $_.name -like '*.nuspec' } | Select-Object -First 1
if (-not $nuspecEntry) { throw "No .nuspec found under '$path' in $owner/$repo@$branch." }

$toolsListing = $null
try {
    $toolsListing = Invoke-RestMethod -Uri "https://api.github.com/repos/$owner/$repo/contents/$path/tools`?ref=$branch" -Headers $ghHeaders
} catch {
    Write-Warning "No tools/ folder found under '$path' (or couldn't list it) -- only the nuspec will be drafted."
}

New-Item -Path $OutputDir -ItemType Directory -Force | Out-Null
$originalDir = Join-Path $OutputDir 'original'
New-Item -Path $originalDir -ItemType Directory -Force | Out-Null

Invoke-WebRequest -Uri $nuspecEntry.download_url -Headers $ghHeaders -OutFile (Join-Path $originalDir $nuspecEntry.name) | Out-Null

$installEntry = $toolsListing | Where-Object { $_.name -eq 'chocolateyInstall.ps1' } | Select-Object -First 1
if ($installEntry) {
    New-Item -Path (Join-Path $originalDir 'tools') -ItemType Directory -Force | Out-Null
    Invoke-WebRequest -Uri $installEntry.download_url -Headers $ghHeaders -OutFile (Join-Path $originalDir 'tools\chocolateyInstall.ps1') | Out-Null
}

$summaryLines = @(
    "Current Community version: $($row.CommunityVersion)"
    "Real current version (evergreen-api): $($row.EvergreenVersion)"
    "Published (Community): $($row.Published) ($($row.StaleDays) day(s) ago)"
)
if ($evergreenUrl) { $summaryLines += "Real current download URL: $evergreenUrl" }
if ($evergreenChecksum) { $summaryLines += "Real current checksum: $evergreenChecksum" }

$notes = @"
# Draft update for $CommunityPackageId

$($summaryLines -join "`n")

Source: https://github.com/$owner/$repo/tree/$branch/$path

## To submit this update

1. Fork $owner/$repo on GitHub, if you haven't already.
2. Branch from $branch. Edit the files under $path (see original/ in
   this folder for what's there now) to bump the version -- and the
   download URL / checksum above, if this package embeds them directly
   rather than resolving them at install time.
3. Test locally (``choco pack`` then ``choco install <id> --source .``)
   before opening a PR -- this only drafts, it never verifies the
   result actually installs.
4. Open a PR against $owner/$repo, describing what changed and why.

This was never auto-edited or opened as a PR automatically -- every
external contribution from this tooling is reviewed and submitted by a
human. See docs/architecture.md section 6.9.
"@
Set-Content -Path (Join-Path $OutputDir 'UPDATE-NOTES.md') -Value $notes -Encoding UTF8

Write-Host "`nDrafted to: $OutputDir"
Write-Host "Original files under 'original\'; see UPDATE-NOTES.md for what to change and where to submit it."
