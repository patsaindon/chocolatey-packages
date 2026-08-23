[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]
    $InstallerPath,

    [Parameter(Mandatory)]
    [string]
    $Switches,

    # Some bootstrapper EXEs download files mid-install -- off by
    # default since a disposable, network-isolated sandbox is the
    # safer default for something you don't yet trust.
    [switch]
    $AllowNetwork,

    [string]
    $WorkDir = (Join-Path $env:TEMP 'SilentTestKit')
)

# Verifies a candidate silent-install switch is real before it reaches
# a production package -- the same "don't guess, confirm against a real
# source" principle as every discovery tool in this repo, taken one
# step further: an actual, isolated install run, not just a plausible-
# looking string from a forum post or an AI chat.
#
# This is a human-run, interactive tool, not something the headless
# package-request pipeline can call directly -- Windows Sandbox opens a
# real GUI window and needs an interactive desktop session, which the
# self-hosted GitHub Actions runner (a Windows service account, no
# interactive session) doesn't have. It's meant to be run locally by
# whoever is about to approve a package-request PR that introduces a
# new or previously-unverified silent switch -- see docs/architecture.md
# and prospecting/README.md for where this fits in the review flow.

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $InstallerPath -PathType Leaf)) {
    throw "No such file: $InstallerPath"
}
$resolvedInstaller = (Resolve-Path -LiteralPath $InstallerPath).Path
$installerDir = Split-Path -Parent $resolvedInstaller
$installerFileName = Split-Path -Leaf $resolvedInstaller

try {
    $feature = Get-WindowsOptionalFeature -Online -FeatureName 'Containers-DisposableClientVM' -ErrorAction Stop
    if ($feature.State -ne 'Enabled') {
        throw "Windows Sandbox isn't enabled on this machine. Run as Administrator: Enable-WindowsOptionalFeature -Online -FeatureName 'Containers-DisposableClientVM' -All, then restart."
    }
} catch [Microsoft.Management.Infrastructure.CimException] {
    # Querying optional features itself needs an elevated or capable
    # session on some setups -- not fatal to the check itself, since
    # launching the .wsb file below will fail with its own clear error
    # if the feature really is missing. Warn and continue rather than
    # block on a check that couldn't run.
    Write-Warning "Couldn't confirm Windows Sandbox is enabled (ignore if you already know it is): $($_.Exception.Message)"
}

if (Test-Path $WorkDir) { Remove-Item -Path $WorkDir -Recurse -Force }
New-Item -Path $WorkDir -ItemType Directory -Force | Out-Null

# The in-sandbox script -- runs entirely inside the disposable VM via
# the .wsb's LogonCommand. Snapshots installed programs before and
# after the install so "it exited 0" and "it actually installed
# something" are checked separately -- confirmed by testing elsewhere
# in this repo's own packaging work that a clean exit code alone isn't
# proof of a real install (some installers exit 0 having done nothing,
# e.g. silently rejecting an unsupported OS/arch).
$runTestScript = @'
$ErrorActionPreference = 'Stop'
$resultPath = 'C:\SilentTestKit\result.txt'
$installerPath = 'C:\Installer\__INSTALLER_FILENAME__'
$switches = '__SWITCHES__'

function Get-InstalledProgramNames {
    $roots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    $names = @()
    foreach ($root in $roots) {
        if (Test-Path $root) {
            $names += Get-ChildItem $root | ForEach-Object {
                (Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).DisplayName
            } | Where-Object { $_ }
        }
    }
    return @($names | Sort-Object -Unique)
}

$before = Get-InstalledProgramNames

$startArgs = @{
    FilePath     = $installerPath
    ArgumentList = $switches
    PassThru     = $true
    Wait         = $true
}
$exitCode = $null
$processError = $null
try {
    $proc = Start-Process @startArgs
    $exitCode = $proc.ExitCode
} catch {
    $processError = $_.Exception.Message
}

# A short settle delay -- some installers finish their own process
# before Add/Remove Programs registration is fully written.
Start-Sleep -Seconds 3
$after = Get-InstalledProgramNames
$newEntries = @($after | Where-Object { $before -notcontains $_ })

$lines = @(
    "Silent-Test Kit result"
    "======================"
    "Installer: $installerPath"
    "Switches:  $switches"
    "Ran at:    $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    ""
    "Exit code: $(if ($null -ne $exitCode) { $exitCode } else { 'N/A (process failed to start)' })"
    "Process launch error: $(if ($processError) { $processError } else { 'none' })"
    ""
    "New Add/Remove Programs entries detected: $(if ($newEntries.Count -gt 0) { 'YES' } else { 'NONE DETECTED' })"
)
if ($newEntries.Count -gt 0) {
    $lines += $newEntries | ForEach-Object { "  - $_" }
}
Set-Content -Path $resultPath -Value $lines -Encoding UTF8

# Closes the sandbox automatically once the result is safely written --
# "closes on its own logic" from the guide. A short grace period so the
# result file write above is flushed to the mapped host folder first.
shutdown.exe /s /t 5 /c "Silent-Test Kit finished -- see result.txt on the host"
'@

$runTestScript = $runTestScript.Replace('__INSTALLER_FILENAME__', $installerFileName).Replace('__SWITCHES__', $Switches)
Set-Content -Path (Join-Path $WorkDir 'RunTest.ps1') -Value $runTestScript -Encoding UTF8

$networkingMode = if ($AllowNetwork) { 'Default' } else { 'Disable' }
$wsbXml = @"
<Configuration>
  <VGpu>Disable</VGpu>
  <Networking>$networkingMode</Networking>
  <MappedFolders>
    <MappedFolder>
      <HostFolder>$installerDir</HostFolder>
      <SandboxFolder>C:\Installer</SandboxFolder>
      <ReadOnly>true</ReadOnly>
    </MappedFolder>
    <MappedFolder>
      <HostFolder>$WorkDir</HostFolder>
      <SandboxFolder>C:\SilentTestKit</SandboxFolder>
      <ReadOnly>false</ReadOnly>
    </MappedFolder>
  </MappedFolders>
  <LogonCommand>
    <Command>powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\SilentTestKit\RunTest.ps1</Command>
  </LogonCommand>
</Configuration>
"@

$wsbPath = Join-Path $WorkDir 'SilentTest.wsb'
Set-Content -Path $wsbPath -Value $wsbXml -Encoding UTF8

Write-Host "Launching Windows Sandbox to test '$installerFileName' with switches '$Switches'..."
Write-Host "(networking: $networkingMode)"
Start-Process -FilePath $wsbPath

Write-Host "`nWatch the sandbox window -- it will close on its own once the test finishes."
Write-Host "Result will be waiting at: $(Join-Path $WorkDir 'result.txt')"
