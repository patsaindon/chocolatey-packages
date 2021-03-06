$ErrorActionPreference = 'Stop'

$toolsDir = Split-Path $MyInvocation.MyCommand.Definition

$installerFile = Get-Item "$toolsDir\*_x64.exe"

$packageArgs = @{
  packageName    = $env:ChocolateyPackageName
  fileType       = 'exe'
  file           = $installerFile
  silentArgs     = '/S'
  validExitCodes = @(0, 1223)
}
Install-ChocolateyInstallPackage @packageArgs
Remove-Item ($toolsDir + '\*.' + $packageArgs.fileType)

$pp = Get-PackageParameters
if ($pp.Language) {
    Write-Host 'Setting langauge to' $pp.Language
    mkdir -force HKCU:\Software\VideoLAN\VLC
    Set-ItemProperty HKCU:\Software\VideoLAN\VLC Lang $pp.Language
}

$packageName = $packageArgs.packageName
$installLocation = Get-AppInstallLocation $packageName
if ($installLocation)  {
    Write-Host "$packageName installed to '$installLocation'"
    Register-Application "$installLocation\$packageName.exe"
    Write-Host "$packageName registered as $packageName"
}
else { Write-Warning "Can't find $PackageName install location" }

