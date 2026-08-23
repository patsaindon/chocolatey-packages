[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]
    $Path,

    # Emit the result as JSON instead of a formatted console object --
    # what get-installer-signals.js (the MCP tool wrapping this script)
    # asks for, so it can parse a single structured value instead of
    # scraping formatted text.
    [switch]
    $Json,

    # EXE string-scanning reads the whole file into memory -- some
    # bootstrappers bundle a full runtime and run 100+ MB. Capped by
    # default so a single call stays fast and bounded; raised explicitly
    # when a bigger installer genuinely needs deeper scanning.
    [int]
    $MaxScanBytes = 50MB
)

# Companion to the Switch-Finder AI Prompt Pack's prompts 2/3 (Static
# Signal Interpreter for MSI/EXE): pulls whatever a silent-switch guess
# can be grounded in -- an MSI's own Property table, or an EXE's
# embedded strings -- without ever running the installer. Read-only,
# same safety principle as every other discovery tool in this repo
# (get_winget_package_manifest, get_community_package_tools): report
# real signals from the file itself, never guess past what was actually
# found.
#
# This intentionally stops at *signals*, not a final answer -- an MSI's
# Property table doesn't by itself prove ALLUSERS=1 is safe for every
# deployment, and matching "Nullsoft" in an EXE's strings is evidence of
# NSIS, not a guarantee the vendor didn't customize its switch handling.
# Treat the output as what to feed an AI prompt or a human's own
# judgment, not as a switch already confirmed -- that confirmation is
# what New-SilentTestKit.ps1 (a genuine, isolated install) is for.

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "No such file: $Path"
}
$resolvedPath = (Resolve-Path -LiteralPath $Path).Path
$extension = [System.IO.Path]::GetExtension($resolvedPath).ToLowerInvariant()

function Get-MsiSignals {
    param([string]$MsiPath)

    # The Windows Installer COM API opens an MSI as a structured-storage
    # database directly -- msiOpenDatabaseModeReadOnly (0) never invokes
    # any install sequence, so this is exactly as safe as opening the
    # file in a hex editor, just structured.
    $installer = New-Object -ComObject WindowsInstaller.Installer
    $db = $installer.OpenDatabase($MsiPath, 0)

    $properties = [ordered]@{}
    $view = $db.OpenView('SELECT `Property`, `Value` FROM `Property`')
    $view.Execute()
    while ($true) {
        $record = $view.Fetch()
        if (-not $record) { break }
        $name = $record.StringData(1)
        $value = $record.StringData(2)
        $properties[$name] = $value
    }
    $view.Close()

    # SummaryInformation stream -- Template (property 7) reveals the
    # target architecture/platform (e.g. "Intel;1033" vs "x64;1033"),
    # useful for flagging an architecture mismatch before it becomes a
    # silent-install failure.
    $template = $null
    try {
        $summaryInfo = $db.SummaryInformation(0)
        $template = $summaryInfo.Property(7)
    } catch {
        # Not fatal -- some MSIs omit summary properties entirely.
    }

    [pscustomobject]@{
        Path             = $MsiPath
        Type             = 'MSI'
        ProductName      = $properties['ProductName']
        ProductVersion   = $properties['ProductVersion']
        Manufacturer     = $properties['Manufacturer']
        ProductCode      = $properties['ProductCode']
        UpgradeCode      = $properties['UpgradeCode']
        Template         = $template
        AllProperties    = $properties
        RecommendedCommandLine = 'msiexec /i "<path>" /qn /norestart' + $(if ($properties.Contains('MSIFASTINSTALL')) { '' } else { '' })
        Notes            = @(
            if ($properties['ALLUSERS'] -eq '1') { "ALLUSERS=1 already set in the package -- a per-machine install is the default, no extra property needed." }
            elseif ($properties.Contains('ALLUSERS')) { "ALLUSERS='$($properties['ALLUSERS'])' -- confirm this matches the deployment scope intended (0=per-user, 1/2=per-machine)." }
            if ($properties.Contains('REBOOT')) { "REBOOT='$($properties['REBOOT'])' already set by the package." }
        )
    }
}

# Known installer-framework fingerprints -- each is a string (or byte
# marker) that framework's bootstrapper reliably embeds, found by
# checking real installers built with each tool. Ordered by
# specificity: a hit on a more specific marker (e.g. WiX's literal
# ".wixburn" section name) is trusted over a looser one.
$frameworkSignatures = [ordered]@{
    'WiX Burn bootstrapper' = @('.wixburn', 'WixBundle', 'wixstdba')
    'InstallShield'         = @('InstallShield', 'isetup.dll', '_ISDel', 'InstallShield Wizard')
    'Inno Setup'            = @('Inno Setup', 'InnoSetupLdrWindow', 'jr_ansi', 'InnoSetupVersion')
    'NSIS (Nullsoft)'       = @('NullsoftInst', 'Nullsoft Install System', 'NSIS Error')
    'InstallAware'          = @('InstallAware', 'IAWebInstall')
    'Squirrel'              = @('SquirrelSetup', 'Squirrel.exe', 'squirrel.exe')
    # Found missing by real testing against a genuine Advanced
    # Installer-built EXE (Caphyon DriverFusion) -- it embeds its own
    # vendor name plainly but matched none of the frameworks above,
    # silently falling through to "no framework detected" instead.
    'Advanced Installer'    = @('Advanced Installer', 'Caphyon')
}

# The switch syntax each framework's own installers standardly accept
# -- reported as a starting guess only, per the prompt pack's own
# framing ("first guess... 2-3 fallback options"), never as confirmed.
$frameworkDefaultSwitches = @{
    'WiX Burn bootstrapper' = @('/quiet /norestart', '/passive')
    'InstallShield'         = @('/s /v"/qn"', '/s /v/qn')
    'Inno Setup'            = @('/VERYSILENT /NORESTART', '/SILENT /NORESTART')
    'NSIS (Nullsoft)'       = @('/S', '/S /D=<install path> (must be last argument, no quotes)')
    'InstallAware'          = @('/s /qn')
    'Squirrel'              = @('--silent')
    # Advanced Installer projects can be configured either as a
    # standard MSI or as a "Simple" bootstrapper -- both accept the
    # same switches as a plain MSI would, since Advanced Installer
    # wraps rather than replaces the Windows Installer engine.
    'Advanced Installer'    = @('/i "<path>" /qn /norestart (same as a plain MSI)', '/exenoui /qn /norestart')
}

function Get-ExeSignals {
    param([string]$ExePath, [int]$MaxBytes)

    $fileInfo = Get-Item -LiteralPath $ExePath
    $bytesToRead = [Math]::Min($fileInfo.Length, $MaxBytes)
    $truncated = $fileInfo.Length -gt $bytesToRead

    $stream = [System.IO.File]::OpenRead($ExePath)
    try {
        $buffer = New-Object byte[] $bytesToRead
        [void]$stream.Read($buffer, 0, $bytesToRead)
    } finally {
        $stream.Close()
    }

    # ASCII runs of 5+ printable characters -- the same heuristic the
    # `strings` utility uses. Unicode (UTF-16LE) runs are also common in
    # PE resources (version info, dialog text), so both encodings get
    # scanned rather than just ASCII, which was found to miss framework
    # markers stored as wide strings in some installers.
    $ascii = [System.Text.Encoding]::ASCII.GetString($buffer)
    $unicode = [System.Text.Encoding]::Unicode.GetString($buffer)
    $asciiStrings = [regex]::Matches($ascii, '[\x20-\x7E]{5,}') | ForEach-Object { $_.Value }
    $unicodeStrings = [regex]::Matches($unicode, '[\x20-\x7E]{5,}') | ForEach-Object { $_.Value }
    $allStrings = @($asciiStrings) + @($unicodeStrings)

    $matchedFrameworks = [ordered]@{}
    foreach ($framework in $frameworkSignatures.Keys) {
        $hits = @()
        foreach ($marker in $frameworkSignatures[$framework]) {
            if ($allStrings -match [regex]::Escape($marker) | Select-Object -First 1) {
                $hits += $marker
            }
        }
        if ($hits.Count -gt 0) { $matchedFrameworks[$framework] = $hits }
    }

    $detectedFramework = $null
    $confidence = 'None'
    $candidateSwitches = @()
    if ($matchedFrameworks.Count -gt 0) {
        # Most markers matched wins; a tie is reported as ambiguous
        # rather than picked arbitrarily -- guessing wrong here is
        # exactly the failure mode this tool exists to avoid.
        $ranked = $matchedFrameworks.GetEnumerator() | Sort-Object { $_.Value.Count } -Descending
        $top = @($ranked)[0]
        $tiedWithTop = @($ranked | Where-Object { $_.Value.Count -eq $top.Value.Count })
        if ($tiedWithTop.Count -eq 1) {
            $detectedFramework = $top.Key
            $confidence = if ($top.Value.Count -ge 2) { 'High' } else { 'Medium' }
            $candidateSwitches = $frameworkDefaultSwitches[$detectedFramework]
        } else {
            $detectedFramework = ($tiedWithTop | ForEach-Object { $_.Key }) -join ' / '
            $confidence = 'Low (ambiguous -- multiple frameworks equally matched)'
        }
    }

    # Strings that look switch-related regardless of which framework was
    # detected -- catches vendor-custom switches a generic framework
    # guess would miss entirely (e.g. a custom "/NOUPDATE" flag baked
    # into a WiX-wrapped installer). Found by real testing that a purely
    # shape-based regex (leading /- , then letters/digits) matched mostly
    # noise from compressed/binary regions -- random fragments like
    # "-cywcd" or "-Dwd9" that happen to fit the shape. Real switches
    # (/S, /VERYSILENT, --silent, /qn) are consistently either all-upper
    # or all-lower and never mix in digits; requiring that consistency
    # cut the noise out while still matching every real example in the
    # prompt pack's own switch list.
    $switchShapePattern = '^[/-]{1,2}[A-Za-z][A-Za-z_-]{0,20}$'
    $notableStrings = @($allStrings | Where-Object {
        if ($_ -notmatch $switchShapePattern) { return $false }
        $token = $_ -replace '^[/-]{1,2}', ''
        ($token -cmatch '^[A-Z_-]+$') -or ($token -cmatch '^[a-z_-]+$')
    } | Sort-Object -Unique | Select-Object -First 40)

    [pscustomobject]@{
        Path                = $ExePath
        Type                = 'EXE'
        ScanTruncated       = $truncated
        BytesScanned        = $bytesToRead
        DetectedFramework   = $detectedFramework
        Confidence          = $confidence
        MatchedSignatures   = $matchedFrameworks
        CandidateSwitches   = $candidateSwitches
        NotableSwitchLikeStrings = $notableStrings
    }
}

$result = switch ($extension) {
    '.msi' { Get-MsiSignals -MsiPath $resolvedPath }
    default { Get-ExeSignals -ExePath $resolvedPath -MaxBytes $MaxScanBytes }
}

if ($Json) {
    $result | ConvertTo-Json -Depth 6
} else {
    $result
}
