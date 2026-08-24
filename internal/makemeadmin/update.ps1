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
    # Logs $LASTEXITCODE right before AU's own `choco pack` call -- a real
    # CI-only failure (Section 15) happens somewhere after au_BeforeUpdate
    # returns successfully (confirmed via this same log file showing every
    # mirror step complete) but before any further AU output appears at
    # all, and AU's own choco-pack-success check
    # (`if ($LastExitCode -ne 0) { throw "Choco pack failed..." }`,
    # majkinetor/AU's Update-Package.ps1) reads this same global,
    # process-wide variable -- one a deeply-nested native call earlier in
    # this same package's own processing (Grype, MpCmdRun, both run by
    # au_BeforeUpdate's own mirror step) could leave at a stale, non-zero
    # value that has nothing to do with choco pack's own real result.
    # Reset to a known-clean 0 here, immediately before AU's own check
    # would run, so a stale value from earlier native calls can't be
    # mistaken for choco pack's own failure.
    au_BeforeUpdateLog "[au_AfterUpdate] $($Package.Name): update_files completed, LASTEXITCODE was '$LASTEXITCODE' -- resetting to 0 before choco pack"
    $global:LASTEXITCODE = 0
}

function global:au_GetLatest {
    # Seeded from evergreen-api.stealthpuppy.com (https://eucpilots.com/evergreen/api/)
    # for 'MakeMeAdmin' — verify the filter below still matches what
    # this package actually wants to ship (was: Architecture=x64, InstallerType=Default).
    $releases = "https://evergreen-api.stealthpuppy.com/app/MakeMeAdmin"
    $variants = Invoke-RestMethod -Uri $releases -UserAgent "chocolatey-packages-mcp-server"
    $latest = $variants | Where-Object { $_.Architecture -eq 'x64' -and $_.InstallerType -eq 'Default' } | Select-Object -First 1
    if (-not $latest) { throw "No matching evergreen-api variant found for MakeMeAdmin." }

    # The checksum field name varies per app — found by testing: 7zip uses
    # 'Sha256', AdoptiumTemurin25 uses 'Checksum'. Try both rather than
    # hardcoding one and silently getting an empty checksum for apps that
    # use the other name.
    $checksum = if ($latest.Sha256) { $latest.Sha256 } else { $latest.Checksum }

    # Evergreen's Version can carry build-metadata syntax NuGet/choco
    # versions don't accept (e.g. '25.0.4.1+1-LTS') — same sanitization
    # already proven to work in production for temurin17's own
    # hand-written au_GetLatest. But found by testing a *different* real
    # app (Temurin25): that replacement isn't always enough on its own —
    # some vendors' version strings have more numeric segments than
    # NuGet/choco's 4-segment limit even after it, which temurin17's
    # version format happened not to hit. Fail loudly here instead of
    # letting choco pack fail later with a more confusing error.
    $version = $latest.Version -replace '\+', '.'
    if ($version -notmatch '^\d+(\.\d+){0,3}(-.+)?$') {
        throw "Sanitized version '$version' has more than 4 numeric segments (NuGet/choco's limit) — adjust this au_GetLatest's version handling for MakeMeAdmin's actual version format."
    }

    return @{
        URL32          = $latest.URI
        Version        = $version
        Checksum32     = $checksum
        ChecksumType32 = 'sha256'
    }
}

update -ChecksumFor none
