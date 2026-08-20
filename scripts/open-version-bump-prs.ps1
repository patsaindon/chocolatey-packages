[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

# TODO (docs/architecture.md section 9.2): consume the output of
# check-upstream-versions.ps1 and, for each outdated package, open a PR
# bumping pinnedVersion in its internalize.yml (safer default — requires
# human merge to trigger re-internalization). Use the GitHub CLI or REST API
# with $env:GH_TOKEN.

Write-Host "TODO: open-version-bump-prs.ps1 not yet implemented."
exit 1
