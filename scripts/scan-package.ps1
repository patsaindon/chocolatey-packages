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

# Mirrors every diagnostic line this script prints to the same fixed log
# file update.ps1's own au_BeforeUpdateLog already writes to
# (test-internal-packages.yml's "Show Nexus-mirror diagnostic log" step
# dumps it unconditionally, if: always()) -- found missing by a real CI
# failure (vdhcoapp, 2026-08-24): a scan genuinely failed ("Scan failed
# for ...vdhcoapp-win7-x86_64-installer.exe. See output above."), but
# every Write-Host line this script had printed to explain *why* --
# which AV/CVE check failed, grype's own VULN lines -- was gone from the
# captured job log by the time CI surfaced the error, because AU
# discards a failed package's own captured output stream (the same
# known limitation au_BeforeUpdateLog itself already works around for
# au_BeforeUpdate's own messages -- this script just never had the same
# treatment). Best-effort: a log write failing here must never fail the
# scan itself, so errors are swallowed silently.
function Write-ScanLog {
    param([string]$Message)
    Write-Host $Message
    try {
        $line = "[$([DateTime]::UtcNow.ToString('o'))] [scan-package] $Message"
        Add-Content -Path (Join-Path ([System.IO.Path]::GetTempPath()) 'nexus-mirror-debug.log') -Value $line -Encoding utf8 -ErrorAction Stop
    } catch {
        # Logging is a diagnostic nicety, not a scan requirement.
    }
}

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

    Write-ScanLog "  AV scan: $FilePath"
    # Same 2>&1 redirection as Invoke-VulnScan's grype call, and for the
    # same reason: an unredirected stderr line from this native command
    # would, under this script's own $ErrorActionPreference = 'Stop', be
    # auto-promoted into an uncaught terminating exception regardless of
    # MpCmdRun's actual exit code.
    #
    # Captured (not discarded via Out-Null) and logged below -- found by
    # testing a real CI run: multiple unrelated, legitimate vendor
    # installers got flagged with exit code 2 ("threat found") on this
    # runner in a single day, one of them (the same exact binary, same
    # run) passing on 3 of 5 repeated scans. A bare true/false gave no way
    # to tell a real detection from Defender's own heuristic flakiness --
    # this is the minimum needed to actually diagnose that.
    #
    # Serialized below -- the same root cause and fix shape as
    # scripts/Initialize-GrypeDb.ps1's grype DB race:
    # test_all.ps1/update_all.ps1 run Threads=10 packages in parallel
    # (separate AU background-job processes, not just threads in one
    # process -- an in-process lock alone did not stop this), each
    # independently invoking MpCmdRun.exe, whose engine/IPC doesn't
    # tolerate that reliably.
    #
    # 45 minutes of wait (below) came from testing: 15 minutes, tried
    # first, worked (zero AV false positives across 15 packages, versus
    # 5-11 before) but was too short for a real queue of ~12 scans -- 3
    # packages legitimately timed out waiting, and the one right behind
    # them barely made it in at 16.7 minutes. 45 minutes gives real
    # headroom above that observed worst case while staying well inside
    # GitHub Actions' own default 6-hour job timeout, so a genuinely stuck
    # MpCmdRun (not just a long queue) still fails the run rather than
    # hanging it indefinitely. This only serializes MpCmdRun's own scan
    # call, not the download/upload around it, so total added wall time
    # per run is bounded by (scan count) x (single scan duration), not
    # (scan count)^2.
    #
    # A named System.Threading.Mutex -- Global\ or session-local alike --
    # turned out not to be portable across this fleet's runners at all:
    # found by testing real CI runs on a second self-hosted runner added
    # mid-day, where even a plain (non-Global\) named mutex failed
    # construction with "Exception calling '.ctor' with '2' argument(s):
    # Access to the path 'ChocolateyPackagesMpCmdRunScan' is denied" --
    # that runner's service account apparently can't create *any* named
    # kernel object, global or session-local. Rather than chase further
    # privilege differences between runners, this uses a plain lock file
    # in %TEMP% instead: ordinary file I/O, which every runner in this
    # fleet is already proven to do successfully (the debug log this
    # function writes to via Write-ScanLog is itself proof). Windows
    # enforces FileShare.None exclusively across processes, not just
    # threads, so this gives the same cross-process serialization a mutex
    # would -- confirmed a real problem in the first place by testing:
    # test_all.ps1/update_all.ps1 run Threads=10 packages in parallel
    # (separate AU background-job processes), each independently invoking
    # MpCmdRun.exe, and its engine/IPC doesn't tolerate concurrent
    # on-demand scans reliably (spurious exit code 2 -- 11 of 15 packages
    # flagged in one real run alone, including two that had scanned clean
    # minutes earlier, with Get-MpThreatDetection's own history staying
    # empty throughout despite the "detections").
    #
    # A lock file surviving a crashed scan would otherwise deadlock every
    # future run forever (unlike a Mutex, which the OS releases when its
    # owning process dies) -- treated as abandoned and removed once older
    # than 10 minutes, comfortably longer than any single real scan
    # observed so far (the slowest so far: LibreOffice's ~300MB installer
    # at a little over 3 minutes).
    $mpCmdRunLockPath = Join-Path ([System.IO.Path]::GetTempPath()) 'ChocolateyPackagesMpCmdRunScan.lock'
    $mpCmdRunLockStream = $null
    $mpCmdRunLockDeadline = (Get-Date).AddMinutes(45)
    while (-not $mpCmdRunLockStream) {
        try {
            $mpCmdRunLockStream = [System.IO.File]::Open($mpCmdRunLockPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        } catch [System.IO.IOException] {
            $lockAgeMinutes = $null
            try {
                $lockAgeMinutes = ((Get-Date) - (Get-Item -LiteralPath $mpCmdRunLockPath -ErrorAction Stop).LastWriteTimeUtc).TotalMinutes
            } catch {
                # Lock file vanished between the failed Open and this check
                # (another scan just finished) -- just retry the Open.
            }
            if ($lockAgeMinutes -and $lockAgeMinutes -gt 10) {
                Write-ScanLog "  MpCmdRun: lock file is over 10 minutes old -- treating it as abandoned by a crashed scan and removing it."
                Remove-Item -LiteralPath $mpCmdRunLockPath -Force -ErrorAction SilentlyContinue
                continue
            }
            if ((Get-Date) -ge $mpCmdRunLockDeadline) {
                throw "Timed out after 45 minutes waiting for exclusive access to MpCmdRun.exe -- another scan appears stuck holding it."
            }
            Start-Sleep -Seconds 2
        }
    }
    try {
        $mpCmdRunOutput = & $mpCmdRun -Scan -ScanType 3 -File $FilePath -DisableRemediation 2>&1
        $mpCmdRunExitCode = $LASTEXITCODE
    } finally {
        $mpCmdRunLockStream.Close()
        Remove-Item -LiteralPath $mpCmdRunLockPath -Force -ErrorAction SilentlyContinue
    }
    # Exit code 0 = clean, 2 = threat found. Anything else is an execution error.
    if ($mpCmdRunExitCode -eq 2) {
        $mpCmdRunOutput | ForEach-Object { Write-ScanLog "  MpCmdRun: $_" }
        # MpCmdRun's own console output rarely names the detected threat;
        # Get-MpThreatDetection (the Defender PowerShell module, built into
        # Windows alongside MpCmdRun.exe) is the actual source of that.
        # Best-effort only -- never let a diagnostics lookup fail the scan
        # verdict itself.
        try {
            $threat = Get-MpThreatDetection -ErrorAction Stop |
                Sort-Object InitialDetectionTime -Descending | Select-Object -First 1
            if ($threat) {
                Write-ScanLog "  MpCmdRun: most recent detection -- ThreatID=$($threat.ThreatID) Resources=$($threat.Resources -join ', ')"
            }
        } catch {
            Write-ScanLog "  MpCmdRun: Get-MpThreatDetection unavailable ($($_.Exception.Message))"
        }
        return $false
    } elseif ($mpCmdRunExitCode -ne 0) {
        throw "MpCmdRun.exe exited with unexpected code $mpCmdRunExitCode while scanning $FilePath"
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
        Write-ScanLog "  Grype scan: $ExtractedDir"
        # Explicitly redirects stderr (2>&1) rather than leaving it
        # unredirected -- found by testing a real CI-only failure: with
        # $ErrorActionPreference = 'Stop' (set at the top of this script),
        # ANY unredirected stderr line from a native command (here: a
        # benign syft/grype WARN, "no explicit name and version provided
        # for directory source...", which this dir-based scan always
        # triggers) is auto-wrapped by PowerShell into a non-terminating
        # ErrorRecord and then promoted into an uncaught terminating
        # exception -- independent of grype's own actual exit code. That
        # killed the entire calling chain (au_BeforeUpdate's Nexus-mirror
        # step, inside AU's own Start-Job) with no AU error message at all,
        # since the exception never reached AU's own error handling.
        # Redirecting merges stderr into this captured output instead,
        # sidestepping that promotion entirely; each line is then just
        # logged plainly below.
        #
        # GRYPE_DB_AUTO_UPDATE=false -- found by testing a real CI run:
        # test_all.ps1/update_all.ps1 run Threads=10 packages in parallel,
        # each independently invoking this function, and grype's own
        # default auto-update-if-stale behavior let up to 10 of those race
        # to update the same on-disk DB cache at once. That race corrupted
        # it (a purge failing mid-update because another process held the
        # file open), which then made every scan on the runner fail to
        # load the DB at all -- misreported below as "no vulnerability
        # matches" rather than the real cause. The DB is instead refreshed
        # exactly once, serially, before any parallel work starts -- see
        # scripts/Initialize-GrypeDb.ps1.
        $env:GRYPE_DB_AUTO_UPDATE = 'false'
        $grypeOutput = & grype "dir:$ExtractedDir" -o json --file $reportPath --fail-on $MinSeverity 2>&1
        $grypeExitCode = $LASTEXITCODE
        $grypeOutput | ForEach-Object { Write-ScanLog "  grype: $_" }
        Write-ScanLog "  Grype exit code: $grypeExitCode"
        $report = Get-Content $reportPath -Raw | ConvertFrom-Json

        $severityOrder = @('Negligible', 'Low', 'Medium', 'High', 'Critical')
        $minIndex = $severityOrder.IndexOf($MinSeverity)
        $flagged = @($report.matches | Where-Object {
            $sev = $_.vulnerability.severity
            $sev -and ($severityOrder.IndexOf($sev) -ge $minIndex)
        })

        foreach ($m in $flagged) {
            Write-ScanLog "  VULN: $($m.vulnerability.id) [$($m.vulnerability.severity)] in $($m.artifact.name)@$($m.artifact.version)"
        }

        # A non-zero exit with nothing actually flagged means grype never
        # completed a real scan (DB load failure, crash, etc.) rather than
        # having found and reported a match -- surfaced distinctly so this
        # isn't mistaken for a real finding like the "FAIL: vulnerability
        # ... found" case above it, should Initialize-GrypeDb.ps1 not have
        # run, or the DB break again for some other reason.
        if ($grypeExitCode -ne 0 -and $flagged.Count -eq 0) {
            Write-ScanLog "  GRYPE EXECUTION FAILURE: grype exited $grypeExitCode without completing a scan (see the 'grype:' lines above) -- this is NOT a real vulnerability finding. Still failing the scan (an unscanned binary can't be trusted), but investigate the grype/DB error above, not the package."
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
    Write-ScanLog "Scanning $($rawFile.Name) (raw file)..."

    if (-not (Invoke-AvScan -FilePath $rawFile.FullName)) {
        Write-ScanLog "  FAIL: AV threat detected in $($rawFile.Name)"
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
                Write-ScanLog "  FAIL: vulnerability at or above '$MinSeverity' found in $($rawFile.Name)"
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
    Write-ScanLog "$($rawFile.Name) passed AV + vulnerability (>= $MinSeverity) scanning."
    exit 0
}

$packages = Get-ChildItem -Path $PackagePath -Filter '*.nupkg' -File
if (-not $packages) {
    throw "No .nupkg files found under $PackagePath"
}

foreach ($pkg in $packages) {
    Write-ScanLog "Scanning $($pkg.Name)..."

    if (-not (Invoke-AvScan -FilePath $pkg.FullName)) {
        Write-ScanLog "  FAIL: AV threat detected in $($pkg.Name)"
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
            Write-ScanLog "  FAIL: vulnerability at or above '$MinSeverity' found in $($pkg.Name)"
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

Write-ScanLog "All packages passed AV + vulnerability (>= $MinSeverity) scanning."
exit 0
