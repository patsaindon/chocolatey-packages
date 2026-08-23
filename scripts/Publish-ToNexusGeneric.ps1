[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]
    $SourceUrl,

    [Parameter(Mandatory)]
    [string]
    $PackageId,

    [Parameter(Mandatory)]
    [string]
    $Version,

    [Parameter(Mandatory)]
    [string]
    $NexusBaseUrl,

    [Parameter(Mandatory)]
    [string]
    $Repository,

    # Write credentials -- 'username:password' or a Nexus User Token pair,
    # scoped to add/edit on just this one repository (see docs/
    # architecture.md's note on the dedicated 'au-mirror' user this was
    # tested with -- never the same credential a human's own read-only
    # paywalled-package access uses, and never admin). Falls back to
    # NEXUS_GENERIC_WRITE_TOKEN from the environment.
    [string]
    $Credentials = $env:NEXUS_GENERIC_WRITE_TOKEN,

    [ValidateSet('Negligible', 'Low', 'Medium', 'High', 'Critical')]
    [string]
    $MinSeverity = 'High'
)

# Mirrors an internal AU package's real vendor binary into Nexus generic
# (raw-format) hosted storage, so the package this repo ships never
# actually points endpoints at the vendor's own server -- the general
# form of the mechanism already built for paywalled software (Section 6.8),
# extended to every internal AU package instead of only paywalled ones
# (Section 15's "generalizing the Nexus-mirror step"), and specifically
# *not* built on Chocolatey's own Package Internalizer: confirmed by
# inspecting a real internalized package's chocolateyInstall.ps1 that
# `choco download --internalize` embeds a hard license-check
# (Invoke-ValidateChocolateyLicense) requiring every consuming endpoint to
# itself hold a Chocolatey Business/MSP license -- a real, previously-
# unverified constraint this mechanism deliberately avoids by never
# touching that licensed feature at all, just a plain authenticated HTTP
# upload.
#
# Called from an internal package's own au_GetLatest via an au_BeforeUpdate
# hook (see internal/_template/update.ps1), after au_GetLatest has already
# resolved the real vendor URL/version/checksum but *before* au_SearchReplace
# writes anything into chocolateyinstall.ps1 -- this script's own returned
# URL/checksum replace the vendor's, so everything downstream (au_SearchReplace,
# choco pack) ends up referencing Nexus without needing any change to that
# existing machinery.
#
# Scans the real binary itself before ever uploading it -- not the eventual
# nupkg, which (being a thin, URL-referencing package like every AU package
# already is) has nothing for Grype to see. This is the one point where the
# actual bytes exist and can be scanned; once mirrored, every future
# reference reuses this exact, already-scanned copy.

$ErrorActionPreference = 'Stop'

if (-not $Credentials) {
    throw "No write credentials given (pass -Credentials or set NEXUS_GENERIC_WRITE_TOKEN) -- refusing to mirror without one rather than attempt an anonymous write."
}

$tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Path $tempDir | Out-Null

try {
    $fileName = Split-Path -Leaf ([uri]$SourceUrl).LocalPath
    if (-not $fileName) { $fileName = "$PackageId-$Version" }
    $localPath = Join-Path $tempDir $fileName

    # Write-Host (not Write-Verbose) deliberately -- found by testing a real
    # CI run that AU's own output buffering can lose an entire package's
    # worth of piped ('| result') messages if that package's processing
    # throws, leaving no trace of how far it got. These print unconditionally
    # and immediately, so a future failure still shows exactly which step
    # was reached.
    Write-Host "[Publish-ToNexusGeneric] Downloading '$SourceUrl' -> '$localPath'"
    Invoke-WebRequest -Uri $SourceUrl -OutFile $localPath -UseBasicParsing
    Write-Host "[Publish-ToNexusGeneric] Downloaded $((Get-Item $localPath).Length) bytes"

    Write-Host "[Publish-ToNexusGeneric] Scanning downloaded file before mirroring it anywhere"
    & (Join-Path $PSScriptRoot 'scan-package.ps1') -RawFilePath $localPath -MinSeverity $MinSeverity
    if ($LASTEXITCODE -ne 0) {
        throw "'$PackageId' $Version failed scanning (scan-package.ps1 exit $LASTEXITCODE) -- not mirroring an unscanned or flagged binary to Nexus."
    }
    Write-Host "[Publish-ToNexusGeneric] Scan passed"

    $checksum = (Get-FileHash -Path $localPath -Algorithm SHA256).Hash.ToLowerInvariant()

    $pathPrefix = "internal/$PackageId/"
    $nexusPath = "$pathPrefix$fileName"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Credentials)
    $authHeader = @{ Authorization = "Basic $([Convert]::ToBase64String($bytes))" }

    $uploadUri = "$($NexusBaseUrl.TrimEnd('/'))/repository/$Repository/$nexusPath"
    Write-Host "[Publish-ToNexusGeneric] Uploading to '$uploadUri'"
    Invoke-RestMethod -Uri $uploadUri -Method Put -InFile $localPath -Headers $authHeader | Out-Null
    Write-Host "[Publish-ToNexusGeneric] Upload complete"

    [pscustomobject]@{
        Url      = $uploadUri
        Checksum = $checksum
    }
} catch {
    Write-Host "[Publish-ToNexusGeneric] FAILED: $($_.Exception.GetType().FullName): $($_.Exception.Message)"
    Write-Host "[Publish-ToNexusGeneric] Stack: $($_.ScriptStackTrace)"
    throw
} finally {
    Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
}
