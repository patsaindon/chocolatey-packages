$ErrorActionPreference = 'Stop'

# Refreshes grype's local vulnerability DB once, serially, before any
# parallel package processing starts (test_all.ps1 / update_all.ps1 both
# run their AU updates across Threads = 10 background jobs).
#
# Found by testing a real CI run: with no single up-front refresh, every
# package's own scan-package.ps1 -> grype invocation independently
# triggers grype's own auto-update-if-stale logic. Ten of those racing at
# once against the same on-disk DB cache produced this real failure:
#   grype: [0221]  WARN error updating db error=unable to activate new
#   vulnerability database: failed to purge existing database: unlinkat
#   ...\grype\db\6\vulnerability.db: The process cannot access the file
#   because it is being used by another process.
# which left the DB missing its import metadata file -- and every scan
# afterwards (any package, not just the one that lost the race) then
# failed to load the DB at all, exit code 1, which scan-package.ps1's own
# generic non-zero-exit handling misreports as "vulnerability found"
# (a real detection) rather than "grype couldn't run" (an infra failure).
# That combination silently turned an infra outage into what looked like
# a mass real-security-finding, blocking every internal package's Nexus
# mirror step at once.
#
# `grype db delete` (idempotent; a no-op if nothing's there) followed by
# `grype db update` is grype's own documented recovery for exactly the
# "no import metadata file" state its error message names. Doing that
# once here, before Threads=10 workers start, removes the race window
# entirely -- see scan-package.ps1's GRYPE_DB_AUTO_UPDATE=false, which
# stops each individual scan from ever attempting its own concurrent
# update again.
if (-not (Get-Command grype -ErrorAction SilentlyContinue)) {
    throw "grype not found on PATH. Install it on this runner (e.g. 'choco install grype') -- see https://github.com/anchore/grype."
}

Write-Host "Refreshing grype vulnerability DB (serialized, before parallel package processing)..."
& grype db delete 2>&1 | ForEach-Object { Write-Host "  grype db delete: $_" }
& grype db update 2>&1 | ForEach-Object { Write-Host "  grype db update: $_" }
if ($LASTEXITCODE -ne 0) {
    throw "grype db update failed (exit $LASTEXITCODE) -- every package's scan step will fail to load the vulnerability DB until this is resolved. See output above."
}
Write-Host "grype vulnerability DB is current."
