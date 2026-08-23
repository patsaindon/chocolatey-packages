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

    # 'username:password' (or a Nexus User Token's 'tokenName:tokenPass'
    # pair, Nexus's own recommended alternative to a real login password --
    # Server Administration > Security > User Tokens) -- Nexus's REST API
    # authenticates via HTTP Basic auth, confirmed against a real instance
    # (see the header note below); this string is base64-encoded into that
    # header, never sent as a bearer token. Falls back to
    # NEXUS_GENERIC_READ_TOKEN from the environment, the same pattern as
    # GH_TOKEN/GITHUB_TOKEN elsewhere in this repo -- a read-only
    # credential scoped to this one generic repo, never the write access
    # the human's own manual upload uses.
    [string]
    $Credentials = $env:NEXUS_GENERIC_READ_TOKEN
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
# VERIFIED AGAINST A REAL NEXUS INSTANCE (Sonatype's own sonatype/nexus3
# Docker image) -- this caught two real bugs the synthetic-fixture-only
# testing had missed entirely:
#   1. Real auth is HTTP Basic, not Bearer. The original version sent
#      'Authorization: Bearer <token>' -- Nexus didn't reject it, it just
#      silently ignored it and returned an authenticated-as-anonymous,
#      EMPTY result set (HTTP 200, zero items), which this script would
#      then report as "no asset found" -- indistinguishable from a
#      genuinely empty repository. A wrong header that fails loudly is a
#      minor annoyance; one that fails silently and looks like "nothing's
#      there yet" is far worse, and would have made this whole mechanism
#      quietly non-functional in real use.
#   2. A real asset's own 'path' field comes back with a *leading slash*
#      ('/acme/test-app/file.exe'), which the synthetic fixture (built by
#      hand from Sonatype's documented schema, not from a real response)
#      hadn't included -- so the path-prefix filter below would have
#      matched nothing real, ever, despite working perfectly against the
#      fixture. Both fixed below; see Select-LatestNexusAsset's own
#      normalization and Get-NexusSearchAssetsHeaders' Basic-auth header.

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
    # A real asset's path comes back leading-slashed ('/acme/app/x.exe');
    # PathPrefix is documented and passed without one ('acme/app/') --
    # normalize both the same way before comparing so this doesn't depend
    # on the caller happening to match Nexus's own convention.
    $normalizedPrefix = $PathPrefix.TrimStart('/')
    $candidates = foreach ($item in $Items) {
        $normalizedPath = $item.path.TrimStart('/')
        if ($normalizedPath -notlike "$normalizedPrefix*") { continue }
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
    param([string]$Credentials)
    $headers = @{}
    if ($Credentials) {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Credentials)
        $headers['Authorization'] = "Basic $([Convert]::ToBase64String($bytes))"
    }
    return $headers
}

$headers = Get-NexusSearchAssetsHeaders -Credentials $Credentials
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
