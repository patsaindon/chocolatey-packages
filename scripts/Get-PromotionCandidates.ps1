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
# human review (see docs/architecture.md section 9.4). Never pushes
# anything -- it does download from $TestRepo (read-only) to inspect a
# candidate's own nuspec for dependencies, but never touches $ProdRepo
# beyond listing it, so it still needs no production credentials at all.
#
# Dependencies matter here because production endpoints have no internet
# access to resolve anything themselves (see docs/architecture.md section
# 6.4/12) -- if a package depends on another that never gets promoted,
# installing it at an endpoint fails. Neither this script nor
# Promote-Package.ps1 considered dependencies at all before this; found
# by testing that `choco info`/`choco search` don't surface them either
# -- only a package's own nuspec does.

. (Join-Path $PSScriptRoot 'ConvertTo-ChocoObject.ps1')

# Reads a candidate's real dependency ids straight from its own nuspec --
# `choco info` was checked and confirmed by testing not to surface this
# at all. Downloads only that one package (--ignore-dependencies, same
# reasoning Promote-Package.ps1 already uses) purely to read its nuspec;
# nothing here is pushed or kept.
function Get-PackageDependencyIds {
    param([string]$PackageId, [string]$Version, [string]$Source)

    $tempPath = Join-Path -Path $env:TEMP -ChildPath ([GUID]::NewGuid()).GUID
    try {
        choco download $PackageId --no-progress --version=$Version --output-directory=$tempPath --source=$Source --force --ignore-dependencies *> $null
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Couldn't download '$PackageId' $Version from staging to check its dependencies -- skipping dependency check for it."
            return @()
        }

        $nupkg = Get-Item -Path (Join-Path $tempPath '*.nupkg') -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $nupkg) { return @() }

        $extractPath = Join-Path $tempPath 'extracted'
        Expand-Archive -Path $nupkg.FullName -DestinationPath $extractPath -Force

        $nuspecFile = Get-Item -Path (Join-Path $extractPath '*.nuspec') -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $nuspecFile) { return @() }

        [xml]$nuspecXml = Get-Content -Path $nuspecFile.FullName -Raw
        $depNodes = $nuspecXml.package.metadata.dependencies.dependency
        if (-not $depNodes) { return @() }
        return @($depNodes | ForEach-Object { $_.id })
    } finally {
        Remove-Item -Path $tempPath -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$testPkgs = @(choco search --source=$TestRepo --all-versions --limit-output | ConvertTo-ChocoObject)
$prodPkgs = @(choco search --source=$ProdRepo --all-versions --limit-output | ConvertTo-ChocoObject)

if ($testPkgs.Count -eq 0) {
    Write-Verbose "Test repository appears to be empty. Nothing to promote."
    return @()
}

$prodIds = @{}
foreach ($p in $prodPkgs) { $prodIds["$($p.name)|$($p.version)"] = $true }

$testByName = @{}
foreach ($p in $testPkgs) { $testByName[$p.name] = $p }

$initialCandidates = if ($prodPkgs.Count -eq 0) {
    $testPkgs
} else {
    @(Compare-Object -ReferenceObject $testPkgs -DifferenceObject $prodPkgs -Property name, version |
        Where-Object SideIndicator -eq '<=' |
        Select-Object name, version)
}

$resultByKey = [ordered]@{}
$dependencyOf = @{}   # key -> package(s) that pulled it in, for a human-readable PR note
foreach ($c in $initialCandidates) { $resultByKey["$($c.name)|$($c.version)"] = $c }

$queue = [System.Collections.Generic.Queue[object]]::new()
foreach ($c in $initialCandidates) { $queue.Enqueue($c) }
$processed = @{}

while ($queue.Count -gt 0) {
    $current = $queue.Dequeue()
    $currentKey = "$($current.name)|$($current.version)"
    if ($processed.ContainsKey($currentKey)) { continue }
    $processed[$currentKey] = $true

    $depIds = Get-PackageDependencyIds -PackageId $current.name -Version $current.version -Source $TestRepo
    foreach ($depId in $depIds) {
        $depPkg = $testByName[$depId]
        if (-not $depPkg) {
            Write-Warning "'$($current.name)' $($current.version) depends on '$depId', which isn't in staging at all -- can't promote a dependency that was never internalized."
            continue
        }
        $depKey = "$($depPkg.name)|$($depPkg.version)"
        if ($prodIds.ContainsKey($depKey)) { continue }   # already in production, nothing to do

        $existingReason = if ($dependencyOf.ContainsKey($depKey)) { $dependencyOf[$depKey] } else { @() }
        $dependencyOf[$depKey] = @($existingReason + "$($current.name) $($current.version)" | Select-Object -Unique)

        if (-not $resultByKey.Contains($depKey)) {
            $resultByKey[$depKey] = $depPkg
            $queue.Enqueue($depPkg)
        }
    }
}

return $resultByKey.Values | ForEach-Object {
    $key = "$($_.name)|$($_.version)"
    [pscustomobject]@{
        name         = $_.name
        version      = $_.version
        dependencyOf = if ($dependencyOf.ContainsKey($key)) { $dependencyOf[$key] -join ', ' } else { $null }
    }
}
