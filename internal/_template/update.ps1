# AU (Chocolatey Automatic Packages) update script.
# https://github.com/majkinetor/AU
#
# Run for a single package:  .\update.ps1 -Verbose
# Run for every internal/ package: see update_all.ps1 / test_all.ps1 at the
# repo root, and .github/workflows/update-internal-packages.yml.

import-module au

function global:au_SearchReplace {
    @{
        ".\tools\chocolateyinstall.ps1" = @{
            "(?i)^(\s*url\s*=\s*)('.*')"      = "`$1'$($Latest.URL32)'"
            "(?i)^(\s*checksum\s*=\s*)('.*')" = "`$1'$($Latest.Checksum32)'"
        }
    }
}

function global:au_BeforeUpdateLog($Message) {
    # Same fixed log file scripts/Publish-ToNexusGeneric.ps1 writes to --
    # found by testing a real CI run that AU's own output handling can lose
    # Write-Host entirely for a package whose processing throws, so this
    # exists purely so a workflow step can dump the file unconditionally
    # (`if: always()`) regardless of what AU itself does with the console.
    $line = "[$([DateTime]::UtcNow.ToString('o'))] $Message"
    Write-Host $line
    Add-Content -Path (Join-Path ([System.IO.Path]::GetTempPath()) 'nexus-mirror-debug.log') -Value $line -Encoding utf8
}

function global:au_BeforeUpdate($Package) {
    au_BeforeUpdateLog "[au_BeforeUpdate] ENTERED for $($Package.Name), URL32=$($global:Latest.URL32)"
    # Mirrors the real binary au_GetLatest just resolved into Nexus generic
    # (raw-format) hosted storage *before* au_SearchReplace writes anything
    # above into chocolateyinstall.ps1 -- deliberately not Chocolatey's own
    # Package Internalizer (`choco download --internalize`), which embeds a
    # license check every consuming endpoint would then need a Chocolatey
    # Business/MSP license to satisfy, confirmed by inspecting a real
    # internalized package's own script. See docs/architecture.md section
    # 15 ("generalizing the Nexus-mirror step") for the full rationale, and
    # scripts/Publish-ToNexusGeneric.ps1 for what this actually does
    # (download, scan, upload) -- this function only ever overwrites
    # $Latest's own URL32/Checksum32 with what that script returns, so
    # au_SearchReplace above needs no changes at all.
    #
    # Skipped, not a hard failure, when NEXUS_MIRROR_BASE_URL isn't set --
    # keeps this optional for an ad-hoc local run that hasn't configured
    # it; every real workflow in this repo does. Also skipped if the URL
    # already points at this same Nexus base (e.g. a paywalled package,
    # whose own au_GetLatest already reads straight from Nexus) -- mirroring
    # an already-mirrored file would be pointless and would need write
    # credentials that package type never otherwise needs.
    if (-not $env:NEXUS_MIRROR_BASE_URL) {
        Write-Warning "NEXUS_MIRROR_BASE_URL not set -- skipping the Nexus mirror step; $($Package.Name) will keep referencing its real vendor URL directly."
        return
    }
    if ($global:Latest.URL32 -like "$($env:NEXUS_MIRROR_BASE_URL)*") {
        au_BeforeUpdateLog "[au_BeforeUpdate] $($Package.Name): URL32 already points at the Nexus mirror base -- skipping (already mirrored, e.g. a paywalled package)."
        return
    }

    au_BeforeUpdateLog "[au_BeforeUpdate] $($Package.Name): mirroring $($global:Latest.URL32) to Nexus"
    $mirrored = & (Join-Path $PSScriptRoot '..' '..' 'scripts' 'Publish-ToNexusGeneric.ps1') `
        -SourceUrl $global:Latest.URL32 `
        -PackageId $Package.Name `
        -Version $global:Latest.Version `
        -NexusBaseUrl $env:NEXUS_MIRROR_BASE_URL `
        -Repository $env:NEXUS_MIRROR_REPOSITORY

    $global:Latest.URL32 = $mirrored.Url
    $global:Latest.Checksum32 = $mirrored.Checksum
    au_BeforeUpdateLog "[au_BeforeUpdate] $($Package.Name): mirrored to $($mirrored.Url)"
}

function global:au_AfterUpdate($Package) {
    # Diagnostic only -- confirms update_files (au_SearchReplace) completed
    # before AU calls `choco pack`, to narrow down a real CI-only failure
    # (Section 15) that happens somewhere after au_BeforeUpdate returns
    # successfully but before any further AU output appears at all.
    au_BeforeUpdateLog "[au_AfterUpdate] $($Package.Name): update_files completed, about to choco pack"
}

function global:au_GetLatest {
    # TODO: point this at wherever this internal software actually publishes
    # releases (an internal file share, artifact repo, or vendor page) and
    # return at least URL32 + Version. See the AU README's "Public interface"
    # section: https://github.com/majkinetor/AU#public-interface
    $releases = 'https://CHANGE_ME/releases'
    $page = Invoke-WebRequest -Uri $releases -UseBasicParsing

    $re  = 'CHANGE_ME-(?<version>[\d.]+)\.exe'
    $url = $page.Links | Where-Object href -match $re | Select-Object -First 1 -ExpandProperty href
    $version = ($url -split '-' | Select-Object -Last 1) -replace '\.exe$'

    return @{ URL32 = $url; Version = $version }
}

update -ChecksumFor none
