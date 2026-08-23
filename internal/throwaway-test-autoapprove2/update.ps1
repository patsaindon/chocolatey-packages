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
    # NOT YET VERIFIED AGAINST A REAL NEXUS INSTANCE — see
    # docs/architecture.md and scripts/Get-NexusGenericLatestAsset.ps1's
    # own header before trusting this in production.
    $scriptPath = Join-Path $PSScriptRoot '..' '..' 'scripts' 'Get-NexusGenericLatestAsset.ps1'
    $asset = & $scriptPath -NexusBaseUrl 'https://nexus.example.internal' -Repository 'generic-hosted' -PathPrefix 'test/throwaway-test-autoapprove2/'

    return @{
        URL32          = $asset.DownloadUrl
        Version        = $asset.Version
        Checksum32     = $asset.Sha256
        ChecksumType32 = 'sha256'
    }
}

update -ChecksumFor none
