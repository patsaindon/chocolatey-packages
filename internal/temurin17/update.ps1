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
            "(?i)^(\s*checksum\s*=\s*)('.*')" = "`$1'$($Latest.Checksum)'"
            "(?i)^(\s*file\s*=\s*)('.*')" = "`$1'$($Latest.FileName)'"
        }
    }
}

function global:au_GetLatest {
    # TODO: point this at wherever this internal software actually publishes
    # releases (an internal file share, artifact repo, or vendor page) and
    # return at least URL32 + Version. See the AU README's "Public interface"
    # section: https://github.com/majkinetor/AU#public-interface
    $releases = "https://evergreen-api.stealthpuppy.com/app/AdoptiumTemurin17"
    $page = Invoke-RestMethod -Uri $releases -UserAgent "company/location"
    $latest = $page | Where-Object { $_.Architecture -eq "x64" -and $_.Type -eq "msi" -and $_.ImageType -eq "jdk" }

    $url = $latest.Links | Where-Object href -match 'temurin17-(?<version>[\d.]+)\.exe' | Select-Object -First 1 -ExpandProperty href
    $version = ($latest.Version -replace '\+', '.')

    return @{ URL = $latest.URI; 
              Version = $version;
              Checksum = $latest.Checksum;
              FileType = "msi";
              FileName = "OpenJDK17U-jdk_x64_windows_hotspot_${version}.msi"
            }
}

update -ChecksumFor none
