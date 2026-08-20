[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PackageId,
    [Parameter(Mandatory)][string]$Version,

    # Nexus server root, e.g. https://nexus.corp.local (no trailing slash, no /repository/... suffix).
    [Parameter(Mandatory)][string]$NexusBaseUrl,

    [Parameter(Mandatory)][string]$SourceRepo,
    [Parameter(Mandatory)][string]$TargetRepo
)

$ErrorActionPreference = 'Stop'

# Promotes the exact .nupkg already sitting in $SourceRepo (by content hash) to
# $TargetRepo, against Nexus Repository OSS — see docs/architecture.md section
# 9.4. Never rebuilds: what gets promoted is bit-for-bit identical to what was
# scanned in staging.
#
# Auth:
#   NEXUS_READ_USER / NEXUS_READ_PASSWORD — read-only creds, used to search and
#     download the artifact from the staging repo.
#   PRODUCTION_API_KEY — NuGet API key scoped to the production repo only,
#     used solely for the push step. Must never be available to the
#     internalize/build workflows (docs/architecture.md section 6.6 / 12).

$NexusBaseUrl = $NexusBaseUrl.TrimEnd('/')

foreach ($var in 'NEXUS_READ_USER', 'NEXUS_READ_PASSWORD', 'PRODUCTION_API_KEY') {
    if (-not (Get-Item "env:$var" -ErrorAction SilentlyContinue)) {
        throw "Required environment variable '$var' is not set."
    }
}

$readCred = New-Object System.Management.Automation.PSCredential(
    $env:NEXUS_READ_USER,
    (ConvertTo-SecureString $env:NEXUS_READ_PASSWORD -AsPlainText -Force)
)

Write-Host "Looking up $PackageId@$Version in repo '$SourceRepo'..."

# Nexus REST API v1 search — https://help.sonatype.com/repomanager3/rest-and-integration-api/search-api
$searchUri = "$NexusBaseUrl/service/rest/v1/search/assets?repository=$SourceRepo&name=$PackageId&version=$Version"
$searchResult = Invoke-RestMethod -Uri $searchUri -Credential $readCred -Method Get

$assets = @($searchResult.items)
if ($assets.Count -eq 0) {
    throw "No asset found for $PackageId@$Version in repo '$SourceRepo'."
}
if ($assets.Count -gt 1) {
    throw "Expected exactly one asset for $PackageId@$Version in '$SourceRepo', found $($assets.Count). Refusing to guess which one to promote."
}

$asset = $assets[0]
$expectedSha256 = $asset.checksum.sha256
if (-not $expectedSha256) {
    throw "Nexus did not report a sha256 checksum for the asset at $($asset.downloadUrl); cannot verify integrity before promoting."
}

$tempFile = Join-Path ([System.IO.Path]::GetTempPath()) "$PackageId.$Version.nupkg"
Write-Host "Downloading $($asset.downloadUrl)..."
Invoke-WebRequest -Uri $asset.downloadUrl -Credential $readCred -OutFile $tempFile

$actualSha256 = (Get-FileHash -Path $tempFile -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actualSha256 -ne $expectedSha256.ToLowerInvariant()) {
    Remove-Item $tempFile -ErrorAction SilentlyContinue
    throw "Checksum mismatch for $PackageId@${Version}: Nexus reported $expectedSha256, downloaded file hashes to $actualSha256. Refusing to promote."
}
Write-Host "Checksum verified: $actualSha256"

try {
    Write-Host "Pushing to '$TargetRepo'..."
    $pushSource = "$NexusBaseUrl/repository/$TargetRepo/"
    choco push $tempFile --source="$pushSource" --api-key="$env:PRODUCTION_API_KEY"
    if ($LASTEXITCODE -ne 0) {
        throw "choco push exited with code $LASTEXITCODE"
    }

    Write-Host "Verifying promoted asset in '$TargetRepo'..."
    $verifyUri = "$NexusBaseUrl/service/rest/v1/search/assets?repository=$TargetRepo&name=$PackageId&version=$Version"
    $verifyResult = Invoke-RestMethod -Uri $verifyUri -Credential $readCred -Method Get
    $promoted = @($verifyResult.items) | Select-Object -First 1
    if (-not $promoted -or $promoted.checksum.sha256.ToLowerInvariant() -ne $expectedSha256.ToLowerInvariant()) {
        throw "Post-push verification failed: promoted asset in '$TargetRepo' does not match the expected checksum $expectedSha256."
    }

    Write-Host "$PackageId@$Version promoted to '$TargetRepo' (sha256 $expectedSha256)."
} finally {
    Remove-Item $tempFile -ErrorAction SilentlyContinue
}
