[CmdletBinding()]

  Param (
      [Parameter(Mandatory)]
      [string]
      $ProdRepo,

      [Parameter(Mandatory)]
      [string]
      $ProdRepoApiKey,

      [Parameter(Mandatory)]
      [string]
      $TestRepo
  )

  . (Join-Path $PSScriptRoot 'ConvertTo-ChocoObject.ps1')

  # get all of the packages from the test repo
  $testPkgs = choco search --source=$TestRepo --all-versions --limit-output | ConvertTo-ChocoObject
  $prodPkgs = choco search --source=$ProdRepo --all-versions --limit-output | ConvertTo-ChocoObject

  if ($null -eq $testPkgs) {
      Write-Verbose "Test repository appears to be empty. Nothing to push to production."
  }
  elseif ($null -eq $prodPkgs) {
      $pkgs = $testPkgs
  }
  else {
      $pkgs = Compare-Object -ReferenceObject $testPkgs -DifferenceObject $prodPkgs -Property name, version | Where-Object SideIndicator -eq '<='
  }

  $pkgs | ForEach-Object {
      $pkgName = $_.name
      # A fresh temp dir per package — reusing one $tempPath across iterations
      # (as the original script did) meant every download landed in the same
      # folder, so `Get-Item *.nupkg` could match a previous iteration's file
      # and cleanup at the end of the loop would remove a dir subsequent
      # iterations still expected to exist.
      $tempPath = Join-Path -Path $env:TEMP -ChildPath ([GUID]::NewGuid()).GUID

      try {
          Write-Verbose "Downloading package '$pkgName' to '$tempPath'."
          choco download $pkgName --no-progress --output-directory=$tempPath --source=$TestRepo --force --ignore-dependencies
          if ($LASTEXITCODE -ne 0) {
              Write-Warning "Could not download package '$pkgName'."
              return
          }

          $pkgPath = (Get-Item -Path (Join-Path -Path $tempPath -ChildPath '*.nupkg')).FullName

          # Re-scan (AV + Grype) here too, not just at the original internalize/
          # publish step — a new CVE can be disclosed against software that
          # hasn't itself changed since it was scanned into test. See
          # docs/architecture.md section 9.5.
          & (Join-Path $PSScriptRoot 'scan-package.ps1') -PackagePath $tempPath
          $testExitCode = $LASTEXITCODE

          if ($testExitCode -eq 0) {
              Write-Verbose "Pushing downloaded package '$(Split-Path -Path $pkgPath -Leaf)' to production repository '$ProdRepo'."
              choco push $pkgPath --source=$ProdRepo --api-key=$ProdRepoApiKey --force
              if ($LASTEXITCODE -eq 0) {
                  Write-Verbose "Pushed package successfully."
              }
              else {
                  Write-Warning "Could not push package '$pkgName' to '$ProdRepo'."
              }
          }
          else {
              Write-Warning "Package testing failed for '$pkgName' (scan-package.ps1 exit code $testExitCode) — not promoting."
          }
      } catch {
          Write-Warning "Package '$pkgName' failed with an unexpected error — skipping: $($_.Exception.Message)"
      } finally {
          Remove-Item -Path $tempPath -Recurse -Force -ErrorAction SilentlyContinue
      }
  }
