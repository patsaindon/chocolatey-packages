[CmdletBinding()]
param(
    [string]$ResultsPath = '.\update-check-results.json',
    [string]$BaseBranch = 'main',
    [string]$ManifestDir = '.\internalized\'
)

$ErrorActionPreference = 'Stop'

# Consumes the JSON written by check-upstream-versions.ps1 and opens one PR
# per outdated package, bumping pinnedVersion in its internalize.yml. Merging
# that PR is what actually triggers re-internalization — this script never
# pushes straight to main and never touches staging/production feeds.
# See docs/architecture.md section 9.2.
#
# Requires: git configured with push access to origin (the workflow's
# GITHUB_TOKEN needs `permissions: contents: write, pull-requests: write`),
# and GH_TOKEN set in the environment for `gh`.

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw "gh (GitHub CLI) not found on PATH."
}
if (-not $env:GH_TOKEN -and -not $env:GITHUB_TOKEN) {
    throw "GH_TOKEN (or GITHUB_TOKEN) must be set for gh to authenticate."
}

if (-not (Test-Path $ResultsPath)) {
    Write-Host "No results file at $ResultsPath — nothing to do."
    exit 0
}

$raw = Get-Content $ResultsPath -Raw
$updates = @()
if (-not [string]::IsNullOrWhiteSpace($raw)) {
    $updates = @(ConvertFrom-Json $raw)
}

if ($updates.Count -eq 0) {
    Write-Host "No outdated packages — nothing to do."
    exit 0
}

# Ensure a git identity exists for the commit (ephemeral runners may have none).
if (-not (git config user.email)) {
    git config user.email 'github-actions[bot]@users.noreply.github.com'
}
if (-not (git config user.name)) {
    git config user.name 'github-actions[bot]'
}

git fetch origin $BaseBranch | Out-Null

$failures = [System.Collections.Generic.List[string]]::new()

foreach ($update in $updates) {
    $packageId = $update.packageId
    $latest = $update.latestVersion
    $branchSuffix = ($latest -replace '[^A-Za-z0-9.\-]', '-')
    $branch = "bump/$packageId-$branchSuffix"

    Write-Host "=== $packageId : $($update.pinnedVersion) -> $latest ==="

    $existingRemote = git ls-remote --heads origin $branch
    if ($existingRemote) {
        Write-Host "  Branch '$branch' already exists on origin — skipping (already has an open PR or a prior run handled it)."
        continue
    }

    $manifestPath = Join-Path (Join-Path $ManifestDir $update.folder) 'internalize.yml'
    if (-not (Test-Path $manifestPath)) {
        $failures.Add("${packageId}: manifest not found at $manifestPath")
        continue
    }

    try {
        git checkout -B $branch "origin/$BaseBranch" | Out-Null

        $content = Get-Content $manifestPath -Raw
        $pattern = '(?m)^(\s*pinnedVersion:\s*)("(?:[^"]*)"|\S+)\s*$'
        if ($content -notmatch $pattern) {
            $failures.Add("${packageId}: could not find a pinnedVersion line to update in $manifestPath")
            git checkout $BaseBranch | Out-Null
            continue
        }
        # There's exactly one pinnedVersion: line in a well-formed manifest,
        # so the plain (pattern, evaluator) overload is sufficient — no
        # static Regex.Replace overload accepts a match-count limit alongside
        # a MatchEvaluator.
        $evaluator = [System.Text.RegularExpressions.MatchEvaluator]{ param($m) "$($m.Groups[1].Value)`"$latest`"" }
        $newContent = [regex]::Replace($content, $pattern, $evaluator)
        Set-Content -Path $manifestPath -Value $newContent -Encoding utf8 -NoNewline

        git add $manifestPath
        git commit -m "Bump $packageId to $latest" | Out-Null
        git push origin $branch | Out-Null

        $body = "Upstream Community Repository has $packageId@$latest; this manifest is pinned to $($update.pinnedVersion).`n`nOwner: $($update.owner)`n`nMerging this PR does not touch staging or production — it only updates the pinned version. The next internalize run (manual dispatch or the next scheduled check) will re-internalize $packageId@$latest and push it to staging for scanning. See docs/architecture.md section 9.2."

        gh pr create `
            --base $BaseBranch `
            --head $branch `
            --title "Bump $packageId to $latest" `
            --body $body

        Write-Host "  Opened PR for $packageId."
    } catch {
        $failures.Add("${packageId}: $($_.Exception.Message)")
    } finally {
        git checkout $BaseBranch 2>$null | Out-Null
    }
}

if ($failures.Count -gt 0) {
    Write-Warning "Failed to open PRs for $($failures.Count) package(s):"
    foreach ($f in $failures) { Write-Warning "  - $f" }
    exit 1
}

exit 0
