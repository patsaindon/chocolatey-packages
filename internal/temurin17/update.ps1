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

function global:au_GetLatest {
    # evergreen-api.stealthpuppy.com (https://eucpilots.com/evergreen/api/)
    # for 'AdoptiumTemurin17' — same shape as temurin25's own (already
    # working) au_GetLatest; kept temurin17's original Type=msi filter too,
    # since evergreen can list more than one installer Type (msi/exe/zip)
    # per Architecture+ImageType combination and this package specifically
    # wants the MSI.
    $releases = "https://evergreen-api.stealthpuppy.com/app/AdoptiumTemurin17"
    $variants = Invoke-RestMethod -Uri $releases -UserAgent "chocolatey-packages-mcp-server"
    $latest = $variants | Where-Object { $_.Architecture -eq 'x64' -and $_.Type -eq 'msi' -and $_.ImageType -eq 'jdk' } | Select-Object -First 1
    if (-not $latest) { throw "No matching evergreen-api variant found for AdoptiumTemurin17." }

    # The checksum field name varies per app — found by testing: 7zip uses
    # 'Sha256', AdoptiumTemurin25 uses 'Checksum'. Try both rather than
    # hardcoding one and silently getting an empty checksum for apps that
    # use the other name.
    $checksum = if ($latest.Sha256) { $latest.Sha256 } else { $latest.Checksum }

    # Evergreen's Version can carry build-metadata syntax NuGet/choco
    # versions don't accept (e.g. '17.0.16+8') — same sanitization already
    # proven to work in production for this package before this fix, kept
    # unchanged, plus the 4-numeric-segment guard temurin25's au_GetLatest
    # added after finding a different real app that needed it.
    $version = ($latest.Version -replace '\-LTS', '' -split '\+')[0]
    if ($version -notmatch '^\d+(\.\d+){0,3}(-.+)?$') {
        throw "Sanitized version '$version' has more than 4 numeric segments (NuGet/choco's limit) — adjust this au_GetLatest's version handling for AdoptiumTemurin17's actual version format."
    }

    return @{
        URL32          = $latest.URI
        Version        = $version
        Checksum32     = $checksum
        ChecksumType32 = 'sha256'
    }
}

update -ChecksumFor none
