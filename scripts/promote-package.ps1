[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PackageId,
    [Parameter(Mandatory)][string]$Version,
    [Parameter(Mandatory)][string]$SourceFeed,
    [Parameter(Mandatory)][string]$TargetFeed
)

$ErrorActionPreference = 'Stop'

# TODO (docs/architecture.md section 9.4): copy the exact .nupkg identified by
# PackageId + Version (verify by content hash) from SourceFeed to TargetFeed
# using the artifact repository's promotion/copy API (native promotion on
# ProGet; repo-to-repo copy on Artifactory/Nexus). Must NOT rebuild the
# package — bit-for-bit identical to what was scanned in staging.

Write-Host "TODO: promote-package.ps1 not yet implemented. PackageId=$PackageId Version=$Version SourceFeed=$SourceFeed TargetFeed=$TargetFeed"
exit 1
