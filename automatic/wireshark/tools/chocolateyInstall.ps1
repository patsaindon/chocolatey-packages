﻿$ErrorActionPreference = 'Stop';

$toolsDir       = "$(Split-Path -parent $MyInvocation.MyCommand.Definition)"

$packageArgs = @{
  packageName    = $env:ChocolateyPackageName
  fileType       = 'exe'
  file          = "$toolsDir\Wireshark-win32-3.6.5.exe"
  file64        = "$toolsDir\Wireshark-win64-3.6.5.exe"
  softwareName  = 'Wireshark*'
  silentArgs     = '/S /quicklaunchicon=no'
  validExitCodes = @(0)
}

Install-ChocolateyInstallPackage @packageArgs

Get-ChildItem $toolsDir\*.exe | ForEach-Object { Remove-Item $_ -ea 0; if (Test-Path $_) { Set-Content "$_.ignore" } }
