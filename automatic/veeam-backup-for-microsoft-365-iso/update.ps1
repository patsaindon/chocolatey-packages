Import-Module au

$releases = 'https://www.veeam.com/download-version.html'
$releaseNotesFeed = 'https://www.veeam.com/services/veeam/technical-documents?resourceType=resourcetype:techdoc/releasenotes&productId=36'
$productName = 'for Microsoft 365'

function global:au_SearchReplace {
  @{
    'tools\chocolateyInstall.ps1' = @{
      "(^[$]filename\s*=\s*)('.*')"     = "`$1'$($Latest.Filename)'"
      "(^[$]url\s*=\s*)('.*')"          = "`$1'$($Latest.URL32)'"
      "(^[$]checksum\s*=\s*)('.*')"     = "`$1'$($Latest.Checksum32)'"
      "(^[$]checksumType\s*=\s*)('.*')" = "`$1'$($Latest.ChecksumType32)'"
    }
    "$($Latest.PackageName).nuspec" = @{
      "(?i)(^\s*\<releaseNotes\>).*(\<\/releaseNotes\>)" = "`${1}$($Latest.ReleaseNotes)`${2}"
    }
  }
}

function global:au_GetLatest {
    $download_page = Invoke-WebRequest -Uri $releases -DisableKeepAlive
    $table = $download_page.ParsedHtml.getElementsByTagName('tbody') | Where-Object innerhtml -Match $productName | Select-Object -First 1

    $re = "Version\s+:\s+([0-9]+\.[0-9]+\.[0-9]+(?:\.[0-9]+)(?:\.[0-9]+)?)"

    $table.innerHTML -imatch $re
    $version = $Matches[1]

    $isoVersion = $version

    if($version -match "6.0.0.379") {
      $isoVersion = "6.0.0.379_P20220413"
    }

    $version = Get-Version ($version)
    $majversion = $version.ToString(1)

    $filename = "Veeam.Backup365_$($isoVersion).iso"
    $url = "https://download2.veeam.com/VBO/v$($majversion)/$($filename)"

    $releaseNotesPage = Invoke-WebRequest $releaseNotesFeed | ConvertFrom-Json

    $ReleaseNotes = $releaseNotesPage.payload.products[0].documentGroups[0].documents[0].links.pdf

    return @{
        Filename = $filename
        URL32 = $url
        Version = $version
        ReleaseNotes = $ReleaseNotes
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    update -ChecksumFor 32
}
