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

# Writes to both the host AND a fixed, predictable log file -- found by
# testing a real CI run that AU's own output handling can lose Write-Host
# output entirely for a package whose processing throws (no trace of how
# far it got, not even these checkpoints), something local testing never
# reproduced. The file survives regardless of whatever AU itself does with
# stdout/host streams; a workflow step can print it unconditionally
# (`if: always()`) after the AU step, independent of AU's own behavior.
$debugLogPath = Join-Path ([System.IO.Path]::GetTempPath()) 'nexus-mirror-debug.log'
function Write-MirrorLog {
    param([string]$Message)
    $line = "[$([DateTime]::UtcNow.ToString('o'))] $Message"
    Write-Host $line
    Add-Content -Path $debugLogPath -Value $line -Encoding utf8
}

if (-not $Credentials) {
    throw "No write credentials given (pass -Credentials or set NEXUS_GENERIC_WRITE_TOKEN) -- refusing to mirror without one rather than attempt an anonymous write."
}

$tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Path $tempDir | Out-Null

try {
    $fileName = Split-Path -Leaf ([uri]$SourceUrl).LocalPath
    if (-not $fileName) { $fileName = "$PackageId-$Version" }
    $localPath = Join-Path $tempDir $fileName

    Write-MirrorLog "[Publish-ToNexusGeneric] Downloading '$SourceUrl' -> '$localPath'"
    Invoke-WebRequest -Uri $SourceUrl -OutFile $localPath -UseBasicParsing
    Write-MirrorLog "[Publish-ToNexusGeneric] Downloaded $((Get-Item $localPath).Length) bytes"

    Write-MirrorLog "[Publish-ToNexusGeneric] Scanning downloaded file before mirroring it anywhere"
    & (Join-Path $PSScriptRoot 'scan-package.ps1') -RawFilePath $localPath -MinSeverity $MinSeverity
    if ($LASTEXITCODE -ne 0) {
        throw "'$PackageId' $Version failed scanning (scan-package.ps1 exit $LASTEXITCODE) -- not mirroring an unscanned or flagged binary to Nexus."
    }
    Write-MirrorLog "[Publish-ToNexusGeneric] Scan passed"

    $checksum = (Get-FileHash -Path $localPath -Algorithm SHA256).Hash.ToLowerInvariant()

    $pathPrefix = "internal/$PackageId/"
    $nexusPath = "$pathPrefix$fileName"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Credentials)
    $authHeader = @{ Authorization = "Basic $([Convert]::ToBase64String($bytes))" }

    $uploadUri = "$($NexusBaseUrl.TrimEnd('/'))/repository/$Repository/$nexusPath"
    Write-MirrorLog "[Publish-ToNexusGeneric] Uploading to '$uploadUri'"
    Invoke-RestMethod -Uri $uploadUri -Method Put -InFile $localPath -Headers $authHeader | Out-Null
    Write-MirrorLog "[Publish-ToNexusGeneric] Upload complete"

    [pscustomobject]@{
        Url      = $uploadUri
        Checksum = $checksum
    }
} catch {
    Write-MirrorLog "[Publish-ToNexusGeneric] FAILED: $($_.Exception.GetType().FullName): $($_.Exception.Message)"
    Write-MirrorLog "[Publish-ToNexusGeneric] Stack: $($_.ScriptStackTrace)"
    throw
} finally {
    Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
}
