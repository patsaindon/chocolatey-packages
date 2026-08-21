[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]
    $TestRepo,

    [Parameter(Mandatory)]
    [string]
    $ProdRepo
)

# Read-only diff of every package/version present in staging ($TestRepo)
# but not yet in production ($ProdRepo). Used by
# propose-package-promotion.yml to populate promotions/pending.yml for
# human review (see docs/architecture.md section 9.4). Deliberately never
# downloads or pushes anything, so it needs no production credentials at
# all -- only enough read access to run `choco search` against both feeds.

. (Join-Path $PSScriptRoot 'ConvertTo-ChocoObject.ps1')

$testPkgs = choco search --source=$TestRepo --all-versions --limit-output | ConvertTo-ChocoObject
$prodPkgs = choco search --source=$ProdRepo --all-versions --limit-output | ConvertTo-ChocoObject

if ($null -eq $testPkgs) {
    Write-Verbose "Test repository appears to be empty. Nothing to promote."
    return @()
}
elseif ($null -eq $prodPkgs) {
    return $testPkgs
}
else {
    return Compare-Object -ReferenceObject $testPkgs -DifferenceObject $prodPkgs -Property name, version |
        Where-Object SideIndicator -eq '<=' |
        Select-Object name, version
}
