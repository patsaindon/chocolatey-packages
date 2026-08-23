[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]
    $NexusBaseUrl,

    [Parameter(Mandatory)]
    [string]
    $Repository,

    # Every asset this package cares about lives under this path inside the
    # generic/raw-format repository, e.g. "acme/licensed-app/" -- a human
    # uploads a new file here (same path, new filename) each time they log
    # in to the vendor's paywalled portal and fetch a new release. Nothing
    # in this repo's automation ever holds those vendor credentials; this
    # script only ever reads what a human already deposited.
    [Parameter(Mandatory)]
    [string]
    $PathPrefix,

    # Falls back to NEXUS_GENERIC_READ_TOKEN from the environment, the same
    # pattern as GH_TOKEN/GITHUB_TOKEN elsewhere in this repo -- a
    # read-only credential scoped to this one generic repo, never the
    # write access the human's own manual upload uses.
    [string]
    $ApiToken = $env:NEXUS_GENERIC_READ_TOKEN
)

# The AU update source for a package whose real binary is paywalled --
# behind a vendor login this automation must never hold credentials for
# (same reasoning as every other credential-scoping decision in this
# repo: a tool only ever gets the narrowest credential it needs). A human
# logs in, downloads the new release themselves, and uploads it to this
# fixed path in Nexus's own generic (raw-format) hosted repository; this
# script is what a scaffolded package's au_GetLatest calls instead of
# scraping a vendor page it can no longer reach, treating "a new file
# appeared at this path" as the version signal instead of "the vendor's
# page says a new version exists."
#
# NOT YET VERIFIED AGAINST A REAL NEXUS INSTANCE -- unlike every other
# script in this repo, there was no real Nexus (or Nexus-compatible
# generic/raw endpoint) available to test this against end-to-end. The
# response-parsing logic (Select-LatestNexusAsset) is unit-tested against
# a synthetic fixture built from Sonatype's own documented Search Assets
# API schema; the HTTP call itself (auth header shape, the real
# reachability of /service/rest/v1/search/assets, and Nexus's actual
# per-format search behavior for raw repos) is not. Treat this as a
# reviewed design, not a proven one, until it's run against a real
# instance -- see docs/architecture.md.

$ErrorActionPreference = 'Stop'

function Get-VersionFromFileName {
    param([string]$FileName)
    # 2-4 dot-separated numeric segments -- matches typical release
    # filenames ('myapp-1.2.3-x64.exe', 'myapp_2024.1.msi') while
    # naturally skipping a bare architecture marker like '64' or '32',
    # since those never have a second segment for the regex to require.
    $match = [regex]::Match($FileName, '\d+(?:\.\d+){1,3}')
    if ($match.Success) { return $match.Value }
    return $null
}

function Compare-VersionStrings {
    param([string]$A, [string]$B)
    # Not [version] -- found elsewhere in this repo (evergreen version
    # handling) that a real version can carry more segments than
    # [version]/NuGet's 4-segment limit tolerates. Compares segment by
    # segment as integers instead, padding the shorter one with zeros,
    # so it works regardless of how many segments either side has.
    $partsA = $A -split '\.' | ForEach-Object { [int]$_ }
    $partsB = $B -split '\.' | ForEach-Object { [int]$_ }
    $len = [Math]::Max($partsA.Count, $partsB.Count)
    for ($i = 0; $i -lt $len; $i++) {
        $x = if ($i -lt $partsA.Count) { $partsA[$i] } else { 0 }
        $y = if ($i -lt $partsB.Count) { $partsB[$i] } else { 0 }
        if ($x -ne $y) { return $x - $y }
    }
    return 0
}

# Separated from the HTTP call so it can be unit-tested against a
# synthetic fixture without needing a real Nexus to talk to.
function Select-LatestNexusAsset {
    param(
        [Parameter(Mandatory)] [array]$Items,
        [Parameter(Mandatory)] [string]$PathPrefix
    )
    $candidates = foreach ($item in $Items) {
        if ($item.path -notlike "$PathPrefix*") { continue }
        $fileName = Split-Path -Leaf $item.path
        $version = Get-VersionFromFileName -FileName $fileName
        if (-not $version) { continue }
        [pscustomobject]@{
            Version     = $version
            DownloadUrl = $item.downloadUrl
            Sha256      = $item.checksum.sha256
            AssetPath   = $item.path
        }
    }
    if (-not $candidates) { return $null }

    $latest = $candidates[0]
    foreach ($candidate in $candidates) {
        if ((Compare-VersionStrings -A $candidate.Version -B $latest.Version) -gt 0) {
            $latest = $candidate
        }
    }
    return $latest
}

function Get-NexusSearchAssetsHeaders {
    param([string]$Token)
    $headers = @{}
    if ($Token) { $headers['Authorization'] = "Bearer $Token" }
    return $headers
}

$headers = Get-NexusSearchAssetsHeaders -Token $ApiToken
$allItems = New-Object System.Collections.Generic.List[object]
$continuationToken = $null

do {
    $uri = "$($NexusBaseUrl.TrimEnd('/'))/service/rest/v1/search/assets?repository=$([uri]::EscapeDataString($Repository))&q=$([uri]::EscapeDataString($PathPrefix))"
    if ($continuationToken) { $uri += "&continuationToken=$([uri]::EscapeDataString($continuationToken))" }
    $response = Invoke-RestMethod -Uri $uri -Headers $headers
    foreach ($item in $response.items) { $allItems.Add($item) }
    $continuationToken = $response.continuationToken
} while ($continuationToken)

$result = Select-LatestNexusAsset -Items $allItems -PathPrefix $PathPrefix
if (-not $result) {
    throw "No asset found under '$PathPrefix' in repository '$Repository' -- has it been uploaded yet?"
}

$result
