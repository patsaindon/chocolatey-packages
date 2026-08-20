[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$PackagePath
)

$ErrorActionPreference = 'Stop'

# TODO (docs/architecture.md section 6.7): run AV + CVE/vulnerability scanning
# against every .nupkg under $PackagePath. Fail the step (non-zero exit) on
# any finding above the agreed severity threshold so the workflow halts
# before pushing to staging.
#
# Candidates: Grype, OSV-Scanner, a commercial SCA tool, or the artifact
# repository's built-in scanning (Artifactory Xray / Nexus IQ / ProGet).

Write-Host "TODO: scan-package.ps1 not yet implemented. PackagePath=$PackagePath"
exit 1
