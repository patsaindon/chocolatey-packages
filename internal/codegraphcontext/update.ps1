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
    # Real GitHub Releases API lookup, not a placeholder -- confirmed against
    # the real releases page (tag v0.5.7). The Windows asset is
    # 'cgc-windows.exe' (the binary's own short command name, not the
    # package id at all), which the placeholder regex
    # ('codegraphcontext-(?<version>[\d.]+)\.exe') could never have matched
    # -- the PR's own original testing already confirmed this exact asset
    # (downloaded, SHA256-verified, ran and reported "CodeGraphContext
    # 0.5.7"), so no further verification of the asset name itself was
    # needed here, just wiring it into a real lookup.
    $releases = 'https://api.github.com/repos/CodeGraphContext/CodeGraphContext/releases/latest'
    $latest = Invoke-RestMethod -Uri $releases -UserAgent 'chocolatey-packages-mcp-server'
    $asset = $latest.assets | Where-Object name -eq 'cgc-windows.exe'
    if (-not $asset) {
        throw "No 'cgc-windows.exe' asset found on codegraphcontext's latest release ($($latest.tag_name)) -- did the vendor rename it?"
    }

    return @{ URL32 = $asset.browser_download_url; Version = $latest.tag_name -replace '^v' }
}

update -ChecksumFor 32
