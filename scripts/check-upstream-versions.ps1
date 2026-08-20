[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ManifestDir
)

$ErrorActionPreference = 'Stop'

# TODO (docs/architecture.md section 9.2): for every internalize.yml under
# $ManifestDir with autoUpdateCheck: true, query the Community Repository's
# current version for that packageId and compare against pinnedVersion.
# Write results (e.g. a JSON list of {packageId, pinnedVersion, latestVersion})
# for open-version-bump-prs.ps1 to consume.

Write-Host "TODO: check-upstream-versions.ps1 not yet implemented. ManifestDir=$ManifestDir"
exit 1
