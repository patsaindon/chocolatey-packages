import-module au

#Virtual package uses dependency updater to get the version
. $PSScriptRoot\..\mariadb.install\update.ps1

function global:au_SearchReplace {
  @{
        "$($Latest.PackageName).nuspec" = @{
            "(\<dependency .+?`"$($Latest.PackageName).install`" version=)`"([^`"]+)`"" = "`$1`"[$($Latest.Version)]`""
            "(?i)(^\s*\<releaseNotes\>).*(\<\/releaseNotes\>)" = "`${1}$($Latest.ReleaseNotes)`${2}"
          }
    }
 }

# Left empty intentionally to override BeforeUpdate in mariadb.install
function global:au_BeforeUpdate { }

update -ChecksumFor None -NoCheckUrl
