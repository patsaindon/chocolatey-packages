[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$PackageDir
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\SimpleYaml.ps1')

# Validates an internal package folder before `choco pack` runs — see
# docs/architecture.md section 9.3. Checks structure, required nuspec
# metadata, and that template placeholders were actually filled in.
# Collects every violation and reports them together rather than failing
# on the first one, so a packager isn't stuck fixing issues one at a time.

if (-not (Test-Path $PackageDir)) {
    throw "PackageDir '$PackageDir' does not exist."
}
$PackageDir = (Resolve-Path $PackageDir).Path
$folderName = (Split-Path -Leaf $PackageDir.TrimEnd('\', '/'))

$violations = [System.Collections.Generic.List[string]]::new()

function Test-NotTemplatePlaceholder {
    param([string]$Value, [string]$FieldDescription)
    if ($null -eq $Value -or $Value -match 'CHANGE_ME') {
        $violations.Add("$FieldDescription is still the template placeholder ('$Value') — fill it in.")
        return $false
    }
    return $true
}

# --- nuspec presence & well-formedness --------------------------------
$nuspecFiles = @(Get-ChildItem -Path $PackageDir -Filter '*.nuspec' -File)
if ($nuspecFiles.Count -eq 0) {
    $violations.Add("No .nuspec file found directly under $PackageDir.")
} elseif ($nuspecFiles.Count -gt 1) {
    $violations.Add("Expected exactly one .nuspec file under $PackageDir, found $($nuspecFiles.Count): $($nuspecFiles.Name -join ', ').")
} else {
    $nuspecFile = $nuspecFiles[0]

    # AU (see internal/README.md) discovers a package by nuspec *filename*,
    # not just the <id> element — confirmed by actually running update.ps1
    # against a mismatched folder/filename, which failed with "No nuspec
    # file found" until the filename matched the folder name.
    $nuspecBaseName = [System.IO.Path]::GetFileNameWithoutExtension($nuspecFile.Name)
    if ($nuspecBaseName -ne $folderName) {
        $violations.Add("$($nuspecFile.Name) filename does not match folder name '$folderName' — AU won't discover this package until they match.")
    }

    try {
        [xml]$nuspec = Get-Content $nuspecFile.FullName -Raw
    } catch {
        $violations.Add("$($nuspecFile.Name) is not well-formed XML: $($_.Exception.Message)")
        $nuspec = $null
    }

    if ($nuspec) {
        $metadata = $nuspec.package.metadata
        if (-not $metadata) {
            $violations.Add("$($nuspecFile.Name) has no <metadata> element under <package>.")
        } else {
            foreach ($field in 'id', 'version', 'title', 'authors', 'owners', 'description') {
                $val = $metadata.$field
                if ([string]::IsNullOrWhiteSpace($val)) {
                    $violations.Add("<$field> is missing or empty in $($nuspecFile.Name).")
                } else {
                    Test-NotTemplatePlaceholder -Value $val -FieldDescription "<$field> in $($nuspecFile.Name)" | Out-Null
                }
            }

            if (-not [string]::IsNullOrWhiteSpace($metadata.id) -and $metadata.id -ne $folderName) {
                $violations.Add("<id>$($metadata.id)</id> does not match folder name '$folderName'.")
            }

            if (-not [string]::IsNullOrWhiteSpace($metadata.version) -and
                $metadata.version -notmatch '^\d+(\.\d+){1,3}(-[0-9A-Za-z.\-]+)?$') {
                $violations.Add("<version>$($metadata.version)</version> is not a valid NuGet/Chocolatey version string.")
            }

            # Promotion (Get-PromotionCandidates.ps1) reads dependency ids
            # straight from this element -- an empty id there would silently
            # break that recursive-include logic rather than fail loudly, so
            # it's worth catching here instead.
            $depNodes = @($metadata.dependencies.dependency)
            foreach ($dep in $depNodes) {
                if ($null -eq $dep) { continue }
                if ([string]::IsNullOrWhiteSpace($dep.id)) {
                    $violations.Add("$($nuspecFile.Name) has a <dependency> with no 'id' attribute.")
                }
            }
        }
    }
}

# --- metadata.yml -------------------------------------------------------
$metadataYmlPath = Join-Path $PackageDir 'metadata.yml'
if (-not (Test-Path $metadataYmlPath)) {
    $violations.Add("metadata.yml is missing (needed for owner/lifecycle tags — see docs/architecture.md section 6.1).")
} else {
    $meta = Get-Content $metadataYmlPath | ConvertFrom-SimpleYaml
    if ([string]::IsNullOrWhiteSpace($meta.owner)) {
        $violations.Add("metadata.yml has no 'owner' field set.")
    } else {
        Test-NotTemplatePlaceholder -Value $meta.owner -FieldDescription "'owner' in metadata.yml" | Out-Null
    }
    if (-not [string]::IsNullOrWhiteSpace($meta.packageId) -and $meta.packageId -ne $folderName) {
        $violations.Add("metadata.yml packageId '$($meta.packageId)' does not match folder name '$folderName'.")
    }
}

# --- install script -------------------------------------------------------
# Note: url/checksum are *expected* to be empty in tools\chocolateyinstall.ps1
# as committed — update.ps1's au_SearchReplace fills them in at update time.
# That's not something to lint for; CHANGE_ME below is.
$installScript = Join-Path $PackageDir 'tools\chocolateyinstall.ps1'
if (-not (Test-Path $installScript)) {
    $violations.Add("tools\chocolateyinstall.ps1 is missing.")
} elseif ((Get-Content $installScript -Raw) -match 'CHANGE_ME') {
    $violations.Add("tools\chocolateyinstall.ps1 still contains the template placeholder ('CHANGE_ME') — packageName/softwareName were never filled in.")
}

# --- AU update script -----------------------------------------------------
$updateScript = Join-Path $PackageDir 'update.ps1'
if (-not (Test-Path $updateScript)) {
    $violations.Add("update.ps1 is missing (required for AU-based updates — see internal/README.md).")
} elseif ((Get-Content $updateScript -Raw) -match 'CHANGE_ME') {
    $violations.Add("update.ps1 still contains the template placeholder ('CHANGE_ME') — au_GetLatest was never pointed at a real release source.")
}

if ($violations.Count -gt 0) {
    Write-Host "lint-nuspec.ps1 found $($violations.Count) issue(s) in $PackageDir :"
    foreach ($v in $violations) { Write-Host "  - $v" }
    exit 1
}

Write-Host "lint-nuspec.ps1: $folderName passed."
exit 0
