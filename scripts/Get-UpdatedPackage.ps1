[CmdletBinding()]
  Param (
      [Parameter(Mandatory)]
      [string]
      $LocalRepo,

      [Parameter(Mandatory)]
      [string]
      $LocalRepoApiKey,

      [Parameter(Mandatory)]
      [string]
      $RemoteRepo

  )

  . (Join-Path $PSScriptRoot 'ConvertTo-ChocoObject.ps1')

  Write-Verbose "Getting list of local packages from '$LocalRepo'."
  $localPkgs = choco search --source=$LocalRepo --limit-output | ConvertTo-ChocoObject
  Write-Verbose "Retrieved list of $(($localPkgs).count) packages from '$Localrepo'."

  $localPkgs | ForEach-Object {
      $pkgName = $_.name
      $localVersion = $_.version
      try {
          Write-Verbose "Getting remote package information for '$pkgName'."
          $remotePkg = choco search $pkgName --source=$RemoteRepo --exact --limit-output | ConvertTo-ChocoObject

          if (-not $remotePkg -or -not $remotePkg.version) {
              # Package may have been removed/renamed upstream — don't let a
              # missing match crash the rest of the batch (an unguarded
              # [version] cast on $null throws and previously stopped this
              # whole ForEach-Object here).
              Write-Warning "Package '$pkgName' not found on remote '$RemoteRepo' (exact match) — skipping."
              return
          }

          if ([version]$remotePkg.version -gt [version]$localVersion) {
              Write-Verbose "Package '$pkgName' has a remote version of '$($remotePkg.version)' which is later than the local version '$localVersion'."
              Write-Verbose "Internalizing package '$pkgName' with version '$($remotePkg.version)'."
              $tempPath = Join-Path -Path $env:TEMP -ChildPath ([GUID]::NewGuid()).GUID
              choco download $pkgName --no-progress --internalize --force --internalize-all-urls --append-use-original-location --output-directory=$tempPath --source=$RemoteRepo

              if ($LASTEXITCODE -eq 0) {
                  # Scan before pushing anywhere — this step was missing
                  # entirely until a real end-to-end test against a live
                  # feed showed nothing between download and push actually
                  # checked the result (docs/architecture.md sections 6.7/
                  # 9.2 already claimed this happened; it didn't).
                  & (Join-Path $PSScriptRoot 'scan-package.ps1') -PackagePath $tempPath
                  if ($LASTEXITCODE -ne 0) {
                      Write-Warning "scan-package.ps1 flagged '$pkgName' (exit $LASTEXITCODE) — not pushing."
                      Remove-Item -Path $tempPath -Recurse -Force -ErrorAction SilentlyContinue
                      return
                  }

                  Write-Verbose "Pushing package '$pkgName' to local repository '$LocalRepo'."
                  (Get-Item -Path (Join-Path -Path $tempPath -ChildPath "*.nupkg")).fullname | ForEach-Object {
                      choco push $_ --source=$LocalRepo --api-key $LocalRepoApiKey --force
                      if ($LASTEXITCODE -eq 0) {
                          Write-Verbose "Package '$_' pushed to '$LocalRepo'."
                      }
                      else {
                          Write-Verbose "Package '$_' could not be pushed to '$LocalRepo'.`nThis could be because it already exists in the repository at a higher version and can be mostly ignored. Check error logs."
                      }
                  }
              }
              else {
                  Write-Verbose "Failed to download package '$pkgName'"
              }
              Remove-Item -Path $tempPath -Recurse -Force -ErrorAction SilentlyContinue
          }
          else {
              Write-Verbose "Package '$pkgName' has a remote version of '$($remotePkg.version)' which is not later than the local version '$localVersion'."
          }
      } catch {
          Write-Warning "Package '$pkgName' failed with an unexpected error — skipping: $($_.Exception.Message)"
      }
  }