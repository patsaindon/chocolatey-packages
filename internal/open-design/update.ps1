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
    # the real releases page: the Windows asset is
    # 'open-design-<version>-win-x64-setup.exe' (a '-win-x64-setup' suffix
    # between version and extension), and the release tag itself is
    # 'open-design-v<version>' (package name baked into the tag, not a bare
    # 'v<version>') -- both broke the placeholder regex, which assumed a
    # plain '<id>-<version>.exe' shape neither actually has.
    $releases = 'https://api.github.com/repos/nexu-io/open-design/releases/latest'
    $latest = Invoke-RestMethod -Uri $releases -UserAgent 'chocolatey-packages-mcp-server'
    $asset = $latest.assets | Where-Object name -match '^open-design-[\d.]+-win-x64-setup\.exe$'
    if (-not $asset) {
        throw "No 'open-design-<version>-win-x64-setup.exe' asset found on open-design's latest release ($($latest.tag_name)) -- did the vendor rename it?"
    }
    if ($latest.tag_name -notmatch '(?<version>\d+\.\d+\.\d+)') {
        throw "Could not find a <major>.<minor>.<patch> version inside tag '$($latest.tag_name)'."
    }

    return @{ URL32 = $asset.browser_download_url; Version = $Matches.version }
}

update -ChecksumFor 32
