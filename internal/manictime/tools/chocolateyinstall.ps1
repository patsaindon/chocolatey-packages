$ErrorActionPreference = 'Stop'

$toolsPath = Split-Path $MyInvocation.MyCommand.Definition
# url/checksum are left empty here on purpose: update.ps1's au_SearchReplace
# fills them in from au_GetLatest's result at update time. Committing this
# file with empty url/checksum is the normal, expected state for an AU
# package — do not fill them in by hand.
$packageArgs = @{
  packageName    = 'manictime'
  fileType       = 'exe'                # adjust: exe / msi / msu
  url            = ''
  softwareName   = 'manictime*'         # part of/whole software name, for uninstall registry lookup
  checksum       = ''
  checksumType   = 'sha256'
  silentArgs     = '/S'                 # adjust for this installer's actual silent-install flag
  validExitCodes = @(0)
}

Install-ChocolateyPackage @packageArgs
