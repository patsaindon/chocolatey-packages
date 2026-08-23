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
    # Sourced from a Nexus generic (raw-format) hosted repository, not a
    # vendor page: this software is paywalled, so a human logs in,
    # downloads a new release themselves, and uploads it to this fixed
    # path whenever the vendor ships one — this automation never holds
    # those vendor credentials, only reads what was already deposited.
    # Verified against a real Nexus instance (docs/architecture.md) —
    # NEXUS_GENERIC_READ_TOKEN must be set wherever this runs (a
    # 'username:password' or Nexus User Token pair), and the target
    # repository needs to be readable by whatever downloads the file this
    # returns (Get-ChocolateyWebFile has no credential of its own to send
    # — see docs/architecture.md's note on scoping anonymous read to just
    # this one repository, not Nexus's broader default).
    $scriptPath = Join-Path $PSScriptRoot '..' '..' 'scripts' 'Get-NexusGenericLatestAsset.ps1'
    $asset = & $scriptPath -NexusBaseUrl 'http://localhost:8082' -Repository 'generic-hosted' -PathPrefix 'acme/demo-app/'

    return @{
        URL32          = $asset.DownloadUrl
        Version        = $asset.Version
        Checksum32     = $asset.Sha256
        ChecksumType32 = 'sha256'
    }
}

update -ChecksumFor none
