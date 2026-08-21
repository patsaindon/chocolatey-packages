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
            "(?i)^(\s*checksum\s*=\s*)('.*')" = "`$1'$($Latest.Checksum32)'"
            "(?i)^(\s*file\s*=\s*)('.*')"     = "`$1'$($Latest.Filename)'"
        }
    }
}

function global:au_GetLatest {
    # Seeded from evergreen-api.stealthpuppy.com (https://eucpilots.com/evergreen/api/)
    # for 'AdoptiumTemurin25' — verify the filter below still matches what
    # this package actually wants to ship (was: Architecture=x64, ImageType=jdk).
    $releases = "https://evergreen-api.stealthpuppy.com/app/AdoptiumTemurin25"
    $variants = Invoke-RestMethod -Uri $releases -UserAgent "chocolatey-packages-mcp-server"
    $latest = $variants | Where-Object { $_.Architecture -eq 'x64' -and $_.ImageType -eq 'jdk' } | Select-Object -First 1
    if (-not $latest) { throw "No matching evergreen-api variant found for AdoptiumTemurin25." }

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
    $fileName = $latest.URI -split '/' | Select-Object -Last 1
    $version = ($latest.Version -replace '\-LTS', '' -split '\+')[0]
    if ($version -notmatch '^\d+(\.\d+){0,3}(-.+)?$') {
        throw "Sanitized version '$version' has more than 4 numeric segments (NuGet/choco's limit) — adjust this au_GetLatest's version handling for AdoptiumTemurin25's actual version format."
    }

    return @{
        URL32          = $latest.URI
        Version        = $version
        Checksum32     = $checksum
        ChecksumType32 = 'sha256'
        Filename       = $fileName
    }
}

update -ChecksumFor none
