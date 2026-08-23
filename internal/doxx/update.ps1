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
    # Real GitHub Releases API lookup, not a placeholder -- confirmed by
    # testing against the real releases page: doxx's Windows asset
    # (doxx-x86_64-pc-windows-msvc.msi) carries no version in its own
    # filename at all (unlike, say, an '<id>-<version>.exe' convention), so
    # the version has to come from the release's own tag_name instead.
    $releases = 'https://api.github.com/repos/bgreenwell/doxx/releases/latest'
    $latest = Invoke-RestMethod -Uri $releases -UserAgent 'chocolatey-packages-mcp-server'
    $asset = $latest.assets | Where-Object name -eq 'doxx-x86_64-pc-windows-msvc.msi'
    if (-not $asset) {
        throw "No 'doxx-x86_64-pc-windows-msvc.msi' asset found on doxx's latest release ($($latest.tag_name)) -- did the vendor rename it?"
    }

    return @{ URL32 = $asset.browser_download_url; Version = $latest.tag_name -replace '^v' }
}

# doxx also publishes a matching .sha256 sidecar file per asset, but letting
# AU download-and-hash the .msi itself (ChecksumFor 32) is simpler and just
# as reliable, and matches the pattern already proven by alacritty/rufus.
update -ChecksumFor 32
