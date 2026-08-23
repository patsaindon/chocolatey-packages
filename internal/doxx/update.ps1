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
    # TODO: point this at wherever this internal software actually publishes
    # releases (an internal file share, artifact repo, or vendor page) and
    # return at least URL32 + Version. See the AU README's "Public interface"
    # section: https://github.com/majkinetor/AU#public-interface
    $releases = 'https://github.com/bgreenwell/doxx/releases'
    $page = Invoke-WebRequest -Uri $releases -UseBasicParsing

    $re  = 'doxx-(?<version>[\d.]+)\.exe'
    $url = $page.Links | Where-Object href -match $re | Select-Object -First 1 -ExpandProperty href
    $version = ($url -split '-' | Select-Object -Last 1) -replace '\.exe$'

    return @{ URL32 = $url; Version = $version }
}

update -ChecksumFor none
