[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ManifestDir,

    [string]$OutputPath = '.\update-check-results.json',

    [string]$CommunitySource = 'https://community.chocolatey.org/api/v2/'
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\SimpleYaml.ps1')

# Scans internalized/**/internalize.yml for manifests with autoUpdateCheck:
# true, compares pinnedVersion against what's currently latest in the
# Chocolatey Community Repository, and writes the outdated ones to
# $OutputPath as JSON for open-version-bump-prs.ps1 to consume.
# See docs/architecture.md section 9.2.

function Get-NormalizedVersion {
    param([string]$VersionString)
    # Chocolatey/NuGet versions aren't always strict 4-part System.Version;
    # pad short ones so comparisons behave (e.g. "23.1" -> "23.1.0.0").
    $core = ($VersionString -split '-', 2)[0]
    $parts = $core -split '\.'
    while ($parts.Count -lt 4) { $parts += '0' }
    $parts = $parts[0..3]
    try {
        return [version]($parts -join '.')
    } catch {
        return $null
    }
}

function Get-LatestCommunityVersion {
    param([string]$PackageId, [string]$Source)

    $uri = "$($Source.TrimEnd('/'))/FindPackagesById()?id='$PackageId'&`$orderby=Version%20desc&`$top=1"
    # Invoke-RestMethod already parses an application/atom+xml response into
    # an XML object — casting it again with [xml] fails, since what comes
    # back isn't always an XmlDocument (sometimes just the root element).
    $response = Invoke-RestMethod -Uri $uri -Method Get

    # With $top=1 the OData endpoint returns a single Atom <entry> as the
    # document root; with more than one match it wraps them in <feed>. Handle
    # both shapes rather than assuming one.
    if ($response.properties) {
        $entry = $response
    } else {
        $entry = $response.feed.entry
    }
    if (-not $entry) {
        throw "No package '$PackageId' found in Community Repository at $Source."
    }
    if ($entry -is [array]) { $entry = $entry[0] }

    $versionNode = $entry.properties.Version
    if (-not $versionNode) {
        throw "Community Repository response for '$PackageId' had no Version property."
    }
    return [string]$versionNode
}

if (-not (Test-Path $ManifestDir)) {
    throw "ManifestDir '$ManifestDir' does not exist."
}

$results = [System.Collections.Generic.List[object]]::new()
$errors = [System.Collections.Generic.List[string]]::new()

$packageFolders = Get-ChildItem -Path $ManifestDir -Directory | Where-Object { $_.Name -notlike '_*' }

foreach ($folder in $packageFolders) {
    $manifestPath = Join-Path $folder.FullName 'internalize.yml'
    if (-not (Test-Path $manifestPath)) { continue }

    $manifest = Get-Content $manifestPath | ConvertFrom-SimpleYaml

    if ($manifest.autoUpdateCheck -ne $true) {
        Write-Host "Skipping $($folder.Name): autoUpdateCheck not enabled."
        continue
    }
    if ([string]::IsNullOrWhiteSpace($manifest.packageId)) {
        $errors.Add("$($folder.Name)/internalize.yml has no packageId.")
        continue
    }
    if ($manifest.pinnedVersion -eq 'latest') {
        Write-Host "Skipping $($manifest.packageId): pinnedVersion is 'latest' (always re-checked at internalize time, nothing to bump)."
        continue
    }

    try {
        $source = if ($manifest.source) { $manifest.source } else { $CommunitySource }
        $latest = Get-LatestCommunityVersion -PackageId $manifest.packageId -Source $source
    } catch {
        $errors.Add("$($manifest.packageId): failed to query upstream version — $($_.Exception.Message)")
        continue
    }

    $pinnedNorm = Get-NormalizedVersion $manifest.pinnedVersion
    $latestNorm = Get-NormalizedVersion $latest

    if (-not $pinnedNorm -or -not $latestNorm) {
        $errors.Add("$($manifest.packageId): could not compare versions (pinned='$($manifest.pinnedVersion)', latest='$latest') — needs manual review.")
        continue
    }

    if ($latestNorm -gt $pinnedNorm) {
        Write-Host "$($manifest.packageId): $($manifest.pinnedVersion) -> $latest"
        $results.Add([pscustomobject]@{
            folder        = $folder.Name
            packageId     = $manifest.packageId
            owner         = $manifest.owner
            pinnedVersion = $manifest.pinnedVersion
            latestVersion = $latest
        })
    } else {
        Write-Host "$($manifest.packageId): up to date ($($manifest.pinnedVersion))."
    }
}

$results | ConvertTo-Json -AsArray -Depth 5 | Set-Content -Path $OutputPath -Encoding utf8
Write-Host "Wrote $($results.Count) outdated package(s) to $OutputPath."

if ($errors.Count -gt 0) {
    Write-Warning "Encountered $($errors.Count) error(s) while checking upstream versions:"
    foreach ($e in $errors) { Write-Warning "  - $e" }
    # Deliberately non-fatal (exit 0): a package that couldn't be checked
    # (bad manifest, upstream lookup failure) shouldn't block PRs for every
    # other package that checked out fine. The warnings above still surface
    # in the workflow run log for someone to follow up on.
}
exit 0
