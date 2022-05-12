import-module au

$releases = 'https://www.rarlab.com/download.htm'

function global:au_AfterUpdate {
  $re = "winrar-x64-$($Latest.FileVersion)(.+)?.exe"
  $download_page = Invoke-WebRequest -Uri $releases
  $urls = $download_page.links | Where-Object href -match $re
  $defaultLocale = "en"

  $lines = @()

  foreach ($url64 in $urls) {
    $url64 = 'https://www.rarlab.com' + $url64.href
    $url32 = $url64.Replace("winrar-x64-","winrar-x32-")
    $locale = ([regex]::Match($url64,$re)).Captures.Groups[1].value
    if ($locale -eq '') {
      $locale = $defaultLocale
    }
    #Write-Host "Getting checksums for locale $($locale)"
    $checksum32 = Get-RemoteChecksum $url32
    $checksum64 = Get-RemoteChecksum $url64
    $line = @($locale; $url64; $checksum64; $url32; $checksum32) -join '|'
    $lines += ,$line
  }
  [System.IO.File]::WriteAllLines("$PSScriptRoot\tools\downloadInfo.csv", $lines);
}

function global:au_SearchReplace {
    @{
        'tools\chocolateyInstall.ps1' = @{
            "(^[$]url_version\s*=\s*)('.*')" = "`$1'$($Latest.FileVersion)'"
        }
     }

}

function global:au_GetLatest {
    $download_page = Invoke-WebRequest -Uri $releases
    $version = $download_page.Links | Where-Object href -Match "winrar-x32-\d+.exe" | Select-Object -First 1 -ExpandProperty innerhtml
    $version = ([regex]::Match($version,'\(32 bit\) (.+)</[bB]>')).Captures.Groups[1].value
    $fileVersion = $version.Replace('.','')
    @{
      Version = $version
      FileVersion = $fileVersion
    }
}

update -ChecksumFor none
