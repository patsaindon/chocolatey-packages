[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]
    $InternalDir,

    [Parameter(Mandatory)]
    [string]
    $StagingRepo,

    [Parameter(Mandatory)]
    [string]
    $StagingApiKey
)

$ErrorActionPreference = 'Stop'

# For every internal/<id>/*.nupkg that update_all.ps1 (AU) just packed
# LOCALLY (Push disabled — see update-internal-packages.yml), internalizes
# it from that local file, scans it, and pushes only the internalized
# result to staging. The "thin" (vendor-URL-referencing) nupkg AU produced
# never touches any shared feed — it's a transient local build artifact,
# the same principle internalize-community-package.yml already uses
# (download -> scan -> push, nothing shared in between).
#
# This deliberately avoids trying to replace an already-published version
# in place: Nexus/Artifactory/BaGetter (and the NuGet protocol generally)
# treat a published id+version as immutable — confirmed by testing that
# even a successful DELETE (which only unlists, doesn't purge) still left
# a same-version push rejected with 409 Conflict. AU itself only repacks
# when a genuinely new version was found (see docs/architecture.md), so
# the nupkg this script finds should always be for a version not yet in
# staging — nothing here needs to overwrite anything.

$nupkgs = Get-ChildItem -Path $InternalDir -Recurse -Filter '*.nupkg' -File |
    Where-Object { $_.DirectoryName -notlike '*\_template*' -and $_.DirectoryName -notlike '*/_template*' }

if ($nupkgs.Count -eq 0) {
    Write-Host "No packages were packed by update_all.ps1 — nothing to internalize."
    exit 0
}

$failed = $false

foreach ($nupkg in $nupkgs) {
    $packageDir = Split-Path $nupkg.FullName -Parent
    $packageId = Split-Path $packageDir -Leaf
    $tempPath = Join-Path -Path $env:TEMP -ChildPath ([GUID]::NewGuid()).GUID

    try {
        Write-Host "Internalizing '$($nupkg.Name)' (packed locally by AU) for '$packageId'."
        choco download $packageId --internalize --internalize-all-urls --force `
            --source="$packageDir" --outputdirectory=$tempPath --no-progress
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "'$packageId': choco download --internalize failed (exit $LASTEXITCODE)."
            $failed = $true
            continue
        }

        & (Join-Path $PSScriptRoot 'scan-package.ps1') -PackagePath $tempPath
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "'$packageId': scan-package.ps1 flagged it (exit $LASTEXITCODE) — not pushing."
            $failed = $true
            continue
        }

        $internalizedNupkgs = Get-ChildItem -Path $tempPath -Filter '*.nupkg' -File
        if ($internalizedNupkgs.Count -eq 0) {
            Write-Warning "'$packageId': no .nupkg produced after internalize."
            $failed = $true
            continue
        }

        foreach ($internalized in $internalizedNupkgs) {
            choco push $internalized.FullName --source=$StagingRepo --api-key=$StagingApiKey
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "'$packageId': push of '$($internalized.Name)' to staging failed (exit $LASTEXITCODE)."
                $failed = $true
            } else {
                Write-Host "'$packageId': pushed internalized '$($internalized.Name)' to staging."
            }
        }
    } catch {
        Write-Warning "'$packageId' failed with an unexpected error: $($_.Exception.Message)"
        $failed = $true
    } finally {
        Remove-Item -Path $tempPath -Recurse -Force -ErrorAction SilentlyContinue
        # The thin nupkg AU packed locally is a build artifact, not
        # something to keep around or accidentally commit.
        Remove-Item -Path $nupkg.FullName -Force -ErrorAction SilentlyContinue
    }
}

if ($failed) { exit 1 }
