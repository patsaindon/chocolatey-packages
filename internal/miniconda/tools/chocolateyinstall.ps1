$ErrorActionPreference = 'Stop'

$toolsPath = Split-Path $MyInvocation.MyCommand.Definition
# url/checksum are left empty here on purpose: update.ps1's au_SearchReplace
# fills them in from au_GetLatest's result at update time. Committing this
# file with empty url/checksum is the normal, expected state for an AU
# package — do not fill them in by hand.
$packageArgs = @{
  packageName    = 'miniconda'
  fileType       = 'exe'                # adjust: exe / msi / msu
  url            = 'https://repo.anaconda.com/miniconda/Miniconda3-py314_26.5.3-2-Windows-x86_64.exe'
  softwareName   = 'miniconda*'         # part of/whole software name, for uninstall registry lookup
  checksum       = '4441b50816f866f4e6e774e90f90a71bde756f06c94144407a6d93677c539e46'
  checksumType   = 'sha256'
  silentArgs     = '/S'
  validExitCodes = @(0)
}

Install-ChocolateyPackage @packageArgs
