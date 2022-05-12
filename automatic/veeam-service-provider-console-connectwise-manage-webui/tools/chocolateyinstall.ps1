﻿$ErrorActionPreference = 'Stop';
$toolsDir     = "$(Split-Path -parent $MyInvocation.MyCommand.Definition)"

$isoPackageName = 'veeam-service-provider-console-iso'
$scriptPath = $(Split-Path -parent $MyInvocation.MyCommand.Definition)
$commonPath = $(Split-Path -parent $(Split-Path -parent $scriptPath))
$filename = 'VeeamServiceProviderConsole_6.0.0.7739_20210917.iso'
$installPath = Join-Path  (Join-Path $commonPath $isoPackageName) $filename

$fileLocation = 'Plugins\ConnectWise\Manage\VAC.ConnectorWebUI.x64.msi'

$packageArgs = @{
  packageName    = $env:ChocolateyPackageName
  isoFile        = $installPath
  softwareName   = 'Web UI for Veeam ConnectWise Manage Plugin*'
  file           = $fileLocation
  fileType       = 'msi'
  silentArgs     = "ACCEPT_EULA=1 ACCEPT_THIRDPARTY_LICENSES=1 /qn /norestart /l*v `"$env:TEMP\$env:ChocolateyPackageName.$env:ChocolateyPackageVersion.log`""
  validExitCodes = @(0,1638,1641,3010) #1638 was added to allow updating when an newer version is already installed.
  destination    = $toolsDir
}

Install-ChocolateyIsoInstallPackage @packageArgs

