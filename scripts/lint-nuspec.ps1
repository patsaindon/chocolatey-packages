[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$PackageDir
)

$ErrorActionPreference = 'Stop'

# TODO (docs/architecture.md section 9.3): validate the .nuspec under
# $PackageDir — required metadata fields present, version format valid,
# id matches folder name, etc. Fail the step on any violation.

Write-Host "TODO: lint-nuspec.ps1 not yet implemented. PackageDir=$PackageDir"
exit 1
