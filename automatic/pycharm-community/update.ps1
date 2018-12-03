import-module au

$releases = 'https://data.services.jetbrains.com/products/releases?code=PCC&latest=true&type=release'

function global:au_SearchReplace {
    @{
        'tools\chocolateyInstall.ps1' = @{
            "(^[$]url\s*=\s*)('.*')"      = "`$1'$($Latest.URL32)'"
            "(^[$]checksum\s*=\s*)('.*')" = "`$1'$($Latest.Checksum32)'"
            "(^[$]checksumType\s*=\s*)('.*')" = "`$1'$($Latest.ChecksumType32)'"
        }
     }
}

function global:au_GetLatest {
    $json = Invoke-WebRequest $releases | ConvertFrom-Json
    $url = $json.PCC.downloads.windows.link
    $version = $json.PCC.version
    $checksum = ((Invoke-RestMethod -Uri $json.PCC.downloads.windows.checksumLink -UseBasicParsing).Split(" "))[0]

    $Latest = @{ URL32 = $url; Version = $version; Checksum32 = $checksum; ChecksumType32 = 'sha256' }
    return $Latest
}

update -ChecksumFor none