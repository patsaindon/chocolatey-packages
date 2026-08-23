$ErrorActionPreference = 'Stop'

$toolsDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
# url/checksum are left empty here on purpose: update.ps1's au_SearchReplace
# fills them in from au_GetLatest's result at update time. Committing this
# file with empty url/checksum is the normal, expected state for an AU
# package — do not fill them in by hand.
$packageArgs = @{
  packageName  = 'codegraphcontext'
  url          = ''
  checksum     = ''
  checksumType = 'sha256'
  # Renames the downloaded binary to this stable filename -- Chocolatey
  # auto-shims any .exe under tools\ onto PATH, so this is also the
  # command name 'cgc' users get after install.
  fileFullPath = "$toolsDir\cgc.exe"
}

Get-ChocolateyWebFile @packageArgs
