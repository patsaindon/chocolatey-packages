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
    # above into chocolateyinstall.ps1 -- see docs/architecture.md section
    # 15 ("generalizing the Nexus-mirror step") and
    # scripts/Publish-ToNexusGeneric.ps1 for what this actually does
    # (download, scan, upload).
    #
    # Missing here until now -- this package predates the Nexus-mirror
    # generalization and was never retrofitted with this hook, which every
    # package scaffolded since has had. Found via an audit after a user
    # report that temurin17 kept resolving to its raw vendor URL instead of
    # Nexus no matter what au_GetLatest returned: the same gap (no
    # au_BeforeUpdate at all) turned out to affect seven packages, this one
    # included.
    #
    # Skipped, not a hard failure, when NEXUS_MIRROR_BASE_URL isn't set --
    # keeps this optional for an ad-hoc local run that hasn't configured
    # it; every real workflow in this repo does. Also skipped if the URL
    # already points at this same Nexus base.
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
    # CI-only failure happens somewhere after au_BeforeUpdate returns
    # successfully but before any further AU output appears at all, and
    # AU's own choco-pack-success check reads this same global,
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
