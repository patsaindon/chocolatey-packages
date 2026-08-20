$ErrorActionPreference = 'Stop'

$packageName = 'CHANGE_ME'
$toolsDir    = "$(Split-Path -Parent $MyInvocation.MyCommand.Definition)"

# TODO: replace with the real install logic for this internal package.
# Examples: Install-ChocolateyZipPackage, Install-ChocolateyInstallPackage,
# or a direct copy of files bundled in tools\.
