[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]
    $Name,

    [Parameter(Mandatory)]
    [string]
    $Version,

    [Parameter(Mandatory)]
    [string]
    $TestRepo,

    [Parameter(Mandatory)]
    [string]
    $ProdRepo,

    [Parameter(Mandatory)]
    [string]
    $ProdRepoApiKey
)

# Promotes a single package/version already approved for promotion (see
# promotions/pending.yml and docs/architecture.md section 9.4): downloads
# it from staging, re-scans it (a second, independent scan from whatever
# ran at internalize/AU-update time -- a new CVE could have been disclosed
# since), and pushes it on to production. Exits non-zero on any failure so
# the calling workflow (promote-approved-packages.yml) knows to leave this
# entry queued for retry rather than dropping it silently.

$ErrorActionPreference = 'Stop'
$tempPath = Join-Path -Path $env:TEMP -ChildPath ([GUID]::NewGuid()).GUID

try {
    Write-Verbose "Downloading package '$Name' version '$Version' to '$tempPath'."
    # --version is required here: without it, choco download always grabs
    # whatever's latest in $TestRepo regardless of which version this
    # queue entry is actually for (see Update-ProdRepoFromTest.ps1's own
    # history of this exact bug, fixed the same way).
    choco download $Name --no-progress --version=$Version --output-directory=$tempPath --source=$TestRepo --force --ignore-dependencies
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Could not download package '$Name' version '$Version' from '$TestRepo'."
        exit 1
    }

    $pkgPath = (Get-Item -Path (Join-Path -Path $tempPath -ChildPath '*.nupkg')).FullName

    & (Join-Path $PSScriptRoot 'scan-package.ps1') -PackagePath $tempPath
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "'$Name' $Version failed re-scan (exit $LASTEXITCODE) -- not promoting."
        exit 1
    }

    Write-Verbose "Pushing '$(Split-Path -Path $pkgPath -Leaf)' to production repository '$ProdRepo'."
    choco push $pkgPath --source=$ProdRepo --api-key=$ProdRepoApiKey --force
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Could not push package '$Name' $Version to '$ProdRepo'."
        exit 1
    }

    Write-Host "Promoted '$Name' $Version to production."
}
finally {
    Remove-Item -Path $tempPath -Recurse -Force -ErrorAction SilentlyContinue
}
