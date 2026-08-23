[CmdletBinding(DefaultParameterSetName = 'PackageDir')]
param(
    [Parameter(Mandatory, ParameterSetName = 'PackageDir')]
    [string]$PackagePath,

    # Scans one raw, not-yet-packaged file directly (e.g. an installer
    # just downloaded from a vendor, before it's mirrored to Nexus --
    # Section 15's Nexus-mirror generalization) instead of a directory of
    # already-built .nupkg files. Added because the existing nupkg mode
    # only ever sees what a nupkg embeds; a "thin" AU-packed nupkg that
    # just references a URL has nothing real for Grype to scan at all --
    # the actual binary has to be scanned before it becomes a package.
    [Parameter(Mandatory, ParameterSetName = 'RawFile')]
    [string]$RawFilePath,

    # Grype severities: Negligible, Low, Medium, High, Critical.
    # Any match at or above this severity fails the scan.
    [ValidateSet('Negligible', 'Low', 'Medium', 'High', 'Critical')]
    [string]$MinSeverity = 'High'
)

$ErrorActionPreference = 'Stop'

# Targets:
#   - Nexus Repository OSS (no Nexus IQ license) — see docs/architecture.md section 6.7.
#   - AV: Windows Defender via MpCmdRun.exe (built into Windows, no extra license).
#   - CVE: Grype (open-source SCA scanner, https://github.com/anchore/grype),
#     run against each package's extracted contents.
#
# Any AV detection or any Grype match >= $MinSeverity fails this script
# (non-zero exit), which halts the calling workflow before the package is
# pushed to staging.

function Get-MpCmdRunPath {
    $candidates = @(
        (Join-Path $env:ProgramFiles 'Windows Defender\MpCmdRun.exe')
    )
    $platformRoot = Join-Path $env:ProgramData 'Microsoft\Windows Defender\Platform'
    if (Test-Path $platformRoot) {
        $latest = Get-ChildItem $platformRoot -Directory |
            Sort-Object Name -Descending | Select-Object -First 1
        if ($latest) { $candidates += (Join-Path $latest.FullName 'MpCmdRun.exe') }
    }
    foreach ($c in $candidates) { if (Test-Path $c) { return $c } }
    return $null
}

function Invoke-AvScan {
    param([string]$FilePath)

    $mpCmdRun = Get-MpCmdRunPath
    if (-not $mpCmdRun) {
        throw "MpCmdRun.exe not found. Windows Defender must be installed and enabled on this runner (or swap this function for whatever AV product is in use)."
    }

    Write-Host "  AV scan: $FilePath"
    & $mpCmdRun -Scan -ScanType 3 -File $FilePath -DisableRemediation | Out-Null
    # Exit code 0 = clean, 2 = threat found. Anything else is an execution error.
    if ($LASTEXITCODE -eq 2) {
        return $false
    } elseif ($LASTEXITCODE -ne 0) {
        throw "MpCmdRun.exe exited with unexpected code $LASTEXITCODE while scanning $FilePath"
    }
    return $true
}

function Invoke-VulnScan {
    param([string]$ExtractedDir)

    if (-not (Get-Command grype -ErrorAction SilentlyContinue)) {
        throw "grype not found on PATH. Install it on this runner (e.g. 'choco install grype') — see https://github.com/anchore/grype."
    }

    $reportPath = [System.IO.Path]::GetTempFileName()
    try {
        Write-Host "  Grype scan: $ExtractedDir"
        & grype "dir:$ExtractedDir" -o json --file $reportPath --fail-on $MinSeverity
        $grypeExitCode = $LASTEXITCODE
        Write-Host "  Grype exit code: $grypeExitCode"
        $report = Get-Content $reportPath -Raw | ConvertFrom-Json

        $severityOrder = @('Negligible', 'Low', 'Medium', 'High', 'Critical')
        $minIndex = $severityOrder.IndexOf($MinSeverity)
        $flagged = @($report.matches | Where-Object {
            $sev = $_.vulnerability.severity
            $sev -and ($severityOrder.IndexOf($sev) -ge $minIndex)
        })

        foreach ($m in $flagged) {
            Write-Host "  VULN: $($m.vulnerability.id) [$($m.vulnerability.severity)] in $($m.artifact.name)@$($m.artifact.version)"
        }

        # grype's --fail-on already sets a non-zero exit code when matches meet
        # the threshold; treat that (or our own re-check above) as authoritative.
        return ($grypeExitCode -eq 0 -and $flagged.Count -eq 0)
    } finally {
        Remove-Item $reportPath -ErrorAction SilentlyContinue
    }
}

$failed = $false

if ($PSCmdlet.ParameterSetName -eq 'RawFile') {
    if (-not (Test-Path -LiteralPath $RawFilePath -PathType Leaf)) {
        throw "No such file: $RawFilePath"
    }
    $rawFile = Get-Item -LiteralPath $RawFilePath
    Write-Host "Scanning $($rawFile.Name) (raw file)..."

    if (-not (Invoke-AvScan -FilePath $rawFile.FullName)) {
        Write-Host "  FAIL: AV threat detected in $($rawFile.Name)"
        $failed = $true
    } else {
        # Grype scans a whole directory's contents -- copied into its own
        # isolated temp folder first so a caller's file sitting alongside
        # unrelated files (e.g. a busy Downloads folder) doesn't get every
        # one of those neighbors scanned and reported on too.
        $isolatedDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName())
        New-Item -ItemType Directory -Path $isolatedDir | Out-Null
        try {
            Copy-Item $rawFile.FullName -Destination $isolatedDir
            if (-not (Invoke-VulnScan -ExtractedDir $isolatedDir)) {
                Write-Host "  FAIL: vulnerability at or above '$MinSeverity' found in $($rawFile.Name)"
                $failed = $true
            }
        } finally {
            Remove-Item $isolatedDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    if ($failed) {
        Write-Error "Scan failed for $RawFilePath. See output above."
        exit 1
    }
    Write-Host "$($rawFile.Name) passed AV + vulnerability (>= $MinSeverity) scanning."
    exit 0
}

$packages = Get-ChildItem -Path $PackagePath -Filter '*.nupkg' -File
if (-not $packages) {
    throw "No .nupkg files found under $PackagePath"
}

foreach ($pkg in $packages) {
    Write-Host "Scanning $($pkg.Name)..."

    if (-not (Invoke-AvScan -FilePath $pkg.FullName)) {
        Write-Host "  FAIL: AV threat detected in $($pkg.Name)"
        $failed = $true
        continue
    }

    $extractDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName())
    New-Item -ItemType Directory -Path $extractDir | Out-Null
    try {
        $zipCopy = "$extractDir.zip"
        Copy-Item $pkg.FullName $zipCopy
        Expand-Archive -Path $zipCopy -DestinationPath $extractDir -Force
        Remove-Item $zipCopy -ErrorAction SilentlyContinue

        if (-not (Invoke-VulnScan -ExtractedDir $extractDir)) {
            Write-Host "  FAIL: vulnerability at or above '$MinSeverity' found in $($pkg.Name)"
            $failed = $true
        }
    } finally {
        Remove-Item $extractDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($failed) {
    Write-Error "Scan failed for one or more packages under $PackagePath. See output above."
    exit 1
}

Write-Host "All packages passed AV + vulnerability (>= $MinSeverity) scanning."
exit 0
